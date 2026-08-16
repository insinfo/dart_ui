/// The glyph atlas: what it keeps, what it throws away, and when.
///
/// Every assertion here is device-independent - the atlas is a byte array, a
/// packer and a map - so all of it runs with no driver attached. The fonts are
/// real, because the thing being asserted is that a *real* glyph is rasterised
/// once and then never again, and `ahem.ttf` in particular draws solid blocks,
/// which is what makes the padding assertion able to name exact texels.
library;

import 'dart:io';

import 'package:dart_ui/src/rendering/gpu/gpu_glyph_atlas.dart';
import 'package:dart_ui/src/rendering/text/glyph_cache.dart';
import 'package:dart_ui/src/rendering/text/glyph_raster.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

void main() {
  late Typeface ahem;
  late Typeface roboto;
  late _CountingSource source;

  setUp(() {
    ahem = _face('ahem.ttf');
    roboto = _face('Roboto-Regular.ttf');
    source = _CountingSource();
  });

  int glyph(Typeface face, String character) =>
      face.glyphForCodePoint(character.runes.first);

  GpuGlyphAtlas atlas({
    int width = 256,
    int height = 256,
    int plotSize = 128,
    int padding = 1,
  }) =>
      GpuGlyphAtlas(
        width: width,
        height: height,
        plotSize: plotSize,
        padding: padding,
        source: source,
      );

  group('persistence', () {
    test('a glyph drawn on two frames is rasterised once', () {
      // The entire reason this class exists. A frame-local atlas would report
      // two rasterisations here and look identical from every other angle.
      final a = atlas();
      final font = ahem.atSize(16);
      final id = glyph(ahem, 'X');

      final first = a.acquire(font, id)!;
      a.beginFrame();
      final second = a.acquire(font, id)!;

      expect(source.renderCount, 1);
      expect(a.missCount, 1);
      expect(a.hitCount, 1);
      expect(second.x, first.x);
      expect(second.y, first.y);
    });

    test('a blank glyph is cached too, not re-rasterised every frame', () {
      // A space is in every run. A lookup that missed on it would decode its
      // (empty) outline once per frame forever, which is a cache that reports
      // a fine hit rate while doing work on the hottest path there is.
      final a = atlas();
      final font = ahem.atSize(16);
      final space = glyph(ahem, ' ');

      final entry = a.acquire(font, space)!;
      a.beginFrame();
      a.acquire(font, space);

      expect(entry.isBlank, isTrue);
      expect(entry.plotIndex, -1, reason: 'a blank glyph holds no texels');
      expect(source.renderCount, 1);
      expect(a.hitCount, 1);
    });
  });

  group('the key, one dimension at a time', () {
    test('the pixel size is part of it', () {
      final a = atlas();
      final id = glyph(ahem, 'X');
      a.acquire(ahem.atSize(16), id);
      a.acquire(ahem.atSize(24), id);

      expect(source.renderCount, 2);
      expect(a.entryCount, 2);
    });

    test('sizes inside one 1/64 px bucket share an entry', () {
      // The size is quantised to 26.6 exactly as GlyphCache quantises it, and
      // the mask is rasterised at the *quantised* size, so an animation
      // sweeping 16.0 to 17.0 admits 64 entries rather than one per double.
      final a = atlas();
      final id = glyph(ahem, 'X');
      a.acquire(ahem.atSize(16.0), id);
      a.acquire(ahem.atSize(16.001), id);

      expect(source.renderCount, 1);
      expect(a.entryCount, 1);
      expect(source.sizes.single, 16.0,
          reason: 'the quantised size is what gets rasterised');
    });

    test('the face is part of it, by identity', () {
      final a = atlas();
      a.acquire(ahem.atSize(16), glyph(ahem, 'X'));
      a.acquire(roboto.atSize(16), glyph(roboto, 'X'));

      expect(source.renderCount, 2);
      expect(a.entryCount, 2);
    });

    test('the same file parsed twice is two faces', () {
      // Identity, not equality: two Typeface objects have independently
      // decoded outlines, and sharing coverage between them would hand out
      // masks built from the other object's tables.
      final a = atlas();
      final other = _face('ahem.ttf');
      a.acquire(ahem.atSize(16), glyph(ahem, 'X'));
      a.acquire(other.atSize(16), glyph(other, 'X'));

      expect(a.entryCount, 2);
    });

    test('the glyph id is part of it', () {
      final a = atlas();
      final font = ahem.atSize(16);
      a.acquire(font, glyph(ahem, 'X'));
      a.acquire(font, glyph(ahem, 'Y'));

      expect(source.renderCount, 2);
      expect(a.entryCount, 2);
    });

    test('the subpixel bucket is part of it, and picks the variant', () {
      // A mask rasterised for a pen at x.0 is not the mask for a pen at x.5:
      // the antialiased fringe falls on the other side. Sharing one between
      // them is how letter spacing starts to ripple.
      final a = atlas();
      final font = ahem.atSize(16);
      final id = glyph(ahem, 'X');
      final flush = a.acquire(font, id, subpixelBucket: 0)!;
      final half = a.acquire(font, id, subpixelBucket: 2)!;

      expect(source.renderCount, 2);
      expect(source.offsets, <double>[0.0, 0.5]);
      // The shifted variant straddles one more column, which is the whole
      // reason it has to be a separate entry.
      expect(half.width, flush.width + 1);
    });

    test('a bucket outside 0..3 is refused rather than folded', () {
      final a = atlas();
      expect(
        () => a.acquire(ahem.atSize(16), glyph(ahem, 'X'), subpixelBucket: 4),
        throwsArgumentError,
      );
      expect(
        () => a.acquire(ahem.atSize(16), glyph(ahem, 'X'), subpixelBucket: -1),
        throwsArgumentError,
      );
      expect(kSubpixelBuckets, 4, reason: 'the atlas mirrors the cache');
    });

    test('a size outside the 26.6 key range is named, not truncated', () {
      final a = atlas(width: 8192, height: 8192, plotSize: 8192);
      expect(
        () => a.acquire(ahem.atSize(5000), glyph(ahem, 'X')),
        throwsArgumentError,
      );
    });
  });

  group('padding', () {
    test('two neighbouring glyphs do not touch, and the gap is zeroed', () {
      // Bilinear filtering reaches half a texel past a quad's edge. Without
      // the ring, the right column of one glyph samples a fraction of its
      // neighbour's left column - a faint smudge on one letter in a hundred.
      final a = atlas(width: 64, height: 64, plotSize: 64);
      final font = ahem.atSize(8);
      final first = a.acquire(font, glyph(ahem, 'X'))!;
      final second = a.acquire(font, glyph(ahem, 'Y'))!;

      expect(second.y, first.y, reason: 'same shelf, side by side');
      final int gap = second.x - (first.x + first.width);
      expect(gap, greaterThanOrEqualTo(1));
      // Both glyphs are solid blocks, so anything non-zero between them came
      // from one of them.
      for (var x = first.x + first.width; x < second.x; x++) {
        for (var y = first.y; y < first.y + first.height; y++) {
          expect(a.pixels[y * a.width + x], 0,
              reason: 'texel $x,$y sits between two glyphs');
        }
      }
      // And the row above the first glyph, which a vertical tap would reach.
      for (var x = first.x; x < first.x + first.width; x++) {
        expect(a.pixels[(first.y - 1) * a.width + x], 0);
      }
    });

    test('a recycled plot does not leave ink in the next tenant\'s ring', () {
      // The ring is zeroed on every write rather than once at allocation,
      // because a recycled plot's texels are the previous tenant's.
      final a = atlas(width: 32, height: 32, plotSize: 32);
      final font = ahem.atSize(16);
      a.acquire(font, glyph(ahem, 'X'));
      a.beginFrame();
      a.recycleAll();
      final second = a.acquire(font, glyph(ahem, 'Y'))!;

      for (var x = second.x - 1; x < second.x + second.width + 1; x++) {
        expect(a.pixels[(second.y - 1) * a.width + x], 0);
      }
    });
  });

  group('incremental upload', () {
    test('a fresh atlas has nothing to upload', () {
      final a = atlas();
      expect(a.isDirty, isFalse);
      expect(a.dirtyRegionCount, 0);
    });

    test('only the plot that changed is dirty', () {
      // The alternative - one rectangle for the whole atlas - turns two
      // glyphs admitted into opposite corners into a megabyte of upload.
      final a = atlas(width: 64, height: 64, plotSize: 32);
      final font = ahem.atSize(16);
      a.acquire(font, glyph(ahem, 'X'));

      final regions = _dirtyRegions(a);
      expect(regions.length, 1);
      final region = regions.single;
      expect(region.x, lessThan(32));
      expect(region.y, lessThan(32));
      expect(region.width, lessThanOrEqualTo(32));
      expect(region.height, lessThanOrEqualTo(32));
      // The ring is included: a padding texel the texture never received is a
      // padding texel that still holds whatever was there before.
      expect(region.width, greaterThanOrEqualTo(16 + 2));
    });

    test('a hit uploads nothing at all', () {
      // The steady state this class is for: a screen full of text that did
      // not change costs zero bytes of texture traffic.
      final a = atlas();
      final font = ahem.atSize(16);
      a.acquire(font, glyph(ahem, 'X'));
      a.markUploaded();
      a.beginFrame();
      a.acquire(font, glyph(ahem, 'X'));

      expect(a.isDirty, isFalse);
    });

    test('markUploaded clears the regions without clearing the texels', () {
      final a = atlas();
      final entry = a.acquire(ahem.atSize(16), glyph(ahem, 'X'))!;
      a.markUploaded();

      expect(a.isDirty, isFalse);
      expect(
        a.pixels[(entry.y + 4) * a.width + entry.x + 4],
        greaterThan(0),
        reason: 'the texels are still the ones that were uploaded',
      );
    });

    test('two plots dirty produce two regions, not one union', () {
      final a = atlas(width: 64, height: 64, plotSize: 32);
      final font = ahem.atSize(16);
      a.acquire(font, glyph(ahem, 'X'));
      a.acquire(font, glyph(ahem, 'Y'));

      expect(a.usedPlotCount, 2, reason: 'one 16x17 glyph fills a 32 plot');
      expect(_dirtyRegions(a).length, 2);
    });
  });

  group('eviction', () {
    // A 64x64 atlas of 32 px plots holds four plots, and one 16 px ahem glyph
    // (16x17, padded to 18x19) fills a plot: four glyphs, one per plot, which
    // is what makes the policy observable in four lines.
    GpuGlyphAtlas full() {
      final a = atlas(width: 64, height: 64, plotSize: 32);
      final font = ahem.atSize(16);
      for (final String character in <String>['X', 'Y', 'M', 'Z']) {
        expect(a.acquire(font, glyph(ahem, character)), isNotNull);
      }
      expect(a.entryCount, 4);
      expect(a.usedPlotCount, 4);
      return a;
    }

    test('the least recently used plot goes first', () {
      final a = full();
      final font = ahem.atSize(16);
      a.beginFrame();
      // Touch the first glyph so its plot is the current frame's, leaving the
      // other three tied on the previous frame.
      a.acquire(font, glyph(ahem, 'X'));
      a.acquire(font, glyph(ahem, 'W'));

      expect(a.evictionCount, 1);
      expect(a.plotRecycleCount, 1);
      expect(a.isResident(font, glyph(ahem, 'X')), isTrue);
      expect(a.isResident(font, glyph(ahem, 'Y')), isFalse);
      expect(a.isResident(font, glyph(ahem, 'M')), isTrue);
      expect(a.isResident(font, glyph(ahem, 'W')), isTrue);
    });

    test('a glyph the current frame already drew is never evicted', () {
      // The classic bug: the frame emits a quad into a plot, the atlas then
      // recycles that plot for a later glyph, and the first letter is drawn
      // with the last letter's coverage. Nothing downstream can detect it.
      final a = full();
      final font = ahem.atSize(16);
      a.beginFrame();
      a.acquire(font, glyph(ahem, 'X'));

      for (final String character in <String>['W', 'q', 'j']) {
        expect(a.acquire(font, glyph(ahem, character)), isNotNull);
      }

      expect(a.isResident(font, glyph(ahem, 'X')), isTrue);
      expect(a.evictionCount, 3);
      // And the fourth new glyph has nowhere to go, because every plot now
      // belongs to this frame - it must not take the pinned one.
      expect(a.acquire(font, glyph(ahem, 'z')), isNull);
      expect(a.isResident(font, glyph(ahem, 'X')), isTrue);
    });

    test('isResident does not count as a use', () {
      // Otherwise a diagnostic changes the answer it is reporting.
      final a = full();
      final font = ahem.atSize(16);
      a.beginFrame();
      a.isResident(font, glyph(ahem, 'X'));
      a.acquire(font, glyph(ahem, 'W'));

      expect(a.isResident(font, glyph(ahem, 'X')), isFalse,
          reason: 'plot 0 was still the least recently used one');
    });

    test('an evicted glyph is rasterised again when it comes back', () {
      final a = full();
      final font = ahem.atSize(16);
      a.beginFrame();
      a.acquire(font, glyph(ahem, 'X'));
      a.acquire(font, glyph(ahem, 'W'));
      expect(a.isResident(font, glyph(ahem, 'Y')), isFalse);

      final int before = source.renderCount;
      a.beginFrame();
      a.acquire(font, glyph(ahem, 'Y'));
      expect(source.renderCount, before + 1);
    });
  });

  group('running out of room', () {
    test('a full atlas signals a flush instead of throwing', () {
      // Fullness is a state a caller that knows how to flush recovers from.
      // Throwing here would make the only recovery impossible.
      final a = atlas(width: 32, height: 32, plotSize: 32);
      final font = ahem.atSize(16);
      expect(a.acquire(font, glyph(ahem, 'X')), isNotNull);

      final GlyphAtlasEntry? second = a.acquire(font, glyph(ahem, 'Y'));
      expect(second, isNull);
      expect(a.needsFlush, isTrue);
      expect(a.lastFailure, GlyphAtlasFailure.atlasFull);
    });

    test('a glyph larger than a plot is its own failure', () {
      // No eviction fixes it and no tiling exists, so a caller that answered
      // it by flushing would flush forever.
      final a = atlas(width: 32, height: 32, plotSize: 32);
      expect(a.acquire(ahem.atSize(64), glyph(ahem, 'X')), isNull);
      expect(a.lastFailure, GlyphAtlasFailure.glyphTooLarge);
      expect(a.needsFlush, isFalse);
    });

    test('recycleAll takes the atlas back to empty', () {
      final a = atlas(width: 32, height: 32, plotSize: 32);
      final font = ahem.atSize(16);
      a.acquire(font, glyph(ahem, 'X'));
      a.acquire(font, glyph(ahem, 'Y'));
      expect(a.needsFlush, isTrue);

      a.recycleAll();
      expect(a.entryCount, 0);
      expect(a.needsFlush, isFalse);
      expect(a.acquire(font, glyph(ahem, 'Y')), isNotNull);
    });

    test('a later success clears the signal', () {
      final a = atlas(width: 64, height: 64, plotSize: 32);
      expect(a.acquire(ahem.atSize(64), glyph(ahem, 'X')), isNull);
      expect(a.acquire(ahem.atSize(16), glyph(ahem, 'X')), isNotNull);
      expect(a.lastFailure, GlyphAtlasFailure.none);
    });
  });

  group('construction', () {
    test('a plot size that does not divide the atlas is refused', () {
      // The leftover strip would be texels no plot can allocate and no
      // diagnostic can account for.
      expect(
        () => GpuGlyphAtlas(width: 100, height: 100, plotSize: 32),
        throwsArgumentError,
      );
    });

    test('the packer is replaceable', () {
      // The shelf packer in gpu_texture.dart is being consolidated
      // separately; this is the seam it plugs into.
      var built = 0;
      final a = GpuGlyphAtlas(
        width: 64,
        height: 64,
        plotSize: 32,
        source: source,
        packerFactory: (width, height, padding) {
          built++;
          return ShelfGlyphPacker(
              width: width, height: height, padding: padding);
        },
      );
      expect(built, 4);
      expect(a.acquire(ahem.atSize(16), glyph(ahem, 'X')), isNotNull);
    });
  });
}

/// Counts rasterisations, which is the only way to prove a cache is one.
///
/// It has to be a separate type: [GlyphRasterizer] is a `final class` and
/// cannot be subclassed, which is exactly why the atlas takes a
/// [GlyphMaskSource] rather than a rasteriser.
final class _CountingSource implements GlyphMaskSource {
  final GlyphRasterizer _rasterizer = GlyphRasterizer();

  int renderCount = 0;
  final List<double> offsets = <double>[];
  final List<double> sizes = <double>[];

  @override
  GlyphMask render(
    ScaledTypeface font,
    int glyphId, {
    double subpixelOffsetX = 0,
  }) {
    renderCount++;
    offsets.add(subpixelOffsetX);
    sizes.add(font.pixelSize);
    return _rasterizer.render(font, glyphId, subpixelOffsetX: subpixelOffsetX);
  }
}

typedef _Region = ({int x, int y, int width, int height});

List<_Region> _dirtyRegions(GpuGlyphAtlas atlas) {
  final List<_Region> regions = <_Region>[];
  atlas.forEachDirtyRegion((x, y, width, height) =>
      regions.add((x: x, y: y, width: width, height: height)));
  return regions;
}
