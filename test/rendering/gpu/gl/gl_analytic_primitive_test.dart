/// The closed-form rounded rectangle, against the route it replaces.
///
/// `GpuPathStrategy.analyticPrimitive` is the one strategy in this renderer
/// that changes *which rasteriser* computes a shape's coverage rather than
/// where the result is stored. Every other route - the dense atlas, sparse
/// strips, tessellation, stencil-then-cover - ultimately takes its antialiasing
/// from `ScanlineFiller`. This one takes it from a signed distance field
/// evaluated in the fragment stage, and a distance field and an area
/// integrator are not the same function. So the question this file exists to
/// answer is not "does it draw a rounded rectangle" but "**how far** from the
/// route it replaces does it draw one, and where is that worst".
///
/// ## The comparison is against the coverage atlas, not against arithmetic
///
/// An expectation written by hand would only prove that the shader agrees with
/// whoever wrote the expectation. So every pixel test here renders one display
/// list twice through one GL device - once with
/// [GlRenderDevice.analyticPrimitivesEnabled] false, which is the dense
/// coverage atlas and the parity route this repository measures everything
/// against, and once with it true - and subtracts. That is the same idiom
/// `test/differential/cpu_gpu_parity_test.dart` uses for CPU against GPU, for
/// the same reason: a difference held on both sides of a boundary is asserted
/// identically on both sides of it and nobody notices.
///
/// ## The tolerances, and which side of them is wrong
///
/// They are not zero, and the reason turned out to be the opposite of the one
/// expected. The guess going in was that `0.5 - d` is only an approximation on
/// a curve - true, and worth about a hundredth of a coverage level at the
/// radii an interface uses. What actually dominates is the *dense* route: it
/// takes its coverage from `ScanlineFiller`, which fills a **polygon**, and
/// the polygon is the corner arc flattened at `kDefaultFlattenTolerance` -
/// a quarter of a device pixel. A chord cuts inside the arc it replaces, so
/// the dense route draws every rounded corner slightly *small*, by up to a
/// quarter of a pixel of coverage, and the deviation therefore **grows with
/// the radius** rather than shrinking with it. Measured here: 18 levels at
/// radius 1, 32 at radius 8, 37 at radius 12, 41 at radius 16.
///
/// [_theClosedFormIsTheAccurateOne] pins that down rather than leaving it as
/// an argument: it supersamples the true circle and shows the closed form
/// landing an order of magnitude closer to it than the filler does. So the
/// tolerances below are **not** a budget for the shader's error. They are a
/// measurement of how far the route being replaced was from the shape it was
/// asked for, and the direction of every one of them is the closed form being
/// right.
///
/// Each test states the deviation it measured and the number of pixels that
/// carried it, because a large maximum on four pixels and a large maximum on
/// four hundred are different facts. The tolerance is never the place a
/// failure is made to go away: a scene that deviated by 32 levels and starts
/// deviating by 320 is a regression even though both are "some difference at
/// an antialiased corner".
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_atlas.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_raster_sink.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/vector/analytic_primitive.dart';
import 'package:dart_ui/src/rendering/path/coverage_span_sink.dart';
import 'package:dart_ui/src/rendering/path/scanline_filler.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

/// Big enough that a 40px radius fits and small enough that a failure prints a
/// picture a person can read.
const int _size = 64;
const int _clear = 0xFF000000;

