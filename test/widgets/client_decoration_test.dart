/// The title bar and borders a window draws when the window system will not.
///
/// Each case drives [ClientDecorationFrame] through a fake
/// [ClientDecoratedWindow] and checks the request that reached the window,
/// since the moving and resizing themselves belong to the compositor.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('ClientDecorationFrame', () {
    test('draws nothing while the system decorates the window', () {
      final _FakeWindow window = _FakeWindow(decorated: false);
      final List<Offset> presses = <Offset>[];
      final _Harness harness = _Harness(_frame(window, presses));

      harness.click(const Offset(200, 2));

      // The press at the very top reached the application: no bar, no border.
      expect(presses, <Offset>[const Offset(200, 2)]);
      expect(window.moves, 0);
      expect(window.resizes, isEmpty);
      harness.dispose();
    });

    test('the caption buttons minimise, maximise and close', () {
      final _FakeWindow window = _FakeWindow(decorated: true);
      final _Harness harness = _Harness(_frame(window, <Offset>[]));

      harness.click(const Offset(377, 16));
      expect(window.closeRequests, 1);

      harness.click(const Offset(333, 16));
      expect(window.isMaximized, isTrue);
      harness.click(const Offset(333, 16));
      expect(window.isMaximized, isFalse);

      harness.click(const Offset(288, 16));
      expect(window.minimizes, 1);
      harness.dispose();
    });

    test('dragging the title bar starts a compositor move', () {
      final _FakeWindow window = _FakeWindow(decorated: true);
      final _Harness harness = _Harness(_frame(window, <Offset>[]));

      harness.pointer(_down(const Offset(100, 16)));
      harness.pointer(_move(const Offset(160, 40)));

      expect(window.moves, 1);
      harness.dispose();
    });

    test('the bar takes presses above the content', () {
      final _FakeWindow window = _FakeWindow(decorated: true);
      final List<Offset> presses = <Offset>[];
      final _Harness harness = _Harness(_frame(window, presses));

      harness.click(const Offset(200, 20));
      harness.click(const Offset(200, 150));

      expect(presses, <Offset>[const Offset(200, 150)]);
      harness.dispose();
    });

    test('a press on an edge or corner starts a resize from it', () {
      final _FakeWindow window = _FakeWindow(decorated: true);
      final _Harness harness = _Harness(_frame(window, <Offset>[]));

      harness.click(const Offset(200, 298));
      harness.click(const Offset(398, 150));
      harness.click(const Offset(1, 1));
      harness.click(const Offset(398, 298));

      expect(window.resizes, <WindowResizeEdge>[
        WindowResizeEdge.bottom,
        WindowResizeEdge.right,
        WindowResizeEdge.topLeft,
        WindowResizeEdge.bottomRight,
      ]);
      harness.dispose();
    });

    test('a maximised window has no borders to resize', () {
      final _FakeWindow window = _FakeWindow(decorated: true)
        ..isMaximized = true;
      final List<Offset> presses = <Offset>[];
      final _Harness harness = _Harness(_frame(window, presses));

      harness.click(const Offset(200, 298));

      expect(window.resizes, isEmpty);
      expect(presses, hasLength(1));
      harness.dispose();
    });

    test('the bar appears when the compositor declines to decorate', () {
      // The order a real compositor answers in: the window maps undecorated
      // as far as anyone knows, then the decoration configure arrives.
      final _FakeWindow window = _FakeWindow(decorated: false);
      final List<Offset> presses = <Offset>[];
      final _Harness harness = _Harness(_frame(window, presses));

      window.clientDecorations.value = true;
      harness.frame();
      harness.click(const Offset(377, 16));

      expect(window.closeRequests, 1);
      expect(presses, isEmpty);

      window.clientDecorations.value = false;
      harness.frame();
      harness.click(const Offset(377, 16));

      expect(window.closeRequests, 1);
      expect(presses, <Offset>[const Offset(377, 16)]);
      harness.dispose();
    });
  });
}

Widget _frame(_FakeWindow window, List<Offset> presses) =>
    ClientDecorationFrame(
      window: window,
      child: PointerListener(
        onPointerDown: (PointerDownEvent e) => presses.add(e.logicalPosition),
        child: const SizedBox(width: 400, height: 300),
      ),
    );

final class _FakeWindow implements ClientDecoratedWindow {
  _FakeWindow({required bool decorated})
      : clientDecorations = ValueNotifier<bool>(decorated);

  @override
  final ValueNotifier<bool> clientDecorations;

  @override
  String get title => 'Fake';

  @override
  bool isMaximized = false;

  int moves = 0;
  int minimizes = 0;
  int closeRequests = 0;
  final List<WindowResizeEdge> resizes = <WindowResizeEdge>[];

  @override
  bool beginMove() {
    moves++;
    return true;
  }

  @override
  bool beginResize(WindowResizeEdge edge) {
    resizes.add(edge);
    return true;
  }

  @override
  void minimize() => minimizes++;

  @override
  void setMaximized(bool maximized) => isMaximized = maximized;

  @override
  void requestClose() => closeRequests++;
}

final class _Harness {
  _Harness(Widget widget, {Size size = const Size(400, 300)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
    owner.updateRoot(widget);
    frame();
  }

  late final BuildOwner owner;

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  bool pointer(PointerEvent event) => owner.dispatchPointerEvent(event);

  void click(Offset at) {
    pointer(_down(at));
    pointer(_up(at));
    frame();
  }

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerMoveEvent _move(Offset at) => PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );
