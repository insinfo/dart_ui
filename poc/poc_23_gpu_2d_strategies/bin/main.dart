import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_framebuffer_pool.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_stencil_cover_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_atlas.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/vector/cpu_tessellation.dart';
import 'package:dart_ui/src/rendering/gpu/vector/stencil_cover_draw_plan.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';

const int _width = 1024;
const int _height = 1024;
const int _pathCount = 128;
const int _gpuDrawCount = 1024;
const Rect _clip = Rect.fromLTRB(0, 0, 1024, 1024);

const StencilCoverCapabilities _portableStencil = StencilCoverCapabilities(
  stencilBits: 8,
  sampleCount: 1,
  separateFrontBackOperations: true,
  wrapOperations: true,
  invertOperation: true,
  scissoredClear: true,
);

Future<void> main(List<String> args) async {
  final int samples = _integerArgument(args, '--samples=', fallback: 7);
  final int gpuFrames = _integerArgument(args, '--gpu-frames=', fallback: 120);
  final bool quick = args.contains('--quick');

  print('POC-23 - Intel UHD: APIs and 2D strategies A/B/C/D');
  print(
      'Dart ${Platform.version.split(' ').first} | ${Platform.operatingSystem}');
  print('Every number is a median. Smaller is better.');
  print('');

  if (Platform.isWindows) _printWindowsGpuIdentity();
  await _printVulkanIdentity();
  if (Platform.isWindows) {
    _probeD3d11();
    _probeD3d12();
  }

  final List<Path> paths = _workloadPaths(_pathCount);
  print('CPU preparation (${paths.length} curved paths)');
  print(_rule());
  final List<_Measurement> cpu = <_Measurement>[
    _measureAtlasCold(paths, samples),
    _measureAtlasWarm(paths, samples, quick ? 8 : 64),
    _measureTessellationCold(paths, samples),
    _measureTessellationWarm(paths, samples, quick ? 8 : 64),
    _measureStencilPlanning(paths, samples),
  ];
  _printMeasurements(cpu);
  print('');

  if (!Platform.isWindows && !Platform.isLinux) {
    print('The live GL section supports WGL on Windows and EGL on Linux.');
    return;
  }

  final _GlSession session = _GlSession.open();
  if (session.failure != null) {
    print('OpenGL GPU benchmark skipped: ${session.failure}');
    return;
  }
  try {
    final GlRenderDevice device = session.device!;
    print('OpenGL runtime');
    print(_rule());
    print('vendor   : ${device.api.stringOf(glVendor)}');
    print('renderer : ${device.api.stringOf(glRenderer)}');
    print('version  : ${device.api.stringOf(glVersion)}');
    print('');

    final List<_Measurement> gpu = <_Measurement>[];
    gpu.add(_benchmarkAnalyticQuads(
      device,
      samples: samples,
      frames: quick ? 20 : gpuFrames,
    ));
    gpu.add(_benchmarkTessellatedGpu(
      device,
      session.context!,
      session.glLibrary!,
      paths,
      samples: samples,
      frames: quick ? 20 : gpuFrames,
    ));
    final _Measurement? stencil = _benchmarkStencilGpu(
      device,
      paths,
      samples: samples,
      frames: quick ? 10 : math.max(20, gpuFrames ~/ 4),
    );
    if (stencil != null) gpu.add(stencil);

    final _ComputeResult compute = _benchmarkCompute(
      device,
      session.context!,
      session.glLibrary!,
      samples: samples,
      frames: quick ? 20 : gpuFrames,
    );
    if (compute.measurement != null) gpu.add(compute.measurement!);

    print(
        'Live GPU work (same 1024 x 1024 target, synchronized with glFinish)');
    print(_rule());
    _printMeasurements(gpu);
    if (compute.detail != null) print('D capability: ${compute.detail}');
    print('');
    print('Interpretation');
    print(_rule());
    print('A: production GL executor measured; $_gpuDrawCount analytic quads, '
        'one batch/draw.');
    print('B: CPU tessellation/cache plus a POC-local retained indexed-mesh '
        'GL executor measured; production integration is still TODO.');
    print('C: production experimental stencil executor measured; one clear + '
        'accumulate + cover sequence per path.');
    print('D: the number is only an RGBA8 compute-fill microkernel. It proves '
        'compute execution, not Vello-equivalent path rasterization.');
  } finally {
    session.close();
  }
}

