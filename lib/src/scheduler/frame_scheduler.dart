/// Deterministic pulse coordinator for a widget/render tree.
library;

import '../graphics/display_list.dart';
import '../layout/pipeline.dart';
import 'dispatcher_priority.dart';
import 'manual_dispatcher.dart';

/// Coordinates build, layout and paint without owning a wall clock.
///
/// A mutation requests one frame; multiple mutations before the dispatcher is
/// drained are coalesced. Tests can therefore assert the exact number of
/// pulses while production backends can replace the dispatcher later.
final class FrameScheduler {
  FrameScheduler({
    ManualDispatcher? dispatcher,
    PipelineOwner? pipelineOwner,
    required this.onFrame,
  })  : dispatcher = dispatcher ?? ManualDispatcher(),
        pipelineOwner = pipelineOwner ?? PipelineOwner() {
    if (this.pipelineOwner.onNeedsVisualUpdate != null) {
      throw ArgumentError('pipelineOwner already has a visual update owner');
    }
    this.pipelineOwner.onNeedsVisualUpdate = _scheduleFromPipeline;
  }

  final ManualDispatcher dispatcher;
  final PipelineOwner pipelineOwner;
  final void Function(DisplayList displayList) onFrame;

  bool _frameScheduled = false;
  bool _disposed = false;

  bool get hasScheduledFrame => _frameScheduled;

  void scheduleFrame() {
    _throwIfDisposed();
    if (_frameScheduled) return;
    _frameScheduled = true;
    dispatcher.post(_handleFrame, priority: DispatcherPriority.animation);
  }

  void pump() {
    _throwIfDisposed();
    dispatcher.drain();
  }

  void advance(Duration duration) {
    _throwIfDisposed();
    dispatcher.advance(duration);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    pipelineOwner.root = null;
  }

  void _scheduleFromPipeline() => scheduleFrame();

  void _handleFrame() {
    if (_disposed) return;
    _frameScheduled = false;
    final list = DisplayList();
    pipelineOwner.drawFrame(list);
    onFrame(list);
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('FrameScheduler was used after dispose().');
  }
}
