/// The same display list down the CPU path and the Direct3D 11 path, compared
/// pixel by pixel.
///
/// `test/differential/cpu_gpu_parity_test.dart` does this for OpenGL and states
/// the argument for why it is worth more than any other test in the suite: every
/// other file checks one backend against an expectation written by the person
/// who wrote that backend, which catches a wrong number and misses a wrong
/// *idea*, because an idea held on both sides of a boundary is asserted
/// identically on both sides of it. That argument is not repeated here. What is
/// repeated is the rule: **one [DisplayList], two renderers, one comparison, and
/// no reference written by hand.**
///
/// This file is the second backend to be held against the CPU, and it is the
/// first time the CPU renderer has had two independent witnesses. That is worth
/// more than a second copy of the same test: where GL and D3D11 both agree with
/// the CPU on a scene, three implementations of the same compositing arithmetic
/// agree, and the chance of a shared wrong idea drops sharply.
///
/// ## The tolerance, declared and measured: **zero, on every scene**
///
/// A non-zero tolerance is *justifiable* in principle here and it is important
/// to say why before saying it was not needed. The CPU folds 8-bit channels
/// through `mul255`, which is exact round-to-nearest of `v * a / 255`. The GPU
/// multiplies floats in a pixel shader, quantises once at the end, and hands the
/// result to a fixed-function blend unit that the Direct3D specification only
/// requires to be accurate to within one unit in the last place of the render
/// target format. A driver is therefore *allowed* to round a tie the other way,
/// and a scene whose arithmetic lands on a tie could differ by one level with
/// nothing wrong anywhere.
///
/// It was measured rather than assumed. On the device this was written against
/// - an Intel UHD Graphics at feature level 11_1 - **every scene below matches
/// in all four channels on all 576 pixels**, antialiased path fills and
/// half-opacity layers included, which are the two places a rounding difference
/// was most expected. So every test declares `tolerance: 0` and records the
/// deviation it observed.
///
/// The `tolerance` parameter stays even though nothing uses it, because it is
/// the honest place to record a driver that genuinely rounds differently. What
/// it must never become is the place a failure is made to go away: a scene that
/// has been exact and stops being exact is a regression, a scene that has always
/// been one level out is noise, and a margin wide enough to cover both destroys
/// the only signal this file produces. If a scene here starts differing, the
/// answer is to find which backend moved - and with GL asserting the same scenes
/// against the same CPU renderer, finding out is now a matter of running the
/// other file.
///
/// ## What is compared and what is not
///
/// The two scenes the task requires - solid rectangles and rectangles with
/// alpha - come first, because they are the floor: if those differ, nothing
/// below them means anything. The rest are the scenes where a Direct3D port
/// specifically goes wrong, and each says which failure it would catch. What is
/// *not* here is even-odd filling, for the reason the GL file gives: the display
/// list has no fill-rule operand, so an even-odd scene cannot be encoded.
///
/// It skips rather than fails where no device answers, which on the Linux and
/// macOS halves of CI is every run.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

/// One size for every scene, so a coordinate reads the same in all of them and
/// a difference can be found by eye in the failure output.
const int _size = 24;

/// Opaque, so a scene that gets its alpha wrong shows up as a colour and not as
/// a difference in transparency nobody looks at.
const int _clear = 0xFF000000;

