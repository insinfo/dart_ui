/// Getting a current OpenGL context, with or without a window.
///
/// Two paths, because the two platforms this framework runs on disagree about
/// what a context needs.
///
///   * **EGL pbuffer**, for CI and for every offscreen test. The GPU renderer
///     must be testable without a display or a compositor, or it is not
///     testable at all - a golden test that needs a visible window is a
///     golden test that does not run. This is the configuration
///     `poc/poc_06_opengl` proved works on Linux under software Mesa, and it
///     stays the default everywhere it is available.
///   * **WGL**, for Windows, where there is no EGL. A modern context there is
///     created from a device context that already carries a pixel format, and
///     a pixel format can only be set on a window's device context - so a
///     window has to exist first.
///
/// ## How WGL stays on the right side of the layering rule
///
/// It never names a window. [GlContextFactory.createForDeviceContext] takes
/// the device context as a plain integer: an opaque handle whose meaning is
/// the caller's business. `lib/src/backends/win32` owns the window, sets the
/// pixel format on its device context and passes the number here; this file
/// calls only entry points the GL library itself exports, so nothing under
/// `lib/src/rendering` gains a dependency on a window system. The
/// architecture test in `test/architecture/layering_test.dart` enforces that.
///
/// The obstacle the previous version of this file reported - "windows belong
/// to another module" - was real. Its advice was not: it suggested installing
/// ANGLE, which is a native runtime this framework does not ship and will not
/// require. Handing an integer across a module boundary costs nothing and
/// solves it.
///
/// ## What is still deliberately not here
///
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
import 'gl_surface_descriptor.dart';

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

/// `EGL_WINDOW_BIT`. The bit that makes the difference between a config a
/// pbuffer can use and one `eglCreateWindowSurface` will accept - see
/// [GlContextFactory.createForWindowSurface].
const int _eglWindowBit = 0x0004;
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
const int _eglNativeVisualId = 0x302E;
const int _eglRenderBuffer = 0x3086;
const int _eglBackBuffer = 0x3084;

// WGL_ARB_create_context, from the registry.
const int _wglContextMajorVersion = 0x2091;
const int _wglContextMinorVersion = 0x2092;
const int _wglContextProfileMask = 0x9126;
const int _wglContextCoreProfileBit = 0x00000001;

/// A GL context that can be made current on this thread.
abstract interface class GlContext {
  /// True when the context became current. False - never an exception -
  /// when the driver refused, which is one of the ways device loss shows up.
  bool makeCurrent();

  /// Where this context's entry points come from.
  ///
  /// Belongs to the context and not to the library because on Windows the
  /// answer depends on which context is current: `wglGetProcAddress` is
  /// documented to return an address valid only for the pixel format of the
  /// context that was current when it was called. A table built under one
  /// context and used under another is the kind of bug that works on the
  /// developer's single-GPU machine and crashes on a laptop that switches.
  GlProcResolver get procAddress;

  /// Which client API the context actually gave us. `true` means desktop
  /// OpenGL and therefore GLSL `#version 330 core`; `false` means OpenGL ES
  /// and GLSL ES `#version 300 es`. The shader source differs, so this is not
  /// a detail the renderer can ignore.
  bool get isDesktopGl;

  /// Whether this context draws into a window-system surface.
  ///
  /// True means framebuffer 0 is a window's back buffer and swapping it puts
  /// pixels on a screen, which is what `Capability.gpuPresentation` reports and
  /// what `GlWindowTarget` needs. False means framebuffer 0 is a pbuffer or an
  /// invisible scratch surface: the renderer still works, but the only way its
  /// output leaves the GPU is a readback.
  ///
  /// Asked rather than assumed because the two look identical from GL's side -
  /// the same `glViewport`, the same `glClear` - and the difference only shows
  /// up as a frame that renders correctly and appears nowhere.
  bool get presentsToWindow;

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

/// What [GlContextFactory.createForWindowSurface] found.
///
/// Separate from [GlContextAttempt] because a windowed attempt produces a
/// second thing: the [GlSwapChain] that presents the surface. Returning them
/// together rather than letting the caller fish the swap chain out of the
/// context is deliberate - the surface and the context are created in one
/// transaction and either both exist or neither does, and a two-call API would
/// let a caller hold one without the other.
final class GlWindowContextAttempt {
  const GlWindowContextAttempt(
    this.context,
    this.swapChain,
    this.diagnostics, {
    this.nativeVisualId,
  });

  /// Null when no context could be created; [diagnostics] then says why.
  /// Non-null exactly when [swapChain] is.
  final GlContext? context;

