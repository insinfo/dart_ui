/// The shell: everything between `main` and a widget tree.
///
/// Before this file existed, `example/gallery_win32.dart` was 286 lines of
/// which perhaps twenty were about the gallery. The rest was assembly - choose
/// a backend, make a window, make a surface, make a renderer, make a scheduler,
/// make a [BuildOwner] and a [PipelineOwner], wire pointer and keyboard events
/// into them, run a loop, tear it all down in the right order - and every MVP
/// under `mvp/` had its own copy of the same code, subtly diverged. That is
/// the direct reason there was no X11 or AppKit gallery: writing one meant
/// re-deriving the assembly rather than swapping a backend.
///
/// So the assembly lives here, once, and the platform enters through two
/// lists the caller supplies. Nothing in this file names Win32, X11, AppKit or
/// even the headless backend; the layering test enforces that, and the reason
/// it must is that the moment a shell knows what a DIB section is, "the same
/// application runs everywhere" stops being checkable.
///
/// ## One application, N windows
///
/// An [Application] owns a *set* of [ApplicationWindow]s, opened and closed at
/// runtime through [Application.openWindow] and [Application.closeWindow]. The
/// split between the two classes is exactly the split between what is shared
/// and what is not:
///
///   * **[Application] owns** the windowing backend, the selection reports, the
///     clipboard, the frame statistics, the application lifecycle state, the
///     keyboard-focus arbitration between windows, and the modal relation.
///   * **[ApplicationWindow] owns** one [NativeWindow], one [SurfacePresenter]
///     through one [WindowHost], one [PipelineOwner], one [FrameScheduler],
///     one [BuildOwner] and one widget tree.
///
/// ### Why the owners are per window and not shared
///
/// It is not a preference; the types already say so, and the alternative is
/// unimplementable rather than merely undesirable:
///
///   * [BuildOwner]'s constructor *throws* on a [PipelineOwner] that already
///     has a root, and [FrameScheduler]'s throws on one that already has a
///     visual-update owner. A shared pipeline could therefore hold exactly one
///     window's render tree.
///   * `element.dart` already states the rule for focus - "one per owner,
///     because focus is per window: two windows each have a focused control
///     and only one of them is active". The [FocusManager] hangs off the
///     [BuildOwner]; sharing the owner would fuse the two windows' focus.
///   * The dirty lists are the point. [PipelineOwner.rootConstraints] is one
///     window's client size, and `flushLayout` starts from
///     `root.layout(_rootConstraints)`. With a shared pipeline, a `setState` in
///     window A would put A's render objects in the same
///     `_nodesNeedingLayout` list that B's frame drains, so B's frame would lay
///     out A's tree - against B's constraints. That is the failure this design
///     is required to make impossible, and `test/app/multi_window_test.dart`
///     counts `performLayout` calls per window to prove it.
///
/// What is given up by not sharing is a single [InheritedWidget] scope across
/// windows - a `Theme` above the root would otherwise be visible in every
/// window at once. That is recovered without sharing an owner: the *widget* and
/// its state object may be shared even though the owners are not, so an
/// application wraps each window's root in the same `Theme(data: sharedTheme)`
/// and calls [ApplicationWindow.updateRoot] on every window when it changes.
/// `example/gallery_multiwindow.dart` does exactly that. Sharing a value is a
/// application-level decision; sharing a dirty list is a correctness bug.
///
/// ## Startup order, and why teardown is its exact reverse
///
///   1. **Select a windowing backend.** Through `backend_selection.dart`, with
///      a report that names every candidate and why each was passed over -
///      including the healthy ones. Failure throws [BackendSelectionError]
///      carrying *all* the probes, never a fallback nobody was told about.
///   2. **Initialize it.**
///   3. **Select a presentation path.**
///   4. **Open the first window**, which is steps 4a-4e of
///      [Application.openWindow]: create the window, attach a
///      [SurfacePresenter] to it producing a [WindowHost], build the frame
///      plumbing, mount nothing yet, subscribe to the window's events.
///
/// Each step is registered with a [DisposableBag] as it succeeds, so teardown
/// runs backwards with no ordering decision left to make at shutdown - which is
/// the whole reason `lifecycle.dart` has a bag at all. There are two levels of
/// bag: the application's holds the backend and then each window, so windows
/// are released newest-first and the backend last; each window's holds its own
/// four resources. A startup that fails half-way disposes exactly what it
/// built, and disposing twice is a no-op.
///
/// ## Lifecycle, stated as policy
///
/// The states are [ApplicationLifecycleState]. What happens to a frame that is
/// in flight across each transition is the question that actually matters, so:
///
///   * **starting -> running.** No frame is in flight. A window's root is
///     mounted on its first [ApplicationWindow.drawFrame], not at [start], so a
///     caller can attach diagnostics between the two.
///   * **running -> suspended** (every window minimised, or deactivated when
///     [ApplicationOptions.suspendWhenDeactivated] is set). A frame already
///     begun runs to completion and is *presented if its generation still
///     matches*. Throwing away pixels that are already rasterised buys
///     nothing; what suspension stops is the *next* frame. While suspended the
///     loop still pumps events - a suspended application that stopped reading
///     its message queue would be an unresponsive window, which on Windows is
///     a visible failure. Suspension is per window and the application state
///     follows the *whole set*: minimising one of two windows must not stop the
///     other drawing.
///   * **suspended -> running.** The tree is marked dirty and a full repaint
///     is requested. Not an optimisation to skip: the compositor may have
///     discarded the window's contents, and a damage-only repaint would leave
///     whatever the platform put there.
///   * **-> closing.** [WindowHost] invalidates its generation the moment the
///     close is accepted, so a frame in flight is *rejected* rather than
///     drawn - it would otherwise be writing into a surface that teardown is
///     about to free. The in-flight `await` still completes; it just returns
///     [PresentStatus.stale].
///   * **resize / DPI change / device loss.** Same rule, same mechanism: the
///     generation moves, the in-flight frame is rejected, a fresh one is
///     requested. See `window_host.dart`, which states the contract in full.
///   * **-> closed.** [dispose] has run. Every accessor that needs live state
///     throws; [framesPresented], [statistics], [controlCount] and
///     [semanticNodeCount] are snapshotted *before* teardown precisely so a
///     summary can be printed afterwards.
///
/// ### What closing the last window does
///
/// [ApplicationOptions.exitWhenLastWindowClosed], **true by default**. True is
/// the desktop-application answer: the last window going away ends the run
/// loop, `run()` returns and the caller disposes. False is the tray/agent
/// answer: the application survives with zero windows, keeps its backend, its
/// clipboard and its scheduled work, and can [openWindow] again later. It is a
/// policy and not a guess, so it is configurable and stated here rather than
/// implied by whichever branch happened to be written.
///
/// One asymmetry is deliberate. A [WindowCloseRequestedEvent] for the *last*
/// window under the default policy is a request to close the **application**:
/// [requestClose] runs, which invalidates every host's generation at once but
/// leaves teardown to [dispose]. Tearing the window down from inside an event
/// handler would leave `run()` half-way through a loop iteration holding a
/// released surface. A close request for any other window is an immediate,
/// ordered [closeWindow].
library;

import 'dart:async';

import '../diagnostics/dev_overlay.dart';
import '../foundation/collections.dart';
import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/pipeline.dart';
import '../layout/render_box.dart';
import '../platform/backend_selection.dart';
import '../platform/clipboard.dart';
import '../platform/drag_drop.dart';
import '../platform/input_events.dart';
import '../platform/native_window.dart';
import '../platform/text_input.dart';
import '../platform/window_events.dart';
import '../rendering/cpu_renderer.dart';
import '../rendering/render_diagnostics.dart';
import '../rendering/render_policy.dart';
import '../rendering/renderer.dart';
import '../scheduler/frame_scheduler.dart';
import '../scheduler/manual_dispatcher.dart';
import '../semantics/accessibility.dart';
import '../text/shaper.dart' show TextDirection;
import '../widgets/context_menu.dart' show ContextMenuScope;
import '../widgets/control.dart';
import '../widgets/controls.dart' show ClipboardScope, TextInputScope;
import '../widgets/dart_ui_app.dart';
import '../widgets/drag_drop.dart' show DragDropScope, WidgetTreeDropTarget;
import '../widgets/element.dart';
import '../widgets/errors.dart';
import '../widgets/media_query.dart';
import '../widgets/popup.dart';
import '../widgets/popup_host.dart';
import '../widgets/theme.dart';
import '../widgets/widget.dart';
import 'application_info.dart';
import 'window_host.dart';
import 'window_popup_host.dart';

/// Where an application is in its life.
enum ApplicationLifecycleState {
  /// Assembled, root not yet mounted, no frame drawn.
  starting,

  /// Drawing on demand.
  running,

  /// Alive and pumping events, but not drawing. See the policy in the library
  /// comment.
  suspended,

  /// Teardown has been requested and the frames in flight have been
  /// invalidated.
  closing,

  /// [Application.dispose] has run.
  closed,
}

/// A windowing backend the application may choose.
///
/// Holds a *factory*, not an instance, so that probing several candidates does
/// not construct native state for the ones that lose. Every backend in this
/// repository has a cheap constructor and does its real work in `probe()` and
/// `initialize()`, which is what makes this shape possible.
final class WindowingBackendEntry {
  const WindowingBackendEntry({
    required this.name,
    required this.create,
    this.experimental = false,
  });

  /// Stable identifier: `win32`, `x11`, `headless`, `appkitNativeHost`. This
  /// is what [ApplicationOptions.requestedBackend], `--backend` and
  /// `DART_UI_BACKEND` match against.
  final String name;

  final WindowingBackend Function() create;

  /// Never chosen automatically. Must be named.
  final bool experimental;
}

/// A way of getting pixels onto a chosen window's surface.
final class PresentationPathEntry {
  const PresentationPathEntry({
    required this.name,
    required this.kind,
    required this.probe,
    required this.attach,
    required this.rasterizationApproach,
    this.backend,
    this.compatibleWindowingBackends,
    this.experimental = false,
    this.sharesDevice = false,
  });

  /// A retained CPU presenter owned by a backend, adapted in one line.
  ///
  /// The shape `Win32CpuPresenter` and `X11CpuPresenter` already have. See
  /// [RetainedCpuPresenter].
  factory PresentationPathEntry.retainedCpu({
    required String name,
    required String deviceDescription,
    required RetainedCpuPresenter Function(NativeWindow window) create,
    BackendProbeResult Function()? probe,
    Set<String>? compatibleWindowingBackends,
  }) =>
      PresentationPathEntry(
        name: name,
        kind: PresentationKind.cpu,
        rasterizationApproach: RasterizationApproach.softwareScanline,
        compatibleWindowingBackends: compatibleWindowingBackends,
        probe: probe ??
            () => BackendProbeResult(
                  backendName: name,
                  supported: true,
                  capabilities: const <Capability>{
                    Capability.cpuPresentation,
                    Capability.partialPresent,
                  },
                  diagnostics: <BackendDiagnostic>[
                    BackendDiagnostic.note(
                      'retained CPU presentation through the window\'s own '
                      'surface',
                      detail: deviceDescription,
                    ),
                  ],
                ),
        // `devices` is ignored, and that is the honest answer rather than an
        // omission: these pixels go through a presenter the windowing backend
        // owns - a DIB section, a `wl_shm` pool, an `IOSurface` - and there is
        // no `RenderDevice` anywhere on this path to share.
        attach: (NativeWindow window, {RenderDeviceProvider? devices}) async =>
            CallbackSurfacePresenter.retained(
          info: RendererInfo(
            name: name,
            deviceDescription: deviceDescription,
            rasterizationApproach: RasterizationApproach.softwareScanline,
          ),
          presenter: create(window),
        ),
      );

  /// The portable path: the CPU renderer over whatever memory surface the
  /// window offers. Always available where the window offers one, which is
  /// what makes the headless backend a complete application rather than a
  /// mock.
  factory PresentationPathEntry.cpuRenderer({
    RendererBackend backend = const CpuRendererBackend(),
    String? name,
  }) =>
      PresentationPathEntry(
        name: name ?? backend.info.name,
        kind: PresentationKind.cpu,
        rasterizationApproach: backend.info.rasterizationApproach,
        backend: backend,
        // A `CpuRenderDevice` has no driver behind it, so sharing one buys
        // nothing dramatic - but the glyph and coverage caches hang off the
        // device here exactly as they do on a GPU one, and a second window
        // rasterising the same font at the same size from scratch is the same
        // waste on either path.
        sharesDevice: true,
        probe: backend.probe,
        attach: (NativeWindow window, {RenderDeviceProvider? devices}) =>
            RenderTargetPresenter.attach(
          backend: backend,
          window: window,
          devices: devices,
        ),
      );

  /// A renderer that replays display lists directly into a native window.
  ///
  /// This is the extension seam for GPU rasterization families. A backend may
  /// use analytic coverage, tessellation, stencil-and-cover, compute tiles, or
  /// a custom strategy; application and compositor code only see the common
  /// [RendererBackend] and [DisplayListRenderTarget] contracts.
  /// [sharesDevice] is Avalonia's `IPlatformGraphics.UsesSharedContext`, moved
  /// onto the path because that is where this framework knows the answer:
  /// [RendererBackend] deliberately does not grow a capability for it, and the
  /// same `GlRendererBackend` is shareable or not depending on how the
  /// attachment obtains its context.
  ///
  /// True is the framework's rule - "um dispositivo, N swapchains" - and every
  /// Direct3D-family path answers true, because one `ID3D11Device` with N swap
  /// chains is what the API is shaped like. The OpenGL paths answer false and
  /// the reason is structural rather than unfinished work: their context is
  /// created from the window's own HDC or drawable with its own pixel format
  /// and no share group, and there is no `wglShareLists` call anywhere in this
  /// repository. Making them share is a design change to the GL backend - a
  /// share group at context creation, or one context made current on several
  /// HDCs, which the spec permits only for matching pixel formats and which
  /// then serialises every window on `MakeCurrent` - not a call-site change,
  /// so it is declared false here rather than silently half-done.
  ///
  /// [openDevice] replaces `RendererBackend.createDevice` as the way a shared
  /// device is opened, for the one path whose presentation device the backend
  /// cannot produce. See [RenderDeviceProvider.acquire].
  factory PresentationPathEntry.directRenderer({
    required RendererBackend backend,
    required RendererWindowAttachmentFactory createAttachment,
    String? name,
    BackendProbeResult Function()? probe,
    Set<String>? compatibleWindowingBackends,
    bool experimental = false,
    bool sharesDevice = true,
    Future<RenderDevice> Function()? openDevice,
  }) =>
      PresentationPathEntry(
        name: name ?? backend.info.name,
        kind: PresentationKind.gpu,
        rasterizationApproach: backend.info.rasterizationApproach,
        backend: backend,
        compatibleWindowingBackends: compatibleWindowingBackends,
        experimental: experimental,
        sharesDevice: sharesDevice,
        probe: probe ?? backend.probe,
        attach: (NativeWindow window, {RenderDeviceProvider? devices}) =>
            RenderTargetPresenter.attachToWindow(
          backend: backend,
          window: window,
          createAttachment: createAttachment,
          devices: sharesDevice ? devices : null,
          openDevice: openDevice,
        ),
      );

  final String name;
  final PresentationKind kind;

  /// How arbitrary vector paths reach pixels on this path.
  ///
  /// Selection does not branch on this value. It is observable metadata and
  /// the registration point for future tessellation, stencil-and-cover and
  /// compute implementations under the same presentation contract.
  final RasterizationApproach rasterizationApproach;

  /// Windowing backend entry names this path can attach to, or null when it is
  /// portable. The check happens after windowing selection but before a native
  /// window is created, preventing a retained native presenter from winning a
  /// headless fallback and failing later on a type cast.
  final Set<String>? compatibleWindowingBackends;

  /// Asked once, during selection. Must not throw: a probe that throws takes
  /// the whole selection down instead of losing one candidate.
  final BackendProbeResult Function() probe;

  /// The renderer this path draws with, when there is one to name.
  ///
  /// Null for [PresentationPathEntry.retainedCpu], where the pixels go through
  /// a presenter the windowing backend owns and no [RendererBackend] is
  /// involved at all. Exposed rather than captured privately in [attach]
  /// because a caller that wants to know what a *device* costs - the popup
  /// smoke does, and the answer is the whole justification for sharing one -
  /// otherwise has no way to ask for one without going through a window.
  final RendererBackend? backend;

  /// Binds this path to a live window. Called once per window, for the winner
  /// only - every window of one application gets its own presenter, because a
  /// presenter is bound to one surface.
  ///
  /// A presenter per window is right and a *device* per window was not, and
  /// [devices] is the difference. The application passes its registry here and
  /// the second window of an application is handed the first window's device,
  /// so what a new window costs is a swap chain rather than a driver
  /// connection. Null means "nobody is sharing" and restores the per-window
  /// device this framework opened before the registry existed, which is what
  /// a caller building a presenter by hand outside an [Application] gets.
  final Future<SurfacePresenter> Function(
    NativeWindow window, {
    RenderDeviceProvider? devices,
  }) attach;

  final bool experimental;

  /// Whether every window of one application draws through one device.
  ///
  /// Reported rather than merely acted on, because "the popup got its own
  /// `ID3D11Device`" was true for a year and invisible from everywhere: the
  /// two devices had the same [RendererInfo], drew the same pixels and
  /// differed only in cost. A path that answers false here is saying so on
  /// purpose - see [PresentationPathEntry.directRenderer].
  final bool sharesDevice;

  BackendProbeResult probeForWindowingBackend(String backendName) {
    final Set<String>? compatible = compatibleWindowingBackends;
    if (compatible == null || compatible.contains(backendName)) return probe();
    return BackendProbeResult.unsupported(
      name,
      BackendDiagnostic(
        kind: DiagnosticKind.rejectedByPolicy,
        message: '$name cannot attach to the selected $backendName windowing '
            'backend',
        detail: 'compatible windowing backends: ${compatible.join(', ')}',
      ),
    );
  }
}

/// Everything an application can be configured with before it starts.
final class ApplicationOptions {
  const ApplicationOptions({
    this.title = 'dart_ui',
    this.size = const Size(800, 600),
    this.visible = false,
    this.clearColor,
    this.showDevOverlay = false,
    this.devOverlayInterval = const Duration(milliseconds: 500),
    this.idleTimeout = const Duration(milliseconds: 250),
    this.frameBudget = 0,
    this.requestedBackend,
    this.requestedPresentation,
    this.preferredBackends = const <String>[],
    this.preferredPresentations = const <String>[],
    this.requiredCapabilities = const <Capability>{Capability.window},
    this.allowExperimentalBackends = false,
    this.suspendWhenDeactivated = false,
    this.exitWhenLastWindowClosed = true,
    this.liveResize = true,
    this.minimumSize,
    this.maximumSize,
    this.windowBackgroundColor,
    this.gpuPresentationCapability = kGpuPresentationCapability,
    this.renderingPolicy = RenderingPolicy.auto,
    this.renderPolicy = RenderPolicy.defaults,
    this.theme = ThemeData.neutralLight,
    this.textDirection = TextDirection.leftToRight,
    this.popupPolicy = PopupPolicy.auto,
    this.headlessRenderScale = 1.0,
    this.arguments = const <String>[],
    this.environment = const <String, String>{},
    this.clipboard,
    this.dragAndDrop,
    this.textInput,
    this.onError,
    this.onDiagnostic,
  }) : assert(headlessRenderScale > 0);

