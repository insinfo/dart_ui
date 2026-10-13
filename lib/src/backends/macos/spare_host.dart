/// A popup host launched before anybody asks for one.
///
/// On this backend every window is its own AppKit process (ADR 0001), and the
/// process is almost all of what opening a window costs. Measured on a Mac M4
/// with macOS 27.2, from `Process.start` to the last handshake line:
///
/// | step | ms |
/// |---|---|
/// | `exec` returns | ~3 |
/// | `applicationDidFinishLaunching:` (first banner line) | ~55 |
/// | the rest of the handshake | < 0.1 |
///
/// and `tool/popup_window_smoke.dart` put a whole menu open at 66 ms median
/// here and 53.5 ms on the `macos-14` runner, against 7.29 ms for the same
/// open on Windows. Nothing in Dart can make AppKit launch faster, so the
/// launch is moved off the critical path instead: once a popup has been
/// opened, one hidden popup host is kept waiting, and the next popup adopts
/// it.
///
/// ## What adopting means
///
/// The spare is an ordinary [MacosHostProcess] whose sink is a relay. Until
/// adoption the relay drops everything except where the hidden panel is, so
/// the spare cannot deliver a resize or an input event to a window that does
/// not exist yet. Adoption points the relay at the new window's sink and
/// sends one `SET_BOUNDS` with the size the window was asked for, because the
/// spare was launched at a placeholder size: a caller that creates a popup
/// and shows it without placing it would otherwise get a 64-point square.
///
/// Only a host whose launch arguments could have produced the requested
/// window is adopted ([matches]). The kind is fixed at launch - it decides
/// `NSPanel` against `NSWindow`, the activation policy and whether the window
/// ignores the mouse - and so are the decoration and resizability masks.
library;

import 'dart:async';

import '../../foundation/diagnostics.dart';
import 'host_process.dart';
import 'host_protocol.dart';
import 'host_supervisor.dart';

/// The placeholder size a spare is launched at. Replaced at adoption.
const double kMacosSpareHostPlaceholderSize = 64;

/// One hidden popup host, ready to become a window.
final class MacosSpareHost {
  MacosSpareHost._(this.binaryPath, this._relay, this._host) {
    unawaited(_host.exitStatus.then((_) => _exited = true));
  }

  /// Launches a spare popup host, or returns null when the launch failed.
  ///
  /// [starter] is [MacosHostProcess.start] in production; tests pass a fake.
  /// A failure is not reported anywhere but the result: the caller falls back
  /// to launching on demand, which is what it did before spares existed.
  static Future<MacosSpareHost?> launch({
    required String binaryPath,
    MacosHostStarter starter = MacosHostProcess.start,
  }) async {
    final relay = _RelaySink();
    final MacosHostProcessHandle? host = await starter(
      MacosHostSpawnOptions(
        binaryPath: binaryPath,
        logicalWidth: kMacosSpareHostPlaceholderSize,
        logicalHeight: kMacosSpareHostPlaceholderSize,
        title: 'dart_ui popup',
        visible: false,
        decorated: false,
        resizable: false,
        kind: MacosHostWindowKind.popup,
      ),
      relay,
      relay.diagnostic,
    );
    if (host == null) return null;
    return MacosSpareHost._(binaryPath, relay, host);
  }

  /// The binary the spare runs. A spare from another binary is not adopted.
  final String binaryPath;

  final _RelaySink _relay;
  final MacosHostProcessHandle _host;
  bool _exited = false;
  bool _adopted = false;

  /// Whether the process is still there and nobody has taken it.
  bool get isAvailable => !_exited && !_adopted;

  /// Whether a window asked for with [options] could be this host.
  bool matches(MacosHostSpawnOptions options) =>
      options.binaryPath == binaryPath &&
      options.kind == MacosHostWindowKind.popup &&
      !options.decorated &&
      !options.resizable;

  /// Hands the process to a window: from here on [sink] receives its events.
  ///
  /// Returns null when the spare can no longer be adopted - it exited, or it
  /// was already taken - so the caller launches a host as it would have
  /// without one.
  MacosHostProcessHandle? adopt(
    MacosHostSpawnOptions options,
    HostMessageSink sink,
    void Function(BackendDiagnostic diagnostic) onDiagnostic,
  ) {
    if (!isAvailable || !matches(options)) return null;
    _adopted = true;
    _relay
      ..target = sink
      ..onDiagnostic = onDiagnostic;
    // Where the caller asked, or where the hidden panel already is. Either
    // way the size is the requested one, which the placeholder is not.
    _host.send(HostCommands.setBounds(
      options.x ?? _relay.lastX,
      options.y ?? _relay.lastY,
      options.logicalWidth,
      options.logicalHeight,
    ));
    return _host;
  }

  /// Closes a spare nobody adopted. Does nothing to one that was adopted:
  /// that process belongs to its window now.
  Future<void> dispose() async {
    if (_adopted || _exited) return;
    _adopted = true;
    await _host.close();
  }
}

/// Builds a [MacosHostStarter] that adopts [spare] on its first call and
/// launches normally on every later one.
///
/// Later calls are host recovery: the adopted process died and the supervisor
/// wants a replacement, which has to be a fresh launch because the spare is
/// gone.
MacosHostStarter adoptingStarter(
  MacosSpareHost spare, {
  MacosHostStarter fallback = MacosHostProcess.start,
}) {
  var first = true;
  return (options, sink, onDiagnostic) async {
    if (first) {
      first = false;
      final MacosHostProcessHandle? adopted =
          spare.adopt(options, sink, onDiagnostic);
      if (adopted != null) return adopted;
    }
    return fallback(options, sink, onDiagnostic);
  };
}

/// Forwards to [target] once there is one, and remembers the panel's position
/// until then.
final class _RelaySink with HostMessageSinkAdapter {
  HostMessageSink? target;
  void Function(BackendDiagnostic diagnostic)? onDiagnostic;

  /// The last `WINDOW=MOVED` the hidden panel reported, in top-left-origin
  /// screen points. Used as the position of an adoption that names none.
  double lastX = 0;
  double lastY = 0;

  void diagnostic(BackendDiagnostic value) => onDiagnostic?.call(value);

  @override
  void onWindowEvent(
    HostWindowEventKind kind,
    double a,
    double b,
    double c,
    double d,
  ) {
    final HostMessageSink? sink = target;
    if (sink != null) {
      sink.onWindowEvent(kind, a, b, c, d);
    } else if (kind == HostWindowEventKind.moved) {
      lastX = a;
      lastY = b;
    }
  }

  @override
  void onInput(
    HostInputKind kind,
    double x,
    double y,
    int keyCode,
    int machTime,
  ) =>
      target?.onInput(kind, x, y, keyCode, machTime);

  @override
  void onViewInput(HostInputKind kind, double x, double y) =>
      target?.onViewInput(kind, x, y);

  @override
  void onInputDetail(HostInputDetail detail) => target?.onInputDetail(detail);

  @override
  void onMenuAction(int generation, int id) =>
      target?.onMenuAction(generation, id);

  @override
  void onTextInput(String base64) => target?.onTextInput(base64);

  @override
  void onComposition(String base64, int selectedLocation, int selectedLength) =>
      target?.onComposition(base64, selectedLocation, selectedLength);

  @override
  void onCommit(String base64) => target?.onCommit(base64);

  @override
  void onDragItem(String kind, String base64) =>
      target?.onDragItem(kind, base64);

  @override
  void onDrag(HostDragPhase phase, double x, double y, int mask, int flags) =>
      target?.onDrag(phase, x, y, mask, flags);
}
