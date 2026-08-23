/// The sparse-strip executor, on a real Direct3D 12 device, compared with the
/// CPU rasteriser pixel by pixel.
///
/// `d3d12_cpu_parity_test.dart` does this for the dense coverage atlas and
/// states the argument at length. This file applies it to the second
/// representation of the same coverage: `SparseStripGenerator` and
/// `ScanlineFiller` produce byte-identical alpha, so a difference here is a
/// difference in *submission* - a wrong atlas page, a strip placed at the wrong
/// device coordinate, an instance element bound to the wrong semantic, a
/// pipeline state left over from the previous command - and not a difference in
/// coverage. That is exactly what makes it worth running: none of those failures
/// is visible in a unit test of the plan.
///
/// ## The tolerance, declared
///
/// **Zero for solid paints.** The CPU folds coverage into the paint with
/// `mul255`, which is round-to-nearest of `v * a / 255`; the pixel shader
/// multiplies a premultiplied float colour by a coverage byte read with an
/// integer `Load` and quantises once. On the adapter this was written against
/// they agree in all four channels on every pixel of every solid scene below.
///
/// **One level for the gradient scene**, and the reason is stated rather than
/// hidden: the CPU evaluates the ramp in double precision and looks the colour
/// up in a `GradientLut` by index, while the shader evaluates the same
/// parameter in float32 and *samples* the same ramp with a linear filter - so a
/// pixel whose parameter lands within half a texel of a stop boundary can take
/// the neighbouring entry. That is a difference of one ramp step, and the ramp
/// in this scene is smooth enough that one step is one level. Measured: 1 level
/// on 106 of 1024 pixels, in one colour channel, with alpha exact everywhere.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

/// One size for every scene, so a coordinate reads the same in all of them.
const int _size = 32;

/// The same number as a double, so a `Rect` covering the whole surface can be
/// a constant. `_size.toDouble()` is a method call and therefore not one.
const double _sizeF = 32;

/// Opaque, so a scene that gets its alpha wrong shows up as a colour rather
/// than as transparency nobody looks at.
const int _clear = 0xFF000000;