  /// How the window's back buffer reaches the screen. Owned by [context]:
  /// disposing the context destroys the surface this presents, and using it
  /// afterwards reports failure rather than crashing.
  final GlSwapChain? swapChain;

  /// The X visual (or platform equivalent) the chosen EGL config wants.
  ///
  /// Reported and not enforced, because this file cannot enforce it: the
  /// window already exists by the time it gets here, and on X11 a window whose
  /// visual disagrees with the config's makes `eglCreateWindowSurface` fail
  /// with `EGL_BAD_MATCH`. When that happens this value is the first thing a
  /// bug report needs - it says which visual the window should have been
  /// created with.
  final int? nativeVisualId;

  final List<BackendDiagnostic> diagnostics;
}

/// Whether this machine has the entry points a windowed GL target needs.
///
/// Not "is there a window" - that is the windowing backend's question and this
/// file may not ask it. This is the narrower one a renderer probe can answer
/// honestly without a display server: are the calls that swap a window's back
/// buffer present in the driver at all.
final class GlWindowPresentationProbe {
  const GlWindowPresentationProbe(this.available, this.diagnostic);

  /// True when a [GlSwapChain] can exist on this machine.
  final bool available;

  /// Always populated, including when [available] is true - a probe that only
  /// explains its failures leaves the successful case unauditable, and "why
  /// did it decide it could" is a question bug reports ask.
  final BackendDiagnostic diagnostic;
}

/// Creates offscreen GL contexts, or explains why it cannot.
final class GlContextFactory {
  const GlContextFactory();

  /// What this machine can do about presenting GL to a window.
  ///
  /// Called by `GlRendererBackend.probe`, which before this reported
  /// "offscreen only" unconditionally - a hard-coded answer that was wrong on
  /// every machine with a working driver, and that the probe had no way of
  /// correcting because the only context it ever created was a pbuffer.
  ///
  /// Never throws, never creates a window, never needs a display server.
  static GlWindowPresentationProbe probeWindowPresentation() {
    if (Platform.isWindows) {
      // WGL, and only the parts the GL library itself exports. Every WGL
      // context is created from a device context that carries a pixel format,
      // and the only device context that can is a window's - so a WGL context
      // that exists at all is one whose framebuffer 0 is a window's back
      // buffer. The swap itself is issued by the platform code that owns the
      // window; this only certifies that the context half is there.
      try {
        final library = DynamicLibrary.open('opengl32.dll');
        _WglApi(library);
        return const GlWindowPresentationProbe(
          true,
          BackendDiagnostic.note(
            'windowed presentation is available through WGL',
            detail: 'opengl32.dll exports the WGL entry points; a target needs '
                'a window from lib/src/backends/win32, which builds the '
                'GlWindowSurfaceDescriptor and its swap chain',
          ),
        );
      } on Object catch (error) {
        return GlWindowPresentationProbe(
          false,
          BackendDiagnostic.missingSymbol(
            'wglCreateContext',
            detail: 'opengl32.dll did not load or does not export the WGL '
                'entry points, so no GL context can reach a window here: '
                '$error',
          ),
        );
      }
    }

    final candidates = eglCandidates();
    if (candidates.isEmpty) {
      return GlWindowPresentationProbe(false, _platformAdvice());
    }
    for (final candidate in candidates) {
      final DynamicLibrary egl;
      try {
        egl = DynamicLibrary.open(candidate);
      } on Object {
        continue;
      }
      try {
        final api = _EglApi(egl);
        // Reading each late field forces the lookup; values are discarded.
        api.createWindowSurface;
        api.swapBuffers;
        api.swapInterval;
        return GlWindowPresentationProbe(
          true,
          BackendDiagnostic.note(
            'windowed presentation is available through EGL',
            detail: '$candidate exports eglCreateWindowSurface, eglSwapBuffers '
                'and eglSwapInterval; a target needs a window from '
                'lib/src/backends/x11, and the window must have been created '
                'with a visual the chosen EGL config accepts',
          ),
        );
      } on Object catch (error) {
        return GlWindowPresentationProbe(
          false,
          BackendDiagnostic.missingSymbol(
            'eglCreateWindowSurface / eglSwapBuffers / eglSwapInterval',
            detail: '$candidate loaded but does not export them: $error',
          ),
        );
      }
    }
    return GlWindowPresentationProbe(
      false,
      BackendDiagnostic.missingLibrary(
        candidates.join(', '),
        detail: 'no EGL implementation answered, so nothing here can swap a '
            "window's back buffer",
      ),
    );
  }

