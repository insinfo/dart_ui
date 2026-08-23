import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

void main() {
  test('instancing bindings are optional for the established GL probe', () {
    expect(kSparseGlRequiredSymbols, <String>[
      'glVertexAttribDivisor',
      'glUniform4f',
      'glDrawArraysInstanced',
    ]);
    expect(
      missingSparseGlSymbols(
        (String name) =>
            name == 'glUniform4f' ? nullptr : Pointer<Void>.fromAddress(1),
      ),
      <String>['glUniform4f'],
    );
    for (final String symbol in kSparseGlRequiredSymbols) {
      expect(kRequiredGlSymbols, isNot(contains(symbol)));
    }
  });

  test('executor uploads alpha pages and draws ordered command ranges', () {
    final StripBuffer source = StripBuffer()..addFill(1, 2, 3);
    final int alpha = source.reserveAlphas(6 * kStripHeight);
    source.alphas.fillRange(alpha, alpha + 6 * kStripHeight, 127);
    source.addStrip(4, 2, 6, alpha);
    final SparseStripDrawPlan plan = SparseStripDrawPlan(
      atlasWidth: 4,
      atlasHeight: 4,
    )..append(source, materialIndex: 0);
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);

    final SparseGlExecutionStats stats = executor.submit(
      plan,
      materials: <SparseGlMaterial>[
        SparseGlMaterial(
          red: 0.25,
          green: 0.125,
          blue: 0,
          alpha: 0.5,
          blendMode: blendModeSrcOver,
        ),
      ],
      viewportWidth: 100,
      viewportHeight: 80,
      yFlip: 0,
    );

    expect(stats.drawCalls, 3);
    expect(stats.instances, 3);
    expect(stats.alphaUploads, 2);
    expect(stats.alphaUploadBytes, 6 * kStripHeight);
    expect(driver.createdTextureSizes, <String>['4x4', '4x4']);
    expect(driver.uploadOffsets, <String>['10:0:0:4x4:0/4', '11:0:0:2x4:0/4']);
    expect(driver.draws, <String>['4x1', '4x1', '4x1']);
    expect(driver.modes, <int>[
      kSparseGlModeSolid,
      kSparseGlModeAlpha,
      kSparseGlModeAlpha,
    ]);
    expect(driver.boundTextures, <int>[10, 11]);
    expect(
      driver.attributeOffsets,
      <String>['0:0', '1:16', '0:24', '1:40', '0:48', '1:64'],
    );
    expect(driver.events.first, 'createProgram');
    expect(driver.events, contains('begin:100x80:0'));
    expect(driver.events.last, 'end');
  });

  test('lifecycle is idempotent and retains high-water atlas pages', () {
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: false)
      ..initialize(desktop: false);
    final StripBuffer source = StripBuffer();
    final int alpha = source.reserveAlphas(5 * kStripHeight);
    source.addStrip(0, 0, 5, alpha);
    final SparseStripDrawPlan plan = SparseStripDrawPlan(
      atlasWidth: 4,
      atlasHeight: 4,
    )..append(source, materialIndex: 0);
    final List<SparseGlMaterial> materials = <SparseGlMaterial>[
      SparseGlMaterial(
        red: 1,
        green: 1,
        blue: 1,
        alpha: 1,
        blendMode: blendModeSrc,
      ),
    ];

    executor.submit(
      plan,
      materials: materials,
      viewportWidth: 8,
      viewportHeight: 8,
      yFlip: 1,
    );
    executor.submit(
      plan,
      materials: materials,
      viewportWidth: 8,
      viewportHeight: 8,
      yFlip: 1,
    );

    expect(driver.programCreates, 1);
    expect(driver.bufferCreates, 1);
    expect(driver.textureCreates, 2);
    expect(executor.retainedAlphaPageCount, 2);
    executor
      ..dispose()
      ..dispose();
    expect(driver.deletedPrograms, <int>[7]);
    expect(driver.deletedBuffers, <int>[9]);
    expect(driver.deletedTextures, <int>[10, 11]);
    expect(
        () => executor.submit(
              plan,
              materials: materials,
              viewportWidth: 8,
              viewportHeight: 8,
              yFlip: 0,
            ),
        throwsStateError);
  });

  test('invalid material is rejected before a pass starts', () {
    final SparseStripDrawPlan plan = SparseStripDrawPlan()
      ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 4);
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);

    expect(
      () => executor.submit(
        plan,
        materials: <SparseGlMaterial>[],
        viewportWidth: 1,
        viewportHeight: 1,
        yFlip: 0,
      ),
      throwsRangeError,
    );
    expect(driver.events, isNot(contains(startsWith('begin:'))));
  });

  test('invalid orientation is rejected before uploads or a pass', () {
    final SparseStripDrawPlan plan = SparseStripDrawPlan()
      ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0);
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);

    expect(
      () => executor.submit(
        plan,
        materials: <SparseGlMaterial>[],
        viewportWidth: 1,
        viewportHeight: 1,
        yFlip: 2,
      ),
      throwsArgumentError,
    );
    expect(driver.events, isNot(contains(startsWith('begin:'))));
  });

  test('a failed draw still closes the sparse pass', () {
    final SparseStripDrawPlan plan = SparseStripDrawPlan()
      ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0);
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver(failDraw: true);
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);

    expect(
      () => executor.submit(
        plan,
        materials: <SparseGlMaterial>[
          SparseGlMaterial(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 4,
        viewportHeight: 4,
        yFlip: 0,
      ),
      throwsStateError,
    );
    expect(driver.events, contains('end'));
    expect(driver.events.last, 'end');
  });

  test('device loss discards names without deleting and rebuilds lazily', () {
    final StripBuffer source = StripBuffer();
    final int alpha = source.reserveAlphas(kStripHeight);
    source.addStrip(0, 0, 1, alpha);
    final SparseStripDrawPlan plan = SparseStripDrawPlan()
      ..append(source, materialIndex: 0);
    final List<SparseGlMaterial> materials = <SparseGlMaterial>[
      SparseGlMaterial(
        red: 1,
        green: 1,
        blue: 1,
        alpha: 1,
        blendMode: blendModeSrcOver,
      ),
    ];
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);
    executor.submit(
      plan,
      materials: materials,
      viewportWidth: 4,
      viewportHeight: 4,
      yFlip: 0,
    );

    executor.discardNativeResources();

    expect(executor.isInitialized, isFalse);
    expect(executor.retainedAlphaPageCount, 0);
    expect(driver.events, contains('discard'));
    expect(driver.deletedPrograms, isEmpty);
    expect(driver.deletedBuffers, isEmpty);
    expect(driver.deletedTextures, isEmpty);

    executor.initialize(desktop: true);
    executor.submit(
      plan,
      materials: materials,
      viewportWidth: 4,
      viewportHeight: 4,
      yFlip: 0,
    );
    expect(driver.programCreates, 2);
    expect(driver.bufferCreates, 2);
    expect(driver.textureCreates, 2);

    executor.dispose();
    expect(driver.deletedPrograms, <int>[7]);
    expect(driver.deletedBuffers, <int>[9]);
    expect(driver.deletedTextures, <int>[11]);
  });

  test('gradient materials reuse canonical cache bindings and parameters', () {
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
    final GpuGradientCache cache = GpuGradientCache(
      allocator: allocator,
      lutSize: 8,
    );
    final GpuGradientBinding binding = cache.resolve(gradient);
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
    final SparseStripDrawPlan plan = SparseStripDrawPlan()
      ..append(StripBuffer()..addFill(0, 0, 4), materialIndex: 0)
      ..append(StripBuffer()..addFill(4, 0, 4), materialIndex: 1);
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);

    executor.submit(
      plan,
      materials: <SparseGlMaterial>[
        SparseGlMaterial.gradient(
          gradientBinding: binding,
          gradientParameters: parameters,
          blendMode: blendModeSrcOver,
        ),
        SparseGlMaterial(
          red: 1,
          green: 1,
          blue: 1,
          alpha: 1,
          blendMode: blendModeSrcOver,
        ),
      ],
      viewportWidth: 8,
      viewportHeight: 4,
      yFlip: 0,
    );

    expect(allocator.uploads, 1);
    expect(driver.gradientBindings, <GpuGradientBinding>[binding]);
    expect(
        driver.gradientParameters, <GpuGradientShaderParameters>[parameters]);
    expect(driver.paintEvents, <String>['gradient:40', 'solid']);
  });

  test('invalidated gradient LUT is rejected before opening a pass', () {
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
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);

    expect(
      () => executor.submit(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0),
        materials: <SparseGlMaterial>[
          SparseGlMaterial.gradient(
            gradientBinding: binding,
            gradientParameters: parameters,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 1,
        viewportHeight: 1,
        yFlip: 0,
      ),
      throwsStateError,
    );
    expect(driver.events, isNot(contains(startsWith('begin:'))));
  });

  test('forged zero-name gradient LUT is rejected before opening a pass', () {
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
    final GpuGradientBinding binding = GpuGradientBinding(
      gradient: gradient,
      texture: _GradientTexture(
        kNoTexture,
        8,
        1,
        GpuTextureFormat.rgba8888Straight,
        GpuTextureFilter.linear,
      ),
      lutSize: 8,
    );
    final GpuGradientShaderParameters parameters =
        GpuGradientShaderParameters.fromPaint(ReplayPaint(
      argbColor: 0,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: true,
      gradient: gradient,
    ));
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);

    expect(
      () => executor.submit(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0),
        materials: <SparseGlMaterial>[
          SparseGlMaterial.gradient(
            gradientBinding: binding,
            gradientParameters: parameters,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 1,
        viewportHeight: 1,
        yFlip: 0,
      ),
      throwsStateError,
    );
    expect(driver.events, isNot(contains(startsWith('begin:'))));
  });

  test('mismatched gradient LUT and geometry are rejected before the pass', () {
    final LinearGradient lutGradient = LinearGradient(
      startX: 0,
      startY: 0,
      endX: 1,
      endY: 0,
      stops: const <GradientStop>[
        GradientStop(0, 0xFF000000),
        GradientStop(1, 0xFFFFFFFF),
      ],
    );
    final LinearGradient parameterGradient = LinearGradient(
      startX: 0,
      startY: 0,
      endX: 8,
      endY: 0,
      stops: const <GradientStop>[
        GradientStop(0, 0xFFFF0000),
        GradientStop(1, 0xFF0000FF),
      ],
    );
    final GpuGradientBinding binding =
        GpuGradientCache(allocator: _GradientAllocator()).resolve(lutGradient);
    final GpuGradientShaderParameters parameters =
        GpuGradientShaderParameters.fromPaint(ReplayPaint(
      argbColor: 0,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: true,
      gradient: parameterGradient,
    ));
    final _FakeSparseGlDriver driver = _FakeSparseGlDriver();
    final SparseGlExecutor executor = SparseGlExecutor(driver)
      ..initialize(desktop: true);

    expect(
      () => executor.submit(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0),
        materials: <SparseGlMaterial>[
          SparseGlMaterial.gradient(
            gradientBinding: binding,
            gradientParameters: parameters,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 1,
        viewportHeight: 1,
        yFlip: 0,
      ),
      throwsArgumentError,
    );
    expect(driver.events, isNot(contains(startsWith('begin:'))));
  });
}

