library;

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_layer_stack.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_vector_command_stream.dart';
import 'package:test/test.dart';

void main() {
  group('GpuVectorCommandStream ordering', () {
    test('a mid-frame snapshot remains appendable and preserves the prefix',
        () {
      final layers = GpuLayerStack(allocator: _FakeAllocator())
        ..beginFrame(surfaceWidth: 80, surfaceHeight: 60);
      final stream = GpuVectorCommandStream<String, String>(layers)
        ..resetForFrame();

      stream.recordVector(
        batchIndex: 1,
        clip: const Rect.fromLTRB(0, 0, 80, 60),
        material: 'first',
        payload: 'v0',
      );
      stream.snapshot(totalBatchCount: 1);

      expect(stream.isRecording, isTrue);
      expect(
        stream.passAt(0).commands.map((command) => command.kind),
        <GpuOrderedCommandKind>[
          GpuOrderedCommandKind.denseBatchRange,
          GpuOrderedCommandKind.experimentalVector,
        ],
      );

      stream.recordVector(
        batchIndex: 1,
        clip: const Rect.fromLTRB(1, 1, 20, 20),
        material: 'second',
        payload: 'v1',
      );
      stream.finish(totalBatchCount: 2);

      expect(stream.vectorCommandCount, 2);
      expect(
        stream.passAt(0).commands.map((command) => command.kind),
        <GpuOrderedCommandKind>[
          GpuOrderedCommandKind.denseBatchRange,
          GpuOrderedCommandKind.experimentalVector,
          GpuOrderedCommandKind.experimentalVector,
          GpuOrderedCommandKind.denseBatchRange,
        ],
      );
    });

    test('interleaves dense ranges and same-boundary vectors exactly', () {
      final stack = GpuLayerStack(allocator: _FakeAllocator())
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 80);
      final stream = GpuVectorCommandStream<_Material, _Payload>(stack)
        ..resetForFrame();
      final materialA = _Material('a');
      final materialB = _Material('b');
      final payloadA = _Payload('path-a');
      final payloadB = _Payload('path-b');

      stream
        ..recordVector(
          batchIndex: 2,
          clip: const Rect.fromLTRB(4, 5, 60, 70),
          material: materialA,
          payload: payloadA,
        )
        ..recordVector(
          batchIndex: 2,
          clip: const Rect.fromLTRB(6, 7, 50, 60),
          material: materialB,
          payload: payloadB,
        )
        ..finish(totalBatchCount: 4);

      expect(stream.passCount, 1);
      expect(stream.vectorCommandCount, 2);
      final pass = stream.passAt(0);
      expect(pass.sourcePassIndex, 0);
      expect(pass.target, isNull);
      expect(pass.firstBatch, 0);
      expect(pass.endBatch, 4);
      expect(pass.viewportWidth, 100);
      expect(pass.viewportHeight, 80);
      expect(pass.commands, hasLength(4));
      _expectDense(pass.commands[0], 0, 2, ordinal: 0);
      _expectVector(pass.commands[1], materialA, payloadA, ordinal: 1);
      _expectVector(pass.commands[2], materialB, payloadB, ordinal: 2);
      _expectDense(pass.commands[3], 2, 4, ordinal: 3);
      expect(pass.commands[1].vector!.vectorOrdinal, 0);
      expect(pass.commands[2].vector!.vectorOrdinal, 1);
      expect(pass.commands[1].vector!.deviceClip,
          const Rect.fromLTRB(4, 5, 60, 70));
      expect(pass.commands[1].vector!.targetClip,
          const Rect.fromLTRB(4, 5, 60, 70));
      expect(pass.commands[1].vector!.effectiveTargetClip,
          const Rect.fromLTRB(4, 5, 60, 70));
    });

    test('retains a vector-only offscreen pass and resumes its parent', () {
      final allocator = _FakeAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 200, surfaceHeight: 160);
      final stream = GpuVectorCommandStream<_Material, _Payload>(stack)
        ..resetForFrame();
      final layer = stack.push(
        deviceBounds: const Rect.fromLTRB(10.2, 20.2, 60.8, 70.8),
        clip: const Rect.fromLTRB(0, 0, 200, 160),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 1,
      );
      final material = _Material('layer');
      final payload = _Payload('layer-path');

      stream.recordVector(
        batchIndex: 1,
        clip: const Rect.fromLTRB(12, 23, 70, 80),
        material: material,
        payload: payload,
      );
      final popped = stack.pop(batchIndex: 1);
      expect(popped, same(layer));
      expect(popped.drewSomething, isTrue);
      stream.finish(totalBatchCount: 2);

      expect(stack.passCount, 3);
      expect(stream.passCount, 3);
      _expectDense(stream.passAt(0).commands.single, 0, 1, ordinal: 0);

      final layerPass = stream.passAt(1);
      expect(layerPass.target, same(layer.target));
      expect(layerPass.viewportWidth, 51);
      expect(layerPass.viewportHeight, 51);
      expect(layerPass.clearsTarget, isTrue);
      expect(layerPass.rendersTopDown, isTrue);
      final vector = layerPass.commands.single.vector!;
      expect(vector.layerOriginX, 10);
      expect(vector.layerOriginY, 20);
      expect(vector.targetClip, const Rect.fromLTRB(2, 3, 60, 60));
      expect(vector.effectiveTargetClip, const Rect.fromLTRB(2, 3, 51, 51));
      expect(vector.material, same(material));
      expect(vector.payload, same(payload));

      _expectDense(stream.passAt(2).commands.single, 1, 2, ordinal: 2);
      expect(stream.passAt(2).target, isNull);
    });

    test('preserves nested layer target order around both composites', () {
      final stack = GpuLayerStack(allocator: _FakeAllocator())
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      final stream = GpuVectorCommandStream<_Material, _Payload>(stack)
        ..resetForFrame();
      stream.recordVector(
        batchIndex: 0,
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        material: _Material('surface'),
        payload: _Payload('surface'),
      );
      final outer = stack.push(
        deviceBounds: const Rect.fromLTRB(10, 10, 90, 90),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );
      stream.recordVector(
        batchIndex: 0,
        clip: const Rect.fromLTRB(10, 10, 90, 90),
        material: _Material('outer'),
        payload: _Payload('outer'),
      );
      final inner = stack.push(
        deviceBounds: const Rect.fromLTRB(20, 30, 50, 60),
        clip: const Rect.fromLTRB(10, 10, 90, 90),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );
      stream.recordVector(
        batchIndex: 0,
        clip: const Rect.fromLTRB(20, 30, 50, 60),
        material: _Material('inner'),
        payload: _Payload('inner'),
      );

      stack.pop(batchIndex: 0); // Inner composite becomes dense batch 0.
      stack.pop(batchIndex: 1); // Outer composite becomes dense batch 1.
      stream.finish(totalBatchCount: 2);

      expect(stream.passCount, 5);
      expect(stream.passAt(0).commands.single.vector!.material.name, 'surface');
      expect(stream.passAt(0).target, isNull);
      expect(stream.passAt(1).commands.single.vector!.material.name, 'outer');
      expect(stream.passAt(1).target, same(outer.target));
      expect(stream.passAt(2).commands.single.vector!.material.name, 'inner');
      expect(stream.passAt(2).target, same(inner.target));
      _expectDense(stream.passAt(3).commands.single, 0, 1, ordinal: 3);
      expect(stream.passAt(3).target, same(outer.target));
      _expectDense(stream.passAt(4).commands.single, 1, 2, ordinal: 4);
      expect(stream.passAt(4).target, isNull);
    });

    test('vector in a flattened layer keeps its offscreen ancestor alive', () {
      final stack = GpuLayerStack(allocator: _FakeAllocator())
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      final stream = GpuVectorCommandStream<_Material, _Payload>(stack)
        ..resetForFrame();
      final outer = stack.push(
        deviceBounds: const Rect.fromLTRB(10, 20, 70, 80),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );
      final flattened = stack.push(
        deviceBounds: const Rect.fromLTRB(20, 30, 50, 60),
        clip: const Rect.fromLTRB(10, 20, 70, 80),
        alpha: 0xFF,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      stream.recordVector(
        batchIndex: 0,
        clip: const Rect.fromLTRB(20, 30, 50, 60),
        material: _Material('flattened-child'),
        payload: _Payload('flattened-child'),
      );
      expect(stack.pop(batchIndex: 0), same(flattened));
      expect(stack.pop(batchIndex: 0).drewSomething, isTrue);
      stream.finish(totalBatchCount: 1);

      // The empty surface prefix is omitted; the offscreen vector pass is
      // followed directly by the dense composite in the resumed surface.
      expect(stream.passCount, 2);
      final vector = stream.passAt(0).commands.single.vector!;
      expect(stream.passAt(0).target, same(outer.target));
      expect(vector.layerOriginX, 10);
      expect(vector.layerOriginY, 20);
      expect(vector.targetClip, const Rect.fromLTRB(10, 10, 40, 40));
      _expectDense(stream.passAt(1).commands.single, 0, 1, ordinal: 1);
    });

    test('does not keep a truly empty offscreen layer alive', () {
      final allocator = _FakeAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      final stream = GpuVectorCommandStream<_Material, _Payload>(stack)
        ..resetForFrame();
      stack.push(
        deviceBounds: const Rect.fromLTRB(10, 10, 50, 50),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      final layer = stack.pop(batchIndex: 0);
      stream.finish(totalBatchCount: 0);

      expect(layer.drewSomething, isFalse);
      expect(stack.passCount, 1);
      expect(stream.passCount, 0);
      expect(allocator.released, 1);
    });
  });

  group('GpuVectorCommandStream contract', () {
    test('requires beginFrame and resetForFrame in that order', () {
      final stack = GpuLayerStack(allocator: _FakeAllocator());
      final stream = GpuVectorCommandStream<_Material, _Payload>(stack);

      expect(stream.resetForFrame, throwsStateError);
      stack.beginFrame(surfaceWidth: 10, surfaceHeight: 10);
      expect(
        () => stream.recordVector(
          batchIndex: 0,
          clip: Rect.zero,
          material: _Material('m'),
          payload: _Payload('p'),
        ),
        throwsStateError,
      );
    });

    test('rejects non-monotonic boundaries, non-finite clips and late writes',
        () {
      final stack = GpuLayerStack(allocator: _FakeAllocator())
        ..beginFrame(surfaceWidth: 10, surfaceHeight: 10);
      final stream = GpuVectorCommandStream<_Material, _Payload>(stack)
        ..resetForFrame()
        ..recordVector(
          batchIndex: 2,
          clip: const Rect.fromLTRB(0, 0, 10, 10),
          material: _Material('m'),
          payload: _Payload('p'),
        );

      expect(
        () => stream.recordVector(
          batchIndex: 1,
          clip: Rect.zero,
          material: _Material('m'),
          payload: _Payload('p'),
        ),
        throwsStateError,
      );
      expect(
        () => stream.recordVector(
          batchIndex: 2,
          clip: const Rect.fromLTRB(0, 0, double.infinity, 1),
          material: _Material('m'),
          payload: _Payload('p'),
        ),
        throwsArgumentError,
      );
      expect(() => stream.finish(totalBatchCount: 1), throwsStateError);
      stream.finish(totalBatchCount: 2);
      expect(stream.isRecording, isFalse);
      expect(() => stream.finish(totalBatchCount: 2), throwsStateError);
      expect(
        () => stream.recordVector(
          batchIndex: 2,
          clip: Rect.zero,
          material: _Material('m'),
          payload: _Payload('p'),
        ),
        throwsStateError,
      );
    });

    test('publishes immutable pass command lists', () {
      final stack = GpuLayerStack(allocator: _FakeAllocator())
        ..beginFrame(surfaceWidth: 10, surfaceHeight: 10);
      final stream = GpuVectorCommandStream<_Material, _Payload>(stack)
        ..resetForFrame()
        ..recordVector(
          batchIndex: 0,
          clip: const Rect.fromLTRB(0, 0, 10, 10),
          material: _Material('m'),
          payload: _Payload('p'),
        )
        ..finish(totalBatchCount: 0);

      expect(
        () => stream.passAt(0).commands.clear(),
        throwsUnsupportedError,
      );
      expect(() => stream.passAt(1), throwsRangeError);
    });
  });
}

