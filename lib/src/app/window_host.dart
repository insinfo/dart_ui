/// The join between one platform window and one presentation path.
///
/// A window and a render target look like two halves of the same thing and
/// are not. The window is owned by the platform and outlives almost
/// everything; the target is pixels, and pixels are destroyed and rebuilt
/// constantly - by a resize, by dragging the window to a monitor with a
/// different DPI, by a GPU reset that takes the device with it. Every one of
/// those events happens *while a frame is in flight*, and that is the whole
/// reason this file exists.
///
/// ## The generation rule, stated once
///
/// `renderer.dart` already fixes the contract: [RenderTarget.generation] is
/// "incremented by resize and by device loss", and [Frame.generation] is "the
/// target's lifetime this frame belongs to - a frame presented after its
/// target was resized or lost must be rejected, not drawn". `lifecycle.dart`
/// supplies the mechanism: [GenerationToken] exists because "native code holds
/// callbacks that keep firing after shutdown, and 'is it still valid?' cannot
/// be answered by a null check".
///
/// [WindowHost] applies both to the *frame loop* rather than to a single
/// target. It stamps every [HostFrame] with the generation that was current
/// when the frame began, and refuses to present a frame whose stamp no longer
/// matches. Refuses meaning: the display list is never handed to the
/// presenter, so nothing is written into a buffer that has been reallocated
/// under it. The rejection is counted ([framesRejected]) and reported as
/// [PresentStatus.stale], which is the status `renderer.dart` reserves for
/// exactly this - "not an error: it is what a resize during a frame looks
/// like".
///
/// ## What this deliberately does not do
///
/// It does not own the window and it does not own the widget tree. It is
/// handed a live [NativeWindow] and a live [SurfacePresenter] and it releases
/// only the presenter, because the window belongs to the backend that made it
/// and the teardown order is the application's to declare. See
/// `application.dart`.
///
/// It also does not decide *when* to draw. Nothing here schedules a frame;
/// [handleEvent] reports what a window event implies and the caller acts on
/// it. A host that scheduled its own frames would be a second scheduler
/// competing with [FrameScheduler] for the same tree.
library;

import 'dart:async';

import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../platform/native_window.dart';
import '../platform/window_events.dart';
import '../rendering/cpu_renderer.dart';
import '../rendering/renderer.dart';

/// The shape every retained CPU presenter in this repository already has.
///
/// `Win32CpuPresenter.renderDisplayList` and `X11CpuPresenter.renderDisplayList`
/// match this signature argument for argument, which is why
/// [CallbackSurfacePresenter] can adapt either one with a tear-off and no
/// wrapper class. The typedef is stated here rather than in a backend so the
/// application layer keeps its rule: it may name a *shape*, never a backend.
typedef DisplayListPresentCallback = Future<PresentResult> Function(
  DisplayList list, {
  int? clearColor,
  Transform2D? deviceTransform,
  Rect? damage,
});

/// The same thing with the future taken off, for the one caller that cannot
/// have one.
///
/// A frame driven from inside a platform handler - see [LiveResizeWindow] - has
/// no event loop to come back to: the isolate is parked inside a native call
/// for the whole of a border drag, so a `Future` that completes "immediately"
/// completes *after the drag*, which is exactly too late. A presenter that
/// happens to do all its work before its first `await` is not enough either,
/// because nothing in the type says so and nothing stops the next edit from
/// adding one.
///
/// So the synchronous path is a separate, declared shape. Both Win32 and X11
/// CPU presenters are already this shape underneath; this is what lets a caller
/// depend on it.
typedef SynchronousDisplayListPresentCallback = PresentResult Function(
  DisplayList list, {
  int? clearColor,
  Transform2D? deviceTransform,
  Rect? damage,
});

/// A backend presenter reduced to the two things a host needs from it.
///
/// Handed as a record so a caller can build one from an existing object's
/// methods without that object having to implement anything:
///
/// ```dart
/// final presenter = Win32CpuPresenter(window as Win32Window);
/// return (present: presenter.renderDisplayList, release: presenter.dispose);
/// ```
/// [presentNow] is nullable rather than absent, and the null is a real answer:
/// a backend that has no synchronous path says so, and
/// [ApplicationOptions.liveResize] then degrades to the erase-background
/// fallback instead of pretending.
typedef RetainedCpuPresenter = ({
  DisplayListPresentCallback present,
  SynchronousDisplayListPresentCallback? presentNow,
  void Function() release,
});

