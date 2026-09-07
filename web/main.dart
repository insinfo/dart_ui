/// The gallery, in a browser, on WebGL2.
///
/// The web counterpart of `example/gallery_headless.dart`, and the thing to
/// notice is how little differs: the widget tree is the same `Gallery`, the
/// options are the same `ApplicationOptions`, and the frame loop draws the same
/// display lists. What changes is two entries - a [WebWindowingBackend] instead
/// of a headless or Win32 one, and a WebGL2 presentation path instead of the
/// CPU renderer - plus the one thing a browser genuinely does differently,
/// which is who owns the clock.
///
/// ## Why this does not call `Application.run()`
///
/// `Application.run()` is a `while` loop that pumps the backend and yields with
/// `await Future.delayed(Duration.zero)`. On Win32 that is right: `pumpEvents`
/// blocks in `GetMessage` until something happens, so the loop sleeps when the
/// application is idle.
///
/// A browser has no such call. `WebWindowingBackend.pumpEvents` returns
/// immediately and always - the browser *is* the event loop, and DOM events are
/// delivered to listeners whether or not anybody asks. So `run()` here would
/// spin through timers at whatever rate the microtask queue allows, burning a
/// core to redraw a static page. `Application`'s own documentation says what to
/// do instead: "drive `drawPendingFrames` yourself".
///
/// That is what [_FrameLoop] below does, from `requestAnimationFrame`, which is
/// the browser's real frame clock - vsync-aligned, throttled in a background
/// tab, and the only callback in which a WebGL drawing buffer is composited the
/// way the application intended. See `webgl_canvas_target.dart` on why a frame
/// must be drawn inside one callback and not across two.
///
/// ## Building and running
///
/// ```
/// dart compile js -O2 -o web/main.dart.js web/main.dart
/// dart run tool/serve_web.dart          # or any static file server
/// ```
///
/// `dart compile wasm` also works and produces `main.wasm` plus `main.mjs`;
/// `index.html` loads the JavaScript build, because that is the one a plain
/// `<script>` tag can take.
library;

import 'dart:js_interop';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/web/dom/dom_presenter.dart';
import 'package:dart_ui/src/backends/web/dom/dom_scene.dart';
import 'package:dart_ui/src/backends/web/web_fonts.dart';
import 'package:dart_ui/src/backends/web/web_gl_presenter.dart';
import 'package:dart_ui/src/backends/web/web_gpu_presenter.dart';
import 'package:dart_ui/src/backends/web/web_window.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_backend.dart';
import 'package:web/web.dart' as web;

/// Asks whether this browser has WebGL2.
///
/// A top-level function rather than `const WebGlRendererBackend().probe`,
/// because a tear-off of an *instance* method is not a constant expression and
/// the entry above wants to be `const`. The probe creates and throws away a
/// detached 1x1 canvas - see `WebGlRendererBackend.probe` - and never throws,
/// so a browser without WebGL2 produces a named rejection in the startup report
/// rather than an exception out of `Application.start`.
BackendProbeResult _probeWebGl2() => const WebGlRendererBackend().probe();

/// Asks whether this browser has WebGPU at all.
///
/// A top-level function for [_probeWebGl2]'s reason. The probe is synchronous
/// and WebGPU's real answers are not, so it checks only that `navigator.gpu`
/// exists; the adapter is requested inside `WebGpuCanvasPresenter.attach`,
/// and a refusal there is what the fallback below exists for - see the
/// presentations list in `main`.
BackendProbeResult _probeWebGpu() => const WebGpuRendererBackend().probe();

/// Whether the page asked for the DOM path by name.
///
/// `?renderer=dom` in the query string, and nothing else. The policy, stated
/// once: **the DOM path is the last fallback and never the default.** It draws
/// with HTML elements instead of pixels, which buys selectable text, find-in-
/// page, a real accessibility tree and real keyboard focus, and pays for them
/// by refusing arbitrary paths, gradients and blend modes - see
/// `dom_presenter.dart` for the list. A gallery whose whole point is vector
/// rendering should not silently land there because a driver was having a bad
/// morning, so it sits below WebGPU and WebGL2 and is only promoted when
/// somebody asks.
///
/// A query parameter rather than a build flag because the interesting
/// comparison is the same page on both paths, side by side in two tabs, and
/// because it is what a browser test can drive.
bool get _domRequested => web.window.location.search.contains('renderer=dom');

/// The face the gallery draws its labels in.
///
/// Bundled in `web/fonts` rather than found on the machine, because a browser
/// offers no way to enumerate or read an installed font - see `web_fonts.dart`
/// for why that is a deliberate closure rather than a gap. Roboto under
/// Apache-2.0, with the licence next to it.
const String _uiFontUrl = 'fonts/Roboto-Regular.ttf';

