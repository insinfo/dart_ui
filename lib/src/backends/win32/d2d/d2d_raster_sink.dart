/// The bridge from the display-list player to Direct2D.
///
/// The same position in the pipeline as `gpu_raster_sink.dart` and the CPU
/// renderer's sink: the [DisplayListPlayer] still walks the encoded list,
/// still composes transforms and clips into device space, and still culls;
/// this sink only turns what survives into `ID2D1RenderTarget` calls. Writing
/// a second walker for Direct2D would double the places a transform-order bug
/// can live, which is the argument the GPU sink already states.
///
/// ## Coordinate spaces
///
/// Every render target this sink draws into is created at 96 DPI, so one
/// device-independent pixel is exactly one physical pixel and the player's
/// device-space output can be written into Direct2D unchanged. The target's
/// transform is identity except inside [drawDevicePath] and the stroked
/// shapes routed through it, where the *local* geometry plus the player's
/// matrix are handed to Direct2D - which strokes in local units and
/// transforms the outline, exactly the contract `display_list_player.dart`
/// states for stroke widths.
///
/// Clips are pushed while the transform is identity, so an axis-aligned
/// device rectangle stays axis-aligned inside Direct2D too.
///
/// ## What is refused, by name
///
///   * blend modes other than source-over: `ID2D1RenderTarget` composites
///     source-over only; `src` and `plus` need `ID2D1DeviceContext`'s
///     primitive blend, which this first backend does not bind yet;
///   * stroked text, for the reason the CPU sink gives: the glyph route is a
///     coverage mask, and a mask has no outline to stroke;
///   * text under rotation or skew, matching the CPU sink, so the two
///     backends disagree about nothing they both accept.
///
/// ## Glyphs come from the shared CPU rasteriser, not DirectWrite
///
/// The project already owns shaping, hinting policy and a glyph rasteriser;
/// DirectWrite would be a second opinion on every one of those. So glyph
/// coverage is produced by the same [GlyphCache] the CPU renderer uses, each
/// mask is uploaded once as a small premultiplied-alpha bitmap, and the run is
/// blitted with `FillOpacityMask` through the paint's brush - the Direct2D
/// spelling of the glyph atlas the GPU backends keep. Masks are cached per
/// (face, quantised size, glyph, subpixel bucket), so steady-state text costs
/// one `FillOpacityMask` per glyph and no rasterisation.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../geometry/offset.dart';
import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list_opcodes.dart';
import '../../../rendering/framebuffer.dart';
import '../../../rendering/raster/clip_stack.dart' show pixelEdge;
import '../../../rendering/replay/display_list_player.dart';
import '../../../rendering/text/glyph_cache.dart';
import '../../../rendering/text/glyph_raster.dart' show GlyphMask;
import '../../../text/typeface.dart';
import '../d3d12/d3d12_com.dart';
import 'd2d1_interfaces.dart';
import 'd2d1_library.dart';
import 'd2d1_structs.dart';

/// Entries the geometry cache holds before it is emptied wholesale.
///
/// The cache is keyed by path identity, and the player mints a new centreline
/// path for every stroked rectangle it replays, so without a bound the cache
/// would grow by a few entries per frame forever. Wholesale clearing rather
/// than LRU because the cache exists for *intra*-frame repeats (an icon drawn
/// forty times) and for paths the producer interned once; both survive a rare
/// clear at no visible cost.
const int kD2dGeometryCacheLimit = 512;

/// Glyph bitmaps kept before the cache is emptied wholesale. At the typical
/// 16x16 mask this is about 4 MB of video memory, the same order as the CPU
/// glyph cache's byte budget.
const int kD2dGlyphCacheLimit = 4096;

