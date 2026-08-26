/// `VkSurfaceKHR`, `VkSwapchainKHR`, and the two policies that pick what they
/// are made of.
///
/// The offscreen half of this backend renders into an image it allocated and
/// reads it back. A window is different in one way that changes everything: the
/// images belong to the *presentation engine*, the application borrows one at a
/// time, and the borrowing is asynchronous. So this file owns three things the
/// offscreen path never needed - a surface, a swapchain, and the acquire/present
/// handshake - and states the two decisions a reader will want to check.
///
/// ## Policy 1: the format is chosen, not requested
///
/// `vkGetPhysicalDeviceSurfaceFormatsKHR` reports what the *compositor* can
/// scan out. A renderer does not get to pick; it picks from that list. The
/// order of preference is stated in [VulkanSurfaceConfiguration.choose] and is
/// deliberately the same one the offscreen path uses -
/// `B8G8R8A8_UNORM`/`SRGB_NONLINEAR` first - so that the same display list
/// produces the same bytes in a window as it does in a `Framebuffer`, and a
/// window/offscreen parity test compares like with like.
///
/// **`UNORM` and not `SRGB`.** An `_SRGB` swapchain format makes the hardware
/// convert every value the fragment shader writes from linear to sRGB on the
/// way out. This renderer's colours are already sRGB-encoded bytes - the CPU
/// rasteriser blends them that way and every parity test in the repository is
/// written against it - so an `_SRGB` surface would apply the transfer function
/// a second time and wash the whole window out. That is the single most likely
/// way for this file to be wrong while still showing a picture, which is why it
/// is written down here and asserted in the test.
///
/// ## Policy 2: the present mode is an intent, not a mode
///
/// [VulkanPresentPolicy] has two values because a UI framework has two intents.
/// `FIFO` is the only mode the specification requires every surface to support,
/// so [VulkanPresentPolicy.fifo] cannot fail. `MAILBOX` is genuinely optional -
/// absent on plenty of drivers and on most compositors inside a virtual
/// machine - so [VulkanPresentPolicy.lowLatency] *asks*, and falls back to
/// FIFO rather than to `IMMEDIATE`: a caller who wanted lower latency has not
/// asked to tear.
///
/// ## Why the swapchain does not own the render pass
///
/// A `VkFramebuffer` is built against a render pass, so the swapchain needs
/// one - but building its own would mean a second render pass for the same
/// attachment format, and pipelines built against the first would still be
/// compatible with it, which makes the duplicate pure cost and one more object
/// whose lifetime has to match the swapchain's. So the render pass is passed
/// in, and it is the one `VulkanPipelines` already built for the format the
/// surface chose.
library;

import 'dart:ffi';

import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import '../../framebuffer.dart';
import 'vulkan_constants.dart';
import 'vulkan_device.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_instance.dart';
import 'vulkan_surface_descriptor.dart';
import 'vulkan_wsi_bindings.dart';
import 'vulkan_wsi_platform.dart';

/// A surface, or the diagnostics explaining why there is none.
final class VulkanSurfaceAttempt {
  const VulkanSurfaceAttempt(this.surface, this.diagnostics);

  final VulkanSurface? surface;
  final List<BackendDiagnostic> diagnostics;

  String get failureText => diagnostics
      .where((BackendDiagnostic d) => d.isFailure)
      .map((BackendDiagnostic d) => d.toString())
      .join('; ');
}

/// One `VkSurfaceKHR` and the questions a physical device can be asked about
/// it.
final class VulkanSurface {
  VulkanSurface._(this.instance, this.handle, this.platform);

  final VulkanInstance instance;
  final Pointer<VkSurfaceKHR_T> handle;
  final VulkanSurfacePlatform platform;

  bool _disposed = false;
  bool get isDisposed => _disposed;

  VulkanSurfaceApi get _api => instance.surfaceApi!;

