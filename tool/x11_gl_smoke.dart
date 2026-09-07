/// Runs the X11 OpenGL path against a real X server, which nothing had ever
/// done.
///
/// ## Why this file exists
///
/// `lib/src/backends/x11/x11_gl_surface.dart` says of itself: *"This file was
/// written on Windows and has never been run."*
/// `test/rendering/gpu/gl_window_target_test.dart` skips its X11 group with
/// the same sentence, and `default_platform_resolver.dart` wires `_x11OpenGl()`
/// into the presentation paths anyway. So the framework offers Linux users a
/// GPU path whose first execution would be theirs. This smoke moves that first
/// execution into CI.
///
/// A unit test cannot replace it, and this repository has a standing rule
/// about why: a headless run gives a **false green** for presentation. EGL is
/// the sharpest case of it. Everything this path can get wrong is a
/// negotiation with a server that a mock does not hold:
///
///   * `eglCreateWindowSurface` refuses with `EGL_BAD_MATCH` when the window's
///     visual is not the chosen config's `EGL_NATIVE_VISUAL_ID`, and the error
///     names neither number. `X11Connection` creates every window with the
///     screen's root visual - depth 24, no alpha, under Xvfb - while
///     `gl_context.dart` asks `eglChooseConfig` for `EGL_ALPHA_SIZE 8`. Those
///     two can simply fail to intersect, and no code path on Windows can find
///     out;
///   * `eglSwapBuffers` on an **unmapped** window is a no-op on some drivers
///     and an error on others, so the window has to be mapped and exposed
///     first - which means driving the real backend's event loop, not
///     constructing a surface in isolation;
///   * the mesh pipeline's GLSL is compiled by the driver, not by us. Whether
///     `GlMeshRenderer` links under llvmpipe is a fact only llvmpipe has.
///
/// ## What it reports
///
/// One `X11_GL_*` line per fact, so a single CI run answers the whole
/// question instead of five pushes each answering a fifth of it. Every failure
/// prints the full `BackendDiagnostic` list - kind, message and detail - and
/// the visual ids on both sides of the comparison.
///
/// Exit 0 when the whole path ran, **2 when this machine cannot host it**
/// (no Linux, no display, no EGL library) and 1 when EGL was present and
/// refused - because a driver that is there and says no is the measurement
/// this file was written to take, not an environment problem to shrug at.
///
/// ```
/// DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 dart run tool/x11_gl_smoke.dart
/// ```
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/x11/x11_backend.dart';
import 'package:dart_ui/src/backends/x11/x11_gl_surface.dart';
import 'package:dart_ui/src/backends/x11/x11_window.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_mesh_renderer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_window_target.dart';

