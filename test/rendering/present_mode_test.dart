/// The two [PresentPacer] implementations, and the refusals they owe.
///
/// `present_mode.dart` has said since it was written that "a backend that
/// cannot do what was asked says so, by name". Until now nothing implemented
/// the interface, so the rule was unenforceable and §68.3 described a file -
/// `win32_present_mode.dart` - that did not exist. These tests hold the two
/// implementations to the rule, in both directions: a refusal must name the
/// missing thing *and* must leave the previously applied mode in force, which
/// is the half that a silent downgrade would still pass.
///
/// Everything here is driven through injected doubles, deliberately. The
/// question "does `wglSwapIntervalEXT` return false over a remote desktop
/// session" is not answerable in a unit test and is not what these assert;
/// they assert what this repository does with each answer. The live half - a
/// real WGL context and a real DWM - is `tool/present_mode_smoke.dart`.
library;

import 'package:dart_ui/src/backends/win32/win32_present_mode.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_present_pacer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/present_mode.dart';
import 'package:test/test.dart';

void main() {
  group('GlSwapChainPresentPacer', () {
    test('fifo is swap interval 1 and immediate is 0', () {
      final swapChain = _FakeSwapChain();
      final pacer = GlSwapChainPresentPacer(swapChain);

      final PresentModeOutcome fifo =
          pacer.requestPresentMode(PresentMode.fifo);
      expect(fifo.accepted, isTrue);
      expect(fifo.applied, PresentMode.fifo);
      expect(swapChain.interval, 1);

      final PresentModeOutcome immediate =
          pacer.requestPresentMode(PresentMode.immediate);
      expect(immediate.accepted, isTrue);
      expect(swapChain.interval, 0);
      expect(pacer.presentMode, PresentMode.immediate);
    });

    test('mailbox is refused by name and changes nothing', () {
      final swapChain = _FakeSwapChain();
      final pacer = GlSwapChainPresentPacer(swapChain)
        ..requestPresentMode(PresentMode.immediate);
      final int before = swapChain.calls;

      final PresentModeOutcome outcome =
          pacer.requestPresentMode(PresentMode.mailbox);

      expect(outcome.accepted, isFalse);
      expect(outcome.requested, PresentMode.mailbox);
      // The rule the contract is for: what remains in force is what the caller
      // last got, never a downgrade it did not ask for.
      expect(outcome.applied, PresentMode.immediate);
      expect(pacer.presentMode, PresentMode.immediate);
      expect(swapChain.calls, before,
          reason: 'a refusal must not touch the driver');
      expect(outcome.diagnostic, isNotNull);
      expect(outcome.diagnostic!.kind, DiagnosticKind.unsupportedPlatform);
      // "Not supported" is not a reason; the message has to name the thing
      // that is missing.
      expect(outcome.diagnostic!.message, contains('mailbox'));
      expect(outcome.diagnostic!.message, contains('swap-interval'));
    });

    test('a driver with no swap control refuses both real modes', () {
      final swapChain = _FakeSwapChain(accepts: false);
      final pacer = GlSwapChainPresentPacer(
        swapChain,
        surfaceDescription: 'a remote desktop session',
      );

      for (final PresentMode mode in <PresentMode>[
        PresentMode.fifo,
        PresentMode.immediate,
      ]) {
        final PresentModeOutcome outcome = pacer.requestPresentMode(mode);
        expect(outcome.accepted, isFalse, reason: '$mode');
        expect(outcome.diagnostic!.message, contains('refused'));
        expect(outcome.diagnostic!.message, contains('remote desktop session'));
      }
      expect(pacer.supportedPresentModes, isEmpty);
    });

    test('supportedPresentModes probes the driver and restores the mode', () {
      // The probe has to *ask*, because neither WGL nor EGL exposes "can you"
      // apart from "do it". Asking must not leave the window in a mode nobody
      // requested.
      final swapChain = _FakeSwapChain();
      final pacer = GlSwapChainPresentPacer(swapChain)
        ..requestPresentMode(PresentMode.immediate);

      expect(
        pacer.supportedPresentModes,
        <PresentMode>{PresentMode.fifo, PresentMode.immediate},
      );
      expect(swapChain.interval, 0,
          reason: 'the probe put back the interval that was in force');
      expect(pacer.presentMode, PresentMode.immediate);
    });

    test('awaitVerticalBlank never waits, because the swap already does', () {
      final pacer = GlSwapChainPresentPacer(_FakeSwapChain())
        ..requestPresentMode(PresentMode.fifo);
      expect(pacer.awaitVerticalBlank(), isFalse);
    });
  });

  group('GdiPresentPacer', () {
    test('starts in immediate, which is what an unpaced BitBlt is', () {
      // Not a preference: the applied mode a refusal reports has to match what
      // the window is actually doing, and wiring a pacer in must not change
      // how anything presents until somebody asks it to.
      final pacer = GdiPresentPacer(dwm: DwmApi.open(open: _noDwm));
      expect(pacer.presentMode, PresentMode.immediate);
    });

    test('fifo is refused by name when the compositor is off', () {
      final pacer = GdiPresentPacer(
        dwm: DwmApi.open(open: _noDwm),
        surfaceDescription: 'a DIB window',
      );
      final PresentModeOutcome outcome =
          pacer.requestPresentMode(PresentMode.fifo);

      expect(outcome.accepted, isFalse);
      expect(outcome.applied, PresentMode.immediate);
      expect(outcome.diagnostic!.message, contains('dwmapi.dll'));
      expect(pacer.supportedPresentModes, <PresentMode>{PresentMode.immediate});
      expect(pacer.awaitVerticalBlank(), isFalse);
    });

    test('mailbox is refused by name whatever the compositor says', () {
      final pacer = GdiPresentPacer(dwm: DwmApi.open(open: _noDwm));
      final PresentModeOutcome outcome =
          pacer.requestPresentMode(PresentMode.mailbox);

      expect(outcome.accepted, isFalse);
      expect(outcome.diagnostic!.message, contains('mailbox'));
      expect(outcome.diagnostic!.message, contains('queue'));
      // The substitution the contract forbids: immediate is the closest thing
      // this path can do, and it must be offered under its own name rather
      // than handed back as if it were mailbox.
      expect(outcome.applied, isNot(PresentMode.mailbox));
    });

    test('immediate is always honoured', () {
      final pacer = GdiPresentPacer(dwm: DwmApi.open(open: _noDwm));
      final PresentModeOutcome outcome =
          pacer.requestPresentMode(PresentMode.immediate);
      expect(outcome.accepted, isTrue);
      expect(outcome.diagnostic, isNotNull,
          reason: 'the detail explains why this path does not tear anyway');
    });
  });

  group('UnpacedPresentation still answers the way it documents', () {
    test('accepts immediate and refuses the tear-free modes', () {
      final pacer = UnpacedPresentation(surfaceDescription: 'a golden target');
      expect(pacer.requestPresentMode(PresentMode.immediate).accepted, isTrue);
      for (final PresentMode mode in <PresentMode>[
        PresentMode.fifo,
        PresentMode.mailbox,
      ]) {
        final PresentModeOutcome outcome = pacer.requestPresentMode(mode);
        expect(outcome.accepted, isFalse);
        expect(outcome.diagnostic!.detail, contains('immediate'));
      }
    });
  });
}

/// `DynamicLibrary.open` that never opens, so `DwmApi` takes its failure path
/// on every platform - including the CI containers where `dwmapi.dll` does not
/// exist and the developer machines where it does.
Never _noDwm(String name) => throw ArgumentError('no $name in this test');

final class _FakeSwapChain implements GlSwapChain {
  _FakeSwapChain({this.accepts = true});

  /// Whether the driver honours a swap-interval request. False is a remote
  /// desktop session and a driver without `WGL_EXT_swap_control`.
  final bool accepts;

  int interval = 1;
  int calls = 0;

  @override
  bool setSwapInterval(int value) {
    calls++;
    if (!accepts) return false;
    interval = value;
    return true;
  }

  @override
  bool swapBuffers() => true;

  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) =>
      null;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
