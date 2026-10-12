/// Textures for the Metal batch renderer: ids, the glyph atlas, images.
///
/// `GpuRasterSink` names textures by an integer id and leaves what an id *is*
/// to the backend. This file is that half for Metal, built the way the
/// Direct3D 11 backend builds it (`d3d11_backend.dart`), because the three
/// GPU backends are compared pixel for pixel and a texture that came out of
/// a different recipe on one of them would show up as a parity difference
/// with no obvious cause:
///
///   * **one store per device** ([MetalTextureStore.of]), so every target on
///     an `MTLDevice` - the slots of a window, a popup, an offscreen test
///     target - shares the glyph atlas and the image textures, as D3D11's
///     device does. A menu does not rasterise again every glyph its owner
///     already uploaded;
///   * the **glyph atlas** and the **coverage atlas** are `R8Unorm`, sampled as
///     `.r` by `fsMain`'s coverage mode; images are `RGBA8Unorm` or
///     `BGRA8Unorm` by the framebuffer's own order, so nothing is swizzled on
///     the CPU - Metal samples both orders as RGBA;
///   * uploads are `replaceRegion:` into `shared` storage, with no blit
///     encoder: on Apple Silicon the texture is the memory.
///
/// ## A hazard Direct3D does not have
///
/// `UpdateSubresource` is ordered against the GPU's use of the texture by the
/// driver; `replaceRegion:` into shared storage is not. An upload is safe when
/// no command buffer still reading the same texels is in flight. The offscreen
/// path waits on every pass, so it always is. The window path does not wait,
/// and relies on what the atlases write: new glyphs and masks go to texels no
/// earlier frame sampled, and the one write that reuses texels - a full atlas
/// recycled mid-frame - happens after a pass this file's caller waited for.
/// A video stream reuses one texture and rewrites it every frame, and that is
/// safe for the same reason: a window's `present` awaits the GPU before the
/// next frame begins, so no earlier frame is still sampling it.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../../../ffi/objc_runtime.dart';
import '../../../graphics/image/decoded_image.dart';
import '../../framebuffer.dart';
import '../gpu_glyph_atlas.dart';
import '../gpu_layer_stack.dart';
import '../gpu_raster_sink.dart';
import '../gpu_texture.dart';
import '../gpu_video_image.dart';
import 'metal_bindings.dart';
import 'metal_device.dart';

/// One `MTLTexture` with the id `GpuRasterSink` knows it by.
final class MetalTexture implements GpuTextureHandle {
  MetalTexture._(
    this.id,
    this.pointer,
    this.width,
    this.height,
    this.format,
    this.filter,
  );

  @override
  final int id;

  /// The `id<MTLTexture>`, **+1**, released by [MetalTextureStore.release].
  final Pointer<ObjCObject> pointer;

  @override
  final int width;

  @override
  final int height;

  @override
  final GpuTextureFormat format;

  @override
  final GpuTextureFilter filter;

  bool _valid = true;

  @override
  bool get isValid => _valid;
}

/// Every texture of one `MTLDevice`, by id.
///
/// Also the [GpuTextureAllocator] the shared video cache asks for its one
/// texture per stream.
final class MetalTextureStore implements GpuTextureAllocator {
  MetalTextureStore._(this._gpu) {
    _gpu.addDisposeHook(_dispose);
  }

  /// The store for [gpu], created on first use and released with it.
  static MetalTextureStore of(MetalGpu gpu) =>
      _stores[gpu] ??= MetalTextureStore._(gpu);

  static final Expando<MetalTextureStore> _stores =
      Expando<MetalTextureStore>('MetalTextureStore');

  final MetalGpu _gpu;
  final Map<int, MetalTexture> _byId = <int, MetalTexture>{};
  int _nextId = 1;

  /// Glyph rasters shared by every target on this device. `R8Unorm`.
  late final GpuGlyphAtlas glyphAtlas = GpuGlyphAtlas();

  late final MetalTexture glyphTexture = create(
    width: glyphAtlas.width,
    height: glyphAtlas.height,
    format: GpuTextureFormat.alpha8,
    filter: GpuTextureFilter.nearest,
  );

  /// Rebound to each list before it is replayed; see [ReplayFontResolver].
  final ReplayFontResolver fontResolver = ReplayFontResolver();

  late final MetalImageCache imageCache = MetalImageCache._(this);