final class _FakeSparseGlDriver implements SparseGlDriver {
  _FakeSparseGlDriver({this.failDraw = false});

  final bool failDraw;
  final List<String> events = <String>[];
  final List<String> createdTextureSizes = <String>[];
  final List<String> uploadOffsets = <String>[];
  final List<String> draws = <String>[];
  final List<int> modes = <int>[];
  final List<int> boundTextures = <int>[];
  final List<String> attributeOffsets = <String>[];
  final List<int> deletedPrograms = <int>[];
  final List<int> deletedBuffers = <int>[];
  final List<int> deletedTextures = <int>[];
  final List<String> paintEvents = <String>[];
  final List<GpuGradientBinding> gradientBindings = <GpuGradientBinding>[];
  final List<GpuGradientShaderParameters> gradientParameters =
      <GpuGradientShaderParameters>[];
  int programCreates = 0;
  int bufferCreates = 0;
  int textureCreates = 0;

  @override
  int createSparseProgram({
    required String vertexSource,
    required String fragmentSource,
  }) {
    programCreates++;
    events.add('createProgram');
    expect(vertexSource, contains('gl_VertexID'));
    expect(fragmentSource, contains('texelFetch'));
    return 7;
  }

  @override
  int createInstanceBuffer() {
    bufferCreates++;
    events.add('createBuffer');
    return 9;
  }

