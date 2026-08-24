/// What the player's device-space primitives turn into.
///
/// The sink is where the two rectangles - the pixels the rasteriser visits
/// and the exact shape it computes coverage against - are decided, and
/// getting that pair wrong is invisible until an edge is off by one pixel of
/// grey. It needs no device: everything below it is a typed array.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_glyph_atlas.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_atlas.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_raster_sink.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

const ReplayPaint _opaque = ReplayPaint(
  argbColor: 0xFF204080,
  style: paintStyleFill,
  strokeWidth: 0,
  blendMode: blendModeSrcOver,
  antiAlias: true,
);

const Rect _wideClip = Rect.fromLTRB(0, 0, 1000, 1000);

void main() {
  group('fillDeviceRect', () {
    test('an antialiased rect snaps the quad out and keeps the shape', () {
      final sink = _sink();
      sink.fillDeviceRect(
          const Rect.fromLTRB(10.3, 20.7, 30.2, 40.1), _wideClip, _opaque);

      // The quad has to cover every pixel the shape touches even partially,
      // or the fragment stage never runs on the edge pixels it is meant to
      // shade. The shape stays fractional: that difference is the coverage.
      expect(_quad(sink), <double>[10, 20, 31, 41]);
      expect(_shape(sink), _near(<double>[10.3, 20.7, 30.2, 40.1]));
    });

    test('an aliased rect makes quad and shape identical', () {
      final sink = _sink();
      sink.fillDeviceRect(
        const Rect.fromLTRB(10.3, 20.7, 30.2, 40.1),
        _wideClip,
        _paint(antiAlias: false),
      );

      // Coverage then evaluates to exactly 1 inside, which is what an aliased
      // fill means, and the rounding matches CpuRasterizer.fillRect so the
      // two backends put ink in the same pixels.
      expect(_quad(sink), _shape(sink));
      expect(_quad(sink), <double>[10, 21, 30, 40]);
    });

    test('the colour is premultiplied at vertex-write time', () {
      final sink = _sink();
      sink.fillDeviceRect(
        const Rect.fromLTRB(0, 0, 10, 10),
        _wideClip,
        _paint(argb: 0x80FF0000),
      );

      final buffer = sink.batcher.buffer;
      const alpha = 0x80 / 255.0;
      expect(buffer.vertexFloat(0, kGpuColorOffset), closeTo(alpha, 1e-6));
      expect(buffer.vertexFloat(0, kGpuColorOffset + 1), 0);
      expect(buffer.vertexFloat(0, kGpuColorOffset + 3), closeTo(alpha, 1e-6));
    });

    test('a fully transparent paint draws nothing at all', () {
      final sink = _sink();
      sink.fillDeviceRect(
        const Rect.fromLTRB(0, 0, 10, 10),
        _wideClip,
        _paint(argb: 0x00FF0000),
      );

      expect(sink.batcher.batchCount, 0);
      expect(sink.batcher.buffer.vertexCount, 0);
    });

    test('a rect entirely outside the clip leaves no empty draw', () {
      final sink = _sink();
      sink.fillDeviceRect(const Rect.fromLTRB(200, 200, 300, 300),
          const Rect.fromLTRB(0, 0, 100, 100), _opaque);

      expect(sink.batcher.batchCount, 0);
    });

    test('the clip is folded into the geometry', () {
      final sink = _sink();
      sink.fillDeviceRect(const Rect.fromLTRB(-10, -10, 50, 50),
          const Rect.fromLTRB(0, 0, 20, 20), _opaque);

      expect(_shape(sink), <double>[0, 0, 20, 20]);
    });

    test('the scissor rounds outward, never inward', () {
      // Inward would clip off the antialiased fringe of a fractional clip
      // edge, which is the one pixel the analytic coverage exists to draw.
      final sink = _sink();
      sink.fillDeviceRect(const Rect.fromLTRB(0, 0, 100, 100),
          const Rect.fromLTRB(4.2, 5.8, 40.1, 50.9), _opaque);

      final batch = sink.batcher.batchAt(0);
      expect(batch.scissorLeft, 4);
      expect(batch.scissorTop, 5);
      expect(batch.scissorRight, 41);
      expect(batch.scissorBottom, 51);
    });

    test('the fill-only primitive redirects strokes to the path API', () {
      // DisplayListPlayer performs that redirect because only the path method
      // carries the local-to-device transform needed to scale stroke width.
      final sink = _sink();
      expect(
        () => sink.fillDeviceRect(const Rect.fromLTRB(0, 0, 10, 10), _wideClip,
            _paint(style: paintStyleStroke)),
        throwsA(
          isA<UnsupportedCapabilityError>().having(
            (e) => e.detail,
            'detail',
            contains('GPU path'),
          ),
        ),
      );
    });
  });

  group('drawDeviceImage', () {
    test('an image at a fractional position covers whole pixels', () {
      // The seam. Before the quad was snapped outward, the shape rect equalled
      // a fractional quad, so `boxCoverage` returned a fraction on every edge
      // pixel that was rasterised and the pixels whose centres fell outside
      // were never rasterised at all - a visible dark line between two
      // adjacent images.
      final sink = _sink(resolver: _FixedResolver(_FakeTexture(9, 64, 64)));
      sink.drawDeviceImage(
        _image,
        const Rect.fromLTRB(0, 0, 64, 64),
        const Rect.fromLTRB(10.3, 20.7, 42.3, 52.7),
        _wideClip,
        _opaque,
      );

      expect(_quad(sink), <double>[10, 20, 43, 53]);
      expect(_shape(sink), _near(<double>[10.3, 20.7, 42.3, 52.7]));
    });

    test('the texture coordinates follow the snapped quad, not the shape', () {
      // Otherwise the snap stretches the image by up to a pixel per edge,
      // which on a nine-patch or an icon grid is a visible misalignment.
      final sink = _sink(resolver: _FixedResolver(_FakeTexture(9, 32, 32)));
      sink.drawDeviceImage(
        _image,
        const Rect.fromLTRB(0, 0, 32, 32),
        const Rect.fromLTRB(10.5, 0, 42.5, 32),
        _wideClip,
        _opaque,
      );

      final buffer = sink.batcher.buffer;
      // The quad starts half a pixel left of the image, so u starts half a
      // texel before zero; clamp-to-edge makes that harmless and the scale
      // stays exactly one texel per pixel.
      expect(
          buffer.vertexFloat(0, kGpuTexCoordOffset), closeTo(-0.5 / 32, 1e-6));
      expect(
          buffer.vertexFloat(1, kGpuTexCoordOffset), closeTo(32.5 / 32, 1e-6));
    });

    test('a clipped image samples the part of itself that survived', () {
      final sink = _sink(resolver: _FixedResolver(_FakeTexture(9, 100, 100)));
      sink.drawDeviceImage(
        _image,
        const Rect.fromLTRB(0, 0, 100, 100),
        const Rect.fromLTRB(0, 0, 100, 100),
        const Rect.fromLTRB(50, 0, 100, 100),
        _opaque,
      );

      final buffer = sink.batcher.buffer;
      expect(buffer.vertexFloat(0, kGpuTexCoordOffset), closeTo(0.5, 1e-6));
      expect(_quad(sink)[0], 50);
    });

    test('it batches on the texture id', () {
      final sink = _sink(resolver: _FixedResolver(_FakeTexture(7, 8, 8)));
      sink
        ..drawDeviceImage(_image, const Rect.fromLTRB(0, 0, 8, 8),
            const Rect.fromLTRB(0, 0, 8, 8), _wideClip, _opaque)
        ..drawDeviceImage(_image, const Rect.fromLTRB(0, 0, 8, 8),
            const Rect.fromLTRB(8, 0, 16, 8), _wideClip, _opaque);

      expect(sink.batcher.batchCount, 1);
      expect(sink.batcher.batchAt(0).textureId, 7);
      expect(sink.batcher.batchAt(0).pipeline, GpuPipelineKind.texturedImage);
    });

    test('a device with no resolver says so instead of drawing nothing', () {
      final sink = _sink();
      expect(
        () => sink.drawDeviceImage(_image, const Rect.fromLTRB(0, 0, 8, 8),
            const Rect.fromLTRB(0, 0, 8, 8), _wideClip, _opaque),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
    });

    test('an invalidated texture is refused, not sampled', () {
      // A device loss frees the driver's textures while the Dart handles
      // survive; binding one is undefined output rather than an error.
      final texture = _FakeTexture(4, 8, 8)..valid = false;
      final sink = _sink(resolver: _FixedResolver(texture));
      expect(
        () => sink.drawDeviceImage(_image, const Rect.fromLTRB(0, 0, 8, 8),
            const Rect.fromLTRB(0, 0, 8, 8), _wideClip, _opaque),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
    });
  });

  group('drawDevicePath', () {
    test('expands strokes with the shared stroker before mask rasterization',
        () {
      final GpuMaskAtlas atlas = GpuMaskAtlas(width: 64, height: 64);
      final GpuRasterSink sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
        maskAtlas: atlas,
        maskTextureId: 17,
      );
      sink.drawDevicePath(
        Path.rect(const Rect.fromLTRB(10, 10, 30, 30)),
        Transform2D.identity,
        _wideClip,
        _paint(style: paintStyleStroke, strokeWidth: 4),
      );

      expect(sink.batcher.quadCount, 1);
      expect(sink.batcher.batchAt(0).textureId, 17);
      expect(atlas.rasterizationCount, 1);
      expect(_quad(sink), <double>[8, 8, 32, 32]);
    });
  });

  group('layers', () {
    test('depth tracks begin and end', () {
      final sink = _sink()
        ..beginLayer(_wideClip, _wideClip, _opaque)
        ..beginLayer(_wideClip, _wideClip, _opaque);
      expect(sink.layerDepth, 2);
      sink
        ..endLayer()
        ..endLayer();
      expect(sink.layerDepth, 0);
    });

    test('an unbalanced endLayer throws rather than going negative', () {
      // A negative depth would hide the real problem: the player and the sink
      // disagreeing about whether a clip is still in force.
      expect(() => _sink().endLayer(), throwsStateError);
    });
  });

  group('drawDeviceGlyphRun', () {
    late Typeface ahem;
    late ScaledTypeface font;
    late int letterX;
    late int letterY;
    late int space;

    setUp(() {
      // Ahem's letters are solid em-square blocks, so a glyph's quad is a
      // rectangle whose corners can be named exactly: 16x17 at 16 px, sitting
      // 13 px above the baseline.
      ahem = Typeface.parse(File('test/fonts/ahem.ttf').readAsBytesSync());
      font = ahem.atSize(16);
      letterX = ahem.glyphForCodePoint(0x58);
      letterY = ahem.glyphForCodePoint(0x59);
      space = ahem.glyphForCodePoint(0x20);
    });

    test('a run of repeated glyphs is one batch, not one per glyph', () {
      // The reason the atlas exists. A draw call per glyph would be no
      // acceleration at all, and nothing downstream can tell the difference
      // except a profile - so it is asserted here.
      final atlas = GpuGlyphAtlas();
      final sink = _sink(glyphAtlas: atlas, fonts: _FixedFont(font));

      _drawRun(
        sink,
        ids: List<int>.filled(8, letterX),
        offsets: <double>[
          for (var i = 0; i < 8; i++) ...<double>[i * 16.0, 0],
        ],
      );

      expect(sink.batcher.batchCount, 1);
      expect(sink.batcher.quadCount, 8);
      final batch = sink.batcher.batchAt(0);
      expect(batch.quadCount, 8);
      expect(batch.pipeline, GpuPipelineKind.coverageMask);
      expect(batch.textureId, _glyphTextureId);
      // Eight quads out of one rasterisation: the repeats are cache hits.
      expect(atlas.missCount, 1);
      expect(atlas.hitCount, 7);
    });

    test('the quad is whole pixels around the mask, at one texel per pixel',
        () {
      final atlas = GpuGlyphAtlas();
      final sink = _sink(glyphAtlas: atlas, fonts: _FixedFont(font));
      _drawRun(sink, ids: <int>[letterX], offsets: <double>[0, 0]);

      // Pen at (10, 30); the mask is 16x17 and starts 13 px above the
      // baseline, so the quad is exactly that box on whole pixels.
      expect(_quad(sink), <double>[10, 17, 26, 34]);
      final entry = atlas.acquire(font, letterX)!;
      final buffer = sink.batcher.buffer;
      expect(buffer.vertexFloat(0, kGpuTexCoordOffset),
          closeTo(entry.x * atlas.texelWidth, 1e-9));
      expect(buffer.vertexFloat(2, kGpuTexCoordOffset),
          closeTo((entry.x + 16) * atlas.texelWidth, 1e-9));
      // Sixteen texels across sixteen pixels: any other ratio resamples the
      // coverage and gives the soft, muddy text bitmap caches are known for.
      final double u0 = buffer.vertexFloat(0, kGpuTexCoordOffset);
      final double u1 = buffer.vertexFloat(2, kGpuTexCoordOffset);
      expect((u1 - u0) * atlas.width, closeTo(16, 1e-6));
    });

    test('the shape rect equals the quad, so coverage comes only from the mask',
        () {
      // Letting the analytic term run as well would shave the outer row and
      // column off every glyph - text that looks a little too light.
      final sink = _sink(glyphAtlas: GpuGlyphAtlas(), fonts: _FixedFont(font));
      _drawRun(sink, ids: <int>[letterX], offsets: <double>[0, 0]);

      expect(_shape(sink), _quad(sink));
    });

    test('offsets inside one subpixel bucket give one variant and one quad',
        () {
      // The rule: the fraction picks the variant, the *quantised* whole pixel
      // places the quad. Two pens a hundredth of a pixel apart must not move
      // the glyph, or text shimmers as a list scrolls.
      final atlas = GpuGlyphAtlas();
      final sink = _sink(glyphAtlas: atlas, fonts: _FixedFont(font));
      _drawRun(sink,
          ids: <int>[letterX],
          offsets: <double>[0, 0],
          origin: const Offset(10.02, 30));
      _drawRun(sink,
          ids: <int>[letterX],
          offsets: <double>[0, 0],
          origin: const Offset(10.1, 30));

      expect(atlas.missCount, 1, reason: 'both pens are in bucket 0');
      expect(_quadAt(sink, 0), _quadAt(sink, 1));
      expect(_quadAt(sink, 0)[0], 10);
    });

    test('a different bucket is a different variant at the same whole pixel',
        () {
      final atlas = GpuGlyphAtlas();
      final sink = _sink(glyphAtlas: atlas, fonts: _FixedFont(font));
      _drawRun(sink,
          ids: <int>[letterX],
          offsets: <double>[0, 0],
          origin: const Offset(10.02, 30));
      _drawRun(sink,
          ids: <int>[letterX],
          offsets: <double>[0, 0],
          origin: const Offset(10.2, 30));

      expect(atlas.missCount, 2, reason: '0.2 px rounds into bucket 1');
      final buffer = sink.batcher.buffer;
      expect(
        buffer.vertexFloat(4, kGpuTexCoordOffset),
        isNot(closeTo(buffer.vertexFloat(0, kGpuTexCoordOffset), 1e-9)),
        reason: 'the two variants are different texels',
      );
      // Same whole pixel: the offset lives in the mask, not in the position.
      expect(_quadAt(sink, 1)[0], 10);
      // The shifted variant is one column wider, and that column is drawn.
      expect(_quadAt(sink, 1)[2], 27);
    });

    test('a pen that rounds up to the next pixel moves the quad, not the mask',
        () {
      // glyphSubpixelBucket and glyphPixelOrigin have to be read as a pair:
      // 10.9 rounds to bucket 0 *of pixel 11*, and using bucket 0 with pixel
      // 10 would put the glyph a pixel to the left of where it was measured.
      final atlas = GpuGlyphAtlas();
      final sink = _sink(glyphAtlas: atlas, fonts: _FixedFont(font));
      _drawRun(sink,
          ids: <int>[letterX],
          offsets: <double>[0, 0],
          origin: const Offset(10.0, 30));
      _drawRun(sink,
          ids: <int>[letterX],
          offsets: <double>[0, 0],
          origin: const Offset(10.9, 30));

      expect(atlas.missCount, 1, reason: 'both are bucket 0');
      expect(_quadAt(sink, 0)[0], 10);
      expect(_quadAt(sink, 1)[0], 11);
    });

    test('a blank glyph draws nothing but still batches with its neighbours',
        () {
      final sink = _sink(glyphAtlas: GpuGlyphAtlas(), fonts: _FixedFont(font));
      _drawRun(sink,
          ids: <int>[letterX, space, letterY],
          offsets: <double>[0, 0, 16, 0, 32, 0]);

      expect(sink.batcher.quadCount, 2, reason: 'the space has no coverage');
      expect(sink.batcher.batchCount, 1);
    });

    test('a glyph outside the clip emits no quad', () {
      final sink = _sink(glyphAtlas: GpuGlyphAtlas(), fonts: _FixedFont(font));
      _drawRun(
        sink,
        ids: <int>[letterX],
        offsets: <double>[0, 0],
        clip: const Rect.fromLTRB(200, 200, 300, 300),
      );

      expect(sink.batcher.batchCount, 0, reason: 'and no empty draw call');
    });

    test('a partly clipped glyph is trimmed in texels as well as pixels', () {
      // Trimming the quad without trimming the texture coordinates squeezes
      // the whole glyph into what is left of it.
      final atlas = GpuGlyphAtlas();
      final sink = _sink(glyphAtlas: atlas, fonts: _FixedFont(font));
      _drawRun(
        sink,
        ids: <int>[letterX],
        offsets: <double>[0, 0],
        clip: const Rect.fromLTRB(14, 0, 1000, 1000),
      );

      final entry = atlas.acquire(font, letterX)!;
      expect(_quad(sink), <double>[14, 17, 26, 34]);
      expect(
        sink.batcher.buffer.vertexFloat(0, kGpuTexCoordOffset),
        closeTo((entry.x + 4) * atlas.texelWidth, 1e-9),
      );
    });

    test('the paint colour is premultiplied, and transparent text is skipped',
        () {
      final sink = _sink(glyphAtlas: GpuGlyphAtlas(), fonts: _FixedFont(font));
      _drawRun(sink,
          ids: <int>[letterX],
          offsets: <double>[0, 0],
          paint: _paint(argb: 0x80FF0000));

      const alpha = 0x80 / 255.0;
      final buffer = sink.batcher.buffer;
      expect(buffer.vertexFloat(0, kGpuColorOffset), closeTo(alpha, 1e-6));
      expect(buffer.vertexFloat(0, kGpuColorOffset + 1), 0);

      final invisible =
          _sink(glyphAtlas: GpuGlyphAtlas(), fonts: _FixedFont(font));
      _drawRun(invisible,
          ids: <int>[letterX],
          offsets: <double>[0, 0],
          paint: _paint(argb: 0x00FF0000));
      expect(invisible.batcher.batchCount, 0);
    });

    test('a uniform scale scales the font, not the mask', () {
      // Resampling a mask is what gives bitmap glyph caches their soft,
      // muddy reputation; the outline was kept precisely to avoid it.
      final atlas = GpuGlyphAtlas();
      final sink = _sink(glyphAtlas: atlas, fonts: _FixedFont(font));
      _drawRun(
        sink,
        ids: <int>[letterX],
        offsets: <double>[0, 0],
        transform: const Transform2D.scaling(2, 2),
      );

      expect(atlas.isResident(ahem.atSize(32), letterX), isTrue);
      final quad = _quad(sink);
      expect(quad[2] - quad[0], 32);
    });

    test('a rotated transform leaves the glyph atlas for the mask route', () {
      // This used to be a refusal, and that refusal is what forced every
      // caller with a vertical label to stack characters instead. A slot in
      // the glyph atlas is keyed by size and sampled one texel per pixel,
      // which a rotation destroys - so the run goes to the *mask* atlas
      // instead, as a filled outline, exactly as a rotated path would.
      final glyphs = GpuGlyphAtlas();
      final masks = GpuMaskAtlas(width: 256, height: 256)..beginFrame();
      final sink = _sink(
        glyphAtlas: glyphs,
        maskAtlas: masks,
        maskTextureId: 17,
        fonts: _FixedFont(font),
      );

      _drawRun(
        sink,
        ids: <int>[letterX],
        offsets: <double>[0, 0],
        clip: const Rect.fromLTRB(-256, -256, 256, 256),
        transform: const Transform2D(0, 1, -1, 0, 0, 0),
      );

      expect(glyphs.missCount, 0,
          reason: 'a slot keyed by size cannot carry an angle, so admitting '
              'this glyph would draw one frame at the previous frame angle');
      expect(glyphs.hitCount, 0);
      expect(sink.batcher.quadCount, 1,
          reason: 'the glyph still has to reach the surface');
      expect(sink.batcher.batchAt(0).textureId, 17,
          reason: 'out of the mask atlas, which is where rotated coverage '
              'lives');
    });

    test('the rotated quad is placed by the outline, not by a mask offset', () {
      // Ahem's letter is a solid em box rising 0.8 em above the baseline and
      // spanning one em. At 16 px the box sits at x in [0, 16), y in [-13, 4)
      // *relative to the pen* - which the upright test above sees as
      // (10, 17, 26, 34) for a pen at (10, 30).
      //
      // The matrix here is (x, y) -> (-y, x) and the pen is already in device
      // space, so only the box turns about it: x in (-4, 13], y in [0, 16),
      // which lands at (6, 30, 23, 46). A sink that silently dropped the
      // rotation would report the upright rect and look like it had worked.
      final masks = GpuMaskAtlas(width: 256, height: 256)..beginFrame();
      final sink = _sink(
        glyphAtlas: GpuGlyphAtlas(),
        maskAtlas: masks,
        maskTextureId: 17,
        fonts: _FixedFont(font),
      );

      _drawRun(
        sink,
        ids: <int>[letterX],
        offsets: <double>[0, 0],
        clip: const Rect.fromLTRB(-256, -256, 256, 256),
        transform: const Transform2D(0, 1, -1, 0, 0, 0),
      );

      final List<double> quad = _quad(sink);
      expect(quad[0], closeTo(6, 0.5), reason: 'left');
      expect(quad[1], closeTo(30, 0.5), reason: 'top');
      expect(quad[2], closeTo(23, 0.5), reason: 'right');
      expect(quad[3], closeTo(46, 0.5), reason: 'bottom');
      // 17 wide by 16 tall, where the upright quad is 16 by 17: the em box's
      // two dimensions have swapped, which is the whole visible consequence of
      // the quarter turn on a shape this symmetric.
      expect(quad[2] - quad[0], 17);
      expect(quad[3] - quad[1], 16);
    });

    test('stroked text is refused, and says why the coverage cannot serve', () {
      final sink = _sink(glyphAtlas: GpuGlyphAtlas(), fonts: _FixedFont(font));
      expect(
        () => _drawRun(sink,
            ids: <int>[letterX],
            offsets: <double>[0, 0],
            paint: _paint(style: paintStyleStroke)),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.detail, 'detail', contains('outline'))),
      );
    });

    test('a device with no glyph atlas says so instead of drawing nothing', () {
      // And no longer claims a shaper and an outline source are what is
      // missing: both exist, and this used to throw UnimplementedError saying
      // otherwise.
      final sink = _sink(fonts: _FixedFont(font));
      expect(
        () => _drawRun(sink, ids: <int>[letterX], offsets: <double>[0, 0]),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.detail, 'detail', contains('glyph atlas'))),
      );
    });

    test('a device with no font resolver says so too', () {
      final sink = _sink(glyphAtlas: GpuGlyphAtlas());
      expect(
        () => _drawRun(sink, ids: <int>[letterX], offsets: <double>[0, 0]),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.detail, 'detail', contains('GpuFontResolver'))),
      );
    });

    test('a full atlas with no flush handler fails by name, not silently', () {
      // Dropping the rest of the run would leave a hole in a word that reads
      // as a font bug.
      final atlas = GpuGlyphAtlas(width: 32, height: 32, plotSize: 32);
      final sink = _sink(glyphAtlas: atlas, fonts: _FixedFont(font));
      expect(
        () => _drawRun(sink,
            ids: <int>[letterX, letterY], offsets: <double>[0, 0, 16, 0]),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.detail, 'detail', contains('full'))),
      );
    });

    test('a full atlas with a handler flushes and finishes the run', () {
      // One 16 px ahem glyph fills a 32 px plot, so the second glyph of this
      // run cannot be placed until the first batch has been issued.
      final atlas = GpuGlyphAtlas(width: 32, height: 32, plotSize: 32);
      var flushes = 0;
      final sink = _sink(
        glyphAtlas: atlas,
        fonts: _FixedFont(font),
        // The backend's half of the protocol is upload-then-submit; the sink
        // marks both atlases uploaded and recycles the full one afterwards, so
        // a handler that only counts is a complete one here.
        onAtlasFlush: () => flushes++,
      );
      _drawRun(sink,
          ids: <int>[letterX, letterY], offsets: <double>[0, 0, 16, 0]);

      expect(flushes, 1);
      expect(sink.batcher.quadCount, 2, reason: 'no glyph was dropped');
      // Two batches, because the first one was submitted before the texels it
      // samples were overwritten.
      expect(sink.batcher.batchCount, 2);
      expect(sink.batcher.batchAt(0).quadCount, 1);
      expect(sink.batcher.batchAt(1).quadCount, 1);
    });

    test('a run longer than the whole atlas keeps every glyph', () {
      // Four plots, one 16 px ahem glyph each, and a run of twelve distinct
      // letters: the atlas turns over twice in the middle of one run. A
      // dropped glyph here is a hole in a word, which reads as a font bug.
      final atlas = GpuGlyphAtlas(width: 64, height: 64, plotSize: 32);
      var flushes = 0;
      final sink = _sink(
        glyphAtlas: atlas,
        fonts: _FixedFont(font),
        onAtlasFlush: () => flushes++,
      );

      final ids = <int>[
        for (var i = 0; i < 12; i++) ahem.glyphForCodePoint(0x41 + i),
      ];
      _drawRun(
        sink,
        ids: ids,
        offsets: <double>[
          for (var i = 0; i < 12; i++) ...<double>[i * 16.0, 0],
        ],
      );

      expect(sink.batcher.quadCount, 12, reason: 'no glyph was dropped');
      expect(flushes, greaterThan(1));
      // One batch per flush cycle plus the first: every quad in a batch
      // samples texels that were still resident when it was issued.
      expect(sink.batcher.batchCount, flushes + 1);
      var total = 0;
      for (var i = 0; i < sink.batcher.batchCount; i++) {
        total += sink.batcher.batchAt(i).quadCount;
      }
      expect(total, 12);
    });

    test('a glyph enlarged past 256 px falls back to a tiled outline', () {
      // This reproduces the vector editor crash: a 16 px face enlarged to
      // 352 px no longer fits a production-sized 256 px glyph plot. The mask
      // atlas is also only 256 px, deliberately forcing the outline route to
      // tile the visible shape instead of merely moving the same limit.
      final atlas = GpuGlyphAtlas(width: 512, height: 512, plotSize: 256);
      final masks = GpuMaskAtlas(width: 256, height: 256)..beginFrame();
      var flushes = 0;
      final sink = _sink(
        glyphAtlas: atlas,
        maskAtlas: masks,
        maskTextureId: 17,
        fonts: _FixedFont(font),
        onAtlasFlush: () => flushes++,
      );
      _drawRun(
        sink,
        ids: <int>[letterX],
        offsets: <double>[0, 0],
        origin: const Offset(100, 400),
        transform: const Transform2D.scaling(22, 22),
      );

      expect(atlas.lastFailure, GlyphAtlasFailure.glyphTooLarge);
      expect(sink.batcher.quadCount, greaterThan(1),
          reason: 'the glyph was tiled rather than dropped');
      expect(sink.batcher.batchAt(0).textureId, 17,
          reason: 'large coverage belongs to the mask/path atlas');
      expect(flushes, greaterThan(0),
          reason: 'tiles reuse the mask atlas only after submitting the '
              'previous tile');
    });

    test('text and paths do not batch together', () {
      // Different textures, so merging them would sample whichever happened
      // to be bound - the reason the two atlases carry separate ids.
      final sink = _sink(
        glyphAtlas: GpuGlyphAtlas(),
        fonts: _FixedFont(font),
      );
      sink.fillDeviceRect(const Rect.fromLTRB(0, 0, 4, 4), _wideClip, _opaque);
      _drawRun(sink, ids: <int>[letterX], offsets: <double>[0, 0]);

      expect(sink.batcher.batchCount, 2);
      expect(sink.batcher.batchAt(1).textureId, _glyphTextureId);
    });
  });
}

