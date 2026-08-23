import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_layer_stack.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_vector_command_stream.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_vector_submission_cursor.dart';
import 'package:test/test.dart';

void main() {
  test('incremental snapshots submit every dense/vector operation once', () {
    final layers = GpuLayerStack(allocator: _Allocator())
      ..beginFrame(surfaceWidth: 100, surfaceHeight: 80);
    final stream = GpuVectorCommandStream<String, String>(layers)
      ..resetForFrame()
      ..recordVector(
        batchIndex: 1,
        clip: const Rect.fromLTRB(0, 0, 100, 80),
        material: 'm0',
        payload: 'p0',
      )
      ..snapshot(totalBatchCount: 2);
    final cursor = GpuVectorSubmissionCursor();

    _consume(stream, cursor);
    expect(cursor.nextDenseBatch, 2);
    expect(cursor.nextVectorOrdinal, 1);

    stream
      ..recordVector(
        batchIndex: 2,
        clip: const Rect.fromLTRB(2, 2, 20, 20),
        material: 'm1',
        payload: 'p1',
      )
      ..finish(totalBatchCount: 4);
    final consumed = _consume(stream, cursor);

    expect(consumed, <String>['vector:1', 'dense:2-4']);
    expect(cursor.nextDenseBatch, 4);
    expect(cursor.nextVectorOrdinal, 2);
  });

  test('an offscreen clear is issued once across repeated snapshots', () {
    final layers = GpuLayerStack(allocator: _Allocator())
      ..beginFrame(surfaceWidth: 100, surfaceHeight: 80);
    final stream = GpuVectorCommandStream<String, String>(layers)
      ..resetForFrame();
    layers.push(
      deviceBounds: const Rect.fromLTRB(10, 10, 30, 30),
      clip: const Rect.fromLTRB(0, 0, 100, 80),
      alpha: 128,
      blendMode: blendModeSrcOver,
      batchIndex: 0,
    );
    stream
      ..recordVector(
        batchIndex: 0,
        clip: const Rect.fromLTRB(10, 10, 30, 30),
        material: 'm',
        payload: 'p',
      )
      ..snapshot(totalBatchCount: 0);
    final cursor = GpuVectorSubmissionCursor();
    final pass =
        stream.passAt(0).clearsTarget ? stream.passAt(0) : stream.passAt(1);

    expect(cursor.isClearPending(pass), isTrue);
    cursor.markPassCleared(pass);
    expect(cursor.isClearPending(pass), isFalse);
    stream.snapshot(totalBatchCount: 0);
    final rebuilt =
        stream.passAt(0).clearsTarget ? stream.passAt(0) : stream.passAt(1);
    expect(cursor.isClearPending(rebuilt), isFalse);
  });

  test('walker retains callback order and resumes after a snapshot', () {
    final layers = GpuLayerStack(allocator: _Allocator())
      ..beginFrame(surfaceWidth: 100, surfaceHeight: 80);
    final stream = GpuVectorCommandStream<String, String>(layers)
      ..resetForFrame()
      ..recordVector(
        batchIndex: 1,
        clip: const Rect.fromLTRB(0, 0, 100, 80),
        material: 'm0',
        payload: 'p0',
      )
      ..snapshot(totalBatchCount: 2);
    final cursor = GpuVectorSubmissionCursor();
    final log = <String>[];

    void walk() => const GpuOrderedSubmissionWalker().submit(
          stream: stream,
          cursor: cursor,
          beginPass: (pass, clear) => log.add('begin:${pass.sourcePassIndex}'),
          submitDense: (_, range) =>
              log.add('dense:${range.firstBatch}-${range.endBatch}'),
          submitVector: (_, vector) =>
              log.add('vector:${vector.vectorOrdinal}'),
          endPass: (pass) => log.add('end:${pass.sourcePassIndex}'),
        );

    walk();
    stream
      ..recordVector(
        batchIndex: 2,
        clip: const Rect.fromLTRB(0, 0, 10, 10),
        material: 'm1',
        payload: 'p1',
      )
      ..finish(totalBatchCount: 3);
    walk();

    expect(log, <String>[
      'begin:0',
      'dense:0-1',
      'vector:0',
      'dense:1-2',
      'end:0',
      'begin:0',
      'vector:1',
      'dense:2-3',
      'end:0',
    ]);
  });
}

List<String> _consume(
  GpuVectorCommandStream<String, String> stream,
  GpuVectorSubmissionCursor cursor,
) {
  final result = <String>[];
  for (final pass in stream.passes) {
    for (final command in pass.commands) {
      switch (command.kind) {
        case GpuOrderedCommandKind.denseBatchRange:
          final range = cursor.pendingDense(command);
          if (range == null) continue;
          result.add('dense:${range.firstBatch}-${range.endBatch}');
          cursor.markDenseSubmitted(range);
        case GpuOrderedCommandKind.experimentalVector:
          final vector = command.vector!;
          if (!cursor.isVectorPending(vector)) continue;
          result.add('vector:${vector.vectorOrdinal}');
          cursor.markVectorSubmitted(vector);
      }
    }
  }
  return result;
}

final class _Allocator implements GpuLayerTargetAllocator {
  var _next = 1;

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) =>
      _Target(_next++, width, height);

  @override
  void releaseLayerTarget(GpuLayerTarget target) {}
}

final class _Target implements GpuLayerTarget {
  const _Target(this.id, this.width, this.height);

  @override
  final int id;
  @override
  int get textureId => id + 100;
  @override
  final int width;
  @override
  final int height;
}
