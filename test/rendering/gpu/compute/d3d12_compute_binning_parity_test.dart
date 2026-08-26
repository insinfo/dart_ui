/// Tile binning, executed on the GPU, against the CPU planner it replaces.
///
/// The oracle here is not a purpose-built reference: it is
/// `ComputeTileScene.build`, the CPU binner this framework already ships and
/// whose output `d3d12_compute_tile_shader.dart` already consumes. The GPU
/// stage is fed that plan's own `bounds` array and has to reproduce its `bins`,
/// `references` and `commands` **exactly**.
///
/// ## Why exact, with no tolerance at all
///
/// Everything the stage produces is an integer. A tile index is a floor of a
/// division that both sides compute exactly - `d3d12_compute_binning_shader`
/// explains the correction that makes the float32 division land on the same
/// integer as the float64 one - a count is a sum of ones, an offset is a prefix
/// sum, and a reference is a draw index. There is no rounding anywhere for a
/// tolerance to forgive, so a tolerance here would only hide a defect.
///
/// ## What a disagreement would mean, by array
///
///   * **`bins`** - either the counting kernel binned a draw into the wrong
///     tiles (a tile range computed from unintersected bounds, a column count
///     read wrong, a floor that went the other way) or the scan is broken.
///   * **`references` with correct `bins`** - the ordering. The scatter uses
///     atomics, so the *order* it produces is whatever the hardware did; the
///     rank sort is what turns that into increasing draw order. A tile whose
///     draws come back permuted is a sort bug, and it is exactly the bug that
///     paints two overlapping shapes in the wrong order and looks plausible.
///   * **`commands` with both correct** - the second scan, over occupancy.
///
/// So the test asserts them separately rather than comparing one blob, and the
/// scenes are chosen so that each failure mode has somewhere to show up:
/// overlapping draws that share tiles, a grid that does not divide evenly, a
/// draw entirely outside the surface, and a scene with many small draws whose
/// tiles are shared by three or more.
library;

import 'dart:math' as math;

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_binning_driver.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_binning_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_binning_shader.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

