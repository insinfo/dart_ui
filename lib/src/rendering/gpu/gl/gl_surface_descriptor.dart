/// What a GL target needs to know about a window, and nothing more.
///
/// Until this file existed, `MemorySurfaceDescriptor` was the only
/// [NativeSurfaceDescriptor] in the framework, so `GlRenderDevice.createTarget`
/// could only ever build an offscreen framebuffer object and read it back.
/// That made the whole GL backend an image exporter with a renderer inside it:
/// correct, testable, and unable to put a pixel on a screen.
///
/// ## Why the handle is an `int`
///
/// [GlWindowSurfaceDescriptor.nativeHandle] is a plain integer, not an `HWND`,
/// an `xcb_window_t` or an `NSView*`. The reason is the one
/// `lib/src/platform/native_window.dart` gives for `NativeWindowId`, quoted
/// because it is the same rule and not a coincidence:
///
/// > Deliberately not the native handle. `HWND`, `xcb_window_t` and
/// > `CGSWindowID` have different widths and lifetimes, and letting them leak
/// > into common code is how backend-specific assumptions spread.
///
/// This descriptor lives one layer lower than `NativeWindowId` - it *is* the
/// native handle rather than an identity for one - but the constraint on the
/// type is identical and is enforced mechanically:
/// `test/architecture/layering_test.dart` fails the build if any file under
/// `lib/src` outside `backends/` so much as names `HWND` or `xcb_`. The
/// integer is how the value crosses that line. It is the same trick
/// `GlContextFactory.createForDeviceContext` already plays with a Win32 device
/// context, and it costs nothing: the renderer never dereferences the number,
/// it only hands it back to the code that produced it.
///
/// The consequence is stated out loud rather than hidden: **this file cannot
/// validate the handle**. A stale, freed or simply wrong integer is
/// indistinguishable from a live one here, and the failure surfaces in the
/// window system's own error - a `SetPixelFormat` refusal, an EGL
/// `EGL_BAD_NATIVE_WINDOW`. That is why [GlWindowSurfaceDescriptor] also
/// carries the [swapChain] that produced the handle: the object that knows
/// what the number means is the only one that can present it, so the two
/// travel together instead of the renderer being trusted to pair them.
///
/// ## Why the generation token is here and not invented by the target
///
/// A window resizes on the window system's schedule, not the renderer's. The
/// frame that was recorded against a 800x600 back buffer must not be swapped
/// into a 1200x900 one - it would be stretched, torn, or drawn into memory the
/// driver already released. `lib/src/foundation/lifecycle.dart` already solves
/// this: the window owns a [GenerationToken], invalidates it when its surfaces
/// move, and every piece of work carries the generation it was recorded under.
///
/// Putting the *window's* token in the descriptor is what makes that contract
/// reach the GPU. A target that invented its own counter could only reject
/// frames it had itself invalidated, which is precisely the case that does not
/// matter; the dangerous one is the resize the target has not heard about yet.
library;

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../framebuffer.dart';
import '../../renderer.dart';

/// The window-system half of a presenting GL target.
///
/// The renderer draws; something else owns the buffers and shows them. On
/// Windows that something is a device context and `SwapBuffers`; on X11 and
/// Wayland it is an `EGLSurface` and `eglSwapBuffers`. Both are reduced to
/// this interface so that `GlWindowTarget` contains no platform branch at all.
///
/// Implementations live where the platform types are legal:
/// `lib/src/backends/win32/win32_gl_surface.dart` and
/// `lib/src/backends/x11/x11_gl_surface.dart`, plus the EGL window context in
/// `gl_context.dart`, which is allowed because EGL is a driver API rather than
/// a window API and names no window type.
///
/// Every method reports failure by returning something, never by throwing. A
/// present that throws unwinds through the frame loop; a present that reports
/// gets turned into a [PresentResult] with a diagnostic attached, which is
/// what section 6.6 asks for.
abstract interface class GlSwapChain {
  /// Shows the back buffer. False means the window system refused, which is
  /// what a destroyed window looks like from here.
  ///
  /// Must be called with the GL context current: on WGL the swap is defined in
  /// terms of the calling thread's current context, and on EGL the surface
  /// being swapped is the one bound to it.
  bool swapBuffers();

  /// Asks for [interval] vertical blanks between swaps. 0 disables vsync.
  ///
  /// Returns false when the platform has no control over it - a remote desktop
  /// session, a driver without `WGL_EXT_swap_control` - rather than pretending
  /// the request took effect. A caller that needs to know whether frames are
  /// paced must check this, not assume.
  bool setSwapInterval(int interval);