  /// Library names tried for EGL, in order.
  ///
  /// Empty on Windows: there is no system EGL there, and the WGL path is the
  /// supported one. Naming a third-party redistributable here would make the
  /// probe's answer depend on what happens to be sitting next to the
  /// executable.
  static List<String> eglCandidates() {
    if (Platform.isWindows) return const <String>[];
    if (Platform.isMacOS) return const <String>['libEGL.dylib'];
    return const <String>['libEGL.so.1', 'libEGL.so'];
  }

  /// Attempts to create a [width] x [height] pbuffer context.
  ///
  /// [glLibrary] is the already-open GL library; its export table is the
  /// first half of the context's [GlContext.procAddress].
  ///
  /// Never throws. Every failure is a diagnostic.
  GlContextAttempt create({
    required int width,
    required int height,
    required DynamicLibrary glLibrary,
  }) {
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
      return _createEgl(
          egl, eglName!, glLibrary, heap, width, height, diagnostics);
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
        message: 'Windows has no EGL; use the WGL path',
        detail: 'a context here is created from a device context that already '
            'carries a pixel format, which only a window can provide. '
            'lib/src/backends/win32 makes one and calls '
            'GlContextFactory.createForDeviceContext with its handle',
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
    DynamicLibrary glLibrary,
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

    final versions = heap.allocateInt32(2);
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

      final configs = heap.allocatePointers<Void>(1);
      final configCount = heap.allocateInt32(1);
      final configAttribs = heap.allocateInt32(16);
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

        final surfaceAttribs = heap.allocateInt32(8);
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
          heap: heap,
          glLibrary: glLibrary,
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

  /// Creates a context whose default framebuffer is a window's back buffer.
  ///
  /// [nativeWindow] is opaque here for the same reason a device context is:
  /// it is `EGLNativeWindowType`, whatever that happens to be on this
  /// platform, and `lib/src/rendering` may not name a window type. On X11 -
  /// the only platform this path targets today - it is the `xcb_window_t` of
  /// an already-mapped window, which is the same XID an Xlib `Window` is, so
  /// the value crosses from `lib/src/backends/x11` unchanged.
  ///
  /// ## The config is chosen differently from the pbuffer one, and must be
  ///
  /// [create] asks for `EGL_SURFACE_TYPE = EGL_PBUFFER_BIT`. This asks for
  /// `EGL_WINDOW_BIT`, and the difference is not cosmetic: the two sets of
  /// configs overlap but neither contains the other. A driver routinely
  /// offers pbuffer-only configs (no visual attached, so no window can use
  /// them) and window-only configs (backed by a scanout format a pbuffer
  /// cannot allocate). Reusing the pbuffer config here produces
  /// `EGL_BAD_MATCH` from `eglCreateWindowSurface` on a good driver, and on a
  /// permissive one produces a surface that renders and never scans out -
  /// which is the failure that looks like a renderer bug for a week.
  ///
  /// ## What this cannot check, said out loud
  ///
  /// On X11 the window's *visual* must match the config's
  /// `EGL_NATIVE_VISUAL_ID`. The window already exists by the time this is
  /// called, so there is nothing to do about a mismatch except report it: the
  /// chosen config's visual id comes back in
  /// [GlWindowContextAttempt.nativeVisualId] so the caller can compare it
  /// against the visual it created the window with. Creating the window with
  /// the right visual is the window owner's job, and it needs the config to
  /// know which one - a chicken-and-egg the EGL spec resolves by expecting the
  /// window owner to run `eglChooseConfig` first. This framework's X11 backend
  /// creates its windows with the root visual, which is the common case and is
  /// what a 32-bit RGBA config usually matches; when it does not, this is the
  /// number that says so.
  ///
  /// Never throws. Every failure is a diagnostic.
  GlWindowContextAttempt createForWindowSurface({
    required int nativeWindow,
    required DynamicLibrary glLibrary,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    if (nativeWindow == 0) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'a null native window cannot carry an EGL surface',
      ));
      return GlWindowContextAttempt(null, null, diagnostics);
    }

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
      return GlWindowContextAttempt(null, null, diagnostics);
    }

    final heap = NativeHeap.tryBind(egl);
    if (heap == null) {
      diagnostics.add(const BackendDiagnostic.missingSymbol(
        'malloc',
        detail: 'no native allocator could be bound from the EGL library, the '
            'process or the C runtime, so no attribute list can be built',
      ));
      return GlWindowContextAttempt(null, null, diagnostics);
    }

