/// The closed-form rounded rectangle on Vulkan, against the route it replaces.
///
/// `d3d11_analytic_primitive_test.dart` and `gl_analytic_primitive_test.dart`
/// make this measurement for the other two backends and state the argument at
/// length; it is not repeated. In one paragraph:
/// `GpuPathStrategy.analyticPrimitive` is the one route in this renderer that
/// changes *which rasteriser* computes a shape's coverage rather than where the
/// answer is stored. Every other route ultimately takes its antialiasing from
/// `ScanlineFiller`, which fills the corner arc **flattened into a polyline** at
/// a quarter of a device pixel; this one evaluates a signed distance field in
/// the fragment stage. A distance field and an area integrator are not the same
/// function, so the question is not "does it draw a rounded rectangle" but
/// **how far** from the route it replaces it draws one, and where that is worst.
///
/// ## Why Vulkan is the hard port, and what could go wrong here only
///
/// GL is handed GLSL and D3D11 is handed HLSL; a driver compiles the text. This
/// backend has no such entry point - `vkCreateShaderModule` takes SPIR-V words
/// and nothing else, and `vulkan_spirv.dart` explains why the words are emitted
/// in Dart rather than checked in as a blob. So the failure available here and
/// nowhere else is a **hand-emitted instruction stream that assembles, passes
/// the validator, creates a pipeline, and computes the wrong number**. Nothing
/// throws on that path. It is exactly the shape of the bug this backend already
/// shipped once with the glyph atlas, where "Vulkan draws text" was concluded
/// from the absence of an exception.
///
/// Two independent guards, therefore, and both are needed:
///
///   * **the instruction stream**, decoded and asserted below - the select is
///     an `OpSelect` and not a branch, the comparison is `>= 0.5` and not an
///     equality, the field really calls `Length` and `FAbs`. A pixel test can
///     pass with the wrong instruction if the scene does not reach the case it
///     breaks; this cannot.
///   * **the pixels**, rendered twice through one device - once with
///     [VulkanRenderDevice.analyticPrimitivesEnabled] false, which is the dense
///     coverage atlas, and once with it true - and subtracted. No expectation
///     is written by hand anywhere in this file.
///
/// ## The tolerances measure the *dense* route's error, not the shader's
///
/// This was chased down on OpenGL, rediscovered on Direct3D 11, and must not be
/// rediscovered a third time. A chord cuts *inside* the arc it replaces, so the
/// dense route has always drawn every rounded corner slightly too sharp, and
/// the deviation therefore **grows with the radius** rather than shrinking with
/// it. `gl_analytic_primitive_test.dart`'s `_theClosedFormIsTheAccurateOne`
/// pins that against a 400x400 point sample of the exact circle - a reference
/// neither rasteriser is derived from - and finds the closed form out by at
/// most 0.035 of a pixel's area against the flattened polygon's 0.164. That
/// measurement is CPU code shared by every backend, so it is proved once there.
///
/// What is backend-specific, and what this file asserts, is that the SPIR-V
/// transcription lands in the same band the GLSL original and the HLSL port
/// did. Each pixel test states the deviation it measured; the tolerances are
/// the GL and D3D11 files' own numbers, unchanged, because a hand-emitted
/// shader that needed a *wider* band than a driver-compiled one would be the
/// finding rather than the baseline. [_expectDifferenceOnlyOnCornerArcs] adds
/// the structural claim that makes a band meaningful at all: the four straight
/// edges and the whole interior agree **exactly**, and every pixel that moved
/// is on a corner arc.
///
/// The tolerance is never the place a failure is made to go away. A scene that
/// deviated by 32 levels and starts deviating by 320 is a regression even
/// though both are "some difference at an antialiased corner".
library;

import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/vector/analytic_primitive.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_backend.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_spirv.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

/// Big enough that a 40px radius fits and small enough that a failure prints a
/// picture a person can read. The same size the GL and D3D11 twins use, so a
/// tolerance can be compared between the three files without rescaling it.
const int _size = 64;
const int _clear = 0xFF000000;

