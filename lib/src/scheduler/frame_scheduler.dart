/// Deterministic pulse coordinator for a widget/render tree.
library;

import '../graphics/display_list.dart';
import '../layout/pipeline.dart';
import 'dispatcher_priority.dart';
import 'manual_dispatcher.dart';

/// Called once per frame, before build/layout/paint, with that frame's
/// timestamp.
///
/// The timestamp is the dispatcher's virtual time, which is monotonic and -
/// crucially - not the wall clock. See `animation/clock.dart` for why nothing
/// above this layer is allowed to read one.
typedef FrameCallback = void Function(Duration timestamp);

/// Coordinates build, layout and paint without owning a wall clock.
///
/// A mutation requests one frame; multiple mutations before the dispatcher is
/// drained are coalesced. Tests can therefore assert the exact number of
/// pulses while production backends can replace the dispatcher later.
///
/// ## Two ways to ask for a frame, and why they are different
///
/// [scheduleFrame] posts the frame as a *callback*: it runs on the next
/// [pump], with no virtual time passing. That is what a mutation wants - the
/// tree is dirty now and the next drain must show it.
///
/// [scheduleNextFrame] arms a *timer* for [frameInterval]. That is what a
/// running animation wants, and it must not be the same mechanism: a posted
/// frame that re-posts itself from inside its own frame callback never lets
/// the dispatcher's queue empty, so a single `pump()` would spin until the
/// runaway limit fires. Going through a timer means one frame per
/// [frameInterval] of virtual time, which is both what a real vsync does and
/// what makes "advance 100 ms, expect 10 frames" an exact assertion.
///
/// ## Frame callbacks run before the build
///
/// [addFrameCallback] registers work that runs at the top of a frame, before
/// [PipelineOwner.drawFrame]. Animations live here: a tick that writes a
/// property must land before layout reads it, or every animated value is one
/// frame stale. A dirty mark raised *by* a frame callback therefore does not
/// schedule another frame - the frame it is already inside will consume it.
final class FrameScheduler {
  FrameScheduler({
    ManualDispatcher? dispatcher,
    PipelineOwner? pipelineOwner,
    this.frameInterval = const Duration(microseconds: 16667),
    required this.onFrame,
    this.onNextFrameScheduled,
  })  : dispatcher = dispatcher ?? ManualDispatcher(),
        pipelineOwner = pipelineOwner ?? PipelineOwner() {
    if (frameInterval <= Duration.zero) {
      throw ArgumentError.value(
        frameInterval,
        'frameInterval',
        'must be strictly positive; a zero interval would arm a timer that is '
            'due at the instant it was armed, which virtual time cannot escape',
      );
    }
    if (this.pipelineOwner.onNeedsVisualUpdate != null) {
      throw ArgumentError('pipelineOwner already has a visual update owner');
    }
    this.pipelineOwner.onNeedsVisualUpdate = _scheduleFromPipeline;
  }

  final ManualDispatcher dispatcher;
  final PipelineOwner pipelineOwner;
  final void Function(DisplayList displayList) onFrame;

  /// Wakes an owning platform loop when a timer-driven animation frame is
  /// armed. Tests normally leave this null and advance virtual time directly.
  final void Function(Duration delay)? onNextFrameScheduled;

  /// The nominal gap between two continuous frames. 16667 microseconds is
  /// 60 Hz; a test that wants round numbers should pass its own.
  final Duration frameInterval;

  /// Registered per-frame callbacks, walked by index so a frame allocates no
  /// iterator (section 6.5).
  final List<FrameCallback> _frameCallbacks = <FrameCallback>[];
  final List<FrameCallback> _pendingCallbackRemovals = <FrameCallback>[];

  bool _frameScheduled = false;
  bool _nextFrameArmed = false;
  bool _inFrameCallbacks = false;
  bool _disposed = false;
  Duration _frameTimestamp = Duration.zero;
  int _frameNumber = 0;

  bool get hasScheduledFrame => _frameScheduled;

