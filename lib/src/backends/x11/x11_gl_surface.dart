/// EGL over an X11 window, so the GL backend can present on Linux.
///
/// The X11 backend already presents CPU framebuffers - `x11_cpu_presenter.dart`
/// pushes them with `PutImage`. This is the other half: a GL context whose
/// default framebuffer *is* the window's back buffer, so a `GlWindowTarget`
/// can draw and swap without a readback.
///
/// ## Why EGL and not GLX
///
/// GLX needs an Xlib `Display*`. This backend speaks xcb, and the two are only
/// interchangeable through `XGetXCBConnection`, which means linking Xlib *and*
/// libX11-xcb next to the xcb this file already loads, and inheriting Xlib's
/// global error handler along with them. EGL takes the window as an XID -
/// exactly the `xcb_window_t` this file already has - and is what
/// `gl_context.dart` already documents as the supported Linux path.
///
/// ## The visual, which is the thing that goes wrong
///
/// An `EGLSurface` over an X11 window requires the window's visual to match
/// the chosen config's `EGL_NATIVE_VISUAL_ID`. The X server enforces it and
/// the failure is `EGL_BAD_MATCH` from `eglCreateWindowSurface` - not a
/// rendering artefact, a hard refusal at creation time, which is the good
/// outcome. `X11Connection` creates its windows with the screen's root visual,
/// which on a modern Mesa/X.Org pairing is a 24- or 32-bit TrueColor visual
/// that the 8/8/8/8 config this framework asks for normally matches. When it
/// does not, [X11GlSurface.forWindow] reports both numbers so the mismatch is
/// a diagnostic rather than a mystery, and it does **not** try to recover:
/// recovering means recreating the window with the config's visual, and the
/// window belongs to whoever made it.
///
/// ## Not executed
///
/// This file was written on Windows and has never been run. Every X11 test in
/// `test/rendering/gpu/gl_window_target_test.dart` that would exercise it is
/// skipped off Linux with that reason stated, and the compile-time contract -
/// that it implements `GlSwapChain` and hands the renderer nothing but
/// integers - is all that has actually been verified. Treat the first Linux
/// run as the real test.
library;

import 'dart:ffi';
import 'dart:io';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/gpu/gl/gl_bindings.dart';
import '../../rendering/gpu/gl/gl_context.dart';
import '../../rendering/gpu/gl/gl_surface_descriptor.dart';

/// What [X11GlSurface.forWindow] found.
final class X11GlSurfaceAttempt {
  const X11GlSurfaceAttempt(this.surface, this.diagnostics);

  /// Null when no surface could be created; [diagnostics] then says why.
  final X11GlSurface? surface;

  final List<BackendDiagnostic> diagnostics;
}

/// A GL context and swap chain over an X11 window.
///
/// Implements [GlSwapChain] by delegating to the EGL context created for the
/// window: on EGL the object that swaps *is* the surface the context is bound
/// to, so there is nothing to add here beyond forwarding. This class exists
/// anyway, rather than the X11 backend handing the raw context to the
/// renderer, because it is the place the X11-specific failure - the visual
/// mismatch - gets named, and because the window handle must not leave here as
/// anything but an integer.
final class X11GlSurface implements GlSwapChain {
  X11GlSurface._({
    required this.context,
    required GlSwapChain swapChain,
    required this.glLibrary,
    required this.xcbWindow,
    required this.configVisualId,
  }) : _swapChain = swapChain;

  /// The GL context. Hand it to `GlRendererBackend.adoptContext`, which takes
  /// ownership of it - and therefore of the EGL surface underneath.
  final GlContext context;

  final GlSwapChain _swapChain;

  /// The already-open GL library, so the caller does not open it twice.
  final DynamicLibrary glLibrary;

  /// The window, as the opaque integer the renderer is allowed to see.
  final int xcbWindow;

  /// The native visual the EGL config wanted, or null when EGL would not say.
  ///
  /// Kept after a *successful* creation as well as reported on failure,
  /// because "it worked and here is the visual it agreed on" is what a bug
  /// report needs when the same code fails on a different machine.
  final int? configVisualId;

  bool _disposed = false;

