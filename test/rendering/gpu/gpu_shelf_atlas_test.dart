/// Shelf packing: the placements, the padding, and running out of room.
///
/// The packer is the one piece of the GPU path that can corrupt a frame
/// without any GL call being wrong: two slots that overlap draw one shape's
/// coverage through another's quad, and the result looks like a rasteriser
/// bug. So the overlap check below is done exhaustively rather than by
/// spot-checking coordinates.
library;

import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:test/test.dart';

void main() {
  group('ShelfAtlas placement', () {
    test('the first slot sits at the padding, not at the origin', () {
      final atlas = ShelfAtlas(width: 64, height: 64);
      final slot = atlas.allocate(10, 10)!;

      expect(slot.x, 1);
      expect(slot.y, 1);
      expect(slot.width, 10);
      expect(slot.height, 10);
      expect(atlas.shelfCount, 1);
    });

    test('padding zero packs flush against the edge', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      final slot = atlas.allocate(10, 10)!;

      expect(slot.x, 0);
      expect(slot.y, 0);
    });

    test('items of one height fill a shelf left to right', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 0);
      final first = atlas.allocate(10, 10)!;
      final second = atlas.allocate(10, 10)!;
      final third = atlas.allocate(10, 10)!;

      expect(<int>[first.x, second.x, third.x], <int>[0, 10, 20]);
      expect(<int>[first.y, second.y, third.y], <int>[0, 0, 0]);
      expect(atlas.shelfCount, 1);
    });

    test('a full row opens the next shelf below it', () {
      final atlas = ShelfAtlas(width: 32, height: 64, padding: 0);
      atlas.allocate(20, 10);
      final wrapped = atlas.allocate(20, 10)!;

      expect(wrapped.x, 0);
      expect(wrapped.y, 10);
      expect(atlas.shelfCount, 2);
    });

    test('best fit chooses the tightest shelf that still fits', () {
      // Both shelves have room for the small item, and the tall one is
      // scanned first: first fit would drop the 4-pixel item onto the
      // 40-pixel shelf and waste 36 rows of column for the rest of the frame.
      final atlas = ShelfAtlas(width: 64, height: 128, padding: 0);
      atlas.allocate(50, 40); // shelf A, height 40, at y = 0, 14 px left
      atlas.allocate(20, 8); // too wide for A, so shelf B opens at y = 40
      final small = atlas.allocate(4, 4)!;

      expect(small.y, 40, reason: 'the 4px item belongs on the 8px shelf');
    });

    test('a shelf too short for the item is skipped, not grown', () {
      final atlas = ShelfAtlas(width: 64, height: 128, padding: 0);
      atlas.allocate(10, 8); // shelf at y = 0, height 8
      final tall = atlas.allocate(10, 30)!;

      expect(tall.y, 8, reason: 'a 30px item cannot live on an 8px shelf');
      expect(atlas.shelfCount, 2);
    });

    test('padding separates neighbours on the same shelf', () {
      final atlas = ShelfAtlas(width: 64, height: 64, padding: 2);
      final first = atlas.allocate(10, 10)!;
      final second = atlas.allocate(10, 10)!;

      // Four texels of gap: two of the first slot's padding and two of the
      // second's. This is what stops linear filtering bleeding one shape's
      // coverage into its neighbour.
      expect(second.x - (first.x + first.width), 4);
    });

    test('no two slots ever overlap', () {
      final atlas = ShelfAtlas(width: 128, height: 128);
      final placed = <AtlasSlot>[];
      // Deterministic but irregular sizes, so shelves of several heights are
      // open at once and best fit has real choices to make.
      for (var i = 0; i < 200; i++) {
        final w = 3 + (i * 7) % 29;
        final h = 3 + (i * 13) % 17;
        final slot = atlas.allocate(w, h);
        if (slot == null) break;
        placed.add(slot);
      }
      expect(placed.length, greaterThan(20));

      for (var i = 0; i < placed.length; i++) {
        final a = placed[i];
        expect(a.x >= 0 && a.y >= 0, isTrue);
        expect(a.x + a.width <= atlas.width, isTrue);
        expect(a.y + a.height <= atlas.height, isTrue);
        for (var j = i + 1; j < placed.length; j++) {
          final b = placed[j];
          final disjoint = a.x + a.width <= b.x ||
              b.x + b.width <= a.x ||
              a.y + a.height <= b.y ||
              b.y + b.height <= a.y;
          expect(disjoint, isTrue, reason: '$a overlaps $b');
        }
      }
    });
  });

  group('ShelfAtlas exhaustion', () {
    test('an item wider than the atlas is refused, not clipped', () {
      final atlas = ShelfAtlas(width: 32, height: 32, padding: 0);
      expect(atlas.allocate(33, 8), isNull);
      expect(atlas.allocate(8, 33), isNull);
    });

    test('padding counts against the limit', () {
      // An item exactly as wide as the atlas does not fit once it is padded,
      // and reporting that it does would place it past the right edge.
      final atlas = ShelfAtlas(width: 32, height: 32);
      expect(atlas.allocate(32, 8), isNull);
      expect(atlas.allocate(30, 8), isNotNull);
    });

    test('a degenerate size is refused rather than reserving nothing', () {
      final atlas = ShelfAtlas(width: 32, height: 32);
      expect(atlas.allocate(0, 8), isNull);
      expect(atlas.allocate(8, 0), isNull);
      expect(atlas.allocate(-1, 8), isNull);
      expect(atlas.shelfCount, 0);
    });

    test('a full atlas returns null instead of throwing', () {
      // Fullness is a steady state for a caller that knows how to flush, so
      // it has to be a value. The sink turns it into an error only because
      // mid-frame flushing does not exist yet.
      final atlas = ShelfAtlas(width: 16, height: 16, padding: 0);
      expect(atlas.allocate(16, 8), isNotNull);
      expect(atlas.allocate(16, 8), isNotNull);
      expect(atlas.allocate(1, 1), isNull);
    });

    test('exhaustion is permanent until reset', () {
      final atlas = ShelfAtlas(width: 16, height: 16, padding: 0);
      atlas.allocate(16, 16);
      expect(atlas.allocate(1, 1), isNull);
      expect(atlas.allocate(1, 1), isNull);

      atlas.reset();
      expect(atlas.shelfCount, 0);
      expect(atlas.allocate(1, 1), isNotNull);
    });

    test('reset returns the packer to its initial placements', () {
      final atlas = ShelfAtlas(width: 64, height: 64);
      final before = atlas.allocate(10, 10)!;
      atlas
        ..allocate(10, 10)
        ..allocate(20, 30)
        ..reset();
      final after = atlas.allocate(10, 10)!;

      expect(after.x, before.x);
      expect(after.y, before.y);
    });
  });
}