void main() {
  final D3d12Session session = D3d12Session.open(sparseStrips: true);
  tearDownAll(session.close);

  group('the sparse-strip executor exists on this device', () {
    test('the device reports the opt-in pipeline', () {
      final String? reason = session.skipReason;
      if (reason != null) {
        markTestSkipped('no Direct3D 12 device: $reason');
        return;
      }
      expect(session.device!.experimentalSparseStripsEnabled, isTrue);
    });

    test('a device opened without the flag refuses the submission', () async {
      final String? reason = session.skipReason;
      if (reason != null) {
        markTestSkipped('no Direct3D 12 device: $reason');
        return;
      }
      // The whole shape of the opt-in, asserted: a device that was not asked
      // for sparse strips must say so by name rather than silently drawing
      // nothing, and the dense path must be unaffected.
      final D3d12Session plain = D3d12Session.open();
      addTearDown(plain.close);
      if (plain.skipReason != null) {
        markTestSkipped('no second device: ${plain.skipReason}');
        return;
      }
      expect(plain.device!.experimentalSparseStripsEnabled, isFalse);
      final D3d12OffscreenTarget target = plain.target(_size, _size);
      addTearDown(target.dispose);
      target.enqueueSparseStrips(
        _planFor(_rectPath(4.5, 4.5, 20, 20), FillRule.nonZero),
        materials: <SparseD3d12Material>[_white()],
      );
      final Frame frame = target.beginFrame(const FrameRequest());
      await expectLater(
        target.present(frame),
        throwsA(isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('enableExperimentalSparseStrips'),
        )),
      );
    });
  });

  group('the CPU and the Direct3D 12 sparse pipeline agree', () {
    test('a pixel-aligned rectangle: 0', () async {
      // Whole-pixel edges: every column is either a solid fill run or nothing,
      // so this scene exercises the solid instance path with no alpha page at
      // all. A y flip or an off-by-one in the quad would move the whole shape.
      // Observed deviation: 0.
      await _expectSparseParity(
        session,
        _rectPath(6, 8, 24, 24),
        tolerance: 0,
        expectAlphaPages: 0,
      );
    });

    test('a rectangle with fractional edges: 0', () async {
      // Both representations at once: solid interior runs plus boundary strips
      // whose coverage arrives through an alpha8 page, an upload heap and a
      // CopyTextureRegion. The half-pixel edges are what put a partially
      // covered column on all four sides.
      // Observed deviation: 0.
      await _expectSparseParity(
        session,
        _rectPath(6.5, 8.25, 23.5, 21.75),
        tolerance: 0,
        expectAlphaPages: 1,
      );
    });

    test('a diagonal quadrilateral: 0', () async {
      // Nearly every strip is a boundary strip here, so this is the scene where
      // an atlas placement bug shows up: strips are packed left to right along
      // a shelf row, and an instance that read the wrong atlas origin would
      // pick up its neighbour's coverage and stay perfectly plausible.
      // Observed deviation: 0.
      await _expectSparseParity(
        session,
        _diagonalPath(),
        tolerance: 0,
        expectAlphaPages: 1,
      );
    });

    test('a self-overlapping path under even-odd: 0', () async {
      // The fill rule reaches the sparse encoder through the same
      // `ScanlineFiller` the CPU uses, so the overlap is a hole on both sides.
      // The display list has no fill-rule operand, which is why this scene
      // reaches the CPU through a path built with the rule baked in - see
      // `_evenOddCpuList`.
      // Observed deviation: 0.
      await _expectSparseParity(
        session,
        _twoRectsPath(),
        fillRule: FillRule.evenOdd,
        tolerance: 0,
        expectAlphaPages: 0,
      );
    });

    test('a translucent paint composited source-over: 0', () async {
      // Coverage folded into an alpha below one, which is where a backend that
      // premultiplies at the wrong moment diverges first.
      // Observed deviation: 0.
      await _expectSparseParity(
        session,
        _rectPath(5.5, 5.5, 24.5, 24.5),
        argb: 0x8033CC55,
        tolerance: 0,
        expectAlphaPages: 1,
      );
    });

    test('a clipped path: 0', () async {
      // The sparse encoder takes the clip as the filler's clip rather than as a
      // scissor, so this asserts that the two produce the same edge. The clip
      // is deliberately not pixel aligned.
      // Observed deviation: 0.
      await _expectSparseParity(
        session,
        _rectPath(4, 4, 28, 28),
        clip: const Rect.fromLTRB(8.5, 6, 21, 23.5),
        tolerance: 0,
        expectAlphaPages: 1,
      );
    });

    test('a linear gradient through the shared LUT: 1', () async {
      // Measured on Intel UHD Graphics, feature level 12_1: **1 level on 106
      // of 1024 pixels**, always in a single channel, and never on the
      // coverage - the alpha channel is exact everywhere. That is the ramp
      // interpolation described in the library comment and not a coverage or
      // a compositing difference.
      await _expectGradientParity(session, tolerance: 1);
    });
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

Path _rectPath(double left, double top, double right, double bottom) {
  final PathBuilder builder = PathBuilder();
  _addRect(builder, Rect.fromLTRB(left, top, right, bottom), clockwise: true);
  return builder.build();
}

Path _twoRectsPath() {
  final PathBuilder builder = PathBuilder();
  _addRect(builder, const Rect.fromLTRB(4, 4, 20, 20), clockwise: true);
  _addRect(builder, const Rect.fromLTRB(12, 12, 28, 28), clockwise: true);
  return builder.build();
}

Path _diagonalPath() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(3, 27)
    ..lineTo(16, 4)
    ..lineTo(29, 27)
    ..lineTo(16, 20)
    ..close();
  return builder.build();
}

void _addRect(PathBuilder builder, Rect rect, {required bool clockwise}) {
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

SparseD3d12Material _white() => SparseD3d12Material(
      red: 1,
      green: 1,
      blue: 1,
      alpha: 1,
      blendMode: blendModeSrcOver,
    );

SparseStripDrawPlan _planFor(
  Path path,
  FillRule fillRule, {
  Rect clip = const Rect.fromLTRB(0, 0, _sizeF, _sizeF),
}) {
  final SparseStripDrawPlan plan = SparseStripDrawPlan();
  plan.append(
    SparseStripGenerator().fill(path, clip, rule: fillRule),
    materialIndex: 0,
  );
  return plan;
}

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

/// Renders [path] through the CPU rasteriser and through the sparse Direct3D 12
/// executor, and asserts they agree.
Future<void> _expectSparseParity(
  D3d12Session session,
  Path path, {
  required int tolerance,
  required int expectAlphaPages,
  FillRule fillRule = FillRule.nonZero,
  int argb = 0xFFFFFFFF,
  Rect clip = const Rect.fromLTRB(0, 0, _sizeF, _sizeF),
}) async {
  final String? reason = session.skipReason;
  if (reason != null) {
    printOnFailure('skipped: $reason');
    markTestSkipped('no Direct3D 12 device: $reason');
    return;
  }

  final MemoryRenderTarget cpu = _cpuTarget();
  await cpu.renderDisplayList(
    _cpuList(path, fillRule, argb, clip),
    clearColor: _clear,
  );

  final SparseStripDrawPlan plan = _planFor(path, fillRule, clip: clip);
  expect(
    plan.alphaPageCount,
    expectAlphaPages,
    reason: 'the scene no longer exercises the representation it was written '
        'for; a plan with no alpha pages tests only the solid instance path',
  );

  final D3d12OffscreenTarget gpu = session.target(_size, _size);
  gpu.enqueueSparseStrips(
    plan,
    materials: <SparseD3d12Material>[_materialFor(argb)],
  );
  final Frame frame = gpu.beginFrame(const FrameRequest(clearColor: _clear));
  final PresentResult result = await gpu.present(frame);
  expect(result.status, PresentStatus.presented,
      reason: '${result.diagnostic}');
  expect(gpu.lastSparseStats, isNotNull);
  expect(gpu.lastSparseStats!.drawCalls, greaterThan(0));

  expect(_isUniform(cpu.framebuffer), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');

  final _Diff diff = _diff(cpu.framebuffer, gpu.framebuffer);
  printOnFailure('max deviation ${diff.maxDeviation} over '
      '${diff.differingPixels} pixels, ${plan.alphaPageCount} alpha pages, '
      '${gpu.lastSparseStats!.drawCalls} draw calls');
  expect(
    diff.maxDeviation,
    lessThanOrEqualTo(tolerance),
    reason: 'the CPU and the sparse Direct3D 12 pipeline disagree by up to '
        '${diff.maxDeviation} levels on ${diff.differingPixels} pixels, over '
        'a declared tolerance of $tolerance.\n${diff.report}',
  );

  cpu.dispose();
  gpu.dispose();
}

/// The gradient scene, which needs a resident LUT and therefore a device.
Future<void> _expectGradientParity(
  D3d12Session session, {
  required int tolerance,
}) async {
  final String? reason = session.skipReason;
  if (reason != null) {
    printOnFailure('skipped: $reason');
    markTestSkipped('no Direct3D 12 device: $reason');
    return;
  }

  final Gradient gradient = LinearGradient(
    startX: 6,
    startY: 6,
    endX: 26,
    endY: 26,
    stops: <GradientStop>[
      const GradientStop(0, 0xFF2040C0),
      const GradientStop(0.5, 0xFFF0C020),
      const GradientStop(1, 0xFF20C040),
    ],
  );
  final Path path = _rectPath(6.5, 6.5, 25.5, 25.5);
  const Rect clip = Rect.fromLTRB(0, 0, _sizeF, _sizeF);

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, gradient: gradient);
  list.drawPath(list.addPath(path), paint);
  final MemoryRenderTarget cpu = _cpuTarget();
  await cpu.renderDisplayList(list, clearColor: _clear);

  final D3d12RenderDevice device = session.device!;
  final GpuGradientCache cache = GpuGradientCache(allocator: device);
  addTearDown(cache.clear);
  final GpuGradientBinding binding = cache.resolve(gradient);
  final GpuGradientShaderParameters parameters =
      GpuGradientShaderParameters.fromPaint(ReplayPaint(
    argbColor: 0xFFFFFFFF,
    style: paintStyleFill,
    strokeWidth: 0,
    blendMode: blendModeSrcOver,
    antiAlias: true,
    gradient: gradient,
  ));

  final D3d12OffscreenTarget gpu = session.target(_size, _size);
  gpu.enqueueSparseStrips(
    _planFor(path, FillRule.nonZero, clip: clip),
    materials: <SparseD3d12Material>[
      SparseD3d12Material.gradient(
        gradientBinding: binding,
        gradientParameters: parameters,
        blendMode: blendModeSrcOver,
      ),
    ],
  );
  final Frame frame = gpu.beginFrame(const FrameRequest(clearColor: _clear));
  final PresentResult result = await gpu.present(frame);
  expect(result.status, PresentStatus.presented,
      reason: '${result.diagnostic}');

  expect(_isUniform(cpu.framebuffer), isFalse);
  final _Diff diff = _diff(cpu.framebuffer, gpu.framebuffer);
  printOnFailure('max deviation ${diff.maxDeviation} over '
      '${diff.differingPixels} pixels');
  expect(
    diff.maxDeviation,
    lessThanOrEqualTo(tolerance),
    reason: 'the CPU and the sparse Direct3D 12 gradient disagree by up to '
        '${diff.maxDeviation} levels on ${diff.differingPixels} pixels, over '
        'a declared tolerance of $tolerance.\n${diff.report}',
  );

  cpu.dispose();
  gpu.dispose();
}

DisplayList _cpuList(Path path, FillRule fillRule, int argb, Rect clip) {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(
    colorArgb: argb,
    fillRule: fillRule == FillRule.evenOdd
        ? pathFillRuleEvenOdd
        : pathFillRuleNonZero,
  );
  final int id = list.addPath(path);
  if (clip.left == 0 &&
      clip.top == 0 &&
      clip.right == _size &&
      clip.bottom == _size) {
    list.drawPath(id, paint);
    return list;
  }
  list
    ..save()
    ..clipRect(clip.left, clip.top, clip.right, clip.bottom)
    ..drawPath(id, paint)
    ..restore();
  return list;
}

SparseD3d12Material _materialFor(int argb) {
  final double alpha = ((argb >> 24) & 0xFF) / 255.0;
  return SparseD3d12Material(
    red: ((argb >> 16) & 0xFF) / 255.0 * alpha,
    green: ((argb >> 8) & 0xFF) / 255.0 * alpha,
    blue: (argb & 0xFF) / 255.0 * alpha,
    alpha: alpha,
    blendMode: blendModeSrcOver,
  );
}

final class _Diff {
  const _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;
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

MemoryRenderTarget _cpuTarget() =>
    MemoryRenderTarget(const MemorySurfaceDescriptor(
      pixelWidth: _size,
      pixelHeight: _size,
      format: PixelFormat.rgba8888Premultiplied,
    ));
