/// A Metal render pass whose result is read back and compared with the CPU.
///
/// This is where the Metal backend stops describing itself and produces
/// pixels. Everything before it - symbol resolution, encodings, a compiled
/// library, a validated pipeline state - proves that Metal *accepted* a
/// description. A cleared texture read back byte for byte proves that the GPU
/// wrote what was asked for, in the channel order this framework expects.
///
/// Every assertion is on a value. Apple documents that a message to nil does
/// nothing and returns zero, so a test that ran a pass and checked for the
/// absence of a crash would pass against a nil texture, a nil command buffer
/// and a nil encoder alike.
library;

import 'dart:io';

import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_device.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_offscreen.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

final String? _needsMac = Platform.isMacOS
    ? null
    : 'needs a Mac: this renders into an MTLTexture and reads it back.';

const int _size = 24;

void main() {
  late MetalGpu gpu;

  setUpAll(() {
    if (!Platform.isMacOS) return;
    gpu = MetalGpu.open();
  });

  tearDownAll(() {
    if (!Platform.isMacOS) return;
    gpu.dispose();
  });

  group('an offscreen pass that only clears', () {
    test('writes the requested colour into every pixel', () {
      // 0xFF204060 is the background every parity scene in this repository
      // uses: opaque, and different in all three channels, so a channel swap
      // is visible rather than symmetric.
      const int color = 0xFF204060;
      final MetalOffscreenTarget target =
          MetalOffscreenTarget.create(gpu, width: _size, height: _size);
      try {
        target.clear(color);
        final Framebuffer result = target.readPixels();
        expect(result.width, _size);
        expect(result.height, _size);
        final List<int> corner = <int>[
          result.pixels[0],
          result.pixels[1],
          result.pixels[2],
          result.pixels[3],
        ];
        expect(corner, <int>[0x20, 0x40, 0x60, 0xFF],
            reason: 'the readback is rgba8888Premultiplied, so the first four '
                'bytes are r, g, b, a of the top-left pixel');
        // Every pixel, not only the corner: a pass whose store action was
        // wrong, or whose region was smaller than the texture, would leave
        // part of the surface at whatever the allocation happened to hold.
        for (var y = 0; y < result.height; y++) {
          for (var x = 0; x < result.width; x++) {
            final int i = result.offsetOf(x, y);
            expect(
              <int>[
                result.pixels[i],
                result.pixels[i + 1],
                result.pixels[i + 2],
                result.pixels[i + 3],
              ],
              corner,
              reason: 'pixel ($x, $y) differs from the clear colour',
            );
          }
        }
      } finally {
        target.dispose();
      }
    }, skip: _needsMac);

    test('a translucent clear stays premultiplied', () {
      // The clear colour is handed to Metal exactly as it arrives, the way
      // ClearRenderTargetView takes it in d3d11_backend.dart. A backend that
      // un-premultiplied on the way in would produce 0x40 here instead of
      // 0x20 and would look right in every opaque scene.
      const int color = 0x80402010;
      final MetalOffscreenTarget target =
          MetalOffscreenTarget.create(gpu, width: 4, height: 4);
      try {
        target.clear(color);
        final Framebuffer result = target.readPixels();
        expect(
          <int>[
            result.pixels[0],
            result.pixels[1],
            result.pixels[2],
            result.pixels[3],
          ],
          <int>[0x40, 0x20, 0x10, 0x80],
        );
      } finally {
        target.dispose();
      }
    }, skip: _needsMac);

    test('the CPU renderer agrees with it, deviation 0', () async {
      // The first CPU/Metal comparison in this repository. What it can prove
      // is narrow and worth stating: a uniform surface would match a uniform
      // surface of the wrong colour only if both were wrong the same way, so
      // this pins the clear path and the channel order and nothing else. The
      // scenes with geometry in them are the ones that carry signal about the
      // shader, and they come next.
      const int color = 0xFF204060;
      final MemoryRenderTarget cpu =
          MemoryRenderTarget(const MemorySurfaceDescriptor(
        pixelWidth: _size,
        pixelHeight: _size,
        format: PixelFormat.rgba8888Premultiplied,
      ));
      final MetalOffscreenTarget gpuTarget =
          MetalOffscreenTarget.create(gpu, width: _size, height: _size);
      try {
        await cpu.renderDisplayList(DisplayList(), clearColor: color);
        gpuTarget.clear(color);
        expect(gpuTarget.readPixels().pixels, cpu.framebuffer.pixels);
      } finally {
        gpuTarget.dispose();
        cpu.dispose();
      }
    }, skip: _needsMac);
  });
}
