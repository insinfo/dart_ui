/// The two Direct2D drawing surfaces: a window target and an offscreen
/// readback surface.
///
/// ## Why an HWND render target and not Direct2D-over-DXGI
///
/// Direct2D 1.1 can share a Direct3D 11 swapchain, and the roadmap names that
/// as the eventual production shape. It is not the first shape, on purpose:
/// an `ID2D1HwndRenderTarget` is self-contained - the driver owns the device,
/// the swap, the resize and the occlusion handling - so the whole replay
/// pipeline can be proven against real pixels without coupling this backend's
/// bring-up to the Direct3D 11 device work happening in parallel. The sink
/// draws through `ID2D1RenderTarget`, which is exactly the interface a
/// DXGI-surface target also implements, so moving up to the shared swapchain
/// later changes this file and not the replayer.
///
/// ## The offscreen surface reads back through GDI, not WIC
///
/// A DC render target bound to a top-down 32-bit DIB section is the one
/// Direct2D target whose pixels the CPU can read with no second COM
/// apartment, no WIC factory and no Direct3D staging texture: after `EndDraw`
/// and `GdiFlush` the DIB's memory simply *is* the image. That is the whole
/// test story - draw, flush, compare bytes - and it is also an honest
/// headless fallback.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../../rendering/framebuffer.dart';
import '../../../rendering/renderer.dart';
import '../../../rendering/replay/display_list_player.dart';
import '../d3d12/d3d12_com.dart';
import 'd2d1_interfaces.dart';
import 'd2d1_library.dart';
import 'd2d1_structs.dart';
import 'd2d_raster_sink.dart';

/// A Win32 window a Direct2D device can present into.
///
/// The same shape as `D3d11WindowSurfaceDescriptor` and for the same reasons,
/// stated there at length: the handle is an opaque integer because the
/// layering test forbids `HWND` outside `backends/`, and the *window's*
/// generation token travels with the descriptor so a frame recorded before a
/// resize is rejected instead of stretched.
final class Win32D2dSurfaceDescriptor implements NativeSurfaceDescriptor {
  Win32D2dSurfaceDescriptor({
    required this.windowHandle,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.generation,
    this.scale = 1.0,
    this.description = 'window',
  })  : assert(pixelWidth > 0 && pixelHeight > 0),
        assert(scale > 0);

  /// Diagnostics only; `D2dRenderDevice.createTarget` type-tests instead.
  @override
  String get kind => 'd2d-hwnd-window';

  /// The window, as whatever integer the platform calls one.
  final int windowHandle;

  /// Physical pixels, already multiplied by [scale] by whoever built this.
  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  /// The *window's* lifetime counter. Shared, not copied.
  final GenerationToken generation;

  /// Free text for probe and bug reports. Never parsed.
  final String description;

  @override
  String toString() => 'Win32D2dSurfaceDescriptor(0x'
      '${windowHandle.toUnsigned(64).toRadixString(16)}, '
      '${pixelWidth}x$pixelHeight @${scale}x, $description)';
}

/// Fills the render-target properties every target in this file shares.
///
/// 96 DPI always - see `D2dRenderTargetProperties.dpiX` for why that is a
/// correctness rule and not a default.
void _describeTarget(
  Pointer<D2dRenderTargetProperties> properties, {
  required int alphaMode,
}) {
  properties.ref
    ..type = d2d1RenderTargetTypeDefault
    ..dpiX = 96
    ..dpiY = 96
    ..usage = d2d1RenderTargetUsageNone
    ..minLevel = d2d1FeatureLevelDefault;
  properties.ref.pixelFormat
    ..format = dxgiFormatB8G8R8A8Unorm
    ..alphaMode = alphaMode;
}

