/// Device loss as a state, not an exception.
///
/// A GPU device dies for reasons that are not bugs: a driver update, a TDR
/// after a long shader, a laptop switching from the discrete GPU to the
/// integrated one, an external display being unplugged. The window survives
/// all of them. So "the device is gone" has to be something the renderer
/// *reports* and the owner recovers from, which is what
/// [RenderDevice.isLost] and [PresentStatus.deviceLost] are for.
///
/// Throwing instead is the failure mode this file exists to prevent. An
/// exception thrown from inside a present unwinds through the frame loop,
/// gets caught somewhere generic, and turns a recoverable event into either a
/// crash or - worse - a silently skipped frame that repeats forever because
/// nothing recreated the device.
///
/// This class is deliberately device-independent and holds no handles, so the
/// loss path is testable on a machine with no GPU at all: mark it lost, and
/// assert that the target answers [PresentStatus.deviceLost] with a
/// diagnostic that names the cause.
library;

import '../../foundation/diagnostics.dart';
import '../renderer.dart';

/// The liveness of one GPU device, shared by the device and its targets.
final class GpuDeviceState {
  GpuDeviceState();

  BackendDiagnostic? _diagnostic;
  int _lossCount = 0;

  bool get isLost => _diagnostic != null;

  /// Why the device was lost, or null while it is healthy. Goes straight
  /// into the [PresentResult] and into the log, per section 6.6.
  BackendDiagnostic? get lossDiagnostic => _diagnostic;

  /// How many times a loss has been recorded. A target bumps its generation
  /// from this, so a frame begun before the loss presents as stale rather
  /// than being drawn into a framebuffer the driver has already freed.
  int get lossCount => _lossCount;

  /// Records a loss. The first reason wins: the errors that follow a lost
  /// context are consequences, and the first one is the one worth reporting.
  void markLost(BackendDiagnostic reason) {
    if (_diagnostic != null) return;
    _diagnostic = reason;
    _lossCount++;
  }

  /// The result a present must return while the device is lost, or null when
  /// the caller should carry on.
  ///
  /// Returning the result rather than throwing is the whole point; a caller
  /// writes `return state.blockedPresent() ?? await _reallyPresent(frame);`
  /// and cannot forget the case.
  PresentResult? blockedPresent() {
    final diagnostic = _diagnostic;
    if (diagnostic == null) return null;
    return PresentResult(
      status: PresentStatus.deviceLost,
      diagnostic: diagnostic,
    );
  }
}