/// Turns the player's device-space primitives into Direct2D calls.
///
/// One sink per render target, reused every frame. [beginFrame] arms it with
/// the frame's resources; [endFrame] settles the clip stack and releases the
/// bitmaps that were created for one-shot images. The sink never calls
/// `BeginDraw`/`EndDraw` - the target does, because only it knows what a
/// failed `EndDraw` means for its surface.
final class D2dRasterSink implements RasterSink {
  D2dRasterSink({
    required D2dRenderTarget target,
    required D2dFactory factory,
    required Allocator allocator,
    required this.backendName,
    GlyphCache? glyphCache,
  })  : _target = target,
        _factory = factory,
        _allocator = allocator,
        _glyphCache = glyphCache ?? GlyphCache() {
    _color = _allocator.allocate<D2dColorF>(sizeOf<D2dColorF>());
    _rect = _allocator.allocate<D2dRectF>(sizeOf<D2dRectF>());
    _sourceRect = _allocator.allocate<D2dRectF>(sizeOf<D2dRectF>());
    _clipRect = _allocator.allocate<D2dRectF>(sizeOf<D2dRectF>());
    _matrix = _allocator.allocate<D2dMatrix3x2F>(sizeOf<D2dMatrix3x2F>());
    _roundedRect = _allocator.allocate<D2dRoundedRect>(sizeOf<D2dRoundedRect>());
    _layerParameters =
        _allocator.allocate<D2dLayerParameters>(sizeOf<D2dLayerParameters>());
    _size = _allocator.allocate<D2dSizeU>(sizeOf<D2dSizeU>());
    _point = _allocator.allocate<D2dPoint2F>(sizeOf<D2dPoint2F>());
    _bezier = _allocator.allocate<D2dBezierSegment>(sizeOf<D2dBezierSegment>());
    _quadratic = _allocator
        .allocate<D2dQuadraticBezierSegment>(sizeOf<D2dQuadraticBezierSegment>());
    _bitmapProperties =
        _allocator.allocate<D2dBitmapProperties>(sizeOf<D2dBitmapProperties>());
    _out = _allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());

    _bitmapProperties.ref
      ..dpiX = 96
      ..dpiY = 96;
    _bitmapProperties.ref.pixelFormat
      ..format = dxgiFormatB8G8R8A8Unorm
      ..alphaMode = d2d1AlphaModePremultiplied;

