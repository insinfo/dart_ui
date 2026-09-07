/// Metal presenting to a window, by way of a shared `IOSurface`.
///
/// This is ADR 0005's `MetalSurfacePresenter`, and it is the file whose
/// absence §21.6 of the roadmap recorded as *"clear/present — não há
/// apresentação nenhuma"*. `d3d11_window_target.dart` is its nearest relative
/// and most of its reasoning carries over unchanged; what is written down here
/// is only what macOS does differently, because those are the places a port
/// from Direct3D goes silently wrong.
///
/// ## The three differences from every other window target in this repository
///
///   1. **There is no swap chain and no drawable.** The buffers belong to
///      `surface_pool.dart` and the thing that shows them is a *different
///      process* - ADR 0001 put the `NSWindow` there. So presenting is not a
///      driver call; it is a line on a pipe (`PRESENT_SLOT`), and this target
///      reaches it through [MetalPresentSurface] rather than naming any of it.
///
///   2. **`commit` is not the end of the frame.** On a swap chain, `Present`
///      is ordered after the draws by the driver. Here the draws land in an
///      `IOSurface` that another process may read the instant it is told to,
///      so the present has to wait for the GPU to have actually finished.
///      `waitUntilCompleted` would do it and would serialise the CPU against
///      the GPU every frame, destroying the parallelism Metal was adopted for.
///      So this target installs `addCompletedHandler:` and presents from
///      there, which is ADR 0005's choice and costs one isolate round trip -
///      measured at 6.7 ms end to end on the paravirtual CI GPU in run
///      [`34165428755`](https://github.com/insinfo/dart_ui/actions/runs/34165428755).
///
///   3. **The attachment is `BGRA8Unorm`, not `RGBA8Unorm`.** An `IOSurface`
///      from this repository's pool carries the FourCC `'BGRA'`, and in Metal
///      a pipeline state's attachment format is part of its *identity*: a
///      state built for one is rejected at encode time by a pass using the
///      other, and Metal raises rather than converting. That is why this
///      target is handed its own [MetalPipelineCache] instead of borrowing the
///      device's, which is built for `rgba8Unorm` and serves the offscreen
///      path.
///
/// ## Why the textures are cached per slot and rebuilt on resize
///
/// Wrapping an `IOSurface` costs a `newTextureWithDescriptor:iosurface:plane:`
/// and a retain; doing it per frame would be pointless churn on a pointer that
/// does not change. What *does* change is the pool: a resize allocates new
/// surfaces at the new pixel size, and a texture wrapping a freed surface is
/// the sharpest edge in this file. [resize] therefore releases every cached
/// texture before anything else, and the generation moves first so a frame
/// begun against the old size is already stale by the time it is presented.
library;

import 'dart:async';
import 'dart:ffi';

import '../../../ffi/objc_runtime.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../renderer.dart';
import 'metal_bindings.dart';
import 'metal_device.dart';
import 'metal_offscreen.dart';
import 'metal_surface_descriptor.dart';

/// How long a frame waits for the GPU before giving up on it.
///
/// Not a frame budget: it is the point at which "the GPU is busy" stops being
/// a credible explanation and a hung present becomes a reported failure
/// instead of a future nobody completes. The measured handler latency on the
/// slowest device this has run on is 6.7 ms, so two seconds is three orders of
/// magnitude of headroom and still finite.
const Duration kMetalPresentTimeout = Duration(seconds: 2);