void _printWindowsGpuIdentity() {
  final ProcessResult result = Process.runSync(
    'powershell',
    <String>[
      '-NoProfile',
      '-Command',
      r'''Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name)|$($_.PNPDeviceID)|$($_.DriverVersion)" }''',
    ],
    stdoutEncoding: const SystemEncoding(),
  );
  final String value = '${result.stdout}'.trim();
  if (result.exitCode != 0 || value.isEmpty) return;
  print('Windows display adapters');
  print(_rule());
  for (final String line in value.split(RegExp(r'[\r\n]+'))) {
    final List<String> fields = line.split('|');
    print('adapter  : ${fields.first}');
    if (fields.length > 1) {
      print('PCI id   : ${_pciId(fields[1])}');
    }
    if (fields.length > 2) {
      print('driver   : ${fields[2]}');
    }
  }
  print('');
}

String _pciId(String pnp) {
  final RegExpMatch? match = RegExp(
    r'VEN_([0-9A-F]{4}).*DEV_([0-9A-F]{4})',
    caseSensitive: false,
  ).firstMatch(pnp);
  return match == null ? pnp : '${match.group(1)}:${match.group(2)}';
}

Future<void> _printVulkanIdentity() async {
  try {
    final ProcessResult result = await Process.run(
      'vulkaninfo',
      const <String>['--summary'],
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );
    if (result.exitCode != 0) return;
    final String text = '${result.stdout}';
    final List<String> devices = <String>[];
    String? name;
    String? api;
    String? type;
    for (final String raw in text.split(RegExp(r'[\r\n]+'))) {
      final String line = raw.trim();
      if (line.startsWith('deviceName')) name = _right(line);
      if (line.startsWith('apiVersion')) api = _right(line);
      if (line.startsWith('deviceType')) type = _right(line);
      if (name != null && api != null && type != null) {
        devices.add('$name | Vulkan $api | $type');
        name = api = type = null;
      }
    }
    print('Vulkan runtime');
    print(_rule());
    if (devices.isEmpty) {
      print('vulkaninfo ran, but no physical device was parsed.');
    } else {
      for (final String device in devices) {
        print(device);
      }
    }
    print('');
  } on ProcessException {
    print('Vulkan runtime: vulkaninfo not installed; probe skipped.');
    print('');
  }
}

String _right(String line) {
  final int equals = line.indexOf('=');
  return equals < 0 ? line : line.substring(equals + 1).trim();
}

void _probeD3d12() {
  final D3d12DeviceAttempt attempt = D3d12RenderDevice.open();
  final D3d12RenderDevice? device = attempt.device;
  print('Direct3D 12 runtime');
  print(_rule());
  if (device == null) {
    print('unavailable: ${attempt.diagnostics.join('; ')}');
  } else {
    print('adapter       : ${device.info.deviceDescription}');
    print('feature level : ${device.featureLevelText}');
    print('note          : feature level is not Shader Model; optional D3D12 '
        'features require CheckFeatureSupport.');
    device.dispose();
  }
  print('');
}

void _probeD3d11() {
  print('Direct3D 11 runtime');
  print(_rule());
  try {
    final D3d11RenderDevice device = D3d11RendererBackend.openDevice();
    print('adapter       : ${device.info.deviceDescription}');
    print('feature level : ${d3dFeatureLevelName(device.featureLevel)}');
    device.dispose();
  } on Object catch (error) {
    print('unavailable: $error');
  }
  print('');
}

