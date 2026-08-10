/// One spawned AppKit host, and the handshake that makes it usable.
///
/// The host is the process that owns thread 0. ADR 0001 chose that split after
/// measuring what it costs: 22-59 us for a round trip with no pixels, roughly
/// 0.2% of a 60 Hz frame, against an embedder that is not even buildable with
/// a release SDK (`Dart_Initialize` has no linkable `libdart`). What the split
/// buys is that a bug in Dart UI code cannot take the window down - and what
/// it obliges is this file: a protocol, a handshake, and a death to notice.
///
/// Everything that can wait, waits with a deadline. A host that never answers
/// must produce a diagnostic, never a hang; that is a hard requirement of this
/// backend and the reason there is not a single bare `await` on a completer
/// below.
library;

import 'dart:async';
import 'dart:io';

import '../../foundation/diagnostics.dart';
import 'host_protocol.dart';

/// How a host instance ended.
enum MacosHostExitReason {
  /// Still running.
  none,

  /// `CLOSE` was sent and the host terminated with status 0.
  requested,

  /// The process died on its own - a signal, a crash, an `exit` we did not
  /// ask for. This is the case the recovery path exists for.
  unexpected,

  /// The host never completed its handshake within the deadline.
  handshakeTimeout,

  /// The process could not be spawned at all.
  spawnFailed,
}

/// What one host reported about itself before it was usable.
final class MacosHostHandshake {
  const MacosHostHandshake({
    required this.windowNumber,
    required this.hostPid,
    required this.protocolVersion,
    required this.features,
    this.renderScale = 1,
  });

  /// The `CGSWindowID`. Kept for `screencapture -l<id>` - the only witness
  /// that a window really exists, because no backend can self-report it - and
  /// deliberately not what the framework sees as a window id.
  final int windowNumber;

  final int hostPid;
  final int protocolVersion;

  /// Backing scale reported before the first IOSurface allocation.
  final double renderScale;

  /// `PROTOCOL_FEATURES` verbatim. Compared with `contains`, never for
  /// equality: a host that gains a feature must not look like a stranger.
  final String features;

  bool get supportsSurfacePort => features.contains('surface-port');

  /// Whether the host reports `WINDOW=` lines. A protocol 3 host does not, and
  /// then the window's size is whatever it was asked for and never changes.
  bool get supportsWindowEvents =>
      features.contains('window-events') ||
      protocolVersion >= kMacosHostProtocolVersion;
}

/// Spawn parameters for one host process.
final class MacosHostSpawnOptions {
  const MacosHostSpawnOptions({
    required this.binaryPath,
    required this.logicalWidth,
    required this.logicalHeight,
    this.title = 'dart_ui',
    this.x,
    this.y,
    this.visible = true,
    this.decorated = true,
    this.resizable = true,
    this.handshakeTimeout = const Duration(seconds: 10),
  });

  final String binaryPath;
  final double logicalWidth;
  final double logicalHeight;
  final String title;

  /// Top-left-origin screen points, or null for "let AppKit place it".
  final double? x;
  final double? y;

  final bool visible;
  final bool decorated;
  final bool resizable;

  /// Ten seconds because a cold `NSApplication` on a loaded CI runner has been
  /// seen to take seconds, and because the alternative to waiting is a false
  /// negative that costs a whole CI round trip.
  final Duration handshakeTimeout;

  List<String> toArguments() => <String>[
        '--command-stdin',
        '--width',
        logicalWidth.toStringAsFixed(0),
        '--height',
        logicalHeight.toStringAsFixed(0),
        '--title',
        title,
        if (x != null && y != null) ...<String>[
          '--x',
          x!.toStringAsFixed(0),
          '--y',
          y!.toStringAsFixed(0),
        ],
        if (!visible) '--hidden',
        if (!decorated) '--no-decorations',
        if (!resizable) '--not-resizable',
      ];
}

/// Signals a caller can wait for, without allocating one per event.
enum _SignalKind {
  ack,
  surfaceAttached,
  surfacePortAttached,
  presented,
  error,
  exited,
}

final class _Waiter {
  _Waiter(this.test, this.completer);

  /// `(kind, a, b)` -> whether this waiter is satisfied. `a` and `b` carry the
  /// signal's numbers; their meaning is per [_SignalKind].
  final bool Function(_SignalKind kind, int a, int b) test;
  final Completer<bool> completer;
}

