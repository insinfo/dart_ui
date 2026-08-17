library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list.dart';
import '../../graphics/display_list_opcodes.dart';
import '../../graphics/image/decoded_image.dart';
import '../../graphics/image/raster_formats.dart';
import '../../layout/render_box.dart';
import '../../pdf/document/pdf_page.dart';
import '../../pdf/format/pdf_object.dart';
import '../../pdf/gfx/pdf_gfx_state.dart';
import '../../pdf/gfx/pdf_matrix.dart';
import '../../pdf/gfx/pdf_output_device.dart';
import '../../pdf/render/pdf_page_renderer.dart';
import '../../rendering/text/font_registry.dart';
import '../../text/typeface.dart';
import '../element.dart';
import '../image.dart' show framebufferFromImage;
import '../widget.dart';

/// Paints one PDF page through the framework's ordinary display-list pipeline.
final class PdfPageView extends RenderObjectWidget {
  const PdfPageView({
    super.key,
    required this.page,
    this.scale = 1.0,
    this.backgroundColor = 0xFFFFFFFF,
  }) : assert(scale > 0);

  final PdfPage page;
  final double scale;
  final int backgroundColor;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderPdfPage createRenderObject(BuildContext context) => RenderPdfPage(
        page,
        scale: scale,
        backgroundColor: backgroundColor,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderPdfPage renderObject,
  ) {
    renderObject
      ..page = page
      ..scale = scale
      ..backgroundColor = backgroundColor;
  }
}

final class RenderPdfPage extends RenderBox {
  RenderPdfPage(
    PdfPage page, {
    double scale = 1.0,
    int backgroundColor = 0xFFFFFFFF,
  })  : _page = page,
        _scale = scale,
        _backgroundColor = backgroundColor;

  PdfPage _page;
  double _scale;
  int _backgroundColor;
  final Map<Object, DecodedImage> _decodedImages = <Object, DecodedImage>{};
  final Map<String, Typeface?> _embeddedFonts = <String, Typeface?>{};

  PdfPage get page => _page;

  set page(PdfPage value) {
    if (identical(value, _page)) return;
    _page = value;
    _decodedImages.clear();
    _embeddedFonts.clear();
    markNeedsLayout();
  }

  double get scale => _scale;

  set scale(double value) {
    if (value == _scale) return;
    if (value <= 0 || !value.isFinite) {
      throw ArgumentError.value(value, 'scale', 'must be finite and positive');
    }
    _scale = value;
    _decodedImages.clear();
    markNeedsLayout();
  }

  int get backgroundColor => _backgroundColor;

  set backgroundColor(int value) {
    if (value == _backgroundColor) return;
    _backgroundColor = value;
    markNeedsPaint();
  }

  Size get _naturalSize => Size(page.width * scale, page.height * scale);

  @override
  void performLayout() => size = constraints.constrain(_naturalSize);

  @override
  double computeMinIntrinsicWidth(double height) => _naturalSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _naturalSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _naturalSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _naturalSize.height;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty) return;
    final Rect bounds =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    list.drawRect(
      bounds.left,
      bounds.top,
      bounds.right,
      bounds.bottom,
      list.addPaint(colorArgb: backgroundColor),
    );
    list
      ..save()
      ..clipRect(bounds.left, bounds.top, bounds.right, bounds.bottom);
    final _PdfDisplayListOutputDevice device = _PdfDisplayListOutputDevice(
      list: list,
      page: page,
      pageToDevice: _pageTransform(page, offset, scale),
      renderScale: scale,
      decodedImages: _decodedImages,
      embeddedFonts: _embeddedFonts,
    );
    PdfPageRenderer(page).render(device, applyPageRotation: false);
    list.restore();
  }
}

Transform2D _pageTransform(PdfPage page, Offset offset, double scale) {
  final Rect crop = page.cropBox;
  final int rotation = ((page.rotation % 360) + 360) % 360;
  return switch (rotation) {
    90 => Transform2D(
        0,
        scale,
        scale,
        0,
        offset.dx - crop.top * scale,
        offset.dy - crop.left * scale,
      ),
    180 => Transform2D(
        -scale,
        0,
        0,
        scale,
        offset.dx + crop.right * scale,
        offset.dy - crop.top * scale,
      ),
    270 => Transform2D(
        0,
        -scale,
        -scale,
        0,
        offset.dx + crop.bottom * scale,
        offset.dy + crop.right * scale,
      ),
    _ => Transform2D(
        scale,
        0,
        0,
        -scale,
        offset.dx - crop.left * scale,
        offset.dy + crop.bottom * scale,
      ),
  };
}