  /// Creates a surface for [descriptor], reporting rather than throwing.
  ///
  /// A window system that refuses is the ordinary case - a destroyed window, a
  /// handle from a previous run - and section 6.6 asks for a named refusal
  /// rather than an exception through the frame loop.
  static VulkanSurfaceAttempt create(
    VulkanInstance instance,
    VulkanWindowSurfaceDescriptor descriptor,
  ) {
    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];
    if (!instance.supportsSurface(descriptor.platform)) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.missingLibrary,
        message: 'this Vulkan instance cannot create a '
            '${descriptor.platform.name} surface',
        detail: 'it was created with extensions '
            '${instance.enabledExtensions.isEmpty ? '(none)' : instance.enabledExtensions.join(', ')}; '
            '${descriptor.platform.instanceExtension} is what this needs',
      ));
      return VulkanSurfaceAttempt(null, diagnostics);
    }
    if (descriptor.windowHandle == 0) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.rejectedByPolicy,
        message: 'the window handle is zero, which is not a window',
      ));
      return VulkanSurfaceAttempt(null, diagnostics);
    }
    if (descriptor.platform != VulkanSurfacePlatform.win32 &&
        descriptor.displayHandle == 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.rejectedByPolicy,
        message: 'a ${descriptor.platform.name} surface needs a display or '
            'connection handle and none was given',
      ));
      return VulkanSurfaceAttempt(null, diagnostics);
    }

    return using((NativeArena arena) {
      final Pointer<Pointer<VkSurfaceKHR_T>> out =
          arena<Pointer<VkSurfaceKHR_T>>();
      final VulkanSurfaceApi api = instance.surfaceApi!;
      final int result;
      switch (descriptor.platform) {
        case VulkanSurfacePlatform.win32:
          final Pointer<VkWin32SurfaceCreateInfoKHR> info =
              arena<VkWin32SurfaceCreateInfoKHR>();
          info.ref
            ..sType =
                VkStructureType.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR
            // Zero is legal and means "the module this process was loaded
            // from", which is what every driver does with it. Resolving it here
            // would mean calling `GetModuleHandle`, which is a Win32 name this
            // file may not use - see `vulkan_wsi_platform.dart`.
            ..hinstance = descriptor.displayHandle
            ..hwnd = descriptor.windowHandle;
          result = api.createWin32Surface!(instance.handle, info, nullptr, out);
        case VulkanSurfacePlatform.xlib:
          final Pointer<VkXlibSurfaceCreateInfoKHR> info =
              arena<VkXlibSurfaceCreateInfoKHR>();
          info.ref
            ..sType =
                VkStructureType.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR
            ..dpy = descriptor.displayHandle
            ..window = descriptor.windowHandle;
          result = api.createXlibSurface!(instance.handle, info, nullptr, out);
        case VulkanSurfacePlatform.xcb:
          final Pointer<VkXcbSurfaceCreateInfoKHR> info =
              arena<VkXcbSurfaceCreateInfoKHR>();
          info.ref
            ..sType =
                VkStructureType.VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR
            ..connection = descriptor.displayHandle
            ..window = descriptor.windowHandle;
          result = api.createXcbSurface!(instance.handle, info, nullptr, out);
        case VulkanSurfacePlatform.wayland:
          final Pointer<VkWaylandSurfaceCreateInfoKHR> info =
              arena<VkWaylandSurfaceCreateInfoKHR>();
          info.ref
            ..sType = VkStructureType
                .VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR
            ..display = descriptor.displayHandle
            ..surface = descriptor.windowHandle;
          result =
              api.createWaylandSurface!(instance.handle, info, nullptr, out);
      }

      if (vkFailed(result)) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'vkCreate${_creatorName(descriptor.platform)} refused',
          detail: '${vkResultName(result)} for $descriptor',
        ));
        return VulkanSurfaceAttempt(null, diagnostics);
      }
      diagnostics.add(BackendDiagnostic.note(
          'Vulkan ${descriptor.platform.name} surface for $descriptor'));
      return VulkanSurfaceAttempt(
        VulkanSurface._(instance, out.value, descriptor.platform),
        diagnostics,
      );
    });
  }

  static String _creatorName(VulkanSurfacePlatform platform) =>
      switch (platform) {
        VulkanSurfacePlatform.win32 => 'Win32SurfaceKHR',
        VulkanSurfacePlatform.xlib => 'XlibSurfaceKHR',
        VulkanSurfacePlatform.xcb => 'XcbSurfaceKHR',
        VulkanSurfacePlatform.wayland => 'WaylandSurfaceKHR',
      };

  /// Whether [family] on [physical] can present to this surface.
  bool supportsPresentOn(VulkanPhysicalDevice physical, int family) =>
      using((NativeArena arena) {
        final Pointer<Uint32> supported = arena<Uint32>();
        supported.value = vkFalse;
        final int result = _api.getPhysicalDeviceSurfaceSupport(
            physical.handle, family, handle, supported);
        return !vkFailed(result) && supported.value == vkTrue;
      });

  /// The queue family to present on, or null when none can.
  ///
  /// The graphics family is tried first and returned when it works, which is
  /// the case on every desktop driver and the case that costs nothing: one
  /// queue, one submission, and swapchain images with
  /// `VK_SHARING_MODE_EXCLUSIVE`. Only when it cannot present does this look
  /// for another family, and the caller then pays for concurrent sharing.
  int? presentQueueFamilyOn(VulkanPhysicalDevice physical) {
    final int? graphics = physical.graphicsQueueFamily;
    if (graphics != null && supportsPresentOn(physical, graphics)) {
      return graphics;
    }
    for (var family = 0; family < physical.queueFamilyFlags.length; family++) {
      if (supportsPresentOn(physical, family)) return family;
    }
    return null;
  }

  /// `vkGetPhysicalDeviceSurfaceCapabilitiesKHR`, copied out of the struct.
  ///
  /// Copied rather than returned by pointer because the arena it was read into
  /// dies with this call, and a caller holding a dangling `VkSurfaceCapabilities`
  /// would read plausible numbers out of freed memory.
  VulkanSurfaceCapabilities? capabilitiesOn(VulkanPhysicalDevice physical) =>
      using((NativeArena arena) {
        final Pointer<VkSurfaceCapabilitiesKHR> caps =
            arena<VkSurfaceCapabilitiesKHR>();
        final int result = _api.getPhysicalDeviceSurfaceCapabilities(
            physical.handle, handle, caps);
        if (vkFailed(result)) return null;
        return VulkanSurfaceCapabilities(
          minImageCount: caps.ref.minImageCount,
          maxImageCount: caps.ref.maxImageCount,
          currentWidth: caps.ref.currentExtent.width,
          currentHeight: caps.ref.currentExtent.height,
          minWidth: caps.ref.minImageExtent.width,
          minHeight: caps.ref.minImageExtent.height,
          maxWidth: caps.ref.maxImageExtent.width,
          maxHeight: caps.ref.maxImageExtent.height,
          currentTransform: caps.ref.currentTransform,
          supportedCompositeAlpha: caps.ref.supportedCompositeAlpha,
          supportedUsageFlags: caps.ref.supportedUsageFlags,
        );
      });

  /// The `(format, colorSpace)` pairs this surface reports.
  List<VulkanSurfaceFormat> formatsOn(VulkanPhysicalDevice physical) =>
      using((NativeArena arena) {
        final Pointer<Uint32> count = arena<Uint32>();
        count.value = 0;
        if (vkFailed(_api.getPhysicalDeviceSurfaceFormats(
            physical.handle, handle, count, nullptr))) {
          return const <VulkanSurfaceFormat>[];
        }
        if (count.value == 0) return const <VulkanSurfaceFormat>[];
        final Pointer<VkSurfaceFormatKHR> formats =
            arena<VkSurfaceFormatKHR>(count.value);
        if (vkFailed(_api.getPhysicalDeviceSurfaceFormats(
            physical.handle, handle, count, formats))) {
          return const <VulkanSurfaceFormat>[];
        }
        return <VulkanSurfaceFormat>[
          for (var i = 0; i < count.value; i++)
            VulkanSurfaceFormat(formats[i].format, formats[i].colorSpace),
        ];
      });

  /// The `VkPresentModeKHR` values this surface reports.
  List<int> presentModesOn(VulkanPhysicalDevice physical) =>
      using((NativeArena arena) {
        final Pointer<Uint32> count = arena<Uint32>();
        count.value = 0;
        if (vkFailed(_api.getPhysicalDeviceSurfacePresentModes(
            physical.handle, handle, count, nullptr))) {
          return const <int>[];
        }
        if (count.value == 0) return const <int>[];
        final Pointer<UnsignedInt> modes = arena<UnsignedInt>(count.value);
        if (vkFailed(_api.getPhysicalDeviceSurfacePresentModes(
            physical.handle, handle, count, modes))) {
          return const <int>[];
        }
        return <int>[for (var i = 0; i < count.value; i++) modes[i]];
      });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _api.destroySurface(instance.handle, handle, nullptr);
  }
}