// The handful of opcodes this file decodes. Declared here rather than exported
// from `vulkan_spirv.dart` for the reason that file gives about its own
// constants: a number nobody uses is a number nobody checks, and a test that
// re-derives the number it is checking against checks nothing.
const int _opExtInst = 12;
const int _opConstant = 43;
const int _opLabel = 248;
const int _opSelect = 169;
const int _opFOrdEqual = 180;
const int _opFOrdGreaterThanEqual = 190;
const int _opSelectionMerge = 247;
const int _opBranchConditional = 250;

void main() {
  group('the encoding that crosses into SPIR-V', () {
    test('the shape code is the one the enum publishes', () {
      // The solid module compares an interpolated float against a literal and
      // `gpu_raster_sink.dart` writes `AnalyticPrimitiveKind.rounded.shaderCode`
      // into that float. Nothing in the type system connects the two: the
      // enum's own comment says those integers may be added to but not
      // renumbered precisely because they cross this boundary, and this is what
      // makes the promise enforceable rather than aspirational.
      expect(
          kVulkanAnalyticRoundedRect, AnalyticPrimitiveKind.rounded.shaderCode);
      expect(kVulkanAnalyticNone, 0);
    });

    test('Vulkan and OpenGL decode the same two floats', () {
      // The sink writes one vertex and every backend reads it. If two shaders
      // disagreed about what a code meant, the same display list would draw two
      // different pictures on one machine depending on which backend the policy
      // opened - and every golden in this repository is rendered through one
      // backend at a time, so nothing would catch it.
      expect(kVulkanAnalyticRoundedRect, kAnalyticRoundedRect);
      expect(kVulkanAnalyticNone, kAnalyticNone);
    });
  });

  group('the instruction stream, which is the part no driver checks', () {
    final Uint32List solid =
        VulkanShaderCode().fragmentFor(GpuPipelineKind.solid);
    final List<_Instruction> decoded = _decode(solid);

    test('the shape code is tested on a threshold, not on an equality', () {
      // The shape code arrives interpolated across the quad. It is written
      // identically on all four corners so it *should* arrive constant, but a
      // driver is entitled to reconstruct 1.0 as 0.99999994 at the pixel
      // centre, and an `== 1.0` test would then silently draw a plain rectangle
      // where a rounded one was asked for - on some hardware only, which is the
      // worst kind of only, and the hardware this suite runs on is exactly the
      // hardware that would keep passing.
      //
      // The GL and D3D11 twins assert this by searching their shader *source*
      // for the text `>= 0.5`. Here the source is the instruction stream, so
      // the assertion is stronger than a string match: the comparison exists,
      // there is exactly one of it, its right-hand operand is the constant
      // 0.5, and no ordered equality is emitted anywhere in the module.
      final List<_Instruction> comparisons = decoded
          .where((_Instruction i) => i.opcode == _opFOrdGreaterThanEqual)
          .toList();
      expect(comparisons, hasLength(1));
      expect(
          decoded.where((_Instruction i) => i.opcode == _opFOrdEqual), isEmpty);

      // Operands of OpFOrdGreaterThanEqual: result type, result id, operand 1,
      // operand 2. The right-hand side must be the id of a float constant whose
      // bits are those of 0.5 - a threshold at 0.75 or at 1.0 would pass a
      // count and fail here.
      final int rightHandSide = comparisons.single.operands[3];
      expect(_floatConstants(decoded)[rightHandSide], 0.5,
          reason: 'the threshold the shape code is compared against is not '
              '0.5, so a driver that interpolates 1.0 imprecisely could take '
              'the wrong arm');
    });

    test('the arm is an OpSelect and the module is still one block', () {
      // `vulkan_shaders.dart` promises the closed form did not cost this
      // backend its straight-line SSA, and this is that promise as an
      // assertion. A branch would be an `OpSelectionMerge` plus an
      // `OpBranchConditional` plus at least three labels, and would need a
      // builder that tracks which block it is writing into - machinery
      // `vulkan_spirv.dart` explicitly declines to grow until a shader needs a
      // loop.
      expect(decoded.where((_Instruction i) => i.opcode == _opSelect),
          hasLength(1));
      expect(decoded.where((_Instruction i) => i.opcode == _opSelectionMerge),
          isEmpty);
      expect(
          decoded.where((_Instruction i) => i.opcode == _opBranchConditional),
          isEmpty);
      expect(decoded.where((_Instruction i) => i.opcode == _opLabel),
          hasLength(1));
    });

    test('the field is Length and FAbs, the instructions the GLSL names', () {
      // Not a style preference. `length(max(q, 0.0))` and `sqrt(dot(v, v))` are
      // the same real number and a different float32 once a driver has chosen
      // its own contraction for each, and a half-covered pixel that lands on a
      // quantisation boundary then rounds one level the other way along every
      // rounded edge. `vulkan_cpu_parity_test.dart` asserts this shape at
      // tolerance 0, so "algebraically equivalent" is not good enough and this
      // test is what says so before the pixels do.
      final Set<int> extended = decoded
          .where((_Instruction i) => i.opcode == _opExtInst)
          // Operands: result type, result id, set, instruction, args...
          .map((_Instruction i) => i.operands[3])
          .toSet();
      expect(extended, contains(kGlslStd450Length));
      expect(extended, contains(kGlslStd450FAbs));
      expect(extended, contains(kGlslStd450FClamp));
      // And the alternative spelling really is absent, rather than merely
      // unused: a `Sqrt` here would mean somebody expanded `Length` by hand.
      expect(extended, isNot(contains(kGlslStd450Sqrt)));
    });

    test('only the solid module carries the field', () {
      // A coverage mask and a textured image get their antialiasing from the
      // mask they sample; a distance field in either would be dead arithmetic
      // executed per pixel, and its presence would mean the builder stopped
      // distinguishing the modes - the failure a `switch` with a wrong default
      // produces.
      final VulkanShaderCode code = VulkanShaderCode();
      for (final GpuPipelineKind kind in <GpuPipelineKind>[
        GpuPipelineKind.coverageMask,
        GpuPipelineKind.texturedImage,
      ]) {
        final List<_Instruction> other = _decode(code.fragmentFor(kind));
        expect(other.where((_Instruction i) => i.opcode == _opSelect), isEmpty,
            reason: '${kind.name} grew a select it has no use for');
        expect(
            other
                .where((_Instruction i) => i.opcode == _opExtInst)
                .map((_Instruction i) => i.operands[3]),
            isNot(contains(kGlslStd450Length)),
            reason: '${kind.name} grew the distance field');
      }
    });
  });

  group('pixels, against the coverage atlas the closed form replaces', () {
    final _VulkanRoutes routes = _VulkanRoutes.open();
    tearDownAll(routes.close);

    test('an ordinary rounded rectangle, radius 8', () async {
      // The shape a button is, and the headline case of this whole change.
      // Observed here: 32 levels per channel over 60 pixels of 4096, every one
      // of them on a corner arc - the same 32 over the same 60 the GL and
      // D3D11 twins record, on the same scene. Three shaders written in three
      // languages agreeing to the pixel is what a correct transcription looks
      // like.
      await _expectRouteParity(routes, _button(), tolerance: 32);
    });

    test('a one-pixel radius', () async {
      // Expected to be the worst case and it is the best one. At radius 1 a
      // quarter-pixel flattening tolerance cannot be reached - the whole arc is
      // a pixel across - so the two rasterisers have almost nothing to disagree
      // about, and what is left is four corner pixels.
      await _expectRouteParity(routes, _tinyRadius(), tolerance: 18);
    });

    test('a pill, radius exactly half the short side', () async {
      // The clamping boundary. Both routes must apply the same overrun rule -
      // `PathBuilder.addRoundedRectPerCorner`'s single global factor - or the
      // shapes would differ in *size* rather than at their edges, which would
      // show up here as hundreds of differing pixels instead of a rim.
      await _expectRouteParity(routes, _pill(), tolerance: 37);
    });

    test('a radius larger than half the side, clamped', () async {
      // Asked for 40 on a 24-tall box. Whatever the two do here they must do
      // together; a disagreement about clamping is a different shape, not a
      // different edge.
      await _expectRouteParity(routes, _overrun(), tolerance: 37);
    });

    test('a circle, a square at radius half its side', () async {
      // The degenerate rounded rectangle, and the one where an off-by-one in
      // the clamp would produce a visible flat spot rather than a soft edge.
      await _expectRouteParity(routes, _circle(), tolerance: 41);
    });

    test('zero radius, which must be the plain rectangle path', () async {
      // The redirect in `GpuRasterSink._fillAnalyticRRect` asserted end to end.
      // A rounded rectangle with no rounding has to come out as the rectangle
      // it is, drawn by `boxCoverage`, not as a radius-zero distance field: the
      // two disagree at the four corner pixels, where the separable area of a
      // pixel centred on a square corner is a quarter and the field says a
      // half.
      //
      // One level, on the corner pixels, and it is the difference this renderer
      // has always had between `boxCoverage` and `ScanlineFiller`: the CPU
      // quantises positions to 1/255ths of a pixel per axis and the shader
      // stays in float. Anything larger than one means the redirect stopped
      // happening and the field is drawing corners it must not draw.
      await _expectRouteParity(routes, _squareCorners(), tolerance: 1);
    });

    test('translucent and overlapping', () async {
      // Coverage times alpha times source-over, twice, so an error in the
      // coverage is amplified by the blend rather than hidden by it.
      await _expectRouteParity(routes, _translucent(), tolerance: 12);
    });

    test('a stroked rounded rectangle is refused by both routes', () async {
      // The player converts a stroked rrect to its centreline path before the
      // sink sees it and `PathStroker` turns that into a two-contour annulus,
      // which is not one of the closed forms. Refused by both routes, so this
      // is the assertion that the refusal is total: not one pixel may move.
      await _expectRouteParity(routes, _stroked(), tolerance: 0);
    });

    test('per-corner radii are refused by both routes', () async {
      // Two floats hold one radius and one shape code; a second radius has
      // nowhere to go. Drawing all four corners at the first radius would be a
      // wrong picture chosen for speed, so the shape keeps the atlas and the
      // picture must be byte-identical. This is also the standing answer to
      // "why not ellipses and capsules too": the vertex layout, not the
      // shader.
      await _expectRouteParity(routes, _perCorner(), tolerance: 0);
    });

    test('every pixel that moved is on a corner arc', () async {
      // The structural half of the claim, and the one that separates "the
      // closed form rounds a corner slightly differently" from "the shader is
      // wrong". A field evaluated against the wrong box, a radius decoded from
      // the wrong vertex float, a quad snapped the wrong way or a texture
      // coordinate read where a device position was meant would all move pixels
      // on a straight edge or in the interior, where `0.5 - d` and the filler's
      // area are provably the same quantity.
      await _expectDifferenceOnlyOnCornerArcs(
        routes,
        _button(),
        box: const Rect.fromLTRB(8, 18, 56, 46),
        radius: 8,
      );
    });
  });

  group('what it costs, which is what it was for', () {
    final _VulkanRoutes routes = _VulkanRoutes.open();
    tearDownAll(routes.close);

    test('the atlas is never touched for the analytic scene', () async {
      if (routes.skipped()) return;
      // Stronger evidence than a frame time, because it cannot be confounded by
      // driver scheduling: the same scene through the same target, and the CPU
      // rasterisation count goes from one per shape per frame to zero.
      //
      // This is also the assertion that would catch the failure this framework
      // treats as a bug rather than a safety net - a GPU path that quietly
      // falls back to the CPU. A Vulkan backend that drew the right picture by
      // rasterising every rounded rectangle on the CPU would pass every pixel
      // test in this file and fail here.
      final VulkanOffscreenTarget target = routes.target(_size, _size);
      final DisplayList list = _grid();

      routes.device.analyticPrimitivesEnabled = false;
      await target.renderDisplayList(list, clearColor: _clear);
      final int dense = target.maskAtlas.rasterizationCount;

      routes.device.analyticPrimitivesEnabled = true;
      await target.renderDisplayList(list, clearColor: _clear);
      final int analytic = target.maskAtlas.rasterizationCount - dense;

      printOnFailure('rasterisations per frame: dense $dense, '
          'analytic $analytic');
      expect(dense, greaterThan(0),
          reason: 'if the dense route stopped rasterising these, the '
              'comparison is measuring nothing');
      expect(analytic, 0);
      target.dispose();
    });

    test('an analytic quad joins the batch the plain rectangles are in',
        () async {
      if (routes.skipped()) return;
      // The claim the encoding was chosen for, and the reason the closed form
      // did not become a fourth fragment module: the shape needs no texture, no
      // second pipeline and no push constant, so it merges into the batch the
      // solid rectangles are already in rather than opening one. Three
      // primitives, one draw call, and the rounded one in the middle, which is
      // where a pipeline change would show.
      final VulkanOffscreenTarget target = routes.target(_size, _size);
      routes.device.analyticPrimitivesEnabled = true;
      final PresentResult result =
          await target.renderDisplayList(_mixed(), clearColor: _clear);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(target.quadCount, 3);
      expect(target.batchCount, 1,
          reason: 'the analytic quad opened a draw call of its own, which '
              'gives back the batching the encoding exists to preserve');
      expect(target.maskAtlas.rasterizationCount, 0);
      target.dispose();
    });

    test('600 distinct rounded rectangles cost no CPU rasterisation at all',
        () async {
      if (routes.skipped()) return;
      // The benchmark scene, as an assertion. Distinct sizes on purpose:
      // `DeviceRRectPathCache` holds 64 and the atlas recycles, so under the
      // dense route every one of these is a fresh CPU rasterisation in every
      // frame.
      final VulkanOffscreenTarget target = routes.target(1024, 768);
      final DisplayList list = _manyRoundedRects(600);

      routes.device.analyticPrimitivesEnabled = false;
      await target.renderDisplayList(list, clearColor: _clear);
      final int dense = target.maskAtlas.rasterizationCount;

      routes.device.analyticPrimitivesEnabled = true;
      await target.renderDisplayList(list, clearColor: _clear);
      final int analytic = target.maskAtlas.rasterizationCount - dense;

      printOnFailure('600 rounded rectangles: dense $dense rasterisations, '
          'analytic $analytic, batches ${target.batchCount}');
      expect(dense, greaterThan(0));
      expect(analytic, 0);
      expect(target.quadCount, 600);
      expect(target.batchCount, 1);
      target.dispose();
    });
  });

  group('the first frame of a fresh device', () {
    test('draws the analytic scene the same as the second one', () async {
      // Written because a first frame is where a backend's uninitialised state
      // shows: a descriptor never bound, a push constant never written, a
      // pipeline created lazily on the second pass. The analytic arm reads no
      // new descriptor and no new push constant, which is the claim - and every
      // other test in this file compares two frames that are both past the
      // first, so none of them could see it.
      //
      // A device of its own, opened and disposed here, because a device shared
      // with a group above would already have drawn.
      final _VulkanRoutes routes = _VulkanRoutes.open();
      if (routes.skipped()) {
        routes.close();
        return;
      }
      try {
        final VulkanOffscreenTarget target = routes.target(_size, _size);
        final DisplayList list = _button();
        final PresentResult first =
            await target.renderDisplayList(list, clearColor: _clear);
        expect(first.status, PresentStatus.presented,
            reason: '${first.diagnostic}');
        final Framebuffer firstFrame = _copy(target.framebuffer);
        expect(_isUniform(firstFrame), isFalse,
            reason: 'the very first frame of the device drew nothing, which '
                'is the failure this test exists for');

        await target.renderDisplayList(list, clearColor: _clear);
        final _Diff diff = _diff(firstFrame, target.framebuffer);
        expect(diff.maxDeviation, 0,
            reason: 'the first frame differs from the second by up to '
                '${diff.maxDeviation} levels on ${diff.differingPixels} '
                'pixels.\n${diff.report}');
        target.dispose();
      } finally {
        routes.close();
      }
    });
  });
}