void main() {
  group('the vertex encoding', () {
    test('the shader code is the one the enum publishes', () {
      // `gl_shaders.dart` compares a float against a literal and the sink
      // writes `AnalyticPrimitiveKind.rounded.shaderCode` into that float. The
      // enum's own comment says those integers may be added to but not
      // renumbered precisely because they cross this boundary; this is the
      // assertion that makes the promise enforceable rather than aspirational.
      expect(kAnalyticRoundedRect, AnalyticPrimitiveKind.rounded.shaderCode);
      expect(kAnalyticNone, 0);
    });

    test('a uniform rounded rectangle is one solid quad carrying its radius',
        () {
      final harness = _SinkHarness();
      harness.sink.fillDeviceRRect(
        const Rect.fromLTRB(10, 20, 60, 44),
        const Rect.fromLTRB(0, 0, 64, 64),
        _uniformRadii(6),
        _paint(0xFF3366CC),
      );

      expect(harness.atlas.rasterizationCount, 0,
          reason: 'the whole claim of this route is that no CPU coverage is '
              'rasterised for the shape');
      expect(harness.batcher.batchCount, 1);
      final vertex = harness.vertex(0);
      // The radius and the shape code, in the two floats the solid pipeline
      // has never sampled anything with.
      expect(vertex.u, 6);
      expect(vertex.v, AnalyticPrimitiveKind.rounded.shaderCode);
      // The *unclipped* box, which is what the field is evaluated against.
      expect(
        <double>[
          vertex.shapeLeft,
          vertex.shapeTop,
          vertex.shapeRight,
          vertex.shapeBottom
        ],
        <double>[10, 20, 60, 44],
      );
      expect(vertex.pipeline, GpuPipelineKind.solid);
      expect(vertex.textureId, kNoTexture);
    });

    test(
        'all four corners write the same two floats, so they interpolate to '
        'a constant', () {
      // A driver interpolates whatever the four vertices carry. If the radius
      // were written per corner the fragment stage would read a bilinear blend
      // of four numbers and the shape would bulge; this is the assertion that
      // the quad is flat in those two channels.
      final harness = _SinkHarness();
      harness.sink.fillDeviceRRect(
        const Rect.fromLTRB(4, 4, 40, 30),
        const Rect.fromLTRB(0, 0, 64, 64),
        _uniformRadii(9),
        _paint(0xFFFFFFFF),
      );
      for (var corner = 0; corner < 4; corner++) {
        final vertex = harness.vertex(corner);
        expect(vertex.u, 9, reason: 'corner $corner');
        expect(vertex.v, 1, reason: 'corner $corner');
      }
    });

    test('a rounded rectangle batches with the plain rectangles around it', () {
      // The claim `analytic_primitive.dart` makes in its header: the shape
      // needs no texture, so it merges into the batch the solid rectangles are
      // already in rather than opening one. Three primitives, one draw call -
      // and the rounded one in the middle, where a pipeline change would show.
      final harness = _SinkHarness();
      const clip = Rect.fromLTRB(0, 0, 64, 64);
      harness.sink
        ..fillDeviceRect(
            const Rect.fromLTRB(0, 0, 10, 10), clip, _paint(0xFF112233))
        ..fillDeviceRRect(const Rect.fromLTRB(12, 12, 40, 30), clip,
            _uniformRadii(5), _paint(0xFF445566))
        ..fillDeviceRect(
            const Rect.fromLTRB(42, 0, 60, 10), clip, _paint(0xFF778899));
      expect(harness.batcher.batchCount, 1);
      expect(harness.batcher.quadCount, 3);
      expect(harness.atlas.rasterizationCount, 0);
    });

    test('a zero radius is drawn as the rectangle it is', () {
      // Not as a radius-zero field. The two disagree at the four corner
      // pixels - the separable area of a pixel centred on a square corner is a
      // quarter, the distance field says a half - so a rounded rectangle with
      // no rounding has to come out byte-identical to `fillDeviceRect`, and
      // the way to guarantee that is to *be* `fillDeviceRect`.
      final analytic = _SinkHarness();
      analytic.sink.fillDeviceRRect(
        const Rect.fromLTRB(10.25, 20.5, 60, 44),
        const Rect.fromLTRB(0, 0, 64, 64),
        _uniformRadii(0),
        _paint(0xFF3366CC),
      );
      final plain = _SinkHarness();
      plain.sink.fillDeviceRect(
        const Rect.fromLTRB(10.25, 20.5, 60, 44),
        const Rect.fromLTRB(0, 0, 64, 64),
        _paint(0xFF3366CC),
      );
      expect(analytic.atlas.rasterizationCount, 0);
      expect(analytic.floats, plain.floats);
    });

    test('600 distinct rounded rectangles never touch the atlas', () {
      // The measurement in the throughput benchmark's `rrects-aa` row, as an
      // assertion that cannot be confounded by driver scheduling. Distinct
      // sizes on purpose: `DeviceRRectPathCache` holds 64 and the atlas
      // recycles, so under the dense route every one of these is a fresh CPU
      // rasterisation in every frame. Under this one there are none at all,
      // and they are one draw call.
      final harness = _SinkHarness();
      const clip = Rect.fromLTRB(0, 0, 4096, 4096);
      for (var i = 0; i < 600; i++) {
        final double left = (i % 25) * 40.0;
        final double top = (i ~/ 25) * 30.0;
        harness.sink.fillDeviceRRect(
          Rect.fromLTRB(left, top, left + 36 + i % 3, top + 26),
          clip,
          _uniformRadii(3 + (i % 7)),
          _paint(0xFF204060),
        );
      }
      expect(harness.atlas.rasterizationCount, 0);
      expect(harness.batcher.quadCount, 600);
      expect(harness.batcher.batchCount, 1);

      final dense = _SinkHarness(analytic: false);
      for (var i = 0; i < 600; i++) {
        final double left = (i % 25) * 40.0;
        final double top = (i ~/ 25) * 30.0;
        dense.sink.fillDeviceRRect(
          Rect.fromLTRB(left, top, left + 36 + i % 3, top + 26),
          clip,
          _uniformRadii(3 + (i % 7)),
          _paint(0xFF204060),
        );
      }
      expect(dense.atlas.rasterizationCount, greaterThan(0),
          reason: 'if the dense route stopped rasterising these the comparison '
              'above would be measuring nothing');
    });
  });

  group('which of the two is closer to the shape that was asked for', () {
    test('the closed form is, by an order of magnitude', () {
      _theClosedFormIsTheAccurateOne();
    });
  });

  group('what the closed form refuses, and keeps drawing correctly', () {
    test('per-corner radii go to the atlas', () {
      // Two floats hold one radius and one shape code. A second radius has
      // nowhere to go, and drawing all four corners at the first one would be
      // a wrong picture chosen for speed.
      final harness = _SinkHarness();
      final radii = Float32List.fromList(<double>[2, 2, 8, 8, 2, 2, 8, 8]);
      harness.sink.fillDeviceRRect(
        const Rect.fromLTRB(4, 4, 40, 30),
        const Rect.fromLTRB(0, 0, 64, 64),
        radii,
        _paint(0xFFFFFFFF),
      );
      expect(harness.atlas.rasterizationCount, 1);
    });

    test('an elliptical corner goes to the atlas', () {
      // The refusal `AnalyticPrimitiveRecognizer` already made by name, here
      // to prove the sink honours it rather than reading p0 and moving on.
      final harness = _SinkHarness();
      final radii = Float32List.fromList(<double>[6, 3, 6, 3, 6, 3, 6, 3]);
      harness.sink.fillDeviceRRect(
        const Rect.fromLTRB(4, 4, 40, 30),
        const Rect.fromLTRB(0, 0, 64, 64),
        radii,
        _paint(0xFFFFFFFF),
      );
      expect(harness.atlas.rasterizationCount, 1);
    });

    test('a fractional clip that cuts the shape goes to the atlas', () {
      // The quad is snapped to whole pixels and the clip is then a scissor,
      // which cannot express half a pixel; the atlas route runs the filler
      // against the exact clip and antialiases that edge. Only the cut is
      // refused - a fractional clip that does not reach the shape is fine.
      final cutting = _SinkHarness();
      cutting.sink.fillDeviceRRect(
        const Rect.fromLTRB(4, 4, 40, 30),
        const Rect.fromLTRB(0, 0, 20.5, 64),
        _uniformRadii(5),
        _paint(0xFFFFFFFF),
      );
      expect(cutting.atlas.rasterizationCount, 1);

      final clear = _SinkHarness();
      clear.sink.fillDeviceRRect(
        const Rect.fromLTRB(4, 4, 40, 30),
        const Rect.fromLTRB(0, 0, 60.5, 64),
        _uniformRadii(5),
        _paint(0xFFFFFFFF),
      );
      expect(clear.atlas.rasterizationCount, 0,
          reason: 'a fraction the shape never reaches is not a cut');
    });

    test('a whole-pixel clip that cuts the shape stays analytic', () {
      // Where the clip lands on integers the scissor is exact and the two
      // routes agree, so refusing it would give up the scrolled list - which
      // is exactly the case this route was written for.
      final harness = _SinkHarness();
      harness.sink.fillDeviceRRect(
        const Rect.fromLTRB(4, 4, 40, 30),
        const Rect.fromLTRB(0, 0, 20, 64),
        _uniformRadii(5),
        _paint(0xFFFFFFFF),
      );
      expect(harness.atlas.rasterizationCount, 0);
      expect(harness.batcher.quadCount, 1);
    });

    test('a gradient goes to the route that has a ramp', () {
      // The analytic quad modulates one vertex colour by a coverage. A ramp is
      // not a colour, and a flat fill where a gradient was asked for reads as
      // a paint bug rather than a renderer limitation.
      final harness = _SinkHarness();
      expect(
        () => harness.sink.fillDeviceRRect(
          const Rect.fromLTRB(4, 4, 40, 30),
          const Rect.fromLTRB(0, 0, 64, 64),
          _uniformRadii(5),
          _gradientPaint(),
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
        reason: 'the dense atlas cannot draw one either, and this harness has '
            'no sparse executor, so the honest answer is the named refusal',
      );
      expect(harness.batcher.quadCount, 0);
    });

    test('a stroked rounded rectangle is untouched', () {
      // The player converts a stroked rrect to its centreline path before the
      // sink sees it, and `PathStroker` turns that into a fill outline. What
      // arrives is a two-contour annulus, which is not one of the four closed
      // forms - `analytic_primitive.dart` says so in its header - so it keeps
      // the atlas. Half of the throughput benchmark's `rrects-aa` scene is
      // this shape, which is why that row can only improve by about half.
      final harness = _SinkHarness();
      final list = DisplayList();
      final int stroke = list.addPaint(
        colorArgb: 0xFFEFEFEF,
        style: paintStyleStroke,
        strokeWidth: 1.5,
      );
      list.drawRRectUniform(6, 6, 50, 40, 8, 8, stroke);
      DisplayListPlayer(harness.sink).play(
        DisplayListReader(list),
        DisplayListResources(list),
        deviceBounds: const Rect.fromLTRB(0, 0, 64, 64),
      );
      expect(harness.atlas.rasterizationCount, 1);
    });
  });

  group('pixels, against the coverage atlas the closed form replaces', () {
    final session = _GlSession.open();
    tearDownAll(session.close);

    test('an ordinary rounded rectangle, radius 8: 32 levels on 60 pixels',
        () async {
      // The shape a button is, and the headline number of this whole change.
      // Observed: 32 levels per channel over 60 pixels of 4096, every one of
      // them on a corner arc - the four straight edges agree exactly, because
      // there the field's `0.5 - d` and the filler's area are the same
      // quantity. The closed form is the *fuller* of the two everywhere it
      // differs; see the file comment and [_theClosedFormIsTheAccurateOne].
      await _expectRouteParity(session, _button(), tolerance: 32);
    });

    test('a one-pixel radius: 18 levels on 4 pixels', () async {
      // Expected to be the worst case and it is the best one, which is the
      // measurement that overturned the guess this file was written on. At
      // radius 1 a quarter-pixel flattening tolerance cannot be reached - the
      // whole arc is a pixel across - so the two rasterisers have almost
      // nothing to disagree about, and what is left is four corner pixels.
      await _expectRouteParity(session, _tinyRadius(), tolerance: 18);
    });

    test('a pill, radius exactly half the short side: 37 levels on 92 pixels',
        () async {
      // The clamping boundary. Both routes must apply the same overrun rule -
      // `PathBuilder.addRoundedRectPerCorner`'s single global factor - or the
      // shapes would differ in *size* rather than at their edges, which would
      // show up here as hundreds of differing pixels instead of a rim.
      await _expectRouteParity(session, _pill(), tolerance: 37);
    });

    test('a radius larger than half the side, clamped: 37 levels', () async {
      // Asked for 40 on a 24-tall box. Whatever the two do here they must do
      // together; a disagreement about clamping is a different shape.
      await _expectRouteParity(session, _overrun(), tolerance: 37);
    });

    test('a circle, a square at radius half its side: 41 levels on 124 pixels',
        () async {
      // The degenerate rounded rectangle, and the one where an off-by-one in
      // the clamp would produce a visible flat spot rather than a soft edge.
      await _expectRouteParity(session, _circle(), tolerance: 41);
    });

    test('zero radius: 1 level on the 4 corner pixels', () async {
      // The redirect to [GpuRasterSink.fillDeviceRect] asserted end to end: a
      // rounded rectangle with no rounding must come out as the rectangle it
      // is, drawn by `boxCoverage`, not as a radius-zero distance field.
      //
      // One level, on exactly the four corners, and it is the difference this
      // renderer has always had between `boxCoverage` and `ScanlineFiller`:
      // the CPU quantises positions to 1/255ths of a pixel per axis and the
      // shader stays in float, so a pixel whose coverage is fractional on
      // *both* axes at once can round the other way. `gl_shaders.dart` states
      // that bound. Anything larger than one means the redirect stopped
      // happening and the field is drawing the corners.
      await _expectRouteParity(session, _squareCorners(), tolerance: 1);
    });

    test('translucent and overlapping: 12 levels on 128 pixels', () async {
      // Coverage times alpha times source-over, twice, so an error in the
      // coverage is amplified by the blend rather than hidden by it.
      await _expectRouteParity(session, _translucent(), tolerance: 12);
    });

    test('inside a half-opacity layer: 15 levels on 60 pixels', () async {
      // The layer origin is subtracted from the quad and from the shape rect
      // by different lines of the sink. If it were subtracted from one and not
      // the other the shape would be drawn at the right place with its corners
      // rounded in the wrong ones, which is a large diff and not a rim.
      await _expectRouteParity(session, _inLayer(), tolerance: 15);
    });

    test('a stroked rounded rectangle: 0', () async {
      // Refused by both routes, so this is the assertion that the refusal is
      // total: not one pixel of a stroked shape may move.
      await _expectRouteParity(session, _stroked(), tolerance: 0);
    });

    test('per-corner radii: 0', () async {
      // Same, for the shape the vertex has no room for.
      await _expectRouteParity(session, _perCorner(), tolerance: 0);
    });

    test('the atlas is never touched for the analytic scene', () async {
      final String? reason = session.skipReason;
      if (reason != null) {
        markTestSkipped('no GL device: $reason');
        return;
      }
      // Stronger than a frame time, because it cannot be confounded by driver
      // scheduling: the same scene, the same target, and the CPU rasterisation
      // count goes from "one per shape per frame" to zero.
      final target = session.target(_size, _size);
      final DisplayList list = _grid();

      session.device!.analyticPrimitivesEnabled = false;
      await target.renderDisplayList(list, clearColor: _clear);
      final int dense = target.maskAtlas.rasterizationCount;

      session.device!.analyticPrimitivesEnabled = true;
      await target.renderDisplayList(list, clearColor: _clear);
      final int analytic = target.maskAtlas.rasterizationCount - dense;

      expect(dense, greaterThan(0));
      expect(analytic, 0);
      target.dispose();
    }, skip: session.skipReason);
  });
}

// ---------------------------------------------------------------------
// Which route is right
// ---------------------------------------------------------------------

/// Both rasterisers against a supersampled circle, on the pixels where they
/// disagree.
///
/// Written because "the two routes differ by 41 levels" is only half a
/// finding: it says nothing about which of them moved away from the shape the
/// display list asked for, and a change that made the picture *worse* by 41
/// levels while making it faster would be a regression dressed as an
/// optimisation. The reference is a 400x400 point sample of the exact circle
/// per pixel, which no rasteriser in this repository is derived from, so it
/// cannot flatter either of them.
///
/// The result on the corner of a radius-12 rounded rectangle: the closed form
/// is out by at most **0.035** of a pixel's area - which is the `0.5 - d`
/// approximation being what it says it is, about nine coverage levels at the
/// single worst pixel - and the flattened polygon is out by **0.164**, nearly
/// five times further. The polygon's error also has a direction: a chord lies
/// inside the arc it replaces, so the filler draws every rounded corner
/// slightly too sharp, and always in the same sense.
void _theClosedFormIsTheAccurateOne() {
  const Rect box = Rect.fromLTRB(6, 20, 58, 44);
  const double radius = 12;

  final analytic = AnalyticPrimitive();
  const AnalyticPrimitiveRecognizer()
      .recogniseRoundedRect(analytic, box, _uniformRadii(radius));
  expect(analytic.kind, AnalyticPrimitiveKind.rounded);

  final builder = PathBuilder()..addRoundedRect(box, radius, radius);
  final coverage = _SpanCoverage(64, 64);
  ScanlineFiller().fill(
    builder.build(),
    const Rect.fromLTRB(0, 0, 64, 64),
    coverage,
  );

  var worstAnalytic = 0.0;
  var worstDense = 0.0;
  // The top-left corner's quadrant only: that is where the arc is, and a
  // straight edge would dilute both errors with pixels neither route can get
  // wrong.
  for (var y = 19; y < 33; y++) {
    for (var x = 5; x < 19; x++) {
      final double truth = _sampledCoverage(x, y, box, radius);
      final double a = (analytic.coverageAt(x + 0.5, y + 0.5) - truth).abs();
      final double d = (coverage.at(x, y) - truth).abs();
      if (a > worstAnalytic) worstAnalytic = a;
      if (d > worstDense) worstDense = d;
    }
  }

  printOnFailure('worst error: closed form $worstAnalytic, '
      'flattened polygon $worstDense');
  expect(worstAnalytic, lessThan(0.04),
      reason: 'the closed form should track the true circle to within a few '
          'coverage levels at the worst pixel; if it does not, the field is '
          'wrong rather than merely approximate');
  expect(worstDense, greaterThan(worstAnalytic * 3),
      reason: 'if the flattened polygon ever became this accurate the '
          'tolerances above would all be wrong, and the honest response is to '
          'remeasure them rather than to widen this');
}

/// The exact rounded rectangle, point sampled. Slow and obviously correct,
/// which is the whole reason it is here.
double _sampledCoverage(int px, int py, Rect box, double radius) {
  const int n = 400;
  var inside = 0;
  for (var i = 0; i < n; i++) {
    final double x = px + (i + 0.5) / n;
    for (var j = 0; j < n; j++) {
      final double y = py + (j + 0.5) / n;
      final double dx = x < box.left + radius
          ? box.left + radius - x
          : x - (box.right - radius);
      final double dy = y < box.top + radius
          ? box.top + radius - y
          : y - (box.bottom - radius);
      final double ox = dx > 0 ? dx : 0;
      final double oy = dy > 0 ? dy : 0;
      if (x < box.left || x > box.right || y < box.top || y > box.bottom) {
        continue;
      }
      if (ox * ox + oy * oy <= radius * radius) inside++;
    }
  }
  return inside / (n * n);
}

/// The spans `ScanlineFiller` emits, unpacked into a coverage image.
final class _SpanCoverage implements CoverageSpanSink {
  _SpanCoverage(this.width, this.height) : _pixels = Uint8List(width * height);

  final int width;
  final int height;
  final Uint8List _pixels;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    if (y < 0 || y >= height) return;
    for (var x = xStart; x < xEnd; x++) {
      if (x < 0 || x >= width) continue;
      _pixels[y * width + x] = coverage;
    }
  }

  double at(int x, int y) => _pixels[y * width + x] / 255.0;
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

DisplayList _button() {
  final list = DisplayList();
  final fill = list.addPaint(colorArgb: 0xFF3366CC);
  list.drawRRectUniform(8, 18, 56, 46, 8, 8, fill);
  return list;
}

DisplayList _tinyRadius() {
  final list = DisplayList();
  final fill = list.addPaint(colorArgb: 0xFFCC6633);
  list.drawRRectUniform(8, 18, 56, 46, 1, 1, fill);
  return list;
}

DisplayList _pill() {
  final list = DisplayList();
  final fill = list.addPaint(colorArgb: 0xFF33CC66);
  list.drawRRectUniform(6, 20, 58, 44, 12, 12, fill);
  return list;
}

DisplayList _overrun() {
  final list = DisplayList();
  final fill = list.addPaint(colorArgb: 0xFFCCCC33);
  // 40 on a 24-tall box: both routes have to clamp it, by the same rule.
  list.drawRRectUniform(6, 20, 58, 44, 40, 40, fill);
  return list;
}

DisplayList _circle() {
  final list = DisplayList();
  final fill = list.addPaint(colorArgb: 0xFFCC33CC);
  list.drawRRectUniform(16, 16, 48, 48, 16, 16, fill);
  return list;
}

DisplayList _squareCorners() {
  final list = DisplayList();
  final fill = list.addPaint(colorArgb: 0xFF66CCCC);
  // Fractional edges, so the antialiasing term is doing something even though
  // the corners are square.
  list.drawRRectUniform(8.25, 18.5, 56.75, 46.5, 0, 0, fill);
  return list;
}

DisplayList _translucent() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 64, 64, base);
  final half = list.addPaint(colorArgb: 0x80CC3311);
  final quarter = list.addPaint(colorArgb: 0x4011CC33);
  list
    ..drawRRectUniform(6, 6, 40, 40, 7, 7, half)
    ..drawRRectUniform(24, 24, 58, 58, 11, 11, quarter);
  return list;
}

