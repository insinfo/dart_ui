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
/// ## Two ways in, and the trap they share
///
/// [Win32GlSurface.hidden] makes its own window. [Win32GlSurface.forWindow]
/// adopts one somebody else already made - a real, visible application window
/// - so that `GlWindowTarget` can swap its back buffer.
///
/// Both have to set a pixel format, and **a window's pixel format can only be
/// set once**. `SetPixelFormat` is documented that way and the failure is
/// quiet: the second call returns zero and `GetLastError` says
/// `ERROR_INVALID_PIXEL_FORMAT`, or, on some drivers, it returns success and
/// changes nothing. A caller that ignores it gets a context created against a
/// format the window does not have, which draws into nowhere. So
/// [Win32GlSurface.forWindow] asks `GetPixelFormat` first and adopts an
/// existing format rather than fighting it, and says in its diagnostics which
/// of the two happened. The corollary is worth stating: a window that was
/// given a non-OpenGL pixel format by someone else can never carry a GL
/// context and must be recreated - that is a caller error this file reports
/// and cannot fix.
///
/// This is also why a GL window must be created with `CS_OWNDC`. Without it
/// the device context returned by `GetDC` is a temporary from a system cache,
/// and the pixel format set on one is not the pixel format the next call
/// returns.
library;

import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/gpu/gl/gl_context.dart';
import '../../rendering/gpu/gl/gl_surface_descriptor.dart';
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

/// What [Win32GlSurface.hidden] or [Win32GlSurface.forWindow] found.
final class Win32GlSurfaceAttempt {
  const Win32GlSurfaceAttempt(this.surface, this.diagnostics);

  /// Null when no surface could be created; [diagnostics] then says why.
  final Win32GlSurface? surface;

  final List<BackendDiagnostic> diagnostics;
}

/// A window carrying an OpenGL pixel format, and the swap chain over it.
///
/// Implements [GlSwapChain] so `GlWindowTarget` can present through it without
/// the renderer ever learning what a window is - the interface is declared in
/// `lib/src/rendering/gpu/gl/gl_surface_descriptor.dart`, which is allowed to
/// describe presenting and forbidden to name a window type.
final class Win32GlSurface implements GlSwapChain {
  Win32GlSurface._({
    required Win32Api api,
    required _Gdi32 gdi,
    required int windowHandle,
    required int deviceContext,
    required Pointer<Uint16>? className,
    required this.pixelFormat,
    required this.glLibrary,
    required bool ownsWindow,
  })  : _api = api,
        _gdi = gdi,
        _windowHandle = windowHandle,
        _deviceContext = deviceContext,
        _className = className,
        _ownsWindow = ownsWindow;

  final Win32Api _api;
  final _Gdi32 _gdi;
  final int _windowHandle;
  final int _deviceContext;

  /// Null when the window came from somewhere else: there is no class name to
  /// release because this file did not register one.
  final Pointer<Uint16>? _className;

  /// Whether [dispose] destroys the window.
  ///
  /// False for [forWindow]. Destroying a window this object merely borrowed
  /// would take the application's window down with the renderer, which is the
  /// opposite of the lifetime `renderer.dart` describes - "a target is bound
  /// to a window and dies with it, while the device outlives both".
  final bool _ownsWindow;

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

  /// The window, as an opaque integer, for the same reason.
  ///
  /// Goes into [GlWindowSurfaceDescriptor.nativeHandle], which documents at
  /// length why it is a number rather than a type.
  int get windowHandle => _windowHandle;

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