/// A native surface created for a renderer device and borrowed window.
///
/// The release callback owns API objects such as a swapchain or GL context,
/// never the window. It is separate from [RenderTarget.dispose] because a
/// target owns shader resources while the platform adapter owns the object
/// that connects those resources to the compositor.
typedef RendererWindowAttachment = ({
  RenderDevice device,
  NativeSurfaceDescriptor surface,
  void Function() releaseSurface,
  bool releaseSurfaceBeforeDevice,
});

typedef RendererWindowAttachmentFactory = Future<RendererWindowAttachment>
    Function(
  RendererBackend backend,
  NativeWindow window,
);

/// Anything that can turn a display list into presented pixels for one window.
///
/// The interface is narrow on purpose. A host needs to draw, to be told the
/// surface changed size, and to be told whether the device underneath is gone.
/// Everything else - swapchains, DIB sections, `IOSurface` handoffs - is the
/// implementation's business and none of it appears here, which is what lets
/// the same [WindowHost] drive a memory framebuffer in a test and a GDI blit
/// on Windows.
abstract interface class SurfacePresenter implements Disposable {
  /// Identity for logs and for the startup report.
  RendererInfo get info;

  /// Rasterises [list] and puts it on screen.
  ///
  /// [deviceTransform] carries the window's render scale. It is passed
  /// explicitly rather than left to the presenter's own idea of the surface
  /// scale so that one authority - the window - decides how many physical
  /// pixels a logical unit is worth, and a disagreement between the two shows
  /// up as a visibly wrong size instead of a silently blurry one.
  Future<PresentResult> present(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  });

  /// The surface behind this presenter changed size or scale.
  ///
  /// Called *after* the window has already reallocated its own surface, so an
  /// implementation that reads the window's surface on every frame (the Win32
  /// and X11 presenters do) may legitimately do nothing here.
  void surfaceResized({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  });

  /// Whether the device this presenter draws with has been lost.
  ///
  /// Distinct from [isDisposed]: a lost device is recoverable and the window
  /// survives it, which is exactly the split `renderer.dart` describes when it
  /// says "recreating a device must not mean recreating the window".
  bool get isDeviceLost;

  /// Rebuilds whatever the device loss destroyed.
  ///
  /// Returns false when recovery failed, in which case the caller must tear
  /// down rather than spin: a presenter that cannot get a device back will not
  /// get one back on the next frame either, and retrying forever is how a
  /// dead GPU turns into a hung process.
  Future<bool> recoverFromDeviceLoss();
}

/// A presenter that can also draw without yielding to the event loop.
///
/// Separate from [SurfacePresenter] rather than a method on it, for the reason
/// [ActivatableWindow] is separate from [NativeWindow]: a presenter that cannot
/// do this must be able to say so by not implementing it, and adding a method
/// to the presenter contract would break every implementation at once for a
/// capability only some of them have. Tested for with a pattern:
///
/// ```dart
/// if (presenter case final SynchronousSurfacePresenter sync) ...
/// ```
///
/// See [SynchronousDisplayListPresentCallback] for why the future has to go.
abstract interface class SynchronousSurfacePresenter {
  /// Whether [presentNow] will actually do anything.
  ///
  /// A presenter can implement this interface and still be handed no
  /// synchronous callback - [CallbackSurfacePresenter] is exactly that case -
  /// so the type alone is not the answer.
  bool get canPresentNow;

  /// [SurfacePresenter.present], finished before it returns.
  PresentResult presentNow(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  });
}

/// One frame's claim on a window's surface.
///
/// Carries the generation it was begun in, which is the entire point. It is a
/// value, not a handle: holding it across an `await` is safe precisely because
/// it owns nothing - if the surface it described is gone, [WindowHost.present]
/// says so and drops it.
final class HostFrame {
  const HostFrame({
    required this.generation,
    required this.logicalSize,
    required this.renderScale,
    this.damage,
  });

