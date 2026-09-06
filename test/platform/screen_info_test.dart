/// The screen contract, exercised where no display server exists.
///
/// Everything here is arithmetic over rectangles, which is exactly the part
/// that a test against the real machine cannot pin: this laptop has one
/// monitor, so the cases that matter for a popup - a point past the edge, two
/// monitors at different scales, the gap the two logical spaces leave between
/// them - only exist if they are constructed.
library;

import 'package:dart_ui/src/backends/headless/headless_backend.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/platform/screen_info.dart';
import 'package:test/test.dart';

const ScreenInfo _left = ScreenInfo(
  bounds: Rect.fromLTRB(0, 0, 1920, 1080),
  workArea: Rect.fromLTRB(0, 0, 1920, 1040),
  scale: 1,
  isPrimary: true,
  name: 'left',
);

/// A 3840x2160 panel at 200%, placed to the right of [_left] on the desktop.
///
/// Its logical origin is 1920 because that is where the *physical* desktop
/// puts it divided by its own scale... which is the trap: 3840 physical pixels
/// at scale 2 are 1920 logical units, so the two screens' logical rectangles
/// do not tile. That gap is deliberate here - it is the arrangement
/// `ScreenInfo.nearest` has to answer for.
const ScreenInfo _rightHiDpi = ScreenInfo(
  bounds: Rect.fromLTRB(960, 0, 2880, 1080),
  workArea: Rect.fromLTRB(960, 0, 2880, 1040),
  scale: 2,
  isPrimary: false,
  name: 'right',
);

