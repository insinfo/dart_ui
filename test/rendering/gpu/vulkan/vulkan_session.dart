/// One Vulkan device shared by a test file, or the reason there is none.
///
/// Every live-device test under this directory opens one of these in `main`
/// and passes [skipReason] to every `test(..., skip: ...)`. That is the shape
/// `test/rendering/gpu/gl_device_test.dart` established and the reason is the
/// same: **no Vulkan on the runner is not a defect in the renderer.** The CI
/// containers for Linux and macOS have no ICD, `referencias/` is in
/// `.gitignore` so the software rasteriser cannot travel with the repository,
/// and a test that failed there would block every unrelated change.
///
/// The reason is always a sentence, never a bare skip: "no Vulkan loader:
/// libvulkan.so.1, libvulkan.so" tells a reader which package is missing,
/// where "skipped" tells them nothing.
library;

import 'dart:io';

import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_device.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_instance.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_library.dart';

final class VulkanSession {
  VulkanSession._(this.library, this.instance, this.device, this.skipReason);

  final VulkanLibrary? library;
  final VulkanInstance? instance;
  final VulkanDevice? device;

  /// Null when a device opened. A sentence - which `skip:` accepts - when it
  /// did not.
  final String? skipReason;

  bool get isOpen => device != null;

  /// Opens the loader, an instance and a device, in that order, stopping at
  /// the first that refuses.
  ///
  /// [validation] is passed straight through to [VulkanInstanceOptions] and is
  /// never inferred; see the policy in `vulkan_instance.dart`.
  static VulkanSession open({bool validation = false, int framesInFlight = 2}) {
    try {
      final VulkanLoadResult load = VulkanLibrary.open();
      final VulkanLibrary? library = load.library;
      if (library == null) {
        return VulkanSession._(
            null,
            null,
            null,
            'no Vulkan loader (tried ${load.attempted.join(', ')}): '
            '${load.failureText}');
      }

      final VulkanInstanceAttempt attempt = VulkanInstance.create(
        library,
        options: VulkanInstanceOptions(validation: validation),
      );
      final VulkanInstance? instance = attempt.instance;
      if (instance == null) {
        return VulkanSession._(
            library, null, null, 'no Vulkan instance: ${attempt.failureText}');
      }

      final VulkanPhysicalDevice? physical = instance.chooseDevice();
      if (physical == null) {
        instance.dispose();
        return VulkanSession._(
            library,
            null,
            null,
            'no Vulkan physical device with a graphics queue; the loader on '
            '${library.path} reported '
            '${instance.physicalDevices().length} device(s)');
      }

      final VulkanDeviceAttempt opened =
          VulkanDevice.open(physical, framesInFlight: framesInFlight);
      final VulkanDevice? device = opened.device;
      if (device == null) {
        instance.dispose();
        return VulkanSession._(
            library, null, null, 'no Vulkan device: ${opened.failureText}');
      }
      return VulkanSession._(library, instance, device, null);
    } on Object catch (error, stack) {
      return VulkanSession._(
          null, null, null, 'opening a Vulkan device threw: $error\n$stack');
    }
  }

  /// Why this platform could not possibly work, or null.
  ///
  /// Distinct from [skipReason] so a test that needs no device at all - the
  /// SPIR-V and layout tests - can still say something useful. Vulkan itself
  /// is portable; what is not portable is having a driver.
  static String? get platformNote => Platform.isMacOS
      ? 'macOS has no native Vulkan; this needs MoltenVK from the LunarG SDK'
      : null;

  void close() {
    device?.dispose();
    instance?.dispose();
  }
}