Future<void> main() async {
  // Before the application starts, so the first frame already has a face. A
  // font loaded afterwards would be correct too - the registry clears its size
  // cache - but the first frame would draw blank labels and the page would
  // visibly flash from no text to text.
  final String? fontFailure = await useWebUiFont(_uiFontUrl);
  if (fontFailure != null) {
    // Loud, because the symptom is silent: every label draws blank and every
    // box draws normally, which looks exactly like a text layout bug rather
    // than a missing file.
    web.console.error(
      'no UI font, so every label will be blank: $fontFailure'.toJS,
    );
  }

  final Application application = await Application.start(
    rootWidget: Gallery(model: GalleryModel(), theme: ThemeData.neutralLight),
    backends: <WindowingBackendEntry>[
      const WindowingBackendEntry(
        name: WebWindowingBackend.backendName,
        create: WebWindowingBackend.new,
      ),
    ],
    // Preference order, and the fallback between the two entries is the
    // selection machinery's own: an `attach` that throws is recorded against
    // its path's name and the next entry is tried. WebGPU asks the adapter
    // and the device for everything they can refuse before touching the
    // canvas, so a browser that says no leaves the element virgin for the
    // WebGL2 entry - and the startup report logged below names which one won
    // and why the other did not.
    // The `devices` argument is accepted and dropped, in both entries and on
    // purpose. It carries the shared render device a second window would
    // adopt instead of opening its own - the whole point of the desktop work
    // that made a menu open in 7 ms instead of 30 - and on the web there is no
    // second window to share with: a page has one canvas, and a browser hands
    // out a context per canvas whatever the caller would prefer. Taking the
    // parameter and ignoring it is the honest shape; a named refusal here
    // would fire on every startup for a request nobody made.
    presentations: <PresentationPathEntry>[
      // Promoted to the front only when the page asked; see [_domRequested] for
      // the policy and the reason it is a query parameter.
      if (_domRequested) _domPresentationPath(),
      PresentationPathEntry(
        name: WebGpuRendererBackend.backendName,
        kind: PresentationKind.gpu,
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
        probe: _probeWebGpu,
        attach: (NativeWindow window, {RenderDeviceProvider? devices}) =>
            WebGpuCanvasPresenter.attach(window),
      ),
      PresentationPathEntry(
        name: WebGlRendererBackend.backendName,
        kind: PresentationKind.gpu,
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
        probe: _probeWebGl2,
        attach: (NativeWindow window, {RenderDeviceProvider? devices}) =>
            WebGlCanvasPresenter.attach(window),
      ),
      // Last, and reachable without asking: this is the path that works when
      // WebGL2 is blocked by policy, disabled by a flag, or absent because the
      // machine has no GPU at all. A page that fell all the way here is drawn
      // as HTML, which is worse-looking and entirely usable - and the startup
      // report below says so by name, which is the difference between "the DOM
      // path is running" and "something went wrong".
      if (!_domRequested) _domPresentationPath(),
    ],
    options: ApplicationOptions(
      // No API in the name: which of the two GPU paths won is the startup
      // report's job to say, and a title that claimed one would lie half the
      // time.
      title: 'dart_ui gallery - web',
      size: galleryDesignSize,
      // No frame budget: this is interactive, not a smoke run. The loop below
      // stops when the page goes away.
      showDevOverlay: true,
      minimumSize: const Size(480, 360),
      windowBackgroundColor: ThemeData.neutralLight.surface,
      // Both go to the browser console, which is the web's stderr. A page that
      // swallowed them would be a page where a failed present is invisible.
      onError: (FrameworkError error) => web.console.error(
        error.describe().toJS,
      ),
      onDiagnostic: (BackendDiagnostic diagnostic) => web.console.warn(
        'present: $diagnostic'.toJS,
      ),
    ),
  );

  // The startup report, in full, before the first frame. It names the backend
  // and the presentation path that were chosen and every candidate that was
  // passed over with the reason - which on the web is the difference between
  // "WebGL2 is running" and "WebGL2 was rejected and you are looking at
  // something else", and those two look identical on screen.
  web.console.log(application.describeStartup().toJS);

  _connectDomSemantics(application);

  _FrameLoop(application).start();
}

