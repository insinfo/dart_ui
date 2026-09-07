library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../../../ffi/objc_runtime.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/mesh/mesh3d.dart';
import '../../mesh/mesh_rasterizer.dart';
import '../../mesh/mesh_scene.dart';
import '../../renderer.dart';
import 'metal_backend.dart';
import 'metal_bindings.dart';
import 'metal_device.dart';
import 'metal_mesh_shaders.dart';

final class MetalMeshRenderer implements MeshSceneRenderer {
  MetalMeshRenderer(this._device) : _gpu = _device.meshGpu {
    _buildObjects();
  }

  final MetalRenderDevice _device;
  final MetalGpu _gpu;
  late final Pointer<ObjCObject> _library;
  late final Pointer<ObjCObject> _pipeline;
  late final Pointer<ObjCObject> _depthState;
  late final Pointer<ObjCObject> _white;
  final Map<_BufferKey, _Buffers> _buffers = <_BufferKey, _Buffers>{};
  final Map<MeshTexture, Pointer<ObjCObject>> _textures =
      <MeshTexture, Pointer<ObjCObject>>{};
  final Map<MetalMemoryTarget, _Depth> _depth = <MetalMemoryTarget, _Depth>{};
  late final Pointer<Float> _uniform =
      NativeAllocator.instance.allocate<Float>(kMetalMeshUniformBytes);
  bool _disposed = false;

  int get cachedPrimitiveCount => _buffers.length;
  int get cachedTextureCount => _textures.length;
  int get bufferUploadCount => _bufferUploads;
  int _bufferUploads = 0;

  void _buildObjects() {
    _library = _gpu.compileShaderLibrary(kMetalMeshShaderSource);
    Pointer<ObjCObject>? vertex;
    Pointer<ObjCObject>? fragment;
    try {
      vertex = _gpu.newFunction(_library, 'meshVs');
      fragment = _gpu.newFunction(_library, 'meshFs');
      _pipeline = ObjCAutoreleasePool.run(() {
        final Pointer<ObjCObject> descriptor = metalSendPointer(
            metalSendPointer(objcClass('MTLRenderPipelineDescriptor'), 'alloc'),
            'init');
        try {
          metalSendVoid1(descriptor, 'setVertexFunction:', vertex!.address);
          metalSendVoid1(descriptor, 'setFragmentFunction:', fragment!.address);
          metalSendVoid1(
              descriptor,
              'setVertexDescriptor:',
              metalBuildVertexDescriptor(
                stride: kMetalMeshVertexStride,
                attributes: const <MetalVertexAttribute>[
                  MetalVertexAttribute(
                      attributeIndex: 0,
                      format: MtlVertexFormat.float3,
                      byteOffset: 0,
                      name: 'position'),
                  MetalVertexAttribute(
                      attributeIndex: 1,
                      format: MtlVertexFormat.float3,
                      byteOffset: 12,
                      name: 'normal'),
                  MetalVertexAttribute(
                      attributeIndex: 2,
                      format: MtlVertexFormat.float2,
                      byteOffset: 24,
                      name: 'uv'),
                ],
              ).address);
          final Pointer<ObjCObject> color = metalSendPointer1(
              metalSendPointer(descriptor, 'colorAttachments'),
              'objectAtIndexedSubscript:',
              0);
          metalSendVoid1(color, 'setPixelFormat:', MtlPixelFormat.rgba8Unorm);
          metalSendVoid1(descriptor, 'setDepthAttachmentPixelFormat:',
              MtlPixelFormat.depth32Float);
          final Pointer<Pointer<ObjCObject>> error =
              NativeAllocator.instance.allocate<Pointer<ObjCObject>>(1);
          try {
            error.value = nullptr;
            final Pointer<ObjCObject> state = metalSendPointer2(
                _gpu.device,
                'newRenderPipelineStateWithDescriptor:error:',
                descriptor.address,
                error.address);
            if (state == nullptr) {
              throw MetalError('Metal refused the mesh pipeline',
                  detail: metalErrorDescription(error.value));
            }
            return state;
          } finally {
            NativeAllocator.instance.free(error);
          }
        } finally {
          objcRelease(descriptor);
        }
      });
      _depthState = ObjCAutoreleasePool.run(() {
        final Pointer<ObjCObject> descriptor = metalSendPointer(
            metalSendPointer(objcClass('MTLDepthStencilDescriptor'), 'alloc'),
            'init');
        try {
          metalSendVoid1(
              descriptor, 'setDepthCompareFunction:', MtlCompareFunction.less);
          metalSendVoid1(descriptor, 'setDepthWriteEnabled:', 1);
          final Pointer<ObjCObject> state = metalSendPointer1(_gpu.device,
              'newDepthStencilStateWithDescriptor:', descriptor.address);
          if (state == nullptr) {
            throw MetalError('Metal refused the mesh depth state');
          }
          return state;
        } finally {
          objcRelease(descriptor);
        }
      });
      _white =
          _uploadTexture(1, 1, Uint8List.fromList(const [255, 255, 255, 255]));
    } on Object {
      if (fragment != null) objcRelease(fragment);
      if (vertex != null) objcRelease(vertex);
      objcRelease(_library);
      rethrow;
    }
    objcRelease(fragment);
    objcRelease(vertex);
  }