// ---------------------------------------------------------------------
// Scenes. The same coordinates the GL and D3D11 twins use, so a tolerance
// moving in one file and not the others is a real difference between the
// shaders rather than a difference between the scenes.
// ---------------------------------------------------------------------

DisplayList _button() {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFF3366CC);
  list.drawRRectUniform(8, 18, 56, 46, 8, 8, fill);
  return list;
}

DisplayList _tinyRadius() {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFFCC6633);
  list.drawRRectUniform(8, 18, 56, 46, 1, 1, fill);
  return list;
}

DisplayList _pill() {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFF33CC66);
  list.drawRRectUniform(6, 20, 58, 44, 12, 12, fill);
  return list;
}

DisplayList _overrun() {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFFCCCC33);
  // 40 on a 24-tall box: both routes have to clamp it, by the same rule.
  list.drawRRectUniform(6, 20, 58, 44, 40, 40, fill);
  return list;
}

DisplayList _circle() {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFFCC33CC);
  list.drawRRectUniform(16, 16, 48, 48, 16, 16, fill);
  return list;
}

DisplayList _squareCorners() {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFF66CCCC);
  // Fractional edges, so the antialiasing term is doing something even though
  // the corners are square.
  list.drawRRectUniform(8.25, 18.5, 56.75, 46.5, 0, 0, fill);
  return list;
}