  /// The [WindowHost] lifetime this frame belongs to.
  final int generation;

  /// The client area in logical units, which is what the tree was laid out
  /// against.
  final Size logicalSize;

  /// Physical pixels per logical unit at the moment the frame began.
  final double renderScale;

  /// The region the frame promises to redraw, or null for all of it.
  final Rect? damage;

  /// The transform that takes the tree's logical coordinates to device pixels.
  Transform2D get deviceTransform =>
      Transform2D.scaling(renderScale, renderScale);

  @override
  String toString() => 'HostFrame(generation: $generation, '
      '${logicalSize.width}x${logicalSize.height} @ $renderScale)';
}

/// What a window event means for the frame loop.
///
/// Returned rather than acted on, because the two responses a host could take
/// - relayout and repaint - belong to owners it does not have.
final class WindowEventOutcome {
  const WindowEventOutcome({
    this.needsFrame = false,
    this.logicalSize,
    this.surfaceInvalidated = false,
    this.closeRequested = false,
    this.closed = false,
    this.activation,
    this.suspended = false,
    this.resumed = false,
    this.ignoredAsStale = false,
  });

  /// The application should draw.
  final bool needsFrame;

  /// A new client size in logical units; null when it did not change. The
  /// caller turns this into root constraints - the host has no pipeline.
  final Size? logicalSize;

  /// The pixels behind the window were thrown away. Every frame stamped with
  /// an earlier generation will now be rejected.
  final bool surfaceInvalidated;

  final bool closeRequested;
  final bool closed;
  final WindowActivation? activation;

  /// The window became unpresentable - minimised to a zero-sized client area.
  final bool suspended;

  /// It became presentable again.
  final bool resumed;

  /// The event carried a generation the window has already moved past, so it
  /// described a surface that no longer exists and was dropped.
  final bool ignoredAsStale;

  static const WindowEventOutcome ignored = WindowEventOutcome();
}

/// Marries a [NativeWindow] to a [SurfacePresenter] and keeps them agreeing
/// about which surface is current.
final class WindowHost with DisposableMixin {
  WindowHost({
    required this.window,
    required SurfacePresenter presenter,
    this.onDiagnostic,
  })  : _presenter = presenter,
        _logicalSize = window.clientSize,
        _renderScale = window.renderScale,
        _desktopScale = window.desktopScale;

  final NativeWindow window;
  final SurfacePresenter _presenter;

  /// Where a non-fatal presentation failure goes. Never swallowed: a present
  /// that fails silently is the hardest kind of rendering bug to chase, which
  /// is the reason `PresentResult` carries a diagnostic at all.
  final void Function(BackendDiagnostic diagnostic)? onDiagnostic;

  final GenerationToken _generation = GenerationToken();

  Size _logicalSize;
  double _renderScale;
  double _desktopScale;
  bool _suspended = false;
  int _framesRejected = 0;
  int _framesPresented = 0;

  SurfacePresenter get presenter => _presenter;

  /// The lifetime a frame must carry to be presented.
  int get generation => _generation.current;

  Size get logicalSize => _logicalSize;
  double get renderScale => _renderScale;
  double get desktopScale => _desktopScale;

  /// Whether the window currently has a client area worth drawing into.
  ///
  /// False while minimised. Win32 reports a 0x0 client area then, and laying
  /// a tree out against `BoxConstraints.tight(Size.zero)` is not merely
  /// wasteful - it collapses every scroll offset and every measured extent,
  /// so the window comes back from the taskbar visibly reset.
  bool get isPresentable => !_suspended && !_logicalSize.isEmpty;

  /// Frames that were begun and then dropped because the surface moved under
  /// them. Exposed because "the generation rule is enforced" is otherwise an
  /// invisible claim.
  int get framesRejected => _framesRejected;

  int get framesPresented => _framesPresented;

  /// The pixel size the surface must be allocated at.
  int get pixelWidth => (_logicalSize.width * _renderScale).ceil();
  int get pixelHeight => (_logicalSize.height * _renderScale).ceil();

