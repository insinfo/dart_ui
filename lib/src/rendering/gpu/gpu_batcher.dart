/// The batching layer: many primitives, few draw calls.
///
/// ## The batching rule, stated once
///
/// A batch is a maximal run of quads that share **all four** pieces of draw
/// state:
///
///   1. the pipeline kind ([GpuPipelineKind]);
///   2. the bound texture id ([kNoTexture] counts as a value);
///   3. the blend mode;
///   4. the scissor rectangle, in whole device pixels.
///
/// Anything else - colour, position, transform, the paint object, the order
/// the display list wrote them in - is *vertex data* and never breaks a batch.
/// That is the whole design: the four things above are GPU state changes that
/// cannot be expressed per vertex, and everything that can be expressed per
/// vertex is.
///
/// Consequences worth knowing before reading a profile:
///
///   * A thousand rectangles of a thousand different colours under one clip
///     are one draw call. A thousand rectangles of one colour under a
///     thousand nested clips are a thousand draw calls. Clip churn, not
///     colour churn, is what costs.
///   * A `saveLayer` does not appear here at all. The player already
///     intersects a layer's bounds into the clip it passes with every
///     primitive, so a layer that is only a clip breaks batches exactly as a
///     clip does. A layer that needs a real offscreen pass is cut into its own
///     render pass by `gpu_layer_stack.dart`, which slices this batcher's
///     output by batch index rather than reordering it - so batching stays
///     oblivious to layers, and a pass boundary is just a range of batches
///     drawn into a different target. See `gpu_raster_sink.dart`.
///   * Ordering is preserved absolutely. Batches are emitted in the order
///     their first quad arrived and are never reordered to merge two runs of
///     the same state with a different state between them. Reordering is
///     legal only when the primitives do not overlap, and proving that costs
///     more than the draw call saves.
///
/// ## No allocation per primitive
///
/// The state is compared as five ints and an enum against the open batch, so
/// there is no key object per primitive and no map lookup. [GpuBatch] objects
/// are pooled across frames and rewritten in place, so even the batch list
/// stops allocating once a process has drawn its busiest frame.
library;

import 'gpu_pipeline.dart';
import 'gpu_texture.dart';
import 'gpu_vertex_buffer.dart';

/// One draw call: a state, and a range of the frame's index buffer.
///
/// Mutable and pooled. A caller must read what it needs before the next
/// [GpuBatcher.beginFrame]; holding a [GpuBatch] across frames is holding a
/// buffer slot that has been rewritten.
final class GpuBatch {
  GpuBatch._();

  GpuPipelineKind _pipeline = GpuPipelineKind.solid;
  int _textureId = kNoTexture;
  int _blendMode = 0;
  int _scissorLeft = 0;
  int _scissorTop = 0;
  int _scissorRight = 0;
  int _scissorBottom = 0;
  int _indexOffset = 0;
  int _indexCount = 0;

  GpuPipelineKind get pipeline => _pipeline;
  int get textureId => _textureId;

  /// One of the display list's `blendMode*` constants. The backend turns it
  /// into factors with [gpuBlendForMode]; keeping the constant rather than the
  /// factors means a diagnostic dump names the mode the paint asked for.
  int get blendMode => _blendMode;

  /// Half-open in device pixels, matching [Rect]: the pixel at
  /// [scissorRight] is outside.
  int get scissorLeft => _scissorLeft;
  int get scissorTop => _scissorTop;
  int get scissorRight => _scissorRight;
  int get scissorBottom => _scissorBottom;

  int get scissorWidth => _scissorRight - _scissorLeft;
  int get scissorHeight => _scissorBottom - _scissorTop;

  /// First index of this batch in [GpuBatcher.buffer]'s index array.
  int get indexOffset => _indexOffset;

  int get indexCount => _indexCount;

  /// Quads merged into this batch. The number a batching test asserts.
  int get quadCount => _indexCount ~/ kGpuIndicesPerQuad;

  @override
  String toString() => 'GpuBatch(${_pipeline.name}, tex $_textureId, '
      'blend $_blendMode, scissor $_scissorLeft,$_scissorTop..'
      '$_scissorRight,$_scissorBottom, $quadCount quads)';
}

/// Turns a stream of device-space quads into the fewest draw calls that
/// preserve the picture.
final class GpuBatcher {
  GpuBatcher({GpuVertexBuffer? buffer}) : buffer = buffer ?? GpuVertexBuffer();

  /// The frame's geometry. Shared with the backend, which uploads it once.
  final GpuVertexBuffer buffer;

