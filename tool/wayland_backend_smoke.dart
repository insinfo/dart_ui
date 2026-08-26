/// Production smoke test for the Wayland backend, against a real compositor.
///
/// This is the counterpart of `tool/x11_backend_smoke.dart`, and it exists for
/// one reason: every automated test of this backend runs against an in-memory
/// fake compositor. That fake decodes the client's bytes with the real wire
/// codec and synthesises events back, which is a good test and is *not* the
/// same thing as a compositor. Three layers have no coverage at all without a
/// real one:
///
/// - the libc FFI transport - `socket`/`connect`/`sendmsg`/`recvmsg`, the
///   hand-built `cmsghdr` that carries `SCM_RIGHTS` in both directions, and
///   the LP64 struct layouts it hard-codes;
/// - `memfd_create` + `ftruncate` + `mmap`, and whether the compositor
///   accepts the pool, stride and format the shm surface computes;
/// - the protocol itself. A fake accepts what it was written to accept. A
///   compositor answers a malformed request by killing the connection, so a
///   run that reaches the end is evidence the requests were well formed.
///
/// Every line it prints is a claim about what the compositor did, not about
/// what this process intended. Run it inside a Wayland session - CI runs it
/// under `weston --backend=headless`.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/wayland/wayland_backend.dart';
import 'package:dart_ui/src/backends/wayland/wayland_cpu_presenter.dart';
import 'package:dart_ui/src/backends/wayland/wayland_window.dart';

Future<void> main() async {
  if (!Platform.isLinux) {
    stderr.writeln(
      'WAYLAND_BACKEND_SMOKE=SKIP platform=${Platform.operatingSystem}',
    );
    exitCode = 2;
    return;
  }

  final backend = WaylandWindowingBackend();
  NativeWindow? window;
  Object? failure;
  StackTrace? failureStack;

  try {
    final probe = backend.probe();
    final probePassed = probe.supported &&
        probe.supports(Capability.window) &&
        probe.supports(Capability.cpuPresentation);
    stdout.writeln(
      'WAYLAND_BACKEND_PROBE=${probePassed ? 'PASS' : 'FAIL'} '
      'supported=${probe.supported} '
      'window=${probe.supports(Capability.window)} '
      'cpu=${probe.supports(Capability.cpuPresentation)}',
    );
    if (!probePassed) {
      // The diagnostics are the whole point of a failed probe: they name the
      // socket that was tried and the errno that stopped it.
      for (final diagnostic in backend.diagnostics) {
        stderr.writeln('  probe: ${diagnostic.message}');
      }
      throw StateError(probe.describe());
    }

    await backend.initialize().timeout(const Duration(seconds: 10));

    // What the registry advertised. Printed rather than asserted: the set is
    // a property of the compositor, and a smoke test that demanded GNOME's
    // list would fail on Weston for no good reason.
    final globals = backend.globalInterfaces.toList()..sort();
    stdout.writeln('WAYLAND_GLOBALS=${globals.join(',')}');
    for (final required in <String>['wl_compositor', 'wl_shm', 'xdg_wm_base']) {
      if (!globals.contains(required)) {
        throw StateError('compositor advertises no $required');
      }
    }

    window = await backend
        .createWindow(
          const WindowOptions(
            size: Size(320, 200),
            title: 'dart_ui Wayland production smoke',
          ),
        )
        .timeout(const Duration(seconds: 10));
    final waylandWindow = window as WaylandWindow;

    var exposed = false;
    var resized = false;
    final subscription = window.events.listen((event) {
      exposed |= event is WindowExposedEvent;
      resized |= event is WindowResizedEvent;
    });
    final presenter = WaylandCpuPresenter(waylandWindow);
    try {
      // The first xdg_surface.configure. Nothing local produces it: the
      // window commits an empty surface and waits, and this returning is the
      // compositor having answered.
      await _pumpUntil(
        backend,
        () => exposed && waylandWindow.cpuSurface != null,
        const Duration(seconds: 10),
        'xdg_surface.configure',
      );
      final initialSurface = waylandWindow.cpuSurface!;
      stdout.writeln(
        'WAYLAND_CONFIGURE=PASS '
        'size=${initialSurface.pixelWidth}x${initialSurface.pixelHeight} '
        'bufferScale=${initialSurface.bufferScale} '
        'generation=${initialSurface.generation} '
        'decorations=${waylandWindow.hasServerSideDecorations}',
      );

      final firstList = DisplayList();
      firstList.drawRect(
        0,
        0,
        320,
        200,
        firstList.addPaint(colorArgb: 0xffc06020),
      );
      final firstPresent = await presenter.renderDisplayList(
        firstList,
        clearColor: 0xff101010,
      );
      if (!firstPresent.isSuccess) throw StateError('$firstPresent');
      stdout.writeln(
        'WAYLAND_SHM_PRESENT=PASS format=ARGB8888 '
        'slots=${initialSurface.slotCount} '
        'busyReuse=${initialSurface.busyReuseCount}',
      );

      // The frame callback. This is the strongest single claim the tool can
      // make: `wl_surface.frame` only comes back when the compositor has
      // taken the committed buffer and is ready for the next frame, so it
      // proves the memfd travelled over SCM_RIGHTS, that the pool geometry
      // was accepted, and that the surface is actually being composited.
      if (!waylandWindow.isFrameThrottled) {
        throw StateError('present did not arm a frame callback');
      }
      await _pumpUntil(
        backend,
        () => !waylandWindow.isFrameThrottled,
        const Duration(seconds: 10),
        'wl_surface.frame callback',
      );
      stdout.writeln('WAYLAND_FRAME_CALLBACK=PASS throttled='
          '${waylandWindow.throttledFrameCount}');

      // Resize. On Wayland the client resizes itself by committing a buffer
      // of the new size, so this replaces the surface locally and then asks
      // the compositor to accept the new pool - a wrong stride or a stale
      // buffer is a protocol error that kills the connection.
      window.setBounds(const Rect.fromLTWH(0, 0, 360, 240));
      await _pumpUntil(
        backend,
        () => resized,
        const Duration(seconds: 5),
        'resize',
      );
      final resizedSurface = waylandWindow.cpuSurface;
      if (resizedSurface == null ||
          identical(resizedSurface, initialSurface) ||
          !initialSurface.isDisposed ||
          resizedSurface.generation != waylandWindow.generation) {
        throw StateError('resize did not replace the Wayland shm surface');
      }
      await presenter.idle;
      final secondList = DisplayList();
      secondList.drawRect(
        7.25,
        8.5,
        58.75,
        45.75,
        secondList.addPaint(colorArgb: 0xff103090),
      );
      final damagePresent = await presenter.renderDisplayList(
        secondList,
        clearColor: 0xff202020,
        damage: const Rect.fromLTWH(7.25, 8.5, 51.5, 37.25),
      );
      if (!damagePresent.isSuccess) throw StateError('$damagePresent');
      await _pumpUntil(
        backend,
        () => !waylandWindow.isFrameThrottled,
        const Duration(seconds: 10),
        'wl_surface.frame after resize',
      );
      stdout.writeln(
        'WAYLAND_RESIZE=PASS '
        'size=${resizedSurface.pixelWidth}x${resizedSurface.pixelHeight} '
        'generation=${resizedSurface.generation}',
      );
    } finally {
      await subscription.cancel();
      presenter.dispose();
    }

    _reportKeyboard(backend);
    await _reportClipboard(backend);

    if (!backend.pumpEvents(timeout: const Duration(milliseconds: 25))) {
      throw StateError('the compositor dropped the connection during the run');
    }
    stdout.writeln('WAYLAND_BACKEND_WINDOW=PASS id=${window.id.value}');
    window.close();
    if (backend.windows.isNotEmpty || backend.pumpEvents()) {
      throw StateError('closing the final Wayland window did not request quit');
    }
    backend.wake();
  } on Object catch (error, stack) {
    failure = error;
    failureStack = stack;
  }

  try {
    await backend.shutdown().timeout(const Duration(seconds: 10));
    if (backend.windows.isNotEmpty) {
      throw StateError('Wayland backend retained windows after shutdown');
    }
  } on Object catch (error, stack) {
    failure ??= error;
    failureStack ??= stack;
  }

  final capturedFailure = failure;
  if (capturedFailure != null) {
    Error.throwWithStackTrace(
      capturedFailure,
      failureStack ?? StackTrace.current,
    );
  }
  stdout.writeln('WAYLAND_BACKEND_SMOKE=PASS');
}

