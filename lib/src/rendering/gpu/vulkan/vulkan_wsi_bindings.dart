/// The window-system commands, resolved separately from the core tables.
///
/// `vulkan_bindings.dart` resolves the commands a device cannot render without
/// and throws on the first one missing, which is right for core Vulkan 1.0: a
/// driver without `vkCmdDraw` is not a driver. **Every command here is
/// different in kind.** `VK_KHR_surface` and `VK_KHR_swapchain` are extensions,
/// they are absent on a headless ICD by design, and a machine without them is a
/// machine that renders offscreen rather than a machine that is broken.
///
/// So these tables:
///
///   * live in their own file, so [VulkanInstanceApi.requiredSymbols] keeps
///     meaning "cannot render without", and `vulkan_symbol_test.dart` keeps
///     being able to assert that every name in it resolves;
///   * are **nullable as a whole**. [VulkanSurfaceApi.bind] returns null when
///     the surface commands are not all there, rather than a table with holes
///     in it, because a surface that can be created and not destroyed is worse
///     than no surface at all;
///   * report by returning, never by throwing. A missing extension is the
///     ordinary case on a CI container, and it becomes a
///     [BackendDiagnostic] naming what was missing.
///
/// ## The platform creators are four fields, not a map
///
/// `vkCreateWin32SurfaceKHR` and `vkCreateXcbSurfaceKHR` have *different*
/// signatures - each takes its own create-info structure - and the whole point
/// of the parameterised typedefs in `vulkan_bindings.dart` is that a create
/// command cannot be handed the wrong structure. Collapsing them into one map
/// of `Pointer<Void>`-taking functions would throw that away to save a switch,
/// and the switch is the same three lines that pick the structure anyway.
library;

import 'dart:ffi';

import '../../../ffi/native_memory.dart';
import 'vulkan_bindings.dart';
import 'vulkan_constants.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_library.dart';
import 'vulkan_surface_descriptor.dart';
import 'vulkan_wsi_platform.dart';

// ---------------------------------------------------------------------------
// Signatures
// ---------------------------------------------------------------------------

/// `vkCreate*SurfaceKHR`. Instance-level, so the first parameter is a
/// `VkInstance` where the device-level [VkCreateNative] takes a `VkDevice`.
typedef VkCreateSurfaceNative<I extends NativeType> = Int32 Function(
    Pointer<VkInstance_T>,
    Pointer<I>,
    Pointer<Void>,
    Pointer<Pointer<VkSurfaceKHR_T>>);
typedef VkCreateSurfaceDart<I extends NativeType> = int Function(
    Pointer<VkInstance_T>,
    Pointer<I>,
    Pointer<Void>,
    Pointer<Pointer<VkSurfaceKHR_T>>);

typedef VkDestroySurfaceNative = Void Function(
    Pointer<VkInstance_T>, Pointer<VkSurfaceKHR_T>, Pointer<Void>);
typedef VkDestroySurfaceDart = void Function(
    Pointer<VkInstance_T>, Pointer<VkSurfaceKHR_T>, Pointer<Void>);

typedef VkGetSurfaceSupportNative = Int32 Function(Pointer<VkPhysicalDevice_T>,
    Uint32, Pointer<VkSurfaceKHR_T>, Pointer<Uint32>);
typedef VkGetSurfaceSupportDart = int Function(
    Pointer<VkPhysicalDevice_T>, int, Pointer<VkSurfaceKHR_T>, Pointer<Uint32>);

typedef VkGetSurfaceCapabilitiesNative = Int32 Function(
    Pointer<VkPhysicalDevice_T>,
    Pointer<VkSurfaceKHR_T>,
    Pointer<VkSurfaceCapabilitiesKHR>);
typedef VkGetSurfaceCapabilitiesDart = int Function(Pointer<VkPhysicalDevice_T>,
    Pointer<VkSurfaceKHR_T>, Pointer<VkSurfaceCapabilitiesKHR>);

/// The two-call enumeration shape: null output means "tell me the count".
typedef VkEnumerateSurfaceNative<T extends NativeType> = Int32 Function(
    Pointer<VkPhysicalDevice_T>,
    Pointer<VkSurfaceKHR_T>,
    Pointer<Uint32>,
    Pointer<T>);
typedef VkEnumerateSurfaceDart<T extends NativeType> = int Function(
    Pointer<VkPhysicalDevice_T>,
    Pointer<VkSurfaceKHR_T>,
    Pointer<Uint32>,
    Pointer<T>);