/// Unpacks the frame request's premultiplied BGRA word into a straight-alpha
/// Direct2D colour. Direct2D's `Clear` takes straight alpha; the division is
/// the honest inverse of the premultiplication, with alpha 0 collapsing to
/// transparent black - the only colour alpha 0 can mean.
void _writeClearColor(Pointer<D2dColorF> color, int premultipliedBgra) {
  final int a = (premultipliedBgra >> 24) & 0xFF;
  final int r = (premultipliedBgra >> 16) & 0xFF;
  final int g = (premultipliedBgra >> 8) & 0xFF;
  final int b = premultipliedBgra & 0xFF;
  if (a == 0) {
    color.ref
      ..r = 0
      ..g = 0
      ..b = 0
      ..a = 0;
    return;
  }
  color.ref
    ..r = r / a
    ..g = g / a
    ..b = b / a
    ..a = a / 255.0;
}

/// The result of running one display list through a [D2dRasterSink].
typedef _ReplayEnd = ({int endDrawResult, Object? error, StackTrace? trace});

/// Replays [list] between `BeginDraw` and `EndDraw`, keeping the target's
/// begin/end state balanced even when the player throws.
///
/// The player's errors are not caught *as policy* - a frame that cannot be
/// interpreted must not be half-drawn - but `EndDraw` must still run or the
/// target is wedged in the drawing state and every later frame fails with
/// `D2DERR_WRONG_STATE`. So the error is carried out and rethrown after the
/// state is settled.
_ReplayEnd _replay({
  required D2dRenderTarget target,
  required D2dRasterSink sink,
  required DisplayListPlayer player,
  required DisplayList list,
  required Rect deviceBounds,
  required Transform2D deviceTransform,
  required int? clearColor,
  required Pointer<D2dColorF> colorScratch,
}) {
  target.beginDraw();
  if (clearColor != null) {
    _writeClearColor(colorScratch, clearColor);
    target.clear(colorScratch);
  }
  Object? error;
  StackTrace? trace;
  final DisplayListResources resources = DisplayListResources(list);
  sink.beginFrame(resources);
  try {
    player.play(
      DisplayListReader(list),
      resources,
      deviceBounds: deviceBounds,
      deviceTransform: deviceTransform,
    );
  } on Object catch (thrown, thrownTrace) {
    error = thrown;
    trace = thrownTrace;
  } finally {
    sink.endFrame();
  }
  final int hr = target.endDraw();
  sink.releaseFrameData();
  return (endDrawResult: hr, error: error, trace: trace);
}