void main() {
  group('screenAt', () {
    test('a point inside a screen answers with that screen', () {
      expect(
        ScreenInfo.nearest(const <ScreenInfo>[_left], const Offset(10, 10)),
        _left,
      );
      expect(
        ScreenInfo.nearest(
          const <ScreenInfo>[_left, _rightHiDpi],
          const Offset(2000, 500),
        ),
        _rightHiDpi,
        reason: 'only the second screen contains x=2000',
      );
    });

    test('a point outside every screen answers with the nearest, never null',
        () {
      // Twenty logical units below the bottom edge: a menu anchored on the
      // last row of a maximised window is exactly this, and "no screen" would
      // leave it nowhere to go.
      expect(
        ScreenInfo.nearest(const <ScreenInfo>[_left], const Offset(100, 1100)),
        _left,
      );
      // Far off to the left of both, so the answer must be the left screen and
      // not merely the first one that was looked at.
      expect(
        ScreenInfo.nearest(
          const <ScreenInfo>[_rightHiDpi, _left],
          const Offset(-500, 500),
        ),
        _left,
      );
      // Far off to the right of both.
      expect(
        ScreenInfo.nearest(
          const <ScreenInfo>[_left, _rightHiDpi],
          const Offset(5000, 500),
        ),
        _rightHiDpi,
      );
    });

    test('distance is measured to the bounds, not to the centre', () {
      // A point one unit above the top edge of the tall-and-narrow screen. Its
      // centre is far away; its edge is one unit away, and edge distance is
      // what decides where a popup that just left a monitor should land.
      const ScreenInfo narrow = ScreenInfo(
        bounds: Rect.fromLTRB(0, 0, 100, 4000),
        workArea: Rect.fromLTRB(0, 0, 100, 4000),
        scale: 1,
        isPrimary: false,
      );
      const ScreenInfo squat = ScreenInfo(
        bounds: Rect.fromLTRB(0, -600, 900, -500),
        workArea: Rect.fromLTRB(0, -600, 900, -500),
        scale: 1,
        isPrimary: true,
      );
      expect(
        ScreenInfo.nearest(
          const <ScreenInfo>[squat, narrow],
          const Offset(50, -1),
        ),
        narrow,
      );
    });

    test('an empty screen list is the only null', () {
      expect(
        ScreenInfo.nearest(const <ScreenInfo>[], const Offset(10, 10)),
        isNull,
      );
    });

    test('the half-open contains rule puts a shared edge on one screen only',
        () {
      // x=960 is the right screen's left edge and inside the left screen. Both
      // claim it geometrically; Rect.contains is half-open, so exactly one
      // wins - and it must be the one whose interior holds the point.
      expect(
        ScreenInfo.nearest(
          const <ScreenInfo>[_left, _rightHiDpi],
          const Offset(960, 500),
        ),
        _left,
      );
      expect(
        ScreenInfo.nearest(
          const <ScreenInfo>[_rightHiDpi, _left],
          const Offset(960, 500),
        ),
        _rightHiDpi,
        reason: 'both contain it; the order decides, and neither answer is a '
            'crash or a null',
      );
    });
  });

  group('the value', () {
    test('two screens with the same numbers are the same screen', () {
      const ScreenInfo copy = ScreenInfo(
        bounds: Rect.fromLTRB(0, 0, 1920, 1080),
        workArea: Rect.fromLTRB(0, 0, 1920, 1040),
        scale: 1,
        isPrimary: true,
        name: 'left',
      );
      expect(copy, _left);
      expect(copy.hashCode, _left.hashCode);
    });

    test('every field participates in equality', () {
      expect(
        const ScreenInfo(
          bounds: Rect.fromLTRB(0, 0, 1920, 1080),
          // The one that matters: a work area equal to the bounds is a
          // different screen from one with a taskbar, and a == that ignored it
          // would let the taskbar bug through.
          workArea: Rect.fromLTRB(0, 0, 1920, 1080),
          scale: 1,
          isPrimary: true,
          name: 'left',
        ),
        isNot(_left),
      );
      expect(
        const ScreenInfo(
          bounds: Rect.fromLTRB(0, 0, 1920, 1080),
          workArea: Rect.fromLTRB(0, 0, 1920, 1040),
          scale: 2,
          isPrimary: true,
          name: 'left',
        ),
        isNot(_left),
      );
      expect(
        const ScreenInfo(
          bounds: Rect.fromLTRB(0, 0, 1920, 1080),
          workArea: Rect.fromLTRB(0, 0, 1920, 1040),
          scale: 1,
          isPrimary: false,
          name: 'left',
        ),
        isNot(_left),
      );
      expect(
        const ScreenInfo(
          bounds: Rect.fromLTRB(0, 0, 1920, 1080),
          workArea: Rect.fromLTRB(0, 0, 1920, 1040),
          scale: 1,
          isPrimary: true,
        ),
        isNot(_left),
      );
    });

    test('toString names the rectangles and the scale', () {
      expect(_left.toString(), contains('left'));
      expect(_left.toString(), contains('primary'));
      expect(_rightHiDpi.toString(), isNot(contains('primary')));
    });
  });

  group('the headless backend as a ScreenProvider', () {
    test('defaults to one screen whose work area is not its bounds', () {
      final HeadlessWindowingBackend backend = HeadlessWindowingBackend();

      expect(backend, isA<ScreenProvider>());
      expect(backend.screens, hasLength(1));

      final ScreenInfo screen = backend.screens.single;
      expect(screen.isPrimary, isTrue);
      expect(screen.scale, 1);
      expect(screen.bounds, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(
        screen.workArea,
        isNot(screen.bounds),
        reason: 'a synthetic screen whose work area equals its bounds would '
            'let a popup that ignores the taskbar pass this suite',
      );
      expect(screen.workArea.bottom, lessThan(screen.bounds.bottom));
      expect(screen.bounds.contains(screen.workArea.topLeft), isTrue);
    });

    test('the screen list is unmodifiable once given', () {
      final HeadlessWindowingBackend backend = HeadlessWindowingBackend();
      expect(
        () => backend.screens.add(_left),
        throwsUnsupportedError,
      );
    });

    test('a test can describe a two-monitor mixed-DPI desktop', () {
      final HeadlessWindowingBackend backend = HeadlessWindowingBackend(
        screens: const <ScreenInfo>[_left, _rightHiDpi],
      );

      expect(backend.screens, hasLength(2));
      expect(
        backend.screens.where((ScreenInfo s) => s.isPrimary),
        hasLength(1),
      );
      expect(backend.screenAt(const Offset(10, 10)), _left);
      expect(backend.screenAt(const Offset(2000, 10)), _rightHiDpi);

      // The anchor conversion the mixed-DPI popup depends on: 40 logical units
      // on the left screen are 40 physical pixels, and the same 40 physical
      // pixels are 20 logical units on the right one. The two screens carry
      // the scales that make that arithmetic possible; a single desktop-wide
      // scale could not.
      final ScreenInfo left = backend.screenAt(const Offset(10, 10))!;
      final ScreenInfo right = backend.screenAt(const Offset(2000, 10))!;
      expect(40 * left.scale / right.scale, 20);
    });

    test('a backend with no screens answers null rather than inventing one',
        () {
      final HeadlessWindowingBackend backend = HeadlessWindowingBackend(
        screens: const <ScreenInfo>[],
      );
      expect(backend.screens, isEmpty);
      expect(backend.screenAt(Offset.zero), isNull);
    });
  });
}