_Measurement _measureAtlasCold(List<Path> paths, int samples) {
  return _measure('A atlas cold: CPU scanline + R8', samples, () {
    final GpuMaskAtlas atlas = GpuMaskAtlas(width: 1024, height: 1024);
    for (var i = 0; i < paths.length; i++) {
      final MaskRasterResult result = atlas.rasterizeMask(
        paths[i],
        transform: Transform2D.translation(
          ((i % 8) * 120).toDouble(),
          ((i ~/ 8) * 58).toDouble(),
        ),
        clip: _clip,
      );
      if (result.status != MaskRasterStatus.ok) {
        throw StateError('atlas cold workload failed: ${result.status}');
      }
    }
  }, operations: paths.length);
}

_Measurement _measureAtlasWarm(
  List<Path> paths,
  int samples,
  int rounds,
) {
  final GpuMaskAtlas atlas = GpuMaskAtlas(width: 1024, height: 1024);
  final List<Transform2D> transforms = <Transform2D>[
    for (var i = 0; i < paths.length; i++)
      Transform2D.translation(
        ((i % 8) * 120).toDouble(),
        ((i ~/ 8) * 58).toDouble(),
      ),
  ];
  for (var i = 0; i < paths.length; i++) {
    atlas.rasterizeMask(paths[i], transform: transforms[i], clip: _clip);
  }
  return _measure('A atlas warm: retained lookup', samples, () {
    for (var round = 0; round < rounds; round++) {
      for (var i = 0; i < paths.length; i++) {
        atlas.rasterizeMask(paths[i], transform: transforms[i], clip: _clip);
      }
    }
  }, operations: paths.length * rounds);
}

_Measurement _measureTessellationCold(List<Path> paths, int samples) {
  const CpuPathTessellator tessellator = CpuPathTessellator();
  return _measure('B tessellation cold: flatten + ear clip', samples, () {
    for (final Path path in paths) {
      tessellator.tessellate(path);
    }
  }, operations: paths.length);
}

_Measurement _measureTessellationWarm(
  List<Path> paths,
  int samples,
  int rounds,
) {
  final CpuTessellatedPathCache cache = CpuTessellatedPathCache();
  for (final Path path in paths) {
    cache.resolve(path);
  }
  return _measure('B tessellation warm: retained cache', samples, () {
    for (var round = 0; round < rounds; round++) {
      for (final Path path in paths) {
        cache.resolve(path);
      }
    }
  }, operations: paths.length * rounds);
}

_Measurement _measureStencilPlanning(List<Path> paths, int samples) {
  final StencilCoverDrawPlan plan = StencilCoverDrawPlan();
  return _measure('C stencil plan: flatten + fan commands', samples, () {
    plan.reset();
    for (final Path path in paths) {
      plan.append(
        path,
        clip: _clip,
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _portableStencil,
        antiAlias: false,
      );
    }
  }, operations: paths.length);
}

_Measurement _benchmarkAnalyticQuads(
  GlRenderDevice device, {
  required int samples,
  required int frames,
}) {
  final GpuBatcher batcher = GpuBatcher()..beginFrame();
  batcher.setState(
    pipeline: GpuPipelineKind.solid,
    textureId: kNoTexture,
    blendMode: blendModeSrcOver,
    scissorLeft: 0,
    scissorTop: 0,
    scissorRight: _width,
    scissorBottom: _height,
  );
  for (var i = 0; i < _gpuDrawCount; i++) {
    final double left = ((i % 32) * 32).toDouble() + 0.25;
    final double top = ((i ~/ 32) * 32).toDouble() + 0.25;
    batcher.addQuad(
      left: left,
      top: top,
      right: left + 24.5,
      bottom: top + 24.5,
      u0: 0,
      v0: 0,
      u1: 0,
      v1: 0,
      red: 0.2,
      green: 0.5,
      blue: 0.8,
      alpha: 1,
      shapeLeft: left,
      shapeTop: top,
      shapeRight: left + 24.5,
      shapeBottom: top + 24.5,
    );
  }
  return _measure('A GL analytic atlas shader', samples, () {
    for (var frame = 0; frame < frames; frame++) {
      if (!device.submit(batcher, _width, _height, 0xFF000000)) {
        throw StateError('GL device lost during A benchmark');
      }
      device.api.finish();
    }
  }, operations: frames);
}