    try {
      return _createEglWindow(
          egl, eglName!, glLibrary, heap, nativeWindow, diagnostics);
    } on Object catch (error, stack) {
      // A throw here is a bug in this file, not a missing driver. The contract
      // says never throw, so it becomes a diagnostic that is obviously ours.
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'EGL window context creation threw',
        detail: '$error\n$stack',
      ));
      return GlWindowContextAttempt(null, null, diagnostics);
    }
  }

  GlWindowContextAttempt _createEglWindow(
    DynamicLibrary egl,
    String eglName,
    DynamicLibrary glLibrary,
    NativeHeap heap,
    int nativeWindow,
    List<BackendDiagnostic> diagnostics,
  ) {
    final api = _EglApi(egl);

    // The three window entry points are resolved before anything is created,
    // so an EGL that cannot present to a window says so by name instead of
    // failing halfway through with a surface already allocated.
    try {
      // Reading each late field forces the lookup; the values are discarded.
      api.createWindowSurface;
      api.swapBuffers;
      api.swapInterval;
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic.missingSymbol(
        'eglCreateWindowSurface / eglSwapBuffers / eglSwapInterval',
        detail: 'library: $eglName; $error',
      ));
      return GlWindowContextAttempt(null, null, diagnostics);
    }

    final display =
        api.getDisplay(Pointer<Void>.fromAddress(_eglDefaultDisplay));
    if (display.address == 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'eglGetDisplay returned EGL_NO_DISPLAY',
        detail: 'library: $eglName',
      ));
      return GlWindowContextAttempt(null, null, diagnostics);
    }

    final versions = heap.allocateInt32(2);
    try {
      if (api.initialize(display, versions, versions + 1) == 0) {
        diagnostics.add(_eglError(api, 'eglInitialize'));
        return GlWindowContextAttempt(null, null, diagnostics);
      }
      final eglVersion = '${versions[0]}.${versions[1]}';

      var desktop = true;
      if (api.bindApi(_eglOpenglApi) == 0) {
        desktop = false;
        if (api.bindApi(_eglOpenglEsApi) == 0) {
          diagnostics.add(_eglError(api, 'eglBindAPI'));
          return GlWindowContextAttempt(null, null, diagnostics);
        }
      }

      final configs = heap.allocatePointers<Void>(1);
      final configCount = heap.allocateInt32(1);
      final configAttribs = heap.allocateInt32(16);
      final scratch = heap.allocateInt32(1);
      try {
        var i = 0;
        configAttribs[i++] = _eglSurfaceType;
        // The one line this method exists for.
        configAttribs[i++] = _eglWindowBit;
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
          diagnostics.add(_eglError(api, 'eglChooseConfig(EGL_WINDOW_BIT)'));
          return GlWindowContextAttempt(null, null, diagnostics);
        }
        final config = configs[0];

        int? visualId;
        scratch[0] = 0;
        if (api.getConfigAttrib(display, config, _eglNativeVisualId, scratch) !=
            0) {
          visualId = scratch[0];
        }

        // EGL_RENDER_BUFFER is spelled out rather than left to default. The
        // default for a window surface *is* EGL_BACK_BUFFER, but a
        // single-buffered surface would make eglSwapBuffers a no-op and the
        // renderer would show a half-drawn frame, which is worth two integers
        // to rule out.
        final surfaceAttribs = heap.allocateInt32(4);
        surfaceAttribs[0] = _eglRenderBuffer;
        surfaceAttribs[1] = _eglBackBuffer;
        surfaceAttribs[2] = _eglNone;
        final surface = api.createWindowSurface(
            display, config, nativeWindow, surfaceAttribs);
        heap.release(surfaceAttribs);
        if (surface.address == 0) {
          diagnostics.add(_eglError(api, 'eglCreateWindowSurface'));
          diagnostics.add(BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'the window did not accept an EGL surface',
            detail: 'native window 0x'
                '${nativeWindow.toUnsigned(64).toRadixString(16)}; the config '
                'wants native visual '
                '${visualId == null ? 'unknown' : '0x'
                    '${visualId.toUnsigned(32).toRadixString(16)}'}. An '
                'EGL_BAD_MATCH here means the window was created with a '
                'different visual',
          ));
          return GlWindowContextAttempt(null, null, diagnostics);
        }

        final context = _createContext(api, heap, display, config, desktop);
        if (context.address == 0) {
          api.destroySurface(display, surface);
          diagnostics.add(_eglError(api, 'eglCreateContext'));
          return GlWindowContextAttempt(null, null, diagnostics);
        }

        final glContext = _EglContext(
          api: api,
          display: display,
          surface: surface,
          context: context,
          heap: heap,
          glLibrary: glLibrary,
          isDesktopGl: desktop,
          presentsToWindow: true,
          description: 'EGL $eglVersion via $eglName, '
              '${desktop ? 'desktop GL' : 'GLES'} window surface on 0x'
              '${nativeWindow.toUnsigned(64).toRadixString(16)}',
        );
        if (!glContext.makeCurrent()) {
          diagnostics.add(_eglError(api, 'eglMakeCurrent'));
          glContext.dispose();
          return GlWindowContextAttempt(null, null, diagnostics);
        }
        return GlWindowContextAttempt(
          glContext,
          glContext,
          diagnostics,
          nativeVisualId: visualId,
        );
      } finally {
        heap
          ..release(configs)
          ..release(configCount)
          ..release(configAttribs)
          ..release(scratch);
      }
    } finally {
      heap.release(versions);
    }
  }

  /// Creates a context on an existing device context, for Windows.
  ///
  /// [deviceContext] is opaque here on purpose: it is whatever integer the
  /// platform's `GetDC` returned, and this file neither knows nor may know
  /// what it points at. The caller must already have chosen and set a pixel
  /// format on it - a device context can only be given one once, and getting
  /// that wrong produces a context that draws nowhere rather than an error.
  ///
  /// The two-step dance below is not ceremony. `wglCreateContextAttribsARB`
  /// is itself an extension, so it can only be obtained from
  /// `wglGetProcAddress`, which only answers with a context already current -
  /// so a throwaway legacy context has to be created and made current first.
  /// This is the sequence `poc/poc_06_opengl/bin/opengl_windows.dart` proves
  /// works on this project's hardware.
  ///
  /// Never throws. Every failure is a diagnostic.
  GlContextAttempt createForDeviceContext({
    required int deviceContext,
    required DynamicLibrary glLibrary,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    if (deviceContext == 0) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'a null device context cannot carry a GL context',
      ));
      return GlContextAttempt(null, diagnostics);
    }

    final heap = NativeHeap.tryBind(glLibrary);
    if (heap == null) {
      diagnostics.add(const BackendDiagnostic.missingSymbol(
        'malloc',
        detail: 'no native allocator could be bound, so no attribute list '
            'and no entry-point name can be built',
      ));
      return GlContextAttempt(null, diagnostics);
    }

    _WglApi api;
    try {
      api = _WglApi(glLibrary);
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic.missingSymbol(
        'wglCreateContext',
        detail: 'the GL library does not export the WGL entry points: $error',
      ));
      return GlContextAttempt(null, diagnostics);
    }

    try {
      return _createWgl(api, heap, deviceContext, diagnostics);
    } on Object catch (error, stack) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'WGL context creation threw',
        detail: '$error\n$stack',
      ));
      return GlContextAttempt(null, diagnostics);
    }
  }

  GlContextAttempt _createWgl(
    _WglApi api,
    NativeHeap heap,
    int deviceContext,
    List<BackendDiagnostic> diagnostics,
  ) {
    final legacy = api.createContext(deviceContext);
    if (legacy == nullptr) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'wglCreateContext returned null',
        detail: 'the device context has no pixel format, or the one it has '
            'does not support OpenGL',
      ));
      return GlContextAttempt(null, diagnostics);
    }
    if (api.makeCurrent(deviceContext, legacy) == 0) {
      api.deleteContext(legacy);
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the bootstrap GL context could not be made current',
      ));
      return GlContextAttempt(null, diagnostics);
    }

    final resolver = _wglResolver(api, heap);
    final createAttribs = resolver('wglCreateContextAttribsARB');
    var context = legacy;
    var description = 'WGL legacy context';
    if (createAttribs != nullptr) {
      final modern = _createModernWgl(
        createAttribs
            .cast<
                NativeFunction<
                    Pointer<Void> Function(
                        IntPtr, Pointer<Void>, Pointer<Int32>)>>()
            .asFunction<
                Pointer<Void> Function(int, Pointer<Void>, Pointer<Int32>)>(),
        heap,
        deviceContext,
      );
      if (modern != null) {
        // Unbind before deleting: deleting the current context is legal and
        // leaves the driver holding it until the thread exits.
        api
          ..makeCurrent(0, nullptr)
          ..deleteContext(legacy);
        if (api.makeCurrent(deviceContext, modern.$1) == 0) {
          api.deleteContext(modern.$1);
          diagnostics.add(const BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'the core-profile GL context could not be made current',
          ));
          return GlContextAttempt(null, diagnostics);
        }
        context = modern.$1;
        description = 'WGL ${modern.$2} context';
      } else {
        // Not fatal. A driver that refuses a core profile still runs this
        // renderer's shaders through the compatibility profile, and saying so
        // is more useful than failing on a machine that would have worked.
        diagnostics.add(const BackendDiagnostic.note(
          'wglCreateContextAttribsARB refused a 3.3 core profile; '
          'continuing on the compatibility context',
        ));
      }
    } else {
      diagnostics.add(const BackendDiagnostic.note(
        'WGL_ARB_create_context is absent; the context is whatever version '
        'wglCreateContext gave, which on a modern driver is still 4.x '
        'compatibility',
      ));
    }

    return GlContextAttempt(
      _WglContext(
        api: api,
        heap: heap,
        deviceContext: deviceContext,
        context: context,
        description: '$description on device context '
            '0x${deviceContext.toUnsigned(64).toRadixString(16)}',
      ),
      diagnostics,
    );
  }

  /// Versions asked for, highest first, down to the one that is required.
  ///
  /// The renderer's GLSL is `#version 330 core`, so 3.3 is the floor and the
  /// last entry must stay 3.3. The higher entries are not needed and are
  /// asked for anyway, because a driver hands back *exactly* the version
  /// requested rather than the best it has, and reporting "GL 3.3" on a
  /// machine that offers 4.6 makes every later capability question harder to
  /// answer. Nothing above 3.3 is used; the ladder only affects what the
  /// context calls itself.
  static const List<List<int>> _wglVersionLadder = <List<int>>[
    <int>[4, 6],
    <int>[3, 3],
  ];

  /// Walks the ladder in core profile, then retries 3.3 with no profile mask.
  ///
  /// Returns the context and the version string that produced it, or null.
  (Pointer<Void>, String)? _createModernWgl(
    Pointer<Void> Function(int, Pointer<Void>, Pointer<Int32>) create,
    NativeHeap heap,
    int deviceContext,
  ) {
    final attribs = heap.allocateInt32(16);
    try {
      for (final version in _wglVersionLadder) {
        attribs[0] = _wglContextMajorVersion;
        attribs[1] = version[0];
        attribs[2] = _wglContextMinorVersion;
        attribs[3] = version[1];
        attribs[4] = _wglContextProfileMask;
        attribs[5] = _wglContextCoreProfileBit;
        attribs[6] = 0;
        final core = create(deviceContext, nullptr, attribs);
        if (core != nullptr) {
          return (core, '${version[0]}.${version[1]} core');
        }
      }

      // A driver that has no core profile at all still runs this renderer:
      // the compatibility profile is a superset. Only refusing 3.3 outright
      // is fatal, and that is handled by the caller.
      attribs[0] = _wglContextMajorVersion;
      attribs[1] = 3;
      attribs[2] = _wglContextMinorVersion;
      attribs[3] = 3;
      attribs[4] = 0;
      final compatibility = create(deviceContext, nullptr, attribs);
      if (compatibility != nullptr) return (compatibility, '3.3');
      return null;
    } finally {
      heap.release(attribs);
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
    final attribs = heap.allocateInt32(16);
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

  /// `eglCreateWindowSurface(display, config, EGLNativeWindowType, attribs)`.
  ///
  /// The native window is declared `IntPtr` and not a pointer, because
  /// `EGLNativeWindowType` is not one thing: on the X11 platform it is a
  /// `Window`, an XID, which is a 32-bit value carried in a `long`; on Wayland
  /// it is a `struct wl_egl_window*`; on Android an `ANativeWindow*`. All of
  /// them are word-sized, and `IntPtr` is the only Dart type that is
  /// word-sized on every one of them without this file having to name a
  /// window type - which `test/architecture/layering_test.dart` forbids
  /// anyway.
  late final Pointer<Void> Function(
          Pointer<Void>, Pointer<Void>, int, Pointer<Int32>)
      createWindowSurface = library.lookupFunction<
          Pointer<Void> Function(
              Pointer<Void>, Pointer<Void>, IntPtr, Pointer<Int32>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int,
              Pointer<Int32>)>('eglCreateWindowSurface');

  /// `eglSwapBuffers(display, surface)`. The whole point of a window surface.
  late final int Function(Pointer<Void>, Pointer<Void>) swapBuffers =
      library.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>)>('eglSwapBuffers');

  /// `eglSwapInterval(display, interval)`.
  ///
  /// Unlike WGL's, this is core EGL rather than an extension, so it always
  /// resolves - but it is still allowed to fail, and a driver that clamps the
  /// interval reports success while ignoring the value.
  late final int Function(Pointer<Void>, int) swapInterval =
      library.lookupFunction<Int32 Function(Pointer<Void>, Int32),
          int Function(Pointer<Void>, int)>('eglSwapInterval');

  /// `eglQuerySurface(display, surface, attribute, out)`.
  ///
  /// Used to ask what size the driver thinks a window surface is, which is the
  /// only reliable way to find out whether it tracked a resize or not.
  late final int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Int32>)
      querySurface = library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>, Int32, Pointer<Int32>),
          int Function(Pointer<Void>, Pointer<Void>, int,
              Pointer<Int32>)>('eglQuerySurface');

  /// `eglGetConfigAttrib(display, config, attribute, out)`.
  late final int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Int32>)
      getConfigAttrib = library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>, Int32, Pointer<Int32>),
          int Function(Pointer<Void>, Pointer<Void>, int,
              Pointer<Int32>)>('eglGetConfigAttrib');

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

  late final Pointer<Void> Function(Pointer<Uint8>) getProcAddress =
      library.lookupFunction<Pointer<Void> Function(Pointer<Uint8>),
          Pointer<Void> Function(Pointer<Uint8>)>('eglGetProcAddress');
}