  /// Opens a frame against the current surface.
  ///
  /// Cheap and allocation-light on purpose: nothing is locked and nothing is
  /// reserved, so abandoning a frame costs nothing and a rejected frame leaks
  /// nothing.
  HostFrame beginFrame({Rect? damage}) {
    throwIfDisposed();
    return HostFrame(
      generation: _generation.current,
      logicalSize: _logicalSize,
      renderScale: _renderScale,
      damage: damage,
    );
  }

  /// Presents [list] as [frame], or rejects it.
  ///
  /// Three outcomes, and the first two never touch the surface:
  ///
  ///   * [PresentStatus.stale] - [frame] was begun in an earlier generation.
  ///     A resize, a DPI change or a device loss happened between
  ///     [beginFrame] and here. The pixels describe a surface that no longer
  ///     exists and drawing them would either tear or write out of bounds.
  ///   * [PresentStatus.stale] - the window is not presentable (minimised).
  ///   * [PresentStatus.deviceLost] - passed straight back. Recovery is
  ///     [recoverFromDeviceLoss]; a caller that retried the same frame would
  ///     retry it against the same dead device.
  Future<PresentResult> present(
    HostFrame frame,
    DisplayList list, {
    int? clearColor,
  }) async {
    throwIfDisposed();
    if (!_generation.accepts(frame.generation)) {
      _framesRejected++;
      return PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame from generation ${frame.generation} dropped; the window host '
          'is at generation ${_generation.current}',
          detail: 'the surface was reallocated between beginFrame and present',
        ),
      );
    }
    if (!isPresentable) {
      _framesRejected++;
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame dropped; the window has no presentable client area',
        ),
      );
    }

    final result = await _presenter.present(
      list,
      clearColor: clearColor,
      deviceTransform: frame.deviceTransform,
      damage: frame.damage,
    );

    // Re-checked after the await for the same reason `beginFrame` stamps at
    // all: the presenter may have yielded, and a resize delivered in that
    // window makes a "presented" result describe pixels nobody will ever see.
    // Reporting it as presented would make `framesPresented` a lie.
    if (!_generation.accepts(frame.generation)) {
      _framesRejected++;
      return PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame from generation ${frame.generation} was presented into a '
          'surface that was replaced during the present',
        ),
      );
    }

    if (result.isSuccess) {
      _framesPresented++;
    } else {
      final diagnostic = result.diagnostic;
      if (diagnostic != null) onDiagnostic?.call(diagnostic);
    }
    return result;
  }

  /// Whether [presentNow] can do anything but reject.
  ///
  /// A pattern rather than `is`, for the same reason [Application.clipboard]
  /// uses one: [SynchronousSurfacePresenter] is not a subtype of
  /// [SurfacePresenter], and `is` only promotes to a subtype of the declared
  /// type.
  bool get canPresentSynchronously =>
      _synchronousPresenter?.canPresentNow ?? false;

  SynchronousSurfacePresenter? get _synchronousPresenter {
    if (_presenter case final SynchronousSurfacePresenter presenter) {
      return presenter;
    }
    return null;
  }

  /// [present], without the await - for a frame driven from inside a platform
  /// handler.
  ///
  /// The generation rule is *identical* and deliberately so: a frame begun
  /// before a resize is rejected here exactly as it is there. It needs stating
  /// because the temptation is to skip it - "nothing can have changed, nothing
  /// yielded" - and that is wrong in the one case this method exists for. A
  /// live-resize frame lays out and paints while the user is still dragging,
  /// and Windows delivers the next `WM_SIZE` from inside `SetWindowPos` calls
  /// that layout itself can make. There is only one check rather than two
  /// because nothing suspends between them.
  ///
  /// Rejects rather than throws when the presenter has no synchronous path, so
  /// a caller can offer live resize on every backend and get it on the ones
  /// that can do it.
  PresentResult presentNow(
    HostFrame frame,
    DisplayList list, {
    int? clearColor,
  }) {
    throwIfDisposed();
    final presenter = _synchronousPresenter;
    if (presenter == null || !presenter.canPresentNow) {
      _framesRejected++;
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame dropped; this presenter has no synchronous path',
          detail: 'live resize needs a presenter that finishes before it '
              'returns, because the isolate is inside a native call',
        ),
      );
    }
    if (!_generation.accepts(frame.generation)) {
      _framesRejected++;
      return PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame from generation ${frame.generation} dropped; the window host '
          'is at generation ${_generation.current}',
          detail: 'the surface was reallocated between beginFrame and present',
        ),
      );
    }
    if (!isPresentable) {
      _framesRejected++;
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame dropped; the window has no presentable client area',
        ),
      );
    }

    final result = presenter.presentNow(
      list,
      clearColor: clearColor,
      deviceTransform: frame.deviceTransform,
      damage: frame.damage,
    );
    if (result.isSuccess) {
      _framesPresented++;
    } else {
      final diagnostic = result.diagnostic;
      if (diagnostic != null) onDiagnostic?.call(diagnostic);
    }
    return result;
  }

  /// Adopts a new client size and render scale, invalidating every frame in
  /// flight.
  ///
  /// Invalidation happens *first*, before the presenter is told anything, so
  /// there is no instant at which a frame stamped with the old generation
  /// could still be accepted against a surface that is already being replaced.
  void surfaceChanged({
    Size? logicalSize,
    double? renderScale,
    double? desktopScale,
  }) {
    throwIfDisposed();
    final nextSize = logicalSize ?? _logicalSize;
    final nextRenderScale = renderScale ?? _renderScale;
    final nextDesktopScale = desktopScale ?? _desktopScale;
    if (nextSize == _logicalSize &&
        nextRenderScale == _renderScale &&
        nextDesktopScale == _desktopScale) {
      return;
    }

    _generation.invalidate();
    _logicalSize = nextSize;
    _renderScale = nextRenderScale;
    _desktopScale = nextDesktopScale;
    if (_logicalSize.isEmpty) return;
    _presenter.surfaceResized(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: _renderScale,
    );
  }

  /// Rebuilds the device after a loss, invalidating everything in flight.
  Future<bool> recoverFromDeviceLoss() async {
    throwIfDisposed();
    _generation.invalidate();
    final recovered = await _presenter.recoverFromDeviceLoss();
    if (!recovered) {
      onDiagnostic?.call(const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the render device was lost and could not be recreated',
        detail: 'the window survives a device loss, so this is a renderer '
            'failure and not a windowing one',
      ));
      return false;
    }
    _presenter.surfaceResized(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: _renderScale,
    );
    return true;
  }

  /// Interprets one platform event. Never draws, never schedules.
  ///
  /// Surface-affecting events carry a generation and are dropped when it no
  /// longer matches the window's, because such an event describes geometry
  /// that has already been superseded - acting on it would size the surface
  /// for a window shape that existed two resizes ago. Lifecycle and input
  /// events are *not* filtered that way: a close that arrives late is still a
  /// close, and refusing to process it is how a process fails to exit.
  WindowEventOutcome handleEvent(PlatformWindowEvent event) {
    throwIfDisposed();
    switch (event) {
      case WindowResizedEvent(
          clientSize: final Size size,
          renderScale: final double scale,
        ):
        if (event.generation != window.generation) {
          return const WindowEventOutcome(ignoredAsStale: true);
        }
        final wasPresentable = isPresentable;
        surfaceChanged(logicalSize: size, renderScale: scale);
        if (size.isEmpty) {
          _suspended = true;
          return const WindowEventOutcome(
            surfaceInvalidated: true,
            suspended: true,
          );
        }
        final resumed = _suspended || !wasPresentable;
        _suspended = false;
        return WindowEventOutcome(
          needsFrame: true,
          logicalSize: size,
          surfaceInvalidated: true,
          resumed: resumed,
        );

      case WindowScaleChangedEvent(
          renderScale: final double render,
          desktopScale: final double desktop,
        ):
        if (event.generation != window.generation) {
          return const WindowEventOutcome(ignoredAsStale: true);
        }
        // The layout is unchanged in logical units and every rasterised
        // resource is now the wrong resolution, which is why this event exists
        // separately from a resize. So: no new logicalSize, but the surface is
        // invalidated and everything must be redrawn.
        surfaceChanged(renderScale: render, desktopScale: desktop);
        return const WindowEventOutcome(
          needsFrame: true,
          surfaceInvalidated: true,
        );

      case WindowExposedEvent():
        if (event.generation != window.generation) {
          return const WindowEventOutcome(ignoredAsStale: true);
        }
        return const WindowEventOutcome(needsFrame: true);

      case WindowActivationEvent(activation: final WindowActivation state):
        return WindowEventOutcome(needsFrame: true, activation: state);

      case WindowCloseRequestedEvent():
        return const WindowEventOutcome(closeRequested: true);

      case WindowClosedEvent():
        return const WindowEventOutcome(closed: true);

      default:
        return WindowEventOutcome.ignored;
    }
  }

  /// Releases the presenter and refuses every frame still in flight.
  ///
  /// The window is *not* closed here. It was handed in, it is owned by the
  /// backend that created it, and closing it from inside the object that
  /// merely draws to it would invert the teardown order the application
  /// declares. See `DisposableBag` in `lifecycle.dart`.
  @override
  void onDispose() {
    _generation.invalidate();
    _presenter.dispose();
  }
}

