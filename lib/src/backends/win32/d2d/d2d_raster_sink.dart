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
///     coverage mask, and a mask has no outline to stroke.
///
/// Text under a rotated, skewed, mirrored or non-uniformly scaled transform is
/// **not** on that list any more, and the comment that said it was is the
/// pendency ADR 0007 recorded by name. See below.
///
/// ## DirectWrite is an application's choice, and it is off
///
/// Everything below describes what this sink does by default and what it does
/// on every platform: the framework's own coverage, drawn the framework's own
/// way. An application that would rather have Windows' own look can say so
/// with [GlyphRasterization.platformNative], and then - and only then - an
/// upright run whose font is installed on the machine is handed to
/// `ID2D1RenderTarget::DrawGlyphRun` with the glyph ids, the size and the
/// per-glyph offsets this framework computed. Shaping, metrics and line
/// breaking never move; see [_drawGlyphRunNatively] for exactly what is
/// delegated and `doc/architecture/TEXTO_DIRECT2D.md` for why the default is
/// the other one.
///
/// ## Glyphs come from the shared CPU rasteriser, not DirectWrite
///
/// The project already owns shaping, hinting policy and a glyph rasteriser;
/// DirectWrite would be a second opinion on every one of those. So glyph
/// coverage is produced by the same [GlyphCache] the CPU renderer uses, each
/// mask is written once into a [D2dGlyphAtlas], and a run is drawn from that
/// one bitmap - the Direct2D spelling of the glyph atlas the GPU backends
/// keep. Masks are keyed per (face, quantised size, glyph, subpixel bucket),
/// so steady-state text costs no rasterisation and no upload.
///
/// ## One bitmap, and where possible one call
///
/// This used to be one `FillOpacityMask` per glyph, each from that glyph's own
/// small bitmap, and `d2d_text_cost_test.dart` was written to find out which
/// half of that was expensive. Drawing 3400 glyph-sized quads over 1280x720 on
/// this machine: **12.1 ms** from a bitmap each, **5.4 ms** from one atlas
/// with the call count unchanged, **4.5 ms** as a single `DrawSpriteBatch`.
///
/// The call count was not the story. Two thirds of the cost was *changing
/// which bitmap the call reads*, so the atlas is the change that matters and
/// it is unconditional. The batch is worth a further 15% and needs
/// `ID2D1DeviceContext3`, which the targets in `d2d_targets.dart` turn out to
/// answer `QueryInterface` for - see [D2dDeviceContext3] - so a run is issued
/// as one `DrawSpriteBatch` where the runtime has one and as a loop of
/// `FillOpacityMask` over the same atlas where it does not. Both routes place
/// identical quads over identical texels and blend them in the same order, one
/// glyph at a time, so neither can disagree with the other about a pixel.
///
/// ## And from the glyph's outline when a mask cannot carry the matrix
///
/// A mask is a rectangle of pixels: it can be blitted and nothing else. The
/// moment the matrix rotates, skews, mirrors or scales the two axes
/// differently, this sink leaves the bitmap route and fills each glyph's
/// *outline* as an `ID2D1PathGeometry` under the full matrix - the same
/// `FillGeometry` [drawDevicePath] uses, so a rotated letter and a rotated
/// path beside it go through one rasteriser.
///
/// The criterion is [glyphMasksFit] and the matrix is [glyphOutlineTransform],
/// both imported from `rendering/text/glyph_raster.dart` rather than restated
/// here: the CPU renderer and the GPU sink import the same two functions, and
/// a criterion copied into a third file is exactly how one backend ends up
/// refusing a scene the other two draw. That is the divergence ADR 0007 left
/// open on this backend and this is where it closes.
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
import '../../../rendering/render_policy.dart';
import '../../../rendering/replay/display_list_player.dart';
import '../../../rendering/text/glyph_cache.dart';
import '../../../rendering/text/glyph_raster.dart'
    show GlyphMask, glyphMasksFit, glyphOutlineTransform;
import '../../../text/typeface.dart';
import '../d3d12/d3d12_com.dart';
import 'd2d1_interfaces.dart';
import 'd2d1_library.dart';
import 'd2d1_structs.dart';
import 'd2d_glyph_atlas.dart';
import 'dwrite_font_faces.dart';
import 'dwrite_interfaces.dart';

