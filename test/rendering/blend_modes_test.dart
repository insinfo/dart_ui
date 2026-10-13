/// A primitive's own blend mode, on the CPU, per channel.
///
/// Until this file existed the CPU rasteriser composited every *primitive*
/// source-over whatever the paint asked for. Only a layer's composite honoured
/// `blendMode`, and it said so in a comment. That is correct for source-over
/// and silently wrong for the other two the display list can encode: a
/// rectangle drawn with `plus` came out identical to the same rectangle drawn
/// normally, while `gpu_raster_sink.dart` handed the mode to the fixed-function
/// blend unit and got a different picture. Both suites were green; the
/// differential suite is what found it.
///
/// So the assertions here are **numbers, per channel**, and they are derived
/// from the GL blend factors rather than from what this backend happens to
/// produce:
///
///   * `srcOver` is `ONE, ONE_MINUS_SRC_ALPHA`: `dst = src + dst * (1 - a)`.
///   * `src` is `ONE, ZERO`: `dst = src`, alpha included.
///   * `plus` is `ONE, ONE` with the fixed function's clamp: `dst =
///     min(255, src + dst)`.
///
/// Every expected value below is written out as the arithmetic that produces
/// it, so a reader can check the number without running anything - and so that
/// a change to the rounding has to be argued for rather than absorbed.
///
/// ## The four primitive paths, and why each is tested separately
///
/// A rectangle, a filled path, an image and a glyph run reach four different
/// loops. A rectangle goes down `CpuRasterizer.fillRect`; a path goes through
/// the scanline filler, one span at a time, via `_CoverageToRasterizer`; an
/// image goes down the blit loop in `drawFramebuffer`; a glyph run goes down
/// `blendCoverageMask`. Four loops is four places to forget the mode, and the
/// first version of this change forgot two of them. The scene below is built
/// so that all four draw the *same* premultiplied source over the *same*
/// destination, which turns "did each path get the mode" into a single
/// expected triple that all four have to hit.
library;

import 'dart:io';
import 'dart:typed_data';

// The individual libraries rather than `package:dart_ui/dart_ui.dart`, the
// same way `test/differential` imports them: this file is about the rendering
// stack, and pulling the whole public surface in would make it fail to compile
// for reasons that have nothing to do with a blend equation.
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/raster/blend.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

/// The one source every primitive here draws: 50% red, `0x80FF0000`.
///
/// Premultiplied it is `(128, 0, 0, 128)` - `mul255(255, 128) = 128` - and its
/// alpha is neither 0 nor 255, so none of the three equations collapses into
/// another. An opaque source would make `src` and `srcOver` identical and hide
/// half of what this file is for.
const int _source = 0x80FF0000;

/// The destination: opaque blue, `(0, 0, 255, 255)` premultiplied.
///
/// Opaque so `plus` has something to saturate against, and blue so that the
/// channel `src` erases is a different one from the channel the source writes.
const int _destination = 0xFF0000FF;

/// The three answers, computed once from the equations above.
///
///   * srcOver: `128 + round(0 * 127/255) = 128` red, `0 + round(255 * 127/255)
///     = 127` blue, `128 + 127 = 255` alpha.
///   * src: the premultiplied source, unchanged, alpha included.
///   * plus: `min(255, 128 + 0)` red, `min(255, 0 + 255)` blue, `min(255, 128 +
///     255) = 255` alpha - the clamp, in two channels at once.
const (int, int, int, int) _overOpaque = (128, 0, 127, 255);
const (int, int, int, int) _srcOpaque = (128, 0, 0, 128);
const (int, int, int, int) _plusOpaque = (128, 0, 255, 255);