  /// Tells the swap chain the window is now [pixelWidth] x [pixelHeight].
  ///
  /// Returns null on success, or the reason the surface could not be brought
  /// to that size. Implementations differ in how much work this is and the
  /// difference is deliberate rather than hidden:
  ///
  ///   * WGL has nothing to do. The back buffer belongs to the window's device
  ///     context and the window system resizes it; the call exists so the
  ///     caller does not need to know that.
  ///   * EGL usually has nothing to do either - a window surface tracks its
  ///     native window - but not always, and the implementation there checks
  ///     what the driver actually reports before deciding.
  ///
  /// It is not a promise that the *next* swap is the right size. The window
  /// may resize again a microsecond later, which is what the generation token
  /// is for.
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  });

  /// Whether this swap chain can still be presented to.
  ///
  /// False after the window it belongs to was destroyed. Checked before a
  /// swap so a dead window becomes a named present failure instead of an
  /// access violation inside the driver.
  bool get isPresentable;
}

/// A window a GL context can present into.
///
/// Handed to `GlRenderDevice.createTarget`, which builds a `GlWindowTarget`
/// from it. The device refuses anything it does not recognise with a named
/// [UnsupportedCapabilityError] rather than quietly falling back to an
/// offscreen target that would render correctly and show nothing.
final class GlWindowSurfaceDescriptor implements NativeSurfaceDescriptor {
  GlWindowSurfaceDescriptor({
    required this.nativeHandle,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.swapChain,
    required this.generation,
    this.scale = 1.0,
    this.format = PixelFormat.rgba8888Premultiplied,
    this.description = 'window',
  })  : assert(pixelWidth > 0 && pixelHeight > 0),
        assert(scale > 0);

  /// `gl-window`. Diagnostics only - `NativeSurfaceDescriptor.kind` documents
  /// that branching on it is how backend assumptions get into common code, and
  /// `GlRenderDevice.createTarget` type-tests instead.
  @override
  String get kind => 'gl-window';

  /// The window, as whatever integer the platform calls one.
  ///
  /// See the library comment for why this is an `int`. Nothing in
  /// `lib/src/rendering` may interpret it; it exists so the target can name
  /// the window in a diagnostic and so a caller can prove two descriptors
  /// refer to the same window.
  final int nativeHandle;

  /// Physical pixels, already multiplied by [scale] by whoever built this.
  ///
  /// Physical and not logical because that is what `glViewport` and
  /// `glScissor` take. A descriptor that carried logical units would push the
  /// multiplication into the draw loop, where getting it wrong produces a
  /// renderer that is subtly soft on a HiDPI monitor and sharp everywhere
  /// else - the hardest class of rendering bug to notice.
  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  /// Physical pixels per logical unit, from the monitor the window is on.
  ///
  /// Carried even though the GL path does not multiply by it, because the
  /// scene above does, and a target that did not report the scale it was built
  /// for could not tell a caller that its assumption had gone stale.
  @override
  final double scale;

  /// The pixel format the window's back buffer was configured with.
  ///
  /// Defaults to RGBA rather than the framework-wide BGRA default because that
  /// is the order GL's own default framebuffer uses, and because nothing reads
  /// these pixels back - the value is here for diagnostics and for a caller
  /// comparing a window surface against a memory one.
  final PixelFormat format;

  /// How the back buffer reaches the screen.
  final GlSwapChain swapChain;

  /// The *window's* lifetime counter, not the target's.
  ///
  /// The window invalidates it on every resize, scale change and close. The
  /// target folds [GenerationToken.current] into its own `generation`, so a
  /// frame recorded before a resize is rejected on present with
  /// `PresentStatus.stale` instead of being swapped into a buffer that moved.
  ///
  /// Shared, not copied. A snapshot would be a number that was true once.
  final GenerationToken generation;

  /// Free text for probe reports and bug reports - a driver name, a window
  /// title, `hidden test window`. Never parsed.
  final String description;

  /// The same window at a new size.
  ///
  /// Returns a new descriptor rather than mutating, because a descriptor is
  /// the record of what a frame was recorded against and a mutable one could
  /// not serve as that record. The [swapChain] and the [generation] are shared
  /// with the original on purpose: they belong to the window, which did not
  /// change.
  GlWindowSurfaceDescriptor resized({
    required int pixelWidth,
    required int pixelHeight,
    double? scale,
  }) =>
      GlWindowSurfaceDescriptor(
        nativeHandle: nativeHandle,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        swapChain: swapChain,
        generation: generation,
        scale: scale ?? this.scale,
        format: format,
        description: description,
      );

  @override
  String toString() => 'GlWindowSurfaceDescriptor(0x'
      '${nativeHandle.toUnsigned(64).toRadixString(16)}, '
      '${pixelWidth}x$pixelHeight @${scale}x, $description)';
}
