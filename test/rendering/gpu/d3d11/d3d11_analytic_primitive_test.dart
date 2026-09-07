/// The closed-form rounded rectangle on Direct3D 11, against the route it
/// replaces.
///
/// `GpuPathStrategy.analyticPrimitive` is the one strategy in this renderer
/// that changes *which rasteriser* computes a shape's coverage rather than
/// where the result is stored. Every other route - the dense atlas,
/// tessellation, stencil-then-cover - ultimately takes its antialiasing from
/// `ScanlineFiller`. This one takes it from a signed distance field evaluated
/// in the pixel stage, and a distance field and an area integrator are not the
/// same function. So the question this file exists to answer is not "does it
/// draw a rounded rectangle" but "**how far** from the route it replaces does
/// it draw one, and where is that worst".
///
/// Direct3D 11 is the default production path on Windows, which is why the
/// port matters: `gl_analytic_primitive_test.dart` measured 12.1x on the same
/// machine through a backend almost nobody here actually runs.
///
/// ## The comparison is against the coverage atlas, not against arithmetic
///
/// An expectation written by hand would only prove that the shader agrees with
/// whoever wrote the expectation. So every pixel test here renders one display
/// list twice through one D3D11 device - once with
/// [D3d11RenderDevice.analyticPrimitivesEnabled] false, which is the dense
/// coverage atlas and the parity route this repository measures everything
/// against, and once with it true - and subtracts. That is the same idiom
/// `d3d11_cpu_parity_test.dart` uses for CPU against GPU, for the same reason:
/// a difference held on both sides of a boundary is asserted identically on
/// both sides of it and nobody notices.
///
/// ## The tolerances measure the *dense* route's error, not the shader's
///
/// This was chased down once already on OpenGL and must not be rediscovered as
/// a bug here. The dense route takes its coverage from `ScanlineFiller`, which
/// fills a **polygon**, and the polygon is the corner arc flattened at
/// `kDefaultFlattenTolerance` - a quarter of a device pixel. A chord cuts
/// *inside* the arc it replaces, so the dense route has always drawn every
/// rounded corner slightly too sharp, by up to a quarter of a pixel of
/// coverage, and the deviation therefore **grows with the radius** rather than
/// shrinking with it.
///
/// `gl_analytic_primitive_test.dart`'s `_theClosedFormIsTheAccurateOne` pins
/// that down against a 400x400 point sample of the exact circle - a reference
/// no rasteriser in this repository is derived from, so it cannot flatter
/// either of them - and finds the closed form out by at most 0.035 of a
/// pixel's area against the flattened polygon's 0.164, 4.7x further and always
/// in the same direction. That measurement is backend-independent: both sides
/// of it are CPU code shared by every backend, so it is proved once there and
/// not repeated here.
///
/// What *is* backend-specific, and is what this file asserts, is that the HLSL
/// transcription of `roundedCoverage` lands in the same band the GLSL original
/// did. So each pixel test states the deviation it measured and the number of
/// pixels that carried it, and [_expectDifferenceOnlyOnCornerArcs] adds the
/// structural claim that makes the band meaningful: the four straight edges
/// and the whole interior agree **exactly**, and every pixel that moved is on
/// a corner arc. A shader that were merely wrong would fail that long before
/// it exceeded a tolerance - it would move the edges too.
///
/// The tolerance is never the place a failure is made to go away. A scene that
/// deviated by 32 levels and starts deviating by 320 is a regression even
/// though both are "some difference at an antialiased corner".
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/vector/analytic_primitive.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

/// Big enough that a 40px radius fits and small enough that a failure prints a
/// picture a person can read. The same size the GL twin uses, so a tolerance
/// can be compared between the two files without rescaling it.
const int _size = 64;
const int _clear = 0xFF000000;

