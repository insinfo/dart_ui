/// The workloads the leak suite repeats.
///
/// Every cycle here is something this framework does over and over in a real
/// session and that hands back operating-system resources when it is done. The
/// selection is deliberately short: a cycle nobody can trust is worse than a
/// cycle nobody wrote, because it produces a number that gets quoted.
///
/// ## Nothing here appears on screen and nothing here makes a sound
///
/// Every window is created with `visible: false`, which
/// `Win32Window.create` honours by simply not calling `ShowWindow` - the HWND,
/// its window class, its device context and its DIB section are all created
/// exactly as they would be for a visible window, which is the whole point.
/// The audio backends are not exercised at all.
///
/// ## Why these and not the others
///
/// `--cycle window` and `--cycle resize` are the two that motivated the suite:
/// a surface is destroyed and rebuilt on **every** resize (`Win32Window
/// ._rebuildSurface`), which means a `CreateCompatibleDC` and a
/// `CreateDIBSection` per drag step, and the generation token in
/// `window_host.dart` exists precisely because frames outlive the surface they
/// were begun against. That is where a GDI leak would be, and GDI is the
/// counter nothing in this repository was reading.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_cpu_presenter.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/video/video_frame_ring_buffer.dart';
import 'package:dart_ui/src/platform/native_window.dart';

/// One repeatable unit of work.
abstract interface class LeakCycle {
  /// The `--cycle` name.
  String get name;

  /// One line for the report header.
  String get description;

  /// Dart classes whose live instance count is worth watching for this cycle.
  ///
  /// Named rather than "everything", because an allocation profile has some
  /// three thousand classes in it and a report listing all of them is a report
  /// nobody reads. A class that is not here is not covered by class A for this
  /// cycle, which the roadmap says out loud.
  Set<String> get watchedClasses;

  /// Runs once before any cycle and is not measured.
  Future<void> setUp();

  /// One cycle. Everything it acquires it must give back.
  Future<void> runOnce(int index);

  /// Runs once after the last cycle and is not measured.
  Future<void> tearDown();
}

/// Creating a top-level window and destroying it.
///
/// The whole chain: `CreateWindowExW`, a device context, a DIB section, a Dart
/// `Win32Window` with a stream and a registry entry, then `DestroyWindow` and
/// `dispose`. One HWND, one or more USER objects and several GDI objects per
/// cycle, all of which must come back.
final class WindowOpenCloseCycle implements LeakCycle {
  WindowOpenCloseCycle();

  Win32WindowingBackend? _backend;

  @override
  String get name => 'window';

  @override
  String get description => 'create a hidden top-level window and destroy it';

  @override
  Set<String> get watchedClasses => const <String>{
        'Win32Window',
        'Win32DibSurface',
        'DisposableBag',
        'GenerationToken',
      };

  @override
  Future<void> setUp() async {
    // The backend is set up once and torn down once: registering and
    // unregistering a window class per cycle would measure `RegisterClassExW`,
    // which an application does exactly once, and would hide the per-window
    // cost under it.
    final Win32WindowingBackend backend = Win32WindowingBackend();
    await backend.initialize();
    _backend = backend;
  }

  @override
  Future<void> runOnce(int index) async {
    final Win32WindowingBackend backend = _backend!;
    final NativeWindow window = await backend.createWindow(
      const WindowOptions(
        title: 'leak suite',
        size: Size(320, 240),
        visible: false,
      ),
    );
    // Pumped before the close so the window has processed its own WM_CREATE
    // and WM_SIZE, which is what allocates the DIB section. Closing before
    // that would measure a window that never had a surface.
    backend.pumpEvents();
    window.close();
    backend.pumpEvents();
    window.dispose();
    // WM_NCDESTROY arrives after DestroyWindow returns, and the registry entry
    // that keeps an HWND resolvable is dropped there. Not pumping here would
    // leave one entry per cycle in `Win32WindowRegistry` and report a leak the
    // application would never see.
    backend.pumpEvents();
  }