void main() {
  group('a rectangle', () {
    test('composites the three modes over an opaque destination', () async {
      expect(await _rect(blendModeSrcOver), _overOpaque);
      // The one that used to be ignored. Before this change every line here
      // read (128, 0, 127, 255).
      expect(await _rect(blendModeSrc), _srcOpaque);
      expect(await _rect(blendModePlus), _plusOpaque);
    });

    test('composites the three modes identically over transparency', () async {
      // Over a destination of (0, 0, 0, 0) the three equations coincide: the
      // destination term of source-over is scaled by an alpha of zero, and the
      // sum `plus` forms has nothing to add. Worth asserting rather than
      // assuming, because it is the invariant that says the modes differ only
      // in how they treat *what is already there* - a backend that mixed up
      // the source term would break this line first.
      const (int, int, int, int) premultipliedSource = (128, 0, 0, 128);
      expect(
          await _rect(blendModeSrcOver, background: null), premultipliedSource);
      expect(await _rect(blendModeSrc, background: null), premultipliedSource);
      expect(await _rect(blendModePlus, background: null), premultipliedSource);
    });

    test('plus saturates rather than wrapping', () async {
      // The classic failure: 0xC0 + 0xC0 is 0x180, which a `Uint8List` store
      // truncates to 0x80 - so two bright overlapping reds come out *darker*
      // than one. GL's fixed function clamps to 1.0 before quantising, and
      // `addSaturating` clamps in exactly the same place.
      final list = DisplayList();
      final black = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      final red = list.addPaint(
        colorArgb: 0xFFC00000,
        blendMode: blendModePlus,
        antiAlias: false,
      );
      list
        ..drawRect(0, 0, 12, 12, black)
        ..drawRect(2, 2, 10, 10, red)
        ..drawRect(2, 2, 10, 10, red);

      final target = _target();
      await target.renderDisplayList(list, clearColor: 0);

      // Drawn once: 0xC0. Drawn twice: clamped to 0xFF, not wrapped to 0x80.
      expect(_rgba(target.framebuffer, 5, 5), (255, 0, 0, 255));
      // And the alpha saturated too - 255 + 255 twice over is still 255.
      // Wrapping there would punch a transparent hole in an opaque surface.
      expect(_rgba(target.framebuffer, 5, 5).$4, 255);
      target.dispose();
    });

    test('src on an antialiased edge replaces in proportion to coverage',
        () async {
      // The semantics, pinned down. The rectangle runs to x = 5.5, so column 5
      // is half covered: `spanCoverage` quantises positions to 1/255ths of a
      // pixel from the surface origin, and 5.5 - 5.0 there is exactly 128.
      //
      // "Replace the destination" then means replace it with the source scaled
      // by that coverage - `(128, 0, 0, 128)` from an opaque red - and *not*
      // "mix the two in proportion to the coverage", which is what Skia does
      // and what would leave the pixel opaque. The reason is not taste: the
      // GL backend multiplies the premultiplied colour by the coverage in the
      // fragment shader and hands the product to a `ONE, ZERO` blend, so the
      // GPU writes `src * coverage` and keeps none of the destination. A CPU
      // that lerped would disagree with it on every antialiased edge.
      //
      // So an antialiased `src` fill cuts a soft-edged hole in what was under
      // it, and the fringe of that hole is transparent rather than a blend.
      final list = DisplayList();
      final blue = list.addPaint(colorArgb: _destination, antiAlias: false);
      final red = list.addPaint(colorArgb: 0xFFFF0000, blendMode: blendModeSrc);
      list
        ..drawRect(0, 0, 12, 12, blue)
        ..drawRect(2, 2, 5.5, 10, red);

      final target = _target();
      await target.renderDisplayList(list, clearColor: 0);

      // Interior: full coverage, so a plain replace by an opaque source.
      expect(_rgba(target.framebuffer, 3, 5), (255, 0, 0, 255));
      // The half-covered column: the source at half strength, and the blue
      // gone. A lerp would read (128, 0, 127, 255) here; source-over would
      // read (255, 0, 0, 255).
      expect(_rgba(target.framebuffer, 5, 5), (128, 0, 0, 128));
      // And the column past the edge is untouched, in `src` as in every other
      // mode: a pixel the shape does not cover is not part of the shape, so
      // there is nothing there to replace.
      expect(_rgba(target.framebuffer, 6, 5), (0, 0, 255, 255));
      target.dispose();
    });
  });

  group('a filled path', () {
    // A different loop from the rectangle's: the scanline filler emits spans
    // and `_CoverageToRasterizer` paints them one row at a time. Passing the
    // mode to `fillRect` and forgetting the span sink is the obvious way to
    // half-fix this, and it would leave every path in the framework - every
    // rounded rectangle, every stroke outline - composited source-over.
    test('composites the three modes over an opaque destination', () async {
      expect(await _path(blendModeSrcOver), _overOpaque);
      expect(await _path(blendModeSrc), _srcOpaque);
      expect(await _path(blendModePlus), _plusOpaque);
    });

    test('agrees with the rectangle path byte for byte', () async {
      // The same colour over the same destination through two different
      // loops. They have to land on the same bytes or a shape's interior and
      // an abutting rectangle show a seam.
      for (final mode in <int>[blendModeSrcOver, blendModeSrc, blendModePlus]) {
        expect(await _path(mode), await _rect(mode), reason: 'mode $mode');
      }
    });

    test('src leaves an antialiased fringe that erased the destination',
        () async {
      // The filler's coverage on a fractional edge is its own arithmetic - a
      // signed area accumulator, not the rectangle's separable product - so
      // the exact byte is not asserted here. What is asserted is the
      // semantics: the fringe is partly transparent, and the destination's
      // blue is gone from it rather than showing through.
      final builder = PathBuilder()
        ..moveTo(2, 2)
        ..lineTo(5.5, 2)
        ..lineTo(5.5, 10)
        ..lineTo(2, 10)
        ..close();

      final list = DisplayList();
      final blue = list.addPaint(colorArgb: _destination, antiAlias: false);
      final red = list.addPaint(colorArgb: 0xFFFF0000, blendMode: blendModeSrc);
      list
        ..drawRect(0, 0, 12, 12, blue)
        ..drawPath(list.addPath(builder.build()), red);

      final target = _target();
      await target.renderDisplayList(list, clearColor: 0);

      expect(_rgba(target.framebuffer, 3, 5), (255, 0, 0, 255));
      final (r, g, b, a) = _rgba(target.framebuffer, 5, 5);
      expect(a, greaterThan(0));
      expect(a, lessThan(255));
      expect(b, 0, reason: 'src replaces the destination, it does not mix');
      expect(r, a, reason: 'premultiplied red at the fringe alpha');
      expect(g, 0);
      target.dispose();
    });
  });

  group('an image', () {
    test('composites the three modes over an opaque destination', () async {
      expect(await _image(blendModeSrcOver), _overOpaque);
      expect(await _image(blendModeSrc), _srcOpaque);
      expect(await _image(blendModePlus), _plusOpaque);
    });
  });

  group('a glyph run', () {
    test('composites the three modes over an opaque destination', () async {
      // Ahem's letters are solid boxes, so a pixel well inside one has mask
      // coverage 255 and the run reduces to the same source every other
      // primitive here draws. That is what makes a per-channel assertion
      // possible on text at all.
      expect(await _glyphs(blendModeSrcOver), _overOpaque);
      expect(await _glyphs(blendModeSrc), _srcOpaque);
      expect(await _glyphs(blendModePlus), _plusOpaque);
    });

    test('src does not erase the space around the stems', () async {
      // A glyph mask is mostly zero, and a zero mask byte means the glyph does
      // not touch that pixel - so `src` has nothing to replace there. The run
      // must not clear its own bounding box.
      final target = await _glyphTarget(blendModeSrc);
      // Just outside the block, on the same row as its solid interior.
      expect(_rgba(target.framebuffer, 7, 10), (0, 0, 255, 255));
      expect(_rgba(target.framebuffer, 16, 10), (0, 0, 255, 255));
      target.dispose();
    });
  });

  group('an unknown blend mode', () {
    test('is refused by name rather than falling back to source-over', () {
      // The refusal `gpuBlendForMode` makes for the same input, so a mode
      // added to the display list and to only one backend fails loudly on the
      // other instead of drawing a plausible wrong picture. A silent fallback
      // is worse than a crash here for one specific reason: it is invisible to
      // a differential test, because the backend that substituted has stopped
      // disagreeing.
      expect(
        () => cpuBlendForMode(kBlendModeCount),
        throwsA(isA<ArgumentError>()
            .having((e) => e.name, 'name', 'blendMode')
            .having((e) => e.invalidValue, 'invalidValue', kBlendModeCount)
            .having((e) => e.message.toString(), 'message',
                allOf(contains('srcOver'), contains('src'), contains('plus')))),
      );
      expect(() => cpuBlendForMode(-1), throwsA(isA<ArgumentError>()));
    });

    test('is exactly the six the display list encodes', () {
      // The enum and the wire format have to stay the same size. If a seventh
      // constant is added, this line fails and points at the switch that needs
      // an equation rather than letting it default.
      expect(CpuBlendMode.values.length, kBlendModeCount);
      expect(cpuBlendForMode(blendModeSrcOver), CpuBlendMode.srcOver);
      expect(cpuBlendForMode(blendModeSrc), CpuBlendMode.src);
      expect(cpuBlendForMode(blendModePlus), CpuBlendMode.plus);
      expect(cpuBlendForMode(blendModeSrcIn), CpuBlendMode.srcIn);
      expect(cpuBlendForMode(blendModeDstIn), CpuBlendMode.dstIn);
      expect(cpuBlendForMode(blendModeDstOut), CpuBlendMode.dstOut);
    });

    test('skips a transparent source exactly where the wire says it may', () {
      // One rule, stated twice - once on the wire constant for the GPU sink,
      // once on the enum for the span loops - and the two must not drift.
      for (var mode = 0; mode < kBlendModeCount; mode++) {
        expect(
          cpuBlendForMode(mode).skipsTransparentSource,
          !blendModeWritesTransparentSource(mode),
          reason: 'mode $mode',
        );
      }
    });
  });

  group('the masking modes', () {
    // The GL factor pairs, applied to the same (128, 0, 0, 128) source:
    //
    //   * srcIn  `DST_ALPHA, ZERO`:           dst = src * dstAlpha
    //   * dstIn  `ZERO, SRC_ALPHA`:           dst = dst * srcAlpha
    //   * dstOut `ZERO, ONE_MINUS_SRC_ALPHA`: dst = dst * (1 - srcAlpha)
    //
    // Over the opaque blue destination (0, 0, 255, 255):
    //
    //   * srcIn:  the source scaled by 255/255 - itself, (128, 0, 0, 128).
    //   * dstIn:  blue and alpha `mul255(255, 128) = 128`: (0, 0, 128, 128).
    //   * dstOut: blue and alpha `mul255(255, 127) = 127`: (0, 0, 127, 127).
    const (int, int, int, int) srcInOpaque = (128, 0, 0, 128);
    const (int, int, int, int) dstInOpaque = (0, 0, 128, 128);
    const (int, int, int, int) dstOutOpaque = (0, 0, 127, 127);

    test('a rectangle composites each over an opaque destination', () async {
      expect(await _rect(blendModeSrcIn), srcInOpaque);
      expect(await _rect(blendModeDstIn), dstInOpaque);
      expect(await _rect(blendModeDstOut), dstOutOpaque);
    });

    test('over a half-transparent destination, srcIn reads its alpha',
        () async {
      // 0x800000FF is (0, 0, 128, 128) premultiplied. srcIn keeps the
      // *source's* colour at the destination's alpha: `mul255(128, 128) = 64`
      // in red and alpha, and the blue is gone. dstIn and dstOut scale the
      // destination by 128/255 and 127/255, both of which round 128 to 64.
      const int halfBlue = 0x800000FF;
      expect(await _rect(blendModeSrcIn, background: halfBlue), (64, 0, 0, 64));
      expect(await _rect(blendModeDstIn, background: halfBlue), (0, 0, 64, 64));
      expect(
          await _rect(blendModeDstOut, background: halfBlue), (0, 0, 64, 64));
    });

    test('over transparency, srcIn has nothing to keep', () async {
      // The destination's alpha is zero, so srcIn writes zero - the picture
      // that makes it gradient *text*: the ramp exists only where the glyphs
      // put alpha.
      expect(await _rect(blendModeSrcIn, background: null), (0, 0, 0, 0));
      expect(await _rect(blendModeDstIn, background: null), (0, 0, 0, 0));
    });

    test('a path, an image and a glyph run land on the rectangle\'s bytes',
        () async {
      // Four loops, as in the groups above, and the new modes have to reach
      // every one of them: the span sink, the blit, the coverage mask.
      for (final int mode in <int>[
        blendModeSrcIn,
        blendModeDstIn,
        blendModeDstOut,
      ]) {
        final (int, int, int, int) expected = await _rect(mode);
        expect(await _path(mode), expected, reason: 'path, mode $mode');
        expect(await _image(mode), expected, reason: 'image, mode $mode');
        expect(await _glyphs(mode), expected, reason: 'glyphs, mode $mode');
      }
    });

    test('a transparent source erases under srcIn and dstIn only', () async {
      // `blendModeWritesTransparentSource`: for the two "in" modes a source
      // of alpha zero is the strongest thing they can say. dstOut and the
      // older modes treat it as nothing to draw.
      Future<(int, int, int, int)> transparent(int mode) async {
        final list = DisplayList();
        list
          ..drawRect(0, 0, 12, 12,
              list.addPaint(colorArgb: _destination, antiAlias: false))
          ..drawRect(2, 2, 10, 10,
              list.addPaint(colorArgb: 0x00FF0000, blendMode: mode));
        final target = _target();
        await target.renderDisplayList(list, clearColor: 0);
        final pixel = _rgba(target.framebuffer, 5, 5);
        // Outside the rectangle nothing changes in any mode: the masking modes
        // are bounded.
        expect(_rgba(target.framebuffer, 0, 0), (0, 0, 255, 255),
            reason: 'mode $mode');
        target.dispose();
        return pixel;
      }

      expect(await transparent(blendModeSrcIn), (0, 0, 0, 0));
      expect(await transparent(blendModeDstIn), (0, 0, 0, 0));
      expect(await transparent(blendModeDstOut), (0, 0, 255, 255));
      expect(await transparent(blendModeSrcOver), (0, 0, 255, 255));
    });

    test('a dstIn ramp fades the destination to nothing', () async {
      // The fade-out mask, which is the reason a transparent source must not
      // be skipped. The ramp runs from opaque at x = 0 to transparent at
      // x = 12, its colour is irrelevant, and the blue under it is kept in
      // proportion. Before the "in" modes wrote transparent sources, the
      // last columns - where the ramp's alpha rounds to zero - kept the blue
      // at full strength: a fade that un-faded at its end.
      final list = DisplayList();
      list.drawRect(0, 0, 12, 12,
          list.addPaint(colorArgb: _destination, antiAlias: false));
      final Gradient ramp = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 12,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0xFF00FF00),
          GradientStop(1, 0x0000FF00),
        ],
      );
      list.drawRect(
          0,
          0,
          12,
          12,
          list.addPaint(
              colorArgb: 0, gradient: ramp, blendMode: blendModeDstIn));
      final target = _target();
      await target.renderDisplayList(list, clearColor: 0);

      var previous = 256;
      for (var x = 0; x < 12; x++) {
        final (int r, int g, int b, int a) = _rgba(target.framebuffer, x, 5);
        expect((r, g), (0, 0), reason: 'the ramp\'s green never shows ($x)');
        expect(b, a, reason: 'still opaque blue, premultiplied ($x)');
        expect(a, lessThan(previous), reason: 'monotonic fade at x = $x');
        previous = a;
      }
      expect(_rgba(target.framebuffer, 0, 5).$4, greaterThan(230));
      expect(_rgba(target.framebuffer, 11, 5).$4, lessThan(20));
      target.dispose();
    });

    test('a gradient mask reaches the fractional row a solid fill reaches',
        () async {
      // The layer ends at y = 10.3, so row 10 is 30% inside it. The red
      // content is an antialiased rectangle and covers that fraction exactly. A
      // fully transparent dstIn ramp over the layer must erase all of it -
      // row 10 included - so the blue background is all that is left. Before
      // a gradient rectangle took the exact clip into its geometry, the span
      // sink rounded y = 10.3 down to the integer clip, the mask never touched
      // row 10, and a faint red line survived under a mask that says
      // "nothing".
      final list = DisplayList();
      final Gradient clear = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 12,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0x00FFFFFF),
          GradientStop(1, 0x00FFFFFF),
        ],
      );
      list
        ..drawRect(0, 0, 12, 12,
            list.addPaint(colorArgb: _destination, antiAlias: false))
        ..saveLayer(0, 0, 12, 10.3,
            list.addPaint(colorArgb: 0xFFFFFFFF, isolatedLayer: true))
        ..drawRect(0, 0, 12, 12, list.addPaint(colorArgb: 0xFFFF0000))
        ..drawRect(
            0,
            0,
            12,
            10.3,
            list.addPaint(
                colorArgb: 0, gradient: clear, blendMode: blendModeDstIn))
        ..restore();
      final target = _target();
      await target.renderDisplayList(list, clearColor: 0);
      for (var y = 0; y < 12; y++) {
        expect(_rgba(target.framebuffer, 5, y), (0, 0, 255, 255),
            reason: 'row $y');
      }
      target.dispose();
    });

    test('on an antialiased edge, dstIn scales by the coverage too', () async {
      // The GPU multiplies the fragment by its coverage before the blend, so
      // dstIn under half coverage keeps half the destination even from an
      // opaque source. The CPU folds coverage into the source the same way.
      // Column 5 is covered 128/255 by a rectangle ending at x = 5.5.
      final list = DisplayList();
      list
        ..drawRect(0, 0, 12, 12,
            list.addPaint(colorArgb: _destination, antiAlias: false))
        ..drawRect(2, 2, 5.5, 10,
            list.addPaint(colorArgb: 0xFFFFFFFF, blendMode: blendModeDstIn));
      final target = _target();
      await target.renderDisplayList(list, clearColor: 0);
      expect(_rgba(target.framebuffer, 3, 5), (0, 0, 255, 255));
      expect(_rgba(target.framebuffer, 5, 5), (0, 0, 128, 128));
      expect(_rgba(target.framebuffer, 6, 5), (0, 0, 255, 255));
      target.dispose();
    });

    test('a layer composited with each mode', () async {
      // A layer of the (128, 0, 0, 128) source, composited back over opaque
      // blue: the composite runs the same equations as a primitive.
      Future<List<(int, int, int, int)>> layer(int mode) async {
        final list = DisplayList();
        list
          ..drawRect(0, 0, 12, 12,
              list.addPaint(colorArgb: _destination, antiAlias: false))
          ..saveLayer(0, 0, 12, 12,
              list.addPaint(colorArgb: 0xFFFFFFFF, blendMode: mode))
          ..drawRect(
              2, 2, 10, 10, list.addPaint(colorArgb: _source, antiAlias: false))
          ..restore();
        final target = _target();
        await target.renderDisplayList(list, clearColor: 0);
        final List<(int, int, int, int)> pixels = <(int, int, int, int)>[
          _rgba(target.framebuffer, 5, 5),
          _rgba(target.framebuffer, 0, 0),
        ];
        target.dispose();
        return pixels;
      }

      // Inside the layer's bounds but outside its content the layer is
      // transparent: srcIn and dstIn erase there - the composite covers the
      // whole layer - and dstOut keeps the blue.
      expect(await layer(blendModeSrcIn), <(int, int, int, int)>[
        srcInOpaque,
        (0, 0, 0, 0),
      ]);
      expect(await layer(blendModeDstIn), <(int, int, int, int)>[
        dstInOpaque,
        (0, 0, 0, 0),
      ]);
      expect(await layer(blendModeDstOut), <(int, int, int, int)>[
        dstOutOpaque,
        (0, 0, 255, 255),
      ]);
    });
  });

  group('an isolated layer', () {
    test('lets a masking primitive inside a full-opacity layer through',
        () async {
      // The same layer paint as the refusal below - opaque, source-over - plus
      // the isolation bit. It gets a real buffer, so the dstIn mask multiplies
      // the layer's red and not the blue background under it.
      final list = DisplayList();
      list
        ..drawRect(0, 0, 12, 12,
            list.addPaint(colorArgb: _destination, antiAlias: false))
        ..saveLayer(0, 0, 12, 12,
            list.addPaint(colorArgb: 0xFFFFFFFF, isolatedLayer: true))
        ..drawRect(2, 2, 10, 10,
            list.addPaint(colorArgb: 0xFFFF0000, antiAlias: false))
        ..drawRect(0, 0, 12, 12,
            list.addPaint(colorArgb: 0x80FFFFFF, blendMode: blendModeDstIn))
        ..restore();
      final target = _target();
      await target.renderDisplayList(list, clearColor: 0);
      // Red at alpha 128 inside, (128, 0, 0, 128), over opaque blue: red 128,
      // blue `mul255(255, 127) = 127`, alpha 255.
      expect(_rgba(target.framebuffer, 5, 5), (128, 0, 127, 255));
      // Outside the red, the layer was transparent and dstIn kept it so; the
      // background is untouched. Flattened, this pixel would be half blue.
      expect(_rgba(target.framebuffer, 0, 0), (0, 0, 255, 255));
      target.dispose();
    });
  });

  group('a blended primitive inside a flattened layer', () {
    test('is refused, because flattening it is not an identity', () async {
      // A layer at alpha 255 with source-over is flattened into its parent:
      // compositing it back would be the identity, so no buffer is allocated.
      // That reasoning holds for every primitive *except* one with its own
      // non-source-over mode, which then blends against the parent's pixels
      // where an isolating renderer would have blended it against
      // transparency. `gpu_raster_sink.dart` refuses that combination by name;
      // this backend could not reach it while it ignored a primitive's blend
      // mode, and honouring the mode is what made it reachable.
      final list = DisplayList();
      final opaque = list.addPaint(colorArgb: 0xFFFFFFFF);
      final red = list.addPaint(colorArgb: _source, blendMode: blendModePlus);
      list
        ..saveLayer(0, 0, 12, 12, opaque)
        ..drawRect(2, 2, 10, 10, red)
        ..restore();

      final target = _target();
      await expectLater(
        () => target.renderDisplayList(list, clearColor: 0),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.backendName, 'backendName', 'cpu')
            .having((e) => e.detail, 'detail', contains('flattened layer'))),
      );
      target.dispose();
    });

    test('is allowed once the layer is given a real buffer', () async {
      // The fix the refusal names: a layer paint that forces an offscreen
      // pass. The `plus` then adds to the transparency the layer's buffer was
      // cleared to, which is exactly what an isolating renderer means by it,
      // and the finished layer is composited over the background afterwards.
      final list = DisplayList();
      final blue = list.addPaint(colorArgb: _destination, antiAlias: false);
      final red = list.addPaint(
        colorArgb: _source,
        blendMode: blendModePlus,
        antiAlias: false,
      );
      list
        ..drawRect(0, 0, 12, 12, blue)
        // Alpha below 255, so the layer is offscreen rather than flattened.
        ..saveLayer(0, 0, 12, 12, list.addPaint(colorArgb: 0xFEFFFFFF))
        ..drawRect(2, 2, 10, 10, red)
        ..restore();

      final target = _target();
      await target.renderDisplayList(list, clearColor: 0);
      // Inside the layer: plus against (0, 0, 0, 0) is the source itself,
      // (128, 0, 0, 128). Composited at alpha 254: `mul255(128, 254) = 127` in
      // red and in alpha. Source-over that onto opaque blue: red stays 127,
      // blue becomes `mul255(255, 128) = 128`, alpha 127 + 128 = 255.
      //
      // Note what it is *not*: 255 in the blue channel. Had the layer been
      // flattened, the `plus` would have added to the background instead of to
      // transparency and the blue would have saturated - the difference the
      // refusal above exists to stop happening silently.
      expect(_rgba(target.framebuffer, 5, 5), (127, 0, 128, 255));
      target.dispose();
    });
  });
}

