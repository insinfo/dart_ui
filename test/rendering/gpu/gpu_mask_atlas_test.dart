/// The coverage-mask atlas: what it writes, where, what it keeps, what it
/// throws away, and what it refuses.
///
/// The whole antialiasing strategy for paths on the GPU rests on this file
/// producing the *same* coverage bytes the CPU rasteriser produces, in a slot
/// whose texture coordinates map one texel to one pixel. Both halves are
/// checked here, on the CPU, because both are wrong in ways that look like a
/// shader bug from the other side of an upload.
///
/// The cache tests carry the same weight for a different reason. A key that
/// is missing a component does not fail - it *succeeds*, with the wrong
/// pixels, on the second frame, for one shape, and only when two shapes
/// happen to differ in exactly the component that was left out. So there is
/// one test per component of the key, each changing that component alone and
/// asserting a re-rasterisation, and the rasterisation counter is the atlas's
/// own, not a spy that could disagree with it.
library;

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_atlas.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

const Rect _clip = Rect.fromLTRB(0, 0, 500, 500);

void main() {
  group('GpuMaskAtlas rasterize', () {
    test('a rectangle path fills its interior texels solid', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final quad = atlas.rasterize(
        _rect(const Rect.fromLTRB(2, 3, 12, 13)),
        transform: Transform2D.identity,
        clip: _clip,
      )!;

      expect(quad.deviceRect, const Rect.fromLTRB(2, 3, 12, 13));
      // Whole pixels inside the shape must be full coverage; anything less
      // means the filler and the slot disagree about the origin.
      final centre = _texel(atlas, quad.u0, quad.v0, 5, 5);
      expect(centre, 255);
    });

    test('the device rect is snapped outward to whole pixels', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final quad = atlas.rasterize(
        _rect(const Rect.fromLTRB(2.4, 3.6, 11.1, 12.9)),
        transform: Transform2D.identity,
        clip: _clip,
      )!;

      // The mask has to contain every pixel the shape touches even partially,
      // because the quad drawn from it is the only place those pixels get
      // shaded.
      expect(quad.deviceRect, const Rect.fromLTRB(2, 3, 12, 13));
    });

    test('texture coordinates are texel edges, one texel per pixel', () {
      final atlas = GpuMaskAtlas(width: 64, height: 32);
      final quad = atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 10, 20)),
        transform: Transform2D.identity,
        clip: _clip,
      )!;

      // Edges rather than centres: the quad is exactly as many device pixels
      // as the slot is texels, so with nearest filtering pixel centres land
      // on texel centres. Half-texel offsets here shift the mask by half a
      // pixel, which reads as a blurred or doubled edge.
      expect((quad.u1 - quad.u0) * atlas.width, closeTo(10, 1e-6));
      expect((quad.v1 - quad.v0) * atlas.height, closeTo(20, 1e-6));
    });

    test('a slot reused after an eviction is cleared before it is filled', () {
      // Slots are reused memory. The filler only writes covered spans, so
      // without the clear the uncovered interior of a shape shows the evicted
      // mask's coverage - a ghost of whatever was there.
      final atlas = GpuMaskAtlas(width: 32, height: 32);
      final first = atlas.rasterizeMask(
        _rect(const Rect.fromLTRB(0, 0, 20, 20)),
        transform: Transform2D.identity,
        clip: _clip,
      );
      atlas.beginFrame();

      final triangle = PathBuilder()
        ..moveTo(0, 0)
        ..lineTo(20, 0)
        ..lineTo(0, 20)
        ..close();
      final second = atlas.rasterizeMask(
        triangle.build(),
        transform: Transform2D.identity,
        clip: _clip,
      );

      // Only one 22x22 padded slot fits in a 32x32 atlas, so the triangle can
      // only be placed by evicting the rectangle and taking its texels.
      expect(atlas.evictionCount, 1);
      expect(second.u0, first.u0);
      expect(second.v0, first.v0);
      expect(second.deviceRect, first.deviceRect);
      // Bottom-right corner is outside the triangle and was solid before.
      expect(_texel(atlas, second.u0, second.v0, 18, 18), 0);
    });

    test('an invisible shape is empty, not an error and not a slot', () {
      final atlas = GpuMaskAtlas(width: 32, height: 32);
      final result = atlas.rasterizeMask(
        _rect(const Rect.fromLTRB(100, 100, 110, 110)),
        transform: Transform2D.identity,
        clip: const Rect.fromLTRB(0, 0, 50, 50),
      );

      expect(result.status, MaskRasterStatus.empty);
      expect(atlas.isDirty, isFalse);
      expect(atlas.cachedMaskCount, 0, reason: 'nothing to cache');
      expect(atlas.rasterizationCount, 0);
    });

    test('a non-finite device rectangle is empty rather than an exception', () {
      // NaN survives Rect.isEmpty (every comparison against NaN is false) and
      // then throws out of floor(). A shape at an undefined position covers
      // no definable pixel, which is the same thing as being clipped away.
      final atlas = GpuMaskAtlas(width: 32, height: 32);
      final result = atlas.rasterizeMask(
        _rect(const Rect.fromLTRB(0, 0, 10, 10)),
        transform: const Transform2D.translation(double.nan, 0),
        clip: _clip,
      );

      expect(result.status, MaskRasterStatus.empty);
      expect(atlas.cachedMaskCount, 0);
    });

    test('an aliased mask is the same coverage thresholded at half a pixel',
        () {
      final diagonal = PathBuilder()
        ..moveTo(0, 0)
        ..lineTo(10, 0)
        ..lineTo(0, 10)
        ..close();
      final path = diagonal.build();

      final soft = GpuMaskAtlas(width: 32, height: 32);
      final softMask = soft.rasterizeMask(
        path,
        transform: Transform2D.identity,
        clip: _clip,
      );
      final hard = GpuMaskAtlas(width: 32, height: 32);
      final hardMask = hard.rasterizeMask(
        path,
        transform: Transform2D.identity,
        clip: _clip,
        antiAlias: false,
      );

      var softPartials = 0;
      var hardPartials = 0;
      for (var y = 0; y < 10; y++) {
        for (var x = 0; x < 10; x++) {
          final s = _texel(soft, softMask.u0, softMask.v0, x, y);
          final h = _texel(hard, hardMask.u0, hardMask.v0, x, y);
          if (s > 0 && s < 255) softPartials++;
          if (h > 0 && h < 255) hardPartials++;
          // The threshold is on coverage, so the hard mask is the soft one
          // rounded: a texel the soft mask left empty cannot become ink.
          if (s == 0) expect(h, 0);
        }
      }
      expect(softPartials, greaterThan(4), reason: 'a diagonal is soft');
      expect(hardPartials, 0, reason: 'nothing between 0 and 255');
    });
  });

  group('GpuMaskAtlas cache', () {
    test('read-only cache probe predicts a hit without touching statistics',
        () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(2, 3, 12, 13));

      expect(
        atlas.containsMask(
          path,
          transform: Transform2D.identity,
          clip: _clip,
        ),
        isFalse,
      );
      _draw(atlas, path);
      final int hits = atlas.cacheHitCount;
      final int lookups = atlas.maskLookupCount;
      expect(
        atlas.containsMask(
          path,
          transform: const Transform2D.translation(5, 7),
          clip: _clip,
        ),
        isTrue,
        reason: 'whole-pixel translation preserves the coverage bytes',
      );
      expect(atlas.cacheHitCount, hits);
      expect(atlas.maskLookupCount, lookups);
      expect(atlas.isDirty, isTrue,
          reason: 'the existing miss dirtied it, not the probe');
    });

    test('the same shape twice in one frame rasterises once', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(2, 3, 12, 13));

      final first = _draw(atlas, path);
      final second = _draw(atlas, path);

      expect(atlas.rasterizationCount, 1);
      expect(atlas.cacheHitCount, 1);
      expect(atlas.maskLookupCount, 2);
      expect(second.u0, first.u0);
      expect(second.v0, first.v0);
      expect(second.deviceRect, first.deviceRect);
    });

    test('a shape that survives a frame boundary is not rasterised again', () {
      // The defect this cache exists to fix: beginFrame used to reset the
      // packer, so a static icon cost a full CPU rasterisation every frame
      // and the "GPU path" accelerated nothing but the compositing.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(2, 3, 12, 13));

      final first = _draw(atlas, path);
      atlas.beginFrame();
      final second = _draw(atlas, path);
      atlas.beginFrame();
      final third = _draw(atlas, path);

      expect(atlas.rasterizationCount, 1);
      expect(atlas.cacheHitCount, 2);
      expect(second.u0, first.u0);
      expect(third.u0, first.u0);
    });

    test('a cache hit writes nothing, so it dirties nothing', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(2, 3, 12, 13));
      _draw(atlas, path);
      atlas.markUploaded();

      _draw(atlas, path);

      expect(atlas.isDirty, isFalse,
          reason: 'a hit re-uploading its slot would waste the whole point');
    });

    test('two separately built copies of one shape are one mask', () {
      // Path equality is by content, which is what makes a UI that rebuilds
      // its geometry every frame - the normal case - cache at all.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      _draw(atlas, _rect(const Rect.fromLTRB(2, 3, 12, 13)));
      _draw(atlas, _rect(const Rect.fromLTRB(2, 3, 12, 13)));

      expect(atlas.rasterizationCount, 1);
      expect(atlas.cachedMaskCount, 1);
    });

    test('a whole-pixel move reuses the mask at a new address', () {
      // The reason the key stores the sub-pixel phase and not the raw
      // translation: shifting a shape by whole pixels produces the identical
      // coverage bytes, and re-rasterising them would be pure waste.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(2, 3, 12, 13));

      final still = _draw(atlas, path);
      final moved = _draw(atlas, path, at: const Transform2D.translation(5, 7));

      expect(atlas.rasterizationCount, 1, reason: 'same bytes, new address');
      expect(moved.u0, still.u0);
      expect(moved.v0, still.v0);
      expect(moved.deviceRect, const Rect.fromLTRB(7, 10, 17, 20));
    });

    test('a sub-pixel move rasterises again even at the same size', () {
      // A shape already sitting on a fractional boundary, moved by half a
      // pixel: the snapped window is the same size in the same place, and the
      // coverage inside it is completely different. A key that quantised the
      // phase would return the first mask here and shift the shape.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(2.25, 3.25, 12.25, 13.25));

      final first = _draw(atlas, path);
      final second =
          _draw(atlas, path, at: const Transform2D.translation(0.5, 0));

      expect(first.deviceRect, second.deviceRect,
          reason: 'same window, so only the phase can have caused the miss');
      expect(atlas.rasterizationCount, 2);
      expect(atlas.cacheHitCount, 0);
    });

    test('a scale change rasterises again', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(0, 0, 10, 10));

      _draw(atlas, path);
      _draw(atlas, path, at: const Transform2D.scaling(2, 2));

      expect(atlas.rasterizationCount, 2);
    });

    test('a rotation rasterises again even at the same size', () {
      // 180 degrees about the shape's own centre: the device bounds, the
      // phase and the size are all unchanged, and only a, b, c and d differ.
      // Without them in the key an asymmetric shape would come out mirrored.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final triangle = PathBuilder()
        ..moveTo(-5, -5)
        ..lineTo(5, -5)
        ..lineTo(-5, 5)
        ..close();
      final path = triangle.build();
      const centred = Transform2D.translation(20, 20);
      final turned = centred.multiply(Transform2D.rotation(3.141592653589793));

      final first = _draw(atlas, path, at: centred);
      final second = _draw(atlas, path, at: turned);

      expect(first.deviceRect, second.deviceRect);
      expect(atlas.rasterizationCount, 2);
      // And the two masks really are different pixels, so returning the first
      // for the second would have drawn the triangle the wrong way round.
      expect(
        _texel(atlas, second.u0, second.v0, 8, 8),
        isNot(_texel(atlas, first.u0, first.v0, 8, 8)),
      );
    });

    test('a fill rule change rasterises again', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      // Two overlapping contours wound the same way: solid under non-zero,
      // holed under even-odd.
      final path = (PathBuilder()
            ..addRect(const Rect.fromLTRB(0, 0, 12, 12))
            ..addRect(const Rect.fromLTRB(4, 4, 16, 16)))
          .build();

      final nonZero = _draw(atlas, path);
      final evenOdd = _draw(atlas, path, rule: FillRule.evenOdd);

      expect(atlas.rasterizationCount, 2);
      expect(_texel(atlas, nonZero.u0, nonZero.v0, 6, 6), 255);
      expect(_texel(atlas, evenOdd.u0, evenOdd.v0, 6, 6), 0,
          reason: 'the overlap is a hole under even-odd');
    });

    test('an anti-alias change rasterises again', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final triangle = PathBuilder()
        ..moveTo(0, 0)
        ..lineTo(10, 0)
        ..lineTo(0, 10)
        ..close();
      final path = triangle.build();

      _draw(atlas, path);
      _draw(atlas, path, antiAlias: false);

      expect(atlas.rasterizationCount, 2);
      expect(atlas.cachedMaskCount, 2);
    });

    test('a clip that shrinks the window rasterises again', () {
      // The clip is not in the key literally - it acts through the snapped
      // window - so this is the test that says the indirection is complete.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(0, 0, 20, 20));

      final whole = _draw(atlas, path);
      final half = _draw(atlas, path, clip: const Rect.fromLTRB(0, 0, 10, 20));

      expect(atlas.rasterizationCount, 2);
      expect(whole.deviceRect, const Rect.fromLTRB(0, 0, 20, 20));
      expect(half.deviceRect, const Rect.fromLTRB(0, 0, 10, 20));
    });

    test('a clip that does not cut the shape does not rasterise again', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final path = _rect(const Rect.fromLTRB(0, 0, 20, 20));

      _draw(atlas, path);
      _draw(atlas, path, clip: const Rect.fromLTRB(-50, -50, 300, 300));

      expect(atlas.rasterizationCount, 1);
    });
  });

  group('GpuMaskAtlas eviction', () {
    test('the least recently used mask is the one that goes', () {
      final atlas = _fourSlotAtlas();
      final shapes = _fourShapes();
      for (final shape in shapes) {
        _draw(atlas, shape);
      }
      expect(atlas.rasterizationCount, 4);
      expect(atlas.cachedMaskCount, 4);

      // Frame two: use the first two, leaving the third as the oldest.
      atlas.beginFrame();
      _draw(atlas, shapes[0]);
      _draw(atlas, shapes[1]);
      final fifth = _draw(atlas, _shapeAt(80));
      expect(fifth.status, MaskRasterStatus.ok);
      expect(atlas.evictionCount, 1);
      expect(atlas.rasterizationCount, 5);

      // Frame three: the two that were used and the one that was not touched
      // in frame two but was newer than the victim are all still cached, and
      // a lookup that hits allocates nothing, so none of these can disturb
      // the order before the last assertion.
      atlas.beginFrame();
      _draw(atlas, shapes[0]);
      _draw(atlas, shapes[1]);
      _draw(atlas, shapes[3]);
      expect(atlas.rasterizationCount, 5, reason: 'three survivors, no work');

      // And the one that went is exactly the one the policy names.
      _draw(atlas, shapes[2]);
      expect(atlas.rasterizationCount, 6);
    });

    test('a mask already used this frame is never evicted', () {
      final atlas = _fourSlotAtlas();
      final shapes = _fourShapes();
      for (final shape in shapes) {
        _draw(atlas, shape);
      }

      atlas.beginFrame();
      for (final shape in shapes) {
        _draw(atlas, shape);
      }
      final overflow = _draw(atlas, _shapeAt(80));

      // Every texel is under a quad that has been batched and not yet drawn.
      // Evicting one would repaint an earlier shape with this one's coverage.
      expect(overflow.status, MaskRasterStatus.needsFlush);
      expect(atlas.evictionCount, 0);
      expect(atlas.rasterizationCount, 4);
    });

    test('stale masks are evicted rather than reported as a full atlas', () {
      final atlas = _fourSlotAtlas();
      for (final shape in _fourShapes()) {
        _draw(atlas, shape);
      }

      atlas.beginFrame();
      final overflow = _draw(atlas, _shapeAt(80));

      expect(overflow.status, MaskRasterStatus.ok);
      expect(atlas.evictionCount, 1);
      expect(atlas.cachedMaskCount, 4);
    });

    test('eviction frees the packer, not just the map', () {
      final atlas = _fourSlotAtlas();
      for (final shape in _fourShapes()) {
        _draw(atlas, shape);
      }
      expect(atlas.shelfCount, 2);

      for (var frame = 0; frame < 8; frame++) {
        atlas.beginFrame();
        _draw(atlas, _shapeAt(100 + frame * 20));
      }

      // Eight more masks through a four-slot atlas: the space has to be
      // genuinely returned each time, or the fifth would have signalled a
      // flush and the count would have stopped rising.
      expect(atlas.rasterizationCount, 12);
      expect(atlas.cachedMaskCount, 4);
      expect(atlas.shelfCount, lessThanOrEqualTo(2));
    });
  });

  group('GpuMaskAtlas flush cycle', () {
    test('a full atlas signals a flush instead of failing the frame', () {
      final atlas = _fourSlotAtlas();
      final shapes = _fourShapes();
      for (final shape in shapes) {
        _draw(atlas, shape);
      }
      atlas.beginFrame();
      for (final shape in shapes) {
        _draw(atlas, shape);
      }

      final blocked = _draw(atlas, _shapeAt(80));
      expect(blocked.status, MaskRasterStatus.needsFlush);
      expect(blocked.isOk, isFalse);

      // The backend's half of the protocol: submit, upload, recycle, retry.
      atlas.markUploaded();
      atlas.recycle();
      expect(atlas.cachedMaskCount, 0);
      expect(atlas.shelfCount, 0);
      expect(atlas.isDirty, isFalse);

      final retried = _draw(atlas, _shapeAt(80));
      expect(retried.status, MaskRasterStatus.ok);
      expect(atlas.rasterizationCount, 5);
    });

    test('recycle keeps the pixels it stops describing', () {
      // The texels are not cleared, because whoever takes the slot next
      // writes all of it. Clearing a megabyte to hide bytes nobody samples is
      // pure cost.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final quad = _draw(atlas, _rect(const Rect.fromLTRB(0, 0, 10, 10)));
      final before = _texel(atlas, quad.u0, quad.v0, 5, 5);
      atlas.recycle();

      expect(before, 255);
      expect(_texel(atlas, quad.u0, quad.v0, 5, 5), 255);
    });

    test('the legacy null result merges the three failures back together', () {
      final atlas = _fourSlotAtlas();
      final shapes = _fourShapes();
      for (final shape in shapes) {
        _draw(atlas, shape);
      }
      atlas.beginFrame();
      for (final shape in shapes) {
        _draw(atlas, shape);
      }

      // All three of these are null through the old entry point, which is
      // exactly why the sink cannot tell a clipped-away shape from a full
      // atlas and turns both into a capability error.
      expect(
        atlas.rasterize(
          _shapeAt(80),
          transform: Transform2D.identity,
          clip: _clip,
        ),
        isNull,
      );
      expect(
        atlas.rasterize(
          _rect(const Rect.fromLTRB(0, 0, 10, 10)),
          transform: Transform2D.identity,
          clip: const Rect.fromLTRB(200, 200, 300, 300),
        ),
        isNull,
      );
      expect(
        atlas.rasterize(
          _rect(const Rect.fromLTRB(0, 0, 400, 400)),
          transform: Transform2D.identity,
          clip: _clip,
        ),
        isNull,
      );
    });
  });

  group('GpuMaskAtlas shapes larger than the atlas', () {
    test('a shape too big for an empty atlas is named, not merely refused', () {
      final atlas = GpuMaskAtlas(width: 32, height: 32);

      expect(atlas.maxMaskWidth, 30);
      expect(atlas.maxMaskHeight, 30);
      // tooLarge and not needsFlush: flushing would change nothing, and a
      // caller that retried would loop forever.
      expect(
        _draw(atlas, _rect(const Rect.fromLTRB(0, 0, 200, 200))).status,
        MaskRasterStatus.tooLarge,
      );
      expect(
        _draw(atlas, _rect(const Rect.fromLTRB(0, 0, 31, 10))).status,
        MaskRasterStatus.tooLarge,
      );
      expect(
        _draw(atlas, _rect(const Rect.fromLTRB(0, 0, 30, 30))).status,
        MaskRasterStatus.ok,
      );
      expect(atlas.rasterizationCount, 1, reason: 'refusals cost nothing');
    });

    test('tiling by clip reproduces the mask the atlas could not hold', () {
      // The documented recipe on MaskRasterStatus.tooLarge, verified rather
      // than asserted: because the clip acts on the mask through the window
      // it leaves, one call per tile produces exactly the bytes one
      // impossible full-size mask would have carried. If this ever stops
      // being true, the recipe is a lie and the constant's documentation has
      // to change with it.
      final shape =
          (PathBuilder()..addOval(const Rect.fromLTRB(5, 5, 45, 45))).build();

      final reference = GpuMaskAtlas(width: 128, height: 128);
      final whole = _draw(reference, shape);
      expect(whole.deviceRect, const Rect.fromLTRB(5, 5, 45, 45));

      final tiled = GpuMaskAtlas(width: 32, height: 32);
      expect(_draw(tiled, shape).status, MaskRasterStatus.tooLarge);

      const tiles = <Rect>[
        Rect.fromLTRB(5, 5, 25, 25),
        Rect.fromLTRB(25, 5, 45, 25),
        Rect.fromLTRB(5, 25, 25, 45),
        Rect.fromLTRB(25, 25, 45, 45),
      ];
      var compared = 0;
      for (final tile in tiles) {
        // One flush cycle per tile, which is what a backend driving this
        // would do: only one 20x20 mask fits in this atlas at a time.
        tiled.recycle();
        final part = _draw(tiled, shape, clip: tile);
        expect(part.status, MaskRasterStatus.ok);
        expect(part.deviceRect, tile);

        for (var y = 0; y < 20; y++) {
          for (var x = 0; x < 20; x++) {
            final deviceX = tile.left.toInt() + x;
            final deviceY = tile.top.toInt() + y;
            expect(
              _texel(tiled, part.u0, part.v0, x, y),
              _texel(
                reference,
                whole.u0,
                whole.v0,
                deviceX - 5,
                deviceY - 5,
              ),
              reason: 'tile coverage differs at device ($deviceX, $deviceY)',
            );
            compared++;
          }
        }
      }
      expect(compared, 1600);
    });
  });

  group('GpuMaskAtlas compaction', () {
    test('fragmentation counts the rows a shelf reserved and did not use', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      _draw(atlas, _rect(const Rect.fromLTRB(0, 0, 30, 30)));
      expect(atlas.fragmentation, closeTo(1 - 1024 / (32 * 64), 1e-12));

      // A 2-pixel-tall mask on the 32-row shelf: 30 rows of its column are
      // now reserved and empty, and only a repack can get them back.
      _draw(atlas, _rect(const Rect.fromLTRB(0, 40, 30, 42)));
      expect(atlas.fragmentation, closeTo(1 - 1152 / (32 * 64), 1e-12));
    });

    test('a repack recovers the rows and keeps every mask', () {
      final atlas = GpuMaskAtlas(
        width: 64,
        height: 64,
        compactionThreshold: 0.4,
      );
      final tall = _rect(const Rect.fromLTRB(0, 0, 30, 30));
      final flat = _rect(const Rect.fromLTRB(0, 40, 30, 42));
      final other = _rect(const Rect.fromLTRB(100, 0, 130, 30));

      _draw(atlas, tall);
      _draw(atlas, flat);
      _draw(atlas, other);
      expect(atlas.rasterizationCount, 3);
      expect(atlas.shelfCount, 2);
      expect(atlas.fragmentation, closeTo(1 - 2176 / 4096, 1e-12));

      atlas.beginFrame();

      expect(atlas.compactionCount, 1);
      // Two 32-row shelves became one 32-row shelf holding both tall masks
      // and one 4-row shelf holding the flat one: 36 rows instead of 64.
      expect(atlas.shelfCount, 2);
      expect(atlas.fragmentation, closeTo(1 - 2176 / (36 * 64), 1e-12));
      expect(atlas.cachedMaskCount, 3);

      // Moved, not rebuilt: a repack copies bytes and must never spend the
      // CPU rasterisation the cache exists to avoid.
      final movedTall = _draw(atlas, tall);
      final movedFlat = _draw(atlas, flat);
      final movedOther = _draw(atlas, other);
      expect(atlas.rasterizationCount, 3);
      expect(_texel(atlas, movedTall.u0, movedTall.v0, 15, 15), 255);
      expect(_texel(atlas, movedFlat.u0, movedFlat.v0, 15, 1), 255);
      expect(_texel(atlas, movedOther.u0, movedOther.v0, 15, 15), 255);
    });

    test('a repack dirties the whole atlas, because every texel may move', () {
      final atlas = GpuMaskAtlas(
        width: 64,
        height: 64,
        compactionThreshold: 0.4,
      );
      _draw(atlas, _rect(const Rect.fromLTRB(0, 0, 30, 30)));
      _draw(atlas, _rect(const Rect.fromLTRB(0, 40, 30, 42)));
      _draw(atlas, _rect(const Rect.fromLTRB(100, 0, 130, 30)));

      atlas.beginFrame();

      expect(atlas.isDirty, isTrue);
      expect(atlas.dirtyLeft, 0);
      expect(atlas.dirtyTop, 0);
      expect(atlas.dirtyRight, 64);
      expect(atlas.dirtyBottom, 64);
    });

    test('a layout a repack cannot improve is not repacked every frame', () {
      // Masks of one height pack into the same shelves however they are
      // ordered, so the waste above them is irreducible. Without the
      // anti-thrash rule this layout would copy and re-upload the whole atlas
      // on every single frame, forever, for nothing.
      final atlas = GpuMaskAtlas(
        width: 32,
        height: 32,
        compactionThreshold: 0.4,
      );
      _draw(atlas, _shapeAt(0));
      _draw(atlas, _shapeAt(20));
      _draw(atlas, _shapeAt(40));
      expect(atlas.fragmentation, closeTo(1 - 432 / 768, 1e-12));

      atlas.beginFrame();
      expect(atlas.compactionCount, 1);
      final after = atlas.fragmentation;

      atlas.beginFrame();
      atlas.beginFrame();
      expect(atlas.compactionCount, 1, reason: 'no repack can beat this');
      expect(atlas.fragmentation, after);
    });

    test('an empty atlas is never worth repacking', () {
      final atlas = GpuMaskAtlas(width: 32, height: 32);
      atlas.beginFrame();
      atlas.beginFrame();

      expect(atlas.compactionCount, 0);
      expect(atlas.fragmentation, 0);
    });
  });

  group('GpuMaskAtlas dirty region', () {
    test('a fresh atlas has nothing to upload', () {
      expect(GpuMaskAtlas(width: 32, height: 32).isDirty, isFalse);
    });

    test('the dirty region grows to contain every slot written', () {
      final atlas = GpuMaskAtlas(width: 128, height: 128);
      atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 10, 10)),
        transform: Transform2D.identity,
        clip: _clip,
      );
      atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 40, 40)),
        transform: Transform2D.identity,
        clip: _clip,
      );

      expect(atlas.isDirty, isTrue);
      // One texel in on both axes: the packer pads every slot so that turning
      // on linear filtering later cannot bleed one shape into its neighbour.
      expect(atlas.dirtyLeft, 1);
      expect(atlas.dirtyTop, 1);
      // Two shelves, so the region spans both; uploading less would leave the
      // second shape sampling whatever the texture held before.
      expect(atlas.dirtyBottom, greaterThanOrEqualTo(42));
      expect(atlas.dirtyRight, greaterThanOrEqualTo(40));
    });

    test('markUploaded clears the region without clearing the pixels', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final quad = atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 10, 10)),
        transform: Transform2D.identity,
        clip: _clip,
      )!;
      atlas.markUploaded();

      expect(atlas.isDirty, isFalse);
      expect(_texel(atlas, quad.u0, quad.v0, 5, 5), 255,
          reason: 'the texels are still the ones that were uploaded');
    });

    test('beginFrame consumes the dirty region and keeps the packing', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 10, 10)),
        transform: Transform2D.identity,
        clip: _clip,
      );
      expect(atlas.shelfCount, 1);

      atlas.beginFrame();

      expect(atlas.isDirty, isFalse);
      expect(atlas.shelfCount, 1, reason: 'the mask is still on the GPU');
      expect(atlas.cachedMaskCount, 1);
      expect(atlas.frameIndex, 1);
    });

    test('recycle is what drops the packing', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 10, 10)),
        transform: Transform2D.identity,
        clip: _clip,
      );

      atlas.recycle();

      expect(atlas.shelfCount, 0);
      expect(atlas.cachedMaskCount, 0);
    });
  });
}

