// POC-08: end-to-end Vulkan bootstrap.
//
// Flow exercised:
//   1. Load the system Vulkan loader (libvulkan.so.1 / vulkan-1.dll).
//   2. Use `vkGetInstanceProcAddr` to fetch `vkCreateInstance`.
//   3. Build a minimal `VkInstanceCreateInfo` referencing a `VkApplicationInfo`
//      that targets Vulkan 1.0 (the lowest common denominator supported by
//      lavapipe, SwiftShader, native drivers, ...).
//   4. Create the instance, then use `vkGetInstanceProcAddr` again to fetch
//      `vkEnumeratePhysicalDevices`, `vkGetPhysicalDeviceProperties` and
//      `vkDestroyInstance`.
//   5. Enumerate physical devices, query properties for each, and print a
//      human-readable summary.
//   6. Destroy the instance and confirm cleanup.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'vulkan_bindings.dart';

class VulkanProbeResult {
  bool loaderLoaded;
  bool instanceCreated;
  bool devicesEnumerated;
  bool propertiesRead;
  bool instanceDestroyed;
  final List<String> deviceSummaries;
  String? diagnostic;

  VulkanProbeResult({
    required this.loaderLoaded,
    required this.instanceCreated,
    required this.devicesEnumerated,
    required this.propertiesRead,
    required this.instanceDestroyed,
    required this.deviceSummaries,
    this.diagnostic,
  });

  bool get allPassed =>
      loaderLoaded &&
      instanceCreated &&
      devicesEnumerated &&
      propertiesRead &&
      instanceDestroyed;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('POC-08 Vulkan status:')
      ..writeln('  loader loaded      : $loaderLoaded')
      ..writeln('  instance created   : $instanceCreated')
      ..writeln('  devices enumerated : $devicesEnumerated')
      ..writeln('  properties readable: $propertiesRead')
      ..writeln('  instance destroyed : $instanceDestroyed');
    if (deviceSummaries.isNotEmpty) {
      buffer.writeln('  devices:');
      for (final line in deviceSummaries) {
        buffer.writeln('    - $line');
      }
    }
    if (diagnostic != null) {
      buffer.writeln('  diagnostic: $diagnostic');
    }
    return buffer.toString();
  }
}

