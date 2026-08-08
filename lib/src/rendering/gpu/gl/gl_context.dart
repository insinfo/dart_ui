/// Getting a current OpenGL context without a window.
///
/// The GPU renderer must be testable offscreen or it is not testable at all:
/// CI has no display, and a golden test that needs a visible window is a
/// golden test that does not run. So the only context this file knows how to
/// create is an EGL pbuffer - a driver-owned offscreen surface - which is
/// exactly the configuration `poc/poc_06_opengl` proved works on Linux under
/// software Mesa.
///
/// ## What is deliberately not here
///
///   * **WGL.** Creating a modern GL context on Windows requires an `HWND`
///     and a pixel format set on its device context, even for offscreen
///     rendering. Windows are owned by `lib/src/backends/win32`, so this file
///     reports the obstacle by name and stops rather than reaching across
///     that boundary.
///   * **CGL/NSOpenGL.** Deprecated on macOS since 10.14, and the roadmap
///     (section 18) lists macOS OpenGL as legacy rather than a target. Metal
///     is the intended backend there.
///   * **GLX.** Needs an X display connection, which lives in
///     `lib/src/backends/x11`, and EGL covers both X11 and Wayland on any
///     Mesa new enough to matter.
///
/// Each of those is a [BackendDiagnostic] with a reason, not a silent false.
library;

import 'dart:ffi';
import 'dart:io';

import '../../../foundation/diagnostics.dart';
import 'gl_bindings.dart';

// EGL constants, from the registry. Same values poc_06 uses.
const int _eglNone = 0x3038;
const int _eglSuccess = 0x3000;
const int _eglAlphaSize = 0x3021;
const int _eglBlueSize = 0x3022;
const int _eglGreenSize = 0x3023;
const int _eglRedSize = 0x3024;
const int _eglSurfaceType = 0x3033;
const int _eglRenderableType = 0x3040;
const int _eglPbufferBit = 0x0001;
const int _eglOpenglBit = 0x0008;
const int _eglOpenglEs2Bit = 0x0004;
const int _eglHeight = 0x3056;
const int _eglWidth = 0x3057;
const int _eglOpenglApi = 0x30A2;
const int _eglOpenglEsApi = 0x30A0;
const int _eglContextMajorVersion = 0x3098;
const int _eglContextMinorVersion = 0x30FB;
const int _eglContextOpenglProfileMask = 0x30FD;
const int _eglContextOpenglCoreProfileBit = 0x00000001;
const int _eglDefaultDisplay = 0;

/// A GL context that can be made current on this thread.
abstract interface class GlContext {
  /// True when the context became current. False - never an exception -
  /// when the driver refused, which is one of the ways device loss shows up.
  bool makeCurrent();

  /// Which client API the context actually gave us. `true` means desktop
  /// OpenGL and therefore GLSL `#version 330 core`; `false` means OpenGL ES
  /// and GLSL ES `#version 300 es`. The shader source differs, so this is not
  /// a detail the renderer can ignore.
  bool get isDesktopGl;

  /// For the probe report and for bug reports.
  String get description;

  void dispose();
}

/// What [GlContextFactory.create] found.
final class GlContextAttempt {
  const GlContextAttempt(this.context, this.diagnostics);

  /// Null when no context could be created; [diagnostics] then says why.
  final GlContext? context;

  final List<BackendDiagnostic> diagnostics;
}

/// Creates offscreen GL contexts, or explains why it cannot.
final class GlContextFactory {
  const GlContextFactory();

  /// Library names tried for EGL, in order.
  static List<String> eglCandidates() {
    if (Platform.isWindows) {
      // ANGLE, if somebody dropped it next to the executable. Not shipped by
      // this framework; listed so that a developer who has it gets a working
      // context instead of a refusal.
      return const <String>['libEGL.dll'];
    }
    if (Platform.isMacOS) return const <String>['libEGL.dylib'];
    return const <String>['libEGL.so.1', 'libEGL.so'];
  }

  /// Attempts to create a [width] x [height] pbuffer context.
  ///
  /// Never throws. Every failure is a diagnostic.
  GlContextAttempt create({required int width, required int height}) {
    final diagnostics = <BackendDiagnostic>[];

    DynamicLibrary? egl;
    String? eglName;
    for (final candidate in eglCandidates()) {
      try {
        egl = DynamicLibrary.open(candidate);
        eglName = candidate;
        break;
      } on Object catch (error) {
        diagnostics.add(
          BackendDiagnostic.missingLibrary(candidate, detail: '$error'),
        );
      }
    }

    if (egl == null) {
      diagnostics.add(_platformAdvice());
      return GlContextAttempt(null, diagnostics);
    }

    final heap = NativeHeap.tryBind(egl);
    if (heap == null) {
      diagnostics.add(
        const BackendDiagnostic.missingSymbol(
          'malloc',
          detail: 'no native allocator could be bound from the EGL library, '
              'the process or the C runtime, so no attribute list can be '
              'built',
        ),
      );
      return GlContextAttempt(null, diagnostics);
    }

    try {
      return _createEgl(egl, eglName!, heap, width, height, diagnostics);
    } on Object catch (error, stack) {
      // A throw here is a bug in this file, not a missing driver - but the
      // probe contract says never throw, so it becomes a diagnostic that is
      // obviously ours.
      diagnostics.add(
        BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'EGL context creation threw',
          detail: '$error\n$stack',
        ),
      );
      return GlContextAttempt(null, diagnostics);
    }
  }

  static BackendDiagnostic _platformAdvice() {
    if (Platform.isWindows) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.unsupportedPlatform,
        message: 'no offscreen GL context on Windows without ANGLE',
        detail: 'WGL needs an HWND and a pixel format on its device context '
            'even to render offscreen; windows belong to '
            'lib/src/backends/win32, so this backend does not create one. '
            'Install ANGLE (libEGL.dll) or use the Direct3D backend',
      );
    }
    if (Platform.isMacOS) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.unsupportedPlatform,
        message: 'no EGL on macOS',
        detail: 'CGL is deprecated and section 18 of the roadmap treats macOS '
            'OpenGL as legacy; Metal is the intended GPU backend there',
      );
    }
    return const BackendDiagnostic(
      kind: DiagnosticKind.missingLibrary,
      message: 'no EGL implementation found',
      detail: 'install a Mesa EGL runtime (libegl1 / mesa-libEGL); GLX is not '
          'attempted because it needs an X display connection owned by '
          'lib/src/backends/x11',
    );
  }

  GlContextAttempt _createEgl(
    DynamicLibrary egl,
    String eglName,
    NativeHeap heap,
    int width,
    int height,
    List<BackendDiagnostic> diagnostics,
  ) {
    final api = _EglApi(egl);

    final display =
        api.getDisplay(Pointer<Void>.fromAddress(_eglDefaultDisplay));
    if (display.address == 0) {
      diagnostics.add(
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'eglGetDisplay returned EGL_NO_DISPLAY',
          detail: 'library: $eglName',
        ),
      );
      return GlContextAttempt(null, diagnostics);
    }

    final versions = heap.allocate<Int32>(8);
    try {
      if (api.initialize(display, versions, versions + 1) == 0) {
        diagnostics.add(_eglError(api, 'eglInitialize'));
        return GlContextAttempt(null, diagnostics);
      }
      final eglVersion = '${versions[0]}.${versions[1]}';

      // Desktop GL first: the renderer's shaders are written for GLSL 330
      // core, and a desktop context also guarantees 32-bit element indices
      // without an extension. ES is the fallback, and the shader source
      // switches with it.
      var desktop = true;
      if (api.bindApi(_eglOpenglApi) == 0) {
        desktop = false;
        if (api.bindApi(_eglOpenglEsApi) == 0) {
          diagnostics.add(_eglError(api, 'eglBindAPI'));
          return GlContextAttempt(null, diagnostics);
        }
      }

      final configs = heap.allocate<Pointer<Void>>(1);
      final configCount = heap.allocate<Int32>(1);
      final configAttribs = heap.allocate<Int32>(16);
      try {
        var i = 0;
        configAttribs[i++] = _eglSurfaceType;
        configAttribs[i++] = _eglPbufferBit;
        configAttribs[i++] = _eglRenderableType;
        configAttribs[i++] = desktop ? _eglOpenglBit : _eglOpenglEs2Bit;
        configAttribs[i++] = _eglRedSize;
        configAttribs[i++] = 8;
        configAttribs[i++] = _eglGreenSize;
        configAttribs[i++] = 8;
        configAttribs[i++] = _eglBlueSize;
        configAttribs[i++] = 8;
        configAttribs[i++] = _eglAlphaSize;
        configAttribs[i++] = 8;
        configAttribs[i++] = _eglNone;

        if (api.chooseConfig(display, configAttribs, configs, 1, configCount) ==
                0 ||
            configCount[0] < 1) {
          diagnostics.add(_eglError(api, 'eglChooseConfig'));
          return GlContextAttempt(null, diagnostics);
        }
        final config = configs[0];

        final surfaceAttribs = heap.allocate<Int32>(8);
        surfaceAttribs[0] = _eglWidth;
        surfaceAttribs[1] = width;
        surfaceAttribs[2] = _eglHeight;
        surfaceAttribs[3] = height;
        surfaceAttribs[4] = _eglNone;
        final surface =
            api.createPbufferSurface(display, config, surfaceAttribs);
        heap.release(surfaceAttribs);
        if (surface.address == 0) {
          diagnostics.add(_eglError(api, 'eglCreatePbufferSurface'));
          return GlContextAttempt(null, diagnostics);
        }

        final context = _createContext(api, heap, display, config, desktop);
        if (context.address == 0) {
          api.destroySurface(display, surface);
          diagnostics.add(_eglError(api, 'eglCreateContext'));
          return GlContextAttempt(null, diagnostics);
        }

        final glContext = _EglContext(
          api: api,
          display: display,
          surface: surface,
          context: context,
          isDesktopGl: desktop,
          description: 'EGL $eglVersion via $eglName, '
              '${desktop ? 'desktop GL' : 'GLES'} pbuffer ${width}x$height',
        );
        if (!glContext.makeCurrent()) {
          diagnostics.add(_eglError(api, 'eglMakeCurrent'));
          glContext.dispose();
          return GlContextAttempt(null, diagnostics);
        }
        return GlContextAttempt(glContext, diagnostics);
      } finally {
        heap
          ..release(configs)
          ..release(configCount)
          ..release(configAttribs);
      }
    } finally {
      heap.release(versions);
    }
  }

  /// Tries 3.3 core, then a bare major/minor, then no attributes at all.
  ///
  /// Three attempts because the attribute names differ across EGL versions:
  /// `EGL_CONTEXT_MINOR_VERSION` and the profile mask are EGL 1.5, and an
  /// EGL 1.4 driver rejects the whole list rather than ignoring what it does
  /// not know. Falling back is how a context still gets created there.
  Pointer<Void> _createContext(
    _EglApi api,
    NativeHeap heap,
    Pointer<Void> display,
    Pointer<Void> config,
    bool desktop,
  ) {
    final attribs = heap.allocate<Int32>(16);
    try {
      if (desktop) {
        var i = 0;
        attribs[i++] = _eglContextMajorVersion;
        attribs[i++] = 3;
        attribs[i++] = _eglContextMinorVersion;
        attribs[i++] = 3;
        attribs[i++] = _eglContextOpenglProfileMask;
        attribs[i++] = _eglContextOpenglCoreProfileBit;
        attribs[i++] = _eglNone;
        final full = api.createContext(display, config, nullptr, attribs);
        if (full.address != 0) return full;

        attribs[0] = _eglContextMajorVersion;
        attribs[1] = 3;
        attribs[2] = _eglNone;
        final major = api.createContext(display, config, nullptr, attribs);
        if (major.address != 0) return major;

        attribs[0] = _eglNone;
        return api.createContext(display, config, nullptr, attribs);
      }

      attribs[0] = _eglContextMajorVersion;
      attribs[1] = 3;
      attribs[2] = _eglNone;
      final es3 = api.createContext(display, config, nullptr, attribs);
      if (es3.address != 0) return es3;
      attribs[1] = 2;
      return api.createContext(display, config, nullptr, attribs);
    } finally {
      heap.release(attribs);
    }
  }

  static BackendDiagnostic _eglError(_EglApi api, String call) {
    final code = api.getError();
    return BackendDiagnostic(
      kind: DiagnosticKind.surfaceCreationFailed,
      message: '$call failed',
      detail: 'EGL error 0x${code.toRadixString(16)}'
          '${code == _eglSuccess ? ' (EGL_SUCCESS - the call reported '
              'failure without setting an error, which points at the '
              'driver)' : ''}',
    );
  }
}

/// The EGL entry points, bound the same lazy way [GlApi] binds GL's.
final class _EglApi {
  _EglApi(this.library);

  final DynamicLibrary library;

  late final Pointer<Void> Function(Pointer<Void>) getDisplay =
      library.lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('eglGetDisplay');

  late final int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>)
      initialize = library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>),
          int Function(
              Pointer<Void>, Pointer<Int32>, Pointer<Int32>)>('eglInitialize');

  late final int Function(int) bindApi = library
      .lookupFunction<Int32 Function(Uint32), int Function(int)>('eglBindAPI');

  late final int Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>,
          int, Pointer<Int32>) chooseConfig =
      library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>,
              Int32, Pointer<Int32>),
          int Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>,
              int, Pointer<Int32>)>('eglChooseConfig');

  late final Pointer<Void> Function(
          Pointer<Void>, Pointer<Void>, Pointer<Int32>) createPbufferSurface =
      library.lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>,
              Pointer<Int32>)>('eglCreatePbufferSurface');

  late final Pointer<Void> Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>)
      createContext = library.lookupFunction<
          Pointer<Void> Function(
              Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
              Pointer<Int32>)>('eglCreateContext');

  late final int Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)
      makeCurrent = library.lookupFunction<
          Int32 Function(
              Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
              Pointer<Void>)>('eglMakeCurrent');

  late final int Function(Pointer<Void>, Pointer<Void>) destroySurface =
      library.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>)>('eglDestroySurface');

  late final int Function(Pointer<Void>, Pointer<Void>) destroyContext =
      library.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>)>('eglDestroyContext');

  late final int Function(Pointer<Void>) terminate = library.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('eglTerminate');

  late final int Function() getError =
      library.lookupFunction<Int32 Function(), int Function()>('eglGetError');
}

final class _EglContext implements GlContext {
  _EglContext({
    required _EglApi api,
    required Pointer<Void> display,
    required Pointer<Void> surface,
    required Pointer<Void> context,
    required this.isDesktopGl,
    required this.description,
  })  : _api = api,
        _display = display,
        _surface = surface,
        _context = context;

  final _EglApi _api;
  final Pointer<Void> _display;
  final Pointer<Void> _surface;
  final Pointer<Void> _context;

  @override
  final bool isDesktopGl;

  @override
  final String description;

  bool _disposed = false;

  @override
  bool makeCurrent() {
    if (_disposed) return false;
    return _api.makeCurrent(_display, _surface, _surface, _context) != 0;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Reverse acquisition order, and unbind first: destroying a context that
    // is still current is legal but leaves the driver holding it until the
    // thread exits, which on a test runner means until the process does.
    _api
      ..makeCurrent(_display, nullptr, nullptr, nullptr)
      ..destroyContext(_display, _context)
      ..destroySurface(_display, _surface)
      ..terminate(_display);
  }
}