/// `VkSurfaceCapabilitiesKHR`, as plain numbers.
final class VulkanSurfaceCapabilities {
  const VulkanSurfaceCapabilities({
    required this.minImageCount,
    required this.maxImageCount,
    required this.currentWidth,
    required this.currentHeight,
    required this.minWidth,
    required this.minHeight,
    required this.maxWidth,
    required this.maxHeight,
    required this.currentTransform,
    required this.supportedCompositeAlpha,
    required this.supportedUsageFlags,
  });

  final int minImageCount;

  /// Zero means "no limit", which is the specification's spelling and not a
  /// missing value. Clamping to it would produce a zero-image swapchain.
  final int maxImageCount;

  final int currentWidth;
  final int currentHeight;
  final int minWidth;
  final int minHeight;
  final int maxWidth;
  final int maxHeight;
  final int currentTransform;
  final int supportedCompositeAlpha;
  final int supportedUsageFlags;

  /// Whether the surface leaves the extent to the application.
  ///
  /// `0xFFFFFFFF` in both dimensions is how a surface says "you choose" - a
  /// Wayland compositor typically does. Treating it as a size produces a
  /// four-billion-pixel swapchain, which is the failure this getter exists to
  /// prevent.
  bool get definesExtent =>
      currentWidth != 0xFFFFFFFF || currentHeight != 0xFFFFFFFF;

