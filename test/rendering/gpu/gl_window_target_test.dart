/// The windowed GL target, against a real driver where there is one.
///
/// `gl_device_test.dart` covers the offscreen target and can check its work by
/// reading the pixels back. This file cannot: the whole point of
/// [GlWindowTarget] is that nothing reads pixels back, so what is asserted
/// here is the contract around the swap rather than the image it produced -
/// that a present reaches `SwapBuffers` and reports success, that a frame
/// recorded before a resize is refused, that a dead window becomes a named
/// failure and not a crash, and that the probe now tells the truth about this
/// machine.
///
/// The window is a real `HWND`. `Win32GlSurface.hidden` makes one and never
/// shows it, which is what `test/backends/win32` does throughout: a hidden
/// window has a valid device context, a valid pixel format and a real
/// double-buffered back buffer, and `SwapBuffers` on it does everything it
/// would do on a visible one except reach a monitor. That is exactly the part
/// under test.
///
/// The X11 path is **not covered by anything that runs**. It is written, it
/// compiles, and the tests that would exercise it skip with that reason
/// stated - this suite is developed on Windows. See
/// `lib/src/backends/x11/x11_gl_surface.dart`.
library;

import 'dart:io';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/backends/x11/x11_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_window_target.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  group('the surface descriptor', () {
    test('carries the window as an opaque integer and keeps its token', () {
      final token = GenerationToken();
      final chain = _FakeSwapChain();
      final surface = GlWindowSurfaceDescriptor(
        nativeHandle: 0xDEADBEEF,
        pixelWidth: 320,
        pixelHeight: 200,
        swapChain: chain,
        generation: token,
        scale: 2.0,
      );

      expect(surface.kind, 'gl-window');
      expect(surface.nativeHandle, 0xDEADBEEF);
      expect(surface.scale, 2.0);
      // The window's token, not a copy of its value. A snapshot would be a
      // number that was true once, which is the bug the shared token exists
      // to prevent.
      token.invalidate();
      expect(surface.generation.current, token.current);
    });

    test('resizing shares the window, the chain and the token', () {
      final token = GenerationToken();
      final chain = _FakeSwapChain();
      final surface = GlWindowSurfaceDescriptor(
        nativeHandle: 7,
        pixelWidth: 100,
        pixelHeight: 50,
        swapChain: chain,
        generation: token,
      );
      final bigger = surface.resized(pixelWidth: 200, pixelHeight: 100);

      expect(bigger.pixelWidth, 200);
      expect(bigger.pixelHeight, 100);
      expect(bigger.nativeHandle, 7);
      expect(identical(bigger.swapChain, chain), isTrue);
      expect(identical(bigger.generation, token), isTrue);
    });
  });

  group('a live windowed GL target', () {
    final session = _WindowSession.open();
    tearDownAll(session.close);

    test('creates a target over a real window handle', () {
      final target = session.target(64, 48);
      expect(target.surface.nativeHandle, session.surface!.windowHandle);
      expect(target.surface.pixelWidth, 64);
      expect(target.surface.pixelHeight, 48);
      target.dispose();
    }, skip: session.skipReason);

    test('present swaps the back buffer instead of reading it back', () async {
      final target = session.target(64, 48);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
      list.drawRect(4, 4, 40, 30, paint);

      final result =
          await target.renderDisplayList(list, clearColor: 0xFF102030);

      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(session.surface!.swapCount, greaterThan(0),
          reason: 'a windowed present that never reaches SwapBuffers is the '
              'readback path wearing a different name');
      target.dispose();
    }, skip: session.skipReason);

    test('several frames in a row each swap once', () async {
      final target = session.target(32, 32);
      final before = session.surface!.swapCount;
      for (var i = 0; i < 3; i++) {
        final result = await target.renderDisplayList(
          DisplayList(),
          clearColor: 0xFF000000 | i,
        );
        expect(result.status, PresentStatus.presented);
      }
      expect(session.surface!.swapCount - before, 3);
      target.dispose();
    }, skip: session.skipReason);

    test('a frame from before a resize is refused, not drawn', () async {
      final target = session.target(64, 48);
      final frame =
          target.beginFrame(const FrameRequest(clearColor: 0xFF000000));
      final swapsBefore = session.surface!.swapCount;

      target.resize(96, 72, 1.0);
      final result = await target.present(frame);

      expect(result.status, PresentStatus.stale);
      expect(result.diagnostic, isNotNull);
      expect(session.surface!.swapCount, swapsBefore,
          reason: 'a stale frame must not reach the window system at all');
      // And the target still works afterwards: stale is not an error state.
      final next =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(next.status, PresentStatus.presented);
      target.dispose();
    }, skip: session.skipReason);

    test('a frame from before the window invalidated itself is refused',
        () async {
      // The case a target-local counter cannot catch: the window resized and
      // nobody told the target. The shared GenerationToken is what makes it
      // visible.
      final token = GenerationToken();
      final target = session.target(64, 48, token: token);
      final frame = target.beginFrame(const FrameRequest());

      token.invalidate();

      expect(target.needsResize, isTrue);
      final result = await target.present(frame);
      expect(result.status, PresentStatus.stale);
      expect(result.diagnostic!.detail, contains('resize()'));

      // Reconciling with the window's new size clears it, and frames flow.
      target.resize(64, 48, 1.0);
      expect(target.needsResize, isFalse);
      final next =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(next.status, PresentStatus.presented);
      target.dispose();
    }, skip: session.skipReason);

    test('resize changes the viewport the next frame is drawn at', () async {
      final target = session.target(32, 32);
      expect(target.surface.pixelWidth, 32);

      target.resize(80, 60, 2.0);

      expect(target.surface.pixelWidth, 80);
      expect(target.surface.pixelHeight, 60);
      expect(target.surface.scale, 2.0);
      // The window handle and the swap chain survive a resize: a window that
      // was resized is the same window.
      expect(target.surface.nativeHandle, session.surface!.windowHandle);
      final result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF204060);
      expect(result.status, PresentStatus.presented);
      target.dispose();
    }, skip: session.skipReason);

    test('a resize to the same size with no invalidation is a no-op', () {
      final target = session.target(40, 40);
      final generation = target.generation;
      target.resize(40, 40, 1.0);
      expect(target.generation, generation);
      target.dispose();
    }, skip: session.skipReason);

    test('a zero-sized resize is refused', () {
      final target = session.target(40, 40);
      expect(() => target.resize(0, 40, 1.0), throwsA(isA<ArgumentError>()));
      target.dispose();
    }, skip: session.skipReason);

    test('a swap chain that refuses reports a named failure', () async {
      // Not a mock of the window: a real target over a real device, with a
      // swap chain that says no. The point is that a refusal at the very last
      // step is a PresentResult with a diagnostic, not an exception and not a
      // silent success.
      final chain = _FakeSwapChain()..presentable = false;
      final target = GlWindowTarget(
        session.device!,
        GlWindowSurfaceDescriptor(
          nativeHandle: session.surface!.windowHandle,
          pixelWidth: 32,
          pixelHeight: 32,
          swapChain: chain,
          generation: GenerationToken(),
        ),
      );

      final result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(result.status, PresentStatus.failed);
      expect(result.diagnostic!.message, contains('window is gone'));
      expect(chain.swapCount, 0);

      chain
        ..presentable = true
        ..succeed = false;
      final refused =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(refused.status, PresentStatus.failed);
      expect(refused.diagnostic!.message, contains('refused to swap'));
      expect(chain.swapCount, 1);
      target.dispose();
    }, skip: session.skipReason);

    test('the device refuses a descriptor it cannot present to', () {
      expect(
        () => session.device!.createTarget(const _AlienSurface()),
        throwsA(
          isA<UnsupportedCapabilityError>().having(
            (error) => error.capability,
            'capability',
            Capability.gpuPresentation,
          ),
        ),
      );
    }, skip: session.skipReason);

    test('the same device still builds offscreen targets', () {
      // The window path must not have taken the offscreen one with it: both
      // descriptors go to the same createTarget and produce different classes.
      final target = session.device!.createTarget(const MemorySurfaceDescriptor(
        pixelWidth: 8,
        pixelHeight: 8,
        format: PixelFormat.rgba8888Premultiplied,
      ));
      expect(target, isA<GlOffscreenTarget>());
      target.dispose();
    }, skip: session.skipReason);

    test('the backend accepts a window descriptor', () {
      const backend = GlRendererBackend();
      expect(
        backend.supportsSurface(GlWindowSurfaceDescriptor(
          nativeHandle: 1,
          pixelWidth: 4,
          pixelHeight: 4,
          swapChain: _FakeSwapChain(),
          generation: GenerationToken(),
        )),
        isTrue,
      );
    });

    test('the swap interval can be asked for, and the answer is honest', () {
      // Either outcome is correct: a driver without WGL_EXT_swap_control
      // returns false rather than pretending vsync is on. What is asserted is
      // that it answers at all rather than throwing, because it is called from
      // the frame loop.
      final target = session.target(16, 16);
      final answer = target.swapChain.setSwapInterval(0);
      expect(answer, anyOf(isTrue, isFalse));
      printOnFailure('setSwapInterval(0) -> $answer');
      target.dispose();
    }, skip: session.skipReason);
  });

  group('adopting a window', () {
    test('a null handle is refused by name', () {
      final attempt = Win32GlSurface.forWindow(0);
      expect(attempt.surface, isNull);
      expect(
        attempt.diagnostics.map((d) => d.message).join('; '),
        contains('null window handle'),
      );
    }, skip: _windowsOnly);

    test('a handle that is not a window is refused by name', () {
      // 0x1234 is not an HWND. The check is IsWindow, and the point is that
      // this fails with a diagnostic rather than inside GetDC.
      final attempt = Win32GlSurface.forWindow(0x1234);
      expect(attempt.surface, isNull);
      expect(
        attempt.diagnostics.map((d) => d.message).join('; '),
        contains('not a live window'),
      );
    }, skip: _windowsOnly);

    test('a second adoption of the same window reuses its pixel format', () {
      // The trap the whole file documents: SetPixelFormat may be called once
      // per window. A second surface over the same window must adopt what is
      // there instead of trying again.
      final first = Win32GlSurface.hidden(className: 'DartUiGlAdoptTest');
      final surface = first.surface;
      if (surface == null) {
        markTestSkipped('no GL surface: ${first.diagnostics.join('; ')}');
        return;
      }
      try {
        final second = Win32GlSurface.forWindow(surface.windowHandle);
        expect(second.surface, isNotNull,
            reason: second.diagnostics.join('; '));
        expect(second.surface!.pixelFormat, surface.pixelFormat);
        expect(
          second.diagnostics.map((d) => d.message).join('; '),
          contains('already had pixel format'),
        );
        // And it did not take the window with it when it went.
        second.surface!.dispose();
        expect(
          Win32GlSurface.forWindow(surface.windowHandle).surface,
          isNotNull,
          reason: 'a borrowed window must survive its borrower',
        );
      } finally {
        surface.dispose();
      }
    }, skip: _windowsOnly);
  });

  group('the probe', () {
    test('reports what this machine can do about windows', () {
      final windowing = GlContextFactory.probeWindowPresentation();
      // Always a diagnostic, including on success: a probe that only explains
      // its failures leaves the successful case unauditable.
      expect(windowing.diagnostic.message, isNotEmpty);
      printOnFailure('${windowing.available}: ${windowing.diagnostic}');

      if (Platform.isWindows) {
        // opengl32.dll is present on every Windows this framework supports,
        // so anything but true here is a real regression rather than a
        // machine difference.
        expect(windowing.available, isTrue);
        expect(windowing.diagnostic.message, contains('WGL'));
      }
    });

    test('a windowed context claims gpuPresentation and vsync', () {
      final session = _WindowSession.open();
      addTearDown(session.close);
      if (session.skipReason != null) {
        markTestSkipped(session.skipReason ?? 'no windowed GL device');
        return;
      }

      final report = GlRendererBackend.describeContext(session.context!);
      expect(report.supported, isTrue, reason: report.describe());
      // The claim that did not exist before: this context can put pixels on a
      // screen without a readback.
      expect(report.supports(Capability.gpuPresentation), isTrue,
          reason: report.describe());
      expect(report.supports(Capability.vsync), isTrue);
      expect(report.supports(Capability.cpuPresentation), isTrue,
          reason: 'the same device still offers offscreen readback');
      expect(
        report.diagnostics.map((d) => d.message).join('\n'),
        contains('windowed presentation'),
        reason: 'the report used to say "offscreen only" unconditionally',
      );
    }, skip: _windowsOnly);
  });

  group('the X11 path', () {
    test('refuses to run off Linux instead of failing obscurely', () {
      final attempt = X11GlSurface.forWindow(1);
      if (Platform.isLinux) {
        // Nothing is asserted about the outcome here: this suite has never
        // been run on Linux and guessing what a display server would answer
        // is how a test becomes a lie. What matters is that it returned.
        printOnFailure('X11 attempt: ${attempt.diagnostics.join('; ')}');
        return;
      }
      expect(attempt.surface, isNull);
      expect(
          attempt.diagnostics.first.kind, DiagnosticKind.unsupportedPlatform);
    });

    test('creates an EGL window surface over an xcb window', () {
      // Deliberately left as a skip rather than deleted. The X11 path is
      // written and unexecuted, and a suite that simply omits it reads as if
      // it were covered.
    },
        skip: Platform.isLinux
            ? 'needs a mapped X11 window and a running display server; the '
                'X11 GL path has never been executed'
            : 'the X11 GL path needs a Linux display server and has never '
                'been executed - this suite runs on Windows');
  });
}

