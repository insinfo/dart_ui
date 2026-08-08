import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';
import 'package:poc_20_macos_three_backends/src/mach_port_transfer.dart';

// ---------------------------------------------------------------------------
// Which mach-port handoff still works on this machine?
//
// Three mechanisms, one host, one surface created WITHOUT kIOSurfaceIsGlobal -
// so a success cannot be the deprecated lookup path in disguise. The probe
// never fails the job on a mechanism saying no: "bootstrap_register is refused
// on macOS 15" is a result, not a broken build. It fails only if the host does
// not start, or if the deprecated fallback stopped working.
// ---------------------------------------------------------------------------

class _Host {
  _Host(this.process);

  final Process process;
  final List<String> lines = <String>[];

  /// One cursor for the whole run, not one per wait: the probe is strictly
  /// sequential, and a per-call cursor would let the ERROR= line from a
  /// mechanism that already failed satisfy the wait for the next one.
  int _cursor = 0;

  static Future<_Host> start(String binary) async {
    final process = await Process.start(binary, const ['--command-stdin']);
    final host = _Host(process);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      host.lines.add(line);
      stdout.writeln('HOST| $line');
    });
    unawaited(process.stderr.transform(utf8.decoder).forEach(stderr.write));
    return host;
  }

  /// Always flushed: the host reads with fgets, so a command left in Dart's
  /// sink is a command the host never sees and a wait that only times out.
  Future<void> send(String command) async {
    process.stdin.writeln(command);
    await process.stdin.flush();
  }

  Future<String?> waitFor(bool Function(String line) match,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      while (_cursor < lines.length) {
        final line = lines[_cursor++];
        if (match(line)) return line;
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return null;
  }

  /// Every attach ends in exactly one of these two, so one wait covers both
  /// and a timeout means the host never answered at all.
  Future<String?> waitForAttach(String mechanism) => waitFor((line) =>
      line.startsWith('SURFACE_PORT_OK $mechanism') ||
      line.startsWith('ERROR=SURFACE_PORT:'));
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('usage: surface_port_probe <host-binary>');
    exitCode = 64;
    return;
  }

  final surface = IOSurfaceFrame.create(width: 480, height: 320, global: false);
  surface.fillBgra(0x20, 0xC0, 0x40);
  final port = surface.createMachPort();
  print('PROBE_SURFACE_GLOBAL=${surface.isGlobal ? 1 : 0}');
  print('PROBE_SURFACE_PORT=$port');

  // (a) has to happen before the spawn: the kernel copies the registered-port
  // array into a task when it creates it, and never again.
  final handoff = MachPortTransfer.registerInHighestFreeSlot(port);
  print('PROBE_REGISTERED_SLOT=${handoff.slot}');
  print('PROBE_REGISTERED_STATUS=${handoff.status}');
  print('PROBE_REGISTERED_MASK_BEFORE=${handoff.before.occupancyMask}');
  print('PROBE_REGISTERED_MASK_AFTER=${handoff.after.occupancyMask}');

  // (b) has no ordering constraint but is the one most likely to be refused
  // outright, so its status is printed whether or not the host is up yet.
  final bootstrapName = 'dart-ui.poc20.s.$pid';
  final bootstrapStatus =
      MachPortTransfer.bootstrapRegister(bootstrapName, port);
  print('PROBE_BOOTSTRAP_NAME=$bootstrapName');
  print('PROBE_BOOTSTRAP_REGISTER=$bootstrapStatus');

  final host = await _Host.start(arguments.first);
  if (await host.waitFor((l) => l.startsWith('WINDOW_ID=')) == null) {
    stderr.writeln('host did not start');
    exitCode = 1;
    return;
  }

  // The reading that decides mechanism (a): if the mask lost the slot between
  // the registration above and here, libxpc overwrote the array during the
  // fork and the child was never going to see the port.
  final postSpawn = MachPortTransfer.lookupRegisteredPorts();
  print('PROBE_REGISTERED_MASK_POSTSPAWN=${postSpawn.occupancyMask}');

  final winners = <String>[];

  if (handoff.ok) {
    await host.send('SURFACE_PORT REGISTERED ${handoff.slot}');
    final line = await host.waitForAttach('registered');
    print('PROBE_REGISTERED_RESULT=${line ?? "timeout"}');
    if (line != null && line.startsWith('SURFACE_PORT_OK')) {
      winners.add('registered');
    }
  } else {
    print('PROBE_REGISTERED_RESULT=skipped');
  }

  if (bootstrapStatus == kernSuccess) {
    await host.send('SURFACE_PORT BOOTSTRAP $bootstrapName');
    final line = await host.waitForAttach('bootstrap');
    print('PROBE_BOOTSTRAP_RESULT=${line ?? "timeout"}');
    if (line != null && line.startsWith('SURFACE_PORT_OK')) {
      winners.add('bootstrap');
    }
  } else {
    print('PROBE_BOOTSTRAP_RESULT=skipped');
  }

  // (c) The host publishes the name, so its pid is what makes the name unique.
  final hostPidLine = await host.waitFor((l) => l.startsWith('HOST_PID='));
  final hostPid =
      hostPidLine == null ? pid : int.parse(hostPidLine.substring(9));
  final serviceName = 'dart-ui.poc20.r.$hostPid';
  await host.send('PORT_SERVER $serviceName');
  final checkIn = await host.waitFor((l) =>
      l.startsWith('PORT_SERVER_OK') ||
      l.startsWith('ERROR=SURFACE_PORT:PORT_SERVER'));
  print('PROBE_PORT_SERVER=${checkIn ?? "timeout"}');
  if (checkIn != null && checkIn.startsWith('PORT_SERVER_OK')) {
    // Send first, then tell the host to receive: the message queues on the
    // port, so there is no race to lose and no need to sequence them.
    final sendStatus = MachPortTransfer.rendezvousSend(serviceName, port, 0x51);
    print('PROBE_RENDEZVOUS_SEND=$sendStatus');
    if (sendStatus == kernSuccess) {
      await host.send('SURFACE_PORT RENDEZVOUS');
      final line = await host.waitForAttach('rendezvous');
      print('PROBE_RENDEZVOUS_RESULT=${line ?? "timeout"}');
      if (line != null && line.startsWith('SURFACE_PORT_OK')) {
        winners.add('rendezvous');
      }
    } else {
      print('PROBE_RENDEZVOUS_RESULT=skipped');
    }
  } else {
    print('PROBE_RENDEZVOUS_SEND=skipped');
    print('PROBE_RENDEZVOUS_RESULT=skipped');
  }

  print('SURFACE_PORT_WINNERS=${winners.isEmpty ? "none" : winners.join(",")}');

  // A mechanism that attached but cannot present is not a working mechanism.
  if (winners.isNotEmpty) {
    await host.send('PRESENT 1');
    final presented = await host.waitFor(
        (l) => l.startsWith('PRESENT_OK 1 ') || l.startsWith('ERROR='));
    print('SURFACE_PORT_PRESENT=${presented ?? "timeout"}');
  } else {
    print('SURFACE_PORT_PRESENT=skipped');
  }

  // The fallback has to still be the fallback. A second, global surface goes
  // through the deprecated path so a regression there is caught in the same
  // run that measures the replacement.
  final legacy = IOSurfaceFrame.create(width: 480, height: 320);
  legacy.fillBgra(0xC0, 0x20, 0x40);
  await host.send('SURFACE ${legacy.id}');
  final legacyAttach = await host.waitFor(
      (l) => l.startsWith('SURFACE_OK') || l == 'ERROR=SURFACE_LOOKUP');
  await host.send('PRESENT 2');
  final legacyPresent = await host
      .waitFor((l) => l.startsWith('PRESENT_OK 2 ') || l.startsWith('ERROR='));
  print('SURFACE_FALLBACK_ATTACH=${legacyAttach ?? "timeout"}');
  print('SURFACE_FALLBACK_PRESENT=${legacyPresent ?? "timeout"}');

  await host.send('CLOSE');
  await host.process.exitCode.timeout(const Duration(seconds: 5),
      onTimeout: () {
    host.process.kill();
    return -1;
  });
  surface.dispose();
  legacy.dispose();

  // Only the fallback breaking is a build failure. A mechanism refused by the
  // OS is the finding this probe exists to produce.
  if (legacyPresent != 'PRESENT_OK 2 surface') {
    stderr.writeln('deprecated SURFACE path regressed');
    exitCode = 1;
  }
}
