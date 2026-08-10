import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/macos/host_process.dart';
import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/host_supervisor.dart';
import 'package:dart_ui/src/backends/macos/io_surface.dart';
import 'package:dart_ui/src/backends/macos/surface_pool.dart';
import 'package:test/test.dart';

void main() {
  group('MacosHostSupervisor recovery', () {
    test('unexpected exit restarts with injected clock and backoff', () async {
      final first = _FakeHost(pid: 101, windowNumber: 1);
      final replacement = _FakeHost(pid: 202, windowNumber: 2);
      final hosts = <_FakeHost>[first, replacement];
      final delays = <Duration>[];
      var now = DateTime.utc(2026, 8, 9, 12);
      var starts = 0;
      final replaced = Completer<Duration>();

      final supervisor = _supervisor(
        starter: (options, sink, onDiagnostic) async {
          starts++;
          return hosts.removeAt(0);
        },
        clock: () => now,
        delay: (duration) async {
          delays.add(duration);
          now = now.add(duration);
        },
        onHostReplaced: (handshake, downtime) {
          expect(handshake, same(replacement.handshake));
          replaced.complete(downtime);
        },
      );

      expect(await supervisor.start(), isTrue);
      first.crash(-9);

      expect(await replaced.future, const Duration(milliseconds: 10));
      expect(supervisor.state, MacosSupervisorState.running);
      expect(supervisor.host, same(replacement));
      expect(supervisor.restartCount, 1);
      expect(starts, 2);
      expect(delays, <Duration>[const Duration(milliseconds: 10)]);
    });

    test('replays window state after attaching the replacement pool', () async {
      final first = _FakeHost(pid: 101, windowNumber: 1);
      final replacement = _FakeHost(pid: 202, windowNumber: 2);
      final hosts = <_FakeHost>[first, replacement];
      final pool = _pool();
      final attached = <(MacosHostProcessHandle, MacosSurfacePool)>[];
      final replaced = Completer<void>();

      final supervisor = _supervisor(
        starter: (options, sink, onDiagnostic) async => hosts.removeAt(0),
        poolAttacher: (host, candidate) async {
          attached.add((host, candidate));
          return true;
        },
        onHostReplaced: (handshake, downtime) => replaced.complete(),
      );

      expect(await supervisor.start(), isTrue);
      expect(await supervisor.attachPool(pool), isTrue);
      supervisor
        ..rememberTitle('Recovered window')
        ..rememberBounds(12, 34, 640, 480)
        ..rememberCursor('crosshair')
        ..rememberVisibility(false);

      first.crash(-9);
      await replaced.future;

      expect(
        replacement.commands,
        <String>[
          HostCommands.setTitle('Recovered window'),
          HostCommands.setBounds(12, 34, 640, 480),
          HostCommands.setCursor('crosshair'),
          HostCommands.hide(),
        ],
      );
      expect(attached.map((entry) => entry.$1), <Object>[first, replacement]);
      expect(attached.every((entry) => identical(entry.$2, pool)), isTrue);
      expect(supervisor.activeHandoff, MacosSurfaceHandoff.rendezvous);
    });

    test('preserves pixels and reattaches the same pool after a crash',
        () async {
      final first = _FakeHost(pid: 101, windowNumber: 1);
      final replacement = _FakeHost(pid: 202, windowNumber: 2);
      final hosts = <_FakeHost>[first, replacement];
      final surfaces = <_FakeSurface>[
        _FakeSurface(1),
        _FakeSurface(2),
      ];
      final pool = MacosSurfacePool(surfaces);
      final attachedPools = <MacosSurfacePool>[];
      final replaced = Completer<void>();

      final supervisor = _supervisor(
        starter: (options, sink, onDiagnostic) async => hosts.removeAt(0),
        poolAttacher: (host, candidate) async {
          attachedPools.add(candidate);
          return true;
        },
        onHostReplaced: (handshake, downtime) => replaced.complete(),
      );

      expect(await supervisor.start(), isTrue);
      expect(await supervisor.attachPool(pool), isTrue);
      final presentedSlot = pool.backSlot;
      pool.withBackBuffer((buffer) => buffer.pixels[0] = 0x7f);
      expect(pool.markPresented(presentedSlot), 1);

      first.crash(-9);
      await replaced.future;

      expect(attachedPools, hasLength(2));
      expect(attachedPools.every((candidate) => identical(candidate, pool)),
          isTrue);
      expect(pool.presentedSlot, -1);
      expect(pool.contentSequenceOf(presentedSlot), 1);
      expect(surfaces[presentedSlot].pixels[0], 0x7f);
      expect(pool.isDisposed, isFalse);
      expect(pool.surfaces[0], same(surfaces[0]));
      expect(pool.surfaces[1], same(surfaces[1]));
    });

    test('exhausts the configured retry budget deterministically', () async {
      final first = _FakeHost(pid: 101, windowNumber: 1);
      final delays = <Duration>[];
      var now = DateTime.utc(2026, 8, 9, 12);
      var starts = 0;
      final exhausted = Completer<void>();

      final supervisor = _supervisor(
        starter: (options, sink, onDiagnostic) async {
          starts++;
          return starts == 1 ? first : null;
        },
        policy: const MacosRecoveryPolicy(
          maxAttempts: 2,
          backoff: Duration(milliseconds: 5),
        ),
        clock: () => now,
        delay: (duration) async {
          delays.add(duration);
          now = now.add(duration);
        },
        onRecoveryExhausted: exhausted.complete,
      );

      expect(await supervisor.start(), isTrue);
      first.crash(70);
      await exhausted.future;

      expect(supervisor.state, MacosSupervisorState.failed);
      expect(supervisor.host, isNull);
      expect(supervisor.restartCount, 2);
      expect(starts, 3);
      expect(
        delays,
        <Duration>[
          const Duration(milliseconds: 5),
          const Duration(milliseconds: 10),
        ],
      );
    });

    test('serializes concurrent pool attaches on the same host', () async {
      final host = _FakeHost(pid: 101, windowNumber: 1);
      final firstMayFinish = Completer<void>();
      var calls = 0;
      var active = 0;
      var maximumActive = 0;
      final supervisor = _supervisor(
        starter: (options, sink, onDiagnostic) async => host,
        poolAttacher: (candidate, pool) async {
          calls++;
          active++;
          if (active > maximumActive) maximumActive = active;
          if (calls == 1) await firstMayFinish.future;
          active--;
          return true;
        },
      );

      expect(await supervisor.start(), isTrue);
      final first = supervisor.attachPool(_pool());
      while (calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final second = supervisor.attachPool(_pool());
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      expect(maximumActive, 1);
      firstMayFinish.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(calls, 2);
      expect(maximumActive, 1);
    });

    test('failed replacement attach schedules exactly one next recovery',
        () async {
      final first = _FakeHost(pid: 101, windowNumber: 1);
      final failedReplacement = _FakeHost(pid: 202, windowNumber: 2);
      final healthyReplacement = _FakeHost(pid: 303, windowNumber: 3);
      final hosts = <_FakeHost>[
        first,
        failedReplacement,
        healthyReplacement,
      ];
      var starts = 0;
      var attaches = 0;
      final replaced = Completer<void>();
      final supervisor = _supervisor(
        starter: (options, sink, onDiagnostic) async {
          starts++;
          return hosts.removeAt(0);
        },
        poolAttacher: (host, pool) async {
          attaches++;
          return !identical(host, failedReplacement);
        },
        onHostReplaced: (handshake, downtime) {
          expect(handshake, same(healthyReplacement.handshake));
          replaced.complete();
        },
      );

      expect(await supervisor.start(), isTrue);
      expect(await supervisor.attachPool(_pool()), isTrue);
      first.crash(-9);
      await replaced.future;

      expect(starts, 3);
      expect(attaches, 3);
      expect(supervisor.restartCount, 2);
      expect(supervisor.host, same(healthyReplacement));
    });
  });
}

MacosHostSupervisor _supervisor({
  required MacosHostStarter starter,
  MacosRecoveryPolicy policy = const MacosRecoveryPolicy(
    maxAttempts: 3,
    backoff: Duration(milliseconds: 10),
  ),
  DateTime Function()? clock,
  Future<void> Function(Duration duration)? delay,
  MacosSurfacePoolAttacher? poolAttacher,
  void Function(MacosHostHandshake handshake, Duration downtime)?
      onHostReplaced,
  void Function()? onRecoveryExhausted,
}) {
  return MacosHostSupervisor(
    spawnOptions: const MacosHostSpawnOptions(
      binaryPath: '/not-used-by-the-fake',
      logicalWidth: 640,
      logicalHeight: 480,
    ),
    sink: _Sink(),
    onDiagnostic: (diagnostic) {},
    onHostReplaced: onHostReplaced ?? (handshake, downtime) {},
    onRecoveryExhausted: onRecoveryExhausted ?? () {},
    policy: policy,
    starter: starter,
    clock: clock,
    delay: delay ?? (duration) async {},
    poolAttacher: poolAttacher,
  );
}

MacosSurfacePool _pool() => MacosSurfacePool(
      <MacosPoolSurface>[
        _FakeSurface(1),
        _FakeSurface(2),
      ],
    );

final class _FakeHost implements MacosHostProcessHandle {
  _FakeHost({required this.pid, required int windowNumber})
      : handshake = MacosHostHandshake(
          windowNumber: windowNumber,
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

  @override
  Future<int> get exitStatus => _exited.future;

  void crash(int status) {
    exitReason = MacosHostExitReason.unexpected;
    _exited.complete(status);
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

final class _FakeSurface implements MacosPoolSurface {
  _FakeSurface(this.id)
      : pixels = Uint8List(4 * 4 * 4),
        bytesPerRow = 4 * 4;

  @override
  final int id;

  @override
  final int width = 4;

  @override
  final int height = 4;

  @override
  final int bytesPerRow;

  final Uint8List pixels;

  @override
  bool isDisposed = false;

  @override
  int createMachPort() => id + 1000;

  @override
  void dispose() => isDisposed = true;

  @override
  void withPixels(void Function(Uint8List pixels) write) => write(pixels);
}

final class _Sink with HostMessageSinkAdapter {}
