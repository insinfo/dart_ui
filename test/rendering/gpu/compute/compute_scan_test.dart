/// The prefix-sum primitive both GPU stages are built on.
///
/// The Dart half is the definition the HLSL half is generated to implement, so
/// it is checked here on every runner - and the generator is checked too, since
/// a scan emitted with the wrong element-count name compiles, binds, and
/// silently scans a different number of elements.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/rendering/gpu/compute/compute_scan.dart';
import 'package:test/test.dart';

void main() {
  group('the exclusive scan', () {
    test('is empty for no elements, and still carries a total', () {
      expect(computeExclusiveScan(Uint32List(0)), <int>[0]);
    });

    test('starts at zero and appends the grand total', () {
      final Uint32List counts = Uint32List.fromList(<int>[3, 0, 7, 1]);
      expect(computeExclusiveScan(counts), <int>[0, 3, 3, 10, 11]);
    });

    test('reconstructs every count as a difference of neighbours', () {
      // The property a consumer relies on, which is why the total is appended
      // rather than returned separately: element i's count is
      // offsets[i + 1] - offsets[i] with no special case at the end.
      final Uint32List counts =
          Uint32List.fromList(List<int>.generate(1000, (int i) => i % 17));
      final Uint32List offsets = computeExclusiveScan(counts);
      expect(offsets.length, counts.length + 1);
      for (var i = 0; i < counts.length; i++) {
        expect(offsets[i + 1] - offsets[i], counts[i]);
      }
    });
  });

  group('the dispatch arithmetic', () {
    test('rounds up, and one element is one group', () {
      expect(computeScanGroups(0), 0);
      expect(computeScanGroups(1), 1);
      expect(computeScanGroups(kComputeScanGroupSize), 1);
      expect(computeScanGroups(kComputeScanGroupSize + 1), 2);
    });

    test('the two-level ceiling is the group size squared', () {
      expect(kComputeScanMaxElements,
          kComputeScanGroupSize * kComputeScanGroupSize);
      // And one group scans exactly that many block sums, which is what makes
      // the ceiling the ceiling.
      expect(computeScanGroups(kComputeScanMaxElements), kComputeScanGroupSize);
    });

    test('the dispatch ceiling is below the scan ceiling', () {
      // Not a coincidence to be discovered at a dispatch: several stages use
      // one group per element, so this is the binding limit and every executor
      // refuses past it by name.
      expect(kComputeMaxDispatchGroups, lessThan(kComputeScanMaxElements));
    });
  });

  group('the generated kernels', () {
    const ComputeScanEntryPoints names = ComputeScanEntryPoints('csThing');

    test('are named apart from anything else in the unit', () {
      expect(names.all, <String>[
        'csThingScanBlocks',
        'csThingScanBlockSums',
        'csThingScanApply'
      ]);
    });

    test('declare the three entry points and use the named uniforms', () {
      final String source = scanKernels(
        entryPoints: names,
        elementCount: 'uThingCount',
        blockCount: 'uThingBlocks',
      );
      expect(() => validateComputeScanContract(source, names), returnsNormally);
      expect(source, contains('uThingCount'));
      expect(source, contains('uThingBlocks'));
      // The grand total goes one past the last element, which is the whole
      // reason uOffsets is sized elementCount + 1.
      expect(source, contains('uOffsets[index] = uBlockSums[uThingBlocks];'));
    });

    test('a contract check names a missing entry point', () {
      expect(
        () => validateComputeScanContract('// nothing', names),
        throwsStateError,
      );
    });
  });
}
