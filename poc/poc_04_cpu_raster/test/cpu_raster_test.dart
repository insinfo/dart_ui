import 'package:poc_04_cpu_raster/poc_04_cpu_raster.dart';
import 'package:test/test.dart';

void main() {
  test('uses a tight BGRA stride and clips rectangles', () {
    final buffer = BgraPremultipliedBuffer(3, 2);
    buffer.fillRect(const DirtyRect(-1, -1, 2, 1), 3, 2, 1, 255);

    expect(buffer.stride, 12);
    expect(buffer.data, <int>[
      3,
      2,
      1,
      255,
      3,
      2,
      1,
      255,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  });

  test('source-over blend preserves premultiplied alpha', () {
    final buffer = BgraPremultipliedBuffer(1, 1);
    buffer.fillRect(const DirtyRect(0, 0, 1, 1), 50, 100, 200, 255);
    buffer.blendRect(const DirtyRect(0, 0, 1, 1), 64, 0, 0, 128);

    expect(buffer.data, <int>[89, 50, 100, 255]);
  });

  test('scene reuses a buffer across frames', () {
    final scene = BenchmarkScene(400, 300);
    final data = scene.buffer.data;
    scene.render(0);
    scene.render(1);

    expect(identical(scene.buffer.data, data), isTrue);
    expect(data.any((value) => value != 0), isTrue);
  });
}
