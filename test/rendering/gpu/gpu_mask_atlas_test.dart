/// The coverage-mask atlas: what it writes, where, and what it refuses.
///
/// The whole antialiasing strategy for paths on the GPU rests on this file
/// producing the *same* coverage bytes the CPU rasteriser produces, in a slot
/// whose texture coordinates map one texel to one pixel. Both halves are
/// checked here, on the CPU, because both are wrong in ways that look like a
/// shader bug from the other side of an upload.
library;

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_atlas.dart';
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
      final centre = _texel(atlas, quad, 5, 5);
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

    test('a slot is cleared before it is filled', () {
      // Slots are reused memory. The filler only writes covered spans, so
      // without the clear the uncovered interior of a shape shows the
      // previous frame's coverage - a ghost of whatever was there.
      final atlas = GpuMaskAtlas(width: 32, height: 32);
      atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 20, 20)),
        transform: Transform2D.identity,
        clip: _clip,
      );
      atlas.beginFrame();

      final quad = atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 20, 20)),
        transform: Transform2D.identity,
        clip: _clip,
      )!;
      // A triangle-free rect covers everything, so instead check a shape that
      // leaves part of its bounding box empty.
      atlas.beginFrame();
      final triangle = PathBuilder()
        ..moveTo(0, 0)
        ..lineTo(20, 0)
        ..lineTo(0, 20)
        ..close();
      final second = atlas.rasterize(
        triangle.build(),
        transform: Transform2D.identity,
        clip: _clip,
      )!;

      expect(second.deviceRect, quad.deviceRect);
      // Bottom-right corner is outside the triangle and was solid last frame.
      expect(_texel(atlas, second, 18, 18), 0);
    });

    test('an invisible shape returns null rather than an empty slot', () {
      final atlas = GpuMaskAtlas(width: 32, height: 32);
      final quad = atlas.rasterize(
        _rect(const Rect.fromLTRB(100, 100, 110, 110)),
        transform: Transform2D.identity,
        clip: const Rect.fromLTRB(0, 0, 50, 50),
      );

      expect(quad, isNull);
      expect(atlas.isDirty, isFalse);
    });

    test('a shape larger than the atlas returns null rather than clipping', () {
      final atlas = GpuMaskAtlas(width: 32, height: 32);
      expect(
        atlas.rasterize(
          _rect(const Rect.fromLTRB(0, 0, 200, 200)),
          transform: Transform2D.identity,
          clip: _clip,
        ),
        isNull,
      );
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
      expect(_texel(atlas, quad, 5, 5), 255,
          reason: 'the texels are still the ones that were uploaded');
    });

    test('beginFrame drops the packing and the dirty region together', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      atlas.rasterize(
        _rect(const Rect.fromLTRB(0, 0, 10, 10)),
        transform: Transform2D.identity,
        clip: _clip,
      );
      expect(atlas.shelfCount, 1);

      atlas.beginFrame();
      expect(atlas.isDirty, isFalse);
      expect(atlas.shelfCount, 0);
    });
  });
}

Path _rect(Rect rect) => (PathBuilder()..addRect(rect)).build();

/// One texel of the slot [quad] occupies, in slot-local coordinates.
int _texel(GpuMaskAtlas atlas, MaskQuad quad, int x, int y) {
  final slotX = (quad.u0 * atlas.width).round();
  final slotY = (quad.v0 * atlas.height).round();
  return atlas.pixels[(slotY + y) * atlas.width + slotX + x];
}