/// The DOM presentation path, in the one shape `Application.start` accepts.
///
/// A function rather than a `const` entry because the presenter it attaches
/// needs two things wired to it afterwards - a semantic tree to publish and
/// somewhere to report what it could not draw - and both are held on the object
/// rather than passed to the constructor. See [_wireDomPresenter], which is
/// where that happens.
PresentationPathEntry _domPresentationPath() => PresentationPathEntry(
      name: DomCanvasPresenter.backendName,
      // `cpu` and not `gpu`, and neither word is really right: nothing here
      // rasterises at all - the browser's own compositor does, on whatever
      // hardware it chooses. `cpu` is the honest half of the answer, because
      // this path makes no claim on a GPU device and shares none.
      kind: PresentationKind.cpu,
      rasterizationApproach: RasterizationApproach.custom,
      probe: DomCanvasPresenter.probe,
      attach: (NativeWindow window, {RenderDeviceProvider? devices}) async {
        final DomCanvasPresenter presenter =
            await DomCanvasPresenter.attach(window);
        _wireDomPresenter(presenter);
        return presenter;
      },
    );

/// Where the presenter built above is remembered until an [Application] exists.
///
/// `attach` runs *inside* `Application.start`, before the object that owns the
/// semantic tree has been returned, so the tree cannot be handed over there.
/// This is the smallest thing that closes that gap: one field, set during
/// attach and consumed immediately after start.
DomCanvasPresenter? _domPresenter;

void _wireDomPresenter(DomCanvasPresenter presenter) {
  _domPresenter = presenter;
  // Once per distinct reason, not once per command. A page whose interface uses
  // one gradient should say so once and then be quiet.
  presenter.onRefusal = (DomRefusal refusal) => web.console.warn(
        'the DOM backend cannot draw ${refusal.what}: ${refusal.why}'.toJS,
      );
}

/// Gives the DOM path the semantic tree and the action sink it could not be
/// given at attach time.
///
/// Does nothing when another path won, which is the ordinary case.
///
/// The tree is built per frame rather than diffed through
/// `BuildOwner.updateSemantics`, because the layer does its own diff by node id
/// and a second diff above it would only be able to describe changes the layer
/// then has to look up anyway. The cost is one render-tree walk per frame, paid
/// only by a page that is actually on this path.
void _connectDomSemantics(Application application) {
  final DomCanvasPresenter? presenter = _domPresenter;
  if (presenter == null) return;
  presenter
    ..semanticsSource = application.buildOwner.buildSemantics
    ..onSemanticsAction = (int nodeId, SemanticsAction action) {
      // Through the owner rather than straight at the render object, because
      // `SemanticsOwner.performAction` refuses an action the last published
      // snapshot did not declare - which is what stops the DOM being able to
      // press a button the framework never offered.
      final bool performed =
          application.buildOwner.semanticsOwner.performAction(nodeId, action);
      if (performed) application.requestFrame();
    };
}

/// Drives [Application.drawPendingFrames] from `requestAnimationFrame`.
///
/// ## Why it reschedules unconditionally
///
/// The obvious loop asks `application.needsFrame` and only reschedules when
/// something is dirty. That is the right shape for a backend whose event
/// delivery can wake the loop - and it is wrong here, because the thing that
/// would have to wake it is a DOM event, and a DOM event arriving does not by
/// itself resume a `requestAnimationFrame` chain that has stopped.
///
/// So the chain never stops. The cost is one callback per vsync doing almost
/// nothing on an idle page, which is what every browser application does and
/// what the browser is built to make cheap: it throttles the callback to a few
/// per second in a background tab and stops it entirely in a hidden one,
/// without the page having to know.
///
/// The alternative - stopping the chain and restarting it from every input
/// listener - is a second scheduler competing with the first, and the failure
/// it produces is a page that is occasionally, unreproducibly one frame stale.
final class _FrameLoop {
  _FrameLoop(this._application);

  final Application _application;
  bool _stopped = false;

  /// Whether a frame is still being awaited.
  ///
  /// `drawPendingFrames` is a `Future`, and a callback that fired again before
  /// the previous one settled would have two frames recording into the same
  /// batcher. The flag is the whole of the guard: `requestAnimationFrame`
  /// callbacks never overlap, so nothing more elaborate is needed.
  bool _drawing = false;

  void start() => web.window.requestAnimationFrame(_tick.toJS);

  void _tick(num _) {
    if (_stopped) return;
    // Rescheduled first, so an exception below does not end the loop. A page
    // whose frame loop died silently on one bad frame is far worse than one
    // that logs it and draws the next.
    web.window.requestAnimationFrame(_tick.toJS);
    if (_drawing) return;
    if (!_application.needsFrame) return;
    _drawing = true;
    _application.drawPendingFrames().whenComplete(() => _drawing = false);
  }

  /// Stops the chain. Nothing calls it yet: a tab closing tears the isolate
  /// down without running Dart, so there is no teardown path a page can rely
  /// on. It exists so an embedder that wants to hand the page back - a test
  /// harness, an application that unmounts itself - has something to call.
  void stop() => _stopped = true;
}
