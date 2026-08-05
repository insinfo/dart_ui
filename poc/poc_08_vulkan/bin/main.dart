import 'dart:io';

import 'package:poc_08_vulkan/vulkan_probe.dart';

void main(List<String> args) {
  print('------------------------------------------------');
  print('  POC-08: Vulkan Loader via FFI (Linux+Windows) ');
  print('  No C/C++ wrapper, just dart:ffi + libvulkan   ');
  print('------------------------------------------------\n');

  if (!Platform.isLinux && !Platform.isWindows) {
    print('Error: POC-08 only runs on Linux or Windows. '
        'macOS is not supported because the loader is shipped with the Vulkan '
        'SDK via MoltenVK and is not present on the standard image.');
    exit(1);
  }

  final result = runVulkanProbe();
  print('\n$result');

  if (!result.allPassed) {
    stderr.writeln('[POC-08] Vulkan validation failed.');
    exit(1);
  }
  exit(0);
}