/// A Direct2D target presenting into a Win32 window.
final class D2dHwndWindowTarget
    with DisposableMixin
    implements DisplayListRenderTarget {
  D2dHwndWindowTarget({
    required D2dFactory factory,
    required D2d1Library library,
    required Win32D2dSurfaceDescriptor surface,
    required String backendName,
    void Function()? onDeviceLost,
  })  : _library = library,
        _surface = surface,
        _backendName = backendName,
        _onDeviceLost = onDeviceLost {
    final Allocator alloc = library.allocator;
    _color = alloc.allocate<D2dColorF>(sizeOf<D2dColorF>());
    _sizeScratch = alloc.allocate<D2dSizeU>(sizeOf<D2dSizeU>());

    final Pointer<D2dRenderTargetProperties> targetProperties = alloc
        .allocate<D2dRenderTargetProperties>(
            sizeOf<D2dRenderTargetProperties>());
    // The window is opaque; premultiplied alpha would buy nothing and some
    // drivers refuse it on an HWND target.
    _describeTarget(targetProperties, alphaMode: d2d1AlphaModeIgnore);

    final Pointer<D2dHwndRenderTargetProperties> hwndProperties = alloc
        .allocate<D2dHwndRenderTargetProperties>(
            sizeOf<D2dHwndRenderTargetProperties>());
    hwndProperties.ref
      ..hwnd = Pointer<Void>.fromAddress(surface.windowHandle)
      ..presentOptions = d2d1PresentOptionsNone;
    hwndProperties.ref.pixelSize
      ..width = surface.pixelWidth
      ..height = surface.pixelHeight;

    final Pointer<Pointer<Void>> out =
        alloc.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    final int hr =
        factory.createHwndRenderTarget(targetProperties, hwndProperties, out);
    final Pointer<Void> raw = out.value;
    alloc
      ..free(targetProperties)
      ..free(hwndProperties)
      ..free(out);
    if (comFailed(hr) || raw == nullptr) {
      alloc
        ..free(_color)
        ..free(_sizeScratch);
      throw StateError('$backendName: CreateHwndRenderTarget over '
          '$surface failed: ${d2dHresultText(hr)}');
    }
    _hwndTarget = D2dHwndRenderTarget(raw);
    _sink = D2dRasterSink(
      target: _hwndTarget.target,
      factory: factory,
      allocator: alloc,
      backendName: backendName,
    );
    _player = DisplayListPlayer(_sink);
    _windowGeneration = surface.generation.current;
  }

  final D2d1Library _library;
  final String _backendName;
  final void Function()? _onDeviceLost;

  Win32D2dSurfaceDescriptor _surface;
  late final D2dHwndRenderTarget _hwndTarget;
  late final D2dRasterSink _sink;
  late final DisplayListPlayer _player;
  late final Pointer<D2dColorF> _color;
  late final Pointer<D2dSizeU> _sizeScratch;

  int _generation = 0;
  int _windowGeneration = 0;
  bool _frameOpen = false;
  Rect _frameDamage = Rect.zero;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  @override
  int get generation => _generation;

  @override
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) {
    throwIfDisposed();
    if (_surface.generation.current != _windowGeneration) {
      return Future<PresentResult>.value(PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'the window resized after this frame was scheduled',
          detail: 'window generation ${_surface.generation.current}, '
              'target saw $_windowGeneration; resize() reconciles',
        ),
      ));
    }
    final _ReplayEnd end = _replay(
      target: _hwndTarget.target,
      sink: _sink,
      player: _player,
      list: list,
      deviceBounds: Rect.fromLTRB(
        0,
        0,
        _surface.pixelWidth.toDouble(),
        _surface.pixelHeight.toDouble(),
      ),
      deviceTransform: deviceTransform,
      clearColor: clearColor,
      colorScratch: _color,
    );
    if (end.error != null) {
      return Future<PresentResult>.error(end.error!, end.trace);
    }
    return Future<PresentResult>.value(_mapEndDraw(end.endDrawResult));
  }

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    if (_frameOpen) {
      throw StateError('$_backendName: beginFrame while a frame is open');
    }
    _frameOpen = true;
    _frameDamage = request.damage ??
        Rect.fromLTRB(0, 0, _surface.pixelWidth.toDouble(),
            _surface.pixelHeight.toDouble());
    _hwndTarget.target.beginDraw();
    final int? clearColor = request.clearColor;
    if (clearColor != null) {
      _writeClearColor(_color, clearColor);
      _hwndTarget.target.clear(_color);
    }
    // No CPU pixels: the point of this target is that its pixels never leave
    // the GPU. Frame.cpuPixels documents the shape.
    return Frame(
      target: this,
      damage: _frameDamage,
      generation: _generation,
    );
  }

  @override
  Future<PresentResult> present(Frame frame) {
    throwIfDisposed();
    if (!_frameOpen) {
      throw StateError('$_backendName: present without beginFrame');
    }
    _frameOpen = false;
    final int hr = _hwndTarget.target.endDraw();
    if (frame.generation != _generation) {
      return Future<PresentResult>.value(const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'the frame belonged to a previous target generation',
        ),
      ));
    }
    return Future<PresentResult>.value(_mapEndDraw(hr));
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth <= 0 || pixelHeight <= 0) return;
    _sizeScratch.ref
      ..width = pixelWidth
      ..height = pixelHeight;
    final int hr = _hwndTarget.resize(_sizeScratch);
    _generation++;
    _windowGeneration = _surface.generation.current;
    _surface = Win32D2dSurfaceDescriptor(
      windowHandle: _surface.windowHandle,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      generation: _surface.generation,
      scale: scale,
      description: _surface.description,
    );
    if (hr == d2dErrRecreateTarget) {
      _onDeviceLost?.call();
    } else if (comFailed(hr)) {
      throw StateError('$_backendName: ID2D1HwndRenderTarget::Resize to '
          '${pixelWidth}x$pixelHeight failed: ${d2dHresultText(hr)}');
    }
  }

  PresentResult _mapEndDraw(int hr) {
    if (hr == d2dErrRecreateTarget) {
      _onDeviceLost?.call();
      return PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'Direct2D asked for the target to be recreated',
          detail: d2dHresultText(hr),
        ),
      );
    }
    if (comFailed(hr)) {
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'EndDraw failed',
          detail: d2dHresultText(hr),
        ),
      );
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  @override
  void onDispose() {
    _generation++;
    _sink.dispose();
    _hwndTarget.release();
    _library.allocator
      ..free(_color)
      ..free(_sizeScratch);
  }
}

