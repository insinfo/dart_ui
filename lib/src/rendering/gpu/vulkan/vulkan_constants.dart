/// The manual half of the Vulkan binding: the four things `ffigen` cannot
/// produce, and the names a diagnostic needs.
///
/// ## The overrides list section 11.4 asks for
///
/// `vulkan_ffi.g.dart` is generated from `Vulkan-Headers` at a pinned commit
/// and is never edited. Everything a hand still has to write is here, and this
/// list is exhaustive - if it is not in this file and not in the generated
/// one, this backend does not have it.
///
///   1. **The macros.** `VK_WHOLE_SIZE` is `(~0ULL)`, `VK_SUBPASS_EXTERNAL`
///      and `VK_QUEUE_FAMILY_IGNORED` are `(~0U)`, and `VK_MAKE_API_VERSION`
///      is a bit-shift expression. libclang hands ffigen the *token sequence*
///      for those, not a value, so they cannot be generated; each one below
///      quotes the `vulkan_core.h` line it came from. The four size constants
///      (`VK_MAX_PHYSICAL_DEVICE_NAME_SIZE` and friends) are the same case.
///   2. **Six opaque handle types.** `ffigen` emits `final class VkBuffer_T
///      extends Opaque {}` for every handle *mentioned by a generated struct*,
///      which leaves out the six that only ever appear as command parameters:
///      `VkInstance`, `VkPhysicalDevice`, `VkDevice`, `VkQueue`, `VkFence` and
///      `VkDebugUtilsMessengerEXT`. Declaring them here is safe in the way the
///      rest of this list is not: an [Opaque] carries **no layout claim at
///      all**, so there is nothing a hand can get wrong about it. The
///      alternative - adding unrelated structs to the generator's include list
///      purely to drag these in - would put noise in the generated file to
///      avoid six lines here.
///   3. **The dispatch tables**, in `vulkan_bindings.dart`. ffigen binds a
///      command with `DynamicLibrary.lookup`, which is the wrong door for
///      Vulkan; see that file's library comment.
///   4. **The names**, below. `vkResultName` and its siblings exist because
///      section 6.6 forbids reporting `-4` when `VK_ERROR_DEVICE_LOST` is
///      what happened, and a generator has no reason to emit a formatter.
///
/// Everything else - every structure, every enumerant, every flag bit - comes
/// out of the generator, so a wrong digit in `VK_FORMAT_B8G8R8A8_UNORM` is not
/// a class of bug this backend can have.
///
/// The `camel_case_types` suppression below covers the six handle types and
/// nothing else. `VkDevice_T` is the name `vulkan_core.h` gives that struct and
/// the name `ffigen` generates for every *other* handle in
/// `vulkan_ffi.g.dart`; spelling these six differently would mean two
/// conventions for one concept, and a reader would have to know which handles
/// happened to be mentioned by a struct.
// ignore_for_file: camel_case_types
library;

import 'dart:ffi';

import 'vulkan_ffi.g.dart';

// ---------------------------------------------------------------------------
// Override 2: the handle types no generated struct mentions
// ---------------------------------------------------------------------------

/// `VK_DEFINE_HANDLE(VkInstance)` - a pointer to an opaque driver structure.
final class VkInstance_T extends Opaque {}

/// `VK_DEFINE_HANDLE(VkPhysicalDevice)`.
final class VkPhysicalDevice_T extends Opaque {}

/// `VK_DEFINE_HANDLE(VkDevice)`.
final class VkDevice_T extends Opaque {}

/// `VK_DEFINE_HANDLE(VkQueue)`.
final class VkQueue_T extends Opaque {}

/// `VK_DEFINE_NON_DISPATCHABLE_HANDLE(VkFence)`.
///
/// On a 64-bit build - the only build this backend supports, see
/// `vulkan_library.dart` - a non-dispatchable handle is also a pointer to an
/// opaque structure, which is why this looks the same as the four above.
final class VkFence_T extends Opaque {}

/// `VK_DEFINE_NON_DISPATCHABLE_HANDLE(VkEvent)`.
final class VkEvent_T extends Opaque {}

/// `VK_DEFINE_NON_DISPATCHABLE_HANDLE(VkDebugUtilsMessengerEXT)`.
final class VkDebugUtilsMessengerEXT_T extends Opaque {}

