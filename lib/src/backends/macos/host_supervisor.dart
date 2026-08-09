/// Keeping a host alive, including across its own death.
///
/// ADR 0001 chose a worker process *because* it isolates crashes, and then
/// wrote down that crash detection and restart become requirements rather than
/// details. Run `31272239992` measured the three facts this file is built on:
///
///   | Dart notices the SIGKILL       | 29 ms, status -9        |
///   | The surface outlives the host  | a later write works     |
///   | A new host reattaches the SAME | `SURFACE_OK 7` +        |
///   | surface and presents           | `PRESENT_OK`            |
///
/// The third is what makes recovery cheap: **the window is new, the
/// framebuffer is not.** The surfaces belong to Dart - the host is a consumer
/// of pixels, not their owner - so a restart re-attaches the pool it already
/// has instead of re-uploading a frame.
///
/// A backend that merely dies with its host throws all of that away, which is
/// why this is a supervisor and not a field holding a `Process`.
library;

import 'dart:async';

import '../../foundation/diagnostics.dart';
import 'host_process.dart';
import 'host_protocol.dart';
import 'mach_rendezvous.dart';
import 'surface_pool.dart';

/// How the surface reaches the host.
enum MacosSurfaceHandoff {
  /// `IOSurfaceCreateMachPort` in Dart, `IOSurfaceLookupFromMachPort` in the
  /// host, with the port carried by a rendezvous over a launchd name the host
  /// checked in. Supported, non-deprecated, no ordering constraint.
  rendezvous,

}

/// Tuning for the restart policy.
final class MacosRecoveryPolicy {
  const MacosRecoveryPolicy({
    this.maxAttempts = 3,
    this.backoff = const Duration(milliseconds: 100),
    this.minimumHealthyUptime = const Duration(seconds: 2),
    this.attachTimeout = const Duration(seconds: 5),
  });

  /// Zero disables recovery entirely, which is what a test that wants to
  /// observe the death itself asks for.
  final int maxAttempts;

  /// Multiplied by the attempt number. Small because the measured detection
  /// latency is 29 ms and the whole point is that the window comes back before
  /// a user reaches for the mouse.
  final Duration backoff;

  /// A host that dies sooner than this after starting is crash-looping, and
  /// restarting it faster will not help. Counted separately so a host that ran
  /// for an hour and then crashed gets a fresh budget.
  final Duration minimumHealthyUptime;

  /// Deadline for each attach step. Five seconds matches the host's own
  /// rendezvous receive timeout, so a client that gives up first would hide
  /// the host's error line.
  final Duration attachTimeout;
}

/// What the supervisor is doing.
enum MacosSupervisorState {
  created,
  starting,
  running,
  recovering,
  stopped,
  failed
}

/// Owns the current host and replaces it when it dies.
final class MacosHostSupervisor {
  MacosHostSupervisor({
    required MacosHostSpawnOptions spawnOptions,
    required HostMessageSink sink,
    required void Function(BackendDiagnostic diagnostic) onDiagnostic,
    required void Function(MacosHostHandshake handshake, Duration downtime)
        onHostReplaced,
    required void Function() onRecoveryExhausted,
    MacosRecoveryPolicy policy = const MacosRecoveryPolicy(),
    MacosSurfaceHandoff handoff = MacosSurfaceHandoff.rendezvous,
  })  : _spawnOptions = spawnOptions,
        _sink = sink,
        _onDiagnostic = onDiagnostic,
        _onHostReplaced = onHostReplaced,
        _onRecoveryExhausted = onRecoveryExhausted,
        _policy = policy,
        _handoff = handoff;

  MacosHostSpawnOptions _spawnOptions;
  final HostMessageSink _sink;
  final void Function(BackendDiagnostic diagnostic) _onDiagnostic;
  final void Function(MacosHostHandshake handshake, Duration downtime)
      _onHostReplaced;
  final void Function() _onRecoveryExhausted;
  final MacosRecoveryPolicy _policy;
  final MacosSurfaceHandoff _handoff;

  MacosHostProcess? _host;
  MacosSurfacePool? _pool;
  MacosSupervisorState _state = MacosSupervisorState.created;

  /// Counts *consecutive* failures, reset by a host that stayed up longer than
  /// [MacosRecoveryPolicy.minimumHealthyUptime].
  int _consecutiveFailures = 0;
  int _restartCounter = 0;
  DateTime? _startedAt;
  bool _stopping = false;

  /// Replayed onto every new host, in the order a fresh window would receive
  /// them. Without this a recovered window loses its title and its position -
  /// visible proof that the recovery was not complete.
  String? _title;
  double? _boundsX;
  double? _boundsY;
  double? _boundsWidth;
  double? _boundsHeight;
  String? _cursor;
  bool _visible = true;

  MacosSupervisorState get state => _state;
  MacosHostProcess? get host => _host;
  MacosHostHandshake? get handshake => _host?.handshake;
  int get restartCount => _restartCounter;