/// Skip reason for the tests that need a Win32 window, or null on Windows.
final String? _windowsOnly =
    Platform.isWindows ? null : 'the WGL path needs Windows';

/// One GL device over one hidden window, shared by the whole group.
///
/// The window is hidden for the reason `win32_gl_surface.dart` gives: a hidden
/// window owns a real device context, a real pixel format and a real
/// double-buffered back buffer. `SwapBuffers` on it exercises every line under
/// test; the only thing it does not do is reach a monitor, and a test that
/// needed it to would need a human to look at it.
final class _WindowSession {
  _WindowSession._(this.device, this.context, this.surface, this.skipReason);

  final GlRenderDevice? device;
  final GlContext? context;
  final _CountingSurface? surface;

  /// Null when the device opened; a string - which `skip:` accepts - when it
  /// did not, so the report names what was missing.
  final String? skipReason;

  static _WindowSession open() {
    if (!Platform.isWindows) {
      return _WindowSession._(
        null,
        null,
        null,
        'the windowed GL target is exercised through WGL, which needs Windows',
      );
    }
    try {
      final attempt = Win32GlSurface.hidden(className: 'DartUiGlWindowTarget');
      final surface = attempt.surface;
      if (surface == null) {
        return _WindowSession._(null, null, null,
            'no GL surface: ${attempt.diagnostics.join('; ')}');
      }
      final contextAttempt = surface.createContext();
      final context = contextAttempt.context;
      if (context == null) {
        surface.dispose();
        return _WindowSession._(null, null, null,
            'no GL context: ${contextAttempt.diagnostics.join('; ')}');
      }
      try {
        return _WindowSession._(
          GlRendererBackend.adoptContext(context, surface.glLibrary),
          context,
          _CountingSurface(surface),
          null,
        );
      } on BackendSelectionError catch (error) {
        surface.dispose();
        return _WindowSession._(null, null, null, 'no GL device: $error');
      }
    } on Object catch (error) {
      return _WindowSession._(
          null, null, null, 'opening a windowed GL device threw: $error');
    }
  }

