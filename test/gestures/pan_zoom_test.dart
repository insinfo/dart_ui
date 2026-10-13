/// Trackpad pinches and turns: PointerPanZoomEvent through the router to a
/// GestureDetector's scale callbacks, to a Listener, and AppKit's two
/// streams folded into one gesture.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_input.dart';
import 'package:test/test.dart';

PointerPanZoomEvent _panZoom(PanZoomPhase phase,
        {double scale = 1,
        double rotation = 0,
        Offset at = const Offset(50, 50)}) =>
    PointerPanZoomEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.trackpad,
      logicalPosition: at,
      phase: phase,
      scale: scale,
      rotation: rotation,
    );

void main() {
  group('the framework', () {
    late BuildOwner owner;
    late List<String> log;

    void mount(Widget child) {
      owner = BuildOwner(
        pipelineOwner: PipelineOwner(
            rootConstraints: BoxConstraints.tight(const Size(200, 200))),
      )..updateRoot(child);
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
    }

    setUp(() => log = <String>[]);
    tearDown(() => owner.dispose());

    Widget scaler(String name, {Widget? child}) => GestureDetector(
          behavior: GestureHitTestBehavior.opaque,
          onScaleStart: (_) => log.add('$name start'),
          onScaleUpdate: (ScaleUpdateDetails d) =>
              log.add('$name ${d.scale.toStringAsFixed(2)} '
                  '${d.rotation.toStringAsFixed(2)} ${d.pointerCount}'),
          onScaleEnd: (_) => log.add('$name end'),
          child: child ?? const SizedBox(width: 200, height: 200),
        );

    test('a pinch drives the scale callbacks with its totals', () {
      mount(scaler('outer'));
      owner
        ..dispatchPointerEvent(_panZoom(PanZoomPhase.start))
        ..dispatchPointerEvent(_panZoom(PanZoomPhase.update, scale: 1.5))
        ..dispatchPointerEvent(
            _panZoom(PanZoomPhase.update, scale: 2, rotation: 0.25))
        ..dispatchPointerEvent(
            _panZoom(PanZoomPhase.end, scale: 2, rotation: 0.25));
      expect(log, <String>[
        'outer start',
        'outer 1.50 0.00 2',
        'outer 2.00 0.25 2',
        'outer end',
      ]);
    });

    test('the innermost zoomable gets it, not both', () {
      mount(scaler('outer',
          child: Center(
              child:
                  SizedBox(width: 100, height: 100, child: scaler('inner')))));
      owner
        ..dispatchPointerEvent(
            _panZoom(PanZoomPhase.start, at: const Offset(100, 100)))
        ..dispatchPointerEvent(_panZoom(PanZoomPhase.update,
            scale: 1.2, at: const Offset(100, 100)));
      expect(log, <String>['inner start', 'inner 1.20 0.00 2']);
    });

    test('a mouse button held elsewhere does not swallow the pinch', () {
      mount(scaler('outer'));
      owner.dispatchPointerEvent(const PointerDownEvent(
        windowId: NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(10, 10),
        button: PointerButton.primary,
      ));
      // No up: the press still holds its capture - as when a native drag
      // swallowed the release.
      log.clear();
      owner
        ..dispatchPointerEvent(_panZoom(PanZoomPhase.start))
        ..dispatchPointerEvent(_panZoom(PanZoomPhase.update, scale: 1.1));
      expect(log, contains('outer 1.10 0.00 2'));
    });

    test('a PointerListener sees it', () {
      final List<PanZoomPhase> phases = <PanZoomPhase>[];
      mount(PointerListener(
        behavior: GestureHitTestBehavior.opaque,
        onPointerPanZoom: (PointerPanZoomEvent e) => phases.add(e.phase),
        child: const SizedBox(width: 200, height: 200),
      ));
      owner
        ..dispatchPointerEvent(_panZoom(PanZoomPhase.start))
        ..dispatchPointerEvent(_panZoom(PanZoomPhase.end));
      expect(phases, <PanZoomPhase>[PanZoomPhase.start, PanZoomPhase.end]);
    });
  });

  group('AppKit streams', () {
    late MacosGestureAccumulator gestures;
    List<PointerPanZoomEvent> take(String kind, String phase, double value) =>
        gestures.take(
          kind: kind,
          phase: phase,
          value: value,
          position: const Offset(5, 5),
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
        );

    setUp(() => gestures = MacosGestureAccumulator());

    test('interleaved pinch and turn are one gesture with both totals', () {
      final List<PointerPanZoomEvent> events = <PointerPanZoomEvent>[
        ...take('magnify', 'begin', 0),
        ...take('magnify', 'change', 0.25),
        ...take('rotate', 'begin', 0),
        ...take('magnify', 'change', 0.25),
        ...take('rotate', 'change', 15),
        ...take('magnify', 'end', 0),
        ...take('rotate', 'end', 0),
      ];
      expect(
          events
              .where((PointerPanZoomEvent e) => e.phase == PanZoomPhase.start),
          hasLength(1));
      expect(events.last.phase, PanZoomPhase.end);
      expect(events.last.scale, closeTo(1.5625, 1e-9));
      expect(events.last.rotation, closeTo(-15 * math.pi / 180, 1e-9),
          reason: 'counterclockwise in AppKit is negative here');
      expect(gestures.isActive, isFalse);
    });

    test('a phaseless magnify is a whole gesture', () {
      final List<PointerPanZoomEvent> events = take('magnify', 'once', 0.5);
      expect(events.map((PointerPanZoomEvent e) => e.phase), <PanZoomPhase>[
        PanZoomPhase.start,
        PanZoomPhase.update,
        PanZoomPhase.end,
      ]);
      expect(events[1].scale, 1.5);
    });

    test('an unknown kind and a stray end are ignored', () {
      expect(take('swipe', 'begin', 1), isEmpty);
      expect(take('magnify', 'end', 0), isEmpty);
    });
  });
}
