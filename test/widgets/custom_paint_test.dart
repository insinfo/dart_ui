import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('a painter draws in the box\'s own coordinates', () async {
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(40, 40)),
      ),
    );
    owner.updateRoot(Directionality(
      textDirection: TextDirection.leftToRight,
      child: Padding(
        padding: const EdgeInsets.only(left: 10, top: 10),
        child: Align(
          alignment: Alignment.topLeft,
          child: CustomPaint(
            size: const Size(20, 20),
            painter: (DisplayList list, Size size) => list.drawRect(0, 0,
                size.width, size.height, list.addPaint(colorArgb: 0xFFFF0000)),
          ),
        ),
      ),
    ));
    owner.buildScope();
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);

    final device = await const CpuRendererBackend().createDevice();
    final MemoryRenderTarget target = device.createTarget(
      const MemorySurfaceDescriptor(pixelWidth: 40, pixelHeight: 40),
    ) as MemoryRenderTarget;
    await target.renderDisplayList(list, clearColor: 0xFF000000);
    final Framebuffer fb = target.framebuffer;
    int red(int x, int y) {
      final int i = y * fb.bytesPerRow + x * 4;
      // BGRA or RGBA: the red channel is the one that is not zero in both.
      return fb.pixels[i] > fb.pixels[i + 2] ? fb.pixels[i] : fb.pixels[i + 2];
    }

    expect(red(20, 20), 255, reason: 'inside the box');
    expect(red(5, 5), 0, reason: 'above and left of the box');
    expect(red(35, 35), 0, reason: 'past the box');
    owner.dispose();
  });
}
