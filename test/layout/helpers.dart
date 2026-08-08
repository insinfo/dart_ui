/// Render boxes that exist only to be observed.
///
/// The concrete nodes in `lib/src/layout` are the subject of most tests, but
/// two claims - that a relayout stops at a boundary, and that reading a size
/// you did not ask for throws - can only be checked by counting layouts and by
/// misbehaving on purpose. That is what these are for.
library;

import 'package:dart_ui/dart_ui.dart';

/// A leaf that asks for one size and accepts whatever it is given instead.
final class FixedBox extends RenderBox {
  FixedBox(this._preferredSize);

  Size _preferredSize;

  /// How many times this node has actually re-run layout. The number the
  /// relayout boundary tests are about.
  int layoutCount = 0;

  Size get preferredSize => _preferredSize;

  set preferredSize(Size value) {
    if (value == _preferredSize) return;
    _preferredSize = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    layoutCount++;
    size = constraints.constrain(_preferredSize);
  }

  @override
  bool hitTestSelf(Offset position) => true;
}

/// A leaf that takes everything it is offered.
final class FillBox extends RenderBox {
  int layoutCount = 0;

  @override
  void performLayout() {
    layoutCount++;
    size = constraints.largestFinite;
  }

  @override
  bool hitTestSelf(Offset position) => true;
}

/// A single-child wrapper that passes constraints chosen by the test, and
/// counts its own layouts.
final class CountingProxy extends RenderSingleChildBox {
  CountingProxy({
    required this.childConstraints,
    this.parentUsesSize = true,
    super.child,
  });

  final BoxConstraints childConstraints;
  final bool parentUsesSize;
  int layoutCount = 0;

  @override
  void performLayout() {
    layoutCount++;
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.largestFinite;
      return;
    }
    child.layout(childConstraints, parentUsesSize: parentUsesSize);
    // Only legal because parentUsesSize was true; the test that flips it to
    // false is asserting that this line throws.
    size = constraints.constrain(child.size);
  }
}

/// Reads a pixel as (r, g, b, a) regardless of the buffer's channel order, so
/// a test asserting colour never accidentally asserts byte layout.
(int, int, int, int) pixelAt(Framebuffer buffer, int x, int y) {
  final int i = buffer.offsetOf(x, y);
  final bytes = buffer.pixels;
  return switch (buffer.format) {
    PixelFormat.bgra8888Premultiplied => (
        bytes[i + 2],
        bytes[i + 1],
        bytes[i],
        bytes[i + 3],
      ),
    PixelFormat.rgba8888Premultiplied => (
        bytes[i],
        bytes[i + 1],
        bytes[i + 2],
        bytes[i + 3],
      ),
  };
}

/// A CPU render target of the given pixel size, with no window anywhere in the
/// path.
Future<MemoryRenderTarget> memoryTarget(int width, int height) async {
  final RenderDevice device = await const CpuRendererBackend().createDevice();
  return device.createTarget(
    MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
  ) as MemoryRenderTarget;
}
