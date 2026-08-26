/// The flatten executor's policy, with no device in the room.
///
/// Everything the executor decides - the dispatch sizes, the refusals, and the
/// bump-allocator retry - is arithmetic over numbers a driver hands back. A
/// fake driver that computes the same answers `ComputeFlattenReference` does,
/// and truncates at the budget the way the emit kernel does, exercises all of
/// it on every runner instead of only on a Windows machine with a GPU.
///
/// The retry in particular is worth checking here rather than there: the second
/// pass only happens when the first overflows, so on a GPU it is one branch out
/// of two and easy to leave untested by choosing a comfortable budget.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_curve_scene.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_flatten_reference.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_flatten_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_flatten_shader.dart';
import 'package:test/test.dart';

void main() {
  group('the dispatch sizes follow from the group size', () {
    test('one curve is one block, one apply group and one emit group', () {
      final ComputeFlattenDispatch dispatch =
          ComputeFlattenExecutor.dispatchFor(curveCount: 1, segmentBudget: 16);
      expect(dispatch.blockCount, 1);
      expect(dispatch.applyGroups, 1);
      expect(dispatch.curveCount, 1);
    });

    test('a full block still applies over one more element', () {
      // csScanApply covers curveCount + 1 elements, so a curve count that is an
      // exact multiple of the group size needs a second group for the total
      // alone. Getting this wrong loses the grand total and every consumer
      // reads a segment count of zero for the last curve.
      final ComputeFlattenDispatch dispatch =
          ComputeFlattenExecutor.dispatchFor(
        curveCount: kComputeFlattenGroupSize,
        segmentBudget: 16,
      );
      expect(dispatch.blockCount, 1);
      expect(dispatch.applyGroups, 2);
    });

    test('the block count rounds up', () {
      final ComputeFlattenDispatch dispatch =
          ComputeFlattenExecutor.dispatchFor(
        curveCount: kComputeFlattenGroupSize + 1,
        segmentBudget: 16,
      );
      expect(dispatch.blockCount, 2);
    });
  });

  group('the executor refuses what the kernels cannot do', () {
    test('more curves than the two-level scan handles, by name', () {
      final _FakeFlattenDriver driver = _FakeFlattenDriver(null);
      final ComputeFlattenExecutor executor = ComputeFlattenExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);
      expect(
        () => executor.flatten(_oversizedUpload()),
        throwsA(isA<ComputeFlattenError>().having(
          (ComputeFlattenError error) => error.rejection,
          'rejection',
          ComputeFlattenRejection.curveCountExceedsScan,
        )),
      );
      expect(driver.passes, 0);
    });

    test('a scene past the segment ceiling, by name', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(Path.oval(const Rect.fromLTRB(0, 0, 400, 400)));
      final ComputeCurveUpload upload = scene.upload();
      final _FakeFlattenDriver driver = _FakeFlattenDriver(upload);
      final ComputeFlattenExecutor executor = ComputeFlattenExecutor(
        driver,
        maxSegments: 8,
        minimumSegmentBudget: 4,
      )..initialize();
      addTearDown(executor.dispose);
      expect(
        () => executor.flatten(upload),
        throwsA(isA<ComputeFlattenError>().having(
          (ComputeFlattenError error) => error.rejection,
          'rejection',
          ComputeFlattenRejection.segmentBudgetExceeded,
        )),
      );
    });

    test('an empty scene never reaches the driver', () {
      final _FakeFlattenDriver driver = _FakeFlattenDriver(null);
      final ComputeFlattenExecutor executor = ComputeFlattenExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);
      final ComputeFlattenResult result = executor.flatten(
        ComputeCurveScene().upload(),
      );
      expect(result.isEmpty, isTrue);
      expect(result.passes, 0);
      expect(result.offsets, <int>[0]);
      expect(driver.passes, 0);
    });

    test('flatten before initialize is a state error', () {
      final ComputeFlattenExecutor executor =
          ComputeFlattenExecutor(_FakeFlattenDriver(null));
      expect(
        () => executor.flatten(ComputeCurveScene().upload()),
        throwsStateError,
      );
    });
  });

  group('the bump allocator grows once and only when it has to', () {
    test('a budget that fits runs one pass', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(Path.rect(const Rect.fromLTRB(0, 0, 10, 10)));
      final ComputeCurveUpload upload = scene.upload();
      final _FakeFlattenDriver driver = _FakeFlattenDriver(upload);
      final ComputeFlattenExecutor executor = ComputeFlattenExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);

      final ComputeFlattenResult result = executor.flatten(upload);
      expect(result.passes, 1);
      expect(driver.passes, 1);
      expect(result.totalSegments, 4);
      expect(result.segments.length, 16);
    });

    test('a budget that overflows runs exactly twice and is then exact', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(Path.oval(const Rect.fromLTRB(0, 0, 120, 90)));
      final ComputeCurveUpload upload = scene.upload();
      final ComputeFlattenReference reference = ComputeFlattenReference(upload);
      final _FakeFlattenDriver driver = _FakeFlattenDriver(upload);
      final ComputeFlattenExecutor executor = ComputeFlattenExecutor(
        driver,
        minimumSegmentBudget: 1,
      )..initialize();
      addTearDown(executor.dispose);

      final ComputeFlattenResult result =
          executor.flatten(upload, segmentBudget: 2);
      expect(result.passes, 2);
      expect(driver.passes, 2);
      // The second budget is the total the first pass reported, not a guess:
      // the scan is unaffected by the emit kernel's bound, so one growth is
      // always enough.
      expect(driver.budgets, <int>[2, reference.totalSegments]);
      expect(result.segmentBudget, reference.totalSegments);
      expect(result.totalSegments, reference.totalSegments);
      expect(result.segments, reference.segments);
    });

    test('carrying the budget forward removes the second pass', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(Path.oval(const Rect.fromLTRB(0, 0, 120, 90)));
      final ComputeCurveUpload upload = scene.upload();
      final _FakeFlattenDriver driver = _FakeFlattenDriver(upload);
      final ComputeFlattenExecutor executor = ComputeFlattenExecutor(
        driver,
        minimumSegmentBudget: 1,
      )..initialize();
      addTearDown(executor.dispose);

      final ComputeFlattenResult first =
          executor.flatten(upload, segmentBudget: 2);
      final ComputeFlattenResult second =
          executor.flatten(upload, segmentBudget: first.segmentBudget);
      expect(second.passes, 1);
      expect(second.segments, first.segments);
    });
  });

  group('a driver that answers inconsistently is caught, not trusted', () {
    test('the wrong number of counts is a state error', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(Path.rect(const Rect.fromLTRB(0, 0, 10, 10)));
      final ComputeCurveUpload upload = scene.upload();
      final _FakeFlattenDriver driver =
          _FakeFlattenDriver(upload, dropOneCount: true);
      final ComputeFlattenExecutor executor = ComputeFlattenExecutor(driver)
        ..initialize();
      addTearDown(executor.dispose);
      expect(() => executor.flatten(upload), throwsStateError);
    });

    test('a total that changes between passes is a state error', () {
      // The scan is a pure function of the scene. A driver whose second pass
      // reports a different total is one that did not reset its buffers, and
      // that is the failure the executor must not paper over by believing the
      // second answer.
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(Path.oval(const Rect.fromLTRB(0, 0, 120, 90)));
      final ComputeCurveUpload upload = scene.upload();
      final _FakeFlattenDriver driver =
          _FakeFlattenDriver(upload, driftOnSecondPass: true);
      final ComputeFlattenExecutor executor = ComputeFlattenExecutor(
        driver,
        minimumSegmentBudget: 1,
      )..initialize();
      addTearDown(executor.dispose);
      expect(
        () => executor.flatten(upload, segmentBudget: 2),
        throwsStateError,
      );
    });
  });
}