_Measurement _benchmarkTessellatedGpu(
  GlRenderDevice device,
  GlContext context,
  DynamicLibrary glLibrary,
  List<Path> paths, {
  required int samples,
  required int frames,
}) {
  final NativeHeap? heap = NativeHeap.tryBind(glLibrary);
  if (heap == null) throw StateError('native heap unavailable for B');
  final _GlTessellationKernel kernel = _GlTessellationKernel(
    device.api,
    heap,
    paths,
  );
  try {
    return _measure(
      'B GL retained tessellated mesh (${paths.length} paths)',
      samples,
      () {
        for (var frame = 0; frame < frames; frame++) {
          kernel.draw();
          device.api.finish();
        }
      },
      operations: frames,
    );
  } finally {
    kernel.dispose();
  }
}

_Measurement? _benchmarkStencilGpu(
  GlRenderDevice device,
  List<Path> source, {
  required int samples,
  required int frames,
}) {
  if (!GlDeviceFramebufferFactory.supportsAttachments(device.api)) {
    print('C GPU skipped: attachment framebuffer functions are unavailable.');
    return null;
  }
  final GlFramebufferPool pool = GlFramebufferPool(
    factory: GlDeviceFramebufferFactory(
      gl: device.api,
      scratchNames: device.scratchNames,
      makeCurrent: device.makeCurrentOrLose,
    ),
  );
  final GlFramebuffer target = pool.acquireFramebuffer(
    _width,
    _height,
    attachments: GlFramebufferAttachments.stencil8,
  );
  final StencilCoverCapabilities capabilities =
      device.queryStencilCoverCapabilities(surfaceFramebuffer: target.id);
  final StencilCoverDrawPlan plan = StencilCoverDrawPlan();
  for (var i = 0; i < source.length; i++) {
    final int column = i % 8;
    final int row = i ~/ 8;
    plan.append(
      source[i],
      clip: _clip,
      materialIndex: 0,
      fillRule: i.isEven ? FillRule.nonZero : FillRule.evenOdd,
      capabilities: capabilities,
      antiAlias: false,
      transform: Transform2D.translation(
        (column * 120).toDouble(),
        (row * 58).toDouble(),
      ),
    );
  }
  final List<StencilGlMaterial> materials = <StencilGlMaterial>[
    StencilGlMaterial(
      red: 0.2,
      green: 0.5,
      blue: 0.8,
      alpha: 1,
      blendMode: blendModeSrcOver,
    ),
  ];
  try {
    return _measure(
      'C GL stencil-then-cover (${source.length} paths)',
      samples,
      () {
        for (var frame = 0; frame < frames; frame++) {
          device.submitStencilCover(
            plan,
            materials: materials,
            viewportWidth: _width,
            viewportHeight: _height,
            surfaceFramebuffer: target.id,
          );
          device.api.finish();
        }
      },
      operations: frames,
    );
  } finally {
    pool
      ..releaseLayerTarget(target)
      ..dispose();
  }
}

_ComputeResult _benchmarkCompute(
  GlRenderDevice device,
  GlContext context,
  DynamicLibrary glLibrary, {
  required int samples,
  required int frames,
}) {
  final RegExpMatch? version =
      RegExp(r'^(\d+)\.(\d+)').firstMatch(device.api.stringOf(glVersion));
  final int major = int.tryParse(version?.group(1) ?? '') ?? 0;
  final int minor = int.tryParse(version?.group(2) ?? '') ?? 0;
  if (major < 4 || (major == 4 && minor < 3)) {
    return _ComputeResult(null,
        'OpenGL $major.$minor has no core compute shaders (requires 4.3).');
  }
  final List<String> required = <String>[
    'glBindImageTexture',
    'glDispatchCompute',
    'glMemoryBarrier',
  ];
  final List<String> missing = <String>[
    for (final String symbol in required)
      if (context.procAddress(symbol) == nullptr) symbol,
  ];
  if (missing.isNotEmpty) {
    return _ComputeResult(null, 'missing GL functions: ${missing.join(', ')}');
  }
  final NativeHeap? heap = NativeHeap.tryBind(glLibrary);
  if (heap == null) {
    return const _ComputeResult(null, 'native heap unavailable');
  }
  final _GlComputeKernel kernel = _GlComputeKernel(
    device.api,
    context,
    heap,
    width: _width,
    height: _height,
  );
  try {
    final _Measurement measurement = _measure(
      'D GL compute RGBA8 tile microkernel',
      samples,
      () {
        for (var frame = 0; frame < frames; frame++) {
          kernel.dispatch();
          device.api.finish();
        }
      },
      operations: frames,
    );
    final Pointer<Int32> value = heap.allocate<Int32>(sizeOf<Int32>());
    device.api.getIntegerv(_glMaxComputeSharedMemorySize, value);
    final int sharedKiB = value[0] ~/ 1024;
    device.api.getIntegerv(_glMaxComputeWorkGroupInvocations, value);
    final int invocations = value[0];
    heap.release(value);
    return _ComputeResult(
      measurement,
      'available; max workgroup invocations $invocations, '
      'shared memory $sharedKiB KiB. Full vector binning/raster is TODO.',
    );
  } finally {
    kernel.dispose();
  }
}

