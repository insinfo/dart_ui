/// The sparse WebGPU executor against a recording driver, on the VM.
///
/// Everything worth asserting about this path is a property of the *sequence*
/// of driver calls: uploads before draws, materials validated before anything
/// is written, one draw per atlas-page run in submission order, a pipeline per
/// (coverage, paint, blend) triple, a uniform slice per material actually used,
/// and a pass that closes even when a draw throws. A fake driver sees all of
/// it, which is why `webgpu_sparse_executor.dart` speaks integers and typed
/// data rather than `GPUBuffer` and `GPUTextureView` - and why this file needs
/// no browser.
///
/// The sibling of `gl_sparse_executor_test.dart`, deliberately: where the two
/// backends make the same claim, they make it in the same shape.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/wgsl_sparse_shaders.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

void main() {
  test('uploads alpha pages and draws ordered command ranges', () {
    final StripBuffer source = StripBuffer()..addFill(1, 2, 3);
    final int alpha = source.reserveAlphas(6 * kStripHeight);
    source.alphas.fillRange(alpha, alpha + 6 * kStripHeight, 127);
    source.addStrip(4, 2, 6, alpha);
    // A four-texel-wide atlas splits the six-texel strip across two pages,
    // which is what makes this a page-run test and not just a draw test.
    final SparseStripDrawPlan plan = SparseStripDrawPlan(
      atlasWidth: 4,
      atlasHeight: 4,
    )..append(source, materialIndex: 0);
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(driver)
      ..initialize();

    final WebGpuSparseExecutionStats stats = executor.submit(
      plan,
      materials: <SparseWebGpuMaterial>[
        SparseWebGpuMaterial(
          red: 0.25,
          green: 0.125,
          blue: 0,
          alpha: 0.5,
          blendMode: blendModeSrcOver,
        ),
      ],
      viewportWidth: 100,
      viewportHeight: 80,
    );

    expect(stats.drawCalls, 3);
    expect(stats.instances, 3);
    expect(stats.alphaUploads, 2);
    expect(stats.alphaUploadBytes, 6 * kStripHeight);
    expect(stats.uniformSlices, 1);
    expect(driver.createdTextureSizes, <String>['4x4', '4x4']);
    expect(driver.uploads, <String>['0:0:4x4', '0:0:2x4']);
    // firstInstance rather than a rebased attribute pointer: WebGPU has a
    // base-instance draw and GL 3.3 does not, which is the one place the two
    // executors legitimately differ.
    expect(driver.draws, <String>['4x1@0', '4x1@1', '4x1@2']);
    expect(driver.pipelineRequests, <String>[
      '$kSparseGlModeSolid/$kSparseGlPaintSolid/$blendModeSrcOver',
      '$kSparseGlModeAlpha/$kSparseGlPaintSolid/$blendModeSrcOver',
      '$kSparseGlModeAlpha/$kSparseGlPaintSolid/$blendModeSrcOver',
    ]);
    // The solid interior binds no page - kNoTexture, which the production
    // driver answers with its stand-in - and the two strips bind one page
    // each. Handles 1 and 2 went to the instance and uniform buffers.
    expect(driver.bindGroupRequests, <String>['0/0', '3/0', '4/0']);
    expect(driver.uniformOffsets, <int>[0, 0, 0]);
    expect(driver.events.last, 'end');
  });

  test('every upload precedes the pass that reads it', () {
    final StripBuffer source = StripBuffer();
    final int alpha = source.reserveAlphas(2 * kStripHeight);
    source.alphas.fillRange(alpha, alpha + 2 * kStripHeight, 200);
    source.addStrip(0, 0, 2, alpha);
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    WebGpuSparseExecutor(driver)
      ..initialize()
      ..submit(
        SparseStripDrawPlan()..append(source, materialIndex: 0),
        materials: <SparseWebGpuMaterial>[
          SparseWebGpuMaterial(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 8,
        viewportHeight: 8,
      );

    final int begin = driver.events.indexWhere((String e) => e == 'begin');
    expect(begin, greaterThan(0));
    // WebGPU's queue orders writeBuffer and writeTexture against submit, but
    // only if they are issued first; an upload after the encoder was finished
    // would land in the *next* frame.
    for (final String event in <String>[
      'instances',
      'uniforms',
      'upload',
    ]) {
      expect(
        driver.events.indexWhere((String e) => e.startsWith(event)),
        lessThan(begin),
        reason: '$event must be enqueued before the render pass',
      );
    }
  });

  test('batch order is preserved across materials and pages', () {
    // Two paths, two materials. Grouping every solid run in the frame ahead of
    // every alpha run would change compositing order, which is the whole
    // reason batches exist in the plan.
    final StripBuffer first = StripBuffer()..addFill(0, 0, 2);
    final int alpha = first.reserveAlphas(kStripHeight);
    first.alphas.fillRange(alpha, alpha + kStripHeight, 64);
    first.addStrip(2, 0, 1, alpha);
    final StripBuffer second = StripBuffer()..addFill(4, 0, 2);
    final SparseStripDrawPlan plan = SparseStripDrawPlan()
      ..append(first, materialIndex: 0)
      ..append(second, materialIndex: 1);
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(driver)
      ..initialize();

    final WebGpuSparseExecutionStats stats = executor.submit(
      plan,
      materials: <SparseWebGpuMaterial>[
        SparseWebGpuMaterial(
          red: 1,
          green: 0,
          blue: 0,
          alpha: 1,
          blendMode: blendModeSrcOver,
        ),
        SparseWebGpuMaterial(
          red: 0,
          green: 0,
          blue: 1,
          alpha: 1,
          blendMode: blendModePlus,
        ),
      ],
      viewportWidth: 16,
      viewportHeight: 4,
    );

    expect(stats.drawCalls, 3);
    expect(stats.uniformSlices, 2);
    expect(driver.uniformOffsets, <int>[
      0,
      0,
      kWebGpuSparseUniformSliceStride,
    ]);
    expect(driver.pipelineRequests, <String>[
      '$kSparseGlModeSolid/$kSparseGlPaintSolid/$blendModeSrcOver',
      '$kSparseGlModeAlpha/$kSparseGlPaintSolid/$blendModeSrcOver',
      // The second path's blend mode bakes into its own pipeline, which is
      // what WebGPU makes of a blend change.
      '$kSparseGlModeSolid/$kSparseGlPaintSolid/$blendModePlus',
    ]);
  });

  test('an unused material costs no uniform slice', () {
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutionStats stats =
        (WebGpuSparseExecutor(driver)..initialize()).submit(
      SparseStripDrawPlan()
        ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 2),
      materials: <SparseWebGpuMaterial>[
        for (var i = 0; i < 4; i++)
          SparseWebGpuMaterial(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
      ],
      viewportWidth: 4,
      viewportHeight: 4,
    );
    expect(stats.uniformSlices, 1);
    expect(driver.uniformOffsets, <int>[2 * kWebGpuSparseUniformSliceStride]);
  });

  test('an empty plan draws nothing and opens no pass', () {
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutionStats stats =
        (WebGpuSparseExecutor(driver)..initialize()).submit(
      SparseStripDrawPlan(),
      materials: const <SparseWebGpuMaterial>[],
      viewportWidth: 4,
      viewportHeight: 4,
    );
    expect(stats.drawCalls, 0);
    expect(stats.instances, 0);
    expect(driver.events, isNot(contains('begin')));
  });

  test('a material index outside the list is refused before any write', () {
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(driver)
      ..initialize();
    driver.events.clear();

    expect(
      () => executor.submit(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 3),
        materials: <SparseWebGpuMaterial>[
          SparseWebGpuMaterial(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 4,
        viewportHeight: 4,
      ),
      throwsRangeError,
    );
    // Transactional: the caller falls back to the dense atlas with the target,
    // the queue and the submission order exactly as they were.
    expect(driver.events, isEmpty);
  });

  test('a blend mode with no GPU state is refused while building a material',
      () {
    // The first of two gates. The constructor refuses here, before a plan
    // exists; the executor asks `gpuBlendForMode` again before it opens a
    // pass, so a mode that somehow got past this one still cannot become a
    // pipeline inside an open encoder.
    expect(
      () => SparseWebGpuMaterial(
        red: 0,
        green: 0,
        blue: 0,
        alpha: 1,
        blendMode: 0xBEEF,
      ),
      throwsArgumentError,
    );
  });

  test('a colour brighter than its own alpha is refused', () {
    // Premultiplied end to end, like every other paint this renderer carries.
    expect(
      () => SparseWebGpuMaterial(
        red: 1,
        green: 0,
        blue: 0,
        alpha: 0.5,
        blendMode: blendModeSrcOver,
      ),
      throwsArgumentError,
    );
  });

  test('a failing draw still closes the pass', () {
    final _FakeSparseWebGpuDriver driver =
        _FakeSparseWebGpuDriver(failDraw: true);
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(driver)
      ..initialize();

    expect(
      () => executor.submit(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0),
        materials: <SparseWebGpuMaterial>[
          SparseWebGpuMaterial(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 4,
        viewportHeight: 4,
      ),
      throwsStateError,
    );
    // A render pass encoder left open makes every later call on the same
    // command encoder a validation error, so the caller could not even fall
    // back this frame.
    expect(driver.events.last, 'end');
  });

  test('device loss forgets handles without destroying them', () {
    final SparseStripDrawPlan plan = SparseStripDrawPlan()
      ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0);
    final List<SparseWebGpuMaterial> materials = <SparseWebGpuMaterial>[
      SparseWebGpuMaterial(
        red: 1,
        green: 1,
        blue: 1,
        alpha: 1,
        blendMode: blendModeSrcOver,
      ),
    ];
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(driver)
      ..initialize()
      ..submit(
        plan,
        materials: materials,
        viewportWidth: 4,
        viewportHeight: 4,
      );

    executor.discardNativeResources();
    expect(executor.isInitialized, isFalse);
    expect(executor.retainedAlphaPageCount, 0);
    expect(driver.events, contains('discard'));
    expect(driver.deletedBuffers, isEmpty);
    expect(driver.deletedTextures, isEmpty);

    executor
      ..initialize()
      ..submit(
        plan,
        materials: materials,
        viewportWidth: 4,
        viewportHeight: 4,
      );
    expect(driver.moduleCreates, 2);
    expect(driver.bufferCreates, 4,
        reason: 'one instance and one uniform '
            'buffer per initialisation');

    executor.dispose();
    expect(driver.deletedBuffers.length, 2);
    expect(driver.events, contains('destroyModule'));
  });

  test('a plan with a new atlas size drops the retained pages', () {
    final StripBuffer source = StripBuffer();
    final int alpha = source.reserveAlphas(kStripHeight);
    source.addStrip(0, 0, 1, alpha);
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(driver)
      ..initialize()
      ..submit(
        SparseStripDrawPlan(atlasWidth: 8, atlasHeight: 4)
          ..append(source, materialIndex: 0),
        materials: <SparseWebGpuMaterial>[
          SparseWebGpuMaterial(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 8,
        viewportHeight: 8,
      );
    expect(executor.retainedAlphaPageCount, 1);

    executor.submit(
      SparseStripDrawPlan(atlasWidth: 16, atlasHeight: 4)
        ..append(source, materialIndex: 0),
      materials: <SparseWebGpuMaterial>[
        SparseWebGpuMaterial(
          red: 1,
          green: 1,
          blue: 1,
          alpha: 1,
          blendMode: blendModeSrcOver,
        ),
      ],
      viewportWidth: 8,
      viewportHeight: 8,
    );
    expect(driver.deletedTextures.length, 1);
    expect(driver.createdTextureSizes, <String>['8x4', '16x4']);
  });

  test('a gradient material becomes a gradient pipeline and its LUT group', () {
    final LinearGradient gradient = LinearGradient(
      startX: 0,
      startY: 0,
      endX: 8,
      endY: 0,
      stops: const <GradientStop>[
        GradientStop(0, 0x80FF0000),
        GradientStop(1, 0xFF0000FF),
      ],
      spread: GradientSpread.reflect,
    );
    final _GradientAllocator allocator = _GradientAllocator();
    final GpuGradientBinding binding =
        GpuGradientCache(allocator: allocator, lutSize: 8).resolve(gradient);
    final GpuGradientShaderParameters parameters =
        GpuGradientShaderParameters.fromPaint(ReplayPaint(
      argbColor: 0,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: true,
      gradient: gradient,
      shaderTransform: const Transform2D.translation(2, 3),
    ));
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();

    WebGpuSparseExecutor(driver, textureAllocator: allocator)
      ..initialize()
      ..submit(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 4), materialIndex: 0)
          ..append(StripBuffer()..addFill(4, 0, 4), materialIndex: 1),
        materials: <SparseWebGpuMaterial>[
          SparseWebGpuMaterial.gradient(
            gradientBinding: binding,
            gradientParameters: parameters,
            blendMode: blendModeSrcOver,
          ),
          SparseWebGpuMaterial(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 8,
        viewportHeight: 4,
      );

    expect(allocator.uploads, 1);
    expect(driver.pipelineRequests, <String>[
      '$kSparseGlModeSolid/$kSparseGlPaintGradient/$blendModeSrcOver',
      '$kSparseGlModeSolid/$kSparseGlPaintSolid/$blendModeSrcOver',
    ]);
    // The gradient's group names its LUT; the solid material's names none.
    expect(driver.bindGroupRequests, <String>['0/40', '0/0']);
    // The slice the gradient draw binds carries the LUT lookup the shader
    // multiplies its parameter by.
    final ByteData slice = ByteData.sublistView(driver.uniformBytes!);
    expect(
      slice.getFloat32(WebGpuSparseUniformOffset.gradientLookup, Endian.little),
      closeTo(binding.lookupScale, 1e-6),
    );
    expect(
      slice.getInt32(WebGpuSparseUniformOffset.gradientSpread, Endian.little),
      GradientSpread.reflect.index,
    );
  });

  test('an invalidated gradient LUT is refused before any write', () {
    final LinearGradient gradient = LinearGradient(
      startX: 0,
      startY: 0,
      endX: 1,
      endY: 0,
      stops: const <GradientStop>[
        GradientStop(0, 0xFF000000),
        GradientStop(1, 0xFFFFFFFF),
      ],
    );
    final _GradientAllocator allocator = _GradientAllocator();
    final GpuGradientBinding binding =
        GpuGradientCache(allocator: allocator).resolve(gradient);
    (binding.texture as _GradientTexture).valid = false;
    final GpuGradientShaderParameters parameters =
        GpuGradientShaderParameters.fromPaint(ReplayPaint(
      argbColor: 0,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: true,
      gradient: gradient,
    ));
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(
      driver,
      textureAllocator: allocator,
    )..initialize();
    driver.events.clear();

    expect(
      () => executor.submit(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0),
        materials: <SparseWebGpuMaterial>[
          SparseWebGpuMaterial.gradient(
            gradientBinding: binding,
            gradientParameters: parameters,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 4,
        viewportHeight: 4,
      ),
      throwsStateError,
    );
    expect(driver.events, isEmpty);
  });

  test('a LUT from another device is refused before any write', () {
    final LinearGradient gradient = LinearGradient(
      startX: 0,
      startY: 0,
      endX: 1,
      endY: 0,
      stops: const <GradientStop>[
        GradientStop(0, 0xFF000000),
        GradientStop(1, 0xFFFFFFFF),
      ],
    );
    final _GradientAllocator owner = _GradientAllocator();
    final _GradientAllocator otherDevice = _GradientAllocator();
    final GpuGradientBinding binding =
        GpuGradientCache(allocator: owner).resolve(gradient);
    final GpuGradientShaderParameters parameters =
        GpuGradientShaderParameters.fromPaint(ReplayPaint(
      argbColor: 0,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: true,
      gradient: gradient,
    ));
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(
      driver,
      textureAllocator: otherDevice,
    )..initialize();
    driver.events.clear();

    expect(
      () => executor.submit(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0),
        materials: <SparseWebGpuMaterial>[
          SparseWebGpuMaterial.gradient(
            gradientBinding: binding,
            gradientParameters: parameters,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 4,
        viewportHeight: 4,
      ),
      throwsStateError,
    );
    expect(driver.events, isEmpty);
  });

  test('submitting before initialize is a refusal, not a silent no-op', () {
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    expect(
      () => WebGpuSparseExecutor(driver).submit(
        SparseStripDrawPlan(),
        materials: const <SparseWebGpuMaterial>[],
        viewportWidth: 4,
        viewportHeight: 4,
      ),
      throwsStateError,
    );
  });

  test('a non-positive viewport is refused', () {
    final _FakeSparseWebGpuDriver driver = _FakeSparseWebGpuDriver();
    final WebGpuSparseExecutor executor = WebGpuSparseExecutor(driver)
      ..initialize();
    expect(
      () => executor.submit(
        SparseStripDrawPlan(),
        materials: const <SparseWebGpuMaterial>[],
        viewportWidth: 0,
        viewportHeight: 4,
      ),
      throwsArgumentError,
    );
  });
}

final class _FakeSparseWebGpuDriver implements SparseWebGpuDriver {
  _FakeSparseWebGpuDriver({this.failDraw = false});

  final bool failDraw;
  final List<String> events = <String>[];
  final List<String> createdTextureSizes = <String>[];
  final List<String> uploads = <String>[];
  final List<String> draws = <String>[];
  final List<String> pipelineRequests = <String>[];
  final List<String> bindGroupRequests = <String>[];
  final List<int> uniformOffsets = <int>[];
  final List<int> deletedBuffers = <int>[];
  final List<int> deletedTextures = <int>[];
  int moduleCreates = 0;
  int bufferCreates = 0;
  Float32List? instanceBytes;
  Uint8List? uniformBytes;

  int _nextHandle = 1;

  @override
  void createSparseModule(String source) {
    expect(source, isNotEmpty);
    moduleCreates++;
    events.add('module');
  }

  @override
  void destroySparseModule() => events.add('destroyModule');

  @override
  int createInstanceBuffer(int byteCapacity) {
    expect(byteCapacity, greaterThan(0));
    bufferCreates++;
    events.add('instanceBuffer:$byteCapacity');
    return _nextHandle++;
  }

  @override
  int createUniformBuffer(int sliceCount) {
    expect(sliceCount, greaterThan(0));
    bufferCreates++;
    events.add('uniformBuffer:$sliceCount');
    return _nextHandle++;
  }

  @override
  void deleteBuffer(int buffer) {
    deletedBuffers.add(buffer);
    events.add('deleteBuffer:$buffer');
  }

  @override
  void writeInstances(int buffer, Float32List instances) {
    instanceBytes = Float32List.fromList(instances);
    events.add('instances:${instances.length}');
  }

  @override
  void writeUniformSlices(int buffer, Uint8List slices, int sliceCount) {
    uniformBytes = Uint8List.fromList(slices);
    events.add('uniforms:$sliceCount');
  }

  @override
  int createAlpha8Texture({required int width, required int height}) {
    createdTextureSizes.add('${width}x$height');
    events.add('texture:${width}x$height');
    return _nextHandle++;
  }

  @override
  void deleteTexture(int texture) {
    deletedTextures.add(texture);
    events.add('deleteTexture:$texture');
  }

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
  }) {
    uploads.add('$x:$y:${width}x$height');
    events.add('upload:$texture');
  }

  @override
  int acquirePipeline({
    required int coverageMode,
    required int paintMode,
    required int blendMode,
  }) {
    pipelineRequests.add('$coverageMode/$paintMode/$blendMode');
    // The same key shape the production driver uses, so a repeated triple
    // repeats a handle here too.
    return (coverageMode << 12) | (paintMode << 8) | blendMode;
  }

  @override
  int acquireBindGroup({
    required int alphaTexture,
    required int gradientLut,
  }) {
    bindGroupRequests.add('$alphaTexture/$gradientLut');
    return alphaTexture * 0x100000 + gradientLut;
  }

  @override
  void beginSparsePass({
    required int instanceBuffer,
    required int uniformBuffer,
    required int viewportWidth,
    required int viewportHeight,
  }) =>
      events.add('begin');

  @override
  void setPipeline(int pipeline) => events.add('pipeline:$pipeline');

  @override
  void setDrawState({
    required int bindGroup,
    required int uniformSliceOffsetBytes,
  }) {
    uniformOffsets.add(uniformSliceOffsetBytes);
    events.add('state:$bindGroup');
  }

  @override
  void draw({
    required int vertexCount,
    required int instanceCount,
    required int firstInstance,
  }) {
    if (failDraw) throw StateError('injected draw failure');
    draws.add('${vertexCount}x$instanceCount@$firstInstance');
    events.add('draw');
  }

  @override
  void endSparsePass() => events.add('end');

  @override
  void discardNativeResources() => events.add('discard');
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

final class _GradientAllocator implements GpuTextureAllocator {
  /// The one id every LUT this allocator hands out carries, so a test can
  /// name it in an expectation without reaching into the binding.
  final int textureId = 40;
  int uploads = 0;

  @override
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.nearest,
  }) =>
      _GradientTexture(textureId, width, height, format, filter);

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
