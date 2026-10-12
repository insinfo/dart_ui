import 'dart:async';

import 'package:dart_ui/src/backends/macos/host_process.dart';
import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/host_supervisor.dart';
import 'package:dart_ui/src/backends/macos/spare_host.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:test/test.dart';

void main() {
  late _Launches launches;

  setUp(() => launches = _Launches());

  MacosHostSpawnOptions popup({
    double? x,
    double? y,
    String binaryPath = 'host',
    MacosHostWindowKind kind = MacosHostWindowKind.popup,
    bool decorated = false,
    bool resizable = false,
  }) =>
      MacosHostSpawnOptions(
        binaryPath: binaryPath,
        logicalWidth: 220,
        logicalHeight: 190,
        x: x,
        y: y,
        visible: false,
        decorated: decorated,
        resizable: resizable,
        kind: kind,
      );

  test('a spare is launched hidden, as an undecorated popup panel', () async {
    final MacosSpareHost? spare = await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start);

    expect(spare, isNotNull);
    final MacosHostSpawnOptions options = launches.options.single;
    expect(options.kind, MacosHostWindowKind.popup);
    expect(options.visible, isFalse);
    expect(options.decorated, isFalse);
    expect(options.resizable, isFalse);
    expect(options.binaryPath, 'host');
  });

  test('a failed launch is no spare, not an error', () async {
    final MacosSpareHost? spare = await MacosSpareHost.launch(
      binaryPath: 'host',
      starter: (_, __, ___) async => null,
    );
    expect(spare, isNull);
  });

  test('nothing reaches a window before adoption, and everything after it',
      () async {
    final MacosSpareHost spare = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;
    final HostMessageSink relay = launches.sinks.single;
    final _RecordingSink window = _RecordingSink();

    // What the hidden panel reports on its own, before any window exists: a
    // resize to the placeholder size must not become this window's size.
    relay.onWindowEvent(HostWindowEventKind.resized, 64, 64, 1, 0);
    relay.onInput(HostInputKind.pointerMove, 1, 2, 0, 0);

    expect(spare.adopt(popup(), window, (_) {}), isNotNull);
    expect(window.events, isEmpty);

    relay.onWindowEvent(HostWindowEventKind.resized, 220, 190, 1, 0);
    relay.onInput(HostInputKind.pointerDown, 3, 4, 0, 0);
    expect(window.events, <String>['resized 220.0x190.0', 'input pointerDown']);
  });

  test('adoption resizes the placeholder to the size the window asked for',
      () async {
    final MacosSpareHost spare = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;
    // Where AppKit put the hidden panel, reported before adoption.
    launches.sinks.single
        .onWindowEvent(HostWindowEventKind.moved, 860, 250, 0, 0);

    spare.adopt(popup(), _RecordingSink(), (_) {});

    expect(launches.hosts.single.commands, <String>[
      HostCommands.setBounds(860, 250, 220, 190),
    ]);
  });

  test('a requested position wins over where the panel was', () async {
    final MacosSpareHost spare = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;
    launches.sinks.single
        .onWindowEvent(HostWindowEventKind.moved, 860, 250, 0, 0);

    spare.adopt(popup(x: 676, y: 494), _RecordingSink(), (_) {});

    expect(launches.hosts.single.commands, <String>[
      HostCommands.setBounds(676, 494, 220, 190),
    ]);
  });

  group('only a host that could have been launched for the request', () {
    late MacosSpareHost spare;

    setUp(() async {
      spare = (await MacosSpareHost.launch(
          binaryPath: 'host', starter: launches.start))!;
    });

    for (final (String name, MacosHostSpawnOptions Function() options)
        in <(String, MacosHostSpawnOptions Function())>[
      ('a normal window', () => popup(kind: MacosHostWindowKind.normal)),
      // Ignores the mouse, which is fixed at launch.
      ('a tooltip', () => popup(kind: MacosHostWindowKind.tooltip)),
      ('a decorated popup', () => popup(decorated: true)),
      ('a resizable popup', () => popup(resizable: true)),
      ('another binary', () => popup(binaryPath: 'other')),
    ]) {
      test('is not adopted as $name, and stays available', () {
        expect(spare.matches(options()), isFalse);
        expect(spare.adopt(options(), _RecordingSink(), (_) {}), isNull);
        expect(spare.isAvailable, isTrue);
        expect(launches.hosts.single.commands, isEmpty);
      });
    }
  });

  test('a spare that exited is not adopted', () async {
    final MacosSpareHost spare = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;
    launches.hosts.single.crash();
    await pumpEventQueue();

    expect(spare.isAvailable, isFalse);
    expect(spare.adopt(popup(), _RecordingSink(), (_) {}), isNull);
  });

  test('a spare is adopted once', () async {
    final MacosSpareHost spare = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;

    expect(spare.adopt(popup(), _RecordingSink(), (_) {}), isNotNull);
    expect(spare.adopt(popup(), _RecordingSink(), (_) {}), isNull);
  });

  test('the starter adopts first and launches on recovery', () async {
    final MacosSpareHost spare = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;
    final _FakeHost spareHost = launches.hosts.single;
    final MacosHostStarter starter =
        adoptingStarter(spare, fallback: launches.start);

    final MacosHostProcessHandle? first =
        await starter(popup(), _RecordingSink(), (_) {});
    final MacosHostProcessHandle? second =
        await starter(popup(), _RecordingSink(), (_) {});

    expect(identical(first, spareHost), isTrue);
    expect(identical(second, spareHost), isFalse);
    expect(launches.hosts, hasLength(2),
        reason: 'the replacement after a crash has to be a fresh launch');
  });

  test('the starter falls back when the spare cannot be adopted', () async {
    final MacosSpareHost spare = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;
    final MacosHostStarter starter =
        adoptingStarter(spare, fallback: launches.start);

    final MacosHostProcessHandle? host =
        await starter(popup(decorated: true), _RecordingSink(), (_) {});

    expect(identical(host, launches.hosts.first), isFalse);
    expect(launches.hosts, hasLength(2));
  });

  test('dispose closes an idle spare and leaves an adopted one alone',
      () async {
    final MacosSpareHost idle = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;
    final MacosSpareHost adopted = (await MacosSpareHost.launch(
        binaryPath: 'host', starter: launches.start))!;
    adopted.adopt(popup(), _RecordingSink(), (_) {});

    await idle.dispose();
    await adopted.dispose();

    expect(launches.hosts[0].closed, isTrue);
    expect(launches.hosts[1].closed, isFalse,
        reason: 'that process is a window now, and the window owns it');
  });
}

