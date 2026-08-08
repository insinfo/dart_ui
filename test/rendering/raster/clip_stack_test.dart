import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/raster/clip_stack.dart';
import 'package:test/test.dart';

void main() {
  group('root state', () {
    test('starts at the whole device surface', () {
      final clip = ClipStack.forDevice(320, 200);

      expect(clip.current, const Rect.fromLTRB(0, 0, 320, 200));
      expect(clip.left, 0);
      expect(clip.top, 0);
      expect(clip.right, 320);
      expect(clip.bottom, 200);
      expect(clip.isEmpty, isFalse);
      expect(clip.depth, 0);
    });
  });

  group('intersect', () {
    test('narrows to the shared area', () {
      final clip = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(10, 20, 60, 70));

      expect(clip.current, const Rect.fromLTRB(10, 20, 60, 70));
    });

    test('cannot widen an enclosing clip', () {
      final clip = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(10, 10, 20, 20))
        ..intersect(const Rect.fromLTRB(-100, -100, 1000, 1000));

      expect(clip.current, const Rect.fromLTRB(10, 10, 20, 20));
    });

    test('is clamped by the device bounds it started from', () {
      final clip = ClipStack.forDevice(50, 50)
        ..intersect(const Rect.fromLTRB(-10, -10, 200, 200));

      expect(clip.current, const Rect.fromLTRB(0, 0, 50, 50));
    });

    test('a disjoint rectangle empties the clip', () {
      final clip = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(0, 0, 10, 10))
        ..intersect(const Rect.fromLTRB(50, 50, 60, 60));

      expect(clip.isEmpty, isTrue);
      expect(clip.current, Rect.zero);
    });

    test('every empty clip collapses to the same rectangle', () {
      final a = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(90, 90, 95, 95))
        ..intersect(const Rect.fromLTRB(0, 0, 5, 5));
      final b = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(10, 10, 12, 12))
        ..intersect(const Rect.fromLTRB(40, 40, 42, 42));

      expect(a.current, b.current);
      expect(a.left, b.left);
      expect(a.right, b.right);
    });

    test('an empty clip stays empty however it is narrowed', () {
      final clip = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(0, 0, 0, 0))
        ..intersect(const Rect.fromLTRB(10, 10, 20, 20));

      expect(clip.isEmpty, isTrue);
    });

    test('a zero-area rectangle empties rather than inverting', () {
      final clip = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(30, 30, 30, 80));

      expect(clip.isEmpty, isTrue);
    });

    test('integer edges skip the double round-trip', () {
      final clip = ClipStack.forDevice(100, 100)..intersectDevice(5, 6, 7, 8);

      expect(clip.current, const Rect.fromLTRB(5, 6, 7, 8));
    });
  });

  group('pixelEdge', () {
    test('rounds to the nearest pixel', () {
      expect(pixelEdge(10.0), 10);
      expect(pixelEdge(10.4), 10);
      expect(pixelEdge(10.6), 11);
    });

    test('rounds halves the same way on both sides of zero', () {
      // Dart's round() takes halves away from zero, which would make a
      // rectangle change width by a pixel as it was dragged across the origin.
      expect(pixelEdge(0.5), 1);
      expect(pixelEdge(-0.5), 0);
      expect(pixelEdge(-1.5), -1);
      expect(pixelEdge(-0.5) - pixelEdge(-10.5), 10);
      expect(pixelEdge(10.5) - pixelEdge(0.5), 10);
    });
  });

  group('save and restore', () {
    test('restore puts back exactly what save pushed', () {
      final clip = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(10, 10, 90, 90));
      final before = clip.current;

      clip
        ..save()
        ..intersect(const Rect.fromLTRB(20, 20, 30, 30));
      expect(clip.current, const Rect.fromLTRB(20, 20, 30, 30));

      clip.restore();

      expect(clip.current, before);
      expect(clip.depth, 0);
    });

    test('nesting unwinds level by level', () {
      final clip = ClipStack.forDevice(100, 100)
        ..save()
        ..intersect(const Rect.fromLTRB(10, 10, 90, 90))
        ..save()
        ..intersect(const Rect.fromLTRB(20, 20, 80, 80))
        ..save()
        ..intersect(const Rect.fromLTRB(30, 30, 70, 70));

      expect(clip.depth, 3);
      expect(clip.current, const Rect.fromLTRB(30, 30, 70, 70));

      clip.restore();
      expect(clip.current, const Rect.fromLTRB(20, 20, 80, 80));

      clip.restore();
      expect(clip.current, const Rect.fromLTRB(10, 10, 90, 90));

      clip.restore();
      expect(clip.current, const Rect.fromLTRB(0, 0, 100, 100));
      expect(clip.depth, 0);
    });

    test('restoring past an empty clip brings the region back', () {
      // An empty clip forgets its coordinates on purpose, so this is the check
      // that the forgetting happens in the current level and not in the saved
      // one.
      final clip = ClipStack.forDevice(100, 100)
        ..intersect(const Rect.fromLTRB(10, 10, 40, 40))
        ..save()
        ..intersect(const Rect.fromLTRB(60, 60, 70, 70));
      expect(clip.isEmpty, isTrue);

      clip.restore();

      expect(clip.current, const Rect.fromLTRB(10, 10, 40, 40));
    });

    test('reuses its backing storage across repeated cycles', () {
      // The list behind the stack is never shrunk, so a restore leaves stale
      // numbers for the next save to overwrite. This drives that overwrite
      // path many times over and checks the clip is still exact - a save that
      // wrote to the wrong slot would show up here as drift.
      final clip = ClipStack.forDevice(100, 100);
      for (var i = 0; i < 1000; i++) {
        clip
          ..save()
          ..intersect(Rect.fromLTRB(1.0 + i % 5, 2, 50, 60))
          ..save()
          ..intersect(const Rect.fromLTRB(3, 4, 40, 50))
          ..restore()
          ..restore();
        expect(clip.current, const Rect.fromLTRB(0, 0, 100, 100));
        expect(clip.depth, 0);
      }
    });

    test('an unbalanced restore throws instead of silently clamping', () {
      final clip = ClipStack.forDevice(10, 10);

      expect(clip.restore, throwsStateError);

      clip
        ..save()
        ..restore();
      expect(clip.restore, throwsStateError);
    });
  });
}
