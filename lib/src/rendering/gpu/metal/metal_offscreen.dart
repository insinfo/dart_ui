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
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../framebuffer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_layer_stack.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_pipeline.dart';
import '../gpu_raster_sink.dart';
import '../gpu_texture.dart';
import '../gpu_vertex_buffer.dart';
import 'metal_bindings.dart';
import 'metal_device.dart';
import 'metal_shaders.dart';
import 'metal_textures.dart';

/// A texture this framework renders into and then reads back.
final class MetalOffscreenTarget {
  MetalOffscreenTarget._(
    this._gpu,
    this._pipelines,
    this.texture,
    this._white,
    this.width,
    this.height,
    this._framebuffer,
    this._staging, {
    required bool ownsTexture,
  }) : _ownsTexture = ownsTexture;

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
        _createWhiteTexture(gpu), width, height, framebuffer, staging,
        ownsTexture: true);
  }

  /// A target that draws into a texture **somebody else owns**.
  ///
  /// The window path of ADR 0005: the colour texture is an `IOSurface` from
  /// `surface_pool.dart` wrapped with
  /// `newTextureWithDescriptor:iosurface:plane:`, so the pages this draws into
  /// are the pages the host scans out. Three things differ from [create] and
  /// each is a decision:
  ///
  ///   * **the texture is not released here.** It belongs to the caller, whose
  ///     pool outlives any one target; disposing it from a target would free a
  ///     surface the compositor is still showing;
  ///   * **there is no [Framebuffer] and no staging buffer.** A window target
  ///     that allocated both would cost two full-resolution copies per window
  ///     - 16 MB at 1080p - for a readback that never happens. [cpuPixels] is
  ///     null and [readPixels] says so by name;
  ///   * **the pixel format is the caller's**, not `rgba8Unorm`. An IOSurface
  ///     from this repository's pool is `BGRA`, and a pipeline state's
  ///     attachment format is part of its identity in Metal - so [pipelines]
  ///     must have been built for the format the texture actually has or every
  ///     draw is rejected at encode time.
  static MetalOffscreenTarget overTexture(
    MetalGpu gpu,
    MetalPipelineCache pipelines, {
    required Pointer<ObjCObject> texture,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) {
      throw MetalError('a target needs a positive size, got ${width}x$height');
    }
    if (texture == nullptr) {
      throw MetalError('overTexture was given a nil texture');
    }
    return MetalOffscreenTarget._(gpu, pipelines, texture,
        _createWhiteTexture(gpu), width, height, null, null,
        ownsTexture: false);
  }

  /// A 1x1 opaque white texture, bound whenever a batch names no texture.
  ///
  /// See [_drawRange] for why an unbound texture argument is not an option.
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

  /// Whether [dispose] releases [texture]. False for [overTexture].
  final bool _ownsTexture;

  /// Where [readPixels] leaves the result, or null on a target that draws
  /// into somebody else's texture. See [overTexture].
  final Framebuffer? _framebuffer;

  /// The CPU-visible pixels, or null when this target has none.
  ///
  /// Mirrors `Frame.cpuPixels`: a window target genuinely has no readback
  /// buffer, and a 1x1 placeholder would be a lie in the type.
  Framebuffer? get cpuPixels => _framebuffer;

  /// The readback buffer, or a named failure when there is none.
  Framebuffer get framebuffer {
    final Framebuffer? pixels = _framebuffer;
    if (pixels != null) return pixels;
    throw MetalError(
      'this target draws into a texture it does not own and has no readback '
      'buffer: it was built by MetalOffscreenTarget.overTexture, which is the '
      'window path of ADR 0005. Read the pixels through the IOSurface the '
      'caller owns instead',
    );
  }

  final Pointer<Uint8>? _staging;

  bool _disposed = false;

  /// The vertex and index buffers of the last pass, released by the next one.
  ///
  /// Not at the end of their own pass, because the command buffer retains
  /// what it encodes and drops it on Metal's completion thread - and the last
  /// release of an `MTLBuffer` autoreleases the device
  /// (`-[IOGPUMetalResource dealloc]`) on whichever thread performs it. Metal's
  /// completion thread has no pool to catch that, so releasing at the end of
  /// the pass leaked one device reference per buffer: two per frame, counted
  /// by `OBJC_DEBUG_MISSING_POOLS` in `tool/metal_window_present_probe.dart`.
  /// One pass later the command buffer has long let go, so the release below
  /// is the last one and lands in the pass's own pool.
  final List<Pointer<ObjCObject>> _retiredBuffers = <Pointer<ObjCObject>>[];

  void _releaseRetiredBuffers() {
    for (final Pointer<ObjCObject> buffer in _retiredBuffers) {
      objcRelease(buffer);
    }
    _retiredBuffers.clear();
  }

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
    Pointer<ObjCObject>? depthTexture,
    void Function(Pointer<ObjCObject> encoder)? body,
    Pointer<ObjCObject>? completedHandler,
  }) =>
      _encodePass(
        clearColor: clearColor,
        depthTexture: depthTexture,
        body: body,
        completedHandler: completedHandler,
      );

  void _encodePass({
    required int? clearColor,
    Pointer<ObjCObject>? depthTexture,
    required void Function(Pointer<ObjCObject> encoder)? body,
    Pointer<ObjCObject>? completedHandler,
  }) {
    _checkAlive();
    ObjCAutoreleasePool.run(() {
      _releaseRetiredBuffers();
      final Pointer<ObjCObject> commandBuffer = _newCommandBuffer();
      final Pointer<ObjCObject> encoder = _renderEncoder(
        commandBuffer,
        texture,
        clearArgb: clearColor,
        depthTexture: depthTexture,
      );
      if (body != null) body(encoder);
      metalSendVoid(encoder, 'endEncoding');
      _finishCommandBuffer(commandBuffer, completedHandler);
    });
  }

  Pointer<ObjCObject> _newCommandBuffer() {
    final Pointer<ObjCObject> commandBuffer =
        metalSendPointer(_gpu.commandQueue, 'commandBuffer');
    if (commandBuffer == nullptr) {
      throw MetalError('-[MTLCommandQueue commandBuffer] returned nil');
    }
    return commandBuffer;
  }

  /// One render pass into [target]: cleared to [clearArgb], or to transparent
  /// when [clearTransparent], or loaded as it is.
  Pointer<ObjCObject> _renderEncoder(
    Pointer<ObjCObject> commandBuffer,
    Pointer<ObjCObject> target, {
    int? clearArgb,
    bool clearTransparent = false,
    Pointer<ObjCObject>? depthTexture,
  }) {
    final Pointer<ObjCObject> passClass = objcClass('MTLRenderPassDescriptor');
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
    final bool clears = clearArgb != null || clearTransparent;
    metalSendVoid1(attachment, 'setTexture:', target.address);
    metalSendVoid1(
      attachment,
      'setLoadAction:',
      clears ? MtlLoadAction.clear : MtlLoadAction.load,
    );
    metalSendVoid1(attachment, 'setStoreAction:', MtlStoreAction.store);
    if (clears) {
      metalSendDouble4(
          attachment, 'setClearColor:', metalClearColor(clearArgb ?? 0));
    }
    if (depthTexture != null) {
      final Pointer<ObjCObject> depth =
          metalSendPointer(pass, 'depthAttachment');
      metalSendVoid1(depth, 'setTexture:', depthTexture.address);
      metalSendVoid1(depth, 'setLoadAction:', MtlLoadAction.clear);
      metalSendVoid1(depth, 'setStoreAction:', MtlStoreAction.dontCare);
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
    return encoder;
  }

  void _finishCommandBuffer(
    Pointer<ObjCObject> commandBuffer,
    Pointer<ObjCObject>? completedHandler,
  ) {
    if (completedHandler != null) {
      // Installed before commit, never after: a handler added to a buffer
      // that has already completed is not guaranteed to run, and this one
      // is what tells the presenter the IOSurface is finished. Measured at
      // 6.7 ms end to end in run 34165428755.
      metalSendVoid1(
          commandBuffer, 'addCompletedHandler:', completedHandler.address);
      metalSendVoid(commandBuffer, 'commit');
      // No waitUntilCompleted and no status read. `commit` only enqueues, so
      // `status` here would be `committed` and asserting `completed` would
      // fail every frame - the handler is what observes the outcome, which
      // is the whole reason a caller asked for one.
      return;
    }

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
  }

  /// The batches recorded since the last pass, in one command buffer: one
  /// render pass per [GpuRenderPass] of the layer stack - the surface, or a
  /// layer's own texture - as `submit` walks them on Direct3D 11.
  ///
  /// The surface is cleared to the frame's colour the first time a pass of
  /// this frame touches it, and never again: a surface pass that resumes after
  /// a layer has to keep what the earlier one drew. A layer's texture is
  /// cleared to transparent where its pass begins, and only there, so a pass
  /// split by a mid-frame flush does not lose its first half.
  void _encodeFrame({Pointer<ObjCObject>? completedHandler}) {
    _checkAlive();
    ObjCAutoreleasePool.run(() {
      _releaseRetiredBuffers();
      final int first = _submittedBatches;
      final int count = _batcher.batchCount;
      Pointer<ObjCObject>? vertexBuffer;
      Pointer<ObjCObject>? indexBuffer;
      if (count > first) {
        final GpuVertexBuffer buffer = _batcher.buffer;
        vertexBuffer = _newBuffer(buffer.vertices.buffer.asUint8List(
          0,
          buffer.vertexCount * kGpuFloatsPerVertex * 4,
        ));
        indexBuffer = _newBuffer(
            buffer.indices.buffer.asUint8List(0, buffer.indexCount * 4));
        // Handed to the next pass rather than released here; see
        // [_retiredBuffers]. The command buffer holds its own reference until
        // the GPU is done, so this cannot pull one out from under it.
        _retiredBuffers
          ..add(indexBuffer)
          ..add(vertexBuffer);
      }
      final Pointer<ObjCObject> commandBuffer = _newCommandBuffer();

      void segment(
        Pointer<ObjCObject> target, {
        required int from,
        required int to,
        required int viewportWidth,
        required int viewportHeight,
        int? clearArgb,
        bool clearTransparent = false,
      }) {
        final Pointer<ObjCObject> encoder = _renderEncoder(
          commandBuffer,
          target,
          clearArgb: clearArgb,
          clearTransparent: clearTransparent,
        );
        if (to > from) {
          _drawRange(encoder, from, to, viewportWidth, viewportHeight,
              vertexBuffer!, indexBuffer!);
        }
        metalSendVoid(encoder, 'endEncoding');
      }

      int? surfaceClear() {
        if (_surfaceTouched) return null;
        _surfaceTouched = true;
        return _frameClear;
      }

      final int passCount = _layers.passCount;
      if (passCount == 0) {
        final int? clear = surfaceClear();
        if (count > first || clear != null) {
          segment(texture,
              from: first,
              to: count,
              viewportWidth: width,
              viewportHeight: height,
              clearArgb: clear);
        }
      } else {
        for (var p = 0; p < passCount; p++) {
          final GpuRenderPass pass = _layers.passAt(p);
          final int end = _layers.passEnd(p, count);
          final int start = pass.firstBatch < first ? first : pass.firstBatch;
          final GpuLayerTarget? target = pass.target;
          if (target == null) {
            // A surface pass with nothing left to draw still has to be
            // encoded while the frame's clear is pending - a frame that only
            // clears is a frame.
            final bool clearPending = !_surfaceTouched && _frameClear != null;
            if (end <= start && !clearPending) continue;
            final int? clear = surfaceClear();
            segment(texture,
                from: start,
                to: end,
                viewportWidth: pass.viewportWidth,
                viewportHeight: pass.viewportHeight,
                clearArgb: clear);
          } else {
            // Drawn by an earlier pass of this frame - a mid-frame flush.
            if (end <= first) continue;
            final bool clears = pass.clearsTarget && start == pass.firstBatch;
            if (end <= start && !clears) continue;
            segment((target as MetalLayerTarget).texture.pointer,
                from: start,
                to: end,
                viewportWidth: pass.viewportWidth,
                viewportHeight: pass.viewportHeight,
                clearTransparent: clears);
          }
        }
      }
      _finishCommandBuffer(commandBuffer, completedHandler);
    });
  }

  /// Copies the texture into [framebuffer].
  ///
  /// Returns the same [Framebuffer] every time; it is overwritten, not
  /// reallocated.
  Framebuffer readPixels() {
    _checkAlive();
    final Pointer<Uint8>? staging = _staging;
    final Framebuffer? destination = _framebuffer;
    if (staging == nullptr || staging == null || destination == null) {
      throw MetalError(
        'readPixels on a target built by MetalOffscreenTarget.overTexture: it '
        'has no staging buffer because a window target never reads its own '
        'back buffer back. The pixels are in the IOSurface the caller owns',
      );
    }
    final int bytesPerRow = width * 4;
    metalSendGetBytes(
      texture,
      'getBytes:bytesPerRow:fromRegion:mipmapLevel:',
      staging.cast<Void>(),
      bytesPerRow,
      mtlRegion2D(x: 0, y: 0, width: width, height: height),
      0,
    );
    final Uint8List source = staging.asTypedList(bytesPerRow * height);
    destination.pixels.setRange(0, source.length, source);
    return destination;
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
  /// Text, images, paths and rounded rectangles go through the atlases and the
  /// image cache of `metal_textures.dart`, and a compositing `saveLayer`
  /// through its own pass into a pooled texture (see [_encodeFrame]). A
  /// gradient raises `UnsupportedCapabilityError` naming this backend, as on
  /// every dense GPU path without the sparse-strip executor.
  void renderDisplayList(DisplayList list, {int? clearColor}) {
    beginFrame(clearColor: clearColor);
    playDisplayList(list);
    submit(clearColor: clearColor);
  }

  /// Drops the previous frame's geometry, keeping the memory.
  ///
  /// Split out of [renderDisplayList] because a [RenderTarget] has to record
  /// between `beginFrame` and `present` rather than in one call - see
  /// `MetalMemoryTarget` in `metal_backend.dart`.
  ///
  /// [clearColor] is the frame's clear, applied by its first pass. It belongs
  /// here and not only in [submit] because a frame can issue a pass before
  /// [submit]: an atlas that fills up mid-frame flushes the batches recorded
  /// so far (`onAtlasFlush`), and that pass is the one that has to clear.
  void beginFrame({int? clearColor}) {
    _checkAlive();
    _batcher.beginFrame();
    _frameClear = clearColor;
    _submittedBatches = 0;
    _surfaceTouched = false;
    _layers.beginFrame(surfaceWidth: width, surfaceHeight: height);
  }

  int? _frameClear;

  /// Batches already drawn by a pass this frame; the next pass starts here.
  int _submittedBatches = 0;

  /// Whether a pass of this frame has rendered into the surface. Only the
  /// first one clears it.
  bool _surfaceTouched = false;

  /// Walks [list] into the batcher. No GPU work happens here.
  void playDisplayList(
    DisplayList list, {
    Transform2D deviceTransform = Transform2D.identity,
  }) {
    _checkAlive();
    // The font resolver is the device's and shared by every target on it, so
    // it is pointed at this list's fonts right before this list replays.
    _store.fontResolver.bind(DisplayListResources(list));
    _player.play(
      DisplayListReader(list),
      DisplayListResources(list),
      deviceBounds: Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      // Passed through rather than dropped: a window target is handed one by
      // the presenter when the surface and the layout disagree about scale,
      // and silently ignoring it would draw every frame at 1x on a display
      // that is not.
      deviceTransform: deviceTransform,
    );
  }

  /// Encodes the recorded batches into one pass and waits for it.
  ///
  /// [clearColor], when given, overrides the one [beginFrame] recorded; either
  /// is applied only if no pass has run yet this frame.
  void submit({int? clearColor, Pointer<ObjCObject>? completedHandler}) {
    _checkAlive();
    if (clearColor != null && !_surfaceTouched) _frameClear = clearColor;
    _uploadAtlases();
    _encodeFrame(completedHandler: completedHandler);
    _submittedBatches = _batcher.batchCount;
    // The layer targets go back to the pool here, after the composite quads
    // that sample them are encoded; a later frame rendering into one is
    // ordered after this one by the queue and Metal's hazard tracking.
    _layers.endFrame();
  }

  /// `onAtlasFlush`: an atlas filled up mid-frame. Uploads both, draws the
  /// batches recorded so far and **waits** - the sink recycles the full atlas
  /// as soon as this returns, and those texels must not be overwritten while
  /// a pass still samples them.
  void _flushMidFrame() {
    _uploadAtlases();
    _encodeFrame();
    _submittedBatches = _batcher.batchCount;
  }

  void _uploadAtlases() {
    final GpuMaskAtlas mask = _maskAtlas;
    if (mask.isDirty) {
      final int top = mask.dirtyTop;
      final int rows = mask.dirtyBottom - top;
      _store.upload(
        _maskTexture,
        x: 0,
        y: top,
        width: mask.width,
        height: rows,
        pixels: Uint8List.sublistView(mask.pixels, top * mask.width),
        bytesPerRow: mask.width,
      );
      mask.markUploaded();
    }
    _store.uploadGlyphAtlas();
  }

  /// This device's textures, glyph atlas, image cache and font resolver.
  late final MetalTextureStore _store = MetalTextureStore.of(_gpu);

  /// Coverage masks for paths and rounded shapes, per target as on D3D11.
  final GpuMaskAtlas _maskAtlas = GpuMaskAtlas();

  MetalTexture? _maskTextureOrNull;
  MetalTexture get _maskTexture => _maskTextureOrNull ??= _store.create(
        width: _maskAtlas.width,
        height: _maskAtlas.height,
        format: GpuTextureFormat.alpha8,
        filter: GpuTextureFilter.nearest,
      );

  late final MetalLayerAllocator _layerAllocator =
      MetalLayerAllocator(_store, _pipelines.pixelFormat);

  /// Where a compositing `saveLayer` gets its own pass and texture. See
  /// [_encodeFrame].
  late final GpuLayerStack _layers =
      GpuLayerStack(allocator: _layerAllocator, backendName: 'metal');

  late final GpuBatcher _batcher = GpuBatcher();
  late final GpuRasterSink _sink = GpuRasterSink(
    batcher: _batcher,
    backendName: 'metal',
    maskAtlas: _maskAtlas,
    maskTextureId: _maskTexture.id,
    glyphAtlas: _store.glyphAtlas,
    glyphTextureId: _store.glyphTexture.id,
    imageResolver: _store.imageCache,
    fontResolver: _store.fontResolver,
    onAtlasFlush: _flushMidFrame,
    layerStack: _layers,
    // Uniform-radius rounded rectangles through the shader's closed form, as
    // on D3D11, Vulkan and GL: the coverage atlas is a different
    // approximation, and against the CPU it was 52 levels apart on the edges.
    analyticPrimitives: true,
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

  /// Draws batches [firstBatch] to [batchCount] into the pass [encoder] is
  /// recording, whose target is [viewportWidth] x [viewportHeight] - the
  /// surface, or a layer's texture at the layer's own size.
  void _drawRange(
    Pointer<ObjCObject> encoder,
    int firstBatch,
    int batchCount,
    int viewportWidth,
    int viewportHeight,
    Pointer<ObjCObject> vertexBuffer,
    Pointer<ObjCObject> indexBuffer,
  ) {
    {
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
          width: viewportWidth.toDouble(),
          height: viewportHeight.toDouble(),
        ),
      );
      metalSendVoid3(encoder, 'setVertexBuffer:offset:atIndex:',
          vertexBuffer.address, 0, kMetalVertexBufferIndex);

      var boundBlend = -1;
      var boundMode = -1;
      var boundLinear = -1;
      var boundTexture = -1;
      for (var i = firstBatch; i < batchCount; i++) {
        final GpuBatch batch = _batcher.batchAt(i);
        var left = batch.scissorLeft;
        var top = batch.scissorTop;
        var right = batch.scissorRight;
        var bottom = batch.scissorBottom;
        if (left < 0) left = 0;
        if (top < 0) top = 0;
        if (right > viewportWidth) right = viewportWidth;
        if (bottom > viewportHeight) bottom = viewportHeight;
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

        // The batch's texture - a glyph or coverage atlas, or an image - and
        // the sampler its filter asks for. kNoTexture and anything released
        // bind the white texel; see below.
        final MetalTexture? texture = _store.byId(batch.textureId);
        final int linear = texture?.filter == GpuTextureFilter.linear
            ? kMetalSamplerLinear
            : kMetalSamplerPoint;
        final int mode = metalPipelineMode(batch.pipeline);
        if (mode != boundMode || linear != boundLinear) {
          boundMode = mode;
          boundLinear = linear;
          _uniforms.ref
            ..viewportWidth = viewportWidth.toDouble()
            ..viewportHeight = viewportHeight.toDouble()
            ..mode = mode
            ..yFlip = kMetalYFlipDefault
            ..useLinear = linear;
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
        final int textureId = texture?.id ?? kNoTexture;
        if (textureId != boundTexture) {
          boundTexture = textureId;
          metalSendVoid2(encoder, 'setFragmentTexture:atIndex:',
              (texture?.pointer ?? _white).address, 0);
        }

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
    final Pointer<Uint8>? staging = _staging;
    if (staging != null) NativeAllocator.instance.free(staging);
    // In a pool because freeing a texture autoreleases: `-[IOGPUMetalResource
    // dealloc]` hands its device to `autorelease`, and with no pool on the
    // thread that is one leaked `MTLDevice` reference per target disposed.
    // Caught by `OBJC_DEBUG_MISSING_POOLS` on the framework's macOS leg.
    final MetalTexture? mask = _maskTextureOrNull;
    if (mask != null) _store.release(mask);
    _layerAllocator.dispose();
    ObjCAutoreleasePool.run(() {
      _releaseRetiredBuffers();
      objcRelease(_white);
      // Never for an overTexture target: the IOSurface-backed texture belongs
      // to the pool, which outlives every target built over it, and releasing
      // it here would free a surface the host may still be showing.
      if (_ownsTexture) objcRelease(texture);
    });
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