typedef VkGetWin32PresentationSupportNative = Uint32 Function(
    Pointer<VkPhysicalDevice_T>, Uint32);
typedef VkGetWin32PresentationSupportDart = int Function(
    Pointer<VkPhysicalDevice_T>, int);

typedef VkGetSwapchainImagesNative = Int32 Function(Pointer<VkDevice_T>,
    Pointer<VkSwapchainKHR_T>, Pointer<Uint32>, Pointer<Pointer<VkImage_T>>);
typedef VkGetSwapchainImagesDart = int Function(Pointer<VkDevice_T>,
    Pointer<VkSwapchainKHR_T>, Pointer<Uint32>, Pointer<Pointer<VkImage_T>>);

typedef VkAcquireNextImageNative = Int32 Function(
    Pointer<VkDevice_T>,
    Pointer<VkSwapchainKHR_T>,
    Uint64,
    Pointer<VkSemaphore_T>,
    Pointer<VkFence_T>,
    Pointer<Uint32>);
typedef VkAcquireNextImageDart = int Function(
    Pointer<VkDevice_T>,
    Pointer<VkSwapchainKHR_T>,
    int,
    Pointer<VkSemaphore_T>,
    Pointer<VkFence_T>,
    Pointer<Uint32>);

typedef VkQueuePresentNative = Int32 Function(
    Pointer<VkQueue_T>, Pointer<VkPresentInfoKHR>);
typedef VkQueuePresentDart = int Function(
    Pointer<VkQueue_T>, Pointer<VkPresentInfoKHR>);

// ---------------------------------------------------------------------------
// Instance level: VK_KHR_surface and the platform extensions
// ---------------------------------------------------------------------------

/// The `VK_KHR_surface` commands, plus whichever platform creators resolved.
final class VulkanSurfaceApi {
  const VulkanSurfaceApi._({
    required this.destroySurface,
    required this.getPhysicalDeviceSurfaceSupport,
    required this.getPhysicalDeviceSurfaceCapabilities,
    required this.getPhysicalDeviceSurfaceFormats,
    required this.getPhysicalDeviceSurfacePresentModes,
    required this.createWin32Surface,
    required this.createXlibSurface,
    required this.createXcbSurface,
    required this.createWaylandSurface,
    required this.getPhysicalDeviceWin32PresentationSupport,
  });

  /// The five `VK_KHR_surface` commands. All or nothing - see the library
  /// comment.
  static const List<String> requiredSymbols = <String>[
    'vkDestroySurfaceKHR',
    'vkGetPhysicalDeviceSurfaceSupportKHR',
    'vkGetPhysicalDeviceSurfaceCapabilitiesKHR',
    'vkGetPhysicalDeviceSurfaceFormatsKHR',
    'vkGetPhysicalDeviceSurfacePresentModesKHR',
  ];

  /// One per platform extension. Present exactly when its extension was
  /// enabled, which is why they are individually nullable where the five above
  /// are not.
  static const List<String> platformSymbols = <String>[
    'vkCreateWin32SurfaceKHR',
    'vkCreateXlibSurfaceKHR',
    'vkCreateXcbSurfaceKHR',
    'vkCreateWaylandSurfaceKHR',
    'vkGetPhysicalDeviceWin32PresentationSupportKHR',
  ];

  final VkDestroySurfaceDart destroySurface;
  final VkGetSurfaceSupportDart getPhysicalDeviceSurfaceSupport;
  final VkGetSurfaceCapabilitiesDart getPhysicalDeviceSurfaceCapabilities;
  final VkEnumerateSurfaceDart<VkSurfaceFormatKHR>
      getPhysicalDeviceSurfaceFormats;
  final VkEnumerateSurfaceDart<UnsignedInt>
      getPhysicalDeviceSurfacePresentModes;

  final VkCreateSurfaceDart<VkWin32SurfaceCreateInfoKHR>? createWin32Surface;
  final VkCreateSurfaceDart<VkXlibSurfaceCreateInfoKHR>? createXlibSurface;
  final VkCreateSurfaceDart<VkXcbSurfaceCreateInfoKHR>? createXcbSurface;
  final VkCreateSurfaceDart<VkWaylandSurfaceCreateInfoKHR>?
      createWaylandSurface;