/// A window a Metal device presents into, through a shared `IOSurface`.
final class MetalWindowTarget
    with DisposableMixin
    implements DisplayListRenderTarget {
  /// Wraps [surface] for [gpu].
  ///
  /// Takes ownership of **nothing**. The `MTLDevice` and the pipeline cache
  /// belong to the device that built this target and outlive it; the surfaces
  /// belong to the window's pool and outlive it too. What this object owns is
  /// the textures it wrapped and the block it installed, and [onDispose]
  /// releases exactly those.
  ///
  /// [pipelines] must have been built for [MtlPixelFormat.bgra8Unorm]. Passing
  /// the device's `rgba8Unorm` cache compiles and then fails at encode time on
  /// every frame with a pipeline/attachment mismatch, which is three steps
  /// away from the mistake - hence the check in the body rather than a comment
  /// asking the caller to be careful.
  MetalWindowTarget({
    required MetalGpu gpu,
    required MetalPipelineCache pipelines,
    required MetalPresentSurface surface,
  })  : _gpu = gpu,
        _pipelines = pipelines,
        _surface = surface,
        _descriptor = surface {
    if (pipelines.pixelFormat != MtlPixelFormat.bgra8Unorm) {
      throw MetalError(
        'MetalWindowTarget was given a pipeline cache built for pixel format '
        '${pipelines.pixelFormat}, and an IOSurface from surface_pool.dart is '
        'MTLPixelFormatBGRA8Unorm (${MtlPixelFormat.bgra8Unorm}). A pipeline '
        "state's attachment format is part of its identity in Metal, so every "
        'draw would be rejected at encode time',
      );
    }
  }

  final MetalGpu _gpu;
  final MetalPipelineCache _pipelines;
  final MetalPresentSurface _surface;

  NativeSurfaceDescriptor _descriptor;

  /// One borrowed-texture target per slot, built on first use.
  final Map<int, MetalOffscreenTarget> _slots = <int, MetalOffscreenTarget>{};

  /// The `MTLTexture` wrapping each slot's `IOSurface`, **+1** each.
  final Map<int, Pointer<ObjCObject>> _textures = <int, Pointer<ObjCObject>>{};

  int _generation = 0;
  int? _pendingClear;
  int? _frameSlot;

  /// Completed by the Metal completion handler, on Metal's own thread.
  ///
  /// One field rather than one per frame because only one frame is ever in
  /// flight per target: [present] awaits this before it returns, and
  /// [beginFrame] cannot run again until it has. A second concurrent frame
  /// would silently overwrite this and hang the first, which is why
  /// [beginFrame] refuses one by name.
  Completer<void>? _frameDone;

  /// Frames that timed out and whose handler has still not been seen.
  ///
  /// Without this, a frame that timed out and then completed late would
  /// complete the **next** frame's future, and that frame would present a
  /// surface the GPU was still writing - the exact tearing this target waits
  /// to avoid, made intermittent and blamed on the wrong frame.
  ///
  /// Counting works because Metal runs one command queue here and calls
  /// completion handlers in submission order, so the first handler to arrive
  /// after a timeout is the timed-out frame's.
  int _abandonedFrames = 0;

  NativeCallable<Void Function(Pointer<Void>, Pointer<ObjCObject>)>? _callable;
  ObjCBlock? _completedHandler;

  @override
  NativeSurfaceDescriptor get surface => _descriptor;

  @override
  int get generation => _generation;

  /// The completion block, built once and reused for every frame.
  ///
  /// Reused rather than rebuilt because the block is marked
  /// `BLOCK_IS_GLOBAL`: nothing copies it, this object owns its lifetime
  /// outright, and allocating one per frame would be a native allocation on
  /// the hot path for no benefit. The `NativeCallable` **must** be a listener
  /// - Metal invokes a completion handler on a thread it owns, and an
  /// `isolateLocal` callable reached from a foreign thread is undefined
  /// behaviour.
  Pointer<ObjCObject> get _handler {
    final ObjCBlock? existing = _completedHandler;
    if (existing != null) return existing.pointer;
    final NativeCallable<Void Function(Pointer<Void>, Pointer<ObjCObject>)>
        callable = NativeCallable<
            Void Function(
                Pointer<Void>, Pointer<ObjCObject>)>.listener(_onGpuFinished);
    _callable = callable;
    final ObjCBlock block = ObjCBlock(callable.nativeFunction);
    _completedHandler = block;
    return block.pointer;
  }

  /// Runs when the GPU has finished writing the surface.
  ///
  /// Delivered on the isolate by `NativeCallable.listener`, not on Metal's
  /// thread, which is what makes touching a Dart field here legal at all.
  void _onGpuFinished(Pointer<Void> block, Pointer<ObjCObject> commandBuffer) {
    if (_abandonedFrames > 0) {
      _abandonedFrames--;
      return;
    }
    final Completer<void>? done = _frameDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    if (_frameDone != null && !_frameDone!.isCompleted) {
      throw StateError(
        'a frame is already in flight on this MetalWindowTarget: present() '
        'must be awaited before the next beginFrame(). Two concurrent frames '
        'would share one completion handler and the first would never finish',
      );
    }
    final int slot = _surface.backSlot;
    _frameSlot = slot;
    _pendingClear = request.clearColor;
    _targetForSlot(slot).beginFrame();
    return Frame(
      target: this,
      // Null, and deliberately: these pixels live in an IOSurface the host
      // scans out and are never read back per frame. `Frame.cpuPixels`
      // documents why a 1x1 placeholder here would be a lie in the type.
      framebuffer: null,
      damage: request.damage ??
          Rect.fromLTWH(
            0,
            0,
            _descriptor.pixelWidth.toDouble(),
            _descriptor.pixelHeight.toDouble(),
          ),
      generation: _generation,
    );
  }

  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    if (frame.generation != _generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame belonged to a previous generation of the target',
        ),
      );
    }
    if (!_surface.isPresentable) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'the macOS window is no longer presentable',
          detail: 'the host died and recovery has not finished, or the window '
              'was destroyed. The IOSurfaces are intact - they belong to this '
              'process - so the next frame after recovery will land',
        ),
      );
    }
    final int? slot = _frameSlot;
    final MetalOffscreenTarget? target = slot == null ? null : _slots[slot];
    if (target == null) {
      return const PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'present without a matching beginFrame',
        ),
      );
    }

    final Completer<void> done = Completer<void>();
    _frameDone = done;
    try {
      target.submit(clearColor: _pendingClear, completedHandler: _handler);
    } on MetalError catch (error) {
      _frameDone = null;
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the Metal command buffer could not be encoded',
          detail: '$error',
        ),
      );
    }

    // The wait ADR 0005 is about. Not `waitUntilCompleted` - that blocks the
    // isolate on the GPU - but the completion handler coming back round the
    // event loop, which leaves the CPU free to do the rest of the frame.
    bool timedOut = false;
    await done.future.timeout(
      kMetalPresentTimeout,
      onTimeout: () => timedOut = true,
    );
    _frameDone = null;
    if (timedOut) {
      // The GPU may still finish this frame later. Its handler must not be
      // mistaken for the next frame's; see [_abandonedFrames].
      _abandonedFrames++;
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the Metal completion handler did not fire',
          detail: 'waited ${kMetalPresentTimeout.inMilliseconds} ms for the '
              'GPU to finish writing the IOSurface. The frame was NOT '
              'presented, because presenting a surface the GPU may still be '
              'writing shows tearing inside a single frame',
        ),
      );
    }

    // Only now. Between `commit` and here the surface was still being written.
    return _surface.presentBackBuffer(generation: _generation);
  }

  @override
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    final MetalOffscreenTarget? target = _slots[_frameSlot];
    if (target == null) {
      return const PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'no slot target after beginFrame',
        ),
      );
    }
    target.playDisplayList(list, deviceTransform: deviceTransform);
    return present(frame);
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth == _descriptor.pixelWidth &&
        pixelHeight == _descriptor.pixelHeight &&
        scale == _descriptor.scale) {
      return;
    }
    // The generation moves first, so a frame begun against the old size is
    // already stale before a single texture is released.
    _generation++;
    _releaseSlots();
    _descriptor = _ResizedSurface(
      original: _descriptor,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
    );
  }

  /// The borrowed-texture target for [slot], wrapping its `IOSurface`.
  MetalOffscreenTarget _targetForSlot(int slot) {
    final MetalOffscreenTarget? cached = _slots[slot];
    if (cached != null) return cached;

    final Pointer<Void> surfaceRef = _surface.surfaceRefForSlot(slot);
    if (surfaceRef == nullptr) {
      throw UnsupportedCapabilityError(
        backendName: 'metal',
        capability: Capability.gpuPresentation,
        detail: 'slot $slot of this window is not backed by an IOSurface, so '
            'newTextureWithDescriptor:iosurface:plane: has nothing to wrap. '
            'That is what a test double reports; a real MacosSurfacePool '
            'always has one',
      );
    }
    final Pointer<ObjCObject> texture = _wrapSurface(surfaceRef);
    if (texture == nullptr) {
      throw MetalError(
        'newTextureWithDescriptor:iosurface:plane: returned nil for slot '
        '$slot at ${_descriptor.pixelWidth}x${_descriptor.pixelHeight}',
        detail: 'the usual causes are a pixel format that does not match the '
            "surface's FourCC - it must be BGRA - and a storage mode the "
            'device refuses for an IOSurface-backed texture. Run 34165428755 '
            'measured MTLStorageModeShared working on Apple Silicon; a Mac '
            'with discrete memory may need managed',
      );
    }
    _textures[slot] = texture;
    final MetalOffscreenTarget target = MetalOffscreenTarget.overTexture(
      _gpu,
      _pipelines,
      texture: texture,
      width: _descriptor.pixelWidth,
      height: _descriptor.pixelHeight,
    );
    _slots[slot] = target;
    return target;
  }

  Pointer<ObjCObject> _wrapSurface(Pointer<Void> surfaceRef) =>
      ObjCAutoreleasePool.run(() {
        final Pointer<ObjCObject> cls = objcClass('MTLTextureDescriptor');
        if (cls == nullptr) {
          throw MetalError('the MTLTextureDescriptor class is not loaded');
        }
        final Pointer<ObjCObject> descriptor = metalSendPointer4(
          cls,
          'texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
          MtlPixelFormat.bgra8Unorm,
          _descriptor.pixelWidth,
          _descriptor.pixelHeight,
          0,
        );
        if (descriptor == nullptr) {
          throw MetalError('texture2DDescriptorWithPixelFormat:... nil');
        }
        // renderTarget because the pass draws into it, shaderRead because a
        // later layer pass may sample it. A usage without renderTarget does
        // not fail here - it fails one step later, when the render pass
        // descriptor is rejected, which is the harder place to read it.
        metalSendVoid1(descriptor, 'setUsage:',
            MtlTextureUsage.renderTarget | MtlTextureUsage.shaderRead);
        // shared, measured working on Apple Silicon in run 34165428755. The
        // probe tried managed as well and it was not needed; recording that
        // here because a Mac with discrete memory may answer differently and
        // this line is the assumption that would have to change.
        metalSendVoid1(descriptor, 'setStorageMode:', MtlStorageMode.shared);
        return metalSendPointer3(
          _gpu.device,
          'newTextureWithDescriptor:iosurface:plane:',
          descriptor.address,
          surfaceRef.address,
          0,
        );
      });

  void _releaseSlots() {
    for (final MetalOffscreenTarget target in _slots.values) {
      target.dispose();
    }
    _slots.clear();
    // After the targets, because a target holds the texture it draws into and
    // releasing the texture first would leave one pointing at freed memory for
    // the length of the loop above.
    for (final Pointer<ObjCObject> texture in _textures.values) {
      objcRelease(texture);
    }
    _textures.clear();
  }

  @override
  void onDispose() {
    _releaseSlots();
    // The block last, and only here: it is marked global so nothing copied it,
    // which means freeing it while Metal could still call it is a
    // use-after-free on Metal's own completion thread - the least debuggable
    // place in the process. By here every frame has completed or timed out.
    _completedHandler?.dispose();
    _completedHandler = null;
    _callable?.close();
    _callable = null;
  }
}

/// The same surface at a new size.
///
/// A private wrapper rather than a mutable descriptor because
/// [NativeSurfaceDescriptor] implementations elsewhere are immutable value
/// objects and a target that mutated the window's own descriptor would be
/// changing something it does not own.
final class _ResizedSurface implements NativeSurfaceDescriptor {
  _ResizedSurface({
    required NativeSurfaceDescriptor original,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.scale,
  }) : _original = original;

  final NativeSurfaceDescriptor _original;

  @override
  String get kind => _original.kind;

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  @override
  String toString() =>
      '${_original.kind}(${pixelWidth}x$pixelHeight @${scale}x, resized)';
}
