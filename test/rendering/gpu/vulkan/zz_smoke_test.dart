import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_backend.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_instance.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_library.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_surface_descriptor.dart';
import 'package:test/test.dart';

void main() {
  test('window smoke', () async {
    final load = VulkanLibrary.open();
    final lib = load.library;
    if (lib == null) { markTestSkipped('no loader'); return; }
    final attempt = VulkanInstance.create(lib,
        options: const VulkanInstanceOptions(
            validation: true,
            surfaces: <VulkanSurfacePlatform>{VulkanSurfacePlatform.win32}));
    final instance = attempt.instance;
    if (instance == null) { markTestSkipped('no instance: ${attempt.failureText}'); return; }
    print('EXT=${instance.enabledExtensions}');
    print('SUPPORTS_WIN32=${instance.supportsSurface(VulkanSurfacePlatform.win32)}');

    final backend = Win32WindowingBackend();
    await backend.initialize();
    final window = await backend.createWindow(
      const WindowOptions(title: 'vk', size: Size(160, 120), visible: false),
    ) as Win32Window;
    print('HWND=${window.handle} ${window.pixelSize}');

    final device = VulkanRenderDevice.adoptInstance(instance,
        enablePresentation: true, enableExperimentalSparseStrips: true);
    print('canPresent=${device.gpu.canPresent} family=${device.gpu.queueFamily}/${device.gpu.presentQueueFamily}');

    final target = device.createTarget(VulkanWindowSurfaceDescriptor(
      platform: VulkanSurfacePlatform.win32,
      windowHandle: window.handle,
      pixelWidth: 160,
      pixelHeight: 120,
    )) as VulkanWindowTarget;
    print('failure=${target.creationFailure}');
    print('config=${target.configuration}');
    print('images=${target.imageCount} canCapture=${target.canCaptureFrames}');

    target.captureFrames = true;
    for (var i = 0; i < 5; i++) {
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFF3366CC);
      list.drawRect(10, 10, 100, 80, paint);
      final result = await target.renderDisplayList(list, clearColor: 0xFF000000);
      print('frame $i -> ${result.status} ${result.diagnostic ?? ''}');
    }
    final fb = target.framebuffer;
    print('fb=${fb?.width}x${fb?.height} ${fb?.format}');
    if (fb != null) {
      final o = fb.offsetOf(50, 50);
      print('pixel(50,50)=${fb.pixels.sublist(o, o + 4)}');
    }
    target.resize(200, 150, 1.0);
    print('after resize config=${target.configuration} failure=${target.creationFailure}');
    final r2 = await target.renderDisplayList(DisplayList(), clearColor: 0xFF102030);
    print('post-resize frame -> ${r2.status}');

    print('VALIDATION=${instance.validationEnabled} problems=${instance.problems}');
    target.dispose();
    device.dispose();
    window.close();
    await backend.shutdown();
    instance.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