final class _Launches {
  final List<MacosHostSpawnOptions> options = <MacosHostSpawnOptions>[];
  final List<HostMessageSink> sinks = <HostMessageSink>[];
  final List<_FakeHost> hosts = <_FakeHost>[];

  Future<MacosHostProcessHandle?> start(
    MacosHostSpawnOptions spawnOptions,
    HostMessageSink sink,
    void Function(BackendDiagnostic diagnostic) onDiagnostic,
  ) async {
    options.add(spawnOptions);
    sinks.add(sink);
    final _FakeHost host = _FakeHost(hosts.length + 1);
    hosts.add(host);
    return host;
  }
}

final class _RecordingSink with HostMessageSinkAdapter {
  final List<String> events = <String>[];

  @override
  void onWindowEvent(
    HostWindowEventKind kind,
    double a,
    double b,
    double c,
    double d,
  ) =>
      events.add('${kind.name} ${a}x$b');

  @override
  void onInput(
    HostInputKind kind,
    double x,
    double y,
    int keyCode,
    int machTime,
  ) =>
      events.add('input ${kind.name}');
}

final class _FakeHost implements MacosHostProcessHandle {
  _FakeHost(this.pid)
      : handshake = MacosHostHandshake(
          windowNumber: 100 + pid,
          hostPid: pid,
          protocolVersion: 4,
          features: 'surface-port',
        );

  @override
  final int pid;

  @override
  final MacosHostHandshake handshake;

  @override
  MacosHostExitReason exitReason = MacosHostExitReason.none;

  final List<String> commands = <String>[];
  final Completer<int> _exited = Completer<int>();
  bool closed = false;

  @override
  Future<int> get exitStatus => _exited.future;

  void crash() {
    exitReason = MacosHostExitReason.unexpected;
    _exited.complete(-11);
  }

  @override
  bool send(String command) {
    if (_exited.isCompleted) return false;
    commands.add(command);
    return true;
  }

  @override
  Future<bool> awaitAck(HostAckKind kind, Duration timeout) async => true;

  @override
  Future<bool> awaitSurfaceAttached(int slot, Duration timeout) async => true;

  @override
  Future<bool> awaitPresented(int sequence, Duration timeout) async => true;

  @override
  Future<int> close({Duration timeout = const Duration(seconds: 5)}) {
    closed = true;
    exitReason = MacosHostExitReason.requested;
    if (!_exited.isCompleted) _exited.complete(0);
    return _exited.future;
  }

  @override
  Future<int> kill() {
    exitReason = MacosHostExitReason.unexpected;
    if (!_exited.isCompleted) _exited.complete(-9);
    return _exited.future;
  }
}