  /// Which mechanism actually delivered the surfaces to the current host.
  MacosSurfaceHandoff? get activeHandoff => _activeHandoff;
  MacosSurfaceHandoff? _activeHandoff;

  /// Starts the first host.
  ///
  /// No pool yet: the host's banner reports the backing scale factor of the
  /// screen it opened on, and allocating the surfaces before knowing that
  /// means allocating a Retina window at half resolution and immediately
  /// throwing it away. [attachPool] follows.
  Future<bool> start() async {
    if (_state != MacosSupervisorState.created) return false;
    _state = MacosSupervisorState.starting;
    final started = await _spawnAndAttach();
    _state =
        started ? MacosSupervisorState.running : MacosSupervisorState.failed;
    return started;
  }

  /// Sends a command to the current host, dropping it if there is none.
  ///
  /// Dropping is right: during recovery there is no window to act on, and the
  /// state that matters is replayed by [_applyState] when the new host is up.
  bool send(String command) => _host?.send(command) ?? false;

  void rememberTitle(String title) {
    _title = title;
    send(HostCommands.setTitle(title));
  }

  void rememberBounds(double x, double y, double width, double height) {
    _boundsX = x;
    _boundsY = y;
    _boundsWidth = width;
    _boundsHeight = height;
    send(HostCommands.setBounds(x, y, width, height));
  }

  void rememberCursor(String cursor) {
    _cursor = cursor;
    send(HostCommands.setCursor(cursor));
  }

  void rememberVisibility(bool visible) {
    _visible = visible;
    send(visible ? HostCommands.show() : HostCommands.hide());
  }

  /// Presents [slot], returning the sequence number the host was given.
  ///
  /// Fire and forget by default: the measured present round trip is 188 us of
  /// median latency, and blocking a frame on it buys nothing because the
  /// double buffer already guarantees the client is not writing the presented
  /// slot. [awaitAck] exists for the conformance path, which has to prove the
  /// pixels arrived rather than assume it.
  Future<bool> present(int slot, int sequence, {bool awaitAck = false}) async {
    final host = _host;
    if (host == null) return false;
    if (!host.send(HostCommands.presentSlot(sequence, slot))) return false;
    if (!awaitAck) return true;
    return host.awaitPresented(sequence, _policy.attachTimeout);
  }