  /// How many regions of the glyph atlas have gone to the GPU, for tests that
  /// want to see the atlas shared rather than re-uploaded.
  int glyphUploadCount = 0;

  /// The texture with [id], or null for [kNoTexture] and anything released.
  MetalTexture? byId(int id) => _byId[id];

  /// A texture the shaders sample. [renderTarget] also lets a pass draw
  /// into it - a layer - and keeps it in `private` storage, since the CPU
  /// never writes it.
  MetalTexture create({
    required int width,
    required int height,
    required GpuTextureFormat format,
    required GpuTextureFilter filter,
    bool renderTarget = false,
  }) {
    final int pixelFormat = switch (format) {
      GpuTextureFormat.alpha8 => MtlPixelFormat.r8Unorm,
      GpuTextureFormat.bgra8888Premultiplied => MtlPixelFormat.bgra8Unorm,
      _ => MtlPixelFormat.rgba8Unorm,
    };
    final Pointer<ObjCObject> texture = ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> descriptor = metalSendPointer4(
        objcClass('MTLTextureDescriptor'),
        'texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
        pixelFormat,
        width,
        height,
        0,
      );
      metalSendVoid1(
          descriptor,
          'setUsage:',
          renderTarget
              ? MtlTextureUsage.shaderRead | MtlTextureUsage.renderTarget
              : MtlTextureUsage.shaderRead);
      metalSendVoid1(descriptor, 'setStorageMode:',
          renderTarget ? MtlStorageMode.private : MtlStorageMode.shared);
      return metalSendPointer1(
          _gpu.device, 'newTextureWithDescriptor:', descriptor.address);
    });
    if (texture == nullptr) {
      throw MetalError('newTextureWithDescriptor: returned nil for a '
          '${width}x$height ${format.name} texture');
    }
    final MetalTexture result =
        MetalTexture._(_nextId++, texture, width, height, format, filter);
    _byId[result.id] = result;
    return result;
  }

  /// Copies a [width] x [height] rectangle into [texture] at ([x], [y]).
  ///
  /// [pixels] starts at the rectangle's first texel and advances
  /// [bytesPerRow] bytes per row - an atlas row, or a framebuffer row - which
  /// is the layout `replaceRegion:` reads, so only the span the rectangle
  /// covers is copied to native memory, not the whole source.
  void upload(
    MetalTexture texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    if (width <= 0 || height <= 0) return;
    final int bytesPerPixel = texture.format == GpuTextureFormat.alpha8 ? 1 : 4;
    final int span = (height - 1) * bytesPerRow + width * bytesPerPixel;
    final Pointer<Uint8> native =
        NativeAllocator.instance.allocate<Uint8>(span);
    try {
      native.asTypedList(span).setRange(0, span, pixels);
      metalSendReplaceRegion(
        texture.pointer,
        'replaceRegion:mipmapLevel:withBytes:bytesPerRow:',
        mtlRegion2D(x: x, y: y, width: width, height: height),
        0,
        native.cast<Void>(),
        bytesPerRow,
      );
    } finally {
      NativeAllocator.instance.free(native);
    }
  }

  /// Sends the glyph atlas's dirty plots to [glyphTexture].
  void uploadGlyphAtlas() {
    if (!glyphAtlas.isDirty) return;
    final int stride = glyphAtlas.width;
    glyphAtlas.forEachDirtyRegion((int x, int y, int width, int height) {
      upload(
        glyphTexture,
        x: x,
        y: y,
        width: width,
        height: height,
        pixels: Uint8List.sublistView(glyphAtlas.pixels, y * stride + x),
        bytesPerRow: stride,
      );
      glyphUploadCount++;
    });
    glyphAtlas.markUploaded();
  }

  @override
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.linear,
  }) =>
      create(width: width, height: height, format: format, filter: filter);

  @override
  void uploadRegion(
    GpuTextureHandle texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) =>
      upload(texture as MetalTexture,
          x: x,
          y: y,
          width: width,
          height: height,
          pixels: pixels,
          bytesPerRow: bytesPerRow);

  @override
  void releaseTexture(GpuTextureHandle texture) {
    if (texture is MetalTexture) release(texture);
  }

  void release(MetalTexture texture) {
    if (!texture._valid) return;
    texture._valid = false;
    _byId.remove(texture.id);
    // Freeing a texture autoreleases its device; see metal_offscreen.dart.
    ObjCAutoreleasePool.run(() => objcRelease(texture.pointer));
  }

  void _dispose() {
    for (final MetalTexture texture in _byId.values.toList()) {
      release(texture);
    }
    _stores[_gpu] = null;
  }
}