VulkanProbeResult runVulkanProbe() {
  final result = VulkanProbeResult(
    loaderLoaded: false,
    instanceCreated: false,
    devicesEnumerated: false,
    propertiesRead: false,
    instanceDestroyed: false,
    deviceSummaries: <String>[],
  );

  print('[Vulkan] Loading system Vulkan loader...');
  try {
    libVulkan;
    // Touching `vkGetInstanceProcAddr` lazily evaluates the late field, which
    // may also raise an ArgumentError from the lookupFunction call.
    // ignore: unnecessary_statements
    vkGetInstanceProcAddr;
  } on ArgumentError catch (e) {
    result.diagnostic = 'vkGetInstanceProcAddr lookup failed: $e';
    return result;
  }
  result.loaderLoaded = true;
  print('[Vulkan] Loader ready.');

  // Build VkApplicationInfo.
  final appInfoPtr = calloc<VkApplicationInfo>();
  final applicationNamePtr = 'dart_ui_poc_08'.toNativeUtf8();
  final engineNamePtr = 'dart_ui'.toNativeUtf8();
  appInfoPtr.ref
    ..sType = vkStructureTypeApplicationInfo
    ..pNext = nullptr
    ..pApplicationName = applicationNamePtr
    ..applicationVersion = vkMakeVersion(0, 1, 0)
    ..pEngineName = engineNamePtr
    ..engineVersion = vkMakeVersion(0, 1, 0)
    ..apiVersion = vkApiVersion1_0;

  // Build VkInstanceCreateInfo.
  final instanceCreateInfoPtr = calloc<VkInstanceCreateInfo>();
  instanceCreateInfoPtr.ref
    ..sType = vkStructureTypeInstanceCreateInfo
    ..pNext = nullptr
    ..flags = 0
    ..pApplicationInfo = appInfoPtr
    ..enabledLayerCount = 0
    ..ppEnabledLayerNames = nullptr
    ..enabledExtensionCount = 0
    ..ppEnabledExtensionNames = nullptr;

  // Instance pointer out-parameter.
  final instanceHandlePtr = calloc<Pointer<Void>>();

  print('[Vulkan] Creating VkInstance...');
  final VkCreateInstanceDart vkCreateInstance;
  try {
    vkCreateInstance = loadVkCreateInstance();
  } on StateError catch (e) {
    result.diagnostic = 'vkCreateInstance unavailable: $e';
    _freeBootstrapAllocations(
      appInfoPtr,
      applicationNamePtr,
      engineNamePtr,
      instanceCreateInfoPtr,
      instanceHandlePtr,
    );
    return result;
  }

  final createResult =
      vkCreateInstance(instanceCreateInfoPtr.cast(), nullptr, instanceHandlePtr);
  if (createResult != vkSuccess) {
    result.diagnostic = 'vkCreateInstance returned $createResult '
        '(driver may be missing — CI Linux expects lavapipe).';
    _freeBootstrapAllocations(
      appInfoPtr,
      applicationNamePtr,
      engineNamePtr,
      instanceCreateInfoPtr,
      instanceHandlePtr,
    );
    return result;
  }
  result.instanceCreated = true;
  final instance = instanceHandlePtr.value;
  print('[Vulkan] Instance created (${instance.address}).');

  // Enumerate physical devices using the two-call pattern.
  final VkEnumeratePhysicalDevicesDart vkEnumeratePhysicalDevices;
  try {
    vkEnumeratePhysicalDevices = loadVkEnumeratePhysicalDevices(instance);
  } on StateError catch (e) {
    result.diagnostic = 'vkEnumeratePhysicalDevices unavailable: $e';
    _destroyInstanceAndFree(
      instance,
      appInfoPtr,
      applicationNamePtr,
      engineNamePtr,
      instanceCreateInfoPtr,
      instanceHandlePtr,
    );
    return result;
  }

  final deviceCountPtr = calloc<Uint32>();
  print('[Vulkan] First enumeration call (count query)...');
  var enumResult =
      vkEnumeratePhysicalDevices(instance, deviceCountPtr, nullptr);
  if (enumResult != vkSuccess) {
    result.diagnostic =
        'vkEnumeratePhysicalDevices (count pass) returned $enumResult.';
    _destroyInstanceAndFree(
      instance,
      appInfoPtr,
      applicationNamePtr,
      engineNamePtr,
      instanceCreateInfoPtr,
      instanceHandlePtr,
      deviceCountPtr: deviceCountPtr,
    );
    return result;
  }
  final deviceCount = deviceCountPtr.value;
  print('[Vulkan] Found $deviceCount physical device(s).');
  if (deviceCount == 0) {
    result.devicesEnumerated = false;
    result.diagnostic = 'vkEnumeratePhysicalDevices reported 0 devices.';
    _destroyInstanceAndFree(
      instance,
      appInfoPtr,
      applicationNamePtr,
      engineNamePtr,
      instanceCreateInfoPtr,
      instanceHandlePtr,
      deviceCountPtr: deviceCountPtr,
    );
    result.instanceDestroyed = true;
    return result;
  }

  // Allocate an array of device handles and re-issue enumeration.
  final devicesArrayPtr = calloc<Pointer<Void>>(deviceCount);
  enumResult =
      vkEnumeratePhysicalDevices(instance, deviceCountPtr, devicesArrayPtr);
  if (enumResult != vkSuccess) {
    result.diagnostic =
        'vkEnumeratePhysicalDevices (retrieval pass) returned $enumResult.';
    _destroyInstanceAndFree(
      instance,
      appInfoPtr,
      applicationNamePtr,
      engineNamePtr,
      instanceCreateInfoPtr,
      instanceHandlePtr,
      deviceCountPtr: deviceCountPtr,
      devicesArrayPtr: devicesArrayPtr,
    );
    return result;
  }
  result.devicesEnumerated = true;

  // Query properties for each device.
  final VkGetPhysicalDevicePropertiesDart vkGetPhysicalDeviceProperties;
  try {
    vkGetPhysicalDeviceProperties =
        loadVkGetPhysicalDeviceProperties(instance);
  } on StateError catch (e) {
    result.diagnostic = 'vkGetPhysicalDeviceProperties unavailable: $e';
    _destroyInstanceAndFree(
      instance,
      appInfoPtr,
      applicationNamePtr,
      engineNamePtr,
      instanceCreateInfoPtr,
      instanceHandlePtr,
      deviceCountPtr: deviceCountPtr,
      devicesArrayPtr: devicesArrayPtr,
    );
    return result;
  }

  // The full VkPhysicalDeviceProperties struct is larger than the partial
  // declaration we use (it ends with VkPhysicalDeviceLimits + sparseProperties).
  // We allocate a generous scratch buffer and cast it for reads.
  const int kPropertiesBufferSizeBytes = 1024;
  for (var i = 0; i < deviceCount; i++) {
    final deviceHandle = devicesArrayPtr[i];
    final propsBuf =
        calloc<Uint8>(kPropertiesBufferSizeBytes);
    final props = propsBuf.cast<VkPhysicalDeviceProperties>();
    vkGetPhysicalDeviceProperties(deviceHandle, props);

    final api = props.ref.apiVersion;
    final driver = props.ref.driverVersion;
    final vendor = props.ref.vendorID;
    final device = props.ref.deviceID;
    final type = props.ref.deviceType;
    final typeName = vkPhysicalDeviceTypeNames[type] ?? 'UNKNOWN($type)';
    // deviceName is the Array<Uint8> at byte offset 20.
    final namePtr = (propsBuf + 20).cast<Utf8>();
    final deviceName = namePtr.toDartString();

    print('[Vulkan] device[$i]: $deviceName '
        '(type=$typeName, api=$api, driver=$driver, '
        'vendor=0x${vendor.toRadixString(16).padLeft(8, '0')}, '
        'device=0x${device.toRadixString(16).padLeft(8, '0')})');

    result.deviceSummaries.add('$deviceName ($typeName)');
    result.propertiesRead = true;
    calloc.free(propsBuf);
  }

  // Destroy instance and free all allocations.
  print('[Vulkan] Destroying instance...');
  final vkDestroyInstance = loadVkDestroyInstance(instance);
  vkDestroyInstance(instance, nullptr);
  result.instanceDestroyed = true;
  print('[Vulkan] Instance destroyed.');

  _freeBootstrapAllocations(
    appInfoPtr,
    applicationNamePtr,
    engineNamePtr,
    instanceCreateInfoPtr,
    instanceHandlePtr,
    deviceCountPtr: deviceCountPtr,
    devicesArrayPtr: devicesArrayPtr,
  );
  return result;
}

