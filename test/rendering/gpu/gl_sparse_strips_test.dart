import 'dart:typed_data';

import 'package:dart_ui/src/rendering/gpu/gl/gl_sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:test/test.dart';

void main() {
  group('sparse GL shader contract', () {
    test('desktop and ES sources match attributes and uniforms', () {
      expect(validateSparseGlShaderContract, returnsNormally);
      for (final bool desktop in <bool>[true, false]) {
        final String vertex = sparseGlVertexShaderSource(desktop: desktop);
        final String fragment = sparseGlFragmentShaderSource(desktop: desktop);
        expect(vertex, contains('gl_VertexID'));
        expect(vertex, contains('uYFlip == 0 ? ndcY : -ndcY'));
        expect(fragment, contains('texelFetch'));
        expect(fragment, contains('uColor * coverage'));
        expect(fragment, contains('gradientParameter'));
        expect(fragment, contains('uGradientLut'));
        expect(fragment, contains('straight.rgb *= straight.a'));
      }
    });

    test('instance layout is tightly packed and advances per instance', () {
      expect(kSparseGlInstanceFloatCount, 6);
      expect(kSparseGlInstanceStrideBytes, 24);
      expect(
        <List<Object>>[
          for (final SparseGlAttribute attribute in kSparseGlAttributes)
            <Object>[
              attribute.name,
              attribute.location,
              attribute.components,
              attribute.offsetBytes,
              attribute.strideBytes,
              attribute.divisor,
            ],
        ],
        <List<Object>>[
          <Object>['aQuadRect', 0, 4, 0, 24, 1],
          <Object>['aAtlasOrigin', 1, 2, 16, 24, 1],
        ],
      );
    });
  });

  group('SparseGlSubmission', () {
    test('consumes ordered batches and splits alpha commands per page', () {
      final StripBuffer first = StripBuffer()..addFill(1, 2, 5);
      final int firstAlpha = first.reserveAlphas(6 * kStripHeight);
      first.alphas.fillRange(
        firstAlpha,
        firstAlpha + 6 * kStripHeight,
        91,
      );
      first.addStrip(8, 4, 6, firstAlpha);
      final StripBuffer second = StripBuffer()..addFill(20, 30, 7);
      final SparseStripDrawPlan plan = SparseStripDrawPlan(
        atlasWidth: 4,
        atlasHeight: 4,
      )
        ..append(first, materialIndex: 3)
        ..append(second, materialIndex: 8);
      final SparseGlSubmission submission = SparseGlSubmission()..encode(plan);

      expect(submission.instanceCount, 4);
      expect(submission.commandCount, 4);
      expect(
        <List<int>>[
          for (var i = 0; i < submission.commandCount; i++)
            <int>[
              submission.commandMode(i),
              submission.commandMaterial(i),
              submission.commandAtlasPage(i),
              submission.commandFirstInstance(i),
              submission.commandInstanceCount(i),
            ],
        ],
        <List<int>>[
          <int>[kSparseGlModeSolid, 3, -1, 0, 1],
          <int>[kSparseGlModeAlpha, 3, 0, 1, 1],
          <int>[kSparseGlModeAlpha, 3, 1, 2, 1],
          <int>[kSparseGlModeSolid, 8, -1, 3, 1],
        ],
      );
      expect(
        submission.instances,
        orderedEquals(<double>[
          1,
          2,
          5,
          4,
          0,
          0,
          8,
          4,
          4,
          4,
          0,
          0,
          12,
          4,
          2,
          4,
          0,
          0,
          20,
          30,
          7,
          4,
          0,
          0,
        ]),
      );
      expect(
        submission.commandAttributeOffsetBytes(
          2,
          kSparseGlAttributes[1],
        ),
        2 * kSparseGlInstanceStrideBytes + kSparseGlAtlasOriginOffsetBytes,
      );
    });

    test('GL instance stream reconstructs exact plan coverage', () {
      final StripBuffer source = StripBuffer()..addFill(-2, 3, 6);
      final int alpha = source.reserveAlphas(9 * kStripHeight);
      for (var i = 0; i < 9 * kStripHeight; i++) {
        source.alphas[alpha + i] = (i * 17 + 3) & 0xff;
      }
      source.addStrip(4, 3, 9, alpha);
      final SparseStripDrawPlan plan = SparseStripDrawPlan(
        atlasWidth: 5,
        atlasHeight: 4,
      )..append(source, materialIndex: 0);
      final SparseGlSubmission submission = SparseGlSubmission()..encode(plan);

      expect(
        _reconstructSubmission(submission, plan, -2, 3, 15, 4),
        orderedEquals(_reconstructPlan(plan, -2, 3, 15, 4)),
      );
    });

    test('encode reuses high-water arenas and clears empty plans', () {
      final StripBuffer source = StripBuffer();
      for (var i = 0; i < 12; i++) {
        source.addFill(i, i * kStripHeight, 1);
      }
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(source, materialIndex: 0);
      final SparseGlSubmission submission = SparseGlSubmission(
        initialInstances: 1,
        initialCommands: 1,
      )..encode(plan);
      final Float32List instanceArena = submission.instanceStorage;
      final Int32List commandArena = submission.commandStorage;
      final int growths = submission.arenaGrowths;

      submission.encode(plan);
      expect(submission.instanceStorage, same(instanceArena));
      expect(submission.commandStorage, same(commandArena));
      expect(submission.arenaGrowths, growths);

      submission.encode(SparseStripDrawPlan());
      expect(submission.instanceCount, 0);
      expect(submission.commandCount, 0);
      expect(submission.instanceStorage, same(instanceArena));
    });
  });
}