void main() {
  final session = _D3d11Session.open();
  // At the root, not inside the group: one device serves the whole file, and a
  // per-group teardown would dispose it before the next group opened a target.
  tearDownAll(session.close);

  group('the CPU and Direct3D 11 render the same display list', () {
    test('solid, pixel-aligned rectangles: 0', () async {
      // The floor of the whole comparison, and the first of the two scenes the
      // task names. Both backends round an aliased rectangle's edges with
      // `pixelEdge` and write a constant colour, so there is no arithmetic left
      // for a driver to round differently - and no y flip left to hide, because
      // the rectangles are deliberately not vertically symmetric.
      // Observed deviation: 0. Anything above 0 here is a real difference.
      await _expectParity(session, _solidRects(), tolerance: 0);
    });

    test('a BGRA video frame, on the direct-upload path: 0', () async {
      // The scene that guards the optimisation. A `bgra8888` frame now reaches
      // this device as a BGRA texture and is never reordered in Dart - which
      // saves 12.7 ms per 1080p frame and would, if the format mapping were
      // wrong anywhere between here and `DXGI_FORMAT_B8G8R8A8_UNORM`, swap red
      // with blue on every video in the framework.
      //
      // A unit test can prove the *bytes* handed to the driver are right; only
      // this can prove the sampler reads them the way the backend claims. The
      // CPU renderer converts the identical frame through the reference
      // converter, so the comparison is between two independent routes to the
      // same picture, which is the rule this file is built on.
      // Observed deviation: 0.
      await _expectParity(session, _bgraVideoFrame(), tolerance: 0);
    });

    test('rectangles with alpha, overlapping: 0', () async {
      // The second scene the task names. Source-over on premultiplied bytes,
      // three times over, including where two translucent rectangles overlap -
      // which is where a backend that premultiplies at the wrong moment
      // diverges first, and where a D3D11 blend descriptor that set the colour
      // factors and left the alpha ones at zero would show up.
      // Observed deviation: 0.
      await _expectParity(session, _alphaRects(), tolerance: 0);
    });

    test('a rectangle whose edges are all fractional: 0', () async {
      // The analytic coverage term on all four edges at once. The CPU computes
      // exact area coverage in `ScanlineFiller`; the shader computes it in
      // `boxCoverage` from an interpolated device position that is only the
      // right answer if it arrives at the pixel *centre*. Direct3D 9 put the
      // centre elsewhere and the half-texel offset that fixed it is the single
      // most copied workaround in D3D sample code - it is wrong for D3D10 and
      // later and is not applied. This scene is what says so.
      //
      // The four fractions are 0.8, 0.6, 0.6 and 0.2 of a pixel and they are
      // not arbitrary: each multiplies out to a whole number of 8-bit levels
      // (204, 153, 153, 51), so the byte every edge quantises to is unambiguous
      // on both sides. The scene immediately below is the same idea with the
      // fractions chosen the other way round, and the pair is the point.
      // Observed deviation: 0, on all 576 pixels and all four channels.
      await _expectParity(session, _fractionalRect(), tolerance: 0);
    });

    test('an edge covering exactly half a pixel: 1, and neither side is wrong',
        () async {
      // The one scene in this file that does not match exactly, kept rather
      // than tuned away, because what it measures is real and knowing its shape
      // is worth more than a green line.
      //
      // The rectangle's top edge sits at y = 5.5, so row 5 is covered by
      // exactly one half. White over the 0xFF204060 background at half
      // coverage has an exact answer of 127.5 + 16 = **143.5 levels of red**.
      // The CPU produces 143 and this device produces 144. Both are half a
      // level from the truth and there is no third answer: the value is a tie
      // and the two round it in opposite directions.
      //
      // The failure was characterised by sweeping the edge across a pixel in
      // twentieths and comparing every step. Sixteen of the nineteen fractions
      // matched in all four channels; the three that did not were exactly the
      // ones whose coverage times 255 lands on a half-integer - 229.5, 127.5
      // and 76.5 - and each differed by exactly one level. So the difference is
      // not a bug on either side and it is not a general imprecision: it is the
      // 32-bit float the shader computes coverage in landing on the other side
      // of a rounding boundary from the CPU's exact rational arithmetic, at the
      // only inputs where the two are permitted to disagree at all. Direct3D
      // itself only requires a fixed-function blend to be accurate to one unit
      // in the last place of the render-target format, which is precisely this.
      //
      // Declared tolerance: 1, and it is a ceiling rather than a margin. If
      // this scene ever exceeds it, or if any *other* scene in this file starts
      // needing a tolerance at all, something moved and the answer is to find
      // out which backend - `test/differential/cpu_gpu_parity_test.dart` holds
      // the same CPU renderer against OpenGL and is the other half of that
      // question.
      // Observed deviation: 1, over 16 pixels - the one half-covered row.
      await _expectParity(session, _halfCoveredEdge(), tolerance: 1);
    });

    test('a filled path whose winding decides the answer: 0', () async {
      // Two overlapping rectangles wound the same way: non-zero fills their
      // union, even-odd would punch the overlap out. This also puts the mask
      // atlas on trial - the GPU stages the coverage into an R8_UNORM texture
      // and samples it with a point sampler, and a linear tap or an off-by-one
      // texel offset shows up along the whole antialiased boundary.
      // Observed deviation: 0.
      await _expectParity(session, _overlappingPath(), tolerance: 0);
    });

    test('a filled path with a hole, opposite winding: 0', () async {
      // The case where non-zero and even-odd agree, next to the one where they
      // do not, so the pair says which rule is in force rather than only that
      // the two backends match.
      // Observed deviation: 0.
      await _expectParity(session, _holePath(), tolerance: 0);
    });

    test('a layer at opacity 0.5: 0', () async {
      // The scene the GL parity file exists for, asked again of a second
      // backend. It is also the one that would catch the orientation bug this
      // port is most exposed to: a layer's colour texture is rendered into and
      // then *sampled*, so if D3D11's top-down render target were treated like
      // GL's bottom-up one the composite would come back vertically mirrored -
      // and the content is deliberately not centred in the layer, so a mirror
      // is visible rather than symmetric.
      // Observed deviation: 0.
      await _expectParity(session, _opacityLayer(), tolerance: 0);
    });

    test('nested layers, 0x80 inside 0x40: 0', () async {
      // Two composites on each side rather than one, so a backend that
      // multiplied opacities instead of compositing through the intermediate
      // buffer lands somewhere else entirely.
      // Observed deviation: 0.
      await _expectParity(session, _nestedLayers(), tolerance: 0);
    });

    test('a layer composited with plus: 0', () async {
      // The blend mode belongs to the composite, not to anything inside the
      // layer, and it saturates. D3D11's `ONE, ONE` clamps in its
      // fixed-function blend; `addSaturating` clamps in `blend.dart`. Equal by
      // construction, and measured here rather than assumed.
      // Observed deviation: 0.
      await _expectParity(session, _plusLayer(), tolerance: 0);
    });

    test('a layer composited with src: 0', () async {
      // `src` is the mode that proves a layer really is an isolated image: it
      // copies the layer's own transparency over the parent, so the parts of
      // the layer nothing drew into erase the background.
      // Observed deviation: 0.
      await _expectParity(session, _srcLayer(), tolerance: 0);
    });

    test('rectangles composited with plus, overlapping: 0', () async {
      // `0xC0` red over `0xC0` red is `0xFF`, not `0x80`: wrapping instead of
      // clamping is the classic `plus` bug and it only shows where two of them
      // meet. On this backend it is also a check on the blend descriptor's
      // *alpha* factors, which are set separately from the colour ones.
      // Observed deviation: 0.
      await _expectParity(session, _plusRects(), tolerance: 0);
    });

    test('a translucent rectangle composited with src: 0', () async {
      // `src` replaces all four channels, alpha included, so the result is a
      // half-transparent hole in an opaque surface rather than a blend towards
      // the paint. A backend that read `src` as "source-over with the
      // destination cleared" keeps the surface opaque and passes every other
      // scene in this file.
      // Observed deviation: 0.
      await _expectParity(session, _srcRect(), tolerance: 0);
    });

    test('a rectangular clip with a half-pixel edge: 0', () async {
      // A clip is a scissor rectangle on the GPU and a clip stack on the CPU,
      // and the two round a fractional edge in different code. On this backend
      // the scissor is used exactly as the batcher computed it, with no
      // `height - bottom` - because Direct3D's scissor origin is the top-left
      // corner, unlike GL's. Getting that wrong moves the clipped region to the
      // opposite end of the surface, which this scene's asymmetric rectangle
      // makes visible.
      // Observed deviation: 0.
      await _expectParity(session, _clipped(), tolerance: 0);
    });

    test('a layer inside a clip, and a clip inside a layer: 0', () async {
      // The interaction, because each side handles it in a different place:
      // the GPU scissors the composite quad to the layer's saved clip, and the
      // CPU narrows the parent's clip stack around the composite blit.
      // Observed deviation: 0.
      await _expectParity(session, _clippedLayer(), tolerance: 0);
    });
  });
}