  @override
  MeshRenderStats drawScene(RenderTarget target, MeshScene scene,
      {Rect? viewport}) {
    if (_disposed || _device.isDisposed || target is! MetalMemoryTarget) {
      return MeshRenderStats.zero;
    }
    final int width = target.surface.pixelWidth;
    final int height = target.surface.pixelHeight;
    final Rect area =
        viewport ?? Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    if (area.width <= 0 || area.height <= 0) return MeshRenderStats.zero;
    final _Depth depth = _depthFor(target, width, height);
    final Matrix4 mvp = scene.camera
        .projectionMatrix(area.width / area.height)
        .multiply(scene.camera.viewMatrix());
    final int started = DateTime.now().microsecondsSinceEpoch;
    var triangles = 0;
    target.meshTarget.encodePass(
      clearColor: scene.backgroundArgb,
      depthTexture: depth.texture,
      body: (Pointer<ObjCObject> encoder) {
        metalSendVoid1(encoder, 'setRenderPipelineState:', _pipeline.address);
        metalSendVoid1(encoder, 'setDepthStencilState:', _depthState.address);
        metalSendVoid1(
            encoder,
            'setTriangleFillMode:',
            scene.shading == MeshShading.wireframe
                ? MtlTriangleFillMode.lines
                : MtlTriangleFillMode.fill);
        metalSendDouble6(
            encoder,
            'setViewport:',
            mtlViewport(
                originX: area.left,
                originY: area.top,
                width: area.width,
                height: area.height));
        metalSendWord4(
            encoder,
            'setScissorRect:',
            mtlScissorRect(
                x: area.left.floor().clamp(0, width),
                y: area.top.floor().clamp(0, height),
                width: area.width.floor().clamp(0, width),
                height: area.height.floor().clamp(0, height)));
        for (final MeshPrimitive primitive in scene.mesh.primitives) {
          if (primitive.indices.length < 3) continue;
          final _Buffers buffers = _buffers.putIfAbsent(
              _BufferKey(primitive, scene.shading),
              () => _uploadBuffers(primitive, scene.shading));
          _writeUniform(mvp, primitive, scene);
          metalSendVoid1(
              encoder,
              'setCullMode:',
              primitive.material.doubleSided
                  ? MtlCullMode.none
                  : MtlCullMode.back);
          metalSendVoid3(encoder, 'setVertexBuffer:offset:atIndex:',
              buffers.vertices.address, 0, 0);
          metalSendVoid3(encoder, 'setVertexBytes:length:atIndex:',
              _uniform.address, kMetalMeshUniformBytes, 1);
          metalSendVoid3(encoder, 'setFragmentBytes:length:atIndex:',
              _uniform.address, kMetalMeshUniformBytes, 1);
          metalSendVoid2(encoder, 'setFragmentTexture:atIndex:',
              (_textureFor(primitive) ?? _white).address, 0);
          metalSendVoid5(
              encoder,
              'drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:',
              MtlPrimitiveType.triangle,
              buffers.count,
              MtlIndexType.uint32,
              buffers.indices.address,
              0);
          triangles += primitive.triangleCount;
        }
      },
    );
    return gpuMeshStats(
        triangles: triangles,
        microseconds: DateTime.now().microsecondsSinceEpoch - started);
  }

  void _writeUniform(Matrix4 mvp, MeshPrimitive primitive, MeshScene scene) {
    final Float32List data = _uniform.asTypedList(kMetalMeshUniformBytes ~/ 4);
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
    data[23] = 0;
    data[24] = scene.ambient;
    data[25] = scene.shading == MeshShading.unlit ? 0 : 1;
    data[26] = 0;
    data[27] = 0;
  }

  _Buffers _uploadBuffers(MeshPrimitive primitive, MeshShading shading) {
    final Float32List vertices = packMetalMeshVertices(primitive, shading);
    final Uint32List indices = shading == MeshShading.flat
        ? Uint32List.fromList(
            List<int>.generate(primitive.indices.length, (i) => i))
        : primitive.indices;
    _bufferUploads += 2;
    return _Buffers(
        _newBuffer(vertices.buffer
            .asUint8List(vertices.offsetInBytes, vertices.lengthInBytes)),
        _newBuffer(indices.buffer
            .asUint8List(indices.offsetInBytes, indices.lengthInBytes)),
        indices.length);
  }

