/// The Vulkan loader, instance and device against a real driver, when there
/// is one.
///
/// The counterpart of `test/rendering/gpu/gl_device_test.dart`: everything
/// else in this directory can be checked with no GPU, and that is exactly why
/// this file has to exist. A binding whose structures are the right size and
/// whose SPIR-V validates can still be a renderer that has never opened a
/// device.
library;

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_constants.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_device.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_instance.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_library.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

void main() {
  group('the loader', () {
    test('names every file it tried when there is none', () {
      // The failure that has to be *named*: a runner with no ICD must produce
      // a sentence a reader can act on, not a null. This assertion holds on a
      // machine with a driver too - the list of candidates is the same either
      // way, and it is the list that must never be empty.
      final List<String> candidates = VulkanLibrary.candidateNames();
      expect(candidates, isNotEmpty);
      final VulkanLoadResult load = VulkanLibrary.open();
      expect(load.attempted, isNotEmpty);
      if (!load.isLoaded) {
        expect(load.diagnostics, isNotEmpty);
        expect(load.failureText, isNotEmpty);
        for (final BackendDiagnostic diagnostic in load.diagnostics) {
          expect(diagnostic.message, isNotEmpty);
        }
      }
    });

    test('a loader that does not exist fails by name rather than throwing', () {
      // Section 6.6 in one assertion. `open` must never throw for "no Vulkan
      // here", because a probe that throws cannot choose another backend.
      final VulkanLoadResult load =
          VulkanLibrary.open(override: 'definitely-not-vulkan-1.dll');
      expect(load.isLoaded, isFalse);
      expect(load.attempted, <String>['definitely-not-vulkan-1.dll']);
      expect(load.failureText, contains('definitely-not-vulkan-1.dll'));
      expect(
        load.diagnostics.first.kind,
        anyOf(
            DiagnosticKind.missingLibrary, DiagnosticKind.unsupportedPlatform),
      );
    });
  });

  group('a live Vulkan device', () {
    final VulkanSession session = VulkanSession.open();
    tearDownAll(session.close);

    test('reports a device name, a type and an API version', () {
      final VulkanPhysicalDevice physical = session.device!.physicalDevice;
      // An empty name means the 824-byte properties structure was read at the
      // wrong offset, which is the failure that otherwise surfaces as a
      // plausible-looking renderer drawing nothing.
      expect(physical.name, isNotEmpty);
      expect(
          physical.apiVersion, greaterThanOrEqualTo(vkMakeApiVersion(1, 0, 0)));
      expect(physical.maxImageDimension2D, greaterThanOrEqualTo(4096));
      expect(physical.maxPushConstantsSize, greaterThanOrEqualTo(128));
      expect(physical.deviceType, inInclusiveRange(0, 4));
      printOnFailure('$physical');
    }, skip: session.skipReason);

    test('the queue family it chose really has VK_QUEUE_GRAPHICS_BIT', () {
      final VulkanDevice device = session.device!;
      final int flags =
          device.physicalDevice.queueFamilyFlags[device.queueFamily];
      expect(flags & VkQueueFlagBits.VK_QUEUE_GRAPHICS_BIT, isNonZero);
      // A graphics family is required by the specification to support transfer
      // operations, which is why this backend needs no second queue. Asserted
      // rather than assumed, because every upload it records depends on it.
      expect(flags & VkQueueFlagBits.VK_QUEUE_TRANSFER_BIT, isNonZero,
          reason: 'a graphics queue family must implicitly support transfer');
      expect(device.queue.address, isNot(0));
    }, skip: session.skipReason);

    test('the memory properties describe at least one usable heap', () {
      final device = session.device!;
      expect(device.allocator.memoryTypeCount, greaterThan(0));
      // Two types every Vulkan implementation must expose: something the
      // device can render into, and something the host can write.
      var deviceLocal = 0;
      var hostVisible = 0;
      for (var i = 0; i < device.allocator.memoryTypeCount; i++) {
        final int properties = device.allocator.propertiesOfType(i);
        if (properties &
                VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT !=
            0) {
          deviceLocal++;
        }
        if (properties &
                VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT !=
            0) {
          hostVisible++;
        }
        expect(device.allocator.heapSizeOfType(i), greaterThan(0));
      }
      expect(deviceLocal, greaterThan(0));
      expect(hostVisible, greaterThan(0));
    }, skip: session.skipReason);

    test('the formats this renderer needs are renderable and samplable', () {
      final VulkanPhysicalDevice physical = session.device!.physicalDevice;
      // B8G8R8A8_UNORM is the surface format and the readback format; R8_UNORM
      // is the coverage-mask and glyph atlas. Neither is optional in practice,
      // but "in practice" is not a guarantee, so it is checked and named.
      expect(physical.supportsRenderTarget(VkFormat.VK_FORMAT_B8G8R8A8_UNORM),
          isTrue,
          reason: 'no ${vkFormatName(VkFormat.VK_FORMAT_B8G8R8A8_UNORM)} '
              'colour attachment on ${physical.name}');
      expect(physical.supportsSampling(VkFormat.VK_FORMAT_R8_UNORM), isTrue,
          reason: 'no sampled ${vkFormatName(VkFormat.VK_FORMAT_R8_UNORM)} on '
              '${physical.name}');
    }, skip: session.skipReason);

    test('a frame can be recorded, submitted and waited for', () {
      final VulkanDevice device = session.device!;
      expect(device.beginFrame(), isNotNull);
      expect(device.isRecording, isTrue);
      expect(device.endFrame(), isTrue);
      expect(device.isRecording, isFalse);
      expect(device.waitIdle(), isTrue);
      expect(device.isLost, isFalse);
      expect(device.frameCount, greaterThan(0));
    }, skip: session.skipReason);

    test('the ring reuses its slots and waits before it does', () {
      final VulkanDevice device = session.device!;
      expect(device.framesInFlight, 2);
      final int before = device.waitCount;
      final Set<int> indices = <int>{};
      for (var i = 0; i < 6; i++) {
        indices.add(device.frameIndex);
        expect(device.beginFrame(), isNotNull);
        expect(device.endFrame(), isTrue);
      }
      expect(indices, <int>{0, 1});
      // Six frames through a two-slot ring means four of them landed on a slot
      // that had already been submitted, and each of those had to wait. A ring
      // that never waited would leave this at zero - and would be resetting a
      // command pool the GPU is still reading.
      expect(device.waitCount - before, 4);
      expect(device.waitIdle(), isTrue);
    }, skip: session.skipReason);

    test('a one-shot command buffer runs and completes', () {
      // The path every upload and every layout transition takes. It records
      // nothing here on purpose: what is being checked is the submit-and-wait,
      // not what was recorded.
      expect(session.device!.oneShot((_) {}), isTrue);
    }, skip: session.skipReason);
  });
}
