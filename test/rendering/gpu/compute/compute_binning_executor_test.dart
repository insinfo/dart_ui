/// The binning executor's policy, with no device in the room.
///
/// The same argument `compute_flatten_executor_test.dart` makes: the dispatch
/// sizes, the refusals and the bump-allocator retry are arithmetic over numbers
/// a driver hands back, and they should be checked on every runner rather than
/// only on a Windows machine with a GPU.
///
/// The fake here does not reimplement binning. It replays a `ComputeTilePlan` -
/// the CPU planner's own answer - and truncates the reference buffer the way
/// the scatter kernel does, because that truncation is precisely what the retry
/// depends on. A fake that binned the scene itself would be testing the fake.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_scan.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_binning_executor.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

void main() {
  group('the grid derives its own shape', () {
    test('a size that divides evenly', () {
      final ComputeBinningGrid grid =
          ComputeBinningGrid(width: 64, height: 32, tileSize: 16);
      expect(grid.columns, 4);
      expect(grid.rows, 2);
      expect(grid.tileCount, 8);
    });

    test('a size that does not divides its last tile short', () {
      final ComputeBinningGrid grid =
          ComputeBinningGrid(width: 70, height: 54, tileSize: 16);
      expect(grid.columns, 5);
      expect(grid.rows, 4);
    });

    test('a non-positive size is refused', () {
      expect(
        () => ComputeBinningGrid(width: 0, height: 8, tileSize: 16),
        throwsArgumentError,
      );
    });
  });

  group('the dispatch sizes follow from the group size', () {
    test('one sort group per tile, whatever the scan needs', () {
      final ComputeBinningDispatch dispatch =
          ComputeBinningExecutor.dispatchFor(
        drawCount: 3,
        tileCount: 300,
        referenceBudget: 64,
      );
      expect(dispatch.drawGroups, 1);
      expect(dispatch.blockCount, 2);
      expect(dispatch.tileGroups, 2);
      // 301 elements, so the apply pass needs a second group for the total.
      expect(dispatch.applyGroups, 2);
      // The sort is indexed by tile and not by block: an empty tile retires
      // immediately, but a tile has to be a group for its run to be sorted.
      expect(dispatch.tileCount, 300);
    });

    test('a tile count that is an exact multiple still applies over one more',
        () {
      final ComputeBinningDispatch dispatch =
          ComputeBinningExecutor.dispatchFor(
        drawCount: 1,
        tileCount: kComputeScanGroupSize,
        referenceBudget: 8,
      );
      expect(dispatch.blockCount, 1);
      expect(dispatch.applyGroups, 2);
    });
  });

  group('the executor refuses what the kernels cannot do', () {
    test('a grid past the scan and dispatch ceiling, by name', () {
      final _FakeBinningDriver driver = _FakeBinningDriver(null);
      final ComputeBinningExecutor executor = ComputeBinningExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);
      expect(
        () => executor.bin(
          bounds: Float32List(4),
          drawCount: 1,
          // 65 536 tiles: one over what a single sort dispatch can address.
          grid: ComputeBinningGrid(width: 4096, height: 4096, tileSize: 16),
        ),
        throwsA(isA<ComputeBinningError>().having(
          (ComputeBinningError error) => error.rejection,
          'rejection',
          ComputeBinningRejection.tileCountExceedsScan,
        )),
      );
      expect(driver.passes, 0);
    });

    test('a scene past the reference ceiling, by name', () {
      final ComputeTilePlan plan = _crowdedPlan();
      final _FakeBinningDriver driver = _FakeBinningDriver(plan);
      final ComputeBinningExecutor executor = ComputeBinningExecutor(
        driver,
        maxReferences: 4,
      )..initialize();
      addTearDown(executor.dispose);
      expect(
        () => executor.bin(
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: ComputeBinningGrid(
            width: plan.width,
            height: plan.height,
            tileSize: plan.tileSize,
          ),
        ),
        throwsA(isA<ComputeBinningError>().having(
          (ComputeBinningError error) => error.rejection,
          'rejection',
          ComputeBinningRejection.referenceBudgetExceeded,
        )),
      );
    });

    test('a bounds array shorter than the draw count is an argument error', () {
      final _FakeBinningDriver driver = _FakeBinningDriver(null);
      final ComputeBinningExecutor executor = ComputeBinningExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);
      expect(
        () => executor.bin(
          bounds: Float32List(4),
          drawCount: 2,
          grid: ComputeBinningGrid(width: 32, height: 32, tileSize: 16),
        ),
        throwsArgumentError,
      );
    });

    test('an empty scene never reaches the driver', () {
      final _FakeBinningDriver driver = _FakeBinningDriver(null);
      final ComputeBinningExecutor executor = ComputeBinningExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);
      final ComputeBinningResult result = executor.bin(
        bounds: Float32List(0),
        drawCount: 0,
        grid: ComputeBinningGrid(width: 32, height: 32, tileSize: 16),
      );
      expect(result.passes, 0);
      expect(result.referenceCount, 0);
      expect(result.commandCount, 0);
      expect(result.bins.length, 8);
      expect(driver.passes, 0);
    });

    test('bin before initialize is a state error', () {
      final ComputeBinningExecutor executor =
          ComputeBinningExecutor(_FakeBinningDriver(null));
      expect(
        () => executor.bin(
          bounds: Float32List(4),
          drawCount: 1,
          grid: ComputeBinningGrid(width: 32, height: 32, tileSize: 16),
        ),
        throwsStateError,
      );
    });
  });

  group('the bump allocator grows once and only when it has to', () {
    test('a budget that fits runs one pass', () {
      final ComputeTilePlan plan = _crowdedPlan();
      final _FakeBinningDriver driver = _FakeBinningDriver(plan);
      final ComputeBinningExecutor executor = ComputeBinningExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);
      final ComputeBinningResult result = executor.bin(
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        ),
      );
      expect(result.passes, 1);
      expect(result.references, plan.references);
      expect(result.commands, plan.commands);
    });

    test('a budget that overflows runs exactly twice', () {
      final ComputeTilePlan plan = _crowdedPlan();
      final _FakeBinningDriver driver = _FakeBinningDriver(plan);
      final ComputeBinningExecutor executor = ComputeBinningExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);
      final ComputeBinningResult result = executor.bin(
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        ),
        referenceBudget: 3,
      );
      expect(result.passes, 2);
      expect(driver.budgets, <int>[3, plan.references.length]);
      expect(result.references, plan.references);
    });
  });

  test('a driver whose count drifts between passes is a state error', () {
    final ComputeTilePlan plan = _crowdedPlan();
    final _FakeBinningDriver driver =
        _FakeBinningDriver(plan, driftOnSecondPass: true);
    final ComputeBinningExecutor executor = ComputeBinningExecutor(driver)
      ..initialize();
    addTearDown(executor.dispose);
    expect(
      () => executor.bin(
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        ),
        referenceBudget: 3,
      ),
      throwsStateError,
    );
  });
}

