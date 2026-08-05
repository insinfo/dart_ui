import 'dart:io';

import 'package:poc_09_wayland/wayland_probe.dart';

void main(List<String> args) {
  print('------------------------------------------------');
  print('  POC-09: Wayland Client via FFI (Linux)        ');
  print('  No C/C++ wrapper, just dart:ffi + libwayland  ');
  print('------------------------------------------------\n');

  if (!Platform.isLinux) {
    print('Error: POC-09 only runs on Linux. Validation is performed in the '
        'ubuntu-24.04 job of `POC Tests` under a Weston headless backend.');
    exit(1);
  }

  final result = runWaylandProbe(width: 320, height: 240);

  print('\n--- POC-09 Wayland summary ---');
  print('  connected             : ${result.connected}');
  print('  registry created      : ${result.registryCreated}');
  print('  listeners installed   : ${result.listenersInstalled}');
  print('  registry drained      : ${result.registryDrained}');
  print('  compositor bound      : ${result.compositorBound}');
  print('  shm bound             : ${result.shmBound}');
  print('  surface created       : ${result.surfaceCreated}');
  print('  pool allocated        : ${result.poolAllocated}');
  print('  buffer committed      : ${result.bufferCommitted}');
  print('  disposed cleanly      : ${result.disposed}');
  print('  globals seen          : ${result.globalNames.length}');
  if (result.diagnostic != null) {
    print('  diagnostic            : ${result.diagnostic}');
  }

  final allPassed = result.connected &&
      result.registryCreated &&
      result.listenersInstalled &&
      result.registryDrained &&
      result.compositorBound &&
      result.shmBound &&
      result.surfaceCreated &&
      result.poolAllocated &&
      result.bufferCommitted &&
      result.disposed;

  final smokeTest = args.contains('--smoke-test');
  if (smokeTest && !result.connected) {
    print('[POC-09] Smoke-test mode: '
        'compositor unreachable — exiting cleanly (CI skips when Weston is down).');
    exit(0);
  }
  if (!allPassed && !smokeTest) {
    exit(1);
  }
  exit(0);
}