final class _PdfDisplayListOutputDevice extends PdfOutputDevice {
  _PdfDisplayListOutputDevice({
    required this.list,
    required this.page,
    required this.pageToDevice,
    required this.renderScale,
    required this.decodedImages,
    required this.embeddedFonts,
  });

  final DisplayList list;
  final PdfPage page;
  final Transform2D pageToDevice;
  final double renderScale;
  final Map<Object, DecodedImage> decodedImages;
  final Map<String, Typeface?> embeddedFonts;
  final List<Transform2D> _stack = <Transform2D>[];
  Transform2D _ctm = Transform2D.identity;

  Transform2D get _deviceTransform => pageToDevice.multiply(_ctm);

  @override
  void saveState() {
    _stack.add(_ctm);
    list.save();
  }

  @override
  void restoreState() {
    if (_stack.isEmpty) return;
    _ctm = _stack.removeLast();
    list.restore();
  }

  @override
  void transform(PdfMatrix matrix) {
    _ctm = _ctm.multiply(
      Transform2D(matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f),
    );
  }

  @override
  void clip(Path path, {bool evenOdd = false}) {
    final Path transformed = path.transform(_deviceTransform);
    // PDF generators overwhelmingly express page/table clipping as a path
    // containing one rectangle. Keep that common case on the rectangular
    // clip fast path supported by every dart_ui renderer. Until the replay
    // layer grows a coverage mask for arbitrary clip paths, using the tight
    // path bounds is the safe conservative fallback: it preserves nesting and
    // prevents an otherwise fatal UnsupportedCommandException.
    final Rect clip = _axisAlignedRectangle(transformed) ?? transformed.bounds;
    list.clipRect(clip.left, clip.top, clip.right, clip.bottom);
  }

  @override
  void fillPath(Path path, PdfGfxState state, {bool evenOdd = false}) {
    final Path transformed = path.transform(_deviceTransform);
    list.drawPath(
      list.addPath(transformed),
      list.addPaint(
        colorArgb: _withOpacity(state.fillColor, state.fillAlpha),
        fillRule: evenOdd ? pathFillRuleEvenOdd : pathFillRuleNonZero,
      ),
    );
  }

  @override
  void strokePath(Path path, PdfGfxState state) {
    final Transform2D transform = _deviceTransform;
    final double sx =
        math.sqrt(transform.a * transform.a + transform.b * transform.b);
    final double sy =
        math.sqrt(transform.c * transform.c + transform.d * transform.d);
    final Path transformed = path.transform(transform);
    list.drawPath(
      list.addPath(transformed),
      list.addPaint(
        colorArgb: _withOpacity(state.strokeColor, state.strokeAlpha),
        style: paintStyleStroke,
        strokeWidth: state.lineWidth * (sx + sy) / 2,
      ),
    );
  }

  @override
  void drawText(String text, PdfGfxState state, PdfMatrix textMatrix) {
    if (text.isEmpty || state.textRenderMode == PdfTextRenderMode.invisible) {
      return;
    }
    final Transform2D textTransform = _deviceTransform.multiply(
      Transform2D(
        textMatrix.a,
        textMatrix.b,
        textMatrix.c,
        textMatrix.d,
        textMatrix.e,
        textMatrix.f,
      ),
    );
    final double deviceScale = math.sqrt(
      textTransform.c * textTransform.c + textTransform.d * textTransform.d,
    );
    final double fontSize = (state.fontSize * deviceScale).abs();
    if (fontSize == 0 || !fontSize.isFinite) return;
    final ScaledTypeface? font = _fontFor(text, state.fontName, fontSize);
    if (font == null) return;
    final Offset baseline = textTransform.transformOffset(
      Offset(0, state.textRise),
    );
    final int paint = list.addPaint(
      colorArgb: _withOpacity(state.fillColor, state.fillAlpha),
    );
    uiTextPainter.paint(list, text, font, baseline, paint);
  }