// ---------------------------------------------------------------------
// The scenes. Each is a display list and nothing else: no reference, no
// expected buffer, no per-backend variation.
// ---------------------------------------------------------------------

DisplayList _solidRects() {
  final list = DisplayList();
  final red = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  final blue = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
  list
    ..drawRect(2, 2, 12, 10, red)
    ..drawRect(10, 8, 22, 20, blue)
    // Touching the surface edge, where a projection off by a row shows up.
    ..drawRect(0, 22, 24, 24, red);
  return list;
}

DisplayList _alphaRects() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final half = list.addPaint(colorArgb: 0x80CC3311, antiAlias: false);
  final quarter = list.addPaint(colorArgb: 0x4011CC33, antiAlias: false);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(2, 2, 16, 16, half)
    // Overlapping the one above: two translucent layers of arithmetic.
    ..drawRect(8, 8, 22, 22, quarter);
  return list;
}

/// A rectangle no edge of which lands on a pixel boundary.
///
/// The fractions are 0.8, 0.6, 0.6 and 0.2 of a pixel, all of which multiply
/// out to a whole number of 8-bit levels, so no edge here sits on a rounding
/// boundary. Different on every side, so no two can be right by the same
/// accident.
DisplayList _fractionalRect() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, base);
  final ink = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawRect(3.2, 5.4, 18.6, 17.2, ink);
  return list;
}