/// A curve scene with more curves than the two-level scan accepts.
///
/// Built by hand rather than out of a path: it needs no valid geometry, only a
/// count, and flattening a path with 65 537 curves to reach one would cost more
/// than the test measures.
ComputeCurveUpload _oversizedUpload() {
  const int curves = kComputeFlattenMaxCurves + 1;
  return ComputeCurveUpload(
    curves: Uint32List(curves * kComputeCurveHeaderStride),
    curvePoints: Float32List(curves * kComputeCurvePointStride),
    transforms: Float32List(kComputeCurveTransformStride),
    paths: Uint32List(kComputeCurvePathStride),
    curveCount: curves,
    pathCount: 1,
  );
}

/// A driver that computes what the kernels are specified to compute.
///
/// Not a mock returning canned values: it runs [ComputeFlattenReference] and
/// then applies the emit kernel's budget rule - a segment past the bound is
/// **not written**, and the slot keeps the zero the driver fills the buffer
/// with. That is the behaviour the retry depends on, so faking it any other way
/// would test the fake.
final class _FakeFlattenDriver implements ComputeFlattenDriver {
  _FakeFlattenDriver(
    this._upload, {
    this.dropOneCount = false,
    this.driftOnSecondPass = false,
  });

  final ComputeCurveUpload? _upload;
  final bool dropOneCount;
  final bool driftOnSecondPass;

  int passes = 0;
  final List<int> budgets = <int>[];

  @override
  int createFlattenPipeline() => 7;

  @override
  void disposeFlattenPipeline(int pipeline) {}

  @override
  void discardNativeResources() {}

  @override
  ComputeFlattenReadback runFlattenPass({
    required int pipeline,
    required ComputeCurveUpload scene,
    required Uint32List rootConstants,
    required ComputeFlattenDispatch dispatch,
  }) {
    passes++;
    budgets.add(dispatch.segmentBudget);
    final ComputeFlattenReference reference =
        ComputeFlattenReference(_upload ?? scene);
    final Uint32List counts = Uint32List.fromList(reference.counts);
    final Uint32List offsets = Uint32List.fromList(reference.offsets);
    if (driftOnSecondPass && passes == 2) {
      offsets[offsets.length - 1] += 1;
    }
    final Float32List segments = Float32List(dispatch.segmentBudget * 4);
    final int written = reference.totalSegments < dispatch.segmentBudget
        ? reference.totalSegments
        : dispatch.segmentBudget;
    segments.setRange(0, written * 4, reference.segments);
    return ComputeFlattenReadback(
      counts: dropOneCount
          ? Uint32List.sublistView(counts, 0, counts.length - 1)
          : counts,
      offsets: offsets,
      segments: segments,
    );
  }
}