  @override
  int createAlpha8Texture({required int width, required int height}) {
    createdTextureSizes.add('${width}x$height');
    return 10 + textureCreates++;
  }

  @override
  void uploadInstances(int buffer, Float32List instances) {
    events.add('uploadInstances:$buffer:${instances.length}');
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
    expect(pixels.length, greaterThan(sourceOffset));
    uploadOffsets.add(
      '$texture:$x:$y:${width}x$height:$sourceOffset/$sourceBytesPerRow',
    );
  }

  @override
  void beginSparsePass({
    required int program,
    required int instanceBuffer,
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) {
    events.add('begin:${viewportWidth}x$viewportHeight:$yFlip');
  }

  @override
  void setBlendState(GpuBlendState blend) {}

  @override
  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  ) {}

  @override
  void useSolidPaint() => paintEvents.add('solid');

  @override
  void useGradientPaint(
    GpuGradientBinding binding,
    GpuGradientShaderParameters parameters,
  ) {
    gradientBindings.add(binding);
    gradientParameters.add(parameters);
    paintEvents.add('gradient:${binding.texture.id}');
  }

  @override
  void setSparseMode(int mode) => modes.add(mode);

  @override
  void bindAlpha8Texture(int texture) => boundTextures.add(texture);

  @override
  void setInstanceAttribute({
    required int location,
    required int components,
    required int strideBytes,
    required int offsetBytes,
    required int divisor,
  }) {
    expect(strideBytes, kSparseGlInstanceStrideBytes);
    expect(divisor, 1);
    attributeOffsets.add('$location:$offsetBytes');
  }

  @override
  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
  }) {
    if (failDraw) throw StateError('injected draw failure');
    draws.add('${vertexCount}x$instanceCount');
  }

  @override
  void endSparsePass() => events.add('end');

  @override
  void discardNativeResources() => events.add('discard');

  @override
  void deleteProgram(int program) => deletedPrograms.add(program);

  @override
  void deleteBuffer(int buffer) => deletedBuffers.add(buffer);

  @override
  void deleteTexture(int texture) => deletedTextures.add(texture);
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