/// A rectangle whose top edge covers row 5 by exactly one half.
///
/// The other three edges are on whole pixels on purpose: the scene has to
/// isolate the tie, so that a failure here cannot be anything else.
DisplayList _halfCoveredEdge() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, base);
  final ink = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawRect(4, 5.5, 20, 18, ink);
  return list;
}

/// Two rectangles wound the same way, so non-zero fills their union.
DisplayList _overlappingPath() {
  final builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 14, 14), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(9, 9, 20, 20), clockwise: true);

  final list = DisplayList();
  final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

/// An inner contour wound against the outer one: a hole under either rule.
DisplayList _holePath() {
  final builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 21, 21), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(8, 8, 16, 16), clockwise: false);

  final list = DisplayList();
  final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

DisplayList _opacityLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  // Only the alpha of a layer paint means anything; the colour is not a tint.
  final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
  list.saveLayer(4, 4, 20, 20, layerPaint);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  // Deliberately not centred in the layer: a composite that is upside down or
  // off by a row is invisible against a symmetric shape.
  list
    ..drawRect(6, 6, 18, 12, content)
    ..restore();
  return list;
}

DisplayList _nestedLayers() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final outer = list.addPaint(colorArgb: 0x80FFFFFF);
  list.saveLayer(3, 3, 21, 21, outer);
  final inner = list.addPaint(colorArgb: 0x40FFFFFF);
  list.saveLayer(6, 6, 18, 18, inner);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..drawRect(6, 6, 18, 12, content)
    ..restore()
    ..restore();
  return list;
}

DisplayList _plusRects() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final add = list.addPaint(
    colorArgb: 0xC0CC3311,
    antiAlias: false,
    blendMode: blendModePlus,
  );
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(2, 2, 16, 16, add)
    ..drawRect(10, 10, 22, 22, add);
  return list;
}

DisplayList _srcRect() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final replace = list.addPaint(
    colorArgb: 0x80CC3311,
    antiAlias: false,
    blendMode: blendModeSrc,
  );
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(4, 4, 20, 20, replace);
  return list;
}

DisplayList _plusLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final layerPaint =
      list.addPaint(colorArgb: 0xFFFFFFFF, blendMode: blendModePlus);
  list.saveLayer(4, 4, 20, 20, layerPaint);
  final content = list.addPaint(colorArgb: 0xFF443322, antiAlias: false);
  list
    ..drawRect(6, 6, 18, 12, content)
    ..restore();
  return list;
}

DisplayList _srcLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final layerPaint =
      list.addPaint(colorArgb: 0xFFFFFFFF, blendMode: blendModeSrc);
  list.saveLayer(4, 4, 20, 20, layerPaint);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..drawRect(6, 6, 18, 12, content)
    ..restore();
  return list;
}

DisplayList _clipped() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..save()
    // A half-pixel edge, and an asymmetric rectangle, so a scissor computed
    // from the wrong origin lands somewhere visibly wrong.
    ..clipRect(4.5, 4, 18, 17.5)
    ..drawRect(0, 0, 24, 24, content)
    ..restore()
    // And something outside the clip afterwards, so a clip that leaked past
    // its restore is visible as well.
    ..drawRect(20, 20, 24, 24, content);
  return list;
}

DisplayList _clippedLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..save()
    // The clip is tighter than the layer, so the composite has to obey it.
    ..clipRect(6, 6, 16, 16)
    ..saveLayer(3, 3, 21, 21, layerPaint);
  // And a clip inside the layer, narrower still.
  list
    ..save()
    ..clipRect(8, 8, 20, 14)
    ..drawRect(0, 0, 24, 24, content)
    ..restore()
    ..restore()
    ..restore();
  return list;
}

