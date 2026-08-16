/// Keyframe tracks: per-segment curves, the hold-at-the-ends rule, and the
/// validation that refuses to sort bad data into looking correct.
library;

import 'package:dart_ui/src/animation/animation.dart';
import 'package:dart_ui/src/animation/clock.dart';
import 'package:dart_ui/src/animation/curves.dart';
import 'package:dart_ui/src/animation/keyframes.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:test/test.dart';

void main() {
  group('validation', () {
    test('an empty track is rejected', () {
      expect(
        () => KeyframeTracks.ofDouble(const <Keyframe<double>>[]),
        throwsArgumentError,
      );
    });

    test('out-of-order times are rejected, not sorted', () {
      expect(
        () => KeyframeTracks.ofDouble(const <Keyframe<double>>[
          Keyframe<double>(time: 0.0, value: 0),
          Keyframe<double>(time: 0.8, value: 1),
          Keyframe<double>(time: 0.4, value: 2),
        ]),
        throwsArgumentError,
      );
    });

    test('duplicate times are rejected', () {
      expect(
        () => KeyframeTracks.ofDouble(const <Keyframe<double>>[
          Keyframe<double>(time: 0.0, value: 0),
          Keyframe<double>(time: 0.5, value: 1),
          Keyframe<double>(time: 0.5, value: 2),
        ]),
        throwsArgumentError,
      );
    });

    test('times outside [0, 1] are rejected', () {
      expect(
        () => KeyframeTracks.ofDouble(const <Keyframe<double>>[
          Keyframe<double>(time: -0.1, value: 0),
          Keyframe<double>(time: 1.0, value: 1),
        ]),
        throwsArgumentError,
      );
      expect(
        () => KeyframeTracks.ofDouble(const <Keyframe<double>>[
          Keyframe<double>(time: 0.0, value: 0),
          Keyframe<double>(time: 1.5, value: 1),
        ]),
        throwsArgumentError,
      );
      expect(
        () => KeyframeTracks.ofDouble(const <Keyframe<double>>[
          Keyframe<double>(time: 0.0, value: 0),
          Keyframe<double>(time: double.nan, value: 1),
        ]),
        throwsArgumentError,
      );
    });

    test('a single keyframe is a constant track', () {
      final KeyframeTrack<double> track =
          KeyframeTracks.ofDouble(const <Keyframe<double>>[
        Keyframe<double>(time: 0.5, value: 7),
      ]);
      expect(track.valueAt(0.0), 7);
      expect(track.valueAt(0.5), 7);
      expect(track.valueAt(1.0), 7);
      expect(track.length, 1);
    });
  });

  group('evaluation', () {
    final KeyframeTrack<double> track =
        KeyframeTracks.ofDouble(const <Keyframe<double>>[
      Keyframe<double>(time: 0.0, value: 0),
      Keyframe<double>(time: 0.25, value: 10),
      Keyframe<double>(time: 0.75, value: 30),
      Keyframe<double>(time: 1.0, value: 0),
    ]);

    test('lands exactly on every declared keyframe', () {
      expect(track.valueAt(0.0), 0);
      expect(track.valueAt(0.25), 10);
      expect(track.valueAt(0.75), 30);
      expect(track.valueAt(1.0), 0);
    });

    test('interpolates linearly inside each segment', () {
      expect(track.valueAt(0.125), 5);
      expect(track.valueAt(0.5), 20);
      expect(track.valueAt(0.875), 15);
    });

    test('holds outside the range instead of extrapolating', () {
      final KeyframeTrack<double> staggered =
          KeyframeTracks.ofDouble(const <Keyframe<double>>[
        Keyframe<double>(time: 0.3, value: 100),
        Keyframe<double>(time: 0.7, value: 200),
      ]);
      expect(staggered.valueAt(0.0), 100);
      expect(staggered.valueAt(0.29), 100);
      expect(staggered.valueAt(0.5), 150);
      expect(staggered.valueAt(0.71), 200);
      expect(staggered.valueAt(1.0), 200);
      // Out of range is clamped rather than rejected, unlike Curve.transform.
      expect(staggered.valueAt(-5), 100);
      expect(staggered.valueAt(5), 200);
    });
  });

  group('per-segment curves', () {
    test('each segment eases with the curve stored on its end keyframe', () {
      final KeyframeTrack<double> track =
          KeyframeTracks.ofDouble(const <Keyframe<double>>[
        Keyframe<double>(time: 0.0, value: 0),
        // First segment eases in and out: symmetric, so its own midpoint is
        // exactly halfway.
        Keyframe<double>(time: 0.5, value: 100, curve: Curves.easeInOut),
        // Second segment is a hard switch at its own midpoint.
        Keyframe<double>(time: 1.0, value: 200, curve: Threshold(0.5)),
      ]);

      expect(track.valueAt(0.25), 50, reason: 'easeInOut is 0.5 at 0.5');
      expect(track.valueAt(0.125), lessThan(25),
          reason: 'the first quarter of an ease-in-out lags a straight line');
      expect(track.valueAt(0.375), greaterThan(75));

      expect(track.valueAt(0.6), 100, reason: 'threshold has not flipped');
      expect(track.valueAt(0.74), 100);
      expect(track.valueAt(0.75), 200, reason: 'threshold flipped');
      expect(track.valueAt(0.9), 200);
    });

    test('the first keyframe carries no incoming segment', () {
      // Its curve is unused: there is nothing before it to ease from.
      final KeyframeTrack<double> track =
          KeyframeTracks.ofDouble(const <Keyframe<double>>[
        Keyframe<double>(time: 0.0, value: 0, curve: Threshold(0.9)),
        Keyframe<double>(time: 1.0, value: 100),
      ]);
      expect(track.valueAt(0.5), 50);
    });
  });

  group('the typed constructors', () {
    test('offset, size, rect and colour tracks all interpolate', () {
      expect(
        KeyframeTracks.ofOffset(const <Keyframe<Offset>>[
          Keyframe<Offset>(time: 0, value: Offset.zero),
          Keyframe<Offset>(time: 1, value: Offset(10, 20)),
        ]).valueAt(0.5),
        const Offset(5, 10),
      );
      expect(
        KeyframeTracks.ofSize(const <Keyframe<Size>>[
          Keyframe<Size>(time: 0, value: Size(10, 10)),
          Keyframe<Size>(time: 1, value: Size(30, 50)),
        ]).valueAt(0.5),
        const Size(20, 30),
      );
      expect(
        KeyframeTracks.ofRect(const <Keyframe<Rect>>[
          Keyframe<Rect>(time: 0, value: Rect.fromLTRB(0, 0, 10, 10)),
          Keyframe<Rect>(time: 1, value: Rect.fromLTRB(10, 10, 20, 20)),
        ]).valueAt(0.5),
        const Rect.fromLTRB(5, 5, 15, 15),
      );
      expect(
        KeyframeTracks.ofColor(const <Keyframe<int>>[
          Keyframe<int>(time: 0, value: 0xFFFF0000),
          Keyframe<int>(time: 1, value: 0xFF0000FF),
        ]).valueAt(0.5),
        0xFF800080,
      );
    });

    test('a colour track fades premultiplied, like the tween', () {
      final KeyframeTrack<int> track =
          KeyframeTracks.ofColor(const <Keyframe<int>>[
        Keyframe<int>(time: 0, value: 0xFFFF0000),
        Keyframe<int>(time: 1, value: 0x00000000),
      ]);
      expect(track.valueAt(0.5), 0x80FF0000);
    });
  });

  test('a track can be driven by a controller', () {
    final AnimationClock clock = AnimationClock();
    final AnimationController controller = AnimationController(
      clock: clock,
      duration: const Duration(milliseconds: 100),
    )..forward();
    final KeyframeTrack<double> track =
        KeyframeTracks.ofDouble(const <Keyframe<double>>[
      Keyframe<double>(time: 0.0, value: 0),
      Keyframe<double>(time: 0.5, value: 100),
      Keyframe<double>(time: 1.0, value: 50),
    ]);

    clock.tick(Duration.zero);
    expect(track.evaluate(controller), 0);
    clock.tick(const Duration(milliseconds: 50));
    expect(track.evaluate(controller), 100);
    clock.tick(const Duration(milliseconds: 75));
    expect(track.evaluate(controller), 75);
    clock.tick(const Duration(milliseconds: 100));
    expect(track.evaluate(controller), 50);
  });
}
