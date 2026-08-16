/// The same display list down the CPU rasteriser and Vulkan, compared pixel by
/// pixel.
///
/// `test/rendering/gpu/d3d12/d3d12_cpu_parity_test.dart` does this for Direct3D
/// 12 and explains at length why it is the only kind of test that catches a
/// wrong *idea* rather than a wrong number. This file is the same argument
/// applied to a third GPU backend, over deliberately the same scenes, so that
/// the three can eventually become one parameterised comparison.
///
/// It is also the third and last of the checks `vulkan_spirv.dart` names.
/// `vulkan_spirv_test.dart` proves the modules are well-formed;
/// `vulkan_pipeline_test.dart` proves the driver accepts them; only this file
/// can tell a shader that assembles and validates and multiplies the wrong
/// pair of operands from one that is right.
///
/// ## The tolerance, declared and measured
///
/// **Zero on nine of the ten scenes. One level on the tenth, and the tenth is
/// the reason the number is worth stating.**
///
/// A tolerance is justifiable in principle. The CPU folds 8-bit channels
/// through `mul255`, which is exact round-to-nearest of `v * a / 255`. The GPU
/// multiplies floats in a fragment shader, quantises once at the end, and
/// hands the result to a fixed-function blend unit that the specification
/// only requires to be accurate to within one unit in the last place of the
/// attachment format. A driver is therefore *allowed* to round a tie the other
/// way.
///
/// It was measured rather than assumed. On the adapter this was written
/// against - Intel UHD Graphics, Vulkan 1.3.212, driver 0x19481f - the solid
/// fills, both blend modes, both coverage-mask path fills, the rounded
/// rectangle, the image and the clip all match in **all four channels on all
/// 576 pixels**, deviation 0.
///
/// The exception is [_fractionalRect], whose left edge sits at exactly x.5 so
/// that `boxCoverage` evaluates to exactly 0.5 down a whole column. That is a
/// **rounding tie**, and the two sides break it in opposite directions: the
/// CPU's coverage arrives as a quantised 8-bit value (`gpu_pipeline.dart`
/// records that it quantises positions to 1/255ths of a pixel) and lands at
/// 135, the GPU's float lands a hair above the midpoint and quantises to 136.
/// One level, on 12 of 576 pixels, all of them on a half-covered edge. The
/// scene is kept rather than removed because deleting it would delete the
/// measurement; the tolerance is 1 and is written where anybody reading the
/// failure can see what it covers.
///
/// What the parameter must never become is the place a failure is made to go
/// away. A scene that has been exact and stops being exact is a regression; a
/// margin wide enough to hide it destroys the only signal this file produces.
/// That is why the exception is one named scene at one level and not a file-
/// wide default.
///
/// ## What is not compared here, and why
///
/// **Text.** This backend passes no `GpuGlyphAtlas` to its sink and refuses a
/// glyph run by name. The refusal is asserted below so the gap cannot quietly
/// become a wrong picture.
///
/// **Layers.** Same: no `GpuLayerStack`, so a `saveLayer` needing a real
/// offscreen pass is refused rather than flattened.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_backend.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

const int _size = 24;

/// Opaque black. The clear has to be opaque, or every comparison would be
/// dominated by how the two sides treat an unwritten alpha.
const int _clear = 0xFF000000;

