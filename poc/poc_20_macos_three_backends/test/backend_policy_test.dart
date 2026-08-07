import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';
import 'package:test/test.dart';

void main() {
  const allAvailable = MacosBackendAvailability(
    nativeHostAvailable: true,
    skylightAbiValidated: true,
    signalHijackAvailable: true,
  );

  test('native AppKit host is the default', () {
    final result = selectMacosBackend(availability: allAvailable);

    expect(result.selected, MacosBackendKind.appkitNativeHost);
    expect(result.attempts, hasLength(1));
  });

  test('SkyLight requires explicit private API permission and validated ABI',
      () {
    final result = selectMacosBackend(
      availability: const MacosBackendAvailability(
        nativeHostAvailable: false,
        skylightAbiValidated: true,
        signalHijackAvailable: false,
      ),
      request: const MacosBackendRequest(allowPrivateApi: true),
    );

    expect(result.selected, MacosBackendKind.skylight);
    expect(result.attempts.map((attempt) => attempt.kind), [
      MacosBackendKind.appkitNativeHost,
      MacosBackendKind.skylight,
    ]);
  });

  test('disabled private API produces an explicit rejection', () {
    final result = selectMacosBackend(
      availability: const MacosBackendAvailability(
        nativeHostAvailable: false,
        skylightAbiValidated: true,
        signalHijackAvailable: false,
      ),
    );

    expect(result.succeeded, isFalse);
    expect(result.attempts.last.reason, contains('not explicitly allowed'));
  });

  test('signal hijack is never an automatic fallback', () {
    final result = selectMacosBackend(
      availability: const MacosBackendAvailability(
        nativeHostAvailable: false,
        skylightAbiValidated: false,
        signalHijackAvailable: true,
      ),
      request: const MacosBackendRequest(allowUnsafeSignal: true),
    );

    expect(result.succeeded, isFalse);
    expect(
      result.attempts.map((attempt) => attempt.kind),
      isNot(contains(MacosBackendKind.appkitSignal)),
    );
  });

  test('signal backend reports recoverable but non-normal lifecycle', () {
    final descriptor = macosBackendDescriptors[MacosBackendKind.appkitSignal]!;

    expect(descriptor.hasRecoverableShutdown, isTrue);
    expect(descriptor.hasNormalAppKitLifecycle, isFalse);
    expect(descriptor.support, MacosBackendSupport.experimentalUnsafe);
  });

  test('signal hijack requires explicit preference and permission', () {
    final denied = selectMacosBackend(
      availability: allAvailable,
      request: const MacosBackendRequest(
        preferred: MacosBackendKind.appkitSignal,
        allowFallback: false,
      ),
    );
    final allowed = selectMacosBackend(
      availability: allAvailable,
      request: const MacosBackendRequest(
        preferred: MacosBackendKind.appkitSignal,
        allowUnsafeSignal: true,
        allowFallback: false,
      ),
    );

    expect(denied.succeeded, isFalse);
    expect(allowed.selected, MacosBackendKind.appkitSignal);
  });

  test('unavailable preference does not fall back when forbidden', () {
    final result = selectMacosBackend(
      availability: allAvailable,
      request: const MacosBackendRequest(
        preferred: MacosBackendKind.skylight,
        allowPrivateApi: false,
        allowFallback: false,
      ),
    );

    expect(result.succeeded, isFalse);
    expect(result.attempts, hasLength(1));
  });

  test('fallback records rejection before selecting native host', () {
    final result = selectMacosBackend(
      availability: allAvailable,
      request: const MacosBackendRequest(
        preferred: MacosBackendKind.skylight,
        allowPrivateApi: false,
      ),
    );

    expect(result.selected, MacosBackendKind.appkitNativeHost);
    expect(result.attempts.first.accepted, isFalse);
    expect(result.attempts.last.accepted, isTrue);
  });
}