final class _GlComputeKernel {
  _GlComputeKernel(
    this.gl,
    GlContext context,
    this.heap, {
    required this.width,
    required this.height,
  })  : _bindImageTexture = context
            .procAddress('glBindImageTexture')
            .cast<
                NativeFunction<
                    Void Function(
                        Uint32, Uint32, Int32, Uint8, Int32, Uint32, Uint32)>>()
            .asFunction(),
        _dispatchCompute = context
            .procAddress('glDispatchCompute')
            .cast<NativeFunction<Void Function(Uint32, Uint32, Uint32)>>()
            .asFunction(),
        _memoryBarrier = context
            .procAddress('glMemoryBarrier')
            .cast<NativeFunction<Void Function(Uint32)>>()
            .asFunction() {
    _program = _createProgram();
    final Pointer<Uint32> name = heap.allocate<Uint32>(sizeOf<Uint32>());
    gl.genTextures(1, name);
    _texture = name[0];
    heap.release(name);
    if (_texture == 0) throw StateError('GL returned texture name zero');
    gl
      ..bindTexture(glTexture2D, _texture)
      ..texParameteri(glTexture2D, glTextureMinFilter, glNearest)
      ..texParameteri(glTexture2D, glTextureMagFilter, glNearest)
      ..texImage2D(glTexture2D, 0, glRgba8, width, height, 0, glRgba,
          glUnsignedByte, nullptr);
  }

  final GlApi gl;
  final NativeHeap heap;
  final int width;
  final int height;
  final void Function(int, int, int, int, int, int, int) _bindImageTexture;
  final void Function(int, int, int) _dispatchCompute;
  final void Function(int) _memoryBarrier;
  int _program = 0;
  int _texture = 0;

  void dispatch() {
    gl.useProgram(_program);
    _bindImageTexture(0, _texture, 0, glFalseValue, 0, _glWriteOnly, glRgba8);
    _dispatchCompute(width ~/ 16, height ~/ 16, 1);
    _memoryBarrier(_glShaderImageAccessBarrierBit);
  }

  int _createProgram() {
    const String source = r'''#version 430 core
layout(local_size_x = 16, local_size_y = 16) in;
layout(rgba8, binding = 0) writeonly uniform image2D destination;
void main() {
  ivec2 p = ivec2(gl_GlobalInvocationID.xy);
  vec2 uv = vec2(p) / vec2(imageSize(destination));
  imageStore(destination, p, vec4(uv.x, uv.y, 1.0 - uv.x, 1.0));
}
''';
    final int shader = gl.createShader(_glComputeShader);
    if (shader == 0) throw StateError('GL returned shader name zero');
    final Pointer<Pointer<Uint8>> slot = heap.allocatePointers<Uint8>(1);
    final Pointer<Int32> status = heap.allocate<Int32>(sizeOf<Int32>());
    final Pointer<Uint8> native = heap.allocateUtf8(source);
    slot[0] = native;
    try {
      gl
        ..shaderSource(shader, 1, slot, nullptr)
        ..compileShader(shader)
        ..getShaderiv(shader, glCompileStatus, status);
      if (status[0] == glFalseValue) {
        throw StateError('compute shader compilation failed');
      }
      final int program = gl.createProgram();
      if (program == 0) throw StateError('GL returned program name zero');
      gl
        ..attachShader(program, shader)
        ..linkProgram(program)
        ..getProgramiv(program, glLinkStatus, status);
      if (status[0] == glFalseValue) {
        gl.deleteProgram(program);
        throw StateError('compute program link failed');
      }
      return program;
    } finally {
      gl.deleteShader(shader);
      heap
        ..release(native)
        ..release(slot)
        ..release(status);
    }
  }

