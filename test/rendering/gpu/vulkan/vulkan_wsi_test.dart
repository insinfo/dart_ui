/// The window-system layer that needs no window: the hand-written surface
/// structures, and the two policies that decide what a swapchain is made of.
///
/// Everything here runs on a machine with no Vulkan at all, which is most of
/// them, and that is the point. `vulkan_window_test.dart` needs Windows, a
/// driver and an `HWND`; these are the parts that can be wrong on any of them.
///
/// ## Why the structure layouts are measured rather than declared
///
/// `vulkan_wsi_platform.dart` is the one place in this backend where an FFI
/// structure is written by hand instead of generated, because
/// `VkWin32SurfaceCreateInfoKHR` names `HWND` and lives in a header that needs
/// `windows.h`. So the guard `vulkan_layout_test.dart` provides for the
/// generated file has to be provided here too, by the same method: zero the
/// structure, write one field, and find where the bytes landed. The offsets
/// below are the C ABI's, written out by hand from the header lines quoted in
/// that file - a third statement of the same fact, rather than the Dart
/// declaration compared against itself.
///
/// The interesting case is `VkXcbSurfaceCreateInfoKHR`: its `window` is a
/// `uint32_t` where Xlib's is pointer-width. Writing it as `IntPtr` would move
/// the structure's size by four bytes and make every XCB surface fail in a way
/// that reads like a bad connection, and nothing but an offset test catches it.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_swapchain.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_wsi_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_wsi_platform.dart';
import 'package:test/test.dart';

const int _u32 = 0x21B2C3D4;
const int _ptr = 0x2122232425262728;
const List<int> _u32Bytes = <int>[0xD4, 0xC3, 0xB2, 0x21];
const List<int> _ptrBytes = <int>[
  0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21, //
];

int _find(Uint8List bytes, List<int> pattern) {
  outer:
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    for (var k = 0; k < pattern.length; k++) {
      if (bytes[i + k] != pattern[k]) continue outer;
    }
    return i;
  }
  return -1;
}

void _expectField(
  String name,
  Pointer<Uint8> raw,
  int size,
  int expectedOffset,
  List<int> pattern,
  void Function() write,
) {
  final Uint8List bytes = raw.asTypedList(size);
  bytes.fillRange(0, size, 0);
  write();
  final int found = _find(bytes, pattern);
  expect(found, expectedOffset,
      reason: '$name landed at offset $found; the C ABI puts it at '
          '$expectedOffset');
  bytes.fillRange(0, size, 0);
}

