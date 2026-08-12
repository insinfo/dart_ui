import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('CpuCanvas records, damages, and flushes through the selected adapter',
      () {
    final framebuffer = Framebuffer.allocate(width: 8, height: 4);
    final canvas = CpuCanvas(framebuffer: framebuffer);
    final paint = canvas.paint(colorArgb: 0xFFFF0000);

    canvas.fillRect(const Rect.fromLTWH(2, 1, 3, 2), paint);
    expect(canvas.damage, const Rect.fromLTWH(2, 1, 3, 2));
    expect(canvas.rasterizer.name, 'scanline');

    canvas.flush(clearColor: 0xFF000000);

    final pixel = framebuffer.offsetOf(3, 2);
    expect(framebuffer.pixels.sublist(pixel, pixel + 4), <int>[0, 0, 255, 255]);
    expect(canvas.damage, isNull);
  });

  test('reference adapter is selectable without changing the canvas contract',
      () {
    final canvas = CpuCanvas(
      framebuffer: Framebuffer.allocate(width: 2, height: 2),
      rasterizer: const CpuRasterizerSelector(
        kind: CpuRasterizerKind.reference,
      ).create(),
    );

    expect(canvas.rasterizer.name, 'reference');
  });

  test('linear gradient writes premultiplied pixels in the target format', () {
    final framebuffer = Framebuffer.allocate(width: 2, height: 1);
    final canvas = CpuCanvas(framebuffer: framebuffer);

    canvas.fillLinearGradient(
      const Rect.fromLTWH(0, 0, 2, 1),
      0xFFFF0000,
      0xFF0000FF,
    );

    expect(framebuffer.pixels.sublist(0, 4), <int>[64, 0, 191, 255]);
    expect(framebuffer.pixels.sublist(4, 8), <int>[191, 0, 64, 255]);
  });

  test('reference stroke handles open contours without filling the interior',
      () {
    final framebuffer = Framebuffer.allocate(width: 5, height: 5);
    final canvas = CpuCanvas(framebuffer: framebuffer);
    final path = PathBuilder()
      ..moveTo(1, 1)
      ..lineTo(4, 1);

    canvas.strokePath(path.build(), 0xFFFFFFFF, 1);

    expect(framebuffer.pixels[framebuffer.offsetOf(2, 1) + 3], 255);
    expect(framebuffer.pixels[framebuffer.offsetOf(2, 2) + 3], 0);
  });

  test('glyph alpha masks are composited as basic text primitives', () {
    final framebuffer = Framebuffer.allocate(width: 2, height: 1);
    final canvas = CpuCanvas(framebuffer: framebuffer);

    canvas.drawGlyph(
      GlyphBitmap(
        width: 2,
        height: 1,
        pixels: Uint8List.fromList(<int>[255, 128]),
      ),
      0,
      0,
      0xFFFF0000,
    );

    expect(framebuffer.pixels[framebuffer.offsetOf(0, 0) + 2], 255);
    expect(framebuffer.pixels[framebuffer.offsetOf(1, 0) + 2], 128);
  });
}