// ---------------------------------------------------------------------------
// Override 1: the macros
// ---------------------------------------------------------------------------

/// `#define VK_WHOLE_SIZE (~0ULL)` - `vulkan_core.h:130`.
///
/// All ones in 64 bits, which is what Dart's `-1` is when it crosses as a
/// `Uint64`. Writing `0xFFFFFFFFFFFFFFFF` would not compile as a Dart `int`.
const int vkWholeSize = -1;

/// `#define VK_SUBPASS_EXTERNAL (~0U)` - `vulkan_core.h:138`.
const int vkSubpassExternal = 0xFFFFFFFF;

/// `#define VK_QUEUE_FAMILY_IGNORED (~0U)` - `vulkan_core.h:126`.
const int vkQueueFamilyIgnored = 0xFFFFFFFF;

/// `#define VK_MAX_PHYSICAL_DEVICE_NAME_SIZE 256U` - `vulkan_core.h:132`.
const int vkMaxPhysicalDeviceNameSize = 256;

/// `#define VK_UUID_SIZE 16U` - `vulkan_core.h:133`.
const int vkUuidSize = 16;

/// `#define VK_MAX_EXTENSION_NAME_SIZE 256U` - `vulkan_core.h:134`.
const int vkMaxExtensionNameSize = 256;

/// `#define VK_MAX_DESCRIPTION_SIZE 256U` - `vulkan_core.h:135`.
const int vkMaxDescriptionSize = 256;

/// `VK_TRUE` and `VK_FALSE`, as the `VkBool32` fields want them.
const int vkTrue = 1;
const int vkFalse = 0;

/// `#define VK_MAKE_API_VERSION(variant, major, minor, patch)`, with the
/// variant fixed at 0 as every non-Vulkan-SC caller passes it.
int vkMakeApiVersion(int major, int minor, int patch) =>
    (major << 22) | (minor << 12) | patch;

/// A `major.minor.patch` reading of a packed `VK_API_VERSION`.
String vkVersionText(int packed) =>
    '${(packed >> 22) & 0x7F}.${(packed >> 12) & 0x3FF}.${packed & 0xFFF}';

// ---------------------------------------------------------------------------
// Override 4: names, for diagnostics
// ---------------------------------------------------------------------------

/// Whether [result] means the call did not do what was asked.
///
/// Positive codes are successes with a qualification - `VK_SUBOPTIMAL_KHR` is
/// a swapchain that still presented - and treating them as failures would make
/// a window that needs resizing look like a dead device.
bool vkFailed(int result) => result < VkResult.VK_SUCCESS;

