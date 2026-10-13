/// A rotated or skewed box, rasterised: the pixels of the real quadrilateral,
/// not of its bounding box, on the CPU and on Metal.
///
/// Regression for the display-list player handing a filled rectangle under a
/// rotation to `fillDeviceRect` as its device bounding box: a `ColoredBox`
/// inside `Transform.rotate(angle: pi / 4)` came out as an upright square
/// twice the area of the one it stood for, on every backend.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_device.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_offscreen.dart';
import 'package:test/test.dart';

import '../layout/helpers.dart';

const int _side = 200;
const Color _ink = Color(0xFF2563EB);
const int _background = 0xFFFFFFFF;

DisplayList _record(Widget child) {
  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.tight(const Size(200, 200)),
  );
  BuildOwner(pipelineOwner: pipeline).updateRoot(Center(child: child));
  final DisplayList list = DisplayList();
  pipeline.drawFrame(list);
  return list;
}

/// A 100x100 box turned 45 degrees about its centre, which is (100, 100):
/// a diamond whose vertices are 70.7 px from the centre along the axes.
Widget _diamond({double radius = 0}) => Transform.rotate(
      angle: math.pi / 4,
      child: SizedBox(
        width: 100,
        height: 100,
        child: radius == 0
            ? const ColoredBox(color: _ink)
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: _ink,
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
      ),
    );

Future<Framebuffer> _cpu(DisplayList list) async {
  final MemoryRenderTarget target = await memoryTarget(_side, _side);
  addTearDown(target.dispose);
  await target.renderDisplayList(list, clearColor: _background);
  return target.framebuffer;
}

bool _isInk(Framebuffer buffer, int x, int y) =>
    pixelAt(buffer, x, y) == (_ink.red, _ink.green, _ink.blue, 0xFF);

bool _isBackground(Framebuffer buffer, int x, int y) =>
    pixelAt(buffer, x, y) == (0xFF, 0xFF, 0xFF, 0xFF);

void _expectDiamond(Framebuffer buffer) {
  // The centre and points just inside each vertex.
  for (final (int, int) p in <(int, int)>[
    (100, 100),
    (100, 38),
    (100, 162),
    (38, 100),
    (162, 100),
  ]) {
    expect(_isInk(buffer, p.$1, p.$2), isTrue, reason: 'inside at $p');
  }
  // The corners of the bounding box, which the old fill painted, and points
  // just outside each edge of the diamond.
  for (final (int, int) p in <(int, int)>[
    (32, 32),
    (167, 32),
    (32, 167),
    (167, 167),
    (60, 60),
    (140, 140),
  ]) {
    expect(_isBackground(buffer, p.$1, p.$2), isTrue, reason: 'outside at $p');
  }
}

void main() {
  group('a rotated box on the CPU', () {
    test('a ColoredBox turned 45 degrees is a diamond, not its box', () async {
      _expectDiamond(await _cpu(_record(_diamond())));
    });

    test('a rounded box turned 45 degrees keeps its rounded vertices',
        () async {
      final Framebuffer buffer = await _cpu(_record(_diamond(radius: 30)));
      // A square vertex would reach y = 29.3; the 30 px corner pulls it in to
      // 100 - 20 * sqrt2 - 30 = 41.7.
      expect(_isBackground(buffer, 100, 36), isTrue);
      expect(_isInk(buffer, 100, 46), isTrue);
      expect(_isInk(buffer, 100, 100), isTrue);
      expect(_isBackground(buffer, 32, 32), isTrue);
    });

    test('a skewed box is a parallelogram', () async {
      final Framebuffer buffer = await _cpu(_record(const Transform(
        transform: Transform2D(1, 0, 0.5, 1, 0, 0),
        alignment: Alignment.center,
        child:
            SizedBox(width: 100, height: 100, child: ColoredBox(color: _ink)),
      )));
      // x' = x + 0.5 * (y - 100): the top edge spans 25..125, the bottom
      // 75..175.
      expect(_isInk(buffer, 30, 52), isTrue);
      expect(_isBackground(buffer, 30, 148), isTrue);
      expect(_isInk(buffer, 170, 148), isTrue);
      expect(_isBackground(buffer, 170, 52), isTrue);
    });
  });

  group('the same scenes on Metal', () {
    MetalGpu? gpu;
    MetalPipelineCache? pipelines;

    setUpAll(() {
      if (!Platform.isMacOS) return;
      gpu = MetalGpu.open();
      pipelines = MetalPipelineCache.build(gpu!);
    });

    tearDownAll(() {
      pipelines?.dispose();
      gpu?.dispose();
    });

    Future<void> expectParity(DisplayList list) async {
      final Framebuffer cpu = await _cpu(list);
      final MetalOffscreenTarget metal = MetalOffscreenTarget.create(
          gpu!, pipelines!,
          width: _side, height: _side);
      try {
        metal.renderDisplayList(list, clearColor: _background);
        final Framebuffer gpuPixels = metal.readPixels();
        _expectDiamond(gpuPixels);
        var worst = 0;
        for (var y = 0; y < _side; y++) {
          for (var x = 0; x < _side; x++) {
            final (int, int, int, int) a = pixelAt(cpu, x, y);
            final (int, int, int, int) b = pixelAt(gpuPixels, x, y);
            worst = <int>[
              worst,
              (a.$1 - b.$1).abs(),
              (a.$2 - b.$2).abs(),
              (a.$3 - b.$3).abs(),
              (a.$4 - b.$4).abs(),
            ].reduce(math.max);
          }
        }
        // Measured 0 on this Mac (13/10/2026): both fill the outline through
        // the same coverage path.
        expect(worst, lessThanOrEqualTo(1));
      } finally {
        metal.dispose();
      }
    }

    test('a ColoredBox turned 45 degrees', () async {
      await expectParity(_record(_diamond()));
    }, skip: Platform.isMacOS ? null : 'needs Metal');

    test('a rounded box turned 45 degrees', () async {
      await expectParity(_record(_diamond(radius: 12)));
    }, skip: Platform.isMacOS ? null : 'needs Metal');
  });
}
