/// Backend-neutral ordered representation of experimental vector work.
///
/// The stream deliberately does not dispatch. It interleaves retained vector
/// commands with dense batch ranges only after the layer stack has finished
/// describing its render passes. A backend can therefore inspect or reject a
/// whole command before any native side effect, while the established dense
/// renderer remains unchanged.
library;

import '../../geometry/rect.dart';
import 'gpu_layer_stack.dart';

enum GpuOrderedCommandKind { denseBatchRange, experimentalVector }

/// One vector command retained exactly as it appeared in display-list order.
///
/// [M] and [P] are intentionally generic: material and payload contracts can
/// evolve independently of GL/Vulkan/D3D without this ordering layer using an
/// untyped `Object` or importing a backend adapter. Their object identity is
/// retained until [GpuVectorCommandStream.resetForFrame].
final class GpuExperimentalVectorCommand<M, P> {
  const GpuExperimentalVectorCommand._({
    required this.vectorOrdinal,
    required this.batchIndex,
    required this.sourcePassIndex,
    required this.target,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.rendersTopDown,
    required this.attachments,
    required this.layerOriginX,
    required this.layerOriginY,
    required this.deviceClip,
    required this.targetClip,
    required this.effectiveTargetClip,
    required this.material,
    required this.payload,
  });

  /// Order among vector commands recorded at the same dense batch boundary.
  final int vectorOrdinal;

  /// Number of dense batches that precede this command in the display list.
  final int batchIndex;

  final int sourcePassIndex;
  final GpuLayerTarget? target;
  final int viewportWidth;
  final int viewportHeight;
  final bool rendersTopDown;

  /// What the framebuffer this command will be executed against carries
  /// besides colour, captured when the command was recorded.
  ///
  /// An executor validates against it instead of re-querying the driver: the
  /// recorder already refused anything the pass could not satisfy, and a
  /// second answer arriving between recording and submission would mean the
  /// command was ordered into a pass that no longer exists.
  final GpuPassAttachments attachments;

  /// Whole-pixel device origin subtracted when drawing into [target].
  final double layerOriginX;
  final double layerOriginY;

  /// Original replay clip and its exact target-local translation.
  final Rect deviceClip;
  final Rect targetClip;

  /// Target-local clip additionally clamped to the pass viewport.
  final Rect effectiveTargetClip;

  final M material;
  final P payload;
}

/// One operation in a [GpuVectorPassRecord].
final class GpuOrderedRenderCommand<M, P> {
  const GpuOrderedRenderCommand._dense({
    required this.ordinal,
    required this.firstBatch,
    required this.endBatch,
  })  : kind = GpuOrderedCommandKind.denseBatchRange,
        vector = null;

  GpuOrderedRenderCommand._vector({
    required this.ordinal,
    required GpuExperimentalVectorCommand<M, P> command,
  })  : kind = GpuOrderedCommandKind.experimentalVector,
        firstBatch = command.batchIndex,
        endBatch = command.batchIndex,
        vector = command;

  /// Monotonic across every pass and operation in the frame.
  final int ordinal;
  final GpuOrderedCommandKind kind;

  /// Half-open dense range. Equal for a vector command.
  final int firstBatch;
  final int endBatch;

  final GpuExperimentalVectorCommand<M, P>? vector;
}

/// One immutable snapshot of [GpuRenderPass] plus its ordered operations.
final class GpuVectorPassRecord<M, P> {
  GpuVectorPassRecord._({
    required this.sourcePassIndex,
    required this.target,
    required this.firstBatch,
    required this.endBatch,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.clearsTarget,
    required this.rendersTopDown,
    required this.attachments,
    required List<GpuOrderedRenderCommand<M, P>> commands,
  }) : commands = List<GpuOrderedRenderCommand<M, P>>.unmodifiable(commands);

  final int sourcePassIndex;
  final GpuLayerTarget? target;
  final int firstBatch;
  final int endBatch;
  final int viewportWidth;
  final int viewportHeight;
  final bool clearsTarget;
  final bool rendersTopDown;

