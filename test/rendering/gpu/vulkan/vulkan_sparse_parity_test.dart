/// The sparse-strip executor, on a real Vulkan device, compared with the CPU
/// rasteriser pixel by pixel.
///
/// `vulkan_cpu_parity_test.dart` does this for the dense coverage atlas and
/// `d3d12_sparse_parity_test.dart` does it for the same sparse plan on another
/// API. This file is the third leg, over deliberately the same scenes, and its
/// value is the same: `SparseStripGenerator` and `ScanlineFiller` produce
/// byte-identical alpha, so a difference here is a difference in *submission* -
/// a wrong descriptor set, a strip at the wrong device coordinate, an attribute
/// bound at the wrong input rate, a pipeline left over from the previous
/// command, a push-constant member at the wrong offset - and not a difference
/// in coverage. None of those is visible in a unit test of the plan.
///
/// It is also the last of the three checks `vulkan_spirv.dart` names. The
/// structural test proves the modules are well-formed and the pipeline test
/// proves the driver accepts them; only this file can tell a shader that
/// assembles and validates and multiplies the wrong pair of operands from one
/// that is right.
///
/// ## The tolerance, declared and measured
///
/// Measured on **Intel(R) UHD Graphics, Vulkan 1.4.323, driver 0x195bb0**.
///
/// **Zero for every solid-paint scene** - aligned rectangle, fractional
/// rectangle, diagonal quadrilateral, even-odd overlap, translucent
/// source-over, clip. All four channels, all 1024 pixels, deviation 0. The CPU
/// folds coverage into the paint with `mul255`, which is round-to-nearest of
/// `v * a / 255`; the fragment shader multiplies a premultiplied float colour
/// by a coverage byte read with an integer fetch and quantises once. On this
/// adapter they agree exactly - including the fractional-edge scene, which is
/// the one the *dense* comparison in `vulkan_cpu_parity_test.dart` has to
/// allow a level on. That is not luck and it is worth saying why: the dense
/// path evaluates `boxCoverage` in the fragment shader and can break a
/// half-covered tie the other way from the CPU, whereas here the coverage byte
/// the shader reads is the byte `ScanlineFiller` computed. The sparse
/// representation removes the disagreement rather than tolerating it.
///
/// **One level for the two gradient scenes**, and the reason is stated rather
/// than hidden: the CPU evaluates the ramp in double precision and looks the
/// colour up in a `GradientLut` by index, while the shader evaluates the same
/// parameter in float32 and *samples* the same ramp with a linear filter, so a
/// pixel whose parameter lands within half a texel of a stop boundary can take
/// the neighbouring entry. Measured: **1 level on 106 of 1024 pixels** for the
/// linear ramp and **1 level on 15 of 1024** for the focal radial one, always
/// in a single colour channel and never on alpha. The linear figure is 106 on
/// Direct3D 12 too, over the same scene - two independently written shaders
/// landing on the same 106 pixels is the ramp interpolation and not a
/// backend's arithmetic.
///
/// What the parameter must never become is the place a failure is made to go
/// away. A scene that has been exact and stops being exact is a regression.
///
/// ## The validation layer, honestly
///
/// The session below asks for `VK_LAYER_KHRONOS_validation` and the last test
/// asserts it reported nothing. **On the machine these numbers were measured
/// on the layer is not installed** - there is no Vulkan SDK on it, only the
/// Intel ICD - so what that test proved here is that the pipelines, the two
/// descriptor sets, the two push-constant ranges and the coverage barriers
/// draw the right pixels, not that a validator inspected them. On a machine
/// with the SDK the same test does check, by name, and fails loudly. The
/// distinction is printed rather than hidden, because "validation passed" and
/// "validation was absent" are not the same claim.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_backend.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_sparse_executor.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

/// One size for every scene, so a coordinate reads the same in all of them.
const int _size = 32;

/// The same number as a double, so a `Rect` covering the whole surface can be
/// a constant. `_size.toDouble()` is a method call and therefore not one.
const double _sizeF = 32;

/// Opaque, so a scene that gets its alpha wrong shows up as a colour rather
/// than as transparency nobody looks at.
const int _clear = 0xFF000000;