/// The name of [result].
///
/// Named rather than numeric because section 6.6 forbids reporting a failure
/// the reader has to look up: `-4` and `VK_ERROR_DEVICE_LOST` are the same
/// information only to somebody who already knows the answer.
///
/// Only the codes this backend can actually produce are spelled out. A code
/// from an extension it never enables falls through to the numeric form, which
/// is honest: a name this file invented for it would be a guess.
String vkResultName(int result) => switch (result) {
      VkResult.VK_SUCCESS => 'VK_SUCCESS',
      VkResult.VK_NOT_READY => 'VK_NOT_READY',
      VkResult.VK_TIMEOUT => 'VK_TIMEOUT',
      VkResult.VK_EVENT_SET => 'VK_EVENT_SET',
      VkResult.VK_EVENT_RESET => 'VK_EVENT_RESET',
      VkResult.VK_INCOMPLETE => 'VK_INCOMPLETE',
      VkResult.VK_ERROR_OUT_OF_HOST_MEMORY => 'VK_ERROR_OUT_OF_HOST_MEMORY',
      VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY => 'VK_ERROR_OUT_OF_DEVICE_MEMORY',
      VkResult.VK_ERROR_INITIALIZATION_FAILED =>
        'VK_ERROR_INITIALIZATION_FAILED',
      VkResult.VK_ERROR_DEVICE_LOST => 'VK_ERROR_DEVICE_LOST',
      VkResult.VK_ERROR_MEMORY_MAP_FAILED => 'VK_ERROR_MEMORY_MAP_FAILED',
      VkResult.VK_ERROR_LAYER_NOT_PRESENT => 'VK_ERROR_LAYER_NOT_PRESENT',
      VkResult.VK_ERROR_EXTENSION_NOT_PRESENT =>
        'VK_ERROR_EXTENSION_NOT_PRESENT',
      VkResult.VK_ERROR_FEATURE_NOT_PRESENT => 'VK_ERROR_FEATURE_NOT_PRESENT',
      VkResult.VK_ERROR_INCOMPATIBLE_DRIVER => 'VK_ERROR_INCOMPATIBLE_DRIVER',
      VkResult.VK_ERROR_TOO_MANY_OBJECTS => 'VK_ERROR_TOO_MANY_OBJECTS',
      VkResult.VK_ERROR_FORMAT_NOT_SUPPORTED => 'VK_ERROR_FORMAT_NOT_SUPPORTED',
      VkResult.VK_ERROR_FRAGMENTED_POOL => 'VK_ERROR_FRAGMENTED_POOL',
      VkResult.VK_ERROR_UNKNOWN => 'VK_ERROR_UNKNOWN',
      VkResult.VK_ERROR_OUT_OF_POOL_MEMORY => 'VK_ERROR_OUT_OF_POOL_MEMORY',
      VkResult.VK_ERROR_INVALID_EXTERNAL_HANDLE =>
        'VK_ERROR_INVALID_EXTERNAL_HANDLE',
      VkResult.VK_ERROR_FRAGMENTATION => 'VK_ERROR_FRAGMENTATION',
      VkResult.VK_ERROR_SURFACE_LOST_KHR => 'VK_ERROR_SURFACE_LOST_KHR',
      VkResult.VK_SUBOPTIMAL_KHR => 'VK_SUBOPTIMAL_KHR',
      VkResult.VK_ERROR_OUT_OF_DATE_KHR => 'VK_ERROR_OUT_OF_DATE_KHR',
      _ => 'VkResult($result)',
    };

/// The name of the [VkFormat] values this renderer can ask for.
String vkFormatName(int format) => switch (format) {
      VkFormat.VK_FORMAT_UNDEFINED => 'VK_FORMAT_UNDEFINED',
      VkFormat.VK_FORMAT_R8_UNORM => 'VK_FORMAT_R8_UNORM',
      VkFormat.VK_FORMAT_R8G8B8A8_UNORM => 'VK_FORMAT_R8G8B8A8_UNORM',
      VkFormat.VK_FORMAT_R8G8B8A8_SRGB => 'VK_FORMAT_R8G8B8A8_SRGB',
      VkFormat.VK_FORMAT_B8G8R8A8_UNORM => 'VK_FORMAT_B8G8R8A8_UNORM',
      VkFormat.VK_FORMAT_B8G8R8A8_SRGB => 'VK_FORMAT_B8G8R8A8_SRGB',
      _ => 'VkFormat($format)',
    };

/// The name of a [VkImageLayout], for a barrier diagnostic.
String vkImageLayoutName(int layout) => switch (layout) {
      VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED => 'VK_IMAGE_LAYOUT_UNDEFINED',
      VkImageLayout.VK_IMAGE_LAYOUT_GENERAL => 'VK_IMAGE_LAYOUT_GENERAL',
      VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL =>
        'VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL',
      VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL =>
        'VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL',
      VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL =>
        'VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL',
      VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL =>
        'VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL',
      VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR =>
        'VK_IMAGE_LAYOUT_PRESENT_SRC_KHR',
      _ => 'VkImageLayout($layout)',
    };

/// A readable form of `VkPhysicalDeviceProperties.deviceType`.
String vkPhysicalDeviceTypeName(int type) => switch (type) {
      VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_OTHER => 'other',
      VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU =>
        'integrated GPU',
      VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU =>
        'discrete GPU',
      VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 'virtual GPU',
      VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_CPU => 'CPU',
      _ => 'device type $type',
    };

// ---------------------------------------------------------------------------
// Layer and extension names
// ---------------------------------------------------------------------------

/// The layer this backend enables when validation is asked for, and the only
/// one. See `VulkanInstanceOptions` in `vulkan_instance.dart` for the policy.
const String vkKhronosValidationLayer = 'VK_LAYER_KHRONOS_validation';

const String vkExtDebugUtilsExtension = 'VK_EXT_debug_utils';
const String vkKhrSurfaceExtension = 'VK_KHR_surface';
const String vkKhrSwapchainExtension = 'VK_KHR_swapchain';
