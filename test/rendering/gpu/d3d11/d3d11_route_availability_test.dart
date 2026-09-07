/// Approaches B and C on Direct3D 11, reached the way an application reaches
/// them.
///
/// ## What was actually missing
///
/// `test/rendering/gpu/gl_route_availability_test.dart` is the same file for
/// OpenGL and it opens with the observation that both routes existed and no
/// window on any platform could reach them. On Direct3D 11 the gap was one step
/// wider: the two executors did not exist at all, and Direct3D 11 is the
/// **default production path on Windows** - `default_platform_resolver.dart`
/// tries it before OpenGL - so the two strategies POC-23 integrated were
/// unreachable for very nearly every real user of this framework.
///
/// This file opens its devices the way the composition root opens one: from a
/// [RenderPolicy]. `D3d11RendererBackend.createDevice` reads
/// [RenderPolicyScope.policy] and forwards
/// [RenderPolicy.buildsTessellationExecutor] and
/// [RenderPolicy.buildsStencilCoverExecutor] to
/// [D3d11RendererBackend.openDevice]; the sessions below call `openDevice` with
/// those same two getters, so a change that stopped the backend asking fails
/// here rather than only on a screen nobody runs in CI.
///
/// ## Why the picture is asserted and not assumed
///
/// Neither route carries the analytic coverage the rest of this renderer
/// shares. C is masked by a stencil test, which is binary, so its edge is the
/// pass's MSAA and nothing else; B hands the rasteriser triangles. The
/// promotion is therefore a *measured trade*, and what the tests below pin is
/// the shape of that trade: the interior of a promoted shape is exact, the
/// deviation is confined to its fringe, and the count and the depth of the
/// fringe are bounded numbers rather than "some pixels changed". The bounds are
/// the GL file's, deliberately - the two backends promote the same draw through
/// four-sample hardware coverage, so a Direct3D fringe that fell outside the
/// OpenGL envelope would mean one of the two ports is wrong.
///
/// Windows only, and a real GPU: an offscreen layer built by this backend is
/// what a `saveLayer` gets, and the attachments of that layer are the whole
/// question for approach C.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_window_target.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_recovery.dart';
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
    expect(baseline.device!.hasExperimentalVectorRoutes, isFalse);
    // The second half of "neither", and the one that costs frame time on a
    // device that never promotes anything: with approach C off, every layer is
    // allocated colour-only and the frame pays neither the multisampled colour
    // plane, the D24S8, nor the resolve. POC-23 measured that cost at 9% on a
    // static panel that drew *zero* stencil draws.
    expect(baseline.device!.vectorPipeline, isNull);
  }, skip: skip);

  test('largeAnimatedPaths builds both on a driver that has the symbols', () {
    expect(routes.device!.experimentalCpuTessellationEnabled, isTrue);
    expect(routes.device!.experimentalStencilCoverEnabled, isTrue);
  }, skip: skip);

  test('a kill switch over the request builds only the other one', () {
    expect(coverOnly.device!.experimentalCpuTessellationEnabled, isFalse);
    expect(coverOnly.device!.experimentalStencilCoverEnabled, isTrue);
  }, skip: coverSkip);

  test('an ordinary UI draw takes the same route with the executors built',
      () async {
    // The rule the whole change is subject to: neither route may become a
    // default. An interface of rounded panels, chips and icons must select
    // exactly what it selected before, and it must do so *with both executors
    // present* - a selector that started preferring a promoted route for
    // ordinary chrome would be a regression whatever it measured.
    final FrameRenderDiagnostics dense =
        await _routesTaken(routes, _ordinary());
    expect(dense.drawsOf(GpuPathStrategy.tessellatedMesh), 0);
    expect(dense.drawsOf(GpuPathStrategy.stencilThenCover), 0);
    // And the pixels are the dense ones, not merely the same count of them.
    final Framebuffer plain = await _render(baseline, _ordinary());
    final Framebuffer built = await _render(routes, _ordinary());
    expect(_compare(plain, built).differing, 0);
  }, skip: skip);

  test('the cover pass draws a large uncached path inside a layer', () async {
    // C's advertised workload, and the only shape of scene that reaches it: an
    // offscreen readback texture is single-sample and carries no depth-stencil
    // view, so the four samples `StencilCoverRequirements` demands exist only
    // inside a layer that `d3d11LayerAttachmentsFor` allocated them for.
    final FrameRenderDiagnostics frame =
        await _routesTaken(coverOnly, _scene());
    expect(frame.drawsOf(GpuPathStrategy.stencilThenCover), 1);
    expect(
      frame.reasonFor(GpuPathStrategy.stencilThenCover),
      contains('stencil threshold'),
    );
  }, skip: coverSkip);

  test('approach B preempts approach C in the workload C is named for',
      () async {
    // Not a defect, and worth pinning on this backend too: the selector reaches
    // tessellation before either stencil branch, so with both routes built the
    // retained mesh takes the draw POC-23 assigns to the cover pass. The GL
    // file asserts the identical fact, and the two agreeing is evidence that
    // the ordering lives in `gpu_path_strategy.dart` and not in either port.
    final FrameRenderDiagnostics frame = await _routesTaken(routes, _scene());
    expect(frame.drawsOf(GpuPathStrategy.tessellatedMesh), 1);
    expect(frame.drawsOf(GpuPathStrategy.stencilThenCover), 0);
  }, skip: skip);

  test('the cover pass keeps the interior exact and moves only the fringe',
      () async {
    final Framebuffer dense = await _render(baseline, _scene());
    final Framebuffer cover = await _render(coverOnly, _scene());
    final _Deviation deviation = _compare(dense, cover);

    // The centre of the star is deep inside every contour, so a stencil test
    // that disagreed with the analytic coverage anywhere but at an edge would
    // show here first - and a non-zero accumulation whose front/back faces were
    // the wrong way round would show here as the shape's own complement.
    expect(_pixel(dense, _size ~/ 2, _size ~/ 2),
        _pixel(cover, _size ~/ 2, _size ~/ 2));
    // The GL file's envelope, unchanged: 24 757 pixels of a 262 144 pixel frame
    // and 55 levels at four samples were what OpenGL measured on this machine.
    // The bounds are deliberately loose - a driver may resolve MSAA differently
    // - and what they pin is that this is a *fringe* and not a repaint.
    // Measured on Intel(R) UHD Graphics, feature level 11_1, driver
    // 32.0.101.7088: **24 759 pixels of a 262 144 pixel frame and 55 levels**
    // at four samples, interiors exact. OpenGL measured 24 757 and 55 for the
    // same scene through the same route on the same machine, which is the
    // useful part of the number: two independent ports of approach C land
    // within two pixels of each other, so the fringe is the hardware's and not
    // either backend's. The bounds are deliberately loose - another driver may
    // resolve MSAA differently - and what they pin is that this is a *fringe*
    // and not a repaint.
    expect(deviation.differing, greaterThan(0));
    expect(deviation.differing, lessThan(_size * _size ~/ 8));
    expect(deviation.maxChannelDelta, lessThanOrEqualTo(96));
  }, skip: coverSkip);

  test(
      'the tessellated mesh keeps the interior exact and moves only the fringe',
      () async {
    final Framebuffer dense = await _render(baseline, _scene());
    final Framebuffer mesh = await _render(routes, _scene());
    final _Deviation deviation = _compare(dense, mesh);
    expect(_pixel(dense, _size ~/ 2, _size ~/ 2),
        _pixel(mesh, _size ~/ 2, _size ~/ 2));
    // 24 759 pixels and 55 levels, the same numbers to the pixel as the cover
    // pass above - which is what should happen and is worth pinning: both
    // routes replace one analytic edge with the same four-sample hardware
    // coverage over the same geometry, so a backend where they differed would
    // have something wrong in one of the two.
    expect(deviation.differing, greaterThan(0));
    expect(deviation.differing, lessThan(_size * _size ~/ 8));
    expect(deviation.maxChannelDelta, lessThanOrEqualTo(96));
  }, skip: skip);

  test('even-odd through the stencil path leaves the same holes the atlas does',
      () async {
    // The classic stencil bug, and the reason it gets its own scene: a non-zero
    // accumulation increments and decrements by face, while even-odd inverts a
    // single bit, and a port that reached for `INCR_SAT` or forgot to narrow
    // the write mask to `0x01` draws a *solid* star where this one has a hole.
    // The five-pointed star below is self-intersecting by construction, so the
    // two fill rules genuinely disagree about its middle.
    final Framebuffer dense = await _render(baseline, _evenOddScene());
    final Framebuffer cover = await _render(coverOnly, _evenOddScene());
    final _Deviation deviation = _compare(dense, cover);
    // The centre of a self-intersecting five-pointed star is inside the outline
    // twice, so even-odd leaves it empty. If the stencil path had silently
    // filled it, this pixel would be the fill colour on one side and the
    // background on the other - a deviation of the whole colour, not a fringe.
    expect(_pixel(dense, _size ~/ 2, _size ~/ 2),
        _pixel(cover, _size ~/ 2, _size ~/ 2));
    // Measured: 2 585 pixels and 65 levels, all of them on the outline. A
    // stencil path that had lost the fill rule would differ over the whole
    // pentagon in the middle instead - about 40 000 pixels at the full colour.
    expect(deviation.differing, greaterThan(0));
    expect(deviation.differing, lessThan(_size * _size ~/ 8));
    expect(deviation.maxChannelDelta, lessThanOrEqualTo(96));
  }, skip: coverSkip);

  test('a self-intersecting non-zero fill agrees with the atlas', () async {
    // The same outline under the other rule, so the pair proves the fill rule
    // reaches the stencil state rather than being ignored: under non-zero the
    // centre is *filled*, and the two scenes differ from each other there.
    final Framebuffer dense = await _render(baseline, _nonZeroScene());
    final Framebuffer cover = await _render(coverOnly, _nonZeroScene());
    expect(_pixel(dense, _size ~/ 2, _size ~/ 2),
        _pixel(cover, _size ~/ 2, _size ~/ 2));
    // Measured: 1 981 pixels and 34 levels, again only on the outline.
    expect(_compare(dense, cover).maxChannelDelta, lessThanOrEqualTo(96));

    final Framebuffer evenOdd = await _render(baseline, _evenOddScene());
    expect(
      _pixel(dense, _size ~/ 2, _size ~/ 2),
      isNot(_pixel(evenOdd, _size ~/ 2, _size ~/ 2)),
      reason: 'the two fill rules must disagree about a self-intersecting '
          'star, or neither scene proves anything about the stencil state',
    );
  }, skip: coverSkip);

  test('a window target promotes the same draw the offscreen one does',
      () async {
    // The one that matters most and is hardest to reach. Direct3D 11 is the
    // default production path on Windows, and a window presents through a swap
    // chain rather than into a readback texture - a different `present`, a
    // different clear, a different render-target view. Everything above runs on
    // the offscreen target, so without this the *screen* would be the only
    // configuration these routes had never been submitted through, which is
    // exactly the failure `gl_vector_replay.dart` was factored out to stop.
    //
    // The swap chain here is a stub over a real render-target view - a layer
    // target's, because that is the only render target this backend's public
    // surface will hand out - so the pixels are not read back and what is
    // asserted is the promotion and the present. `tool/` has no Direct3D
    // equivalent of `gl_vector_routes_smoke.dart`; a real `HWND` is still the
    // only way to see these routes on a screen.
    if (!Platform.isWindows) return;
    final _RouteSession session = _RouteSession.open(const RenderPolicy(
      routes: GpuRouteAvailability.largeAnimatedPaths,
    ));
    if (session.skipReason != null) {
      session.close();
      return;
    }
    final D3d11RenderDevice device = session.device!;
    final D3d11LayerPool pool = D3d11LayerPool(device);
    final backBuffer =
        pool.acquireLayerTarget(_size, _size) as D3d11LayerTarget;
    RenderPolicyScope.install(session.policy.copyWith(
      diagnostics: RenderDiagnosticsMode.counters,
    ));
    final D3d11WindowTarget window = D3d11WindowTarget(
      device,
      D3d11WindowSurfaceDescriptor(
        nativeHandle: 0xD3D11,
        pixelWidth: _size,
        pixelHeight: _size,
        swapChain: _ViewBackedSwapChain(backBuffer.renderTarget.pointer),
        generation: GenerationToken(),
      ),
    );
    try {
      final PresentResult result =
          await window.renderDisplayList(_scene(), clearColor: _clear);
      expect(result.status, PresentStatus.presented, reason: '$result');
      final FrameRenderDiagnostics frame =
          RenderPolicyScope.diagnostics.snapshot();
      expect(frame.drawsOf(GpuPathStrategy.tessellatedMesh), 1);
    } finally {
      window.dispose();
      pool.dispose();
      session.close();
    }
  }, skip: skip);

  test('a device loss rebuilds both executors and the picture comes back',
      () async {
    // The routes are pipeline objects and GPU buffers like everything else in
    // this backend, so a removal takes them with it. Two things have to be true
    // afterwards and neither is automatic: `_initialise` has to build them
    // again from the *request* the device was opened with, and the retained
    // mesh inventory - the only GPU allocations here that no `ComBag` owns -
    // has to have been released rather than left holding buffers belonging to
    // a device the driver has freed.
    if (!Platform.isWindows) return;
    final _RouteSession session = _RouteSession.open(const RenderPolicy(
      routes: GpuRouteAvailability.largeAnimatedPaths,
    ));
    if (session.skipReason != null) {
      session.close();
      return;
    }
    try {
      final D3d11RenderDevice device = session.device!;
      final Framebuffer before = await _render(session, _scene());
      final coordinator = GpuRecoveryCoordinator(host: device);
      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      expect(coordinator.recover().isRecovered, isTrue);
      expect(device.experimentalCpuTessellationEnabled, isTrue);
      expect(device.experimentalStencilCoverEnabled, isTrue);
      final Framebuffer after = await _render(session, _scene());
      expect(_compare(before, after).differing, 0);
    } finally {
      session.close();
    }
  }, skip: skip);

  test('the first frame on a device draws what the second one draws', () async {
    // A regression test for a real bug and for the *shape* of it, which is why
    // it opens a device of its own rather than reusing one of the sessions
    // above: the failure existed only on the very first stencil submission a
    // device ever made, and any earlier frame hid it.
    //
    // The cause was the constant buffer. Approach C writes it for its cover
    // command only - the clear and the accumulation draw no colour - and on the
    // first pass of a process it therefore held whatever `CreateBuffer` left
    // behind. The viewport the vertex shader read was garbage, the accumulation
    // projected its triangles off-screen, the stencil plane stayed zero, and
    // the cover quad was masked away: **74 508 pixels of this frame drew
    // nothing, once**, and every later frame was exact because by then the
    // buffer held the previous frame's values. `D3d11VectorPipeline.beginPass`
    // now writes the whole register file, which is where OpenGL sets
    // `uViewport` too.
    if (!Platform.isWindows) return;
    final _RouteSession session = _RouteSession.open(const RenderPolicy(
      routes: GpuRouteAvailability.largeAnimatedPaths,
      strategies: GpuStrategySwitches(tessellation: false),
    ));
    if (session.skipReason != null) {
      session.close();
      return;
    }
    try {
      final Framebuffer first = await _render(session, _scene());
      final Framebuffer second = await _render(session, _scene());
      expect(_compare(first, second).differing, 0);
    } finally {
      session.close();
    }
  }, skip: coverSkip);
}