  /// Adopts a window somebody else created, so GL can present into it.
  ///
  /// This is the entry point a real application uses:
  /// `lib/src/backends/win32/win32_window.dart` owns a visible window, and a
  /// `GlWindowTarget` over it needs exactly three things from this file - a
  /// device context with an OpenGL pixel format, a GL context on it, and
  /// something that can call `SwapBuffers`.
  ///
  /// [windowHandle] is the window, as an integer. The type is not named even
  /// here, where naming it would be legal, because the value's only journey is
  /// from the window that made it to `GetDC`, and giving it a name would
  /// invite code that assumes more about it than that.
  ///
  /// ## The pixel format is set at most once, and possibly not at all
  ///
  /// `GetPixelFormat` is asked first. A non-zero answer means the window
  /// already has one - because a previous surface adopted it, or because
  /// something else in the process did - and it is adopted as-is: calling
  /// `SetPixelFormat` a second time on the same window is documented to fail,
  /// and the failure mode when it is ignored is a context that draws into
  /// nowhere rather than an error. When the format is adopted rather than
  /// chosen, a note says so, because a format this file did not pick may not
  /// be double-buffered and a single-buffered window makes `SwapBuffers` a
  /// no-op.
  ///
  /// Never throws. Every failure is a diagnostic. Does **not** take ownership
  /// of the window: [dispose] releases the device context and stops there.
  static Win32GlSurfaceAttempt forWindow(int windowHandle) {
    final diagnostics = <BackendDiagnostic>[];
    if (windowHandle == 0) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'a null window handle cannot carry a GL surface',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }

    final load = Win32Api.load();
    final api = load.api;
    if (api == null) return Win32GlSurfaceAttempt(null, load.diagnostics);

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
      return _adopt(api, gdi, glLibrary, windowHandle, diagnostics);
    } on Object catch (error, stack) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'adopting the window for GL threw',
        detail: '$error\n$stack',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }
  }

  static Win32GlSurfaceAttempt _adopt(
    Win32Api api,
    _Gdi32 gdi,
    DynamicLibrary glLibrary,
    int windowHandle,
    List<BackendDiagnostic> diagnostics,
  ) {
    if (api.isWindow(windowHandle) == 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the handle is not a live window',
        detail: '0x${windowHandle.toUnsigned(64).toRadixString(16)}; it was '
            'closed, or it never was one',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }

    final deviceContext = api.getDC(windowHandle);
    if (deviceContext == 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the window has no device context',
        detail: 'GetLastError=${api.getLastError()}',
      ));
      return Win32GlSurfaceAttempt(null, diagnostics);
    }

    final existing = gdi.getPixelFormat(deviceContext);
    var chosen = existing;
    if (existing == 0) {
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
      chosen = gdi.choosePixelFormat(deviceContext, format);
      final applied =
          chosen == 0 ? 0 : gdi.setPixelFormat(deviceContext, chosen, format);
      api.allocator.free(format);
      if (chosen == 0 || applied == 0) {
        api.releaseDC(windowHandle, deviceContext);
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: chosen == 0
              ? 'no OpenGL-capable pixel format on this window'
              : 'the OpenGL pixel format could not be applied to this window',
          detail: 'GetLastError=${api.getLastError()}. A window can be given a '
              'pixel format exactly once; if something else in this process '
              'already gave this one a non-OpenGL format, it has to be '
              'recreated',
        ));
        return Win32GlSurfaceAttempt(null, diagnostics);
      }
    } else {
      diagnostics.add(BackendDiagnostic.note(
        'the window already had pixel format $existing, which was adopted',
        detail: 'SetPixelFormat may only be called once per window, so this '
            'format was not chosen by dart_ui. If it is not double-buffered, '
            'SwapBuffers will succeed and show nothing',
      ));
    }

    return Win32GlSurfaceAttempt(
      Win32GlSurface._(
        api: api,
        gdi: gdi,
        windowHandle: windowHandle,
        deviceContext: deviceContext,
        className: null,
        pixelFormat: chosen,
        glLibrary: glLibrary,
        ownsWindow: false,
      ),
      diagnostics,
    );
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
        ownsWindow: true,
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

  /// Describes this window to the renderer, as the thing a target draws into.
  ///
  /// The bridge the GL backend was missing: `GlRenderDevice.createTarget`
  /// takes a `NativeSurfaceDescriptor`, and until [GlWindowSurfaceDescriptor]
  /// existed the only one in the framework was a block of memory. Everything
  /// crossing here is either a number or an interface declared in the
  /// rendering layer, so the layering rule holds.
  ///
  /// [generation] is the *window's* token. Pass the one the window already
  /// owns - `NativeWindow.generation` is driven by one - so that a resize
  /// invalidates in-flight frames without the window and the renderer having
  /// to agree on a protocol. A fresh token is created when none is given,
  /// which is right only for a window nobody else resizes, such as the hidden
  /// one in a test.
  ///
  /// The size is in physical pixels and is the caller's to get right: this
  /// file could call `GetClientRect`, and deliberately does not, because the
  /// window owner already tracks its client size and a second source of truth
  /// for it is how a renderer ends up one resize behind.
  GlWindowSurfaceDescriptor describeSurface({
    required int pixelWidth,
    required int pixelHeight,
    double scale = 1.0,
    GenerationToken? generation,
    PixelFormat format = PixelFormat.rgba8888Premultiplied,
  }) =>
      GlWindowSurfaceDescriptor(
        nativeHandle: _windowHandle,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        swapChain: this,
        generation: generation ?? GenerationToken(),
        scale: scale,
        format: format,
        description: 'Win32 window, WGL pixel format $pixelFormat',
      );

  /// False once [dispose] ran or the window went away underneath us.
  ///
  /// `IsWindow` is asked rather than assumed because a window can be destroyed
  /// by its own message loop between two frames, and `SwapBuffers` on a stale
  /// device context is undefined rather than an error.
  @override
  bool get isPresentable => !_disposed && _api.isWindow(_windowHandle) != 0;

  /// Presents the back buffer. Only meaningful once something draws into it.
  ///
  /// Must be called with the GL context current. `SwapBuffers` is defined
  /// against the device context passed to it, but the driver flushes the
  /// calling thread's current context as part of it, and swapping without one
  /// current presents whatever was in the buffer before.
  @override
  bool swapBuffers() {
    if (_disposed) return false;
    return _gdi.swapBuffers(_deviceContext) != 0;
  }

  /// Nothing to do: a window's back buffer is resized by the window system.
  ///
  /// The method exists because `GlSwapChain` declares it and because EGL is
  /// not always as obliging. Returning null unconditionally is the honest
  /// answer here rather than a stub - there is no WGL call that resizes a back
  /// buffer, because the back buffer is not a WGL object. It belongs to the
  /// device context, and the device context belongs to the window.
  ///
  /// One consequence worth stating: a swap issued before the window system has
  /// finished resizing presents at the old size and is not an error anywhere.
  /// That is what the generation token on the descriptor is for.
  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    if (_disposed) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'this GL surface was disposed and cannot be resized',
      );
    }
    if (_api.isWindow(_windowHandle) == 0) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the window is gone, so its back buffer cannot follow a '
            'resize',
        detail: '0x${_windowHandle.toUnsigned(64).toRadixString(16)} to '
            '${pixelWidth}x$pixelHeight',
      );
    }
    return null;
  }

  /// Asks the driver to hold the swap for [interval] vertical blanks.
  ///
  /// Returns false when the extension is absent - which is normal on a remote
  /// desktop session - rather than pretending vsync is on. Requires a context
  /// to be current: `wglSwapIntervalEXT` is an extension entry point like any
  /// other and cannot be resolved without one.
  @override
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

  /// Releases the device context, and the window only if this made it.
  ///
  /// The class registration is left behind on purpose: unregistering it would
  /// break any other surface still using it, and a process holds at most one
  /// such class for its whole life.
  ///
  /// A surface from [forWindow] never destroys the window. It borrowed it, and
  /// destroying a borrowed window would close the application's own window the
  /// first time a renderer was torn down and rebuilt - which is exactly what a
  /// device loss does.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _api.releaseDC(_windowHandle, _deviceContext);
    if (!_ownsWindow) return;
    _api.destroyWindow(_windowHandle);
    final className = _className;
    if (className != null) _api.heapRelease(className);
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
    getPixelFormat =
        _gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'GetPixelFormat');
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

  /// The format index already on a device context, or 0 for none.
  ///
  /// The guard that makes [Win32GlSurface.forWindow] safe: a window's pixel
  /// format may only be set once, so this is how a second surface over the
  /// same window learns to leave it alone.
  late final int Function(int) getPixelFormat;
  late final int Function(int) swapBuffers;
  late final Pointer<NativeFunction<WndProcNative>> defaultWindowProc;
}