/// The process operations the supervisor needs from one host instance.
///
/// Keeping this boundary smaller than [MacosHostProcess] lets recovery be
/// exercised without spawning AppKit (or even running on macOS). Production
/// still uses [MacosHostProcess.start]; tests can supply a deterministic
/// implementation whose exit status they control.
abstract interface class MacosHostProcessHandle {
  MacosHostHandshake? get handshake;
  MacosHostExitReason get exitReason;
  int get pid;
  Future<int> get exitStatus;

  bool send(String command);
  Future<bool> awaitAck(HostAckKind kind, Duration timeout);
  Future<bool> awaitSurfaceAttached(int slot, Duration timeout);
  Future<bool> awaitPresented(int sequence, Duration timeout);
  Future<int> close({Duration timeout = const Duration(seconds: 5)});
  Future<int> kill();
}

/// A live host process.
///
/// Owns exactly one `Process` and never restarts it: replacing a dead host is
/// [MacosHostSupervisor]'s job, and keeping the two apart is what lets the
/// restart path be read without also reading the protocol.
final class MacosHostProcess
    implements HostMessageSink, MacosHostProcessHandle {
  MacosHostProcess._(this._process, this._sink, this._onDiagnostic) {
    _parser = HostProtocolParser(this);
  }

  final Process _process;

  /// Where parsed messages go once the handshake is done. The host process
  /// itself is the parser's sink, so it can serve its own waiters first.
  final HostMessageSink _sink;

  final void Function(BackendDiagnostic diagnostic) _onDiagnostic;

  late final HostProtocolParser _parser;
  final List<_Waiter> _waiters = <_Waiter>[];

  final Completer<MacosHostHandshake> _handshake =
      Completer<MacosHostHandshake>();
  final Completer<int> _exited = Completer<int>();

  int _windowNumber = 0;
  int _hostPid = 0;
  int _protocolVersion = 0;
  int _renderScaleMilli = 1000;
  String _features = '';
  bool _sawMainThread = false;

  MacosHostExitReason _exitReason = MacosHostExitReason.none;
  bool _closeRequested = false;
  bool _stdinBroken = false;

  MacosHostHandshake? _completedHandshake;

  @override
  MacosHostHandshake? get handshake => _completedHandshake;

  @override
  MacosHostExitReason get exitReason => _exitReason;

  @override
  int get pid => _process.pid;

  bool get isAlive => !_exited.isCompleted;

  /// Completes with the process exit status. `-9` is the `SIGKILL` the
  /// recovery probe uses; Dart reports a signal death as `-signal` on POSIX.
  @override
  Future<int> get exitStatus => _exited.future;

  /// Spawns a host and waits for its banner.
  ///
  /// Returns null on failure, having reported at least one diagnostic. Null
  /// rather than an exception because the caller's next move - report and try
  /// again, or give up - is the same either way, and a throw from here would
  /// have to be caught in every one of them.
  static Future<MacosHostProcess?> start(
    MacosHostSpawnOptions options,
    HostMessageSink sink,
    void Function(BackendDiagnostic diagnostic) onDiagnostic,
  ) async {
    Process process;
    try {
      process = await Process.start(
        options.binaryPath,
        options.toArguments(),
      );
    } on Object catch (error) {
      onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'could not spawn the macOS AppKit host',
          detail: '${options.binaryPath}: $error',
        ),
      );
      return null;
    }

    final host = MacosHostProcess._(process, sink, onDiagnostic);
    host._listen();

    final banner = await host._handshake.future
        .timeout(options.handshakeTimeout, onTimeout: () {
      host._exitReason = MacosHostExitReason.handshakeTimeout;
      return const MacosHostHandshake(
        windowNumber: 0,
        hostPid: 0,
        protocolVersion: 0,
        features: '',
      );
    });

    if (banner.windowNumber == 0) {
      onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'macOS host did not complete its handshake',
          detail: 'binary ${options.binaryPath}, waited '
              '${options.handshakeTimeout.inMilliseconds} ms; expected '
              'MAIN_THREAD=1, WINDOW_ID, PROTOCOL and HOST_PID',
        ),
      );
      await host.kill();
      return null;
    }
    if (banner.protocolVersion < kMacosHostMinimumProtocolVersion) {
      onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.incompatibleVersion,
          message: 'macOS host speaks an unsupported protocol',
          detail: 'host reported ${banner.protocolVersion}, this backend '
              'needs at least $kMacosHostMinimumProtocolVersion',
        ),
      );
      await host.kill();
      return null;
    }
    if (banner.protocolVersion < kMacosHostProtocolVersion) {
      // Not fatal: a protocol 3 host presents and reports input, it just never
      // reports a resize. Saying so is better than either refusing to run or
      // silently reporting a window whose size can never change.
      onDiagnostic(
        BackendDiagnostic.note(
          'macOS host is older than this backend',
          detail: 'protocol ${banner.protocolVersion} < '
              '$kMacosHostProtocolVersion: no WINDOW= events, so resizes and '
              'scale changes will not be reported',
        ),
      );
    }
    return host;
  }

  void _listen() {
    _process.stdout.listen(
      _parser.addBytes,
      onError: (Object error) => _onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'macOS host stdout failed',
          detail: '$error',
        ),
      ),
      onDone: _parser.flush,
      cancelOnError: false,
    );
    // stderr is where clang runtime errors and AppKit's own complaints land.
    // Forwarding it as diagnostics rather than dropping it is the difference
    // between "the host died" and "the host died because the framework was
    // missing".
    _process.stderr.listen((List<int> bytes) {
      final text = String.fromCharCodes(bytes).trim();
      if (text.isEmpty) return;
      _onDiagnostic(
        BackendDiagnostic.note('macOS host stderr', detail: text),
      );
    }, cancelOnError: false);

    unawaited(_process.exitCode.then((int status) {
      if (_exited.isCompleted) return;
      if (_exitReason == MacosHostExitReason.none) {
        _exitReason = _closeRequested && status == 0
            ? MacosHostExitReason.requested
            : MacosHostExitReason.unexpected;
      }
      _exited.complete(status);
      _notify(_SignalKind.exited, status, 0);
      if (!_handshake.isCompleted) {
        _handshake.complete(
          const MacosHostHandshake(
            windowNumber: 0,
            hostPid: 0,
            protocolVersion: 0,
            features: '',
          ),
        );
      }
    }));
  }

  // --- sending ---------------------------------------------------------------

  /// Writes a command. Returns false when the pipe is gone, which is what a
  /// host that died between two commands looks like from here.
  @override
  bool send(String command) {
    if (_stdinBroken || _exited.isCompleted) return false;
    try {
      _process.stdin.write(command);
      return true;
    } on Object catch (error) {
      // A broken pipe is not an error worth throwing: the exit future is about
      // to arrive and carries the real reason.
      _stdinBroken = true;
      _onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'macOS host stdin is closed',
          detail: '$error',
        ),
      );
      return false;
    }
  }

  /// Asks the host to terminate and waits for it to go.
  ///
  /// Reverse order on purpose: `CLOSE` lets `applicationWillTerminate` release
  /// the event monitor, the layer contents, the pool and the window before the
  /// process leaves. `kill` is the fallback for a host that ignored it.
  @override
  Future<int> close({Duration timeout = const Duration(seconds: 5)}) async {
    if (_exited.isCompleted) return _exited.future;
    _closeRequested = true;
    send(HostCommands.close());
    final status = await _exited.future.timeout(timeout, onTimeout: () => -998);
    if (status == -998) {
      _onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'macOS host ignored CLOSE',
          detail: 'killing after ${timeout.inMilliseconds} ms',
        ),
      );
      return kill();
    }
    return status;
  }

  @override
  Future<int> kill() async {
    if (_exited.isCompleted) return _exited.future;
    _process.kill(ProcessSignal.sigkill);
    return _exited.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -997,
    );
  }

  // --- waiting ---------------------------------------------------------------

  /// Waits for a signal, or for the host to die, or for [timeout].
  ///
  /// Returns false in the last two cases. Never returns a future that can hang
  /// - that property is the whole reason this helper exists instead of ad hoc
  /// completers at each call site.
  Future<bool> _waitFor(
    bool Function(_SignalKind kind, int a, int b) test,
    Duration timeout,
  ) {
    if (_exited.isCompleted) return Future<bool>.value(false);
    final completer = Completer<bool>();
    final waiter = _Waiter(test, completer);
    _waiters.add(waiter);
    return completer.future.timeout(timeout, onTimeout: () {
      _waiters.remove(waiter);
      return false;
    });
  }

  @override
  Future<bool> awaitAck(HostAckKind kind, Duration timeout) => _waitFor(
        (signal, a, _) => signal == _SignalKind.ack && a == kind.index,
        timeout,
      );

  /// Waits for a surface to be attached, by either mechanism, into [slot].
  @override
  Future<bool> awaitSurfaceAttached(int slot, Duration timeout) => _waitFor(
        (signal, _, attachedSlot) =>
            (signal == _SignalKind.surfaceAttached ||
                signal == _SignalKind.surfacePortAttached) &&
            attachedSlot == slot,
        timeout,
      );

  @override
  Future<bool> awaitPresented(int sequence, Duration timeout) => _waitFor(
        (signal, presented, _) =>
            signal == _SignalKind.presented && presented == sequence,
        timeout,
      );

  void _notify(_SignalKind kind, int a, int b) {
    // The common case is an input event with nobody waiting. Returning here
    // keeps the hot path free of iterator allocation.
    if (_waiters.isEmpty) return;
    for (var index = _waiters.length - 1; index >= 0; index--) {
      final waiter = _waiters[index];
      if (!waiter.test(kind, a, b)) continue;
      _waiters.removeAt(index);
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(kind != _SignalKind.exited);
      }
    }
  }

  // --- HostMessageSink -------------------------------------------------------

  @override
  void onHandshake(HostHandshakeField field, int value) {
    switch (field) {
      case HostHandshakeField.mainThread:
        _sawMainThread = value == 1;
      case HostHandshakeField.windowNumber:
        _windowNumber = value;
      case HostHandshakeField.protocolVersion:
        _protocolVersion = value;
      case HostHandshakeField.hostPid:
        _hostPid = value;
      case HostHandshakeField.renderScaleMilli:
        if (value > 0) _renderScaleMilli = value;
    }
    _maybeCompleteHandshake();
    _sink.onHandshake(field, value);
  }

  @override
  void onProtocolFeatures(String features) {
    _features = features;
    _sink.onProtocolFeatures(features);
  }

  /// `HOST_PID` is the last line of the banner, so its arrival is the signal.
  /// Checking the other three explicitly rather than counting lines means a
  /// reordered banner still works and a truncated one still fails.
  void _maybeCompleteHandshake() {
    if (_handshake.isCompleted) return;
    if (!_sawMainThread || _windowNumber == 0 || _hostPid == 0) return;
    if (_protocolVersion == 0) return;
    final banner = MacosHostHandshake(
      windowNumber: _windowNumber,
      hostPid: _hostPid,
      protocolVersion: _protocolVersion,
      features: _features,
      renderScale: _renderScaleMilli / 1000,
    );
    _completedHandshake = banner;
    _handshake.complete(banner);
  }

  @override
  void onWindowEvent(
    HostWindowEventKind kind,
    double a,
    double b,
    double c,
    double d,
  ) =>
      _sink.onWindowEvent(kind, a, b, c, d);

  @override
  void onInput(
    HostInputKind kind,
    double x,
    double y,
    int keyCode,
    int machTime,
  ) =>
      _sink.onInput(kind, x, y, keyCode, machTime);

  @override
  void onViewInput(HostInputKind kind, double x, double y) =>
      _sink.onViewInput(kind, x, y);

  @override
  void onAck(HostAckKind kind, int value) {
    if (kind == HostAckKind.notMainThread) {
      // The one banner answer that is fatal on its own: a host that is not on
      // thread 0 has thrown away the guarantee this backend was chosen for.
      _onDiagnostic(
        const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleVersion,
          message: 'macOS host reported MAIN_THREAD=0',
          detail: 'AppKit requires the first thread of the process; a host '
              'that does not own it cannot be trusted with a window',
        ),
      );
    }
    _notify(_SignalKind.ack, kind.index, value);
    _sink.onAck(kind, value);
  }

  @override
  void onSurfaceAttached(int surfaceId, int slot) {
    _notify(_SignalKind.surfaceAttached, surfaceId, slot);
    _sink.onSurfaceAttached(surfaceId, slot);
  }

  @override
  void onSurfacePortAttached(HostSurfaceMechanism mechanism, int slot) {
    _notify(_SignalKind.surfacePortAttached, mechanism.index, slot);
    _sink.onSurfacePortAttached(mechanism, slot);
  }

  @override
  void onPresented(int sequence, int slot, HostPresentTransport transport) {
    _notify(_SignalKind.presented, sequence, slot);
    _sink.onPresented(sequence, slot, transport);
  }

  @override
  void onError(String code) {
    _onDiagnostic(
      BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'macOS host reported an error',
        detail: code,
      ),
    );
    _notify(_SignalKind.error, 0, 0);
    _sink.onError(code);
  }

  @override
  void onUnrecognised(String line) {
    _onDiagnostic(
      BackendDiagnostic.note('unrecognised macOS host output', detail: line),
    );
    _sink.onUnrecognised(line);
  }
}