DisplayList _inLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 64, 64, background);
  final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
  list.saveLayer(8, 8, 56, 56, layerPaint);
  final content = list.addPaint(colorArgb: 0xFFCC3311);
  list
    // Off-centre in the layer: a composite off by a row is invisible against a
    // symmetric shape.
    ..drawRRectUniform(12, 14, 50, 40, 9, 9, content)
    ..restore();
  return list;
}

DisplayList _stroked() {
  final list = DisplayList();
  final stroke = list.addPaint(
    colorArgb: 0xFFEFEFEF,
    style: paintStyleStroke,
    strokeWidth: 1.5,
  );
  list.drawRRectUniform(8, 18, 56, 46, 8, 8, stroke);
  return list;
}

DisplayList _perCorner() {
  final list = DisplayList();
  final fill = list.addPaint(colorArgb: 0xFF88AACC);
  list.drawRRect(8, 18, 56, 46, 2, 2, 12, 12, 2, 2, 12, 12, fill);
  return list;
}

/// Distinct rounded rectangles, more of them than the path cache holds.
DisplayList _grid() {
  final list = DisplayList();
  final fill = list.addPaint(colorArgb: 0xFF3366CC);
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

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

/// Renders [list] through one device twice - dense, then analytic - and
/// asserts the two pictures agree to [tolerance] levels per channel.
Future<void> _expectRouteParity(
  _GlSession session,
  DisplayList list, {
  required int tolerance,
}) async {
  final String? reason = session.skipReason;
  if (reason != null) {
    printOnFailure('skipped: $reason');
    markTestSkipped('no GL device: $reason');
    return;
  }
  final device = session.device!;

  device.analyticPrimitivesEnabled = false;
  final denseTarget = session.target(_size, _size);
  final PresentResult denseResult =
      await denseTarget.renderDisplayList(list, clearColor: _clear);
  expect(denseResult.status, PresentStatus.presented);
  final Framebuffer dense = _copy(denseTarget.framebuffer);
  denseTarget.dispose();

  device.analyticPrimitivesEnabled = true;
  final analyticTarget = session.target(_size, _size);
  final PresentResult analyticResult =
      await analyticTarget.renderDisplayList(list, clearColor: _clear);
  expect(analyticResult.status, PresentStatus.presented);
  final Framebuffer analytic = analyticTarget.framebuffer;

  // Two blank surfaces agree perfectly, so a scene that drew nothing would
  // pass this file in silence.
  expect(_isUniform(dense), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');

  final _Diff diff = _diff(dense, analytic);
  printOnFailure('max deviation ${diff.maxDeviation} over '
      '${diff.differingPixels} pixels');
  expect(
    diff.maxDeviation,
    lessThanOrEqualTo(tolerance),
    reason: 'the closed form and the coverage atlas disagree by up to '
        '${diff.maxDeviation} levels on ${diff.differingPixels} pixels, over '
        'a declared tolerance of $tolerance.\n${diff.report}',
  );
  analyticTarget.dispose();
}

final class _Diff {
  _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;
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
      final p = _rgba(a, x, y);
      final q = _rgba(b, x, y);
      final deviation = <int>[
        (p.$1 - q.$1).abs(),
        (p.$2 - q.$2).abs(),
        (p.$3 - q.$3).abs(),
        (p.$4 - q.$4).abs(),
      ].reduce((int m, int n) => m > n ? m : n);
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) lines.add('($x, $y): dense $p, analytic $q');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

bool _isUniform(Framebuffer buffer) {
  final first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      if (_rgba(buffer, x, y) != first) return false;
    }
  }
  return true;
}

