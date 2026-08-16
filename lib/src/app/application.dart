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
import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/pipeline.dart';
import '../layout/render_box.dart';
import '../platform/backend_selection.dart';
import '../platform/clipboard.dart';
import '../platform/input_events.dart';
import '../platform/native_window.dart';
import '../platform/window_events.dart';
import '../rendering/cpu_renderer.dart';
import '../rendering/renderer.dart';
import '../scheduler/frame_scheduler.dart';
import '../scheduler/manual_dispatcher.dart';
import '../widgets/context_menu.dart' show ContextMenuScope;
import '../widgets/control.dart';
import '../widgets/controls.dart' show ClipboardScope;
import '../widgets/element.dart';
import '../widgets/errors.dart';
import '../widgets/widget.dart';
import 'window_host.dart';

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
    this.experimental = false,
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
  }) =>
      PresentationPathEntry(
        name: name,
        kind: PresentationKind.cpu,
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
        attach: (NativeWindow window) async =>
            CallbackSurfacePresenter.retained(
          info: RendererInfo(
            name: name,
            deviceDescription: deviceDescription,
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
        probe: backend.probe,
        attach: (NativeWindow window) =>
            RenderTargetPresenter.attach(backend: backend, window: window),
      );

  final String name;
  final PresentationKind kind;

  /// Asked once, during selection. Must not throw: a probe that throws takes
  /// the whole selection down instead of losing one candidate.
  final BackendProbeResult Function() probe;

  /// Binds this path to a live window. Called once per window, for the winner
  /// only - every window of one application gets its own presenter, because a
  /// presenter is bound to one surface.
  final Future<SurfacePresenter> Function(NativeWindow window) attach;

  final bool experimental;
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
    this.arguments = const <String>[],
    this.environment = const <String, String>{},
    this.clipboard,
    this.onError,
    this.onDiagnostic,
  });

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

  /// Premultiplied BGRA packed into a 32-bit int, or null to leave whatever
  /// the previous frame left. Null is only safe when the tree paints an opaque
  /// background of its own - the gallery does.
  final int? clearColor;

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
  /// Premultiplied BGRA in a 32-bit int, the same encoding as [clearColor], or
  /// null for the system's window colour. Distinct from [clearColor], which is
  /// what the *renderer* clears the framebuffer to: this one is used at moments
  /// when there is no framebuffer covering the pixel at all, which is exactly
  /// when [clearColor] cannot help.
  ///
  /// Set it to the tree's own background and a resize stops showing a colour
  /// the application never chose.
  final int? windowBackgroundColor;

  /// Passed through to [selectPresentation]. Defaults to
  /// [kGpuPresentationCapability]; setting it to null makes every GPU path
  /// rejected by name rather than silently outranked, which is the right
  /// setting for an application that wants to prove it is on the CPU path.
  final Capability? gpuPresentationCapability;

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

  /// Where a build/layout/paint failure goes. Null installs a reporter that
  /// contains the error - the frame still draws, minus the failed subtree -
  /// and records it in [Application.errors].
  final void Function(FrameworkError error)? onError;

  /// Where a non-fatal presentation failure goes.
  final void Function(BackendDiagnostic diagnostic)? onDiagnostic;
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
  try {
    await application.run();
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
  final int? clearColor;

  final DisposableBag _resources;

  Widget _rootWidget;
  DisplayList? _painted;
  bool _rootMounted = false;
  bool _needsFrame = true;
  bool _inFrame = false;
  bool _minimised = false;
  bool _active = false;
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
  Widget get _mountableRoot => ClipboardScope(
        clipboard: application.clipboard,
        child: ContextMenuScope(child: _rootWidget),
      );

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
        clearColor: clearColor ?? application.options.clearColor,
      );
      stopwatch.stop();

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
      return result;
    } finally {
      _inFrame = false;
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
      var pass = 0;
      while (pass++ < _maxSettlePasses) {
        buildOwner.buildScope();
        scheduler.scheduleFrame();
        scheduler.pump();
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
        clearColor: clearColor ?? application.options.clearColor,
      );
      stopwatch.stop();
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
    } finally {
      _inFrame = false;
    }
  }

  /// Receives the finished display list from [FrameScheduler].
  void _onPainted(DisplayList list) {
    if (application.options.showDevOverlay) {
      DevOverlay(statistics: application.statistics).paint(
        list,
        Rect.fromLTWH(0, 0, host.logicalSize.width, host.logicalSize.height),
      );
    }
    _painted = list;
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    buildOwner.errorReporter.report(FrameworkError(
      phase: FrameworkPhase.build,
      cause: error,
      stackTrace: stackTrace,
      context: 'the window event stream failed',
    ));
  }

  /// Releases everything this window acquired, last first, exactly once.
  @override
  void onDispose() {
    // Snapshotted while the tree is still alive; a summary is printed after it
    // is gone.
    _controlCount = _countControls(buildOwner.renderRoot);
    _semanticNodeCount = buildOwner.buildSemantics().nodes.length;
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
    required DisposableBag resources,
    required List<String> teardownOrder,
  })  : _presentationPath = presentationPath,
        _resources = resources,
        _teardownOrder = teardownOrder;

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
    final presentationSelection = selectPresentation(
      <PresentationCandidate>[
        for (final path in paths)
          PresentationCandidate(
            name: path.name,
            kind: path.kind,
            probe: path.probe(),
            experimental: path.experimental,
          ),
      ],
      requested: options.requestedPresentation,
      preferred: options.preferredPresentations,
      allowExperimental: options.allowExperimentalBackends,
      arguments: options.arguments,
      environment: options.environment,
      gpuPresentationCapability: options.gpuPresentationCapability,
    );
    if (!presentationSelection.isSuccess) throw presentationSelection.toError();
    final path = paths.firstWhere(
      (entry) => entry.name == presentationSelection.chosen!.name,
    );

    // Acquisition order is teardown order, reversed. Registered as each step
    // succeeds so a failure half-way releases exactly what was built.
    final resources = DisposableBag();
    final teardown = <String>[];
    late final Application application;

    try {
      await backend.initialize();
      resources.add(backend, () {
        teardown.add('backend');
        application._pendingShutdown = backend.shutdown();
      });

      application = Application._(
        options: options,
        backend: backend,
        windowingSelection: windowingSelection,
        presentationSelection: presentationSelection,
        presentationPath: path,
        resources: resources,
        teardownOrder: teardown,
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
  final PresentationSelection presentationSelection;

  final PresentationPathEntry _presentationPath;
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
    int? clearColor,
    int? backgroundColor,
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
        backgroundColor: backgroundColor ??
            options.windowBackgroundColor ??
            clearColor ??
            options.clearColor,
        owner: ownerWindow?.nativeWindow,
        kind: kind,
      ));
      bag.add(native, () {
        _teardownOrder.add('window');
        native.close();
      });

      // --- b. presenter and host ---------------------------------------
      final presenter = await _presentationPath.attach(native);
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
      buildOwner.errorReporter = ErrorReporter(onError: options.onError);

      // --- d. events ----------------------------------------------------
      // Subscribed last and cancelled first: an event delivered into a
      // half-disposed tree is the classic teardown crash, and the stream
      // outlives the tree by construction. Routed through the application
      // rather than straight into this window, because the windowId on the
      // event is the authority on where it belongs - a backend that mislabels
      // one must not be able to smuggle it into the wrong tree.
      final subscription = native.events.listen(
        handleEvent,
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
        window._settleForInput();
        final handled = window.buildOwner.dispatchKeyEvent(event);
        window.requestFrame();
        return handled;

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
        window._settleForInput();
        final handled = window.buildOwner.dispatchTextInputEvent(event);
        window.requestFrame();
        return handled;

      default:
        return _handleWindowEvent(window, event);
    }
  }

  bool _holdsKeyboard(ApplicationWindow window) =>
      _keyboardFocus == null || _keyboardFocus == window.id;

  bool _handleWindowEvent(ApplicationWindow window, PlatformWindowEvent event) {
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

    while (_state == ApplicationLifecycleState.running ||
        _state == ApplicationLifecycleState.suspended) {
      final wantsFrame = _state == ApplicationLifecycleState.running &&
          (needsFrame || _overlayIsStale);
      if (!backend.pumpEvents(
        timeout: wantsFrame ? Duration.zero : options.idleTimeout,
      )) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
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
    _state = ApplicationLifecycleState.closed;
  }

  @override
  String toString() => 'Application(state: ${_state.name}, '
      'backend: ${backend.name}, windows: ${_windows.length}, '
      'frames: $framesPresented)';
}

extension _LastOrNull<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : this[length - 1];
}
