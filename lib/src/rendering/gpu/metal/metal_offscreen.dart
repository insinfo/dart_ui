/// An offscreen `MTLTexture`, a render pass, and the readback that makes the
/// result comparable against the CPU rasteriser.
///
/// This is the smallest thing that can be *checked*: everything before it -
/// symbols, encodings, a compiled library, a validated pipeline state - proves
/// that Metal accepted a description, and none of it proves that a pixel came
/// out right. A cleared texture read back into a [Framebuffer] does, and it is
/// the same shape `D3d11OffscreenTarget` and `GlOffscreenTarget` take, so the
/// parity test can hold one against the other.
///
/// ## Storage mode, and why `shared`
///
/// `MTLStorageModeShared` puts the texture in memory both processors address,
/// which on Apple Silicon is all of it. That is what makes
/// `getBytes:bytesPerRow:fromRegion:mipmapLevel:` legal without a blit encoder:
/// a `private` texture cannot be read by the CPU at all, and a `managed` one
/// would need an explicit `synchronizeResource:` on a blit encoder first -
/// and `managed` does not exist on Apple Silicon in the first place.
///
/// ## Why the command buffer is waited on
///
/// `commit` **enqueues**. It does not draw. Reading the texture without
/// waiting reads whatever was there before the GPU got to it, which on a
/// freshly allocated texture is usually zeroes - so the failure looks like "the
/// clear colour was black" rather than "the readback raced the GPU". Every
/// pass here waits, because this is a test path where latency does not matter
/// and a race would be diagnosed as a colour bug.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../../../ffi/objc_runtime.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../framebuffer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_pipeline.dart';
import '../gpu_raster_sink.dart';
import '../gpu_vertex_buffer.dart';
import 'metal_bindings.dart';
import 'metal_device.dart';
import 'metal_shaders.dart';

/// A texture this framework renders into and then reads back.
final class MetalOffscreenTarget {
  MetalOffscreenTarget._(
    this._gpu,
    this._pipelines,
    this.texture,
    this._white,
    this.width,
    this.height,
    this.framebuffer,
    this._staging,
  );

