/// What a WebGPU device can be asked to present to.
///
/// One descriptor, where `webgl_surface_descriptor.dart` has two. The WebGL
/// backend's second descriptor - the memory surface that becomes an offscreen
/// readback target - exists for the CPU-parity suite, and that suite runs on
/// WebGL2 today. A WebGPU readback needs `copyTextureToBuffer` plus an async
/// `mapAsync`, which is a different present contract than the synchronous
/// `Framebuffer` the parity harness reads; it is future work and is refused by
/// name in `WebGpuRenderDevice.createTarget` rather than half-supported here.
///
/// ## Why the canvas is carried here and not a handle
///
/// The same reason `webgl_surface_descriptor.dart` gives, unchanged: in a
/// browser "the thing to draw into" is a live `HTMLCanvasElement`, there is no
/// integer that identifies one, and `getContext` is a method on the element.
/// The element travels in the descriptor, and the descriptor **borrows** it -
/// the page created the canvas, the page removes it, and disposing a target
/// built from this descriptor does not touch the DOM.
library;

import 'package:web/web.dart' as web;

import '../../../foundation/lifecycle.dart';
import '../../renderer.dart';

/// A canvas whose WebGPU-configured swap texture is the surface.
///
/// [generation] is shared with whatever owns the canvas - a `WebWindow`, or a
/// test that resizes it by hand - so a frame recorded before a resize can be
/// dropped rather than stretched. See `webgl_canvas_target.dart` for why that
/// number is checked twice per present rather than once; the argument is the
/// canvas's, not the API's, and applies here unchanged.
final class WebGpuCanvasSurfaceDescriptor implements NativeSurfaceDescriptor {
  WebGpuCanvasSurfaceDescriptor({
    required this.canvas,
    required this.generation,
    this.scale = 1.0,
  });

  /// The element whose swap texture this target draws into. Borrowed.
  final web.HTMLCanvasElement canvas;

  /// The owner's lifetime counter. Bumped by whoever resizes the canvas.
  final GenerationToken generation;

  @override
  String get kind => 'webgpu-canvas';

  /// Read from the element on every access rather than cached, for the reason
  /// `WebGlCanvasSurfaceDescriptor` gives: the backing store is
  /// `canvas.width`/`canvas.height`, caching them would put a third copy of
  /// the surface size in play, and the failure that produces reads as a
  /// layout bug rather than a renderer one.
  @override
  int get pixelWidth => canvas.width;

  @override
  int get pixelHeight => canvas.height;

  @override
  final double scale;

  @override
  String toString() => 'WebGpuCanvasSurfaceDescriptor(${pixelWidth}x'
      '$pixelHeight @${scale}x, generation ${generation.current})';
}
