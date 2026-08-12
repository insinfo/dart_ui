/// The batching rule, asserted rather than described.
///
/// `gpu_batcher.dart` states the rule in prose - a batch breaks on pipeline,
/// texture, blend mode or scissor, and on nothing else - and its `quadCount`
/// getter says outright that it is "the number a batching test asserts". This
/// is that test. It needs no device: the batcher writes into a typed array and
/// keeps a list of state records, which is exactly why the split between
/// `gpu_batcher.dart` and `gl/gl_backend.dart` exists.
library;

import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:test/test.dart';

void main() {
  group('GpuBatcher merging', () {
    test('a thousand quads in one state are one draw call', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher);
      for (var i = 0; i < 1000; i++) {
        _quad(batcher, left: i.toDouble(), red: i / 1000.0);
      }

      // The claim from the library comment: colour and position are vertex
      // data and never break a batch.
      expect(batcher.batchCount, 1);
      expect(batcher.quadCount, 1000);
      expect(batcher.batchAt(0).quadCount, 1000);
      expect(batcher.batchAt(0).indexCount, 1000 * kGpuIndicesPerQuad);
    });

    test('the pipeline kind breaks a batch', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher);
      _quad(batcher);
      _state(batcher, pipeline: GpuPipelineKind.coverageMask, texture: 7);
      _quad(batcher);

      expect(batcher.batchCount, 2);
      expect(batcher.batchAt(0).pipeline, GpuPipelineKind.solid);
      expect(batcher.batchAt(1).pipeline, GpuPipelineKind.coverageMask);
    });

    test('the texture id breaks a batch, and kNoTexture is a value', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher, pipeline: GpuPipelineKind.texturedImage, texture: 3);
      _quad(batcher);
      _state(batcher, pipeline: GpuPipelineKind.texturedImage, texture: 4);
      _quad(batcher);
      _state(batcher, pipeline: GpuPipelineKind.texturedImage, texture: 3);
      _quad(batcher);

      // Three, not two: a run of state A, state B, state A is never reordered
      // into two draws, because that would change what covers what.
      expect(batcher.batchCount, 3);
      expect(
        <int>[for (final batch in batcher.batches) batch.textureId],
        <int>[3, 4, 3],
      );
    });

    test('kNoTexture and a real texture are different states', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher, texture: kNoTexture);
      _quad(batcher);
      _state(batcher, texture: kNoTexture);
      _quad(batcher);
      _state(batcher, texture: 1);
      _quad(batcher);

      expect(batcher.batchCount, 2);
      expect(batcher.batchAt(0).quadCount, 2);
    });

    test('the blend mode breaks a batch', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher, blend: blendModeSrcOver);
      _quad(batcher);
      _state(batcher, blend: blendModePlus);
      _quad(batcher);

      expect(batcher.batchCount, 2);
      expect(batcher.batchAt(1).blendMode, blendModePlus);
    });

    test('the scissor rectangle breaks a batch on any of its four edges', () {
      for (final edge in <String>['left', 'top', 'right', 'bottom']) {
        final batcher = GpuBatcher()..beginFrame();
        _state(batcher);
        _quad(batcher);
        _state(
          batcher,
          scissorLeft: edge == 'left' ? 1 : 0,
          scissorTop: edge == 'top' ? 1 : 0,
          scissorRight: edge == 'right' ? 99 : 100,
          scissorBottom: edge == 'bottom' ? 99 : 100,
        );
        _quad(batcher);

        expect(batcher.batchCount, 2, reason: 'a changed $edge must break');
      }
    });

    test('an identical scissor merges', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher, scissorLeft: 5, scissorTop: 6);
      _quad(batcher);
      _state(batcher, scissorLeft: 5, scissorTop: 6);
      _quad(batcher);

      expect(batcher.batchCount, 1);
    });
  });

  group('GpuBatcher ordering', () {
    test('batches carry contiguous, increasing index ranges', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher);
      _quad(batcher);
      _quad(batcher);
      _state(batcher, texture: 2, pipeline: GpuPipelineKind.texturedImage);
      _quad(batcher);
      _state(batcher);
      _quad(batcher);

      // The backend issues glDrawElements from these offsets straight into
      // one uploaded index buffer, so a gap or an overlap here draws the
      // wrong triangles rather than failing.
      var expected = 0;
      for (final batch in batcher.batches) {
        expect(batch.indexOffset, expected);
        expected += batch.indexCount;
      }
      expect(expected, batcher.buffer.indexCount);
    });

    test('flush closes the open batch without changing the state', () {
      // The mid-frame atlas flush the mask atlas will eventually need: the
      // geometry has to be split so an upload can happen between the two
      // draws, even though nothing about the draw state changed.
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher);
      _quad(batcher);
      batcher.flush();
      _quad(batcher);

      expect(batcher.batchCount, 2);
      expect(batcher.batchAt(0).quadCount, 1);
      expect(batcher.batchAt(1).quadCount, 1);
      expect(batcher.batchAt(1).textureId, batcher.batchAt(0).textureId);
    });
  });

  group('GpuBatcher emptiness', () {
    test('a state set and never drawn with leaves no empty draw call', () {
      // The reason setState is lazy. A primitive culled between the state
      // decision and the geometry - every fully clipped rectangle - would
      // otherwise leave a zero-index draw for the backend to issue.
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher);
      _quad(batcher);
      _state(batcher, texture: 9, pipeline: GpuPipelineKind.texturedImage);
      _state(batcher, texture: 11, pipeline: GpuPipelineKind.texturedImage);

      expect(batcher.batchCount, 1);
      expect(batcher.batchAt(0).textureId, kNoTexture);
    });

    test('a frame with no quads has no batches', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher);

      expect(batcher.batchCount, 0);
      expect(batcher.batches, isEmpty);
      expect(batcher.quadCount, 0);
    });

    test('no batch is ever emitted empty', () {
      final batcher = GpuBatcher()..beginFrame();
      for (var i = 0; i < 20; i++) {
        _state(batcher, texture: i, pipeline: GpuPipelineKind.texturedImage);
        if (i.isEven) _quad(batcher);
      }

      expect(batcher.batchCount, 10);
      for (final batch in batcher.batches) {
        expect(batch.indexCount, greaterThan(0));
      }
    });
  });

  group('GpuBatcher frames', () {
    test('beginFrame drops the batches and the geometry, keeping the pool', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher);
      _quad(batcher);
      _state(batcher, texture: 2, pipeline: GpuPipelineKind.texturedImage);
      _quad(batcher);
      final firstBatch = batcher.batchAt(0);

      batcher.beginFrame();
      expect(batcher.batchCount, 0);
      expect(batcher.buffer.vertexCount, 0);
      expect(batcher.buffer.indexCount, 0);

      _state(batcher);
      _quad(batcher);
      // Pooling is the allocation contract from the library comment; the
      // identity check is the only way to observe it from outside.
      expect(identical(batcher.batchAt(0), firstBatch), isTrue);
      expect(batcher.batchAt(0).quadCount, 1);
    });

    test('batchAt refuses an index past the live batches', () {
      final batcher = GpuBatcher()..beginFrame();
      _state(batcher);
      _quad(batcher);
      _state(batcher, texture: 2, pipeline: GpuPipelineKind.texturedImage);
      _quad(batcher);
      batcher.beginFrame();
      _state(batcher);
      _quad(batcher);

      // The pool still holds two batches; only one is live, and reading the
      // stale one would report last frame's draw.
      expect(() => batcher.batchAt(1), throwsRangeError);
      expect(() => batcher.batchAt(-1), throwsRangeError);
    });
  });
}

void _state(
  GpuBatcher batcher, {
  GpuPipelineKind pipeline = GpuPipelineKind.solid,
  int texture = kNoTexture,
  int blend = blendModeSrcOver,
  int scissorLeft = 0,
  int scissorTop = 0,
  int scissorRight = 100,
  int scissorBottom = 100,
}) {
  batcher.setState(
    pipeline: pipeline,
    textureId: texture,
    blendMode: blend,
    scissorLeft: scissorLeft,
    scissorTop: scissorTop,
    scissorRight: scissorRight,
    scissorBottom: scissorBottom,
  );
}

void _quad(GpuBatcher batcher, {double left = 0, double red = 1}) {
  batcher.addQuad(
    left: left,
    top: 0,
    right: left + 10,
    bottom: 10,
    u0: 0,
    v0: 0,
    u1: 1,
    v1: 1,
    red: red,
    green: 0,
    blue: 0,
    alpha: 1,
    shapeLeft: left,
    shapeTop: 0,
    shapeRight: left + 10,
    shapeBottom: 10,
  );
}
