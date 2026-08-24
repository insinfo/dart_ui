/// One Direct2D device for a whole test file, or the reason there is none.
///
/// The same shape and the same skip contract as `d3d12_session.dart`, stated
/// there once: [platformSkip] says "not Windows at all", [skipReason] says
/// "Windows, but Direct2D would not open", and both are strings because
/// `skip:` prints a string and a skipped run has to say why.
library;

import 'dart:io';

import 'package:dart_ui/src/backends/win32/d2d/d2d_backend.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d_targets.dart';

final class D2dSession {
  D2dSession._(this.device, this.skipReason);

  /// Null on Windows; the reason to skip on every other platform.
  static final String? platformSkip = Platform.isWindows
      ? null
      : 'Direct2D exists only on Windows; this runner is '
          '${Platform.operatingSystem}';

  final D2dRenderDevice? device;

  /// Null when the device opened; the reason to skip when it did not.
  final String? skipReason;

  static D2dSession open() {
    if (!Platform.isWindows) {
      return D2dSession._(null, 'Direct2D exists only on Windows');
    }
    try {
      final D2dDeviceAttempt attempt = D2dRenderDevice.open();
      final D2dRenderDevice? device = attempt.device;
      if (device == null) {
        return D2dSession._(null, 'no Direct2D: ${attempt.failureText}');
      }
      return D2dSession._(device, null);
    } on Object catch (error) {
      return D2dSession._(null, 'opening a Direct2D device threw: $error');
    }
  }

  /// An offscreen surface of [width] by [height].
  ///
  /// [spriteBatching] false makes the sink take the `FillOpacityMask` loop a
  /// runtime without `ID2D1DeviceContext3` would take, so a test can compare
  /// the two routes on one machine instead of hoping about another.
  D2dOffscreenSurface surface(int width, int height,
          {bool spriteBatching = true}) =>
      device!.createOffscreenSurface(
        width: width,
        height: height,
        spriteBatching: spriteBatching,
      );

  void close() {
    device?.dispose();
  }
}