  /// Stops supervising and shuts the host down in reverse order.
  ///
  /// Idempotent, because callers dispose on both the success and the failure
  /// path and making them track which one ran is how double frees get written.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    final host = _host;
    _host = null;
    _state = MacosSupervisorState.stopped;
    if (host != null) await host.close();
  }

  // --- spawning and attaching -----------------------------------------------

  Future<bool> _spawnAndAttach() async {
    final host = await MacosHostProcess.start(
      _spawnOptions,
      _sink,
      _onDiagnostic,
    );
    if (host == null) return false;
    _host = host;
    _startedAt = DateTime.now();
    unawaited(host.exitStatus.then((int status) => _onHostExit(host, status)));

    final pool = _pool;
    if (pool == null) return true;
    if (!await _attachPool(host, pool)) {
      await host.kill();
      return false;
    }
    _applyState();
    return true;
  }

  /// Attaches every slot of [pool] to [host].
  ///
  /// Strictly one slot at a time. The host's rendezvous receive is a blocking
  /// `mach_msg` on a worker thread, so two outstanding receives on the same
  /// port would race for the same two messages and could pair a port with the
  /// wrong slot - a mix-up that would show up as tearing rather than as an
  /// error, which is the worst kind.
  Future<bool> _attachPool(MacosHostProcess host, MacosSurfacePool pool) async {
    if (_handoff == MacosSurfaceHandoff.rendezvous &&
        MachRendezvous.isAvailable &&
        (host.handshake?.supportsSurfacePort ?? false)) {
      if (await _attachByRendezvous(host, pool)) {
        _activeHandoff = MacosSurfaceHandoff.rendezvous;
        return true;
      }
    }
    return false;
  }

  Future<bool> _attachByRendezvous(
    MacosHostProcess host,
    MacosSurfacePool pool,
  ) async {
    if (!host.send(HostCommands.surfacePool(pool.slotCount))) return false;
    if (!await host.awaitAck(
      HostAckKind.surfacePoolAllocated,
      _policy.attachTimeout,
    )) {
      return false;
    }

    // The name carries the host's pid so a replacement host cannot collide
    // with a name its killed predecessor published and launchd has not yet
    // reaped.
    final name = HostCommands.rendezvousName(host.pid, _restartCounter);
    if (!host.send(HostCommands.portServer(name))) return false;
    if (!await host.awaitAck(HostAckKind.portServer, _policy.attachTimeout)) {
      return false;
    }

    for (var slot = 0; slot < pool.slotCount; slot++) {
      if (!host.send(HostCommands.surfacePortRendezvous(slot))) return false;
      final port = pool.surfaces[slot].createMachPort();
      final status = MachRendezvous.send(name, port, slot);
      if (status != kernSuccess) {
        _onDiagnostic(
          BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'could not send surface port to the macOS host',
            detail: 'slot $slot, name $name, status $status '
                '(1102 = the host has not checked in, 1100 = sandbox refused '
                'mach-register, 0x10000004 = send timed out)',
          ),
        );
        return false;
      }
      if (!await host.awaitSurfaceAttached(slot, _policy.attachTimeout)) {
        return false;
      }
    }
    return true;
  }

  void _applyState() {
    final title = _title;
    if (title != null) send(HostCommands.setTitle(title));
    final x = _boundsX;
    final y = _boundsY;
    final width = _boundsWidth;
    final height = _boundsHeight;
    if (x != null && y != null && width != null && height != null) {
      send(HostCommands.setBounds(x, y, width, height));
    }
    final cursor = _cursor;
    if (cursor != null) send(HostCommands.setCursor(cursor));
    // Visibility last: a window that is shown before it is placed flashes at
    // the wrong position, which after a crash looks like a second failure.
    send(_visible ? HostCommands.show() : HostCommands.hide());
  }

  // --- recovery --------------------------------------------------------------

  void _onHostExit(MacosHostProcess host, int status) {
    if (!identical(host, _host)) return;
    if (_stopping || _state == MacosSupervisorState.stopped) return;
    _host = null;

    if (host.exitReason == MacosHostExitReason.requested) {
      _state = MacosSupervisorState.stopped;
      return;
    }

    final uptime = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    if (uptime > _policy.minimumHealthyUptime) _consecutiveFailures = 0;

    _onDiagnostic(
      BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'macOS AppKit host died',
        detail: 'exit status $status after ${uptime.inMilliseconds} ms '
            '(-9 is SIGKILL); attempting recovery '
            '${_consecutiveFailures + 1}/${_policy.maxAttempts}',
      ),
    );

    if (_policy.maxAttempts <= 0 ||
        _consecutiveFailures >= _policy.maxAttempts) {
      _state = MacosSupervisorState.failed;
      _onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'macOS AppKit host could not be recovered',
          detail: 'gave up after $_consecutiveFailures consecutive failures; '
              'the surfaces are intact but nothing is showing them',
        ),
      );
      _onRecoveryExhausted();
      return;
    }

    _consecutiveFailures++;
    _state = MacosSupervisorState.recovering;
    unawaited(_recover(DateTime.now()));
  }

  Future<void> _recover(DateTime diedAt) async {
    await Future<void>.delayed(_policy.backoff * _consecutiveFailures);
    if (_stopping) return;

    _restartCounter++;
    // The presented slot belonged to a compositor that no longer exists, so
    // the whole pool is writable again. The pixels themselves survived - that
    // is the measured property this recovery is built on.
    _pool?.resetPresentation();

    final started = await _spawnAndAttach();
    if (!started) {
      if (_stopping) return;
      // A spawn that fails does not produce an exit event, so the retry has to
      // be driven from here or recovery would stop silently after one attempt.
      if (_consecutiveFailures >= _policy.maxAttempts) {
        _state = MacosSupervisorState.failed;
        _onRecoveryExhausted();
        return;
      }
      _consecutiveFailures++;
      unawaited(_recover(diedAt));
      return;
    }

    _state = MacosSupervisorState.running;
    final downtime = DateTime.now().difference(diedAt);
    final banner = _host?.handshake;
    if (banner != null) {
      _onDiagnostic(
        BackendDiagnostic.note(
          'macOS AppKit host recovered',
          detail: 'new window ${banner.windowNumber}, pid ${banner.hostPid}, '
              'down for ${downtime.inMilliseconds} ms, same surfaces '
              'reattached via ${_activeHandoff?.name}',
        ),
      );
      _onHostReplaced(banner, downtime);
    }
  }

  /// Attaches [pool], first time or after a resize allocated new surfaces.
  ///
  /// The pool is created by the caller because its surfaces outlive every host
  /// this supervisor will ever spawn - exactly the property recovery depends
  /// on - and the caller disposes the previous one only after this returns:
  /// the host holds its own reference to every surface, but releasing ours
  /// while it is still the layer's contents is the ordering mistake
  /// `lifecycle.dart` exists to prevent.
  Future<bool> attachPool(MacosSurfacePool pool) async {
    _pool = pool;
    final host = _host;
    if (host == null) return false;
    return _attachPool(host, pool);
  }

  /// Updates the spawn options a *future* host will use.
  ///
  /// Called on resize so that a recovered window comes back the size it was,
  /// not the size it was created at.
  void updateSpawnGeometry(double width, double height) {
    _spawnOptions = MacosHostSpawnOptions(
      binaryPath: _spawnOptions.binaryPath,
      logicalWidth: width,
      logicalHeight: height,
      title: _title ?? _spawnOptions.title,
      x: _boundsX,
      y: _boundsY,
      visible: _visible,
      decorated: _spawnOptions.decorated,
      resizable: _spawnOptions.resizable,
      handshakeTimeout: _spawnOptions.handshakeTimeout,
    );
  }
}
