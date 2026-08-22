// ignore_for_file: camel_case_types, implementation_imports
library;

import 'dart:ffi';
import 'dart:math' as math;

import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_constants.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_library.dart';

import 'presenter.dart';
import 'x11_context.dart';

const int _vkStructureTypeXcbSurfaceCreateInfoKhr = 1000005000;
const int _vkStructureTypeSwapchainCreateInfoKhr = 1000001000;
const int _vkStructureTypePresentInfoKhr = 1000001001;
const int _vkPresentModeImmediateKhr = 0;
const int _vkPresentModeMailboxKhr = 1;
const int _vkPresentModeFifoKhr = 2;
const int _vkColorSpaceSrgbNonlinearKhr = 0;
const int _vkCompositeAlphaOpaqueBitKhr = 1;
const int _vkQueueGraphicsBit = 1;
const int _vkInfiniteTimeout = -1;

final class VkSurfaceKHR_T extends Opaque {}

final class VkSwapchainKHR_T extends Opaque {}

final class VkXcbSurfaceCreateInfoKHR extends Struct {
  @Uint32()
  external int sType;
  external Pointer<Void> pNext;
  @Uint32()
  external int flags;
  external Pointer<Void> connection;
  @Uint32()
  external int window;
}

final class VkSurfaceCapabilitiesKHR extends Struct {
  @Uint32()
  external int minImageCount;
  @Uint32()
  external int maxImageCount;
  external VkExtent2D currentExtent;
  external VkExtent2D minImageExtent;
  external VkExtent2D maxImageExtent;
  @Uint32()
  external int maxImageArrayLayers;
  @Uint32()
  external int supportedTransforms;
  @Uint32()
  external int currentTransform;
  @Uint32()
  external int supportedCompositeAlpha;
  @Uint32()
  external int supportedUsageFlags;
}

final class VkSurfaceFormatKHR extends Struct {
  @Uint32()
  external int format;
  @Uint32()
  external int colorSpace;
}

final class VkSwapchainCreateInfoKHR extends Struct {
  @Uint32()
  external int sType;
  external Pointer<Void> pNext;
  @Uint32()
  external int flags;
  external Pointer<VkSurfaceKHR_T> surface;
  @Uint32()
  external int minImageCount;
  @Uint32()
  external int imageFormat;
  @Uint32()
  external int imageColorSpace;
  external VkExtent2D imageExtent;
  @Uint32()
  external int imageArrayLayers;
  @Uint32()
  external int imageUsage;
  @Uint32()
  external int imageSharingMode;
  @Uint32()
  external int queueFamilyIndexCount;
  external Pointer<Uint32> pQueueFamilyIndices;
  @Uint32()
  external int preTransform;
  @Uint32()
  external int compositeAlpha;
  @Uint32()
  external int presentMode;
  @Uint32()
  external int clipped;
  external Pointer<VkSwapchainKHR_T> oldSwapchain;
}

final class VkPresentInfoKHR extends Struct {
  @Uint32()
  external int sType;
  external Pointer<Void> pNext;
  @Uint32()
  external int waitSemaphoreCount;
  external Pointer<Pointer<VkSemaphore_T>> pWaitSemaphores;
  @Uint32()
  external int swapchainCount;
  external Pointer<Pointer<VkSwapchainKHR_T>> pSwapchains;
  external Pointer<Uint32> pImageIndices;
  external Pointer<Int32> pResults;
}