(int, int, int, int) _rgba(Framebuffer buffer, int x, int y) {
  final i = buffer.offsetOf(x, y);
  final bytes = buffer.pixels;
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
  final copy = Framebuffer.allocate(
    width: source.width,
    height: source.height,
    format: source.format,
  );
  copy.pixels.setAll(0, source.pixels);
  return copy;
}

// ---------------------------------------------------------------------
// Device-free harness
// ---------------------------------------------------------------------

/// A sink with a real batcher and a real atlas and no GL at all.
///
/// The atlas is real rather than a double because the question every test in
/// the first two groups asks is "did this shape cost a CPU rasterisation", and
/// [GpuMaskAtlas.rasterizationCount] is the counter that answers it.
final class _SinkHarness {
  _SinkHarness({bool analytic = true})
      : atlas = GpuMaskAtlas(width: 512, height: 512) {
    batcher.beginFrame();
    atlas.beginFrame();
    sink = GpuRasterSink(
      batcher: batcher,
      backendName: 'analytic-test',
      maskAtlas: atlas,
      maskTextureId: 7,
      analyticPrimitives: analytic,
      onAtlasFlush: () {},
    );
  }

  final GpuBatcher batcher = GpuBatcher();
  final GpuMaskAtlas atlas;
  late final GpuRasterSink sink;