  /// The pass's attachments, copied from [GpuRenderPass.attachments].
  final GpuPassAttachments attachments;
  final List<GpuOrderedRenderCommand<M, P>> commands;
}

/// Builds a side-effect-free mixed dense/vector pass stream.
final class GpuVectorCommandStream<M, P> {
  GpuVectorCommandStream(this.layers);

  final GpuLayerStack layers;
  final List<GpuExperimentalVectorCommand<M, P>> _vectors =
      <GpuExperimentalVectorCommand<M, P>>[];
  final List<GpuVectorPassRecord<M, P>> _passes = <GpuVectorPassRecord<M, P>>[];
  bool _recording = false;
  bool _finished = false;
  int _lastBatchIndex = 0;

  bool get isRecording => _recording && !_finished;
  int get vectorCommandCount => _vectors.length;
  int get passCount => _passes.length;

  GpuVectorPassRecord<M, P> passAt(int index) {
    if (index < 0 || index >= _passes.length) {
      throw RangeError.index(index, _passes, 'index');
    }
    return _passes[index];
  }

  Iterable<GpuVectorPassRecord<M, P>> get passes =>
      List<GpuVectorPassRecord<M, P>>.unmodifiable(_passes);

  /// Starts alongside an already-open [GpuLayerStack] frame.
  void resetForFrame() {
    // Accessing currentPass gives a named failure if beginFrame was omitted.
    layers.currentPass;
    _vectors.clear();
    _passes.clear();
    _lastBatchIndex = 0;
    _recording = true;
    _finished = false;
  }

  /// Records one vector command at a dense batch boundary.
  ///
  /// The caller closes the batcher before calling, so [batchIndex] is exactly
  /// the first dense batch that must execute after this command.
  void recordVector({
    required int batchIndex,
    required Rect clip,
    required M material,
    required P payload,
  }) {
    _requireRecording();
    if (batchIndex < _lastBatchIndex) {
      throw StateError('vector command batch indices must be monotonic; got '
          '$batchIndex after $_lastBatchIndex');
    }
    if (!_finiteRect(clip)) {
      throw ArgumentError.value(clip, 'clip', 'must contain finite bounds');
    }
    final GpuRenderPass pass = layers.currentPass;
    final double originX = layers.originX;
    final double originY = layers.originY;
    final Rect targetClip = Rect.fromLTRB(
      clip.left - originX,
      clip.top - originY,
      clip.right - originX,
      clip.bottom - originY,
    );
    final Rect viewport = Rect.fromLTRB(
      0,
      0,
      pass.viewportWidth.toDouble(),
      pass.viewportHeight.toDouble(),
    );
    _vectors.add(GpuExperimentalVectorCommand<M, P>._(
      vectorOrdinal: _vectors.length,
      batchIndex: batchIndex,
      sourcePassIndex: layers.currentPassIndex,
      target: pass.target,
      viewportWidth: pass.viewportWidth,
      viewportHeight: pass.viewportHeight,
      rendersTopDown: pass.rendersTopDown,
      attachments: pass.attachments,
      layerOriginX: originX,
      layerOriginY: originY,
      deviceClip: clip,
      targetClip: targetClip,
      effectiveTargetClip: targetClip.intersect(viewport),
      material: material,
      payload: payload,
    ));
    layers.markCurrentPassHasVectorWork();
    _lastBatchIndex = batchIndex;
  }

  /// Rebuilds an immutable view without closing the recording side.
  ///
  /// A mask/glyph atlas may have to submit the prefix of a frame before replay
  /// has finished. That prefix still has to include vector commands in order.
  /// [snapshot] makes the current pass records consumable and then permits
  /// later commands at the same or a greater dense boundary. A submission
  /// cursor must skip operations it already issued when it consumes another
  /// snapshot.
  void snapshot({required int totalBatchCount}) {
    _requireRecording();
    _rebuildPasses(totalBatchCount);
  }

  /// Freezes pass boundaries and inserts dense ranges around vector commands.
  void finish({required int totalBatchCount}) {
    _requireRecording();
    _rebuildPasses(totalBatchCount);
    _finished = true;
  }