/// Entries the geometry cache holds before it is emptied wholesale.
///
/// The cache is keyed by path identity, and the player mints a new centreline
/// path for every stroked rectangle it replays, so without a bound the cache
/// would grow by a few entries per frame forever. Wholesale clearing rather
/// than LRU because the cache exists for *intra*-frame repeats (an icon drawn
/// forty times) and for paths the producer interned once; both survive a rare
/// clear at no visible cost. The clear happens after `EndDraw` rather than at
/// the moment the limit is crossed - see `_geometryFor`, and note that a
/// rotated run adds one entry per distinct glyph.
const int kD2dGeometryCacheLimit = 512;

/// Standalone glyph bitmaps kept before that cache is emptied wholesale.
///
/// This is the *fallback* cache now: everything that fits goes into the
/// [D2dGlyphAtlas], and a bitmap of its own is what a glyph gets when its mask
/// cannot fit an empty atlas - display type at a few hundred pixels. A run of
/// those is a handful of glyphs, so the limit is small on purpose; a cache
/// sized for body text here would be memory reserved for a case that never
/// fills it.
const int kD2dGlyphCacheLimit = 64;

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
    this.spriteBatching = true,
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
    _spriteColor = _allocator.allocate<D2dColorF>(sizeOf<D2dColorF>());
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

  /// Whether a glyph run may be issued as one `DrawSpriteBatch`.
  ///
  /// True in production. A test sets it false to exercise the loop of
  /// `FillOpacityMask` calls that a runtime without `ID2D1DeviceContext3`
  /// would take, which is how `d2d_glyph_transform_test.dart` can assert that
  /// the two routes agree pixel for pixel on the same machine rather than
  /// hoping they do on some other one.
  final bool spriteBatching;

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

  /// The tint every sprite of a run multiplies its coverage by.
  ///
  /// Separate from [_color], which [_solidBrush] overwrites: a sprite array is
  /// read by Direct2D at `AddSprites` time and the brush may be recoloured
  /// between building the array and drawing it.
  late final Pointer<D2dColorF> _spriteColor;
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

  /// Set when [_geometryFor] finds the cache over [kD2dGeometryCacheLimit];
  /// acted on by [releaseFrameData], after `EndDraw`. See there.
  bool _geometryEvictionPending = false;

  /// Standalone mask bitmaps for glyphs too large for the atlas, by (face,
  /// quantised size, glyph id, subpixel bucket).
  final Map<(Typeface, int, int, int), _D2dGlyphBitmap> _glyphBitmaps =
      <(Typeface, int, int, int), _D2dGlyphBitmap>{};

  /// How many standalone glyph bitmaps are held, for tests and diagnostics.
  ///
  /// Zero for body text now: everything that fits goes into [glyphAtlas]. A
  /// non-zero count means display type went down the oversize fallback.
  int get glyphBitmapCount => _glyphBitmaps.length;

  /// Resident glyphs in the atlas, for tests and diagnostics.
  ///
  /// The cost model is asserted through this rather than assumed: a run the
  /// outline route drew must leave it at 0, because the atlas key has nowhere
  /// to record an angle and an entry made under one matrix would be blitted
  /// upright under the next.
  int get glyphAtlasEntryCount => _atlas?.entryCount ?? 0;

  /// The atlas, once a run has needed one. Null before that and after
  /// [dispose]; tests read [glyphAtlasEntryCount] rather than this.
  D2dGlyphAtlas? get glyphAtlas => _atlas;

  /// Whether runs on this sink are being issued as sprite batches.
  ///
  /// Answered by the runtime, not by [spriteBatching] alone: null until the
  /// first run has asked `QueryInterface` for an `ID2D1DeviceContext3`.
  bool? get usesSpriteBatch => _spriteRouteResolved ? _batch != null : null;

  /// The glyph atlas every upright run draws from. See `d2d_glyph_atlas.dart`.
  D2dGlyphAtlas? _atlas;

  /// The device context the batch belongs to, the batch, and whether the pair
  /// has been asked for yet. Resolved once per sink, on the first run.
  D2dDeviceContext3? _spriteContext;
  D2dSpriteBatch? _batch;
  bool _spriteRouteResolved = false;

  /// Sprites already appended to [_batch] this frame.
  ///
  /// The batch is filled across the whole frame and cleared after `EndDraw`,
  /// never mid-frame: `Clear` on a batch a recorded command still points at is
  /// the same hazard [D2dBitmap.copyFromMemory] states, and the start-index
  /// argument of `DrawSpriteBatch` exists precisely so it need not be.
  int _batchOffset = 0;

  /// Whether a command that samples the atlas is sitting in Direct2D's
  /// unflushed batch. See [_drawSprites].
  bool _atlasSampled = false;

  /// The sprite arrays handed to `AddSprites`, grown to the longest run seen.
  Pointer<D2dRectF> _spriteDestinations = nullptr;
  Pointer<D2dRectU> _spriteSources = nullptr;
  int _spriteCapacity = 0;

  /// DirectWrite, opened on the first run drawn under
  /// [GlyphRasterization.platformNative] and never otherwise. Null after a
  /// load that failed, which is a normal answer and not an error: the run
  /// takes the portable route.
  DWriteFontFaces? _dwriteFaces;
  bool _dwriteResolved = false;

  /// Why the native route was not taken, for a diagnostic that would
  /// otherwise be "I turned the option on and nothing changed".
  ///
  /// The last reason, not a list: the same font refuses for the same reason on
  /// every run, and a growing list of identical strings is not a diagnostic.
  String? _nativeTextRefusal;

  /// The last refusal the native-text route recorded, or null if it has not
  /// refused. Read by tests and by anyone asking why the option did nothing.
  String? get nativeTextRefusal => _nativeTextRefusal;

  /// How many runs this sink has drawn through `DrawGlyphRun`.
  ///
  /// The only way a test can tell the two routes apart from the outside: the
  /// native route is *supposed* to produce different pixels, so "did it look
  /// different" is not an assertion, and this is.
  int get nativeTextRunCount => _nativeTextRunCount;
  int _nativeTextRunCount = 0;

  /// The glyph-run structure and its three arrays, grown to the longest run.
  Pointer<DWriteGlyphRun> _dwriteRun = nullptr;
  Pointer<Uint16> _dwriteIndices = nullptr;
  Pointer<Float> _dwriteAdvances = nullptr;
  Pointer<DWriteGlyphOffset> _dwriteOffsets = nullptr;
  int _dwriteCapacity = 0;

  bool _disposed = false;

  // -------------------------------------------------------------------------
  // Frame lifecycle
  // -------------------------------------------------------------------------

  /// Arms the sink for one frame. The caller has already called `BeginDraw`.
  void beginFrame(ReplayResources resources) {
    _resources = resources;
    _layerDepth = 0;
    // Both are settled by the previous frame's `EndDraw`, which executes
    // everything Direct2D had batched; saying so here rather than trusting it
    // means a target that skipped [releaseFrameData] starts clean instead of
    // drawing this frame's first run at last frame's offset.
    _batchOffset = 0;
    _atlasSampled = false;
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
    // After `EndDraw`, for the reason the field states: until the command
    // batch has run, the sprites are still being read.
    if (_batchOffset > 0) {
      _batch?.clear();
      _batchOffset = 0;
    }
    if (_geometryEvictionPending) {
      _geometryEvictionPending = false;
      for (final Pointer<Void> geometry in _geometryCache.values) {
        ComObject(geometry).release();
      }
      _geometryCache.clear();
    }
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
    _batch?.release();
    _batch = null;
    _spriteContext?.release();
    _spriteContext = null;
    _atlas?.dispose();
    _atlas = null;
    if (_spriteCapacity > 0) {
      _allocator
        ..free(_spriteDestinations)
        ..free(_spriteSources);
      _spriteCapacity = 0;
      _spriteDestinations = nullptr;
      _spriteSources = nullptr;
    }
    if (_dwriteCapacity > 0) {
      _allocator
        ..free(_dwriteIndices)
        ..free(_dwriteAdvances)
        ..free(_dwriteOffsets);
      _dwriteCapacity = 0;
      _dwriteIndices = nullptr;
      _dwriteAdvances = nullptr;
      _dwriteOffsets = nullptr;
    }
    if (_dwriteRun != nullptr) {
      _allocator.free(_dwriteRun);
      _dwriteRun = nullptr;
    }
    // The faces are process-wide and cached by `DWriteFontFaces.open`, so this
    // sink borrows them rather than owning them: disposing one target's sink
    // must not release the font faces another window is still drawing with.
    _dwriteFaces = null;
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
      ..free(_spriteColor)
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

    // The one branch in this method, and it is not a refusal any more. A
    // cached mask is a rectangle of pixels and can only be blitted; under a
    // matrix that rotates, skews, mirrors or scales the axes differently the
    // run is filled from its outlines instead. [glyphMasksFit] is the shared
    // criterion, so this backend takes the same route for the same run as the
    // CPU renderer and the GPU sink.
    if (!glyphMasksFit(transform)) {
      _drawGlyphRunAsOutlines(
        resource,
        deviceOrigin,
        transform,
        glyphIds,
        deviceOffsets,
        glyphCount,
        clip,
        paint,
      );
      return;
    }

    final ScaledTypeface font = _deviceFont(resource, transform);
    final int sizeKey = (font.pixelSize * kSizeQuantum).round();

    // The application's choice, asked once per run and only where it can be
    // honoured. False means "not this run" - an uninstalled font, a font whose
    // installed copy numbers its glyphs differently, no `dwrite.dll` - and the
    // portable route below draws it, which is why this is a fall-through and
    // not a refusal.
    if (RenderPolicyScope.policy.glyphRasterization ==
            GlyphRasterization.platformNative &&
        _drawGlyphRunNatively(resource, font, deviceOrigin, glyphIds,
            deviceOffsets, glyphCount, clip, argb)) {
      return;
    }

    _ensureClip(clip);
    // Both routes below require the aliased mode - the mask *is* the
    // antialiasing, baked in by the CPU rasteriser.
    _target.setAntialiasMode(d2d1AntialiasModeAliased);

    final D2dGlyphAtlas atlas = _ensureAtlas();
    _writeSpriteColor(argb);
    _reserveSprites(glyphCount);
    var pending = 0;

    for (var i = 0; i < glyphCount; i++) {
      final double penX = deviceOrigin.dx + deviceOffsets[i * 2];
      final double penY = deviceOrigin.dy + deviceOffsets[i * 2 + 1];
      final int bucket = glyphSubpixelBucket(penX);
      var (D2dGlyphAtlasResult outcome, D2dGlyphSlot? slot) =
          atlas.acquire(_glyphCache, font, sizeKey, glyphIds[i], bucket);

      if (outcome == D2dGlyphAtlasResult.full) {
        // Everything accumulated so far reads texels the reset is about to
        // hand to other glyphs, so it is issued and executed *before* the
        // packer forgets where they were.
        pending = _drawSprites(pending, argb);
        _target.flush();
        _atlasSampled = false;
        atlas.reset();
        (outcome, slot) = atlas.acquire(
            _glyphCache, font, sizeKey, glyphIds[i], bucket);
      }

      switch (outcome) {
        case D2dGlyphAtlasResult.blank:
          continue;
        case D2dGlyphAtlasResult.tooLarge:
          // Drawn here and not deferred, because deferring it would put this
          // glyph on top of letters that come after it in the run. Overlap is
          // rare and a reordering is not a rounding error.
          pending = _drawSprites(pending, argb);
          _drawGlyphFromOwnBitmap(font, sizeKey, glyphIds[i], bucket, penX,
              penY, argb);
          continue;
        case D2dGlyphAtlasResult.full:
          // The retry above ran against an empty atlas, and a glyph that does
          // not fit an empty atlas is reported as tooLarge, not as full.
          throw StateError('$backendName: the glyph atlas reported itself '
              'full immediately after being emptied, for glyph '
              '${glyphIds[i]} of $font');
        case D2dGlyphAtlasResult.placed:
          break;
      }

      final D2dGlyphSlot placed = slot!;
      final double left = (glyphPixelOrigin(penX) + placed.left).toDouble();
      final double top = (pixelEdge(penY) + placed.top).toDouble();
      (_spriteDestinations + pending).ref
        ..left = left
        ..top = top
        ..right = left + placed.width
        ..bottom = top + placed.height;
      (_spriteSources + pending).ref
        ..left = placed.x
        ..top = placed.y
        ..right = placed.x + placed.width
        ..bottom = placed.y + placed.height;
      pending++;
    }

    _drawSprites(pending, argb);
    _target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
  }

  /// Draws [glyphCount] glyphs through `ID2D1RenderTarget::DrawGlyphRun`, or
  /// returns false without drawing anything.
  ///
  /// ## What is delegated, and what is not
  ///
  /// Delegated: the coverage inside each glyph. Windows applies its own
  /// hinting and, where the target allows it, ClearType.
  ///
  /// Not delegated, and this is the whole design of the option: **the shaping,
  /// the metrics and the placement**. Every glyph is given
  /// `glyphAdvances[i] = 0` and a `DWRITE_GLYPH_OFFSET` carrying the offset
  /// this framework computed, so DirectWrite never advances a pen of its own
  /// and never has an opinion about where a letter goes. A run drawn this way
  /// occupies exactly the box the portable route would have occupied, so a
  /// widget is the same size, a line breaks in the same place and a hit test
  /// lands on the same character as on every other platform. Only the pixels
  /// differ.
  ///
  /// `DWRITE_MEASURING_MODE_NATURAL` for the same reason: the GDI-compatible
  /// modes re-grid-fit advances by DirectWrite's rules, which is the metric
  /// substitution this whole shape exists to avoid.
  ///
  /// The offset's `ascenderOffset` is *negated*: DirectWrite measures it up
  /// from the baseline and this framework's device space measures y down.
  ///
  /// ## Why false rather than an error
  ///
  /// Every reason this returns false is a property of the machine, not of the
  /// program: DirectWrite is absent, the font is not installed, or the
  /// installed copy of the font numbers its glyphs differently from the bytes
  /// the application loaded. None of those is something an application can fix
  /// at the call site, and refusing the frame over any of them would turn an
  /// appearance preference into a crash. The reason is recorded in
  /// [nativeTextRefusal] and the run is drawn the portable way.
  bool _drawGlyphRunNatively(
    ScaledTypeface interned,
    ScaledTypeface deviceFont,
    Offset deviceOrigin,
    Int32List glyphIds,
    Float32List deviceOffsets,
    int glyphCount,
    Rect clip,
    int argb,
  ) {
    if (glyphCount == 0) return true;
    final DWriteFontFaces? faces = _ensureDWrite();
    if (faces == null) return false;
    final DWriteFontFace? face = faces.faceFor(interned.typeface);
    if (face == null) {
      _nativeTextRefusal = faces.refusalFor(interned.typeface);
      return false;
    }

    _reserveGlyphRun(glyphCount);
    for (var i = 0; i < glyphCount; i++) {
      final int glyph = glyphIds[i];
      // A glyph id wider than 16 bits cannot be expressed in a
      // `DWRITE_GLYPH_RUN` at all. No OpenType font has one - the format's own
      // limit is 65 535 - so this is a corrupt-input guard, and it declines
      // the run rather than truncating it into a different letter.
      if (glyph < 0 || glyph > 0xFFFF) {
        _nativeTextRefusal = 'glyph id $glyph does not fit the 16 bits a '
            'DWRITE_GLYPH_RUN carries; the run was drawn the portable way';
        return false;
      }
      (_dwriteIndices + i).value = glyph;
      (_dwriteAdvances + i).value = 0;
      (_dwriteOffsets + i).ref
        ..advanceOffset = deviceOffsets[i * 2]
        ..ascenderOffset = -deviceOffsets[i * 2 + 1];
    }

    _dwriteRun.ref
      ..fontFace = face.pointer
      ..fontEmSize = deviceFont.pixelSize
      ..glyphCount = glyphCount
      ..glyphIndices = _dwriteIndices
      ..glyphAdvances = _dwriteAdvances
      ..glyphOffsets = _dwriteOffsets
      ..isSideways = 0
      ..bidiLevel = 0;

    _ensureClip(clip);
    // Per-primitive, not aliased: this route has no mask to carry the
    // antialiasing, and the aliased mode the atlas route needs would leave
    // Windows' own coverage nowhere to go.
    _target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
    // Default rather than ClearType by name. Direct2D already knows which of
    // the two this target can composite correctly - it drops to greyscale
    // wherever alpha is not ignored - and naming ClearType here would only
    // pretend to promise something the runtime decides.
    _target.setTextAntialiasMode(d2d1TextAntialiasModeDefault);
    _point.ref
      ..x = deviceOrigin.dx
      ..y = deviceOrigin.dy;
    _target.drawGlyphRun(_point.ref, _dwriteRun, _solidBrush(argb),
        dwriteMeasuringModeNatural);
    _nativeTextRunCount++;
    return true;
  }

  /// DirectWrite, opened at most once per sink.
  DWriteFontFaces? _ensureDWrite() {
    if (_dwriteResolved) return _dwriteFaces;
    _dwriteResolved = true;
    final DWriteLoad load = DWriteFontFaces.open(_allocator);
    if (!load.isLoaded) {
      _nativeTextRefusal = 'DirectWrite did not open: '
          '${load.diagnostics.map((BackendDiagnostic d) => d.message).join('; ')}';
      return null;
    }
    _dwriteFaces = load.faces;
    return _dwriteFaces;
  }

  /// Grows the glyph-run arrays to hold [count] glyphs.
  void _reserveGlyphRun(int count) {
    if (_dwriteRun == nullptr) {
      _dwriteRun =
          _allocator.allocate<DWriteGlyphRun>(sizeOf<DWriteGlyphRun>());
    }
    if (_dwriteCapacity >= count) return;
    if (_dwriteCapacity > 0) {
      _allocator
        ..free(_dwriteIndices)
        ..free(_dwriteAdvances)
        ..free(_dwriteOffsets);
    }
    _dwriteIndices = _allocator.allocate<Uint16>(sizeOf<Uint16>() * count);
    _dwriteAdvances = _allocator.allocate<Float>(sizeOf<Float>() * count);
    _dwriteOffsets = _allocator
        .allocate<DWriteGlyphOffset>(sizeOf<DWriteGlyphOffset>() * count);
    _dwriteCapacity = count;
  }

  /// The atlas, created on the first run that needs one.
  ///
  /// Lazy because it is four megabytes on each side of the API and a window
  /// that draws no text should not pay them.
  D2dGlyphAtlas _ensureAtlas() {
    final D2dGlyphAtlas? existing = _atlas;
    if (existing != null) return existing;
    final D2dGlyphAtlas created = D2dGlyphAtlas(
      target: _target,
      allocator: _allocator,
      backendName: backendName,
    );
    _atlas = created;
    return created;
  }

  /// Asks the runtime, once, whether this target is also an
  /// `ID2D1DeviceContext3` with a sprite batch on it.
  ///
  /// Null is a normal answer: a `d2d1.dll` that predates the sprite batch
  /// leaves [_batch] null and every run takes the `FillOpacityMask` loop, from
  /// the same atlas and over the same quads.
  void _resolveSpriteRoute() {
    if (_spriteRouteResolved) return;
    _spriteRouteResolved = true;
    if (!spriteBatching) return;
    final D2dDeviceContext3? context =
        _target.queryDeviceContext3(_allocator);
    if (context == null) return;
    final int hr = context.createSpriteBatch(_out);
    if (comFailed(hr) || _out.value == nullptr) {
      context.release();
      return;
    }
    _spriteContext = context;
    _batch = D2dSpriteBatch(_out.value);
  }

  /// Grows the sprite arrays to hold [count] entries.
  void _reserveSprites(int count) {
    if (_spriteCapacity >= count) return;
    if (_spriteCapacity > 0) {
      _allocator
        ..free(_spriteDestinations)
        ..free(_spriteSources);
    }
    // A run is usually short and the next one is usually the same length, so
    // the arrays are grown to what was asked for rather than doubled: this
    // reallocates once per new maximum and then never again.
    _spriteDestinations =
        _allocator.allocate<D2dRectF>(sizeOf<D2dRectF>() * count);
    _spriteSources = _allocator.allocate<D2dRectU>(sizeOf<D2dRectU>() * count);
    _spriteCapacity = count;
  }

  /// The paint colour as the straight-alpha tint a sprite multiplies by.
  ///
  /// The same arithmetic [_solidBrush] does, and it has to be: the two routes
  /// draw the same glyph and a colour that round-tripped differently would
  /// show as text of a slightly different weight depending on which one ran.
  void _writeSpriteColor(int argb) {
    _spriteColor.ref
      ..a = ((argb >> 24) & 0xFF) / 255.0
      ..r = ((argb >> 16) & 0xFF) / 255.0
      ..g = ((argb >> 8) & 0xFF) / 255.0
      ..b = (argb & 0xFF) / 255.0;
  }

  /// Issues the [pending] accumulated sprites and returns 0.
  ///
  /// Returns the new pending count so the caller can write
  /// `pending = _drawSprites(pending, argb)` and not have to remember to zero
  /// it - the mistake that would draw a run twice.
  ///
  /// ## The flush, and why it is conditional
  ///
  /// Direct2D holds drawing commands until `Flush` or `EndDraw`, and a held
  /// command reads the atlas as it is when the batch runs. So new texels may
  /// only be uploaded once anything already recorded that samples the atlas
  /// has been executed. [_atlasSampled] is exactly that question, and the
  /// flush is skipped when the answer is no - which is every frame after the
  /// first, where nothing new is admitted at all.
  int _drawSprites(int pending, int argb) {
    if (pending == 0) return 0;
    final D2dGlyphAtlas atlas = _atlas!;
    if (atlas.isDirty) {
      if (_atlasSampled) {
        _target.flush();
        _atlasSampled = false;
      }
      atlas.upload();
    }

    _resolveSpriteRoute();
    final D2dSpriteBatch? batch = _batch;
    if (batch != null) {
      final int hr = batch.addSprites(
        pending,
        _spriteDestinations,
        _spriteSources,
        _spriteColor,
        nullptr,
        destinationStride: sizeOf<D2dRectF>(),
        sourceStride: sizeOf<D2dRectU>(),
      );
      if (comFailed(hr)) {
        throw StateError('$backendName: AddSprites for $pending glyphs '
            'failed: ${d2dHresultText(hr)}');
      }
      _spriteContext!.drawSpriteBatch(
        batch.pointer,
        _batchOffset,
        pending,
        atlas.bitmap,
        d2d1BitmapInterpolationModeNearestNeighbor,
        // The quads are integral and 1:1 with the texels, so nothing should
        // reach past a slot; the clamp says so to the hardware as well.
        d2d1SpriteOptionsClampToSourceRectangle,
      );
      _batchOffset += pending;
    } else {
      final Pointer<Void> brush = _solidBrush(argb);
      for (var i = 0; i < pending; i++) {
        final Pointer<D2dRectF> destination = _spriteDestinations + i;
        final Pointer<D2dRectU> source = _spriteSources + i;
        _rect.ref
          ..left = destination.ref.left
          ..top = destination.ref.top
          ..right = destination.ref.right
          ..bottom = destination.ref.bottom;
        _sourceRect.ref
          ..left = source.ref.left.toDouble()
          ..top = source.ref.top.toDouble()
          ..right = source.ref.right.toDouble()
          ..bottom = source.ref.bottom.toDouble();
        _target.fillOpacityMask(atlas.bitmap, brush, _rect, _sourceRect);
      }
    }
    _atlasSampled = true;
    return 0;
  }

  /// Draws one glyph too large for the atlas, from a bitmap of its own.
  ///
  /// The route this file had for everything, kept for the case that still
  /// needs it. Display type is a handful of glyphs a frame, where a call each
  /// is not measurable - `d2d_text_cost_test.dart` puts eight glyphs at 96 px
  /// under the noise floor of the clock.
  void _drawGlyphFromOwnBitmap(
    ScaledTypeface font,
    int sizeKey,
    int glyphId,
    int bucket,
    double penX,
    double penY,
    int argb,
  ) {
    final _D2dGlyphBitmap? glyph =
        _glyphBitmap(font, sizeKey, glyphId, bucket);
    if (glyph == null) return;
    final double left = (glyphPixelOrigin(penX) + glyph.left).toDouble();
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
    _target.fillOpacityMask(glyph.bitmap, _solidBrush(argb), _rect,
        _sourceRect);
  }

  /// Draws a run by filling each glyph's outline under the full matrix.
  ///
  /// The general case: rotation, skew, mirroring, per-axis scale and any
  /// composition of them. Reached only when [glyphMasksFit] says a cached mask
  /// cannot stand in - which is to say, never in the upright, uniformly scaled
  /// case every interface is made of. See ADR 0007.
  ///
  /// ## Why the outline, and not a rotated bitmap
  ///
  /// `FillOpacityMask` can only place a mask axis-aligned, and even where a
  /// transform could be smuggled in around it, rotating a rasterised mask
  /// resamples an antialiased edge - the soft, smeared text bitmap glyph
  /// caches are known for, visibly worse at 45 degrees than at 0. Filling the
  /// outline instead puts text through the same `FillGeometry` as
  /// [drawDevicePath], so a rotated letter and a rotated path drawn beside it
  /// antialias identically because they are the same call.
  ///
  /// ## Where this differs from the CPU and GPU outline routes
  ///
  /// The *route* is chosen by the same function and the *matrix* is built by
  /// the same function, so the three backends always agree about which run
  /// takes which path and where each glyph lands. The coverage underneath is
  /// Direct2D's own analytic rasteriser rather than `ScanlineFiller`, so
  /// parity against the CPU here is a small declared tolerance on
  /// antialiased edges and not the deviation of 0 that CPU-versus-OpenGL
  /// measures - those two share one coverage implementation and this one does
  /// not. `test/backends/win32/d2d/d2d_glyph_transform_test.dart` states the
  /// measured number.
  ///
  /// ## Positioning, hinting and caching
  ///
  /// The pen is used exactly as it arrives, fraction and all: neither half of
  /// the fast path's snapping survives a rotation - "the whole pixel to the
  /// left" is no longer a direction the baseline runs in, and a *horizontal*
  /// subpixel bucket is not the axis the stems need. Analytic coverage places
  /// the glyph, as it does for every other shape.
  ///
  /// The outline is fetched **unhinted** - [Typeface.outlineOf] with no ppem,
  /// where the mask route passes the pixel size - because hinting grid-fits
  /// stems in the glyph's own axes and under a rotation those are not the
  /// screen's. The geometry is cached by [_geometryFor] under the outline's
  /// identity, and [Typeface] hands back one `Path` per glyph, so a run
  /// spinning through a whole turn builds each `ID2D1PathGeometry` once.
  void _drawGlyphRunAsOutlines(
    ScaledTypeface font,
    Offset deviceOrigin,
    Transform2D transform,
    Int32List glyphIds,
    Float32List deviceOffsets,
    int glyphCount,
    Rect clip,
    ReplayPaint paint,
  ) {
    // The *interned* face's scale, not a device-scaled one: the matrix below
    // carries the device scale in its linear part, and folding it into the
    // font as well would apply it twice.
    final double fontScale = font.scale;
    final Typeface face = font.typeface;

    // Clip first, under the identity transform, so the axis-aligned device
    // rectangle means what the player computed - the same order
    // [drawDevicePath] states.
    _ensureClip(clip);
    final Pointer<Void> brush = _solidBrush(paint.argbColor);
    for (var i = 0; i < glyphCount; i++) {
      final Path outline = face.outlineOf(glyphIds[i]);
      if (outline.isEmpty) continue;
      // Non-zero winding, and not a default taken for convenience: TrueType
      // and CFF both define a filled glyph by the non-zero winding of its
      // contours - it is how the counter of an `o` comes out empty - and
      // even-odd would fill the overlap wherever two contours of a composite
      // glyph cross.
      final Pointer<Void> geometry =
          _geometryFor(outline, d2d1FillModeWinding);
      _setTransform(
        glyphOutlineTransform(
          transform,
          fontScale,
          deviceOrigin.dx + deviceOffsets[i * 2],
          deviceOrigin.dy + deviceOffsets[i * 2 + 1],
        ),
      );
      _target.fillGeometry(geometry, brush);
    }
    _setIdentityTransform();
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
    // Over the limit the cache is emptied - but *after* the frame, never in
    // the middle of one. Direct2D batches commands, so a geometry handed to
    // `FillGeometry` has to outlive the batch and not just the call, exactly
    // the reason `_frameBitmaps` exists. One rotated paragraph is enough to
    // cross the limit inside a single frame, so releasing here would free
    // geometry the driver had not read yet.
    if (_geometryCache.length >= kD2dGeometryCacheLimit) {
      _geometryEvictionPending = true;
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

  /// [font] at the size the device transform asks for - the same rule as the
  /// CPU sink's `_deviceFont`, so the two backends size a run identically.
  ///
  /// Only ever called for a matrix [glyphMasksFit] has accepted, so the two
  /// diagonal terms are equal and positive and there is one scale to take.
  /// The assert says so rather than trusting the caller, because the failure
  /// it guards is silent: `transform.a` alone under a non-uniform scale would
  /// produce upright text at the wrong height.
  ScaledTypeface _deviceFont(ScaledTypeface font, Transform2D transform) {
    assert(
      glyphMasksFit(transform),
      'a cached mask cannot serve $transform; the outline route handles it',
    );
    final double a = transform.a;
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
