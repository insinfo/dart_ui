/// The DPI and coordinate arithmetic, tested on every platform.
///
/// None of this needs an HWND, and that is the point: the conversions are
/// where the subtle bugs live (a window that shrinks by a pixel per resize, a
/// menu that lands 40 pixels left of the window on a second monitor), and a
/// backend whose arithmetic is only exercised on the one CI runner that has
/// Windows is a backend whose arithmetic is barely exercised.
library;

import 'package:dart_ui/src/backends/win32/win32_coordinates.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:test/test.dart';

/// The scales section 13.5 names, as the DPI values Windows reports.
const Map<String, int> _dpis = <String, int>{
  '100%': 96,
  '125%': 120,
  '150%': 144,
  '175%': 168,
  '200%': 192,
};

void main() {
  group('win32ScaleForDpi', () {
    test('maps the documented DPI values to their scales', () {
      expect(win32ScaleForDpi(96), 1.0);
      expect(win32ScaleForDpi(120), 1.25);
      expect(win32ScaleForDpi(144), 1.5);
      expect(win32ScaleForDpi(168), 1.75);
      expect(win32ScaleForDpi(192), 2.0);
    });

    test('a nonsensical DPI degrades to 1.0 rather than to zero or NaN', () {
      // GetDpiForWindow returns 0 for a handle that is no longer a window, and
      // a scale of 0 would divide every logical size into infinity.
      expect(win32ScaleForDpi(0), 1.0);
      expect(win32ScaleForDpi(-1), 1.0);
    });
  });

  group('Win32CoordinateSpace sizes', () {
    for (final entry in _dpis.entries) {
      final scale = win32ScaleForDpi(entry.value);
      final space = Win32CoordinateSpace(
        clientOriginX: 0,
        clientOriginY: 0,
        scale: scale,
      );

      test('${entry.key}: physical size is round(logical * scale)', () {
        final pixels = space.logicalSizeToPhysical(const Size(800, 600));
        expect(pixels.width, (800 * scale).round());
        expect(pixels.height, (600 * scale).round());
      });

      test('${entry.key}: the conversion is deterministic', () {
        // Called twice with the same input it must give the same answer, or a
        // window that is resized to its own reported size drifts.
        const size = Size(801.5, 599.5);
        expect(
          space.logicalSizeToPhysical(size),
          space.logicalSizeToPhysical(size),
        );
      });

      test('${entry.key}: a physical size converts back within a pixel', () {
        final pixels = space.logicalSizeToPhysical(const Size(800, 600));
        final logical =
            space.physicalSizeToLogical(pixels.width, pixels.height);
        expect(logical.width, closeTo(800, 1 / scale));
        expect(logical.height, closeTo(600, 1 / scale));
      });
    }

    test('a positive logical size never becomes a zero-pixel surface', () {
      // CreateDIBSection fails on a zero extent, so the floor is one pixel.
      const space = Win32CoordinateSpace(
        clientOriginX: 0,
        clientOriginY: 0,
        scale: 0.5,
      );
      final pixels = space.logicalSizeToPhysical(const Size(1, 1));
      expect(pixels.width, 1);
      expect(pixels.height, 1);
    });

    test('an empty logical size stays empty', () {
      const space = Win32CoordinateSpace(
        clientOriginX: 0,
        clientOriginY: 0,
        scale: 2,
      );
      expect(space.logicalSizeToPhysical(Size.zero), (width: 0, height: 0));
    });
  });

  group('Win32CoordinateSpace positions', () {
    test('screen and client round-trip exactly', () {
      for (final dpi in _dpis.values) {
        final space = Win32CoordinateSpace(
          clientOriginX: 137,
          clientOriginY: -84,
          scale: win32ScaleForDpi(dpi),
        );
        for (final point in const <Offset>[
          Offset.zero,
          Offset(10, 20),
          Offset(-500.5, 12.25),
          Offset(1919, 1079),
        ]) {
          final csc = space.screenToClient(space.clientToScreen(point));
          expect(csc.dx, closeTo(point.dx, 1e-10),
              reason: 'client -> screen -> client at $dpi dpi (dx)');
          expect(csc.dy, closeTo(point.dy, 1e-10),
              reason: 'client -> screen -> client at $dpi dpi (dy)');

          final scs = space.clientToScreen(space.screenToClient(point));
          expect(scs.dx, closeTo(point.dx, 1e-10),
              reason: 'screen -> client -> screen at $dpi dpi (dx)');
          expect(scs.dy, closeTo(point.dy, 1e-10),
              reason: 'screen -> client -> screen at $dpi dpi (dy)');
        }
      }
    });

    test('the origin is the offset between the two spaces', () {
      const space = Win32CoordinateSpace(
        clientOriginX: 200,
        clientOriginY: 100,
        scale: 2,
      );
      // 200 physical pixels at scale 2 is 100 logical units.
      expect(space.logicalOrigin, const Offset(100, 50));
      expect(space.clientToScreen(Offset.zero), const Offset(100, 50));
      expect(space.screenToClient(const Offset(100, 50)), Offset.zero);
    });

    test('a client position converts to physical pixels', () {
      const space = Win32CoordinateSpace(
        clientOriginX: 0,
        clientOriginY: 0,
        scale: 1.5,
      );
      expect(space.logicalToPhysical(10), 15);
      expect(space.physicalToLogical(15, 30), const Offset(10, 20));
    });
  });

  group('Win32CoordinateSpace damage rectangles', () {
    test('a logical rectangle grows outwards in pixels', () {
      const space = Win32CoordinateSpace(
        clientOriginX: 0,
        clientOriginY: 0,
        scale: 1.5,
      );
      // 10.4 * 1.5 = 15.6 -> 15, and 20.4 * 1.5 = 30.6 -> 31. Rounding to
      // nearest would clip the left edge and leave a stale seam.
      final pixels =
          space.logicalRectToPhysical(const Rect.fromLTRB(10.4, 10.4, 20.4, 2));
      expect(pixels.left, 15);
      expect(pixels.top, 15);
      expect(pixels.right, 31);
    });

    test('a physical rectangle grows outwards in logical units', () {
      const space = Win32CoordinateSpace(
        clientOriginX: 0,
        clientOriginY: 0,
        scale: 2,
      );
      final rect = space.physicalRectToLogical(3, 3, 9, 9);
      expect(rect.left, 1);
      expect(rect.top, 1);
      expect(rect.right, 5);
      expect(rect.bottom, 5);
    });
  });

  group('LPARAM unpacking', () {
    int pack(int low, int high) => ((high & 0xFFFF) << 16) | (low & 0xFFFF);

    test('sizes read unsigned', () {
      final lParam = pack(1920, 1080);
      expect(win32LoWord(lParam), 1920);
      expect(win32HiWord(lParam), 1080);
    });

    test('a size at the 16-bit boundary is not mistaken for a negative', () {
      final lParam = pack(40000, 33000);
      expect(win32LoWord(lParam), 40000);
      expect(win32HiWord(lParam), 33000);
    });

    test('coordinates read signed, which is what a left monitor needs', () {
      final lParam = pack(-40, -1000);
      expect(win32SignedLoWord(lParam), -40);
      expect(win32SignedHiWord(lParam), -1000);
      // The same bits read unsigned are the bug this guards against.
      expect(win32LoWord(lParam), 65496);
    });

    test('positive coordinates are unchanged by sign extension', () {
      final lParam = pack(32767, 1);
      expect(win32SignedLoWord(lParam), 32767);
      expect(win32SignedHiWord(lParam), 1);
    });
  });

  test('copyWith replaces only what it is given', () {
    const space = Win32CoordinateSpace(
      clientOriginX: 1,
      clientOriginY: 2,
      scale: 1.25,
    );
    expect(space.copyWith(scale: 2).scale, 2);
    expect(space.copyWith(scale: 2).clientOriginX, 1);
    expect(space.copyWith(clientOriginX: 9).clientOriginY, 2);
  });
}