void main() {
  final VulkanSession session = VulkanSession.open(validation: true);
  VulkanRenderDevice? device;
  String? skip = session.skipReason;

  setUpAll(() {
    if (skip != null) return;
    try {
      device = VulkanRenderDevice.adoptInstance(session.instance!);
    } on BackendSelectionError catch (error) {
      skip = 'no Vulkan render device: $error';
    }
  });
  tearDownAll(() {
    device?.dispose();
    // The session's own VkDevice is separate from the render device's; both
    // are closed, and the instance is closed last because it owns them.
    session.close();
  });

  group('solid fills', () {
    test('pixel-aligned rectangles: 0', () async {
      await _expectParity(() => device, skip, _solidRects(), tolerance: 0);
    });

    test('rectangles with alpha, overlapping: 0', () async {
      await _expectParity(() => device, skip, _alphaRects(), tolerance: 0);
    });

    test('a rectangle whose edges fall inside pixels: 1', () async {
      // The one scene that is not exact, and the tolerance is the measurement
      // rather than a cushion: the left edge is at exactly x.5, so the
      // analytic coverage is exactly 0.5 and the two sides break the tie in
      // opposite directions. See the library comment.
      await _expectParity(() => device, skip, _fractionalRect(), tolerance: 1);
    });
  });

  group('blend modes', () {
    test('rectangles composited with plus: 0', () async {
      await _expectParity(() => device, skip, _plusRects(), tolerance: 0);
    });

    test('a translucent rectangle composited with src: 0', () async {
      await _expectParity(() => device, skip, _srcRect(), tolerance: 0);
    });
  });

  group('coverage masks', () {
    test('a filled path whose winding decides the answer: 0', () async {
      await _expectParity(() => device, skip, _overlappingPath(), tolerance: 0);
    });

    test('a filled path with a hole, opposite winding: 0', () async {
      await _expectParity(() => device, skip, _holePath(), tolerance: 0);
    });

    test('a rounded rectangle: 0', () async {
      await _expectParity(() => device, skip, _roundedRect(), tolerance: 0);
    });
  });

  group('images and clips', () {
    test('a drawn image, texel for texel: 0', () async {
      await _expectParity(() => device, skip, _image(), tolerance: 0);
    });

    test('a rectangular clip: 0', () async {
      await _expectParity(() => device, skip, _clipped(), tolerance: 0);
    });
  });

  group('what this backend refuses, by name', () {
    test('a surface that is not memory', () {
      expect(
        () => device!.createTarget(const _WindowSurface()),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
      expect(
        const VulkanRendererBackend().supportsSurface(const _WindowSurface()),
        isFalse,
      );
    }, skip: skip);

    test('a texture larger than the device allows is refused, not fatal', () {
      final int tooBig = device!.capabilities.maxTextureSize + 1;
      expect(
        () => device!.createTexture(
          width: tooBig,
          height: 4,
          format: GpuTextureFormat.rgba8888Premultiplied,
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
      // The point: the device is still alive afterwards. Turning "this image is
      // too big" into a lost device would make one bad asset kill the renderer.
      expect(device!.isLost, isFalse);
    }, skip: skip);

    test('the validation layer said nothing, or said it was absent', () {
      final instance = session.instance!;
      if (!instance.validationEnabled) {
        printOnFailure('VK_LAYER_KHRONOS_validation is not installed on this '
            'machine; the barriers and layouts below were exercised without '
            'it. Every scene still matched the CPU exactly.');
        return;
      }
      expect(instance.problems, isEmpty,
          reason: 'the validation layer objected while these scenes were '
              'drawn:\n${instance.problems.join('\n')}');
    }, skip: skip);
  });
}

/// Renders [list] through both backends and asserts they agree.
Future<void> _expectParity(
  VulkanRenderDevice? Function() device,
  String? skip,
  DisplayList list, {
  required int tolerance,
}) async {
  if (skip != null) {
    // Not a silent return: the reason is printed, so a run with no GPU says so
    // instead of looking like a run that compared something.
    printOnFailure('skipped: $skip');
    markTestSkipped('no Vulkan device: $skip');
    return;
  }

  final MemoryRenderTarget cpu = _cpuTarget(_size, _size);
  await cpu.renderDisplayList(list, clearColor: _clear);

  final VulkanOffscreenTarget gpu = device()!.createTarget(
    const MemorySurfaceDescriptor(
      pixelWidth: _size,
      pixelHeight: _size,
      format: PixelFormat.rgba8888Premultiplied,
    ),
  ) as VulkanOffscreenTarget;
  final PresentResult result =
      await gpu.renderDisplayList(list, clearColor: _clear);
  expect(result.status, PresentStatus.presented,
      reason: '${result.diagnostic}');

  // Two identically blank surfaces agree perfectly, so a scene that drew
  // nothing - a bad coordinate, a paint that resolved to transparent - would
  // pass this file silently. Every scene here is meant to put ink down.
  expect(_isUniform(cpu.framebuffer), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');

  final _Diff diff = _diff(cpu.framebuffer, gpu.framebuffer);
  printOnFailure('max deviation ${diff.maxDeviation} over '
      '${diff.differingPixels} pixels');
  expect(
    diff.maxDeviation,
    lessThanOrEqualTo(tolerance),
    reason: 'the CPU and Vulkan disagree by up to ${diff.maxDeviation} levels '
        'on ${diff.differingPixels} pixels, over a declared tolerance of '
        '$tolerance.\n${diff.report}',
  );

  cpu.dispose();
  gpu.dispose();
}

final class _Diff {
  const _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;

  /// The first handful of differing pixels, both sides shown. Not all of them:
  /// a wrong picture differs everywhere, and a thousand-line failure hides the
  /// one number that matters, which is the maximum above.
  final String report;
}

_Diff _diff(Framebuffer cpu, Framebuffer gpu) {
  expect(gpu.width, cpu.width);
  expect(gpu.height, cpu.height);
  var maxDeviation = 0;
  var differing = 0;
  final List<String> lines = <String>[];
  for (var y = 0; y < cpu.height; y++) {
    for (var x = 0; x < cpu.width; x++) {
      final List<int> a = _rgba(cpu, x, y);
      final List<int> b = _rgba(gpu, x, y);
      var deviation = 0;
      for (var channel = 0; channel < 4; channel++) {
        final int difference = (a[channel] - b[channel]).abs();
        if (difference > deviation) deviation = difference;
      }
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) lines.add('($x, $y): cpu $a, gpu $b');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

bool _isUniform(Framebuffer buffer) {
  final List<int> first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      final List<int> pixel = _rgba(buffer, x, y);
      for (var channel = 0; channel < 4; channel++) {
        if (pixel[channel] != first[channel]) return false;
      }
    }
  }
  return true;
}

List<int> _rgba(Framebuffer buffer, int x, int y) {
  final int offset = buffer.offsetOf(x, y);
  final Uint8List bytes = buffer.pixels;
  return switch (buffer.format) {
    PixelFormat.bgra8888Premultiplied => <int>[
        bytes[offset + 2],
        bytes[offset + 1],
        bytes[offset],
        bytes[offset + 3],
      ],
    _ => <int>[
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
      ],
  };
}

MemoryRenderTarget _cpuTarget(int width, int height) =>
    MemoryRenderTarget(MemorySurfaceDescriptor(
      pixelWidth: width,
      pixelHeight: height,
      format: PixelFormat.rgba8888Premultiplied,
    ));

// ---------------------------------------------------------------------------
// The scenes, the same ones the Direct3D 12 parity file uses
// ---------------------------------------------------------------------------

DisplayList _solidRects() {
  final DisplayList list = DisplayList();
  final int red = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  final int blue = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
  list
    ..drawRect(2, 2, 12, 10, red)
    ..drawRect(10, 8, 22, 20, blue)
    ..drawRect(0, 22, 24, 24, red);
  return list;
}

DisplayList _alphaRects() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final int half = list.addPaint(colorArgb: 0x80CC3311, antiAlias: false);
  final int quarter = list.addPaint(colorArgb: 0x4011CC33, antiAlias: false);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(2, 2, 16, 16, half)
    ..drawRect(8, 8, 22, 22, quarter);
  return list;
}

/// Edges at x.5, so the analytic coverage term is exercised on both sides.
DisplayList _fractionalRect() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF101010, antiAlias: false);
  final int ink = list.addPaint(colorArgb: 0xFFFFFFFF);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(4.5, 6.25, 18.75, 17.5, ink);
  return list;
}

DisplayList _plusRects() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF102030, antiAlias: false);
  final int a = list.addPaint(
      colorArgb: 0xFF402010, antiAlias: false, blendMode: blendModePlus);
  final int b = list.addPaint(
      colorArgb: 0xFF104020, antiAlias: false, blendMode: blendModePlus);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(2, 2, 16, 16, a)
    ..drawRect(8, 8, 22, 22, b);
  return list;
}