// ---------------------------------------------------------------------
// The scenes. One destination, one source, four ways of drawing it.
// ---------------------------------------------------------------------

const int _size = 12;

/// Draws [_source] as a rectangle with [blendMode] and reads the interior.
///
/// [background] defaults to [_destination]; pass null for a transparent
/// surface. Anti-aliasing is off and the bounds are integers, so the pixel
/// read back has coverage 255 and the number under test is the equation and
/// nothing else.
Future<(int, int, int, int)> _rect(
  int blendMode, {
  int? background = _destination,
}) async {
  final list = DisplayList();
  if (background != null) {
    list.drawRect(0, 0, _size.toDouble(), _size.toDouble(),
        list.addPaint(colorArgb: background, antiAlias: false));
  }
  final paint = list.addPaint(
    colorArgb: _source,
    blendMode: blendMode,
    antiAlias: false,
  );
  list.drawRect(2, 2, 10, 10, paint);

  final target = _target();
  await target.renderDisplayList(list, clearColor: 0);
  final pixel = _rgba(target.framebuffer, 5, 5);
  target.dispose();
  return pixel;
}

/// The same fill as [_rect], through the scanline filler instead.
///
/// The contour is on integer bounds on purpose: the interior pixel read back
/// then has coverage 255 exactly, which is `mul255`'s identity, so the two
/// paths are comparable byte for byte.
Future<(int, int, int, int)> _path(int blendMode) async {
  final builder = PathBuilder()
    ..moveTo(2, 2)
    ..lineTo(10, 2)
    ..lineTo(10, 10)
    ..lineTo(2, 10)
    ..close();

  final list = DisplayList();
  list.drawRect(0, 0, _size.toDouble(), _size.toDouble(),
      list.addPaint(colorArgb: _destination, antiAlias: false));
  final paint = list.addPaint(colorArgb: _source, blendMode: blendMode);
  list.drawPath(list.addPath(builder.build()), paint);

  final target = _target();
  await target.renderDisplayList(list, clearColor: 0);
  final pixel = _rgba(target.framebuffer, 5, 5);
  target.dispose();
  return pixel;
}