/// Reports whether `wl_keyboard.keymap` arrived, decoded and produced a map.
///
/// This is the only automated exercise of the receiving half of `SCM_RIGHTS`
/// anywhere in the repository. The compositor sends the xkb keymap as a file
/// descriptor riding in the ancillary data of a protocol message; the backend
/// has to pull it out of the `cmsghdr` it assembled by hand, `mmap` it
/// `MAP_PRIVATE`, and parse the text. A fake compositor cannot pass a real
/// descriptor, so nothing but a live session reaches this path.
void _reportKeyboard(WaylandWindowingBackend backend) {
  if (!backend.globalInterfaces.contains('wl_seat')) {
    // A compositor with no input devices advertises no seat, and without a
    // seat there is no `wl_keyboard` to send a keymap. Reported as SKIP
    // because nothing in this backend was exercised, let alone found wanting.
    stdout.writeln('WAYLAND_KEYBOARD=SKIP compositor advertises no wl_seat');
    return;
  }
  stdout.writeln(
    'WAYLAND_KEYBOARD=${backend.hasKeyboardMap ? 'PASS' : 'FAIL'} '
    'scm_rights_keymap=${backend.hasKeyboardMap}',
  );
}

/// Reports the clipboard, and says plainly when it could not be attempted.
///
/// Wayland grants the selection only to a client that owns a recent input
/// serial. A headless compositor with no input device never gives one, so
/// `SKIP` here is the protocol working as designed and not a defect; it is
/// reported rather than hidden because the difference between "refused for a
/// named reason" and "failed" is exactly what this tool is for.
Future<void> _reportClipboard(WaylandWindowingBackend backend) async {
  const String sample = 'dart_ui clipboard smoke';
  final Clipboard clipboard = backend.clipboard;
  if (clipboard is UnavailableClipboard) {
    stdout.writeln('WAYLAND_CLIPBOARD=SKIP no wl_data_device_manager');
    return;
  }
  try {
    await clipboard.writeText(sample).timeout(const Duration(seconds: 5));
    final String? read =
        await clipboard.readText().timeout(const Duration(seconds: 5));
    stdout.writeln(
      'WAYLAND_CLIPBOARD=${read == sample ? 'PASS' : 'FAIL'} '
      'owner=self roundtrip=${read == sample}',
    );
  } on ClipboardException catch (error) {
    // No input serial is the expected answer under a headless compositor.
    stdout.writeln('WAYLAND_CLIPBOARD=SKIP ${error.reason}');
  } on Object catch (error) {
    stdout.writeln('WAYLAND_CLIPBOARD=FAIL $error');
  }
}

Future<void> _pumpUntil(
  WaylandWindowingBackend backend,
  bool Function() predicate,
  Duration timeout,
  String eventName,
) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    backend.pumpEvents(timeout: const Duration(milliseconds: 25));
    await Future<void>.delayed(Duration.zero);
  }
  if (!predicate()) throw StateError('timed out waiting for $eventName');
}
