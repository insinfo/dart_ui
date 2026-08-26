/// Approaches B and C, reached the way an application reaches them.
///
/// ## What was actually broken
///
/// `GlRenderDevice.adoptContext` builds the retained-tessellation executor (B)
/// and the stencil-then-cover executor (C) only when it is asked to, and
/// nothing in the framework ever asked: `default_platform_resolver.dart`
/// called it with no flags, so both routes ran from this test directory, from
/// `poc/poc_23_gpu_2d_strategies` and from direct device use, and from no
/// window on any platform. `RenderPolicy.routes` is the ask, and
/// [RenderPolicy.buildsTessellationExecutor] /
/// [RenderPolicy.buildsStencilCoverExecutor] are what the resolver reads.
///
/// This file opens its devices exactly as the resolver does - from a policy -
/// so a change that stopped the resolver asking fails here rather than only in
/// a window nobody runs in CI.
///
/// ## Why the picture is asserted and not assumed
///
/// Neither route carries the analytic coverage the rest of this renderer
/// shares. C is masked by a stencil test, which is binary, so its edge is the
/// pass's MSAA and nothing else; B hands the rasteriser triangles. The
/// promotion is therefore a *measured trade*, and what the tests below pin is
/// the shape of that trade: the interior of a promoted shape is exact, the
/// deviation is confined to its fringe, and the count and the depth of the
/// fringe are bounded numbers rather than "some pixels changed".
///
/// Windows only, and a real GPU: an offscreen FBO built by this backend is
/// what a `saveLayer` gets, and the attachments of that FBO are the whole
/// question for approach C. `tool/gl_vector_routes_smoke.dart` is the same
/// claim against a real HWND.
library;

import 'dart:io' show Platform;

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/render_diagnostics.dart';
import 'package:dart_ui/src/rendering/render_policy.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

const int _size = 512;
const int _clear = 0xFF101418;

void main() {
  final _RouteSession baseline = _RouteSession.open(RenderPolicy.defaults);
  final _RouteSession routes = _RouteSession.open(const RenderPolicy(
    routes: GpuRouteAvailability.largeAnimatedPaths,
  ));
  final _RouteSession coverOnly = _RouteSession.open(const RenderPolicy(
    routes: GpuRouteAvailability.largeAnimatedPaths,
    strategies: GpuStrategySwitches(tessellation: false),
  ));
  tearDownAll(() {
    baseline.close();
    routes.close();
    coverOnly.close();
  });
  tearDown(RenderPolicyScope.reset);

  final String? skip = baseline.skipReason ?? routes.skipReason;
  final String? coverSkip = coverOnly.skipReason ?? skip;

  test('the default policy builds neither executor', () {
    expect(baseline.device!.experimentalCpuTessellationEnabled, isFalse);
    expect(baseline.device!.experimentalStencilCoverEnabled, isFalse);
  }, skip: skip);

  test('largeAnimatedPaths builds both on a driver that has the symbols', () {
    expect(routes.device!.experimentalCpuTessellationEnabled, isTrue);
    expect(routes.device!.experimentalStencilCoverEnabled, isTrue);
  }, skip: skip);

  test('a kill switch over the request builds only the other one', () {
    expect(coverOnly.device!.experimentalCpuTessellationEnabled, isFalse);
    expect(coverOnly.device!.experimentalStencilCoverEnabled, isTrue);
  }, skip: coverSkip);

  test('the cover pass draws a large uncached path inside a layer', () async {
    // C's advertised workload, and the only shape of scene that reaches it on
    // a window: the surface framebuffer is single-sample, so the four samples
    // `StencilCoverRequirements` demands exist only inside a layer that
    // `glLayerAttachmentsFor` allocated them for.
    final FrameRenderDiagnostics frame = await _routesTaken(coverOnly);
    expect(frame.drawsOf(GpuPathStrategy.stencilThenCover), 1);
    expect(
      frame.reasonFor(GpuPathStrategy.stencilThenCover),
      contains('stencil threshold'),
    );
  }, skip: coverSkip);

  test('approach B preempts approach C in the workload C is named for',
      () async {
    // Not a defect, and worth pinning: the selector reaches tessellation
    // before either stencil branch, so with both routes built the retained
    // mesh takes the draw the POC-23 report assigns to the cover pass. It was
    // also the faster of the two when measured - see
    // `doc/RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md`.
    final FrameRenderDiagnostics frame = await _routesTaken(routes);
    expect(frame.drawsOf(GpuPathStrategy.tessellatedMesh), 1);
    expect(frame.drawsOf(GpuPathStrategy.stencilThenCover), 0);
  }, skip: skip);

  test('the cover pass keeps the interior exact and moves only the fringe',
      () async {
    final Framebuffer dense = await _render(baseline);
    final Framebuffer cover = await _render(coverOnly);
    final _Deviation deviation = _compare(dense, cover);

    // The centre of the star is deep inside every contour, so a stencil test
    // that disagreed with the analytic coverage anywhere but at an edge would
    // show here first.
    expect(_pixel(dense, _size ~/ 2, _size ~/ 2),
        _pixel(cover, _size ~/ 2, _size ~/ 2));
    // Measured on Intel UHD Graphics, GL 4.6, driver 32.0.101.7088: 24 757
    // pixels of a 262 144 pixel frame, 55 levels at four samples. The bounds
    // are deliberately loose - another driver may resolve MSAA differently -
    // and what they pin is that this is a *fringe* and not a repaint.
    expect(deviation.differing, greaterThan(0));
    expect(deviation.differing, lessThan(_size * _size ~/ 8));
    expect(deviation.maxChannelDelta, lessThanOrEqualTo(96));
  }, skip: coverSkip);
}