  /// Builds the common application options directly from process arguments.
  ///
  /// Recognised flags are `--dark`, `--light`, `--gpu`, `--cpu`,
  /// `--headless`, `--scale N` and `--frames N`. Backend and presentation
  /// flags remain in [arguments] and are interpreted by the ordinary selection
  /// machinery, so there is only one precedence rule for them.
  factory ApplicationOptions.fromArguments(
    List<String> arguments, {
    String title = 'dart_ui',
    Size size = const Size(800, 600),
    bool visible = false,
    Color? clearColor,
    bool showDevOverlay = false,
    Duration devOverlayInterval = const Duration(milliseconds: 500),
    Duration idleTimeout = const Duration(milliseconds: 250),
    int frameBudget = 0,
    String? requestedBackend,
    String? requestedPresentation,
    List<String> preferredBackends = const <String>[],
    List<String> preferredPresentations = const <String>[],
    Set<Capability> requiredCapabilities = const <Capability>{
      Capability.window,
    },
    bool allowExperimentalBackends = false,
    bool suspendWhenDeactivated = false,
    bool exitWhenLastWindowClosed = true,
    bool liveResize = true,
    Size? minimumSize,
    Size? maximumSize,
    Color? windowBackgroundColor,
    Capability? gpuPresentationCapability = kGpuPresentationCapability,
    RenderingPolicy renderingPolicy = RenderingPolicy.auto,
    RenderPolicy renderPolicy = RenderPolicy.defaults,
    ThemeData theme = ThemeData.neutralLight,
    TextDirection textDirection = TextDirection.leftToRight,
    PopupPolicy popupPolicy = PopupPolicy.auto,
    double headlessRenderScale = 1.0,
    Map<String, String> environment = const <String, String>{},
    Clipboard? clipboard,
    DragDropBackend? dragAndDrop,
    TextInputBackend? textInput,
    void Function(FrameworkError error)? onError,
    void Function(BackendDiagnostic diagnostic)? onDiagnostic,
  }) {
    final bool dark = arguments.contains('--dark');
    final bool light = arguments.contains('--light');
    if (dark && light) {
      throw ArgumentError('use only one of --dark and --light');
    }
    final bool gpu = arguments.contains('--gpu');
    final bool cpu = arguments.contains('--cpu');
    if (gpu && cpu) {
      throw ArgumentError('use only one of --gpu and --cpu');
    }

    final String? framesValue = _argumentValue(arguments, '--frames');
    final int parsedFrames = framesValue == null
        ? frameBudget
        : _parseNonNegativeInt(framesValue, '--frames');
    final String? scaleValue = _argumentValue(arguments, '--scale');
    final double parsedScale = scaleValue == null
        ? headlessRenderScale
        : _parsePositiveDouble(scaleValue, '--scale');
    final String? backendArgument = _argumentValue(arguments, '--backend');
    final bool headless = arguments.contains('--headless');
    if (headless && backendArgument != null && backendArgument != 'headless') {
      throw ArgumentError('--headless conflicts with --backend '
          '$backendArgument');
    }
    if (headless &&
        requestedBackend != null &&
        requestedBackend != 'headless') {
      throw ArgumentError('--headless conflicts with requestedBackend '
          '$requestedBackend');
    }

    return ApplicationOptions(
      title: title,
      size: size,
      visible: visible,
      clearColor: clearColor,
      showDevOverlay: showDevOverlay,
      devOverlayInterval: devOverlayInterval,
      idleTimeout: idleTimeout,
      frameBudget: parsedFrames,
      requestedBackend: headless ? 'headless' : requestedBackend,
      requestedPresentation: requestedPresentation,
      preferredBackends: preferredBackends,
      preferredPresentations: preferredPresentations,
      requiredCapabilities: requiredCapabilities,
      allowExperimentalBackends: allowExperimentalBackends,
      suspendWhenDeactivated: suspendWhenDeactivated,
      exitWhenLastWindowClosed: exitWhenLastWindowClosed,
      liveResize: liveResize,
      minimumSize: minimumSize,
      maximumSize: maximumSize,
      windowBackgroundColor: windowBackgroundColor,
      gpuPresentationCapability: gpuPresentationCapability,
      renderingPolicy: gpu
          ? RenderingPolicy.gpuOnly
          : cpu
              ? RenderingPolicy.cpuOnly
              : renderingPolicy,
      renderPolicy: renderPolicy,
      theme: dark
          ? ThemeData.neutralDark
          : light
              ? ThemeData.neutralLight
              : theme,
      textDirection: textDirection,
      popupPolicy: popupPolicy,
      headlessRenderScale: parsedScale,
      arguments: List<String>.unmodifiable(arguments),
      environment: environment,
      clipboard: clipboard,
      dragAndDrop: dragAndDrop,
      textInput: textInput,
      onError: onError,
      onDiagnostic: onDiagnostic,
    );
  }

  final String title;

  /// Initial client size of the first window, in logical units.
  final Size size;

  /// Whether the first window is mapped at creation.
  ///
  /// Defaults to false, and [Application.run] calls `show()` itself. A window
  /// that appears before its first frame flashes whatever the platform put in
  /// it, which on Windows is the desktop behind it. Windows opened later with
  /// [Application.openWindow] default to visible, because by then the loop is
  /// running and the first frame follows immediately.
  final bool visible;

  /// The renderer clear colour, or null to leave whatever
  /// the previous frame left. Null is only safe when the tree paints an opaque
  /// background of its own - the gallery does.
  final Color? clearColor;

  final bool showDevOverlay;

  /// How stale the overlay's numbers may get before a frame is drawn purely to
  /// refresh them. The overlay is the one thing on screen that changes with no
  /// input, so without this it turns a static window into a busy loop that
  /// repaints forever *because* it is measuring how long repainting takes.
  final Duration devOverlayInterval;

  /// How long [Application.run] blocks in the platform's event wait when there
  /// is nothing to draw. A long timeout costs no latency - the wait returns
  /// the instant a message arrives - it only stops the loop spinning.
  final Duration idleTimeout;

  /// Stop after this many presented frames, counted across every window; 0 runs
  /// until the application closes. What makes an example runnable in CI.
  final int frameBudget;

  /// Pin the windowing backend by name. Beaten only by nothing; see
  /// [resolveSelectionOverride] for how `--backend` and `DART_UI_BACKEND`
  /// rank below it.
  final String? requestedBackend;

  final String? requestedPresentation;

  /// Declared preference, section 5.1: names hoisted to the front of the
  /// candidate list before the scan.
  final List<String> preferredBackends;
  final List<String> preferredPresentations;

  /// What the windowing backend must report. A window is the floor.
  final Set<Capability> requiredCapabilities;

  final bool allowExperimentalBackends;

  /// Whether losing window activation suspends that window's frame loop.
  ///
  /// Off by default: a background window that stops animating is correct for a
  /// game and wrong for a text editor with a blinking caret, and the framework
  /// cannot know which it is in. When on, the *application* only suspends once
  /// every one of its windows is inactive, since a second window of the same
  /// application taking focus is not the application going away.
  final bool suspendWhenDeactivated;

  /// Whether the application ends when its last window closes.
  ///
  /// **True by default**, which is the desktop-application answer: the last
  /// window going away moves the application to
  /// [ApplicationLifecycleState.closing], [Application.run] returns, and the
  /// caller disposes.
  ///
  /// False is the tray-icon / background-agent answer: the application stays
  /// [ApplicationLifecycleState.running] with no windows at all, keeps its
  /// backend, clipboard and scheduled work, and may [Application.openWindow]
  /// again later. Note the backend still has the final word on the *loop*:
  /// [WindowingBackend.pumpEvents] returns false when the platform asks the
  /// application to stop, and the headless backend reports that as soon as it
  /// has no windows - so a windowless headless application must be driven by
  /// hand rather than by [Application.run].
  final bool exitWhenLastWindowClosed;

  /// Whether a window may draw a whole frame from inside the platform's own
  /// resize handler.
  ///
  /// **True by default**, and the default is the interesting half.
  ///
  /// ### What it costs
  ///
  /// One complete frame - build, layout, paint, present - per resize message,
  /// on the thread the window manager is dragging, with no chance to coalesce
  /// two messages into one frame the way the ordinary loop does. Windows sends
  /// a `WM_SIZE` per mouse movement during a drag, so this is a frame per
  /// mouse movement.
  ///
  /// `example/benchmark_live_resize.dart` measures both sides of it on the
  /// gallery tree, through the real `WndProc` of a real HWND. On this machine,
  /// 200 synthetic resize messages under `dart run` (JIT, no AOT):
  ///
  /// ```
  /// liveResize=on   5883 us per WM_SIZE   200 frames   ~170 fps
  /// liveResize=off    49 us per WM_SIZE     0 frames
  /// ```
  ///
  /// So the frame is the whole difference - 5.8 ms of it - and the number that
  /// decides is not the ratio but the absolute: 5.8 ms is comfortably inside a
  /// 16.7 ms frame, so a drag of this tree stays above 60 fps while drawing
  /// every step. A tree that takes 30 ms to lay out would make the same drag
  /// feel like 30 fps, and *that* is the application this option exists for.
  ///
  /// ### Why it is on anyway
  ///
  /// Because the alternative is not "a cheaper resize", it is **no resize**.
  /// Dragging a border on Windows runs a modal loop inside the OS, and while
  /// it runs the Dart event loop does not: not slowly, at all. Every frame the
  /// framework would normally draw is queued behind a `DispatchMessageW` that
  /// does not return until the user lets go of the mouse. So with this off, the
  /// window shows the pixels it had when the drag started for the whole drag,
  /// and the strip it grows into shows [windowBackgroundColor]. That is a
  /// correct, cheap, and visibly unfinished window; every other desktop toolkit
  /// pays this cost, and a framework whose windows do not repaint while being
  /// resized reads as broken rather than as fast.
  ///
  /// Turn it off for a tree whose frame is too expensive to run at pointer
  /// rate, or when the platform's own frame is the only thing that must stay
  /// responsive. See [LiveResizeWindow] for the mechanism and for what a
  /// backend has to implement to offer it; a backend that offers nothing
  /// ignores this flag rather than failing.
  final bool liveResize;

  /// The smallest and largest client area the user may drag a window to, in
  /// logical units, or null for the platform's own bounds. Applied to every
  /// window [openWindow] creates unless that call overrides them.
  ///
  /// Worth setting on any real application: without a minimum, a window can be
  /// dragged down to a client area a few pixels tall, and every layout below
  /// then runs against constraints nothing was designed for.
  final Size? minimumSize;
  final Size? maximumSize;

  /// What the platform paints where no frame has drawn yet - the strip a
  /// window grows into mid-resize, and the client area before the first frame.
  ///
  /// Null uses the system's window colour. Distinct from [clearColor], which is
  /// what the *renderer* clears the framebuffer to: this one is used at moments
  /// when there is no framebuffer covering the pixel at all, which is exactly
  /// when [clearColor] cannot help.
  ///
  /// Set it to the tree's own background and a resize stops showing a colour
  /// the application never chose.
  final Color? windowBackgroundColor;

  /// Passed through to [selectPresentation]. Defaults to
  /// [kGpuPresentationCapability]. Set [renderingPolicy] to
  /// [RenderingPolicy.cpuOnly] to require software rendering. A null value is
  /// reserved for hosts that have not wired a GPU capability vocabulary and
  /// therefore cannot verify GPU candidates.
  final Capability? gpuPresentationCapability;

  /// Whether presentation may use GPU paths, CPU paths, or the ranked
  /// GPU-first chain supplied by the resolver.
  final RenderingPolicy renderingPolicy;

  /// Budgets, the quality trade and the per-strategy kill switches.
  ///
  /// Deliberately *not* the same thing as [renderingPolicy], which chooses a
  /// presentation path - CPU or GPU - before a frame exists. This one is about
  /// what the GPU renderer does once it has one, and it never chooses a
  /// backend: see [RenderPolicy] for why "pick your renderer" is the wrong
  /// shape for a decision that varies per draw inside one frame.
  ///
  /// [Application.start] installs it into [RenderPolicyScope] and reports
  /// anything it changed through [onDiagnostic], so a support log names the
  /// routes an operator turned off.
  final RenderPolicy renderPolicy;

  /// Defaults installed by the framework-owned [DartUiApp] wrapper.
  final ThemeData theme;
  final TextDirection textDirection;

  /// Whether menus, dropdowns and tooltips get windows of their own.
  ///
  /// [PopupPolicy.auto] is the default and the value almost every application
  /// should keep: a window when [Application.canOpenPopupWindows] says the
  /// backend has one to give, the owner's own surface otherwise. The other two
  /// exist because the trade is real in both directions and neither answer is
  /// safe to guess for somebody else - an application recording its window to
  /// a video wants [PopupPolicy.inTree] so the menu is *in* the recording, and
  /// one whose menus must never be cropped wants [PopupPolicy.window] and
  /// wants to be told, not silently accommodated, when it cannot have them.
  ///
  /// [PopupPolicy.window] on a backend that has no popup windows therefore
  /// throws [PopupWindowUnavailableError] out of [Application.openWindow] -
  /// and so out of [Application.start], since that is where the first window
  /// is opened. Failing at startup is the whole point: an application that
  /// asked for windows because being cropped is unacceptable to it must not
  /// discover at the first menu that it quietly got overlays.
  final PopupPolicy popupPolicy;

  /// Pixel scale used when the automatically selected backend is headless.
  /// Native windows obtain their scale from the operating system.
  final double headlessRenderScale;

  /// The process arguments, consulted for `--backend` and `--presentation`.
  final List<String> arguments;

  /// The environment, consulted for [kBackendEnvironmentVariable] and
  /// [kPresentationEnvironmentVariable].
  ///
  /// Empty by default rather than `Platform.environment`, so that a test is
  /// never at the mercy of a variable exported in the shell that launched it.
  /// A `main` that wants the real environment passes it.
  final Map<String, String> environment;

  /// Overrides the clipboard the widget tree would otherwise get.
  ///
  /// **Null is the normal value and no longer means "no clipboard".** The
  /// selected backend supplies one when it is a [ClipboardProvider] - the Win32
  /// and headless backends are - so the default path copies and pastes with
  /// nothing configured here. See [Application.clipboard] for the full order.
  ///
  /// Setting it is for the cases where the backend's answer is not the one
  /// wanted: a test that needs a clipboard which fails on demand while the rest
  /// of the application runs on the real backend, an application that routes
  /// copy through its own history, or a backend that has no clipboard yet.
  final Clipboard? clipboard;

  /// Overrides the drag and drop the widget tree would otherwise get.
  ///
  /// Null is the normal value and means "the selected backend's", exactly as
  /// [clipboard] does. Setting it is for a test that wants a [FakeDragDrop] in
  /// an application otherwise running on the real backend, or for an
  /// application that routes drops through its own policy.
  final DragDropBackend? dragAndDrop;

  /// Overrides the input method the widget tree would otherwise get.
  ///
  /// Null is the normal value and means "the selected backend's", exactly as
  /// [clipboard] and [dragAndDrop] do. Setting it is for a test that wants a
  /// scripted input method in an application otherwise running on the real
  /// backend.
  final TextInputBackend? textInput;

  /// Where a build/layout/paint failure goes. Null installs a reporter that
  /// contains the error - the frame still draws, minus the failed subtree -
  /// and records it in [Application.errors].
  final void Function(FrameworkError error)? onError;

  /// Where a non-fatal presentation failure goes.
  final void Function(BackendDiagnostic diagnostic)? onDiagnostic;
}

String? _argumentValue(List<String> arguments, String flag) {
  for (var index = 0; index < arguments.length; index++) {
    final String argument = arguments[index];
    if (argument.startsWith('$flag=')) {
      final String value = argument.substring(flag.length + 1);
      if (value.isEmpty) {
        throw ArgumentError('$flag requires a value');
      }
      return value;
    }
    if (argument == flag) {
      if (index + 1 >= arguments.length ||
          arguments[index + 1].startsWith('-')) {
        throw ArgumentError('$flag requires a value');
      }
      return arguments[index + 1];
    }
  }
  return null;
}

int _parseNonNegativeInt(String source, String flag) {
  final int? value = int.tryParse(source);
  if (value == null || value < 0) {
    throw ArgumentError.value(source, flag, 'expected a non-negative integer');
  }
  return value;
}

double _parsePositiveDouble(String source, String flag) {
  final double? value = double.tryParse(source);
  if (value == null || !value.isFinite || value <= 0) {
    throw ArgumentError.value(
        source, flag, 'expected a finite positive number');
  }
  return value;
}

/// Mounts a widget tree on a real window and runs it to completion.
///
/// The three lines that replace the old 286:
///
/// ```dart
/// final app = await runApp(
///   Gallery(model: GalleryModel()),
///   backends: <WindowingBackendEntry>[
///     WindowingBackendEntry(name: 'win32', create: Win32WindowingBackend.new),
///   ],
/// );
/// ```
///
/// Returns the [Application] *after* it has been torn down, so a caller can
/// still read [Application.framesPresented] and friends for a summary. Use
/// [Application.start] instead when the loop needs to be driven by hand, or
/// when more than one window is wanted - [Application.openWindow] needs a
/// started application to open into.
Future<Application> runApp(
  Widget rootWidget, {
  required List<WindowingBackendEntry> backends,
  List<PresentationPathEntry> presentations = const <PresentationPathEntry>[],
  ApplicationOptions options = const ApplicationOptions(),
}) async {
  final application = await Application.start(
    rootWidget: rootWidget,
    backends: backends,
    presentations: presentations,
    options: options,
  );
  final completion = Completer<void>();
  try {
    runZonedGuarded<void>(
      () {
        application.run().then<void>(
          (_) {
            if (!completion.isCompleted) completion.complete();
          },
          onError: (Object error, StackTrace stackTrace) {
            application._reportUnhandledAsync(error, stackTrace);
            if (!completion.isCompleted) completion.complete();
          },
        );
      },
      application._reportUnhandledAsync,
    );
    await completion.future;
  } finally {
    application.dispose();
    await application.closed;
  }
  return application;
}

