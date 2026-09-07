/// Hardware mesh rendering into a WebGPU canvas target.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../../geometry/rect.dart';
import '../../../graphics/mesh/mesh3d.dart';
import '../../mesh/mesh_rasterizer.dart';
import '../../mesh/mesh_scene.dart';
import '../../renderer.dart';
import 'webgpu_backend.dart';
import 'webgpu_canvas_target.dart';
import 'webgpu_interop.dart';
import 'wgsl_mesh_shaders.dart';

final class WebGpuMeshRenderer implements MeshSceneRenderer {
  WebGpuMeshRenderer(WebGpuRenderDevice device) : _device = device {
    final GPUDevice gpu = device.gpuDevice;
    _module = gpu.createShaderModule(
      GPUShaderModuleDescriptor(code: kWgslMeshShaderSource),
    );
    _layout = gpu.createBindGroupLayout(GPUBindGroupLayoutDescriptor(
        entries: <GPUBindGroupLayoutEntry>[
      GPUBindGroupLayoutEntry(
        binding: 0,
        visibility: web.$GPUShaderStage.VERTEX | web.$GPUShaderStage.FRAGMENT,
        buffer: GPUBufferBindingLayout(
          type: 'uniform',
          hasDynamicOffset: false,
          minBindingSize: kWebGpuMeshUniformBytes,
        ),
      ),
      GPUBindGroupLayoutEntry(
        binding: 1,
        visibility: web.$GPUShaderStage.FRAGMENT,
        sampler: GPUSamplerBindingLayout(type: 'filtering'),
      ),
      GPUBindGroupLayoutEntry(
        binding: 2,
        visibility: web.$GPUShaderStage.FRAGMENT,
        texture: GPUTextureBindingLayout(sampleType: 'float'),
      ),
    ].toJS));
    _pipelineLayout = gpu.createPipelineLayout(
      GPUPipelineLayoutDescriptor(
          bindGroupLayouts: <GPUBindGroupLayout>[_layout].toJS),
    );
    _sampler = gpu.createSampler(GPUSamplerDescriptor(
      magFilter: 'nearest',
      minFilter: 'nearest',
      addressModeU: 'repeat',
      addressModeV: 'repeat',
    ));
    _whiteTexture = _uploadRgbaTexture(
        1, 1, Uint8List.fromList(const <int>[255, 255, 255, 255]));
  }

  final WebGpuRenderDevice _device;
  late final GPUShaderModule _module;
  late final GPUBindGroupLayout _layout;
  late final GPUPipelineLayout _pipelineLayout;
  late final GPUSampler _sampler;
  late final GPUTexture _whiteTexture;
  final Map<MeshPrimitive, Map<MeshShading, _Buffers>> _buffers = {};
  final Map<MeshTexture, GPUTexture> _textures = <MeshTexture, GPUTexture>{};
  final Map<String, GPURenderPipeline> _pipelines =
      <String, GPURenderPipeline>{};
  GPUTexture? _depth;
  int _depthWidth = 0;
  int _depthHeight = 0;
  bool _disposed = false;