  /// Pooled, reused across frames. Grows to the busiest frame and stops.
  final List<GpuBatch> _pool = <GpuBatch>[];
  int _batchCount = 0;

  // The state the next quad will be drawn with. Kept as scalars rather than a
  // key object because [setState] runs once per primitive.
  GpuPipelineKind _pendingPipeline = GpuPipelineKind.solid;
  int _pendingTexture = kNoTexture;
  int _pendingBlend = 0;
  int _pendingScissorLeft = 0;
  int _pendingScissorTop = 0;
  int _pendingScissorRight = 0;
  int _pendingScissorBottom = 0;

  /// Whether the last batch is still accepting quads.
  bool _open = false;

  int get batchCount => _batchCount;

  /// The frame's batches, in submission order. Valid until [beginFrame].
  Iterable<GpuBatch> get batches => _pool.take(_batchCount);

  GpuBatch batchAt(int index) {
    if (index < 0 || index >= _batchCount) {
      throw RangeError.index(index, _pool, 'index', null, _batchCount);
    }
    return _pool[index];
  }

  /// Total quads across all batches. A batching test compares this against
  /// [batchCount] to say "N primitives, one draw call".
  int get quadCount => buffer.indexCount ~/ kGpuIndicesPerQuad;

  /// Drops the previous frame's geometry and batches, keeping the memory.
  void beginFrame() {
    buffer.reset();
    _batchCount = 0;
    _open = false;
  }

  /// Declares the state the next [addQuad] will use.
  ///
  /// Lazy on purpose: this never opens a batch. A state set and then not drawn
  /// with - which happens whenever a primitive is fully clipped away between
  /// the state decision and the geometry - must not leave an empty draw call
  /// behind for the backend to issue.
  void setState({
    required GpuPipelineKind pipeline,
    required int textureId,
    required int blendMode,
    required int scissorLeft,
    required int scissorTop,
    required int scissorRight,
    required int scissorBottom,
  }) {
    _pendingPipeline = pipeline;
    _pendingTexture = textureId;
    _pendingBlend = blendMode;
    _pendingScissorLeft = scissorLeft;
    _pendingScissorTop = scissorTop;
    _pendingScissorRight = scissorRight;
    _pendingScissorBottom = scissorBottom;
  }

  /// Closes the open batch. The next quad starts a new one whatever its state.
  ///
  /// Needed by a backend that has to flush geometry mid-frame - an atlas that
  /// filled up and must be re-uploaded before the next draw reads it. Not
  /// needed at the end of a frame: [beginFrame] closes everything.
  void flush() {
    _open = false;
  }

  /// Appends a quad in the pending state, merging into the open batch when
  /// the four state components match.
  ///
  /// Returns the batch it landed in, so a caller can assert on merging
  /// without reaching into the list.
  GpuBatch addQuad({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required double u0,
    required double v0,
    required double u1,
    required double v1,
    required double red,
    required double green,
    required double blue,
    required double alpha,
    required double shapeLeft,
    required double shapeTop,
    required double shapeRight,
    required double shapeBottom,
  }) {
    final batch = _currentBatch();
    buffer.addQuad(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      u0: u0,
      v0: v0,
      u1: u1,
      v1: v1,
      red: red,
      green: green,
      blue: blue,
      alpha: alpha,
      shapeLeft: shapeLeft,
      shapeTop: shapeTop,
      shapeRight: shapeRight,
      shapeBottom: shapeBottom,
    );
    batch._indexCount += kGpuIndicesPerQuad;
    return batch;
  }

  /// The batch the pending state belongs in, opening one if it has to.
  GpuBatch _currentBatch() {
    if (_open) {
      final open = _pool[_batchCount - 1];
      if (open._pipeline == _pendingPipeline &&
          open._textureId == _pendingTexture &&
          open._blendMode == _pendingBlend &&
          open._scissorLeft == _pendingScissorLeft &&
          open._scissorTop == _pendingScissorTop &&
          open._scissorRight == _pendingScissorRight &&
          open._scissorBottom == _pendingScissorBottom) {
        return open;
      }
    }

    if (_batchCount == _pool.length) _pool.add(GpuBatch._());
    final batch = _pool[_batchCount++];
    batch
      .._pipeline = _pendingPipeline
      .._textureId = _pendingTexture
      .._blendMode = _pendingBlend
      .._scissorLeft = _pendingScissorLeft
      .._scissorTop = _pendingScissorTop
      .._scissorRight = _pendingScissorRight
      .._scissorBottom = _pendingScissorBottom
      .._indexOffset = buffer.indexCount
      .._indexCount = 0;
    _open = true;
    return batch;
  }
}