  /// Allocates the colour texture and the readback buffer.
  ///
  /// The pixel format is [MtlPixelFormat.rgba8Unorm] and the [Framebuffer] is
  /// [PixelFormat.rgba8888Premultiplied], which is the same pair
  /// `D3d11OffscreenTarget` uses - so a parity failure cannot be a channel
  /// order difference in the comparison itself.
  ///
  /// [pipelines] is passed in rather than built here because a pipeline cache
  /// costs a shader compile and belongs to the device; a target is cheap and a
  /// test makes one per scene.
  static MetalOffscreenTarget create(
    MetalGpu gpu,
    MetalPipelineCache pipelines, {
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) {
      throw MetalError('an offscreen target needs a positive size, '
          'got ${width}x$height');
    }
    final Pointer<ObjCObject> texture = ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> cls = objcClass('MTLTextureDescriptor');
      if (cls == nullptr) {
        throw MetalError('the MTLTextureDescriptor class is not loaded');
      }
      final Pointer<ObjCObject> descriptor = metalSendPointer4(
        cls,
        'texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
        MtlPixelFormat.rgba8Unorm,
        width,
        height,
        0,
      );
      if (descriptor == nullptr) {
        throw MetalError('texture2DDescriptorWithPixelFormat:... returned nil');
      }
      // renderTarget because it is drawn into, shaderRead because a layer
      // target of the same kind is sampled afterwards - and a usage that does
      // not include renderTarget makes the render pass fail rather than the
      // texture creation, one step away from the mistake.
      metalSendVoid1(descriptor, 'setUsage:',
          MtlTextureUsage.renderTarget | MtlTextureUsage.shaderRead);
      metalSendVoid1(descriptor, 'setStorageMode:', MtlStorageMode.shared);
      final Pointer<ObjCObject> created = metalSendPointer1(
          gpu.device, 'newTextureWithDescriptor:', descriptor.address);
      if (created == nullptr) {
        throw MetalError('-[MTLDevice newTextureWithDescriptor:] returned nil '
            'for a ${width}x$height rgba8Unorm render target');
      }
      return created;
    });

    final Framebuffer framebuffer = Framebuffer.allocate(
      width: width,
      height: height,
      format: PixelFormat.rgba8888Premultiplied,
    );
    // getBytes: writes through a raw pointer, and a Dart typed list is not one:
    // its storage may move. So the readback lands in native memory and is
    // copied across, which is one memcpy per frame on a path that only exists
    // for tests.
    final Pointer<Uint8> staging =
        NativeAllocator.instance.allocate<Uint8>(width * height * 4);
    return MetalOffscreenTarget._(gpu, pipelines, texture,
        _createWhiteTexture(gpu), width, height, framebuffer, staging);
  }

  /// A 1x1 opaque white texture, bound whenever a batch names no texture.
  ///
  /// See [_drawBatches] for why an unbound texture argument is not an option.
  /// White and opaque so that a mode which *did* sample it by mistake would
  /// draw the colour unchanged rather than black - the failure would then show
  /// up in a scene with a texture in it, where it belongs, instead of turning
  /// every solid fill into a silhouette.
  static Pointer<ObjCObject> _createWhiteTexture(MetalGpu gpu) =>
      ObjCAutoreleasePool.run(() {
        final Pointer<ObjCObject> cls = objcClass('MTLTextureDescriptor');
        final Pointer<ObjCObject> descriptor = metalSendPointer4(
          cls,
          'texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
          MtlPixelFormat.rgba8Unorm,
          1,
          1,
          0,
        );
        metalSendVoid1(descriptor, 'setUsage:', MtlTextureUsage.shaderRead);
        metalSendVoid1(descriptor, 'setStorageMode:', MtlStorageMode.shared);
        final Pointer<ObjCObject> white = metalSendPointer1(
            gpu.device, 'newTextureWithDescriptor:', descriptor.address);
        if (white == nullptr) {
          throw MetalError('the 1x1 white texture could not be created');
        }
        final Pointer<Uint8> texel =
            NativeAllocator.instance.allocate<Uint8>(4);
        try {
          texel.asTypedList(4).fillRange(0, 4, 0xFF);
          metalSendReplaceRegion(
            white,
            'replaceRegion:mipmapLevel:withBytes:bytesPerRow:',
            mtlRegion2D(x: 0, y: 0, width: 1, height: 1),
            0,
            texel.cast<Void>(),
            4,
          );
        } finally {
          NativeAllocator.instance.free(texel);
        }
        return white;
      });

  final MetalGpu _gpu;
  final MetalPipelineCache _pipelines;

  /// The 1x1 white texture, **+1**.
  final Pointer<ObjCObject> _white;

  /// The colour texture, **+1**.
  final Pointer<ObjCObject> texture;

  final int width;
  final int height;

  /// Where [readPixels] leaves the result.
  final Framebuffer framebuffer;

  final Pointer<Uint8> _staging;

  bool _disposed = false;

  /// Runs a pass that only clears, and waits for it.
  ///
  /// [premultipliedArgb] is packed the way `FrameRequest.clearColor` documents
  /// it - alpha in the top byte, then red, green, blue, all **premultiplied**.
  /// The four components are divided by 255 and handed to `setClearColor:`
  /// unchanged, which is exactly what `d3d11_backend.dart` does with
  /// `ClearRenderTargetView`: the value is written into the attachment as
  /// given, so converting out of premultiplied here would produce a surface
  /// that differs from every other backend by the alpha it was drawn with.
  void clear(int premultipliedArgb) {
    _encodePass(clearColor: premultipliedArgb, body: null);
  }

  /// Encodes one render pass into this target's texture.
  ///
  /// [body] receives the `id<MTLRenderCommandEncoder>` and may issue draws;
  /// null means the pass exists only for its load action, which is what
  /// [clear] wants. The pass always stores - `MTLStoreActionDontCare` on a
  /// texture that is about to be read is the mistake `metal_bindings.dart`'s
  /// library comment records the POC making, and it does not fail, it just
  /// discards.
  void encodePass({
    int? clearColor,
    void Function(Pointer<ObjCObject> encoder)? body,
  }) =>
      _encodePass(clearColor: clearColor, body: body);

  void _encodePass({
    required int? clearColor,
    required void Function(Pointer<ObjCObject> encoder)? body,
  }) {
    _checkAlive();
    ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> passClass =
          objcClass('MTLRenderPassDescriptor');
      if (passClass == nullptr) {
        throw MetalError('the MTLRenderPassDescriptor class is not loaded');
      }
      final Pointer<ObjCObject> pass =
          metalSendPointer(passClass, 'renderPassDescriptor');
      final Pointer<ObjCObject> attachment = metalSendPointer1(
          metalSendPointer(pass, 'colorAttachments'),
          'objectAtIndexedSubscript:',
          0);
      if (attachment == nullptr) {
        throw MetalError('colorAttachments[0] is nil on a render pass '
            'descriptor');
      }
      metalSendVoid1(attachment, 'setTexture:', texture.address);
      metalSendVoid1(
        attachment,
        'setLoadAction:',
        clearColor == null ? MtlLoadAction.load : MtlLoadAction.clear,
      );
      metalSendVoid1(attachment, 'setStoreAction:', MtlStoreAction.store);
      if (clearColor != null) {
        metalSendDouble4(
            attachment, 'setClearColor:', metalClearColor(clearColor));
      }

      final Pointer<ObjCObject> commandBuffer =
          metalSendPointer(_gpu.commandQueue, 'commandBuffer');
      if (commandBuffer == nullptr) {
        throw MetalError('-[MTLCommandQueue commandBuffer] returned nil');
      }
      final Pointer<ObjCObject> encoder = metalSendPointer1(
          commandBuffer, 'renderCommandEncoderWithDescriptor:', pass.address);
      if (encoder == nullptr) {
        throw MetalError(
          'renderCommandEncoderWithDescriptor: returned nil',
          detail: 'the pass descriptor was rejected - the usual cause is an '
              'attachment whose texture was not created with '
              'MTLTextureUsageRenderTarget',
        );
      }
      if (body != null) body(encoder);
      metalSendVoid(encoder, 'endEncoding');
      metalSendVoid(commandBuffer, 'commit');
      metalSendVoid(commandBuffer, 'waitUntilCompleted');

      final int status = metalSendUnsigned(commandBuffer, 'status');
      if (status != MtlCommandBufferStatus.completed) {
        throw MetalError(
          'the command buffer ended in status $status rather than '
          '${MtlCommandBufferStatus.completed} (completed)',
          detail:
              metalErrorDescription(metalSendPointer(commandBuffer, 'error')) ??
                  'no NSError was attached',
        );
      }
    });
  }

  /// Copies the texture into [framebuffer].
  ///
  /// Returns the same [Framebuffer] every time; it is overwritten, not
  /// reallocated.
  Framebuffer readPixels() {
    _checkAlive();
    final int bytesPerRow = width * 4;
    metalSendGetBytes(
      texture,
      'getBytes:bytesPerRow:fromRegion:mipmapLevel:',
      _staging.cast<Void>(),
      bytesPerRow,
      mtlRegion2D(x: 0, y: 0, width: width, height: height),
      0,
    );
    final Uint8List source = _staging.asTypedList(bytesPerRow * height);
    framebuffer.pixels.setRange(0, source.length, source);
    return framebuffer;
  }

  // -------------------------------------------------------------------
  // Drawing a display list
  // -------------------------------------------------------------------

  /// Rasterises [list] into this target, clearing to [clearColor] first.
  ///
  /// The same path the other GPU backends take, and deliberately not a
  /// shortcut: `DisplayListPlayer` walks the list, [GpuRasterSink] turns
  /// primitives into quads and batches, and this method turns batches into
  /// draw calls. A test that assembled vertices by hand would compare this
  /// backend's shader against the test author's idea of the layout rather than
  /// against the layout every other backend uses.
  ///
  /// **Rectangles and images only.** The sink is built without a mask atlas, a
  /// glyph atlas or a layer stack, so a path, a rounded rectangle, a glyph run
  /// or a compositing `saveLayer` raises `UnsupportedCapabilityError` naming
  /// this backend instead of drawing something approximate. That is section
  /// 6.6 applied to a backend that is being built a piece at a time.
  void renderDisplayList(DisplayList list, {int? clearColor}) {
    beginFrame();
    playDisplayList(list);
    submit(clearColor: clearColor);
  }

  /// Drops the previous frame's geometry, keeping the memory.
  ///
  /// Split out of [renderDisplayList] because a [RenderTarget] has to record
  /// between `beginFrame` and `present` rather than in one call - see
  /// `MetalMemoryTarget` in `metal_backend.dart`.
  void beginFrame() {
    _checkAlive();
    _batcher.beginFrame();
  }

  /// Walks [list] into the batcher. No GPU work happens here.
  void playDisplayList(DisplayList list) {
    _checkAlive();
    _player.play(
      DisplayListReader(list),
      DisplayListResources(list),
      deviceBounds: Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
  }

  /// Encodes the recorded batches into one pass and waits for it.
  void submit({int? clearColor}) {
    _checkAlive();
    encodePass(clearColor: clearColor, body: _drawBatches);
  }

  late final GpuBatcher _batcher = GpuBatcher();
  late final GpuRasterSink _sink = GpuRasterSink(
    batcher: _batcher,
    backendName: 'metal',
  );
  late final DisplayListPlayer _player = DisplayListPlayer(_sink);

  /// The uniform block, filled once per state change and handed to
  /// `setVertexBytes:` / `setFragmentBytes:`.
  ///
  /// Native memory rather than a Dart list because both selectors take a
  /// pointer, and 20 bytes is under the 4 kB `setVertexBytes:` is documented
  /// to accept - which is why there is no `MTLBuffer` for constants.
  late final Pointer<MetalUniforms> _uniforms =
      NativeAllocator.instance.allocate<MetalUniforms>(sizeOf<MetalUniforms>());

  void _drawBatches(Pointer<ObjCObject> encoder) {
    final int batchCount = _batcher.batchCount;
    if (batchCount == 0) return;

    final GpuVertexBuffer buffer = _batcher.buffer;
    final Pointer<ObjCObject> vertexBuffer =
        _newBuffer(buffer.vertices.buffer.asUint8List(
      0,
      buffer.vertexCount * kGpuFloatsPerVertex * 4,
    ));
    final Pointer<ObjCObject> indexBuffer =
        _newBuffer(buffer.indices.buffer.asUint8List(0, buffer.indexCount * 4));
    try {
      // Both faces are drawn. GpuVertexBuffer emits quads clockwise in a y-down
      // device space, which is counter-clockwise after the shader's flip; the
      // renderer is 2D and has no back faces, so culling could only turn a sign
      // error into invisible geometry.
      metalSendVoid1(encoder, 'setCullMode:', MtlCullMode.none);
      metalSendDouble6(
        encoder,
        'setViewport:',
        mtlViewport(
          originX: 0,
          originY: 0,
          width: width.toDouble(),
          height: height.toDouble(),
        ),
      );
      metalSendVoid3(encoder, 'setVertexBuffer:offset:atIndex:',
          vertexBuffer.address, 0, kMetalVertexBufferIndex);

      var boundBlend = -1;
      var boundMode = -1;
      for (var i = 0; i < batchCount; i++) {
        final GpuBatch batch = _batcher.batchAt(i);
        var left = batch.scissorLeft;
        var top = batch.scissorTop;
        var right = batch.scissorRight;
        var bottom = batch.scissorBottom;
        if (left < 0) left = 0;
        if (top < 0) top = 0;
        if (right > width) right = width;
        if (bottom > height) bottom = height;
        if (right <= left || bottom <= top) continue;

        // No y flip. Metal's scissor origin is the top-left corner of the
        // render target, which is device space's origin; GL needs
        // `height - bottom` here only because its origin is at the bottom.
        metalSendWord4(
          encoder,
          'setScissorRect:',
          mtlScissorRect(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
          ),
        );

        if (batch.blendMode != boundBlend) {
          boundBlend = batch.blendMode;
          metalSendVoid1(encoder, 'setRenderPipelineState:',
              _pipelines.forBlendMode(batch.blendMode).address);
        }

        final int mode = metalPipelineMode(batch.pipeline);
        if (mode != boundMode) {
          boundMode = mode;
          _uniforms.ref
            ..viewportWidth = width.toDouble()
            ..viewportHeight = height.toDouble()
            ..mode = mode
            ..yFlip = kMetalYFlipDefault
            ..useLinear = kMetalSamplerPoint;
          metalSendVoid3(
              encoder,
              'setVertexBytes:length:atIndex:',
              _uniforms.address,
              sizeOf<MetalUniforms>(),
              kMetalUniformBufferIndex);
          metalSendVoid3(
              encoder,
              'setFragmentBytes:length:atIndex:',
              _uniforms.address,
              sizeOf<MetalUniforms>(),
              kMetalUniformBufferIndex);
        }

        // Always a texture, even for a solid fill. The fragment function
        // samples `tex` unconditionally - it selects between a point tap and a
        // linear one and then ignores both in mode 0 - and Metal does not
        // define what an unbound texture argument reads. A 1x1 opaque white
        // texel costs one binding and removes the question; the alternative is
        // a shader branch that the other two backends do not have, which would
        // make a parity difference mean something else.
        metalSendVoid2(
            encoder, 'setFragmentTexture:atIndex:', _white.address, 0);

        metalSendVoid5(
          encoder,
          'drawIndexedPrimitives:indexCount:indexType:indexBuffer:'
          'indexBufferOffset:',
          MtlPrimitiveType.triangle,
          batch.indexCount,
          MtlIndexType.uint32,
          indexBuffer.address,
          batch.indexOffset * 4,
        );
      }
    } finally {
      // The pass is waited on before these are released - see the library
      // comment - so releasing here cannot pull a buffer out from under the
      // GPU. It is the reason this file waits at all.
      objcRelease(indexBuffer);
      objcRelease(vertexBuffer);
    }
  }

  /// An `MTLBuffer` holding a copy of [bytes], **+1**.
  ///
  /// `newBufferWithBytes:length:options:` copies, so the scratch native buffer
  /// is freed immediately and the Dart list is never pinned.
  Pointer<ObjCObject> _newBuffer(Uint8List bytes) {
    final Pointer<Uint8> scratch =
        NativeAllocator.instance.allocate<Uint8>(bytes.length);
    try {
      scratch.asTypedList(bytes.length).setRange(0, bytes.length, bytes);
      final Pointer<ObjCObject> buffer = metalSendPointer3(
        _gpu.device,
        'newBufferWithBytes:length:options:',
        scratch.address,
        bytes.length,
        MtlResourceOptions.storageModeShared,
      );
      if (buffer == nullptr) {
        throw MetalError('newBufferWithBytes:length:options: returned nil for '
            '${bytes.length} bytes');
      }
      return buffer;
    } finally {
      NativeAllocator.instance.free(scratch);
    }
  }

  void _checkAlive() {
    if (_disposed) throw MetalError('this MetalOffscreenTarget was disposed');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    NativeAllocator.instance.free(_uniforms);
    NativeAllocator.instance.free(_staging);
    objcRelease(_white);
    objcRelease(texture);
    // The pipeline cache is the caller's; a target that disposed it would
    // invalidate every other target built from the same device.
  }
}

/// An `MTLClearColor` from a premultiplied ARGB integer.
///
/// See [MetalOffscreenTarget.clear] for why the components are not
/// un-premultiplied on the way through.
ObjCDouble4 metalClearColor(int premultipliedArgb) => mtlClearColor(
      ((premultipliedArgb >> 16) & 0xFF) / 255.0,
      ((premultipliedArgb >> 8) & 0xFF) / 255.0,
      (premultipliedArgb & 0xFF) / 255.0,
      ((premultipliedArgb >> 24) & 0xFF) / 255.0,
    );