/// The id the test backend "bound" its glyph atlas to. Any non-zero value; it
/// only has to differ from [kNoTexture] and from the mask atlas's.
const int _glyphTextureId = 11;

GpuRasterSink _sink({
  GpuImageResolver? resolver,
  GpuGlyphAtlas? glyphAtlas,
  GpuMaskAtlas? maskAtlas,
  int maskTextureId = kNoTexture,
  GpuFontResolver? fonts,
  void Function()? onAtlasFlush,
}) =>
    GpuRasterSink(
      batcher: GpuBatcher()..beginFrame(),
      backendName: 'test',
      imageResolver: resolver,
      glyphAtlas: glyphAtlas,
      glyphTextureId: glyphAtlas == null ? kNoTexture : _glyphTextureId,
      maskAtlas: maskAtlas,
      maskTextureId: maskTextureId,
      fontResolver: fonts,
      onAtlasFlush: onAtlasFlush,
    );

/// Feeds a run through the sink the way the player does.
///
/// The typed arrays are deliberately longer than the run: the sink's contract
/// is that they are borrowed scratch buffers and that only the first
/// [ids].length entries mean anything.
void _drawRun(
  GpuRasterSink sink, {
  required List<int> ids,
  required List<double> offsets,
  Offset origin = const Offset(10, 30),
  Rect clip = _wideClip,
  ReplayPaint paint = _opaque,
  Transform2D? transform,
}) {
  final glyphIds = Int32List(ids.length + 4)..setRange(0, ids.length, ids);
  final deviceOffsets = Float32List((ids.length + 4) * 2)
    ..setRange(0, offsets.length, offsets);
  sink.drawDeviceGlyphRun(
    0,
    origin,
    transform ?? Transform2D.identity,
    glyphIds,
    deviceOffsets,
    ids.length,
    clip,
    paint,
  );
}

