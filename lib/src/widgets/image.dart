/// The widget that puts decoded pixels on screen.
///
/// ## The three sizes involved, and why they are all different
///
/// An image has a size, the box it is given has a size, and the rectangle the
/// pixels end up in has a third. [BoxFit] is the rule connecting them, and
/// [applyBoxFit] is that rule written as a pure function of two [Size]s - no
/// widget, no render node, no image - so that it can be asserted directly
/// instead of inferred from pixels.
///
/// ## Why this file resamples
///
/// The CPU rasteriser's blit reads exactly one source pixel per destination
/// pixel, and `CpuRasterizer.drawFramebuffer` states that outright: a
/// destination smaller than the source **crops**, and a larger one leaves the
/// rest untouched. That is the honest behaviour for a routine with no
/// resampling in it, and it means a scaled draw has to come from somewhere
/// else.
///
/// So [RenderImage] produces the pixels at the size they will be drawn -
/// through `DecodedImage.resample`, nearest-neighbour, documented there - and
/// hands the rasteriser a buffer whose destination rectangle is exactly its own
/// size. The scaled buffer is cached on the render node and keyed by the
/// destination's whole-pixel size and the source rectangle, so a static image
/// resamples once and a resize resamples once more, rather than once a frame.
///
/// The destination is snapped to whole pixels before the resample. It has to
/// be: a buffer has an integer number of pixels, so a fractional destination
/// would be rounded by the blit anyway, and rounding *after* choosing the
/// buffer size is how an image ends up one pixel narrower than the rectangle
/// reserved for it.
///
/// ## Premultiplication and channel order
///
/// Both are settled by the time pixels reach here. `DecodedImage` is
/// premultiplied by construction and carries its own [ImageChannelOrder], and
/// [framebufferFromImage] maps that order onto the matching `PixelFormat`
/// rather than assuming one. When the image's order and the target surface's
/// disagree, the rasteriser's blit swaps red and blue as it reads - both are
/// premultiplied, so nothing else has to change - which is why an image decoded
/// for a BGRA window still draws correctly into an RGBA one.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../graphics/image/decoded_image.dart';
import '../graphics/image/png.dart';
import '../graphics/image/raster_formats.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../rendering/framebuffer.dart';
import 'element.dart';
import 'widget.dart';

/// How an image is scaled into the box it was given.
///
/// The six rules a user interface actually needs. `scaleDown` - contain, but
/// never enlarging - is deliberately absent: it is [BoxFit.none] and
/// [BoxFit.contain] chosen by a comparison the caller can make itself, and
/// adding it would be a seventh case in every switch for no new geometry.
enum BoxFit {
  /// As large as possible while still fitting entirely inside the box. The
  /// aspect ratio is kept and part of the box is left empty.
  contain,

  /// As small as possible while still covering the whole box. The aspect ratio
  /// is kept and part of the **image** is cropped.
  cover,

  /// Stretched to the box exactly. The aspect ratio is not kept; this is the
  /// only rule that distorts.
  fill,

  /// The box's width is filled and the height follows from the aspect ratio,
  /// cropping vertically if that overflows.
  fitWidth,

  /// The box's height is filled and the width follows from the aspect ratio,
  /// cropping horizontally if that overflows.
  fitHeight,

  /// No scaling at all. The image is drawn at its own size, cropped to the box
  /// if it is larger.
  none,
}

/// What [applyBoxFit] decided: which part of the source to read, and how large
/// to draw it.
///
/// Two sizes rather than two rectangles because *where* each one sits is the
/// alignment's business, and keeping the two decisions apart is what lets one
/// fit rule serve nine alignments.
typedef FittedSizes = ({Size source, Size destination});

