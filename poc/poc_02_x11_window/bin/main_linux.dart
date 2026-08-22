import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ============================================================================
// XCB Definitions & Bindings
// ============================================================================

const int _xcbCwBackPixel = 1 << 1;
const int _xcbCwEventMask = 1 << 11;
const int _xcbEventMaskExposure = 1 << 15;
const int _xcbEventMaskStructureNotify = 1 << 17;
const int _xcbEventMaskKeyPress = 1 << 0;
const int _xcbEventMaskKeyRelease = 1 << 1;
const int _xcbWindowClassInputOutput = 1;
const int _xcbExpose = 12;
const int _xcbKeyPress = 2;
const int _xcbClientMessage = 33;
const int _xcbPropModeReplace = 0;
const int _xcbAtomAtom = 4;

final class _XcbScreen extends Struct {
  @Uint32()
  external int root;
  @Uint32()
  external int defaultColormap;
  @Uint32()
  external int whitePixel;
  @Uint32()
  external int blackPixel;
  @Uint32()
  external int currentInputMasks;
  @Uint16()
  external int widthInPixels;
  @Uint16()
  external int heightInPixels;
  @Uint16()
  external int widthInMillimeters;
  @Uint16()
  external int heightInMillimeters;
  @Uint16()
  external int minInstalledMaps;
  @Uint16()
  external int maxInstalledMaps;
  @Uint32()
  external int rootVisual;
  @Uint8()
  external int backingStores;
  @Uint8()
  external int saveUnders;
  @Uint8()
  external int rootDepth;
  @Uint8()
  external int allowedDepthsLen;
}

final class _XcbScreenIterator extends Struct {
  external Pointer<_XcbScreen> data;
  @Int32()
  external int rem;
  @Int32()
  external int index;
}

final class _XcbInternAtomCookie extends Struct {
  @Uint32()
  external int sequence;
}

final class _XcbInternAtomReply extends Struct {
  @Uint8()
  external int responseType;
  @Uint8()
  external int pad0;
  @Uint16()
  external int sequence;
  @Uint32()
  external int length;
  @Uint32()
  external int atom;
  @Array(20)
  external Array<Uint8> pad;
}

final class _XcbClientMessageEvent extends Struct {
  @Uint8()
  external int responseType;
  @Uint8()
  external int format;
  @Uint16()
  external int sequence;
  @Uint32()
  external int window;
  @Uint32()
  external int type;
  @Array(5)
  external Array<Uint32> data32;
}

final class _XcbKeyPressEvent extends Struct {
  @Uint8()
  external int responseType;
  @Uint8()
  external int detail;
  @Uint16()
  external int sequence;
  @Uint32()
  external int time;
  @Uint32()
  external int root;
  @Uint32()
  external int event;
  @Uint32()
  external int child;
  @Int16()
  external int rootX;
  @Int16()
  external int rootY;
  @Int16()
  external int eventX;
  @Int16()
  external int eventY;
  @Uint16()
  external int state;
  @Uint8()
  external int sameScreen;
  @Uint8()
  external int pad0;
}

// ============================================================================
// EGL Definitions & Bindings
// ============================================================================

const int _eglNone = 0x3038;
const int _eglRedSize = 0x3024;
const int _eglGreenSize = 0x3023;
const int _eglBlueSize = 0x3022;
const int _eglAlphaSize = 0x3021;
const int _eglDepthSize = 0x3025;
const int _eglSurfaceType = 0x3033;
const int _eglRenderableType = 0x3040;
const int _eglWindowBit = 0x0004;
const int _eglOpenglBit = 0x0008;
const int _eglOpenglEs2Bit = 0x0004;
const int _eglContextClientVersion = 0x3098;
const int _eglOpenglApi = 0x30A2;
const int _eglOpenglEsApi = 0x30A0;

// ============================================================================
// OpenGL Constants
// ============================================================================

const int _glVendor = 0x1F00;
const int _glRenderer = 0x1F01;
const int _glVersion = 0x1F02;
const int _glShadingLanguageVersion = 0x8B8C;

const int _glColorBufferBit = 0x00004000;
const int _glDepthBufferBit = 0x00000100;
const int _glTriangles = 0x0004;
const int _glFloat = 0x1406;
const int _glFalse = 0;
const int _glArrayBuffer = 0x8892;
const int _glStaticDraw = 0x88E4;
const int _glVertexShader = 0x8B31;
const int _glFragmentShader = 0x8B30;
const int _glCompileStatus = 0x8B81;
const int _glLinkStatus = 0x8B82;

// ============================================================================
// Main Application
// ============================================================================

