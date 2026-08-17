import 'dart:convert';
import 'dart:typed_data';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../format/pdf_lexer.dart';
import '../format/pdf_object.dart';
import '../io/byte_reader.dart';
import 'pdf_gfx_state.dart';
import 'pdf_matrix.dart';
import 'pdf_output_device.dart';

/// Interpretador de fluxos de comandos gráficos de conteúdo PDF (`/Contents`).
class PdfContentInterpreter {
  final PdfOutputDevice device;
  final PdfDict? resources;
  final PdfResolver? resolver;

  final List<PdfGfxState> _stateStack = [];
  PdfGfxState _state = PdfGfxState();

  PathBuilder _pathBuilder = PathBuilder();
  bool _hasPath = false;
  bool _clipEvenOdd = false;
  bool _pendingClip = false;

  PdfContentInterpreter({
    required this.device,
    this.resources,
    this.resolver,
  });

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

      case 'Tj': // Draw Text String
        if (args.isNotEmpty) {
          final text = _extractStringText(args[0]);
          device.drawText(text, _state, _state.textMatrix);
        }
        break;

      case 'TJ': // Draw Text Array com ajustes de espaçamento
        if (args.isNotEmpty) {
          final buf = StringBuffer();
          for (final item in args) {
            if (item.type == PdfTokenType.string ||
                item.type == PdfTokenType.hexString) {
              buf.write(_extractStringText(item));
            }
          }
          device.drawText(buf.toString(), _state, _state.textMatrix);
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
                  imgBytes, w, h, const Rect.fromLTWH(0, 0, 1, 1), _state);
            }
          }
        }
        break;
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

  double _toDouble(PdfToken token) => token.numberValue?.toDouble() ?? 0.0;
  int _toInt(PdfToken token) => token.numberValue?.toInt() ?? 0;
}