  @override
  MeshRenderStats drawScene(RenderTarget target, MeshScene scene,
      {Rect? viewport}) {
    if (_disposed || _device.isLost || target is! WebGpuCanvasTarget) {
      return MeshRenderStats.zero;
    }
    final GPUTextureView? color = target.acquireAttachmentView();
    if (color == null) return MeshRenderStats.zero;
    _ensureDepth(target.pixelWidth, target.pixelHeight);
    final Rect area = viewport ??
        Rect.fromLTWH(
            0, 0, target.pixelWidth.toDouble(), target.pixelHeight.toDouble());
    if (area.width <= 0 || area.height <= 0) return MeshRenderStats.zero;
    final int started = DateTime.now().microsecondsSinceEpoch;
    final GPUCommandEncoder encoder = _device.gpuDevice.createCommandEncoder();
    final int? clear = scene.backgroundArgb;
    final GPURenderPassEncoder pass =
        encoder.beginRenderPass(GPURenderPassDescriptor(
      colorAttachments: <GPURenderPassColorAttachment>[
        GPURenderPassColorAttachment(
          view: color,
          loadOp: clear == null ? 'load' : 'clear',
          storeOp: 'store',
          clearValue: _color(clear ?? 0),
        ),
      ].toJS,
      depthStencilAttachment: GPURenderPassDepthStencilAttachment(
          view: _depth!.createView(),
          depthClearValue: 1,
          depthLoadOp: 'clear',
          depthStoreOp: 'discard'),
    ));
    pass.setViewport(area.left, area.top, area.width, area.height, 0, 1);
    pass.setScissorRect(area.left.floor(), area.top.floor(), area.width.floor(),
        area.height.floor());
    final Matrix4 mvp = scene.camera
        .projectionMatrix(area.width / area.height)
        .multiply(scene.camera.viewMatrix());
    var triangles = 0;
    final List<GPUBuffer> transientUniforms = <GPUBuffer>[];
    for (final MeshPrimitive primitive in scene.mesh.primitives) {
      final _Buffers buffers = _buffers
          .putIfAbsent(primitive, () => {})
          .putIfAbsent(scene.shading, () => _upload(primitive, scene.shading));
      final GPUBuffer uniform = _uniform(primitive, scene, mvp);
      final GPUTexture texture = _textureFor(primitive) ?? _whiteTexture;
      transientUniforms.add(uniform);
      final GPUBindGroup group =
          _device.gpuDevice.createBindGroup(GPUBindGroupDescriptor(
        layout: _layout,
        entries: <GPUBindGroupEntry>[
          GPUBindGroupEntry(
              binding: 0,
              resource: GPUBufferBinding(
                  buffer: uniform, offset: 0, size: kWebGpuMeshUniformBytes)),
          GPUBindGroupEntry(binding: 1, resource: _sampler),
          GPUBindGroupEntry(binding: 2, resource: texture.createView()),
        ].toJS,
      ));
      pass
        ..setPipeline(_pipeline(primitive.material.doubleSided,
            scene.shading == MeshShading.wireframe))
        ..setBindGroup(0, group)
        ..setVertexBuffer(0, buffers.vertices)
        ..setIndexBuffer(buffers.indices, 'uint32')
        ..drawIndexed(buffers.count);
      triangles += primitive.triangleCount;
    }
    pass.end();
    _device.gpuDevice.queue.submit(<GPUCommandBuffer>[encoder.finish()].toJS);
    for (final GPUBuffer uniform in transientUniforms) {
      uniform.destroy();
    }
    return gpuMeshStats(
        triangles: triangles,
        microseconds: DateTime.now().microsecondsSinceEpoch - started);
  }

  GPUTexture? _textureFor(MeshPrimitive primitive) {
    final MeshTexture? texture = primitive.material.baseColorTexture;
    final Float32List? uvs = primitive.uvs;
    if (texture == null ||
        uvs == null ||
        uvs.length < primitive.vertexCount * 2) {
      return null;
    }
    return _textures.putIfAbsent(texture, () {
      return _uploadRgbaTexture(
          texture.width, texture.height, packWebGpuTexturePixels(texture));
    });
  }

  GPUTexture _uploadRgbaTexture(int width, int height, Uint8List rgba) {
    final GPUTexture texture =
        _device.gpuDevice.createTexture(GPUTextureDescriptor(
      size: GPUExtent3DDict(width: width, height: height),
      format: 'rgba8unorm',
      usage:
          web.$GPUTextureUsage.TEXTURE_BINDING | web.$GPUTextureUsage.COPY_DST,
    ));
    _device.gpuDevice.queue.writeTexture(
      GPUTexelCopyTextureInfo(
          texture: texture, origin: GPUOrigin3DDict(x: 0, y: 0)),
      rgba.toJS,
      GPUTexelCopyBufferLayout(
          offset: 0, bytesPerRow: width * 4, rowsPerImage: height),
      GPUExtent3DDict(width: width, height: height),
    );
    return texture;
  }

  int get debugCachedTextureCount => _textures.length;

  _Buffers _upload(MeshPrimitive primitive, MeshShading shading) {
    final Float32List vertices = packWebGpuMeshVertices(primitive, shading);
    final Uint32List indices = shading == MeshShading.wireframe
        ? _wireIndices(primitive.indices)
        : shading == MeshShading.flat
            ? Uint32List.fromList(
                List<int>.generate(primitive.indices.length, (int i) => i))
            : primitive.indices;
    final GPUBuffer vb = _device.gpuDevice.createBuffer(GPUBufferDescriptor(
        size: vertices.lengthInBytes,
        usage: web.$GPUBufferUsage.VERTEX | web.$GPUBufferUsage.COPY_DST));
    final GPUBuffer ib = _device.gpuDevice.createBuffer(GPUBufferDescriptor(
        size: indices.lengthInBytes,
        usage: web.$GPUBufferUsage.INDEX | web.$GPUBufferUsage.COPY_DST));
    _device.gpuDevice.queue
      ..writeBuffer(vb, 0, vertices.toJS)
      ..writeBuffer(ib, 0, indices.toJS);
    return _Buffers(vb, ib, indices.length);
  }

