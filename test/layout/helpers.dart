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

/// A leaf that answers intrinsic questions and counts how often it was asked.
///
/// The counter is the whole point: "the cache works" is not observable from the
/// answers, which are the same either way. It is observable from the number of
/// times the node had to compute one, so every intrinsic caching claim in
/// `intrinsics_test.dart` is an assertion on this integer.
final class MeasuredBox extends RenderBox {
  MeasuredBox(this._preferredSize);

  Size _preferredSize;

  /// How many times one of the four `compute*` methods actually ran. A cache
  /// hit does not increment it.
  int intrinsicComputeCount = 0;

  int layoutCount = 0;

  Size get preferredSize => _preferredSize;

  set preferredSize(Size value) {
    if (value == _preferredSize) return;
    _preferredSize = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    intrinsicComputeCount++;
    return _preferredSize.width;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    intrinsicComputeCount++;
    return _preferredSize.width;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    intrinsicComputeCount++;
    return _preferredSize.height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    intrinsicComputeCount++;
    return _preferredSize.height;
  }

  @override
  void performLayout() {
    layoutCount++;
    size = constraints.constrain(_preferredSize);
  }

  @override
  bool hitTestSelf(Offset position) => true;
}

/// A leaf whose height depends on its width, the way a paragraph's does.
///
/// It owns a fixed area of "ink" and a line height, and reports the number of
/// lines that area needs at a given width. Without a node like this, "a row is
/// as tall as its content needs at the width its columns settled on" is not
/// testable: every other leaf here has a height that ignores its width, which
/// is exactly the case that would pass even if the grid measured rows first.
final class ReflowingBox extends RenderBox {
  ReflowingBox({
    required this.contentWidth,
    required this.lineHeight,
  });

  /// The main-axis extent the content would need on a single line.
  final double contentWidth;

  final double lineHeight;

  @override
  double computeMinIntrinsicWidth(double height) => 0.0;

  @override
  double computeMaxIntrinsicWidth(double height) => contentWidth;

  @override
  double computeMinIntrinsicHeight(double width) =>
      computeMaxIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) {
    if (width <= 0 || !width.isFinite) return lineHeight;
    return (contentWidth / width).ceil() * lineHeight;
  }

  @override
  void performLayout() {
    final double width = constraints.constrainWidth(contentWidth);
    size = constraints.constrain(
        Size(width, computeMaxIntrinsicHeight(constraints.maxWidth)));
  }
}

/// A leaf that claims a baseline at a fixed distance from its top edge.
///
/// Stands in for text without needing a font on the machine, so the baseline
/// tests can assert exact offsets instead of "the same on both".
final class BaselineBox extends RenderBox {
  BaselineBox(this._preferredSize, this.baselineFromTop);

  final Size _preferredSize;

  /// Distance from this box's top edge down to its alphabetic baseline.
  final double baselineFromTop;

  @override
  double computeMinIntrinsicWidth(double height) => _preferredSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _preferredSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _preferredSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _preferredSize.height;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      baseline == TextBaseline.alphabetic
          ? baselineFromTop
          : _preferredSize.height;

  @override
  void performLayout() {
    layoutCount++;
    size = constraints.constrain(_preferredSize);
  }

  int layoutCount = 0;
}

/// A leaf that lays a child out from inside an intrinsic query - the thing the
/// protocol forbids.
final class IllegalIntrinsic extends RenderSingleChildBox {
  IllegalIntrinsic({super.child});

  @override
  double computeMaxIntrinsicWidth(double height) {
    child!.layout(BoxConstraints.tight(const Size(1, 1)));
    return 0.0;
  }

  @override
  void performLayout() {
    child?.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child?.size ?? Size.zero);
  }
}

/// A leaf that reports an infinite extent, which no constraint makes legal.
final class InfiniteBox extends RenderBox {
  @override
  void performLayout() {
    size = Size(constraints.maxWidth, constraints.constrainHeight(10));
  }
}

/// A node that dirties another one every time it is laid out.
///
/// Two of these pointing at each other is the cheapest honest layout cycle:
/// neither is doing anything a `performLayout` is forbidden to do in isolation,
/// and together they cannot converge.
final class PingPongBox extends RenderBox {
  RenderBox? peer;
  int layoutCount = 0;

  @override
  void performLayout() {
    layoutCount++;
    size = constraints.constrain(const Size(10, 10));
    peer?.markNeedsLayout();
  }
}

/// Lays every child out under one tight constraint, declaring it does not read
/// their sizes - which makes each child its own relayout boundary.
final class BoundaryHost extends RenderBoxContainer<BoxParentData> {
  BoundaryHost({this.cell = const Size(10, 10)});

  final Size cell;

  @override
  void performLayout() {
    for (int i = 0; i < childCount; i++) {
      childAt(i).layout(BoxConstraints.tight(cell));
    }
    size = constraints.constrain(cell);
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
