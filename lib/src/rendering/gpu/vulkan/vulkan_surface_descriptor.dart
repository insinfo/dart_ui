/// What a Vulkan target needs to know about a window, and nothing more.
///
/// The shape and the reasoning are `d3d12_surface_descriptor.dart`'s, and the
/// two substantive differences are stated here rather than left to be
/// discovered.
///
/// ## Two integers, not one
///
/// Direct3D needs an `HWND` and nothing else. Every Vulkan WSI extension takes
/// a *pair*: `(HINSTANCE, HWND)` on Win32, `(Display*, Window)` on Xlib,
/// `(xcb_connection_t*, xcb_window_t)` on XCB, `(wl_display*, wl_surface*)` on
/// Wayland. So the descriptor carries [displayHandle] and [windowHandle], and
/// [platform] says which pair they are.
///
/// Both are plain integers for the reason `vulkan_wsi_platform.dart` gives at
/// length: `test/architecture/layering_test.dart` fails the build if any file
/// under `lib/src` outside `backends/` names `HWND` or `xcb_`, and this file is
/// under `lib/src/rendering`. Nothing here dereferences them.
///
/// ## Why the present mode is a *policy* and not a mode
///
/// [presentPolicy] names what the caller wants - a guaranteed present, or the
/// lowest latency the driver can give - and the surface picks a
/// `VkPresentModeKHR` from what the driver actually reports. Naming a mode
/// directly would make the descriptor a request the surface can only honour or
/// refuse, and the honest answer for `MAILBOX` on a driver that lacks it is
/// "fall back to FIFO", not "fail to create a window".
///
/// The policy is here rather than on the device because it is a property of the
/// *window*: a tooltip and a video surface on the same device can reasonably
/// want different answers, and a reader of a bug report needs to see which one
/// was in force.
///
/// ## Why there is no `VkSurfaceKHR` in this descriptor
///
/// The same argument `d3d12_surface_descriptor.dart` makes about its swap
/// chain, and it lands the same way. A `VkSurfaceKHR` is created from the
/// *instance*, which the renderer owns, so there is nothing for the caller to
/// hand in; the target creates the surface in its constructor and owns it for
/// its whole life. What the caller cannot supply, the caller should not be
/// asked for.
library;

import '../../framebuffer.dart';
import '../../renderer.dart';

/// Which pair of handles [VulkanWindowSurfaceDescriptor] carries.
///
/// Not inferred from the host operating system, and that is deliberate: a
/// Linux session can be XCB or Wayland, and a backend that guessed would create
/// the wrong surface on half of them. The windowing backend that made the window
/// is the only thing that knows, so it says so.
enum VulkanSurfacePlatform {
  /// `VK_KHR_win32_surface`: `displayHandle` is the `HINSTANCE`,
  /// `windowHandle` is the `HWND`.
  win32,

  /// `VK_KHR_xlib_surface`: `displayHandle` is the `Display*`,
  /// `windowHandle` is the `Window` XID.
  xlib,

  /// `VK_KHR_xcb_surface`: `displayHandle` is the `xcb_connection_t*`,
  /// `windowHandle` is the `xcb_window_t` - which is a 32-bit id, not a
  /// pointer. See `vulkan_wsi_platform.dart`.
  xcb,

  /// `VK_KHR_wayland_surface`: `displayHandle` is the `wl_display*`,
  /// `windowHandle` is the `wl_surface*`.
  wayland;

  /// The instance extension this platform's surface needs, beside
  /// `VK_KHR_surface`.
  String get instanceExtension => switch (this) {
        VulkanSurfacePlatform.win32 => 'VK_KHR_win32_surface',
        VulkanSurfacePlatform.xlib => 'VK_KHR_xlib_surface',
        VulkanSurfacePlatform.xcb => 'VK_KHR_xcb_surface',
        VulkanSurfacePlatform.wayland => 'VK_KHR_wayland_surface',
      };
}

/// What the caller wants of the presentation engine.
///
/// Two entries and not five, because the five `VkPresentModeKHR` values are the
/// mechanism and these are the only two *intents* a UI framework has.
enum VulkanPresentPolicy {
  /// `VK_PRESENT_MODE_FIFO_KHR`, always.
  ///
  /// The default and the safe answer: FIFO is the only mode the specification
  /// requires every surface to support, it never tears, and it blocks the
  /// caller at the refresh rate - which for a UI that renders on demand is not
  /// a cost at all. A window that asks for this gets it or gets nothing, so
  /// there is no fallback to reason about.
  fifo,