ComputeTilePlan _crowdedPlan() {
  final ComputeTileScene scene = ComputeTileScene();
  const Rect clip = Rect.fromLTRB(0, 0, 128, 96);
  for (var i = 0; i < 12; i++) {
    final double x = (i * 13) % 96 + 1.5;
    final double y = (i * 7) % 64 + 2.25;
    scene.appendPath(
      Path.rect(Rect.fromLTRB(x, y, x + 30, y + 26)),
      clip: clip,
      materialIndex: i,
      fillRule: FillRule.nonZero,
    );
  }
  return scene.build(width: 128, height: 96, tileSize: 16);
}

/// Replays a plan, truncated at the budget the way the scatter kernel is.
final class _FakeBinningDriver implements ComputeBinningDriver {
  _FakeBinningDriver(this._plan, {this.driftOnSecondPass = false});

  final ComputeTilePlan? _plan;
  final bool driftOnSecondPass;

  int passes = 0;
  final List<int> budgets = <int>[];

  @override
  int createBinningPipeline() => 5;

  @override
  void disposeBinningPipeline(int pipeline) {}

  @override
  void discardNativeResources() {}

  @override
  ComputeBinningReadback runBinningPass({
    required int pipeline,
    required Float32List bounds,
    required Uint32List rootConstants,
    required ComputeBinningDispatch dispatch,
  }) {
    passes++;
    budgets.add(dispatch.referenceBudget);
    final ComputeTilePlan plan = _plan!;
    final int tileCount = dispatch.tileCount;

    final Uint32List bins = Uint32List.fromList(plan.bins);
    if (driftOnSecondPass && passes == 2) {
      // The last tile's run grows by one, so the recovered total changes.
      bins[(tileCount - 1) * 2 + 1] += 1;
    }
    // The scatter advances its cursor whether or not the write lands, so the
    // counts are exact even when the buffer overflowed - only the contents are
    // missing.
    final Uint32List references = Uint32List(dispatch.referenceBudget);
    final int written = plan.references.length < dispatch.referenceBudget
        ? plan.references.length
        : dispatch.referenceBudget;
    references.setRange(0, written, plan.references);

    final Uint32List commands = Uint32List(tileCount * 3)
      ..setRange(0, plan.commands.length, plan.commands);

    // uOffsets ends the pass holding the exclusive scan of the occupancy flags.
    final Uint32List flags = Uint32List(tileCount);
    for (var tile = 0; tile < tileCount; tile++) {
      flags[tile] = bins[tile * 2 + 1] == 0 ? 0 : 1;
    }
    return ComputeBinningReadback(
      bins: bins,
      references: references,
      commands: commands,
      offsets: computeExclusiveScan(flags),
    );
  }
}
