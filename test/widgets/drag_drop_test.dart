/// Routing a platform drag to the widget under it, headlessly.
///
/// Everything here is real except the platform: the render tree, the hit test
/// and the enter/leave diffing are the ones a Win32 or XDND drag drives, and
/// the events are built by hand with the coordinates a backend would have
/// converted. That is the whole point of the split - the part that needs a
/// mouse and a second application is `Win32DropTarget`, and the part that
/// decides *which widget* is this.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('DragRouter', () {
    test('the deepest target under the pointer wins', () {
      final _Harness harness = _Harness(
        child: _target(
          key: 'outer',
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      final DropResponse response = harness.owner.dispatchDragUpdate(
        _event(const Offset(10, 10)),
      );

      expect(response.isAccepted, isTrue);
      expect(response.acceptedFormat, DragFormats.uriList);
      expect(harness.owner.activeDropTarget, isNotNull);
      expect(harness.find<RenderDropTarget>()!.isDragOver, isTrue);
    });

    test('a point outside every target is refused', () {
      final _Harness harness = _Harness(
        child: Align(
          alignment: Alignment.topLeft,
          child: _target(child: const SizedBox(width: 20, height: 20)),
        ),
      )..frame();
      addTearDown(harness.dispose);

      expect(
        harness.owner.dispatchDragUpdate(_event(const Offset(200, 200)))
            .isAccepted,
        isFalse,
      );
      expect(harness.owner.activeDropTarget, isNull);
    });

    test('a target that refuses passes the question to its ancestor', () {
      final List<String> accepted = <String>[];
      final _Harness harness = _Harness(
        child: DropTarget(
          formats: const <String>[DragFormats.uriList],
          onDrop: (DropDetails details) async {
            accepted.add('outer');
            return DragAction.copy;
          },
          child: DropTarget(
            // Wants text; the drag carries files only.
            formats: const <String>[DragFormats.text],
            onDrop: (DropDetails details) async {
              accepted.add('inner');
              return DragAction.copy;
            },
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      )..frame();
      addTearDown(harness.dispose);

      final DropResponse response =
          harness.owner.dispatchDragUpdate(_event(const Offset(10, 10)));

      expect(response.isAccepted, isTrue,
          reason: 'the outer zone takes what the inner label cannot');
      expect(response.acceptedFormat, DragFormats.uriList);
    });

    test('moving between two zones is a leave and an enter, in that order',
        () async {
      final List<String> log = <String>[];
      final _Harness harness = _Harness(
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 50,
              height: 100,
              child: _target(
                key: 'left',
                onEnter: () => log.add('enter left'),
                onLeave: () => log.add('leave left'),
              ),
            ),
            SizedBox(
              width: 50,
              height: 100,
              child: _target(
                key: 'right',
                onEnter: () => log.add('enter right'),
                onLeave: () => log.add('leave right'),
              ),
            ),
          ],
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.owner.dispatchDragUpdate(_event(const Offset(10, 10)));
      harness.owner.dispatchDragUpdate(_event(const Offset(20, 10)));
      harness.owner.dispatchDragUpdate(_event(const Offset(70, 10)));

      expect(log, <String>[
        'enter left',
        'leave left',
        'enter right',
      ], reason: 'a move inside one zone must not re-enter it');
    });

    test('a leave from the platform clears the active target', () {
      final _Harness harness = _Harness(child: _target())..frame();
      addTearDown(harness.dispose);

      harness.owner.dispatchDragUpdate(_event(const Offset(10, 10)));
      expect(harness.find<RenderDropTarget>()!.isDragOver, isTrue);

      harness.owner.dispatchDragLeave();

      expect(harness.owner.activeDropTarget, isNull);
      expect(harness.find<RenderDropTarget>()!.isDragOver, isFalse);
    });

    test('a leave with no drag in flight is not an error', () {
      final _Harness harness = _Harness(child: _target())..frame();
      addTearDown(harness.dispose);
      harness.owner.dispatchDragLeave();
      expect(harness.owner.activeDropTarget, isNull);
    });

    test('a drop reaches the widget that accepted, and only it', () async {
      final List<List<String>> dropped = <List<String>>[];
      final _Harness harness = _Harness(
        child: DropTarget(
          formats: const <String>[DragFormats.uriList],
          onDrop: (DropDetails details) async {
            dropped.add(await details.data.readFilePaths());
            return DragAction.move;
          },
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.owner.dispatchDragUpdate(_event(const Offset(10, 10)));
      final DragAction performed =
          await harness.owner.dispatchDrop(_event(const Offset(10, 10)));

      expect(performed, DragAction.move,
          reason: 'the honest answer is what lets the source delete');
      expect(dropped.single, <String>['/tmp/a.txt']);
      expect(harness.owner.activeDropTarget, isNull);
      expect(harness.find<RenderDropTarget>()!.isDragOver, isFalse,
          reason: 'a drop ends the drag, so the highlight goes with it');
    });

    test('a drop with nothing accepted performs nothing', () async {
      final _Harness harness = _Harness(child: _target())..frame();
      addTearDown(harness.dispose);

      expect(
        await harness.owner.dispatchDrop(_event(const Offset(10, 10))),
        DragAction.none,
      );
    });

    test('the local position is relative to the target, not the window',
        () async {
      Offset? seen;
      final _Harness harness = _Harness(
        child: Align(
          alignment: Alignment.bottomRight,
          child: SizedBox(
            width: 40,
            height: 20,
            child: DropTarget(
              onDragEnter: (DropDetails details) =>
                  seen = details.localPosition,
              onDrop: (DropDetails details) async => DragAction.copy,
            ),
          ),
        ),
      )..frame();
      addTearDown(harness.dispose);

      // The harness is 320x220, so the box occupies (280,200)-(320,220).
      harness.owner.dispatchDragUpdate(_event(const Offset(290, 205)));

      expect(seen, const Offset(10, 5));
    });
  });

  group('DropTarget acceptance', () {
    test('an action the source does not allow is refused, never downgraded',
        () {
      final _Harness harness = _Harness(
        child: DropTarget(
          formats: const <String>[DragFormats.uriList],
          action: DragAction.move,
          onDrop: (DropDetails details) async => DragAction.move,
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      final DropResponse response = harness.owner.dispatchDragUpdate(
        _event(
          const Offset(10, 10),
          allowed: const <DragAction>{DragAction.copy},
        ),
      );

      expect(response.isAccepted, isFalse,
          reason: 'a move the source cannot perform is a refusal, and '
              'quietly copying instead would be a different operation');
    });

    test('a custom predicate overrides the format rule', () {
      final _Harness harness = _Harness(
        child: DropTarget(
          formats: const <String>[DragFormats.text],
          accepts: (DropDetails details) => details.session.position.dx < 50
              ? const DropResponse(acceptedFormat: DragFormats.uriList)
              : const DropResponse.reject(),
          onDrop: (DropDetails details) async => DragAction.copy,
          child: const SizedBox(width: 200, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      expect(
        harness.owner.dispatchDragUpdate(_event(const Offset(10, 10)))
            .isAccepted,
        isTrue,
      );
      expect(
        harness.owner.dispatchDragUpdate(_event(const Offset(100, 10)))
            .isAccepted,
        isFalse,
      );
    });

    test('formats are consulted in the target order, not the source order',
        () {
      final _Harness harness = _Harness(
        child: DropTarget(
          formats: const <String>[DragFormats.text, DragFormats.uriList],
          onDrop: (DropDetails details) async => DragAction.copy,
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      final DropResponse response = harness.owner.dispatchDragUpdate(
        _event(
          const Offset(10, 10),
          data: MemoryDragData(<String, Uint8List>{
            DragFormats.uriList: Uint8List(0),
            DragFormats.text: Uint8List(0),
          }),
        ),
      );

      expect(response.acceptedFormat, DragFormats.text);
    });

    test('a non-opaque target is only hittable where its child is', () {
      final _Harness harness = _Harness(
        child: DropTarget(
          opaque: false,
          onDrop: (DropDetails details) async => DragAction.copy,
          child: const Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 20,
              height: 20,
              child: ColoredBox(color: Color(0xFF000000)),
            ),
          ),
        ),
      )..frame();
      addTearDown(harness.dispose);

      expect(
        harness.owner.dispatchDragUpdate(_event(const Offset(5, 5)))
            .isAccepted,
        isTrue,
      );
      expect(
        harness.owner.dispatchDragUpdate(_event(const Offset(200, 200)))
            .isAccepted,
        isFalse,
      );
    });
  });

  group('semantics', () {
    test('a drop target under an accepted drag reads as selected', () {
      final _Harness harness = _Harness(
        child: _target(label: 'Drop files here'),
      )..frame();
      addTearDown(harness.dispose);

      final RenderDropTarget node = harness.find<RenderDropTarget>()!;
      expect(node.describeSemantics().label, 'Drop files here');
      expect(node.describeSemantics().states, isEmpty);

      harness.owner.dispatchDragUpdate(_event(const Offset(10, 10)));

      expect(
        node.describeSemantics().states,
        contains(SemanticsState.selected),
      );
    });
  });

  group('DragDropScope', () {
    test('a subtree with no scope gets a named failure, not a null', () {
      final DragDropBackend backend =
          DragDropScope.of(_NoContext());
      expect(backend, isA<UnavailableDragDrop>());
      expect(
        backend.registerDropTarget(
          window: _FakeWindow(),
          handler: _NullHandler(),
        ),
        throwsA(isA<DragDropException>()),
      );
    });
  });

  group('DragSource', () {
    test('a press alone starts nothing; travel past the slop starts a drag',
        () async {
      final FakeDragDrop backend = FakeDragDrop();
      final List<String> log = <String>[];
      final _Harness harness = _Harness(
        backend: backend,
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('payload'),
          onDragStarted: () => log.add('started'),
          onDragEnd: (DragAction action) => log.add('end ${action.name}'),
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      final RenderDragSource source = harness.find<RenderDragSource>()!;
      harness.down(const Offset(10, 10));
      expect(source.isTracking, isTrue);
      expect(log, isEmpty, reason: 'a press is not a drag');

      // Inside the 4px mouse slop: still a click, not a drag.
      harness.move(const Offset(12, 11));
      expect(log, isEmpty);
      expect(backend.requests, isEmpty);

      harness.move(const Offset(20, 20));
      await Future<void>.delayed(Duration.zero);

      expect(log, <String>['started', 'end copy']);
      expect(backend.requests.single.data.formats,
          contains(DragFormats.text));
      expect(source.isTracking, isFalse);
    });

    test('the slop is the pointer kind that pressed, not a constant', () {
      final _Harness harness = _Harness(
        backend: FakeDragDrop(),
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('x'),
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);
      final RenderDragSource source = harness.find<RenderDragSource>()!;

      harness.down(const Offset(10, 10));
      expect(source.threshold, kPrecisePointerSlop);

      harness.up(const Offset(10, 10));
      harness.down(const Offset(10, 10), kind: PointerKind.touch);
      expect(source.threshold, kTouchSlop,
          reason: 'a fingertip wanders inside its own contact patch');
    });

    test('an explicit slop overrides both', () {
      final _Harness harness = _Harness(
        backend: FakeDragDrop(),
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('x'),
          slop: 40,
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.down(const Offset(10, 10));
      harness.move(const Offset(40, 10));
      expect(harness.find<RenderDragSource>()!.isTracking, isTrue,
          reason: '30 pixels is under the 40 this source asked for');
    });

    test('a secondary-button press never drags', () async {
      final FakeDragDrop backend = FakeDragDrop();
      final _Harness harness = _Harness(
        backend: backend,
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('x'),
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.down(const Offset(10, 10), button: PointerButton.secondary);
      harness.move(const Offset(60, 60));
      await Future<void>.delayed(Duration.zero);

      expect(backend.requests, isEmpty,
          reason: 'a right-press opens a context menu on every desktop');
    });

    test('a release before the slop cancels the candidate', () async {
      final FakeDragDrop backend = FakeDragDrop();
      final _Harness harness = _Harness(
        backend: backend,
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('x'),
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);
      final RenderDragSource source = harness.find<RenderDragSource>()!;

      harness.down(const Offset(10, 10));
      harness.up(const Offset(11, 11));
      expect(source.isTracking, isFalse);

      // A move after the release belongs to no press and must not commit.
      harness.move(const Offset(80, 80));
      await Future<void>.delayed(Duration.zero);
      expect(backend.requests, isEmpty);
    });

    test('the payload is built when the gesture commits, not at build time',
        () async {
      int builds = 0;
      final FakeDragDrop backend = FakeDragDrop();
      final _Harness harness = _Harness(
        backend: backend,
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () {
            builds++;
            return MemoryDragData.text('now');
          },
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      expect(builds, 0, reason: 'a source that never drags serialises nothing');
      harness.down(const Offset(10, 10));
      harness.move(const Offset(60, 60));
      await Future<void>.delayed(Duration.zero);
      expect(builds, 1);
    });

    test('the allowed actions and the feedback reach the request', () async {
      final FakeDragDrop backend = FakeDragDrop()
        ..dragResult = DragAction.move;
      final List<DragAction> ended = <DragAction>[];
      final _Harness harness = _Harness(
        backend: backend,
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.filePaths(<String>['/tmp/a.txt']),
          allowedActions: const <DragAction>{
            DragAction.copy,
            DragAction.move,
          },
          preferredAction: DragAction.move,
          feedback: () => const DragFeedbackImage(
            width: 2,
            height: 2,
            pixels: <int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          ),
          onDragEnd: ended.add,
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.down(const Offset(10, 10));
      harness.move(const Offset(60, 60));
      await Future<void>.delayed(Duration.zero);

      final DragRequest request = backend.requests.single;
      expect(request.allowedActions,
          <DragAction>{DragAction.copy, DragAction.move});
      expect(request.preferredAction, DragAction.move);
      expect(request.feedback?.width, 2);
      expect(ended, <DragAction>[DragAction.move],
          reason: 'only a confirmed move may delete the original');
    });

    test('a second gesture cannot start a nested drag', () async {
      final Completer<DragAction> pending = Completer<DragAction>();
      final _BlockingDragDrop backend = _BlockingDragDrop(pending);
      final _Harness harness = _Harness(
        backend: backend,
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('x'),
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.down(const Offset(10, 10));
      harness.move(const Offset(60, 60));
      await Future<void>.delayed(Duration.zero);
      expect(backend.starts, 1);

      harness.frame();
      harness.down(const Offset(10, 10));
      harness.move(const Offset(60, 60));
      await Future<void>.delayed(Duration.zero);
      expect(backend.starts, 1,
          reason: 'on Win32 that would be a modal loop inside a modal loop');

      pending.complete(DragAction.copy);
      await Future<void>.delayed(Duration.zero);
    });

    test('a backend without drag and drop fails by name, not silently',
        () async {
      final List<DragDropException> failures = <DragDropException>[];
      final _Harness harness = _Harness(
        backend: const UnavailableDragDrop(
          name: 'headless',
          reason: 'no other application to drag to',
        ),
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('x'),
          onDragFailed: failures.add,
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.down(const Offset(10, 10));
      harness.move(const Offset(60, 60));
      await Future<void>.delayed(Duration.zero);

      expect(failures.single.backend, 'headless');
      expect(failures.single.operation, 'startDrag');
    });

    test('a tree with no window says so instead of dereferencing null',
        () async {
      final List<DragDropException> failures = <DragDropException>[];
      final _Harness harness = _Harness(
        backend: FakeDragDrop(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('x'),
          onDragFailed: failures.add,
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.down(const Offset(10, 10));
      harness.move(const Offset(60, 60));
      await Future<void>.delayed(Duration.zero);

      expect(failures.single.reason, contains('not mounted in an application'));
    });

    test('a disabled source tracks nothing at all', () async {
      final FakeDragDrop backend = FakeDragDrop();
      final _Harness harness = _Harness(
        backend: backend,
        window: _FakeWindow(),
        child: DragSource(
          opaque: true,
          data: () => MemoryDragData.text('x'),
          enabled: false,
          child: const SizedBox(width: 100, height: 100),
        ),
      )..frame();
      addTearDown(harness.dispose);

      harness.down(const Offset(10, 10));
      expect(harness.find<RenderDragSource>()!.isTracking, isFalse);
      harness.move(const Offset(60, 60));
      await Future<void>.delayed(Duration.zero);
      expect(backend.requests, isEmpty);
    });

    test('a source inside a drop target does not swallow drops', () async {
      final FakeDragDrop backend = FakeDragDrop();
      final _Harness harness = _Harness(
        backend: backend,
        window: _FakeWindow(),
        child: DropTarget(
          formats: const <String>[DragFormats.uriList],
          onDrop: (DropDetails details) async => DragAction.copy,
          child: DragSource(
            opaque: true,
            data: () => MemoryDragData.text('x'),
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      )..frame();
      addTearDown(harness.dispose);

      expect(
        harness.owner.dispatchDragUpdate(_event(const Offset(10, 10)))
            .isAccepted,
        isTrue,
        reason: 'a draggable row inside a drop zone is the ordinary case',
      );
    });
  });

  group('WidgetTreeDropTarget', () {
    test('is the window-level handler a backend registers', () async {
      final _Harness harness = _Harness(child: _target())..frame();
      addTearDown(harness.dispose);
      final DropTargetHandler handler = WidgetTreeDropTarget(harness.owner);

      expect(handler.onDragEnter(_event(const Offset(10, 10))).isAccepted,
          isTrue);
      expect(
          handler.onDragOver(_event(const Offset(11, 11))).isAccepted, isTrue);
      expect(await handler.onDrop(_event(const Offset(11, 11))),
          DragAction.copy);
      handler.onDragLeave();
      expect(harness.owner.activeDropTarget, isNull);
    });

    test('drives a FakeDragDrop end to end', () async {
      final _Harness harness = _Harness(child: _target())..frame();
      addTearDown(harness.dispose);
      final FakeDragDrop backend = FakeDragDrop();
      await backend.registerDropTarget(
        window: _FakeWindow(),
        handler: WidgetTreeDropTarget(harness.owner),
      );

      final DropTargetHandler handler = backend.handler!;
      expect(handler.onDragEnter(_event(const Offset(5, 5))).isAccepted,
          isTrue);
      expect(await handler.onDrop(_event(const Offset(5, 5))),
          DragAction.copy);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _target({
  String? key,
  String? label,
  Widget? child,
  void Function()? onEnter,
  void Function()? onLeave,
}) =>
    DropTarget(
      key: key == null ? null : ValueKey<String>(key),
      formats: const <String>[DragFormats.uriList],
      semanticLabel: label,
      onDragEnter: onEnter == null ? null : (DropDetails _) => onEnter(),
      onDragLeave: onLeave,
      onDrop: (DropDetails details) async => DragAction.copy,
      child: child,
    );

DragSessionEvent _event(
  Offset position, {
  Set<DragAction> allowed = const <DragAction>{
    DragAction.copy,
    DragAction.move,
  },
  DragData? data,
}) =>
    DragSessionEvent(
      windowId: const NativeWindowId(1),
      position: position,
      data: data ?? MemoryDragData.filePaths(<String>['/tmp/a.txt']),
      allowedActions: allowed,
    );

final class _Harness {
  _Harness({required this.child, this.backend, this.window}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(320, 220)),
      ),
    );
    _mount();
  }

  final Widget child;

  /// Installed as a [DragDropScope] when present, which is what a `DragSource`
  /// needs and a `DropTarget` does not - the drop path comes from the backend
  /// through the [BuildOwner], the drag path is asked for from the tree.
  final DragDropBackend? backend;
  final NativeWindow? window;

  late final BuildOwner owner;

  int _pointerId = 0;

  void _mount() {
    final Widget wrapped = Directionality(
      textDirection: TextDirection.leftToRight,
      child: child,
    );
    owner.updateRoot(
      backend == null
          ? wrapped
          : DragDropScope(
              dragAndDrop: backend!,
              window: window,
              child: wrapped,
            ),
    );
  }

  void down(
    Offset position, {
    PointerButton button = PointerButton.primary,
    PointerKind kind = PointerKind.mouse,
  }) {
    _pointerId++;
    owner.dispatchPointerEvent(
      PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 0,
        timestamp: Duration.zero,
        pointerId: _pointerId,
        kind: kind,
        logicalPosition: position,
        button: button,
      ),
    );
  }

  void move(Offset position, {PointerKind kind = PointerKind.mouse}) =>
      owner.dispatchPointerEvent(
        PointerMoveEvent(
          windowId: const NativeWindowId(1),
          generation: 0,
          timestamp: Duration.zero,
          pointerId: _pointerId,
          kind: kind,
          logicalPosition: position,
        ),
      );

  void up(Offset position, {PointerButton button = PointerButton.primary}) =>
      owner.dispatchPointerEvent(
        PointerUpEvent(
          windowId: const NativeWindowId(1),
          generation: 0,
          timestamp: Duration.zero,
          pointerId: _pointerId,
          kind: PointerKind.mouse,
          logicalPosition: position,
          button: button,
        ),
      );

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  T? find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is T) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  void dispose() => owner.dispose();
}

final class _NullHandler implements DropTargetHandler {
  @override
  DropResponse onDragEnter(DragSessionEvent event) =>
      const DropResponse.reject();

  @override
  DropResponse onDragOver(DragSessionEvent event) =>
      const DropResponse.reject();

  @override
  void onDragLeave() {}

  @override
  Future<DragAction> onDrop(DragSessionEvent event) async => DragAction.none;
}

/// A context with nothing above it, for the "no scope installed" path.
final class _NoContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeWindow implements NativeWindow {
  @override
  NativeWindowId get id => const NativeWindowId(1);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}


/// A backend whose drag never ends until the test says so, which is how the
/// "no nested drag" rule is provable without a modal loop.
final class _BlockingDragDrop implements DragDropBackend {
  _BlockingDragDrop(this._pending);

  final Completer<DragAction> _pending;

  int starts = 0;

  @override
  String get name => 'blocking';

  @override
  bool get canStartDrag => true;

  @override
  Future<DropTargetRegistration> registerDropTarget({
    required NativeWindow window,
    required DropTargetHandler handler,
  }) async =>
      throw UnimplementedError();

  @override
  Future<DragAction> startDrag(DragRequest request) {
    starts++;
    return _pending.future;
  }
}