    // The stroke defaults the replay contract promises: butt cap, miter join,
    // miter limit 4. Direct2D's own defaults differ (miter limit 10), which
    // is why the style is built explicitly instead of passing null.
    final Pointer<D2dStrokeStyleProperties> strokeProperties = _allocator
        .allocate<D2dStrokeStyleProperties>(sizeOf<D2dStrokeStyleProperties>());
    strokeProperties.ref
      ..startCap = d2d1CapStyleFlat
      ..endCap = d2d1CapStyleFlat
      ..dashCap = d2d1CapStyleFlat
      ..lineJoin = d2d1LineJoinMiter
      ..miterLimit = 4
      ..dashStyle = d2d1DashStyleSolid
      ..dashOffset = 0;
    final int hr = _factory.createStrokeStyle(
        strokeProperties, nullptr.cast<Float>(), 0, _out);
    _allocator.free(strokeProperties);
    if (comFailed(hr)) {
      _releaseScratch();
      throw StateError(
          '$backendName: CreateStrokeStyle failed: ${d2dHresultText(hr)}');
    }
    _strokeStyle = _out.value;
  }

  final D2dRenderTarget _target;
  final D2dFactory _factory;
  final Allocator _allocator;

  /// Named in every refusal this sink raises, per section 6.6.
  final String backendName;

  final GlyphCache _glyphCache;

  // Scratch native structures, allocated once and reused per call.
  late final Pointer<D2dColorF> _color;
  late final Pointer<D2dRectF> _rect;
  late final Pointer<D2dRectF> _sourceRect;
  late final Pointer<D2dRectF> _clipRect;
  late final Pointer<D2dMatrix3x2F> _matrix;
  late final Pointer<D2dRoundedRect> _roundedRect;
  late final Pointer<D2dLayerParameters> _layerParameters;
  late final Pointer<D2dSizeU> _size;
  late final Pointer<D2dPoint2F> _point;
  late final Pointer<D2dBezierSegment> _bezier;
  late final Pointer<D2dQuadraticBezierSegment> _quadratic;
  late final Pointer<D2dBitmapProperties> _bitmapProperties;
  late final Pointer<Pointer<Void>> _out;

  late final Pointer<Void> _strokeStyle;

  /// One brush, recoloured per primitive with `SetColor`. Created lazily
  /// because a brush belongs to the target and the first draw is the first
  /// moment one is certainly needed.
  D2dSolidColorBrush? _brush;

  /// The frame's resource tables, armed by [beginFrame]. Only the glyph route
  /// reads them - the player resolves everything else before it calls.
  ReplayResources? _resources;

  /// The axis-aligned clip currently pushed on the target, or NaN-left when
  /// none is. Direct2D requires push/pop nesting, so the active clip is
  /// dropped at every layer boundary and re-pushed on demand.
  double _clipLeft = double.nan;
  double _clipTop = 0;
  double _clipRight = 0;
  double _clipBottom = 0;

  /// `ID2D1Layer` objects, one per depth, created on demand and kept for the
  /// target's life - a layer is a texture and recreating one per `saveLayer`
  /// would be an allocation per frame per panel.
  final List<Pointer<Void>> _layerPool = <Pointer<Void>>[];
  int _layerDepth = 0;

  /// Bitmaps created for this frame's `drawDeviceImage` calls. Released after
  /// the target ends the frame: Direct2D batches commands, and the bitmap has
  /// to outlive the batch, not just the call.
  final List<Pointer<Void>> _frameBitmaps = <Pointer<Void>>[];

  /// Path geometries by (path identity, fill mode). See
  /// [kD2dGeometryCacheLimit] for the eviction story.
  final Map<(Object, int), Pointer<Void>> _geometryCache =
      <(Object, int), Pointer<Void>>{};

  /// Glyph mask bitmaps by (face, quantised size, glyph id, subpixel bucket).
  final Map<(Typeface, int, int, int), _D2dGlyphBitmap> _glyphBitmaps =
      <(Typeface, int, int, int), _D2dGlyphBitmap>{};

  bool _disposed = false;

  // -------------------------------------------------------------------------
  // Frame lifecycle
  // -------------------------------------------------------------------------

  /// Arms the sink for one frame. The caller has already called `BeginDraw`.
  void beginFrame(ReplayResources resources) {
    _resources = resources;
    _layerDepth = 0;
    _dropClip();
  }

  /// Settles the clip stack. Call *before* `EndDraw`; call [releaseFrameData]
  /// after it.
  void endFrame() {
    _dropClip();
    _resources = null;
  }

  /// Releases the one-shot bitmaps of the frame. After `EndDraw`, because the
  /// command batch may still reference them until then.
  void releaseFrameData() {
    for (final Pointer<Void> bitmap in _frameBitmaps) {
      ComObject(bitmap).release();
    }
    _frameBitmaps.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    releaseFrameData();
    for (final Pointer<Void> geometry in _geometryCache.values) {
      ComObject(geometry).release();
    }
    _geometryCache.clear();
    for (final _D2dGlyphBitmap glyph in _glyphBitmaps.values) {
      ComObject(glyph.bitmap).release();
    }
    _glyphBitmaps.clear();
    for (final Pointer<Void> layer in _layerPool) {
      ComObject(layer).release();
    }
    _layerPool.clear();
    _brush?.release();
    _brush = null;
    ComObject(_strokeStyle).release();
    _releaseScratch();
  }

  void _releaseScratch() {
    _allocator
      ..free(_color)
      ..free(_rect)
      ..free(_sourceRect)
      ..free(_clipRect)
      ..free(_matrix)
      ..free(_roundedRect)
      ..free(_layerParameters)
      ..free(_size)
      ..free(_point)
      ..free(_bezier)
      ..free(_quadratic)
      ..free(_bitmapProperties)
      ..free(_out);
  }

  // -------------------------------------------------------------------------
  // RasterSink
  // -------------------------------------------------------------------------

  @override
  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint) {
    _requireSrcOver(paint, 'a saveLayer');
    // Clips and layers share one nesting stack inside Direct2D; the active
    // clip is dropped so the layer push nests correctly, and the next
    // primitive inside re-pushes its own.
    _dropClip();

    if (_layerPool.length <= _layerDepth) {
      final int hr = _target.createLayer(nullptr, _out);
      if (comFailed(hr)) {
        throw StateError(
            '$backendName: CreateLayer failed: ${d2dHresultText(hr)}');
      }
      _layerPool.add(_out.value);
    }
    final Pointer<Void> layer = _layerPool[_layerDepth];
    _layerDepth++;

    // The player already intersected the declared bounds with the clip, so
    // the content bounds are the whole promise. An empty rectangle is pushed
    // anyway - the pairs must stay balanced, and Direct2D draws nothing into
    // an empty layer, which is exactly the contract.
    _layerParameters.ref
      ..geometricMask = nullptr
      ..maskAntialiasMode = d2d1AntialiasModePerPrimitive
      ..opacity = ((paint.argbColor >> 24) & 0xFF) / 255.0
      ..opacityBrush = nullptr
      ..layerOptions = d2d1LayerOptionsNone;
    _layerParameters.ref.contentBounds
      ..left = deviceBounds.left
      ..top = deviceBounds.top
      ..right = deviceBounds.right
      ..bottom = deviceBounds.bottom;
    final D2dMatrix3x2F mask = _layerParameters.ref.maskTransform;
    mask
      ..m11 = 1
      ..m12 = 0
      ..m21 = 0
      ..m22 = 1
      ..dx = 0
      ..dy = 0;
    _target.pushLayer(_layerParameters, layer);
  }

  @override
  void endLayer() {
    if (_layerDepth == 0) {
      throw StateError('$backendName: endLayer() without a matching '
          'beginLayer(); the player and this sink disagree about how many '
          'layers are open');
    }
    _dropClip();
    _layerDepth--;
    _target.popLayer();
  }

  @override
  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) {
    _requireSrcOver(paint, 'a rectangle');
    _ensureClip(clip);
    _rect.ref
      ..left = deviceRect.left
      ..top = deviceRect.top
      ..right = deviceRect.right
      ..bottom = deviceRect.bottom;
    final bool aliased = !paint.antiAlias;
    if (aliased) _target.setAntialiasMode(d2d1AntialiasModeAliased);
    _target.fillRectangle(_rect, _solidBrush(paint.argbColor));
    if (aliased) _target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
  }

  @override
  void fillDeviceRRect(
    Rect deviceRect,
    Rect clip,
    Float32List deviceRadii,
    ReplayPaint paint,
  ) {
    _requireSrcOver(paint, 'a rounded rectangle');
    // D2D1_ROUNDED_RECT carries one x and one y radius for all four corners;
    // per-corner radii need a path. The uniform case is the overwhelmingly
    // common one - every themed control - so it keeps the fast shape.
    final double rx = deviceRadii[0];
    final double ry = deviceRadii[1];
    var uniform = true;
    for (var i = 2; i < 8; i += 2) {
      if (deviceRadii[i] != rx || deviceRadii[i + 1] != ry) {
        uniform = false;
        break;
      }
    }
    if (!uniform) {
      final PathBuilder builder = PathBuilder()
        ..addRoundedRectRadii(deviceRect, deviceRadii);
      drawDevicePath(builder.build(), Transform2D.identity, clip, paint);
      return;
    }
    _ensureClip(clip);
    _roundedRect.ref
      ..radiusX = rx
      ..radiusY = ry;
    _roundedRect.ref.rect
      ..left = deviceRect.left
      ..top = deviceRect.top
      ..right = deviceRect.right
      ..bottom = deviceRect.bottom;
    final bool aliased = !paint.antiAlias;
    if (aliased) _target.setAntialiasMode(d2d1AntialiasModeAliased);
    _target.fillRoundedRectangle(_roundedRect, _solidBrush(paint.argbColor));
    if (aliased) _target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
  }

  @override
  void drawDevicePath(
    Object path,
    Transform2D transform,
    Rect clip,
    ReplayPaint paint,
  ) {
    if (path is! Path) {
      throw ArgumentError.value(
        path,
        'path',
        '$backendName draws geometry Path objects; got ${path.runtimeType}',
      );
    }
    _requireSrcOver(paint, 'a path');
    if (path.isEmpty) return;

    final int fillMode = paint.fillRule == pathFillRuleEvenOdd
        ? d2d1FillModeAlternate
        : d2d1FillModeWinding;
    final Pointer<Void> geometry = _geometryFor(path, fillMode);

    // Clip first, under the identity transform, so the axis-aligned device
    // rectangle means what the player computed. Only then the matrix.
    _ensureClip(clip);
    _setTransform(transform);

    final bool aliased = !paint.antiAlias;
    if (aliased) _target.setAntialiasMode(d2d1AntialiasModeAliased);

    final Pointer<Void> brush = _solidBrush(paint.argbColor);
    // Fill before stroke, or the stroke's inner half disappears under the
    // fill - the ordering rule RasterSink.drawDevicePath states.
    if (paint.style == paintStyleFill ||
        paint.style == paintStyleFillAndStroke) {
      _target.fillGeometry(geometry, brush);
    }
    if (paint.style == paintStyleStroke ||
        paint.style == paintStyleFillAndStroke) {
      _target.drawGeometry(geometry, brush, paint.strokeWidth, _strokeStyle);
    }

    if (aliased) _target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
    _setIdentityTransform();
  }

  @override
  void drawDeviceImage(
    Object image,
    Rect sourceRect,
    Rect deviceRect,
    Rect clip,
    ReplayPaint paint,
  ) {
    if (image is! Framebuffer) {
      throw ArgumentError.value(
        image,
        'image',
        '$backendName draws Framebuffer images; got ${image.runtimeType}',
      );
    }
    _requireSrcOver(paint, 'an image');
    _ensureClip(clip);

    final Pointer<Void> bitmap = _uploadFramebuffer(image);
    _frameBitmaps.add(bitmap);

    _rect.ref
      ..left = deviceRect.left
      ..top = deviceRect.top
      ..right = deviceRect.right
      ..bottom = deviceRect.bottom;
    _sourceRect.ref
      ..left = sourceRect.left
      ..top = sourceRect.top
      ..right = sourceRect.right
      ..bottom = sourceRect.bottom;

    // Nearest when the blit is 1:1 so a UI icon stays pixel-exact like the
    // CPU blit; linear when it actually scales.
    final bool oneToOne = deviceRect.width == sourceRect.width &&
        deviceRect.height == sourceRect.height;
    _target.drawBitmap(
      bitmap,
      _rect,
      ((paint.argbColor >> 24) & 0xFF) / 255.0,
      oneToOne
          ? d2d1BitmapInterpolationModeNearestNeighbor
          : d2d1BitmapInterpolationModeLinear,
      _sourceRect,
    );
  }

  @override
  void drawDeviceGlyphRun(
    int fontId,
    Offset deviceOrigin,
    Transform2D transform,
    Int32List glyphIds,
    Float32List deviceOffsets,
    int glyphCount,
    Rect clip,
    ReplayPaint paint,
  ) {
    final ReplayResources? resources = _resources;
    if (resources == null) {
      throw StateError('$backendName: drawDeviceGlyphRun before beginFrame(); '
          'the sink has no resource table to resolve fontId $fontId against');
    }
    final Object resource = resources.fontAt(fontId);
    if (resource is! ScaledTypeface) {
      throw ArgumentError.value(
        resource,
        'font',
        '$backendName rasterizes ScaledTypeface faces; got '
            '${resource.runtimeType}',
      );
    }
    // Same refusal, same reason as the CPU sink: the glyph route is a
    // coverage mask, and a mask has no outline to stroke.
    if (paint.style != paintStyleFill) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'stroked text is not implemented; glyph coverage comes from '
            'the shared CPU glyph cache, and a coverage mask has no outline '
            'to stroke',
      );
    }
    _requireSrcOver(paint, 'a glyph run');
    final int argb = paint.argbColor;
    if ((argb >> 24) & 0xFF == 0) return;

    final ScaledTypeface font = _deviceFont(resource, transform);
    final int sizeKey = (font.pixelSize * kSizeQuantum).round();

    _ensureClip(clip);
    final Pointer<Void> brush = _solidBrush(argb);
    // FillOpacityMask requires the aliased mode - the mask *is* the
    // antialiasing, baked in by the CPU rasteriser.
    _target.setAntialiasMode(d2d1AntialiasModeAliased);
    for (var i = 0; i < glyphCount; i++) {
      final double penX = deviceOrigin.dx + deviceOffsets[i * 2];
      final double penY = deviceOrigin.dy + deviceOffsets[i * 2 + 1];
      final int bucket = glyphSubpixelBucket(penX);
      final _D2dGlyphBitmap? glyph =
          _glyphBitmap(font, sizeKey, glyphIds[i], bucket);
      if (glyph == null) continue;

      final double left =
          (glyphPixelOrigin(penX) + glyph.left).toDouble();
      final double top = (pixelEdge(penY) + glyph.top).toDouble();
      _rect.ref
        ..left = left
        ..top = top
        ..right = left + glyph.width
        ..bottom = top + glyph.height;
      _sourceRect.ref
        ..left = 0
        ..top = 0
        ..right = glyph.width.toDouble()
        ..bottom = glyph.height.toDouble();
      _target.fillOpacityMask(glyph.bitmap, brush, _rect, _sourceRect);
    }
    _target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
  }

  // -------------------------------------------------------------------------
  // Gradient brushes - bound and exercised, not yet reachable from the wire
  // -------------------------------------------------------------------------

  /// Creates a linear gradient brush over [stops].
  ///
  /// The display-list paint record carries a single colour today, so the
  /// player can never ask for this; it exists - and is tested against real
  /// pixels - so that the day the wire format grows gradient paints, the
  /// Direct2D half is already proven. [stops] is a list of
  /// `(position, argb)` pairs in stop order. The caller owns the returned
  /// brush and must release it with [ComObject.release].
  Pointer<Void> createLinearGradientBrush({
    required Offset start,
    required Offset end,
    required List<(double, int)> stops,
  }) {
    final Pointer<Void> collection = _gradientStops(stops);
    final Pointer<D2dLinearGradientBrushProperties> properties =
        _allocator.allocate<D2dLinearGradientBrushProperties>(
            sizeOf<D2dLinearGradientBrushProperties>());
    properties.ref.startPoint
      ..x = start.dx
      ..y = start.dy;
    properties.ref.endPoint
      ..x = end.dx
      ..y = end.dy;
    final int hr = _target.createLinearGradientBrush(
        properties, collection, _out);
    _allocator.free(properties);
    ComObject(collection).release();
    if (comFailed(hr)) {
      throw StateError('$backendName: CreateLinearGradientBrush failed: '
          '${d2dHresultText(hr)}');
    }
    return _out.value;
  }

  /// Creates a radial gradient brush over [stops]; see
  /// [createLinearGradientBrush] for ownership and why this exists now.
  Pointer<Void> createRadialGradientBrush({
    required Offset center,
    required double radiusX,
    required double radiusY,
    required List<(double, int)> stops,
  }) {
    final Pointer<Void> collection = _gradientStops(stops);
    final Pointer<D2dRadialGradientBrushProperties> properties =
        _allocator.allocate<D2dRadialGradientBrushProperties>(
            sizeOf<D2dRadialGradientBrushProperties>());
    properties.ref.center
      ..x = center.dx
      ..y = center.dy;
    properties.ref.gradientOriginOffset
      ..x = 0
      ..y = 0;
    properties.ref
      ..radiusX = radiusX
      ..radiusY = radiusY;
    final int hr = _target.createRadialGradientBrush(
        properties, collection, _out);
    _allocator.free(properties);
    ComObject(collection).release();
    if (comFailed(hr)) {
      throw StateError('$backendName: CreateRadialGradientBrush failed: '
          '${d2dHresultText(hr)}');
    }
    return _out.value;
  }

  /// Fills [deviceRect] with an already created gradient (or any) brush.
  /// The test-visible seam for the gradient methods above.
  void fillRectWithBrush(Rect deviceRect, Pointer<Void> brush) {
    _rect.ref
      ..left = deviceRect.left
      ..top = deviceRect.top
      ..right = deviceRect.right
      ..bottom = deviceRect.bottom;
    _target.fillRectangle(_rect, brush);
  }

  Pointer<Void> _gradientStops(List<(double, int)> stops) {
    if (stops.length < 2) {
      throw ArgumentError.value(
          stops.length, 'stops', 'a gradient needs at least two stops');
    }
    final Pointer<D2dGradientStop> native = _allocator
        .allocate<D2dGradientStop>(sizeOf<D2dGradientStop>() * stops.length);
    for (var i = 0; i < stops.length; i++) {
      final (double position, int argb) = stops[i];
      final D2dGradientStop stop = (native + i).ref;
      stop.position = position;
      stop.color
        ..a = ((argb >> 24) & 0xFF) / 255.0
        ..r = ((argb >> 16) & 0xFF) / 255.0
        ..g = ((argb >> 8) & 0xFF) / 255.0
        ..b = (argb & 0xFF) / 255.0;
    }
    final int hr = _target.createGradientStopCollection(
        native, stops.length, d2d1Gamma22, d2d1ExtendModeClamp, _out);
    _allocator.free(native);
    if (comFailed(hr)) {
      throw StateError('$backendName: CreateGradientStopCollection failed: '
          '${d2dHresultText(hr)}');
    }
    return _out.value;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Direct2D's classic render target composites source-over only. Everything
  /// else is refused by name rather than approximated - a `plus` drawn as
  /// source-over is a picture that is quietly wrong, which is the failure
  /// mode section 6.6 forbids.
  void _requireSrcOver(ReplayPaint paint, String what) {
    if (paint.blendMode == blendModeSrcOver) return;
    throw UnsupportedCapabilityError(
      backendName: backendName,
      capability: Capability.gpuPresentation,
      detail: 'blend mode ${paint.blendMode} on $what: ID2D1RenderTarget '
          'composites source-over only; src and plus need the '
          'ID2D1DeviceContext primitive blend, which this backend does not '
          'bind yet',
    );
  }

  Pointer<Void> _solidBrush(int argb) {
    _color.ref
      ..a = ((argb >> 24) & 0xFF) / 255.0
      ..r = ((argb >> 16) & 0xFF) / 255.0
      ..g = ((argb >> 8) & 0xFF) / 255.0
      ..b = (argb & 0xFF) / 255.0;
    final D2dSolidColorBrush? existing = _brush;
    if (existing != null) {
      existing.setColor(_color);
      return existing.pointer;
    }
    final int hr = _target.createSolidColorBrush(_color, _out);
    if (comFailed(hr)) {
      throw StateError('$backendName: CreateSolidColorBrush failed: '
          '${d2dHresultText(hr)}');
    }
    final D2dSolidColorBrush brush = D2dSolidColorBrush(_out.value);
    _brush = brush;
    return brush.pointer;
  }

  void _ensureClip(Rect clip) {
    if (clip.left == _clipLeft &&
        clip.top == _clipTop &&
        clip.right == _clipRight &&
        clip.bottom == _clipBottom) {
      return;
    }
    _dropClip();
    _clipRect.ref
      ..left = clip.left
      ..top = clip.top
      ..right = clip.right
      ..bottom = clip.bottom;
    _target.pushAxisAlignedClip(_clipRect, d2d1AntialiasModePerPrimitive);
    _clipLeft = clip.left;
    _clipTop = clip.top;
    _clipRight = clip.right;
    _clipBottom = clip.bottom;
  }

  void _dropClip() {
    if (_clipLeft.isNaN) return;
    _target.popAxisAlignedClip();
    _clipLeft = double.nan;
  }

  void _setTransform(Transform2D transform) {
    if (transform.isIdentity) return;
    _matrix.ref
      ..m11 = transform.a
      ..m12 = transform.b
      ..m21 = transform.c
      ..m22 = transform.d
      ..dx = transform.tx
      ..dy = transform.ty;
    _target.setTransform(_matrix);
  }

  void _setIdentityTransform() {
    _matrix.ref
      ..m11 = 1
      ..m12 = 0
      ..m21 = 0
      ..m22 = 1
      ..dx = 0
      ..dy = 0;
    _target.setTransform(_matrix);
  }

  Pointer<Void> _geometryFor(Path path, int fillMode) {
    final (Object, int) key = (path, fillMode);
    final Pointer<Void>? cached = _geometryCache[key];
    if (cached != null) return cached;
    if (_geometryCache.length >= kD2dGeometryCacheLimit) {
      for (final Pointer<Void> geometry in _geometryCache.values) {
        ComObject(geometry).release();
      }
      _geometryCache.clear();
    }
    final Pointer<Void> geometry = _buildGeometry(path, fillMode);
    _geometryCache[key] = geometry;
    return geometry;
  }

  /// Streams [path]'s verbs into a new `ID2D1PathGeometry`.
  ///
  /// The path's verbs map one-to-one: no flattening happens here - Direct2D
  /// consumes the same quadratics and cubics [Path] stores, which is the
  /// entire reason a GPU-quality rasteriser was worth binding.
  Pointer<Void> _buildGeometry(Path path, int fillMode) {
    int hr = _factory.createPathGeometry(_out);
    if (comFailed(hr)) {
      throw StateError(
          '$backendName: CreatePathGeometry failed: ${d2dHresultText(hr)}');
    }
    final D2dPathGeometry geometry = D2dPathGeometry(_out.value);
    hr = geometry.open(_out);
    if (comFailed(hr)) {
      geometry.release();
      throw StateError('$backendName: ID2D1PathGeometry::Open failed: '
          '${d2dHresultText(hr)}');
    }
    final D2dGeometrySink sink = D2dGeometrySink(_out.value);
    sink.setFillMode(fillMode);

    var figureOpen = false;
    var point = 0;
    for (var v = 0; v < path.verbCount; v++) {
      switch (path.verbAt(v)) {
        case verbMoveTo:
          if (figureOpen) sink.endFigure(d2d1FigureEndOpen);
          _point.ref
            ..x = path.pointX(point)
            ..y = path.pointY(point);
          point += 1;
          sink.beginFigure(_point.ref, d2d1FigureBeginFilled);
          figureOpen = true;
        case verbLineTo:
          _point.ref
            ..x = path.pointX(point)
            ..y = path.pointY(point);
          point += 1;
          sink.addLine(_point.ref);
        case verbQuadraticTo:
          _quadratic.ref.point1
            ..x = path.pointX(point)
            ..y = path.pointY(point);
          _quadratic.ref.point2
            ..x = path.pointX(point + 1)
            ..y = path.pointY(point + 1);
          point += 2;
          sink.addQuadraticBezier(_quadratic);
        case verbCubicTo:
          _bezier.ref.point1
            ..x = path.pointX(point)
            ..y = path.pointY(point);
          _bezier.ref.point2
            ..x = path.pointX(point + 1)
            ..y = path.pointY(point + 1);
          _bezier.ref.point3
            ..x = path.pointX(point + 2)
            ..y = path.pointY(point + 2);
          point += 3;
          sink.addBezier(_bezier);
        case verbClose:
          if (figureOpen) {
            sink.endFigure(d2d1FigureEndClosed);
            figureOpen = false;
          }
      }
    }
    if (figureOpen) sink.endFigure(d2d1FigureEndOpen);

    hr = sink.close();
    sink.release();
    if (comFailed(hr)) {
      geometry.release();
      throw StateError('$backendName: ID2D1GeometrySink::Close failed: '
          '${d2dHresultText(hr)}');
    }
    return geometry.pointer;
  }

  /// Uploads [image] as a premultiplied BGRA bitmap. RGBA sources are
  /// swizzled on the way in; the target format is always BGRA because that is
  /// what the render targets in this directory are created with.
  Pointer<Void> _uploadFramebuffer(Framebuffer image) {
    final int width = image.width;
    final int height = image.height;
    final int pitch = width * 4;
    final Pointer<Uint8> staging =
        _allocator.allocate<Uint8>(pitch * height);
    final Uint8List stagingBytes = staging.asTypedList(pitch * height);
    final bool bgra = image.format == PixelFormat.bgra8888Premultiplied;
    for (var y = 0; y < height; y++) {
      final int sourceRow = y * image.bytesPerRow;
      final int targetRow = y * pitch;
      if (bgra) {
        stagingBytes.setRange(
            targetRow, targetRow + pitch, image.pixels, sourceRow);
      } else {
        for (var x = 0; x < width; x++) {
          final int s = sourceRow + x * 4;
          final int t = targetRow + x * 4;
          stagingBytes[t] = image.pixels[s + 2];
          stagingBytes[t + 1] = image.pixels[s + 1];
          stagingBytes[t + 2] = image.pixels[s];
          stagingBytes[t + 3] = image.pixels[s + 3];
        }
      }
    }
    _size.ref
      ..width = width
      ..height = height;
    final int hr = _target.createBitmap(
        _size.ref, staging.cast<Void>(), pitch, _bitmapProperties, _out);
    _allocator.free(staging);
    if (comFailed(hr)) {
      throw StateError(
          '$backendName: CreateBitmap failed: ${d2dHresultText(hr)}');
    }
    return _out.value;
  }

  /// The cached mask bitmap for one glyph, or null for an empty mask.
  _D2dGlyphBitmap? _glyphBitmap(
    ScaledTypeface font,
    int sizeKey,
    int glyphId,
    int bucket,
  ) {
    final (Typeface, int, int, int) key =
        (font.typeface, sizeKey, glyphId, bucket);
    final _D2dGlyphBitmap? cached = _glyphBitmaps[key];
    if (cached != null) return cached.isEmpty ? null : cached;

    if (_glyphBitmaps.length >= kD2dGlyphCacheLimit) {
      for (final _D2dGlyphBitmap glyph in _glyphBitmaps.values) {
        if (!glyph.isEmpty) ComObject(glyph.bitmap).release();
      }
      _glyphBitmaps.clear();
    }

    final GlyphMask mask =
        _glyphCache.maskFor(font, glyphId, subpixelBucket: bucket);
    if (mask.isEmpty) {
      final _D2dGlyphBitmap empty = _D2dGlyphBitmap.empty();
      _glyphBitmaps[key] = empty;
      return null;
    }

    // Coverage byte -> premultiplied white. FillOpacityMask samples only the
    // alpha channel; the colour channels are set to match so the bitmap is
    // also honest if anything ever draws it directly.
    final int pitch = mask.width * 4;
    final Pointer<Uint8> staging =
        _allocator.allocate<Uint8>(pitch * mask.height);
    final Uint8List bytes = staging.asTypedList(pitch * mask.height);
    for (var i = 0; i < mask.coverage.length; i++) {
      final int coverage = mask.coverage[i];
      final int t = i * 4;
      bytes[t] = coverage;
      bytes[t + 1] = coverage;
      bytes[t + 2] = coverage;
      bytes[t + 3] = coverage;
    }
    _size.ref
      ..width = mask.width
      ..height = mask.height;
    final int hr = _target.createBitmap(
        _size.ref, staging.cast<Void>(), pitch, _bitmapProperties, _out);
    _allocator.free(staging);
    if (comFailed(hr)) {
      throw StateError('$backendName: CreateBitmap for a glyph mask failed: '
          '${d2dHresultText(hr)}');
    }
    final _D2dGlyphBitmap glyph = _D2dGlyphBitmap(
      bitmap: _out.value,
      width: mask.width,
      height: mask.height,
      left: mask.left,
      top: mask.top,
    );
    _glyphBitmaps[key] = glyph;
    return glyph;
  }

  /// [font] at the size the device transform asks for - the same rule, and
  /// the same refusal, as the CPU sink's `_deviceFont`, so the two backends
  /// accept exactly the same runs.
  ScaledTypeface _deviceFont(ScaledTypeface font, Transform2D transform) {
    final double a = transform.a;
    final double d = transform.d;
    if (transform.b != 0 || transform.c != 0 || a <= 0 || d <= 0 || a != d) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'text under a rotated, skewed, mirrored or non-uniformly '
            'scaled transform is not implemented; the glyph rasterizer takes '
            'a uniform scale, and drawing this run would silently produce '
            'upright text (transform $transform)',
      );
    }
    if (a == 1) return font;
    return ScaledTypeface(font.typeface, font.pixelSize * a);
  }
}

/// One glyph's uploaded mask, or the shared record of "this glyph draws
/// nothing" so a space is not re-rasterised per frame.
final class _D2dGlyphBitmap {
  _D2dGlyphBitmap({
    required this.bitmap,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
  });

  _D2dGlyphBitmap.empty()
      : bitmap = nullptr,
        width = 0,
        height = 0,
        left = 0,
        top = 0;

  final Pointer<Void> bitmap;
  final int width;
  final int height;
  final int left;
  final int top;

  bool get isEmpty => width == 0 || height == 0;
}