/// An EGL context, over a pbuffer or over a window.
///
/// One class for both because everything except the surface is identical, and
/// because being the [GlSwapChain] as well as the [GlContext] is the honest
/// shape: on EGL the thing that swaps is the surface the context is bound to,
/// so splitting them would mean two objects with the same lifetime, one of
/// which is only valid while the other is current.
///
/// A pbuffer context implements [GlSwapChain] too - it has to, they are the
/// same class - and refuses every call with a diagnostic rather than
/// pretending. [presentsToWindow] is how a caller tells the two apart before
/// asking.
final class _EglContext implements GlContext, GlSwapChain {
  _EglContext({
    required _EglApi api,
    required Pointer<Void> display,
    required Pointer<Void> surface,
    required Pointer<Void> context,
    required NativeHeap heap,
    required DynamicLibrary glLibrary,
    required this.isDesktopGl,
    required this.description,
    this.presentsToWindow = false,
  })  : _api = api,
        _display = display,
        _surface = surface,
        _context = context,
        _heap = heap,
        _libraryResolver = libraryProcResolver(glLibrary);

  final _EglApi _api;
  final Pointer<Void> _display;
  final Pointer<Void> _surface;
  final Pointer<Void> _context;
  final NativeHeap _heap;
  final GlProcResolver _libraryResolver;

  @override
  final bool isDesktopGl;

  @override
  final bool presentsToWindow;

  @override
  final String description;

  bool _disposed = false;

  @override
  bool get isPresentable => !_disposed && presentsToWindow;

  @override
  bool swapBuffers() {
    if (!isPresentable) return false;
    return _api.swapBuffers(_display, _surface) != 0;
  }

  @override
  bool setSwapInterval(int interval) {
    if (!isPresentable) return false;
    // eglSwapInterval is defined against the surface currently bound to the
    // calling thread's context, so the context has to be current first. Doing
    // it here rather than requiring it of the caller keeps the GlSwapChain
    // interface free of a precondition only one implementation has.
    if (!makeCurrent()) return false;
    return _api.swapInterval(_display, interval) != 0;
  }

  /// An EGL window surface tracks its native window, so this normally has
  /// nothing to do - and it verifies that instead of assuming it.
  ///
  /// The verification is the point. `eglQuerySurface` reports what the driver
  /// believes the surface is, and a driver that has not noticed the resize
  /// answers with the old size; rendering a frame at the new size into it
  /// produces a scaled or clipped image with no error anywhere. Reporting the
  /// disagreement turns that into a named failure, which the target escalates
  /// to device loss.
  ///
  /// It deliberately does *not* destroy and recreate the surface to force the
  /// issue. Recreating an EGL surface invalidates every binding made against
  /// it and has to be followed by a fresh `eglMakeCurrent`; doing that on
  /// every resize, on the overwhelming majority of drivers that did not need
  /// it, would trade a rare bug for a common one.
  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    if (!isPresentable) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'this EGL surface cannot be resized',
        detail: 'it is a pbuffer or it has been disposed, so it has no window '
            'whose size it could follow',
      );
    }
    final slot = _heap.allocateInt32(2);
    try {
      slot[0] = -1;
      slot[1] = -1;
      final gotWidth = _api.querySurface(_display, _surface, _eglWidth, slot);
      final gotHeight =
          _api.querySurface(_display, _surface, _eglHeight, slot + 1);
      if (gotWidth == 0 || gotHeight == 0) {
        // Not fatal by itself: a driver that will not answer the query may
        // still be tracking the window correctly. Reported as a note-free
        // null so the frame goes on, because refusing to draw over a failed
        // *query* would be worse than the bug it is looking for.
        return null;
      }
      if (slot[0] == pixelWidth && slot[1] == pixelHeight) return null;
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the EGL window surface did not follow its window',
        detail: 'the window is ${pixelWidth}x$pixelHeight but the driver '
            'reports the surface as ${slot[0]}x${slot[1]}; drawing into it '
            'would be scaled or clipped with no error reported',
      );
    } finally {
      _heap.release(slot);
    }
  }

  /// The export table first, `eglGetProcAddress` second.
  ///
  /// That order and not the reverse: a Mesa `libGL.so` exports every entry
  /// point this renderer uses, and `eglGetProcAddress` on EGL versions before
  /// 1.5 is only *required* to answer for extensions - so asking it first
  /// finds nothing on exactly the driver the CI runs.
  @override
  GlProcResolver get procAddress => (String name) {
        final exported = _libraryResolver(name);
        if (exported != nullptr) return exported;
        final native = _heap.allocateUtf8(name);
        try {
          return _api.getProcAddress(native);
        } on Object {
          return nullptr;
        } finally {
          _heap.release(native);
        }
      };

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

