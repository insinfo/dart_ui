/// Whether an application can reach the compute-tile rasteriser at all.
///
/// This file exists because the answer used to be **no**, and nothing said so.
/// `GpuPathStrategy.computeTiles` was gated on
/// `D3d12RenderDevice.experimentalComputeTilesEnabled`, which is
/// `_computeTileExecutor != null`, which came from a constructor flag that the
/// two production call sites in `d3d12_backend.dart` did not pass. The only
/// construction site in the entire repository was a **test session**. So a
/// pipeline with byte-for-byte parity against the coverage atlas was
/// unreachable from any program, and the gap was invisible: every test that
/// exercised it opened the device itself and therefore saw it working.
///
/// The tests below are the ones that would have caught that. They open a
/// device through the **production path** — `D3d12RendererBackend.createDevice`
/// — and ask whether the executor came back, which is the only question an
/// application can ask.
///
/// ## What reaching it does and does not mean
///
/// It reaches the **CPU-planned** tile route: `ComputeTileScene` bins on the
/// CPU and coverage and composition run in compute shaders. That half is
/// finished.
///
/// It does **not** reach the fully GPU-side pipeline — flatten, coarse
/// binning, segment binning, chained coverage — which exists and is
/// parity-tested and is on **no** draw path, because
/// `d3d12_vector_path_recorder.dart` builds its plan on the CPU. That is a
/// separate gap and this file does not pretend to close it.
library;

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_backend.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/render_policy.dart';
import 'package:test/test.dart';

void main() {
  const D3d12RendererBackend backend = D3d12RendererBackend();
  final probe = backend.probe();
  final String? skip =
      probe.supported ? null : 'no Direct3D 12 device: ${probe.diagnostics}';

  /// Opens a device the way the composition root does, under [policy].
  Future<D3d12RenderDevice> openUnder(RenderPolicy policy) async {
    final RenderPolicy previous = RenderPolicyScope.policy;
    RenderPolicyScope.install(policy);
    try {
      return await backend.createDevice() as D3d12RenderDevice;
    } finally {
      RenderPolicyScope.install(previous);
    }
  }

  group('the policy decides, before the driver has a say', () {
    test('the default policy asks for no compute executor', () {
      // The important half of the switch: an ordinary application must not
      // pay for a research path it never named.
      expect(
        const RenderPolicy().buildsComputeTilesExecutor,
        isFalse,
      );
      expect(
        const RenderPolicy(routes: GpuRouteAvailability.largeAnimatedPaths)
            .buildsComputeTilesExecutor,
        isFalse,
        reason: 'approach B and C are finished routes with a measured cost; '
            'folding an incomplete pipeline into the same request would '
            'enable it for applications that asked for something else',
      );
    });

    test('the route asks for it by name', () {
      expect(
        const RenderPolicy(
          routes: GpuRouteAvailability.experimentalComputeTiles,
        ).buildsComputeTilesExecutor,
        isTrue,
      );
    });

    test('and the strategy switch still takes it back out', () {
      // `GpuStrategySwitches` existed and defaulted to true long before
      // anything could act on it. Asserting it here is what keeps the switch
      // from becoming decoration.
      expect(
        const RenderPolicy(
          routes: GpuRouteAvailability.experimentalComputeTiles,
          strategies: GpuStrategySwitches(computeTiles: false),
        ).buildsComputeTilesExecutor,
        isFalse,
      );
    });

    test('the diagnostics name the route that was built', () {
      final List<BackendDiagnostic> notes = const RenderPolicy(
        routes: GpuRouteAvailability.experimentalComputeTiles,
      ).describe();
      expect(
        notes.map((BackendDiagnostic d) => '${d.message} ${d.detail}').join(),
        contains('computeTiles'),
        reason: 'a route that is built and not reported is a route nobody can '
            'confirm from a log',
      );
    });
  });

  group('a device opened through the production path', () {
    test('has no compute executor under the default policy', () async {
      final D3d12RenderDevice device = await openUnder(const RenderPolicy());
      addTearDown(device.dispose);

      expect(
        device.experimentalComputeTilesEnabled,
        isFalse,
        reason: 'the default must not build a research pipeline',
      );
    });

    test('has one when the route is asked for by name', () async {
      // The assertion that did not exist and could not have: before the route
      // was wired, this device came back with the executor null however the
      // policy was set, because `createDevice` never read the policy at all.
      final D3d12RenderDevice device = await openUnder(
        const RenderPolicy(
          routes: GpuRouteAvailability.experimentalComputeTiles,
        ),
      );
      addTearDown(device.dispose);

      expect(device.experimentalComputeTilesEnabled, isTrue);
    });

    test('and none again when the switch turns it off', () async {
      final D3d12RenderDevice device = await openUnder(
        const RenderPolicy(
          routes: GpuRouteAvailability.experimentalComputeTiles,
          strategies: GpuStrategySwitches(computeTiles: false),
        ),
      );
      addTearDown(device.dispose);

      expect(device.experimentalComputeTilesEnabled, isFalse);
    });
  }, skip: skip);
}