/// One large, crossing-dense path inside a layer big enough to be allocated
/// with stencil and samples.
///
/// Every term matters: smaller than [kD3d11LayerAttachmentMinimumSize] and the
/// layer is colour-only, and a cheaper path would be taken by the dense atlas
/// before either route is asked. The same scene the GL file uses, so the two
/// backends are held to the same fringe.
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

/// An interface, not a canvas: panels, chips and icons at sizes real chrome
/// uses, each drawn twice so the repetition tracker sees what it exists to see.
DisplayList _ordinary() {
  final DisplayList list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFF2E7D32);
  final int accent = list.addPaint(colorArgb: 0xFFB71C1C);
  for (var pass = 0; pass < 2; pass++) {
    for (var i = 0; i < 6; i++) {
      final double x = 24 + i * 78.0;
      list
        ..drawRect(x, 40, x + 64, 104, fill)
        ..drawPath(list.addPath(_star(x + 32, 200, 26, 5)), accent)
        ..drawPath(list.addPath(_star(x + 32, 320, 14, 6)), fill);
    }
  }
  return list;
}

/// A self-intersecting five-pointed star filled even-odd, so its middle is a
/// hole, inside a layer large enough to carry stencil and samples.
DisplayList _evenOddScene() => _starScene(pathFillRuleEvenOdd);

