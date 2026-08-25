/// Rounded rectangles stop allocating a path per frame.
///
/// `GpuRasterSink.fillDeviceRRect` built a fresh `PathBuilder` and a fresh
/// `Path` for every rounded rectangle of every frame - a builder, its two
/// growing buffers, and then the two arrays `build()` copies into. Static
/// chrome asks for the same twelve numbers every frame, so all of it was
/// garbage by construction.
///
/// The reason this is safe is the mask atlas's own lookup: it ends in
/// `identical(path, other) || path == other`, and `Path.operator ==` compares
/// hash, verbs and points *by value*. Nothing downstream keys on path
/// identity, so handing back the same instance cannot change which mask is
/// found - it only lets the comparison short-circuit.
///
/// The assertions therefore come in pairs: the cache reuses the instance, and
/// the instance it reuses is byte-for-byte the path the uncached code would
/// have built.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_atlas.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_raster_sink.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

const ReplayPaint _fill = ReplayPaint(
  argbColor: 0xFF204080,
  style: paintStyleFill,
  strokeWidth: 0,
  blendMode: blendModeSrcOver,
  antiAlias: true,
);

const Rect _clip = Rect.fromLTRB(0, 0, 1000, 1000);

Float32List _radii(double r) => Float32List.fromList(<double>[
      r, r, r, r, r, r, r, r, //
    ]);