  ScaledTypeface? _fontFor(String text, String? fontName, double size) {
    if (fontName != null) {
      final Typeface? embedded = embeddedFonts.putIfAbsent(
        fontName,
        () => _loadEmbeddedFont(fontName),
      );
      if (embedded != null && embedded.covers(text)) {
        return embedded.atSize(size);
      }
    }
    return FontRegistry.instance.uiFont(size);
  }

  Typeface? _loadEmbeddedFont(String fontName) {
    try {
      final PdfDict? fonts = page.resources?.getDict('Font', page.resolver);
      final PdfObject? rawFont = fonts?.getResolved(fontName, page.resolver);
      if (rawFont is! PdfDict) return null;
      PdfDict font = rawFont;
      if (font.getName('Subtype', page.resolver)?.name == 'Type0') {
        final PdfArray? descendants =
            font.getArray('DescendantFonts', page.resolver);
        final PdfObject? descendant =
            descendants?.getResolved(0, page.resolver);
        if (descendant is PdfDict) font = descendant;
      }
      final PdfDict? descriptor = font.getDict('FontDescriptor', page.resolver);
      final PdfObject? streamObject =
          descriptor?.getResolved('FontFile2', page.resolver) ??
              descriptor?.getResolved('FontFile3', page.resolver);
      if (streamObject is PdfStream) {
        try {
          return Typeface.parse(streamObject.getDecodedBytes(page.resolver));
        } on Object {
          // A system face below is preferable to dropping all text when an
          // embedded CFF/bitmap program is outside the current SFNT parser.
        }
      }
      final String? baseFont = rawFont.getName('BaseFont', page.resolver)?.name;
      if (baseFont == null) return null;
      final _PdfFontRequest request = _systemFontRequest(baseFont);
      return FontRegistry.instance.faceFor(
        request.family,
        weight: request.weight,
        italic: request.italic,
        oblique: request.oblique,
      );
    } on Object {
      return null;
    }
  }

  @override
  void drawImage(
    Uint8List imageBytes,
    int width,
    int height,
    Rect dstRect,
    PdfGfxState state, {
    PdfDict? imageDictionary,
  }) {
    if (width <= 0 || height <= 0 || imageBytes.isEmpty) return;
    final Object key = imageDictionary ?? imageBytes;
    final DecodedImage? decoded = decodedImages[key] ??
        _decodePdfImage(imageBytes, width, height, imageDictionary);
    if (decoded == null) return;
    decodedImages[key] = decoded;

    final Rect device = _deviceTransform.transformRect(dstRect);
    final int pixelWidth = device.width.round().clamp(1, 8192);
    final int pixelHeight = device.height.round().clamp(1, 8192);
    final DecodedImage pixels =
        decoded.width == pixelWidth && decoded.height == pixelHeight
            ? decoded
            : decoded.resample(width: pixelWidth, height: pixelHeight);
    final int left = device.left.round();
    final int top = device.top.round();
    list.drawImage(
      list.addImage(framebufferFromImage(pixels)),
      0,
      0,
      pixels.width.toDouble(),
      pixels.height.toDouble(),
      left.toDouble(),
      top.toDouble(),
      (left + pixels.width).toDouble(),
      (top + pixels.height).toDouble(),
      list.addPaint(
        colorArgb: _withOpacity(0xFFFFFFFF, state.fillAlpha),
      ),
    );
  }

  DecodedImage? _decodePdfImage(
    Uint8List bytes,
    int width,
    int height,
    PdfDict? dictionary,
  ) {
    if (sniffImageFormat(bytes) != null) {
      try {
        return decodeImage(bytes, preferNative: false);
      } on Object {
        return null;
      }
    }
    final int bits =
        dictionary?.getNumber('BitsPerComponent', page.resolver)?.toInt() ?? 8;
    if (bits != 8) return null;
    final String colorSpace = _colorSpaceName(dictionary) ??
        (bytes.length >= width * height * 3 ? 'DeviceRGB' : 'DeviceGray');
    final int components = switch (colorSpace) {
      'DeviceRGB' || 'CalRGB' => 3,
      'DeviceCMYK' => 4,
      _ => 1,
    };
    if (bytes.length < width * height * components) return null;
    final Uint8List pixels = Uint8List(width * height * 4);
    for (var pixel = 0; pixel < width * height; pixel++) {
      final int source = pixel * components;
      final int target = pixel * 4;
      int red;
      int green;
      int blue;
      if (components == 1) {
        red = green = blue = bytes[source];
      } else if (components == 3) {
        red = bytes[source];
        green = bytes[source + 1];
        blue = bytes[source + 2];
      } else {
        final double c = bytes[source] / 255;
        final double m = bytes[source + 1] / 255;
        final double y = bytes[source + 2] / 255;
        final double k = bytes[source + 3] / 255;
        red = (255 * (1 - c) * (1 - k)).round();
        green = (255 * (1 - m) * (1 - k)).round();
        blue = (255 * (1 - y) * (1 - k)).round();
      }
      pixels[target] = blue;
      pixels[target + 1] = green;
      pixels[target + 2] = red;
      pixels[target + 3] = 255;
    }
    return DecodedImage(
      width: width,
      height: height,
      order: ImageChannelOrder.bgra,
      pixels: pixels,
      hasAlpha: false,
    );
  }

