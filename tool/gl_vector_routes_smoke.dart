/// Proves approaches B and C run in a **real window**, not only in a test.
///
/// The two routes are built by `GlRenderDevice.adoptContext` and nothing in
/// the framework used to ask it for them, so they were reachable from tests,
/// from `poc/poc_23_gpu_2d_strategies` and from direct device use, and from no
/// application at all. `default_platform_resolver.dart` now asks, driven by
/// `RenderPolicy.routes`, and this is the smoke test for that seam.
///
/// Why it is a tool and not a unit test: a headless run of this framework
/// gives a false green for presentation, because the headless backend has no
/// window and the offscreen GL target is not the default framebuffer whose
/// attachments decide whether approach C may be selected at all. Only a real
/// HWND with a real WGL context answers the question.
///
/// ```
/// dart run tool/gl_vector_routes_smoke.dart            # routes on
/// dart run tool/gl_vector_routes_smoke.dart --baseline # routes off
/// ```
///
/// Prints one `GL_VECTOR_ROUTES=` line and exits 0 only when the window
/// presented every frame it was asked for. `onError` is installed on purpose:
/// without it a paint failure closes the window with exit 0 and no
/// diagnostic, which is the exact false green this file exists to refuse.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';

const int _frames = 120;

Timer? _ticker;

/// A large path that changes every frame, inside a layer large enough to be
/// allocated with stencil and samples: the workload
/// [GpuRouteAvailability.largeAnimatedPaths] is named after.
final class _AnimatedVectorCanvas extends RenderObjectWidget {
  const _AnimatedVectorCanvas();

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  _RenderAnimatedVectorCanvas createRenderObject(BuildContext context) {
    final _RenderAnimatedVectorCanvas object = _RenderAnimatedVectorCanvas();
    // The animation, driven from outside `paint`. Marking dirty from inside a
    // paint re-posts the callback the dispatcher is draining and it refuses
    // by name, which is what `onError` reported the first time this file ran.
    _ticker = Timer.periodic(const Duration(milliseconds: 8), (Timer _) {
      object.frame++;
      object.markNeedsPaint();
    });
    return object;
  }

  @override
  void updateRenderObject(BuildContext context, RenderBox renderObject) {}
}

final class _RenderAnimatedVectorCanvas extends RenderBox {
  int frame = 0;

  @override
  void performLayout() => size = constraints.biggest;

  @override
  void paint(DisplayList list, Offset offset) {
    final double w = size.width;
    final double h = size.height;
    final int background = list.addPaint(colorArgb: 0xFF101418);
    final int fill = list.addPaint(colorArgb: 0xFF3A7BD5);
    final int layerPaint = list.addPaint(colorArgb: 0x99FFFFFF);
    list.drawRect(
        offset.dx, offset.dy, offset.dx + w, offset.dy + h, background);

    const double inset = 12;
    list
      ..saveLayer(offset.dx + inset, offset.dy + inset, offset.dx + w - inset,
          offset.dy + h - inset, layerPaint)
      ..drawPath(
        list.addPath(_star(
          offset.dx + w / 2,
          offset.dy + h / 2,
          // Continuous, so the mask is new in device space every frame. A
          // radius that repeated would let the dense atlas cache it, and the
          // frame would measure the atlas rather than these routes.
          math.min(w, h) / 2 - 32 + 8 * math.sin(frame * 0.07),
          90,
        )),
        fill,
      )
      ..restore();
  }
}

Path _star(double cx, double cy, double r, int points) {
  final PathBuilder b = PathBuilder();
  final int n = points * 2;
  for (var i = 0; i < n; i++) {
    final double a = i * math.pi / points - math.pi / 2;
    final double rr = i.isEven ? r : r * 0.44;
    final double x = cx + rr * math.cos(a);
    final double y = cy + rr * math.sin(a);
    if (i == 0) {
      b.moveTo(x, y);
    } else {
      b.lineTo(x, y);
    }
  }
  b.close();
  return b.build();
}

String _ms(List<int> sortedMicros) => sortedMicros.isEmpty
    ? 'n/a'
    : (sortedMicros[sortedMicros.length ~/ 2] / 1000).toStringAsFixed(3);

Future<void> main(List<String> args) async {
  if (!Platform.isWindows && !Platform.isLinux) {
    stderr
        .writeln('GL_VECTOR_ROUTES=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }
  final bool baseline = args.contains('--baseline');
  // The kill switches, reachable from the command line so that a bisection is
  // one run rather than a rebuild - and so this file proves they are live.
  final GpuStrategySwitches switches = GpuStrategySwitches(
    tessellation: !args.contains('--no-b'),
    stencilThenCover: !args.contains('--no-c'),
  );
  final List<FrameworkError> errors = <FrameworkError>[];
  final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];

  // `Application.start` and not `runApp`, for one reason: `runApp` disposes
  // before it returns and `Application.dispose` calls
  // `RenderPolicyScope.reset()`, so the counters this file exists to read are
  // already back to the disabled recorder by then.
  final Application app = await Application.start(
    rootWidget: const _AnimatedVectorCanvas(),
    backends: PlatformBackendResolver.defaultBackends(),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: ApplicationOptions(
      title: 'dart_ui GL vector routes smoke',
      size: const Size(720, 540),
      visible: true,
      frameBudget: _frames,
      // gpuOnly, so a machine whose GL probe fails is a loud failure instead
      // of a CPU frame that would silently prove nothing about these routes.
      renderingPolicy: RenderingPolicy.gpuOnly,
      requestedPresentation: 'opengl',
      renderPolicy: RenderPolicy(
        routes: baseline
            ? GpuRouteAvailability.measuredDefaults
            : GpuRouteAvailability.largeAnimatedPaths,
        strategies: switches,
        diagnostics: RenderDiagnosticsMode.counters,
      ),
      // Without this a build/layout/paint failure closes the window with exit
      // 0 and nothing on stderr.
      onError: errors.add,
      onDiagnostic: diagnostics.add,
    ),
  );

  await app.run(frameBudget: _frames);
  _ticker?.cancel();
  final FrameRenderDiagnostics render = app.renderDiagnostics;
  final int presented = app.framesPresented;
  final List<int> totals = <int>[
    for (final FrameTiming frame in app.statistics.frames) frame.total,
  ]..sort();
  final List<int> rasters = <int>[
    for (final FrameTiming frame in app.statistics.frames) frame.raster,
  ]..sort();
  final bool ok = errors.isEmpty && presented >= _frames;
  stdout
    ..writeln('GL_VECTOR_ROUTES=${ok ? 'PASS' : 'FAIL'} '
        'routes=${baseline ? 'measuredDefaults' : 'largeAnimatedPaths'} '
        'presentation=${app.presentationSelection.chosen?.name} '
        'frames=$presented errors=${errors.length} '
        'medianFrame=${_ms(totals)}ms medianRaster=${_ms(rasters)}ms')
    ..write(render.describe());
  for (final BackendDiagnostic diagnostic in diagnostics) {
    if (diagnostic.message.contains('route')) {
      stdout.writeln('  diagnostic: ${diagnostic.message}');
    }
  }
  for (final FrameworkError error in errors) {
    stderr.writeln('  error: $error');
  }
  app.dispose();
  await app.closed;
  exitCode = ok ? 0 : 1;
}