DisplayList _translucent() {
  final list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 64, 64, base);
  final int half = list.addPaint(colorArgb: 0x80CC3311);
  final int quarter = list.addPaint(colorArgb: 0x4011CC33);
  list
    ..drawRRectUniform(6, 6, 40, 40, 7, 7, half)
    ..drawRRectUniform(24, 24, 58, 58, 11, 11, quarter);
  return list;
}

DisplayList _stroked() {
  final list = DisplayList();
  final int stroke = list.addPaint(
    colorArgb: 0xFFEFEFEF,
    style: paintStyleStroke,
    strokeWidth: 1.5,
  );
  list.drawRRectUniform(8, 18, 56, 46, 8, 8, stroke);
  return list;
}

DisplayList _perCorner() {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFF88AACC);
  list.drawRRect(8, 18, 56, 46, 2, 2, 12, 12, 2, 2, 12, 12, fill);
  return list;
}

/// A rounded rectangle between two plain ones, which is what a row of controls
/// looks like to the batcher.
DisplayList _mixed() {
  final list = DisplayList();
  final int a = list.addPaint(colorArgb: 0xFF112233);
  list.drawRect(0, 0, 10, 10, a);
  final int b = list.addPaint(colorArgb: 0xFF445566);
  list.drawRRectUniform(12, 12, 40, 30, 5, 5, b);
  final int c = list.addPaint(colorArgb: 0xFF778899);
  list.drawRect(42, 0, 60, 10, c);
  return list;
}