/// Raised when the run cannot continue but nothing is wrong with the code.
///
/// Separate from a plain failure because the two exit codes mean opposite
/// things to whoever reads the CI log: 2 says "this runner has no EGL", 1 says
/// "this runner has EGL and our path did not work on it". Collapsing them
/// would let a missing package masquerade as a green run, or as a bug.
final class _Unavailable implements Exception {
  _Unavailable(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

const double _width = 320;
const double _height = 200;
const double _resizedWidth = 480;
const double _resizedHeight = 320;

Future<void> main() async {
  if (!Platform.isLinux) {
    stderr.writeln('X11_GL_SMOKE=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }
  if ((Platform.environment['DISPLAY'] ?? '').isEmpty) {
    stderr.writeln('X11_GL_SMOKE=SKIP reason=DISPLAY is not set');
    exitCode = 2;
    return;
  }

  final backend = X11WindowingBackend();
  NativeWindow? window;
  Object? failure;
  StackTrace? failureStack;

  try {
    await backend.initialize().timeout(const Duration(seconds: 10));
    window = await backend
        .createWindow(
          const WindowOptions(
            size: Size(_width, _height),
            title: 'dart_ui X11 EGL smoke',
          ),
        )
        .timeout(const Duration(seconds: 10));
    final x11Window = window as X11Window;

    // Mapped and exposed before EGL is asked for anything. `forWindow`
    // documents that a swap on an unmapped window is a no-op on some drivers
    // and an error on others, and a smoke that hit either would be measuring
    // the wrong thing.
    var exposed = false;
    final subscription =
        window.events.listen((event) => exposed |= event is WindowExposedEvent);
    try {
      await _pumpUntil(backend, () => exposed, const Duration(seconds: 5));
      stdout.writeln(
        'X11_GL_WINDOW=PASS xid=0x${x11Window.xcbWindow.toRadixString(16)} '
        'visual=0x${x11Window.visualId.toRadixString(16)} '
        'size=${x11Window.pixelSize.width}x${x11Window.pixelSize.height} '
        'exposed=true',
      );
      await _runGl(backend, x11Window);
    } finally {
      await subscription.cancel();
    }
    window.close();
  } on _Unavailable catch (error) {
    stderr.writeln('X11_GL_SMOKE=SKIP reason=$error');
    await _shutdown(backend);
    exitCode = 2;
    return;
  } on Object catch (error, stack) {
    failure = error;
    failureStack = stack;
  }

  try {
    await _shutdown(backend);
  } on Object catch (error, stack) {
    failure ??= error;
    failureStack ??= stack;
  }

  final captured = failure;
  if (captured != null) {
    stdout.writeln('X11_GL_SMOKE=FAIL $captured');
    Error.throwWithStackTrace(captured, failureStack ?? StackTrace.current);
  }
  stdout.writeln('X11_GL_SMOKE=PASS');
}

Future<void> _shutdown(X11WindowingBackend backend) =>
    backend.shutdown().timeout(const Duration(seconds: 10));

/// Everything from `eglCreateWindowSurface` to a mesh program, in order.
Future<void> _runGl(X11WindowingBackend backend, X11Window window) async {
  final X11GlSurfaceAttempt attempt = X11GlSurface.forWindow(
    window.xcbWindow,
    windowVisualId: window.visualId,
  );
  final X11GlSurface? surface = attempt.surface;
  if (surface == null) {
    _reportDiagnostics('X11_GL_EGL', attempt.diagnostics);
    // A refusal by a driver that is present is the answer this file came for,
    // so it is a failure and not a skip. Only "there is no libEGL here" is an
    // environment problem.
    if (_isMissingEnvironment(attempt.diagnostics)) {
      throw _Unavailable('no EGL on this machine: '
          '${_summarise(attempt.diagnostics)}');
    }
    stdout.writeln('X11_GL_EGL=FAIL ${_summarise(attempt.diagnostics)}');
    throw StateError('EGL is installed and refused the window surface');
  }
  // Notes are printed even on success: a visual mismatch that the driver
  // tolerated today is the first thing a bug report from another machine will
  // need, and it is invisible unless it is printed while things work.
  _reportDiagnostics('X11_GL_EGL', attempt.diagnostics);
  stdout.writeln(
    'X11_GL_EGL=PASS window_visual=0x${window.visualId.toRadixString(16)} '
    'config_visual=${surface.configVisualId == null ? 'unknown' : '0x'
        '${surface.configVisualId!.toRadixString(16)}'} '
    'desktop_gl=${surface.context.isDesktopGl} '
    'presents_to_window=${surface.context.presentsToWindow}',
  );
  stdout.writeln('X11_GL_CONTEXT=${surface.context.description}');

  GlRenderDevice? device;
  try {
    device = GlRendererBackend.adoptContext(surface.context, surface.glLibrary);
  } on Object catch (error) {
    stdout.writeln('X11_GL_DEVICE=FAIL $error');
    surface.dispose();
    rethrow;
  }

  try {
    if (!surface.context.makeCurrent()) {
      stdout.writeln('X11_GL_DEVICE=FAIL the adopted context would not go '
          'current on this thread');
      throw StateError('eglMakeCurrent failed after adoptContext');
    }
    final GlApi gl = device.api;
    stdout.writeln(
      'X11_GL_DEVICE=PASS vendor=${gl.stringOf(glVendor)} | '
      'renderer=${gl.stringOf(glRenderer)} | '
      'version=${gl.stringOf(glVersion)} | info=${device.info}',
    );

    _reportClear(gl, device.heap, window.pixelSize);
    await _reportPresent(device, surface, window);
    await _reportResize(backend, device, surface, window);
    _reportMesh(device);
  } finally {
    // The device owns the context, which owns the EGL surface: disposing the
    // device is what tears EGL down, and `X11GlSurface.dispose` only marks
    // this wrapper unusable. Doing it in the other order would use a freed
    // context, which is the double free `lifecycle.dart` exists to prevent.
    surface.dispose();
    device.dispose();
  }
}

/// Clears the default framebuffer and reads it back.
///
/// The one thing a windowed target can never prove about itself: that the
/// framebuffer the context is bound to is real memory a rasteriser wrote to.
/// `glReadPixels` before any swap answers it, and answers it about framebuffer
/// 0 - the window's back buffer - rather than about a texture we allocated.
void _reportClear(GlApi gl, NativeHeap heap, ({int width, int height}) size) {
  gl.drainErrors();
  gl.viewport(0, 0, size.width, size.height);
  // 0.25/0.50/0.75 are exact in 8-bit (64/128/191) up to the rounding rule, so
  // a mismatch here is a real difference and not a quantisation argument.
  gl.clearColor(0.25, 0.5, 0.75, 1.0);
  gl.clear(glColorBufferBit);
  gl.finish();
  final Pointer<Int32> pixel = heap.allocateInt32(1);
  try {
    pixel[0] = 0;
    gl.readPixels(size.width ~/ 2, size.height ~/ 2, 1, 1, glRgba,
        glUnsignedByte, pixel.cast<Void>());
    final int raw = pixel[0];
    final int r = raw & 0xFF;
    final int g = (raw >> 8) & 0xFF;
    final int b = (raw >> 16) & 0xFF;
    final int a = (raw >> 24) & 0xFF;
    final int error = gl.drainErrors();
    final bool ok = error == glNoError &&
        (r - 64).abs() <= 2 &&
        (g - 128).abs() <= 2 &&
        (b - 191).abs() <= 2;
    stdout.writeln(
      'X11_GL_CLEAR=${ok ? 'PASS' : 'FAIL'} rgba=$r,$g,$b,$a '
      'expected=64,128,191 gl_error=0x${error.toRadixString(16)}',
    );
    if (!ok) throw StateError('the default framebuffer did not clear');
  } finally {
    heap.release(pixel);
  }
}

/// Draws three frames through the production `GlWindowTarget` and swaps each.
Future<void> _reportPresent(
  GlRenderDevice device,
  X11GlSurface surface,
  X11Window window,
) async {
  final GlWindowTarget target = device.createTarget(
    surface.describeSurface(
      pixelWidth: window.pixelSize.width,
      pixelHeight: window.pixelSize.height,
      scale: window.renderScale,
    ),
  ) as GlWindowTarget;
  try {
    for (var i = 0; i < 3; i++) {
      final list = DisplayList();
      list.drawRect(
        8,
        8,
        _width - 16,
        _height - 16,
        list.addPaint(colorArgb: 0xFF3366CC | i),
      );
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF102030);
      if (!result.isSuccess) {
        stdout.writeln('X11_GL_PRESENT=FAIL frame=$i $result');
        throw StateError('$result');
      }
    }
    // Asked after the frames, not before: an `eglSwapInterval` that a driver
    // silently ignores is worth knowing about, and an interval set first would
    // have changed what the three frames measured.
    final bool unthrottled = surface.setSwapInterval(0);
    stdout.writeln('X11_GL_PRESENT=PASS frames=3 '
        'swap_interval_0=${unthrottled ? 'accepted' : 'refused'} '
        'presentable=${surface.isPresentable}');
  } finally {
    target.dispose();
  }
}

/// Resizes the window on the server and presents at the new size.
///
/// The resize is the half of a swap chain that offscreen rendering cannot
/// reach at all: EGL window surfaces on X11 track the drawable's size on their
/// own, and a target that kept the old viewport draws a correct frame into the
/// wrong corner - which looks like a rendering bug and is a sizing one.
Future<void> _reportResize(
  X11WindowingBackend backend,
  GlRenderDevice device,
  X11GlSurface surface,
  X11Window window,
) async {
  var resized = false;
  final subscription =
      window.events.listen((event) => resized |= event is WindowResizedEvent);
  // Sampled before the resize rather than compared against a literal: the
  // window's generation starts at 0 and one coalesced resize advances it by
  // exactly one, so the number that means "the surface was invalidated once"
  // depends on how many resizes came before. Asserting the delta says what is
  // actually meant; asserting `== 1` would have been a coincidence of this
  // smoke only ever resizing once.
  final int generationBefore = window.generation;
  try {
    window
        .setBounds(const Rect.fromLTWH(12, 14, _resizedWidth, _resizedHeight));
    await _pumpUntil(backend, () => resized, const Duration(seconds: 5));
    final ({int width, int height}) size = window.pixelSize;
    final int advanced = window.generation - generationBefore;
    if (advanced != 1) {
      stdout.writeln('X11_GL_RESIZE=FAIL generation moved by $advanced, not 1 '
          '(before=$generationBefore after=${window.generation}); a frame in '
          'flight across the resize would no longer be refused');
      throw StateError('the resize did not invalidate the window exactly once');
    }
    final BackendDiagnostic? refused = surface.reconfigure(
      pixelWidth: size.width,
      pixelHeight: size.height,
    );
    if (refused != null) {
      stdout.writeln('X11_GL_RESIZE=FAIL ${_format(refused)}');
      throw StateError(refused.message);
    }
    final GlWindowTarget target = device.createTarget(
      surface.describeSurface(
        pixelWidth: size.width,
        pixelHeight: size.height,
        scale: window.renderScale,
      ),
    ) as GlWindowTarget;
    try {
      final list = DisplayList();
      list.drawRect(
        0,
        0,
        size.width.toDouble(),
        size.height.toDouble(),
        list.addPaint(colorArgb: 0xFF20A060),
      );
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);
      if (!result.isSuccess) {
        stdout.writeln('X11_GL_RESIZE=FAIL $result');
        throw StateError('$result');
      }
      stdout.writeln(
        'X11_GL_RESIZE=PASS size=${size.width}x${size.height} '
        'generation=$generationBefore->${window.generation}',
      );
    } finally {
      target.dispose();
    }
  } finally {
    await subscription.cancel();
  }
}

/// Compiles and links the mesh program. **Linking is all this proves.**
///
/// The distance between "the program linked" and "the model draws correctly"
/// is where the Direct3D 11 port found its bugs, so the verdict is worded to
/// stop short of the claim it cannot support. What runs here: the vertex and
/// fragment sources go to the driver's GLSL compiler, every uniform and
/// attribute location resolves, and the pipeline object builds. What does
/// **not** run: a single triangle. No `MeshScene` is submitted, no depth
/// buffer is exercised, nothing is compared against the CPU mesh rasteriser,
/// and no frame contains a model. A `PASS` here means the shaders are valid
/// GLSL for this driver and nothing more.
///
/// Reported and not thrown on: the 2D path above is what decides whether this
/// backend can present at all, and a driver whose GLSL compiler rejects the
/// mesh shaders would still be a usable 2D backend. The line says which of the
/// two happened instead of collapsing them into one verdict.
void _reportMesh(GlRenderDevice device) {
  try {
    final GlMeshRendererAttempt attempt = GlMeshRenderer.create(device);
    final GlMeshRenderer? renderer = attempt.renderer;
    if (renderer == null) {
      stdout.writeln('X11_GL_MESH=FAIL ${_summarise(attempt.diagnostics)}');
      return;
    }
    renderer.dispose();
    stdout.writeln('X11_GL_MESH=PASS the mesh program linked; nothing was '
        'drawn with it'
        '${attempt.diagnostics.isEmpty ? '' : ' '
            '(${_summarise(attempt.diagnostics)})'}');
  } on Object catch (error) {
    stdout.writeln('X11_GL_MESH=FAIL $error');
  }
}

/// True when every diagnostic says the machine lacks EGL rather than that EGL
/// refused us.
bool _isMissingEnvironment(List<BackendDiagnostic> diagnostics) =>
    diagnostics.isNotEmpty &&
    diagnostics.every((BackendDiagnostic item) =>
        item.kind == DiagnosticKind.missingLibrary ||
        item.kind == DiagnosticKind.missingSymbol ||
        item.kind == DiagnosticKind.unsupportedPlatform ||
        item.kind == DiagnosticKind.note);

void _reportDiagnostics(String prefix, List<BackendDiagnostic> diagnostics) {
  for (var i = 0; i < diagnostics.length; i++) {
    stdout.writeln('${prefix}_DIAG[$i] ${_format(diagnostics[i])}');
  }
}

String _format(BackendDiagnostic item) => '${item.kind.name}: ${item.message}'
    '${item.detail == null ? '' : ' | ${item.detail}'}';

String _summarise(List<BackendDiagnostic> diagnostics) => diagnostics.isEmpty
    ? 'no diagnostic was produced, which is itself a bug'
    : diagnostics.map(_format).join(' ;; ');

Future<void> _pumpUntil(
  X11WindowingBackend backend,
  bool Function() predicate,
  Duration timeout,
) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    backend.pumpEvents(timeout: const Duration(milliseconds: 25));
    await Future<void>.delayed(Duration.zero);
  }
  if (!predicate()) throw StateError('timed out pumping X11 events');
}
