/// What a WebGL2 device can be asked to present to.
///
/// Two descriptors, for the two things a browser offers, and they are separate
/// classes rather than one class with a flag for the reason `gl_backend.dart`
/// gives about its own pair: they present in opposite ways. A
/// [MemorySurfaceDescriptor] becomes a target that renders into a framebuffer
/// object and reads it back - which is what a golden test and the CPU-parity
/// suite need, and what section 23 of the roadmap forbids on a screen. A
/// [WebGlCanvasSurfaceDescriptor] becomes a target that renders into the
/// context's *default* framebuffer, which the compositor puts on the page, and
/// which nothing ever reads back.
///
/// ## Why the canvas is carried here and not a handle
///
/// `NativeSurfaceDescriptor` exists so a renderer can be handed "the thing to
/// draw into" without common code knowing what it is, and on every other
/// platform that thing is an integer - an `HWND`, an `xcb_window_t`. In a
/// browser it is a live `HTMLCanvasElement`, and there is no integer that
/// identifies one: `getContext` is a method on the element itself.
///
/// So the element travels in the descriptor. That is the same shape
/// `gl_surface_descriptor.dart` uses when it carries a `GlSwapChain`, and it
/// keeps the ownership rule identical: the descriptor **borrows** the canvas.
/// The page created it, the page removes it, and disposing a target built from
/// this descriptor does not touch the DOM.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../../foundation/lifecycle.dart';
import '../../renderer.dart';

/// The `getContext` id this backend asks a canvas for.
const String kWebGl2ContextId = 'webgl2';

/// A canvas whose WebGL2 default framebuffer is the surface.
///
/// [generation] is shared with whatever owns the canvas - a `WebWindow`, or a
/// test that resizes it by hand - so a frame recorded before a resize can be
/// dropped rather than stretched. See `gl_window_target.dart` for why that
/// number is checked twice per present rather than once.
final class WebGlCanvasSurfaceDescriptor implements NativeSurfaceDescriptor {
  WebGlCanvasSurfaceDescriptor({
    required this.canvas,
    required this.generation,
    this.scale = 1.0,
    this.contextAttributes,
  });

  /// The element whose backing store this target draws into. Borrowed.
  final web.HTMLCanvasElement canvas;

  /// The owner's lifetime counter. Bumped by whoever resizes the canvas.
  final GenerationToken generation;

  @override
  String get kind => 'webgl-canvas';

  /// Read from the element on every access rather than cached.
  ///
  /// A canvas's backing store is `canvas.width`/`canvas.height`, which is not
  /// its CSS size and not the layout's idea of it. Caching them here would put
  /// a third copy of the surface size in play, and the failure that produces
  /// is invisible: the viewport would be set from a stale number and a quarter
  /// of a HiDPI canvas would be drawn into, which reads as a layout bug.
  @override
  int get pixelWidth => canvas.width;

  @override
  int get pixelHeight => canvas.height;

  @override
  final double scale;

  /// The `WebGLContextAttributes` dictionary to create the context with, or
  /// null for this backend's defaults. See [defaultWebGl2ContextAttributes].
  final JSObject? contextAttributes;

  @override
  String toString() => 'WebGlCanvasSurfaceDescriptor(${pixelWidth}x'
      '$pixelHeight @${scale}x, generation ${generation.current})';
}

/// The context attributes this backend asks for, and why each one.
///
///   * **`alpha: false`.** A canvas with an alpha channel is composited by the
///     browser against the page behind it, so a half-transparent pixel the
///     renderer produced would blend with the document's background rather
///     than with what the renderer drew underneath. This framework's
///     framebuffers are premultiplied and opaque at the surface, so the
///     channel is dead weight and the composite is a per-frame cost for
///     nothing.
///   * **`premultipliedAlpha: true`.** The renderer's colours are already
///     premultiplied - `gpu_raster_sink.dart` premultiplies at vertex-write
///     time and the blend function is `(ONE, ONE_MINUS_SRC_ALPHA)`. Saying so
///     is free; letting the browser assume straight alpha would make it
///     divide out an alpha that was never divided in.
///   * **`antialias: false`.** The antialiasing here is analytic - the
///     coverage term in `gl_shaders.dart` and the mask atlas - and a
///     multisampled default framebuffer would add a second, disagreeing one on
///     top, at the cost of a resolve per frame. `RendererCapabilities.
///     supportsMsaa` reports false for the same reason.
///   * **`depth: false`, `stencil: false`.** A 2D renderer that draws in
///     submission order needs neither, and both cost memory per pixel of a
///     full-screen surface.
///   * **`preserveDrawingBuffer: false`.** The default. Preserving it forces
///     the browser to keep a copy across composites; every frame here clears
///     or fully redraws, so there is nothing to preserve.
///
/// `powerPreference` is deliberately left unset: asking for the discrete GPU
/// on a laptop is a battery decision that belongs to the application, not to
/// the renderer, and browsers may ignore it anyway.
/// The `WebGLContextAttributes` dictionary, as a JavaScript object literal.
///
/// An extension type with an `external factory` rather than a bare [JSObject]
/// with properties assigned into it. The bare form does not compile: `[]=` is
/// not defined on `JSObject` in `dart:js_interop`, it lives in
/// `dart:js_interop_unsafe`, and reaching for that library would buy an
/// untyped, unchecked write - `attributes['antilias'] = ...` would compile and
/// silently leave antialiasing on. Here a misspelled attribute is a
/// compile error, and the generated code is the same object literal.
extension type WebGlContextAttributes._(JSObject _) implements JSObject {
  external factory WebGlContextAttributes({
    bool alpha,
    bool depth,
    bool stencil,
    bool antialias,
    bool premultipliedAlpha,
    bool preserveDrawingBuffer,
    bool failIfMajorPerformanceCaveat,
  });
}

WebGlContextAttributes defaultWebGl2ContextAttributes() =>
    WebGlContextAttributes(
      alpha: false,
      depth: false,
      stencil: false,
      antialias: false,
      premultipliedAlpha: true,
      preserveDrawingBuffer: false,
      failIfMajorPerformanceCaveat: false,
    );

/// Asks [canvas] for a WebGL2 context, or null when the browser refuses.
///
/// Never throws. `getContext` returns null on a machine with no GPU process,
/// in a browser with WebGL disabled by policy, and on a canvas that already
/// has a 2D context - all three are "this backend cannot run here", which
/// section 6.6 says must be reported rather than raised.
///
/// The result is checked with `instanceOfString` rather than with `is`. That
/// is not a stylistic choice: `RenderingContext` is a typedef for `JSObject`
/// and `WebGL2RenderingContext` is an *extension type* over the same
/// `JSObject`, so `context is web.WebGL2RenderingContext` is erased to
/// `context is JSObject` and is true for a 2D context, a WebGL1 context and a
/// bitmap renderer alike. It would compile, it would never fail, and the first
/// `gl.createShader` on the wrong object would throw a JavaScript
/// `TypeError` out of the frame loop.
web.WebGL2RenderingContext? createWebGl2Context(
  web.HTMLCanvasElement canvas, {
  JSObject? attributes,
}) {
  try {
    final web.RenderingContext? context = canvas.getContext(
      kWebGl2ContextId,
      attributes ?? defaultWebGl2ContextAttributes(),
    );
    if (context == null) return null;
    if (!context.instanceOfString('WebGL2RenderingContext')) return null;
    return context as web.WebGL2RenderingContext;
  } on Object {
    return null;
  }
}