/// The same source again, this time as the pixels of an image.
///
/// The image is filled with the *premultiplied* form of [_source], because a
/// framebuffer is premultiplied and the blit does no conversion. One source
/// pixel per destination pixel, so the destination rectangle is the image's
/// own size - `drawFramebuffer` crops rather than scaling.
Future<(int, int, int, int)> _image(int blendMode) async {
  final image = Framebuffer.allocate(
    width: 8,
    height: 8,
    format: _format,
  );
  for (var i = 0; i < image.pixels.length; i += 4) {
    image.pixels[i] = 128;
    image.pixels[i + 1] = 0;
    image.pixels[i + 2] = 0;
    image.pixels[i + 3] = 128;
  }

  final list = DisplayList();
  list.drawRect(0, 0, _size.toDouble(), _size.toDouble(),
      list.addPaint(colorArgb: _destination, antiAlias: false));
  final paint = list.addPaint(
    colorArgb: 0xFFFFFFFF,
    blendMode: blendMode,
    antiAlias: false,
  );
  list.drawImage(list.addImage(image), 0, 0, 8, 8, 2, 2, 10, 10, paint);

  final target = _target();
  await target.renderDisplayList(list, clearColor: 0);
  final pixel = _rgba(target.framebuffer, 5, 5);
  target.dispose();
  return pixel;
}