/// One window of an [Application]: its surface, its owners and its tree.
///
/// Everything here is per window on purpose; see the library comment for why
/// the [BuildOwner] and the [PipelineOwner] cannot be shared even if somebody
/// wanted to share them.
///
/// Disposal is the ordered release of the four things this window acquired,
/// newest first: the event subscription, the build owner, the scheduler, the
/// window host (and with it the presenter), and finally the native window. It
/// is idempotent, so closing a window that the platform has already destroyed
/// is a no-op rather than a second `DestroyWindow`.
final class ApplicationWindow with DisposableMixin {
  ApplicationWindow._({
    required this.application,
    required this.nativeWindow,
    required this.host,
    required this.scheduler,
    required this.buildOwner,
    required this.ownerId,
    required this.kind,
    required this.isModal,
    required this.clearColor,
    required DisposableBag resources,
    required Widget rootWidget,
  })  : _resources = resources,
        _rootWidget = rootWidget;

  /// The application this window belongs to. Windows are never freestanding:
  /// the backend, the clipboard and the focus arbitration all live up there.
  final Application application;

  final NativeWindow nativeWindow;
  final WindowHost host;
  final FrameScheduler scheduler;
  final BuildOwner buildOwner;

  /// The window that owns this one, or null for a top-level window.
  final NativeWindowId? ownerId;

  /// What this window is: an ordinary window, a dialog, a menu or a tooltip.
  ///
  /// Read by three separate rules and worth stating once: only a
  /// [WindowKind.normal] window counts for
  /// [ApplicationOptions.exitWhenLastWindowClosed]; only a window whose kind
  /// [WindowKind.takesActivation] is activated when shown; and a
  /// [WindowKind.isDismissable] window closes when focus moves away from it.
  final WindowKind kind;

  /// Whether this window blocks input to its owner while it lives.
  final bool isModal;

  /// This window's clear colour, defaulting to the application's.
  final Color? clearColor;

  /// What kind of popup this window *is*, or null when it is not one.
  ///
  /// [kind] already says the window is a [WindowKind.popup] or a
  /// [WindowKind.tooltip]; this says which of the four popups the framework
  /// distinguishes it is, and the difference decides routing rather than
  /// decoration. A [PopupKind.menu] swallows the press that dismisses it and a
  /// [PopupKind.dropdown] lets it through; a [PopupKind.tooltip] never takes
  /// the keyboard while the other three do. None of that is derivable from
  /// [WindowKind], which is why the value is recorded here at
  /// [Application.openPopup] time instead of being re-guessed by every rule
  /// that needs it - and a rule that guessed would be a menu that pressed the
  /// button behind it.
  PopupKind? popupKind;

  /// Where this window's popups go, resolved once and then reused.
  ///
  /// Null means "no host of the application's own": [DartUiApp] then lets
  /// [PopupScope] own an [InTreePopupHost], which is the portable answer and
  /// the only possible one on a backend with no popup windows.
  ///
  /// Assigned directly by [Application.openPopup] for a popup *window*, before
  /// its tree has mounted, so that a submenu opened from inside it chains onto
  /// the popup it was opened from rather than starting a second, unrelated
  /// chain anchored to the top-level window. Getting that wrong is not
  /// cosmetic: xdg-shell requires the parent of an `xdg_popup` to be the
  /// immediately preceding popup, and a wrong parent is a protocol error that
  /// takes the whole connection - every window of the process - down with it.
  PopupHost? _popupHost;
  bool _popupHostResolved = false;

  /// Called from [Application._retire] when this popup window goes away by any
  /// route at all - closed explicitly, dismissed with its owner, taken by a
  /// `popup_done` from the compositor. It is what makes
  /// `PopupSpec.onDismiss` fire exactly once however the popup died, and it
  /// lives on the window rather than in a list on the application because the
  /// window is the thing whose lifetime it describes.
  void Function()? _onPopupWindowRetired;

  final DisposableBag _resources;

  Widget _rootWidget;
  DisplayList? _painted;
  FrameworkError? _pendingFrameworkError;
  bool _rootMounted = false;
  MediaQueryData? _mountedMediaQueryData;
  bool _needsFrame = true;
  bool _inFrame = false;
  bool _minimised = false;
  bool _active = false;
  Timer? _animationWakeTimer;
  bool _animationFrameDue = false;
  int _framesPresented = 0;
  int _controlCount = 0;
  int _semanticNodeCount = 0;

  /// Live modal children. A list rather than a single reference because a
  /// dialog may itself open a modal dialog, and the innermost one is the one
  /// that holds the keyboard.
  final List<ApplicationWindow> _modalChildren = <ApplicationWindow>[];

  /// How many settle passes one frame may take before it is declared
  /// divergent.
  ///
  /// A settled frame is not one build plus one layout. The virtualized list
  /// realizes items against an *estimated* viewport until layout measures the
  /// real one, then rebuilds with the true window - two passes, legitimately.
  /// A tree that never settles is a bug that must be a message rather than a
  /// hang.
  static const int _maxSettlePasses = 8;

  /// Stable for this window's lifetime, and the value every [PlatformWindowEvent]
  /// carries. This is what routing keys off.
  NativeWindowId get id => nativeWindow.id;

  PipelineOwner get pipelineOwner => scheduler.pipelineOwner;
  ManualDispatcher get dispatcher => scheduler.dispatcher;

  /// The widget currently mounted at the root, before the shell's own wrappers.
  Widget get rootWidget => _rootWidget;

  /// Frames this window actually put on screen.
  int get framesPresented => _framesPresented;

  /// Frames this window began and then dropped because its surface moved.
  int get framesRejected => host.framesRejected;

  bool get needsFrame => _needsFrame;

  /// Whether this window is waiting for the next animation pulse.
  ///
  /// The application loop uses this to shorten its native event wait. A Dart
  /// [Timer] cannot fire while the isolate is synchronously blocked inside
  /// `pumpEvents`, so waiting the ordinary 250 ms idle interval would turn a
  /// nominal 60 Hz animation into a visibly frozen 4 Hz one.
  bool get hasPendingAnimationFrame =>
      _animationWakeTimer != null || scheduler.hasArmedNextFrame;

  /// Whether the platform says this window has the keyboard.
  ///
  /// Distinct from [hasKeyboardFocus]: this is the last activation the platform
  /// reported for *this* window, while [hasKeyboardFocus] is the application's
  /// arbitration across all of them. They agree except in the instant between a
  /// deactivation and the matching activation.
  bool get isActive => _active;

  /// Whether this window is the one the application routes key and text events
  /// to.
  bool get hasKeyboardFocus => application.keyboardFocusWindow == id;

  /// Whether a live modal child is blocking this window's input.
  bool get isBlocked => _modalChildren.any((w) => !w.isDisposed);

  /// The innermost live modal descendant, or null.
  ApplicationWindow? get activeModal {
    for (final ApplicationWindow child in _modalChildren) {
      if (child.isDisposed) continue;
      return child.activeModal ?? child;
    }
    return null;
  }

  /// Whether this window would draw if asked.
  ///
  /// False while minimised, while its client area is empty, and - only when
  /// [ApplicationOptions.suspendWhenDeactivated] is set - while it is inactive.
  bool get isSuspended {
    if (isDisposed) return true;
    if (_minimised || !host.isPresentable) return true;
    return application.options.suspendWhenDeactivated && !_active;
  }

  /// Build failures contained by this window's reporter rather than propagated.
  List<FrameworkError> get errors => buildOwner.errorReporter.errors;

  /// Framework-owned controls in this window's render tree.
  ///
  /// Snapshotted during teardown so the number survives it - which is what
  /// makes "no native control anywhere in the tree" a checkable claim rather
  /// than a promise.
  int get controlCount =>
      isDisposed ? _controlCount : _countControls(buildOwner.renderRoot);

  int get semanticNodeCount => isDisposed
      ? _semanticNodeCount
      : buildOwner.buildSemantics().nodes.length;

  /// Execution mode and the renderer actually attached to this window.
  ApplicationRuntimeInfo get runtimeInfo {
    final PresentationCandidate presentation =
        application.presentationSelection.chosen!;
    return ApplicationRuntimeInfo(
      dartRuntimeMode: DartRuntimeMode.current,
      windowingBackend: application.windowingSelection.chosen!.name,
      presentationBackend: presentation.name,
      presentationKind: presentation.kind,
      renderer: host.presenter.info,
      renderScale: host.renderScale,
      desktopScale: host.desktopScale,
    );
  }

  /// Replaces this window's root widget. Reconciles rather than remounting
  /// when the widget type and key allow it, so state survives a theme change.
  void updateRoot(Widget widget) {
    throwIfDisposed();
    _rootWidget = widget;
    if (_rootMounted) buildOwner.updateRoot(_mountableRoot);
    requestFrame();
  }

  /// The root as the tree actually mounts it.
  ///
  /// Wrapped in a [ClipboardScope] here rather than left to the caller for the
  /// same reason the theme is inherited rather than passed: every text field
  /// needs the clipboard, none of them should be handed one by its parent, and
  /// an application that forgot the wrapper would have a Ctrl+V that silently
  /// did nothing in half its screens. The clipboard is the *application's*, so
  /// every window of one application pastes from the same place.
  /// The [ContextMenuScope] is **per window**, unlike the clipboard.
  ///
  /// The clipboard is the application's, so one instance serves every window.
  /// A context menu is a popup with a position, and a position only means
  /// anything inside one window: two windows showing one menu would fight over
  /// where it is, and closing the window that owns it would leave the other
  /// pointing at a dismissed popup. So each window gets its own controller,
  /// which also means dismissing a menu in one window cannot dismiss another's.
  ///
  /// Installed here rather than left to the caller for the reason the clipboard
  /// is: a `TextField` outside a scope answers a right-click by moving the
  /// caret and opening nothing, which reads as a broken field rather than as a
  /// missing wrapper. An application that wants a different presentation - a
  /// real popup window, once windows are cheap enough to use for menus - passes
  /// its own scope further down; the nearest one wins.
  MediaQueryData get _mediaQueryData => MediaQueryData(
        size: host.logicalSize,
        devicePixelRatio: host.renderScale,
      );

  /// The host this window's menus, dropdowns and tooltips open into.
  ///
  /// Resolved lazily and exactly once, on the first mount, rather than in
  /// [Application.openWindow]: a popup window's host is handed to it by
  /// [Application.openPopup] *after* the window exists, and resolving eagerly
  /// would have already given it a root host of its own - a second chain, with
  /// the broken platform parentage [_popupHost] describes.
  PopupHost? get popupHost {
    if (_popupHostResolved) return _popupHost;
    _popupHostResolved = true;
    _popupHost ??= application._popupHostFor(this);
    return _popupHost;
  }

  /// Builds and lays this window's tree out against [constraints] without
  /// presenting anything, and answers the size its root chose.
  ///
  /// The whole of popup auto-sizing. A window's root constraints are normally
  /// `BoxConstraints.tight(clientSize)`, so a popup window created at a
  /// guessed size would be laid out *against the guess* and would report the
  /// guess back - measuring nothing. Handing the root a loose constraint
  /// instead is the only way to ask a menu how tall it wants to be.
  ///
  /// It is the build-and-lay-out half of a frame and nothing else: the same
  /// `buildScope` + `flushLayout` pair [_settleForInput] runs before a hit
  /// test, reached through the same [BuildOwner], so a popup is measured by
  /// the code path that will later draw it rather than by a second one that
  /// could disagree with it. Nothing is painted and nothing is presented,
  /// which is what lets the window still be hidden while this runs.
  ///
  /// Returns [Size.zero] when the tree has no root render object, which is a
  /// tree that renders nothing; the caller then keeps whatever size it asked
  /// for rather than creating a zero-sized window the platform would refuse.
  Size measureRoot(BoxConstraints constraints) {
    throwIfDisposed();
    pipelineOwner.rootConstraints = constraints;
    if (!_rootMounted) {
      buildOwner.updateRoot(_mountableRoot);
      _rootMounted = true;
    }
    buildOwner.buildScope();
    pipelineOwner.flushLayout();
    final RenderBox? root = buildOwner.renderRoot;
    if (root == null || !root.hasSize) return Size.zero;
    return root.size;
  }

