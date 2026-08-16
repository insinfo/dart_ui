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
import '../../framebuffer.dart';
import 'metal_bindings.dart';
import 'metal_device.dart';

/// A texture this framework renders into and then reads back.
final class MetalOffscreenTarget {
  MetalOffscreenTarget._(
    this._gpu,
    this.texture,
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
  static MetalOffscreenTarget create(
    MetalGpu gpu, {
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
    return MetalOffscreenTarget._(
        gpu, texture, width, height, framebuffer, staging);
  }

  final MetalGpu _gpu;

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

  void _checkAlive() {
    if (_disposed) throw MetalError('this MetalOffscreenTarget was disposed');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    NativeAllocator.instance.free(_staging);
    objcRelease(texture);
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