  void dispose() {
    if (_texture != 0) {
      final Pointer<Uint32> name = heap.allocate<Uint32>(sizeOf<Uint32>());
      name[0] = _texture;
      gl.deleteTextures(1, name);
      heap.release(name);
      _texture = 0;
    }
    if (_program != 0) {
      gl.deleteProgram(_program);
      _program = 0;
    }
  }
}

final class _GlTessellationKernel {
  _GlTessellationKernel(this.gl, this.heap, List<Path> paths) {
    final List<TessellatedPathMesh> meshes = <TessellatedPathMesh>[
      for (final Path path in paths)
        const CpuPathTessellator().tessellate(path),
    ];
    var vertexCount = 0;
    var indexCount = 0;
    for (final TessellatedPathMesh mesh in meshes) {
      vertexCount += mesh.vertexCount;
      indexCount += mesh.indices.length;
    }
    _indexCount = indexCount;
    final Float32List vertices = Float32List(vertexCount * 2);
    final Uint32List indices = Uint32List(indexCount);
    var vertexCursor = 0;
    var indexCursor = 0;
    for (var meshIndex = 0; meshIndex < meshes.length; meshIndex++) {
      final TessellatedPathMesh mesh = meshes[meshIndex];
      final double tx = ((meshIndex % 8) * 120).toDouble();
      final double ty = ((meshIndex ~/ 8) * 58).toDouble();
      final int baseVertex = vertexCursor ~/ 2;
      for (var vertex = 0; vertex < mesh.vertexCount; vertex++) {
        final double x = mesh.vertices[vertex * 2] + tx;
        final double y = mesh.vertices[vertex * 2 + 1] + ty;
        vertices[vertexCursor++] = x * 2 / _width - 1;
        vertices[vertexCursor++] = 1 - y * 2 / _height;
      }
      for (final int index in mesh.indices) {
        indices[indexCursor++] = baseVertex + index;
      }
    }

    _program = _createProgram();
    final Pointer<Uint32> names = heap.allocate<Uint32>(3 * sizeOf<Uint32>());
    gl.genVertexArrays(1, names);
    _vao = names[0];
    gl.genBuffers(1, names);
    _vbo = names[0];
    gl.genBuffers(1, names);
    _ebo = names[0];
    heap.release(names);
    if (_vao == 0 || _vbo == 0 || _ebo == 0) {
      throw StateError('GL returned object name zero for B');
    }
    final Pointer<Uint8> vertexBytes =
        heap.allocate<Uint8>(vertices.lengthInBytes);
    final Pointer<Uint8> indexBytes =
        heap.allocate<Uint8>(indices.lengthInBytes);
    vertexBytes.asTypedList(vertices.lengthInBytes).setAll(
          0,
          vertices.buffer.asUint8List(),
        );
    indexBytes.asTypedList(indices.lengthInBytes).setAll(
          0,
          indices.buffer.asUint8List(),
        );
    try {
      gl
        ..bindVertexArray(_vao)
        ..bindBuffer(glArrayBuffer, _vbo)
        ..bufferData(
          glArrayBuffer,
          vertices.lengthInBytes,
          vertexBytes.cast<Void>(),
          glDynamicDraw,
        )
        ..enableVertexAttribArray(0)
        ..vertexAttribPointer(
          0,
          2,
          glFloat,
          glFalseValue,
          2 * sizeOf<Float>(),
          nullptr,
        )
        ..bindBuffer(glElementArrayBuffer, _ebo)
        ..bufferData(
          glElementArrayBuffer,
          indices.lengthInBytes,
          indexBytes.cast<Void>(),
          glDynamicDraw,
        );
    } finally {
      heap
        ..release(vertexBytes)
        ..release(indexBytes);
    }
  }

