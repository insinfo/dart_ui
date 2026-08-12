/// The window a WGL context needs, and nothing else.
///
/// Windows has no EGL. A modern OpenGL context there is created from a device
/// context that already carries a pixel format, `SetPixelFormat` may only be
/// called once per device context, and the only device context that accepts
/// one is a window's. So even a renderer that never shows a pixel on screen
/// needs a window to exist.
///
/// That requirement is the whole reason this file is in `backends/win32` and
/// not next to the GL code. `lib/src/rendering/gpu/gl/gl_context.dart` takes
/// the device context as a plain integer and calls only entry points the GL
/// library itself exports, so the renderer still names no window type -
/// `test/architecture/layering_test.dart` fails the build if it ever does.
/// This file is where the window type is allowed to be named, and it is
/// deliberately the only thing here.
///
/// ## Why the window is never shown
///
/// [Win32GlSurface.hidden] creates a normal top-level window and does not
/// call `ShowWindow`. A hidden window still owns a valid device context and a
/// valid pixel format, which is all a context needs, and a renderer drawing
/// into a framebuffer object never touches the window's own pixels. The
/// alternative - a message-only window - does not work: `HWND_MESSAGE`
/// windows have no device context that accepts a pixel format.
///
/// ## What is not here yet
///
/// A windowed *target*. This surface can swap its buffers and set a swap
/// interval, which is everything a presenting GL target needs from the window
/// system, but nothing above it draws into a window's back buffer yet - the
/// GL backend renders into a framebuffer object and reads it back. Presenting
/// through [swapBuffers] is the seam that path will use, and it is here
/// because leaving it out would make this file an offscreen-only workaround
/// rather than the platform half of a GL backend.
library;

import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import '../../rendering/gpu/gl/gl_context.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_structs.dart';

// PIXELFORMATDESCRIPTOR flags, from wingdi.h.
const int _pfdDoublebuffer = 0x00000001;
const int _pfdDrawToWindow = 0x00000004;
const int _pfdSupportOpengl = 0x00000020;
const int _pfdTypeRgba = 0;
const int _pfdMainPlane = 0;

/// The pixel-format descriptor, laid out exactly as `wingdi.h` declares it.
///
/// Written out rather than reduced to the fields that are set, because
/// `ChoosePixelFormat` reads `nSize` and walks the whole structure; a short
/// one is read past its end.
final class _PixelFormatDescriptor extends Struct {
  @Uint16()
  external int nSize;
  @Uint16()
  external int nVersion;
  @Uint32()
  external int dwFlags;
  @Uint8()
  external int iPixelType;
  @Uint8()
  external int cColorBits;
  @Uint8()
  external int cRedBits;
  @Uint8()
  external int cRedShift;
  @Uint8()
  external int cGreenBits;
  @Uint8()
  external int cGreenShift;
  @Uint8()
  external int cBlueBits;
  @Uint8()
  external int cBlueShift;
  @Uint8()
  external int cAlphaBits;
  @Uint8()
  external int cAlphaShift;
  @Uint8()
  external int cAccumBits;
  @Uint8()
  external int cAccumRedBits;
  @Uint8()
  external int cAccumGreenBits;
  @Uint8()
  external int cAccumBlueBits;
  @Uint8()
  external int cAccumAlphaBits;
  @Uint8()
  external int cDepthBits;
  @Uint8()
  external int cStencilBits;
  @Uint8()
  external int cAuxBuffers;
  @Uint8()
  external int iLayerType;
  @Uint8()
  external int bReserved;
  @Uint32()
  external int dwLayerMask;
  @Uint32()
  external int dwVisibleMask;
  @Uint32()
  external int dwDamageMask;
}

/// What [Win32GlSurface.hidden] found.
final class Win32GlSurfaceAttempt {
  const Win32GlSurfaceAttempt(this.surface, this.diagnostics);

  /// Null when no surface could be created; [diagnostics] then says why.
  final Win32GlSurface? surface;

  final List<BackendDiagnostic> diagnostics;
}

/// A window that exists only to carry an OpenGL pixel format.
final class Win32GlSurface {
  Win32GlSurface._({
    required Win32Api api,
    required _Gdi32 gdi,
    required int windowHandle,
    required int deviceContext,
    required Pointer<Uint16> className,
    required this.pixelFormat,
    required this.glLibrary,
  })  : _api = api,
        _gdi = gdi,
        _windowHandle = windowHandle,
        _deviceContext = deviceContext,
        _className = className;

