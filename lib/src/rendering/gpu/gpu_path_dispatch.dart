/// Transactional promotion of a planned path draw into an ordered GPU command.
///
/// The selector is advisory until a recorder accepts the complete draw.  This
/// interface is the narrow seam between replay (which owns ordering and the
/// dense coverage fallback) and an experimental executor (which owns its
/// retained payload and native resources).
library;

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../path/fill_rule.dart';
import '../replay/display_list_player.dart';
import 'gpu_path_planning.dart';
import 'gpu_path_strategy.dart';

/// Everything required to reproduce one path draw outside the mask atlas.
///
/// All members are immutable values. [path] and [paint] are immutable renderer
/// objects, so a recorder may retain them while it builds a backend-neutral
/// payload. Native execution must not happen from [tryRecord]: the operation
/// belongs in the ordered render-pass stream produced at frame submission.
final class GpuPathDispatchRequest {
  const GpuPathDispatchRequest({
    required this.proposal,
    required this.path,
    required this.localToTarget,
    required this.clip,
    required this.fillRule,
    required this.paint,
    required this.batchIndex,
  });

  final GpuPathPlanningProposal proposal;
  final Path path;
  final Transform2D localToTarget;
  final Rect clip;
  final FillRule fillRule;
  final ReplayPaint paint;

  /// First dense batch that may follow this draw.
  ///
  /// Replay closes the currently open batch before calling the recorder. This
  /// index therefore places the vector command after every earlier batch and
  /// before every later one without executing native GPU work during replay.
  final int batchIndex;

  GpuPathStrategy get candidateStrategy => proposal.candidate.strategy;
}

/// Records complete experimental path commands without touching the device.
abstract interface class GpuPathCommandRecorder {
  /// Attempts to retain [request] in the ordered command stream.
  ///
  /// Returning true is a commit: the recorder guarantees that one complete
  /// command for [request.candidateStrategy] was appended and owns all payload
  /// needed until submission. Returning false is a transactional refusal and
  /// must leave the stream unchanged. Throwing is treated as a refusal by the
  /// replay sink, but implementations should prefer false for expected limits.
  ///
  /// A recorder must never issue native API calls here. Doing so could draw
  /// before an earlier dense batch or into the wrong saveLayer target.
  bool tryRecord(GpuPathDispatchRequest request);
}