Uint8List _reconstructSubmission(
  SparseGlSubmission submission,
  SparseStripDrawPlan plan,
  int left,
  int top,
  int width,
  int height,
) {
  final Uint8List pixels = Uint8List(width * height);
  for (var command = 0; command < submission.commandCount; command++) {
    final int first = submission.commandFirstInstance(command);
    final int end = first + submission.commandInstanceCount(command);
    final bool alpha = submission.commandMode(command) == kSparseGlModeAlpha;
    final Uint8List? page = alpha
        ? plan.alphaPagePixels(submission.commandAtlasPage(command))
        : null;
    for (var instance = first; instance < end; instance++) {
      for (var y = 0; y < submission.instanceHeight(instance); y++) {
        for (var x = 0; x < submission.instanceWidth(instance); x++) {
          final int destinationX = submission.instanceX(instance).toInt() + x;
          final int destinationY = submission.instanceY(instance).toInt() + y;
          pixels[(destinationY - top) * width + destinationX - left] = alpha
              ? page![(submission.instanceAtlasY(instance).toInt() + y) *
                      plan.atlasWidth +
                  submission.instanceAtlasX(instance).toInt() +
                  x]
              : 255;
        }
      }
    }
  }
  return pixels;
}

Uint8List _reconstructPlan(
  SparseStripDrawPlan plan,
  int left,
  int top,
  int width,
  int height,
) {
  final Uint8List pixels = Uint8List(width * height);
  for (var i = 0; i < plan.solidInstanceCount; i++) {
    for (var y = 0; y < plan.solidHeight(i); y++) {
      for (var x = 0; x < plan.solidWidth(i); x++) {
        pixels[(plan.solidY(i) + y - top) * width + plan.solidX(i) + x - left] =
            255;
      }
    }
  }
  for (var i = 0; i < plan.alphaInstanceCount; i++) {
    final Uint8List page = plan.alphaPagePixels(plan.alphaAtlasPage(i));
    for (var y = 0; y < plan.alphaHeight(i); y++) {
      for (var x = 0; x < plan.alphaWidth(i); x++) {
        pixels[(plan.alphaY(i) + y - top) * width + plan.alphaX(i) + x - left] =
            page[(plan.alphaAtlasY(i) + y) * plan.atlasWidth +
                plan.alphaAtlasX(i) +
                x];
      }
    }
  }
  return pixels;
}
