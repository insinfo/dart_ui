/// The black window during a resize, pinned at the message that causes it.
///
/// The user-visible bug: drag a window border and the area the window grew
/// into stays black until the mouse is released. The cause is not slowness. It
/// is that `WM_ENTERSIZEMOVE` puts Windows into a modal loop of its own, and
/// until `WM_EXITSIZEMOVE` the call to `DispatchMessageW` never returns - so
/// the Dart event loop, where every listener of every window event lives, does
/// not run at all. `WM_SIZE` arrives, a `WindowResizedEvent` is queued on a
/// broadcast stream nobody is draining, and the frame that would have filled
/// the new pixels is drawn after the drag.
///
/// That makes this file's shape mandatory. A test that resized a window and
/// then awaited a turn of the event loop would be testing the path that already
/// worked; the assertion has to be that pixels are produced **without** the
/// event loop running, which means the whole sequence is driven through the
/// real `WndProc` of a real HWND with no `await` in the middle of it.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:dart_ui/dart_ui.dart'
    hide PlatformWindowEvent, Size, WindowOptions, WindowResizedEvent;
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_cpu_presenter.dart';
import 'package:dart_ui/src/backends/win32/win32_structs.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

/// One `WM_SIZE` lParam: height in the high word, width in the low word.
int _size(int width, int height) =>
    ((height & 0xFFFF) << 16) | (width & 0xFFFF);