/// A presenter built on the portable [RenderDevice] / [RenderTarget] pair.
///
/// This is the path with no backend in it at all: a window that exposes a
/// [MemorySurfaceDescriptor] - the headless backend does - plus the CPU
/// renderer is a complete, testable application. It is also the path that a
/// GPU backend will take once a windowed target exists, because nothing here
/// says CPU except the default [RendererBackend] the caller passes.
final class RenderTargetPresenter
    with DisposableMixin
    implements SurfacePresenter {
  RenderTargetPresenter._({
    required RendererBackend backend,
    required RenderDevice device,
    required RenderTarget target,
    required NativeSurfaceDescriptor surface,
    NativeWindow? window,
    RendererWindowAttachmentFactory? attachmentFactory,
    void Function()? releaseSurface,
    bool releaseSurfaceBeforeDevice = true,
  })  : _backend = backend,
        _device = device,
        _target = target,
        _surface = surface,
        _window = window,
        _attachmentFactory = attachmentFactory,
        _releaseSurface = releaseSurface ?? _doNothing,
        _releaseSurfaceBeforeDevice = releaseSurfaceBeforeDevice;

  /// Opens a device on [backend] and binds it to a surface of [window].
  ///
  /// Fails loudly and by name when no surface fits. That is not a theoretical
  /// branch: a Win32 window offers a DIB section, which the CPU renderer
  /// cannot target, so a caller who wires this presenter to a Win32 window
  /// gets a message naming the surface kinds that were offered rather than a
  /// blank window.
  static Future<RenderTargetPresenter> attach({
    required RendererBackend backend,
    required NativeWindow window,
  }) async {
    final surfaces = window.surfaces;
    NativeSurfaceDescriptor? chosen;
    for (final surface in surfaces) {
      if (backend.supportsSurface(surface)) {
        chosen = surface;
        break;
      }
    }
    if (chosen == null) {
      throw BackendSelectionError(
        requested: backend.info.name,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            backend.info.name,
            BackendDiagnostic(
              kind: DiagnosticKind.surfaceCreationFailed,
              message: '${backend.info.name} cannot present to any surface '
                  'this window offers',
              detail: surfaces.isEmpty
                  ? 'the window offers no surfaces at all, which is what a '
                      'minimised or torn-down window reports'
                  : 'offered: '
                      '${surfaces.map((s) => s.kind).join(', ')}',
            ),
          ),
          backend.probe(),
        ],
      );
    }
    final device = await backend.createDevice();
    return RenderTargetPresenter._(
      backend: backend,
      device: device,
      target: device.createTarget(chosen),
      surface: chosen,
    );
  }

  /// Opens a device and lets a platform adapter connect it to [window].
  ///
  /// This is the production GPU seam. The common presenter still owns replay,
  /// resize, device-loss recovery and teardown; the platform callback only
  /// turns an opaque native window into the renderer's surface descriptor.
  static Future<RenderTargetPresenter> attachToWindow({
    required RendererBackend backend,
    required NativeWindow window,
    required RendererWindowAttachmentFactory createAttachment,
  }) async {
    RendererWindowAttachment? attachment;
    try {
      attachment = await createAttachment(backend, window);
      final RenderTarget target =
          attachment.device.createTarget(attachment.surface);
      return RenderTargetPresenter._(
        backend: backend,
        device: attachment.device,
        target: target,
        surface: attachment.surface,
        window: window,
        attachmentFactory: createAttachment,
        releaseSurface: attachment.releaseSurface,
        releaseSurfaceBeforeDevice: attachment.releaseSurfaceBeforeDevice,
      );
    } on Object {
      if (attachment case final RendererWindowAttachment value) {
        _disposeAttachedDevice(
          device: value.device,
          releaseSurface: value.releaseSurface,
          releaseSurfaceBeforeDevice: value.releaseSurfaceBeforeDevice,
        );
      }
      rethrow;
    }
  }

  final RendererBackend _backend;
  RenderDevice _device;
  RenderTarget _target;
  NativeSurfaceDescriptor _surface;
  final NativeWindow? _window;
  final RendererWindowAttachmentFactory? _attachmentFactory;
  void Function() _releaseSurface;
  bool _releaseSurfaceBeforeDevice;

  RenderDevice get device => _device;
  RenderTarget get target => _target;

  @override
  RendererInfo get info => _device.info;

  @override
  bool get isDeviceLost => _device.isLost;

  @override
  Future<PresentResult> present(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) async {
    throwIfDisposed();
    if (_device.isLost) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the render device was lost before the frame was submitted',
        ),
      );
    }
    final RenderTarget target = _target;
    if (target is DisplayListRenderTarget) {
      return target.renderDisplayList(
        list,
        clearColor: clearColor,
        deviceTransform: deviceTransform ?? Transform2D.identity,
      );
    }
    final frame = target.beginFrame(FrameRequest(damage: damage));
    // The clear goes to the rasteriser rather than to `FrameRequest`, so that
    // exactly one thing clears the buffer. Both would work and the second
    // would be pure waste - a full-surface memset on every frame.
    rasterizeDisplayList(
      list,
      frame.framebuffer,
      clearColor: clearColor,
      damage: damage,
      deviceTransform: deviceTransform ?? Transform2D.identity,
    );
    return target.present(frame);
  }

  @override
  void surfaceResized({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  }) {
    throwIfDisposed();
    // `RenderTarget.resize` bumps the target's own generation, so a `Frame`
    // taken before this call is rejected by the target too. The host's
    // generation and the target's are separate counters on purpose: the host
    // also invalidates for reasons the target knows nothing about.
    _target.resize(pixelWidth, pixelHeight, scale);
    _surface = _target.surface;
  }

  @override
  Future<bool> recoverFromDeviceLoss() async {
    throwIfDisposed();
    _target.dispose();
    final void Function() oldRelease = _releaseSurface;
    _releaseSurface = _doNothing;
    _disposeAttachedDevice(
      device: _device,
      releaseSurface: oldRelease,
      releaseSurfaceBeforeDevice: _releaseSurfaceBeforeDevice,
    );
    final RendererWindowAttachmentFactory? factory = _attachmentFactory;
    final NativeWindow? window = _window;
    if (factory != null && window != null) {
      final RendererWindowAttachment attachment = await factory(
        _backend,
        window,
      );
      if (attachment.device.isLost) {
        _disposeAttachedDevice(
          device: attachment.device,
          releaseSurface: attachment.releaseSurface,
          releaseSurfaceBeforeDevice: attachment.releaseSurfaceBeforeDevice,
        );
        return false;
      }
      late final RenderTarget target;
      try {
        target = attachment.device.createTarget(attachment.surface);
      } on Object {
        _disposeAttachedDevice(
          device: attachment.device,
          releaseSurface: attachment.releaseSurface,
          releaseSurfaceBeforeDevice: attachment.releaseSurfaceBeforeDevice,
        );
        rethrow;
      }
      _device = attachment.device;
      _surface = attachment.surface;
      _releaseSurface = attachment.releaseSurface;
      _releaseSurfaceBeforeDevice = attachment.releaseSurfaceBeforeDevice;
      _target = target;
    } else {
      final RenderDevice device = await _backend.createDevice();
      if (device.isLost) {
        device.dispose();
        return false;
      }
      late final RenderTarget target;
      try {
        target = device.createTarget(_surface);
      } on Object {
        device.dispose();
        rethrow;
      }
      _device = device;
      _target = target;
    }
    return true;
  }

  /// Reverse of acquisition: the target draws into memory the device owns, so
  /// the device must outlive it.
  @override
  void onDispose() {
    final void Function() release = _releaseSurface;
    _releaseSurface = _doNothing;
    try {
      _target.dispose();
    } finally {
      _disposeAttachedDevice(
        device: _device,
        releaseSurface: release,
        releaseSurfaceBeforeDevice: _releaseSurfaceBeforeDevice,
      );
    }
  }
}