  Float32List get floats => batcher.buffer.vertices;

  _Vertex vertex(int index) => _Vertex(
        floats,
        index,
        batcher.batchAt(0).pipeline,
        batcher.batchAt(0).textureId,
      );
}

final class _Vertex {
  _Vertex(this._floats, this._index, this.pipeline, this.textureId);

  final Float32List _floats;
  final int _index;
  final GpuPipelineKind pipeline;
  final int textureId;

  int get _base => _index * kGpuFloatsPerVertex;

  double get u => _floats[_base + kGpuTexCoordOffset];
  double get v => _floats[_base + kGpuTexCoordOffset + 1];
  double get shapeLeft => _floats[_base + kGpuShapeRectOffset];
  double get shapeTop => _floats[_base + kGpuShapeRectOffset + 1];
  double get shapeRight => _floats[_base + kGpuShapeRectOffset + 2];
  double get shapeBottom => _floats[_base + kGpuShapeRectOffset + 3];
}

Float32List _uniformRadii(double radius) => Float32List.fromList(<double>[
      radius,
      radius,
      radius,
      radius,
      radius,
      radius,
      radius,
      radius,
    ]);

ReplayPaint _paint(int argb) => ReplayPaint(
      argbColor: argb,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: true,
    );

ReplayPaint _gradientPaint() => ReplayPaint(
      argbColor: 0xFFFFFFFF,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: true,
      gradient: LinearGradient(
        startX: 0,
        startY: 0,
        endX: 64,
        endY: 64,
        stops: const <GradientStop>[
          GradientStop(0, 0xFF000000),
          GradientStop(1, 0xFFFFFFFF),
        ],
      ),
    );