void main() {
  group('DeviceRRectPathCache', () {
    test('the same geometry returns the same instance', () {
      final cache = DeviceRRectPathCache();
      const Rect rect = Rect.fromLTRB(10, 20, 110, 60);
      final Float32List radii = _radii(6);

      final Path first = cache.pathFor(rect, radii);
      final Path second = cache.pathFor(rect, radii);

      expect(identical(first, second), isTrue);
      expect(cache.hitCount, 1);
      expect(cache.missCount, 1);
    });

    test('the reused path is byte-identical to a freshly built one', () {
      final cache = DeviceRRectPathCache();
      const Rect rect = Rect.fromLTRB(3.5, 7.25, 91.75, 40.125);
      final Float32List radii = Float32List.fromList(<double>[
        1, 2, 3, 4, 5, 6, 7, 8, //
      ]);

      final Path cached = cache.pathFor(rect, radii);
      cache.pathFor(rect, radii);
      final Path fresh =
          (PathBuilder()..addRoundedRectRadii(rect, radii)).build();

      // Value equality is what the mask atlas compares on, and it walks both
      // arrays; the counts are asserted too so an empty path cannot pass.
      expect(cached, fresh);
      expect(cached.hashCode, fresh.hashCode);
      expect(cached.verbCount, fresh.verbCount);
      expect(cached.pointCount, fresh.pointCount);
      expect(cached.bounds, fresh.bounds);
    });

    test('a borrowed radii buffer is copied, not retained', () {
      // The player hands the same eight-slot scratch buffer to every rounded
      // rectangle in the frame. A cache that kept the reference would answer
      // the second shape with the first shape's path.
      final cache = DeviceRRectPathCache();
      const Rect rect = Rect.fromLTRB(0, 0, 50, 50);
      final scratch = _radii(4);

      final Path round = cache.pathFor(rect, scratch);
      for (var i = 0; i < 8; i++) {
        scratch[i] = 12;
      }
      final Path rounder = cache.pathFor(rect, scratch);

      expect(identical(round, rounder), isFalse);
      expect(round == rounder, isFalse);
      expect(cache.missCount, 2);
      expect(cache.hitCount, 0);
    });

    test('a different rectangle with the same radii is a different path', () {
      final cache = DeviceRRectPathCache();
      final Float32List radii = _radii(5);
      final Path a = cache.pathFor(const Rect.fromLTRB(0, 0, 40, 40), radii);
      final Path b = cache.pathFor(const Rect.fromLTRB(0, 0, 40, 41), radii);

      expect(identical(a, b), isFalse);
      expect(cache.hitCount, 0);
      expect(cache.missCount, 2);
    });

    test('a working set larger than the table still answers correctly', () {
      // Direct mapped: collisions rebuild, which must be a slow answer and
      // never a wrong one.
      final cache = DeviceRRectPathCache(capacity: 4);
      final Float32List radii = _radii(2);
      final built = <Path>[];
      for (var i = 0; i < 16; i++) {
        built.add(
            cache.pathFor(Rect.fromLTWH(0, 0, 20 + i.toDouble(), 10), radii));
      }
      for (var i = 0; i < 16; i++) {
        final Path again =
            cache.pathFor(Rect.fromLTWH(0, 0, 20 + i.toDouble(), 10), radii);
        expect(again, built[i], reason: 'entry $i');
      }
    });

    test('clear drops every entry', () {
      final cache = DeviceRRectPathCache();
      const Rect rect = Rect.fromLTRB(0, 0, 20, 20);
      final Float32List radii = _radii(3);
      final Path before = cache.pathFor(rect, radii);
      cache.clear();
      final Path after = cache.pathFor(rect, radii);

      expect(identical(before, after), isFalse);
      expect(after, before);
      expect(cache.missCount, 1);
    });
  });

  group('GpuRasterSink', () {
    test('redrawing a rounded rectangle reuses the path and the mask', () {
      final atlas = GpuMaskAtlas(width: 128, height: 128);
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
        maskAtlas: atlas,
        maskTextureId: 5,
      );
      const Rect rect = Rect.fromLTRB(8, 8, 72, 40);
      final Float32List radii = _radii(6);

      for (var frame = 0; frame < 4; frame++) {
        sink.fillDeviceRRect(rect, _clip, radii, _fill);
      }

      expect(sink.batcher.quadCount, 4);
      expect(sink.rrectPathCache.missCount, 1);
      expect(sink.rrectPathCache.hitCount, 3);
      // The atlas was already content-keyed; the point is that reusing the
      // instance did not break that.
      expect(atlas.rasterizationCount, 1);
    });

    test('two different rounded rectangles are still two masks', () {
      final atlas = GpuMaskAtlas(width: 128, height: 128);
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
        maskAtlas: atlas,
        maskTextureId: 5,
      );

      sink.fillDeviceRRect(
        const Rect.fromLTRB(8, 8, 72, 40),
        _clip,
        _radii(6),
        _fill,
      );
      sink.fillDeviceRRect(
        const Rect.fromLTRB(8, 8, 72, 40),
        _clip,
        _radii(2),
        _fill,
      );

      expect(sink.rrectPathCache.missCount, 2);
      expect(atlas.rasterizationCount, 2);
    });

    test('the batched quad is the same one the uncached path produced', () {
      // The geometry the sink emits must not depend on where the path came
      // from. Two sinks, one warm cache and one cold, must batch identical
      // quads.
      final warm = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
        maskAtlas: GpuMaskAtlas(width: 128, height: 128),
        maskTextureId: 5,
      );
      final cold = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
        maskAtlas: GpuMaskAtlas(width: 128, height: 128),
        maskTextureId: 5,
      );
      const Rect rect = Rect.fromLTRB(4.5, 9.25, 84.75, 44.5);
      final Float32List radii = Float32List.fromList(<double>[
        3, 4, 5, 6, 7, 8, 9, 10, //
      ]);

      warm.fillDeviceRRect(rect, _clip, radii, _fill);
      final int quads = warm.batcher.quadCount;
      final Float32List first =
          Float32List.fromList(warm.batcher.buffer.vertices);

      warm.fillDeviceRRect(rect, _clip, radii, _fill);
      cold.fillDeviceRRect(rect, _clip, radii, _fill);

      expect(warm.rrectPathCache.hitCount, 1);
      expect(cold.rrectPathCache.hitCount, 0);
      expect(cold.batcher.quadCount, quads);
      expect(cold.batcher.buffer.vertices, first);
    });
  });
}
