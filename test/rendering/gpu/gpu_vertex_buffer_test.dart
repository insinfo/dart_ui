/// The vertex arena's two contracts: the layout it writes, and the promise
/// that a steady-state frame allocates nothing.
///
/// `gpu_vertex_buffer.dart` says of [GpuVertexBuffer.bufferGrowths] that "a
/// test asserts it stops increasing". Without that test the arena is just a
/// growable list with an extra counter, and the day a `reset` starts
/// reallocating nobody finds out until a profile shows a megabyte per second
/// of short-lived typed data.
library;

import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_vertex_buffer.dart';
import 'package:test/test.dart';

void main() {
  group('GpuVertexBuffer growth', () {
    test('growths stop once the busiest frame has been drawn', () {
      final buffer = GpuVertexBuffer(initialQuads: 4);

      // Frame one overruns the initial capacity and must grow.
      for (var i = 0; i < 100; i++) {
        _quad(buffer, i.toDouble());
      }
      final afterFirstFrame = buffer.bufferGrowths;
      expect(afterFirstFrame, greaterThan(0),
          reason: '100 quads cannot fit in a 4-quad arena without growing');

      // Every later frame of the same size, and one smaller, must be free.
      for (var frame = 0; frame < 20; frame++) {
        buffer.reset();
        for (var i = 0; i < 100; i++) {
          _quad(buffer, i.toDouble());
        }
        expect(buffer.bufferGrowths, afterFirstFrame,
            reason: 'frame $frame reallocated a buffer it already had');
      }

      buffer.reset();
      for (var i = 0; i < 10; i++) {
        _quad(buffer, i.toDouble());
      }
      expect(buffer.bufferGrowths, afterFirstFrame);
    });

    test('a busier frame grows again, and the new size then holds', () {
      final buffer = GpuVertexBuffer(initialQuads: 1);
      for (var i = 0; i < 10; i++) {
        _quad(buffer, i.toDouble());
      }
      final small = buffer.bufferGrowths;

      buffer.reset();
      for (var i = 0; i < 500; i++) {
        _quad(buffer, i.toDouble());
      }
      expect(buffer.bufferGrowths, greaterThan(small));
      final large = buffer.bufferGrowths;

      buffer.reset();
      for (var i = 0; i < 500; i++) {
        _quad(buffer, i.toDouble());
      }
      expect(buffer.bufferGrowths, large);
    });

    test('reset keeps the memory it grew into', () {
      final buffer = GpuVertexBuffer(initialQuads: 1);
      for (var i = 0; i < 64; i++) {
        _quad(buffer, i.toDouble());
      }
      final capacity = buffer.vertexStorage.length;

      buffer.reset();
      expect(buffer.vertexCount, 0);
      expect(buffer.indexCount, 0);
      expect(buffer.vertexStorage.length, capacity);
    });

    test('growth preserves the quads already written', () {
      // The failure this catches is a grown buffer that copies the wrong
      // range: the frame then draws one correct quad and a screenful of
      // zeroes, which looks like a culling bug rather than an arena bug.
      final buffer = GpuVertexBuffer(initialQuads: 1);
      for (var i = 0; i < 32; i++) {
        _quad(buffer, i.toDouble());
      }

      for (var i = 0; i < 32; i++) {
        final firstVertex = i * kGpuVerticesPerQuad;
        expect(buffer.vertexFloat(firstVertex, kGpuPositionOffset),
            i.toDouble());
      }
      expect(buffer.indexAt(31 * kGpuIndicesPerQuad), 31 * kGpuVerticesPerQuad);
    });
  });

  group('GpuVertexBuffer layout', () {
    test('a quad writes four corners clockwise in device space', () {
      final buffer = GpuVertexBuffer();
      buffer.addQuad(
        left: 2,
        top: 3,
        right: 12,
        bottom: 23,
        u0: 0.25,
        v0: 0.5,
        u1: 0.75,
        v1: 1,
        red: 0.1,
        green: 0.2,
        blue: 0.3,
        alpha: 0.4,
        shapeLeft: 2.5,
        shapeTop: 3.5,
        shapeRight: 11.5,
        shapeBottom: 22.5,
      );

      expect(buffer.vertexCount, kGpuVerticesPerQuad);
      const positions = <List<double>>[
        <double>[2, 3],
        <double>[12, 3],
        <double>[12, 23],
        <double>[2, 23],
      ];
      for (var i = 0; i < positions.length; i++) {
        expect(buffer.vertexFloat(i, kGpuPositionOffset), positions[i][0]);
        expect(buffer.vertexFloat(i, kGpuPositionOffset + 1), positions[i][1]);
      }

      // u follows x and v follows y, so a texture is not mirrored.
      expect(buffer.vertexFloat(0, kGpuTexCoordOffset), closeTo(0.25, 1e-6));
      expect(buffer.vertexFloat(1, kGpuTexCoordOffset), closeTo(0.75, 1e-6));
      expect(buffer.vertexFloat(2, kGpuTexCoordOffset + 1), closeTo(1, 1e-6));

      // Colour and shape rect are constant across the quad: the shader needs
      // the same rect at every corner to compute coverage per pixel.
      for (var i = 0; i < kGpuVerticesPerQuad; i++) {
        expect(buffer.vertexFloat(i, kGpuColorOffset), closeTo(0.1, 1e-6));
        expect(buffer.vertexFloat(i, kGpuColorOffset + 3), closeTo(0.4, 1e-6));
        expect(buffer.vertexFloat(i, kGpuShapeRectOffset), closeTo(2.5, 1e-6));
        expect(buffer.vertexFloat(i, kGpuShapeRectOffset + 3),
            closeTo(22.5, 1e-6));
      }
    });

    test('indices wind 0,1,2 0,2,3 relative to the quad', () {
      final buffer = GpuVertexBuffer();
      _quad(buffer, 0);
      _quad(buffer, 10);

      expect(
        <int>[for (var i = 0; i < 12; i++) buffer.indexAt(i)],
        <int>[0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
      );
    });

    test('addQuad returns the first vertex of the quad it wrote', () {
      final buffer = GpuVertexBuffer();
      expect(_quad(buffer, 0), 0);
      expect(_quad(buffer, 1), kGpuVerticesPerQuad);
      expect(_quad(buffer, 2), 2 * kGpuVerticesPerQuad);
    });

    test('the frame views are exactly the floats written', () {
      final buffer = GpuVertexBuffer(initialQuads: 64);
      _quad(buffer, 0);
      _quad(buffer, 1);

      expect(buffer.vertices.length,
          2 * kGpuVerticesPerQuad * kGpuFloatsPerVertex);
      expect(buffer.indices.length, 2 * kGpuIndicesPerQuad);
      // The storage is deliberately larger; uploading it whole would send the
      // driver last frame's leftovers.
      expect(buffer.vertexStorage.length, greaterThan(buffer.vertices.length));
    });

    test('a zero-quad frame produces empty views rather than nulls', () {
      final buffer = GpuVertexBuffer();
      expect(buffer.vertices, isEmpty);
      expect(buffer.indices, isEmpty);
    });
  });
}

int _quad(GpuVertexBuffer buffer, double left) => buffer.addQuad(
      left: left,
      top: 0,
      right: left + 1,
      bottom: 1,
      u0: 0,
      v0: 0,
      u1: 1,
      v1: 1,
      red: 1,
      green: 1,
      blue: 1,
      alpha: 1,
      shapeLeft: left,
      shapeTop: 0,
      shapeRight: left + 1,
      shapeBottom: 1,
    );
