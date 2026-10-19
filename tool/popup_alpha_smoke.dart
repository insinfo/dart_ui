/// Checks real popup alpha composition, independently of widget goldens.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/default_platform_resolver.dart'
    as platform;
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';

Future<void> main(List<String> args) async {
  final options = ApplicationOptions.fromArguments([
    ...args.where((a) => a != '--hold'),
  ],
      size: const Size(360, 260),
      visible: true,
      title: 'Popup alpha smoke',
      environment: Platform.environment);
  final app = await Application.start(
    rootWidget: const ColoredBox(color: Color(0xff204060)),
    backends:
        platform.PlatformBackendResolver.defaultBackends(options: options),
    presentations: platform.PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  final running = app.run();
  try {
    await _until(() => app.primaryWindow.framesPresented > 0);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    stdout.writeln(
        'POPUP_ALPHA_ROOT=${app.primaryWindow.host.presenter.info.name} device=${app.primaryWindow.host.presenter.info.deviceDescription}');
    if (!app.popupWindowsAreTransparent) {
      throw StateError(
          'Backend does not support transparent popup composition');
    }
    for (final kind in [PopupKind.menu, PopupKind.tooltip]) {
      final popup = await app.openPopup(
          owner: app.primaryWindow,
          anchorRect: const Rect.fromLTWH(30, 30, 1, 1),
          kind: kind,
          content: const SizedBox(
              width: 160,
              height: 100,
              child: DecoratedBox(
                  decoration:
                      BoxDecoration(color: Color(0xffffffff), radius: 18))));
      await _until(() => popup.framesPresented > 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final snapshot = popup.paintSnapshot()!;
      final cpu = await const CpuRendererBackend().createDevice();
      final memory = cpu.createTarget(MemorySurfaceDescriptor(
              pixelWidth: popup.nativeWindow.clientSize.width.ceil(),
              pixelHeight: popup.nativeWindow.clientSize.height.ceil()))
          as MemoryRenderTarget;
      await memory.renderDisplayList(snapshot, clearColor: 0);
      final pixels = memory.framebuffer;
      final cornerAlpha = pixels.pixels[pixels.offsetOf(1, 1) + 3];
      final centerAlpha = pixels.pixels[pixels.offsetOf(80, 50) + 3];
      if (cornerAlpha != 0 || centerAlpha != 255) {
        throw StateError('Popup snapshot alpha: $cornerAlpha / $centerAlpha');
      }
      memory.dispose();
      cpu.dispose();
      stdout.writeln(
          'POPUP_ALPHA_BUFFER=PASS kind=$kind size=${popup.nativeWindow.clientSize}');
      if (popup.nativeWindow case final Win32Window native) {
        // A transparent framebuffer alone is insufficient: read the actual
        // desktop after UpdateLayeredWindow and DWM have composed it.
        final api = Win32Api.load().api!;
        final pixel = DynamicLibrary.open('gdi32.dll').lookupFunction<
            Uint32 Function(IntPtr, Int32, Int32),
            int Function(int, int, int)>('GetPixel');
        final dc = api.getDC(0);
        try {
          final corner = native.clientToScreen(const Offset(1, 1));
          final center = native.clientToScreen(const Offset(80, 50));
          final a = pixel(dc, corner.dx.round(), corner.dy.round());
          final b = pixel(dc, center.dx.round(), center.dy.round());
          if (a != 0x604020 || b != 0xffffff) {
            throw StateError(
                'Desktop composition: corner=${a.toRadixString(16)} '
                'center=${b.toRadixString(16)}');
          }
          stdout.writeln('POPUP_ALPHA_DESKTOP=PASS kind=$kind');
        } finally {
          api.releaseDC(0, dc);
        }
      }
      stdout.writeln(
          'POPUP_ALPHA kind=$kind renderer=${popup.host.presenter.info.name} '
          'frames=${popup.framesPresented}');
      if (args.contains('--hold')) {
        await Future<void>.delayed(const Duration(seconds: 15));
      }
      popup.close();
    }
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
    stdout.writeln('POPUP_ALPHA_SMOKE=PASS');
  } finally {
    app.requestClose();
    await running;
    app.dispose();
    await app.closed;
  }
}

Future<void> _until(bool Function() ready) async {
  final limit = DateTime.now().add(const Duration(seconds: 15));
  while (!ready()) {
    if (DateTime.now().isAfter(limit)) throw StateError('No presented frame');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
