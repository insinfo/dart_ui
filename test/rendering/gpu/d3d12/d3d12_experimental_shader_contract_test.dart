/// The Dart-side contracts of the two experimental HLSL programs, checked
/// without a device.
///
/// Every other file in this directory needs Direct3D 12 and therefore skips on
/// the Linux and macOS runners. This one does not: the instance layout, the
/// root-constant packing, the resource registers and the submission encoder are
/// all plain Dart, and all four are exactly the kind of thing a rename breaks
/// silently. A `float4` bound to `TEXCOORD0` instead of `TEXCOORD1` still
/// compiles, still draws, and draws the wrong pixels.
///
/// The encoder assertions mirror `SparseGlSubmission`'s, because the two are
/// deliberately parallel - see `d3d12_sparse_strips.dart` on the one place they
/// differ, which is that a Direct3D command carries a first *instance* where a
/// GL command carries a byte offset into the vertex buffer.
library;

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_compute_tile_shader.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:test/test.dart';

void main() {
  group('the sparse HLSL contract', () {
    test('every declared element and root constant exists in the source', () {
      expect(validateD3d12SparseShaderContract, returnsNormally);
    });

    test('the root constants pack without straddling a register', () {
      // HLSL packs a constant buffer into float4 registers and forbids a vector
      // from crossing a 16-byte boundary. Every float2 here has to sit in .xy
      // or .zw of one register and every float4 has to start one.
      const List<(String, int, int)> vectors = <(String, int, int)>[
        ('uViewport', D3d12SparseRootConstant.viewport, 2),
        ('uColor', D3d12SparseRootConstant.color, 4),
        ('uGradientLookup', D3d12SparseRootConstant.gradientLookup, 2),
        ('uTargetToLocal0', D3d12SparseRootConstant.targetToLocal0, 4),
        ('uTargetToLocal1', D3d12SparseRootConstant.targetToLocal1, 4),
        ('uGradientGeometry0', D3d12SparseRootConstant.gradientGeometry0, 4),
        ('uGradientGeometry1', D3d12SparseRootConstant.gradientGeometry1, 4),
      ];
      for (final (String name, int offset, int width) in vectors) {
        expect(offset ~/ 4, (offset + width - 1) ~/ 4,
            reason: '$name straddles a 16-byte boundary at word $offset');
      }
      expect(kD3d12SparseRootConstantCount,
          D3d12SparseRootConstant.gradientGeometry1 + 4);
    });

    test('the instance elements cover the stride exactly once', () {
      var covered = 0;
      for (final D3d12SparseInputElement element in kD3d12SparseInputElements) {
        expect(element.strideBytes, kD3d12SparseInstanceStrideBytes);
        expect(element.instanceDataStepRate, 1);
        covered += element.components * 4;
        expect(element.offsetBytes + element.components * 4,
            lessThanOrEqualTo(kD3d12SparseInstanceStrideBytes));
      }
      expect(covered, kD3d12SparseInstanceStrideBytes);
      // Both elements are TEXCOORD; only the index tells them apart, which is
      // exactly the mistake this asserts against.
      expect(
        kD3d12SparseInputElements.map((e) => e.semanticIndex).toList(),
        <int>[0, 1],
      );
    });

    test('a renamed shader input is caught rather than compiled', () {
      // The check has to be able to fail, or it proves nothing.
      expect(
        () {
          const D3d12SparseInputElement wrong = D3d12SparseInputElement(
            name: 'quadRectangle',
            semanticName: 'TEXCOORD',
            semanticIndex: 0,
            components: 4,
            offsetBytes: 0,
          );
          if (!kD3d12SparseVertexShader.contains('float4 ${wrong.name}')) {
            throw StateError('missing sparse HLSL input element');
          }
        },
        throwsStateError,
      );
    });
  });

  group('the sparse submission encoder', () {
    test('orders solid before alpha within a batch, and batches in order', () {
      final SparseStripDrawPlan plan = SparseStripDrawPlan();
      expect(plan.append(_strips(0), materialIndex: 0), 0);
      expect(plan.append(_strips(40), materialIndex: 1), 1);

      final SparseD3d12Submission submission = SparseD3d12Submission()
        ..encode(plan);
      expect(submission.commandCount, greaterThanOrEqualTo(2));

      var previousMaterial = -1;
      var seenAlphaForMaterial = false;
      for (var i = 0; i < submission.commandCount; i++) {
        final int material = submission.commandMaterial(i);
        expect(material, greaterThanOrEqualTo(previousMaterial),
            reason: 'materials must appear in batch order');
        if (material != previousMaterial) {
          previousMaterial = material;
          seenAlphaForMaterial = false;
        }
        if (submission.commandMode(i) == kD3d12SparseModeAlpha) {
          seenAlphaForMaterial = true;
        } else {
          expect(seenAlphaForMaterial, isFalse,
              reason: 'a solid run followed an alpha run in the same batch, '
                  'which would composite the interior over its own boundary');
        }
      }
    });

    test('first instance is an instance index, not a byte offset', () {
      // The one deliberate difference from the GL encoder. A command that
      // reported bytes would be passed to StartInstanceLocation and skip six
      // times too many instances.
      final SparseStripDrawPlan plan = SparseStripDrawPlan();
      plan.append(_strips(0), materialIndex: 0);
      final SparseD3d12Submission submission = SparseD3d12Submission()
        ..encode(plan);

      var expectedFirst = 0;
      for (var i = 0; i < submission.commandCount; i++) {
        expect(submission.commandFirstInstance(i), expectedFirst);
        expectedFirst += submission.commandInstanceCount(i);
      }
      expect(expectedFirst, submission.instanceCount);
    });

    test('re-encoding reuses the arenas and produces the same commands', () {
      final SparseStripDrawPlan plan = SparseStripDrawPlan();
      plan.append(_strips(0), materialIndex: 0);
      final SparseD3d12Submission submission = SparseD3d12Submission()
        ..encode(plan);
      final int growths = submission.arenaGrowths;
      final List<int> first = submission.commands.toList();

      submission.encode(plan);
      expect(submission.commands.toList(), first);
      expect(submission.arenaGrowths, growths,
          reason: 'a steady-state frame must not grow an arena');
    });
  });

  group('the compute-tile HLSL contract', () {
    test('every declared constant and register exists in the source', () {
      expect(validateD3d12ComputeTileShaderContract, returnsNormally);
    });

    test('the thread group is square and within the API limit', () {
      expect(kD3d12ComputeTileMaxTileSize, 16);
      expect(
        kD3d12ComputeTileMaxTileSize * kD3d12ComputeTileMaxTileSize,
        lessThanOrEqualTo(1024),
        reason: 'Direct3D 12 allows at most 1024 threads per group',
      );
      for (final String source in <String>[
        kD3d12ComputeTileBufferShader,
        kD3d12ComputeTileTextureShader,
      ]) {
        expect(
          source.contains(
            '[numthreads($kD3d12ComputeTileMaxTileSize, '
            '$kD3d12ComputeTileMaxTileSize, 1)]',
          ),
          isTrue,
        );
      }
    });

    test('the two entry points share one coverage loop', () {
      // Both sources are built from the same shared fragment, so the crossing
      // test, the sample grid and the quantisation exist once. A copy would be
      // two chances to drift from the oracle, and only one of them would be
      // covered by the buffer parity test.
      const String marker = 'uint coverageAtPixel(uint draw,';
      expect(kD3d12ComputeTileBufferShader.contains(marker), isTrue);
      expect(kD3d12ComputeTileTextureShader.contains(marker), isTrue);
      expect(
        kD3d12ComputeTileBufferShader.split(marker).length,
        2,
        reason: 'the loop appears more than once in one compilation unit',
      );
    });

    test('the composition entry point normalises the way R8_UNORM does', () {
      // The composite reads this texture with the same Texture2D.Load the
      // sparse pixel shader uses on an R8_UNORM alpha page, and R8_UNORM
      // normalises to byte / 255. Writing anything else here would make the two
      // routes' composition arithmetic differ by a scale nobody would look for.
      expect(
        kD3d12ComputeTileTextureShader.contains('/ 255.0'),
        isTrue,
      );
      expect(
        kD3d12ComputeTileTextureShader.contains('RWTexture2D<float>'),
        isTrue,
      );
      expect(
        kD3d12ComputeTileBufferShader.contains('RWStructuredBuffer<uint>'),
        isTrue,
      );
    });

    test('the root parameters are contiguous and complete', () {
      expect(kD3d12ComputeTileRootConstantsSlot, 0);
      expect(kD3d12ComputeTileCoverageSlot,
          kD3d12ComputeTileRootParameterCount - 1);
      expect(
        kD3d12ComputeTileCommandsSlot - kD3d12ComputeTileSegmentsSlot,
        5,
        reason: 'six scene buffers occupy t0..t5',
      );
    });

    test('the even-odd constant matches the encoded fill-rule index', () {
      // The shader tests `header.w == 1`. That 1 is `FillRule.evenOdd.index`,
      // written into the draw record by `ComputeTileScene`, so a reordering of
      // the enum would silently invert every fill.
      expect(kD3d12ComputeTileEvenOdd, 1);
    });
  });
}

/// A path whose coverage produces both solid runs and boundary strips.
StripBuffer _strips(double offset) {
  final PathBuilder builder = PathBuilder()
    ..moveTo(offset + 2.5, 2.5)
    ..lineTo(offset + 30.5, 4)
    ..lineTo(offset + 29, 29.25)
    ..lineTo(offset + 4, 27)
    ..close();
  return SparseStripGenerator().fill(
    builder.build(),
    Rect.fromLTRB(offset, 0, offset + 40, 32),
  );
}
