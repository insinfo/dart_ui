import 'dart:convert';
import 'dart:typed_data';

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../font/pdf_cmap.dart';
import '../format/pdf_lexer.dart';
import '../format/pdf_object.dart';
import '../io/byte_reader.dart';
import 'pdf_gfx_state.dart';
import 'pdf_matrix.dart';
import 'pdf_output_device.dart';

/// Interpretador de fluxos de comandos gráficos de conteúdo PDF (`/Contents`).
class PdfContentInterpreter {
  PdfContentInterpreter({
    required this.device,
    this.resources,
    this.resolver,
    PdfGfxState? initialState,
    int nestingDepth = 0,
  })  : _state = initialState ?? PdfGfxState(),
        _nestingDepth = nestingDepth;

  final PdfOutputDevice device;
  final PdfDict? resources;
  final PdfResolver? resolver;
  final int _nestingDepth;

  final List<PdfGfxState> _stateStack = <PdfGfxState>[];
  PdfGfxState _state;

  PathBuilder _pathBuilder = PathBuilder();
  bool _hasPath = false;
  bool _clipEvenOdd = false;
  bool _pendingClip = false;
  final Map<String, PdfCMap?> _toUnicodeMaps = <String, PdfCMap?>{};

  PdfGfxState get currentState => _state;

  /// Executa o fluxo de comandos binários do Content Stream.
  void execute(Uint8List contents) {
    if (contents.isEmpty) return;

    final lexer = PdfLexer(ByteReader(contents));
    final operands = <PdfToken>[];

    while (true) {
      final token = lexer.nextToken();
      if (token.type == PdfTokenType.eof) break;

      if (token.type == PdfTokenType.keyword) {
        final op = token.text;
        _executeOperator(op, operands);
        operands.clear();
      } else {
        operands.add(token);
      }
    }
  }