  /// `vkGetPhysicalDeviceWin32PresentationSupportKHR`, which answers whether a
  /// queue family can present to *the desktop* without needing a surface.
  ///
  /// Worth having beside the per-surface query: it is the only way to ask the
  /// question before a window exists, which is what a probe wants.
  final VkGetWin32PresentationSupportDart?
      getPhysicalDeviceWin32PresentationSupport;

  /// Whether [platform]'s creator resolved.
  bool supports(VulkanSurfacePlatform platform) => switch (platform) {
        VulkanSurfacePlatform.win32 => createWin32Surface != null,
        VulkanSurfacePlatform.xlib => createXlibSurface != null,
        VulkanSurfacePlatform.xcb => createXcbSurface != null,
        VulkanSurfacePlatform.wayland => createWaylandSurface != null,
      };

  /// The table, or null when `VK_KHR_surface` is not present on this instance.
  ///
  /// Null rather than a throw: an instance created without the extension is
  /// the normal state of a headless runner, and the caller turns this into a
  /// diagnostic naming the extension.
  static VulkanSurfaceApi? bind(
    VulkanLibrary library,
    Pointer<VkInstance_T> instance,
  ) {
    Pointer<NativeFunction<T>> maybe<T extends Function>(String symbol) =>
        library.instanceProc(instance, symbol).cast<NativeFunction<T>>();

    final Pointer<NativeFunction<VkDestroySurfaceNative>> destroy =
        maybe<VkDestroySurfaceNative>('vkDestroySurfaceKHR');
    final Pointer<NativeFunction<VkGetSurfaceSupportNative>> support =
        maybe<VkGetSurfaceSupportNative>(
            'vkGetPhysicalDeviceSurfaceSupportKHR');
    final Pointer<NativeFunction<VkGetSurfaceCapabilitiesNative>> capabilities =
        maybe<VkGetSurfaceCapabilitiesNative>(
            'vkGetPhysicalDeviceSurfaceCapabilitiesKHR');
    final Pointer<NativeFunction<VkEnumerateSurfaceNative<VkSurfaceFormatKHR>>>
        formats = maybe<VkEnumerateSurfaceNative<VkSurfaceFormatKHR>>(
            'vkGetPhysicalDeviceSurfaceFormatsKHR');
    final Pointer<NativeFunction<VkEnumerateSurfaceNative<UnsignedInt>>> modes =
        maybe<VkEnumerateSurfaceNative<UnsignedInt>>(
            'vkGetPhysicalDeviceSurfacePresentModesKHR');
    if (destroy == nullptr ||
        support == nullptr ||
        capabilities == nullptr ||
        formats == nullptr ||
        modes == nullptr) {
      return null;
    }

    final Pointer<
            NativeFunction<VkCreateSurfaceNative<VkWin32SurfaceCreateInfoKHR>>>
        win32 = maybe<VkCreateSurfaceNative<VkWin32SurfaceCreateInfoKHR>>(
            'vkCreateWin32SurfaceKHR');
    final Pointer<
            NativeFunction<VkCreateSurfaceNative<VkXlibSurfaceCreateInfoKHR>>>
        xlib = maybe<VkCreateSurfaceNative<VkXlibSurfaceCreateInfoKHR>>(
            'vkCreateXlibSurfaceKHR');
    final Pointer<
            NativeFunction<VkCreateSurfaceNative<VkXcbSurfaceCreateInfoKHR>>>
        xcb = maybe<VkCreateSurfaceNative<VkXcbSurfaceCreateInfoKHR>>(
            'vkCreateXcbSurfaceKHR');
    final Pointer<
            NativeFunction<
                VkCreateSurfaceNative<VkWaylandSurfaceCreateInfoKHR>>> wayland =
        maybe<VkCreateSurfaceNative<VkWaylandSurfaceCreateInfoKHR>>(
            'vkCreateWaylandSurfaceKHR');
    final Pointer<NativeFunction<VkGetWin32PresentationSupportNative>>
        win32Support = maybe<VkGetWin32PresentationSupportNative>(
            'vkGetPhysicalDeviceWin32PresentationSupportKHR');

    return VulkanSurfaceApi._(
      destroySurface: destroy.asFunction<VkDestroySurfaceDart>(),
      getPhysicalDeviceSurfaceSupport:
          support.asFunction<VkGetSurfaceSupportDart>(),
      getPhysicalDeviceSurfaceCapabilities:
          capabilities.asFunction<VkGetSurfaceCapabilitiesDart>(),
      getPhysicalDeviceSurfaceFormats:
          formats.asFunction<VkEnumerateSurfaceDart<VkSurfaceFormatKHR>>(),
      getPhysicalDeviceSurfacePresentModes:
          modes.asFunction<VkEnumerateSurfaceDart<UnsignedInt>>(),
      createWin32Surface: win32 == nullptr
          ? null
          : win32
              .asFunction<VkCreateSurfaceDart<VkWin32SurfaceCreateInfoKHR>>(),
      createXlibSurface: xlib == nullptr
          ? null
          : xlib.asFunction<VkCreateSurfaceDart<VkXlibSurfaceCreateInfoKHR>>(),
      createXcbSurface: xcb == nullptr
          ? null
          : xcb.asFunction<VkCreateSurfaceDart<VkXcbSurfaceCreateInfoKHR>>(),
      createWaylandSurface: wayland == nullptr
          ? null
          : wayland
              .asFunction<VkCreateSurfaceDart<VkWaylandSurfaceCreateInfoKHR>>(),
      getPhysicalDeviceWin32PresentationSupport: win32Support == nullptr
          ? null
          : win32Support.asFunction<VkGetWin32PresentationSupportDart>(),
    );
  }
}

