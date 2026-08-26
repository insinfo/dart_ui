/// Proves `PresentMode` reaches a real driver, in a real window.
///
/// `PresentMode` and `PresentPacer` were a contract with no implementation:
/// nothing in `lib/` implemented the interface, the file §68.3 said the WGL
/// and GDI pacing lived in did not exist, and `present_mode.dart` was not even
/// exported from `dart_ui.dart`. `GlSwapChainPresentPacer` and
/// `GdiPresentPacer` are the implementations; `test/rendering/present_mode_test.dart`
/// holds them to the refusal rules through injected doubles. This file is the
/// other half, and it is the half a unit test cannot be:
///
///   * a headless run gives a **false green** for presentation in this
///     repository - the offscreen target is not a window's back buffer and its
///     swap chain is not a driver's - so "the pacer compiles and returns
///     accepted" proves nothing about whether `wglSwapIntervalEXT` did
///     anything;
///   * the only evidence that a mode took effect is the **cadence**. Under
///     `PresentMode.fifo` the swap blocks on the vertical blank and the loop
///     settles at the monitor's refresh rate; under `PresentMode.immediate` it
///     does not block and the loop runs as fast as the driver will take
///     buffers. A run where the two are the same speed is a run where the
///     request went nowhere, and that is the failure this file detects.
///
/// ```
/// dart run tool/present_mode_smoke.dart
/// ```
///
/// Prints one `PRESENT_MODE=` line per mode plus a verdict, and exits non-zero
/// when a request was refused unexpectedly, when the two modes did not
/// separate, or when the window could not be opened at all.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/backends/win32/win32_present_mode.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_window_target.dart';

const int _width = 640;
const int _height = 360;
const int _frames = 90;
const int _swShow = 5;