void _doNothing() {}

void _disposeAttachedDevice({
  required RenderDevice device,
  required void Function() releaseSurface,
  required bool releaseSurfaceBeforeDevice,
}) {
  if (releaseSurfaceBeforeDevice) {
    try {
      releaseSurface();
    } finally {
      device.dispose();
    }
    return;
  }
  try {
    device.dispose();
  } finally {
    releaseSurface();
  }
}

/// Adapts a backend's own retained presenter to [SurfacePresenter].
///
/// Exists so that `lib/src/app` can drive `Win32CpuPresenter` and
/// `X11CpuPresenter` without importing either - the caller supplies two
/// tear-offs and this closes the gap. That constraint is not bureaucracy: the
/// layering test asserts that no core file names a backend, and the moment the
/// application shell knows what a DIB section is, "the same shell runs
/// everywhere" stops being true.
final class CallbackSurfacePresenter
    with DisposableMixin
    implements SurfacePresenter, SynchronousSurfacePresenter {
  CallbackSurfacePresenter({
    required this.info,
    required DisplayListPresentCallback present,
    required void Function() release,
    SynchronousDisplayListPresentCallback? presentNow,
    void Function({
      required int pixelWidth,
      required int pixelHeight,
      required double scale,
    })? onSurfaceResized,
  })  : _present = present,
        _presentNow = presentNow,
        _release = release,
        _onSurfaceResized = onSurfaceResized;

  /// Builds one from the record form, which is what a two-line call site in an
  /// example produces.
  CallbackSurfacePresenter.retained({
    required this.info,
    required RetainedCpuPresenter presenter,
  })  : _present = presenter.present,
        _presentNow = presenter.presentNow,
        _release = presenter.release,
        _onSurfaceResized = null;

  @override
  final RendererInfo info;

  final DisplayListPresentCallback _present;
  final SynchronousDisplayListPresentCallback? _presentNow;
  final void Function() _release;
  final void Function({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  })? _onSurfaceResized;

  @override
  Future<PresentResult> present(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) {
    throwIfDisposed();
    return _present(
      list,
      clearColor: clearColor,
      deviceTransform: deviceTransform,
      damage: damage,
    );
  }

  @override
  bool get canPresentNow => _presentNow != null && !isDisposed;

  @override
  PresentResult presentNow(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) {
    throwIfDisposed();
    final present = _presentNow;
    if (present == null) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'this retained presenter was built without a synchronous path',
        ),
      );
    }
    return present(
      list,
      clearColor: clearColor,
      deviceTransform: deviceTransform,
      damage: damage,
    );
  }

  /// Usually a no-op, and that is correct rather than lazy.
  ///
  /// The Win32 and X11 presenters read the window's current surface on every
  /// frame and replay the retained display list into the replacement
  /// themselves. Telling them to resize would be telling them something they
  /// already acted on.
  @override
  void surfaceResized({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  }) {
    throwIfDisposed();
    _onSurfaceResized?.call(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
    );
  }

  /// A CPU blit through a window's own surface has no device to lose: the
  /// surface dies with the window, and that is a close, not a loss.
  @override
  bool get isDeviceLost => false;

  @override
  Future<bool> recoverFromDeviceLoss() async => true;

  @override
  void onDispose() => _release();
}