  @override
  Future<void> tearDown() async {
    await _backend?.shutdown();
    _backend = null;
  }
}

/// Resizing one window over and over.
///
/// The surface is destroyed and rebuilt on every size change, so this is a
/// `CreateCompatibleDC` + `CreateDIBSection` + `SelectObject` per cycle against
/// a `DeleteDC` + `DeleteObject`. The window itself is created once, so any
/// slope belongs to the surface and not to the HWND.
final class WindowResizeCycle implements LeakCycle {
  WindowResizeCycle();

  Win32WindowingBackend? _backend;
  Win32Window? _window;

  @override
  String get name => 'resize';

  @override
  String get description =>
      'resize one hidden window, rebuilding its DIB surface each time';

  @override
  Set<String> get watchedClasses => const <String>{
        'Win32DibSurface',
        'DisposableBag',
      };

  @override
  Future<void> setUp() async {
    final Win32WindowingBackend backend = Win32WindowingBackend();
    await backend.initialize();
    _backend = backend;
    _window = await backend.createWindow(
      const WindowOptions(
        title: 'leak suite',
        size: Size(400, 300),
        visible: false,
      ),
    ) as Win32Window;
    backend.pumpEvents();
  }

  @override
  Future<void> runOnce(int index) async {
    final Win32Window window = _window!;
    // Two sizes alternating rather than a monotonically growing one: a window
    // that grew every cycle would grow its DIB every cycle too, and the bytes
    // it committed would look exactly like a leak. Alternating between two
    // sizes means a clean run returns to the same footprint every second
    // cycle, which is the only way the byte counters mean anything here.
    final double width = index.isEven ? 400 : 520;
    final double height = index.isEven ? 300 : 380;
    window.setBounds(Rect.fromLTWH(0, 0, width, height));
    _backend!.pumpEvents();
  }

  @override
  Future<void> tearDown() async {
    _window?.dispose();
    _window = null;
    await _backend?.shutdown();
    _backend = null;
  }
}

/// Presenting a CPU display list into a window's DIB, over and over.
///
/// The per-frame path: record a display list, rasterise it into the DIB, blit.
/// Nothing here should retain anything between frames, and the display list is
/// deliberately rebuilt each cycle rather than reset, so a retained reference
/// to a previous frame's list shows up as heap growth.
final class CpuPresentCycle implements LeakCycle {
  CpuPresentCycle();

  Win32WindowingBackend? _backend;
  Win32Window? _window;
  Win32CpuPresenter? _presenter;

  @override
  String get name => 'present';

  @override
  String get description => 'rasterise and blit a CPU display list per cycle';

  @override
  Set<String> get watchedClasses => const <String>{
        'DisplayList',
        'Win32DibSurface',
      };

  @override
  Future<void> setUp() async {
    final Win32WindowingBackend backend = Win32WindowingBackend();
    await backend.initialize();
    _backend = backend;
    final Win32Window window = await backend.createWindow(
      const WindowOptions(
        title: 'leak suite',
        size: Size(400, 300),
        visible: false,
      ),
    ) as Win32Window;
    backend.pumpEvents();
    _window = window;
    _presenter = Win32CpuPresenter(window);
  }

  @override
  Future<void> runOnce(int index) async {
    final DisplayList list = DisplayList();
    final int paint = list.addPaint(colorArgb: 0xFF3060C0 + (index & 0xFF));
    for (var i = 0; i < 32; i++) {
      final double offset = (i * 7 + index).toDouble() % 200;
      list.drawRect(offset, offset, offset + 40, offset + 30, paint);
    }
    _presenter!.renderDisplayListNow(list, clearColor: 0xFF101010);
    _backend!.pumpEvents();
  }

  @override
  Future<void> tearDown() async {
    _presenter?.dispose();
    _presenter = null;
    _window?.dispose();
    _window = null;
    await _backend?.shutdown();
    _backend = null;
  }
}

