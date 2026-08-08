/// probe() on any platform.
///
/// The important half of this file is what happens on a machine that is *not*
/// Windows: `DynamicLibrary.open('user32.dll')` on Linux is not an exception
/// worth catching, it is a crash of the probe itself, and a probe that crashes
/// cannot report why it failed. So the platform check comes first, and this
/// file runs everywhere to prove it.
library;

import 'dart:io' show Platform;

import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:test/test.dart';

void main() {
  late Win32WindowingBackend backend;

  setUp(() => backend = Win32WindowingBackend());

  test('the backend is named for its platform API, not for the OS', () {
    expect(backend.name, 'win32');
  });

  test('probe never throws, whatever it is running on', () {
    expect(backend.probe, returnsNormally);
  });

  test('probe is repeatable and gives the same verdict', () {
    final first = backend.probe();
    final second = backend.probe();
    expect(second.supported, first.supported);
    expect(second.capabilities, first.capabilities);
  });

  test('every probe carries diagnostics, successful or not', () {
    // Section 6.6: evidence is collected even from a probe that succeeded.
    expect(backend.probe().diagnostics, isNotEmpty);
  });

  test('describe() names the backend and its verdict', () {
    final described = backend.probe().describe();
    expect(described, contains('backend: win32'));
    expect(described, contains('supported: ${Platform.isWindows}'));
  });

  group('off Windows', () {
    test('unsupported, with the platform named rather than a bare false', () {
      final result = backend.probe();
      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);

      final reason = result.failures.single;
      expect(reason.kind, DiagnosticKind.unsupportedPlatform);
      // The operating system has to appear somewhere in the report, or the CI
      // log cannot tell "wrong platform" from "user32.dll missing".
      expect(
        '${reason.message} ${reason.detail}',
        contains(Platform.operatingSystem),
      );
    });

    test('initialize refuses with the probe attached to the error', () {
      expect(
        backend.initialize,
        throwsA(
          isA<BackendSelectionError>()
              .having((e) => e.requested, 'requested', 'win32')
              .having(
                (e) => e.attempts.single.diagnostics.single.kind,
                'reason',
                DiagnosticKind.unsupportedPlatform,
              ),
        ),
      );
    });
  }, skip: Platform.isWindows ? 'runs only off Windows' : false);

  group('on Windows', () {
    test('supported, and the DPI API that was found is reported', () {
      final result = backend.probe();
      expect(result.supported, isTrue);
      expect(result.failures, isEmpty);

      // The probe must say *which* DPI API it found, not merely whether DPI
      // works: the three of them behave differently on a second monitor.
      final dpiNote = result.diagnostics.firstWhere(
        (d) => (d.detail ?? '').contains('dpi api:'),
        orElse: () => fail('no diagnostic naming the DPI awareness API'),
      );
      expect(
        dpiNote.detail,
        anyOf(
          contains('perMonitorV2'),
          contains('perMonitorV1'),
          contains('systemOnly'),
          contains('none'),
        ),
      );
    });

    test('claims the capabilities it actually implements', () {
      final result = backend.probe();
      expect(result.supports(Capability.window), isTrue);
      expect(result.supports(Capability.multipleWindows), isTrue);
      expect(result.supports(Capability.cpuPresentation), isTrue);
      expect(result.supports(Capability.partialPresent), isTrue);
      expect(result.supports(Capability.orderlyShutdown), isTrue);
    });

    test('does not claim what it defers', () {
      final result = backend.probe();
      // Every one of these is unimplemented; claiming them would turn a
      // truthful "no" into a runtime surprise.
      expect(result.supports(Capability.textComposition), isFalse);
      expect(result.supports(Capability.clipboardText), isFalse);
      expect(result.supports(Capability.clipboardImage), isFalse);
      expect(result.supports(Capability.dragAndDrop), isFalse);
      expect(result.supports(Capability.accessibility), isFalse);
      expect(result.supports(Capability.vsync), isFalse);
      // ... and the deferral is written down, not just absent.
      expect(
        result.diagnostics.map((d) => d.message).join('\n'),
        contains('clipboard'),
      );
    });

    test('per-monitor DPI is claimed only with a per-window DPI query', () {
      final result = backend.probe();
      final report = result.describe();
      if (result.supports(Capability.perMonitorDpi)) {
        expect(report, isNot(contains('symbol not found: GetDpiForWindow')));
      }
    });

    test('pumpEvents before initialize is a caller bug, and says so', () {
      expect(
        backend.pumpEvents,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('before initialize()'),
          ),
        ),
      );
    });

    test('wake before initialize is a no-op rather than a crash', () {
      // A wake can race a shutdown from another isolate; refusing loudly would
      // make every teardown a source of spurious errors.
      expect(backend.wake, returnsNormally);
      expect(Win32WindowingBackend.wakeHandleFromAnyIsolate(0), isFalse);
    });

    test('shutdown without initialize is a no-op', () {
      expect(backend.shutdown(), completes);
    });
  }, skip: Platform.isWindows ? false : 'needs Windows');
}
