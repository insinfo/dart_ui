library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/color.dart';
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
import '../../pdf/render/pdf_text_layout.dart';
import '../../platform/input_events.dart';
import '../../rendering/text/font_registry.dart';
import '../../text/typeface.dart';
import '../element.dart';
import '../image.dart' show framebufferFromImage;
import '../media_query.dart';
import '../pointer_router.dart';
import '../widget.dart';
import 'pdf_view_controller.dart';

/// Paints one PDF page through the framework's ordinary display-list pipeline.
final class PdfPageView extends RenderObjectWidget {
  const PdfPageView({
    super.key,
    required this.page,
    this.scale = 1.0,
    this.backgroundColor = const Color(0xFFFFFFFF),
    this.textLayout,
    this.textLayoutResolver,
    this.selection,
    this.enableTextSelection = false,
    this.onSelectionChanged,
  }) : assert(scale > 0);

  final PdfPage page;
  final double scale;
  final Color backgroundColor;
  final PdfPageTextLayout? textLayout;

  /// Produces this page's text layout the first time it is actually needed.
  ///
  /// Extracting a layout re-interprets the page's whole content stream, which
  /// is tens of milliseconds per page - too much to spend on every page a
  /// viewer realizes just in case the user later selects text on it. A
  /// resolver defers that cost to the first selection gesture, search hit or
  /// selection paint, and pages the user never touches never pay it.
  ///
  /// Ignored when [textLayout] is provided. The resolver must be pure: called
  /// once per page identity and cached, so it must return the same layout for
  /// the same [page].
  final PdfPageTextLayout? Function()? textLayoutResolver;
  final PdfTextSelection? selection;
  final bool enableTextSelection;
  final void Function(int baseOffset, int extentOffset)? onSelectionChanged;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderPdfPage createRenderObject(BuildContext context) => RenderPdfPage(
        page,
        scale: scale,
        backgroundColor: backgroundColor.value,
        devicePixelRatio: MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1,
        textLayout: textLayout,
        textLayoutResolver: textLayoutResolver,
        selection: selection,
        enableTextSelection: enableTextSelection,
        onSelectionChanged: onSelectionChanged,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderPdfPage renderObject,
  ) {
    renderObject
      ..page = page
      ..scale = scale
      ..backgroundColor = backgroundColor.value
      ..devicePixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1
      ..textLayoutResolver = textLayoutResolver
      ..textLayout = textLayout
      ..selection = selection
      ..enableTextSelection = enableTextSelection
      ..onSelectionChanged = onSelectionChanged;
  }
}

final class RenderPdfPage extends RenderBox implements PointerEventTarget {
  RenderPdfPage(
    PdfPage page, {
    double scale = 1.0,
    int backgroundColor = 0xFFFFFFFF,
    double devicePixelRatio = 1,
    PdfPageTextLayout? textLayout,
    PdfPageTextLayout? Function()? textLayoutResolver,
    PdfTextSelection? selection,
    bool enableTextSelection = false,
    this.onSelectionChanged,
  })  : _page = page,
        _scale = scale,
        _backgroundColor = backgroundColor,
        _devicePixelRatio = devicePixelRatio,
        _textLayout = textLayout,
        _textLayoutResolver = textLayoutResolver,
        _selection = selection,
        _enableTextSelection = enableTextSelection;

  PdfPage _page;
  double _scale;
  int _backgroundColor;
  double _devicePixelRatio;
  PdfPageTextLayout? _textLayout;
  PdfPageTextLayout? Function()? _textLayoutResolver;
  PdfTextSelection? _selection;
  bool _enableTextSelection;
  void Function(int baseOffset, int extentOffset)? onSelectionChanged;
  int? _selectionPointer;
  int _selectionAnchor = 0;
  final Map<Object, DecodedImage> _decodedImages = <Object, DecodedImage>{};
  final Map<String, Typeface?> _embeddedFonts = <String, Typeface?>{};

  PdfPage get page => _page;

  set page(PdfPage value) {
    if (identical(value, _page)) return;
    _page = value;
    _decodedImages.clear();
    _embeddedFonts.clear();
    // A lazily resolved layout belongs to the page it was extracted from; the
    // new page's layout is re-resolved on demand. An explicit layout is the
    // widget's to replace and is left for its setter.
    if (_textLayoutResolver != null) _textLayout = null;
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

  double get devicePixelRatio => _devicePixelRatio;

  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value > 0 && value.isFinite ? value : 1;
    markNeedsPaint();
  }

  /// This page's text layout, resolving it on first use when a resolver is
  /// installed. Null when there is neither an explicit layout nor a resolver.
  PdfPageTextLayout? get textLayout =>
      _textLayout ??= _textLayoutResolver?.call();

  set textLayout(PdfPageTextLayout? value) {
    // In resolver mode the widget passes null; that must not wipe a layout
    // that was already lazily resolved (and repaint) on every update.
    if (value == null && _textLayoutResolver != null) return;
    if (identical(value, _textLayout)) return;
    _textLayout = value;
    markNeedsPaint();
  }

  /// Replacing the resolver alone invalidates nothing: for one page identity
  /// every resolver must produce the same layout, so a new closure from a
  /// rebuild changes no pixels. The [page] setter clears the cached layout
  /// when the page itself changes.
  set textLayoutResolver(PdfPageTextLayout? Function()? value) {
    _textLayoutResolver = value;
  }

  PdfTextSelection? get selection => _selection;