  void _executeOperator(String op, List<PdfToken> args) {
    switch (op) {
      // --- Estado Gráfico ---
      case 'q': // Salva estado gráfico
        _stateStack.add(_state.clone());
        device.saveState();
        break;

      case 'Q': // Restaura estado gráfico
        if (_stateStack.isNotEmpty) {
          _state = _stateStack.removeLast();
          device.restoreState();
        }
        break;

      case 'cm': // Concatena matriz de transformação
        if (args.length >= 6) {
          final m = PdfMatrix(
            _toDouble(args[0]),
            _toDouble(args[1]),
            _toDouble(args[2]),
            _toDouble(args[3]),
            _toDouble(args[4]),
            _toDouble(args[5]),
          );
          _state.ctm = _state.ctm.multiply(m);
          device.transform(m);
        }
        break;

      case 'w': // Espessura da linha
        if (args.isNotEmpty) {
          _state.lineWidth = _toDouble(args[0]);
        }
        break;

      case 'J': // Line Cap
        if (args.isNotEmpty) {
          final cap = _toInt(args[0]);
          _state.lineCap = cap == 1
              ? PdfLineCap.round
              : cap == 2
                  ? PdfLineCap.projectingSquare
                  : PdfLineCap.butt;
        }
        break;

      case 'j': // Line Join
        if (args.isNotEmpty) {
          final join = _toInt(args[0]);
          _state.lineJoin = join == 1
              ? PdfLineJoin.round
              : join == 2
                  ? PdfLineJoin.bevel
                  : PdfLineJoin.miter;
        }
        break;

      case 'M': // Miter Limit
        if (args.isNotEmpty) {
          _state.miterLimit = _toDouble(args[0]);
        }
        break;

      case 'd': // Dash pattern and phase.
        final int open =
            args.indexWhere((PdfToken token) => token.isDelimiter('['));
        final int close =
            args.indexWhere((PdfToken token) => token.isDelimiter(']'));
        if (open >= 0 && close > open) {
          _state.dashPattern = <double>[
            for (var i = open + 1; i < close; i++)
              if (args[i].type == PdfTokenType.number) _toDouble(args[i]),
          ];
          if (close + 1 < args.length) {
            _state.dashPhase = _toDouble(args[close + 1]);
          }
        }
        break;

      // --- Construção de Caminhos (Paths) ---
      case 'm': // MoveTo (x y m)
        if (args.length >= 2) {
          final x = _toDouble(args[0]);
          final y = _toDouble(args[1]);
          _pathBuilder.moveTo(x, y);
          _hasPath = true;
        }
        break;

      case 'l': // LineTo (x y l)
        if (args.length >= 2) {
          final x = _toDouble(args[0]);
          final y = _toDouble(args[1]);
          _pathBuilder.lineTo(x, y);
          _hasPath = true;
        }
        break;

      case 'c': // Cubic Bézier (x1 y1 x2 y2 x3 y3 c)
        if (args.length >= 6) {
          _pathBuilder.cubicTo(
            _toDouble(args[0]),
            _toDouble(args[1]),
            _toDouble(args[2]),
            _toDouble(args[3]),
            _toDouble(args[4]),
            _toDouble(args[5]),
          );
          _hasPath = true;
        }
        break;

      case 'v': // Curva com primeiro ponto de controle igual ao ponto inicial
        if (args.length >= 4) {
          _pathBuilder.cubicTo(
            _toDouble(args[0]),
            _toDouble(args[1]),
            _toDouble(args[0]),
            _toDouble(args[1]),
            _toDouble(args[2]),
            _toDouble(args[3]),
          );
          _hasPath = true;
        }
        break;

      case 'y': // Curva com segundo ponto de controle igual ao ponto final
        if (args.length >= 4) {
          _pathBuilder.cubicTo(
            _toDouble(args[0]),
            _toDouble(args[1]),
            _toDouble(args[2]),
            _toDouble(args[3]),
            _toDouble(args[2]),
            _toDouble(args[3]),
          );
          _hasPath = true;
        }
        break;

      case 're': // Retângulo (x y w h re)
        if (args.length >= 4) {
          final x = _toDouble(args[0]);
          final y = _toDouble(args[1]);
          final w = _toDouble(args[2]);
          final h = _toDouble(args[3]);
          _pathBuilder.addRect(Rect.fromLTWH(x, y, w, h));
          _hasPath = true;
        }
        break;

      case 'h': // Fechar subcaminho
        _pathBuilder.close();
        break;

      // --- Recorte (Clipping) ---
      case 'W': // Non-Zero Clipping
        _pendingClip = true;
        _clipEvenOdd = false;
        break;

      case 'W*': // Even-Odd Clipping
        _pendingClip = true;
        _clipEvenOdd = true;
        break;

      // --- Pintura de Caminhos ---
      case 'S': // Stroke path
        _finishPath(stroke: true);
        break;

      case 's': // Close and stroke path
        _pathBuilder.close();
        _finishPath(stroke: true);
        break;

      case 'f':
      case 'F': // Fill path (Non-Zero)
        _finishPath(fill: true, evenOdd: false);
        break;

      case 'f*': // Fill path (Even-Odd)
        _finishPath(fill: true, evenOdd: true);
        break;

      case 'B': // Fill and stroke (Non-Zero)
        _finishPath(fill: true, stroke: true, evenOdd: false);
        break;

      case 'B*': // Fill and stroke (Even-Odd)
        _finishPath(fill: true, stroke: true, evenOdd: true);
        break;

      case 'b': // Close, fill and stroke (Non-Zero)
        _pathBuilder.close();
        _finishPath(fill: true, stroke: true, evenOdd: false);
        break;

      case 'b*': // Close, fill and stroke (Even-Odd)
        _pathBuilder.close();
        _finishPath(fill: true, stroke: true, evenOdd: true);
        break;

      case 'n': // End path without painting
        _finishPath();
        break;

      // --- Cores ---
      case 'g': // Non-stroking Gray
        if (args.isNotEmpty) {
          final gray = (_toDouble(args[0]) * 255).round().clamp(0, 255);
          _state.fillColor = 0xFF000000 | (gray << 16) | (gray << 8) | gray;
        }
        break;

      case 'G': // Stroking Gray
        if (args.isNotEmpty) {
          final gray = (_toDouble(args[0]) * 255).round().clamp(0, 255);
          _state.strokeColor = 0xFF000000 | (gray << 16) | (gray << 8) | gray;
        }
        break;

      case 'rg': // Non-stroking RGB
        if (args.length >= 3) {
          final r = (_toDouble(args[0]) * 255).round().clamp(0, 255);
          final g = (_toDouble(args[1]) * 255).round().clamp(0, 255);
          final b = (_toDouble(args[2]) * 255).round().clamp(0, 255);
          _state.fillColor = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
        break;

      case 'RG': // Stroking RGB
        if (args.length >= 3) {
          final r = (_toDouble(args[0]) * 255).round().clamp(0, 255);
          final g = (_toDouble(args[1]) * 255).round().clamp(0, 255);
          final b = (_toDouble(args[2]) * 255).round().clamp(0, 255);
          _state.strokeColor = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
        break;

      case 'k': // Non-stroking CMYK
        if (args.length >= 4) {
          _state.fillColor = _cmykToRgb(
            _toDouble(args[0]),
            _toDouble(args[1]),
            _toDouble(args[2]),
            _toDouble(args[3]),
          );
        }
        break;

      case 'K': // Stroking CMYK
        if (args.length >= 4) {
          _state.strokeColor = _cmykToRgb(
            _toDouble(args[0]),
            _toDouble(args[1]),
            _toDouble(args[2]),
            _toDouble(args[3]),
          );
        }
        break;

      // --- Texto ---
      case 'BT': // Begin Text
        _state.textMatrix = PdfMatrix.identity;
        _state.textLineMatrix = PdfMatrix.identity;
        break;

      case 'ET': // End Text
        break;

      case 'Tf': // Set Font & Size
        if (args.length >= 2) {
          _state.fontName = args[0].text;
          _state.fontSize = _toDouble(args[1]);
        }
        break;

      case 'Tc':
        if (args.isNotEmpty) _state.charSpacing = _toDouble(args[0]);
        break;

      case 'Tw':
        if (args.isNotEmpty) _state.wordSpacing = _toDouble(args[0]);
        break;

      case 'Tz':
        if (args.isNotEmpty) _state.horizontalScaling = _toDouble(args[0]);
        break;

      case 'TL':
        if (args.isNotEmpty) _state.leading = _toDouble(args[0]);
        break;

      case 'Tr':
        if (args.isNotEmpty) {
          final int mode = _toInt(args[0]).clamp(0, 7);
          _state.textRenderMode = PdfTextRenderMode.values[mode];
        }
        break;

      case 'Ts':
        if (args.isNotEmpty) _state.textRise = _toDouble(args[0]);
        break;

      case 'Tm': // Set Text Matrix
        if (args.length >= 6) {
          final m = PdfMatrix(
            _toDouble(args[0]),
            _toDouble(args[1]),
            _toDouble(args[2]),
            _toDouble(args[3]),
            _toDouble(args[4]),
            _toDouble(args[5]),
          );
          _state.textMatrix = m;
          _state.textLineMatrix = m;
        }
        break;

      case 'Td': // Move Text Position
        if (args.length >= 2) {
          final tx = _toDouble(args[0]);
          final ty = _toDouble(args[1]);
          final tMat = PdfMatrix.translation(tx, ty);
          _state.textLineMatrix = _state.textLineMatrix.multiply(tMat);
          _state.textMatrix = _state.textLineMatrix;
        }
        break;

      case 'TD':
        if (args.length >= 2) {
          final double tx = _toDouble(args[0]);
          final double ty = _toDouble(args[1]);
          _state.leading = -ty;
          final PdfMatrix translation = PdfMatrix.translation(tx, ty);
          _state.textLineMatrix = _state.textLineMatrix.multiply(translation);
          _state.textMatrix = _state.textLineMatrix;
        }
        break;

      case 'T*':
        final PdfMatrix translation = PdfMatrix.translation(0, -_state.leading);
        _state.textLineMatrix = _state.textLineMatrix.multiply(translation);
        _state.textMatrix = _state.textLineMatrix;
        break;

      case 'Tj': // Draw Text String
        if (args.isNotEmpty) {
          _showText(args[0]);
        }
        break;

      case 'TJ': // Draw Text Array com ajustes de espaçamento
        if (args.isNotEmpty) {
          for (final item in args) {
            if (item.type == PdfTokenType.string ||
                item.type == PdfTokenType.hexString) {
              _showText(item);
            } else if (item.type == PdfTokenType.number) {
              _moveText(
                -_toDouble(item) /
                    1000 *
                    _state.fontSize *
                    (_state.horizontalScaling / 100),
              );
            }
          }
        }
        break;

      case "'":
        _executeOperator('T*', const <PdfToken>[]);
        if (args.isNotEmpty) _showText(args[0]);
        break;

      case '"':
        if (args.length >= 3) {
          _state.wordSpacing = _toDouble(args[0]);
          _state.charSpacing = _toDouble(args[1]);
          _executeOperator('T*', const <PdfToken>[]);
          _showText(args[2]);
        }
        break;

      // --- XObjects ---
      case 'Do': // Executa XObject (Imagem ou Form)
        if (args.isNotEmpty && resources != null) {
          final name = args[0].text;
          final xobjects = resources!.getDict('XObject', resolver);
          final xobj = xobjects?.getResolved(name, resolver);
          if (xobj is PdfStream) {
            final subtype = xobj.dict.getName('Subtype', resolver)?.name;
            if (subtype == 'Image') {
              final w = xobj.dict.getNumber('Width', resolver)?.toInt() ?? 1;
              final h = xobj.dict.getNumber('Height', resolver)?.toInt() ?? 1;
              final imgBytes = xobj.getDecodedBytes(resolver);
              device.drawImage(
                imgBytes,
                w,
                h,
                const Rect.fromLTWH(0, 0, 1, 1),
                _state,
                imageDictionary: xobj.dict,
              );
            } else if (subtype == 'Form') {
              _executeForm(xobj);
            }
          }
        }
        break;
    }
  }

  void _executeForm(PdfStream form) {
    if (_nestingDepth >= 32) return;
    final PdfArray? matrix = form.dict.getArray('Matrix', resolver);
    final PdfMatrix formMatrix = matrix != null && matrix.length >= 6
        ? PdfMatrix(
            matrix.getNumber(0, resolver)?.toDouble() ?? 1,
            matrix.getNumber(1, resolver)?.toDouble() ?? 0,
            matrix.getNumber(2, resolver)?.toDouble() ?? 0,
            matrix.getNumber(3, resolver)?.toDouble() ?? 1,
            matrix.getNumber(4, resolver)?.toDouble() ?? 0,
            matrix.getNumber(5, resolver)?.toDouble() ?? 0,
          )
        : PdfMatrix.identity;
    device.saveState();
    device.transform(formMatrix);
    final PdfArray? bounds = form.dict.getArray('BBox', resolver);
    if (bounds != null && bounds.length >= 4) {
      final PathBuilder clip = PathBuilder()
        ..addRect(
          Rect.fromLTRB(
            bounds.getNumber(0, resolver)?.toDouble() ?? 0,
            bounds.getNumber(1, resolver)?.toDouble() ?? 0,
            bounds.getNumber(2, resolver)?.toDouble() ?? 0,
            bounds.getNumber(3, resolver)?.toDouble() ?? 0,
          ),
        );
      device.clip(clip.build());
    }
    try {
      PdfContentInterpreter(
        device: device,
        resources: form.dict.getDict('Resources', resolver) ?? resources,
        resolver: resolver,
        initialState: _state.clone()..ctm = _state.ctm.multiply(formMatrix),
        nestingDepth: _nestingDepth + 1,
      ).execute(form.getDecodedBytes(resolver));
    } finally {
      device.restoreState();
    }
  }

  void _finishPath(
      {bool fill = false, bool stroke = false, bool evenOdd = false}) {
    if (!_hasPath) {
      _pendingClip = false;
      return;
    }

    final path = _pathBuilder.build();

    if (_pendingClip) {
      device.clip(path, evenOdd: _clipEvenOdd);
      _pendingClip = false;
    }

    if (fill && stroke) {
      device.fillAndStrokePath(path, _state, evenOdd: evenOdd);
    } else if (fill) {
      device.fillPath(path, _state, evenOdd: evenOdd);
    } else if (stroke) {
      device.strokePath(path, _state);
    }

    _pathBuilder = PathBuilder();
    _hasPath = false;
  }

  int _cmykToRgb(double c, double m, double y, double k) {
    final r = (255 * (1 - c) * (1 - k)).round().clamp(0, 255);
    final g = (255 * (1 - m) * (1 - k)).round().clamp(0, 255);
    final b = (255 * (1 - y) * (1 - k)).round().clamp(0, 255);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  void _showText(PdfToken token) {
    final String text = _decodeText(token);
    device.drawText(text, _state, _state.textMatrix);
    final Uint8List bytes = token.stringBytes ?? Uint8List(0);
    final List<int> codes = _textCodes(bytes);
    var advance = 0.0;
    for (var i = 0; i < codes.length; i++) {
      final int code = codes[i];
      advance += _glyphWidth(code) / 1000 * _state.fontSize;
      advance += _state.charSpacing;
      if (code == 0x20) advance += _state.wordSpacing;
    }
    _moveText(advance * (_state.horizontalScaling / 100));
  }

  void _moveText(double distance) {
    if (distance == 0) return;
    _state.textMatrix =
        _state.textMatrix.multiply(PdfMatrix.translation(distance, 0));
  }

  List<int> _textCodes(Uint8List bytes) {
    if (!_isCompositeFont || bytes.length < 2) return bytes;
    return <int>[
      for (var i = 0; i < bytes.length; i += 2)
        i + 1 < bytes.length ? bytes[i] << 8 | bytes[i + 1] : bytes[i],
    ];
  }

  bool get _isCompositeFont {
    final PdfDict? font = _currentFont;
    return font?.getName('Subtype', resolver)?.name == 'Type0';
  }

  PdfDict? get _currentFont {
    final String? fontName = _state.fontName;
    if (fontName == null || resources == null) return null;
    final PdfObject? font =
        resources?.getDict('Font', resolver)?.getResolved(fontName, resolver);
    return font is PdfDict ? font : null;
  }

  double _glyphWidth(int code) {
    final PdfDict? font = _currentFont;
    if (font == null) return 500;
    if (font.getName('Subtype', resolver)?.name != 'Type0') {
      final int first = font.getNumber('FirstChar', resolver)?.toInt() ?? 0;
      final PdfArray? widths = font.getArray('Widths', resolver);
      final int index = code - first;
      if (widths != null && index >= 0 && index < widths.length) {
        return widths.getNumber(index, resolver)?.toDouble() ?? 500;
      }
      return font
              .getDict('FontDescriptor', resolver)
              ?.getNumber('MissingWidth', resolver)
              ?.toDouble() ??
          500;
    }
    final PdfObject? descendant =
        font.getArray('DescendantFonts', resolver)?.getResolved(0, resolver);
    if (descendant is! PdfDict) return 1000;
    final PdfArray? widths = descendant.getArray('W', resolver);
    if (widths != null) {
      var index = 0;
      while (index < widths.length) {
        final int? start = widths.getNumber(index++, resolver)?.toInt();
        if (start == null || index >= widths.length) break;
        final PdfObject? next = widths.getResolved(index++, resolver);
        if (next is PdfArray) {
          final int offset = code - start;
          if (offset >= 0 && offset < next.length) {
            return next.getNumber(offset, resolver)?.toDouble() ?? 1000;
          }
        } else if (next is PdfNumber && index < widths.length) {
          final int end = next.asInt;
          final double value =
              widths.getNumber(index++, resolver)?.toDouble() ?? 1000;
          if (code >= start && code <= end) return value;
        }
      }
    }
    return descendant.getNumber('DW', resolver)?.toDouble() ?? 1000;
  }

  String _extractStringText(PdfToken token) {
    if (token.stringBytes != null) {
      try {
        return utf8.decode(token.stringBytes!);
      } catch (_) {
        return String.fromCharCodes(token.stringBytes!);
      }
    }
    return token.text;
  }

  String _decodeText(PdfToken token) {
    final Uint8List? bytes = token.stringBytes;
    if (bytes == null) return _extractStringText(token);
    final String? fontName = _state.fontName;
    if (fontName == null || resources == null || resolver == null) {
      return _extractStringText(token);
    }
    final PdfDict? fontObject = _currentFont;
    if (fontObject == null) return _extractStringText(token);
    final PdfCMap? cmap = _toUnicodeMaps.putIfAbsent(fontName, () {
      final PdfObject? toUnicode =
          fontObject.getResolved('ToUnicode', resolver);
      if (toUnicode is! PdfStream) return null;
      try {
        return PdfCMap.parse(toUnicode.getDecodedBytes(resolver));
      } on Object {
        return null;
      }
    });
    final bool composite =
        fontObject.getName('Subtype', resolver)?.name == 'Type0';
    if (cmap != null) {
      return cmap.decode(bytes, fallbackCodeBytes: composite ? 2 : 1);
    }
    if (composite) {
      final StringBuffer result = StringBuffer();
      for (var i = 0; i < bytes.length; i += 2) {
        final int value =
            i + 1 < bytes.length ? (bytes[i] << 8) | bytes[i + 1] : bytes[i];
        result.write(_safeTextCodePoint(value));
      }
      return result.toString();
    }
    return _decodeWinAnsi(bytes);
  }

  String _decodeWinAnsi(Uint8List bytes) => String.fromCharCodes(
        bytes.map((int value) => _winAnsi[value] ?? value),
      );

  String _safeTextCodePoint(int value) => String.fromCharCode(
        value >= 0 && value <= 0x10FFFF ? value : 0xFFFD,
      );

  static const Map<int, int> _winAnsi = <int, int>{
    0x80: 0x20AC,
    0x82: 0x201A,
    0x83: 0x0192,
    0x84: 0x201E,
    0x85: 0x2026,
    0x86: 0x2020,
    0x87: 0x2021,
    0x88: 0x02C6,
    0x89: 0x2030,
    0x8A: 0x0160,
    0x8B: 0x2039,
    0x8C: 0x0152,
    0x8E: 0x017D,
    0x91: 0x2018,
    0x92: 0x2019,
    0x93: 0x201C,
    0x94: 0x201D,
    0x95: 0x2022,
    0x96: 0x2013,
    0x97: 0x2014,
    0x98: 0x02DC,
    0x99: 0x2122,
    0x9A: 0x0161,
    0x9B: 0x203A,
    0x9C: 0x0153,
    0x9E: 0x017E,
    0x9F: 0x0178,
  };

  double _toDouble(PdfToken token) => token.numberValue?.toDouble() ?? 0.0;
  int _toInt(PdfToken token) => token.numberValue?.toInt() ?? 0;
}
