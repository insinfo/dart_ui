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
import 'package:dart_ui/src/backends/web/web_fonts.dart';
import 'package:dart_ui/src/backends/web/web_gl_presenter.dart';
import 'package:dart_ui/src/backends/web/web_window.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
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
    presentations: <PresentationPathEntry>[
      const PresentationPathEntry(
        name: WebGlRendererBackend.backendName,
        kind: PresentationKind.gpu,
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
        probe: _probeWebGl2,
        attach: WebGlCanvasPresenter.attach,
      ),
    ],
    options: ApplicationOptions(
      title: 'dart_ui gallery - WebGL2',
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

  _FrameLoop(application).start();
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