/// Framebuffers the display list draws as images, uploaded once each.
///
/// Keyed by identity, as `D3d11ImageCache` is: a display list hands the same
/// `Framebuffer` object every frame it shows the same image, and an image that
/// changes is a new object. A decoded video frame goes to the
/// [GpuVideoImageCache] every other GPU backend uses - one texture per stream,
/// rewritten per frame - and anything else has no texture here, which the
/// sink refuses by name.
final class MetalImageCache implements GpuImageResolver {
  MetalImageCache._(this._store);

  final MetalTextureStore _store;
  final Expando<MetalTexture> _byImage = Expando<MetalTexture>('MetalImage');

  /// [ImageChannelOrder.rgba] because a converted frame lands in an
  /// `RGBA8Unorm` texture; a BGRA frame skips the conversion into a
  /// `BGRA8Unorm` one, which Metal samples as RGBA all the same.
  late final GpuVideoImageCache video =
      GpuVideoImageCache(_store, channelOrder: ImageChannelOrder.rgba);

  @override
  GpuTextureHandle? resolve(Object image) {
    if (image is! Framebuffer) return video.resolve(image);
    final MetalTexture? cached = _byImage[image];
    if (cached != null && cached.isValid) return cached;
    final MetalTexture texture = _store.create(
      width: image.width,
      height: image.height,
      format: image.format == PixelFormat.bgra8888Premultiplied
          ? GpuTextureFormat.bgra8888Premultiplied
          : GpuTextureFormat.rgba8888Premultiplied,
      filter: GpuTextureFilter.linear,
    );
    _store.upload(
      texture,
      x: 0,
      y: 0,
      width: image.width,
      height: image.height,
      pixels: image.pixels,
      bytesPerRow: image.bytesPerRow,
    );
    _byImage[image] = texture;
    return texture;
  }
}

/// A layer's colour target: a texture a pass renders into and the composite
/// quad then samples, in the same id space as every other texture here.
final class MetalLayerTarget implements GpuLayerTarget {
  MetalLayerTarget._(this.texture);

  final MetalTexture texture;

  @override
  int get id => texture.id;

  @override
  int get textureId => texture.id;

  @override
  int get width => texture.width;

  @override
  int get height => texture.height;
}

/// Layer targets for one render target, pooled across frames.
///
/// In the pixel format of the target's pipelines: a Metal pipeline state is
/// compiled for one colour format, and a layer drawn with the target's
/// pipelines has to be that format or the encoder is rejected. Reused by size
/// - the smallest free target that fits - because an interface animating the
/// opacity of the same dialog asks for the same layer every frame.
final class MetalLayerAllocator implements GpuLayerTargetAllocator {
  MetalLayerAllocator(this._store, this._pixelFormat);

  final MetalTextureStore _store;
  final int _pixelFormat;
  final List<MetalLayerTarget> _free = <MetalLayerTarget>[];
  final List<MetalLayerTarget> _all = <MetalLayerTarget>[];

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) {
    MetalLayerTarget? best;
    for (final MetalLayerTarget candidate in _free) {
      if (candidate.width < width || candidate.height < height) continue;
      if (best == null ||
          candidate.width * candidate.height < best.width * best.height) {
        best = candidate;
      }
    }
    if (best != null) {
      _free.remove(best);
      return best;
    }
    final MetalLayerTarget created = MetalLayerTarget._(_store.create(
      width: width,
      height: height,
      format: _pixelFormat == MtlPixelFormat.bgra8Unorm
          ? GpuTextureFormat.bgra8888Premultiplied
          : GpuTextureFormat.rgba8888Premultiplied,
      // One texel per pixel: a layer is composited back at the size it was
      // drawn, so nearest and linear agree, and nearest cannot blur an edge.
      filter: GpuTextureFilter.nearest,
      renderTarget: true,
    ));
    _all.add(created);
    return created;
  }

  @override
  void releaseLayerTarget(GpuLayerTarget target) {
    if (target is MetalLayerTarget && !_free.contains(target)) {
      _free.add(target);
    }
  }

  void dispose() {
    for (final MetalLayerTarget target in _all) {
      _store.release(target.texture);
    }
    _all.clear();
    _free.clear();
  }
}