void main() {
  final D3d12Session session = D3d12Session.open();
  D3d12ComputeBinningDriver? driver;
  ComputeBinningExecutor? executor;

  tearDownAll(() {
    executor?.dispose();
    driver?.dispose();
    session.close();
  });

  ComputeBinningExecutor? open() {
    if (session.device == null) return null;
    if (executor != null) return executor;
    final D3d12ComputeBinningDriver made =
        D3d12ComputeBinningDriver(session.device!);
    driver = made;
    return executor = ComputeBinningExecutor(made)..initialize();
  }

  group('the binning kernels build on this device', () {
    test('the shader contract holds without a device', () {
      expect(validateComputeBinningShaderContract, returnsNormally);
      expect(kComputeBinningEntryPoints.length, 9);
    });

    test('nine compute pipelines are created', () {
      if (_skipped(session)) return;
      expect(open()!.isInitialized, isTrue);
      expect(driver!.isBuilt, isTrue);
    });
  });

  group('the GPU tile index is the CPU planner\'s, exactly', () {
    for (final _Scene scene in _scenes()) {
      test(scene.name, () {
        if (_skipped(session)) return;
        final ComputeBinningExecutor built = open()!;
        final ComputeTilePlan plan = scene.plan();
        final ComputeBinningResult result = built.bin(
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: ComputeBinningGrid(
            width: plan.width,
            height: plan.height,
            tileSize: plan.tileSize,
          ),
        );

        expect(result.bins, plan.bins,
            reason: 'the CSR tile index must match the CPU planner exactly');
        expect(result.referenceCount, plan.references.length);
        expect(result.references, plan.references,
            reason: 'a tile\'s draws must come back in increasing draw order; '
                'the rank sort is what makes the atomic scatter deterministic');
        expect(result.commandCount * 3, plan.commands.length);
        expect(result.commands, plan.commands,
            reason: 'one command per occupied tile, in tile order');
      });
    }
  });

  group('the properties the arrays have to satisfy on their own', () {
    test('every tile run is strictly increasing and inside its bin', () {
      if (_skipped(session)) return;
      // Independent of the oracle: even if the CPU planner and the GPU agreed
      // on something wrong, a tile whose references are not sorted is a defect
      // by definition, because the coverage shader composites in read order.
      final ComputeBinningExecutor built = open()!;
      final ComputeTilePlan plan = _crowded().plan();
      final ComputeBinningResult result = built.bin(
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        ),
      );
      var occupied = 0;
      var longestRun = 0;
      for (var tile = 0; tile < plan.tileCount; tile++) {
        final int first = result.bins[tile * 2];
        final int count = result.bins[tile * 2 + 1];
        expect(first + count, lessThanOrEqualTo(result.referenceCount));
        if (count == 0) continue;
        occupied++;
        longestRun = math.max(longestRun, count);
        for (var i = 0; i + 1 < count; i++) {
          expect(result.references[first + i],
              lessThan(result.references[first + i + 1]));
        }
      }
      expect(result.commandCount, occupied);
      // A scene where several draws really do share tiles, so the sort had
      // something to do.
      expect(longestRun, greaterThanOrEqualTo(3));
    });

    test('a repeated scene is deterministic', () {
      if (_skipped(session)) return;
      // The scatter is atomic, so `uScratch` genuinely differs between runs.
      // This is the assertion that the rank sort removes that difference.
      final ComputeBinningExecutor built = open()!;
      final ComputeTilePlan plan = _crowded().plan();
      final ComputeBinningGrid grid = ComputeBinningGrid(
        width: plan.width,
        height: plan.height,
        tileSize: plan.tileSize,
      );
      final ComputeBinningResult first = built.bin(
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: grid,
      );
      final ComputeBinningResult second = built.bin(
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: grid,
      );
      expect(second.references, first.references);
      expect(second.bins, first.bins);
      expect(second.commands, first.commands);
    });
  });

  group('the reference budget behaves like a bump allocator', () {
    test('an overflowing budget grows once and lands exactly', () {
      if (_skipped(session)) return;
      final ComputeBinningExecutor built = open()!;
      final ComputeTilePlan plan = _crowded().plan();
      final ComputeBinningGrid grid = ComputeBinningGrid(
        width: plan.width,
        height: plan.height,
        tileSize: plan.tileSize,
      );
      final ComputeBinningResult result = built.bin(
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: grid,
        referenceBudget: 8,
      );
      expect(result.passes, 2,
          reason: 'a budget of 8 cannot hold ${plan.references.length} '
              'references');
      expect(result.referenceBudget, plan.references.length);
      expect(result.references, plan.references);
      // The count the overflowing pass reported was already exact, because the
      // atomics advance whether or not the write lands.
      final ComputeBinningResult again = built.bin(
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: grid,
        referenceBudget: result.referenceBudget,
      );
      expect(again.passes, 1);
      expect(again.references, result.references);
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

List<_Scene> _scenes() => <_Scene>[
      _Scene('one rectangle on an even grid', () => _oneRect(64, 64, 16)),
      _Scene(
        'a grid that does not divide evenly',
        () => _oneRect(70, 54, 16),
      ),
      _Scene('two overlapping draws sharing tiles', () {
        final ComputeTileScene scene = ComputeTileScene();
        const Rect clip = Rect.fromLTRB(0, 0, 96, 96);
        scene.appendPath(_rect(4, 4, 52, 52),
            clip: clip, materialIndex: 0, fillRule: FillRule.nonZero);
        scene.appendPath(_rect(30, 30, 90, 90),
            clip: clip, materialIndex: 1, fillRule: FillRule.nonZero);
        return scene.build(width: 96, height: 96, tileSize: 16);
      }),
      _Scene('a draw clipped entirely outside the surface', () {
        final ComputeTileScene scene = ComputeTileScene();
        const Rect clip = Rect.fromLTRB(0, 0, 200, 200);
        scene.appendPath(_rect(8, 8, 40, 40),
            clip: clip, materialIndex: 0, fillRule: FillRule.nonZero);
        // Its bounds are entirely past the 64x64 surface the plan is built
        // for, so ComputeTileScene.build drops it and the GPU has to as well -
        // without shifting the draw indices of everything after it.
        scene.appendPath(_rect(120, 120, 180, 180),
            clip: clip, materialIndex: 1, fillRule: FillRule.nonZero);
        scene.appendPath(_rect(20, 20, 60, 60),
            clip: clip, materialIndex: 2, fillRule: FillRule.nonZero);
        return scene.build(width: 64, height: 64, tileSize: 16);
      }),
      _Scene('fractional bounds on tile boundaries', () {
        // Bounds that land exactly on a tile edge and just inside one, which
        // is where a floor computed the other way changes a tile range.
        final ComputeTileScene scene = ComputeTileScene();
        const Rect clip = Rect.fromLTRB(0, 0, 80, 80);
        scene.appendPath(_rect(16, 32, 48, 64),
            clip: clip, materialIndex: 0, fillRule: FillRule.nonZero);
        scene.appendPath(_rect(15.9999, 31.9999, 48.0001, 64.0001),
            clip: clip, materialIndex: 1, fillRule: FillRule.nonZero);
        return scene.build(width: 80, height: 80, tileSize: 16);
      }),
      _Scene('a tile size that is not a power of two', () {
        final ComputeTileScene scene = ComputeTileScene();
        const Rect clip = Rect.fromLTRB(0, 0, 100, 70);
        scene.appendPath(_rect(3.5, 6.25, 77.75, 61.5),
            clip: clip, materialIndex: 0, fillRule: FillRule.nonZero);
        return scene.build(width: 100, height: 70, tileSize: 12);
      }),
      _Scene('many small draws', () => _crowded().plan()),
    ];

/// Twenty overlapping draws over a small grid, so several tiles carry runs of
/// three or more and the sort has real work.
_Scene _crowded() => _Scene('many small draws', () {
      final ComputeTileScene scene = ComputeTileScene();
      const Rect clip = Rect.fromLTRB(0, 0, 128, 96);
      for (var i = 0; i < 20; i++) {
        final double x = (i * 13) % 96 + 1.5;
        final double y = (i * 7) % 64 + 2.25;
        scene.appendPath(
          _rect(x, y, x + 30, y + 26),
          clip: clip,
          materialIndex: i,
          fillRule: FillRule.nonZero,
        );
      }
      return scene.build(width: 128, height: 96, tileSize: 16);
    });

ComputeTilePlan _oneRect(int width, int height, int tileSize) {
  final ComputeTileScene scene = ComputeTileScene();
  scene.appendPath(
    _rect(8, 6, width - 9.0, height - 7.0),
    clip: Rect.fromLTRB(0, 0, width.toDouble(), height.toDouble()),
    materialIndex: 0,
    fillRule: FillRule.nonZero,
  );
  return scene.build(width: width, height: height, tileSize: tileSize);
}

Path _rect(double left, double top, double right, double bottom) =>
    Path.rect(Rect.fromLTRB(left, top, right, bottom));