void _destroyInstanceAndFree(
  Pointer<Void> instance,
  Pointer<VkApplicationInfo> appInfoPtr,
  Pointer<Utf8> applicationNamePtr,
  Pointer<Utf8> engineNamePtr,
  Pointer<VkInstanceCreateInfo> instanceCreateInfoPtr,
  Pointer<Pointer<Void>> instanceHandlePtr, {
  Pointer<Uint32>? deviceCountPtr,
  Pointer<Pointer<Void>>? devicesArrayPtr,
}) {
  final vkDestroyInstance = loadVkDestroyInstance(instance);
  vkDestroyInstance(instance, nullptr);
  _freeBootstrapAllocations(
    appInfoPtr,
    applicationNamePtr,
    engineNamePtr,
    instanceCreateInfoPtr,
    instanceHandlePtr,
    deviceCountPtr: deviceCountPtr,
    devicesArrayPtr: devicesArrayPtr,
  );
}

void _freeBootstrapAllocations(
  Pointer<VkApplicationInfo> appInfoPtr,
  Pointer<Utf8> applicationNamePtr,
  Pointer<Utf8> engineNamePtr,
  Pointer<VkInstanceCreateInfo> instanceCreateInfoPtr,
  Pointer<Pointer<Void>> instanceHandlePtr, {
  Pointer<Uint32>? deviceCountPtr,
  Pointer<Pointer<Void>>? devicesArrayPtr,
}) {
  calloc.free(appInfoPtr);
  calloc.free(applicationNamePtr);
  calloc.free(engineNamePtr);
  calloc.free(instanceCreateInfoPtr);
  calloc.free(instanceHandlePtr);
  if (deviceCountPtr != null) {
    calloc.free(deviceCountPtr);
  }
  if (devicesArrayPtr != null) {
    calloc.free(devicesArrayPtr);
  }
}