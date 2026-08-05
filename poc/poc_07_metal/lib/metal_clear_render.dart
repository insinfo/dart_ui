// POC-07: end-to-end clear render through Metal.
//
// Sequence exercised by `runMetalClearRender`:
//   1. Obtain system default MTLDevice (GPU).
//   2. Instantiate CAMetalLayer (via QuartzCore + objc runtime) and configure
//      device / pixel format / drawable size.
//   3. Acquire the next MTLDrawable and its underlying texture.
//   4. Allocate a command queue + command buffer.
//   5. Build a render-pass descriptor with a single color attachment using the
//      drawable texture, MTLLoadActionClear and a solid background color.
//   6. Encode a no-op render pass and end encoding.
//   7. Present the drawable and commit the command buffer.
//   8. Wait for completion and release retained references.
//
// Every Objective-C call goes through `dart:ffi` against `libobjc.A.dylib`
// and `Metal.framework`; no C/C++/Objective-C shim is required.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'metal_bindings.dart';
import 'objc_runtime.dart';

void runMetalClearRender({int width = 800, int height = 600}) {
  print('[Metal] Acquiring system default device...');
  final device = mtlCreateSystemDefaultDevice();
  if (device == nullptr) {
    print('[Metal] No default Metal device available. Aborting.');
    return;
  }
  print('[Metal] MTLDevice acquired (${device.address}).');

  print('[Metal] Instantiating CAMetalLayer...');
  final metalLayerClass = getClass('CAMetalLayer');
  if (metalLayerClass == nullptr) {
    print('[Metal] CAMetalLayer class not found. Aborting.');
    return;
  }
  final layer = metalLayerClass.msgSend('alloc').msgSend('init');
  if (layer == nullptr) {
    print('[Metal] CAMetalLayer init returned nil. Aborting.');
    return;
  }

  // Configure layer: device, pixel format, drawable size.
  msgSendVoidPointer(layer, sel('setDevice:'), device);
  msgSendVoidIntPtr(layer, sel('setPixelFormat:'), mtlPixelFormatBGRA8Unorm);

  final size = calloc<NSSize>();
  size.ref.width = width.toDouble();
  size.ref.height = height.toDouble();
  msgSendVoidSize(layer, sel('setDrawableSize:'), size.ref);
  calloc.free(size);
  print(
      '[Metal] CAMetalLayer configured (size ${width}x$height, BGRA8 Unorm).');

  print('[Metal] Calling nextDrawable...');
  final drawable = msgSendPointer(layer, sel('nextDrawable'));
  if (drawable == nullptr) {
    print('[Metal] nextDrawable returned nil (no drawable surface). Aborting.');
    return;
  }
  print('[Metal] Drawable acquired (${drawable.address}).');

  // A `CAMetalDrawable` is an `MTLDrawable` that supports `texture`.
  final texture = msgSendPointer(drawable, sel('texture'));
  if (texture == nullptr) {
    print('[Metal] Drawable.texture returned nil. Aborting.');
    return;
  }
  print('[Metal] Drawable texture acquired (${texture.address}).');

  print('[Metal] Allocating command queue and command buffer...');
  final queue = msgSendPointer(device, sel('newCommandQueue'));
  if (queue == nullptr) {
    print('[Metal] newCommandQueue returned nil. Aborting.');
    return;
  }
  final cmdBuffer = msgSendPointer(queue, sel('commandBuffer'));
  if (cmdBuffer == nullptr) {
    print('[Metal] commandBuffer returned nil. Aborting.');
    return;
  }

  print('[Metal] Building render-pass descriptor...');
  final descriptorClass = getClass('MTLRenderPassDescriptor');
  final descriptor =
      msgSendPointer(descriptorClass, sel('renderPassDescriptor'));
  if (descriptor == nullptr) {
    print('[Metal] renderPassDescriptor returned nil. Aborting.');
    return;
  }
  final colorAttachments = msgSendPointer(descriptor, sel('colorAttachments'));
  // -[MTLRenderPassColorAttachmentDescriptorArray objectAtIndexedSubscript:]
  final colorAttachment = msgSendPointerIntPtr(
      colorAttachments, sel('objectAtIndexedSubscript:'), 0);
  if (colorAttachment == nullptr) {
    print('[Metal] Color attachment at index 0 is nil. Aborting.');
    return;
  }

  // Configure color attachment: texture + load action + store action + clear color.
  msgSendVoidPointer(colorAttachment, sel('setTexture:'), texture);
  msgSendVoidIntPtr(colorAttachment, sel('setLoadAction:'), mtlLoadActionClear);
  msgSendVoidIntPtr(
      colorAttachment, sel('setStoreAction:'), mtlStoreActionStore);

  // Clear color: a teal-ish background (~ (0.2, 0.6, 0.8, 1.0)).
  final clearColor = calloc<MTLClearColor>();
  clearColor.ref.red = 0.2;
  clearColor.ref.green = 0.6;
  clearColor.ref.blue = 0.8;
  clearColor.ref.alpha = 1.0;
  msgSendVoidClearColor(colorAttachment, sel('setClearColor:'), clearColor.ref);
  calloc.free(clearColor);

  print('[Metal] Encoding render pass...');
  final encoder = msgSendPointerPointer(
      cmdBuffer, sel('renderCommandEncoderWithDescriptor:'), descriptor);
  if (encoder == nullptr) {
    print(
        '[Metal] renderCommandEncoderWithDescriptor: returned nil. Aborting.');
    return;
  }
  msgSendVoid(encoder, sel('endEncoding'));
  print('[Metal] Render pass encoded.');

  print('[Metal] Presenting drawable and committing command buffer...');
  msgSendVoidPointer(cmdBuffer, sel('presentDrawable:'), drawable);
  msgSendVoid(cmdBuffer, sel('commit'));
  msgSendVoid(cmdBuffer, sel('waitUntilCompleted'));
  print('[Metal] Command buffer completed.');

  print('[Metal] POC-07 finished successfully. '
      'A single frame was cleared and presented through Metal on arm64 macOS.');
}
