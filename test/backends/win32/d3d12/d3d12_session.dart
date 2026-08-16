/// One Direct3D 12 device for a whole test file, or the reason there is none.
///
/// Shared because creating a device costs tens of milliseconds - it compiles
/// two shaders and builds three pipeline state objects - and doing it per test
/// would make a file's cost depend on how many assertions it contains. The
/// same argument `gl_device_test.dart` makes for a GL context.
///
/// ## The skip contract, stated once
///
/// The CI for this repository runs on Linux and macOS as well as Windows. A
/// test that *fails* there fails the gate, so every Direct3D 12 test must skip
/// with a reason that says which of the two things was missing:
///
///   * [platformSkip] - not Windows at all. Nothing in this directory can run.
///   * [skipReason] - Windows, but no device: no adapter reached feature level
///     11_0, `d3dcompiler_47.dll` is absent, or the whole runtime is.
///
/// Both are strings rather than bools because `skip:` prints a string, and a
/// run that skipped has to say why instead of looking like a run that passed.
library;

import 'dart:io';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_backend.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';

final class D3d12Session {
  D3d12Session._(this.device, this.skipReason, this._window);

  /// Null on Windows; the reason to skip on every other platform.
  ///
  /// For a test that needs no device - a probe that must not throw, a loader
  /// that must report rather than raise - and therefore only has to know which
  /// operating system it is on.
  static final String? platformSkip = Platform.isWindows
      ? null
      : 'Direct3D 12 exists only on Windows; this runner is '
          '${Platform.operatingSystem}';

  final D3d12RenderDevice? device;

  /// Null when the device opened. A string - which `skip:` accepts - when it
  /// did not, naming what was missing.
  final String? skipReason;

  final D3d12HiddenWindow? _window;

  /// Opens a device with the debug layer off.
  ///
  /// Off by default because it costs several times the driver call on every
  /// call and would make every test in the suite pay for the one file that
  /// needs it; `d3d12_barrier_test.dart` opens its own session with it on.
  static D3d12Session open({bool debugLayer = false, bool window = false}) {
    if (!Platform.isWindows) {
      return D3d12Session._(null, 'Direct3D 12 exists only on Windows', null);
    }
    try {
      final D3d12DeviceAttempt attempt =
          D3d12RenderDevice.open(debugLayer: debugLayer);
      final D3d12RenderDevice? device = attempt.device;
      if (device == null) {
        return D3d12Session._(
          null,
          'no Direct3D 12 device: ${attempt.failureText}',
          null,
        );
      }
      if (!window) return D3d12Session._(device, null, null);

      final D3d12HiddenWindowAttempt made = D3d12HiddenWindow.create();
      if (made.window == null) {
        device.dispose();
        return D3d12Session._(
          null,
          'no window for a swap chain: ${made.diagnostics.join('; ')}',
          null,
        );
      }
      return D3d12Session._(device, null, made.window);
    } on Object catch (error) {
      return D3d12Session._(
          null, 'opening a Direct3D 12 device threw: $error', null);
    }
  }

  /// The hidden window a swap chain presents into, when one was asked for.
  D3d12HiddenWindow? get window => _window;

  D3d12OffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as D3d12OffscreenTarget;

  void close() {
    device?.dispose();
    _window?.dispose();
  }
}
