/// Incremental submission state for mixed dense/vector command snapshots.
library;

import 'gpu_vector_command_stream.dart';

final class GpuDenseSubmissionRange {
  const GpuDenseSubmissionRange(this.firstBatch, this.endBatch);

  final int firstBatch;
  final int endBatch;
}

/// Prevents a mid-frame atlas flush from drawing a command twice.
///
/// [GpuVectorCommandStream.snapshot] may rebuild operation objects as replay
/// continues. Dense batch indices, vector ordinals and source pass indices are
/// stable across those snapshots, so those are the only identities retained
/// here. A backend advances the cursor only after the corresponding native
/// operation succeeds.
final class GpuVectorSubmissionCursor {
  int _nextDenseBatch = 0;
  int _nextVectorOrdinal = 0;
  final Set<int> _clearedPasses = <int>{};

  int get nextDenseBatch => _nextDenseBatch;
  int get nextVectorOrdinal => _nextVectorOrdinal;

  void reset({int firstBatch = 0}) {
    if (firstBatch < 0) {
      throw RangeError.value(firstBatch, 'firstBatch', 'must be non-negative');
    }
    _nextDenseBatch = firstBatch;
    _nextVectorOrdinal = 0;
    _clearedPasses.clear();
  }

  GpuDenseSubmissionRange? pendingDense<M, P>(
    GpuOrderedRenderCommand<M, P> command,
  ) {
    if (command.kind != GpuOrderedCommandKind.denseBatchRange) {
      throw ArgumentError.value(command, 'command', 'must be a dense range');
    }
    final int first = command.firstBatch < _nextDenseBatch
        ? _nextDenseBatch
        : command.firstBatch;
    if (command.endBatch <= first) return null;
    return GpuDenseSubmissionRange(first, command.endBatch);
  }

  void markDenseSubmitted(GpuDenseSubmissionRange range) {
    if (range.firstBatch < _nextDenseBatch ||
        range.endBatch <= range.firstBatch) {
      throw StateError('invalid dense submission '
          '[${range.firstBatch}, ${range.endBatch}) after batch '
          '$_nextDenseBatch');
    }
    _nextDenseBatch = range.endBatch;
  }

  bool isVectorPending<M, P>(GpuExperimentalVectorCommand<M, P> command) =>
      command.vectorOrdinal >= _nextVectorOrdinal;

  void markVectorSubmitted<M, P>(
    GpuExperimentalVectorCommand<M, P> command,
  ) {
    if (command.vectorOrdinal != _nextVectorOrdinal) {
      throw StateError('expected vector ordinal $_nextVectorOrdinal, got '
          '${command.vectorOrdinal}');
    }
    _nextVectorOrdinal++;
  }

  bool isClearPending<M, P>(GpuVectorPassRecord<M, P> pass) =>
      pass.clearsTarget && !_clearedPasses.contains(pass.sourcePassIndex);

  void markPassCleared<M, P>(GpuVectorPassRecord<M, P> pass) {
    if (!pass.clearsTarget) {
      throw ArgumentError.value(pass, 'pass', 'does not clear its target');
    }
    _clearedPasses.add(pass.sourcePassIndex);
  }
}

typedef GpuBeginOrderedPass<M, P> = void Function(
  GpuVectorPassRecord<M, P> pass,
  bool clearTarget,
);
typedef GpuSubmitDenseRange<M, P> = void Function(
  GpuVectorPassRecord<M, P> pass,
  GpuDenseSubmissionRange range,
);
typedef GpuSubmitVectorCommand<M, P> = void Function(
  GpuVectorPassRecord<M, P> pass,
  GpuExperimentalVectorCommand<M, P> command,
);
typedef GpuEndOrderedPass<M, P> = void Function(
  GpuVectorPassRecord<M, P> pass,
);

/// Walks one snapshot and advances [cursor] after each successful callback.
final class GpuOrderedSubmissionWalker {
  const GpuOrderedSubmissionWalker();

  void submit<M, P>({
    required GpuVectorCommandStream<M, P> stream,
    required GpuVectorSubmissionCursor cursor,
    required GpuBeginOrderedPass<M, P> beginPass,
    required GpuSubmitDenseRange<M, P> submitDense,
    required GpuSubmitVectorCommand<M, P> submitVector,
    required GpuEndOrderedPass<M, P> endPass,
  }) {
    for (final GpuVectorPassRecord<M, P> pass in stream.passes) {
      final bool clear = cursor.isClearPending(pass);
      final bool hasPendingCommands = pass.commands.any((command) {
        switch (command.kind) {
          case GpuOrderedCommandKind.denseBatchRange:
            return cursor.pendingDense(command) != null;
          case GpuOrderedCommandKind.experimentalVector:
            return cursor.isVectorPending(command.vector!);
        }
      });
      if (!clear && !hasPendingCommands) continue;

      beginPass(pass, clear);
      if (clear) cursor.markPassCleared(pass);
      try {
        for (final GpuOrderedRenderCommand<M, P> command in pass.commands) {
          switch (command.kind) {
            case GpuOrderedCommandKind.denseBatchRange:
              final GpuDenseSubmissionRange? range =
                  cursor.pendingDense(command);
              if (range == null) continue;
              submitDense(pass, range);
              cursor.markDenseSubmitted(range);
            case GpuOrderedCommandKind.experimentalVector:
              final GpuExperimentalVectorCommand<M, P> vector = command.vector!;
              if (!cursor.isVectorPending(vector)) continue;
              submitVector(pass, vector);
              cursor.markVectorSubmitted(vector);
          }
        }
      } finally {
        endPass(pass);
      }
    }
  }
}