/// Distinct rounded rectangles, more of them than the path cache holds.
DisplayList _grid() {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFF3366CC);
  for (var y = 0; y < 6; y++) {
    for (var x = 0; x < 6; x++) {
      final double left = x * 10.0 + 1;
      final double top = y * 10.0 + 1;
      list.drawRRectUniform(
        left,
        top,
        left + 8 + x * 0.25,
        top + 8,
        2 + y * 0.5,
        2 + y * 0.5,
        fill,
      );
    }
  }
  return list;
}

/// [count] rounded rectangles of distinct sizes and radii, laid out in a grid.
DisplayList _manyRoundedRects(int count) {
  final list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFF204060);
  for (var i = 0; i < count; i++) {
    final double left = (i % 25) * 40.0;
    final double top = (i ~/ 25) * 30.0;
    list.drawRRectUniform(
      left,
      top,
      left + 36 + i % 3,
      top + 26,
      3 + (i % 7).toDouble(),
      3 + (i % 7).toDouble(),
      fill,
    );
  }
  return list;
}

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

/// Renders [list] through one device twice - dense, then analytic - and asserts
/// the two pictures agree to [tolerance] levels per channel.
Future<void> _expectRouteParity(
  _VulkanRoutes routes,
  DisplayList list, {
  required int tolerance,
}) async {
  final _RoutePair? pair = await _renderBothRoutes(routes, list);
  if (pair == null) return;

  final _Diff diff = _diff(pair.dense, pair.analytic);
  printOnFailure('max deviation ${diff.maxDeviation} over '
      '${diff.differingPixels} pixels');
  expect(
    diff.maxDeviation,
    lessThanOrEqualTo(tolerance),
    reason: 'the closed form and the coverage atlas disagree by up to '
        '${diff.maxDeviation} levels on ${diff.differingPixels} pixels, over '
        'a declared tolerance of $tolerance.\n${diff.report}',
  );
  pair.dispose();
}