/// Applies [fit] to a [source]-sized image in a [destination]-sized box.
///
/// A pure function of four doubles. It is the whole of the fit rule: every
/// difference between the six modes is here, and [RenderImage] adds only
/// alignment and rounding on top of it.
///
/// A zero or negative extent on either size yields two zero sizes rather than
/// a division by zero - an empty box draws no image, and that is not an error a
/// frame can do anything about.
FittedSizes applyBoxFit(BoxFit fit, Size source, Size destination) {
  if (source.width <= 0 ||
      source.height <= 0 ||
      destination.width <= 0 ||
      destination.height <= 0) {
    return (source: Size.zero, destination: Size.zero);
  }
  // Comparing the two aspect ratios once, rather than comparing scale factors
  // per branch, is what keeps the six cases from disagreeing at the exact
  // ratio where they meet.
  final bool boxIsWider =
      destination.width / destination.height > source.width / source.height;

  switch (fit) {
    case BoxFit.fill:
      return (source: source, destination: destination);
    case BoxFit.contain:
      return (
        source: source,
        destination: boxIsWider
            ? Size(
                source.width * destination.height / source.height,
                destination.height,
              )
            : Size(
                destination.width,
                source.height * destination.width / source.width,
              ),
      );
    case BoxFit.cover:
      return (
        source: boxIsWider
            ? Size(
                source.width,
                source.width * destination.height / destination.width,
              )
            : Size(
                source.height * destination.width / destination.height,
                source.height,
              ),
        destination: destination,
      );
    case BoxFit.fitWidth:
      // The box is wider than the image, so filling the width overflows the
      // height and the source is cropped instead of the result overflowing.
      return boxIsWider
          ? (
              source: Size(
                source.width,
                source.width * destination.height / destination.width,
              ),
              destination: destination,
            )
          : (
              source: source,
              destination: Size(
                destination.width,
                source.height * destination.width / source.width,
              ),
            );
    case BoxFit.fitHeight:
      return boxIsWider
          ? (
              source: source,
              destination: Size(
                source.width * destination.height / source.height,
                destination.height,
              ),
            )
          : (
              source: Size(
                source.height * destination.width / destination.height,
                source.height,
              ),
              destination: destination,
            );
    case BoxFit.none:
      final Size common = Size(
        math.min(source.width, destination.width),
        math.min(source.height, destination.height),
      );
      return (source: common, destination: common);
  }
}

/// Wraps [image]'s pixels as a framebuffer, with no copy.
///
/// The two types describe the same bytes and differ only in which layer owns
/// them: `DecodedImage` may not name `PixelFormat`, because section 8.2 forbids
/// `graphics` from depending on `rendering`. This function is the one place the
/// mapping between [ImageChannelOrder] and `PixelFormat` is written, and it is
/// exhaustive, so a new member of either cannot be forgotten silently.
Framebuffer framebufferFromImage(DecodedImage image) => Framebuffer(
      width: image.width,
      height: image.height,
      bytesPerRow: image.bytesPerRow,
      format: switch (image.order) {
        ImageChannelOrder.bgra => PixelFormat.bgra8888Premultiplied,
        ImageChannelOrder.rgba => PixelFormat.rgba8888Premultiplied,
      },
      pixels: image.pixels,
    );

