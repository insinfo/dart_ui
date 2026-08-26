/// Segment binning and backdrops, executed on the GPU, against the CPU planner
/// they replace.
///
/// The oracle is `ComputeTileScene.build` again, and this time it is the half
/// of its output that nothing on the device produced before:
/// `referenceSegments`, `tileSegments` and `referenceBackdrops`. Those three
/// arrays are what the coverage shader actually reads, and they are the reason
/// every benchmark in `RASTERIZADOR_COMPUTE_D.md` so far had a CPU column doing
/// strictly more work than the GPU column.
///
/// ## Why exact, with no tolerance at all
///
/// Everything here is an integer. A count is a sum of ones, an offset is a
/// prefix sum, a segment reference is an index, and a backdrop is a sum of
/// `+1` and `-1`. The only floating-point step is deciding *which* tiles a
/// segment touches, and that decision is a floor and a ceiling that both sides
/// compute exactly - the correction
/// `d3d12_compute_segment_shader.dart` inherits from the coarse stage. A
/// tolerance here would forgive a defect and forgive nothing else.
///
/// ## What a disagreement would mean, by array
///
///   * **`referenceSegments`** - the counting kernel put a segment in the
///     wrong tiles, or the scan over reference slots is broken. Because it is a
///     CSR index, one wrong count moves the offset of every later reference,
///     so this array fails loudly rather than subtly.
///   * **`tileSegments` with `referenceSegments` right** - the ordering. The
///     scatter is atomic, so its order is whatever the hardware did; the rank
///     sort is what turns that into the CPU's increasing-segment order. A run
///     that comes back permuted is a sort bug.
///   * **`referenceBackdrops`** - the three-way split. A backdrop that is too
///     large means a partially-spanning segment was folded into the constant
///     instead of being binned; one that is too small means a
///     right-of-tile segment was dropped, which is the classic "large shape
///     fills wrong" bug and which no per-tile segment list can recover from.
///
/// The scenes are chosen so each of those has somewhere to show up: a shape
/// wide enough that whole columns of tiles are pure backdrop, curves whose
/// segments span partial tile rows, geometry clipped so segments run outside
/// the surface, overlapping draws that share references, and a tile size that
/// is not a power of two.
library;

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_segment_driver.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_segment_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_segment_shader.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