// ---------------------------------------------------------------------------
// Device level: VK_KHR_swapchain
// ---------------------------------------------------------------------------

/// The five `VK_KHR_swapchain` commands.
final class VulkanSwapchainApi {
  const VulkanSwapchainApi._({
    required this.createSwapchain,
    required this.destroySwapchain,
    required this.getSwapchainImages,
    required this.acquireNextImage,
    required this.queuePresent,
  });

  static const List<String> requiredSymbols = <String>[
    'vkCreateSwapchainKHR',
    'vkDestroySwapchainKHR',
    'vkGetSwapchainImagesKHR',
    'vkAcquireNextImageKHR',
    'vkQueuePresentKHR',
  ];

  final VkCreateDart<VkSwapchainCreateInfoKHR, VkSwapchainKHR_T>
      createSwapchain;
  final VkDestroyDart<VkSwapchainKHR_T> destroySwapchain;
  final VkGetSwapchainImagesDart getSwapchainImages;
  final VkAcquireNextImageDart acquireNextImage;
  final VkQueuePresentDart queuePresent;

  /// The table, or null when the device was created without
  /// `VK_KHR_swapchain`.
  static VulkanSwapchainApi? bind(
    VulkanInstanceApi instance,
    Pointer<VkDevice_T> device,
  ) {
    Pointer<NativeFunction<T>> maybe<T extends Function>(String symbol) =>
        using((NativeArena arena) => instance
            .getDeviceProcAddr(device, arena.allocateAscii(symbol).cast<Char>())
            .cast<NativeFunction<T>>());

    final Pointer<
            NativeFunction<
                VkCreateNative<VkSwapchainCreateInfoKHR, VkSwapchainKHR_T>>>
        create =
        maybe<VkCreateNative<VkSwapchainCreateInfoKHR, VkSwapchainKHR_T>>(
            'vkCreateSwapchainKHR');
    final Pointer<NativeFunction<VkDestroyNative<VkSwapchainKHR_T>>> destroy =
        maybe<VkDestroyNative<VkSwapchainKHR_T>>('vkDestroySwapchainKHR');
    final Pointer<NativeFunction<VkGetSwapchainImagesNative>> images =
        maybe<VkGetSwapchainImagesNative>('vkGetSwapchainImagesKHR');
    final Pointer<NativeFunction<VkAcquireNextImageNative>> acquire =
        maybe<VkAcquireNextImageNative>('vkAcquireNextImageKHR');
    final Pointer<NativeFunction<VkQueuePresentNative>> present =
        maybe<VkQueuePresentNative>('vkQueuePresentKHR');
    if (create == nullptr ||
        destroy == nullptr ||
        images == nullptr ||
        acquire == nullptr ||
        present == nullptr) {
      return null;
    }

    return VulkanSwapchainApi._(
      createSwapchain: create.asFunction<
          VkCreateDart<VkSwapchainCreateInfoKHR, VkSwapchainKHR_T>>(),
      destroySwapchain: destroy.asFunction<VkDestroyDart<VkSwapchainKHR_T>>(),
      getSwapchainImages: images.asFunction<VkGetSwapchainImagesDart>(),
      acquireNextImage: acquire.asFunction<VkAcquireNextImageDart>(),
      queuePresent: present.asFunction<VkQueuePresentDart>(),
    );
  }
}
