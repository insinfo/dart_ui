/// The three platform surface create-infos, by hand, and why they are not
/// generated.
///
/// `vulkan_ffi.g.dart` is produced by `ffigen` from the pinned Khronos headers
/// and `--verify-existing` fails the build on a hand edit, so anything this
/// backend needs from Vulkan belongs *there* rather than here. These four
/// structures are the exception, and the reason is not convenience:
///
///   1. **They are not in `vulkan_core.h`.** `VkWin32SurfaceCreateInfoKHR`
///      lives in `vulkan_win32.h`, which is guarded by
///      `VK_USE_PLATFORM_WIN32_KHR` and includes `windows.h`. Adding it to the
///      generator's entry points would make the whole generation depend on the
///      Windows SDK headers parsing under libclang - on every machine, for
///      every regeneration, including the Linux one.
///   2. **They name window-system types.** `HWND`, `HINSTANCE`, `Display*`,
///      `xcb_connection_t*`, `wl_display*`. `test/architecture/layering_test.dart`
///      fails the build if any file under `lib/src` outside `backends/` so much
///      as *names* those, and this directory is under `lib/src/rendering`. A
///      generated file would name them, so a generated file cannot live here.
///
/// The way through is the one `d3d12_surface_descriptor.dart` already uses and
/// states its reasoning for: **the handle crosses as an integer**. Every field
/// below that the header declares as a pointer to a window-system type is an
/// `IntPtr` here. Nothing in this directory dereferences it; it is written into
/// the create-info and handed straight back to the driver, and the code that
/// knows what the number means is the backend that produced it.
///
/// The consequence is stated rather than hidden: **this file cannot validate a
/// handle.** A stale, freed or simply wrong integer is indistinguishable from a
/// live one, and the failure surfaces as the driver's own
/// `VK_ERROR_INITIALIZATION_FAILED` or as a validation message naming the
/// window - which `VulkanSurface.create` reports by name rather than throwing.
///
/// ## The layouts, quoted
///
/// Each structure carries the header lines it was transcribed from, because a
/// hand-written FFI struct whose source nobody can check is exactly the debt
/// the generated file exists to avoid. `vulkan_wsi_layout_test.dart` asserts
/// the sizes and offsets that follow from those lines, on the same principle
/// as `vulkan_layout_test.dart`: a field that moves is a driver reading a
/// window handle out of a padding word.
library;

import 'dart:ffi';

/// `VkWin32SurfaceCreateInfoKHR`, from `vulkan_win32.h`:
///
/// ```c
/// typedef struct VkWin32SurfaceCreateInfoKHR {
///     VkStructureType                 sType;
///     const void*                     pNext;
///     VkWin32SurfaceCreateFlagsKHR    flags;
///     HINSTANCE                       hinstance;
///     HWND                            hwnd;
/// } VkWin32SurfaceCreateInfoKHR;
/// ```
///
/// [hinstance] and [hwnd] are `IntPtr` rather than `Pointer<Void>` for the
/// reason in the library comment: an `HWND` is not a pointer this code may
/// name, and an integer is how it crosses the layering boundary. `IntPtr` is
/// the same width as a pointer on every platform Dart runs on, which is what
/// makes the substitution a spelling rather than a change of layout.
final class VkWin32SurfaceCreateInfoKHR extends Struct {
  @UnsignedInt()
  external int sType;

  external Pointer<Void> pNext;

  @Uint32()
  external int flags;

  @IntPtr()
  external int hinstance;

  @IntPtr()
  external int hwnd;
}

/// `VkXlibSurfaceCreateInfoKHR`, from `vulkan_xlib.h`:
///
/// ```c
/// typedef struct VkXlibSurfaceCreateInfoKHR {
///     VkStructureType               sType;
///     const void*                   pNext;
///     VkXlibSurfaceCreateFlagsKHR   flags;
///     Display*                      dpy;
///     Window                        window;
/// } VkXlibSurfaceCreateInfoKHR;
/// ```
///
/// `Window` is `XID`, which is `unsigned long` - **64 bits on Linux and 32 on
/// Windows**. `IntPtr` is the right width on both for the same reason
/// `unsigned long` is: it follows the data model. Xlib surfaces only exist on
/// platforms where Xlib does, so the Windows width is academic; it is spelled
/// this way so that it cannot be wrong if that stops being true.
final class VkXlibSurfaceCreateInfoKHR extends Struct {
  @UnsignedInt()
  external int sType;

  external Pointer<Void> pNext;

  @Uint32()
  external int flags;

  @IntPtr()
  external int dpy;

  @IntPtr()
  external int window;
}

/// `VkXcbSurfaceCreateInfoKHR`, from `vulkan_xcb.h`:
///
/// ```c
/// typedef struct VkXcbSurfaceCreateInfoKHR {
///     VkStructureType              sType;
///     const void*                  pNext;
///     VkXcbSurfaceCreateFlagsKHR   flags;
///     xcb_connection_t*            connection;
///     xcb_window_t                 window;
/// } VkXcbSurfaceCreateInfoKHR;
/// ```
///
/// Note the asymmetry with Xlib and the reason it matters: `xcb_window_t` is a
/// `uint32_t`, **not** a pointer-width id. Writing it as `IntPtr` would move
/// the structure's size by four bytes on 64-bit and make every surface
/// creation fail in a way that reads like a bad connection.
final class VkXcbSurfaceCreateInfoKHR extends Struct {
  @UnsignedInt()
  external int sType;

  external Pointer<Void> pNext;

  @Uint32()
  external int flags;

  @IntPtr()
  external int connection;

  @Uint32()
  external int window;
}

/// `VkWaylandSurfaceCreateInfoKHR`, from `vulkan_wayland.h`:
///
/// ```c
/// typedef struct VkWaylandSurfaceCreateInfoKHR {
///     VkStructureType                  sType;
///     const void*                      pNext;
///     VkWaylandSurfaceCreateFlagsKHR   flags;
///     struct wl_display*               display;
///     struct wl_surface*               surface;
/// } VkWaylandSurfaceCreateInfoKHR;
/// ```
final class VkWaylandSurfaceCreateInfoKHR extends Struct {
  @UnsignedInt()
  external int sType;

  external Pointer<Void> pNext;

  @Uint32()
  external int flags;

  @IntPtr()
  external int display;

  @IntPtr()
  external int surface;
}

/// The instance extension each platform's surface needs, beside
/// `VK_KHR_surface`.
///
/// Named here rather than at the call site because the name and the structure
/// are the two halves of one fact: enabling `VK_KHR_win32_surface` is what
/// makes `vkCreateWin32SurfaceKHR` resolve, and a mismatch between the two is a
/// null function pointer rather than a compile error.
const String vkKhrWin32SurfaceExtension = 'VK_KHR_win32_surface';
const String vkKhrXlibSurfaceExtension = 'VK_KHR_xlib_surface';
const String vkKhrXcbSurfaceExtension = 'VK_KHR_xcb_surface';
const String vkKhrWaylandSurfaceExtension = 'VK_KHR_wayland_surface';