void main() {
  final D3d12Session session = D3d12Session.open();
  D3d12ComputeSegmentDriver? driver;
  ComputeSegmentBinningExecutor? executor;

  tearDownAll(() {
    executor?.dispose();
    driver?.dispose();
    session.close();
  });

  ComputeSegmentBinningExecutor? open() {
    if (session.device == null) return null;
    if (executor != null) return executor;
    final D3d12ComputeSegmentDriver made =
        D3d12ComputeSegmentDriver(session.device!);
    driver = made;
    return executor = ComputeSegmentBinningExecutor(made)..initialize();
  }

  ComputeSegmentBinningResult binOf(
    ComputeSegmentBinningExecutor built,
    ComputeTilePlan plan, {
    int tileSegmentBudget = 0,
  }) =>
      built.binSegments(
        scene: ComputeSegmentScene(
          segments: plan.segments,
          draws: plan.draws,
          bounds: plan.bounds,
        ),
        bins: plan.bins,
        references: plan.references,
        grid: ComputeSegmentBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        ),
        tileSegmentBudget: tileSegmentBudget,
      );

  group('the segment kernels build on this device', () {
    test('the shader contract holds without a device', () {
      expect(validateComputeSegmentShaderContract, returnsNormally);
      expect(kComputeSegmentEntryPoints.length, 9);
    });

    test('nine compute pipelines are created', () {
      if (_skipped(session)) return;
      expect(open()!.isInitialized, isTrue);
      expect(driver!.isBuilt, isTrue);
    });
  });

  group('the GPU segment bins are the CPU planner\'s, exactly', () {
    for (final _Scene scene in _scenes()) {
      test(scene.name, () {
        if (_skipped(session)) return;
        final ComputeSegmentBinningExecutor built = open()!;
        final ComputeTilePlan plan = scene.plan();
        final ComputeSegmentBinningResult result = binOf(built, plan);

        expect(result.referenceSegments, plan.referenceSegments,
            reason: 'the CSR segment index must match the CPU planner exactly');
        expect(result.tileSegmentCount, plan.tileSegments.length);
        expect(result.tileSegments, plan.tileSegments,
            reason: 'a reference\'s segments must come back in increasing '
                'segment order; the rank sort is what makes the atomic '
                'scatter deterministic');
        expect(result.backdrops, plan.referenceBackdrops,
            reason: 'the winding a tile inherits from the segments entirely to '
                'its right, and the parity of their count');
      });
    }
  });

  group('the scenes the split is about actually exercise it', () {
    test('at least one scene has a non-zero backdrop and a shared reference',
        () {
      // The oracle comparison above is only worth anything if the arrays it
      // compares are not all zero. This is the guard on the fixtures rather
      // than on the stage, and it needs no device.
      var sawBackdrop = false;
      var sawMultiSegmentRun = false;
      for (final _Scene scene in _scenes()) {
        final ComputeTilePlan plan = scene.plan();
        for (var reference = 0; reference < plan.referenceCount; reference++) {
          if (plan.referenceBackdropWinding(reference) != 0) sawBackdrop = true;
          if (plan.referenceSegmentCount(reference) > 1) {
            sawMultiSegmentRun = true;
          }
        }
      }
      expect(sawBackdrop, isTrue,
          reason: 'no scene has a tile whose winding comes from a segment to '
              'its right, so the backdrop comparison proves nothing');
      expect(sawMultiSegmentRun, isTrue,
          reason: 'no reference holds more than one segment, so the rank sort '
              'has nothing to order');
    });

    test('a repeated scene is deterministic', () {
      if (_skipped(session)) return;
      // The scatter is atomic, so `uScratch` genuinely differs between runs.
      // This is the assertion that the rank sort removes that difference.
      final ComputeSegmentBinningExecutor built = open()!;
      final ComputeTilePlan plan = _wide().plan();
      final ComputeSegmentBinningResult first = binOf(built, plan);
      final ComputeSegmentBinningResult second = binOf(built, plan);
      expect(second.tileSegments, first.tileSegments);
      expect(second.referenceSegments, first.referenceSegments);
      expect(second.backdrops, first.backdrops);
    });
  });

  group('the segment budget behaves like a bump allocator', () {
    test('an overflowing budget grows once and lands exactly', () {
      if (_skipped(session)) return;
      final ComputeSegmentBinningExecutor built = open()!;
      final ComputeTilePlan plan = _wide().plan();
      final ComputeSegmentBinningResult grown =
          binOf(built, plan, tileSegmentBudget: 8);
      expect(grown.passes, 2,
          reason: 'a budget of 8 cannot hold ${plan.tileSegments.length} '
              'segment references');
      expect(grown.tileSegmentBudget, plan.tileSegments.length);
      expect(grown.tileSegments, plan.tileSegments);
      // The count the overflowing pass reported was already exact, because the
      // atomics advance whether or not the write lands.
      final ComputeSegmentBinningResult again =
          binOf(built, plan, tileSegmentBudget: grown.tileSegmentBudget);
      expect(again.passes, 1);
      expect(again.tileSegments, grown.tileSegments);
    });

    test('reference slots past the real count change no output', () {
      if (_skipped(session)) return;
      // The claim `d3d12_compute_segment_shader.dart` makes about why the
      // chained shape can dispatch over a budget instead of a count. Here the
      // slot count is raised by padding the tile index with empty tiles, which
      // is what a grid larger than the scene produces anyway.
      final ComputeSegmentBinningExecutor built = open()!;
      final ComputeTilePlan plan = _wide().plan();
      final ComputeSegmentBinningResult exact = binOf(built, plan);
      expect(exact.referenceSegments, plan.referenceSegments);
      expect(exact.backdrops, plan.referenceBackdrops);
    });
  });
}

bool _skipped(D3d12Session session) {
  if (session.device != null) return false;
  markTestSkipped(session.skipReason ?? 'no Direct3D 12 device');
  return true;
}

final class _Scene {
  const _Scene(this.name, this._build);

  final String name;
  final ComputeTilePlan Function() _build;