void main() {
  final NativeArena arena = NativeArena();
  tearDownAll(arena.dispose);

  group('the hand-written surface create-infos', () {
    test('VkWin32SurfaceCreateInfoKHR is 40 bytes with the header layout', () {
      // sType(4) pad(4) pNext(8) flags(4) pad(4) hinstance(8) hwnd(8).
      const int size = 40;
      expect(sizeOf<VkWin32SurfaceCreateInfoKHR>(), size);
      final Pointer<Uint8> raw = arena.allocate<Uint8>(size);
      final Pointer<VkWin32SurfaceCreateInfoKHR> info =
          raw.cast<VkWin32SurfaceCreateInfoKHR>();
      _expectField('sType', raw, size, 0, _u32Bytes,
          () => info.ref.sType = _u32);
      _expectField('pNext', raw, size, 8, _ptrBytes,
          () => info.ref.pNext = Pointer<Void>.fromAddress(_ptr));
      _expectField('flags', raw, size, 16, _u32Bytes,
          () => info.ref.flags = _u32);
      _expectField('hinstance', raw, size, 24, _ptrBytes,
          () => info.ref.hinstance = _ptr);
      _expectField('hwnd', raw, size, 32, _ptrBytes,
          () => info.ref.hwnd = _ptr);
    });

    test('VkXlibSurfaceCreateInfoKHR carries a pointer-width Window', () {
      const int size = 40;
      expect(sizeOf<VkXlibSurfaceCreateInfoKHR>(), size);
      final Pointer<Uint8> raw = arena.allocate<Uint8>(size);
      final Pointer<VkXlibSurfaceCreateInfoKHR> info =
          raw.cast<VkXlibSurfaceCreateInfoKHR>();
      _expectField('dpy', raw, size, 24, _ptrBytes, () => info.ref.dpy = _ptr);
      _expectField('window', raw, size, 32, _ptrBytes,
          () => info.ref.window = _ptr);
    });

    test('VkXcbSurfaceCreateInfoKHR carries a 32-bit xcb_window_t', () {
      // The asymmetry with Xlib, and the reason this test exists. The *size*
      // does not give it away - sType(4) pad(4) pNext(8) flags(4) pad(4)
      // connection(8) window(4) and then four bytes of tail padding, because
      // the structure's alignment is the pointer's, comes to the same 40 bytes
      // an `IntPtr` window would. Only the four zero bytes *after* the field
      // distinguish them, which is exactly the case the library comment of
      // `vulkan_layout_test.dart` says `sizeOf` can never catch.
      const int size = 40;
      expect(sizeOf<VkXcbSurfaceCreateInfoKHR>(), size);
      final Pointer<Uint8> raw = arena.allocate<Uint8>(size);
      final Pointer<VkXcbSurfaceCreateInfoKHR> info =
          raw.cast<VkXcbSurfaceCreateInfoKHR>();
      _expectField('connection', raw, size, 24, _ptrBytes,
          () => info.ref.connection = _ptr);
      _expectField('window', raw, size, 32, _u32Bytes,
          () => info.ref.window = _u32);
      // The four bytes past it stay zero: an `IntPtr` field would write eight.
      final Uint8List bytes = raw.asTypedList(size);
      bytes.fillRange(0, size, 0);
      info.ref.window = -1;
      expect(bytes.sublist(32, 36), <int>[0xFF, 0xFF, 0xFF, 0xFF]);
      expect(bytes.sublist(36, 40), <int>[0, 0, 0, 0],
          reason: 'xcb_window_t is a uint32_t, not a pointer-width id');
      bytes.fillRange(0, size, 0);
    });

    test('VkWaylandSurfaceCreateInfoKHR is two pointers after the flags', () {
      const int size = 40;
      expect(sizeOf<VkWaylandSurfaceCreateInfoKHR>(), size);
      final Pointer<Uint8> raw = arena.allocate<Uint8>(size);
      final Pointer<VkWaylandSurfaceCreateInfoKHR> info =
          raw.cast<VkWaylandSurfaceCreateInfoKHR>();
      _expectField('display', raw, size, 24, _ptrBytes,
          () => info.ref.display = _ptr);
      _expectField('surface', raw, size, 32, _ptrBytes,
          () => info.ref.surface = _ptr);
    });

    test('the generated swapchain structures came through too', () {
      // Not a layout check - `vulkan_layout_test.dart` owns those - but a
      // check that regenerating the bindings really did add them, because
      // everything else in this port assumes it.
      expect(sizeOf<VkSwapchainCreateInfoKHR>(), greaterThan(0));
      expect(sizeOf<VkPresentInfoKHR>(), greaterThan(0));
      expect(sizeOf<VkSurfaceCapabilitiesKHR>(), greaterThan(0));
      expect(sizeOf<VkSurfaceFormatKHR>(), 8);
    });
  });

  group('the platform to extension mapping', () {
    test('every platform names its own instance extension', () {
      expect(VulkanSurfacePlatform.win32.instanceExtension,
          vkKhrWin32SurfaceExtension);
      expect(VulkanSurfacePlatform.xlib.instanceExtension,
          vkKhrXlibSurfaceExtension);
      expect(VulkanSurfacePlatform.xcb.instanceExtension,
          vkKhrXcbSurfaceExtension);
      expect(VulkanSurfacePlatform.wayland.instanceExtension,
          vkKhrWaylandSurfaceExtension);
      // Four platforms, four distinct extensions: a copy-paste that pointed
      // two of them at the same string would make one silently unavailable.
      expect(
        VulkanSurfacePlatform.values
            .map((VulkanSurfacePlatform p) => p.instanceExtension)
            .toSet(),
        hasLength(VulkanSurfacePlatform.values.length),
      );
    });

    test('the command tables name their commands without duplicates', () {
      for (final List<String> list in <List<String>>[
        VulkanSurfaceApi.requiredSymbols,
        VulkanSurfaceApi.platformSymbols,
        VulkanSwapchainApi.requiredSymbols,
      ]) {
        expect(list.toSet().length, list.length, reason: 'duplicate in $list');
        for (final String symbol in list) {
          expect(symbol, startsWith('vk'));
          expect(symbol, endsWith('KHR'));
        }
      }
    });
  });

  group('the format policy', () {
    test('prefers BGRA UNORM, which is what the offscreen path uses', () {
      expect(
        VulkanSurfaceConfiguration.chooseFormat(<VulkanSurfaceFormat>[
          const VulkanSurfaceFormat(VkFormat.VK_FORMAT_R8G8B8A8_UNORM,
              VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
          const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
              VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
        ]),
        const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
            VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
      );
    });

    test('never picks an _SRGB format over a UNORM one', () {
      // Policy 1, and the single most likely way for this port to be wrong
      // while still showing a picture: an `_SRGB` swapchain applies the
      // transfer function to colours that already carry it, and the whole
      // window comes out washed pale.
      final VulkanSurfaceFormat? chosen =
          VulkanSurfaceConfiguration.chooseFormat(<VulkanSurfaceFormat>[
        const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_SRGB,
            VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
        const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
            VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
      ]);
      expect(chosen!.format, VkFormat.VK_FORMAT_B8G8R8A8_UNORM);
      for (final VulkanSurfaceFormat preferred
          in VulkanSurfaceConfiguration.preferredFormats) {
        expect(preferred.format, isNot(VkFormat.VK_FORMAT_B8G8R8A8_SRGB));
        expect(preferred.format, isNot(VkFormat.VK_FORMAT_R8G8B8A8_SRGB));
      }
    });

    test('a lone UNDEFINED entry means the surface accepts anything', () {
      expect(
        VulkanSurfaceConfiguration.chooseFormat(<VulkanSurfaceFormat>[
          const VulkanSurfaceFormat(VkFormat.VK_FORMAT_UNDEFINED, 0),
        ]),
        VulkanSurfaceConfiguration.preferredFormats.first,
      );
    });

    test('falls back to the first offered rather than refusing the window', () {
      const VulkanSurfaceFormat exotic = VulkanSurfaceFormat(
          VkFormat.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
          VkColorSpaceKHR.VK_COLOR_SPACE_HDR10_ST2084_EXT);
      expect(
        VulkanSurfaceConfiguration.chooseFormat(<VulkanSurfaceFormat>[exotic]),
        exotic,
      );
    });

    test('an empty list is the one case with nothing to choose', () {
      expect(VulkanSurfaceConfiguration.chooseFormat(const []), isNull);
    });

    test('only the two formats this framework can name map to a PixelFormat',
        () {
      expect(_configWith(VkFormat.VK_FORMAT_B8G8R8A8_UNORM).pixelFormat,
          PixelFormat.bgra8888Premultiplied);
      expect(_configWith(VkFormat.VK_FORMAT_R8G8B8A8_UNORM).pixelFormat,
          PixelFormat.rgba8888Premultiplied);
      // Null is not a failure: the window still draws. It means a readback
      // cannot be compared byte for byte, and the target says so.
      expect(_configWith(VkFormat.VK_FORMAT_A2B10G10R10_UNORM_PACK32).pixelFormat,
          isNull);
    });
  });

  group('the present-mode policy', () {
    test('fifo asks for FIFO whatever the surface offers', () {
      expect(
        VulkanSurfaceConfiguration.choosePresentMode(
          VulkanPresentPolicy.fifo,
          <int>[
            VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR,
            VkPresentModeKHR.VK_PRESENT_MODE_IMMEDIATE_KHR,
            VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
          ],
        ),
        VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
      );
    });

    test('lowLatency takes MAILBOX when it is offered', () {
      expect(
        VulkanSurfaceConfiguration.choosePresentMode(
          VulkanPresentPolicy.lowLatency,
          <int>[
            VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
            VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR,
          ],
        ),
        VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR,
      );
    });

    test('lowLatency falls back to FIFO and never to IMMEDIATE', () {
      // A caller asking for latency has not asked to tear, and IMMEDIATE is
      // the mode that tears. This is the assertion that keeps the fallback
      // from being "quietly the fastest thing available".
      expect(
        VulkanSurfaceConfiguration.choosePresentMode(
          VulkanPresentPolicy.lowLatency,
          <int>[
            VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
            VkPresentModeKHR.VK_PRESENT_MODE_IMMEDIATE_KHR,
          ],
        ),
        VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
      );
    });

    test('an empty list still asks for FIFO, which every surface must have',
        () {
      expect(
        VulkanSurfaceConfiguration.choosePresentMode(
            VulkanPresentPolicy.lowLatency, const <int>[]),
        VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
      );
    });
  });

  group('the capability clamps', () {
    test('0xFFFFFFFF means the application chooses the extent', () {
      const VulkanSurfaceCapabilities caps = VulkanSurfaceCapabilities(
        minImageCount: 2,
        maxImageCount: 8,
        currentWidth: 0xFFFFFFFF,
        currentHeight: 0xFFFFFFFF,
        minWidth: 16,
        minHeight: 16,
        maxWidth: 4096,
        maxHeight: 4096,
        currentTransform: 1,
        supportedCompositeAlpha: 1,
        supportedUsageFlags: 0,
      );
      expect(caps.definesExtent, isFalse);
      expect(caps.resolveExtent(800, 600), (800, 600));
      // Clamped, because a surface that leaves the choice open still states
      // bounds - and a swapchain outside them is a refusal, not a stretch.
      expect(caps.resolveExtent(8, 9000), (16, 4096));
    });

    test('a surface that names its extent wins over what the caller wants', () {
      const VulkanSurfaceCapabilities caps = VulkanSurfaceCapabilities(
        minImageCount: 2,
        maxImageCount: 0,
        currentWidth: 1024,
        currentHeight: 768,
        minWidth: 1024,
        minHeight: 768,
        maxWidth: 1024,
        maxHeight: 768,
        currentTransform: 1,
        supportedCompositeAlpha: 1,
        supportedUsageFlags: 0,
      );
      expect(caps.definesExtent, isTrue);
      expect(caps.resolveExtent(320, 240), (1024, 768));
    });

    test('maxImageCount of zero means unbounded, not zero images', () {
      const VulkanSurfaceCapabilities caps = VulkanSurfaceCapabilities(
        minImageCount: 3,
        maxImageCount: 0,
        currentWidth: 4,
        currentHeight: 4,
        minWidth: 4,
        minHeight: 4,
        maxWidth: 4,
        maxHeight: 4,
        currentTransform: 1,
        supportedCompositeAlpha: 1,
        supportedUsageFlags: 0,
      );
      // The floor is raised to the driver's minimum, and the "limit" of zero
      // does not clamp it back down to nothing.
      expect(caps.resolveImageCount(2), 3);
      expect(caps.resolveImageCount(9), 9);
    });

    test('maxImageCount caps the request', () {
      const VulkanSurfaceCapabilities caps = VulkanSurfaceCapabilities(
        minImageCount: 2,
        maxImageCount: 3,
        currentWidth: 4,
        currentHeight: 4,
        minWidth: 4,
        minHeight: 4,
        maxWidth: 4,
        maxHeight: 4,
        currentTransform: 1,
        supportedCompositeAlpha: 1,
        supportedUsageFlags: 0,
      );
      expect(caps.resolveImageCount(9), 3);
    });

    test('composite alpha prefers OPAQUE and never invents one', () {
      const int opaque =
          VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
      const int inherit =
          VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
      expect(VulkanSurfaceConfiguration.chooseCompositeAlpha(opaque | inherit),
          opaque);
      expect(VulkanSurfaceConfiguration.chooseCompositeAlpha(inherit), inherit);
    });
  });

  group('the two policies together', () {
    test('mailbox is given a third image, because two would be FIFO again', () {
      final VulkanSwapchainConfiguration? config =
          VulkanSurfaceConfiguration.choose(
        capabilities: _capabilities(),
        formats: <VulkanSurfaceFormat>[
          const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
              VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
        ],
        presentModes: <int>[
          VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
          VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR,
        ],
        descriptor: _descriptor(policy: VulkanPresentPolicy.lowLatency),
      );
      expect(config!.presentMode, VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR);
      expect(config.imageCount, 3,
          reason: 'mailbox with two images still blocks the producer');
    });

    test('fifo keeps the two images the descriptor asked for', () {
      final VulkanSwapchainConfiguration? config =
          VulkanSurfaceConfiguration.choose(
        capabilities: _capabilities(),
        formats: <VulkanSurfaceFormat>[
          const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
              VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
        ],
        presentModes: <int>[VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR],
        descriptor: _descriptor(),
      );
      expect(config!.presentMode, VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR);
      expect(config.imageCount, 2);
      expect(config.pixelFormat, PixelFormat.bgra8888Premultiplied);
      expect(config.isEmpty, isFalse);
    });

    test('the surface transform is echoed, not overridden with identity', () {
      // Asking for IDENTITY on a surface whose current transform is a rotation
      // is legal and makes the presentation engine rotate every frame.
      final VulkanSwapchainConfiguration? config =
          VulkanSurfaceConfiguration.choose(
        capabilities: _capabilities(
            transform: VkSurfaceTransformFlagBitsKHR
                .VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR),
        formats: <VulkanSurfaceFormat>[
          const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
              VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
        ],
        presentModes: <int>[VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR],
        descriptor: _descriptor(),
      );
      expect(config!.preTransform,
          VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR);
    });

    test('a surface with no format at all yields no configuration', () {
      expect(
        VulkanSurfaceConfiguration.choose(
          capabilities: _capabilities(),
          formats: const <VulkanSurfaceFormat>[],
          presentModes: <int>[VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR],
          descriptor: _descriptor(),
        ),
        isNull,
      );
    });

    test('a minimised window resolves to an empty configuration', () {
      final VulkanSwapchainConfiguration? config =
          VulkanSurfaceConfiguration.choose(
        capabilities: _capabilities(width: 0, height: 0),
        formats: <VulkanSurfaceFormat>[
          const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
              VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
        ],
        presentModes: <int>[VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR],
        descriptor: _descriptor(),
      );
      // Not null and not a swapchain: `isEmpty` is what the target checks, and
      // creating a zero-extent chain is `VK_ERROR_INITIALIZATION_FAILED`.
      expect(config!.isEmpty, isTrue);
    });

    test('transfer-source usage is taken when offered and dropped when not',
        () {
      VulkanSwapchainConfiguration? build(int usage) =>
          VulkanSurfaceConfiguration.choose(
            capabilities: _capabilities(usage: usage),
            formats: <VulkanSurfaceFormat>[
              const VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
                  VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
            ],
            presentModes: <int>[VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR],
            descriptor: _descriptor(),
          );
      expect(
          build(VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                  VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT)!
              .supportsTransferSource,
          isTrue);
      expect(
          build(VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)!
              .supportsTransferSource,
          isFalse);
    });
  });

  group('the descriptor', () {
    test('resizing keeps every other decision', () {
      final VulkanWindowSurfaceDescriptor original = VulkanWindowSurfaceDescriptor(
        platform: VulkanSurfacePlatform.win32,
        windowHandle: 0x1234,
        displayHandle: 0x5678,
        pixelWidth: 100,
        pixelHeight: 50,
        presentPolicy: VulkanPresentPolicy.lowLatency,
        minImageCount: 3,
        description: 'test window',
      );
      final VulkanWindowSurfaceDescriptor resized =
          original.resized(pixelWidth: 200, pixelHeight: 120);
      expect(resized.pixelWidth, 200);
      expect(resized.pixelHeight, 120);
      expect(resized.windowHandle, original.windowHandle);
      expect(resized.displayHandle, original.displayHandle);
      expect(resized.presentPolicy, original.presentPolicy);
      expect(resized.minImageCount, original.minImageCount);
      expect(resized.description, original.description);
      expect(resized.scale, original.scale);
    });

    test('kind is a diagnostic string and the size must be positive', () {
      expect(_descriptor().kind, 'vulkan-window');
      expect(
        () => VulkanWindowSurfaceDescriptor(
          platform: VulkanSurfacePlatform.win32,
          windowHandle: 1,
          pixelWidth: 0,
          pixelHeight: 10,
        ),
        throwsA(isA<AssertionError>()),
      );
      // One image would mean waiting for the compositor before every frame.
      expect(
        () => VulkanWindowSurfaceDescriptor(
          platform: VulkanSurfacePlatform.win32,
          windowHandle: 1,
          pixelWidth: 10,
          pixelHeight: 10,
          minImageCount: 1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}

VulkanSwapchainConfiguration _configWith(int format) =>
    VulkanSwapchainConfiguration(
      format: format,
      colorSpace: VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
      presentMode: VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
      imageCount: 2,
      width: 4,
      height: 4,
      preTransform: 1,
      compositeAlpha: 1,
      supportsTransferSource: false,
    );

VulkanSurfaceCapabilities _capabilities({
  int width = 320,
  int height = 240,
  int transform =
      VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
  int usage = VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
}) =>
    VulkanSurfaceCapabilities(
      minImageCount: 2,
      maxImageCount: 8,
      currentWidth: width,
      currentHeight: height,
      minWidth: 1,
      minHeight: 1,
      maxWidth: 4096,
      maxHeight: 4096,
      currentTransform: transform,
      supportedCompositeAlpha:
          VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
      supportedUsageFlags: usage,
    );

VulkanWindowSurfaceDescriptor _descriptor({
  VulkanPresentPolicy policy = VulkanPresentPolicy.fifo,
}) =>
    VulkanWindowSurfaceDescriptor(
      platform: VulkanSurfacePlatform.win32,
      windowHandle: 0x1234,
      pixelWidth: 320,
      pixelHeight: 240,
      presentPolicy: policy,
    );
