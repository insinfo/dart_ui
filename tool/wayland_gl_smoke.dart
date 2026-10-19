/// Exercises GPU rendering, DMA-BUF import/release and resize on a real
/// Wayland compositor. Run in the graphical user's session, not under X11.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/default_platform_resolver.dart'
    as platform;
import 'package:dart_ui/src/backends/wayland/wayland_backend.dart';
import 'package:dart_ui/src/backends/wayland/wayland_gl_surface.dart';
import 'package:dart_ui/src/backends/wayland/wayland_window.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_mesh_renderer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_window_target.dart';

Future<void> main() async {
  if (!Platform.isLinux || Platform.environment['WAYLAND_DISPLAY'] == null) {
    stdout.writeln('WAYLAND_GL_SMOKE=SKIP no Wayland session');
    exitCode = 2;
    return;
  }
  final backend = WaylandWindowingBackend();
  WaylandWindow? window;
  WaylandGlSurface? surface;
  GlRenderDevice? device;
  GlWindowTarget? target;
  try {
    await backend.initialize();
    window = await backend.createWindow(const WindowOptions(
      size: Size(320, 240),
      title: 'dart_ui Wayland GPU smoke',
    )) as WaylandWindow;
    await _pump(backend, () => window!.isConfigured, 'initial configure');
    surface = WaylandGlSurface.forWindow(window);
    device = GlRendererBackend.adoptContext(surface.context, surface.glLibrary);
    final mesh = GlMeshRenderer.create(device);
    if (mesh.renderer == null) {
      throw StateError('Mesh shaders: ${mesh.diagnostics}');
    }
    mesh.renderer!.dispose();
    stdout.writeln('WAYLAND_GL_DEVICE=${device.info.deviceDescription}');
    target = device.createTarget(surface.describeSurface(
        pixelWidth: window.pixelSize.width,
        pixelHeight: window.pixelSize.height,
        scale: window.renderScale)) as GlWindowTarget;
    for (final size in <Size>[
      const Size(320, 240),
      const Size(480, 320),
      const Size(400, 280),
      const Size(320, 240)
    ]) {
      window.setBounds(Rect.fromLTWH(0, 0, size.width, size.height));
      await _pump(backend, () => window!.clientSize == size, 'resize $size');
      target.resize(
          window.pixelSize.width, window.pixelSize.height, window.renderScale);
      for (var frame = 0; frame < 6; frame++) {
        final list = DisplayList();
        list.drawRect(16, 16, 160 + frame * 3.0, 100,
            list.addPaint(colorArgb: 0xff2680d0));
        final result =
            await target.renderDisplayList(list, clearColor: 0xffe8edf2);
        if (!result.isSuccess) {
          throw StateError('GPU present: ${result.diagnostic}');
        }
        await _pump(backend, () => !window!.isFrameThrottled, 'frame callback');
      }
    }
    if (surface.submittedFrames < 24 || surface.importedBuffers == 0) {
      throw StateError('No real DMA-BUF commits: ${surface.submittedFrames}');
    }
    stdout.writeln('WAYLAND_GL_PRESENT=PASS commits=${surface.submittedFrames} '
        'imports=${surface.importedBuffers} releases=${surface.releasedBuffers}');
    stdout.writeln('WAYLAND_GL_RESIZE=PASS context preserved across 3 resizes');
  } on Object catch (error, stack) {
    stderr.writeln('WAYLAND_GL_SMOKE=FAIL $error\n$stack');
    exitCode = 1;
  } finally {
    target?.dispose();
    device?.dispose();
    surface?.dispose();
    window?.dispose();
    await backend.shutdown();
    if (surface != null && surface.liveGenerations != 0) {
      stderr.writeln(
          'WAYLAND_GL_CLEANUP=FAIL ${surface.liveGenerations} generations');
      exitCode = 1;
    }
  }
  if (exitCode == 0) {
    try {
      await _applicationPopups();
      stdout.writeln('WAYLAND_GL_SMOKE=PASS');
    } on Object catch (error, stack) {
      stderr.writeln('WAYLAND_GL_POPUPS=FAIL $error\n$stack');
      exitCode = 1;
    }
  }
}

Future<void> _pump(WaylandWindowingBackend backend, bool Function() ready,
    String stage) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out: $stage');
    }
    backend.pumpEvents(timeout: const Duration(milliseconds: 10));
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _applicationPopups() async {
  final options = ApplicationOptions(
      visible: true,
      size: const Size(400, 300),
      requestedBackend: 'wayland',
      requestedPresentation: 'wayland-opengl',
      environment: Platform.environment);
  final app = await Application.start(
      rootWidget: const ColoredBox(color: Color(0xffe8edf2)),
      backends:
          platform.PlatformBackendResolver.defaultBackends(options: options),
      presentations: platform.PlatformBackendResolver.defaultPresentations(),
      options: options);
  final running = app.run();
  try {
    final owner = app.primaryWindow;
    await _waitUntil(() => owner.framesPresented > 0, 'application frame');
    final popup = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(20, 20, 1, 1),
        content: const SizedBox(
            width: 183,
            height: 148,
            child: ColoredBox(color: Color(0xff4080c0))),
        kind: PopupKind.menu);
    final native = popup.nativeWindow as WaylandWindow;
    await _waitUntil(() => native.isConfigured && popup.framesPresented > 0,
        'measured popup frame');
    if (native.clientSize != const Size(183, 148)) {
      throw StateError('Popup expanded to ${native.clientSize}');
    }
    final nested = await app.openPopup(
        owner: owner,
        parentPopup: popup,
        anchorRect: const Rect.fromLTWH(30, 20, 1, 1),
        content: const SizedBox(
            width: 120,
            height: 80,
            child: ColoredBox(color: Color(0xff80b040))),
        kind: PopupKind.menu);
    final nestedNative = nested.nativeWindow as WaylandWindow;
    await _waitUntil(
        () => nestedNative.isConfigured && nested.framesPresented > 0,
        'nested measured popup frame');
    if (nestedNative.clientSize != const Size(120, 80)) {
      throw StateError('Nested popup expanded to ${nestedNative.clientSize}');
    }
    if (app.errors.isNotEmpty) {
      throw StateError('Application errors: ${app.errors}');
    }
    stdout.writeln('WAYLAND_GL_POPUPS=PASS measured=183x148 nested=120x80');
  } finally {
    app.requestClose();
    await running;
    app.dispose();
    await app.closed;
  }
}

Future<void> _waitUntil(bool Function() ready, String stage) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out: $stage');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
