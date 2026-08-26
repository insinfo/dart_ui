/// The sparse-strip SPIR-V, the submission encoder and the executor's ordering,
/// none of which needs a GPU.
///
/// This is the half of the Vulkan sparse port that runs on every CI machine.
/// It answers three questions a live-device test cannot answer cheaply and one
/// it cannot answer at all:
///
///   * **are the words a SPIR-V module?** The structural check of
///     `vulkan_spirv.dart` plus the decorations this particular pipeline layout
///     depends on. A driver that rejects a module says so; a driver that
///     *accepts* a module whose descriptor is decorated into the wrong set
///     samples the wrong image and draws a plausible picture.
///   * **does the Vulkan encoder agree with the OpenGL one?** It is re-derived
///     here rather than shared, so this compares them element for element. The
///     ordering property - batch, then material, then page run - is the thing
///     both files exist to preserve, and a divergence would show up as two
///     backends disagreeing about a scene neither of them draws wrong.
///   * **does the executor send the right calls in the right order?** With a
///     fake driver, including what it does after a device loss and what it
///     refuses before touching anything.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_spirv.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

void main() {
  group('the emitted SPIR-V', () {
    test('the contract check passes', () {
      expect(validateVulkanSparseShaderContract, returnsNormally);
    });

    test('every module is structurally well-formed', () {
      final VulkanSparseShaderCode code = VulkanSparseShaderCode();
      expect(validateSpirvStructure(code.vertex), isEmpty);
      for (var i = 0; i < code.fragments.length; i++) {
        expect(validateSpirvStructure(code.fragments[i]), isEmpty,
            reason: 'fragment module $i');
      }
      expect(code.fragments, hasLength(kVulkanSparseFragmentModuleCount));
      // A shader that stopped being emitted halves the count, and nothing else
      // in this file would notice.
      expect(code.wordCount, greaterThan(400));
    });

    test('the header is SPIR-V 1.0 and the entry point is named main', () {
      final VulkanSparseShaderCode code = VulkanSparseShaderCode();
      for (final Uint32List words in <Uint32List>[
        code.vertex,
        ...code.fragments,
      ]) {
        expect(words[0], kSpirvMagic);
        expect(words[1], kSpirvVersion1_0);
        expect(words[4], 0, reason: 'the reserved schema word');
        // The name is re-derived rather than searched for as a string,
        // because the thing that can be wrong is the NUL padding rule.
        expect(_containsSequence(words, literalString(kVulkanSparseEntryPoint)),
            isTrue);
      }
    });

    test('only the module that samples an image declares one', () {
      // The trap this closes: a fragment module that declared the alpha atlas
      // it never reads would make a solid-coverage draw look as if it needed a
      // page bound, and the first reader to "fix" the binding would be fixing
      // nothing.
      for (final int coverage in kVulkanSparseCoverageModes) {
        for (final int paint in kVulkanSparsePaintModes) {
          final Uint32List words =
              buildVulkanSparseFragmentShader(coverage: coverage, paint: paint);
          final Set<int> sets = _descriptorSetsDecorated(words);
          final Set<int> expected = <int>{
            if (coverage == kVulkanSparseModeAlpha) kVulkanSparseAlphaAtlasSet,
            if (paint == kVulkanSparsePaintGradient)
              kVulkanSparseGradientLutSet,
          };
          expect(sets, expected,
              reason: 'coverage $coverage, paint $paint declares the wrong '
                  'descriptor sets');
        }
      }
    });

    test('the push-constant members carry the offsets the driver writes', () {
      // The single most likely way for this port to be wrong and still draw:
      // a member decorated at the wrong byte offset reads the neighbouring
      // vec4, so a gradient picks up a transform row as its geometry and
      // produces a smooth, plausible, wrong ramp.
      final Uint32List fragment = buildVulkanSparseFragmentShader(
        coverage: kVulkanSparseModeAlpha,
        paint: kVulkanSparsePaintGradient,
      );
      expect(_memberOffsets(fragment), <int>[
        VulkanSparsePushConstant.color,
        VulkanSparsePushConstant.gradientKind,
        VulkanSparsePushConstant.gradientSpread,
        VulkanSparsePushConstant.gradientLookup,
        VulkanSparsePushConstant.targetToLocal0,
        VulkanSparsePushConstant.targetToLocal1,
        VulkanSparsePushConstant.gradientGeometry0,
        VulkanSparsePushConstant.gradientGeometry1,
      ]);
      expect(_memberOffsets(buildVulkanSparseVertexShader()),
          <int>[VulkanSparsePushConstant.viewport]);
    });

    test('the block fits what Vulkan guarantees, with the ranges disjoint', () {
      expect(kVulkanSparsePushConstantBytes,
          lessThanOrEqualTo(kVulkanMinPushConstantBytes));
      expect(kVulkanSparseVertexPushOffset + kVulkanSparseVertexPushBytes,
          lessThanOrEqualTo(kVulkanSparseFragmentPushOffset));
      for (final int offset in <int>[
        VulkanSparsePushConstant.color,
        VulkanSparsePushConstant.targetToLocal0,
        VulkanSparsePushConstant.targetToLocal1,
        VulkanSparsePushConstant.gradientGeometry0,
        VulkanSparsePushConstant.gradientGeometry1,
      ]) {
        expect(offset % 16, 0,
            reason: 'a vec4 in a Block must start on a 16-byte boundary');
      }
      expect(VulkanSparsePushConstant.gradientLookup % 8, 0);
      expect(kVulkanSparseFragmentPushOffset % 4, 0,
          reason: 'a VkPushConstantRange offset must be a multiple of 4');
    });

    test('a coverage or paint mode with no module throws by name', () {
      expect(
        () => buildVulkanSparseFragmentShader(coverage: 7, paint: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => buildVulkanSparseFragmentShader(coverage: 0, paint: 7),
        throwsA(isA<ArgumentError>()),
      );
      expect(() => fragmentIndex(coverage: 9, paint: 0),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('the submission encoder', () {
    test('encodes the same instances and commands as the OpenGL one', () {
      final SparseStripDrawPlan plan = _mixedPlan();
      final SparseVulkanSubmission vulkan = SparseVulkanSubmission()
        ..encode(plan);
      final SparseGlSubmission gl = SparseGlSubmission()..encode(plan);

      expect(vulkan.instanceCount, gl.instanceCount);
      expect(vulkan.commandCount, gl.commandCount);
      expect(vulkan.instances, gl.instances);
      expect(vulkan.commands, gl.commands);
      expect(kVulkanSparseInstanceFloatCount, kSparseGlInstanceFloatCount);
      expect(kVulkanSparseInstanceStrideBytes, kSparseGlInstanceStrideBytes);
      expect(kVulkanSparseCommandStride, kSparseGlCommandStride);
      expect(kVulkanSparseModeSolid, kSparseGlModeSolid);
      expect(kVulkanSparseModeAlpha, kSparseGlModeAlpha);
      expect(kVulkanSparsePaintSolid, kSparseGlPaintSolid);
      expect(kVulkanSparsePaintGradient, kSparseGlPaintGradient);
    });

    test('re-encoding retains the arenas', () {
      final SparseStripDrawPlan plan = _mixedPlan();
      final SparseVulkanSubmission submission = SparseVulkanSubmission(
        initialInstances: 1,
        initialCommands: 1,
      )..encode(plan);
      final int growths = submission.arenaGrowths;
      expect(growths, greaterThan(0));
      submission.encode(plan);
      expect(submission.arenaGrowths, growths,
          reason: 're-encoding the same plan must not reallocate');
    });

    test('a solid command names no page and an alpha command names one', () {
      final SparseVulkanSubmission submission = SparseVulkanSubmission()
        ..encode(_mixedPlan());
      expect(submission.commandMode(0), kVulkanSparseModeSolid);
      expect(submission.commandAtlasPage(0), -1);
      expect(submission.commandMode(1), kVulkanSparseModeAlpha);
      expect(submission.commandAtlasPage(1), 0);
      expect(submission.instanceAtlasX(0), 0);
      expect(submission.instanceAtlasY(0), 0);
    });
  });

  group('the executor', () {
    test('uploads pages and draws ordered command ranges', () {
      final _FakeSparseVulkanDriver driver = _FakeSparseVulkanDriver();
      final SparseVulkanExecutor executor = SparseVulkanExecutor(driver)
        ..initialize();
      final SparseStripDrawPlan plan = _mixedPlan();

      final SparseVulkanExecutionStats stats = executor.submit(
        plan,
        materials: <SparseVulkanMaterial>[
          SparseVulkanMaterial(
            red: 0.25,
            green: 0.125,
            blue: 0,
            alpha: 0.5,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 64,
        viewportHeight: 64,
      );

      expect(stats.drawCalls, 2);
      expect(stats.instances, greaterThan(0));
      expect(stats.alphaUploads, plan.alphaUploadCount);
      expect(executor.retainedAlphaPageCount, plan.alphaPageCount);
      // The order is the contract: every page is uploaded before the pass
      // opens, the pass is opened once, and it is closed once.
      expect(driver.log.first, 'createPipeline');
      expect(driver.log.where((String e) => e == 'beginPass'), hasLength(1));
      expect(driver.log.where((String e) => e == 'endPass'), hasLength(1));
      final int begin = driver.log.indexOf('beginPass');
      expect(
        driver.log.take(begin).where((String e) => e.startsWith('upload')),
        isNotEmpty,
      );
      expect(
        driver.log.skip(begin).where((String e) => e.startsWith('upload')),
        isEmpty,
      );
      expect(driver.log.skip(begin), contains('mode:0'));
      expect(driver.log.skip(begin), contains('mode:1'));
      expect(driver.log.skip(begin), contains('solidPaint'));
      expect(driver.log.last, 'endPass');
    });

    test('an empty plan opens no pass at all', () {
      final _FakeSparseVulkanDriver driver = _FakeSparseVulkanDriver();
      final SparseVulkanExecutor executor = SparseVulkanExecutor(driver)
        ..initialize();
      final SparseVulkanExecutionStats stats = executor.submit(
        SparseStripDrawPlan(),
        materials: const <SparseVulkanMaterial>[],
        viewportWidth: 8,
        viewportHeight: 8,
      );
      expect(stats.drawCalls, 0);
      expect(driver.log, isNot(contains('beginPass')));
    });

    test('a material index outside the list is refused before the pass', () {
      final _FakeSparseVulkanDriver driver = _FakeSparseVulkanDriver();
      final SparseVulkanExecutor executor = SparseVulkanExecutor(driver)
        ..initialize();
      expect(
        () => executor.submit(
          _mixedPlan(),
          materials: const <SparseVulkanMaterial>[],
          viewportWidth: 8,
          viewportHeight: 8,
        ),
        throwsA(isA<RangeError>()),
      );
      // The whole point of validating first: nothing was uploaded and no pass
      // was opened, so the caller can fall back to the dense atlas without
      // undoing anything.
      expect(driver.log, <String>['createPipeline']);
    });

    test('a gradient whose LUT belongs to nobody is refused', () {
      final _FakeSparseVulkanDriver driver = _FakeSparseVulkanDriver();
      final SparseVulkanExecutor executor = SparseVulkanExecutor(driver)
        ..initialize();
      final Gradient gradient = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 8,
        endY: 0,
        stops: <GradientStop>[
          const GradientStop(0, 0xFF000000),
          const GradientStop(1, 0xFFFFFFFF),
        ],
      );
      final GpuGradientCache cache =
          GpuGradientCache(allocator: _GradientAllocator());
      final GpuGradientBinding binding = cache.resolve(gradient);
      expect(
        () => executor.submit(
          _mixedPlan(),
          materials: <SparseVulkanMaterial>[
            SparseVulkanMaterial.gradient(
              gradientBinding: binding,
              gradientParameters: GpuGradientShaderParameters.fromPaint(
                ReplayPaint(
                  argbColor: 0xFFFFFFFF,
                  style: paintStyleFill,
                  strokeWidth: 0,
                  blendMode: blendModeSrcOver,
                  antiAlias: true,
                  gradient: gradient,
                ),
              ),
              blendMode: blendModeSrcOver,
            ),
          ],
          viewportWidth: 8,
          viewportHeight: 8,
        ),
        // The executor here was built with no allocator, so no binding can
        // belong to it. That is the device-loss case in miniature.
        throwsA(isA<StateError>()),
      );
      expect(driver.log, <String>['createPipeline']);
    });

    test('a colour brighter than its own alpha is refused', () {
      expect(
        () => SparseVulkanMaterial(
          red: 1,
          green: 0,
          blue: 0,
          alpha: 0.5,
          blendMode: blendModeSrcOver,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a blend mode with no pipeline is refused at the material', () {
      expect(
        () => SparseVulkanMaterial(
          red: 0,
          green: 0,
          blue: 0,
          alpha: 1,
          blendMode: 0x7FFF,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('discarding native resources forgets pages and permits a rebuild', () {
      final _FakeSparseVulkanDriver driver = _FakeSparseVulkanDriver();
      final SparseVulkanExecutor executor = SparseVulkanExecutor(driver)
        ..initialize();
      executor.submit(
        _mixedPlan(),
        materials: <SparseVulkanMaterial>[_white()],
        viewportWidth: 32,
        viewportHeight: 32,
      );
      expect(executor.retainedAlphaPageCount, greaterThan(0));

      executor.discardNativeResources();
      expect(executor.isInitialized, isFalse);
      expect(executor.retainedAlphaPageCount, 0);
      // Forgotten, not deleted: after a device loss the objects are gone and
      // destroying them is undefined rather than merely redundant.
      expect(driver.log, isNot(contains('deleteTexture')));
      expect(driver.log, contains('discard'));

      executor.initialize();
      expect(executor.isInitialized, isTrue);
      executor.submit(
        _mixedPlan(),
        materials: <SparseVulkanMaterial>[_white()],
        viewportWidth: 32,
        viewportHeight: 32,
      );
      expect(
          driver.log.where((String e) => e == 'createPipeline'), hasLength(2));
    });

    test('a disposed executor refuses everything by name', () {
      final SparseVulkanExecutor executor =
          SparseVulkanExecutor(_FakeSparseVulkanDriver())..initialize();
      executor.dispose();
      expect(executor.isDisposed, isTrue);
      expect(
        () => executor.submit(
          _mixedPlan(),
          materials: <SparseVulkanMaterial>[_white()],
          viewportWidth: 8,
          viewportHeight: 8,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('submitting before initialising is refused', () {
      final SparseVulkanExecutor executor =
          SparseVulkanExecutor(_FakeSparseVulkanDriver());
      expect(
        () => executor.submit(
          _mixedPlan(),
          materials: <SparseVulkanMaterial>[_white()],
          viewportWidth: 8,
          viewportHeight: 8,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a refused pipeline is a named failure and not a zero token', () {
      final SparseVulkanExecutor executor = SparseVulkanExecutor(
        _FakeSparseVulkanDriver(refusePipeline: true),
      );
      expect(executor.initialize, throwsA(isA<StateError>()));
    });
  });
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

/// A plan with one solid run and one boundary strip, so both command modes and
/// one alpha page are exercised.
SparseStripDrawPlan _mixedPlan() {
  final StripBuffer source = StripBuffer()..addFill(1, 2, 3);
  final int alpha = source.reserveAlphas(6 * kStripHeight);
  source.alphas.fillRange(alpha, alpha + 6 * kStripHeight, 127);
  source.addStrip(4, 2, 6, alpha);
  return SparseStripDrawPlan(atlasWidth: 8, atlasHeight: 8)
    ..append(source, materialIndex: 0);
}

SparseVulkanMaterial _white() => SparseVulkanMaterial(
      red: 1,
      green: 1,
      blue: 1,
      alpha: 1,
      blendMode: blendModeSrcOver,
    );

/// True when [needle] appears anywhere in [words].
bool _containsSequence(Uint32List words, List<int> needle) {
  for (var i = 0; i + needle.length <= words.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (words[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

/// The `DescriptorSet` decorations a module carries, decoded from the words.
Set<int> _descriptorSetsDecorated(Uint32List words) {
  const int opDecorate = 71;
  const int decorationDescriptorSet = 34;
  final Set<int> sets = <int>{};
  _forEachInstruction(words, (int opcode, List<int> operands) {
    if (opcode == opDecorate &&
        operands.length >= 3 &&
        operands[1] == decorationDescriptorSet) {
      sets.add(operands[2]);
    }
  });
  return sets;
}

/// The `Offset` member decorations, in member order.
List<int> _memberOffsets(Uint32List words) {
  const int opMemberDecorate = 72;
  const int decorationOffset = 35;
  final Map<int, int> byMember = <int, int>{};
  _forEachInstruction(words, (int opcode, List<int> operands) {
    if (opcode == opMemberDecorate &&
        operands.length >= 4 &&
        operands[2] == decorationOffset) {
      byMember[operands[1]] = operands[3];
    }
  });
  final List<int> members = byMember.keys.toList()..sort();
  return <int>[for (final int member in members) byMember[member]!];
}

void _forEachInstruction(
  Uint32List words,
  void Function(int opcode, List<int> operands) visit,
) {
  var offset = 5;
  while (offset < words.length) {
    final int wordCount = words[offset] >> 16;
    if (wordCount == 0) break;
    visit(words[offset] & 0xFFFF,
        <int>[for (var i = 1; i < wordCount; i++) words[offset + i]]);
    offset += wordCount;
  }
}

final class _FakeSparseVulkanDriver implements SparseVulkanDriver {
  _FakeSparseVulkanDriver({this.refusePipeline = false});

  final bool refusePipeline;
  final List<String> log = <String>[];
  int _nextTexture = 1;

  @override
  int createSparsePipeline() {
    log.add('createPipeline');
    return refusePipeline ? 0 : 42;
  }

  @override
  void disposeSparsePipeline(int pipeline) => log.add('disposePipeline');

  @override
  int createAlpha8Texture({required int width, required int height}) {
    log.add('createTexture:${width}x$height');
    return _nextTexture++;
  }

  @override
  void deleteTexture(int texture) => log.add('deleteTexture');

  @override
  void uploadInstances(Float32List instances) =>
      log.add('uploadInstances:${instances.length}');

  @override
  void uploadAlpha8Region(
    int texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int sourceOffset,
    required int sourceBytesPerRow,
  }) =>
      log.add('uploadPage:$texture:$x,$y,${width}x$height');

  @override
  void beginSparsePass({
    required int pipeline,
    required int viewportWidth,
    required int viewportHeight,
  }) =>
      log.add('beginPass');

  @override
  void setBlendState(GpuBlendState blend) =>
      log.add('blend:${blend.source.name}/${blend.destination.name}');

  @override
  void setPremultipliedColor(
          double red, double green, double blue, double alpha) =>
      log.add('color:$red,$green,$blue,$alpha');

  @override
  void useSolidPaint() => log.add('solidPaint');

  @override
  void useGradientPaint(
    GpuGradientBinding binding,
    GpuGradientShaderParameters parameters,
  ) =>
      log.add('gradientPaint');

  @override
  void setSparseMode(int mode) => log.add('mode:$mode');

  @override
  void bindAlpha8Texture(int texture) => log.add('bindPage:$texture');

  @override
  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
    required int firstInstance,
  }) =>
      log.add('draw:$vertexCount,$instanceCount,$firstInstance');

  @override
  void endSparsePass() => log.add('endPass');

  @override
  void discardNativeResources() => log.add('discard');
}

final class _GradientTexture implements GpuTextureHandle {
  _GradientTexture(this.id, this.width, this.height, this.format, this.filter);

  @override
  final int id;
  @override
  final int width;
  @override
  final int height;
  @override
  final GpuTextureFormat format;
  @override
  final GpuTextureFilter filter;
  bool valid = true;

  @override
  bool get isValid => valid;
}

/// The smallest allocator a [GpuGradientCache] will accept, so a binding can
/// exist without a device. It belongs to nobody the executor knows, which is
/// exactly what the refusal above is checking.
final class _GradientAllocator implements GpuTextureAllocator {
  int uploads = 0;

  @override
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.nearest,
  }) =>
      _GradientTexture(40, width, height, format, filter);

  @override
  void uploadRegion(
    GpuTextureHandle texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    uploads++;
  }

  @override
  void releaseTexture(GpuTextureHandle texture) {
    (texture as _GradientTexture).valid = false;
  }
}