  String? _colorSpaceName(PdfDict? dictionary) {
    final PdfObject? colorSpace =
        dictionary?.getResolved('ColorSpace', page.resolver);
    if (colorSpace is PdfName) return colorSpace.name;
    if (colorSpace is PdfArray && colorSpace.length > 0) {
      final PdfObject? family = colorSpace.getResolved(0, page.resolver);
      if (family is PdfName && family.name == 'ICCBased') {
        final PdfObject? profile = colorSpace.getResolved(1, page.resolver);
        if (profile is PdfStream) {
          return switch (profile.dict.getNumber('N', page.resolver)?.toInt()) {
            1 => 'DeviceGray',
            4 => 'DeviceCMYK',
            _ => 'DeviceRGB',
          };
        }
      }
      if (family is PdfName) return family.name;
    }
    return null;
  }
}

Rect? _axisAlignedRectangle(Path path) {
  if (path.verbCount != 5 ||
      path.pointCount != 4 ||
      path.verbAt(0) != verbMoveTo ||
      path.verbAt(1) != verbLineTo ||
      path.verbAt(2) != verbLineTo ||
      path.verbAt(3) != verbLineTo ||
      path.verbAt(4) != verbClose) {
    return null;
  }
  final Rect bounds = path.bounds;
  var corners = 0;
  for (var i = 0; i < 4; i++) {
    final double x = path.pointX(i);
    final double y = path.pointY(i);
    final bool left = x == bounds.left;
    final bool right = x == bounds.right;
    final bool top = y == bounds.top;
    final bool bottom = y == bounds.bottom;
    if ((!left && !right) || (!top && !bottom)) return null;
    final int corner = (right ? 1 : 0) | (bottom ? 2 : 0);
    final int mask = 1 << corner;
    if (corners & mask != 0) return null;
    corners |= mask;
  }
  return corners == 0xF ? bounds : null;
}

_PdfFontRequest _systemFontRequest(String pdfName) {
  final String name = pdfName.replaceFirst(RegExp(r'^[A-Z]{6}\+'), '');
  final String lower = name.toLowerCase();
  final int weight = lower.contains('bold') || lower.contains('black')
      ? 700
      : lower.contains('light')
          ? 300
          : 400;
  final bool italic = lower.contains('italic');
  final bool oblique = lower.contains('oblique');
  final String family;
  if (lower.startsWith('timesnewroman') || lower.startsWith('times-roman')) {
    family = 'Times New Roman';
  } else if (lower.startsWith('courier')) {
    family = 'Courier New';
  } else if (lower.startsWith('helvetica')) {
    family = 'Arial';
  } else if (lower.startsWith('arial')) {
    family = 'Arial';
  } else {
    family = name
        .replaceFirst(
          RegExp(
            r'(?:-|,)?(?:bold|black|light|italic|oblique).*$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(RegExp(r'(?:PS)?MT$', caseSensitive: false), '')
        .replaceAll('-', ' ');
  }
  return _PdfFontRequest(
    family: family,
    weight: weight,
    italic: italic,
    oblique: oblique,
  );
}

final class _PdfFontRequest {
  const _PdfFontRequest({
    required this.family,
    required this.weight,
    required this.italic,
    required this.oblique,
  });

  final String family;
  final int weight;
  final bool italic;
  final bool oblique;
}

int _withOpacity(int color, double opacity) {
  final int original = color >>> 24 & 0xFF;
  final int alpha = (original * opacity.clamp(0.0, 1.0)).round();
  return alpha << 24 | color & 0x00FFFFFF;
}
