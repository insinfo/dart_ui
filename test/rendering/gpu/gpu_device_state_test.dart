/// Device loss as a state, tested on a machine with no device.
///
/// That is the whole reason `gpu_device_state.dart` holds no handles: the
/// path a driver takes once a second - a TDR, a GPU switch, an unplugged
/// display - is otherwise only exercised by unplugging a monitor mid-test.
library;

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_device_state.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  group('GpuDeviceState', () {
    test('a fresh device is healthy and does not block a present', () {
      final state = GpuDeviceState();

      expect(state.isLost, isFalse);
      expect(state.lossDiagnostic, isNull);
      expect(state.lossCount, 0);
      expect(state.blockedPresent(), isNull);
    });

    test('the first reason wins', () {
      // The errors after a lost context are consequences of it. Letting a
      // later one overwrite the first would report "invalid framebuffer
      // operation" for a driver reset.
      final state = GpuDeviceState()
        ..markLost(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'the GL context was lost',
        ))
        ..markLost(const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'GL error during draw',
        ));

      expect(state.lossDiagnostic!.message, 'the GL context was lost');
      expect(state.lossCount, 1,
          reason: 'a device already lost is not lost a second time');
    });

    test('blockedPresent carries the reason into the result', () {
      final state = GpuDeviceState()
        ..markLost(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'the driver refused to make the context current',
          detail: '0x0507',
        ));

      final result = state.blockedPresent();
      expect(result, isNotNull);
      expect(result!.status, PresentStatus.deviceLost);
      expect(result.diagnostic!.message,
          'the driver refused to make the context current');
      expect(result.diagnostic!.detail, '0x0507');
    });

    test('a lost device stays lost across repeated presents', () {
      final state = GpuDeviceState()
        ..markLost(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'lost',
        ));

      // The failure mode the file was written against: a present that returns
      // deviceLost once and then silently skips frames forever.
      for (var i = 0; i < 3; i++) {
        expect(state.blockedPresent()?.status, PresentStatus.deviceLost);
      }
      expect(state.lossCount, 1);
    });

    test('recover clears the loss and lets presents through again', () {
      // Device loss is recoverable by definition - the window survives it -
      // so the state has to be able to come back after the owner rebuilt the
      // device's objects. lossCount keeps counting so a target still bumps
      // its generation and refuses frames begun before the loss.
      final state = GpuDeviceState()
        ..markLost(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'first',
        ));
      expect(state.recover(), isTrue);

      expect(state.isLost, isFalse);
      expect(state.lossDiagnostic, isNull);
      expect(state.blockedPresent(), isNull);
      expect(state.lossCount, 1);

      state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'second',
      ));
      expect(state.lossDiagnostic!.message, 'second');
      expect(state.lossCount, 2);
    });

    test('recovering a healthy device is a no-op, not an error', () {
      final state = GpuDeviceState();
      expect(state.recover(), isFalse);
      expect(state.lossCount, 0);
    });
  });
}
