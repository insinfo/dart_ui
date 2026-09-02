/// Editor de imagem mínimo: desenha com o mouse sobre um bitmap, importa
/// PNG, JPEG, WebP e JPEG 2000 (JP2/J2K) e salva em PNG, JPEG ou JPEG 2000.
///
/// Existe para provar o caminho completo do JPEG 2000 no `dart_ui`: o
/// `decodeImage` reconhece o formato pela assinatura, o adaptador entrega
/// BGRA premultiplicado, e o `package:jpeg2000` codifica de volta o que foi
/// pintado. A barra de estado mostra qual decodificador rodou (o Dart ou o
/// nativo da plataforma), o tempo, e o tamanho do arquivo salvo.
///
/// ```
/// dart run examples/image_editor_demo/main.dart [imagem.jp2]
/// dart run examples/image_editor_demo/main.dart --frames 3   # fumaça
/// ```
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/graphics/image/codecs/image_lib.dart' as image_lib;
import 'package:jpeg2000/jpeg2000.dart' as jp2;

void main(List<String> arguments) {
  FrameworkFonts.install();
  final ApplicationOptions options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'dart_ui Image Editor',
  );
  runApp(
    ImageEditorApp(initialPath: _initialPath(arguments)),
    options: options,
  );
}

String? _initialPath(List<String> arguments) {
  const Set<String> optionsWithValue = <String>{
    '--backend',
    '--presentation',
    '--scale',
    '--frames',
  };
  for (var index = 0; index < arguments.length; index++) {
    final String argument = arguments[index];
    if (optionsWithValue.contains(argument)) {
      index++;
      continue;
    }
    if (!argument.startsWith('--')) return argument;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

/// The bitmap being edited: premultiplied BGRA, the same layout the renderer
/// consumes, so showing it costs no conversion. Brushes paint opaque colours,
/// for which premultiplied and straight are the same bytes.
final class PaintDocument {
  PaintDocument._(this.width, this.height, this.pixels, this.hasAlpha);

  factory PaintDocument.blank(int width, int height) {
    final Uint8List pixels = Uint8List(width * height * 4);
    pixels.fillRange(0, pixels.length, 0xFF);
    return PaintDocument._(width, height, pixels, false);
  }

  factory PaintDocument.fromDecoded(DecodedImage image) {
    final DecodedImage bgra = image.inOrder(ImageChannelOrder.bgra);
    return PaintDocument._(
      bgra.width,
      bgra.height,
      Uint8List.fromList(bgra.pixels),
      bgra.hasAlpha,
    );
  }

  final int width;
  final int height;
  final Uint8List pixels;
  final bool hasAlpha;

  Uint8List snapshot() => Uint8List.fromList(pixels);

  void restore(Uint8List saved) => pixels.setAll(0, saved);

  DecodedImage toDecodedImage() => DecodedImage(
        width: width,
        height: height,
        order: ImageChannelOrder.bgra,
        pixels: pixels,
        hasAlpha: hasAlpha,
      );

  /// Paints a filled disc of [color] (opaque) centred at ([cx], [cy]).
  void stamp(double cx, double cy, double radius, Color color) {
    final int r = color.red;
    final int g = color.green;
    final int b = color.blue;
    final int x0 = math.max(0, (cx - radius).floor());
    final int x1 = math.min(width - 1, (cx + radius).ceil());
    final int y0 = math.max(0, (cy - radius).floor());
    final int y1 = math.min(height - 1, (cy + radius).ceil());
    final double r2 = radius * radius;
    for (var y = y0; y <= y1; y++) {
      final double dy = y + 0.5 - cy;
      for (var x = x0; x <= x1; x++) {
        final double dx = x + 0.5 - cx;
        if (dx * dx + dy * dy > r2) continue;
        final int index = (y * width + x) * 4;
        pixels[index] = b;
        pixels[index + 1] = g;
        pixels[index + 2] = r;
        pixels[index + 3] = 0xFF;
      }
    }
  }

  /// Stamps along the segment so fast strokes stay continuous.
  void stroke(Offset from, Offset to, double radius, Color color) {
    final double distance = (to - from).distance;
    final int steps = math.max(1, (distance / math.max(1, radius / 2)).ceil());
    for (var i = 0; i <= steps; i++) {
      final double t = i / steps;
      stamp(
        from.dx + (to.dx - from.dx) * t,
        from.dy + (to.dy - from.dy) * t,
        radius,
        color,
      );
    }
  }

  /// Straight (non-premultiplied) RGBA, which every file format wants.
  Uint8List straightRgba() {
    final Uint8List out = Uint8List(width * height * 4);
    for (var i = 0; i < out.length; i += 4) {
      final int a = pixels[i + 3];
      if (a == 255) {
        out[i] = pixels[i + 2];
        out[i + 1] = pixels[i + 1];
        out[i + 2] = pixels[i];
        out[i + 3] = 255;
      } else if (a == 0) {
        out[i] = 0;
        out[i + 1] = 0;
        out[i + 2] = 0;
        out[i + 3] = 0;
      } else {
        out[i] = math.min(255, (pixels[i + 2] * 255 + a ~/ 2) ~/ a);
        out[i + 1] = math.min(255, (pixels[i + 1] * 255 + a ~/ 2) ~/ a);
        out[i + 2] = math.min(255, (pixels[i] * 255 + a ~/ 2) ~/ a);
        out[i + 3] = a;
      }
    }
    return out;
  }

  Uint8List straightRgb() {
    final Uint8List rgba = straightRgba();
    final Uint8List out = Uint8List(width * height * 3);
    for (var i = 0, o = 0; i < rgba.length; i += 4, o += 3) {
      out[o] = rgba[i];
      out[o + 1] = rgba[i + 1];
      out[o + 2] = rgba[i + 2];
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Encoders
// ---------------------------------------------------------------------------

/// Which encoder a save path asks for, by extension.
enum SaveFormat {
  png('png'),
  jpeg('jpg'),
  jp2('jp2'),
  j2k('j2k');

  const SaveFormat(this.extension);

  final String extension;

  static SaveFormat? fromPath(String path) {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.png')) return SaveFormat.png;
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return SaveFormat.jpeg;
    }
    if (lower.endsWith('.jp2') || lower.endsWith('.jpx')) return SaveFormat.jp2;
    if (lower.endsWith('.j2k') || lower.endsWith('.j2c')) return SaveFormat.j2k;
    return null;
  }
}

Uint8List encodeDocument(PaintDocument document, SaveFormat format) =>
    switch (format) {
      SaveFormat.png => encodePngRgba(
          document.width,
          document.height,
          document.straightRgba(),
        ),
      SaveFormat.jpeg => _encodeJpeg(document),
      SaveFormat.jp2 => jp2.encodeJpeg2000Pixels(
          document.hasAlpha ? document.straightRgba() : document.straightRgb(),
          width: document.width,
          height: document.height,
          components: document.hasAlpha ? 4 : 3,
          options: const jp2.Jpeg2000EncodeOptions(wrapInJp2: true),
        ),
      SaveFormat.j2k => jp2.encodeJpeg2000Pixels(
          document.straightRgb(),
          width: document.width,
          height: document.height,
          components: 3,
        ),
    };

Uint8List _encodeJpeg(PaintDocument document) {
  final Uint8List rgb = document.straightRgb();
  final image_lib.Image image = image_lib.Image(
    width: document.width,
    height: document.height,
  );
  var index = 0;
  for (var y = 0; y < document.height; y++) {
    for (var x = 0; x < document.width; x++) {
      image.setPixelRgba(x, y, rgb[index], rgb[index + 1], rgb[index + 2], 255);
      index += 3;
    }
  }
  return image_lib.encodeJpg(image, quality: 92);
}

/// PNG writer with stored (uncompressed) deflate blocks: valid everywhere,
/// larger than a real compressor would produce, and forty lines long.
Uint8List encodePngRgba(int width, int height, Uint8List rgba) {
  final int rowBytes = width * 4;
  final Uint8List raw = Uint8List(height * (rowBytes + 1));
  for (var y = 0; y < height; y++) {
    final int rowStart = y * (rowBytes + 1);
    raw[rowStart] = 0; // filter: none
    raw.setRange(rowStart + 1, rowStart + 1 + rowBytes, rgba, y * rowBytes);
  }

  final BytesBuilder out = BytesBuilder();
  out.add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ByteData header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // colour type: RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  _pngChunk(out, 'IHDR', header.buffer.asUint8List());
  _pngChunk(out, 'IDAT', _zlibStored(raw));
  _pngChunk(out, 'IEND', Uint8List(0));
  return out.toBytes();
}

void _pngChunk(BytesBuilder out, String type, Uint8List data) {
  final ByteData length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  final Uint8List typeBytes = Uint8List.fromList(type.codeUnits);
  out.add(typeBytes);
  out.add(data);
  var crc = _crc32(0xFFFFFFFF, typeBytes);
  crc = _crc32(crc, data);
  final ByteData crcBytes = ByteData(4)..setUint32(0, crc ^ 0xFFFFFFFF);
  out.add(crcBytes.buffer.asUint8List());
}

Uint8List _zlibStored(Uint8List data) {
  final BytesBuilder out = BytesBuilder();
  out.add(const <int>[0x78, 0x01]);
  var offset = 0;
  do {
    final int length = math.min(65535, data.length - offset);
    final bool last = offset + length >= data.length;
    out.addByte(last ? 1 : 0);
    out.addByte(length & 0xFF);
    out.addByte(length >> 8);
    out.addByte(~length & 0xFF);
    out.addByte((~length >> 8) & 0xFF);
    out.add(Uint8List.sublistView(data, offset, offset + length));
    offset += length;
  } while (offset < data.length);
  var a = 1;
  var b = 0;
  for (final int byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  final ByteData adler = ByteData(4)..setUint32(0, (b << 16) | a);
  out.add(adler.buffer.asUint8List());
  return out.toBytes();
}

final Uint32List _crcTable = () {
  final Uint32List table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(int crc, Uint8List bytes) {
  var c = crc;
  for (final int byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return c;
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

class ImageEditorApp extends StatefulWidget {
  const ImageEditorApp({super.key, this.initialPath});

  final String? initialPath;

  @override
  State<ImageEditorApp> createState() => _ImageEditorAppState();
}

class _ImageEditorAppState extends State<ImageEditorApp> {
  static const List<Color> _palette = <Color>[
    Color(0xFF000000),
    Color(0xFFFFFFFF),
    Color(0xFFE53935),
    Color(0xFFFB8C00),
    Color(0xFFFDD835),
    Color(0xFF43A047),
    Color(0xFF1E88E5),
    Color(0xFF8E24AA),
  ];

  static const List<FilePickerFilter> _openFilters = <FilePickerFilter>[
    FilePickerFilter(
      label: 'Imagens (*.jp2;*.j2k;*.png;*.jpg;*.webp)',
      extensions: <String>[
        'jp2',
        'j2k',
        'j2c',
        'jpx',
        'png',
        'jpg',
        'jpeg',
        'webp'
      ],
    ),
    FilePickerFilter(
        label: 'JPEG 2000 (*.jp2;*.j2k)', extensions: <String>['jp2', 'j2k']),
    FilePickerFilter(label: 'PNG (*.png)', extensions: <String>['png']),
    FilePickerFilter(
        label: 'JPEG (*.jpg)', extensions: <String>['jpg', 'jpeg']),
    FilePickerFilter(
        label: 'Todos os arquivos (*.*)', extensions: <String>['*']),
  ];

  static const List<FilePickerFilter> _saveFilters = <FilePickerFilter>[
    FilePickerFilter(label: 'PNG (*.png)', extensions: <String>['png']),
    FilePickerFilter(label: 'JPEG (*.jpg)', extensions: <String>['jpg']),
    FilePickerFilter(
        label: 'JPEG 2000 JP2 (*.jp2)', extensions: <String>['jp2']),
    FilePickerFilter(
        label: 'JPEG 2000 codestream (*.j2k)', extensions: <String>['j2k']),
  ];

  PaintDocument _document = PaintDocument.blank(800, 600);
  final List<Uint8List> _history = <Uint8List>[];
  RenderBox? _canvasBox;
  Offset? _lastPoint;
  Color _color = const Color(0xFF000000);
  double _brushRadius = 6;
  bool _eraser = false;
  bool _busy = false;
  String _fileName = 'sem título (800×600)';
  String _status =
      'Arraste o mouse para pintar. Abra um JP2 para testar o codec.';
  String _codecInfo = '';

  @override
  void initState() {
    super.initState();
    final String? path = widget.initialPath;
    if (path != null) _openPath(path);
  }

  // -- files ---------------------------------------------------------------

  Future<void> _openPath(String path) async {
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      _loadBytes(bytes, File(path).uri.pathSegments.last);
    } on Object catch (error) {
      setState(() => _status = 'Não abriu $path: $error');
    }
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final PickedFile? picked = await FilePicker.openFile(
        title: 'Abrir imagem',
        filters: _openFilters,
      );
      if (!mounted) return;
      if (picked == null) {
        setState(() => _busy = false);
        return;
      }
      _loadBytes(picked.bytes, picked.name);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Falha ao abrir: $error';
        });
      }
    }
  }

  void _loadBytes(Uint8List bytes, String name) {
    final Stopwatch watch = Stopwatch()..start();
    try {
      final RasterImageFormat? format = sniffImageFormat(bytes);
      final RasterDecodeResult result = decodeImageWithCodec(bytes);
      watch.stop();
      setState(() {
        _document = PaintDocument.fromDecoded(result.image);
        _history.clear();
        _fileName = '$name (${_document.width}×${_document.height})';
        _codecInfo = '${format?.name ?? '?'} via ${result.codecName}'
            '${result.isNative ? ' [nativo]' : ' [Dart]'}'
            ' em ${watch.elapsedMilliseconds} ms'
            '${result.image.hasAlpha ? ', com alfa' : ''}';
        _status = 'Aberto. ${bytes.length} bytes.';
        _busy = false;
      });
    } on ImageDecodeException catch (error) {
      setState(() {
        _busy = false;
        _status = 'Recusado: $error';
      });
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final String? path = await FilePicker.saveFile(
        title: 'Salvar imagem',
        suggestedName: 'desenho',
        filters: _saveFilters,
        defaultExtension: 'png',
      );
      if (!mounted) return;
      if (path == null) {
        setState(() => _busy = false);
        return;
      }
      final SaveFormat? format = SaveFormat.fromPath(path);
      if (format == null) {
        setState(() {
          _busy = false;
          _status =
              'Extensão não reconhecida em $path (use png, jpg, jp2 ou j2k).';
        });
        return;
      }
      final Stopwatch watch = Stopwatch()..start();
      final Uint8List bytes = encodeDocument(_document, format);
      await File(path).writeAsBytes(bytes);
      watch.stop();
      // Read the file back through the same dispatcher the app uses, so a
      // save that the decoder would refuse is reported here and now.
      final RasterDecodeResult check = decodeImageWithCodec(bytes);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Salvo ${format.name} em $path: ${bytes.length} bytes em '
            '${watch.elapsedMilliseconds} ms; releitura ${check.image.width}×'
            '${check.image.height} por ${check.codecName}.';
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Falha ao salvar: $error';
        });
      }
    }
  }

  void _newDocument() {
    setState(() {
      _document = PaintDocument.blank(800, 600);
      _history.clear();
      _fileName = 'sem título (800×600)';
      _codecInfo = '';
      _status = 'Documento novo.';
    });
  }

  // -- painting ------------------------------------------------------------

  Offset? _toImage(Offset global) {
    final RenderBox? box = _canvasBox;
    if (box == null || !box.hasSize) return null;
    final Offset local = box.globalToLocal(global);
    final Size area = box.size;
    final double scale = math.min(
      area.width / _document.width,
      area.height / _document.height,
    );
    if (scale <= 0) return null;
    final double offsetX = (area.width - _document.width * scale) / 2;
    final double offsetY = (area.height - _document.height * scale) / 2;
    return Offset(
      (local.dx - offsetX) / scale,
      (local.dy - offsetY) / scale,
    );
  }

  Color get _brushColor => _eraser ? const Color(0xFFFFFFFF) : _color;

  void _pushHistory() {
    _history.add(_document.snapshot());
    if (_history.length > 20) _history.removeAt(0);
  }

  void _beginStroke(Offset global) {
    final Offset? point = _toImage(global);
    if (point == null) return;
    _pushHistory();
    _document.stamp(point.dx, point.dy, _brushRadius, _brushColor);
    _lastPoint = point;
    setState(() {});
  }

  void _continueStroke(Offset global) {
    final Offset? point = _toImage(global);
    final Offset? last = _lastPoint;
    if (point == null) return;
    if (last == null) {
      _beginStroke(global);
      return;
    }
    _document.stroke(last, point, _brushRadius, _brushColor);
    _lastPoint = point;
    setState(() {});
  }

  void _endStroke() {
    _lastPoint = null;
  }

  void _undo() {
    if (_history.isEmpty) return;
    setState(() {
      _document.restore(_history.removeLast());
      _status = 'Desfeito.';
    });
  }

  // -- ui ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    const ThemeData theme = ThemeData.materialLight;
    return Theme(
      data: theme,
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainer,
        child: Column(
          children: <Widget>[
            Toolbar(
              showBorder: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  ToolbarGroup(
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(PhosphorIcons.folderOpen),
                        tooltip: 'Abrir imagem (PNG, JPEG, WebP, JPEG 2000)',
                        onPressed: _busy ? null : _open,
                      ),
                      IconButton(
                        icon: const Icon(PhosphorIcons.floppyDisk),
                        tooltip: 'Salvar como PNG, JPEG ou JPEG 2000',
                        onPressed: _busy ? null : _save,
                      ),
                      IconButton(
                        icon: const Icon(PhosphorIcons.image),
                        tooltip: 'Novo documento 800×600',
                        onPressed: _busy ? null : _newDocument,
                      ),
                      IconButton(
                        icon: const Icon(PhosphorIcons.arrowCounterClockwise),
                        tooltip: 'Desfazer',
                        onPressed: _history.isEmpty ? null : _undo,
                      ),
                    ],
                  ),
                  const ToolbarDivider(),
                  ToolbarGroup(
                    spacing: 4,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(PhosphorIcons.paintBrush),
                        tooltip: 'Pincel',
                        onPressed: _eraser
                            ? () => setState(() => _eraser = false)
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(PhosphorIcons.eraser),
                        tooltip: 'Borracha (pinta de branco)',
                        onPressed: _eraser
                            ? null
                            : () => setState(() => _eraser = true),
                      ),
                      for (final Color color in _palette) _swatch(color),
                    ],
                  ),
                  const ToolbarDivider(),
                  SizedBox(
                    width: 160,
                    child: Slider(
                      value: _brushRadius,
                      min: 1,
                      max: 48,
                      step: 1,
                      onChanged: (double value) =>
                          setState(() => _brushRadius = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('pincel ${_brushRadius.round()} px'),
                  const Spacer(),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: const Color(0xFF3A3F47),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _CanvasSurface(
                    onRenderBox: (RenderBox box) => _canvasBox = box,
                    child: GestureDetector(
                      onTapDown: (TapDetails details) =>
                          _beginStroke(details.globalPosition),
                      onTapUp: (_) => _endStroke(),
                      onPanStart: (DragStartDetails details) =>
                          _beginStroke(details.globalPosition),
                      onPanUpdate: (DragUpdateDetails details) =>
                          _continueStroke(details.globalPosition),
                      onPanEnd: (_) => _endStroke(),
                      onPanCancel: _endStroke,
                      child: Image(
                        _document.toDecodedImage(),
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ColoredBox(
              color: theme.surface,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _fileName +
                          (_codecInfo.isEmpty ? '' : '  •  $_codecInfo'),
                      fontSize: 13,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _status,
                      fontSize: 12,
                      color: theme.foregroundSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _swatch(Color color) {
    final bool selected = !_eraser && color == _color;
    return GestureDetector(
      onTap: () => setState(() {
        _color = color;
        _eraser = false;
      }),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: ColoredBox(
          color: selected ? const Color(0xFF1E88E5) : const Color(0xFF9E9E9E),
          child: Padding(
            padding: EdgeInsets.all(selected ? 3 : 1),
            child: SizedBox(
              width: 20,
              height: 20,
              child: ColoredBox(color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fills the space it is given and hands its render box to the state, which
/// needs `globalToLocal` and the box size to map pointer positions onto image
/// pixels through the `BoxFit.contain` placement of the child.
class _CanvasSurface extends SingleChildRenderObjectWidget {
  const _CanvasSurface({required this.onRenderBox, required super.child});

  final void Function(RenderBox box) onRenderBox;

  @override
  _RenderCanvasSurface createRenderObject(BuildContext context) =>
      _RenderCanvasSurface(onRenderBox);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderCanvasSurface renderObject,
  ) {
    renderObject.onRenderBox = onRenderBox;
  }
}

class _RenderCanvasSurface extends RenderSingleChildBox {
  _RenderCanvasSurface(this.onRenderBox);

  void Function(RenderBox box) onRenderBox;

  @override
  void performLayout() {
    size = constraints.biggest;
    child?.layout(BoxConstraints.tight(size));
    onRenderBox(this);
  }
}