/// One large, crossing-dense path inside a layer big enough to be allocated
/// with stencil and samples. Every term matters: smaller than
/// `kGlLayerAttachmentMinimumSize` and the layer is colour-only; cheaper in
/// tile crossings and the sparse encoder wins it before either route is asked.
DisplayList _scene() {
  final DisplayList list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFF3A7BD5);
  final int layerPaint = list.addPaint(colorArgb: 0x99FFFFFF);
  list
    ..saveLayer(10, 10, 500, 500, layerPaint)
    ..drawPath(list.addPath(_star(256, 256, 220, 90)), fill)
    ..restore();
  return list;
}

Path _star(double cx, double cy, double r, int points) {
  final PathBuilder builder = PathBuilder();
  final int n = points * 2;
  for (var i = 0; i < n; i++) {
    final double angle = i * 3.141592653589793 / points - 1.5707963267948966;
    final double radius = i.isEven ? r : r * 0.44;
    final double x = cx + radius * _cos(angle);
    final double y = cy + radius * _sin(angle);
    if (i == 0) {
      builder.moveTo(x, y);
    } else {
      builder.lineTo(x, y);
    }
  }
  builder.close();
  return builder.build();
}

// A fixture must not depend on the host's libm for the path it builds, and a
// five-term series is exact enough that every platform this runs on produces
// the same geometry.
double _cos(double a) => _sin(a + 1.5707963267948966);
double _sin(double a) {
  const double twoPi = 6.283185307179586;
  var x = a % twoPi;
  if (x > 3.141592653589793) x -= twoPi;
  if (x < -3.141592653589793) x += twoPi;
  final double x2 = x * x;
  return x * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42 * (1 - x2 / 72))));
}

Future<FrameRenderDiagnostics> _routesTaken(_RouteSession session) async {
  RenderPolicyScope.install(session.policy.copyWith(
    diagnostics: RenderDiagnosticsMode.counters,
  ));
  final GlOffscreenTarget target = session.target();
  try {
    await target.renderDisplayList(_scene(), clearColor: _clear);
    return RenderPolicyScope.diagnostics.snapshot();
  } finally {
    target.dispose();
  }
}

Future<Framebuffer> _render(_RouteSession session) async {
  final GlOffscreenTarget target = session.target();
  try {
    await target.renderDisplayList(_scene(), clearColor: _clear);
    final Framebuffer live = target.framebuffer;
    final Framebuffer copy = Framebuffer.allocate(
      width: live.width,
      height: live.height,
      format: live.format,
    );
    copy.pixels.setAll(0, live.pixels);
    return copy;
  } finally {
    target.dispose();
  }
}

final class _Deviation {
  const _Deviation(this.differing, this.maxChannelDelta);
  final int differing;
  final int maxChannelDelta;
}

_Deviation _compare(Framebuffer a, Framebuffer b) {
  var differing = 0;
  var worst = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final int offset = y * a.bytesPerRow + x * 4;
      var delta = 0;
      for (var c = 0; c < 4; c++) {
        final int d = (a.pixels[offset + c] - b.pixels[offset + c]).abs();
        if (d > delta) delta = d;
      }
      if (delta != 0) {
        differing++;
        if (delta > worst) worst = delta;
      }
    }
  }
  return _Deviation(differing, worst);
}

List<int> _pixel(Framebuffer framebuffer, int x, int y) {
  final int offset = y * framebuffer.bytesPerRow + x * 4;
  return <int>[
    framebuffer.pixels[offset],
    framebuffer.pixels[offset + 1],
    framebuffer.pixels[offset + 2],
    framebuffer.pixels[offset + 3],
  ];
}

/// A GL device opened from a [RenderPolicy], the way the resolver opens one.
final class _RouteSession {
  _RouteSession._(
      this.policy, this.device, this.skipReason, this._surface, this._context);

  final RenderPolicy policy;
  final GlRenderDevice? device;
  final String? skipReason;
  final Win32GlSurface? _surface;
  final GlContext? _context;

  static _RouteSession open(RenderPolicy policy) {
    if (!Platform.isWindows) {
      return _RouteSession._(
          policy, null, 'this file measures the Win32 GL path', null, null);
    }
    final Win32GlSurfaceAttempt attempt = Win32GlSurface.hidden();
    final Win32GlSurface? surface = attempt.surface;
    if (surface == null) {
      return _RouteSession._(policy, null,
          'no GL surface: ${attempt.diagnostics.join('; ')}', null, null);
    }
    final contextAttempt = surface.createContext();
    final GlContext? context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _RouteSession._(
          policy,
          null,
          'no GL context: ${contextAttempt.diagnostics.join('; ')}',
          null,
          null);
    }
    try {
      return _RouteSession._(
        policy,
        // The two arguments the resolver passes, from the same two getters.
        GlRendererBackend.adoptContext(
          context,
          surface.glLibrary,
          enableExperimentalCpuTessellation: policy.buildsTessellationExecutor,
          enableExperimentalStencilCover: policy.buildsStencilCoverExecutor,
        ),
        null,
        surface,
        context,
      );
    } on Object catch (error) {
      surface.dispose();
      return _RouteSession._(
          policy, null, 'opening a GL device threw: $error', null, null);
    }
  }

  GlOffscreenTarget target() => device!.createTarget(
        const MemorySurfaceDescriptor(
          pixelWidth: _size,
          pixelHeight: _size,
          format: PixelFormat.rgba8888Premultiplied,
        ),
      ) as GlOffscreenTarget;

  void close() {
    device?.dispose();
    _context?.dispose();
    _surface?.dispose();
  }
}