/// Every font id resolves to the same face, which is all a sink test needs
/// from the display list's resource table.
final class _FixedFont implements GpuFontResolver {
  _FixedFont(this._font);

  final ScaledTypeface _font;

  @override
  ScaledTypeface? resolveFont(int fontId) => _font;
}

ReplayPaint _paint({
  int argb = 0xFF204080,
  int style = paintStyleFill,
  bool antiAlias = true,
  double strokeWidth = 0,
  int fillRule = pathFillRuleNonZero,
}) =>
    ReplayPaint(
      argbColor: argb,
      style: style,
      strokeWidth: strokeWidth,
      blendMode: blendModeSrcOver,
      antiAlias: antiAlias,
      fillRule: fillRule,
    );

/// Float32 rounds a decimal literal, so an exact match would only ever be
/// asserting what the IEEE representation happens to be.
Matcher _near(List<double> values) =>
    equals(<Matcher>[for (final v in values) closeTo(v, 1e-5)]);

/// The quad's left, top, right, bottom, read off its four corners.
List<double> _quad(GpuRasterSink sink) => _quadAt(sink, 0);

/// The [index]th quad of the frame. A quad is four vertices, written
/// top-left, top-right, bottom-right, bottom-left.
List<double> _quadAt(GpuRasterSink sink, int index) {
  final buffer = sink.batcher.buffer;
  final int first = index * kGpuVerticesPerQuad;
  return <double>[
    buffer.vertexFloat(first, kGpuPositionOffset),
    buffer.vertexFloat(first, kGpuPositionOffset + 1),
    buffer.vertexFloat(first + 2, kGpuPositionOffset),
    buffer.vertexFloat(first + 2, kGpuPositionOffset + 1),
  ];
}

List<double> _shape(GpuRasterSink sink) {
  final buffer = sink.batcher.buffer;
  return <double>[
    buffer.vertexFloat(0, kGpuShapeRectOffset),
    buffer.vertexFloat(0, kGpuShapeRectOffset + 1),
    buffer.vertexFloat(0, kGpuShapeRectOffset + 2),
    buffer.vertexFloat(0, kGpuShapeRectOffset + 3),
  ];
}

/// The display list interns an image as an opaque Object; the sink only asks
/// the resolver about it, so a sentinel is enough here.
final Object _image = Uint8List(0);

final class _FixedResolver implements GpuImageResolver {
  _FixedResolver(this._texture);

  final GpuTextureHandle _texture;

  @override
  GpuTextureHandle? resolve(Object image) => _texture;
}

final class _FakeTexture implements GpuTextureHandle {
  _FakeTexture(this.id, this.width, this.height);

  @override
  final int id;

  @override
  final int width;

  @override
  final int height;

  @override
  GpuTextureFormat get format => GpuTextureFormat.rgba8888Premultiplied;

  @override
  GpuTextureFilter get filter => GpuTextureFilter.linear;

  bool valid = true;

  @override
  bool get isValid => valid;
}
