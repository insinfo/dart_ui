import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('screenshot produces deterministic RGBA PNG bytes', () {
    final screenshot = HeadlessScreenshot(
      width: 1,
      height: 1,
      pixels: Uint8List.fromList(<int>[0, 0, 255, 255]),
    );

    final png = screenshot.toPng();
    expect(png.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    expect(png, orderedEquals(screenshot.toPng()));
  });

  test('golden comparison applies channel and pixel thresholds', () {
    final expected = HeadlessScreenshot(
      width: 2,
      height: 1,
      pixels: Uint8List.fromList(<int>[0, 0, 0, 255, 0, 0, 0, 255]),
    );
    final actual = HeadlessScreenshot(
      width: 2,
      height: 1,
      pixels: Uint8List.fromList(<int>[1, 0, 0, 255, 4, 0, 0, 255]),
    );

    expect(compareGolden(actual, expected, maxChannelDelta: 1).match, isFalse);
    expect(
      compareGolden(actual, expected,
              maxChannelDelta: 4, differingPixelsPercent: 100)
          .match,
      isTrue,
    );
  });

  test('input replay round-trips pointer events', () {
    final replay = InputReplay(
      window: const Size(800, 600),
      events: <PlatformInputEvent>[
        const PointerMoveEvent(
          windowId: NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset(5, 6),
        ),
        const PointerDownEvent(
          windowId: NativeWindowId(1),
          generation: 1,
          timestamp: Duration(microseconds: 12),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset(5, 6),
          button: PointerButton.primary,
        ),
      ],
    );

    final decoded = InputReplay.fromJson(replay.toJson());
    expect(decoded.window, replay.window);
    expect(decoded.events, hasLength(2));
    expect(decoded.events[1], isA<PointerDownEvent>());
  });

  test('frame scheduler coalesces visual updates', () {
    final frames = <DisplayList>[];
    final scheduler = FrameScheduler(onFrame: frames.add);
    scheduler.scheduleFrame();
    scheduler.scheduleFrame();

    expect(scheduler.hasScheduledFrame, isTrue);
    scheduler.pump();
    expect(frames, hasLength(1));
    expect(scheduler.hasScheduledFrame, isFalse);
    scheduler.dispose();
  });

  test('semantic recorder exposes deterministic snapshots', () {
    final recorder = SemanticRecorder()
      ..record(const SemanticRecord(
        id: 1,
        role: 'button',
        bounds: Rect.fromLTWH(0, 0, 10, 10),
        label: 'Continue',
      ));

    expect(recorder.snapshot(), hasLength(1));
    expect(recorder.snapshot().single.label, 'Continue');
    recorder.clear();
    expect(recorder.records, isEmpty);
  });
}
