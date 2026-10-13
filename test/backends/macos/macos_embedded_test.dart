/// The fourth macOS backend, `appkitEmbedded`, as far as it can be checked
/// without being inside the embedded runtime: when it is chosen, what it
/// claims, where it sits among the defaults, and the arithmetic of its
/// coordinates. The window itself is proven by `tool/macos/embedded_demo.dart`
/// built as a `.app` (doc/MACOS_TRES_BACKENDS.md, backend 4).
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/embedded/embedded_appkit.dart';
import 'package:dart_ui/src/backends/macos/embedded/embedded_backend.dart';
import 'package:dart_ui/src/backends/macos/embedded/embedded_runtime.dart';
import 'package:dart_ui/src/backends/macos/embedded/embedded_window.dart';
import 'package:dart_ui/src/backends/macos/macos_backend_kind.dart';
import 'package:test/test.dart';

void main() {
  group('runtime detection', () {
    test('only the patched runtime with its loop on, on thread 0, is active',
        () {
      MacosEmbeddedRuntimeStatus classify({
        bool macos = true,
        bool symbol = true,
        int loop = 1,
        bool main = true,
      }) =>
          classifyMacosEmbeddedRuntime(
            isMacOS: macos,
            hasLoopSymbol: symbol,
            loopValue: loop,
            onMainThread: main,
          );

      expect(classify(), MacosEmbeddedRuntimeStatus.active);
      expect(classify(macos: false), MacosEmbeddedRuntimeStatus.notMacos);
      expect(classify(symbol: false), MacosEmbeddedRuntimeStatus.stockRuntime);
      expect(classify(loop: 0), MacosEmbeddedRuntimeStatus.loopOff);
      expect(classify(main: false), MacosEmbeddedRuntimeStatus.notMainThread);
      for (final MacosEmbeddedRuntimeStatus status
          in MacosEmbeddedRuntimeStatus.values) {
        expect(status.isActive, status == MacosEmbeddedRuntimeStatus.active);
        expect(status.description, isNotEmpty);
      }
    });

    test('the test runner is a stock runtime, never the embedded one', () {
      // `dart test` runs on the stock VM, which lacks the patch's symbol:
      // the backend must refuse here, or every macOS run would pick it.
      expect(MacosEmbeddedRuntime.isActive, isFalse);
      expect(
        MacosEmbeddedRuntime.status,
        Platform.isMacOS
            ? MacosEmbeddedRuntimeStatus.stockRuntime
            : MacosEmbeddedRuntimeStatus.notMacos,
      );
    });
  });

  group('probe', () {
    test('outside the embedded runtime it is unsupported and says why', () {
      final BackendProbeResult result = MacosEmbeddedWindowingBackend(
        runtimeStatus: () => MacosEmbeddedRuntimeStatus.stockRuntime,
      ).probe();
      expect(result.supported, isFalse);
      expect(result.backendName, 'macos.appkitEmbedded');
      expect(
        result.diagnostics.map((BackendDiagnostic d) => d.message).join(),
        contains('build_app.dart'),
      );
    });

    test('inside it claims real popups, transparency and many windows', () {
      final BackendProbeResult result = MacosEmbeddedWindowingBackend(
        runtimeStatus: () => MacosEmbeddedRuntimeStatus.active,
      ).probe();
      expect(result.supported, isTrue);
      expect(
        result.capabilities,
        containsAll(<Capability>[
          Capability.window,
          Capability.pointerInput,
          Capability.keyboardInput,
          Capability.cpuPresentation,
          Capability.nativePopups,
          Capability.transparentPopups,
          Capability.multipleWindows,
          Capability.orderlyShutdown,
        ]),
      );
      // Not wired yet: no claim (doc/MACOS_TRES_BACKENDS.md, limitations).
      expect(result.capabilities, isNot(contains(Capability.clipboardText)));
      expect(result.capabilities, isNot(contains(Capability.textComposition)));
      expect(result.capabilities, isNot(contains(Capability.dragAndDrop)));
    });

    test('initialize refuses by name outside the runtime', () async {
      final MacosEmbeddedWindowingBackend backend =
          MacosEmbeddedWindowingBackend(
        runtimeStatus: () => MacosEmbeddedRuntimeStatus.stockRuntime,
      );
      await expectLater(
          backend.initialize(), throwsA(isA<UnsupportedCapabilityError>()));
    });

    test('the facade capability descriptor knows the kind', () {
      const MacosBackendCapabilities none = MacosBackendCapabilities(
        kind: MacosBackendKind.appkitEmbedded,
        canCreateWindow: false,
        hasInput: false,
        hasIme: false,
        hasAccessibility: false,
        hasOrderlyShutdown: false,
        needsHostBinary: false,
      );
      expect(none.toProbeResult().capabilities,
          isNot(contains(Capability.nativePopups)),
          reason: 'popups are claimed only with a window');
      expect(MacosBackendKind.values.last, MacosBackendKind.appkitEmbedded);
    });
  });

  group('resolver', () {
    test('the embedded backend is first on macOS and falls through elsewhere',
        () {
      final List<WindowingBackendEntry> backends =
          PlatformBackendResolver.defaultBackends(operatingSystem: 'macos');
      expect(backends.first.name, macosEmbeddedBackendName);
      expect(backends.first.experimental, isFalse,
          reason: 'chosen automatically inside its runtime');
      expect(backends[1].name, 'macos', reason: 'the default elsewhere');
      expect(
        PlatformBackendResolver.defaultBackends(operatingSystem: 'linux')
            .map((WindowingBackendEntry e) => e.name),
        isNot(contains(macosEmbeddedBackendName)),
      );
    });

    test('Metal first, then its own IOSurface CPU path', () {
      final List<PresentationPathEntry> paths =
          PlatformBackendResolver.defaultPresentations(
              operatingSystem: 'macos');
      bool serves(String path, String backend) =>
          paths
              .singleWhere((PresentationPathEntry p) => p.name == path)
              .compatibleWindowingBackends
              ?.contains(backend) ??
          true;
      final List<String> forEmbedded = <String>[
        for (final PresentationPathEntry path in paths)
          if (path.compatibleWindowingBackends
                  ?.contains(macosEmbeddedBackendName) ??
              true)
            path.name,
      ];
      expect(forEmbedded,
          <String>['metal', macosEmbeddedSurfaceKind, 'headless-cpu']);
      expect(serves(macosEmbeddedSurfaceKind, 'macos'), isFalse);
      expect(serves('macos-iosurface', macosEmbeddedBackendName), isFalse);
      expect(serves('macos-cpu', macosEmbeddedBackendName), isFalse);
    });
  });

  group('AppKit plumbing', () {
    test('every view method maps to its NSEventType', () {
      expect(macosEmbeddedViewEvents['mouseDown:'], 1);
      expect(macosEmbeddedViewEvents['rightMouseDown:'], 3);
      expect(macosEmbeddedViewEvents['mouseMoved:'], 5);
      expect(macosEmbeddedViewEvents['mouseExited:'], 9);
      expect(macosEmbeddedViewEvents['keyDown:'], 10);
      expect(macosEmbeddedViewEvents['scrollWheel:'], 22);
      expect(macosEmbeddedViewEvents.values.toSet().length,
          macosEmbeddedViewEvents.length);
      for (final MacosEmbeddedWindowNotification n
          in MacosEmbeddedWindowNotification.values) {
        expect(n.selector, startsWith('window'));
        expect(n.selector, endsWith(':'));
      }
    });

    test('screen rects flip between AppKit and the framework', () {
      // A 1080-point primary screen; a 640x420 client 197 points from the
      // top sits 463 points above AppKit's bottom-left origin.
      const Rect rect = Rect.fromLTWH(640, 197, 640, 420);
      final appKit = macosRectToAppKit(rect, 1080);
      expect(appKit.origin.x, 640);
      expect(appKit.origin.y, 463);
      expect(appKit.size.width, 640);
      expect(appKit.size.height, 420);
      expect(macosRectFromAppKit(appKit, 1080), rect);
    });
  });
}
