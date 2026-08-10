import 'package:dart_ui/src/backends/x11/x11_backend.dart';
import 'package:dart_ui/src/backends/x11/x11_connection.dart';
import 'package:dart_ui/src/backends/x11/x11_scale.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:test/test.dart';

final class _FakeConnection implements X11BackendConnection {
  _FakeConnection({
    this.valid = true,
    this.invalidateDuringInspection = false,
    this.resourceManager,
    Set<String> extensions = const <String>{},
    X11PhysicalScreen? screen,
  })  : extensions = Set<String>.of(extensions),
        physicalScreen = screen ??
            const X11PhysicalScreen(
              widthInPixels: 1920,
              heightInPixels: 1080,
              widthInMillimetres: 509,
              heightInMillimetres: 286,
            );

  bool valid;
  final bool invalidateDuringInspection;
  final String? resourceManager;

  @override
  final Set<String> extensions;

  @override
  final X11PhysicalScreen physicalScreen;

  @override
  bool isDisposed = false;

  int disposeCalls = 0;
  int wakeCalls = 0;

  @override
  bool get isValid => valid && !isDisposed;

  @override
  String? readResourceManager() {
    if (invalidateDuringInspection) valid = false;
    return resourceManager;
  }

  @override
  bool signalWake() {
    wakeCalls++;
    return true;
  }

  @override
  void dispose() {
    if (isDisposed) return;
    isDisposed = true;
    disposeCalls++;
  }
}

X11ConnectionAttempt _success(_FakeConnection connection) {
  return X11ConnectionAttempt(
    connection: connection,
    diagnostics: const <BackendDiagnostic>[
      BackendDiagnostic.note('fake X11 connection opened'),
    ],
  );
}

void main() {
  group('probe', () {
    test('rejects another OS before trying to load or connect', () {
      var openCalls = 0;
      final backend = X11WindowingBackend(
        isLinux: false,
        operatingSystem: 'windows',
        environment: const <String, String>{'DISPLAY': ':0'},
        connectionOpener: (_) {
          openCalls++;
          return const X11ConnectionAttempt(
            connection: null,
            diagnostics: <BackendDiagnostic>[],
          );
        },
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);
      expect(result.failures.single.kind, DiagnosticKind.unsupportedPlatform);
      expect(result.failures.single.detail, contains('windows'));
      expect(openCalls, 0);
    });

    test('requires DISPLAY before opening a connection', () {
      var openCalls = 0;
      final backend = X11WindowingBackend(
        isLinux: true,
        operatingSystem: 'linux',
        environment: const <String, String>{},
        connectionOpener: (_) {
          openCalls++;
          return const X11ConnectionAttempt(
            connection: null,
            diagnostics: <BackendDiagnostic>[],
          );
        },
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);
      expect(result.failures.single.message, 'DISPLAY not set');
      expect(openCalls, 0);
    });

    test('opens, inspects and closes a temporary connection', () {
      final connection = _FakeConnection(
        resourceManager: 'Xft.dpi: 144',
        extensions: const <String>{'RANDR', 'MIT-SHM'},
      );
      final backend = X11WindowingBackend(
        isLinux: true,
        operatingSystem: 'linux',
        environment: const <String, String>{'DISPLAY': ':77'},
        connectionOpener: (display) {
          expect(display, ':77');
          return _success(connection);
        },
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);
      expect(backend.scale?.scale, 1.5);
      expect(backend.scale?.source, X11ScaleSource.xftDpi);
      expect(connection.disposeCalls, 1);
      expect(
        result.diagnostics.map((item) => item.message).join('\n'),
        contains('not selectable yet'),
      );
      expect(
        result.failures.single.kind,
        DiagnosticKind.rejectedByPolicy,
      );
      expect(
        result.diagnostics.map((item) => item.message).join('\n'),
        contains('randr=yes'),
      );
    });

    test('rejects a connection that becomes invalid during inspection', () {
      final connection = _FakeConnection(invalidateDuringInspection: true);
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':78'},
        connectionOpener: (_) => _success(connection),
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(connection.disposeCalls, 1);
      expect(
        result.failures.map((item) => item.message),
        contains('X11 connection became invalid after probe inspection'),
      );
      expect(
        result.failures.map((item) => item.kind),
        isNot(contains(DiagnosticKind.rejectedByPolicy)),
      );
    });

    test('reports opener failure and does not claim support', () {
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':88'},
        connectionOpener: (_) => const X11ConnectionAttempt(
          connection: null,
          diagnostics: <BackendDiagnostic>[
            BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'synthetic refusal',
            ),
          ],
        ),
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);
      expect(result.failures.map((item) => item.message),
          contains('synthetic refusal'));
      expect(backend.diagnostics, result.diagnostics);
    });

    test('turns an opener exception into a diagnostic', () {
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':89'},
        connectionOpener: (_) => throw StateError('synthetic opener crash'),
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(
        result.failures.map((item) => item.message),
        contains('X11 connection opener threw'),
      );
    });
  });

  group('connection ownership', () {
    test('initialize owns one connection and shutdown closes it once',
        () async {
      final connection = _FakeConnection();
      var openCalls = 0;
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':99'},
        connectionOpener: (_) {
          openCalls++;
          return _success(connection);
        },
      );

      await backend.initialize();
      await backend.initialize();
      expect(openCalls, 1);
      expect(connection.disposeCalls, 0);

      backend.wake();
      expect(connection.wakeCalls, 1);

      await backend.shutdown();
      await backend.shutdown();
      expect(connection.disposeCalls, 1);

      backend.wake();
      expect(connection.wakeCalls, 1);
    });

    test('initialize failure carries the real connection diagnostic', () async {
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':100'},
        connectionOpener: (_) => const X11ConnectionAttempt(
          connection: null,
          diagnostics: <BackendDiagnostic>[
            BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'xcb_connect failed in test',
            ),
          ],
        ),
      );

      await expectLater(
        backend.initialize(),
        throwsA(
          isA<BackendSelectionError>()
              .having((error) => error.requested, 'requested', 'x11')
              .having(
                (error) =>
                    error.attempts.single.failures.map((item) => item.message),
                'failures',
                contains('xcb_connect failed in test'),
              ),
        ),
      );
      await backend.shutdown();
    });

    test('invalid returned connection is disposed and rejected', () async {
      final connection = _FakeConnection(valid: false);
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':101'},
        connectionOpener: (_) => _success(connection),
      );

      await expectLater(
        backend.initialize(),
        throwsA(isA<BackendSelectionError>()),
      );
      expect(connection.disposeCalls, 1);
    });

    test('initialize revalidates the connection after inspection', () async {
      final connection = _FakeConnection(invalidateDuringInspection: true);
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':102'},
        connectionOpener: (_) => _success(connection),
      );

      await expectLater(
        backend.initialize(),
        throwsA(
          isA<BackendSelectionError>().having(
            (error) =>
                error.attempts.single.failures.map((item) => item.message),
            'failures',
            contains(
              'X11 connection became invalid after initialization inspection',
            ),
          ),
        ),
      );
      expect(connection.disposeCalls, 1);
      backend.wake();
      expect(connection.wakeCalls, 0);
    });
  });
}
