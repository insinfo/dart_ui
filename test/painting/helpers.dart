/// Shared plumbing for the painting tests: render a widget or a display list
/// on the CPU and read pixels back.
library;

import 'package:dart_ui/dart_ui.dart';

/// (r, g, b, a) whatever the buffer's channel order.
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

const int kBackground = 0xFF204060;
const (int, int, int, int) kBackgroundPixel = (0x20, 0x40, 0x60, 0xFF);

/// Replays [list] into a [width] x [height] CPU target cleared to
/// [kBackground].
Future<Framebuffer> renderList(DisplayList list, int width, int height) async {
  final RenderDevice device = await const CpuRendererBackend().createDevice();
  final MemoryRenderTarget target = device.createTarget(
    MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
  ) as MemoryRenderTarget;
  await target.renderDisplayList(list, clearColor: kBackground);
  return target.framebuffer;
}

/// Builds [root] into a tight [width] x [height] window and returns the
/// pipeline, the build owner and the frame's display list.
(BuildOwner, DisplayList) mountAndPaint(Widget root,
    {int width = 64, int height = 64}) {
  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints:
        BoxConstraints.tight(Size(width.toDouble(), height.toDouble())),
  );
  final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
    ..updateRoot(root);
  owner.buildScope();
  final DisplayList list = DisplayList();
  pipeline.drawFrame(list);
  return (owner, list);
}

/// [root] rendered at [width] x [height].
Future<Framebuffer> renderWidget(Widget root,
    {int width = 64, int height = 64}) {
  final (_, DisplayList list) =
      mountAndPaint(root, width: width, height: height);
  return renderList(list, width, height);
}

/// Whether two pixels are within [tolerance] per channel.
bool near((int, int, int, int) a, (int, int, int, int) b,
        [int tolerance = 2]) =>
    (a.$1 - b.$1).abs() <= tolerance &&
    (a.$2 - b.$2).abs() <= tolerance &&
    (a.$3 - b.$3).abs() <= tolerance &&
    (a.$4 - b.$4).abs() <= tolerance;