/// Opening and closing a native video frame ring.
///
/// Pure class B: one native block of `slotCount * bytesPerSlot`, plus the
/// borrow bookkeeping. The leases are acquired and released inside the cycle
/// because a missed `release()` in this class does not grow anything - the ring
/// starves and throws - and a suite that only watched bytes would call that
/// clean.
final class VideoFrameRingCycle implements LeakCycle {
  VideoFrameRingCycle();

  @override
  String get name => 'video-ring';

  @override
  String get description =>
      'allocate a native video frame ring, borrow every slot, release, free';

  @override
  Set<String> get watchedClasses => const <String>{
        'NativeVideoFrameRing',
        'NativeVideoFrameLease',
      };

  @override
  Future<void> setUp() async {}

  @override
  Future<void> runOnce(int index) async {
    final NativeVideoFrameRing ring = NativeVideoFrameRing(
      slotCount: 4,
      bytesPerSlot: 64 * 1024,
    );
    try {
      final List<NativeVideoFrameLease> held = <NativeVideoFrameLease>[];
      for (var i = 0; i < 4; i++) {
        final NativeVideoFrameLease? lease = ring.acquire();
        if (lease == null) break;
        final Uint8List bytes = lease.bytes;
        bytes[0] = index & 0xFF;
        held.add(lease);
      }
      for (final NativeVideoFrameLease lease in held) {
        lease.release();
      }
    } finally {
      ring.dispose();
    }
  }

  @override
  Future<void> tearDown() async {}
}

/// Filling and releasing a [NativeArena].
///
/// The smallest possible class B workload and the one that proves the
/// accounting itself: a fixed number of blocks in, the same number out. If this
/// cycle shows a slope, the counters are wrong, not the framework.
final class NativeArenaCycle implements LeakCycle {
  NativeArenaCycle();

  @override
  String get name => 'arena';

  @override
  String get description =>
      'allocate a scope of native blocks and release them all';

  @override
  Set<String> get watchedClasses => const <String>{'NativeArena'};

  @override
  Future<void> setUp() async {}

  @override
  Future<void> runOnce(int index) async {
    using((NativeArena arena) {
      arena.allocateUtf16('leak suite cycle $index');
      arena.allocateUtf8('leak suite cycle $index');
      arena.allocateAscii('cycle');
      arena.allocateOutPointer();
      arena.allocate<Uint8>(4096);
    });
  }

  @override
  Future<void> tearDown() async {}
}

/// Does nothing at all, on purpose.
///
/// The suite is a program, and a program that runs N times allocates N times:
/// it keeps one reading per cycle by design, it decodes a VM Service reply per
/// cycle, and the JIT compiles its own paths on the way through. All of that
/// lands on the same Dart heap the framework's objects are on, so a total-heap
/// number can never be zero however clean the framework is.
///
/// This cycle measures exactly that floor and nothing else. Its `dart heap
/// bytes` slope is the suite's own cost per cycle, and every other workload's
/// heap slope has to be read against it - which is why it runs first by
/// default. The per-class instance counters do not have this problem: the
/// suite allocates no `Win32Window`.
final class IdleCycle implements LeakCycle {
  IdleCycle();

  @override
  String get name => 'idle';

  @override
  String get description =>
      "does nothing; measures the suite's own cost per cycle";

  @override
  Set<String> get watchedClasses => const <String>{};

  @override
  Future<void> setUp() async {}

  @override
  Future<void> runOnce(int index) async {}

  @override
  Future<void> tearDown() async {}
}

/// Every cycle this suite knows, by name.
Map<String, LeakCycle Function()> get availableCycles =>
    <String, LeakCycle Function()>{
      // First, because its heap slope is the floor under every other one's.
      'idle': IdleCycle.new,
      'window': WindowOpenCloseCycle.new,
      'resize': WindowResizeCycle.new,
      'present': CpuPresentCycle.new,
      'video-ring': VideoFrameRingCycle.new,
      'arena': NativeArenaCycle.new,
    };