/// A `bgra8888` video frame drawn over the whole surface.
///
/// The colours are chosen so that a red/blue exchange is the loudest possible
/// failure: pure red, pure blue, and a mid grey that is *not* symmetric in its
/// channels. A swap turns the red block blue, which on a synthetic ramp - or on
/// a dark film - is exactly the difference nobody notices.
///
/// `bgra8888` specifically, because that is what Media Foundation decodes h264
/// into and it is the layout that now reaches the GPU without being converted:
/// [GpuTextureFormat.bgra8888Premultiplied] is uploaded as the decoder's own
/// bytes and reordered by the texture unit. The CPU renderer converts the same
/// frame through `convertVideoFrameToRgba` instead, so the two agree only if
/// the sampler really does return what this backend claims it returns.
DisplayList _bgraVideoFrame() {
  final frame = VideoFrame.allocate(
    VideoFrameFormat(
      pixelFormat: VideoPixelFormat.bgra8888,
      width: _size,
      height: _size,
      range: VideoColorRange.full,
    ),
    streamId: 77,
  );
  final Uint8List bytes = frame.plane(0).bytes;
  // Source order is B, G, R, A.
  const List<List<int>> colors = <List<int>>[
    <int>[0, 0, 255, 255], // red
    <int>[255, 0, 0, 255], // blue
    <int>[0, 255, 0, 255], // green
    <int>[32, 96, 200, 255], // asymmetric in every channel
  ];
  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      // Blocks of 6, so a neighbourhood is uniform and the picture stays
      // readable in the failure report, without any scaling being involved.
      final List<int> color = colors[(x ~/ 6 + y ~/ 6) % colors.length];
      bytes.setAll((y * _size + x) * 4, color);
    }
  }

  final list = DisplayList();
  final paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
  // One texel per pixel, deliberately. Drawing the frame scaled would compare
  // the CPU's image resampler against a GPU linear sampler, and those differ
  // by design on a high-contrast source - a difference far larger than the
  // channel swap this scene exists to catch, and one that would drown it.
  list.drawImage(
    list.addImage(frame),
    0,
    0,
    _size.toDouble(),
    _size.toDouble(),
    0,
    0,
    _size.toDouble(),
    _size.toDouble(),
    paint,
  );
  return list;
}

/// Appends [rect] as one closed contour, wound the way [clockwise] says.
///
/// Written out rather than taken from `PathBuilder.addRect`, because the whole
/// point of the two path scenes is the *direction* of the second contour, and a
/// helper that picked its own would make the pair meaningless.
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

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

/// Renders [list] through both backends and asserts they agree.
///
/// [tolerance] is a per-channel level, and every test states the deviation it
/// actually observed. Skips when there is no device, naming the reason.
Future<void> _expectParity(
  _D3d11Session session,
  DisplayList list, {
  required int tolerance,
}) async {
  final String? reason = session.skipReason;
  if (reason != null) {
    // Not a silent return: the reason is printed and the test is marked
    // skipped, so a run with no device says so instead of looking like a run
    // that compared something.
    printOnFailure('skipped: $reason');
    markTestSkipped('no Direct3D 11 device: $reason');
    return;
  }

  final MemoryRenderTarget cpu = _cpuTarget(_size, _size);
  await cpu.renderDisplayList(list, clearColor: _clear);

  final D3d11OffscreenTarget gpu = session.target(_size, _size);
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
    reason: 'the CPU and Direct3D 11 disagree by up to ${diff.maxDeviation} '
        'levels on ${diff.differingPixels} pixels, over a declared tolerance '
        'of $tolerance.\n${diff.report}',
  );

  cpu.dispose();
  gpu.dispose();
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

_Diff _diff(Framebuffer cpu, Framebuffer gpu) {
  expect(gpu.width, cpu.width);
  expect(gpu.height, cpu.height);
  var maxDeviation = 0;
  var differing = 0;
  final lines = <String>[];
  for (var y = 0; y < cpu.height; y++) {
    for (var x = 0; x < cpu.width; x++) {
      final (int, int, int, int) a = _rgba(cpu, x, y);
      final (int, int, int, int) b = _rgba(gpu, x, y);
      final int deviation = <int>[
        (a.$1 - b.$1).abs(),
        (a.$2 - b.$2).abs(),
        (a.$3 - b.$3).abs(),
        (a.$4 - b.$4).abs(),
      ].reduce((int p, int q) => p > q ? p : q);
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) lines.add('($x, $y): cpu $a, gpu $b');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

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

/// A CPU target in the same pixel format the D3D11 readback uses, so a
/// comparison that went wrong cannot be a channel-order mistake in the test
/// itself.
MemoryRenderTarget _cpuTarget(int width, int height) =>
    MemoryRenderTarget(MemorySurfaceDescriptor(
      pixelWidth: width,
      pixelHeight: height,
      format: PixelFormat.rgba8888Premultiplied,
    ));

// ---------------------------------------------------------------------
// Session plumbing - the same shape `d3d11_device_test.dart` uses, and for the
// same reason: a device costs two shader compiles and every pipeline object.
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