/// Asserts that the only pixels the two routes disagree about are on one of the
/// four corner arcs of [box] at [radius].
///
/// The corner region is the arc's bounding quadrant grown by one pixel on every
/// side, because the antialiased fringe of the arc reaches a pixel outside the
/// box and a pixel inside the point where the arc meets the straight edge.
Future<void> _expectDifferenceOnlyOnCornerArcs(
  _VulkanRoutes routes,
  DisplayList list, {
  required Rect box,
  required double radius,
}) async {
  final _RoutePair? pair = await _renderBothRoutes(routes, list);
  if (pair == null) return;

  final offEdge = <String>[];
  var differing = 0;
  var maxOnCorner = 0;
  for (var y = 0; y < pair.dense.height; y++) {
    for (var x = 0; x < pair.dense.width; x++) {
      final int deviation = _deviation(
        _rgba(pair.dense, x, y),
        _rgba(pair.analytic, x, y),
      );
      if (deviation == 0) continue;
      differing++;
      final double cx = x + 0.5;
      final double cy = y + 0.5;
      final bool nearCornerX =
          cx <= box.left + radius + 1 || cx >= box.right - radius - 1;
      final bool nearCornerY =
          cy <= box.top + radius + 1 || cy >= box.bottom - radius - 1;
      if (nearCornerX && nearCornerY) {
        if (deviation > maxOnCorner) maxOnCorner = deviation;
        continue;
      }
      if (offEdge.length < 12) {
        offEdge.add('($x, $y) by $deviation: dense '
            '${_rgba(pair.dense, x, y)}, analytic '
            '${_rgba(pair.analytic, x, y)}');
      }
    }
  }

  printOnFailure('$differing pixels differ, all on corner arcs, '
      'worst $maxOnCorner levels');
  expect(
    offEdge,
    isEmpty,
    reason: 'the two routes disagree away from a corner arc, which means the '
        'field is not merely rounding the corner differently - a straight edge '
        'and the interior are the same quantity in both '
        'rasterisers.\n${offEdge.join('\n')}',
  );
  expect(differing, greaterThan(0),
      reason: 'the two routes agreed everywhere, which means the analytic '
          'route did not run and this test proved nothing');
  pair.dispose();
}