/// An offscreen Direct2D surface whose pixels the CPU can read back.
///
/// A DC render target bound to a top-down BGRA DIB section; see the library
/// comment for why this is the readback path. Owns everything it creates and
/// is independent of any window.
final class D2dOffscreenSurface with DisposableMixin {
  D2dOffscreenSurface({
    required D2dFactory factory,
    required D2d1Library library,
    required this.width,
    required this.height,
    String backendName = 'direct2d',
  })  : _library = library,
        _backendName = backendName,
        assert(width > 0 && height > 0) {
    final Allocator alloc = library.allocator;
    _color = alloc.allocate<D2dColorF>(sizeOf<D2dColorF>());

    // The DIB: 32-bit, top-down (negative height), BI_RGB.
    final Pointer<Win32BitmapInfoHeader> info = alloc
        .allocate<Win32BitmapInfoHeader>(sizeOf<Win32BitmapInfoHeader>());
    info.ref
      ..biSize = sizeOf<Win32BitmapInfoHeader>()
      ..biWidth = width
      ..biHeight = -height
      ..biPlanes = 1
      ..biBitCount = 32
      ..biCompression = biRgb;
    final Pointer<Pointer<Void>> bits =
        alloc.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    _memoryDc = library.createCompatibleDc(nullptr);
    if (_memoryDc == nullptr) {
      alloc
        ..free(info)
        ..free(bits)
        ..free(_color);
      throw StateError('$backendName: CreateCompatibleDC failed');
    }
    _dibSection =
        library.createDibSection(_memoryDc, info, dibRgbColors, bits, nullptr, 0);
    _dibBits = bits.value;
    alloc
      ..free(info)
      ..free(bits);
    if (_dibSection == nullptr || _dibBits == nullptr) {
      library.deleteDc(_memoryDc);
      alloc.free(_color);
      throw StateError(
          '$backendName: CreateDIBSection ${width}x$height failed');
    }
    _previousBitmap = library.selectObject(_memoryDc, _dibSection);

    final Pointer<D2dRenderTargetProperties> targetProperties = alloc
        .allocate<D2dRenderTargetProperties>(
            sizeOf<D2dRenderTargetProperties>());
    _describeTarget(targetProperties, alphaMode: d2d1AlphaModePremultiplied);
    final Pointer<Pointer<Void>> out =
        alloc.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    int hr = factory.createDcRenderTarget(targetProperties, out);
    final Pointer<Void> raw = out.value;
    alloc
      ..free(targetProperties)
      ..free(out);
    if (comFailed(hr) || raw == nullptr) {
      _releaseGdi();
      alloc.free(_color);
      throw StateError(
          '$backendName: CreateDCRenderTarget failed: ${d2dHresultText(hr)}');
    }
    _dcTarget = D2dDcRenderTarget(raw);

    final Pointer<Win32NativeRect> bindRect =
        alloc.allocate<Win32NativeRect>(sizeOf<Win32NativeRect>());
    bindRect.ref
      ..left = 0
      ..top = 0
      ..right = width
      ..bottom = height;
    hr = _dcTarget.bindDc(_memoryDc, bindRect);
    alloc.free(bindRect);
    if (comFailed(hr)) {
      _dcTarget.release();
      _releaseGdi();
      alloc.free(_color);
      throw StateError(
          '$backendName: BindDC failed: ${d2dHresultText(hr)}');
    }

    _sink = D2dRasterSink(
      target: _dcTarget.target,
      factory: factory,
      allocator: alloc,
      backendName: backendName,
    );
    _player = DisplayListPlayer(_sink);
  }

