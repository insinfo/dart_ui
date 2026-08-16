/// Freeing, reusing and measuring the one shelf packer in the tree.
///
/// `gpu_shelf_atlas_test.dart` covers placement - where a slot lands and when
/// the packer refuses. This file covers everything the consolidation added:
/// giving a slot back, handing its texels to somebody else, and the number
/// that decides when the layout is worth repacking. Those are the parts that
/// can hand one region to two owners, which does not look like an allocator
/// bug from the screen - it looks like one shape wearing another's coverage.
library;

import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:test/test.dart';

void main() {
  group('GpuTextureFormat', () {
    test('a coverage mask is one byte and an image is four', () {
      expect(GpuTextureFormat.alpha8.bytesPerPixel, 1);
      expect(GpuTextureFormat.rgba8888Premultiplied.bytesPerPixel, 4);
    });

    test('the unbound texture id is zero, so a backend can bind it', () {
      expect(kNoTexture, 0);
    });
  });

  group('ShelfAtlas accounting', () {
    test('an empty atlas has no shelves, no waste and no rows committed', () {
      final atlas = ShelfAtlas(width: 64, height: 64);

      expect(atlas.liveCount, 0);
      expect(atlas.usedArea, 0);
      expect(atlas.reservedRows, 0);
      expect(atlas.fragmentation, 0);
    });

    test('used area counts the padding, because nobody else can use it', () {
      final atlas = ShelfAtlas(width: 64, height: 64);
      atlas.allocate(10, 10);

      // 12 by 12, not 10 by 10: the padding ring is space no other slot can
      // be given, so counting it as free would understate fragmentation.
      expect(atlas.usedArea, 144);
      expect(atlas.reservedRows, 12);
      expect(atlas.reservedArea, 12 * 64);
      expect(atlas.fragmentation, closeTo(1 - 144 / (12 * 64), 1e-12));
    });

    test('a short item on a tall shelf is measured as waste', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      atlas.allocate(32, 32); // opens a 32-row shelf
      atlas.allocate(32, 2); // and sits on it, wasting 30 rows of its column

      expect(atlas.reservedRows, 32);
      expect(atlas.usedArea, 32 * 32 + 32 * 2);
      // Exactly the number the repack policy reads: 62.5% of the committed
      // rows is carrying nothing.
      expect(atlas.fragmentation, closeTo(1 - 1088 / 2048.0, 1e-12));
    });

    test('canEverFit separates "full now" from "will never fit"', () {
      final atlas = ShelfAtlas(width: 32, height: 32);

      expect(atlas.maxSlotWidth, 30);
      expect(atlas.maxSlotHeight, 30);
      expect(atlas.canEverFit(30, 30), isTrue);
      expect(atlas.canEverFit(31, 30), isFalse);
      expect(atlas.canEverFit(30, 31), isFalse);
      expect(atlas.canEverFit(0, 10), isFalse);
      expect(atlas.canEverFit(-1, 10), isFalse);

      // Filling it does not change the answer: canEverFit is about the atlas,
      // not about its current contents.
      atlas.allocate(30, 30);
      expect(atlas.allocate(4, 4), isNull);
      expect(atlas.canEverFit(4, 4), isTrue);
    });
  });

  group('ShelfAtlas free', () {
    test('freeing the last slot on a shelf rolls the frontier back', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      atlas.allocate(10, 10);
      final second = atlas.allocate(10, 10)!;
      atlas.free(second);

      // The next item takes the same place, which is only true if the
      // frontier moved back rather than a hole being recorded past it.
      final again = atlas.allocate(10, 10)!;
      expect(again.x, second.x);
      expect(again.y, second.y);
      expect(atlas.shelfCount, 1);
    });

    test('a hole in the middle of a shelf is reused', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      atlas.allocate(10, 10);
      final middle = atlas.allocate(10, 10)!;
      atlas.allocate(10, 10);
      expect(middle.x, 10);

      atlas.free(middle);
      expect(atlas.liveCount, 2);
      final refill = atlas.allocate(10, 10)!;

      expect(refill.x, 10, reason: 'the hole, not the frontier');
      expect(refill.y, middle.y);
    });

    test('a hole splits, keeping the remainder usable', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      atlas.allocate(4, 10);
      final middle = atlas.allocate(20, 10)!;
      atlas.allocate(4, 10);
      atlas.free(middle);

      final first = atlas.allocate(8, 10)!;
      final second = atlas.allocate(8, 10)!;
      expect(first.x, 4);
      expect(second.x, 12, reason: 'the remaining 12 texels of the hole');
      // 4 texels of the hole are left, so a 5-wide item has to go elsewhere.
      final third = atlas.allocate(5, 10)!;
      expect(third.x, 28, reason: 'past the frontier, not into a 4px hole');
    });

    test('two adjacent holes merge into one that holds a wider item', () {
      // Without coalescing, a scrolling list of same-sized rows fragments the
      // atlas into stripes that nothing wider can ever use again.
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      atlas.allocate(4, 10);
      final a = atlas.allocate(10, 10)!;
      final b = atlas.allocate(10, 10)!;
      atlas.allocate(4, 10);

      atlas.free(a);
      atlas.free(b);
      final wide = atlas.allocate(20, 10)!;

      expect(wide.x, 4);
      expect(wide.y, a.y);
    });

    test('holes merge whichever order they are freed in', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      atlas.allocate(4, 10);
      final a = atlas.allocate(10, 10)!;
      final b = atlas.allocate(10, 10)!;
      atlas.allocate(4, 10);

      atlas.free(b);
      atlas.free(a);

      expect(atlas.allocate(20, 10)!.x, 4);
    });

    test('a hole that reaches the frontier becomes shelf, not hole', () {
      final atlas = ShelfAtlas(width: 32, height: 64, padding: 0);
      atlas.allocate(10, 10);
      final b = atlas.allocate(10, 10)!;
      final c = atlas.allocate(10, 10)!;
      atlas.free(c);
      atlas.free(b);

      // 22 texels are free at the right of the shelf. A 20-wide item fits
      // only if the two frees turned into frontier and not into a hole
      // followed by an untouched frontier.
      final wide = atlas.allocate(20, 10)!;
      expect(wide.x, 10);
    });

    test('draining an atlas returns it to exactly its initial state', () {
      final atlas = ShelfAtlas(width: 32, height: 32, padding: 0);
      final a = atlas.allocate(32, 16)!;
      final b = atlas.allocate(32, 16)!;
      expect(atlas.allocate(1, 1), isNull, reason: 'full');

      atlas
        ..free(b)
        ..free(a);

      expect(atlas.shelfCount, 0);
      expect(atlas.liveCount, 0);
      expect(atlas.reservedRows, 0);
      expect(atlas.usedArea, 0);
      expect(atlas.fragmentation, 0);
      // The proof that trailing empty shelves were dropped and not merely
      // emptied: a full-height item needs every row back.
      expect(atlas.allocate(32, 32), isNotNull);
    });

    test('an empty shelf between two live ones is kept and reused', () {
      final atlas = ShelfAtlas(width: 32, height: 64, padding: 0);
      atlas.allocate(32, 8); // shelf 0
      final middle = atlas.allocate(32, 8)!; // shelf 1, y = 8
      atlas.allocate(32, 8); // shelf 2, y = 16
      atlas.free(middle);

      // It cannot be dropped - shelf 2 sits below it - so it stays as an
      // empty shelf whose frontier is back at zero.
      expect(atlas.shelfCount, 3);
      final refill = atlas.allocate(32, 8)!;
      expect(refill.y, 8);
    });

    test('padding comes back with the slot', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 2);
      final slot = atlas.allocate(10, 10)!;
      expect(atlas.usedArea, 14 * 14);
      atlas.free(slot);
      expect(atlas.usedArea, 0);
      expect(atlas.shelfCount, 0);
    });

    test('freeing a slot this atlas never handed out throws', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      atlas.allocate(10, 10);

      // A plausible-looking slot on a shelf that exists, past everything ever
      // allocated on it. Accepting it would record free space that is not
      // free and eventually hand it to a second owner.
      expect(
        () => atlas.free(const AtlasSlot(40, 0, 10, 10)),
        throwsArgumentError,
      );
      // A slot on a row where no shelf starts.
      expect(
        () => atlas.free(const AtlasSlot(0, 5, 10, 10)),
        throwsArgumentError,
      );
      // Taller than the shelf it claims to be on.
      expect(
        () => atlas.free(const AtlasSlot(0, 0, 10, 40)),
        throwsArgumentError,
      );
    });

    test('a double free is caught while the space is still free', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      atlas.allocate(10, 10);
      final middle = atlas.allocate(10, 10)!;
      atlas.allocate(10, 10);

      atlas.free(middle);
      expect(() => atlas.free(middle), throwsArgumentError);
      expect(atlas.liveCount, 2, reason: 'the throw changed nothing');
    });

    test('reset forgets the live count and the waste with the shelves', () {
      final atlas = ShelfAtlas(width: 64, height: 64);
      atlas
        ..allocate(10, 10)
        ..allocate(20, 4)
        ..reset();

      expect(atlas.liveCount, 0);
      expect(atlas.usedArea, 0);
      expect(atlas.reservedRows, 0);
      expect(atlas.fragmentation, 0);
    });
  });

  group('ShelfAtlas free and reuse under churn', () {
    test('free then allocate never hands the same texel to two slots', () {
      // The property that matters. A deterministic churn - allocate a batch,
      // free every third, allocate again - is where a hole-merging bug
      // produces two overlapping live slots, and the overlap is what draws
      // one shape's coverage through another's quad.
      final atlas = ShelfAtlas(width: 128, height: 128);
      final live = <AtlasSlot>[];

      for (var round = 0; round < 6; round++) {
        for (var i = 0; i < 40; i++) {
          final w = 3 + (i * 7 + round * 5) % 29;
          final h = 3 + (i * 13 + round) % 17;
          final slot = atlas.allocate(w, h);
          if (slot == null) continue;
          live.add(slot);
        }
        for (var i = live.length - 1; i >= 0; i -= 3) {
          atlas.free(live.removeAt(i));
        }

        for (var i = 0; i < live.length; i++) {
          final a = live[i];
          expect(a.x >= 0 && a.y >= 0, isTrue);
          expect(a.x + a.width <= atlas.width, isTrue);
          expect(a.y + a.height <= atlas.height, isTrue);
          for (var j = i + 1; j < live.length; j++) {
            final b = live[j];
            final disjoint = a.x + a.width <= b.x ||
                b.x + b.width <= a.x ||
                a.y + a.height <= b.y ||
                b.y + b.height <= a.y;
            expect(disjoint, isTrue, reason: '$a overlaps $b');
          }
        }
      }

      expect(live.length, greaterThan(20));
      expect(atlas.liveCount, live.length);
    });

    test('churn without freeing everything still drains to empty', () {
      final atlas = ShelfAtlas(width: 64, height: 64);
      final live = <AtlasSlot>[];
      for (var i = 0; i < 30; i++) {
        final slot = atlas.allocate(4 + i % 9, 4 + i % 5);
        if (slot != null) live.add(slot);
      }
      for (final slot in live) {
        atlas.free(slot);
      }

      expect(atlas.liveCount, 0);
      expect(atlas.shelfCount, 0);
      expect(atlas.reservedRows, 0);
    });
  });
}