  final Win32Api _api;
  final _Gdi32 _gdi;
  final int _windowHandle;
  final int _deviceContext;
  final Pointer<Uint16> _className;

  /// The format index the driver chose. Reported because a machine that picks
  /// a software format is a machine whose "GPU" renderer runs on the CPU.
  final int pixelFormat;

  /// The already-open `opengl32.dll`, so the caller does not open it twice.
  final DynamicLibrary glLibrary;

  /// The opaque device-context handle a GL context is created from.
  ///
  /// An integer on purpose: this is the value that crosses into
  /// `lib/src/rendering`, where naming what it points at is forbidden.
  int get deviceContext => _deviceContext;

  bool _disposed = false;

  /// Creates a hidden window with a double-buffered RGBA pixel format.
  ///
  /// Never throws. Every failure is a diagnostic, so a caller probing for a
  /// GPU backend on a machine without one falls back rather than crashing.
  static Win32GlSurfaceAttempt hidden({
    int width = 16,
    int height = 16,
    String className = 'DartUiGlSurface',
  }) {
    final diagnostics = <BackendDiagnostic>[];
    final load = Win32Api.load();
    final api = load.api;
    if (api == null) {
      return Win32GlSurfaceAttempt(null, load.diagnostics);
    }

    final DynamicLibrary glLibrary;
    final _Gdi32 gdi;
    try {
      glLibrary = DynamicLibrary.open('opengl32.dll');
      gdi = _Gdi32();
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic.missingLibrary(
        'opengl32.dll / gdi32.dll',
        detail: '$error',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }

    try {
      return _create(
          api, gdi, glLibrary, width, height, className, diagnostics);
    } on Object catch (error, stack) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'creating the GL surface threw',
        detail: '$error\n$stack',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }
  }