  final GlApi gl;
  final NativeHeap heap;
  int _program = 0;
  int _vao = 0;
  int _vbo = 0;
  int _ebo = 0;
  int _indexCount = 0;

  void draw() {
    gl
      ..bindFramebuffer(glFramebuffer, 0)
      ..viewport(0, 0, _width, _height)
      ..disable(glDepthTest)
      ..disable(glCullFace)
      ..disable(glStencilTest)
      ..disable(glBlend)
      ..clearColor(0, 0, 0, 1)
      ..clear(glColorBufferBit)
      ..useProgram(_program)
      ..bindVertexArray(_vao)
      ..drawElements(glTriangles, _indexCount, glUnsignedInt, nullptr);
  }

  int _createProgram() {
    const String vertexSource = r'''#version 330 core
layout(location = 0) in vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
''';
    const String fragmentSource = r'''#version 330 core
out vec4 color;
void main() { color = vec4(0.2, 0.5, 0.8, 1.0); }
''';
    final int vertex = _compile(glVertexShader, vertexSource);
    final int fragment = _compile(glFragmentShader, fragmentSource);
    final Pointer<Int32> status = heap.allocate<Int32>(sizeOf<Int32>());
    try {
      final int program = gl.createProgram();
      gl
        ..attachShader(program, vertex)
        ..attachShader(program, fragment)
        ..linkProgram(program)
        ..getProgramiv(program, glLinkStatus, status);
      if (status[0] == glFalseValue) {
        gl.deleteProgram(program);
        throw StateError('B tessellation program link failed');
      }
      return program;
    } finally {
      gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
      heap.release(status);
    }
  }

  int _compile(int kind, String source) {
    final int shader = gl.createShader(kind);
    final Pointer<Pointer<Uint8>> slot = heap.allocatePointers<Uint8>(1);
    final Pointer<Int32> status = heap.allocate<Int32>(sizeOf<Int32>());
    final Pointer<Uint8> native = heap.allocateUtf8(source);
    slot[0] = native;
    try {
      gl
        ..shaderSource(shader, 1, slot, nullptr)
        ..compileShader(shader)
        ..getShaderiv(shader, glCompileStatus, status);
      if (status[0] == glFalseValue) {
        gl.deleteShader(shader);
        throw StateError('B tessellation shader compilation failed');
      }
      return shader;
    } finally {
      heap
        ..release(native)
        ..release(slot)
        ..release(status);
    }
  }

  void dispose() {
    final Pointer<Uint32> name = heap.allocate<Uint32>(sizeOf<Uint32>());
    if (_ebo != 0) {
      name[0] = _ebo;
      gl.deleteBuffers(1, name);
      _ebo = 0;
    }
    if (_vbo != 0) {
      name[0] = _vbo;
      gl.deleteBuffers(1, name);
      _vbo = 0;
    }
    if (_vao != 0) {
      name[0] = _vao;
      gl.deleteVertexArrays(1, name);
      _vao = 0;
    }
    heap.release(name);
    if (_program != 0) {
      gl.deleteProgram(_program);
      _program = 0;
    }
  }
}

final class _GlSession {
  _GlSession(
    this.surface,
    this.context,
    this.device,
    this.glLibrary,
    this.failure,
  );

  final Win32GlSurface? surface;
  final GlContext? context;
  final GlRenderDevice? device;
  final DynamicLibrary? glLibrary;
  final String? failure;

  static _GlSession open() => Platform.isWindows ? _openWgl() : _openEgl();

