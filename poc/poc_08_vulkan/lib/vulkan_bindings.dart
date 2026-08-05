// Vulkan loader bootstrap and instance-level dispatch.
//
// The Vulkan loader (libvulkan.so.1 on Linux, vulkan-1.dll on Windows) exports
// only `vkGetInstanceProcAddr` and the global instance functions
// (`vkCreateInstance`, `vkEnumerateInstanceVersion`, ...). Instance-level
// functions are obtained through `vkGetInstanceProcAddr(instance, name)` so
// the same Dart code works on both platforms without conditional lookup.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// --- Vulkan result and version constants ------------------------------------

const int vkSuccess = 0;
const int vkErrorIncompatibleDriver = -9;

const int vkStructureTypeApplicationInfo = 0;
const int vkStructureTypeInstanceCreateInfo = 1;

int vkMakeVersion(int major, int minor, int patch) =>
    (major << 22) | (minor << 12) | patch;

// Hex literals because `const` contexts cannot invoke a method.
// VK_MAKE_VERSION(1, 0, 0) = (1 << 22) | 0 | 0 = 0x400000
// VK_MAKE_VERSION(1, 1, 0) = (1 << 22) | (1 << 12) | 0 = 0x401000
// VK_MAKE_VERSION(1, 2, 0) = (1 << 22) | (2 << 12) | 0 = 0x402000
const int vkApiVersion1_0 = 0x400000;
const int vkApiVersion1_1 = 0x401000;
const int vkApiVersion1_2 = 0x402000;

const int vkMaxPhysicalDeviceNameSize = 256;
const int vkUuidSize = 16;

// Map physical-device type enums to printable names.
const Map<int, String> vkPhysicalDeviceTypeNames = {
  0: 'OTHER',
  1: 'INTEGRATED_GPU',
  2: 'DISCRETE_GPU',
  3: 'VIRTUAL_GPU',
  4: 'CPU',
};

// --- Native struct declarations --------------------------------------------

final class VkApplicationInfo extends Struct {
  @Int32() external int sType;
  external Pointer<Void> pNext;
  external Pointer<Utf8> pApplicationName;
  @Uint32() external int applicationVersion;
  external Pointer<Utf8> pEngineName;
  @Uint32() external int engineVersion;
  @Uint32() external int apiVersion;
}

final class VkInstanceCreateInfo extends Struct {
  @Int32() external int sType;
  external Pointer<Void> pNext;
  @Int32() external int flags;
  external Pointer<VkApplicationInfo> pApplicationInfo;
  @Uint32() external int enabledLayerCount;
  external Pointer<Pointer<Utf8>> ppEnabledLayerNames;
  @Uint32() external int enabledExtensionCount;
  external Pointer<Pointer<Utf8>> ppEnabledExtensionNames;
}

// We only consume the leading fields of VkPhysicalDeviceProperties; the
// remainder (limits + sparseProperties) is opaque to the POC, so the declared
// struct stops after `deviceName`. The full Vulkan struct is larger, but the
// caller is expected to allocate enough memory (we use 1024 bytes below).
final class VkPhysicalDeviceProperties extends Struct {
  @Uint32() external int apiVersion;
  @Uint32() external int driverVersion;
  @Uint32() external int vendorID;
  @Uint32() external int deviceID;
  @Int32() external int deviceType;
  @Array(vkMaxPhysicalDeviceNameSize) external Array<Uint8> deviceName;
}

// --- Function pointer typedefs ---------------------------------------------

// PFN_vkGetInstanceProcAddr = void* (VkInstance, const char*)
typedef VkGetInstanceProcAddrNative = Pointer<Void> Function(
    Pointer<Void> instance, Pointer<Utf8> pName);
typedef VkGetInstanceProcAddrDart = Pointer<Void> Function(
    Pointer<Void> instance, Pointer<Utf8> pName);

// PFN_vkCreateInstance = VkResult (const VkInstanceCreateInfo*, const AllocationCallbacks*, VkInstance*)
typedef VkCreateInstanceNative = Int32 Function(
    Pointer<VkInstanceCreateInfo> pCreateInfo,
    Pointer<Void> pAllocator,
    Pointer<Pointer<Void>> pInstance);
typedef VkCreateInstanceDart = int Function(
    Pointer<VkInstanceCreateInfo> pCreateInfo,
    Pointer<Void> pAllocator,
    Pointer<Pointer<Void>> pInstance);

