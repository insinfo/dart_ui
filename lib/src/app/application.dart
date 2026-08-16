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
/// ## Startup order, and why teardown is its exact reverse
///
///   1. **Select a windowing backend.** Through `backend_selection.dart`, with
///      a report that names every candidate and why each was passed over -
///      including the healthy ones. Failure throws [BackendSelectionError]
///      carrying *all* the probes, never a fallback nobody was told about.
///   2. **Initialize it and create the window.**
///   3. **Select a presentation path** and attach a [SurfacePresenter] to the
///      window, producing a [WindowHost].
///   4. **Subscribe to the window's events.**
///   5. **Build the frame plumbing:** a [ManualDispatcher], a [FrameScheduler]
///      over a [PipelineOwner], then a [BuildOwner] over the same pipeline.
///   6. **Mount the root widget.**
///
/// Each step is registered with a [DisposableBag] as it succeeds, so teardown
/// runs 6 -> 1 with no ordering decision left to make at shutdown - which is
/// the whole reason `lifecycle.dart` has a bag at all. A startup that fails
/// half-way disposes exactly what it built, and disposing twice is a no-op.
///
/// ## Lifecycle, stated as policy
///
/// The states are [ApplicationLifecycleState]. What happens to a frame that is
/// in flight across each transition is the question that actually matters, so:
///
///   * **starting -> running.** No frame is in flight. The root is mounted on
///     the first [drawFrame], not at [start], so a caller can attach
///     diagnostics between the two.
///   * **running -> suspended** (window minimised, or deactivated when
///     [ApplicationOptions.suspendWhenDeactivated] is set). A frame already
///     begun runs to completion and is *presented if its generation still
///     matches*. Throwing away pixels that are already rasterised buys
///     nothing; what suspension stops is the *next* frame. While suspended the
///     loop still pumps events - a suspended application that stopped reading
///     its message queue would be an unresponsive window, which on Windows is
///     a visible failure.
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
library;

import 'dart:async';

import '../diagnostics/dev_overlay.dart';
import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
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

  /// Teardown has been requested and the frame in flight has been invalidated.
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

/// A way of getting pixels onto the chosen window's surface.
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

  /// Binds this path to the live window. Called only for the winner.
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
    this.gpuPresentationCapability = kGpuPresentationCapability,
    this.arguments = const <String>[],
    this.environment = const <String, String>{},
    this.clipboard,
    this.onError,
    this.onDiagnostic,
  });

  final String title;

  /// Initial client size in logical units.
  final Size size;

  /// Whether the window is mapped at creation.
  ///
  /// Defaults to false, and [Application.run] calls `show()` itself. A window
  /// that appears before its first frame flashes whatever the platform put in
  /// it, which on Windows is the desktop behind it.
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

  /// Stop after this many presented frames; 0 runs until the window closes.
  /// What makes an example runnable in CI.
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

  /// Whether losing window activation suspends the frame loop.
  ///
  /// Off by default: a background window that stops animating is correct for a
  /// game and wrong for a text editor with a blinking caret, and the framework
  /// cannot know which it is in.
  final bool suspendWhenDeactivated;

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
/// [Application.start] instead when the loop needs to be driven by hand.
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

/// The assembled application: backend, window, renderer, tree and frame loop.
final class Application with DisposableMixin {
  Application._({
    required this.options,
    required this.backend,
    required this.window,
    required this.host,
    required this.scheduler,
    required this.buildOwner,
    required this.windowingSelection,
    required this.presentationSelection,
    required DisposableBag resources,
    required Widget rootWidget,
  })  : _resources = resources,
        _rootWidget = rootWidget;

  /// Assembles everything and stops short of the first frame.
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

      // --- 3. window ---------------------------------------------------
      final window = await backend.createWindow(WindowOptions(
        title: options.title,
        size: options.size,
        visible: options.visible,
      ));
      resources.add(window, () {
        teardown.add('window');
        window.close();
      });

      // --- 4. presenter and host ---------------------------------------
      final presenter = await path.attach(window);
      final host = WindowHost(
        window: window,
        presenter: presenter,
        onDiagnostic: options.onDiagnostic,
      );
      resources.add(host, () {
        teardown.add('host');
        host.dispose();
      });

