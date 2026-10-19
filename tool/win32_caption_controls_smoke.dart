/// Verifies painted caption controls through the real HWND input route.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/default_platform_resolver.dart'
    as platform;
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) throw UnsupportedError('This smoke needs Windows');
  final options = ApplicationOptions.fromArguments(args,
      title: 'Caption controls smoke',
      size: const Size(640, 420),
      titleBar: WindowTitleBar.hidden,
      visible: true,
      environment: Platform.environment);
  final app = await Application.start(
      rootWidget: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WindowDragArea(child: SizedBox(height: 40)),
            Expanded(child: ColoredBox(color: Color(0xfff6f7fb))),
          ]),
      backends:
          platform.PlatformBackendResolver.defaultBackends(options: options),
      presentations: platform.PlatformBackendResolver.defaultPresentations(),
      options: options);
  final running = app.run();
  final api = Win32Api.load().api!;
  final window = app.primaryWindow.nativeWindow as Win32Window;
  Future<void> wait(bool Function() ready, String operation) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('$operation timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
  }

  int pack(Offset p) =>
      ((p.dx * window.renderScale).round() & 0xffff) |
      (((p.dy * window.renderScale).round() & 0xffff) << 16);
  void press(int code, {bool outside = false}) {
    final r = window.systemButtons.value;
    final local = Offset(
        r.left +
            (code == 8
                ? 23
                : code == 9
                    ? 69
                    : 115),
        r.center.dy);
    api.postMessageW(
        window.handle, 0x00A1, code, pack(window.clientToScreen(local)));
    // Windows sends a client release once the press has taken mouse capture.
    api.postMessageW(window.handle, wmLbuttonup, 0,
        pack(outside ? const Offset(100, 100) : local));
  }

  try {
    await wait(() => app.primaryWindow.framesPresented > 0, 'first frame');
    if (!window.isTitleBarHidden) {
      throw StateError('Custom caption unavailable');
    }
    final getCursor = DynamicLibrary.open('user32.dll')
        .lookupFunction<IntPtr Function(), int Function()>('GetCursor');
    final arrow = window.cursorHandle;
    window.setCursor(SystemCursor.text);
    for (final hit in [8, 9, 20]) {
      window.handleMessage(
          window.handle, wmSetcursor, window.handle, hit | (wmMousemove << 16));
      if (getCursor() != arrow) {
        throw StateError('Caption cursor missing: $hit');
      }
    }
    window.handleMessage(window.handle, wmSetcursor, window.handle,
        htClient | (wmMousemove << 16));
    if (getCursor() != window.cursorHandle) {
      throw StateError('Client cursor lost');
    }
    window.setCursor(SystemCursor.arrow);
    press(9);
    await wait(() => window.state == WindowState.maximised, 'maximize');
    press(9);
    await wait(() => window.state == WindowState.normal, 'restore');
    press(9, outside: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (window.state != WindowState.normal || api.getCapture() != 0) {
      throw StateError('Cancelled caption press activated or retained capture');
    }
    press(8);
    await wait(() => window.state == WindowState.minimised, 'minimize');
    window.requestState(WindowState.normal);
    await wait(
        () => window.state == WindowState.normal, 'restore after minimize');
    press(20);
    await running.timeout(const Duration(seconds: 5));
    if (app.errors.isNotEmpty || api.getCapture() != 0) {
      throw StateError(
          'Close retained errors or native capture: ${app.errors}');
    }
    stdout.writeln('CAPTION_CONTROLS=PASS cursor=PASS capture=RELEASED');
  } finally {
    app.requestClose();
    await running;
    app.dispose();
    await app.closed;
  }
}