/// The same source once more, as the ink of one Ahem glyph.
Future<(int, int, int, int)> _glyphs(int blendMode) async {
  final target = await _glyphTarget(blendMode);
  final pixel = _rgba(target.framebuffer, 10, 10);
  target.dispose();
  return pixel;
}

/// One Ahem 'X' at 8 px with its pen at (8, 14), over the blue destination.
///
/// Ahem's box runs one em wide from 0.8 em above the baseline to 0.2 em below,
/// so at this size and pen it covers columns 8..15 and rows 8..14 whole - (10,
/// 10) is deep inside it and (7, 10) is outside it altogether. The surface is
/// 24 px so the whole block fits with room either side.
Future<MemoryRenderTarget> _glyphTarget(int blendMode) async {
  final Typeface ahem =
      Typeface.parse(File('test/fonts/ahem.ttf').readAsBytesSync());
  final ScaledTypeface font = ahem.atSize(8);

  final list = DisplayList();
  list.drawRect(
      0, 0, 24, 24, list.addPaint(colorArgb: _destination, antiAlias: false));
  final ink = list.addPaint(colorArgb: _source, blendMode: blendMode);
  list.drawGlyphRun(
    list.addFont(font),
    ink,
    8,
    14,
    Int32List.fromList(<int>[ahem.glyphForCodePoint(0x58)]),
    Float32List.fromList(<double>[0, 0]),
    1,
  );

  final target = _target(24);
  await target.renderDisplayList(list, clearColor: 0);
  return target;
}

// ---------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------

/// RGBA rather than BGRA so the assertions above read in the order they are
/// written, and so a wrong channel cannot be mistaken for a wrong equation.
const PixelFormat _format = PixelFormat.rgba8888Premultiplied;

MemoryRenderTarget _target([int size = _size]) =>
    MemoryRenderTarget(MemorySurfaceDescriptor(
      pixelWidth: size,
      pixelHeight: size,
      format: _format,
    ));

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