/// Draws a decoded image.
final class Image extends RenderObjectWidget {
  const Image(
    this.image, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
  });

  /// Decodes [bytes] as a PNG and draws the result.
  ///
  /// **Decoding happens here**, in the constructor, which means it happens in
  /// whichever `build` created the widget. That is fine for an icon-sized asset
  /// and wrong for anything large: a rebuild re-decodes. Decode once with
  /// `decodePng` and pass the [DecodedImage] to the ordinary constructor when
  /// the image is big enough to notice, which is the same advice as for any
  /// expensive value in a build method.
  ///
  /// Throws whatever `decodePng` throws - see `graphics/image/png.dart` for the
  /// list. It is not caught here: a widget that swallowed a malformed image and
  /// drew nothing would hide the one piece of information the caller needs.
  factory Image.png(
    Uint8List bytes, {
    Key? key,
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    ImageChannelOrder order = ImageChannelOrder.bgra,
    PngLimits limits = const PngLimits(),
  }) =>
      Image(
        decodePng(bytes, order: order, limits: limits),
        key: key,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );

  /// Detects PNG, JPEG, WebP, or JPEG 2000 from [bytes], decodes it, and
  /// draws it.
  ///
  /// JPEG 2000 decodes in pure Dart at roughly a quarter of a microsecond per
  /// pixel, on the calling thread: for anything larger than an icon, decode
  /// once with `decodeImageAsync`, which moves it to a background isolate,
  /// and pass the [DecodedImage] to the ordinary constructor.
  ///
  /// Prefer decoding once with [decodeImage] and using the ordinary
  /// constructor for large assets or widgets rebuilt frequently.
  factory Image.memory(
    Uint8List bytes, {
    Key? key,
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    ImageChannelOrder order = ImageChannelOrder.bgra,
    PngLimits pngLimits = const PngLimits(),
    RasterImageLimits limits = const RasterImageLimits(),
  }) =>
      Image(
        decodeImage(
          bytes,
          order: order,
          pngLimits: pngLimits,
          limits: limits,
        ),
        key: key,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );

  /// Decodes JP2 or raw J2K bytes and draws the image.
  ///
  /// Synchronous and pure Dart; see [Image.memory] for when to decode off the
  /// UI thread instead.
  factory Image.jp2(
    Uint8List bytes, {
    Key? key,
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    ImageChannelOrder order = ImageChannelOrder.bgra,
    RasterImageLimits limits = const RasterImageLimits(),
  }) =>
      Image(
        decodeJp2(bytes, order: order, limits: limits),
        key: key,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );

  /// Decodes JPEG bytes and draws the first image.
  factory Image.jpeg(
    Uint8List bytes, {
    Key? key,
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    ImageChannelOrder order = ImageChannelOrder.bgra,
    RasterImageLimits limits = const RasterImageLimits(),
  }) =>
      Image(
        decodeJpeg(bytes, order: order, limits: limits),
        key: key,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );

  /// Decodes the first frame of a WebP image and draws it.
  factory Image.webp(
    Uint8List bytes, {
    Key? key,
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    ImageChannelOrder order = ImageChannelOrder.bgra,
    RasterImageLimits limits = const RasterImageLimits(),
  }) =>
      Image(
        decodeWebP(bytes, order: order, limits: limits),
        key: key,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );

  final DecodedImage image;

  /// Forces the box's width, ignoring the image's own. Null takes the image's.
  final double? width;

  /// Forces the box's height. Null takes the image's.
  final double? height;

  final BoxFit fit;

  /// Where the fitted rectangle sits in the box, and - for [BoxFit.cover] and
  /// the two `fit*` rules - which part of the image is kept when it is cropped.
  /// One value drives both, because they are the same choice seen from either
  /// end.
  final Alignment alignment;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderImage createRenderObject(BuildContext context) => RenderImage(
        image,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderImage renderObject,
  ) {
    renderObject
      ..image = image
      ..width = width
      ..height = height
      ..fit = fit
      ..alignment = alignment;
  }
}

