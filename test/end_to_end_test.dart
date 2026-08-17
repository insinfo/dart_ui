import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// The whole stack in one file, with nothing stubbed.
///
/// Constraints go in at the top, a layout tree sizes and positions itself,
/// paints into an encoded display list, a player resolves transforms and clips
/// into device space, a scanline rasteriser composites, and bytes come out.
/// Six layers, no window, no GPU, no display server.
///
/// The per-layer suites prove each piece against its own contract. This one
/// exists for the failure they cannot catch: two layers that are each correct
/// and disagree with one another about coordinates, channel order or edges.
void main() {
  /// Reads a pixel as (r, g, b, a) whatever the buffer's channel order, so an
  /// assertion about colour never accidentally becomes one about byte layout.
  (int, int, int, int) pixelAt(Framebuffer buffer, int x, int y) {
    final i = buffer.offsetOf(x, y);
    final bytes = buffer.pixels;
    return switch (buffer.format) {
      PixelFormat.bgra8888Premultiplied => (
          bytes[i + 2],
          bytes[i + 1],
          bytes[i],
          bytes[i + 3]
        ),
      PixelFormat.rgba8888Premultiplied => (
          bytes[i],
          bytes[i + 1],
          bytes[i + 2],
          bytes[i + 3]
        ),
    };
  }

  Future<MemoryRenderTarget> targetOf(int width, int height) async {
    final device = await const CpuRendererBackend().createDevice();
    return device.createTarget(
      MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
    ) as MemoryRenderTarget;
  }

  /// Lays the tree out at [width] x [height], paints it, rasterises it.
  Future<MemoryRenderTarget> render(
    RenderBox root,
    int width,
    int height,
  ) async {
    final owner = PipelineOwner()
      ..root = root
      ..rootConstraints = BoxConstraints.tight(
        Size(width.toDouble(), height.toDouble()),
      );
    final list = DisplayList();
    owner.drawFrame(list);

    final target = await targetOf(width, height);
    await target.renderDisplayList(list, clearColor: 0xFF000000);
    return target;
  }

  test('a padded coloured box lands exactly where layout put it', () async {
    final target = await render(
      RenderPadding(
        padding: const EdgeInsets.all(4),
        child: RenderColoredBox(color: const Color(0xFF00FF00)),
      ),
      16,
      16,
    );

    // Inside the padding: background. Inside the box: the colour. If layout
    // and painting disagreed about the offset by even one pixel, one of these
    // four flips.
    expect(pixelAt(target.framebuffer, 3, 8), (0, 0, 0, 255));
    expect(pixelAt(target.framebuffer, 4, 8), (0, 255, 0, 255));
    expect(pixelAt(target.framebuffer, 11, 8), (0, 255, 0, 255));
    expect(pixelAt(target.framebuffer, 12, 8), (0, 0, 0, 255));
  });

  test('a flex row divides the surface where the flex factors say', () async {
    final target = await render(
      RenderFlex()
        ..add(RenderColoredBox(color: const Color(0xFFFF0000)), flex: 1)
        ..add(RenderColoredBox(color: const Color(0xFF0000FF)), flex: 3),
      16,
      4,
    );

    // 1:3 over sixteen pixels puts the boundary at x = 4.
    expect(pixelAt(target.framebuffer, 0, 2), (255, 0, 0, 255));
    expect(pixelAt(target.framebuffer, 3, 2), (255, 0, 0, 255));
    expect(pixelAt(target.framebuffer, 4, 2), (0, 0, 255, 255));
    expect(pixelAt(target.framebuffer, 15, 2), (0, 0, 255, 255));
  });

  test('alignment inside a larger box puts the child where it says', () async {
    final target = await render(
      RenderAlign(
        alignment: Alignment.bottomRight,
        child: RenderConstrainedBox(
          additionalConstraints: BoxConstraints.tight(const Size(4, 4)),
          child: RenderColoredBox(color: const Color(0xFFFFFFFF)),
        ),
      ),
      12,
      12,
    );

    // Bottom-right of a 12x12 surface with a 4x4 child: x and y in 8..11.
    expect(pixelAt(target.framebuffer, 11, 11), (255, 255, 255, 255));
    expect(pixelAt(target.framebuffer, 8, 8), (255, 255, 255, 255));
    expect(pixelAt(target.framebuffer, 7, 11), (0, 0, 0, 255));
    expect(pixelAt(target.framebuffer, 11, 7), (0, 0, 0, 255));
  });

  test('hit testing agrees with the pixels that were painted', () async {
    // The claim worth checking is that layout, painting and hit testing share
    // one coordinate system. A tree can render correctly and still route
    // clicks to the wrong node.
    final child = RenderColoredBox(color: const Color(0xFF00FF00));
    final root = RenderPadding(
      padding: const EdgeInsets.all(4),
      child: child,
    );
    final target = await render(root, 16, 16);

    final insidePath = HitTestPath();
    final inside = root.hitTest(const Offset(8, 8), path: insidePath);
    final outsidePath = HitTestPath();
    final outside = root.hitTest(const Offset(1, 1), path: outsidePath);

    expect(inside, same(child));
    expect(insidePath.entries, contains(child));
    expect(outside, isNot(same(child)));
    expect(outsidePath.entries, isNot(contains(child)));

    // And the pixel under the hit is the child's colour, not the background.
    expect(pixelAt(target.framebuffer, 8, 8), (0, 255, 0, 255));
    expect(pixelAt(target.framebuffer, 1, 1), (0, 0, 0, 255));
  });
}