  GlWindowTarget target(int width, int height, {GenerationToken? token}) =>
      device!.createTarget(surface!.describe(width, height, token))
          as GlWindowTarget;

  void close() {
    device?.dispose();
    surface?.inner.dispose();
  }
}

/// The real Win32 swap chain, with a counter around it.
///
/// A counter and not a substitute: every call goes through to `SwapBuffers`.
/// The number is how a test asserts that a present reached the window system,
/// which is the one thing a windowed target cannot prove by looking at pixels.
final class _CountingSurface implements GlSwapChain {
  _CountingSurface(this.inner);

  final Win32GlSurface inner;
  int swapCount = 0;

  int get windowHandle => inner.windowHandle;

  GlWindowSurfaceDescriptor describe(
    int width,
    int height,
    GenerationToken? token,
  ) =>
      GlWindowSurfaceDescriptor(
        nativeHandle: inner.windowHandle,
        pixelWidth: width,
        pixelHeight: height,
        swapChain: this,
        generation: token ?? GenerationToken(),
      );

  @override
  bool get isPresentable => inner.isPresentable;

  @override
  bool swapBuffers() {
    swapCount++;
    return inner.swapBuffers();
  }

  @override
  bool setSwapInterval(int interval) => inner.setSwapInterval(interval);

  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) =>
      inner.reconfigure(pixelWidth: pixelWidth, pixelHeight: pixelHeight);
}

/// A swap chain that can be told to refuse, for the failure paths.
final class _FakeSwapChain implements GlSwapChain {
  bool presentable = true;
  bool succeed = true;
  int swapCount = 0;
  int intervalRequests = 0;
  (int, int)? lastReconfigure;

  @override
  bool get isPresentable => presentable;

  @override
  bool swapBuffers() {
    swapCount++;
    return succeed;
  }

  @override
  bool setSwapInterval(int interval) {
    intervalRequests++;
    return succeed;
  }

  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    lastReconfigure = (pixelWidth, pixelHeight);
    return null;
  }
}

/// A descriptor from no backend at all, to check the refusal is by type and
/// not by a name compared against a string.
final class _AlienSurface implements NativeSurfaceDescriptor {
  const _AlienSurface();

  @override
  String get kind => 'alien';

  @override
  int get pixelWidth => 4;

  @override
  int get pixelHeight => 4;

  @override
  double get scale => 1.0;
}