  Pointer<ObjCObject> _newBuffer(Uint8List bytes) {
    final Pointer<Uint8> scratch =
        NativeAllocator.instance.allocate<Uint8>(bytes.length);
    try {
      scratch.asTypedList(bytes.length).setAll(0, bytes);
      final Pointer<ObjCObject> buffer = metalSendPointer3(
          _gpu.device,
          'newBufferWithBytes:length:options:',
          scratch.address,
          bytes.length,
          MtlResourceOptions.storageModeShared);
      if (buffer == nullptr) {
        throw MetalError('mesh buffer upload returned nil');
      }
      return buffer;
    } finally {
      NativeAllocator.instance.free(scratch);
    }
  }

  Pointer<ObjCObject>? _textureFor(MeshPrimitive primitive) {
    final MeshTexture? texture = primitive.material.baseColorTexture;
    if (texture == null || primitive.uvs == null) return null;
    return _textures.putIfAbsent(
        texture,
        () => _uploadTexture(texture.width, texture.height,
            packMetalMeshTexturePixels(texture)));
  }

  Pointer<ObjCObject> _uploadTexture(int width, int height, Uint8List rgba) {
    return ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> descriptor = metalSendPointer4(
          objcClass('MTLTextureDescriptor'),
          'texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
          MtlPixelFormat.rgba8Unorm,
          width,
          height,
          0);
      metalSendVoid1(descriptor, 'setUsage:', MtlTextureUsage.shaderRead);
      metalSendVoid1(descriptor, 'setStorageMode:', MtlStorageMode.shared);
      final Pointer<ObjCObject> texture = metalSendPointer1(
          _gpu.device, 'newTextureWithDescriptor:', descriptor.address);
      if (texture == nullptr) {
        throw MetalError('mesh texture upload returned nil');
      }
      final Pointer<Uint8> scratch =
          NativeAllocator.instance.allocate<Uint8>(rgba.length);
      try {
        scratch.asTypedList(rgba.length).setAll(0, rgba);
        metalSendReplaceRegion(
            texture,
            'replaceRegion:mipmapLevel:withBytes:bytesPerRow:',
            mtlRegion2D(x: 0, y: 0, width: width, height: height),
            0,
            scratch.cast<Void>(),
            width * 4);
      } finally {
        NativeAllocator.instance.free(scratch);
      }
      return texture;
    });
  }

  _Depth _depthFor(MetalMemoryTarget target, int width, int height) {
    final _Depth? current = _depth[target];
    if (current != null && current.width == width && current.height == height) {
      return current;
    }
    current?.dispose();
    final Pointer<ObjCObject> texture = ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> descriptor = metalSendPointer4(
          objcClass('MTLTextureDescriptor'),
          'texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
          MtlPixelFormat.depth32Float,
          width,
          height,
          0);
      metalSendVoid1(descriptor, 'setUsage:', MtlTextureUsage.renderTarget);
      metalSendVoid1(descriptor, 'setStorageMode:', MtlStorageMode.private);
      return metalSendPointer1(
          _gpu.device, 'newTextureWithDescriptor:', descriptor.address);
    });
    if (texture == nullptr) {
      throw MetalError('depth texture creation returned nil');
    }
    return _depth[target] = _Depth(texture, width, height);
  }

  @override
  void discardMesh(Mesh3D mesh) {
    final List<_BufferKey> keys = _buffers.keys
        .where((key) => mesh.primitives.any((p) => identical(p, key.primitive)))
        .toList();
    for (final _BufferKey key in keys) {
      _buffers.remove(key)?.dispose();
    }
    final Set<MeshTexture> used = mesh.primitives
        .map((p) => p.material.baseColorTexture)
        .whereType<MeshTexture>()
        .toSet();
    for (final MeshTexture texture in used) {
      final Pointer<ObjCObject>? object = _textures.remove(texture);
      if (object != null) objcRelease(object);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final _Buffers value in _buffers.values) {
      value.dispose();
    }
    for (final Pointer<ObjCObject> value in _textures.values) {
      objcRelease(value);
    }
    for (final _Depth value in _depth.values) {
      value.dispose();
    }
    _buffers.clear();
    _textures.clear();
    _depth.clear();
    NativeAllocator.instance.free(_uniform);
    objcRelease(_white);
    objcRelease(_depthState);
    objcRelease(_pipeline);
    objcRelease(_library);
  }
}

final class _BufferKey {
  const _BufferKey(this.primitive, this.shading);
  final MeshPrimitive primitive;
  final MeshShading shading;
  @override
  bool operator ==(Object other) =>
      other is _BufferKey &&
      identical(other.primitive, primitive) &&
      other.shading == shading;
  @override
  int get hashCode => Object.hash(identityHashCode(primitive), shading);
}

final class _Buffers {
  const _Buffers(this.vertices, this.indices, this.count);
  final Pointer<ObjCObject> vertices;
  final Pointer<ObjCObject> indices;
  final int count;
  void dispose() {
    objcRelease(indices);
    objcRelease(vertices);
  }
}

final class _Depth {
  const _Depth(this.texture, this.width, this.height);
  final Pointer<ObjCObject> texture;
  final int width;
  final int height;
  void dispose() => objcRelease(texture);
}
