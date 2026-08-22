// ignore_for_file: implementation_imports
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/backends/x11/x11_gl_surface.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:ffi/ffi.dart';

import 'presenter.dart';
import 'x11_context.dart';

const int _glColorBufferBit = 0x00004000;
const int _glRenderer = 0x1f01;
const int _glVersion = 0x1f02;

typedef _GlClearColorNative = Void Function(Float, Float, Float, Float);
typedef _GlClearColorDart = void Function(double, double, double, double);
typedef _GlClearNative = Void Function(Uint32);
typedef _GlClearDart = void Function(int);
typedef _GlFinishNative = Void Function();
typedef _GlFinishDart = void Function();
typedef _GlViewportNative = Void Function(Int32, Int32, Int32, Int32);
typedef _GlViewportDart = void Function(int, int, int, int);
typedef _GlGetStringNative = Pointer<Uint8> Function(Uint32);
typedef _GlGetStringDart = Pointer<Uint8> Function(int);

final class EglOpenGlPresenter implements FramePresenter {
  EglOpenGlPresenter(this.width, this.height);

  final int width;
  final int height;
  late final X11BenchmarkContext _x11;
  X11GlSurface? _surface;
  GlContext? _context;
  late _GlClearColorDart _clearColor;
  late _GlClearDart _clear;
  late _GlFinishDart _glFinish;
  String _device = 'unknown';
  String _mode = 'EGL window surface';

  @override
  String get name => 'EGL/OpenGL';
  @override
  String get device => _device;
  @override
  String get mode => _mode;

  Pointer<Void> _proc(GlContext context, String name) {
    final address = context.procAddress(name);
    if (address == nullptr) {
      throw StateError('OpenGL symbol unavailable: $name');
    }
    return address;
  }

  @override
  void initialize() {
    _x11 = X11BenchmarkContext.create(
      width: width,
      height: height,
      title: 'POC-22 EGL/OpenGL',
      createGraphicsContext: false,
    );
    final attempt = X11GlSurface.forWindow(
      _x11.window,
      windowVisualId: _x11.visual,
    );
    final surface = attempt.surface;
    if (surface == null) {
      throw StateError(attempt.diagnostics.join('; '));
    }
    _surface = surface;
    _context = surface.context;
    if (!surface.context.makeCurrent()) {
      throw StateError('EGL context could not become current');
    }
    _clearColor = _proc(surface.context, 'glClearColor')
        .cast<NativeFunction<_GlClearColorNative>>()
        .asFunction<_GlClearColorDart>();
    _clear = _proc(surface.context, 'glClear')
        .cast<NativeFunction<_GlClearNative>>()
        .asFunction<_GlClearDart>();
    _glFinish = _proc(surface.context, 'glFinish')
        .cast<NativeFunction<_GlFinishNative>>()
        .asFunction<_GlFinishDart>();
    final viewport = _proc(surface.context, 'glViewport')
        .cast<NativeFunction<_GlViewportNative>>()
        .asFunction<_GlViewportDart>();
    final getString = _proc(surface.context, 'glGetString')
        .cast<NativeFunction<_GlGetStringNative>>()
        .asFunction<_GlGetStringDart>();
    viewport(0, 0, width, height);
    final renderer = getString(_glRenderer);
    final version = getString(_glVersion);
    _device = renderer == nullptr
        ? 'unknown OpenGL renderer'
        : renderer.cast<Utf8>().toDartString();
    final versionText = version == nullptr
        ? 'unknown version'
        : version.cast<Utf8>().toDartString();
    final intervalDisabled = surface.setSwapInterval(0);
    final teardownMode = Platform.environment['POC22_EGL_TEARDOWN'];
    _mode = 'EGL window surface, swap interval '
        '${intervalDisabled ? '0' : 'driver default'}, $versionText'
        '${_device.startsWith('D3D12') ? ', WSLg teardown ${teardownMode == 'explicit' ? 'explicit' : 'deferred'}' : ''}';
  }

  @override
  void present(int frameNumber) {
    if ((frameNumber & 1) == 0) {
      _clearColor(0.88, 0.22, 0.12, 1);
    } else {
      _clearColor(0.18, 0.58, 0.84, 1);
    }
    _clear(_glColorBufferBit);
    if (!_surface!.swapBuffers()) {
      throw StateError('eglSwapBuffers failed');
    }
  }

  @override
  void finish() => _glFinish();

  @override
  void dispose() {
    final forceExplicitTeardown =
        Platform.environment['POC22_EGL_TEARDOWN'] == 'explicit';
    if (_device.startsWith('D3D12') && !forceExplicitTeardown) {
      // Mesa 24.0.9 crashed in this WSLg environment while reclaiming an EGL
      // window surface at process shutdown. Mesa 26.2 added deferred BO
      // reclamation and context-destroy bookkeeping, but the old run has no
      // backtrace that proves it is the same upstream bug. Keep the safe mode
      // as the default and expose an opt-in reproducer for newer Mesa builds.
      return;
    }
    _context?.dispose();
    _surface?.dispose();
    _surface = null;
    _context = null;
    _x11.dispose();
  }
}
