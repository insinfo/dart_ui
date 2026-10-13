/// Caps, joins and dashes, from the display list to the pixels.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  Future<MemoryRenderTarget> render(
    void Function(DisplayList list) draw,
  ) async {
    final device = await const CpuRendererBackend().createDevice();
    final MemoryRenderTarget target = device.createTarget(
      const MemorySurfaceDescriptor(pixelWidth: 64, pixelHeight: 24),
    ) as MemoryRenderTarget;
    final DisplayList list = DisplayList();
    draw(list);
    await target.renderDisplayList(list, clearColor: 0x00000000);
    return target;
  }

  /// The alpha at ([x], [y]) - the stroke's coverage, on a clear target.
  int alpha(MemoryRenderTarget target, int x, int y) {
    final Framebuffer fb = target.framebuffer;
    return fb.pixels[y * fb.bytesPerRow + x * 4 + 3];
  }

  int line(DisplayList list, int paint) {
    final int path = list.addPath((PathBuilder()
          ..moveTo(10, 12)
          ..lineTo(50, 12))
        .build());
    list.drawPath(path, paint);
    return path;
  }

  test('a round cap reaches past the end, a butt cap does not', () async {
    final MemoryRenderTarget butt = await render((DisplayList l) => line(
        l,
        l.addPaint(
            colorArgb: 0xFF000000, style: paintStyleStroke, strokeWidth: 8)));
    final MemoryRenderTarget round = await render((DisplayList l) => line(
        l,
        l.addPaint(
            colorArgb: 0xFF000000,
            style: paintStyleStroke,
            strokeWidth: 8,
            strokeCap: StrokeCap.round)));
    expect(alpha(butt, 7, 12), 0);
    expect(alpha(round, 7, 12), greaterThan(200));
    expect(alpha(round, 30, 12), 255);
  });

  test('a dashed line leaves its gaps empty', () async {
    final MemoryRenderTarget dashed = await render((DisplayList l) => line(
        l,
        l.addPaint(
            colorArgb: 0xFF000000,
            style: paintStyleStroke,
            strokeWidth: 4,
            dashArray: const <double>[10, 10])));
    expect(alpha(dashed, 15, 12), 255, reason: 'the first dash, 10..20');
    expect(alpha(dashed, 25, 12), 0, reason: 'the gap, 20..30');
    expect(alpha(dashed, 35, 12), 255, reason: 'the second dash');
  });

  test('paints differ by cap, join and pattern, and dedup still holds', () {
    final DisplayList list = DisplayList();
    int stroke({
      StrokeCap cap = StrokeCap.butt,
      StrokeJoin join = StrokeJoin.miter,
      List<double>? dashes,
      double miter = 4,
    }) =>
        list.addPaint(
          colorArgb: 0xFF000000,
          style: paintStyleStroke,
          strokeWidth: 2,
          strokeCap: cap,
          strokeJoin: join,
          dashArray: dashes,
          miterLimit: miter,
        );
    final int plain = stroke();
    expect(stroke(), plain);
    final int round = stroke(cap: StrokeCap.round, join: StrokeJoin.round);
    expect(round, isNot(plain));
    expect(stroke(cap: StrokeCap.round, join: StrokeJoin.round), round);
    final int dashed = stroke(dashes: const <double>[3, 1]);
    expect(stroke(dashes: const <double>[3, 1]), dashed);
    expect(stroke(dashes: const <double>[3, 2]), isNot(dashed));
    expect(stroke(miter: 10), isNot(plain));

    expect(list.paintStrokeCap(round), StrokeCap.round);
    expect(list.paintStrokeJoin(round), StrokeJoin.round);
    expect(list.paintStrokeExtras(plain), isNull);
    expect(list.paintStrokeExtras(dashed)!.dashArray, <double>[3, 1]);
    list.reset();
    expect(list.addPaint(colorArgb: 0xFF000000), 0,
        reason: 'reset drops the stroke extras with the paints');
  });
}