/// One list, one device, both routes. Null when there is no device, having
/// already marked the test skipped.
Future<_RoutePair?> _renderBothRoutes(
  _VulkanRoutes routes,
  DisplayList list,
) async {
  if (routes.skipped()) return null;

  // Two targets rather than one, so a stale readback cannot be mistaken for
  // agreement: each render lands in a surface of its own and the dense one is
  // copied out anyway, because a target's framebuffer is rewritten by its next
  // frame and these two pictures are two frames apart.
  routes.device.analyticPrimitivesEnabled = false;
  final VulkanOffscreenTarget denseTarget = routes.target(_size, _size);
  final PresentResult denseResult =
      await denseTarget.renderDisplayList(list, clearColor: _clear);
  expect(denseResult.status, PresentStatus.presented,
      reason: '${denseResult.diagnostic}');
  final Framebuffer dense = _copy(denseTarget.framebuffer);
  denseTarget.dispose();

  routes.device.analyticPrimitivesEnabled = true;
  final VulkanOffscreenTarget analyticTarget = routes.target(_size, _size);
  final PresentResult analyticResult =
      await analyticTarget.renderDisplayList(list, clearColor: _clear);
  expect(analyticResult.status, PresentStatus.presented,
      reason: '${analyticResult.diagnostic}');

  // Two blank surfaces agree perfectly, so a scene that drew nothing would pass
  // every comparison in this file in silence.
  expect(_isUniform(dense), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');

  return _RoutePair(dense, analyticTarget);
}

final class _RoutePair {
  _RoutePair(this.dense, this._analyticTarget);

  final Framebuffer dense;
  final VulkanOffscreenTarget _analyticTarget;

  Framebuffer get analytic => _analyticTarget.framebuffer;

  void dispose() => _analyticTarget.dispose();
}

final class _Diff {
  _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;

  /// The first handful of differing pixels, both sides shown. Not all of them:
  /// a wrong picture differs everywhere, and a thousand-line failure hides the
  /// one number that matters, which is the maximum above.
  final String report;
}

_Diff _diff(Framebuffer a, Framebuffer b) {
  expect(b.width, a.width);
  expect(b.height, a.height);
  var maxDeviation = 0;
  var differing = 0;
  final lines = <String>[];
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final (int, int, int, int) p = _rgba(a, x, y);
      final (int, int, int, int) q = _rgba(b, x, y);
      final int deviation = _deviation(p, q);
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) lines.add('($x, $y): dense $p, analytic $q');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

int _deviation((int, int, int, int) p, (int, int, int, int) q) => <int>[
      (p.$1 - q.$1).abs(),
      (p.$2 - q.$2).abs(),
      (p.$3 - q.$3).abs(),
      (p.$4 - q.$4).abs(),
    ].reduce((int m, int n) => m > n ? m : n);

/// Whether every pixel of [buffer] is the same colour, which is what a scene
/// that drew nothing produces.
bool _isUniform(Framebuffer buffer) {
  final (int, int, int, int) first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      if (_rgba(buffer, x, y) != first) return false;
    }
  }
  return true;
}