// PFN_vkEnumeratePhysicalDevices = VkResult (VkInstance, uint32_t*, VkPhysicalDevice*)
typedef VkEnumeratePhysicalDevicesNative = Int32 Function(
    Pointer<Void> instance,
    Pointer<Uint32> pPhysicalDeviceCount,
    Pointer<Pointer<Void>> pPhysicalDevices);
typedef VkEnumeratePhysicalDevicesDart = int Function(
    Pointer<Void> instance,
    Pointer<Uint32> pPhysicalDeviceCount,
    Pointer<Pointer<Void>> pPhysicalDevices);

// PFN_vkGetPhysicalDeviceProperties = void (VkPhysicalDevice, VkPhysicalDeviceProperties*)
typedef VkGetPhysicalDevicePropertiesNative = Void Function(
    Pointer<Void> physicalDevice,
    Pointer<VkPhysicalDeviceProperties> pProperties);
typedef VkGetPhysicalDevicePropertiesDart = void Function(
    Pointer<Void> physicalDevice,
    Pointer<VkPhysicalDeviceProperties> pProperties);

// PFN_vkDestroyInstance = void (VkInstance, const AllocationCallbacks*)
typedef VkDestroyInstanceNative = Void Function(
    Pointer<Void> instance, Pointer<Void> pAllocator);
typedef VkDestroyInstanceDart = void Function(
    Pointer<Void> instance, Pointer<Void> pAllocator);

// --- Loader entry ----------------------------------------------------------

DynamicLibrary _loadVulkanLoader() {
  if (DynamicLibrary.process().providesSymbol('vkGetInstanceProcAddr')) {
    return DynamicLibrary.process();
  }
  try {
    return DynamicLibrary.open('vulkan-1.dll');
  } on ArgumentError {
    return DynamicLibrary.open('libvulkan.so.1');
  }
}

// Top-level `final` fields are lazily initialized on first access, so platform
// imports do not crash on OSes that lack the Vulkan loader.
final DynamicLibrary libVulkan = _loadVulkanLoader();

final VkGetInstanceProcAddrDart vkGetInstanceProcAddr = libVulkan
    .lookupFunction<VkGetInstanceProcAddrNative, VkGetInstanceProcAddrDart>(
        'vkGetInstanceProcAddr');

/// Wraps `vkGetInstanceProcAddr` with a Dart-friendly API. Pass `nullptr` for
/// `instance` to query global functions (vkCreateInstance etc.); pass the
/// instance pointer to query instance-level functions.
Pointer<Void> getInstanceProcAddress(Pointer<Void> instance, String name) {
  final namePtr = name.toNativeUtf8();
  final result = vkGetInstanceProcAddr(instance, namePtr);
  calloc.free(namePtr);
  return result;
}

// Concrete dispatch entry points used by the POC.

VkCreateInstanceDart loadVkCreateInstance() {
  final ptr = getInstanceProcAddress(nullptr, 'vkCreateInstance');
  if (ptr.address == 0) {
    throw StateError('vkCreateInstance not available from loader');
  }
  return Pointer<NativeFunction<VkCreateInstanceNative>>.fromAddress(ptr.address)
      .asFunction<VkCreateInstanceDart>();
}

VkEnumeratePhysicalDevicesDart loadVkEnumeratePhysicalDevices(
    Pointer<Void> instance) {
  final ptr = getInstanceProcAddress(instance, 'vkEnumeratePhysicalDevices');
  if (ptr.address == 0) {
    throw StateError('vkEnumeratePhysicalDevices not available');
  }
  return Pointer<NativeFunction<VkEnumeratePhysicalDevicesNative>>.fromAddress(
          ptr.address)
      .asFunction<VkEnumeratePhysicalDevicesDart>();
}

VkGetPhysicalDevicePropertiesDart loadVkGetPhysicalDeviceProperties(
    Pointer<Void> instance) {
  final ptr =
      getInstanceProcAddress(instance, 'vkGetPhysicalDeviceProperties');
  if (ptr.address == 0) {
    throw StateError('vkGetPhysicalDeviceProperties not available');
  }
  return Pointer<NativeFunction<VkGetPhysicalDevicePropertiesNative>>.fromAddress(
          ptr.address)
      .asFunction<VkGetPhysicalDevicePropertiesDart>();
}

VkDestroyInstanceDart loadVkDestroyInstance(Pointer<Void> instance) {
  final ptr = getInstanceProcAddress(instance, 'vkDestroyInstance');
  if (ptr.address == 0) {
    throw StateError('vkDestroyInstance not available');
  }
  return Pointer<NativeFunction<VkDestroyInstanceNative>>.fromAddress(ptr.address)
      .asFunction<VkDestroyInstanceDart>();
}