  void _rebuildPasses(int totalBatchCount) {
    if (totalBatchCount < _lastBatchIndex) {
      throw StateError('total batch count $totalBatchCount precedes the last '
          'vector boundary $_lastBatchIndex');
    }
    _passes.clear();
    var operationOrdinal = 0;
    var vectorCursor = 0;
    for (var passIndex = 0; passIndex < layers.passCount; passIndex++) {
      final GpuRenderPass pass = layers.passAt(passIndex);
      final int passEnd = layers.passEnd(passIndex, totalBatchCount);
      final List<GpuOrderedRenderCommand<M, P>> operations =
          <GpuOrderedRenderCommand<M, P>>[];
      var denseCursor = pass.firstBatch;
      while (vectorCursor < _vectors.length &&
          _vectors[vectorCursor].sourcePassIndex == passIndex) {
        final GpuExperimentalVectorCommand<M, P> vector =
            _vectors[vectorCursor++];
        _validateVectorStillMatchesPass(vector, pass, passIndex, passEnd);
        if (vector.batchIndex > denseCursor) {
          operations.add(GpuOrderedRenderCommand<M, P>._dense(
            ordinal: operationOrdinal++,
            firstBatch: denseCursor,
            endBatch: vector.batchIndex,
          ));
        }
        operations.add(GpuOrderedRenderCommand<M, P>._vector(
          ordinal: operationOrdinal++,
          command: vector,
        ));
        denseCursor = vector.batchIndex;
      }
      if (passEnd > denseCursor) {
        operations.add(GpuOrderedRenderCommand<M, P>._dense(
          ordinal: operationOrdinal++,
          firstBatch: denseCursor,
          endBatch: passEnd,
        ));
      }
      // Keep empty clear passes: clearing is itself ordered work, and the
      // dense backend already observes such a pass during nested layers.
      if (operations.isNotEmpty || pass.clearsTarget) {
        _passes.add(GpuVectorPassRecord<M, P>._(
          sourcePassIndex: passIndex,
          target: pass.target,
          firstBatch: pass.firstBatch,
          endBatch: passEnd,
          viewportWidth: pass.viewportWidth,
          viewportHeight: pass.viewportHeight,
          clearsTarget: pass.clearsTarget,
          rendersTopDown: pass.rendersTopDown,
          attachments: pass.attachments,
          commands: operations,
        ));
      }
    }
    if (vectorCursor != _vectors.length) {
      throw StateError('a vector command refers to a render pass that was '
          'discarded or reordered by the layer stack');
    }
  }

  void _validateVectorStillMatchesPass(
    GpuExperimentalVectorCommand<M, P> vector,
    GpuRenderPass pass,
    int passIndex,
    int passEnd,
  ) {
    if (!identical(vector.target, pass.target) ||
        vector.viewportWidth != pass.viewportWidth ||
        vector.viewportHeight != pass.viewportHeight ||
        vector.rendersTopDown != pass.rendersTopDown ||
        // A pass whose attachments changed under a recorded command is a pass
        // the command was not validated against: an antialiased stencil draw
        // accepted for a 4x target would be executed single-sample.
        vector.attachments != pass.attachments) {
      throw StateError('vector command ${vector.vectorOrdinal} no longer '
          'matches render pass $passIndex');
    }
    if (vector.batchIndex < pass.firstBatch || vector.batchIndex > passEnd) {
      throw StateError('vector command ${vector.vectorOrdinal} at batch '
          '${vector.batchIndex} falls outside pass $passIndex range '
          '[${pass.firstBatch}, $passEnd]');
    }
  }

  void _requireRecording() {
    if (!_recording) {
      throw StateError('resetForFrame() before recording vector commands');
    }
    if (_finished) throw StateError('the vector command stream is frozen');
  }

  static bool _finiteRect(Rect rect) =>
      rect.left.isFinite &&
      rect.top.isFinite &&
      rect.right.isFinite &&
      rect.bottom.isFinite;
}