  /// Whether a continuous (timer-driven) frame is already armed.
  bool get hasArmedNextFrame => _nextFrameArmed;

  /// The timestamp of the frame currently being produced, or of the last one
  /// produced. Monotonic, because [ManualDispatcher.elapsed] is.
  Duration get frameTimestamp => _frameTimestamp;

  /// How many frames have been produced. The counter a test uses to assert
  /// that an animation advanced once per frame - not zero, not twice.
  int get frameNumber => _frameNumber;

  /// Registers [callback] to run at the top of every frame.
  ///
  /// Registering the same callback twice throws: a doubled registration would
  /// advance whatever it drives twice per frame, and the symptom - an
  /// animation running at double speed only on the screen where it was
  /// registered twice - is famously hard to find.
  void addFrameCallback(FrameCallback callback) {
    _throwIfDisposed();
    if (_frameCallbacks.contains(callback)) {
      throw StateError(
        'this FrameCallback is already registered; it would run twice per '
        'frame',
      );
    }
    _frameCallbacks.add(callback);
  }

  /// Unregisters [callback]. Returns whether it was registered.
  ///
  /// Safe from inside a frame callback: the removal is deferred to the end of
  /// the callback phase so the walk does not skip a neighbour.
  bool removeFrameCallback(FrameCallback callback) {
    if (!_frameCallbacks.contains(callback)) return false;
    if (_inFrameCallbacks) {
      _pendingCallbackRemovals.add(callback);
      return true;
    }
    return _frameCallbacks.remove(callback);
  }

  /// How many per-frame callbacks are registered.
  int get frameCallbackCount => _frameCallbacks.length;

  /// Requests one frame on the next [pump], coalescing repeated requests.
  void scheduleFrame() {
    _throwIfDisposed();
    if (_frameScheduled) return;
    _frameScheduled = true;
    dispatcher.post(_handleFrame, priority: DispatcherPriority.animation);
  }

  /// Requests a frame one [frameInterval] of virtual time from now.
  ///
  /// This is the continuous-animation path; see the class documentation for
  /// why it must not be a plain post. Coalesced: calling it twice before the
  /// timer fires arms one timer, so N running animations still cost one.
  void scheduleNextFrame() {
    _throwIfDisposed();
    if (_nextFrameArmed || _frameScheduled) return;
    _nextFrameArmed = true;
    dispatcher.schedule(frameInterval, _handleTimedFrame);
    onNextFrameScheduled?.call(frameInterval);
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
    _frameCallbacks.clear();
    _pendingCallbackRemovals.clear();
    pipelineOwner.root = null;
  }

  /// A dirty mark raised while frame callbacks run needs no new frame: this
  /// frame has not drawn yet and will pick it up. Scheduling one anyway would
  /// produce a second frame per tick - the exact double-advance the
  /// once-per-frame test guards against.
  void _scheduleFromPipeline() {
    if (_inFrameCallbacks) return;
    scheduleFrame();
  }

  void _handleTimedFrame() {
    _nextFrameArmed = false;
    _handleFrame();
  }

  void _handleFrame() {
    if (_disposed) return;
    _frameScheduled = false;
    _frameTimestamp = dispatcher.elapsed;
    _frameNumber++;
    _runFrameCallbacks(_frameTimestamp);
    final list = DisplayList();
    pipelineOwner.drawFrame(list);
    onFrame(list);
  }

  void _runFrameCallbacks(Duration timestamp) {
    if (_frameCallbacks.isEmpty) return;
    _inFrameCallbacks = true;
    try {
      for (int i = 0; i < _frameCallbacks.length; i++) {
        _frameCallbacks[i](timestamp);
      }
    } finally {
      _inFrameCallbacks = false;
      if (_pendingCallbackRemovals.isNotEmpty) {
        for (int i = 0; i < _pendingCallbackRemovals.length; i++) {
          _frameCallbacks.remove(_pendingCallbackRemovals[i]);
        }
        _pendingCallbackRemovals.clear();
      }
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('FrameScheduler was used after dispose().');
  }
}