/// A pixel as (r, g, b, a), whatever byte order the surface uses.
(int, int, int, int) _rgba(Framebuffer buffer, int x, int y) {
  final int i = buffer.offsetOf(x, y);
  final Uint8List bytes = buffer.pixels;
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

/// A snapshot, because a target's framebuffer is rewritten by its next frame
/// and the two pictures compared here are two frames apart.
Framebuffer _copy(Framebuffer source) {
  final Framebuffer copy = Framebuffer.allocate(
    width: source.width,
    height: source.height,
    format: source.format,
  );
  copy.pixels.setAll(0, source.pixels);
  return copy;
}

// ---------------------------------------------------------------------
// SPIR-V decoding, for the assertions no driver makes
// ---------------------------------------------------------------------

final class _Instruction {
  _Instruction(this.opcode, this.operands);

  final int opcode;

  /// Every word after the header, result type and result id included, so an
  /// operand index here is the one the specification prints.
  final List<int> operands;
}

/// Splits a module into instructions, skipping the five header words.
List<_Instruction> _decode(Uint32List words) {
  final out = <_Instruction>[];
  var offset = 5;
  while (offset < words.length) {
    final int header = words[offset];
    final int length = header >> 16;
    out.add(_Instruction(
        header & 0xFFFF, words.sublist(offset + 1, offset + length)));
    offset += length;
  }
  return out;
}

/// Every `OpConstant` of float type in [decoded], by result id.
///
/// The width is not consulted: this builder emits 32-bit floats only, and a
/// module that grew a 64-bit one would fail the reinterpretation loudly rather
/// than quietly, which is the behaviour a test wants.
Map<int, double> _floatConstants(List<_Instruction> decoded) {
  final out = <int, double>{};
  final bits = Uint32List(1);
  for (final _Instruction instruction in decoded) {
    if (instruction.opcode != _opConstant) continue;
    // Operands: result type, result id, the literal.
    bits[0] = instruction.operands[2];
    out[instruction.operands[1]] = bits.buffer.asFloat32List()[0];
  }
  return out;
}

// ---------------------------------------------------------------------
// Session plumbing
// ---------------------------------------------------------------------

/// A Vulkan render device and the two targets a route comparison needs.
///
/// The device is opened once per group rather than per test: it costs four
/// shader modules and every pipeline object, and the comparison needs one
/// device to serve both halves anyway - two devices could differ for reasons
/// that have nothing to do with the route.
final class _VulkanRoutes {
  _VulkanRoutes._(this._session, this._device, this._skipReason);

  final VulkanSession _session;
  final VulkanRenderDevice? _device;
  final String? _skipReason;

  VulkanRenderDevice get device => _device!;

  static _VulkanRoutes open() {
    final VulkanSession session = VulkanSession.open(validation: true);
    if (session.skipReason != null) {
      return _VulkanRoutes._(session, null, session.skipReason);
    }
    try {
      return _VulkanRoutes._(
          session, VulkanRenderDevice.adoptInstance(session.instance!), null);
    } on BackendSelectionError catch (error) {
      return _VulkanRoutes._(session, null, 'no Vulkan render device: $error');
    }
  }

  /// True when there is no device, having already marked the test skipped with
  /// the sentence that says which part was missing.
  bool skipped() {
    if (_skipReason == null) return false;
    printOnFailure('skipped: $_skipReason');
    markTestSkipped('no Vulkan device: $_skipReason');
    return true;
  }

  VulkanOffscreenTarget target(int width, int height) =>
      device.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as VulkanOffscreenTarget;

  void close() {
    _device?.dispose();
    _session.close();
  }
}
