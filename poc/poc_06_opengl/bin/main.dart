import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:poc_06_opengl/egl_bindings.dart';
import 'package:poc_06_opengl/gl_bindings.dart';

void main(List<String> args) {
  print('╔══════════════════════════════════════════════════╗');
  print('║  POC-06: OpenGL Context via FFI (Linux)         ║');
  print('║  No C/C++ wrapper, no Flutter, just dart:ffi    ║');
  print('╚══════════════════════════════════════════════════╝\n');

  if (!Platform.isLinux) {
    print('Error: POC-06 only works on Linux.');
    exit(1);
  }

  // Get display
  final display = eglGetDisplay(nullptr);
  if (display.address == 0) {
    print('Error: eglGetDisplay failed.');
    exit(1);
  }

  // Initialize EGL
  final major = calloc<Int32>();
  final minor = calloc<Int32>();
  if (eglInitialize(display, major, minor) == 0) {
    print('Error: eglInitialize failed.');
    exit(1);
  }
  print('EGL Initialized. Version: \${major.value}.\${minor.value}');

  // Choose config
  final attribList = calloc<Int32>(15);
  attribList[0] = eglSurfaceType;
  attribList[1] = eglPbufferBit;
  attribList[2] = eglBlueSize;
  attribList[3] = 8;
  attribList[4] = eglGreenSize;
  attribList[5] = 8;
  attribList[6] = eglRedSize;
  attribList[7] = 8;
  attribList[8] = eglDepthSize;
  attribList[9] = 24;
  attribList[10] = eglRenderableType;
  attribList[11] = eglOpenGLES2Bit;
  attribList[12] = eglNone;

  final config = calloc<EglConfig>();
  final numConfig = calloc<Int32>();

  if (eglChooseConfig(display, attribList, config, 1, numConfig) == 0 ||
      numConfig.value == 0) {
    print('Error: eglChooseConfig failed.');
    exit(1);
  }
  print('EGL Config chosen (Count: \${numConfig.value})');

  // Create Pbuffer surface
  final pbufferAttribs = calloc<Int32>(5);
  pbufferAttribs[0] = eglWidth;
  pbufferAttribs[1] = 800;
  pbufferAttribs[2] = eglHeight;
  pbufferAttribs[3] = 600;
  pbufferAttribs[4] = eglNone;

  final surface =
      eglCreatePbufferSurface(display, config.value, pbufferAttribs);
  if (surface.address == 0) {
    print('Error: eglCreatePbufferSurface failed.');
    exit(1);
  }
  print('EGL Pbuffer Surface created (800x600).');

  // Create Context
  final contextAttribs = calloc<Int32>(3);
  contextAttribs[0] = eglContextClientVersion;
  contextAttribs[1] = 2; // GLES 2
  contextAttribs[2] = eglNone;

  final context =
      eglCreateContext(display, config.value, nullptr, contextAttribs);
  if (context.address == 0) {
    print('Error: eglCreateContext failed.');
    exit(1);
  }
  print('EGL Context created.');

  // Make current
  if (eglMakeCurrent(display, surface, surface, context) == 0) {
    print('Error: eglMakeCurrent failed.');
    exit(1);
  }
  print('EGL Context is now current.');

  // OpenGL calls
  glViewport(0, 0, 800, 600);
  glClearColor(0.2, 0.3, 0.3, 1.0);
  glClear(glColorBufferBit);

  final glVer = glGetString(glVersion);
  if (glVer.address != 0) {
    print('OpenGL Version: \${glVer.cast<Utf8>().toDartString()}');
  }

  final glRend = glGetString(glRenderer);
  if (glRend.address != 0) {
    print('OpenGL Renderer: \${glRend.cast<Utf8>().toDartString()}');
  }

  // Swap buffers
  if (eglSwapBuffers(display, surface) == 0) {
    print('Warning: eglSwapBuffers failed.');
  } else {
    print('eglSwapBuffers succeeded.');
  }

  // Teardown
  print('Tearing down EGL resources...');
  eglMakeCurrent(display, nullptr, nullptr, nullptr);
  eglDestroySurface(display, surface);
  eglDestroyContext(display, context);
  eglTerminate(display);

  calloc.free(major);
  calloc.free(minor);
  calloc.free(attribList);
  calloc.free(config);
  calloc.free(numConfig);
  calloc.free(pbufferAttribs);
  calloc.free(contextAttribs);

  print('POC-06 completed successfully.');
  exit(0);
}