  GPUBuffer _uniform(MeshPrimitive primitive, MeshScene scene, Matrix4 mvp) {
    final Float32List data = Float32List(kWebGpuMeshUniformBytes ~/ 4);
    for (var i = 0; i < 16; i++) {
      data[i] = mvp[i];
    }
    final int color = primitive.material.colorArgb;
    data[16] = ((color >> 16) & 255) / 255;
    data[17] = ((color >> 8) & 255) / 255;
    data[18] = (color & 255) / 255;
    data[19] = ((color >> 24) & 255) / 255;
    final Vector3 light = scene.lightDirection.normalized;
    data[20] = light.x;
    data[21] = light.y;
    data[22] = light.z;
    data[24] = scene.ambient;
    data[25] = scene.shading == MeshShading.unlit ? 0 : 1;
    final GPUBuffer buffer = _device.gpuDevice.createBuffer(GPUBufferDescriptor(
        size: data.lengthInBytes,
        usage: web.$GPUBufferUsage.UNIFORM | web.$GPUBufferUsage.COPY_DST));
    _device.gpuDevice.queue.writeBuffer(buffer, 0, data.toJS);
    return buffer;
  }

  GPURenderPipeline _pipeline(bool doubleSided, bool wireframe) =>
      _pipelines.putIfAbsent(
          '$doubleSided/$wireframe',
          () => _device.gpuDevice
                  .createRenderPipeline(GPURenderPipelineDescriptor(
                layout: _pipelineLayout,
                vertex: GPUVertexState(
                    module: _module,
                    entryPoint: 'vs_main',
                    buffers: <GPUVertexBufferLayout>[
                      GPUVertexBufferLayout(
                          arrayStride: kWebGpuMeshVertexStride,
                          attributes: <GPUVertexAttribute>[
                            GPUVertexAttribute(
                                format: 'float32x3',
                                offset: 0,
                                shaderLocation: 0),
                            GPUVertexAttribute(
                                format: 'float32x3',
                                offset: 12,
                                shaderLocation: 1),
                            GPUVertexAttribute(
                                format: 'float32x2',
                                offset: 24,
                                shaderLocation: 2),
                          ].toJS),
                    ].toJS),
                fragment: GPUFragmentState(
                    module: _module,
                    entryPoint: 'fs_main',
                    targets: <GPUColorTargetState>[
                      GPUColorTargetState(format: _device.surfaceFormat),
                    ].toJS),
                primitive: GPUPrimitiveState(
                    topology: wireframe ? 'line-list' : 'triangle-list',
                    frontFace: 'ccw',
                    cullMode: doubleSided ? 'none' : 'back'),
                depthStencil: GPUDepthStencilState(
                    format: 'depth24plus',
                    depthWriteEnabled: true,
                    depthCompare: 'less'),
              )));

  void _ensureDepth(int width, int height) {
    if (_depth != null && width == _depthWidth && height == _depthHeight) {
      return;
    }
    _depth?.destroy();
    _depth = _device.gpuDevice.createTexture(GPUTextureDescriptor(
        size: GPUExtent3DDict(width: width, height: height),
        format: 'depth24plus',
        usage: web.$GPUTextureUsage.RENDER_ATTACHMENT));
    _depthWidth = width;
    _depthHeight = height;
  }

  GPUColorDict _color(int argb) => GPUColorDict(
      r: ((argb >> 16) & 255) / 255,
      g: ((argb >> 8) & 255) / 255,
      b: (argb & 255) / 255,
      a: ((argb >> 24) & 255) / 255);

  @override
  void discardMesh(Mesh3D mesh) {
    for (final MeshPrimitive primitive in mesh.primitives) {
      for (final _Buffers buffer
          in _buffers.remove(primitive)?.values ?? const <_Buffers>[]) {
        buffer.destroy();
      }
      final MeshTexture? texture = primitive.material.baseColorTexture;
      final bool stillUsed = texture != null &&
          _buffers.keys.any(
            (MeshPrimitive remaining) =>
                identical(remaining.material.baseColorTexture, texture),
          );
      final GPUTexture? object =
          texture == null || stillUsed ? null : _textures.remove(texture);
      object?.destroy();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final Map<MeshShading, _Buffers> variants in _buffers.values) {
      for (final _Buffers buffers in variants.values) {
        buffers.destroy();
      }
    }
    _buffers.clear();
    for (final GPUTexture texture in _textures.values) {
      texture.destroy();
    }
    _textures.clear();
    _whiteTexture.destroy();
    _depth?.destroy();
  }
}

Uint32List _wireIndices(Uint32List source) {
  final Uint32List out = Uint32List(source.length * 2);
  for (var i = 0, o = 0; i < source.length; i += 3) {
    final a = source[i], b = source[i + 1], c = source[i + 2];
    out[o++] = a;
    out[o++] = b;
    out[o++] = b;
    out[o++] = c;
    out[o++] = c;
    out[o++] = a;
  }
  return out;
}

final class _Buffers {
  _Buffers(this.vertices, this.indices, this.count);
  final GPUBuffer vertices;
  final GPUBuffer indices;
  final int count;
  void destroy() {
    vertices.destroy();
    indices.destroy();
  }
}