  Widget get _mountableRoot {
    final MediaQueryData media = _mediaQueryData;
    _mountedMediaQueryData = media;
    return MediaQuery(
      data: media,
      child: ApplicationInfo(
        data: runtimeInfo,
        child: ClipboardScope(
          clipboard: application.clipboard,
          child: DragDropScope(
            dragAndDrop: application.dragAndDrop,
            // The window as well as the backend: starting a drag needs an
            // origin, and this is the only place in the tree that knows what
            // window it is in. See [DragDropScope.window].
            window: nativeWindow,
            child: TextInputScope(
              textInput: application.textInput,
              // The window again, and for a stronger reason than the drag's:
              // a composition belongs to one HWND or one wl_surface, so a
              // field that could not name its window would have nothing to
              // attach an input method to.
              window: nativeWindow,
              child: ContextMenuScope(
                child: DartUiApp(
                  theme: application.options.theme,
                  textDirection: application.options.textDirection,
                  frameScheduler: scheduler,
                  // Null on a backend with no popup windows, and null is not a
                  // degraded answer: `PopupScope` then owns an
                  // `InTreePopupHost` and every menu still opens, composited
                  // into this window's own surface. See [popupHost].
                  popupHost: popupHost,
                  home: _rootWidget,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Replaces only the framework-owned root wrappers when window metrics move.
  ///
  /// The application widget remains the same object, so its element and every
  /// state below it survive a resize or DPI change. Dependents of [MediaQuery]
  /// rebuild through the ordinary inherited-widget path.
  void _syncMediaQuery() {
    if (!_rootMounted) return;
    if (_mountedMediaQueryData == _mediaQueryData) return;
    buildOwner.updateRoot(_mountableRoot);
  }

  /// Marks this window's next frame dirty. Idempotent; many mutations coalesce
  /// into one. Never touches any other window - that is the whole point of the
  /// per-window owners.
  void requestFrame() {
    if (isDisposed) return;
    _needsFrame = true;
  }

  void _requestFrameFromTree() {
    if (_inFrame) return;
    requestFrame();
  }

  void _scheduleAnimationWake(Duration delay) {
    if (isDisposed || _animationWakeTimer != null) return;
    _animationWakeTimer = Timer(delay, () {
      _animationWakeTimer = null;
      if (isDisposed) return;
      _animationFrameDue = true;
      requestFrame();
      // The application loop may currently be blocked inside the native
      // backend's event wait. Marking the frame dirty is not enough in that
      // case: no Dart code gets another turn until a platform event arrives.
      // Wake the wait explicitly so timer-driven animations keep moving even
      // while the user is completely idle.
      application.backend.wake();
    });
  }

  void _consumeAnimationFrame() {
    if (!_animationFrameDue || !scheduler.hasArmedNextFrame) return;
    _animationFrameDue = false;
    final Duration due = scheduler.dispatcher.nextTimerDue ??
        scheduler.dispatcher.elapsed + scheduler.frameInterval;
    final Duration remaining = due - scheduler.dispatcher.elapsed;
    scheduler.advance(remaining.isNegative ? Duration.zero : remaining);
  }

  /// Asks the platform to give this window the keyboard, and records the move.
  void focus() => application.focusWindow(id);

  /// Closes this window. Idempotent; equivalent to
  /// `application.closeWindow(id)`.
  void close() => application.closeWindow(id);

  /// Brings the tree up to date enough to be hit-tested.
  ///
  /// Cheap when nothing is dirty, which is the common case: `buildScope` over
  /// an empty dirty list and `flushLayout` over a clean tree both return
  /// almost immediately.
  void _settleForInput() {
    if (_inFrame || !_rootMounted) return;
    buildOwner.buildScope();
    pipelineOwner.flushLayout();
  }

  /// Whether there is geometry for a pointer to be tested against.
  ///
  /// False in exactly one window of time and it is a real one: between the
  /// platform showing the window and this window's first frame. The platform
  /// delivers input the instant the window exists - a `WM_MOUSEMOVE` arrives
  /// for a window that merely appeared under a stationary cursor - while the
  /// tree is only mounted and laid out by [drawFrame]. Hit-testing then reaches
  /// a root whose `size` has never been computed, and `RenderBox.size` throws
  /// rather than inventing one, which is correct of it and fatal here: the
  /// throw escapes through a stream listener and takes the process down.
  ///
  /// So the event is dropped, counted, and a frame is requested. Dropped rather
  /// than queued because a pointer position is only meaningful against a
  /// layout, and the layout it would be tested against does not exist yet;
  /// whatever the pointer is over will be reported by the next move.
  bool get _isHitTestable {
    if (!_rootMounted) return false;
    final RenderBox? root = buildOwner.renderRoot;
    return root != null && root.hasSize;
  }

  /// Builds, lays out, paints and presents exactly one frame of this window.
  ///
  /// The build/layout/paint half is driven through [FrameScheduler]: this
  /// method flushes builds, then asks the scheduler for a frame and drains its
  /// dispatcher, which is what runs layout and paint and hands the finished
  /// display list back through `onFrame`. Doing layout directly here would
  /// leave the scheduler with a pipeline it no longer drives, and the two
  /// would disagree about whether a frame is pending.
  ///
  /// Only the *last* list of a settle sequence is presented. Presenting the
  /// intermediate ones would put the estimated-viewport pass of a virtualized
  /// list on screen - a visible flash of the wrong layout.
  Future<PresentResult> drawFrame() async {
    throwIfDisposed();
    if (_inFrame) {
      throw StateError(
        'ApplicationWindow.drawFrame() is not reentrant. A frame requested '
        'from inside a frame is coalesced into the next one; call '
        'requestFrame().',
      );
    }
    if (!host.isPresentable) {
      _needsFrame = true;
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame skipped; the window has no presentable client area',
        ),
      );
    }

    // Drawing is what makes an application running, whether the loop asked for
    // it or a test did. Leaving the state at `starting` after pixels have been
    // presented would make every later transition read from a lie.
    application._noteDrawing();
    _inFrame = true;
    _needsFrame = false;
    final stopwatch = Stopwatch()..start();
    try {
      if (!_rootMounted) {
        buildOwner.updateRoot(_mountableRoot);
        _rootMounted = true;
      }
      final build = stopwatch.elapsedMicroseconds;

      _painted = null;
      _consumeAnimationFrame();
      var pass = 0;
      while (true) {
        if (pass++ >= _maxSettlePasses) {
          throw StateError(
            'the frame did not settle in $_maxSettlePasses passes. A build is '
            'dirtying layout, or a layout is dirtying a build, in a cycle '
            'that cannot converge.',
          );
        }
        buildOwner.buildScope();
        scheduler.scheduleFrame();
        scheduler.pump();
        if (scheduler.lastErrorPhase != null) break;
        if (!buildOwner.hasScheduledBuilds && !pipelineOwner.needsLayout) break;
      }

      final list = _painted;
      if (list == null) {
        throw StateError(
          'the frame scheduler produced no display list. Its onFrame callback '
          'is the only path pixels take out of the pipeline.',
        );
      }
      final paint = stopwatch.elapsedMicroseconds - build;

      final frame = host.beginFrame();
      final result = await host.present(
        frame,
        list,
        clearColor: (clearColor ?? application.options.clearColor)?.value,
      );
      stopwatch.stop();
      // The list has left the building. Turning the ring here - once per
      // presented frame, never once per settle pass - is what lets the
      // scheduler rewind an arena instead of allocating one: the next frame
      // records into the *other* list, so a retained CPU presenter can still
      // replay this one into a replacement surface after a resize. See
      // `DisplayListPool`.
      //
      // Unconditional, including on a stale result that [WindowHost.present]
      // rejected before the presenter ever saw the list. That leaves the ring
      // one turn "ahead" of what a presenter is holding, and it is safe rather
      // than merely tolerable: recording a frame is entirely synchronous - the
      // only suspension point in this method is the `await` above - so a
      // retained replay can never observe a half-written arena. The worst it
      // can observe is a newer complete frame, and a rejected present has
      // already asked for one.
      scheduler.advanceDisplayList();

      if (result.status == PresentStatus.deviceLost) {
        // Not a retry of this frame: the device it was built against is gone.
        // Recover, then ask for a fresh one against the new device.
        final recovered = await host.recoverFromDeviceLoss();
        if (recovered) {
          requestFrame();
        } else {
          // One window's dead device is not the application's death. Closing
          // this window leaves the others drawing, and the last-window policy
          // decides whether that ends the process.
          close();
        }
        return result;
      }
      if (result.isSuccess) {
        _framesPresented++;
        application._recordFrame(FrameTiming(
          build: build,
          paint: paint,
          raster: stopwatch.elapsedMicroseconds - build - paint,
        ));
      } else if (result.status == PresentStatus.stale) {
        // The surface moved under the frame. Not an error and not a retry of
        // the same pixels: whatever invalidated the generation has already
        // requested a new frame against the new geometry.
        requestFrame();
      }
      _pumpAccessibility();
      return result;
    } finally {
      _inFrame = false;
    }
  }

  /// Publishes this frame's semantic tree, if anybody is reading it.
  ///
  /// After present rather than before, for the reason a screen reader would
  /// care about: the tree carries bounds, and announcing a control at
  /// coordinates that are not on screen yet is worse than announcing it one
  /// frame later. Layout has already run either way.
  ///
  /// Costs one map lookup on a machine with no assistive technology running -
  /// [AccessibilityHost.forWindow] answers null until a client has asked for
  /// this window - and a tree walk plus a diff when there is. Never throws
  /// into the frame: an accessibility failure is not a reason to lose the
  /// pixels, so it is reported like any other framework error and the frame
  /// stands.
  void _pumpAccessibility() {
    final NativeWindow window = nativeWindow;
    // Not every window has an operating-system handle to key on - see
    // [NativeHandleWindow], which is a separate capability on purpose - and a
    // window without one cannot be pointed at by an accessibility client
    // either, so there is nothing to publish.
    if (window is! NativeHandleWindow) return;
    final WindowAccessibility? published = platformAccessibility
        ?.forWindow((window as NativeHandleWindow).nativeHandle);
    if (published == null) return;
    try {
      published.pump();
    } catch (error, stackTrace) {
      buildOwner.errorReporter.report(FrameworkError(
        phase: FrameworkPhase.paint,
        cause: error,
        stackTrace: stackTrace,
        context: 'publishing the semantic tree to '
            '${platformAccessibility?.apiName ?? 'the platform'}',
      ));
    }
  }

  /// One whole frame with no suspension point anywhere in it.
  ///
  /// Installed on the native window as a [LiveResizeCallback] when
  /// [ApplicationOptions.liveResize] is on, and called *from inside the
  /// platform's resize handler* - which is the only reason it exists in this
  /// shape. [drawFrame] cannot be used there: it is `async`, and everything
  /// after its first `await` runs on a microtask that will not be scheduled
  /// until the platform's modal loop ends, so the pixels would land after the
  /// drag rather than during it. The `finally` that clears [_inFrame] is on the
  /// far side of that await too, which would leave the window believing a frame
  /// was in flight for the rest of the drag and refusing every later one.
  ///
  /// Three rules, all of them things that go wrong quietly:
  ///
  ///   * **it adopts the size it was handed** rather than waiting for the
  ///     [WindowResizedEvent]. That event is real and will arrive - queued on a
  ///     stream nobody is draining - and by then the drag is over;
  ///   * **it never re-enters.** A resize delivered while this is on the stack
  ///     (layout can call `SetWindowPos`, and Windows sends `WM_SIZE` from
  ///     inside it) is coalesced into a request for the next frame, the same
  ///     answer [drawFrame] gives, rather than a second frame on top of the
  ///     first. `ManualDispatcher` throws on exactly this, and a throw here
  ///     would cross an FFI boundary;
  ///   * **it respects the generation.** [WindowHost.presentNow] rejects a
  ///     frame begun before the surface it was begun against was replaced,
  ///     which during a drag is not a corner case: the size changes on every
  ///     message.
  ///
  /// Silent about failure by design - it has no caller to return to but the OS.
  /// A rejected or skipped frame leaves [needsFrame] set, so the ordinary loop
  /// draws it as soon as the drag lets go of the event loop.
  void drawFrameSynchronously({
    required Size logicalSize,
    required double renderScale,
  }) {
    if (isDisposed) return;
    if (_inFrame) {
      requestFrame();
      return;
    }
    if (!host.canPresentSynchronously) {
      requestFrame();
      return;
    }

    // Before anything is laid out: this is what the async path would have done
    // on the WindowResizedEvent, and it is also what invalidates the previous
    // generation, so a frame from before this resize can no longer present.
    host.surfaceChanged(logicalSize: logicalSize, renderScale: renderScale);
    if (!host.isPresentable) {
      _needsFrame = true;
      return;
    }
    pipelineOwner.rootConstraints = BoxConstraints.tight(logicalSize);
    _syncMediaQuery();

    application._noteDrawing();
    _inFrame = true;
    _needsFrame = false;
    final stopwatch = Stopwatch()..start();
    try {
      if (!_rootMounted) {
        buildOwner.updateRoot(_mountableRoot);
        _rootMounted = true;
      }
      final build = stopwatch.elapsedMicroseconds;

      _painted = null;
      _consumeAnimationFrame();
      var pass = 0;
      while (pass++ < _maxSettlePasses) {
        buildOwner.buildScope();
        scheduler.scheduleFrame();
        scheduler.pump();
        if (scheduler.lastErrorPhase != null) break;
        if (!buildOwner.hasScheduledBuilds && !pipelineOwner.needsLayout) break;
      }
      final list = _painted;
      if (list == null) {
        // Never throws out of here: the stack above this frame is the OS's.
        _needsFrame = true;
        return;
      }
      final paint = stopwatch.elapsedMicroseconds - build;

      final result = host.presentNow(
        host.beginFrame(),
        list,
        clearColor: (clearColor ?? application.options.clearColor)?.value,
      );
      stopwatch.stop();
      // Same rule as `drawFrame`, and it matters more here: this is the live
      // resize path, which is precisely when a retained presenter replays the
      // list it is holding.
      scheduler.advanceDisplayList();
      if (result.isSuccess) {
        _framesPresented++;
        application._recordFrame(FrameTiming(
          build: build,
          paint: paint,
          raster: stopwatch.elapsedMicroseconds - build - paint,
        ));
      } else {
        _needsFrame = true;
      }
      _pumpAccessibility();
    } finally {
      _inFrame = false;
    }
  }

  /// Receives the finished display list from [FrameScheduler].
  void _onPainted(DisplayList list) {
    final FrameworkError? error = _pendingFrameworkError;
    _pendingFrameworkError = null;
    if (error != null) {
      const FrameworkErrorBanner().paint(
        list,
        Rect.fromLTWH(0, 0, host.logicalSize.width, host.logicalSize.height),
        title: 'Erro de interface contido — o aplicativo continua aberto',
        detail: '${error.phase.name}: ${error.cause}',
      );
    }
    if (application.options.showDevOverlay) {
      DevOverlay(statistics: application.statistics).paint(
        list,
        Rect.fromLTWH(0, 0, host.logicalSize.width, host.logicalSize.height),
      );
    }
    _painted = list;
  }

  void _captureFrameworkError(FrameworkError error) {
    _pendingFrameworkError = error;
    final handler = application.options.onError;
    if (handler == null) return;
    try {
      handler(error);
    } catch (handlerError, stackTrace) {
      _pendingFrameworkError = FrameworkError(
        phase: FrameworkPhase.async,
        cause: handlerError,
        stackTrace: stackTrace,
        context: 'the ApplicationOptions.onError callback threw while '
            'reporting ${error.phase.name}',
      );
    }
  }

  void _onFrameError(
    FramePipelinePhase phase,
    Object error,
    StackTrace stackTrace,
  ) {
    buildOwner.errorReporter.report(FrameworkError(
      phase: switch (phase) {
        FramePipelinePhase.callbacks => FrameworkPhase.async,
        FramePipelinePhase.layout => FrameworkPhase.layout,
        FramePipelinePhase.paint => FrameworkPhase.paint,
      },
      cause: error,
      stackTrace: stackTrace,
      context: 'producing frame ${scheduler.frameNumber}',
    ));
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    buildOwner.errorReporter.report(FrameworkError(
      phase: FrameworkPhase.async,
      cause: error,
      stackTrace: stackTrace,
      context: 'the window event stream failed',
    ));
    requestFrame();
    application.backend.wake();
  }

  /// Releases everything this window acquired, last first, exactly once.
  @override
  void onDispose() {
    // Snapshotted while the tree is still alive; a summary is printed after it
    // is gone.
    _controlCount = _countControls(buildOwner.renderRoot);
    _semanticNodeCount = buildOwner.buildSemantics().nodes.length;
    _animationWakeTimer?.cancel();
    _animationWakeTimer = null;
    _resources.dispose();
    _painted = null;
    // A disposed window owes nobody a frame. Leaving this set would make
    // `needsFrame` outlive the thing that could satisfy it.
    _needsFrame = false;
    application._retire(this);
  }

  @override
  String toString() => 'ApplicationWindow(id: ${id.value}, '
      '${host.logicalSize.width}x${host.logicalSize.height}, '
      'frames: $_framesPresented'
      '${isModal ? ', modal' : ''}${isDisposed ? ', closed' : ''})';

  static int _countControls(RenderBox? root) {
    var count = 0;
    void walk(RenderBox node) {
      if (node is ControlBehavior) count++;
      node.visitChildren(walk);
    }

    if (root != null) walk(root);
    return count;
  }
}

/// The assembled application: backend, windows, renderers, trees, frame loop.
final class Application with DisposableMixin {
  Application._({
    required this.options,
    required this.backend,
    required this.windowingSelection,
    required this.presentationSelection,
    required PresentationPathEntry presentationPath,
    required List<PresentationPathEntry> presentationPaths,
    required Map<String, BackendProbeResult> presentationProbes,
    required DisposableBag resources,
    required List<String> teardownOrder,
    required SharedRenderDeviceRegistry devices,
  })  : _presentationPath = presentationPath,
        _presentationPaths = presentationPaths,
        _presentationProbes = presentationProbes,
        _resources = resources,
        _teardownOrder = teardownOrder,
        _devices = devices;

  /// Assembles everything, opens the first window, and stops short of the
  /// first frame.
  ///
  /// Throws [BackendSelectionError] when no windowing backend or no
  /// presentation path qualifies. The error carries every probe that was run,
  /// which is section 6.6's rule in its most literal form: the message names
  /// the library, symbol or device that was missing for each candidate, not
  /// just the fact that nothing worked.
  static Future<Application> start({
    required Widget rootWidget,
    required List<WindowingBackendEntry> backends,
    List<PresentationPathEntry> presentations = const <PresentationPathEntry>[],
    ApplicationOptions options = const ApplicationOptions(),
  }) async {
    if (backends.isEmpty) {
      throw ArgumentError.value(
        backends,
        'backends',
        'an application needs at least one windowing backend to choose from; '
            'the shell deliberately knows of none by name',
      );
    }
    final paths = presentations.isEmpty
        ? <PresentationPathEntry>[PresentationPathEntry.cpuRenderer()]
        : presentations;

    // Before any probe, because a kill switch has to be in force for the very
    // first frame a backend draws - and because reporting it beside the probes
    // is what makes a support log self-contained.
    RenderPolicyScope.install(options.renderPolicy);
    for (final BackendDiagnostic diagnostic
        in options.renderPolicy.describe()) {
      options.onDiagnostic?.call(diagnostic);
    }

    // --- 1. windowing backend ------------------------------------------
    final instances = <String, WindowingBackend>{};
    final candidates = <BackendCandidate>[];
    for (final entry in backends) {
      final instance = entry.create();
      instances[entry.name] = instance;
      candidates.add(BackendCandidate(
        name: entry.name,
        probe: instance.probe(),
        experimental: entry.experimental,
      ));
    }
    final windowingSelection = selectBackend(
      candidates,
      requested: options.requestedBackend,
      required: options.requiredCapabilities,
      allowExperimental: options.allowExperimentalBackends,
      preferred: options.preferredBackends,
      arguments: options.arguments,
      environment: options.environment,
    );
    if (!windowingSelection.isSuccess) throw windowingSelection.toError();
    final backend = instances[windowingSelection.chosen!.name]!;

    // --- 2. presentation path ------------------------------------------
    final Map<String, BackendProbeResult> presentationProbes =
        <String, BackendProbeResult>{
      for (final path in paths)
        path.name: path.probeForWindowingBackend(
          windowingSelection.chosen!.name,
        ),
    };
    final presentationSelection = selectPresentation(
      <PresentationCandidate>[
        for (final path in paths)
          PresentationCandidate(
            name: path.name,
            kind: path.kind,
            probe: presentationProbes[path.name]!,
            experimental: path.experimental,
          ),
      ],
      requested: options.requestedPresentation,
      preferred: options.preferredPresentations,
      allowExperimental: options.allowExperimentalBackends,
      arguments: options.arguments,
      environment: options.environment,
      gpuPresentationCapability: options.gpuPresentationCapability,
      renderingPolicy: options.renderingPolicy,
    );
    if (!presentationSelection.isSuccess) throw presentationSelection.toError();
    final path = paths.firstWhere(
      (entry) => entry.name == presentationSelection.chosen!.name,
    );

    // Acquisition order is teardown order, reversed. Registered as each step
    // succeeds so a failure half-way releases exactly what was built.
    final resources = DisposableBag();
    final teardown = <String>[];
    final devices = SharedRenderDeviceRegistry();
    late final Application application;

    try {
      await backend.initialize();
      resources.add(backend, () {
        teardown.add('backend');
        application._pendingShutdown = backend.shutdown();
      });
      // After the backend and therefore released before it, which is the only
      // order that works: a device is a driver object owned by this process
      // and disposing one after the windowing backend has shut down would be
      // a release against a connection that is already gone. It is a safety
      // net regardless - by the time this runs every window has released its
      // lease and the registry holds nothing.
      resources.add(devices, devices.dispose);

      application = Application._(
        options: options,
        backend: backend,
        windowingSelection: windowingSelection,
        presentationSelection: presentationSelection,
        presentationPath: path,
        presentationPaths: List<PresentationPathEntry>.unmodifiable(paths),
        presentationProbes: presentationProbes,
        resources: resources,
        teardownOrder: teardown,
        devices: devices,
      );

      // --- 3. the first window -----------------------------------------
      await application.openWindow(
        rootWidget: rootWidget,
        title: options.title,
        size: options.size,
        visible: options.visible,
      );
      return application;
    } on Object {
      resources.dispose();
      rethrow;
    }
  }

  final ApplicationOptions options;
  final WindowingBackend backend;

  /// The full windowing report - chosen, and every candidate passed over with
  /// the named reason. Worth logging on every startup, not only on failure.
  final BackendSelection windowingSelection;
  PresentationSelection presentationSelection;

  PresentationPathEntry _presentationPath;

  /// The path every window of this application attaches through.
  ///
  /// Not necessarily the one [presentationSelection] chose at startup: a first
  /// window whose attach fails demotes its path and picks the next, and this
  /// getter reports the one in force now.
  PresentationPathEntry get presentationPath => _presentationPath;

  final List<PresentationPathEntry> _presentationPaths;

  /// One GPU device per adapter, for every window of this application.
  ///
  /// The rule from section 3.7 of the popup plan and 8.1.1 of the roadmap -
  /// *um dispositivo, N swapchains* - lives here rather than in any backend.
  /// It was measured before it was written: on an Intel UHD at Direct3D 11,
  /// opening a menu cost 20.7 ms of `ID3D11Device` against 1.4 ms of HWND and
  /// 1.9 ms of swap chain, so a menu was paying seven eighths of its latency
  /// for a driver connection the window behind it already had open. The glyph
  /// atlas and the coverage cache hang off the device, so the second window
  /// also re-rasterised every glyph the first had already drawn.
  ///
  /// Reference counted, not application-lifetime: the device dies with the
  /// last window that was using it and is opened again if another opens later.
  final SharedRenderDeviceRegistry _devices;

  /// Where every window of this application gets its render device.
  RenderDeviceProvider get devices => _devices;

  final Map<String, BackendProbeResult> _presentationProbes;
  final DisposableBag _resources;
  final List<String> _teardownOrder;
  final FrameStatistics statistics = FrameStatistics();
  final Stopwatch _sinceOverlayRefresh = Stopwatch()..start();

  /// Live windows, in the order they were opened.
  final List<ApplicationWindow> _windows = <ApplicationWindow>[];
  final Map<NativeWindowId, ApplicationWindow> _byId =
      <NativeWindowId, ApplicationWindow>{};

  /// Errors from windows that have already been closed, so that
  /// `application.errors` stays a complete account of the run rather than of
  /// whatever happens to still be open.
  final List<FrameworkError> _retiredErrors = <FrameworkError>[];

  ApplicationWindow? _primary;
  NativeWindowId? _keyboardFocus;
  Future<void>? _pendingShutdown;
  ApplicationLifecycleState _state = ApplicationLifecycleState.starting;
  bool _runCalled = false;
  bool _tearingDown = false;

  /// The ceiling [run] currently gives the platform's event wait when nothing
  /// is drawing. Moved by [_noteLoopProgress], which is where the policy is.
  Duration _idlePumpWait = Duration.zero;

  /// Time spent outside the platform wait since it last returned: the yield,
  /// the frame, and whatever else one turn of [run]'s loop did.
  ///
  /// Subtracted from the next wait so that a slice is a *period* rather than a
  /// delay added on top of the work - a loop that waits a whole frame interval
  /// and then draws for nine milliseconds runs at 40 Hz, not at 60. It is a
  /// [Stopwatch] and not a clock: nothing about frame content, ordering or
  /// virtual time reads it, it only shortens a platform wait, and the headless
  /// backend ignores that wait entirely - so no test observes it.
  final Stopwatch _sincePumpReturned = Stopwatch();
  int _retiredFramesPresented = 0;
  int _retiredFramesRejected = 0;
  int _controlCount = 0;
  int _semanticNodeCount = 0;
  int _eventsDropped = 0;

  // ---------------------------------------------------------------------------
  // The window set
  // ---------------------------------------------------------------------------

  /// Every open window, in the order it was opened - menus and tooltips
  /// included.
  List<ApplicationWindow> get windows =>
      List<ApplicationWindow>.unmodifiable(_windows);

  /// The open windows that are *real* windows: [WindowKind.normal], no owner.
  ///
  /// This, and not [windows], is what
  /// [ApplicationOptions.exitWhenLastWindowClosed] counts. A menu, a tooltip
  /// or a dialog disappearing is not the application running out of windows,
  /// and a policy written against "the last window" instead of "the last
  /// top-level window" is how dismissing a popup ends up quitting the app.
  List<ApplicationWindow> get topLevelWindows => <ApplicationWindow>[
        for (final ApplicationWindow window in _windows)
          if (window.kind.isTopLevel && window.ownerId == null) window,
      ];

  /// The window with this id, or null when it never existed or has closed.
  ///
  /// Null rather than a throw: an event or a timer that names a window the
  /// user has already closed is *normal*, and making every caller guard is
  /// exactly how teardown crashes get written.
  ApplicationWindow? windowById(NativeWindowId id) => _byId[id];

  /// The first window still open, or - once none are - the last one that was
  /// first.
  ///
  /// This is what the single-window accessors ([window], [host], [buildOwner],
  /// [scheduler], [pipelineOwner]) mean. It survives teardown deliberately, so
  /// a summary can be printed from a disposed application.
  ApplicationWindow get primaryWindow {
    final primary = _primary;
    if (primary == null) {
      throw StateError(
        'this application has never had a window; Application.start always '
        'opens one, so reaching this means the object was built by hand',
      );
    }
    return primary;
  }

  /// The primary window's native window. See [primaryWindow].
  NativeWindow get window => primaryWindow.nativeWindow;

  /// The primary window's host. See [primaryWindow].
  WindowHost get host => primaryWindow.host;

  /// The primary window's scheduler. See [primaryWindow].
  FrameScheduler get scheduler => primaryWindow.scheduler;

  /// The primary window's build owner. See [primaryWindow].
  BuildOwner get buildOwner => primaryWindow.buildOwner;

  PipelineOwner get pipelineOwner => primaryWindow.pipelineOwner;
  ManualDispatcher get dispatcher => primaryWindow.dispatcher;

  /// Execution mode and renderer information for the primary window.
  ApplicationRuntimeInfo get runtimeInfo => primaryWindow.runtimeInfo;

  ApplicationLifecycleState get state => _state;

  /// The window key and text events are delivered to, or null when no window
  /// of this application currently holds the keyboard.
  ///
  /// At most one, always: that is the invariant requirement 3 asks for, and
  /// [focusWindow] is the only thing that assigns it.
  NativeWindowId? get keyboardFocusWindow => _keyboardFocus;

  /// Frames actually put on screen, across every window this application has
  /// had. Rejected frames are not counted here; [framesRejected] has those.
  int get framesPresented =>
      _retiredFramesPresented +
      _windows.fold<int>(0, (sum, w) => sum + w.framesPresented);

  int get framesRejected =>
      _retiredFramesRejected +
      _windows.fold<int>(0, (sum, w) => sum + w.framesRejected);

  /// Whether any window owes a frame.
  bool get needsFrame => _windows.any((w) => w.needsFrame);

  /// Events that named a window this application does not have - closed,
  /// never opened, or from a superseded generation - and were dropped in
  /// silence.
  ///
  /// Counted rather than merely ignored, because "the event was discarded" and
  /// "the event was never delivered" are indistinguishable without a number,
  /// and the first is correct while the second is a routing bug.
  int get eventsDropped => _eventsDropped;

  /// Build failures contained by the reporters rather than propagated, from
  /// every window including the closed ones.
  List<FrameworkError> get errors => <FrameworkError>[
        ..._retiredErrors,
        for (final ApplicationWindow window in _windows) ...window.errors,
      ];

  /// Framework-owned controls across every open window.
  ///
  /// Snapshotted during teardown so the number survives it - which is what
  /// makes "no native control anywhere in the tree" a checkable claim rather
  /// than a promise.
  int get controlCount => isDisposed
      ? _controlCount
      : _windows.fold<int>(0, (sum, w) => sum + w.controlCount);

  int get semanticNodeCount => isDisposed
      ? _semanticNodeCount
      : _windows.fold<int>(0, (sum, w) => sum + w.semanticNodeCount);

  /// What was released, in the order it was released. Empty until the first
  /// window is closed or [dispose] runs.
  List<String> get teardownOrder => List<String>.unmodifiable(_teardownOrder);

  /// Completes when the backend's asynchronous shutdown has finished.
  ///
  /// [dispose] is synchronous because [Disposable] is, and a backend's
  /// `shutdown()` is not. Rather than pretend, the bag starts the shutdown and
  /// this future is where it lands.
  Future<void> get closed => _pendingShutdown ?? Future<void>.value();

  /// Both selection reports plus a line per open window, ready to be logged
  /// verbatim on startup.
  String describeStartup() {
    final buffer = StringBuffer()
      ..write(windowingSelection.describe())
      ..write(presentationSelection.describe());
    for (final ApplicationWindow window in _windows) {
      buffer
        ..write('  renderer: ${window.host.presenter.info}\n')
        ..write('  window ${window.id.value}: '
            '${window.host.logicalSize.width}x${window.host.logicalSize.height} '
            '@ ${window.host.renderScale}x '
            '(desktop ${window.host.desktopScale}x)\n');
    }
    return buffer.toString();
  }

  /// The clipboard this application's widget trees can reach.
  ///
  /// Resolved in three steps, and the middle one is the whole fix:
  ///
  ///  1. [ApplicationOptions.clipboard], when the caller supplied one. An
  ///     explicit choice still wins - that is what makes a test able to inject
  ///     a failing clipboard into an application running on a real backend.
  ///  2. **Otherwise the clipboard of the backend that was selected**, when
  ///     that backend is a [ClipboardProvider] - which the Win32 backend and
  ///     the headless backend both are. Choosing a backend chooses its
  ///     clipboard, so the default path works with nothing configured. Before
  ///     this, an application that did not pass one - `example/gallery_win32
  ///     .dart`, and every other example - had every Ctrl+C and Ctrl+V in it
  ///     fail against an [UnavailableClipboard], which is the bug this closes.
  ///  3. Failing both, an [UnavailableClipboard]: a backend with no clipboard
  ///     (X11 today) still yields a *named* failure at the Ctrl+V rather than a
  ///     null or a silent no-op the user would read as "the clipboard is
  ///     empty".
  ///
  /// Never null in any of the three, and one per application rather than one
  /// per window: copying in one window and pasting in another is the whole
  /// point of a clipboard.
  Clipboard get clipboard {
    final Clipboard? configured = options.clipboard;
    if (configured != null) return configured;
    // A pattern rather than `is`: [ClipboardProvider] is not a subtype of
    // `WindowingBackend` - deliberately, so that no existing implementation had
    // to change - and Dart only promotes to a subtype of the declared type.
    if (backend case final ClipboardProvider provider) {
      return provider.clipboard;
    }
    return UnavailableClipboard(
      'the ${backend.name} backend provides no clipboard, and none was passed '
      'through ApplicationOptions.clipboard',
    );
  }

  /// The drag and drop this application's windows register with.
  ///
  /// Resolved exactly the way [clipboard] is, and for the same three reasons:
  /// an explicit override wins, otherwise the selected backend supplies its own
  /// when it is a [DragDropProvider], and failing both the answer is an
  /// [UnavailableDragDrop] that names the backend, and that object is what the
  /// `DragDropScope` publishes to every tree. So a control that *asks* - to
  /// start a drag, or to register a target of its own - gets a
  /// [DragDropException] saying which backend has no drag and drop, instead of
  /// a null or a silence. [openWindow] does not ask: a platform without drag
  /// and drop is a fact, not a per-window failure to report.
  ///
  /// Cached rather than rebuilt per call, because the answer is published to
  /// every window through a `DragDropScope` whose `updateShouldNotify` is an
  /// identity check: a fresh [UnavailableDragDrop] on each rebuild would
  /// notify every dependent in the tree that nothing had changed.
  DragDropBackend get dragAndDrop => _dragAndDrop ??= _resolveDragAndDrop();

  DragDropBackend? _dragAndDrop;

  DragDropBackend _resolveDragAndDrop() {
    final DragDropBackend? configured = options.dragAndDrop;
    if (configured != null) return configured;
    // A pattern rather than `is`, for [ClipboardProvider]'s reason.
    if (backend case final DragDropProvider provider) {
      return provider.dragAndDrop;
    }
    return UnavailableDragDrop(
      name: backend.name,
      reason: 'the ${backend.name} backend has no drag and drop, and none was '
          'passed through ApplicationOptions.dragAndDrop',
    );
  }

  /// The platform's input method, resolved exactly as [dragAndDrop] is.
  ///
  /// An explicit override wins, the selected backend supplies its own when it
  /// is a [TextInputProvider], and failing both the answer is an
  /// [UnavailableTextInput] naming the backend. That object is what
  /// `TextInputScope` publishes to every tree, so a field on a platform with no
  /// IME carries the reason rather than a null - and goes on typing, because
  /// plain text comes from `TextInputEvent` and never through here.
  ///
  /// Cached for `TextInputScope.updateShouldNotify`'s sake: it is an identity
  /// check, and a fresh [UnavailableTextInput] per rebuild would tell every
  /// text field in the tree that its input method had changed.
  TextInputBackend get textInput => _textInput ??= _resolveTextInput();

  TextInputBackend? _textInput;

  TextInputBackend _resolveTextInput() {
    final TextInputBackend? configured = options.textInput;
    if (configured != null) return configured;
    if (backend case final TextInputProvider provider) {
      return provider.textInput;
    }
    return UnavailableTextInput(
      name: backend.name,
      reason: 'the ${backend.name} backend has no input method, and none was '
          'passed through ApplicationOptions.textInput; plain typing still '
          'works, composition does not',
    );
  }

  // ---------------------------------------------------------------------------
  // Screens
  // ---------------------------------------------------------------------------

  /// The monitors this application's windows are placed on.
  ///
  /// The backend's own answer when it is a [ScreenProvider] - a pattern rather
  /// than `is`, for [ClipboardProvider]'s reason: the interface is deliberately
  /// not a subtype of [WindowingBackend], so `is` would not promote.
  ///
  /// ## The synthetic fallback, and why it is not an empty list
  ///
  /// A backend that is not a [ScreenProvider] gets **one screen synthesised
  /// from the primary window's own client area and scale**, positioned at the
  /// desktop origin. That is a fabrication and it is documented as one: the
  /// window is not the screen, its origin is not the desktop's, and nothing
  /// here knows where a taskbar is - so [ScreenInfo.workArea] equals
  /// [ScreenInfo.bounds], which is the truthful shape for "nothing was
  /// reserved that I could find out about".
  ///
  /// The alternative - answering with an empty list - reads as the honest one
  /// and is the worse bug. Every popup would then fall back to the owner
  /// window as its work area, which is exactly the in-tree behaviour this
  /// whole feature exists to stop: a menu near the right edge cropped instead
  /// of flipped. A backend that merely has not implemented [ScreenProvider]
  /// yet would silently undo the feature for every application on it, and the
  /// symptom - a cropped menu - names neither the missing interface nor this
  /// method. So the fallback places popups *somewhere plausible* and stays
  /// wrong only about the desktop, while an empty list would be wrong about
  /// the popup.
  ///
  /// Empty only when there is no window to synthesise from either, which is a
  /// windowless application - and one of those has no popup to place.
  List<ScreenInfo> get screens {
    if (backend case final ScreenProvider provider) {
      final List<ScreenInfo> reported = provider.screens;
      if (reported.isNotEmpty) return reported;
    }
    return _syntheticScreens();
  }

  /// The screen [window] is on, or null when nothing can say.
  ///
  /// The window's own centre decides, converted to screen coordinates by the
  /// window itself - a window straddling two monitors belongs to the one that
  /// holds most of it, which is what the centre expresses and what the
  /// platform's own `MonitorFromWindow` means by "nearest".
  ScreenInfo? screenFor(ApplicationWindow window) {
    if (window.isDisposed) return null;
    final Size size = window.host.logicalSize;
    final Offset centre = window.nativeWindow.clientToScreen(
      Offset(size.width / 2, size.height / 2),
    );
    return screenAt(centre);
  }

  /// The screen containing [screenPoint], or the nearest one; null only when
  /// [screens] is empty. See [ScreenInfo.nearest] for why an outside point
  /// resolves to a screen rather than to null.
  ScreenInfo? screenAt(Offset screenPoint) =>
      ScreenInfo.nearest(screens, screenPoint);

  List<ScreenInfo> _syntheticScreens() {
    final ApplicationWindow? window = _windows.isEmpty ? null : _windows.first;
    if (window == null || window.isDisposed) return const <ScreenInfo>[];
    final Size size = window.host.logicalSize;
    if (size.isEmpty) return const <ScreenInfo>[];
    final Rect bounds = Rect.fromLTWH(0, 0, size.width, size.height);
    return <ScreenInfo>[
      ScreenInfo(
        bounds: bounds,
        // Equal to the bounds on purpose: nothing here can find out what a
        // shell reserved, and a guessed inset would be a menu floating above
        // a taskbar that is not there.
        workArea: bounds,
        scale: window.host.renderScale,
        isPrimary: true,
        name: 'synthetic-${backend.name}',
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Opening and closing
  // ---------------------------------------------------------------------------

  /// Opens a window with its own tree, surface, renderer target and owners.
  ///
  /// Every argument that defaults to null falls back to [options], so opening a
  /// second window of the same shape is one named argument. The returned
  /// [ApplicationWindow] is live but has drawn nothing: its root mounts on its
  /// first [ApplicationWindow.drawFrame], the same rule the first window
  /// follows.
  ///
  /// ## Owned and modal windows
  ///
  /// [owner] makes this a child of another window: the backend is asked for a
  /// real owned window (on Windows that is `CreateWindowExW`'s `hWndParent`,
  /// which keeps it above its owner and takes it down with it), and closing the
  /// owner closes it.
  ///
  /// [modal] additionally blocks the owner while this window lives. Blocking is
  /// enforced twice on purpose:
  ///
  ///   * the platform is told, when the backend implements [EnableableWindow] -
  ///     that is what makes the owner's title bar flash and its buttons refuse
  ///     the mouse;
  ///   * and the application refuses to route pointer, key and text events to a
  ///     blocked window regardless, so modality is identical on a backend that
  ///     cannot disable a window. `native_window.dart` states this policy for
  ///     the framework as a whole - "menus, popups and modality are built in
  ///     Dart on top of this, not delegated to the platform, which is what
  ///     keeps them identical everywhere".
  ///
  /// [modal] without [owner] is an [ArgumentError]: a modal window with nothing
  /// to block is a plain window with a misleading name.
  Future<ApplicationWindow> openWindow({
    required Widget rootWidget,
    String? title,
    Size? size,
    Offset? position,
    Size? minimumSize,
    Size? maximumSize,
    bool visible = true,
    bool resizable = true,
    bool decorated = true,
    Color? clearColor,
    Color? backgroundColor,
    NativeWindowId? owner,
    WindowKind kind = WindowKind.normal,
    bool modal = false,
    bool? focus,
  }) async {
    throwIfDisposed();
    if (_state == ApplicationLifecycleState.closing) {
      throw StateError(
        'Application.openWindow() after a close was requested; the teardown '
        'order is already being unwound',
      );
    }
    if (modal && owner == null) {
      throw ArgumentError.value(
        modal,
        'modal',
        'a modal window needs an owner to block; pass owner:',
      );
    }
    if (!kind.isTopLevel && owner == null) {
      throw ArgumentError.value(
        kind.name,
        'kind',
        'a ${kind.name} window belongs to another window; pass owner:. A menu '
            'with no owner is exactly what turns "the menu closed" into "the '
            'application closed"',
      );
    }
    final ApplicationWindow? ownerWindow = owner == null ? null : _byId[owner];
    if (owner != null && ownerWindow == null) {
      throw ArgumentError.value(
        owner.value,
        'owner',
        'no open window has this id',
      );
    }
    // A popup or a tooltip never takes the keyboard unless the caller insists,
    // because a menu that activated itself would deactivate the window it
    // belongs to - and every caret in that window would stop blinking while
    // the user was merely reading a menu.
    final bool wantsFocus = focus ?? kind.takesActivation;

    final bag = DisposableBag();
    late final ApplicationWindow appWindow;
    try {
      // --- a. the native window ----------------------------------------
      final native = await backend.createWindow(WindowOptions(
        title: title ?? options.title,
        size: size ?? options.size,
        position: position,
        minimumSize: minimumSize ?? options.minimumSize,
        maximumSize: maximumSize ?? options.maximumSize,
        resizable: resizable,
        decorated: decorated,
        visible: visible,
        backgroundColor: (backgroundColor ??
                options.windowBackgroundColor ??
                clearColor ??
                options.clearColor)
            ?.value,
        owner: ownerWindow?.nativeWindow,
        kind: kind,
      ));
      bag.add(native, () {
        _teardownOrder.add('window');
        native.close();
      });

      // The first moment the question can be answered - the backend has a
      // window now, so [canOpenPopupWindows] has something to look at - and
      // the last moment before anything expensive is built. A throw here
      // unwinds through the bag below, so the window that was just created is
      // closed rather than leaked.
      _assertPopupPolicySatisfiable();

      // --- b. presenter and host ---------------------------------------
      late SurfacePresenter presenter;
      while (true) {
        try {
          presenter = await _presentationPath.attach(native, devices: _devices);
          break;
        } on Object catch (error) {
          // A pinned path is a demand, not a preference. Falling back would
          // make --presentation useful for neither testing nor diagnostics.
          // Existing windows also keep their renderer: silently changing the
          // renderer only for a later window would make one application have
          // two different visual contracts.
          if (presentationSelection.requested != null || _windows.isNotEmpty) {
            rethrow;
          }
          final String failedName = _presentationPath.name;
          final BackendDiagnostic failure = BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: '$failedName passed its probe but could not attach to '
                'the ${windowingSelection.chosen!.name} window',
            detail: '$error',
          );
          options.onDiagnostic?.call(failure);
          _presentationProbes[failedName] = BackendProbeResult.unsupported(
            failedName,
            failure,
          );
          presentationSelection = _selectPresentation();
          if (!presentationSelection.isSuccess) {
            throw presentationSelection.toError();
          }
          _presentationPath = _presentationPaths.firstWhere(
            (PresentationPathEntry entry) =>
                entry.name == presentationSelection.chosen!.name,
          );
        }
      }
      // Below the host in the bag and therefore released *after* it, and no
      // entry is added to [teardownOrder]: the device is not a new step of a
      // window's life, it is a borrow the presenter already gives back inside
      // `host.dispose()`. Announcing it as a step would change the observed
      // teardown order of every window in the framework to record something
      // that has already happened. See `releaseDeviceLease`.
      if (presenter case final RenderTargetPresenter target) {
        bag.add(target, target.releaseDeviceLease);
      }
      final host = WindowHost(
        window: native,
        presenter: presenter,
        onDiagnostic: options.onDiagnostic,
      );
      bag.add(host, () {
        _teardownOrder.add('host');
        host.dispose();
      });

      // --- c. frame plumbing -------------------------------------------
      // Order is forced by two constructor preconditions, and both are worth
      // stating: `FrameScheduler` refuses a `PipelineOwner` that already has a
      // visual-update owner, and `BuildOwner` refuses one that already has a
      // root. So the pipeline is created bare, the scheduler claims the
      // update hook, and the build owner claims the root. It is also why these
      // three cannot be shared between windows - see the library comment.
      final pipelineOwner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(native.clientSize),
      );
      final scheduler = FrameScheduler(
        dispatcher: ManualDispatcher(),
        pipelineOwner: pipelineOwner,
        onFrame: (DisplayList list) => appWindow._onPainted(list),
        onNextFrameScheduled: (Duration delay) =>
            appWindow._scheduleAnimationWake(delay),
        onError: (phase, error, stackTrace) =>
            appWindow._onFrameError(phase, error, stackTrace),
      );
      bag.add(scheduler, () {
        _teardownOrder.add('scheduler');
        scheduler.dispose();
      });

      final buildOwner = BuildOwner(
        pipelineOwner: pipelineOwner,
        // A build scheduled outside a frame - a setState from a callback -
        // marks this window's next frame dirty rather than painting
        // immediately. Painting inline would produce two frames for one user
        // action, and marking any *other* window would be the cross-window
        // relayout this design exists to prevent.
        onBuildScheduled: () => appWindow._requestFrameFromTree(),
      );
      bag.add(buildOwner, () {
        _teardownOrder.add('buildOwner');
        buildOwner.dispose();
      });

      appWindow = ApplicationWindow._(
        application: this,
        nativeWindow: native,
        host: host,
        scheduler: scheduler,
        buildOwner: buildOwner,
        ownerId: owner,
        kind: kind,
        isModal: modal,
        clearColor: clearColor,
        resources: bag,
        rootWidget: rootWidget,
      );
      appWindow._active = wantsFocus && visible;
      buildOwner.errorReporter = ErrorReporter(
        onError: appWindow._captureFrameworkError,
      );

      // --- c2. accessibility --------------------------------------------
      // Registering is all that happens here, and it is deliberately cheap:
      // no provider is built, no COM is initialised and no tree is walked
      // until assistive technology actually asks for this window. On a machine
      // with no screen reader running - which is most machines, most of the
      // time - this line and the null check in [drawFrame] are the entire cost
      // of the feature. See `semantics/accessibility.dart`.
      final AccessibilityHost? accessibility =
          native is NativeHandleWindow ? platformAccessibility : null;
      if (accessibility != null) {
        final int handle = (native as NativeHandleWindow).nativeHandle;
        accessibility.register(handle, (
          owner: buildOwner.semanticsOwner,
          // A callback and not the root itself: the render root is replaced
          // when the tree is remounted, and a captured one would publish a
          // detached tree for the rest of the process.
          root: () => buildOwner.renderRoot,
        ));
        bag.add(accessibility, () {
          _teardownOrder.add('accessibility');
          accessibility.unregister(handle);
        });
      }

      // --- d. events ----------------------------------------------------
      // Subscribed last and cancelled first: an event delivered into a
      // half-disposed tree is the classic teardown crash, and the stream
      // outlives the tree by construction. Routed through the application
      // rather than straight into this window, because the windowId on the
      // event is the authority on where it belongs - a backend that mislabels
      // one must not be able to smuggle it into the wrong tree.
      final subscription = native.events.listen(
        (event) {
          try {
            handleEvent(event);
          } catch (error, stackTrace) {
            appWindow.buildOwner.errorReporter.report(FrameworkError(
              phase: FrameworkPhase.input,
              cause: error,
              stackTrace: stackTrace,
              context: 'handling ${event.runtimeType}',
            ));
            appWindow.requestFrame();
          }
        },
        onError: appWindow._onStreamError,
      );
      bag.add(subscription, () {
        _teardownOrder.add('events');
        unawaited(subscription.cancel());
      });

      // --- e. live resize ------------------------------------------------
      // The one hook that is *not* a stream, and cannot be: it is called from
      // inside the platform's resize handler, at a moment when no stream in
      // this isolate will be delivered for as long as the drag lasts. See
      // [ApplicationOptions.liveResize] for the policy and [LiveResizeWindow]
      // for the mechanism.
      //
      // A pattern rather than `is`, because LiveResizeWindow is deliberately
      // not a subtype of NativeWindow: a backend that cannot do this says so by
      // not implementing it, and gets the ordinary asynchronous path.
      if (options.liveResize && host.canPresentSynchronously) {
        if (native case final LiveResizeWindow live) {
          live.setLiveResizeCallback(appWindow.drawFrameSynchronously);
          // Registered after the window itself, so it is cleared *before* the
          // handle is destroyed: a callback into a half-disposed tree from a
          // WM_SIZE that DestroyWindow itself sends is the classic teardown
          // crash.
          bag.add(live, () {
            _teardownOrder.add('liveResize');
            live.setLiveResizeCallback(null);
          });
        }
      }

      // --- f. drag and drop ----------------------------------------------
      // Registered here rather than by the caller for the reason the clipboard
      // scope is installed here: a `DropTarget` widget cannot register the
      // window it happens to be mounted in, and an application that forgot to
      // would have a drop zone that never receives anything - a silent failure
      // with nothing to grep for.
      //
      // A backend that has none is skipped rather than tried and caught: an
      // [UnavailableDragDrop] is not a failure to report per window, it is a
      // fact about the platform that the scope in `_mountableRoot` already
      // carries - a control that asks for it gets that object and the reason
      // in its message. Reporting it here would put one note per window in
      // every headless run's diagnostics for a feature nobody asked for.
      //
      // A *real* registration failure is different and is reported, but is
      // still never fatal: losing a whole window because OLE refused would be
      // the worse trade. The registration is revoked through the bag, before
      // the window handle goes, because `RevokeDragDrop` on a dead HWND leaves
      // OLE holding a pointer into this process.
      final DragDropBackend dragDropBackend = dragAndDrop;
      if (dragDropBackend is! UnavailableDragDrop) {
        try {
          final DropTargetRegistration registration =
              await dragDropBackend.registerDropTarget(
            window: native,
            handler: WidgetTreeDropTarget(buildOwner),
          );
          bag.add(registration, () {
            _teardownOrder.add('dragAndDrop');
            unawaited(registration.revoke());
          });
        } on DragDropException catch (error) {
          options.onDiagnostic?.call(
            BackendDiagnostic(
              kind: DiagnosticKind.note,
              message: 'this window could not be registered as a drop target',
              detail: '$error',
            ),
          );
        }
      }
    } on Object {
      bag.dispose();
      rethrow;
    }

    _windows.add(appWindow);
    _byId[appWindow.id] = appWindow;
    _primary ??= appWindow;
    _resources.add(appWindow, appWindow.dispose);

    if (modal && ownerWindow != null) {
      ownerWindow._modalChildren.add(appWindow);
      _applyModalBlocking(ownerWindow);
    }
    if (wantsFocus) {
      // The platform is only asked when the window is actually on screen: a
      // window that has not been shown yet cannot be activated, and asking
      // would be a failed call on every startup.
      focusWindow(appWindow.id, notifyPlatform: visible);
    } else if (_keyboardFocus == null) {
      focusWindow(appWindow.id, notifyPlatform: false);
    } else {
      // Even an unfocused window needs its manager told, or it would paint an
      // active focus ring in a window that plainly does not have the keyboard.
      appWindow.buildOwner.focusManager.isWindowActive = false;
    }
    return appWindow;
  }

  PresentationSelection _selectPresentation() => selectPresentation(
        <PresentationCandidate>[
          for (final path in _presentationPaths)
            PresentationCandidate(
              name: path.name,
              kind: path.kind,
              probe: _presentationProbes[path.name]!,
              experimental: path.experimental,
            ),
        ],
        requested: options.requestedPresentation,
        preferred: options.preferredPresentations,
        allowExperimental: options.allowExperimentalBackends,
        arguments: options.arguments,
        environment: options.environment,
        gpuPresentationCapability: options.gpuPresentationCapability,
        renderingPolicy: options.renderingPolicy,
      );

  // ---------------------------------------------------------------------------
  // Popups
  // ---------------------------------------------------------------------------

  /// Whether a menu opened here can be a window of its own.
  ///
  /// One question, asked of the backend rather than inferred: does its probe
  /// report [Capability.nativePopups]? A popup needs a surface that is
  /// undecorated, refuses activation, is positioned by the client and does not
  /// count as a window of the application - `WS_POPUP | WS_EX_NOACTIVATE`, an
  /// override-redirect window, an `xdg_popup` - and none of that is implied by
  /// being able to open two ordinary windows.
  ///
  /// Asked of the backend and not derived from anything visible here, because
  /// every proxy available at this layer is wrong for some backend. "Does the
  /// window have an operating-system handle" is the tempting one and it
  /// answers no for Wayland, which has no handle to expose and the most real
  /// popups of all; it would have silently dropped every Wayland menu back
  /// into an overlay, with nothing in the symptom naming the cause. So the
  /// backends declare it.
  ///
  /// The headless backend deliberately does not, and that is a decision rather
  /// than a gap: it *can* create a [WindowKind.popup] window - [openPopup]
  /// works there and its tests drive it - but it has no screen to put one on,
  /// and a headless run wants its menus composited into the single surface it
  /// captures.
  bool get canOpenPopupWindows =>
      windowingSelection.chosen?.probe.capabilities
          .contains(Capability.nativePopups) ??
      false;

  /// One [WindowPopupHost] per top-level owner window, shared by its whole
  /// chain.
  ///
  /// Keyed by the *owner*, never by the popup: a submenu's host must be the
  /// same object its parent menu used, or the two chains would not know about
  /// each other and [PopupHost.closeAll] would close half of one.
  final Map<NativeWindowId, WindowPopupHost> _popupHosts =
      <NativeWindowId, WindowPopupHost>{};

  /// The host [window]'s tree publishes, or null for the in-tree one.
  ///
  /// Called once per window, on its first mount, from
  /// [ApplicationWindow.popupHost].
  PopupHost? _popupHostFor(ApplicationWindow window) {
    if (options.popupPolicy == PopupPolicy.inTree) return null;
    if (!canOpenPopupWindows) return null;
    // A popup window's host was handed to it by [openPopup] before it mounted,
    // so reaching here for one means it was opened as a bare window rather
    // than as a popup; a root host is the honest answer for that.
    final ApplicationWindow root = _topLevelOwnerOf(window);
    return _popupHosts.putIfAbsent(
      root.id,
      () => WindowPopupHost(application: this, owner: root),
    );
  }

  /// The window at the top of [window]'s owner chain - itself, when it has no
  /// owner.
  ApplicationWindow _topLevelOwnerOf(ApplicationWindow window) {
    ApplicationWindow node = window;
    while (true) {
      final NativeWindowId? ownerId = node.ownerId;
      final ApplicationWindow? owner = ownerId == null ? null : _byId[ownerId];
      if (owner == null) return node;
      node = owner;
    }
  }

  /// Refuses [PopupPolicy.window] loudly on a backend that has no windows to
  /// give it, rather than quietly handing back the overlays it rejected.
  void _assertPopupPolicySatisfiable() {
    if (options.popupPolicy != PopupPolicy.window) return;
    if (canOpenPopupWindows) return;
    throw PopupWindowUnavailableError(
      'the ${backend.name} backend does not open popup windows '
      '(ApplicationOptions.popupPolicy is PopupPolicy.window)',
    );
  }

  /// Opens a popup as a window of its own, sized to its content and placed
  /// against the monitor's work area.
  ///
  /// [anchorRect] is in **[owner]'s logical coordinate space** - the space
  /// `RenderBox.localToGlobal` produces - because that is the only space that
  /// exists on every backend. See [PopupSpec.anchorRect].
  ///
  /// ## The order of the four steps, and what each one prevents
  ///
  ///   1. **the window is created hidden.** A popup that appeared at a
  ///      provisional size and then resized to its measured one is a visible
  ///      jump, and there is no size to create it at that is not provisional -
  ///      the content has not been laid out yet. Avalonia's `PopupImpl` avoids
  ///      the same jump the same way, `MoveResize` before `Show`;
  ///   2. **it is measured** through [ApplicationWindow.measureRoot] against a
  ///      loose constraint. Skipping this and trusting the created size would
  ///      lay the menu out against the guess and then believe the guess;
  ///   3. **it is placed** by [PopupPositioner] against the work area of the
  ///      screen the anchor is on - flip, then slide - with the anchor
  ///      converted to screen coordinates by the owner itself;
  ///   4. **it is shown**, and its root constraints go back to tight, because
  ///      from here on it is an ordinary window whose layout is its client
  ///      area.
  ///
  /// ## The one divergence, and it is the surprising thing in this method
  ///
  /// **On a backend that reports no screens, step 3 does not run at all.** The
  /// case is Wayland, and it is not a gap to be filled in later: a Wayland
  /// client cannot express a screen coordinate, is never told where its own
  /// window is, and has no business computing a flip. The compositor does it,
  /// from the `xdg_positioner` the backend builds out of exactly the anchor
  /// rectangle and adjustment set handed in here. So the anchor is passed
  /// through untouched and the placement that comes back is the compositor's.
  /// A caller must therefore not assume [ApplicationWindow] bounds mean
  /// anything before the first frame - which is the same rule
  /// [PopupHandle.placedRect] states by being nullable.
  ///
  /// ## Rendering
  ///
  /// None. A popup goes through the application's already-chosen presentation
  /// path, exactly like every other window, because [openWindow] does and this
  /// method does not add an exception. Section 3.7 of the popup plan is
  /// explicit about why: a menu rasterised on the CPU over a window rasterised
  /// on the GPU shows the two rasterisers' divergences side by side on one
  /// screen, and no number of milliseconds buys that back.
  Future<ApplicationWindow> openPopup({
    required ApplicationWindow owner,
    required Rect anchorRect,
    required Widget content,
    required PopupKind kind,
    PopupAnchorPoint anchorPoint = PopupAnchorPoint.bottomLeft,
    PopupAnchorPoint popupPoint = PopupAnchorPoint.topLeft,
    Offset offset = Offset.zero,
    Set<PopupAdjustment> adjustments = const <PopupAdjustment>{
      PopupAdjustment.flipY,
      PopupAdjustment.flipX,
      PopupAdjustment.slideX,
      PopupAdjustment.slideY,
    },
    BoxConstraints? constraints,
    ApplicationWindow? parentPopup,
    PopupHost? host,
    void Function()? onDismissed,
  }) async {
    throwIfDisposed();
    if (owner.isDisposed) {
      throw ArgumentError.value(
        owner,
        'owner',
        'a popup cannot be opened from a window that has closed',
      );
    }
    final ApplicationWindow parent = parentPopup ?? owner;
    if (parent.isDisposed) {
      throw ArgumentError.value(
        parentPopup,
        'parentPopup',
        'the popup this one opens from has already closed',
      );
    }

    final Rect workArea = workAreaFor(owner, anchorRect);

    // --- 1. hidden, at a provisional size ------------------------------
    final Size provisional = _boundedSize(workArea.size, constraints);
    final ApplicationWindow popup = await openWindow(
      rootWidget: content,
      size: provisional,
      visible: false,
      resizable: false,
      decorated: false,
      owner: parent.id,
      kind: kind.windowKind,
      focus: false,
    );
    popup.popupKind = kind;
    // Both before the tree mounts, which [measureRoot] below is about to do.
    // The host in particular: it is what a submenu opened from inside this
    // popup finds, and a popup that mounted without it would resolve a root
    // host of its own and break the platform's parent chain.
    popup._popupHost = host;
    popup._popupHostResolved = true;
    popup._onPopupWindowRetired = onDismissed;

    // --- 2. measure ----------------------------------------------------
    final BoxConstraints measuring = constraints == null
        ? BoxConstraints.loose(provisional)
        : constraints.enforce(BoxConstraints.loose(provisional));
    Size measured = popup.measureRoot(measuring);
    if (measured.isEmpty) measured = provisional;

    // --- 3. place ------------------------------------------------------
    final Rect placed = placePopup(
      owner: owner,
      anchorRect: anchorRect,
      size: measured,
      anchorPoint: anchorPoint,
      popupPoint: popupPoint,
      offset: offset,
      adjustments: adjustments,
    );

    // --- 4. show -------------------------------------------------------
    if (!popup.isDisposed) {
      popup.nativeWindow.setBounds(placed);
      // Back to the ordinary contract: a window's tree is laid out against its
      // client area. Leaving the loose constraint in place would let the next
      // frame lay the menu out at a size the window is not.
      popup.pipelineOwner.rootConstraints =
          BoxConstraints.tight(Size(placed.width, placed.height));
      popup.nativeWindow.show();
      popup.requestFrame();
    }
    return popup;
  }

  /// Whether this platform lets a client name a point on the desktop.
  ///
  /// True when the backend is a [ScreenProvider] that reports at least one
  /// monitor. False is not a defect: a Wayland client is never told where its
  /// own window is and cannot express a screen coordinate at all, and this is
  /// the flag that keeps the framework from pretending otherwise.
  ///
  /// Distinct from `screens.isNotEmpty`, which is never false while a window
  /// is open because [screens] synthesises one. The synthetic screen is a
  /// usable *work area* - it is what bounds a menu's height - and it is not a
  /// coordinate system; conflating the two is how a popup gets placed at a
  /// desktop position the compositor never agreed to.
  bool get hasScreenCoordinates {
    if (backend case final ScreenProvider provider) {
      return provider.screens.isNotEmpty;
    }
    return false;
  }

  /// The rectangle a popup anchored at [anchorRect] in [owner] must fit into.
  ///
  /// The work area of the screen the anchor is on - which on a backend with no
  /// screens is the synthetic one [screens] describes, and that is the
  /// difference between this and [placePopup]: a size may be estimated from a
  /// fabricated screen, a *position* may not.
  Rect workAreaFor(ApplicationWindow owner, Rect anchorRect) {
    final Offset centre = owner.nativeWindow.clientToScreen(anchorRect.center);
    final ScreenInfo? screen = screenAt(centre);
    if (screen != null) return screen.workArea;
    return Rect.fromLTWH(
      0,
      0,
      owner.host.logicalSize.width,
      owner.host.logicalSize.height,
    );
  }

  /// Where a popup of [size] anchored at [anchorRect] should be put.
  ///
  /// The returned rectangle is in **screen** coordinates where there are any,
  /// and in [owner]'s logical space where there are not - see
  /// [hasScreenCoordinates]. Both are what [NativeWindow.setBounds] wants on
  /// the backend in question, which is why one method answers both: a Wayland
  /// window's bounds *are* an anchor offset, because that is all a Wayland
  /// window is allowed to know.
  ///
  /// Shared by [openPopup] and by `PopupHandle.updateAnchor`, so a popup that
  /// follows something - a dropdown whose window moved, a tooltip following
  /// the pointer - is repositioned by the same arithmetic that placed it.
  Rect placePopup({
    required ApplicationWindow owner,
    required Rect anchorRect,
    required Size size,
    PopupAnchorPoint anchorPoint = PopupAnchorPoint.bottomLeft,
    PopupAnchorPoint popupPoint = PopupAnchorPoint.topLeft,
    Offset offset = Offset.zero,
    Set<PopupAdjustment> adjustments = const <PopupAdjustment>{
      PopupAdjustment.flipY,
      PopupAdjustment.flipX,
      PopupAdjustment.slideX,
      PopupAdjustment.slideY,
    },
  }) {
    final Offset anchorCentre =
        owner.nativeWindow.clientToScreen(anchorRect.center);
    final ScreenInfo? screen =
        hasScreenCoordinates ? screenAt(anchorCentre) : null;
    if (screen == null) {
      // The divergence [openPopup] warns about, in the one place it lives.
      // The compositor flips and slides from the `xdg_positioner` the backend
      // builds out of this anchor; computing a flip here would be inventing a
      // desktop this client is not entitled to see.
      return Rect.fromLTWH(
        anchorRect.left + offset.dx,
        anchorRect.bottom + offset.dy,
        size.width,
        size.height,
      );
    }
    final Offset anchorOrigin =
        owner.nativeWindow.clientToScreen(anchorRect.topLeft);
    return const PopupPositioner()
        .place(
          PopupRequest(
            anchorRect: Rect.fromLTWH(
              anchorOrigin.dx,
              anchorOrigin.dy,
              anchorRect.width,
              anchorRect.height,
            ),
            size: size,
            anchorPoint: anchorPoint,
            popupPoint: popupPoint,
            offset: offset,
            adjustments: adjustments,
          ),
          screen.workArea,
        )
        .rect;
  }

  /// [size] clamped by [constraints], or unchanged when there are none.
  static Size _boundedSize(Size size, BoxConstraints? constraints) {
    if (constraints == null) return size;
    final Size bounded = constraints.constrain(size);
    // A constraint with an unbounded maximum constrains to the incoming value,
    // so this only ever shrinks - which is what "bounded by constraints" has
    // to mean for a provisional size that is already the whole work area.
    return Size(
      bounded.width.isFinite ? bounded.width : size.width,
      bounded.height.isFinite ? bounded.height : size.height,
    );
  }

  /// Every live popup window below [window], innermost last.
  ///
  /// Ordered by depth in the owner chain so that the last entry is the
  /// topmost popup - the one Escape closes, the one whose [PopupKind] decides
  /// whether a dismissing press is swallowed - and so that closing the list
  /// backwards closes deepest first.
  List<ApplicationWindow> popupsOf(ApplicationWindow window) {
    final entries = <(int, ApplicationWindow)>[];
    for (final ApplicationWindow candidate in _windows) {
      if (candidate.isDisposed || candidate.popupKind == null) continue;
      final int depth = _popupDepthUnder(candidate, window);
      if (depth > 0) entries.add((depth, candidate));
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    return <ApplicationWindow>[for (final entry in entries) entry.$2];
  }

  /// How many owner links separate [candidate] from [ancestor], or 0 when
  /// [candidate] is not below it.
  int _popupDepthUnder(
      ApplicationWindow candidate, ApplicationWindow ancestor) {
    var depth = 0;
    ApplicationWindow? node = candidate;
    while (node != null) {
      final NativeWindowId? ownerId = node.ownerId;
      if (ownerId == null) return 0;
      depth++;
      if (ownerId == ancestor.id) return depth;
      node = _byId[ownerId];
    }
    return 0;
  }

  /// Closes every popup window below [window], deepest first. Returns how many
  /// closed.
  int _dismissPopupsOf(ApplicationWindow window) {
    final List<ApplicationWindow> popups = popupsOf(window);
    var dismissed = 0;
    for (var i = popups.length - 1; i >= 0; i--) {
      if (closeWindow(popups[i].id)) dismissed++;
    }
    return dismissed;
  }

  /// Closes every live popup and tooltip, optionally sparing one subtree.
  ///
  /// This is what a click outside a menu does, and what moving the keyboard to
  /// an unrelated window does. Returns how many were dismissed.
  int dismissPopups({NativeWindowId? keep}) {
    var dismissed = 0;
    for (final ApplicationWindow window
        in List<ApplicationWindow>.of(_windows)) {
      if (!window.kind.isDismissable || window.isDisposed) continue;
      if (keep != null && _isSelfOrOwnerOf(window, keep)) continue;
      if (closeWindow(window.id)) dismissed++;
    }
    return dismissed;
  }

  /// Whether [candidate] is [window] itself or anywhere in its owner chain.
  bool _isSelfOrOwnerOf(ApplicationWindow window, NativeWindowId candidate) {
    for (ApplicationWindow? node = _byId[candidate];
        node != null;
        node = node.ownerId == null ? null : _byId[node.ownerId!]) {
      if (identical(node, window)) return true;
    }
    return false;
  }

  /// Closes one window, releasing its resources in reverse acquisition order.
  ///
  /// Returns false when there is nothing to close - the id is unknown, or the
  /// window has already gone. **Idempotent by that route**: calling it twice
  /// releases once and answers false the second time, because a caller that
  /// closes on both the success and the failure path is normal and making it
  /// remember which one ran is how double-frees get written.
  ///
  /// Closing a window also closes every window it owns, innermost first, for
  /// the reason the platform does the same: a dialog whose owner is gone has
  /// nothing to be modal against.
  bool closeWindow(NativeWindowId id) {
    final window = _byId[id];
    if (window == null || window.isDisposed) return false;
    for (final ApplicationWindow child in _ownedBy(window)) {
      closeWindow(child.id);
    }
    window.dispose();
    return true;
  }

  /// Every live window whose owner is [window].
  List<ApplicationWindow> _ownedBy(ApplicationWindow window) =>
      <ApplicationWindow>[
        for (final ApplicationWindow candidate in _windows)
          if (candidate.ownerId == window.id) candidate,
      ];

  /// Bookkeeping after a window has released everything it held.
  ///
  /// Runs from [ApplicationWindow.onDispose], so by the time it is called the
  /// window's host, owners and native handle are already gone - which is why
  /// nothing here may touch them.
  void _retire(ApplicationWindow window) {
    _windows.remove(window);
    _byId.remove(window.id);
    _retiredFramesPresented += window.framesPresented;
    _retiredFramesRejected += window.host.framesRejected;
    _retiredErrors.addAll(window.errors);

    // Before the early return below, and deliberately: a popup dismissed
    // during teardown still owes its opener the callback it promised exactly
    // once, and a `PopupHandle` left believing it is open would answer
    // `isOpen` true for a window that no longer exists.
    final void Function()? popupRetired = window._onPopupWindowRetired;
    if (popupRetired != null) {
      window._onPopupWindowRetired = null;
      popupRetired();
    }
    _popupHosts.remove(window.id);

    if (_tearingDown) return;

    final ApplicationWindow? owner =
        window.ownerId == null ? null : _byId[window.ownerId!];
    if (owner != null) {
      owner._modalChildren.remove(window);
      _applyModalBlocking(owner);
    }

    if (_primary == window && _windows.isNotEmpty) _primary = _windows.first;

    if (_keyboardFocus == window.id) {
      _keyboardFocus = null;
      // Focus lands on the owner when there was one - closing a dialog puts the
      // keyboard back in the window that opened it, which is the whole reason
      // FocusScopeNode remembers a child - and otherwise on the most recently
      // opened window that is left.
      final ApplicationWindow? next = owner ?? _windows.lastOrNull;
      if (next != null) focusWindow(next.id);
    }

    if (topLevelWindows.isEmpty && options.exitWhenLastWindowClosed) {
      requestClose();
    }
    _syncSuspension();
  }

  /// Applies (or lifts) the block a modal child imposes on its owner.
  void _applyModalBlocking(ApplicationWindow owner) {
    final blocked = owner.isBlocked;
    final native = owner.nativeWindow;
    if (native case final EnableableWindow enableable) {
      enableable.setEnabled(!blocked);
    }
    if (blocked) {
      owner.buildOwner.focusManager.isWindowActive = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Focus
  // ---------------------------------------------------------------------------

  /// Gives one window the keyboard and takes it from every other.
  ///
  /// Exclusivity is enforced here rather than hoped for: every window's
  /// [FocusManager.isWindowActive] is written on every move, so the window that
  /// lost the keyboard is *told*, and a control that paints a selection or a
  /// caret from that flag cannot be left lit in a window the user has walked
  /// away from. That is the class of bug this method exists to close.
  ///
  /// A window blocked by a modal child cannot take focus; the innermost modal
  /// takes it instead, which is what makes clicking a blocked window flash the
  /// dialog rather than move the caret.
  ///
  /// Returns false when the id names no open window.
  bool focusWindow(NativeWindowId id, {bool notifyPlatform = true}) {
    if (isDisposed) return false;
    final requested = _byId[id];
    if (requested == null || requested.isDisposed) return false;
    final ApplicationWindow target = requested.activeModal ?? requested;

    // Moving the keyboard anywhere that is not a live menu (or the window that
    // owns it) dismisses the menu, which is what a click outside one does on
    // every desktop. Done before the focus is recorded so the dismissal cannot
    // re-enter this method and fight over the assignment.
    if (_windows.any((w) => w.kind.isDismissable)) {
      dismissPopups(keep: target.id);
      if (target.isDisposed) return false;
    }

    _keyboardFocus = target.id;
    for (final ApplicationWindow window in _windows) {
      if (window.isDisposed) continue;
      window.buildOwner.focusManager.isWindowActive = identical(window, target);
    }
    if (notifyPlatform) {
      final native = target.nativeWindow;
      // A pattern rather than `is`, for the same reason as ClipboardProvider:
      // ActivatableWindow is not a subtype of NativeWindow, so `is` would not
      // promote.
      if (native case final ActivatableWindow activatable) {
        activatable.activate();
      }
    }
    return true;
  }

  /// Records what the platform said about a window's activation.
  void _setActivation(ApplicationWindow window, bool active) {
    window._active = active;
    if (active) {
      focusWindow(window.id, notifyPlatform: false);
    } else {
      // The fourth dismissal route: the owner lost activation.
      //
      // [focusWindow] already dismisses when the keyboard moves between *our*
      // windows, and that covers nothing at all when the user clicks another
      // application - the platform deactivates this window and never tells us
      // who took it. So the deactivation itself is the signal. Doing it here
      // rather than in `focusWindow` is what makes "click on another app with
      // a menu open" close the menu, which is the case a framework that only
      // watched its own windows silently misses.
      //
      // Harmless in the between-our-windows case: the popups were already
      // dismissed by `focusWindow`, and this finds none.
      _dismissPopupsOf(window);
      window.buildOwner.focusManager.isWindowActive = false;
      // Focus is surrendered rather than handed on. The window that gains it
      // will say so with its own activation event, and inventing a successor
      // here would put the keyboard somewhere the platform did not.
      if (_keyboardFocus == window.id) _keyboardFocus = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Frames
  // ---------------------------------------------------------------------------

  /// Marks every open window's next frame dirty.
  ///
  /// The application-wide form. A window that only wants *itself* redrawn calls
  /// [ApplicationWindow.requestFrame], and the widget tree only ever reaches
  /// that one - which is what keeps one window's `setState` off another
  /// window's layout.
  void requestFrame() {
    if (isDisposed) return;
    for (final ApplicationWindow window in _windows) {
      window.requestFrame();
    }
  }

  /// Draws one frame of the primary window. See [primaryWindow].
  ///
  /// Kept because the single-window shape is still the common one and reads
  /// better without an argument. A multi-window loop wants [drawPendingFrames].
  Future<PresentResult> drawFrame() async {
    throwIfDisposed();
    if (_windows.isEmpty) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame skipped; the application has no open windows',
        ),
      );
    }
    return primaryWindow.drawFrame();
  }

  /// Draws every window that owes a frame, oldest window first.
  ///
  /// Iterates a copy: a frame may close a window - a dialog that dismisses
  /// itself from a build callback, a device loss that gives up - and mutating
  /// the list under the loop is how that turns into a crash on an otherwise
  /// valid application.
  Future<List<PresentResult>> drawPendingFrames() async {
    throwIfDisposed();
    final results = <PresentResult>[];
    for (final ApplicationWindow window
        in List<ApplicationWindow>.of(_windows)) {
      if (window.isDisposed) continue;
      if (!window.needsFrame && !_overlayIsStale) continue;
      if (window.isSuspended) continue;
      results.add(await window.drawFrame());
    }
    if (options.showDevOverlay && results.isNotEmpty) {
      _sinceOverlayRefresh.reset();
    }
    return results;
  }

  void _noteDrawing() {
    if (_state == ApplicationLifecycleState.starting) {
      _state = ApplicationLifecycleState.running;
    }
  }

  void _recordFrame(FrameTiming timing) {
    statistics.record(timing);
    if (options.showDevOverlay) _sinceOverlayRefresh.reset();
  }

  void _reportUnhandledAsync(Object error, StackTrace stackTrace) {
    final frameworkError = FrameworkError(
      phase: FrameworkPhase.async,
      cause: error,
      stackTrace: stackTrace,
      context: 'an uncaught asynchronous callback escaped its owner',
    );
    final liveWindows = <ApplicationWindow>[
      for (final window in _windows)
        if (!window.isDisposed) window,
    ];
    if (liveWindows.isEmpty) {
      options.onError?.call(frameworkError);
      return;
    }
    for (final window in liveWindows) {
      window.buildOwner.errorReporter.report(frameworkError);
      window.requestFrame();
    }
    backend.wake();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Asks the loop to stop and tear down cleanly.
  ///
  /// Invalidates every host's generation immediately, which is what rejects a
  /// frame that is mid-`await`: it would otherwise land in a surface that
  /// teardown is about to free. The windows themselves are not released here -
  /// that is [dispose]'s single ordered pass.
  void requestClose() {
    if (isDisposed || _state == ApplicationLifecycleState.closing) return;
    _state = ApplicationLifecycleState.closing;
    for (final ApplicationWindow window in _windows) {
      if (window.isDisposed) continue;
      window.host.surfaceChanged(logicalSize: Size.zero);
    }
  }

  /// Stops drawing without stopping event delivery. See the lifecycle policy.
  ///
  /// Accepted from [ApplicationLifecycleState.starting] as well as from
  /// [ApplicationLifecycleState.running], because a window can perfectly well
  /// be minimised between being created and being drawn - and refusing the
  /// transition there would leave the shell believing it may draw into a
  /// zero-sized surface.
  void suspend() {
    if (isDisposed) return;
    if (_state != ApplicationLifecycleState.running &&
        _state != ApplicationLifecycleState.starting) {
      return;
    }
    _state = ApplicationLifecycleState.suspended;
  }

  /// Resumes and requests a full repaint, because the windows' contents may
  /// have been discarded while they were away.
  void resume() {
    if (isDisposed || _state != ApplicationLifecycleState.suspended) return;
    _state = ApplicationLifecycleState.running;
    requestFrame();
  }

  /// Recomputes the application state from the windows' own suspension.
  ///
  /// The rule: an application is suspended only when *every* window is. One of
  /// two windows being minimised must not stop the other drawing, and that is
  /// the whole reason this is a fold rather than a flag.
  void _syncSuspension() {
    if (isDisposed || _tearingDown) return;
    if (_state == ApplicationLifecycleState.closing ||
        _state == ApplicationLifecycleState.closed) {
      return;
    }
    if (_windows.isEmpty) return;
    if (_windows.every((w) => w.isSuspended)) {
      suspend();
    } else {
      resume();
    }
  }

  // ---------------------------------------------------------------------------
  // Event routing
  // ---------------------------------------------------------------------------

  /// Routes one platform event to the window it names.
  ///
  /// Returns whether anything consumed it, which a backend may use to let the
  /// platform have the event instead - a menu mnemonic, a window accelerator.
  ///
  /// Three kinds of event are dropped rather than delivered, silently but
  /// *countably* ([eventsDropped]):
  ///
  ///   * one naming a window this application does not have. Native code keeps
  ///     delivering callbacks for windows that have already closed - that is
  ///     the sentence `lifecycle.dart` opens with - so this is the normal case
  ///     and not an error;
  ///   * an input event from a superseded generation. It describes a surface
  ///     and a coordinate space that no longer exist, so its position is wrong
  ///     by however much the window moved or resized;
  ///   * a pointer, key or text event aimed at a window a modal child is
  ///     blocking.
  ///
  /// Key and text events are additionally refused when *another* window holds
  /// the keyboard, which is the exclusivity rule. When no window holds it -
  /// the instant between one window's deactivation and the next one's
  /// activation - the event is delivered to the window it names rather than
  /// dropped, because losing a keystroke the platform believes it delivered is
  /// worse than delivering one a moment early.
  bool handleEvent(PlatformWindowEvent event) {
    if (isDisposed) return false;

    final window = _byId[event.windowId];
    if (window == null || window.isDisposed) {
      _eventsDropped++;
      return false;
    }

    if (event is PlatformInputEvent) {
      if (event.generation != window.nativeWindow.generation) {
        _eventsDropped++;
        return false;
      }
      if (window.isBlocked) {
        _eventsDropped++;
        return false;
      }
    }

    switch (event) {
      case PointerEvent():
        // A press aimed at a window that owns live popups dismisses them
        // *before* anything is hit-tested, and then either stops or goes on.
        //
        // It has to happen here and not in the tree, for the reason the whole
        // window host exists: the popup is another window, so nothing in this
        // window's render tree can see the press that is meant to close it.
        // The rule it implements is `RenderPopupLayer._isModal`'s, and the two
        // must agree - a user pressing the same pixel must not get different
        // behaviour depending on which host the application happened to pick.
        if (event is PointerDownEvent) {
          final List<ApplicationWindow> popups = popupsOf(window);
          if (popups.isNotEmpty) {
            // The innermost popup decides, because it is the one on top: a
            // menu swallows the press that closes it, since the user was
            // aiming at "not the menu" and must not also press the button
            // behind it; a dropdown lets it through, because closing a combo
            // list by clicking a button should press that button.
            final PopupKind topmost = popups.last.popupKind!;
            _dismissPopupsOf(window);
            if (window.isDisposed) {
              _eventsDropped++;
              return false;
            }
            // Only the *owner's* content is shielded, never a popup's own.
            // `_isModal` shields child 0 and leaves the popups in the hit
            // path, so a press on a parent menu item still activates it while
            // closing the submenu; keying on popupKind is that same rule.
            if (window.popupKind == null && !topmost.dismissalPassesThrough) {
              window.requestFrame();
              return true;
            }
          }
        }
        // Layout must be current before hit testing, or the pointer is tested
        // against the previous frame's geometry - which is exactly wrong
        // during a resize, when the previous frame's geometry is the reason
        // this frame exists.
        window._settleForInput();
        if (!window._isHitTestable) {
          // The window is on screen and its tree has never been laid out. See
          // [ApplicationWindow._isHitTestable]; this is a startup race, not a
          // routing bug, which is why it asks for a frame on the way out.
          _eventsDropped++;
          window.requestFrame();
          return false;
        }
        final handled = window.buildOwner.dispatchPointerEvent(event);
        window.requestFrame();
        return handled;

      case KeyEvent():
        if (!_holdsKeyboard(window)) {
          _eventsDropped++;
          return false;
        }
        return _dispatchKeyboard(
          window,
          (ApplicationWindow target) =>
              target.buildOwner.dispatchKeyEvent(event),
        );

      case TextInputEvent():
        // Text follows the key that produced it, on the same focus route and
        // in the same frame budget. It is a separate arm rather than part of
        // the key arm because the backend produced it separately: the OS
        // applied the layout, the dead keys and the lock state, and this
        // framework is not entitled to a second opinion about what the user
        // typed.
        if (!_holdsKeyboard(window)) {
          _eventsDropped++;
          return false;
        }
        return _dispatchKeyboard(
          window,
          (ApplicationWindow target) =>
              target.buildOwner.dispatchTextInputEvent(event),
        );

      default:
        return _handleWindowEvent(window, event);
    }
  }

  bool _holdsKeyboard(ApplicationWindow window) =>
      _keyboardFocus == null || _keyboardFocus == window.id;

  /// Offers a keyboard event to [window]'s innermost live popup first, then to
  /// [window] itself.
  ///
  /// **A popup window never activates**, so the platform goes on delivering
  /// keys to the owner: the OS focus is the owner's and the framework focus
  /// may be inside the menu. That split is the whole design (see `WindowKind`
  /// for why activating a popup is refused - every caret in the window behind
  /// it would stop blinking while the user merely read a menu), and this is
  /// the redirection that pays for it.
  ///
  /// **If the popup does not consume the event, the owner still gets it.**
  /// That second half is not a nicety: it is what keeps Alt+F4 closing the
  /// application, and the window's own shortcut map working, while a menu is
  /// open. A tooltip is never a target - [PopupKind.takesKeyboard] is false
  /// for it - because a hover label that ate the user's typing would be an
  /// unexplainable dead keyboard.
  bool _dispatchKeyboard(
    ApplicationWindow window,
    bool Function(ApplicationWindow target) dispatch,
  ) {
    final ApplicationWindow target = _keyboardTargetOf(window);
    var handled = false;
    if (!identical(target, window)) {
      target._settleForInput();
      handled = dispatch(target);
      if (!target.isDisposed) target.requestFrame();
    }
    // The owner sees it whenever the popup did not, and always when there is
    // no popup - which is the unchanged path every existing test takes.
    if (!handled && !window.isDisposed) {
      window._settleForInput();
      handled = dispatch(window);
    }
    if (!window.isDisposed) window.requestFrame();
    return handled;
  }

  /// [window]'s innermost live popup that takes the keyboard, or [window].
  ApplicationWindow _keyboardTargetOf(ApplicationWindow window) {
    final List<ApplicationWindow> popups = popupsOf(window);
    for (var i = popups.length - 1; i >= 0; i--) {
      if (popups[i].popupKind!.takesKeyboard) return popups[i];
    }
    return window;
  }

  bool _handleWindowEvent(ApplicationWindow window, PlatformWindowEvent event) {
    // Two of the five dismissal routes, and both are things the popup itself
    // can never see because it is a different window.
    //
    //   * the frame of the owner was pressed - the user grabbed the title bar
    //     or a caption button. Avalonia subscribes to the same signal
    //     (`NonClientLeftButtonDown`) for the same reason; without it a menu
    //     floats over the desktop while the window it is anchored to is
    //     dragged out from under it;
    //   * the owner moved or was resized. A menu anchored to a window that
    //     has moved is pointing at nothing.
    //
    // The move and resize routes are restricted to windows that are not
    // themselves popups, because a popup's *own* placement is a move and a
    // resize: [openPopup] sets its bounds once, and a popup that dismissed its
    // children when it was first positioned would close every submenu the
    // instant it opened.
    if (event is WindowNonClientPressEvent) {
      _dismissPopupsOf(window);
    } else if (window.popupKind == null &&
        (event is WindowMovedEvent || event is WindowResizedEvent)) {
      _dismissPopupsOf(window);
    }
    if (event is WindowPointerLeaveEvent) {
      window.buildOwner.clearPointerHover();
      window.requestFrame();
    }
    final outcome = window.host.handleEvent(event);

    if (outcome.closeRequested) {
      _onCloseRequested(window);
      return true;
    }
    if (outcome.closed) {
      // The platform has already destroyed the window; releasing our half of
      // it is all that is left. Idempotent, so the close() inside the release
      // is a no-op on a handle that is already gone.
      window.dispose();
      return true;
    }
    final activation = outcome.activation;
    if (activation != null) {
      // Keeps the focus assignment but dims the ring, per section 28.3's
      // window-inactive pseudo-class.
      _setActivation(window, activation == WindowActivation.activated);
    }
    if (outcome.suspended) window._minimised = true;
    if (outcome.resumed) window._minimised = false;
    final size = outcome.logicalSize;
    if (size != null) {
      window.pipelineOwner.rootConstraints = BoxConstraints.tight(size);
    }
    window._syncMediaQuery();
    if (outcome.needsFrame) window.requestFrame();
    _syncSuspension();
    return outcome.needsFrame ||
        outcome.suspended ||
        outcome.surfaceInvalidated ||
        outcome.ignoredAsStale;
  }

  /// The user asked for a window to go away.
  void _onCloseRequested(ApplicationWindow window) {
    // A blocked window cannot be closed out from under its dialog. The dialog
    // gets the keyboard instead, which is what a user reading a modal expects
    // when they click the window behind it.
    final ApplicationWindow? modal = window.activeModal;
    if (modal != null) {
      focusWindow(modal.id);
      return;
    }
    // "The last window" means the last *top-level* one. A menu or a tooltip
    // being dismissed must never be able to end the application, which is the
    // bug every toolkit that counted windows instead of classifying them has
    // shipped at least once.
    final topLevel = topLevelWindows;
    final bool isLast = window.kind.isTopLevel &&
        topLevel.length == 1 &&
        identical(topLevel.single, window);
    if (isLast && options.exitWhenLastWindowClosed) {
      // See the library comment: teardown of the last window is the
      // application's single ordered pass, not an unwind from inside an event
      // handler that `run()` is still iterating around.
      requestClose();
      return;
    }
    closeWindow(window.id);
  }

  // ---------------------------------------------------------------------------
  // The loop
  // ---------------------------------------------------------------------------

  /// Runs until the application closes, the frame budget is met, or the backend
  /// says the platform asked the application to stop.
  ///
  /// The loop shape is forced by two facts about real backends. It blocks in
  /// the platform's event wait when there is nothing to draw, because a loop
  /// that spins pegs a core on an idle window; and it yields to the Dart event
  /// loop after every pump, because a backend delivers events through a
  /// broadcast `StreamController` whose listeners run on a later turn - pumping
  /// native messages without ever returning to that loop would queue every
  /// click and deliver none of them.
  ///
  /// One pump serves every window. That is not an optimisation: on Windows a
  /// thread has one message queue and `PeekMessage` with a null window drains
  /// all of it, so a per-window pump would either starve the windows that were
  /// not being pumped or race them for the same queue. Closing a window from
  /// inside the pump is safe for the same reason - the iteration is over the
  /// queue, never over the window list, and the list this loop walks is a copy.
  ///
  /// ## A frame budget is not optional on every backend
  ///
  /// With a budget, the loop deliberately runs flat out: every presented frame
  /// requests the next one. That is what a smoke run wants, and it is also the
  /// only terminating shape on a backend whose `pumpEvents` does not block.
  /// The headless backend is exactly that - "a headless pump never sleeps: no
  /// wall clock participates in delivery" - so `run()` against it with no
  /// budget, no close and nothing animating spins at full speed forever. Give
  /// it a budget, close the window from a callback, or drive
  /// [drawPendingFrames] yourself. A test should do the last of those: it needs
  /// no loop at all.
  Future<void> run({int? frameBudget}) async {
    throwIfDisposed();
    if (_runCalled) {
      throw StateError('Application.run() was called twice (state: $_state)');
    }
    if (_state == ApplicationLifecycleState.closing) {
      throw StateError('Application.run() after a close was requested');
    }
    _runCalled = true;
    final budget = frameBudget ?? options.frameBudget;
    _state = ApplicationLifecycleState.running;
    for (final ApplicationWindow window
        in List<ApplicationWindow>.of(_windows)) {
      window.nativeWindow.show();
    }

    // A run that has just started counts as active: the first wait is one
    // frame long, and the back-off takes it up to the idle timeout within a
    // handful of iterations if nothing turns out to be happening.
    _noteLoopProgress(progressed: true);

    while (_state == ApplicationLifecycleState.running ||
        _state == ApplicationLifecycleState.suspended) {
      final wantsFrame = _state == ApplicationLifecycleState.running &&
          (needsFrame || _overlayIsStale);
      // Dart timers run on this isolate and cannot interrupt the synchronous
      // native message wait, so the length of that wait *is* the latency of
      // every piece of pending Dart work. [_idlePumpWait] is the adaptive
      // answer to that - see [_noteLoopProgress]. An armed animation lowers it
      // further, to exactly one frame interval; that is the case this loop has
      // always handled, and it still wins over the adaptive value.
      Duration pumpTimeout = wantsFrame ? Duration.zero : _idlePumpWait;
      bool animating = false;
      if (!wantsFrame && _state == ApplicationLifecycleState.running) {
        for (final ApplicationWindow window in _windows) {
          if (window.isSuspended || !window.hasPendingAnimationFrame) continue;
          animating = true;
          if (window.scheduler.frameInterval < pumpTimeout) {
            pumpTimeout = window.scheduler.frameInterval;
          }
        }
      }
      // Pacing is for the adaptive path only. An armed animation already has
      // a deadline - its wake timer was armed *during* the frame, so it is
      // due one interval from then, not one interval from now - and taking
      // the work off this wait as well would wake the loop before the timer
      // was due, find nothing, and then sleep a second full interval straight
      // past it. Leaving the animation path exactly as it was is also what
      // makes "the existing animation case does not regress" checkable.
      if (!animating) pumpTimeout = _pacedPumpTimeout(pumpTimeout);
      if (!backend.pumpEvents(
        timeout: pumpTimeout,
      )) {
        break;
      }
      _sincePumpReturned
        ..reset()
        ..start();
      await Future<void>.delayed(Duration.zero);
      // Read after the yield: that is the single turn this iteration gives the
      // Dart event loop, so it is the only point at which the loop can observe
      // whether the turn produced anything.
      final bool progressed = _state == ApplicationLifecycleState.running &&
          (wantsFrame || needsFrame || _overlayIsStale || _isAnimating);
      _noteLoopProgress(progressed: progressed);
      if (_state != ApplicationLifecycleState.running) continue;
      if (needsFrame || _overlayIsStale) await drawPendingFrames();
      if (budget > 0) {
        if (framesPresented >= budget) break;
        // A budgeted run wants frames as fast as it can get them; an
        // interactive one waits for something to actually change.
        requestFrame();
      }
    }
    if (_state != ApplicationLifecycleState.closed) {
      _state = ApplicationLifecycleState.closing;
    }
  }

  /// Whether any live window is waiting on a timer-driven animation frame.
  bool get _isAnimating {
    for (final ApplicationWindow window in _windows) {
      if (!window.isSuspended && window.hasPendingAnimationFrame) return true;
    }
    return false;
  }

  /// The shortest wait that still lets every live window run at its own frame
  /// rate: one frame interval, never longer than
  /// [ApplicationOptions.idleTimeout] - which stays the ceiling on every path.
  Duration get _activePumpSlice {
    Duration slice = options.idleTimeout;
    for (final ApplicationWindow window in _windows) {
      if (window.isDisposed || window.isSuspended) continue;
      final Duration interval = window.scheduler.frameInterval;
      if (interval < slice) slice = interval;
    }
    return slice;
  }

  /// [wait], less the time this iteration has already spent working.
  ///
  /// A slice names how often the loop wants a turn, not how long it wants to
  /// sleep on top of everything else it did. Without this, a loop that waits
  /// one frame interval and then spends nine milliseconds building, laying out
  /// and presenting runs at 1/(16.7+9) ms - 39 Hz - and no amount of shortening
  /// the wait fixes the arithmetic, because the work is on the other side of
  /// the addition.
  ///
  /// Clamped at zero, which is a non-blocking pump: an iteration that already
  /// overran its slice is saturated, and the honest thing is to go straight
  /// back to the queue rather than to sleep on top of being late.
  ///
  /// Not applied while an animation frame is armed; see the call site.
  Duration _pacedPumpTimeout(Duration wait) {
    if (wait <= Duration.zero || !_sincePumpReturned.isRunning) return wait;
    final Duration remaining = wait - _sincePumpReturned.elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Moves the adaptive idle wait after one turn of [run]'s loop.
  ///
  /// ## Why the wait has to adapt at all
  ///
  /// [WindowingBackend.pumpEvents] is a *synchronous* wait on the platform's
  /// queue. While the isolate sits inside it no Dart timer fires, no `Future`
  /// continuation resumes and no I/O callback is delivered; the loop hands the
  /// Dart event loop exactly one turn per iteration, immediately after the
  /// wait returns. The length of that wait is therefore the latency of every
  /// piece of pending Dart work, and a flat 250 ms idle timeout turns an
  /// ordinary `Timer.periodic` of 16 ms into a 4 Hz stutter with nothing wrong
  /// with the timer.
  ///
  /// Exactly one class of pending work used to shorten the wait: an armed
  /// animation frame, which the loop can see through
  /// [ApplicationWindow.hasPendingAnimationFrame]. Everything else - an
  /// application timer, a decoded frame arriving over a port, an `await` that
  /// is merely ready to resume - is invisible from here, because Dart exposes
  /// no way to ask "is anything queued, and when is it due". The loop cannot
  /// know in advance; what it can do is remember what the last few turns
  /// looked like.
  ///
  /// ## The policy
  ///
  /// Exponential back-off, reset by progress:
  ///
  ///   * a turn that produced something - a frame was drawn, a window came out
  ///     of the yield dirty, an animation is armed - resets the wait to
  ///     [_activePumpSlice], one frame interval. An application that is doing
  ///     something therefore gets its Dart turns at display rate.
  ///   * a turn that produced nothing doubles the wait, up to
  ///     [ApplicationOptions.idleTimeout].
  ///
  /// Counted in loop iterations rather than in wall time on purpose: it needs
  /// no clock, which this file deliberately never reads, and it costs a
  /// genuinely idle window five extra wake-ups *once* - 16, 33, 66, 133, 250
  /// ms - after which it is back to the four wake-ups a second the flat
  /// timeout gave it. What it buys is that the wake-up which does find work is
  /// followed by short waits, so a burst of asynchronous work runs at frame
  /// rate instead of advancing one step per idle timeout.
  ///
  /// A suspended or closing application never counts as progressing, so it
  /// returns to the ceiling within a few iterations rather than spinning while
  /// minimised.
  void _noteLoopProgress({required bool progressed}) {
    final Duration ceiling = options.idleTimeout;
    if (progressed) {
      _idlePumpWait = _activePumpSlice;
      return;
    }
    if (_idlePumpWait <= Duration.zero || _idlePumpWait >= ceiling) {
      _idlePumpWait = ceiling;
      return;
    }
    final Duration doubled = _idlePumpWait * 2;
    _idlePumpWait = doubled < ceiling ? doubled : ceiling;
  }

  /// Whether the overlay's numbers are old enough to be worth a repaint.
  bool get _overlayIsStale =>
      options.showDevOverlay &&
      _sinceOverlayRefresh.elapsed >= options.devOverlayInterval;

  /// Releases everything, last acquired first, exactly once.
  ///
  /// The order that comes out of [DisposableBag] is: the newest window first
  /// and, within each window, its build owner, scheduler, window host (and with
  /// it the presenter), event subscription and native window; then the backend.
  /// Each of those depends on the one after it, and reversing any adjacent pair
  /// is a use-after-free in a real backend - which is why `lifecycle.dart`
  /// makes the order structural rather than a comment.
  @override
  void onDispose() {
    // Snapshotted while the trees are still alive; the summary is printed
    // after they are gone. Folded here rather than read through [controlCount]
    // and [semanticNodeCount], because `DisposableMixin.dispose` has already
    // flipped `isDisposed` by the time this runs - so those getters would be
    // reading the very fields being written, and both counts would snapshot as
    // zero.
    _controlCount = _windows.fold<int>(0, (sum, w) => sum + w.controlCount);
    _semanticNodeCount =
        _windows.fold<int>(0, (sum, w) => sum + w.semanticNodeCount);
    _state = ApplicationLifecycleState.closing;
    _tearingDown = true;
    _resources.dispose();
    // The policy is process-wide, so a disposed application has to put it
    // back: otherwise one test's kill switch configures every test that runs
    // after it in the same isolate, which is the failure mode a global exists
    // to earn its way past.
    RenderPolicyScope.reset();
    _state = ApplicationLifecycleState.closed;
  }

  /// What the renderer recorded about the last frame it drew.
  ///
  /// [FrameRenderDiagnostics.empty] unless [ApplicationOptions.renderPolicy]
  /// turned recording on, and in that case reading it is the only thing that
  /// allocates - see `render_diagnostics.dart`.
  FrameRenderDiagnostics get renderDiagnostics =>
      RenderPolicyScope.diagnostics.snapshot();

  @override
  String toString() => 'Application(state: ${_state.name}, '
      'backend: ${backend.name}, windows: ${_windows.length}, '
      'frames: $framesPresented)';
}