void main() {
  group('the encoding that crosses into HLSL', () {
    test('the shape code is the one the enum publishes', () {
      // `d3d11_shaders.dart` compares an interpolated float against a literal
      // and `gpu_raster_sink.dart` writes `AnalyticPrimitiveKind.rounded
      // .shaderCode` into that float. Nothing in the type system connects the
      // two: the enum's own comment says those integers may be added to but
      // not renumbered precisely because they cross this boundary, and this is
      // the assertion that makes the promise enforceable rather than
      // aspirational.
      expect(kD3dAnalyticRoundedRect, AnalyticPrimitiveKind.rounded.shaderCode);
      expect(kD3dAnalyticNone, 0);
    });

    test('Direct3D 11 and OpenGL decode the same two floats', () {
      // The sink writes one vertex and both backends read it. If the two
      // shaders ever disagreed about what a code meant, the same display list
      // would draw two different pictures on one machine depending on which
      // backend the policy opened - and every golden in this repository is
      // rendered through one of them at a time, so nothing would catch it.
      expect(kD3dAnalyticRoundedRect, kAnalyticRoundedRect);
      expect(kD3dAnalyticNone, kAnalyticNone);
    });

    test('the pixel shader selects on a threshold, not an equality', () {
      // The shape code arrives interpolated across the quad. It is written
      // identically on all four corners so it *should* arrive constant, but a
      // driver is entitled to reconstruct 1.0 as 0.99999994 at the pixel
      // centre, and an `== 1.0` test would then silently draw a plain
      // rectangle where a rounded one was asked for - on some hardware only.
      // Asserting the source text is crude; it is also the only way to catch
      // the edit, because the hardware this suite runs on is exactly the
      // hardware that would keep passing with an equality in there.
      expect(kD3d11ShaderSource, contains('input.texCoord.y >= 0.5'));
      expect(kD3d11ShaderSource, isNot(contains('input.texCoord.y ==')));
      // And the branch must live inside the existing solid path rather than in
      // a fourth mode: a fourth mode would be a fourth constant-buffer value,
      // which breaks the batch every analytic quad was written to join.
      expect(kD3d11ShaderSource, contains('roundedCoverage'));
    });
  });

  group('pixels, against the coverage atlas the closed form replaces', () {
    final session = _D3d11Session.open();
    // At the root of the group rather than per test: a device costs two shader
    // compiles and every pipeline object, and the parity idiom needs one
    // device to serve both halves of the comparison anyway.
    tearDownAll(session.close);

    test('an ordinary rounded rectangle, radius 8', () async {
      // The shape a button is, and the headline case of this whole change.
      // Observed here: 32 levels per channel over 60 pixels of 4096, every one
      // of them on a corner arc - the same 32 over the same 60 the GL twin
      // records, which is what a correct transcription looks like.
      await _expectRouteParity(session, _button(), tolerance: 32);
    });

    test('a one-pixel radius', () async {
      // Expected to be the worst case and it is the best one, which is the
      // measurement that overturned the guess this route was written on. At
      // radius 1 a quarter-pixel flattening tolerance cannot be reached - the
      // whole arc is a pixel across - so the two rasterisers have almost
      // nothing to disagree about, and what is left is four corner pixels.
      await _expectRouteParity(session, _tinyRadius(), tolerance: 18);
    });

    test('a pill, radius exactly half the short side', () async {
      // The clamping boundary. Both routes must apply the same overrun rule -
      // `PathBuilder.addRoundedRectPerCorner`'s single global factor - or the
      // shapes would differ in *size* rather than at their edges, which would
      // show up here as hundreds of differing pixels instead of a rim.
      await _expectRouteParity(session, _pill(), tolerance: 37);
    });

    test('a radius larger than half the side, clamped', () async {
      // Asked for 40 on a 24-tall box. Whatever the two do here they must do
      // together; a disagreement about clamping is a different shape, not a
      // different edge.
      await _expectRouteParity(session, _overrun(), tolerance: 37);
    });

    test('a circle, a square at radius half its side', () async {
      // The degenerate rounded rectangle, and the one where an off-by-one in
      // the clamp would produce a visible flat spot rather than a soft edge.
      await _expectRouteParity(session, _circle(), tolerance: 41);
    });

    test('zero radius, which must be the plain rectangle path', () async {
      // The redirect in `GpuRasterSink._fillAnalyticRRect` asserted end to
      // end. A rounded rectangle with no rounding has to come out as the
      // rectangle it is, drawn by `boxCoverage`, not as a radius-zero distance
      // field: the two disagree at the four corner pixels, where the separable
      // area of a pixel centred on a square corner is a quarter and the field
      // says a half.
      //
      // One level, on the corner pixels, and it is the difference this
      // renderer has always had between `boxCoverage` and `ScanlineFiller`:
      // the CPU quantises positions to 1/255ths of a pixel per axis and the
      // shader stays in float, so a pixel whose coverage is fractional on
      // *both* axes at once can round the other way. Anything larger than one
      // means the redirect stopped happening and the field is drawing corners
      // it must not draw.
      await _expectRouteParity(session, _squareCorners(), tolerance: 1);
    });

    test('translucent and overlapping', () async {
      // Coverage times alpha times source-over, twice, so an error in the
      // coverage is amplified by the blend rather than hidden by it.
      await _expectRouteParity(session, _translucent(), tolerance: 12);
    });

    test('inside a half-opacity layer', () async {
      // The layer origin is subtracted from the quad and from the shape rect
      // by different lines of the sink. If it were subtracted from one and not
      // the other the shape would be drawn in the right place with its corners
      // rounded in the wrong ones, which is a large diff and not a rim. On
      // D3D11 this also exercises the one place the two backends genuinely
      // differ - a layer renders top-down here and upside down on GL - so a
      // flip mistake would land on top of the coverage difference.
      await _expectRouteParity(session, _inLayer(), tolerance: 15);
    });

    test('a stroked rounded rectangle is refused by both routes', () async {
      // The player converts a stroked rrect to its centreline path before the
      // sink sees it and `PathStroker` turns that into a two-contour annulus,
      // which is not one of the closed forms. Refused by both routes, so this
      // is the assertion that the refusal is total: not one pixel may move.
      await _expectRouteParity(session, _stroked(), tolerance: 0);
    });

    test('per-corner radii are refused by both routes', () async {
      // Two floats hold one radius and one shape code; a second radius has
      // nowhere to go. Drawing all four corners at the first radius would be a
      // wrong picture chosen for speed, so the shape keeps the atlas and the
      // picture must be byte-identical.
      await _expectRouteParity(session, _perCorner(), tolerance: 0);
    });

    test('every pixel that moved is on a corner arc', () async {
      // The structural half of the claim, and the one that separates "the
      // closed form rounds a corner slightly differently" from "the shader is
      // wrong". A wrong field moves the straight edges too, and a wrong shape
      // rectangle moves the interior; both are excluded here, on a radius the
      // interface actually uses.
      await _expectDifferenceOnlyOnCornerArcs(
        session,
        _button(),
        box: const Rect.fromLTRB(8, 18, 56, 46),
        radius: 8,
      );
    });
  });

  group('what it costs, which is what it was for', () {
    final session = _D3d11Session.open();
    tearDownAll(session.close);

    test('the atlas is never touched for the analytic scene', () async {
      final String? reason = session.skipReason;
      if (reason != null) {
        printOnFailure('skipped: $reason');
        markTestSkipped('no Direct3D 11 device: $reason');
        return;
      }
      // Stronger evidence than a frame time, because it cannot be confounded
      // by driver scheduling: the same scene through the same target, and the
      // CPU rasterisation count goes from one per shape per frame to zero.
      final D3d11OffscreenTarget target = session.target(_size, _size);
      final DisplayList list = _grid();

      session.device!.analyticPrimitivesEnabled = false;
      await target.renderDisplayList(list, clearColor: _clear);
      final int dense = target.maskAtlas.rasterizationCount;

      session.device!.analyticPrimitivesEnabled = true;
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
      final String? reason = session.skipReason;
      if (reason != null) {
        printOnFailure('skipped: $reason');
        markTestSkipped('no Direct3D 11 device: $reason');
        return;
      }
      // The claim the encoding was chosen for: the shape needs no texture, no
      // second program and no extra constant, so it merges into the batch the
      // solid rectangles are already in rather than opening one. Three
      // primitives, one draw call, and the rounded one in the middle, which is
      // where a pipeline or constant-buffer change would show.
      //
      // Asserted through a real device rather than a bare batcher because the
      // batch that matters is the one `D3d11OffscreenTarget.present` submits,
      // and a backend that split it there would still pass a sink-level test.
      final D3d11OffscreenTarget target = session.target(_size, _size);
      session.device!.analyticPrimitivesEnabled = true;
      final PresentResult result =
          await target.renderDisplayList(_mixed(), clearColor: _clear);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(target.batcher.quadCount, 3);
      expect(target.batcher.batchCount, 1,
          reason: 'the analytic quad opened a draw call of its own, which '
              'gives back the batching the encoding exists to preserve');
      expect(target.maskAtlas.rasterizationCount, 0);
      target.dispose();
    });

    test('600 distinct rounded rectangles cost no CPU rasterisation at all',
        () async {
      final String? reason = session.skipReason;
      if (reason != null) {
        printOnFailure('skipped: $reason');
        markTestSkipped('no Direct3D 11 device: $reason');
        return;
      }
      // The benchmark scene, as an assertion. Distinct sizes on purpose:
      // `DeviceRRectPathCache` holds 64 and the atlas recycles, so under the
      // dense route every one of these is a fresh CPU rasterisation in every
      // frame - which is the 600-per-frame number the measurement reports.
      final D3d11OffscreenTarget target = session.target(1024, 768);
      final DisplayList list = _manyRoundedRects(600);

      session.device!.analyticPrimitivesEnabled = false;
      await target.renderDisplayList(list, clearColor: _clear);
      final int dense = target.maskAtlas.rasterizationCount;

      session.device!.analyticPrimitivesEnabled = true;
      await target.renderDisplayList(list, clearColor: _clear);
      final int analytic = target.maskAtlas.rasterizationCount - dense;

      printOnFailure('600 rounded rectangles: dense $dense rasterisations, '
          'analytic $analytic, batches ${target.batcher.batchCount}');
      expect(dense, greaterThan(0));
      expect(analytic, 0);
      expect(target.batcher.quadCount, 600);
      expect(target.batcher.batchCount, 1);
      target.dispose();
    });
  });

  group('the first frame of a fresh device', () {
    test('draws the analytic scene the same as the second one', () async {
      // Written because this backend has had exactly this bug before: a route
      // that drew nothing on the first frame of every device, because a
      // constant-buffer register still held whatever `CreateBuffer` left. The
      // analytic branch reads no new constant, but it *is* selected inside the
      // branch on `mode`, so a device whose first frame ran with an unwritten
      // `mode` would take the wrong arm of it - and every other test in this
      // file compares two frames that are both past the first.
      //
      // A device of its own, opened and disposed here, because a device shared
      // with the group above would already have drawn.
      final session = _D3d11Session.open();
      final String? reason = session.skipReason;
      if (reason != null) {
        printOnFailure('skipped: $reason');
        markTestSkipped('no Direct3D 11 device: $reason');
        return;
      }
      try {
        final D3d11OffscreenTarget target = session.target(_size, _size);
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
        session.close();
      }
    });
  });
}