/// The render node behind [Image].
final class RenderImage extends RenderBox {
  RenderImage(
    DecodedImage image, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  })  : _image = image,
        _width = width,
        _height = height,
        _fit = fit,
        _alignment = alignment;

  DecodedImage _image;
  double? _width;
  double? _height;
  BoxFit _fit;
  Alignment _alignment;

  /// The pixels at the size they will be drawn, and the key they were produced
  /// for. See the library comment for why this exists rather than a scaling
  /// blit.
  DecodedImage? _scaled;
  String? _scaledKey;

  /// How many times the pixels have been resampled.
  ///
  /// For the test that proves the cache works. A number rather than a boolean
  /// because "it resampled once" and "it resamples every paint" are the two
  /// things worth telling apart, and only a count can.
  int resampleCount = 0;

  DecodedImage get image => _image;

  set image(DecodedImage value) {
    if (identical(value, _image)) return;
    _image = value;
    _dropScaled();
    // The natural size may have changed, so this is a layout change and not
    // merely a paint one.
    markNeedsLayout();
  }

  double? get width => _width;

  set width(double? value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  double? get height => _height;

  set height(double? value) {
    if (value == _height) return;
    _height = value;
    markNeedsLayout();
  }

  BoxFit get fit => _fit;

  set fit(BoxFit value) {
    if (value == _fit) return;
    _fit = value;
    _dropScaled();
    markNeedsPaint();
  }

  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    _dropScaled();
    markNeedsPaint();
  }

  void _dropScaled() {
    _scaled = null;
    _scaledKey = null;
  }

  /// The box this image asks for: its own size, with [width] and [height]
  /// overriding either axis.
  Size get _naturalSize => Size(
        _width ?? _image.width.toDouble(),
        _height ?? _image.height.toDouble(),
      );

  @override
  void performLayout() {
    // `tighten` first so that an explicit width or height wins over a loose
    // parent, and `constrain` second so that a *tight* parent still wins over
    // both - which is the ordering every other box in this framework uses.
    final BoxConstraints tightened =
        constraints.tighten(width: _width, height: _height);
    size = tightened.constrain(_naturalSize);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _naturalSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _naturalSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _naturalSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _naturalSize.height;

  /// An image is opaque to hit testing: it is a picture, and a tap on a picture
  /// landed on the picture. A `GestureDetector` above it is what makes that
  /// mean something.
  @override
  bool hitTestSelf(Offset position) => true;

  /// The part of the image that will be read, in image pixels.
  ///
  /// Exposed because it is the half of [BoxFit] that is invisible in the
  /// output: `cover` and the two `fit*` rules crop, and which part they kept is
  /// otherwise only discoverable by looking at the pixels.
  Rect get sourceRect {
    final FittedSizes fitted = applyBoxFit(_fit, _image.size, size);
    return _alignment.inscribe(fitted.source, _image.bounds);
  }

  /// Where the pixels land, in this node's own coordinates.
  Rect get destinationRect {
    final FittedSizes fitted = applyBoxFit(_fit, _image.size, size);
    return _alignment.inscribe(
      fitted.destination,
      Rect.fromLTWH(0, 0, size.width, size.height),
    );
  }

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty || _image.width == 0) return;
    final FittedSizes fitted = applyBoxFit(_fit, _image.size, size);
    if (fitted.destination.isEmpty) return;

    final Rect source = _alignment.inscribe(fitted.source, _image.bounds);
    final Rect box =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final Rect destination = _alignment.inscribe(fitted.destination, box);

    // Whole pixels, and at least one of them: a buffer cannot be 0.4 pixels
    // wide, and a fitted rectangle that rounds to nothing should disappear
    // rather than throw.
    final int left = destination.left.round();
    final int top = destination.top.round();
    final int pixelWidth = destination.width.round();
    final int pixelHeight = destination.height.round();
    if (pixelWidth <= 0 || pixelHeight <= 0) return;

    final DecodedImage scaled = _scaledFor(source, pixelWidth, pixelHeight);
    final int paintId = list.addPaint(colorArgb: 0xFFFFFFFF);

    // Clipped only when the drawn rectangle really does leave the box, which
    // `cover`, `none` and the two `fit*` rules can all do. The rasteriser would
    // clip to the surface anyway; this clips to the *layout*, so an image
    // cannot spill over a sibling.
    final bool clip = destination.left < box.left - 0.5 ||
        destination.top < box.top - 0.5 ||
        destination.right > box.right + 0.5 ||
        destination.bottom > box.bottom + 0.5;
    if (clip) {
      list
        ..save()
        ..clipRectangle(box);
    }
    // The source rectangle handed to the opcode is the whole of the resampled
    // buffer, because the crop has already been applied by the resample. The
    // CPU renderer ignores this operand entirely - its blit is one source pixel
    // per destination pixel from the buffer's origin - and a GPU backend uses
    // it as texture coordinates, so passing the full extent is correct for
    // both.
    list.drawImage(
      list.addImage(framebufferFromImage(scaled)),
      0,
      0,
      scaled.width.toDouble(),
      scaled.height.toDouble(),
      left.toDouble(),
      top.toDouble(),
      (left + pixelWidth).toDouble(),
      (top + pixelHeight).toDouble(),
      paintId,
    );
    if (clip) list.restore();
  }

  /// The resampled pixels for this source rectangle and size, from the cache
  /// when they are already there.
  ///
  /// The key is a string of five numbers rather than a record because it has to
  /// survive a `Rect` whose edges are irrational - a `contain` fit of a 3:2
  /// image into a square box produces one - and comparing those by value is
  /// exactly what a string of their `toString`s does.
  DecodedImage _scaledFor(Rect source, int pixelWidth, int pixelHeight) {
    final String key = '${source.left},${source.top},${source.right},'
        '${source.bottom},$pixelWidth,$pixelHeight';
    final DecodedImage? cached = _scaled;
    if (cached != null && _scaledKey == key) return cached;
    // The common case worth not paying for: drawing an image at its own size,
    // uncropped, is a copy of itself.
    final DecodedImage produced = pixelWidth == _image.width &&
            pixelHeight == _image.height &&
            source.left == 0 &&
            source.top == 0 &&
            source.right == _image.width &&
            source.bottom == _image.height
        ? _image
        : _resample(source, pixelWidth, pixelHeight);
    _scaled = produced;
    _scaledKey = key;
    return produced;
  }

  DecodedImage _resample(Rect source, int pixelWidth, int pixelHeight) {
    resampleCount++;
    return _image.resample(
      width: pixelWidth,
      height: pixelHeight,
      source: source,
    );
  }
}