// ---------------------------------------------------------------------
// Session plumbing - the shape `cpu_gpu_parity_test.dart` uses, and for the
// same reason: a context costs tens of milliseconds and, on Windows, a window.
// ---------------------------------------------------------------------

final class _GlSession {
  _GlSession._(this.device, this.skipReason, this._surface);

  final GlRenderDevice? device;
  final String? skipReason;
  final Win32GlSurface? _surface;

  static _GlSession open() {
    try {
      return Platform.isWindows ? _openWindows() : _openEgl();
    } on Object catch (error) {
      return _GlSession._(null, 'opening a GL device threw: $error', null);
    }
  }

  static _GlSession _openWindows() {
    final attempt = Win32GlSurface.hidden();
    final surface = attempt.surface;
    if (surface == null) {
      return _GlSession._(
          null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null);
    }
    final contextAttempt = surface.createContext();
    final context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _GlSession._(null,
          'no GL context: ${contextAttempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, surface.glLibrary),
        null,
        surface,
      );
    } on BackendSelectionError catch (error) {
      surface.dispose();
      return _GlSession._(null, 'no GL device: $error', null);
    }
  }

  static _GlSession _openEgl() {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return _GlSession._(
          null, 'no GL library: ${load.attempted.join(', ')}', null);
    }
    final attempt = const GlContextFactory()
        .create(width: _size, height: _size, glLibrary: load.library!);
    final context = attempt.context;
    if (context == null) {
      return _GlSession._(
          null, 'no EGL context: ${attempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, load.library!),
        null,
        null,
      );
    } on BackendSelectionError catch (error) {
      return _GlSession._(null, 'no GL device: $error', null);
    }
  }

  GlOffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as GlOffscreenTarget;

  void close() {
    device?.dispose();
    _surface?.dispose();
  }
}