void main(List<String> args) {
  print('╔════════════════════════════════════════════════════════════════╗');
  print('║  POC-02: Native X11 / OpenGL Window Demo (Linux / WSL)         ║');
  print('║  Pure Dart FFI: XCB (Windowing) + EGL (Context) + OpenGL / ES  ║');
  print('╚════════════════════════════════════════════════════════════════╝\n');

  if (!Platform.isLinux) {
    print('❌ Error: This demo runs on Linux (for example under WSL).');
    exit(1);
  }

  // Mute Mesa X11 SHM attachment warnings on WSLg by default
  try {
    final libc = DynamicLibrary.process();
    final setenv = libc.lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv');
    final key = 'MESA_LOG_FILE'.toNativeUtf8();
    final val = '/dev/null'.toNativeUtf8();
    setenv(key, val, 0); // 0 = do not overwrite if user already configured
    calloc.free(key);
    calloc.free(val);
  } catch (_) {}

  // Parse CLI args
  int windowWidth = 640;
  int windowHeight = 480;
  int targetFrames =
      300; // ~5 seconds at 60fps (pass --frames 0 or --continuous for infinite)
  bool continuous = false;
  bool vsync = true;
  int frameDelayMilliseconds = 16;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--continuous' || arg == '-c') {
      continuous = true;
    } else if (arg == '--frames' && i + 1 < args.length) {
      targetFrames = int.tryParse(args[++i]) ?? targetFrames;
      if (targetFrames <= 0) continuous = true;
    } else if (arg == '--width' && i + 1 < args.length) {
      windowWidth = int.tryParse(args[++i]) ?? windowWidth;
    } else if (arg == '--height' && i + 1 < args.length) {
      windowHeight = int.tryParse(args[++i]) ?? windowHeight;
    } else if (arg == '--no-vsync') {
      vsync = false;
    } else if (arg == '--uncapped') {
      vsync = false;
      frameDelayMilliseconds = 0;
    } else if (arg == '--frame-delay' && i + 1 < args.length) {
      frameDelayMilliseconds = int.tryParse(args[++i]) ?? 16;
      if (frameDelayMilliseconds < 0) frameDelayMilliseconds = 0;
    } else if (arg == '--help' || arg == '-h') {
      print('Usage: dart run bin/main_linux.dart [options]');
      print('Options:');
      print(
          '  --frames <n>      Number of frames to render (default: 300, 0 = continuous)');
      print(
          '  --continuous, -c  Run continuously until closed or ESC is pressed');
      print('  --width <w>       Window width in pixels (default: 640)');
      print('  --height <h>      Window height in pixels (default: 480)');
      print('  --no-vsync        Request EGL swap interval 0');
      print('  --uncapped        Disable VSync and the 16 ms frame delay');
      print('  --frame-delay <n> Minimum frame interval in ms (default: 16)');
      exit(0);
    }
  }

  // 1. Open Native Libraries
  print(
      '🔹 Loading native libraries (libxcb.so.1, libEGL.so.1, libGL.so.1 / libGLESv2.so.2)...');
  final xcb = DynamicLibrary.open('libxcb.so.1');
  final egl = DynamicLibrary.open('libEGL.so.1');

  DynamicLibrary gl;
  try {
    gl = DynamicLibrary.open('libGL.so.1');
  } catch (_) {
    gl = DynamicLibrary.open('libGLESv2.so.2');
  }

  // Bind XCB functions
  final xcbConnect = xcb.lookupFunction<
      Pointer<Void> Function(Pointer<Int8>, Pointer<Int32>),
      Pointer<Void> Function(Pointer<Int8>, Pointer<Int32>)>('xcb_connect');
  final xcbConnectionHasError = xcb.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('xcb_connection_has_error');
  final xcbGetSetup = xcb.lookupFunction<Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)>('xcb_get_setup');
  final xcbRootsIterator = xcb.lookupFunction<
      _XcbScreenIterator Function(Pointer<Void>),
      _XcbScreenIterator Function(Pointer<Void>)>('xcb_setup_roots_iterator');
  final xcbGenerateId = xcb.lookupFunction<Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('xcb_generate_id');
  final xcbCreateWindow = xcb.lookupFunction<
      Void Function(Pointer<Void>, Uint8, Uint32, Uint32, Int16, Int16, Uint16,
          Uint16, Uint16, Uint16, Uint32, Uint32, Pointer<Uint32>),
      void Function(Pointer<Void>, int, int, int, int, int, int, int, int, int,
          int, int, Pointer<Uint32>)>('xcb_create_window');
  final xcbMapWindow = xcb.lookupFunction<Void Function(Pointer<Void>, Uint32),
      void Function(Pointer<Void>, int)>('xcb_map_window');
  final xcbInternAtom = xcb.lookupFunction<
      _XcbInternAtomCookie Function(
          Pointer<Void>, Uint8, Uint16, Pointer<Int8>),
      _XcbInternAtomCookie Function(
          Pointer<Void>, int, int, Pointer<Int8>)>('xcb_intern_atom');
  final xcbInternAtomReply = xcb.lookupFunction<
      Pointer<_XcbInternAtomReply> Function(
          Pointer<Void>, _XcbInternAtomCookie, Pointer<Pointer<Void>>),
      Pointer<_XcbInternAtomReply> Function(Pointer<Void>, _XcbInternAtomCookie,
          Pointer<Pointer<Void>>)>('xcb_intern_atom_reply');
  final xcbChangeProperty = xcb.lookupFunction<
      Void Function(Pointer<Void>, Uint8, Uint32, Uint32, Uint32, Uint8, Uint32,
          Pointer<Void>),
      void Function(Pointer<Void>, int, int, int, int, int, int,
          Pointer<Void>)>('xcb_change_property');
  final xcbPollForEvent = xcb.lookupFunction<
      Pointer<Uint8> Function(Pointer<Void>),
      Pointer<Uint8> Function(Pointer<Void>)>('xcb_poll_for_event');
  final xcbFlush = xcb.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('xcb_flush');
  final xcbDestroyWindow = xcb.lookupFunction<
      Void Function(Pointer<Void>, Uint32),
      void Function(Pointer<Void>, int)>('xcb_destroy_window');
  final xcbDisconnect = xcb.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('xcb_disconnect');

  // Bind EGL functions
  final eglGetDisplay = egl.lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)>('eglGetDisplay');
  final eglInitialize = egl.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>),
      int Function(
          Pointer<Void>, Pointer<Int32>, Pointer<Int32>)>('eglInitialize');
  final eglBindApi = egl
      .lookupFunction<Int32 Function(Uint32), int Function(int)>('eglBindAPI');
  final eglChooseConfig = egl.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>,
          Int32, Pointer<Int32>),
      int Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, int,
          Pointer<Int32>)>('eglChooseConfig');
  final eglCreateWindowSurface = egl.lookupFunction<
      Pointer<Void> Function(
          Pointer<Void>, Pointer<Void>, IntPtr, Pointer<Int32>),
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int,
          Pointer<Int32>)>('eglCreateWindowSurface');
  final eglCreateContext = egl.lookupFunction<
      Pointer<Void> Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>),
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
          Pointer<Int32>)>('eglCreateContext');
  final eglMakeCurrent = egl.lookupFunction<
      Int32 Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
          Pointer<Void>)>('eglMakeCurrent');
  final eglSwapBuffers = egl.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)>('eglSwapBuffers');
  final eglSwapInterval = egl.lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)>('eglSwapInterval');
  final eglGetProcAddress = egl.lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)>('eglGetProcAddress');
  final eglDestroySurface = egl.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)>('eglDestroySurface');
  final eglDestroyContext = egl.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)>('eglDestroyContext');
  final eglTerminate = egl.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('eglTerminate');

  // Helper for resolving GL function pointers (via libGL or eglGetProcAddress)
  Pointer<Void> resolveGlSymbol(String name) {
    try {
      return gl.lookup<Void>(name);
    } catch (_) {
      final nameUtf8 = name.toNativeUtf8();
      try {
        final addr = eglGetProcAddress(nameUtf8);
        if (addr != nullptr) return addr;
      } finally {
        calloc.free(nameUtf8);
      }
      throw StateError('Could not resolve OpenGL symbol: $name');
    }
  }

  // 2. Connect to X11 Server (WSLg)
  final screenNumber = calloc<Int32>();
  final connection = xcbConnect(nullptr, screenNumber);
  calloc.free(screenNumber);

  if (connection == nullptr || xcbConnectionHasError(connection) != 0) {
    print(
        '❌ Error: Could not connect to X11 server. Ensure WSLg is active or DISPLAY is set.');
    exit(1);
  }

  final setup = xcbGetSetup(connection);
  final screen = xcbRootsIterator(setup).data.ref;
  final xcbConfigureWindow = xcb.lookupFunction<
      Void Function(Pointer<Void>, Uint32, Uint16, Pointer<Uint32>),
      void Function(
          Pointer<Void>, int, int, Pointer<Uint32>)>('xcb_configure_window');
  final rootWindow = screen.root;
  final rootVisual = screen.rootVisual;
  final rootDepth = screen.rootDepth;

  print(
      '✅ X11 Connected: Root 0x${rootWindow.toRadixString(16)}, Visual 0x${rootVisual.toRadixString(16)}, Depth $rootDepth-bit');

  // 3. Create X11 Window
  final windowId = xcbGenerateId(connection);
  const valueMask = _xcbCwBackPixel | _xcbCwEventMask;
  final valueList = calloc<Uint32>(2);
  valueList[0] = screen.blackPixel;
  valueList[1] = _xcbEventMaskExposure |
      _xcbEventMaskStructureNotify |
      _xcbEventMaskKeyPress |
      _xcbEventMaskKeyRelease;

  xcbCreateWindow(
    connection,
    rootDepth,
    windowId,
    rootWindow,
    100, // X
    100, // Y
    windowWidth,
    windowHeight,
    0, // border
    _xcbWindowClassInputOutput,
    rootVisual,
    valueMask,
    valueList,
  );
  calloc.free(valueList);

  // Set Window Title via _NET_WM_NAME and WM_NAME
  void setWindowTitle(String title) {
    final titleUtf8 = title.toNativeUtf8();
    final netWmName = 'UTF8_STRING'.toNativeUtf8();
    final wmName = 'WM_NAME'.toNativeUtf8();
    try {
      final replyUtf8 = xcbInternAtomReply(
          connection,
          xcbInternAtom(connection, 0, netWmName.length, netWmName.cast()),
          nullptr);
      final replyWm = xcbInternAtomReply(connection,
          xcbInternAtom(connection, 0, wmName.length, wmName.cast()), nullptr);
      final utf8Atom = replyUtf8 != nullptr ? replyUtf8.ref.atom : 0;
      final wmAtom = replyWm != nullptr ? replyWm.ref.atom : 0;
      if (replyUtf8 != nullptr) calloc.free(replyUtf8);
      if (replyWm != nullptr) calloc.free(replyWm);

      if (wmAtom != 0) {
        xcbChangeProperty(connection, _xcbPropModeReplace, windowId, wmAtom,
            31 /* STRING */, 8, titleUtf8.length, titleUtf8.cast());
      }
      if (utf8Atom != 0) {
        final netNameAtom = '_NET_WM_NAME'.toNativeUtf8();
        final replyNet = xcbInternAtomReply(
            connection,
            xcbInternAtom(
                connection, 0, netNameAtom.length, netNameAtom.cast()),
            nullptr);
        if (replyNet != nullptr) {
          xcbChangeProperty(
              connection,
              _xcbPropModeReplace,
              windowId,
              replyNet.ref.atom,
              utf8Atom,
              8,
              titleUtf8.length,
              titleUtf8.cast());
          calloc.free(replyNet);
        }
        calloc.free(netNameAtom);
      }
    } finally {
      calloc.free(titleUtf8);
      calloc.free(netWmName);
      calloc.free(wmName);
    }
  }

  setWindowTitle('POC-02: Dart OpenGL Window (Linux / WSL)');

  // Configure WM_HINTS (NormalState / Visible)
  final wmHintsStr = 'WM_HINTS'.toNativeUtf8();
  final replyHints = xcbInternAtomReply(
      connection,
      xcbInternAtom(connection, 0, wmHintsStr.length, wmHintsStr.cast()),
      nullptr);
  final wmHintsAtom = replyHints != nullptr ? replyHints.ref.atom : 35;
  if (replyHints != nullptr) calloc.free(replyHints);
  calloc.free(wmHintsStr);

  if (wmHintsAtom != 0) {
    final hints = calloc<Uint32>(9);
    hints[0] = (1 << 0) | (1 << 1); // InputHint | StateHint
    hints[1] = 1; // Input = True
    hints[2] = 1; // NormalState
    xcbChangeProperty(connection, _xcbPropModeReplace, windowId, wmHintsAtom,
        wmHintsAtom, 32, 9, hints.cast());
    calloc.free(hints);
  }

  // Configure WM_PROTOCOLS / WM_DELETE_WINDOW
  final wmProtocolsStr = 'WM_PROTOCOLS'.toNativeUtf8();
  final wmDeleteWinStr = 'WM_DELETE_WINDOW'.toNativeUtf8();
  final replyProtocols = xcbInternAtomReply(
      connection,
      xcbInternAtom(
          connection, 0, wmProtocolsStr.length, wmProtocolsStr.cast()),
      nullptr);
  final replyDelete = xcbInternAtomReply(
      connection,
      xcbInternAtom(
          connection, 0, wmDeleteWinStr.length, wmDeleteWinStr.cast()),
      nullptr);
  final wmProtocols = replyProtocols != nullptr ? replyProtocols.ref.atom : 0;
  final wmDeleteWindow = replyDelete != nullptr ? replyDelete.ref.atom : 0;
  if (replyProtocols != nullptr) calloc.free(replyProtocols);
  if (replyDelete != nullptr) calloc.free(replyDelete);
  calloc.free(wmProtocolsStr);
  calloc.free(wmDeleteWinStr);

  if (wmProtocols != 0 && wmDeleteWindow != 0) {
    final atomPtr = calloc<Uint32>()..value = wmDeleteWindow;
    xcbChangeProperty(connection, _xcbPropModeReplace, windowId, wmProtocols,
        _xcbAtomAtom, 32, 1, atomPtr.cast());
    calloc.free(atomPtr);
  }

  // Map window & bring to front (StackModeAbove)
  xcbMapWindow(connection, windowId);
  final stackMode = calloc<Uint32>(1)..value = 0 /* XCB_STACK_MODE_ABOVE */;
  xcbConfigureWindow(connection, windowId,
      1 << 6 /* XCB_CONFIG_WINDOW_STACK_MODE */, stackMode);
  calloc.free(stackMode);
  xcbFlush(connection);
  print(
      '✅ X11 Window created and mapped: ID 0x${windowId.toRadixString(16)} (${windowWidth}x$windowHeight)');

  // 4. Initialize EGL
  final eglDisplay = eglGetDisplay(nullptr);
  if (eglDisplay == nullptr || eglDisplay.address == 0) {
    print('❌ Error: eglGetDisplay failed.');
    exit(1);
  }

  final major = calloc<Int32>();
  final minor = calloc<Int32>();
  if (eglInitialize(eglDisplay, major, minor) == 0) {
    print('❌ Error: eglInitialize failed.');
    exit(1);
  }
  print('✅ EGL Initialized: Version ${major.value}.${minor.value}');
  calloc.free(major);
  calloc.free(minor);

  // Bind OpenGL API (Try Desktop OpenGL, fallback to OpenGL ES)
  var isGles = false;
  if (eglBindApi(_eglOpenglApi) == 0) {
    print('ℹ️ Desktop OpenGL API not available, binding OpenGL ES API...');
    if (eglBindApi(_eglOpenglEsApi) == 0) {
      print(
          '❌ Error: eglBindAPI failed for both Desktop OpenGL and OpenGL ES.');
      exit(1);
    }
    isGles = true;
  }

  // Choose Config for Window Surface
  final attribList = calloc<Int32>(15);
  attribList[0] = _eglSurfaceType;
  attribList[1] = _eglWindowBit;
  attribList[2] = _eglRedSize;
  attribList[3] = 8;
  attribList[4] = _eglGreenSize;
  attribList[5] = 8;
  attribList[6] = _eglBlueSize;
  attribList[7] = 8;
  attribList[8] = _eglAlphaSize;
  attribList[9] = 8;
  attribList[10] = _eglDepthSize;
  attribList[11] = 24;
  attribList[12] = _eglRenderableType;
  attribList[13] = isGles ? _eglOpenglEs2Bit : _eglOpenglBit;
  attribList[14] = _eglNone;

  final configs = calloc<Pointer<Void>>(1);
  final numConfig = calloc<Int32>();
  if (eglChooseConfig(eglDisplay, attribList, configs, 1, numConfig) == 0 ||
      numConfig.value == 0) {
    print('❌ Error: eglChooseConfig failed to find a matching window config.');
    exit(1);
  }
  final eglConfig = configs[0];
  calloc.free(attribList);
  calloc.free(configs);
  calloc.free(numConfig);
  print('✅ EGL Config chosen.');

  // Create Window Surface
  final eglSurface =
      eglCreateWindowSurface(eglDisplay, eglConfig, windowId, nullptr);
  if (eglSurface == nullptr || eglSurface.address == 0) {
    print('❌ Error: eglCreateWindowSurface failed.');
    exit(1);
  }
  print('✅ EGL Window Surface created.');

  // Create Context
  final ctxAttribs = calloc<Int32>(5);
  ctxAttribs[0] = _eglContextClientVersion;
  ctxAttribs[1] = isGles ? 2 : 3;
  ctxAttribs[2] = _eglNone;

  var eglContext = eglCreateContext(eglDisplay, eglConfig, nullptr, ctxAttribs);
  if (eglContext == nullptr || eglContext.address == 0) {
    // Retry without version attributes
    ctxAttribs[0] = _eglNone;
    eglContext = eglCreateContext(eglDisplay, eglConfig, nullptr, ctxAttribs);
  }
  calloc.free(ctxAttribs);

  if (eglContext == nullptr || eglContext.address == 0) {
    print('❌ Error: eglCreateContext failed.');
    exit(1);
  }
  print('✅ EGL Context created.');

  // Make Context Current
  if (eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext) == 0) {
    print('❌ Error: eglMakeCurrent failed.');
    exit(1);
  }
  print('✅ EGL Context is now current.');

  final requestedSwapInterval = vsync ? 1 : 0;
  final swapIntervalAccepted =
      eglSwapInterval(eglDisplay, requestedSwapInterval) != 0;
  print('EGL swap interval: $requestedSwapInterval '
      '(${swapIntervalAccepted ? 'accepted' : 'rejected'})');

  // 5. Query OpenGL Information
  final glGetString = resolveGlSymbol('glGetString')
      .cast<NativeFunction<Pointer<Uint8> Function(Uint32)>>()
      .asFunction<Pointer<Uint8> Function(int)>();
  final glViewport = resolveGlSymbol('glViewport')
      .cast<NativeFunction<Void Function(Int32, Int32, Int32, Int32)>>()
      .asFunction<void Function(int, int, int, int)>();
  final glClearColor = resolveGlSymbol('glClearColor')
      .cast<NativeFunction<Void Function(Float, Float, Float, Float)>>()
      .asFunction<void Function(double, double, double, double)>();
  final glClear = resolveGlSymbol('glClear')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();
  final glDisable = resolveGlSymbol('glDisable')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  // Ensure depth test and face culling do not cull the 2D triangle
  glDisable(0x0B71 /* GL_DEPTH_TEST */);
  glDisable(0x0B44 /* GL_CULL_FACE */);

  String getGlStringSafe(int name) {
    final ptr = glGetString(name);
    return ptr == nullptr ? 'unknown' : ptr.cast<Utf8>().toDartString();
  }

  print('\n═════════════════ OpenGL Driver Details ═════════════════');
  print(' Vendor:       ${getGlStringSafe(_glVendor)}');
  print(' Renderer:     ${getGlStringSafe(_glRenderer)}');
  print(' Version:      ${getGlStringSafe(_glVersion)}');
  print(' GLSL Version: ${getGlStringSafe(_glShadingLanguageVersion)}');
  print('═════════════════════════════════════════════════════════\n');

  // 6. Set up Shader Program & Animated Rotating Rainbow Triangle
  final glCreateShader = resolveGlSymbol('glCreateShader')
      .cast<NativeFunction<Uint32 Function(Uint32)>>()
      .asFunction<int Function(int)>();
  final glShaderSource = resolveGlSymbol('glShaderSource')
      .cast<
          NativeFunction<
              Void Function(
                  Uint32, Int32, Pointer<Pointer<Utf8>>, Pointer<Int32>)>>()
      .asFunction<
          void Function(int, int, Pointer<Pointer<Utf8>>, Pointer<Int32>)>();
  final glCompileShader = resolveGlSymbol('glCompileShader')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();
  final glGetShaderiv = resolveGlSymbol('glGetShaderiv')
      .cast<NativeFunction<Void Function(Uint32, Uint32, Pointer<Int32>)>>()
      .asFunction<void Function(int, int, Pointer<Int32>)>();
  final glGetShaderInfoLog = resolveGlSymbol('glGetShaderInfoLog')
      .cast<
          NativeFunction<
              Void Function(Uint32, Int32, Pointer<Int32>, Pointer<Utf8>)>>()
      .asFunction<void Function(int, int, Pointer<Int32>, Pointer<Utf8>)>();
  final glCreateProgram = resolveGlSymbol('glCreateProgram')
      .cast<NativeFunction<Uint32 Function()>>()
      .asFunction<int Function()>();
  final glAttachShader = resolveGlSymbol('glAttachShader')
      .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
      .asFunction<void Function(int, int)>();
  final glLinkProgram = resolveGlSymbol('glLinkProgram')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();
  final glGetProgramiv = resolveGlSymbol('glGetProgramiv')
      .cast<NativeFunction<Void Function(Uint32, Uint32, Pointer<Int32>)>>()
      .asFunction<void Function(int, int, Pointer<Int32>)>();
  final glGetProgramInfoLog = resolveGlSymbol('glGetProgramInfoLog')
      .cast<
          NativeFunction<
              Void Function(Uint32, Int32, Pointer<Int32>, Pointer<Utf8>)>>()
      .asFunction<void Function(int, int, Pointer<Int32>, Pointer<Utf8>)>();
  final glUseProgram = resolveGlSymbol('glUseProgram')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();
  final glDeleteShader = resolveGlSymbol('glDeleteShader')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();
  final glDeleteProgram = resolveGlSymbol('glDeleteProgram')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();
  final glGetAttribLocation = resolveGlSymbol('glGetAttribLocation')
      .cast<NativeFunction<Int32 Function(Uint32, Pointer<Utf8>)>>()
      .asFunction<int Function(int, Pointer<Utf8>)>();
  final glGetUniformLocation = resolveGlSymbol('glGetUniformLocation')
      .cast<NativeFunction<Int32 Function(Uint32, Pointer<Utf8>)>>()
      .asFunction<int Function(int, Pointer<Utf8>)>();
  final glUniform1f = resolveGlSymbol('glUniform1f')
      .cast<NativeFunction<Void Function(Int32, Float)>>()
      .asFunction<void Function(int, double)>();
  final glGenBuffers = resolveGlSymbol('glGenBuffers')
      .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
      .asFunction<void Function(int, Pointer<Uint32>)>();
  final glBindBuffer = resolveGlSymbol('glBindBuffer')
      .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
      .asFunction<void Function(int, int)>();
  final glBufferData = resolveGlSymbol('glBufferData')
      .cast<
          NativeFunction<
              Void Function(Uint32, IntPtr, Pointer<Void>, Uint32)>>()
      .asFunction<void Function(int, int, Pointer<Void>, int)>();
  final glEnableVertexAttribArray = resolveGlSymbol('glEnableVertexAttribArray')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();
  final glVertexAttribPointer = resolveGlSymbol('glVertexAttribPointer')
      .cast<
          NativeFunction<
              Void Function(
                  Uint32, Int32, Uint32, Uint8, Int32, Pointer<Void>)>>()
      .asFunction<void Function(int, int, int, int, int, Pointer<Void>)>();
  final glDrawArrays = resolveGlSymbol('glDrawArrays')
      .cast<NativeFunction<Void Function(Uint32, Int32, Int32)>>()
      .asFunction<void Function(int, int, int)>();
  final glDeleteBuffers = resolveGlSymbol('glDeleteBuffers')
      .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
      .asFunction<void Function(int, Pointer<Uint32>)>();

  // Optional VAO functions (if available)
  void Function(int, Pointer<Uint32>)? glGenVertexArrays;
  void Function(int)? glBindVertexArray;
  void Function(int, Pointer<Uint32>)? glDeleteVertexArrays;
  try {
    glGenVertexArrays = resolveGlSymbol('glGenVertexArrays')
        .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
        .asFunction<void Function(int, Pointer<Uint32>)>();
    glBindVertexArray = resolveGlSymbol('glBindVertexArray')
        .cast<NativeFunction<Void Function(Uint32)>>()
        .asFunction<void Function(int)>();
    glDeleteVertexArrays = resolveGlSymbol('glDeleteVertexArrays')
        .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
        .asFunction<void Function(int, Pointer<Uint32>)>();
  } catch (_) {}

  // Compile Shaders
  int compileShader(int type, String source) {
    final shader = glCreateShader(type);
    final srcUtf8 = source.toNativeUtf8();
    final ppSrc = calloc<Pointer<Utf8>>(1)..value = srcUtf8;
    try {
      glShaderSource(shader, 1, ppSrc, nullptr);
      glCompileShader(shader);
      final status = calloc<Int32>();
      glGetShaderiv(shader, _glCompileStatus, status);
      if (status.value == 0) {
        final logBuf = calloc<Uint8>(1024);
        glGetShaderInfoLog(shader, 1024, nullptr, logBuf.cast());
        final logMsg = logBuf.cast<Utf8>().toDartString();
        calloc.free(logBuf);
        calloc.free(status);
        throw StateError('Shader compilation failed: $logMsg');
      }
      calloc.free(status);
      return shader;
    } finally {
      calloc.free(ppSrc);
      calloc.free(srcUtf8);
    }
  }

  final vertexShaderSrc = isGles
      ? '''#version 100
attribute vec2 aPosition;
attribute vec3 aColor;
uniform float uAngle;
varying vec3 vColor;

void main() {
    float s = sin(uAngle);
    float c = cos(uAngle);
    mat2 rot = mat2(c, -s, s, c);
    vec2 pos = rot * aPosition;
    gl_Position = vec4(pos, 0.0, 1.0);
    vColor = aColor;
}
'''
      : '''#version 120
attribute vec2 aPosition;
attribute vec3 aColor;
uniform float uAngle;
varying vec3 vColor;

void main() {
    float s = sin(uAngle);
    float c = cos(uAngle);
    mat2 rot = mat2(c, -s, s, c);
    vec2 pos = rot * aPosition;
    gl_Position = vec4(pos, 0.0, 1.0);
    vColor = aColor;
}
''';

  final fragmentShaderSrc = isGles
      ? '''#version 100
precision mediump float;
varying vec3 vColor;

void main() {
    gl_FragColor = vec4(vColor, 1.0);
}
'''
      : '''#version 120
varying vec3 vColor;

void main() {
    gl_FragColor = vec4(vColor, 1.0);
}
''';

  final vertShader = compileShader(_glVertexShader, vertexShaderSrc);
  final fragShader = compileShader(_glFragmentShader, fragmentShaderSrc);

  final program = glCreateProgram();
  glAttachShader(program, vertShader);
  glAttachShader(program, fragShader);
  glLinkProgram(program);

  final linkStatus = calloc<Int32>();
  glGetProgramiv(program, _glLinkStatus, linkStatus);
  if (linkStatus.value == 0) {
    final logBuf = calloc<Uint8>(1024);
    glGetProgramInfoLog(program, 1024, nullptr, logBuf.cast());
    final logMsg = logBuf.cast<Utf8>().toDartString();
    calloc.free(logBuf);
    calloc.free(linkStatus);
    throw StateError('Program link failed: $logMsg');
  }
  calloc.free(linkStatus);
  glDeleteShader(vertShader);
  glDeleteShader(fragShader);
  print('✅ OpenGL Shaders compiled & linked successfully.');

  // Vertex Data: Position (vec2) + Color (vec3)
  // Triangle vertices:
  // Top:    ( 0.0,  0.6), Red:   (1.0, 0.2, 0.2)
  // Right:  ( 0.6, -0.5), Green: (0.2, 1.0, 0.2)
  // Left:   (-0.6, -0.5), Blue:  (0.2, 0.4, 1.0)
  final vertexData = Float32List.fromList([
    // X,     Y,       R,   G,   B
    0.0, 0.65, 1.0, 0.15, 0.2, // Top (Crimson)
    0.6, -0.55, 0.2, 0.95, 0.3, // Bottom-Right (Emerald)
    -0.6, -0.55, 0.1, 0.55, 1.0, // Bottom-Left (Cyan-Blue)
  ]);

  final vboPtr = calloc<Uint32>();
  glGenBuffers(1, vboPtr);
  final vbo = vboPtr.value;
  glBindBuffer(_glArrayBuffer, vbo);

  final pNativeData = calloc<Float>(vertexData.length);
  for (var i = 0; i < vertexData.length; i++) {
    pNativeData[i] = vertexData[i];
  }
  glBufferData(
      _glArrayBuffer, vertexData.length * 4, pNativeData.cast(), _glStaticDraw);
  calloc.free(pNativeData);

  final vaoPtr = calloc<Uint32>();
  if (glGenVertexArrays != null && glBindVertexArray != null) {
    glGenVertexArrays(1, vaoPtr);
    glBindVertexArray(vaoPtr.value);
    glBindBuffer(_glArrayBuffer, vbo);
  }

  // Bind attribute locations
  final posName = 'aPosition'.toNativeUtf8();
  final colName = 'aColor'.toNativeUtf8();
  final angleName = 'uAngle'.toNativeUtf8();
  final aPosition = glGetAttribLocation(program, posName);
  final aColor = glGetAttribLocation(program, colName);
  final uAngle = glGetUniformLocation(program, angleName);
  calloc.free(posName);
  calloc.free(colName);
  calloc.free(angleName);

  const stride = 5 * 4; // 5 floats * 4 bytes = 20 bytes
  if (aPosition >= 0) {
    glEnableVertexAttribArray(aPosition);
    glVertexAttribPointer(aPosition, 2, _glFloat, _glFalse, stride, nullptr);
  }
  if (aColor >= 0) {
    glEnableVertexAttribArray(aColor);
    glVertexAttribPointer(aColor, 3, _glFloat, _glFalse, stride,
        Pointer<Void>.fromAddress(2 * 4));
  }

  // 7. Render Loop
  print('\n🚀 Starting OpenGL Animation Loop on Linux/X11...');
  print('👉 Controls: Press ESC / Q in the window or close it to exit.');
  if (!continuous) {
    print('👉 Rendering $targetFrames frames (or run with --continuous)...\n');
  }

  glViewport(0, 0, windowWidth, windowHeight);
  glUseProgram(program);

  var frameCount = 0;
  var running = true;
  final stopwatch = Stopwatch()..start();
  final fpsTimer = Stopwatch()..start();
  var lastFpsReport = 0;
  var swapWaitMicroseconds = 0;

  while (running) {
    final frameStartMicroseconds = stopwatch.elapsedMicroseconds;
    // Handle X11 events
    while (true) {
      final event = xcbPollForEvent(connection);
      if (event == nullptr) break;

      final responseType = event.value & 0x7F;
      if (responseType == _xcbClientMessage) {
        final clientMsg = event.cast<_XcbClientMessageEvent>().ref;
        if (clientMsg.type == wmProtocols &&
            clientMsg.data32[0] == wmDeleteWindow) {
          print('🚪 Window close requested (WM_DELETE_WINDOW).');
          running = false;
        }
      } else if (responseType == _xcbKeyPress) {
        final keyEvent = event.cast<_XcbKeyPressEvent>().ref;
        // Keycodes: 9 = Escape, 24 = 'q' / 'Q' on standard X11 keymaps
        if (keyEvent.detail == 9 || keyEvent.detail == 24) {
          print('🚪 Exit requested by keypress (keycode ${keyEvent.detail}).');
          running = false;
        }
      } else if (responseType == _xcbExpose) {
        // Redraw on expose
      }
      calloc.free(event);
    }

    if (!running) break;

    final elapsedSeconds = stopwatch.elapsedMicroseconds / 1000000.0;
    final angle = elapsedSeconds * 2.0; // 2 rad/s rotation

    // Dynamic background pulsing
    final bgR = 0.08 + 0.05 * math.sin(elapsedSeconds * 1.5);
    final bgG = 0.08 + 0.05 * math.sin(elapsedSeconds * 1.5 + 2.0);
    final bgB = 0.12 + 0.08 * math.sin(elapsedSeconds * 1.5 + 4.0);

    glClearColor(bgR, bgG, bgB, 1.0);
    glClear(_glColorBufferBit | _glDepthBufferBit);

    // Update uniform rotation
    if (uAngle >= 0) {
      glUniform1f(uAngle, angle);
    }

    // Draw Triangle
    glDrawArrays(_glTriangles, 0, 3);
    // Swap EGL buffers
    final swapStart = Stopwatch()..start();
    if (eglSwapBuffers(eglDisplay, eglSurface) == 0) {
      print('⚠️ eglSwapBuffers returned 0; surface might be invalidated.');
      break;
    }
    swapWaitMicroseconds += swapStart.elapsedMicroseconds;

    if (frameDelayMilliseconds > 0) {
      final targetFrameMicroseconds = frameDelayMilliseconds * 1000;
      final frameWorkMicroseconds =
          stopwatch.elapsedMicroseconds - frameStartMicroseconds;
      final remainingMicroseconds =
          targetFrameMicroseconds - frameWorkMicroseconds;
      if (remainingMicroseconds > 0) {
        sleep(Duration(microseconds: remainingMicroseconds));
      }
    }

    frameCount++;

    // FPS reporting every second
    if (fpsTimer.elapsedMilliseconds - lastFpsReport >= 1000) {
      final fps = (frameCount * 1000.0) / fpsTimer.elapsedMilliseconds;
      final averageSwapMs =
          frameCount == 0 ? 0.0 : swapWaitMicroseconds / frameCount / 1000.0;
      stdout.write('\r✨ Frame $frameCount | FPS: ${fps.toStringAsFixed(1)} | '
          'Swap: ${averageSwapMs.toStringAsFixed(1)} ms | '
          'Time: ${elapsedSeconds.toStringAsFixed(1)}s  ');
      lastFpsReport = fpsTimer.elapsedMilliseconds;
    }

    if (!continuous && frameCount >= targetFrames) {
      print('\n🎯 Target frame count ($targetFrames) reached.');
      break;
    }
  }

  // 8. Cleanup & Teardown
  print('\n🧹 Cleaning up OpenGL and X11 resources...');
  glUseProgram(0);
  glDeleteProgram(program);
  glDeleteBuffers(1, vboPtr);
  if (glDeleteVertexArrays != null && vaoPtr.value != 0) {
    glDeleteVertexArrays(1, vaoPtr);
  }
  calloc.free(vboPtr);
  calloc.free(vaoPtr);

  eglMakeCurrent(eglDisplay, nullptr, nullptr, nullptr);
  eglDestroySurface(eglDisplay, eglSurface);
  eglDestroyContext(eglDisplay, eglContext);
  eglTerminate(eglDisplay);

  xcbDestroyWindow(connection, windowId);
  xcbDisconnect(connection);

  final totalDuration = stopwatch.elapsedMilliseconds / 1000.0;
  final avgFps =
      totalDuration > 0 ? (frameCount / totalDuration).toStringAsFixed(1) : '0';
  print(
      '🏁 Demo finished successfully: $frameCount frames rendered in ${totalDuration.toStringAsFixed(2)}s (Average $avgFps FPS).');
  exit(0);
}