void _expectDense(
  GpuOrderedRenderCommand<_Material, _Payload> command,
  int first,
  int end, {
  required int ordinal,
}) {
  expect(command.kind, GpuOrderedCommandKind.denseBatchRange);
  expect(command.ordinal, ordinal);
  expect(command.firstBatch, first);
  expect(command.endBatch, end);
  expect(command.vector, isNull);
}

void _expectVector(
  GpuOrderedRenderCommand<_Material, _Payload> command,
  _Material material,
  _Payload payload, {
  required int ordinal,
}) {
  expect(command.kind, GpuOrderedCommandKind.experimentalVector);
  expect(command.ordinal, ordinal);
  expect(command.firstBatch, 2);
  expect(command.endBatch, 2);
  expect(command.vector!.material, same(material));
  expect(command.vector!.payload, same(payload));
}

final class _Material {
  _Material(this.name);

  final String name;
}

final class _Payload {
  _Payload(this.name);

  final String name;
}

final class _FakeAllocator implements GpuLayerTargetAllocator {
  int released = 0;
  int _nextId = 1;

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) => _FakeTarget(
        id: _nextId++,
        width: width,
        height: height,
      );

  @override
  void releaseLayerTarget(GpuLayerTarget target) {
    released++;
  }
}

final class _FakeTarget implements GpuLayerTarget {
  const _FakeTarget({
    required this.id,
    required this.width,
    required this.height,
  });

  @override
  final int id;

  @override
  int get textureId => id + 1000;

  @override
  final int width;

  @override
  final int height;
}