  /// The extent to create a swapchain with, given what the caller wants.
  (int, int) resolveExtent(int wantedWidth, int wantedHeight) {
    if (definesExtent) return (currentWidth, currentHeight);
    return (
      wantedWidth.clamp(minWidth, maxWidth),
      wantedHeight.clamp(minHeight, maxHeight),
    );
  }

  /// The number of images to ask for, given a floor and a policy.
  int resolveImageCount(int wanted) {
    var count = wanted < minImageCount ? minImageCount : wanted;
    if (maxImageCount != 0 && count > maxImageCount) count = maxImageCount;
    return count;
  }

  @override
  String toString() => 'VulkanSurfaceCapabilities($minImageCount..'
      '${maxImageCount == 0 ? 'unbounded' : maxImageCount} images, '
      'current ${currentWidth}x$currentHeight, '
      '${minWidth}x$minHeight..${maxWidth}x$maxHeight)';
}

/// One `(VkFormat, VkColorSpaceKHR)` pair.
final class VulkanSurfaceFormat {
  const VulkanSurfaceFormat(this.format, this.colorSpace);

  final int format;
  final int colorSpace;

  @override
  bool operator ==(Object other) =>
      other is VulkanSurfaceFormat &&
      other.format == format &&
      other.colorSpace == colorSpace;

  @override
  int get hashCode => Object.hash(format, colorSpace);

  @override
  String toString() => '${vkFormatName(format)}/${_colorSpaceName(colorSpace)}';

  static String _colorSpaceName(int space) =>
      space == VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
          ? 'SRGB_NONLINEAR'
          : 'colour space $space';
}

/// Everything a swapchain is created with, after both policies have run.
final class VulkanSwapchainConfiguration {
  const VulkanSwapchainConfiguration({
    required this.format,
    required this.colorSpace,
    required this.presentMode,
    required this.imageCount,
    required this.width,
    required this.height,
    required this.preTransform,
    required this.compositeAlpha,
    required this.supportsTransferSource,
  });

  final int format;
  final int colorSpace;
  final int presentMode;
  final int imageCount;
  final int width;
  final int height;
  final int preTransform;
  final int compositeAlpha;

  /// Whether the surface allows `TRANSFER_SRC` usage on its images.
  ///
  /// Not guaranteed by anything, and the only thing it costs to lose is the
  /// ability to copy a rendered image back and compare it against the CPU
  /// rasteriser - which is a test's need, not a window's. So it is asked for
  /// when offered and dropped silently when not, and the test that needs it
  /// skips with a reason rather than the window failing to open.
  final bool supportsTransferSource;

  /// The framework pixel format these bytes are, for a caller comparing a
  /// window against a `Framebuffer`.
  ///
  /// Null when the surface chose something this framework has no name for,
  /// which is not an error - it draws correctly either way - but does mean a
  /// readback cannot be compared byte for byte.
  PixelFormat? get pixelFormat => switch (format) {
        VkFormat.VK_FORMAT_B8G8R8A8_UNORM => PixelFormat.bgra8888Premultiplied,
        VkFormat.VK_FORMAT_R8G8B8A8_UNORM => PixelFormat.rgba8888Premultiplied,
        _ => null,
      };