  set selection(PdfTextSelection? value) {
    if (identical(value, _selection)) return;
    _selection = value;
    markNeedsPaint();
  }

  bool get enableTextSelection => _enableTextSelection;

  set enableTextSelection(bool value) {
    if (value == _enableTextSelection) return;
    _enableTextSelection = value;
    if (!value) _selectionPointer = null;
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
  void handlePointerEvent(PointerEvent event) {
    if (!enableTextSelection) return;
    // Hover moves reach here too, and with a lazy resolver installed reading
    // [textLayout] extracts it. Only a selection interaction is worth that:
    // a press resolves it below, and moves/ups matter only mid-drag, which a
    // press has already gated through [_selectionPointer].
    if (event is PointerDownEvent && textLayout == null) return;
    if (event is! PointerDownEvent && _selectionPointer == null) return;
    switch (event) {
      case PointerDownEvent(
          button: PointerButton.primary,
          kind: PointerKind.mouse,
        ):
      case PointerDownEvent(
          button: PointerButton.primary,
          kind: PointerKind.stylus,
        ):
        final int position = _textPositionAt(event.logicalPosition);
        if (event.clickCount >= 2) {
          final ({int start, int end}) word = _wordAt(position);
          _selectionPointer = null;
          onSelectionChanged?.call(word.start, word.end);
        } else {
          _selectionPointer = event.pointerId;
          _selectionAnchor = position;
          onSelectionChanged?.call(position, position);
        }
      case PointerMoveEvent() when event.pointerId == _selectionPointer:
        onSelectionChanged?.call(
          _selectionAnchor,
          _textPositionAt(event.logicalPosition),
        );
      case PointerUpEvent() when event.pointerId == _selectionPointer:
      case PointerCancelEvent() when event.pointerId == _selectionPointer:
        _selectionPointer = null;
      default:
        break;
    }
  }

  int _textPositionAt(Offset globalPosition) {
    final Offset local = globalToLocal(globalPosition) / scale;
    return textLayout!.positionForOffset(local);
  }

  ({int start, int end}) _wordAt(int position) {
    final String text = textLayout!.text;
    if (text.isEmpty) return (start: 0, end: 0);
    int start = position.clamp(0, text.length);
    int end = start;
    const List<int> punctuation = <int>[
      0x2E,
      0x2C,
      0x3B,
      0x3A,
      0x21,
      0x3F,
      0x28,
      0x29,
      0x5B,
      0x5D,
      0x7B,
      0x7D,
      0x22,
    ];
    bool isWord(int codeUnit) =>
        codeUnit > 32 && !punctuation.contains(codeUnit);
    while (start > 0 && isWord(text.codeUnitAt(start - 1))) {
      start--;
    }
    while (end < text.length && isWord(text.codeUnitAt(end))) {
      end++;
    }
    return (start: start, end: end);
  }

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
      pageToDevice: pdfPageTransform(page, offset, scale),
      renderScale: scale,
      devicePixelRatio: devicePixelRatio,
      decodedImages: _decodedImages,
      embeddedFonts: _embeddedFonts,
    );
    PdfPageRenderer(page).render(device, applyPageRotation: false);

    // Selection is an overlay and must be painted after every PDF operator.
    // Real office documents often place an opaque image, white rectangle or
    // form XObject after their text. Painting the highlight first meant those
    // later operators covered it even though copying used the correct range —
    // most visibly on standalone bold headings.
    final PdfTextSelection? selected = selection;
    // The layout is only read behind the selection check: with a lazy
    // resolver installed, touching [textLayout] extracts it, and a page with
    // nothing selected must not pay for an extraction it does not need.
    final PdfPageTextLayout? layout = selected == null ? null : textLayout;
    final ({int start, int end})? selectedRange =
        selected == null || layout == null
            ? null
            : selected.rangeForPage(page.pageNumber, layout.text.length);
    if (selectedRange != null) {
      final int highlight = list.addPaint(colorArgb: 0x663B82F6);
      for (final Rect rect
          in layout!.selectionRects(selectedRange.start, selectedRange.end)) {
        list.drawRect(
          offset.dx + rect.left * scale,
          offset.dy + rect.top * scale,
          offset.dx + rect.right * scale,
          offset.dy + rect.bottom * scale,
          highlight,
        );
      }
    }
    list.restore();
  }
}

final class _PdfDisplayListOutputDevice extends PdfOutputDevice {
  _PdfDisplayListOutputDevice({
    required this.list,
    required this.page,
    required this.pageToDevice,
    required this.renderScale,
    required this.devicePixelRatio,
    required this.decodedImages,
    required this.embeddedFonts,
  });

  final DisplayList list;
  final PdfPage page;
  final Transform2D pageToDevice;
  final double renderScale;
  final double devicePixelRatio;
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
  void drawText(
    String text,
    PdfGfxState state,
    PdfMatrix textMatrix, {
    double? advance,
  }) {
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
    final int pixelWidth =
        (device.width * devicePixelRatio).round().clamp(1, 8192);
    final int pixelHeight =
        (device.height * devicePixelRatio).round().clamp(1, 8192);
    final DecodedImage pixels =
        decoded.width == pixelWidth && decoded.height == pixelHeight
            ? decoded
            : decoded.resample(width: pixelWidth, height: pixelHeight);
    list.drawImage(
      list.addImage(framebufferFromImage(pixels)),
      0,
      0,
      pixels.width.toDouble(),
      pixels.height.toDouble(),
      device.left,
      device.top,
      device.right,
      device.bottom,
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
