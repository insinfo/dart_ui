@TestOn('browser')

/// One WebGL2 device, opened once, shared by every test file in this directory.
///
/// Not a test file: a helper, in the shape `test/backends/win32/d3d12/
/// d3d12_session.dart` established for Direct3D 12. It exists for the same
/// reason - opening a device per test is slow, and on this platform it is worse
/// than slow: a browser allows only a small number of live WebGL contexts per
/// page (commonly sixteen), and a suite that opened one per test would start
/// losing the oldest ones part way through and report the loss as a rendering
/// failure.
///
/// ## The skip contract, stated once
///
/// The CI for this repository has neither Chrome nor a GPU, and a test that
/// *fails* there fails the gate. Two things therefore have to be true, and both
/// are:
///
///   * every file in this directory carries `@TestOn('browser')`, so a plain
///     `dart test` - which is what CI runs - never compiles or runs them at
///     all. This is the gate that matters, and it is why no `dart_test.yaml` is
///     needed.
///   * within a browser, [skipReason] is a **string** rather than a bool, and
///     it is non-null whenever the context could not be created. A run that
///     skipped has to say why instead of looking like a run that passed, so
///     every caller prints it and passes it to `markTestSkipped`.
///
/// The second is not hypothetical. `dart test -p chrome` on a headless machine,
/// in a container, or on a laptop whose browser has fallen back to a blocklisted
/// driver all produce a null context from `getContext('webgl2')`, and none of
/// them is a bug in this backend.
library;

import 'dart:js_interop';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// A WebGL2 device on a detached canvas, or the reason there is none.
final class WebGlSession {
  WebGlSession._(this.device, this.skipReason, this._canvas);

  /// Null when the context could not be created. [skipReason] says why.
  final WebGlRenderDevice? device;

  /// Null when the device opened. A string when it did not, so a run with no
  /// GPU reports what was missing rather than passing quietly.
  final String? skipReason;

  /// Kept alive for the lifetime of the device.
  ///
  /// A `WebGLRenderingContext` holds a reference to its canvas, so this is
  /// belt and braces - but the canvas is also what [close] loses the context
  /// through, and a session that had dropped it could not.
  final web.HTMLCanvasElement? _canvas;

  /// Opens a device, or records why it could not.
  ///
  /// The canvas is **detached** - created and never added to the document.
  /// Every target this session hands out renders into a framebuffer object of
  /// its own, so nothing is ever drawn into the canvas's own buffer and its
  /// size is irrelevant; 1x1 is the smallest thing that still gets a real
  /// context. A detached canvas is never laid out or composited, which is what
  /// makes this cheap enough to do at the top of every file.
  static WebGlSession open() {
    try {
      final web.HTMLCanvasElement canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas
        ..width = 1
        ..height = 1;
      final web.WebGL2RenderingContext? gl = createWebGl2Context(canvas);
      if (gl == null) {
        return WebGlSession._(
          null,
          'getContext("webgl2") answered null. WebGL2 may be disabled, the '
          'browser may have no usable GPU process, or this may be a '
          'headless run without a software rasteriser - Chrome needs '
          '--enable-unsafe-swiftshader or a real GPU',
          null,
        );
      }
      if (gl.isContextLost()) {
        return WebGlSession._(
          null,
          'the context was born lost, which is what a browser answers when the '
          'GPU process is unavailable',
          canvas,
        );
      }
      final ({WebGlRenderDevice? device, BackendDiagnostic? failure}) opened =
          WebGlRenderDevice.adoptContext(gl);
      final WebGlRenderDevice? device = opened.device;
      if (device == null) {
        return WebGlSession._(
          null,
          'the context refused the renderer objects: ${opened.failure}',
          canvas,
        );
      }
      return WebGlSession._(device, null, canvas);
    } on Object catch (error) {
      // A probe that throws must not take the suite down with it; the reason
      // becomes a skip like any other.
      return WebGlSession._(
          null, 'opening a WebGL2 device threw: $error', null);
    }
  }

  /// What this session's device reports about the machine, for a log line.
  String get description =>
      device == null ? 'no device: $skipReason' : '${device!.info}';

  /// An offscreen target of the given size, in the format the parity suite
  /// compares in.
  WebGlOffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as WebGlOffscreenTarget;

  /// Disposes the device and gives the context back to the browser.
  void close() {
    device?.dispose();
    // Losing the context explicitly rather than waiting for the canvas to be
    // collected. A browser reclaims a context when its canvas is garbage, and
    // "when" is not a promise a test suite can wait on: several files each
    // holding a context they were finished with is exactly how a run hits the
    // per-page limit and starts failing in whichever file happens to be last.
    final web.HTMLCanvasElement? canvas = _canvas;
    if (canvas == null) return;
    try {
      final web.RenderingContext? context = canvas.getContext('webgl2');
      if (context == null) return;
      final JSObject? extension = (context as web.WebGL2RenderingContext)
          .getExtension('WEBGL_lose_context');
      if (extension == null) return;
      // The device already dropped every object it owned; this releases the
      // context slot itself.
      (extension as _WebGlLoseContext).loseContext();
    } on Object {
      // Optional cleanup. A browser without the extension drops the context
      // when the detached canvas is collected.
    }
  }
}

/// The `WEBGL_lose_context` extension object.
///
/// Declared here rather than imported because `package:web` has none: it is
/// generated from the WebIDL of the DOM specifications, and a WebGL extension
/// is defined by the extension registry instead. `webgl_backend.dart` declares
/// the same shape privately for its probe; duplicating three lines is better
/// than widening that file's API for a test helper.
extension type _WebGlLoseContext._(JSObject _) implements JSObject {
  external void loseContext();
}
