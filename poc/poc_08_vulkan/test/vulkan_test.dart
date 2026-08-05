import 'dart:ffi';
import 'dart:io';

import 'package:poc_08_vulkan/vulkan_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('Vulkan bindings resolve Dart-side metadata on every platform', () {
    // Constants are pure-Dart and must always resolve regardless of platform.
    expect(vkSuccess, 0);
    expect(vkErrorIncompatibleDriver, -9);
    expect(vkStructureTypeApplicationInfo, 0);
    expect(vkStructureTypeInstanceCreateInfo, 1);
    expect(vkMakeVersion(1, 0, 0), 0x400000);
    expect(vkApiVersion1_0, 0x400000);
    expect(vkApiVersion1_1, vkMakeVersion(1, 1, 0));
    expect(vkApiVersion1_2, vkMakeVersion(1, 2, 0));
    expect(vkMaxPhysicalDeviceNameSize, 256);
    expect(vkUuidSize, 16);
    expect(vkPhysicalDeviceTypeNames, hasLength(5));
  });

  test('Vulkan loader symbols resolve on Linux or Windows', () {
    if (!Platform.isLinux && !Platform.isWindows) {
      print('Skipping loader test on non-Linux/Windows platform.');
      return;
    }

    // Force the late field to evaluate; this should not throw.
    // ignore: unnecessary_statements
    vkGetInstanceProcAddr;
    // `getInstanceProcAddress` is the Dart-friendly wrapper around the
    // function; it should resolve to a non-null value for a known global
    // symbol.
    const knownGlobal = 'vkCreateInstance';
    final ptr = getInstanceProcAddress(nullptr, knownGlobal);
    expect(ptr.address, isNot(0),
        reason: 'Expected vkCreateInstance to resolve via the loader');
  },
      skip: (!Platform.isLinux && !Platform.isWindows)
          ? 'Vulkan loader is only required on Linux/Windows'
          : false);
}
