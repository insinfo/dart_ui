# dart_sdk_isolate_event_loop

Standalone reproductions for two Dart SDK issues:

- [dart-lang/sdk#64229](https://github.com/dart-lang/sdk/issues/64229): `Isolate.onEvent` / `Isolate.handleEvent` for external event loops, plus the `NativeCallable.isolateGroupBound` follow-up asked for there.
- [dart-lang/sdk#64230](https://github.com/dart-lang/sdk/issues/64230): servicing the isolate event loop from inside a native frame.

The package has no dependencies, no C code and no build step. Every probe uses only `dart:ffi` against the C runtime (`qsort`, `malloc`, `pthread_*`, or `CreateThread` on Windows). It runs the same way on Linux, macOS and Windows:

```text
git clone https://github.com/insinfo/dart_ui.git
cd dart_ui/repro/dart_sdk_isolate_event_loop
dart pub get
dart run bin/run_all.dart
# on a dev SDK, also:
dart run bin/run_all.dart --vm-flag=--experimental-shared-data
```

`run_all.dart` runs each case in a fresh VM under a watchdog. A case that hangs is killed and reported as `HANG`. If it printed its result first and then never exited, it is reported as `HANG_AT_EXIT`. The CI workflow [`sdk_isolate_repro.yml`](https://github.com/insinfo/dart_ui/blob/main/.github/workflows/sdk_isolate_repro.yml) runs the whole matrix: Linux, macOS arm64 and Windows, against 3.13.3 stable and dev.

## Probes

| File | Issue | What it does |
|---|---|---|
| `bin/nested_callback_probe.dart` | #64230 | Arms a 50 ms periodic timer, then calls `qsort` with a Dart comparator that blocks for 1500 ms on the isolate's own thread. It counts how many ticks are delivered while the comparator is on the stack. |
| `bin/on_event_probe.dart` | #64229 | Calls `Isolate.current.onEvent =`, `handleEvent()` and `Isolate.create()` from an ordinary `main`. |
| `bin/group_bound_trivial_probe.dart` | #64229 | Starts a foreign OS thread on a `NativeCallable.isolateGroupBound` start routine that only writes a marker. The main isolate waits either in a native join (`--wait=blocking`) or idle in its event loop (`--wait=async`). |
| `bin/group_bound_create_probe.dart` | #64229 | Same thread setup, but the callback calls `Isolate.create`, and with `--shutdown` also calls `shutdownSync()` on the created isolate. |

The group-bound callback touches no Dart static. Its only channel back is an `Int32` slot passed as the thread argument.

## Results on Windows 11 x64, 23 September 2026

| Case | 3.13.3 stable | 3.14.0-248.0.dev | dev + `--experimental-shared-data` |
|---|---|---|---|
| nested_callback | 0 of ~30 ticks delivered | 0 of ~30 | 0 of ~30 |
| on_event | both throw `UnsupportedError` | API not public | API not public |
| group_bound trivial, async or blocking | completes | **VM abort** in `NativeCallable.isolateGroupBound` (`ffi.cc:169`) | completes |
| group_bound create, async or blocking | `Isolate.create` **succeeds**, then the VM **hangs at exit** waiting for the created isolate to check in | API not public | API not public |
| group_bound create + `shutdownSync` | completes and exits | API not public | API not public |

For Linux and macOS, see the step summary of the workflow run.