Future<void> main() async {
  if (!Platform.isWindows) {
    stderr.writeln('PRESENT_MODE=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }

  final Win32Api? api = Win32Api.load().api;
  if (api == null) {
    stderr.writeln('PRESENT_MODE=SKIP reason=no user32/gdi32');
    exitCode = 2;
    return;
  }

  // The GDI half first. It needs no window of its own: the pacer's answers are
  // about `dwmapi.dll` and the compositor, and both are process-wide.
  final gdi = GdiPresentPacer(surfaceDescription: 'a Win32 DIB window');
  stdout.writeln('PRESENT_MODE_GDI composited=${gdi.isComposited} '
      'supported=${_names(gdi.supportedPresentModes)}');
  for (final PresentMode mode in PresentMode.values) {
    final PresentModeOutcome outcome = gdi.requestPresentMode(mode);
    stdout.writeln('  gdi ${mode.name}: $outcome');
  }
  // Put it back where a running window would want it before timing anything.
  gdi.requestPresentMode(PresentMode.immediate);
  final Stopwatch flush = Stopwatch()..start();
  gdi.requestPresentMode(PresentMode.fifo);
  final bool waited = gdi.awaitVerticalBlank();
  flush.stop();
  stdout.writeln('  gdi DwmFlush waited=$waited '
      'took=${flush.elapsedMicroseconds / 1000}ms');
  if (gdi.requestPresentMode(PresentMode.mailbox).accepted) {
    stderr.writeln('PRESENT_MODE=FAIL gdi accepted mailbox');
    exitCode = 1;
    return;
  }

  // The GL half, which needs a real window a driver will actually pace.
  final attempt = Win32GlSurface.hidden(width: _width, height: _height);
  final Win32GlSurface? surface = attempt.surface;
  if (surface == null) {
    stderr
        .writeln('PRESENT_MODE=SKIP reason=${attempt.diagnostics.join('; ')}');
    exitCode = 2;
    return;
  }
  // Shown, not hidden. A driver is entitled to skip the vertical-blank wait
  // for a window nobody can see, and a run that measured that would report
  // fifo as unpaced and blame this framework for it.
  api
    ..showWindow(surface.windowHandle, _swShow)
    ..updateWindow(surface.windowHandle);

  final contextAttempt = surface.createContext();
  final GlContext? context = contextAttempt.context;
  if (context == null) {
    surface.dispose();
    stderr.writeln(
        'PRESENT_MODE=SKIP reason=${contextAttempt.diagnostics.join('; ')}');
    exitCode = 2;
    return;
  }

  final GlRenderDevice device =
      GlRendererBackend.adoptContext(context, surface.glLibrary);
  final target = GlWindowTarget(
    device,
    GlWindowSurfaceDescriptor(
      nativeHandle: surface.windowHandle,
      pixelWidth: _width,
      pixelHeight: _height,
      swapChain: surface,
      generation: GenerationToken(),
    ),
  );

  // The type test `present_mode.dart` documents, applied the way an owner
  // holding a bare `RenderTarget` would have to apply it - through the static
  // type it actually has, so the check is the runtime one and not a tautology
  // the analyser folds away.
  final RenderTarget erased = target;
  if (erased is! PresentPacer) {
    stderr.writeln('PRESENT_MODE=FAIL the GL window target is not a '
        'PresentPacer, so no application can ask it for a mode');
    exitCode = 1;
    return;
  }
  final PresentPacer pacer = erased as PresentPacer;
  stdout.writeln('PRESENT_MODE_GL device=${device.info.deviceDescription} '
      'supported=${_names(pacer.supportedPresentModes)}');

  if (!pacer.requestPresentMode(PresentMode.mailbox).accepted) {
    stdout.writeln('  gl mailbox refused as it must: '
        '${pacer.requestPresentMode(PresentMode.mailbox)}');
  } else {
    stderr.writeln('PRESENT_MODE=FAIL a GL window accepted mailbox');
    exitCode = 1;
    return;
  }

  final Map<PresentMode, double> rate = <PresentMode, double>{};
  for (final PresentMode mode in <PresentMode>[
    PresentMode.immediate,
    PresentMode.fifo,
  ]) {
    final PresentModeOutcome outcome = pacer.requestPresentMode(mode);
    stdout.writeln('  gl ${mode.name}: $outcome');
    if (!outcome.accepted) continue;
    rate[mode] = await _measure(target, mode);
  }

  target.dispose();
  device.dispose();
  context.dispose();
  surface.dispose();

  final double? fifo = rate[PresentMode.fifo];
  final double? immediate = rate[PresentMode.immediate];
  if (fifo == null || immediate == null) {
    stdout.writeln('PRESENT_MODE=PARTIAL one mode was refused by the driver, '
        'which is a legitimate answer over a remote session');
    exitCode = 0;
    return;
  }
  // The verdict. Immediate has to be meaningfully faster than fifo, or the
  // swap interval never reached the driver. A tenth is deliberately generous:
  // on a 60 Hz panel the real separation is several times over, and a bound
  // this loose still fails a request that did nothing.
  final bool separated = immediate > fifo * 1.1;
  stdout.writeln('PRESENT_MODE=${separated ? 'PASS' : 'FAIL'} '
      'fifo=${fifo.toStringAsFixed(1)}fps '
      'immediate=${immediate.toStringAsFixed(1)}fps '
      'ratio=${(immediate / fifo).toStringAsFixed(2)}x');
  exitCode = separated ? 0 : 1;
}

/// Frames per second the window actually presented in [mode].
Future<double> _measure(GlWindowTarget target, PresentMode mode) async {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF2E7D32);
  list.drawRect(0, 0, _width.toDouble(), _height.toDouble(), paint);

  // Two frames thrown away: the first swap after a swap-interval change is
  // where the driver applies it, and timing it would charge the change to the
  // mode.
  for (var i = 0; i < 2; i++) {
    await target.renderDisplayList(list, clearColor: 0xFF101418);
  }

  final Stopwatch watch = Stopwatch()..start();
  var presented = 0;
  for (var i = 0; i < _frames; i++) {
    final PresentResult result =
        await target.renderDisplayList(list, clearColor: 0xFF101418);
    if (result.status == PresentStatus.presented) presented++;
  }
  watch.stop();
  if (presented == 0 || watch.elapsedMicroseconds == 0) return 0;
  return presented * 1000000 / watch.elapsedMicroseconds;
}

String _names(Set<PresentMode> modes) => modes.isEmpty
    ? 'none'
    : (modes.map((PresentMode mode) => mode.name).toList()..sort()).join('+');