void main() {
  group('the modal resize loop', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late List<PlatformWindowEvent> events;
    late StreamSubscription<PlatformWindowEvent> subscription;

    Future<Win32Window> open(WindowOptions options) async {
      final opened = await backend.createWindow(options) as Win32Window;
      events = <PlatformWindowEvent>[];
      subscription = opened.events.listen(events.add);
      return opened;
    }

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      window = await open(const WindowOptions(
        title: 'live resize',
        size: Size(200, 120),
        visible: false,
      ));
    });

    tearDown(() async {
      await subscription.cancel();
      window.close();
      await backend.shutdown();
    });

    /// The whole gesture, exactly as the OS delivers it, with **no** turn of
    /// the Dart event loop anywhere inside it. That is the point: during a real
    /// drag there is no such turn to be had.
    void drag(List<(int, int)> sizes) {
      window.handleMessage(window.handle, wmEntersizemove, 0, 0);
      for (final (int width, int height) in sizes) {
        window.handleMessage(
          window.handle,
          wmSize,
          sizeRestored,
          _size(width, height),
        );
      }
      window.handleMessage(window.handle, wmExitsizemove, 0, 0);
    }

    test('WM_ENTERSIZEMOVE and WM_EXITSIZEMOVE bracket the loop', () {
      expect(window.isLiveResizing, isFalse);
      window.handleMessage(window.handle, wmEntersizemove, 0, 0);
      expect(
        window.isLiveResizing,
        isTrue,
        reason: 'without this flag the window cannot tell a resize inside the '
            'modal loop - where nothing else will run - from one outside it, '
            'where the ordinary frame loop works',
      );
      window.handleMessage(window.handle, wmExitsizemove, 0, 0);
      expect(window.isLiveResizing, isFalse);
    });

    test('a drag draws nothing when no live-resize callback is installed',
        () async {
      // The state this backend shipped in, and the behaviour
      // ApplicationOptions.liveResize: false still selects. Every resize is
      // recorded and queued; not one pixel is produced during the drag.
      drag(<(int, int)>[(210, 130), (220, 140), (230, 150)]);
      expect(window.liveResizeFrames, 0);

      // The turn of the event loop the OS would not have given us. It is here,
      // *after* the drag, precisely to show what the queue was holding all
      // along: three resizes that nothing acted on while it mattered.
      await Future<void>.delayed(Duration.zero);
      expect(
        events.whereType<WindowResizedEvent>(),
        hasLength(3),
        reason: 'the events are queued, which is exactly the problem: nothing '
            'will drain this stream until the drag ends',
      );
    });

    test('a drag draws one frame per resize when a callback is installed', () {
      final sizes = <Size>[];
      window.setLiveResizeCallback(({
        required Size logicalSize,
        required double renderScale,
      }) {
        sizes.add(logicalSize);
      });

      drag(<(int, int)>[(210, 130), (220, 140), (230, 150)]);

      expect(
        window.liveResizeFrames,
        3,
        reason: 'remove the call to _drawLiveResizeFrame from _onSize and this '
            'is 0 - which is the black window the user reported',
      );
      expect(sizes, hasLength(3));
      expect(
        sizes.last.width * window.renderScale,
        closeTo(230, 1),
        reason: 'the callback is handed the size that has *just* been adopted, '
            'not the one on the queued event nobody has read',
      );
    });

    test('a resize outside the modal loop is left to the frame loop', () async {
      // Maximise, snap, a programmatic setBounds: `DispatchMessageW` returns
      // for all of them, so the ordinary asynchronous path runs and a
      // synchronous frame would only be a second, uncoalesced one.
      var called = 0;
      window.setLiveResizeCallback(({
        required Size logicalSize,
        required double renderScale,
      }) {
        called++;
      });

      window.handleMessage(
          window.handle, wmSize, sizeRestored, _size(300, 200));

      expect(called, 0);
      expect(window.liveResizeFrames, 0);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<WindowResizedEvent>(), hasLength(1));
    });

    test('a frame that resizes the window again does not start a second frame',
        () {
      // Not hypothetical: layout can call SetWindowPos, and Windows sends
      // WM_SIZE from inside it - synchronously, on this stack. A second frame
      // on top of the first is the reentrancy ManualDispatcher throws on, and a
      // throw here would cross the FFI boundary into the WndProc.
      var depth = 0;
      var maxDepth = 0;
      window.setLiveResizeCallback(({
        required Size logicalSize,
        required double renderScale,
      }) {
        depth++;
        maxDepth = depth > maxDepth ? depth : maxDepth;
        if (depth == 1) {
          window.handleMessage(
            window.handle,
            wmSize,
            sizeRestored,
            _size(400, 300),
          );
        }
        depth--;
      });

      drag(<(int, int)>[(210, 130)]);

      expect(
        maxDepth,
        1,
        reason: 'remove the _inLiveFrame guard and this is 2: a frame drawing '
            'inside a frame, against a surface the outer one is still holding',
      );
      expect(window.liveResizeFrames, 1);
      expect(
        window.liveResizeFramesSuppressed,
        1,
        reason: 'the refused message is counted, or "the guard worked" and '
            '"nothing asked" would look identical',
      );
      expect(
        window.pixelSize.width,
        400,
        reason: 'the inner resize is still adopted - it is refused a frame, '
            'not ignored - so the outer frame finishes against the new size',
      );
    });

    test('every resize bumps the generation, so a stale frame is refusable',
        () {
      final generations = <int>[];
      window.setLiveResizeCallback(({
        required Size logicalSize,
        required double renderScale,
      }) {
        generations.add(window.generation);
      });

      final int before = window.generation;
      drag(<(int, int)>[(210, 130), (220, 140)]);

      expect(generations, hasLength(2));
      expect(generations.first, isNot(before));
      expect(
        generations.last,
        isNot(generations.first),
        reason:
            'a drag replaces the surface on every message, so a frame begun '
            'one message ago describes a DIB that has already been freed',
      );
      expect(window.isCurrent(before), isFalse);
      expect(window.isCurrent(generations.last), isTrue);
    });

    test('the callback can be removed again', () {
      var called = 0;
      window.setLiveResizeCallback(({
        required Size logicalSize,
        required double renderScale,
      }) {
        called++;
      });
      drag(<(int, int)>[(210, 130)]);
      expect(called, 1);

      window.setLiveResizeCallback(null);
      drag(<(int, int)>[(220, 140)]);
      expect(
        called,
        1,
        reason: 'teardown clears the callback before the HWND is destroyed, '
            'and a resize after that must not reach a half-disposed tree',
      );
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');

  group('WM_ERASEBKGND paints the strip a resize exposed', () {
    late Win32WindowingBackend backend;
    late Win32Window window;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
    });

    tearDown(() async {
      window.close();
      await backend.shutdown();
    });

    test('the answer is still 1, so nothing else may erase', () async {
      window = await backend.createWindow(const WindowOptions(
        title: 'erase',
        size: Size(200, 120),
        visible: false,
      )) as Win32Window;

      expect(
        window.handleMessage(window.handle, wmErasebkgnd, 0, 0),
        1,
        reason: 'returning 0 would let DefWindowProcW erase with the class '
            'brush over the whole update region - the full-window flash the '
            'class comment refuses',
      );
    });

    test('a window has a brush, so the strip is never uninitialised memory',
        () async {
      window = await backend.createWindow(const WindowOptions(
        title: 'erase',
        size: Size(200, 120),
        visible: false,
        backgroundColor: 0xFF203040,
      )) as Win32Window;

      expect(
        window.backgroundBrush,
        isNot(0),
        reason: 'with no brush and hbrBackground = 0 on the class, nobody '
            'paints the newly exposed area at all, and what shows there is '
            'whatever was in video memory - black, in the report',
      );
    });

    test('the painted rectangle is what a present sets, not what a resize sets',
        () async {
      window = await backend.createWindow(const WindowOptions(
        title: 'erase',
        size: Size(200, 120),
        visible: false,
      )) as Win32Window;

      expect(
        window.paintedPixelSize.width,
        0,
        reason: 'nothing has drawn yet, so the whole client area is up for '
            'erasing',
      );

      expect(window.present(), isNull);
      final ({int width, int height}) painted = window.paintedPixelSize;
      expect(painted.width, window.pixelSize.width);
      expect(painted.height, window.pixelSize.height);

      // Growing does not move it: that is the whole mechanism. The strip
      // between the old painted size and the new client size is what the erase
      // fills, and it stops being filled the moment a frame covers it.
      window.handleMessage(
        window.handle,
        wmSize,
        sizeRestored,
        _size(painted.width + 60, painted.height + 40),
      );
      expect(window.paintedPixelSize.width, painted.width);
      expect(window.pixelSize.width, painted.width + 60);

      expect(window.present(), isNull);
      expect(window.paintedPixelSize.width, painted.width + 60);
    });

    test('growing paints the strip, and only the strip', () async {
      window = await backend.createWindow(const WindowOptions(
        title: 'erase',
        size: Size(200, 120),
        visible: false,
      )) as Win32Window;
      expect(window.present(), isNull);

      final int before = window.backgroundFills;
      final ({int width, int height}) size = window.pixelSize;

      window.handleMessage(
        window.handle,
        wmSize,
        sizeRestored,
        _size(size.width + 40, size.height + 30),
      );
      expect(
        window.backgroundFills,
        before + 1,
        reason: 'this is the fix. WM_SIZE is the last code of ours that runs '
            'before the user sees the bigger window, and without a fill here '
            'the strip shows uninitialised video memory - the reported black',
      );

      // Now cover it, and a further resize that only *shrinks* has nothing to
      // expose and must not repaint anything.
      expect(window.present(), isNull);
      final int covered = window.backgroundFills;
      window.handleMessage(
        window.handle,
        wmSize,
        sizeRestored,
        _size(size.width, size.height),
      );
      expect(
        window.backgroundFills,
        covered,
        reason: 'a shrink exposes nothing; filling anyway would be a flash of '
            'flat colour over pixels the framebuffer already owns',
      );
    });

    test('a live-resize frame covers the strip, so nothing is filled under it',
        () async {
      window = await backend.createWindow(const WindowOptions(
        title: 'erase',
        size: Size(200, 120),
        visible: false,
      )) as Win32Window;
      expect(window.present(), isNull);
      // A callback that draws, which is what the shell installs.
      window.setLiveResizeCallback(({
        required Size logicalSize,
        required double renderScale,
      }) {
        window.present();
      });

      final int before = window.backgroundFills;
      window.handleMessage(window.handle, wmEntersizemove, 0, 0);
      window.handleMessage(
        window.handle,
        wmSize,
        sizeRestored,
        _size(320, 240),
      );
      window.handleMessage(window.handle, wmExitsizemove, 0, 0);

      expect(
        window.backgroundFills,
        before,
        reason: 'filling first and drawing over it would put a frame of flat '
            'colour under every frame of the drag',
      );
      expect(window.paintedPixelSize.width, 320);
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');

  group('WM_GETMINMAXINFO', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late Win32Api api;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      api = Win32Api.load().api!;
    });

    tearDown(() async {
      window.close();
      await backend.shutdown();
    });

    /// Sends the message with a real MINMAXINFO and returns what came back.
    ({({int x, int y}) min, ({int x, int y}) max}) ask(Win32Window window) {
      final info = api.allocator<MinMaxInfo>();
      try {
        info.ref.ptMinTrackSize
          ..x = 1
          ..y = 1;
        info.ref.ptMaxTrackSize
          ..x = 99999
          ..y = 99999;
        expect(
          window.handleMessage(
            window.handle,
            wmGetminmaxinfo,
            0,
            info.address,
          ),
          0,
          reason: 'the answer is the structure; the return value is always 0',
        );
        return (
          min: (x: info.ref.ptMinTrackSize.x, y: info.ref.ptMinTrackSize.y),
          max: (x: info.ref.ptMaxTrackSize.x, y: info.ref.ptMaxTrackSize.y),
        );
      } finally {
        api.allocator.free(info);
      }
    }

    test('a window with no bounds leaves every default alone', () async {
      window = await backend.createWindow(const WindowOptions(
        title: 'minmax',
        size: Size(200, 120),
        visible: false,
      )) as Win32Window;

      final answer = ask(window);
      expect(
        <int>[answer.min.x, answer.min.y],
        <int>[1, 1],
        reason: 'writing a minimum nobody asked for would be worse than not '
            'handling the message: it would silently override the platform',
      );
      expect(<int>[answer.max.x, answer.max.y], <int>[99999, 99999]);
    });

    test('a minimum is honoured, in window pixels including the frame',
        () async {
      window = await backend.createWindow(const WindowOptions(
        title: 'minmax',
        size: Size(400, 300),
        visible: false,
        minimumSize: Size(320, 240),
      )) as Win32Window;

      final answer = ask(window);
      final double scale = window.renderScale;
      expect(
        answer.min.x,
        greaterThanOrEqualTo((320 * scale).round()),
        reason: 'without the frame added, a 320-logical minimum would leave a '
            'client area narrower than 320 - the caption and borders eat it',
      );
      expect(answer.min.y, greaterThanOrEqualTo((240 * scale).round()));
      expect(
        answer.min.x,
        lessThan((320 * scale).round() + 200),
        reason: 'and the frame is a frame, not a second window',
      );
      expect(
        <int>[answer.max.x, answer.max.y],
        <int>[99999, 99999],
        reason: 'a minimum with no maximum must not cap the maximum',
      );
    });

    test('a maximum is honoured too', () async {
      window = await backend.createWindow(const WindowOptions(
        title: 'minmax',
        size: Size(400, 300),
        visible: false,
        maximumSize: Size(640, 480),
      )) as Win32Window;

      final answer = ask(window);
      final double scale = window.renderScale;
      expect(answer.max.x, greaterThanOrEqualTo((640 * scale).round()));
      expect(answer.max.x, lessThan((640 * scale).round() + 200));
      expect(<int>[answer.min.x, answer.min.y], <int>[1, 1]);
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');

  group('a whole application through a drag', () {
    late Application application;

    Future<Application> start({required bool liveResize}) async {
      application = await Application.start(
        rootWidget: const ColoredBox(color: Color(0xFF3060A0)),
        backends: <WindowingBackendEntry>[
          const WindowingBackendEntry(
            name: 'win32',
            create: Win32WindowingBackend.new,
          ),
        ],
        presentations: <PresentationPathEntry>[
          PresentationPathEntry.retainedCpu(
            name: 'win32-dib',
            deviceDescription: 'GDI DIB section, BGRA8888 top-down',
            create: (NativeWindow window) {
              final presenter = Win32CpuPresenter(window as Win32Window);
              return (
                present: presenter.renderDisplayList,
                presentNow: presenter.renderDisplayListNow,
                release: presenter.dispose,
              );
            },
          ),
        ],
        options: ApplicationOptions(
          title: 'drag',
          size: const Size(240, 160),
          clearColor: const Color(0xFF101010),
          liveResize: liveResize,
        ),
      );
      // One ordinary frame first: a drag never starts from an unmounted tree,
      // and mounting one is not what this measures.
      await application.drawFrame();
      return application;
    }

    tearDown(() async {
      application.dispose();
      await application.closed;
    });

    /// The drag, with **no** `await` inside it. Everything that happens here
    /// happens on the stack of a native handler.
    int dragSynchronously(Win32Window window, int steps) {
      final int before = application.framesPresented;
      window.handleMessage(window.handle, wmEntersizemove, 0, 0);
      for (var step = 1; step <= steps; step++) {
        window.handleMessage(
          window.handle,
          wmSize,
          sizeRestored,
          _size(240 + step * 4, 160 + step * 3),
        );
      }
      window.handleMessage(window.handle, wmExitsizemove, 0, 0);
      return application.framesPresented - before;
    }

    test('presents a frame per resize message with live resize on', () async {
      await start(liveResize: true);
      final window = application.window as Win32Window;

      final int drawn = dragSynchronously(window, 5);

      expect(
        drawn,
        5,
        reason: 'these frames were presented from inside WM_SIZE, without one '
            'turn of the Dart event loop - which is the only kind of frame the '
            'OS gives a chance to during a border drag',
      );
      expect(application.framesRejected, 0);
      expect(application.errors, isEmpty);
      // And the tree really was laid out against the last size, not merely
      // blitted at it.
      expect(application.host.logicalSize.width * window.renderScale,
          closeTo(260, 1));
    });

    test('presents nothing during the drag with live resize off', () async {
      await start(liveResize: false);
      final window = application.window as Win32Window;

      expect(
        dragSynchronously(window, 5),
        0,
        reason: 'this is the reported bug, and it is what the option turns off '
            'deliberately: the queued resize events are drawn after the drag',
      );

      // The work is not lost, only deferred - the frame arrives on the turn of
      // the event loop the OS refused to allow.
      await Future<void>.delayed(Duration.zero);
      await application.drawPendingFrames();
      expect(application.errors, isEmpty);
      expect(application.framesPresented, greaterThan(1));
    });

    test('a drag never leaves a frame in flight', () async {
      await start(liveResize: true);
      final window = application.window as Win32Window;
      dragSynchronously(window, 8);

      // `_inFrame` is cleared in a `finally`, and the whole reason
      // drawFrameSynchronously exists is that `drawFrame`'s `finally` is on the
      // far side of an await that a modal loop never reaches. If it leaked, the
      // next ordinary frame would be refused for the rest of the process.
      final result = await application.drawFrame();
      expect(result.isSuccess, isTrue);
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');
}
