import 'dart:ffi';

final DynamicLibrary libEGL = DynamicLibrary.open('libEGL.so.1');

// EGL types
typedef EglDisplay = Pointer<Void>;
typedef EglConfig = Pointer<Void>;
typedef EglContext = Pointer<Void>;
typedef EglSurface = Pointer<Void>;
typedef EglNativeDisplayType = Pointer<Void>;

// EGL constants
const int eglSuccess = 0x3000;
const int eglNone = 0x3038;
const int eglRedSize = 0x3024;
const int eglGreenSize = 0x3023;
const int eglBlueSize = 0x3022;
const int eglAlphaSize = 0x3021;
const int eglDepthSize = 0x3025;
const int eglSurfaceType = 0x3033;
const int eglRenderableType = 0x3040;
const int eglOpenGLES3Bit = 0x00000040;
const int eglOpenGLES2Bit = 0x00000004;
const int eglPbufferBit = 0x0001;
const int eglContextClientVersion = 0x3098;
const int eglWidth = 0x3057;
const int eglHeight = 0x3056;

// eglGetDisplay
typedef EglGetDisplayNative = EglDisplay Function(
    EglNativeDisplayType displayId);
typedef EglGetDisplayDart = EglDisplay Function(EglNativeDisplayType displayId);
final eglGetDisplay = libEGL
    .lookupFunction<EglGetDisplayNative, EglGetDisplayDart>('eglGetDisplay');

// eglInitialize
typedef EglInitializeNative = Int32 Function(
    EglDisplay dpy, Pointer<Int32> major, Pointer<Int32> minor);
typedef EglInitializeDart = int Function(
    EglDisplay dpy, Pointer<Int32> major, Pointer<Int32> minor);
final eglInitialize = libEGL
    .lookupFunction<EglInitializeNative, EglInitializeDart>('eglInitialize');

// eglChooseConfig
typedef EglChooseConfigNative = Int32 Function(
    EglDisplay dpy,
    Pointer<Int32> attribList,
    Pointer<EglConfig> configs,
    Int32 configSize,
    Pointer<Int32> numConfig);
typedef EglChooseConfigDart = int Function(
    EglDisplay dpy,
    Pointer<Int32> attribList,
    Pointer<EglConfig> configs,
    int configSize,
    Pointer<Int32> numConfig);
final eglChooseConfig =
    libEGL.lookupFunction<EglChooseConfigNative, EglChooseConfigDart>(
        'eglChooseConfig');

// eglCreateContext
typedef EglCreateContextNative = EglContext Function(EglDisplay dpy,
    EglConfig config, EglContext shareContext, Pointer<Int32> attribList);
typedef EglCreateContextDart = EglContext Function(EglDisplay dpy,
    EglConfig config, EglContext shareContext, Pointer<Int32> attribList);
final eglCreateContext =
    libEGL.lookupFunction<EglCreateContextNative, EglCreateContextDart>(
        'eglCreateContext');

// eglCreatePbufferSurface
typedef EglCreatePbufferSurfaceNative = EglSurface Function(
    EglDisplay dpy, EglConfig config, Pointer<Int32> attribList);
typedef EglCreatePbufferSurfaceDart = EglSurface Function(
    EglDisplay dpy, EglConfig config, Pointer<Int32> attribList);
final eglCreatePbufferSurface = libEGL.lookupFunction<
    EglCreatePbufferSurfaceNative,
    EglCreatePbufferSurfaceDart>('eglCreatePbufferSurface');

// eglMakeCurrent
typedef EglMakeCurrentNative = Int32 Function(
    EglDisplay dpy, EglSurface draw, EglSurface read, EglContext ctx);
typedef EglMakeCurrentDart = int Function(
    EglDisplay dpy, EglSurface draw, EglSurface read, EglContext ctx);
final eglMakeCurrent = libEGL
    .lookupFunction<EglMakeCurrentNative, EglMakeCurrentDart>('eglMakeCurrent');

// eglSwapBuffers
typedef EglSwapBuffersNative = Int32 Function(
    EglDisplay dpy, EglSurface surface);
typedef EglSwapBuffersDart = int Function(EglDisplay dpy, EglSurface surface);
final eglSwapBuffers = libEGL
    .lookupFunction<EglSwapBuffersNative, EglSwapBuffersDart>('eglSwapBuffers');

// eglDestroyContext
typedef EglDestroyContextNative = Int32 Function(
    EglDisplay dpy, EglContext ctx);
typedef EglDestroyContextDart = int Function(EglDisplay dpy, EglContext ctx);
final eglDestroyContext =
    libEGL.lookupFunction<EglDestroyContextNative, EglDestroyContextDart>(
        'eglDestroyContext');

// eglDestroySurface
typedef EglDestroySurfaceNative = Int32 Function(
    EglDisplay dpy, EglSurface surface);
typedef EglDestroySurfaceDart = int Function(
    EglDisplay dpy, EglSurface surface);
final eglDestroySurface =
    libEGL.lookupFunction<EglDestroySurfaceNative, EglDestroySurfaceDart>(
        'eglDestroySurface');

// eglTerminate
typedef EglTerminateNative = Int32 Function(EglDisplay dpy);
typedef EglTerminateDart = int Function(EglDisplay dpy);
final eglTerminate =
    libEGL.lookupFunction<EglTerminateNative, EglTerminateDart>('eglTerminate');