  bool get isEmpty => width == 0 || height == 0;

  @override
  String toString() => 'VulkanSwapchainConfiguration('
      '${VulkanSurfaceFormat(format, colorSpace)}, '
      '${_presentModeName(presentMode)}, $imageCount images, '
      '${width}x$height)';

  static String _presentModeName(int mode) => switch (mode) {
        VkPresentModeKHR.VK_PRESENT_MODE_IMMEDIATE_KHR => 'IMMEDIATE',
        VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR => 'MAILBOX',
        VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR => 'FIFO',
        VkPresentModeKHR.VK_PRESENT_MODE_FIFO_RELAXED_KHR => 'FIFO_RELAXED',
        _ => 'present mode $mode',
      };
}

/// The two policies, applied.
abstract final class VulkanSurfaceConfiguration {
  /// The formats this renderer prefers, best first.
  ///
  /// `UNORM` and never `_SRGB`; see Policy 1 in the library comment. BGRA
  /// before RGBA because it is what the offscreen path defaults to and what
  /// every Windows compositor reports first, so the common case needs no
  /// swizzle anywhere.
  static const List<VulkanSurfaceFormat> preferredFormats =
      <VulkanSurfaceFormat>[
    VulkanSurfaceFormat(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
        VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
    VulkanSurfaceFormat(VkFormat.VK_FORMAT_R8G8B8A8_UNORM,
        VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
  ];

  /// Picks a format from what the surface offers.
  ///
  /// A single reported entry whose format is `VK_FORMAT_UNDEFINED` is the
  /// specification's way of saying "any format"; the first preference is taken
  /// then. An empty list means the surface reported nothing, which is a surface
  /// that cannot be presented to.
  static VulkanSurfaceFormat? chooseFormat(
      List<VulkanSurfaceFormat> available) {
    if (available.isEmpty) return null;
    if (available.length == 1 &&
        available.single.format == VkFormat.VK_FORMAT_UNDEFINED) {
      return preferredFormats.first;
    }
    for (final VulkanSurfaceFormat wanted in preferredFormats) {
      if (available.contains(wanted)) return wanted;
    }
    // Nothing preferred: take what is offered rather than refuse the window.
    // The picture is still correct; only a byte-for-byte comparison against a
    // `Framebuffer` stops being possible, and `pixelFormat` says so.
    return available.first;
  }

  /// Picks a present mode for [policy] from what the surface offers.
  ///
  /// FIFO is returned even when the list does not contain it, and that is not
  /// an oversight: the specification requires every surface to support FIFO, so
  /// a list without it is a driver bug, and asking for FIFO anyway gives the
  /// driver's own error instead of this file inventing a fallback.
  static int choosePresentMode(
    VulkanPresentPolicy policy,
    List<int> available,
  ) {
    if (policy == VulkanPresentPolicy.lowLatency &&
        available.contains(VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR)) {
      return VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR;
    }
    return VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR;
  }

  /// The composite alpha to ask for.
  ///
  /// `OPAQUE` when the surface offers it, because this renderer's window is not
  /// blended with the desktop and claiming otherwise would let a compositor see
  /// through a frame whose alpha the display list never meant as transparency.
  /// `INHERIT` is the fallback, and it is last: it means "whatever the platform
  /// does", which is right only when there is no choice.
  static int chooseCompositeAlpha(int supported) {
    for (final int candidate in <int>[
      VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
      VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
      VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
      VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
    ]) {
      if ((supported & candidate) != 0) return candidate;
    }
    return VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
  }

  /// Both policies plus the capability clamps, in one value.
  ///
  /// Returns null when the surface reported no format at all - the one case
  /// where there is nothing to choose from and a window cannot be built.
  static VulkanSwapchainConfiguration? choose({
    required VulkanSurfaceCapabilities capabilities,
    required List<VulkanSurfaceFormat> formats,
    required List<int> presentModes,
    required VulkanWindowSurfaceDescriptor descriptor,
  }) {
    final VulkanSurfaceFormat? format = chooseFormat(formats);
    if (format == null) return null;
    final int mode = choosePresentMode(descriptor.presentPolicy, presentModes);
    // Mailbox with two images degenerates into FIFO with extra steps: the
    // producer still blocks, because there is no spare image to replace. Three
    // is the smallest count at which the mode does what it is chosen for.
    final int wanted = mode == VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR &&
            descriptor.minImageCount < 3
        ? 3
        : descriptor.minImageCount;
    final (int width, int height) = capabilities.resolveExtent(
        descriptor.pixelWidth, descriptor.pixelHeight);
    return VulkanSwapchainConfiguration(
      format: format.format,
      colorSpace: format.colorSpace,
      presentMode: mode,
      imageCount: capabilities.resolveImageCount(wanted),
      width: width,
      height: height,
      // The surface's own transform, echoed back. Asking for IDENTITY on a
      // surface whose current transform is a rotation is legal and makes the
      // presentation engine rotate every frame; echoing it means it does not.
      preTransform: capabilities.currentTransform,
      compositeAlpha:
          chooseCompositeAlpha(capabilities.supportedCompositeAlpha),
      supportsTransferSource: (capabilities.supportedUsageFlags &
              VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) !=
          0,
    );
  }
}

/// What an acquire returned.
final class VulkanAcquiredImage {
  const VulkanAcquiredImage(this.result, this.imageIndex);

  /// The raw `VkResult`. `VK_SUCCESS` and `VK_SUBOPTIMAL_KHR` both mean an
  /// image was acquired; only the first means nothing needs rebuilding.
  final int result;

  /// Valid only when [acquired] is true.
  final int imageIndex;

  bool get acquired =>
      result == VkResult.VK_SUCCESS || result == VkResult.VK_SUBOPTIMAL_KHR;

  /// Whether the swapchain has to be rebuilt before or after this frame.
  bool get needsRecreation =>
      result == VkResult.VK_ERROR_OUT_OF_DATE_KHR ||
      result == VkResult.VK_SUBOPTIMAL_KHR;
}

/// One `VkSwapchainKHR`, its images, views and framebuffers.
final class VulkanSwapchain {
  VulkanSwapchain._({
    required this.handle,
    required this.configuration,
    required List<Pointer<VkImage_T>> images,
    required List<Pointer<VkImageView_T>> views,
    required List<Pointer<VkFramebuffer_T>> framebuffers,
  })  : _images = images,
        _views = views,
        _framebuffers = framebuffers,
        _presentable = List<bool>.filled(images.length, false);

  final Pointer<VkSwapchainKHR_T> handle;
  final VulkanSwapchainConfiguration configuration;

  final List<Pointer<VkImage_T>> _images;
  final List<Pointer<VkImageView_T>> _views;
  final List<Pointer<VkFramebuffer_T>> _framebuffers;

  /// Whether each image has been presented at least once, and is therefore in
  /// `PRESENT_SRC_KHR` rather than `UNDEFINED`.
  ///
  /// Tracked on this side because Vulkan does not track it, and a barrier that
  /// names the wrong `oldLayout` is undefined behaviour a driver is free to
  /// implement as "the contents are now garbage".
  final List<bool> _presentable;

  int get imageCount => _images.length;

  Pointer<VkImage_T> imageAt(int index) => _images[index];

  Pointer<VkFramebuffer_T> framebufferAt(int index) => _framebuffers[index];

  /// Whether image [index] has been presented, and therefore holds the last
  /// frame drawn into it and sits in `PRESENT_SRC_KHR`.
  bool isPresentable(int index) => _presentable[index];

  /// The layout image [index] is in right now.
  int layoutOf(int index) => _presentable[index]
      ? VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
      : VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED;

  /// Records that image [index] has been transitioned to `PRESENT_SRC_KHR`.
  void markPresentable(int index) => _presentable[index] = true;

  /// Creates a swapchain, or returns null.
  ///
  /// [oldSwapchain] lets the presentation engine reuse the old images' memory
  /// during a resize and, more importantly, lets it keep presenting the old
  /// chain until the new one has its first image. It is *not* destroyed here:
  /// the caller still owns it and must destroy it after this returns, which is
  /// the only order the specification allows.
  static VulkanSwapchain? create(
    VulkanDevice device,
    VulkanSurface surface, {
    required VulkanSwapchainConfiguration configuration,
    required Pointer<VkRenderPass_T> renderPass,
    // Nullable rather than defaulting to `nullptr`, which `dart:ffi` types as
    // `Pointer<Never>` and Dart therefore refuses as a constant default. Null
    // means "no old chain", the same convention `VulkanDevice.submit` uses for
    // its fence.
    Pointer<VkSwapchainKHR_T>? oldSwapchain,
  }) {
    final VulkanSwapchainApi? api = device.swapchainApi;
    if (api == null || configuration.isEmpty) return null;

    return using((NativeArena arena) {
      final Pointer<VkSwapchainCreateInfoKHR> info =
          arena<VkSwapchainCreateInfoKHR>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
        ..surface = surface.handle
        ..minImageCount = configuration.imageCount
        ..imageFormat = configuration.format
        ..imageColorSpace = configuration.colorSpace
        ..imageArrayLayers = 1
        // COLOR_ATTACHMENT to render into, TRANSFER_SRC so a test can copy the
        // presented image back and compare it against the CPU. The second is
        // guaranteed by nothing, so it is added only when the surface reports
        // it - a window is worth more than a readback.
        ..imageUsage =
            VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                (configuration.supportsTransferSource
                    ? VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT
                    : 0)
        ..preTransform = configuration.preTransform
        ..compositeAlpha = configuration.compositeAlpha
        ..presentMode = configuration.presentMode
        // Clipped: the presentation engine may skip shading pixels another
        // window covers. Legal because nothing here reads a presented image
        // back expecting the obscured pixels to be defined - the readback path
        // copies from an image it has just rendered and not yet presented.
        ..clipped = vkTrue
        ..oldSwapchain = oldSwapchain ?? nullptr;
      info.ref.imageExtent
        ..width = configuration.width
        ..height = configuration.height;

      final Pointer<Uint32> families = arena<Uint32>(2);
      families[0] = device.queueFamily;
      families[1] = device.presentQueueFamily;
      if (device.hasUnifiedQueues) {
        info.ref.imageSharingMode = VkSharingMode.VK_SHARING_MODE_EXCLUSIVE;
      } else {
        // Two families touch the image, so it is shared. The alternative -
        // EXCLUSIVE with an explicit ownership transfer on every frame - is
        // faster and is a barrier pair this backend has no reason to carry
        // until a device that needs it actually appears.
        info.ref
          ..imageSharingMode = VkSharingMode.VK_SHARING_MODE_CONCURRENT
          ..queueFamilyIndexCount = 2
          ..pQueueFamilyIndices = families;
      }

      final Pointer<Pointer<VkSwapchainKHR_T>> out =
          arena<Pointer<VkSwapchainKHR_T>>();
      if (vkFailed(api.createSwapchain(device.handle, info, nullptr, out))) {
        return null;
      }
      final Pointer<VkSwapchainKHR_T> chain = out.value;

      final Pointer<Uint32> count = arena<Uint32>();
      count.value = 0;
      if (vkFailed(
          api.getSwapchainImages(device.handle, chain, count, nullptr))) {
        api.destroySwapchain(device.handle, chain, nullptr);
        return null;
      }
      final Pointer<Pointer<VkImage_T>> imageOut =
          arena<Pointer<VkImage_T>>(count.value);
      if (vkFailed(
          api.getSwapchainImages(device.handle, chain, count, imageOut))) {
        api.destroySwapchain(device.handle, chain, nullptr);
        return null;
      }

      final List<Pointer<VkImage_T>> images = <Pointer<VkImage_T>>[
        for (var i = 0; i < count.value; i++) imageOut[i],
      ];
      final List<Pointer<VkImageView_T>> views = <Pointer<VkImageView_T>>[];
      final List<Pointer<VkFramebuffer_T>> framebuffers =
          <Pointer<VkFramebuffer_T>>[];

      void releasePartial() {
        for (final Pointer<VkFramebuffer_T> buffer in framebuffers) {
          device.api.destroyFramebuffer(device.handle, buffer, nullptr);
        }
        for (final Pointer<VkImageView_T> view in views) {
          device.api.destroyImageView(device.handle, view, nullptr);
        }
        api.destroySwapchain(device.handle, chain, nullptr);
      }

      for (final Pointer<VkImage_T> image in images) {
        final Pointer<VkImageViewCreateInfo> viewInfo =
            arena<VkImageViewCreateInfo>();
        viewInfo.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
          ..image = image
          ..viewType = VkImageViewType.VK_IMAGE_VIEW_TYPE_2D
          ..format = configuration.format;
        viewInfo.ref.subresourceRange
          ..aspectMask = VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT
          ..levelCount = 1
          ..layerCount = 1;
        final Pointer<Pointer<VkImageView_T>> viewOut =
            arena<Pointer<VkImageView_T>>();
        if (vkFailed(device.api
            .createImageView(device.handle, viewInfo, nullptr, viewOut))) {
          releasePartial();
          return null;
        }
        views.add(viewOut.value);

        final Pointer<Pointer<VkImageView_T>> attachments =
            arena<Pointer<VkImageView_T>>();
        attachments.value = viewOut.value;
        final Pointer<VkFramebufferCreateInfo> framebufferInfo =
            arena<VkFramebufferCreateInfo>();
        framebufferInfo.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
          ..renderPass = renderPass
          ..attachmentCount = 1
          ..pAttachments = attachments
          ..width = configuration.width
          ..height = configuration.height
          ..layers = 1;
        final Pointer<Pointer<VkFramebuffer_T>> framebufferOut =
            arena<Pointer<VkFramebuffer_T>>();
        if (vkFailed(device.api.createFramebuffer(
            device.handle, framebufferInfo, nullptr, framebufferOut))) {
          releasePartial();
          return null;
        }
        framebuffers.add(framebufferOut.value);
      }

      return VulkanSwapchain._(
        handle: chain,
        configuration: configuration,
        images: images,
        views: views,
        framebuffers: framebuffers,
      );
    });
  }

  /// `vkAcquireNextImageKHR`, with [semaphore] signalled when the image is
  /// ready to be rendered into.
  VulkanAcquiredImage acquire(
    VulkanDevice device, {
    required Pointer<VkSemaphore_T> semaphore,
    int? timeoutNanoseconds,
  }) =>
      using((NativeArena arena) {
        final Pointer<Uint32> index = arena<Uint32>();
        index.value = 0;
        final int result = device.swapchainApi!.acquireNextImage(
          device.handle,
          handle,
          timeoutNanoseconds ?? VulkanDevice.kFrameTimeoutNanoseconds,
          semaphore,
          nullptr,
          index,
        );
        return VulkanAcquiredImage(result, index.value);
      });

  /// `vkQueuePresentKHR`, waiting on [semaphore].
  ///
  /// Returns the raw `VkResult`: `VK_ERROR_OUT_OF_DATE_KHR` and
  /// `VK_SUBOPTIMAL_KHR` are the ordinary answers to a window that has just
  /// been resized, and the caller decides what to rebuild.
  int present(
    VulkanDevice device, {
    required Pointer<VkSemaphore_T> semaphore,
    required int imageIndex,
  }) =>
      using((NativeArena arena) {
        final Pointer<Pointer<VkSemaphore_T>> waits =
            arena<Pointer<VkSemaphore_T>>();
        waits.value = semaphore;
        final Pointer<Pointer<VkSwapchainKHR_T>> chains =
            arena<Pointer<VkSwapchainKHR_T>>();
        chains.value = handle;
        final Pointer<Uint32> index = arena<Uint32>();
        index.value = imageIndex;

        final Pointer<VkPresentInfoKHR> info = arena<VkPresentInfoKHR>();
        info.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
          ..waitSemaphoreCount = 1
          ..pWaitSemaphores = waits
          ..swapchainCount = 1
          ..pSwapchains = chains
          ..pImageIndices = index;
        return device.swapchainApi!.queuePresent(device.presentQueue, info);
      });

  /// Destroys the framebuffers, the views and the chain, in that order.
  ///
  /// The images are **not** destroyed: they belong to the presentation engine
  /// and destroying one is undefined. The order matters for the same reason it
  /// always does - a framebuffer outliving its view is a dangling attachment.
  void dispose(VulkanDevice device) {
    for (final Pointer<VkFramebuffer_T> buffer in _framebuffers) {
      device.api.destroyFramebuffer(device.handle, buffer, nullptr);
    }
    _framebuffers.clear();
    for (final Pointer<VkImageView_T> view in _views) {
      device.api.destroyImageView(device.handle, view, nullptr);
    }
    _views.clear();
    _images.clear();
    device.swapchainApi?.destroySwapchain(device.handle, handle, nullptr);
  }
}