Path _rect(Rect rect) => (PathBuilder()..addRect(rect)).build();

/// A 10x10 square at ([offset], [offset]), distinct from every other offset
/// in both its geometry and its sub-pixel phase.
Path _shapeAt(double offset) => _rect(Rect.fromLTWH(offset, offset, 10, 10));

/// An atlas that holds exactly four 10x10 masks: 12x12 padded, two per
/// 12-row shelf, two shelves in 32 rows.
GpuMaskAtlas _fourSlotAtlas() => GpuMaskAtlas(width: 32, height: 32);

List<Path> _fourShapes() =>
    <Path>[_shapeAt(0), _shapeAt(20), _shapeAt(40), _shapeAt(60)];

MaskRasterResult _draw(
  GpuMaskAtlas atlas,
  Path path, {
  Transform2D at = Transform2D.identity,
  Rect clip = _clip,
  FillRule rule = FillRule.nonZero,
  bool antiAlias = true,
}) =>
    atlas.rasterizeMask(
      path,
      transform: at,
      clip: clip,
      rule: rule,
      antiAlias: antiAlias,
    );

/// One texel of the slot starting at ([u0], [v0]), in slot-local coordinates.
int _texel(GpuMaskAtlas atlas, double u0, double v0, int x, int y) {
  final slotX = (u0 * atlas.width).round();
  final slotY = (v0 * atlas.height).round();
  return atlas.pixels[(slotY + y) * atlas.width + slotX + x];
}