void main() {
  final VulkanSession session = VulkanSession.open(validation: true);
  VulkanRenderDevice? device;
  String? skip = session.skipReason;

  setUpAll(() {
    if (skip != null) return;
    try {
      device = VulkanRenderDevice.adoptInstance(
        session.instance!,
        enableExperimentalSparseStrips: true,
      );
    } on BackendSelectionError catch (error) {
      skip = 'no Vulkan render device: $error';
    }
  });
  tearDownAll(() {
    device?.dispose();
    session.close();
  });

  group('the sparse-strip pipeline exists on this device', () {
    test('the device reports the opt-in', () {
      if (skip != null) {
        markTestSkipped('no Vulkan device: $skip');
        return;
      }
      expect(device!.experimentalSparseStripsEnabled, isTrue);
    });

    test('a device opened without the flag refuses the submission', () {
      if (skip != null) {
        markTestSkipped('no Vulkan device: $skip');
        return;
      }
      // The whole shape of the opt-in, asserted: a device that was not asked
      // for sparse strips says so by name rather than silently drawing
      // nothing, and it says so before anything has been encoded or uploaded.
      final VulkanRenderDevice plain =
          VulkanRenderDevice.adoptInstance(session.instance!);
      addTearDown(plain.dispose);
      expect(plain.experimentalSparseStripsEnabled, isFalse);
      final VulkanOffscreenTarget target = _targetOn(plain);
      addTearDown(target.dispose);
      expect(
        () => target.enqueueSparseStrips(
          _planFor(_rectPath(4.5, 4.5, 20, 20), FillRule.nonZero),
          materials: <SparseVulkanMaterial>[_white()],
        ),
        throwsA(isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('enableExperimentalSparseStrips'),
        )),
      );
    });

    test('twelve pipelines were built from the emitted SPIR-V', () async {
      if (skip != null) {
        markTestSkipped('no Vulkan device: $skip');
        return;
      }
      final VulkanOffscreenTarget target = _targetOn(device!);
      addTearDown(target.dispose);
      target.enqueueSparseStrips(
        _planFor(_rectPath(4, 4, 20, 20), FillRule.nonZero),
        materials: <SparseVulkanMaterial>[_white()],
      );
      final Frame frame =
          target.beginFrame(const FrameRequest(clearColor: _clear));
      final PresentResult result = await target.present(frame);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      // A shader that stopped being emitted is a word count that halves, which
      // is the one thing a "it drew something" assertion cannot see.
      expect(target.sparseShaderWords, greaterThan(0));
      expect(target.lastSparseStats!.drawCalls, greaterThan(0));
    });
  });

  group('the CPU and the Vulkan sparse pipeline agree', () {
    test('a pixel-aligned rectangle: 0', () async {
      // Whole-pixel edges: every column is either a solid fill run or nothing,
      // so this scene exercises the solid instance path with no alpha page at
      // all. A y flip or an off-by-one in the quad would move the whole shape,
      // and Vulkan's clip space is exactly where a flip copied from the GL
      // shader would have gone unnoticed.
      // Observed deviation: 0.
      await _expectSparseParity(
        () => device,
        skip,
        _rectPath(6, 8, 24, 24),
        tolerance: 0,
        expectAlphaPages: 0,
      );
    });

    test('a rectangle with fractional edges: 0', () async {
      // Both representations at once: solid interior runs plus boundary strips
      // whose coverage arrives through an alpha8 page, a staging buffer and a
      // vkCmdCopyBufferToImage. The half-pixel edges put a partially covered
      // column on all four sides.
      // Observed deviation: 0.
      await _expectSparseParity(
        () => device,
        skip,
        _rectPath(6.5, 8.25, 23.5, 21.75),
        tolerance: 0,
        expectAlphaPages: 1,
      );
    });

    test('a diagonal quadrilateral: 0', () async {
      // Nearly every strip is a boundary strip, so this is the scene where an
      // atlas placement bug shows up: strips are packed left to right along a
      // shelf row, and an instance that read the wrong atlas origin would pick
      // up its neighbour's coverage and stay perfectly plausible.
      // Observed deviation: 0.
      await _expectSparseParity(
        () => device,
        skip,
        _diagonalPath(),
        tolerance: 0,
        expectAlphaPages: 1,
      );
    });

    test('a self-overlapping path under even-odd: 0', () async {
      // The fill rule reaches the sparse encoder through the same
      // `ScanlineFiller` the CPU uses, so the overlap is a hole on both sides.
      // Observed deviation: 0.
      await _expectSparseParity(
        () => device,
        skip,
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
        () => device,
        skip,
        _rectPath(5.5, 5.5, 24.5, 24.5),
        argb: 0x8033CC55,
        tolerance: 0,
        expectAlphaPages: 1,
      );
    });

    test('a clipped path: 0', () async {
      // The sparse encoder takes the clip as the filler's clip rather than as
      // a scissor, so this asserts that the two produce the same edge. The
      // clip is deliberately not pixel aligned.
      // Observed deviation: 0.
      await _expectSparseParity(
        () => device,
        skip,
        _rectPath(4, 4, 28, 28),
        clip: const Rect.fromLTRB(8.5, 6, 21, 23.5),
        tolerance: 0,
        expectAlphaPages: 1,
      );
    });

    test('a linear gradient through the shared LUT: 1', () async {
      // The second descriptor set, the push-constant transform rows and the
      // straight-alpha premultiply, all at once.
      await _expectGradientParity(
        () => device,
        skip,
        LinearGradient(
          startX: 6,
          startY: 6,
          endX: 26,
          endY: 26,
          stops: <GradientStop>[
            const GradientStop(0, 0xFF2040C0),
            const GradientStop(0.5, 0xFFF0C020),
            const GradientStop(1, 0xFF20C040),
          ],
        ),
        tolerance: 1,
      );
    });

    test('a radial gradient with a focus, reflected: 1', () async {
      // The branchless focal solve and the reflect spread, which are the two
      // places `OpSelect` stands in for a branch the GLSL writes with `if`.
      // A shader that reflected through the wrong half, or that let the
      // discarded operand's NaN escape, produces a plausible and wrong ramp -
      // which is exactly what a pixel comparison catches and a unit test of
      // the plan cannot.
      await _expectGradientParity(
        () => device,
        skip,
        RadialGradient(
          centerX: 16,
          centerY: 16,
          radius: 9,
          focusX: 12,
          focusY: 13,
          spread: GradientSpread.reflect,
          stops: <GradientStop>[
            const GradientStop(0, 0xFFE03020),
            const GradientStop(1, 0xFF2050E0),
          ],
        ),
        tolerance: 1,
      );
    });
  });

  test('the validation layer said nothing, or said it was absent', () {
    if (skip != null) {
      markTestSkipped('no Vulkan device: $skip');
      return;
    }
    final instance = session.instance!;
    if (!instance.validationEnabled) {
      printOnFailure('VK_LAYER_KHRONOS_validation is not installed on this '
          'machine; the pipelines, descriptor sets, push-constant ranges and '
          'barriers above were exercised without it. Every solid scene still '
          'matched the CPU exactly.');
      return;
    }
    expect(instance.problems, isEmpty,
        reason: 'the validation layer objected while the sparse pass ran:\n'
            '${instance.problems.join('\n')}');
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

Path _rectPath(double left, double top, double right, double bottom) {
  final PathBuilder builder = PathBuilder();
  _addRect(builder, Rect.fromLTRB(left, top, right, bottom));
  return builder.build();
}

Path _twoRectsPath() {
  final PathBuilder builder = PathBuilder();
  _addRect(builder, const Rect.fromLTRB(4, 4, 20, 20));
  _addRect(builder, const Rect.fromLTRB(12, 12, 28, 28));
  return builder.build();
}

Path _diagonalPath() => (PathBuilder()
      ..moveTo(3, 27)
      ..lineTo(16, 4)
      ..lineTo(29, 27)
      ..lineTo(16, 20)
      ..close())
    .build();

void _addRect(PathBuilder builder, Rect rect) {
  builder
    ..moveTo(rect.left, rect.top)
    ..lineTo(rect.right, rect.top)
    ..lineTo(rect.right, rect.bottom)
    ..lineTo(rect.left, rect.bottom)
    ..close();
}

SparseVulkanMaterial _white() => SparseVulkanMaterial(
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

VulkanOffscreenTarget _targetOn(VulkanRenderDevice device) =>
    device.createTarget(const MemorySurfaceDescriptor(
      pixelWidth: _size,
      pixelHeight: _size,
      format: PixelFormat.rgba8888Premultiplied,
    )) as VulkanOffscreenTarget;

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

Future<void> _expectSparseParity(
  VulkanRenderDevice? Function() device,
  String? skip,
  Path path, {
  required int tolerance,
  required int expectAlphaPages,
  FillRule fillRule = FillRule.nonZero,
  int argb = 0xFFFFFFFF,
  Rect clip = const Rect.fromLTRB(0, 0, _sizeF, _sizeF),
}) async {
  if (skip != null) {
    printOnFailure('skipped: $skip');
    markTestSkipped('no Vulkan device: $skip');
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

  final VulkanOffscreenTarget gpu = _targetOn(device()!);
  gpu.enqueueSparseStrips(
    plan,
    materials: <SparseVulkanMaterial>[_materialFor(argb)],
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
    reason: 'the CPU and the sparse Vulkan pipeline disagree by up to '
        '${diff.maxDeviation} levels on ${diff.differingPixels} pixels, over '
        'a declared tolerance of $tolerance.\n${diff.report}',
  );

  cpu.dispose();
  gpu.dispose();
}

/// A gradient scene, which needs a resident LUT and therefore a device.
Future<void> _expectGradientParity(
  VulkanRenderDevice? Function() device,
  String? skip,
  Gradient gradient, {
  required int tolerance,
}) async {
  if (skip != null) {
    printOnFailure('skipped: $skip');
    markTestSkipped('no Vulkan device: $skip');
    return;
  }

  final Path path = _rectPath(6.5, 6.5, 25.5, 25.5);
  const Rect clip = Rect.fromLTRB(0, 0, _sizeF, _sizeF);

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, gradient: gradient);
  list.drawPath(list.addPath(path), paint);
  final MemoryRenderTarget cpu = _cpuTarget();
  await cpu.renderDisplayList(list, clearColor: _clear);

  final VulkanRenderDevice open = device()!;
  final GpuGradientCache cache = GpuGradientCache(allocator: open);
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

  final VulkanOffscreenTarget gpu = _targetOn(open);
  gpu.enqueueSparseStrips(
    _planFor(path, FillRule.nonZero, clip: clip),
    materials: <SparseVulkanMaterial>[
      SparseVulkanMaterial.gradient(
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
    reason: 'the CPU and the sparse Vulkan gradient disagree by up to '
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

SparseVulkanMaterial _materialFor(int argb) {
  final double alpha = ((argb >> 24) & 0xFF) / 255.0;
  return SparseVulkanMaterial(
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