// ---------------------------------------------------------------------------
// WGL
// ---------------------------------------------------------------------------

/// The four WGL entry points, all exported by the GL library itself.
///
/// Device contexts cross this boundary as `IntPtr`, never as a named platform
/// type: the value is a number to everything in this directory.
final class _WglApi {
  _WglApi(DynamicLibrary library)
      : createContext = library.lookupFunction<Pointer<Void> Function(IntPtr),
            Pointer<Void> Function(int)>('wglCreateContext'),
        makeCurrent = library.lookupFunction<
            Int32 Function(IntPtr, Pointer<Void>),
            int Function(int, Pointer<Void>)>('wglMakeCurrent'),
        deleteContext = library.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('wglDeleteContext'),
        getProcAddress = library.lookupFunction<
            Pointer<Void> Function(Pointer<Uint8>),
            Pointer<Void> Function(Pointer<Uint8>)>('wglGetProcAddress'),
        exports = libraryProcResolver(library);

  final Pointer<Void> Function(int) createContext;
  final int Function(int, Pointer<Void>) makeCurrent;
  final int Function(Pointer<Void>) deleteContext;
  final Pointer<Void> Function(Pointer<Uint8>) getProcAddress;

  /// The GL library's own export table: OpenGL 1.1 and the WGL functions.
  final GlProcResolver exports;
}

