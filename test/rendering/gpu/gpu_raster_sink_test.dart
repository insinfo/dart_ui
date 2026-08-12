/// What the player's device-space primitives turn into.
///
/// The sink is where the two rectangles - the pixels the rasteriser visits
/// and the exact shape it computes coverage against - are decided, and
/// getting that pair wrong is invisible until an edge is off by one pixel of
/// grey. It needs no device: everything below it is a typed array.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_raster_sink.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
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

    test('a stroke is refused rather than filled, and says whose gap it is',
        () {
      // The CPU sink strokes now; this one does not. A message that only said
      // "stroking is not implemented" would send a reader looking for a
      // stroker that exists, so it has to name the side that is missing.
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
}

GpuRasterSink _sink({GpuImageResolver? resolver}) => GpuRasterSink(
      batcher: GpuBatcher()..beginFrame(),
      backendName: 'test',
      imageResolver: resolver,
    );

ReplayPaint _paint({
  int argb = 0xFF204080,
  int style = paintStyleFill,
  bool antiAlias = true,
}) =>
    ReplayPaint(
      argbColor: argb,
      style: style,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: antiAlias,
    );

/// Float32 rounds a decimal literal, so an exact match would only ever be
/// asserting what the IEEE representation happens to be.
Matcher _near(List<double> values) =>
    equals(<Matcher>[for (final v in values) closeTo(v, 1e-5)]);

/// The quad's left, top, right, bottom, read off its four corners.
List<double> _quad(GpuRasterSink sink) {
  final buffer = sink.batcher.buffer;
  return <double>[
    buffer.vertexFloat(0, kGpuPositionOffset),
    buffer.vertexFloat(0, kGpuPositionOffset + 1),
    buffer.vertexFloat(2, kGpuPositionOffset),
    buffer.vertexFloat(2, kGpuPositionOffset + 1),
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