// ---------------------------------------------------------------------
// Scenes. The same coordinates the GL twin uses, so a tolerance moving in one
// file and not the other is a real difference between the two shaders rather
// than a difference between two scenes.
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

DisplayList _inLayer() {
  final list = DisplayList();
  final int background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 64, 64, background);
  final int layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
  list.saveLayer(8, 8, 56, 56, layerPaint);
  final int content = list.addPaint(colorArgb: 0xFFCC3311);
  list
    // Off-centre in the layer: a composite off by a row is invisible against a
    // symmetric shape.
    ..drawRRectUniform(12, 14, 50, 40, 9, 9, content)
    ..restore();
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

/// Renders [list] through one device twice - dense, then analytic - and
/// asserts the two pictures agree to [tolerance] levels per channel.
Future<void> _expectRouteParity(
  _D3d11Session session,
  DisplayList list, {
  required int tolerance,
}) async {
  final _RoutePair? pair = await _renderBothRoutes(session, list);
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

/// Asserts that the only pixels the two routes disagree about are on one of
/// the four corner arcs of [box] at [radius].
///
/// This is the assertion that says the difference is the shape of a corner and
/// not the shape of the rectangle. A field evaluated against the wrong box, a
/// radius decoded from the wrong float, a quad snapped the wrong way or a
/// texture coordinate read where a device position was meant would all move
/// pixels on a straight edge or in the interior, where `0.5 - d` and the
/// filler's area are provably the same quantity and must therefore agree to
/// the last bit.
///
/// The corner region is the arc's bounding quadrant grown by one pixel on
/// every side, because the antialiased fringe of the arc reaches a pixel
/// outside the box and a pixel inside the point where the arc meets the
/// straight edge.
Future<void> _expectDifferenceOnlyOnCornerArcs(
  _D3d11Session session,
  DisplayList list, {
  required Rect box,
  required double radius,
}) async {
  final _RoutePair? pair = await _renderBothRoutes(session, list);
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
        'field is not merely rounding the corner differently - a straight '
        'edge and the interior are the same quantity in both '
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
  _D3d11Session session,
  DisplayList list,
) async {
  final String? reason = session.skipReason;
  if (reason != null) {
    // Not a silent return: the reason is printed and the test is marked
    // skipped, so a run with no device says so instead of looking like a run
    // that compared something.
    printOnFailure('skipped: $reason');
    markTestSkipped('no Direct3D 11 device: $reason');
    return null;
  }
  final D3d11RenderDevice device = session.device!;

  // Two targets rather than one, so a stale readback cannot be mistaken for
  // agreement: each render lands in a surface of its own and the dense one is
  // copied out anyway, because a target's framebuffer is rewritten by its next
  // frame and these two pictures are two frames apart.
  device.analyticPrimitivesEnabled = false;
  final D3d11OffscreenTarget denseTarget = session.target(_size, _size);
  final PresentResult denseResult =
      await denseTarget.renderDisplayList(list, clearColor: _clear);
  expect(denseResult.status, PresentStatus.presented,
      reason: '${denseResult.diagnostic}');
  final Framebuffer dense = _copy(denseTarget.framebuffer);
  denseTarget.dispose();

  device.analyticPrimitivesEnabled = true;
  final D3d11OffscreenTarget analyticTarget = session.target(_size, _size);
  final PresentResult analyticResult =
      await analyticTarget.renderDisplayList(list, clearColor: _clear);
  expect(analyticResult.status, PresentStatus.presented,
      reason: '${analyticResult.diagnostic}');

  // Two blank surfaces agree perfectly, so a scene that drew nothing would
  // pass every comparison in this file in silence.
  expect(_isUniform(dense), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');

  return _RoutePair(dense, analyticTarget);
}

final class _RoutePair {
  _RoutePair(this.dense, this._analyticTarget);

  final Framebuffer dense;
  final D3d11OffscreenTarget _analyticTarget;

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
// Session plumbing - the same shape `d3d11_cpu_parity_test.dart` uses, and for
// the same reason: a device costs two shader compiles and every pipeline
// object.
// ---------------------------------------------------------------------

final class _D3d11Session {
  _D3d11Session._(this.device, this.skipReason);

  final D3d11RenderDevice? device;

  /// Null when the device opened. A string when it did not, so a run with no
  /// GPU reports what was missing rather than passing quietly.
  final String? skipReason;

  static _D3d11Session open() {
    if (!Platform.isWindows) {
      return _D3d11Session._(null,
          'Direct3D 11 needs Windows; this is ${Platform.operatingSystem}');
    }
    try {
      return _D3d11Session._(D3d11RendererBackend.openDevice(), null);
    } on Object catch (error) {
      return _D3d11Session._(null, 'no D3D11 device: $error');
    }
  }

  D3d11OffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as D3d11OffscreenTarget;

  void close() => device?.dispose();
}