  /// Creates an EGL window surface and a context over [xcbWindow].
  ///
  /// [xcbWindow] is the XID of a window that must already exist and should
  /// already be mapped: EGL is allowed to create a surface for an unmapped
  /// window, but the first swap on one is a no-op on some drivers and an error
  /// on others, and neither is worth guessing about.
  ///
  /// [windowVisualId], when given, is compared against the config's and a
  /// mismatch is reported as a note *before* the surface is attempted, so a
  /// later `EGL_BAD_MATCH` arrives with its cause already in the diagnostics
  /// rather than needing to be inferred from it. It is optional because
  /// `X11Window` does not expose the visual it used; the connection does.
  ///
  /// Never throws. Every failure is a diagnostic.
  static X11GlSurfaceAttempt forWindow(
    int xcbWindow, {
    int? windowVisualId,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    if (!Platform.isLinux) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.unsupportedPlatform,
        message: 'the X11 GL surface is for Linux',
        detail: 'this process is on ${Platform.operatingSystem}; on Windows '
            'the equivalent is Win32GlSurface.forWindow',
      ));
      return X11GlSurfaceAttempt(null, diagnostics);
    }
    if (xcbWindow == 0) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'a null window id cannot carry an EGL surface',
      ));
      return X11GlSurfaceAttempt(null, diagnostics);
    }

    final load = GlLibrary.open();
    if (!load.isLoaded) {
      diagnostics.add(BackendDiagnostic.missingLibrary(
        load.attempted.join(', '),
        detail: load.error,
      ));
      return X11GlSurfaceAttempt(null, diagnostics);
    }

    final attempt = const GlContextFactory().createForWindowSurface(
      nativeWindow: xcbWindow,
      glLibrary: load.library!,
    );
    diagnostics.addAll(attempt.diagnostics);

    final visual = attempt.nativeVisualId;
    if (windowVisualId != null && visual != null && windowVisualId != visual) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the window and the EGL config disagree about the visual',
        detail: 'the window was created with visual 0x'
            '${windowVisualId.toUnsigned(32).toRadixString(16)} and the '
            'config wants 0x${visual.toUnsigned(32).toRadixString(16)}; the X '
            'server refuses that pairing, and the fix is to create the window '
            "with the config's visual",
      ));
    }

    final context = attempt.context;
    final swapChain = attempt.swapChain;
    if (context == null || swapChain == null) {
      return X11GlSurfaceAttempt(null, diagnostics);
    }

    return X11GlSurfaceAttempt(
      X11GlSurface._(
        context: context,
        swapChain: swapChain,
        glLibrary: load.library!,
        xcbWindow: xcbWindow,
        configVisualId: visual,
      ),
      diagnostics,
    );
  }

  /// Describes this window to the renderer.
  ///
  /// Mirrors `Win32GlSurface.describeSurface` argument for argument, which is
  /// the point: `GlWindowTarget` is handed the same descriptor on both
  /// platforms and contains no branch for either.
  ///
  /// [generation] should be the window's own token so a resize invalidates
  /// in-flight frames. `X11Window` keeps its `GenerationToken` private and
  /// exposes only `generation` as an int, so there is nothing to pass today
  /// and a fresh token is created - which means a target built this way will
  /// not hear about a resize until somebody calls `resize` on it. That is a
  /// gap in `x11_window.dart`, not here, and it is recorded rather than worked
  /// around with a second counter that could disagree with the window's.
  GlWindowSurfaceDescriptor describeSurface({
    required int pixelWidth,
    required int pixelHeight,
    double scale = 1.0,
    GenerationToken? generation,
    PixelFormat format = PixelFormat.rgba8888Premultiplied,
  }) =>
      GlWindowSurfaceDescriptor(
        nativeHandle: xcbWindow,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        swapChain: this,
        generation: generation ?? GenerationToken(),
        scale: scale,
        format: format,
        description: 'X11 window, EGL window surface'
            '${configVisualId == null ? '' : ', visual 0x'
                '${configVisualId!.toUnsigned(32).toRadixString(16)}'}',
      );

  @override
  bool get isPresentable => !_disposed && _swapChain.isPresentable;

  @override
  bool swapBuffers() => !_disposed && _swapChain.swapBuffers();

  @override
  bool setSwapInterval(int interval) =>
      !_disposed && _swapChain.setSwapInterval(interval);

  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    if (_disposed) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'this X11 GL surface was disposed and cannot be resized',
      );
    }
    return _swapChain.reconfigure(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }

  /// Marks the surface unusable. Does **not** destroy the window or the
  /// context.
  ///
  /// The EGL surface belongs to [context], and the context belongs to whoever
  /// adopted it - `GlRendererBackend.adoptContext` takes ownership and the
  /// device disposes it. Disposing it here as well would be the double free
  /// that `lib/src/foundation/lifecycle.dart` exists to prevent. The window
  /// belongs to `X11Window`, which outlives every renderer over it.
  void dispose() {
    _disposed = true;
  }
}