/// The same outline filled non-zero, so its middle is solid.
DisplayList _nonZeroScene() => _starScene(pathFillRuleNonZero);

DisplayList _starScene(int fillRule) {
  final DisplayList list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFFE0A030, fillRule: fillRule);
  final int layerPaint = list.addPaint(colorArgb: 0x99FFFFFF);
  list
    ..saveLayer(10, 10, 500, 500, layerPaint)
    ..drawPath(list.addPath(_pentagram(256, 256, 230)), fill)
    ..restore();
  return list;
}

/// The classic self-intersecting pentagram: five points visited two apart, so
/// every edge crosses two others and the centre is wound twice.
Path _pentagram(double cx, double cy, double r) {
  final PathBuilder builder = PathBuilder();
  for (var i = 0; i < 5; i++) {
    final double angle =
        (i * 2) * 2 * 3.141592653589793 / 5 - 1.5707963267948966;
    final double x = cx + r * _cos(angle);
    final double y = cy + r * _sin(angle);
    if (i == 0) {
      builder.moveTo(x, y);
    } else {
      builder.lineTo(x, y);
    }
  }
  builder.close();
  return builder.build();
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

Future<FrameRenderDiagnostics> _routesTaken(
  _RouteSession session,
  DisplayList list,
) async {
  RenderPolicyScope.install(session.policy.copyWith(
    diagnostics: RenderDiagnosticsMode.counters,
  ));
  final D3d11OffscreenTarget target = session.target();
  try {
    await target.renderDisplayList(list, clearColor: _clear);
    return RenderPolicyScope.diagnostics.snapshot();
  } finally {
    target.dispose();
  }
}

Future<Framebuffer> _render(_RouteSession session, DisplayList list) async {
  final D3d11OffscreenTarget target = session.target();
  try {
    await target.renderDisplayList(list, clearColor: _clear);
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

/// A swap chain whose back buffer is a render-target view the caller supplies.
///
/// `_StubSwapChain` in `d3d11_shared_caches_test.dart` answers `nullptr`, which
/// makes the target refuse the present before it submits anything - correct for
/// what that file measures and useless here, because the whole point is to get
/// a real submission through the window target's ordered path. A real chain
/// would need `IDXGIFactory2::CreateSwapChainForHwnd`, an `HWND`, a window
/// class and a message loop.
final class _ViewBackedSwapChain implements D3d11SwapChain {
  _ViewBackedSwapChain(this.backBufferView);

  @override
  final Pointer<Void> backBufferView;

  @override
  bool get isPresentable => true;

  @override
  int present() => 0;

  @override
  bool setSyncInterval(int interval) => true;

  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) =>
      null;
}

/// A Direct3D 11 device opened from a [RenderPolicy], the way the backend's own
/// `createDevice` opens one.
final class _RouteSession {
  _RouteSession._(this.policy, this.device, this.skipReason);

  final RenderPolicy policy;
  final D3d11RenderDevice? device;
  final String? skipReason;

  static _RouteSession open(RenderPolicy policy) {
    if (!Platform.isWindows) {
      return _RouteSession._(policy, null,
          'Direct3D 11 needs Windows; this is ${Platform.operatingSystem}');
    }
    try {
      return _RouteSession._(
        policy,
        // The two arguments `D3d11RendererBackend.createDevice` passes, from
        // the same two getters on the same policy.
        D3d11RendererBackend.openDevice(
          enableExperimentalCpuTessellation: policy.buildsTessellationExecutor,
          enableExperimentalStencilCover: policy.buildsStencilCoverExecutor,
        ),
        null,
      );
    } on Object catch (error) {
      return _RouteSession._(policy, null, 'no D3D11 device: $error');
    }
  }

  D3d11OffscreenTarget target() => device!.createTarget(
        const MemorySurfaceDescriptor(
          pixelWidth: _size,
          pixelHeight: _size,
          format: PixelFormat.rgba8888Premultiplied,
        ),
      ) as D3d11OffscreenTarget;

  void close() => device?.dispose();
}