      // --- 5. frame plumbing -------------------------------------------
      // Order is forced by two constructor preconditions, and both are worth
      // stating: `FrameScheduler` refuses a `PipelineOwner` that already has a
      // visual-update owner, and `BuildOwner` refuses one that already has a
      // root. So the pipeline is created bare, the scheduler claims the
      // update hook, and the build owner claims the root.
      final pipelineOwner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(window.clientSize),
      );
      final scheduler = FrameScheduler(
        dispatcher: ManualDispatcher(),
        pipelineOwner: pipelineOwner,
        onFrame: (DisplayList list) => application._onPainted(list),
      );
      resources.add(scheduler, () {
        teardown.add('scheduler');
        scheduler.dispose();
      });

      final buildOwner = BuildOwner(
        pipelineOwner: pipelineOwner,
        // A build scheduled outside a frame - a setState from a callback -
        // marks the next frame dirty rather than painting immediately.
        // Painting inline would produce two frames for one user action.
        onBuildScheduled: () => application._requestFrameFromTree(),
      );
      resources.add(buildOwner, () {
        teardown.add('buildOwner');
        buildOwner.dispose();
      });

      application = Application._(
        options: options,
        backend: backend,
        window: window,
        host: host,
        scheduler: scheduler,
        buildOwner: buildOwner,
        windowingSelection: windowingSelection,
        presentationSelection: presentationSelection,
        resources: resources,
        rootWidget: rootWidget,
      );
      application._teardownOrder = teardown;
      buildOwner.errorReporter = ErrorReporter(onError: options.onError);
      buildOwner.focusManager.isWindowActive = true;

      // --- 6. events ---------------------------------------------------
      // Subscribed last and cancelled first: an event delivered into a
      // half-disposed tree is the classic teardown crash, and the stream
      // outlives the tree by construction.
      final subscription = window.events.listen(
        application.handleEvent,
        onError: application._onStreamError,
      );
      resources.add(subscription, () {
        teardown.add('events');
        unawaited(subscription.cancel());
      });
      return application;
    } on Object {
      resources.dispose();
      rethrow;
    }
  }

  final ApplicationOptions options;
  final WindowingBackend backend;
  final NativeWindow window;
  final WindowHost host;
  final FrameScheduler scheduler;
  final BuildOwner buildOwner;

  /// The full windowing report - chosen, and every candidate passed over with
  /// the named reason. Worth logging on every startup, not only on failure.
  final BackendSelection windowingSelection;
  final PresentationSelection presentationSelection;

  final DisposableBag _resources;
  final FrameStatistics statistics = FrameStatistics();
  final Stopwatch _sinceOverlayRefresh = Stopwatch()..start();

  Widget _rootWidget;
  List<String> _teardownOrder = const <String>[];
  Future<void>? _pendingShutdown;
  DisplayList? _painted;
  ApplicationLifecycleState _state = ApplicationLifecycleState.starting;
  bool _rootMounted = false;
  bool _needsFrame = true;
  bool _inFrame = false;
  bool _runCalled = false;
  int _framesPresented = 0;
  int _controlCount = 0;
  int _semanticNodeCount = 0;

  /// How many settle passes one frame may take before it is declared
  /// divergent.
  ///
  /// A settled frame is not one build plus one layout. The virtualized list
  /// realizes items against an *estimated* viewport until layout measures the
  /// real one, then rebuilds with the true window - two passes, legitimately.
  /// A tree that never settles is a bug that must be a message rather than a
  /// hang.
  static const int _maxSettlePasses = 8;

  PipelineOwner get pipelineOwner => scheduler.pipelineOwner;
  ManualDispatcher get dispatcher => scheduler.dispatcher;
  ApplicationLifecycleState get state => _state;

  /// Frames actually put on screen. Rejected frames are not counted here;
  /// [WindowHost.framesRejected] has those.
  int get framesPresented => _framesPresented;
  int get framesRejected => host.framesRejected;

  bool get needsFrame => _needsFrame;

  /// Build failures contained by the reporter rather than propagated.
  List<FrameworkError> get errors => buildOwner.errorReporter.errors;

  /// Framework-owned controls in the render tree.
  ///
  /// Snapshotted during teardown so the number survives it - which is what
  /// makes "no native control anywhere in the tree" a checkable claim rather
  /// than a promise.
  int get controlCount =>
      isDisposed ? _controlCount : _countControls(buildOwner.renderRoot);

  int get semanticNodeCount => isDisposed
      ? _semanticNodeCount
      : buildOwner.buildSemantics().nodes.length;

  /// What was released, in the order it was released. Empty until [dispose].
  List<String> get teardownOrder => List<String>.unmodifiable(_teardownOrder);

  /// Completes when the backend's asynchronous shutdown has finished.
  ///
  /// [dispose] is synchronous because [Disposable] is, and a backend's
  /// `shutdown()` is not. Rather than pretend, the bag starts the shutdown and
  /// this future is where it lands.
  Future<void> get closed => _pendingShutdown ?? Future<void>.value();

  /// Both selection reports, ready to be logged verbatim on startup.
  String describeStartup() => '${windowingSelection.describe()}'
      '${presentationSelection.describe()}'
      '  renderer: ${host.presenter.info}\n'
      '  window: ${host.logicalSize.width}x${host.logicalSize.height} '
      '@ ${host.renderScale}x (desktop ${host.desktopScale}x)\n';

  /// Replaces the root widget. Reconciles rather than remounting when the
  /// widget type and key allow it, so state survives a theme change.
  void updateRoot(Widget widget) {
    throwIfDisposed();
    _rootWidget = widget;
    if (_rootMounted) buildOwner.updateRoot(_mountableRoot);
    requestFrame();
  }

  /// The clipboard this application's widget tree can reach.
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
  /// Never null in any of the three.
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

  /// The root as the tree actually mounts it.
  ///
  /// Wrapped in a [ClipboardScope] here rather than left to the caller for the
  /// same reason the theme is inherited rather than passed: every text field
  /// needs the clipboard, none of them should be handed one by its parent, and
  /// an application that forgot the wrapper would have a Ctrl+V that silently
  /// did nothing in half its screens.
  Widget get _mountableRoot =>
      ClipboardScope(clipboard: clipboard, child: _rootWidget);

  /// Marks the next frame dirty. Idempotent; many mutations coalesce into one.
  void requestFrame() {
    if (isDisposed) return;
    _needsFrame = true;
  }

  void _requestFrameFromTree() {
    if (_inFrame) return;
    requestFrame();
  }

  /// Asks the loop to stop and tear down cleanly.
  ///
  /// Invalidates the host's generation immediately, which is what rejects a
  /// frame that is mid-`await`: it would otherwise land in a surface that
  /// teardown is about to free.
  void requestClose() {
    if (isDisposed || _state == ApplicationLifecycleState.closing) return;
    _state = ApplicationLifecycleState.closing;
    host.surfaceChanged(logicalSize: Size.zero);
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

  /// Resumes and requests a full repaint, because the window's contents may
  /// have been discarded while it was away.
  void resume() {
    if (isDisposed || _state != ApplicationLifecycleState.suspended) return;
    _state = ApplicationLifecycleState.running;
    requestFrame();
  }

  /// Routes one platform event into the tree.
  ///
  /// Returns whether anything consumed it, which a backend may use to let the
  /// platform have the event instead - a menu mnemonic, a window accelerator.
  bool handleEvent(PlatformWindowEvent event) {
    if (isDisposed) return false;

    switch (event) {
      case PointerEvent():
        // Layout must be current before hit testing, or the pointer is tested
        // against the previous frame's geometry - which is exactly wrong
        // during a resize, when the previous frame's geometry is the reason
        // this frame exists.
        _settleForInput();
        final handled = buildOwner.dispatchPointerEvent(event);
        requestFrame();
        return handled;

      case KeyEvent():
        _settleForInput();
        final handled = buildOwner.dispatchKeyEvent(event);
        requestFrame();
        return handled;

      case TextInputEvent():
        // Text follows the key that produced it, on the same focus route and
        // in the same frame budget. It is a separate arm rather than part of
        // the key arm because the backend produced it separately: the OS
        // applied the layout, the dead keys and the lock state, and this
        // framework is not entitled to a second opinion about what the user
        // typed.
        _settleForInput();
        final handled = buildOwner.dispatchTextInputEvent(event);
        requestFrame();
        return handled;

      default:
        return _handleWindowEvent(event);
    }
  }

  bool _handleWindowEvent(PlatformWindowEvent event) {
    final outcome = host.handleEvent(event);

    if (outcome.closeRequested) {
      requestClose();
      return true;
    }
    if (outcome.closed) {
      _state = ApplicationLifecycleState.closing;
      return true;
    }
    final activation = outcome.activation;
    if (activation != null) {
      // Keeps the focus assignment but dims the ring, per section 28.3's
      // window-inactive pseudo-class.
      buildOwner.focusManager.isWindowActive =
          activation == WindowActivation.activated;
      if (options.suspendWhenDeactivated) {
        activation == WindowActivation.activated ? resume() : suspend();
      }
    }
    if (outcome.suspended) suspend();
    final size = outcome.logicalSize;
    if (size != null) {
      pipelineOwner.rootConstraints = BoxConstraints.tight(size);
    }
    if (outcome.resumed) resume();
    if (outcome.needsFrame) requestFrame();
    return outcome.needsFrame ||
        outcome.suspended ||
        outcome.surfaceInvalidated ||
        outcome.ignoredAsStale;
  }

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

  /// Builds, lays out, paints and presents exactly one frame.
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
        'Application.drawFrame() is not reentrant. A frame requested from '
        'inside a frame is coalesced into the next one; call requestFrame().',
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
    if (_state == ApplicationLifecycleState.starting) {
      _state = ApplicationLifecycleState.running;
    }
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
      final result =
          await host.present(frame, list, clearColor: options.clearColor);
      stopwatch.stop();

      if (result.status == PresentStatus.deviceLost) {
        // Not a retry of this frame: the device it was built against is gone.
        // Recover, then ask for a fresh one against the new device.
        final recovered = await host.recoverFromDeviceLoss();
        if (recovered) {
          requestFrame();
        } else {
          requestClose();
        }
        return result;
      }
      if (result.isSuccess) {
        _framesPresented++;
        statistics.record(FrameTiming(
          build: build,
          paint: paint,
          raster: stopwatch.elapsedMicroseconds - build - paint,
        ));
        if (options.showDevOverlay) _sinceOverlayRefresh.reset();
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

  /// Receives the finished display list from [FrameScheduler].
  void _onPainted(DisplayList list) {
    if (options.showDevOverlay) {
      DevOverlay(statistics: statistics).paint(
        list,
        Rect.fromLTWH(0, 0, host.logicalSize.width, host.logicalSize.height),
      );
    }
    _painted = list;
  }

  /// Runs until the window closes, the frame budget is met, or the backend
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
  /// ## A frame budget is not optional on every backend
  ///
  /// With a budget, the loop deliberately runs flat out: every presented frame
  /// requests the next one. That is what a smoke run wants, and it is also the
  /// only terminating shape on a backend whose `pumpEvents` does not block.
  /// The headless backend is exactly that - "a headless pump never sleeps: no
  /// wall clock participates in delivery" - so `run()` against it with no
  /// budget, no close and nothing animating spins at full speed forever. Give
  /// it a budget, close the window from a callback, or drive [drawFrame]
  /// yourself. A test should do the last of those: it needs no loop at all.
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
    window.show();

    while (_state == ApplicationLifecycleState.running ||
        _state == ApplicationLifecycleState.suspended) {
      final wantsFrame = _state == ApplicationLifecycleState.running &&
          (_needsFrame || _overlayIsStale);
      if (!backend.pumpEvents(
        timeout: wantsFrame ? Duration.zero : options.idleTimeout,
      )) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
      if (_state != ApplicationLifecycleState.running) continue;
      if (_needsFrame || _overlayIsStale) await drawFrame();
      if (budget > 0) {
        if (_framesPresented >= budget) break;
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

  void _onStreamError(Object error, StackTrace stackTrace) {
    buildOwner.errorReporter.report(FrameworkError(
      phase: FrameworkPhase.build,
      cause: error,
      stackTrace: stackTrace,
      context: 'the window event stream failed',
    ));
  }

  /// Releases everything, last acquired first, exactly once.
  ///
  /// The order that comes out of [DisposableBag] is: build owner, scheduler,
  /// window host (and with it the presenter), the event subscription, the
  /// window, the backend. Each of those depends on the one after it, and
  /// reversing any adjacent pair is a use-after-free in a real backend - which
  /// is why `lifecycle.dart` makes the order structural rather than a comment.
  @override
  void onDispose() {
    // Snapshotted while the tree is still alive; the summary is printed after
    // it is gone.
    _controlCount = _countControls(buildOwner.renderRoot);
    _semanticNodeCount = buildOwner.buildSemantics().nodes.length;
    _state = ApplicationLifecycleState.closing;
    _resources.dispose();
    _painted = null;
    // A disposed application owes nobody a frame. Leaving this set would make
    // `needsFrame` outlive the thing that could satisfy it.
    _needsFrame = false;
    _state = ApplicationLifecycleState.closed;
  }

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