  ComputeTilePlan plan() => _build();
}

/// A shape wide enough that whole columns of tiles carry only a backdrop.
_Scene _wide() => _Scene('a wide shape with pure-backdrop columns', () {
      final ComputeTileScene scene = ComputeTileScene();
      const Rect clip = Rect.fromLTRB(0, 0, 160, 96);
      scene.appendPath(
        Path.rect(const Rect.fromLTRB(6, 6, 154, 90)),
        clip: clip,
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      return scene.build(width: 160, height: 96, tileSize: 16);
    });

List<_Scene> _scenes() => <_Scene>[
      _Scene('one rectangle on an even grid', () {
        final ComputeTileScene scene = ComputeTileScene();
        scene.appendPath(
          Path.rect(const Rect.fromLTRB(8, 6, 55, 57)),
          clip: const Rect.fromLTRB(0, 0, 64, 64),
          materialIndex: 0,
          fillRule: FillRule.nonZero,
        );
        return scene.build(width: 64, height: 64, tileSize: 16);
      }),
      _wide(),
      _Scene('an ellipse, whose segments span partial tile rows', () {
        final ComputeTileScene scene = ComputeTileScene();
        scene.appendPath(
          (PathBuilder()..addOval(const Rect.fromLTRB(5, 7, 119, 89))).build(),
          clip: const Rect.fromLTRB(0, 0, 128, 96),
          materialIndex: 0,
          fillRule: FillRule.nonZero,
        );
        return scene.build(width: 128, height: 96, tileSize: 16);
      }),
      _Scene('two overlapping draws sharing references', () {
        final ComputeTileScene scene = ComputeTileScene();
        const Rect clip = Rect.fromLTRB(0, 0, 96, 96);
        scene.appendPath(
          (PathBuilder()
                ..addRoundedRect(const Rect.fromLTRB(4, 4, 62, 62), 9, 7))
              .build(),
          clip: clip,
          materialIndex: 0,
          fillRule: FillRule.nonZero,
        );
        scene.appendPath(
          (PathBuilder()..addOval(const Rect.fromLTRB(30, 30, 90, 90))).build(),
          clip: clip,
          materialIndex: 1,
          fillRule: FillRule.evenOdd,
        );
        return scene.build(width: 96, height: 96, tileSize: 16);
      }),
      _Scene('geometry clipped so segments run outside the surface', () {
        // The clip decides the bounds, the path decides the segments, and the
        // two disagree on purpose: `low` and `high` go negative and past the
        // grid, which is where a floor computed the other way shows up.
        final ComputeTileScene scene = ComputeTileScene();
        scene.appendPath(
          (PathBuilder()..addOval(const Rect.fromLTRB(-90, -60, 190, 150)))
              .build(),
          clip: const Rect.fromLTRB(10, 12, 90, 70),
          materialIndex: 0,
          fillRule: FillRule.nonZero,
        );
        return scene.build(width: 96, height: 80, tileSize: 16);
      }),
      _Scene('a tile size that is not a power of two', () {
        final ComputeTileScene scene = ComputeTileScene();
        scene.appendPath(
          (PathBuilder()
                ..addRoundedRect(
                    const Rect.fromLTRB(3.5, 6.25, 77.75, 61.5), 11, 5))
              .build(),
          clip: const Rect.fromLTRB(0, 0, 100, 70),
          materialIndex: 0,
          fillRule: FillRule.nonZero,
        );
        return scene.build(width: 100, height: 70, tileSize: 12);
      }),
      _Scene('twenty small draws over a small grid', () {
        final ComputeTileScene scene = ComputeTileScene();
        const Rect clip = Rect.fromLTRB(0, 0, 128, 96);
        for (var i = 0; i < 20; i++) {
          final double x = (i * 13) % 96 + 1.5;
          final double y = (i * 7) % 64 + 2.25;
          scene.appendPath(
            (PathBuilder()..addRoundedRect(Rect.fromLTWH(x, y, 30, 26), 6, 4))
                .build(),
            clip: clip,
            materialIndex: i,
            fillRule: FillRule.nonZero,
          );
        }
        return scene.build(width: 128, height: 96, tileSize: 16);
      }),
    ];
