import 'package:dart_ui/src/backends/macos/macos_backend_kind.dart';
import 'package:dart_ui/src/backends/macos/macos_backend_selection.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/platform/backend_selection.dart';
import 'package:test/test.dart';

BackendCandidate _candidate(
  MacosBackendKind kind, {
  bool supported = true,
  bool experimental = false,
}) {
  final name = 'macos.${kind.name}';
  return BackendCandidate(
    name: name,
    experimental: experimental,
    probe: BackendProbeResult(
      backendName: name,
      supported: supported,
      capabilities: supported
          ? const <Capability>{Capability.window}
          : const <Capability>{},
    ),
  );
}

void main() {
  final candidates = <BackendCandidate>[
    _candidate(MacosBackendKind.appkitNativeHost),
    _candidate(MacosBackendKind.skylight),
    _candidate(MacosBackendKind.appkitSignal, experimental: true),
  ];

  test('explicit enum request uses the fully-qualified candidate name', () {
    final selection = selectMacosBackendCandidates(
      candidates,
      const MacosBackendOptions(
        requested: MacosBackendKind.skylight,
        allowPrivateApi: true,
        skylightAbiValidated: true,
      ),
    );

    expect(selection.requested, 'macos.skylight');
    expect(selection.chosen?.name, 'macos.skylight');
  });

  test('SkyLight needs private permission and ABI validation', () {
    final deniedPrivate = selectMacosBackendCandidates(
      candidates,
      const MacosBackendOptions(requested: MacosBackendKind.skylight),
    );
    final deniedAbi = selectMacosBackendCandidates(
      candidates,
      const MacosBackendOptions(
        requested: MacosBackendKind.skylight,
        allowPrivateApi: true,
      ),
    );

    expect(deniedPrivate.chosen, isNull);
    expect(deniedAbi.chosen, isNull);
    final privateProbe = deniedPrivate.rejected
        .firstWhere((rejection) => rejection.name == 'macos.skylight')
        .probe;
    final abiProbe = deniedAbi.rejected
        .firstWhere((rejection) => rejection.name == 'macos.skylight')
        .probe;
    expect(
      privateProbe.failures.single.message,
      contains('not explicitly allowed'),
    );
    expect(
      abiProbe.failures.single.message,
      contains('ABI is not validated'),
    );
  });

  test('unsafe signal permission never makes it an automatic fallback', () {
    final selection = selectMacosBackendCandidates(
      <BackendCandidate>[
        _candidate(MacosBackendKind.appkitNativeHost, supported: false),
        _candidate(MacosBackendKind.skylight, supported: false),
        _candidate(MacosBackendKind.appkitSignal, experimental: true),
      ],
      const MacosBackendOptions(allowUnsafeSignal: true),
    );

    expect(selection.chosen, isNull);
    expect(
      selection.rejected.last.reason,
      RejectionReason.needsExplicitOptIn,
    );
  });

  test('signal backend needs both an explicit request and unsafe opt-in', () {
    final denied = selectMacosBackendCandidates(
      candidates,
      const MacosBackendOptions(requested: MacosBackendKind.appkitSignal),
    );
    final allowed = selectMacosBackendCandidates(
      candidates,
      const MacosBackendOptions(
        requested: MacosBackendKind.appkitSignal,
        allowUnsafeSignal: true,
      ),
    );

    expect(denied.chosen, isNull);
    expect(allowed.chosen?.name, 'macos.appkitSignal');
  });
}