  static Win32GlSurfaceAttempt _create(
    Win32Api api,
    _Gdi32 gdi,
    DynamicLibrary glLibrary,
    int width,
    int height,
    String className,
    List<BackendDiagnostic> diagnostics,
  ) {
    final instance = api.getModuleHandleW(nullptr);
    final name = api.toUtf16(className);

    // The class's window procedure is DefWindowProcW itself, taken straight
    // out of user32's export table. There is no Dart callback and therefore
    // no way for a Dart exception to unwind through a native frame: this
    // window has no behaviour to implement, it only has to exist.
    final descriptor = api.allocator<WndClassExW>();
    descriptor.ref
      ..cbSize = sizeOf<WndClassExW>()
      ..style = csOwndc | csHredraw | csVredraw
      ..lpfnWndProc = gdi.defaultWindowProc
      ..cbClsExtra = 0
      ..cbWndExtra = 0
      ..hInstance = instance
      ..hIcon = 0
      ..hCursor = 0
      ..hbrBackground = 0
      ..lpszMenuName = nullptr
      ..lpszClassName = name
      ..hIconSm = 0;
    final atom = api.registerClassExW(descriptor);
    api.allocator.free(descriptor);
    if (atom == 0) {
      // Class already registered is not a failure: a second surface in the
      // same process reuses it, which is why the error code is inspected
      // rather than the return value alone.
      final error = api.getLastError();
      if (error != _errorClassAlreadyExists) {
        api.heapRelease(name);
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the GL window class could not be registered',
          detail: 'GetLastError=$error',
        ));
        return Win32GlSurfaceAttempt(null, diagnostics);
      }
    }

    final title = api.toUtf16('dart_ui GL surface');
    final window = api.createWindowExW(
      0,
      name,
      title,
      wsOverlappedWindow,
      0,
      0,
      width,
      height,
      0,
      0,
      instance,
      0,
    );
    api.heapRelease(title);
    if (window == 0) {
      api.heapRelease(name);
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the GL window could not be created',
        detail: 'GetLastError=${api.getLastError()}',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }

    final deviceContext = api.getDC(window);
    if (deviceContext == 0) {
      api.destroyWindow(window);
      api.heapRelease(name);
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the GL window has no device context',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }

    final format = api.allocator<_PixelFormatDescriptor>();
    format.ref
      ..nSize = sizeOf<_PixelFormatDescriptor>()
      ..nVersion = 1
      ..dwFlags = _pfdDrawToWindow | _pfdSupportOpengl | _pfdDoublebuffer
      ..iPixelType = _pfdTypeRgba
      ..cColorBits = 32
      ..cAlphaBits = 8
      ..cDepthBits = 24
      ..cStencilBits = 8
      ..iLayerType = _pfdMainPlane;
    final chosen = gdi.choosePixelFormat(deviceContext, format);
    final applied =
        chosen == 0 ? 0 : gdi.setPixelFormat(deviceContext, chosen, format);
    api.allocator.free(format);
    if (chosen == 0 || applied == 0) {
      api.releaseDC(window, deviceContext);
      api.destroyWindow(window);
      api.heapRelease(name);
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: chosen == 0
            ? 'no OpenGL-capable pixel format on this device context'
            : 'the OpenGL pixel format could not be applied',
        detail: 'GetLastError=${api.getLastError()}',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }

    return Win32GlSurfaceAttempt(
      Win32GlSurface._(
        api: api,
        gdi: gdi,
        windowHandle: window,
        deviceContext: deviceContext,
        className: name,
        pixelFormat: chosen,
        glLibrary: glLibrary,
      ),
      diagnostics,
    );
  }

  /// Creates a GL context on this surface, or explains why it could not.
  ///
  /// The whole point of the file: the integer goes across the boundary and a
  /// [GlContext] comes back, with no type from either side visible to the
  /// other.
  GlContextAttempt createContext() =>
      const GlContextFactory().createForDeviceContext(
        deviceContext: _deviceContext,
        glLibrary: glLibrary,
      );

  /// Presents the back buffer. Only meaningful once something draws into it.
  bool swapBuffers() => _gdi.swapBuffers(_deviceContext) != 0;

  /// Asks the driver to hold the swap for [interval] vertical blanks.
  ///
  /// Returns false when the extension is absent - which is normal on a remote
  /// desktop session - rather than pretending vsync is on. Requires a context
  /// to be current: `wglSwapIntervalEXT` is an extension entry point like any
  /// other and cannot be resolved without one.
  bool setSwapInterval(int interval) {
    final address = _wglProc('wglSwapIntervalEXT');
    if (address == nullptr) return false;
    final setter = address
        .cast<NativeFunction<Int32 Function(Int32)>>()
        .asFunction<int Function(int)>();
    return setter(interval) != 0;
  }

  Pointer<Void> _wglProc(String name) {
    final getProcAddress = glLibrary.lookupFunction<
        Pointer<Void> Function(Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Uint8>)>('wglGetProcAddress');
    final units = name.codeUnits;
    final native = _api.heapAllocate(units.length + 1).cast<Uint8>();
    final view = native.asTypedList(units.length + 1);
    view.setRange(0, units.length, units);
    view[units.length] = 0;
    try {
      return getProcAddress(native);
    } finally {
      _api.heapRelease(native);
    }
  }

  /// Releases the window. The class registration is left behind on purpose:
  /// unregistering it would break any other surface still using it, and a
  /// process holds at most one such class for its whole life.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _api.releaseDC(_windowHandle, _deviceContext);
    _api.destroyWindow(_windowHandle);
    _api.heapRelease(_className);
  }
}

/// `ERROR_CLASS_ALREADY_EXISTS`. A second surface in one process is fine.
const int _errorClassAlreadyExists = 1410;

/// The three GDI calls a pixel format needs, plus the address of the default
/// window procedure.
final class _Gdi32 {
  _Gdi32()
      : _gdi = DynamicLibrary.open('gdi32.dll'),
        _user = DynamicLibrary.open('user32.dll') {
    choosePixelFormat = _gdi.lookupFunction<
        Int32 Function(IntPtr, Pointer<_PixelFormatDescriptor>),
        int Function(
            int, Pointer<_PixelFormatDescriptor>)>('ChoosePixelFormat');
    setPixelFormat = _gdi.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<_PixelFormatDescriptor>),
        int Function(
            int, int, Pointer<_PixelFormatDescriptor>)>('SetPixelFormat');
    swapBuffers =
        _gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'SwapBuffers');
    defaultWindowProc =
        _user.lookup<NativeFunction<WndProcNative>>('DefWindowProcW');
  }

  final DynamicLibrary _gdi;
  final DynamicLibrary _user;

  late final int Function(int, Pointer<_PixelFormatDescriptor>)
      choosePixelFormat;
  late final int Function(int, int, Pointer<_PixelFormatDescriptor>)
      setPixelFormat;
  late final int Function(int) swapBuffers;
  late final Pointer<NativeFunction<WndProcNative>> defaultWindowProc;
}