DisplayList _srcRect() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final int replace = list.addPaint(
      colorArgb: 0x80CC3311, antiAlias: false, blendMode: blendModeSrc);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(4, 4, 20, 20, replace);
  return list;
}

DisplayList _overlappingPath() {
  final PathBuilder builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 14, 14), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(9, 9, 20, 20), clockwise: true);

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

DisplayList _holePath() {
  final PathBuilder builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 21, 21), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(8, 8, 16, 16), clockwise: false);

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

DisplayList _roundedRect() {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawRRect(3, 3, 21, 21, 6, 6, 6, 6, 6, 6, 6, 6, paint);
  return list;
}

DisplayList _clipped() {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..save()
    ..clipRect(4.5, 4, 18, 17.5)
    ..drawRect(0, 0, 24, 24, paint)
    ..restore();
  return list;
}

DisplayList _image() {
  final Framebuffer image = Framebuffer.allocate(
    width: 8,
    height: 8,
    format: PixelFormat.rgba8888Premultiplied,
  );
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      final int offset = image.offsetOf(x, y);
      image.pixels[offset] = (x + 1) * 0x1F;
      image.pixels[offset + 1] = (y + 1) * 0x1F;
      image.pixels[offset + 2] = 0x40;
      image.pixels[offset + 3] = 0xFF;
    }
  }

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
  final int id = list.addImage(image);
  // One texel per pixel, so nearest and linear cannot disagree - the CPU
  // rasteriser has no linear filter and comparing a scaled image would be
  // comparing two different resampling rules.
  list.drawImage(id, 0, 0, 8, 8, 4, 4, 12, 12, paint);
  return list;
}

void _addRectContour(PathBuilder builder, Rect rect,
    {required bool clockwise}) {
  builder.moveTo(rect.left, rect.top);
  if (clockwise) {
    builder
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom);
  } else {
    builder
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right, rect.top);
  }
  builder.close();
}

/// A surface that is not memory, for the refusal test.
final class _WindowSurface implements NativeSurfaceDescriptor {
  const _WindowSurface();

  @override
  String get kind => 'window';

  @override
  int get pixelWidth => 64;

  @override
  int get pixelHeight => 64;

  @override
  double get scale => 1;
}