  static _GlSession _openWgl() {
    final Win32GlSurfaceAttempt surfaceAttempt = Win32GlSurface.hidden(
      width: _width,
      height: _height,
      className: 'DartUiPoc23GpuBenchmark',
    );
    final Win32GlSurface? surface = surfaceAttempt.surface;
    if (surface == null) {
      return _GlSession(
        null,
        null,
        null,
        null,
        surfaceAttempt.diagnostics.join('; '),
      );
    }
    final GlContextAttempt contextAttempt = surface.createContext();
    final GlContext? context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _GlSession(
        null,
        null,
        null,
        null,
        contextAttempt.diagnostics.join('; '),
      );
    }
    try {
      final GlRenderDevice device = GlRendererBackend.adoptContext(
        context,
        surface.glLibrary,
        enableExperimentalStencilCover: true,
      );
      return _GlSession(surface, context, device, surface.glLibrary, null);
    } on Object catch (error) {
      surface.dispose();
      return _GlSession(null, null, null, null, '$error');
    }
  }

  static _GlSession _openEgl() {
    final GlLibraryLoad load = GlLibrary.open();
    final DynamicLibrary? library = load.library;
    if (library == null) {
      return _GlSession(
        null,
        null,
        null,
        null,
        'no GL library: ${load.attempted.join(', ')}',
      );
    }
    final GlContextAttempt contextAttempt = const GlContextFactory().create(
      width: _width,
      height: _height,
      glLibrary: library,
    );
    final GlContext? context = contextAttempt.context;
    if (context == null) {
      return _GlSession(
        null,
        null,
        null,
        null,
        contextAttempt.diagnostics.join('; '),
      );
    }
    try {
      final GlRenderDevice device = GlRendererBackend.adoptContext(
        context,
        library,
        enableExperimentalStencilCover: true,
      );
      return _GlSession(null, context, device, library, null);
    } on Object catch (error) {
      return _GlSession(null, null, null, null, '$error');
    }
  }

  void close() {
    device?.dispose();
    surface?.dispose();
  }
}

final class _Measurement {
  const _Measurement(this.label, this.nanosecondsPerOperation, this.operations);

  final String label;
  final double nanosecondsPerOperation;
  final int operations;
}

final class _ComputeResult {
  const _ComputeResult(this.measurement, this.detail);

  final _Measurement? measurement;
  final String? detail;
}

_Measurement _measure(
  String label,
  int samples,
  void Function() body, {
  required int operations,
}) {
  body();
  final List<int> values = <int>[];
  for (var sample = 0; sample < samples; sample++) {
    final Stopwatch watch = Stopwatch()..start();
    body();
    watch.stop();
    values.add(watch.elapsedMicroseconds * 1000);
  }
  values.sort();
  return _Measurement(
      label, values[values.length ~/ 2] / operations, operations);
}

void _printMeasurements(List<_Measurement> measurements) {
  for (final _Measurement value in measurements) {
    final double micros = value.nanosecondsPerOperation / 1000;
    print(
        '${value.label.padRight(45)} ${micros.toStringAsFixed(3).padLeft(11)} us/op');
  }
}

List<Path> _workloadPaths(int count) => <Path>[
      for (var i = 0; i < count; i++) _curvedPath(i),
    ];

Path _curvedPath(int index) {
  final double wobble = (index % 13) * 0.17;
  return (PathBuilder()
        ..moveTo(2, 26)
        ..cubicTo(8 + wobble, 1, 32, 1 + wobble, 39, 25)
        ..quadraticBezierTo(50, 45 - wobble, 29, 51)
        ..cubicTo(15, 55, 1, 42 + wobble, 2, 26)
        ..close())
      .build();
}

int _integerArgument(
  List<String> arguments,
  String prefix, {
  required int fallback,
}) {
  for (final String argument in arguments) {
    if (argument.startsWith(prefix)) {
      return int.tryParse(argument.substring(prefix.length)) ?? fallback;
    }
  }
  return fallback;
}

String _rule() => '-' * 72;

const int _glComputeShader = 0x91B9;
const int _glWriteOnly = 0x88B9;
const int _glShaderImageAccessBarrierBit = 0x00000020;
const int _glMaxComputeSharedMemorySize = 0x8262;
const int _glMaxComputeWorkGroupInvocations = 0x90EB;