  /// `VK_PRESENT_MODE_MAILBOX_KHR` when the surface reports it, FIFO otherwise.
  ///
  /// Mailbox replaces the queued image instead of queueing behind it, so a
  /// frame produced faster than the refresh rate does not stall the producer.
  /// It costs one more image in the swapchain and it is genuinely optional -
  /// plenty of drivers, and most compositors under a virtual machine, do not
  /// offer it. The fallback is FIFO rather than IMMEDIATE: a caller asking for
  /// latency has not asked to tear.
  lowLatency,
}

/// A window a Vulkan swapchain can present into.
///
/// Handed to `VulkanRenderDevice.createTarget`, which builds a
/// `VulkanWindowTarget` from it. The device refuses anything it does not
/// recognise with a named [UnsupportedCapabilityError] rather than quietly
/// building an offscreen target that would render correctly and show nothing.
final class VulkanWindowSurfaceDescriptor implements NativeSurfaceDescriptor {
  VulkanWindowSurfaceDescriptor({
    required this.platform,
    required this.windowHandle,
    required this.pixelWidth,
    required this.pixelHeight,
    this.displayHandle = 0,
    this.scale = 1.0,
    this.presentPolicy = VulkanPresentPolicy.fifo,
    this.minImageCount = kDefaultImageCount,
    this.format = PixelFormat.bgra8888Premultiplied,
    this.description = 'window',
  })  : assert(pixelWidth > 0 && pixelHeight > 0),
        assert(scale > 0),
        assert(
          minImageCount >= 2,
          'a swapchain the application can render into while the presentation '
          'engine holds one needs at least two images; one would mean waiting '
          'for the compositor before every frame',
        );

  /// Two: one being presented, one being drawn.
  ///
  /// A floor rather than a count - the surface raises it to the driver's
  /// `minImageCount` and to three when the policy is
  /// [VulkanPresentPolicy.lowLatency], because mailbox with two images
  /// degenerates into FIFO with extra steps.
  static const int kDefaultImageCount = 2;

  final VulkanSurfacePlatform platform;

  /// The connection, display or module handle half of the pair. See
  /// [VulkanSurfacePlatform].
  ///
  /// Zero is legal on Win32 and means "ask the module the process was loaded
  /// from"; the surface resolves it. It is *not* legal on the other three,
  /// where a null display is a surface the driver cannot create.
  final int displayHandle;

  /// The window half of the pair.
  final int windowHandle;

  /// Physical pixels, already multiplied by [scale] by whoever built this.
  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  final VulkanPresentPolicy presentPolicy;

  /// The fewest images the swapchain may have. See [kDefaultImageCount].
  final int minImageCount;

  /// The pixel format the caller expects to read back or to reason about.
  ///
  /// Advisory: the actual swapchain format comes from
  /// `vkGetPhysicalDeviceSurfaceFormatsKHR`, because a surface offers what the
  /// compositor can scan out and a renderer does not get to choose. It is
  /// carried so a caller comparing a window surface against a memory one sees
  /// what was asked for, and so the target can say what it got instead.
  final PixelFormat format;

  /// Free text for probe reports and bug reports. Never parsed.
  final String description;

  /// `vulkan-window`. [NativeSurfaceDescriptor.kind] documents that branching
  /// on it is how backend assumptions get into common code, and the device
  /// type-tests instead.
  @override
  String get kind => 'vulkan-window';

  /// The same window at a new size.
  ///
  /// A new descriptor rather than a mutation, because a descriptor is the
  /// record of what a frame was recorded against and a mutable one could not
  /// serve as that record.
  VulkanWindowSurfaceDescriptor resized({
    required int pixelWidth,
    required int pixelHeight,
    double? scale,
  }) =>
      VulkanWindowSurfaceDescriptor(
        platform: platform,
        windowHandle: windowHandle,
        displayHandle: displayHandle,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale ?? this.scale,
        presentPolicy: presentPolicy,
        minImageCount: minImageCount,
        format: format,
        description: description,
      );

  @override
  String toString() => 'VulkanWindowSurfaceDescriptor(${platform.name} '
      '0x${windowHandle.toUnsigned(64).toRadixString(16)}, '
      '${pixelWidth}x$pixelHeight @${scale}x, ${presentPolicy.name}, '
      '$description)';
}