typedef _CreateXcbSurfaceNative = Int32 Function(
  Pointer<VkInstance_T>,
  Pointer<VkXcbSurfaceCreateInfoKHR>,
  Pointer<Void>,
  Pointer<Pointer<VkSurfaceKHR_T>>,
);
typedef _CreateXcbSurfaceDart = int Function(
  Pointer<VkInstance_T>,
  Pointer<VkXcbSurfaceCreateInfoKHR>,
  Pointer<Void>,
  Pointer<Pointer<VkSurfaceKHR_T>>,
);
typedef _DestroySurfaceNative = Void Function(
  Pointer<VkInstance_T>,
  Pointer<VkSurfaceKHR_T>,
  Pointer<Void>,
);
typedef _DestroySurfaceDart = void Function(
  Pointer<VkInstance_T>,
  Pointer<VkSurfaceKHR_T>,
  Pointer<Void>,
);
typedef _GetSurfaceSupportNative = Int32 Function(
  Pointer<VkPhysicalDevice_T>,
  Uint32,
  Pointer<VkSurfaceKHR_T>,
  Pointer<Uint32>,
);
typedef _GetSurfaceSupportDart = int Function(
  Pointer<VkPhysicalDevice_T>,
  int,
  Pointer<VkSurfaceKHR_T>,
  Pointer<Uint32>,
);
typedef _GetSurfaceCapabilitiesNative = Int32 Function(
  Pointer<VkPhysicalDevice_T>,
  Pointer<VkSurfaceKHR_T>,
  Pointer<VkSurfaceCapabilitiesKHR>,
);
typedef _GetSurfaceCapabilitiesDart = int Function(
  Pointer<VkPhysicalDevice_T>,
  Pointer<VkSurfaceKHR_T>,
  Pointer<VkSurfaceCapabilitiesKHR>,
);
typedef _GetSurfaceFormatsNative = Int32 Function(
  Pointer<VkPhysicalDevice_T>,
  Pointer<VkSurfaceKHR_T>,
  Pointer<Uint32>,
  Pointer<VkSurfaceFormatKHR>,
);
typedef _GetSurfaceFormatsDart = int Function(
  Pointer<VkPhysicalDevice_T>,
  Pointer<VkSurfaceKHR_T>,
  Pointer<Uint32>,
  Pointer<VkSurfaceFormatKHR>,
);
typedef _GetPresentModesNative = Int32 Function(
  Pointer<VkPhysicalDevice_T>,
  Pointer<VkSurfaceKHR_T>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _GetPresentModesDart = int Function(
  Pointer<VkPhysicalDevice_T>,
  Pointer<VkSurfaceKHR_T>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _CreateSwapchainNative = Int32 Function(
  Pointer<VkDevice_T>,
  Pointer<VkSwapchainCreateInfoKHR>,
  Pointer<Void>,
  Pointer<Pointer<VkSwapchainKHR_T>>,
);
typedef _CreateSwapchainDart = int Function(
  Pointer<VkDevice_T>,
  Pointer<VkSwapchainCreateInfoKHR>,
  Pointer<Void>,
  Pointer<Pointer<VkSwapchainKHR_T>>,
);
typedef _DestroySwapchainNative = Void Function(
  Pointer<VkDevice_T>,
  Pointer<VkSwapchainKHR_T>,
  Pointer<Void>,
);
typedef _DestroySwapchainDart = void Function(
  Pointer<VkDevice_T>,
  Pointer<VkSwapchainKHR_T>,
  Pointer<Void>,
);
typedef _GetSwapchainImagesNative = Int32 Function(
  Pointer<VkDevice_T>,
  Pointer<VkSwapchainKHR_T>,
  Pointer<Uint32>,
  Pointer<Pointer<VkImage_T>>,
);
typedef _GetSwapchainImagesDart = int Function(
  Pointer<VkDevice_T>,
  Pointer<VkSwapchainKHR_T>,
  Pointer<Uint32>,
  Pointer<Pointer<VkImage_T>>,
);
typedef _AcquireNextImageNative = Int32 Function(
  Pointer<VkDevice_T>,
  Pointer<VkSwapchainKHR_T>,
  Uint64,
  Pointer<VkSemaphore_T>,
  Pointer<VkFence_T>,
  Pointer<Uint32>,
);
typedef _AcquireNextImageDart = int Function(
  Pointer<VkDevice_T>,
  Pointer<VkSwapchainKHR_T>,
  int,
  Pointer<VkSemaphore_T>,
  Pointer<VkFence_T>,
  Pointer<Uint32>,
);
typedef _QueuePresentNative = Int32 Function(
  Pointer<VkQueue_T>,
  Pointer<VkPresentInfoKHR>,
);
typedef _QueuePresentDart = int Function(
  Pointer<VkQueue_T>,
  Pointer<VkPresentInfoKHR>,
);
typedef _CmdClearColorImageNative = Void Function(
  Pointer<VkCommandBuffer_T>,
  Pointer<VkImage_T>,
  Uint32,
  Pointer<VkClearColorValue>,
  Uint32,
  Pointer<VkImageSubresourceRange>,
);
typedef _CmdClearColorImageDart = void Function(
  Pointer<VkCommandBuffer_T>,
  Pointer<VkImage_T>,
  int,
  Pointer<VkClearColorValue>,
  int,
  Pointer<VkImageSubresourceRange>,
);

final class VulkanPresenter implements FramePresenter {
  VulkanPresenter(this.width, this.height);

  final int width;
  final int height;
  late final X11BenchmarkContext _x11;
  late final VulkanLibrary _library;
  late final VulkanInstanceApi _instanceApi;
  late final VulkanDeviceApi _deviceApi;
  Pointer<VkInstance_T> _instance = nullptr;
  Pointer<VkSurfaceKHR_T> _surface = nullptr;
  Pointer<VkPhysicalDevice_T> _physicalDevice = nullptr;
  Pointer<VkDevice_T> _deviceHandle = nullptr;
  Pointer<VkQueue_T> _queue = nullptr;
  Pointer<VkSwapchainKHR_T> _swapchain = nullptr;
  Pointer<VkCommandPool_T> _commandPool = nullptr;
  Pointer<VkSemaphore_T> _imageAvailable = nullptr;
  Pointer<VkSemaphore_T> _renderFinished = nullptr;
  Pointer<VkFence_T> _fence = nullptr;
  late _DestroySurfaceDart _destroySurface;
  late _DestroySwapchainDart _destroySwapchain;
  late _AcquireNextImageDart _acquireNextImage;
  late _QueuePresentDart _queuePresent;
  late _CmdClearColorImageDart _cmdClearColorImage;
  final List<Pointer<VkImage_T>> _images = <Pointer<VkImage_T>>[];
  final List<Pointer<VkCommandBuffer_T>> _commands =
      <Pointer<VkCommandBuffer_T>>[];
  int _queueFamily = -1;
  String _deviceName = 'unknown Vulkan device';
  String _deviceType = 'unknown';
  String _presentMode = 'unknown';

  @override
  String get name => 'Vulkan XCB swapchain';
  @override
  String get device => '$_deviceName ($_deviceType)';
  @override
  String get mode => 'VK_KHR_xcb_surface, $_presentMode, 1 frame in flight';

  Pointer<Pointer<Char>> _strings(NativeArena arena, List<String> values) {
    final result = arena<Pointer<Char>>(values.length);
    for (var index = 0; index < values.length; index++) {
      result[index] = arena.allocateAscii(values[index]).cast<Char>();
    }
    return result;
  }

  Pointer<NativeFunction<N>> _instanceProc<N extends Function>(String name) {
    final address = _library.instanceProc(_instance, name);
    if (address == nullptr) throw StateError('Vulkan instance symbol: $name');
    return address.cast<NativeFunction<N>>();
  }

  Pointer<NativeFunction<N>> _deviceProc<N extends Function>(String name) {
    final native =
        NativeAllocator.instance.allocate(name.length + 1).cast<Uint8>();
    final bytes = name.codeUnits;
    for (var index = 0; index < bytes.length; index++) {
      native[index] = bytes[index];
    }
    native[bytes.length] = 0;
    try {
      final address =
          _instanceApi.getDeviceProcAddr(_deviceHandle, native.cast());
      if (address == nullptr) throw StateError('Vulkan device symbol: $name');
      return address.cast<NativeFunction<N>>();
    } finally {
      NativeAllocator.instance.free(native);
    }
  }

  void _check(int result, String operation) {
    if (vkFailed(result)) {
      throw StateError('$operation failed: ${vkResultName(result)}');
    }
  }

  @override
  void initialize() {
    _x11 = X11BenchmarkContext.create(
      width: width,
      height: height,
      title: 'POC-22 Vulkan',
      createGraphicsContext: false,
    );
    final load = VulkanLibrary.open();
    if (load.library == null) throw StateError(load.failureText);
    _library = load.library!;
    _createInstanceAndSurface();
    _selectPhysicalDevice();
    _createDevice();
    _bindDeviceWsi();
    _createSwapchain();
    _createCommands();
    _createSynchronization();
  }

  void _createInstanceAndSurface() {
    using((NativeArena arena) {
      final application = arena<VkApplicationInfo>();
      application.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_APPLICATION_INFO
        ..pApplicationName = arena.allocateAscii('dart_ui_poc_22').cast()
        ..applicationVersion = vkMakeApiVersion(1, 0, 0)
        ..pEngineName = arena.allocateAscii('dart_ui').cast()
        ..engineVersion = vkMakeApiVersion(1, 0, 0)
        ..apiVersion = vkMakeApiVersion(1, 0, 0);
      final extensions = <String>[
        vkKhrSurfaceExtension,
        'VK_KHR_xcb_surface',
      ];
      final info = arena<VkInstanceCreateInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        ..pApplicationInfo = application
        ..enabledExtensionCount = extensions.length
        ..ppEnabledExtensionNames = _strings(arena, extensions);
      final out = arena<Pointer<VkInstance_T>>();
      _check(_library.createInstance(info, nullptr, out), 'vkCreateInstance');
      _instance = out.value;
      _instanceApi = VulkanInstanceApi.bind(_library, _instance);
      final createSurface =
          _instanceProc<_CreateXcbSurfaceNative>('vkCreateXcbSurfaceKHR')
              .asFunction<_CreateXcbSurfaceDart>();
      _destroySurface =
          _instanceProc<_DestroySurfaceNative>('vkDestroySurfaceKHR')
              .asFunction<_DestroySurfaceDart>();
      final surfaceInfo = arena<VkXcbSurfaceCreateInfoKHR>();
      surfaceInfo.ref
        ..sType = _vkStructureTypeXcbSurfaceCreateInfoKhr
        ..connection = _x11.handle
        ..window = _x11.window;
      final surfaceOut = arena<Pointer<VkSurfaceKHR_T>>();
      _check(
        createSurface(_instance, surfaceInfo, nullptr, surfaceOut),
        'vkCreateXcbSurfaceKHR',
      );
      _surface = surfaceOut.value;
    });
  }

  void _selectPhysicalDevice() {
    final getSupport = _instanceProc<_GetSurfaceSupportNative>(
            'vkGetPhysicalDeviceSurfaceSupportKHR')
        .asFunction<_GetSurfaceSupportDart>();
    using((NativeArena arena) {
      final count = arena<Uint32>();
      _check(
        _instanceApi.enumeratePhysicalDevices(_instance, count, nullptr),
        'vkEnumeratePhysicalDevices(count)',
      );
      if (count.value == 0) throw StateError('Vulkan reports no devices');
      final devices = arena<Pointer<VkPhysicalDevice_T>>(count.value);
      _check(
        _instanceApi.enumeratePhysicalDevices(_instance, count, devices),
        'vkEnumeratePhysicalDevices',
      );
      final queueCount = arena<Uint32>();
      final supported = arena<Uint32>();
      for (var deviceIndex = 0; deviceIndex < count.value; deviceIndex++) {
        final candidate = devices[deviceIndex];
        _instanceApi.getPhysicalDeviceQueueFamilyProperties(
          candidate,
          queueCount,
          nullptr,
        );
        final queues = arena<VkQueueFamilyProperties>(queueCount.value);
        _instanceApi.getPhysicalDeviceQueueFamilyProperties(
          candidate,
          queueCount,
          queues,
        );
        for (var queueIndex = 0; queueIndex < queueCount.value; queueIndex++) {
          if ((queues[queueIndex].queueFlags & _vkQueueGraphicsBit) == 0) {
            continue;
          }
          _check(
            getSupport(candidate, queueIndex, _surface, supported),
            'vkGetPhysicalDeviceSurfaceSupportKHR',
          );
          if (supported.value == 0) continue;
          _physicalDevice = candidate;
          _queueFamily = queueIndex;
          final properties = arena<VkPhysicalDeviceProperties>();
          _instanceApi.getPhysicalDeviceProperties(candidate, properties);
          _deviceName = readFixedAscii(
            properties.ref.deviceName,
            vkMaxPhysicalDeviceNameSize,
          );
          _deviceType = vkPhysicalDeviceTypeName(properties.ref.deviceType);
          return;
        }
      }
    });
    if (_physicalDevice == nullptr) {
      throw StateError('no Vulkan graphics queue can present to XCB');
    }
  }

  void _createDevice() {
    using((NativeArena arena) {
      final priority = arena<Float>()..value = 1;
      final queueInfo = arena<VkDeviceQueueCreateInfo>();
      queueInfo.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
        ..queueFamilyIndex = _queueFamily
        ..queueCount = 1
        ..pQueuePriorities = priority;
      final extensions = <String>[vkKhrSwapchainExtension];
      final deviceInfo = arena<VkDeviceCreateInfo>();
      deviceInfo.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        ..queueCreateInfoCount = 1
        ..pQueueCreateInfos = queueInfo
        ..enabledExtensionCount = extensions.length
        ..ppEnabledExtensionNames = _strings(arena, extensions);
      final out = arena<Pointer<VkDevice_T>>();
      _check(
        _instanceApi.createDevice(_physicalDevice, deviceInfo, nullptr, out),
        'vkCreateDevice',
      );
      _deviceHandle = out.value;
      _deviceApi = VulkanDeviceApi.bind(_instanceApi, _deviceHandle);
      final queueOut = arena<Pointer<VkQueue_T>>();
      _deviceApi.getDeviceQueue(_deviceHandle, _queueFamily, 0, queueOut);
      _queue = queueOut.value;
    });
  }

  void _bindDeviceWsi() {
    _destroySwapchain =
        _deviceProc<_DestroySwapchainNative>('vkDestroySwapchainKHR')
            .asFunction<_DestroySwapchainDart>();
    _acquireNextImage =
        _deviceProc<_AcquireNextImageNative>('vkAcquireNextImageKHR')
            .asFunction<_AcquireNextImageDart>();
    _queuePresent = _deviceProc<_QueuePresentNative>('vkQueuePresentKHR')
        .asFunction<_QueuePresentDart>();
    _cmdClearColorImage =
        _deviceProc<_CmdClearColorImageNative>('vkCmdClearColorImage')
            .asFunction<_CmdClearColorImageDart>();
  }

  void _createSwapchain() {
    final getCapabilities = _instanceProc<_GetSurfaceCapabilitiesNative>(
            'vkGetPhysicalDeviceSurfaceCapabilitiesKHR')
        .asFunction<_GetSurfaceCapabilitiesDart>();
    final getFormats = _instanceProc<_GetSurfaceFormatsNative>(
            'vkGetPhysicalDeviceSurfaceFormatsKHR')
        .asFunction<_GetSurfaceFormatsDart>();
    final getModes = _instanceProc<_GetPresentModesNative>(
            'vkGetPhysicalDeviceSurfacePresentModesKHR')
        .asFunction<_GetPresentModesDart>();
    final createSwapchain =
        _deviceProc<_CreateSwapchainNative>('vkCreateSwapchainKHR')
            .asFunction<_CreateSwapchainDart>();
    final getImages =
        _deviceProc<_GetSwapchainImagesNative>('vkGetSwapchainImagesKHR')
            .asFunction<_GetSwapchainImagesDart>();
    using((NativeArena arena) {
      final capabilities = arena<VkSurfaceCapabilitiesKHR>();
      _check(
        getCapabilities(_physicalDevice, _surface, capabilities),
        'vkGetPhysicalDeviceSurfaceCapabilitiesKHR',
      );
      if ((capabilities.ref.supportedUsageFlags &
              VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT) ==
          0) {
        throw StateError('swapchain images cannot be transfer destinations');
      }
      final formatCount = arena<Uint32>();
      _check(
        getFormats(_physicalDevice, _surface, formatCount, nullptr),
        'vkGetPhysicalDeviceSurfaceFormatsKHR(count)',
      );
      final formats = arena<VkSurfaceFormatKHR>(formatCount.value);
      _check(
        getFormats(_physicalDevice, _surface, formatCount, formats),
        'vkGetPhysicalDeviceSurfaceFormatsKHR',
      );
      var format = formats[0].format;
      var colorSpace = formats[0].colorSpace;
      for (var index = 0; index < formatCount.value; index++) {
        if (formats[index].format == VkFormat.VK_FORMAT_B8G8R8A8_UNORM &&
            formats[index].colorSpace == _vkColorSpaceSrgbNonlinearKhr) {
          format = formats[index].format;
          colorSpace = formats[index].colorSpace;
          break;
        }
      }
      final modeCount = arena<Uint32>();
      _check(
        getModes(_physicalDevice, _surface, modeCount, nullptr),
        'vkGetPhysicalDeviceSurfacePresentModesKHR(count)',
      );
      final modes = arena<Uint32>(modeCount.value);
      _check(
        getModes(_physicalDevice, _surface, modeCount, modes),
        'vkGetPhysicalDeviceSurfacePresentModesKHR',
      );
      var presentMode = _vkPresentModeFifoKhr;
      for (var index = 0; index < modeCount.value; index++) {
        if (modes[index] == _vkPresentModeImmediateKhr) {
          presentMode = _vkPresentModeImmediateKhr;
          break;
        }
        if (modes[index] == _vkPresentModeMailboxKhr) {
          presentMode = _vkPresentModeMailboxKhr;
        }
      }
      _presentMode = switch (presentMode) {
        _vkPresentModeImmediateKhr => 'IMMEDIATE',
        _vkPresentModeMailboxKhr => 'MAILBOX',
        _ => 'FIFO',
      };
      final currentWidth = capabilities.ref.currentExtent.width;
      final currentHeight = capabilities.ref.currentExtent.height;
      final extentWidth = currentWidth == 0xffffffff
          ? math.max(
              capabilities.ref.minImageExtent.width,
              math.min(width, capabilities.ref.maxImageExtent.width),
            )
          : currentWidth;
      final extentHeight = currentHeight == 0xffffffff
          ? math.max(
              capabilities.ref.minImageExtent.height,
              math.min(height, capabilities.ref.maxImageExtent.height),
            )
          : currentHeight;
      var imageCount = capabilities.ref.minImageCount + 1;
      if (capabilities.ref.maxImageCount > 0) {
        imageCount = math.min(imageCount, capabilities.ref.maxImageCount);
      }
      final info = arena<VkSwapchainCreateInfoKHR>();
      info.ref
        ..sType = _vkStructureTypeSwapchainCreateInfoKhr
        ..surface = _surface
        ..minImageCount = imageCount
        ..imageFormat = format
        ..imageColorSpace = colorSpace
        ..imageExtent.width = extentWidth
        ..imageExtent.height = extentHeight
        ..imageArrayLayers = 1
        ..imageUsage = VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT
        ..imageSharingMode = VkSharingMode.VK_SHARING_MODE_EXCLUSIVE
        ..preTransform = capabilities.ref.currentTransform
        ..compositeAlpha = _chooseCompositeAlpha(
          capabilities.ref.supportedCompositeAlpha,
        )
        ..presentMode = presentMode
        ..clipped = vkTrue
        ..oldSwapchain = nullptr;
      final out = arena<Pointer<VkSwapchainKHR_T>>();
      _check(
        createSwapchain(_deviceHandle, info, nullptr, out),
        'vkCreateSwapchainKHR',
      );
      _swapchain = out.value;
      final count = arena<Uint32>();
      _check(
        getImages(_deviceHandle, _swapchain, count, nullptr),
        'vkGetSwapchainImagesKHR(count)',
      );
      final images = arena<Pointer<VkImage_T>>(count.value);
      _check(
        getImages(_deviceHandle, _swapchain, count, images),
        'vkGetSwapchainImagesKHR',
      );
      for (var index = 0; index < count.value; index++) {
        _images.add(images[index]);
      }
    });
  }

  int _chooseCompositeAlpha(int supported) {
    if ((supported & _vkCompositeAlphaOpaqueBitKhr) != 0) {
      return _vkCompositeAlphaOpaqueBitKhr;
    }
    return supported & -supported;
  }

  void _createCommands() {
    using((NativeArena arena) {
      final poolInfo = arena<VkCommandPoolCreateInfo>();
      poolInfo.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        ..flags = VkCommandPoolCreateFlagBits
            .VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
        ..queueFamilyIndex = _queueFamily;
      final poolOut = arena<Pointer<VkCommandPool_T>>();
      _check(
        _deviceApi.createCommandPool(_deviceHandle, poolInfo, nullptr, poolOut),
        'vkCreateCommandPool',
      );
      _commandPool = poolOut.value;
      final allocateInfo = arena<VkCommandBufferAllocateInfo>();
      allocateInfo.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        ..commandPool = _commandPool
        ..level = VkCommandBufferLevel.VK_COMMAND_BUFFER_LEVEL_PRIMARY
        ..commandBufferCount = _images.length;
      final commandOut = arena<Pointer<VkCommandBuffer_T>>(_images.length);
      _check(
        _deviceApi.allocateCommandBuffers(
          _deviceHandle,
          allocateInfo,
          commandOut,
        ),
        'vkAllocateCommandBuffers',
      );
      for (var index = 0; index < _images.length; index++) {
        final command = commandOut[index];
        _commands.add(command);
        _recordCommand(arena, command, _images[index], index);
      }
    });
  }

  void _recordCommand(
    NativeArena arena,
    Pointer<VkCommandBuffer_T> command,
    Pointer<VkImage_T> image,
    int variant,
  ) {
    final begin = arena<VkCommandBufferBeginInfo>();
    begin.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
      ..flags = VkCommandBufferUsageFlagBits
          .VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT;
    _check(
        _deviceApi.beginCommandBuffer(command, begin), 'vkBeginCommandBuffer');
    final barrier = arena<VkImageMemoryBarrier>();
    barrier.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
      ..oldLayout = VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED
      ..newLayout = VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      ..srcQueueFamilyIndex = vkQueueFamilyIgnored
      ..dstQueueFamilyIndex = vkQueueFamilyIgnored
      ..image = image
      ..dstAccessMask = VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT
      ..subresourceRange.aspectMask =
          VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT
      ..subresourceRange.levelCount = 1
      ..subresourceRange.layerCount = 1;
    final range = arena<VkImageSubresourceRange>();
    range.ref
      ..aspectMask = VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT
      ..levelCount = 1
      ..layerCount = 1;
    _deviceApi.cmdPipelineBarrier(
      command,
      VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
      VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
      0,
      0,
      nullptr,
      0,
      nullptr,
      1,
      barrier,
    );
    final color = arena<VkClearColorValue>();
    color.ref.float32[0] = variant.isEven ? 0.92 : 0.12;
    color.ref.float32[1] = variant.isEven ? 0.24 : 0.62;
    color.ref.float32[2] = variant.isEven ? 0.10 : 0.88;
    color.ref.float32[3] = 1;
    _cmdClearColorImage(
      command,
      image,
      VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      color,
      1,
      range,
    );
    barrier.ref
      ..srcAccessMask = VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT
      ..dstAccessMask = 0
      ..oldLayout = VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      ..newLayout = VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    _deviceApi.cmdPipelineBarrier(
      command,
      VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
      VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
      0,
      0,
      nullptr,
      0,
      nullptr,
      1,
      barrier,
    );
    _check(_deviceApi.endCommandBuffer(command), 'vkEndCommandBuffer');
  }

  void _createSynchronization() {
    using((NativeArena arena) {
      final semaphoreInfo = arena<VkSemaphoreCreateInfo>();
      semaphoreInfo.ref.sType =
          VkStructureType.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
      final semaphoreOut = arena<Pointer<VkSemaphore_T>>();
      _check(
        _deviceApi.createSemaphore(
          _deviceHandle,
          semaphoreInfo,
          nullptr,
          semaphoreOut,
        ),
        'vkCreateSemaphore(imageAvailable)',
      );
      _imageAvailable = semaphoreOut.value;
      semaphoreOut.value = nullptr;
      _check(
        _deviceApi.createSemaphore(
          _deviceHandle,
          semaphoreInfo,
          nullptr,
          semaphoreOut,
        ),
        'vkCreateSemaphore(renderFinished)',
      );
      _renderFinished = semaphoreOut.value;
      final fenceInfo = arena<VkFenceCreateInfo>();
      fenceInfo.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        ..flags = VkFenceCreateFlagBits.VK_FENCE_CREATE_SIGNALED_BIT;
      final fenceOut = arena<Pointer<VkFence_T>>();
      _check(
        _deviceApi.createFence(_deviceHandle, fenceInfo, nullptr, fenceOut),
        'vkCreateFence',
      );
      _fence = fenceOut.value;
    });
  }

  @override
  void present(int frameNumber) {
    using((NativeArena arena) {
      final fenceList = arena<Pointer<VkFence_T>>()..value = _fence;
      _check(
        _deviceApi.waitForFences(
          _deviceHandle,
          1,
          fenceList,
          vkTrue,
          _vkInfiniteTimeout,
        ),
        'vkWaitForFences',
      );
      _check(
        _deviceApi.resetFences(_deviceHandle, 1, fenceList),
        'vkResetFences',
      );
      final imageIndex = arena<Uint32>();
      _check(
        _acquireNextImage(
          _deviceHandle,
          _swapchain,
          _vkInfiniteTimeout,
          _imageAvailable,
          nullptr,
          imageIndex,
        ),
        'vkAcquireNextImageKHR',
      );
      final waitSemaphores = arena<Pointer<VkSemaphore_T>>()
        ..value = _imageAvailable;
      final signalSemaphores = arena<Pointer<VkSemaphore_T>>()
        ..value = _renderFinished;
      final waitStage = arena<Uint32>()
        ..value = VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT;
      final command = arena<Pointer<VkCommandBuffer_T>>()
        ..value = _commands[imageIndex.value];
      final submit = arena<VkSubmitInfo>();
      submit.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_SUBMIT_INFO
        ..waitSemaphoreCount = 1
        ..pWaitSemaphores = waitSemaphores
        ..pWaitDstStageMask = waitStage
        ..commandBufferCount = 1
        ..pCommandBuffers = command
        ..signalSemaphoreCount = 1
        ..pSignalSemaphores = signalSemaphores;
      _check(
        _deviceApi.queueSubmit(_queue, 1, submit, _fence),
        'vkQueueSubmit',
      );
      final swapchain = arena<Pointer<VkSwapchainKHR_T>>()..value = _swapchain;
      final present = arena<VkPresentInfoKHR>();
      present.ref
        ..sType = _vkStructureTypePresentInfoKhr
        ..waitSemaphoreCount = 1
        ..pWaitSemaphores = signalSemaphores
        ..swapchainCount = 1
        ..pSwapchains = swapchain
        ..pImageIndices = imageIndex;
      _check(_queuePresent(_queue, present), 'vkQueuePresentKHR');
    });
  }

  @override
  void finish() {
    if (_deviceHandle != nullptr) {
      _check(_deviceApi.deviceWaitIdle(_deviceHandle), 'vkDeviceWaitIdle');
    }
  }

  @override
  void dispose() {
    if (_deviceHandle != nullptr) {
      _deviceApi.deviceWaitIdle(_deviceHandle);
      if (_fence != nullptr) {
        _deviceApi.destroyFence(_deviceHandle, _fence, nullptr);
      }
      if (_renderFinished != nullptr) {
        _deviceApi.destroySemaphore(_deviceHandle, _renderFinished, nullptr);
      }
      if (_imageAvailable != nullptr) {
        _deviceApi.destroySemaphore(_deviceHandle, _imageAvailable, nullptr);
      }
      if (_commandPool != nullptr) {
        _deviceApi.destroyCommandPool(_deviceHandle, _commandPool, nullptr);
      }
      if (_swapchain != nullptr) {
        _destroySwapchain(_deviceHandle, _swapchain, nullptr);
      }
      _deviceApi.destroyDevice(_deviceHandle, nullptr);
      _deviceHandle = nullptr;
    }
    if (_surface != nullptr) {
      _destroySurface(_instance, _surface, nullptr);
      _surface = nullptr;
    }
    if (_instance != nullptr) {
      _instanceApi.destroyInstance(_instance, nullptr);
      _instance = nullptr;
    }
    _x11.dispose();
  }
}