  final D2d1Library _library;
  final String _backendName;
  final int width;
  final int height;

  late final Pointer<Void> _memoryDc;
  late final Pointer<Void> _dibSection;
  late final Pointer<Void> _dibBits;
  late final Pointer<Void> _previousBitmap;
  late final D2dDcRenderTarget _dcTarget;
  late final D2dRasterSink _sink;
  late final DisplayListPlayer _player;
  late final Pointer<D2dColorF> _color;

  /// The shared drawing surface, for tests that call Direct2D directly - the
  /// gradient bindings are exercised through this.
  D2dRenderTarget get renderTarget => _dcTarget.target;

  /// The sink, for tests that drive it without a display list.
  D2dRasterSink get sink => _sink;

  /// Replays [list] and leaves the result in the DIB.
  ///
  /// Throws whatever the player throws - a frame that cannot be interpreted
  /// must not be half-drawn - after settling Direct2D's begin/end state.
  PresentResult renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) {
    throwIfDisposed();
    final _ReplayEnd end = _replay(
      target: _dcTarget.target,
      sink: _sink,
      player: _player,
      list: list,
      deviceBounds:
          Rect.fromLTRB(0, 0, width.toDouble(), height.toDouble()),
      deviceTransform: deviceTransform,
      clearColor: clearColor,
      colorScratch: _color,
    );
    _library.gdiFlush();
    if (end.error != null) {
      Error.throwWithStackTrace(end.error!, end.trace ?? StackTrace.current);
    }
    final int hr = end.endDrawResult;
    if (comFailed(hr)) {
      return PresentResult(
        status: hr == d2dErrRecreateTarget
            ? PresentStatus.deviceLost
            : PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: '$_backendName: EndDraw on the offscreen surface failed',
          detail: d2dHresultText(hr),
        ),
      );
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Opens a frame for callers that draw through [renderTarget] or [sink]
  /// directly instead of replaying a display list - the seam the
  /// gradient-binding tests use.
  void beginDirectDraw() {
    throwIfDisposed();
    _dcTarget.target.beginDraw();
  }

  /// Closes a [beginDirectDraw] frame and flushes GDI so [readback] sees the
  /// result. Returns the raw `EndDraw` HRESULT.
  int endDirectDraw() {
    throwIfDisposed();
    final int hr = _dcTarget.target.endDraw();
    _library.gdiFlush();
    return hr;
  }

  /// Copies the DIB into a caller-owned framebuffer.
  ///
  /// A copy rather than a wrap, so the returned pixels survive the next
  /// frame and the surface's own disposal - the shape a golden comparison
  /// wants.
  Framebuffer readback() {
    throwIfDisposed();
    final Framebuffer out = Framebuffer.allocate(width: width, height: height);
    final Uint8List source =
        _dibBits.cast<Uint8>().asTypedList(width * height * 4);
    out.pixels.setAll(0, source);
    return out;
  }

  void _releaseGdi() {
    _library.selectObject(_memoryDc, _previousBitmap);
    _library.deleteObject(_dibSection);
    _library.deleteDc(_memoryDc);
  }

  @override
  void onDispose() {
    _sink.dispose();
    _dcTarget.release();
    _releaseGdi();
    _library.allocator.free(_color);
  }
}