/// The driver first, the DLL's exports second.
///
/// Both halves are needed and neither is enough. `wglGetProcAddress` knows
/// every entry point added since OpenGL 1.1 and is documented to return null
/// for the 1.1 functions themselves, because those are dispatched by the
/// system DLL rather than the driver - so `glGetError`, `glViewport`,
/// `glTexImage2D` and a dozen more come from the export table. Modern drivers
/// often answer for both, and some ancient ones signal failure with 1, 2, 3
/// or -1 instead of null, which is why the sentinel check exists: casting one
/// of those to a function pointer and calling it is an immediate crash with
/// no diagnostic.
GlProcResolver _wglResolver(_WglApi api, NativeHeap heap) => (String name) {
      final native = heap.allocateUtf8(name);
      Pointer<Void> address;
      try {
        address = api.getProcAddress(native);
      } on Object {
        address = nullptr;
      } finally {
        heap.release(native);
      }
      if (_isRealProcAddress(address)) return address;
      return api.exports(name);
    };

bool _isRealProcAddress(Pointer<Void> address) {
  final value = address.address;
  return value != 0 &&
      value != 1 &&
      value != 2 &&
      value != 3 &&
      value != 0xFFFFFFFF &&
      value != -1;
}

final class _WglContext implements GlContext {
  _WglContext({
    required _WglApi api,
    required NativeHeap heap,
    required int deviceContext,
    required Pointer<Void> context,
    required this.description,
  })  : _api = api,
        _deviceContext = deviceContext,
        _context = context,
        _resolver = _wglResolver(api, heap);

  final _WglApi _api;
  final int _deviceContext;
  final Pointer<Void> _context;
  final GlProcResolver _resolver;

  @override
  final String description;

  /// Always true: WGL is desktop OpenGL by construction, so the renderer's
  /// GLSL 330 dialect is the right one.
  @override
  bool get isDesktopGl => true;

  /// Always true, and that is not the same as "always useful".
  ///
  /// A WGL context is created from a device context, and the only device
  /// context that can carry a pixel format is a window's - so every WGL
  /// context this framework makes is bound to a window's back buffer and
  /// `SwapBuffers` on it does present. What the window does with those pixels
  /// is a separate question: `Win32GlSurface.hidden` deliberately never calls
  /// `ShowWindow`, so its swaps go to a window nobody can see. That is a
  /// property of the window, not of the context, and this file cannot see it.
  @override
  bool get presentsToWindow => true;

  @override
  GlProcResolver get procAddress => _resolver;

  bool _disposed = false;

  @override
  bool makeCurrent() {
    if (_disposed) return false;
    return _api.makeCurrent(_deviceContext, _context) != 0;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _api
      ..makeCurrent(0, nullptr)
      ..deleteContext(_context);
  }
}
