/// What a Direct3D 11 target needs to know about a window, and nothing more.
///
/// The counterpart of `gl_surface_descriptor.dart`, and deliberately the same
/// shape: a window is an opaque integer, the swap chain is an interface, and
/// the *window's* generation token travels with the descriptor. Every argument
/// that file makes applies here word for word and is not repeated. What is
/// written down below is only what DXGI does differently, because those are the
/// places a port from GL goes silently wrong.
///
/// ## Why the handle is an `int` here too
///
/// `test/architecture/layering_test.dart` fails the build if any file under
/// `lib/src` outside `backends/` so much as names `HWND`. That rule is what
/// makes the core portable, and the integer is how a window crosses it. The
/// consequence is the same one `gl_surface_descriptor.dart` states out loud:
/// **this file cannot validate the handle**. A stale or simply wrong number is
/// indistinguishable from a live one here, and the failure surfaces as
/// `DXGI_ERROR_INVALID_CALL` inside `CreateSwapChainForHwnd`. That is why the
/// descriptor also carries the [D3d11SwapChain] that was built *from* that
/// handle: the object that knows what the number means is the only one that can
/// present it, so the two travel together.
///
/// ## The three things DXGI does that WGL does not
///
///   1. **A present returns an `HRESULT`, not a bool.** `IDXGISwapChain::
///      Present` distinguishes "shown", "the window is occluded so nothing was
///      drawn" (`DXGI_STATUS_OCCLUDED`, a *success* code) and "your device is
///      gone" (`DXGI_ERROR_DEVICE_REMOVED`). Collapsing that to a boolean would
///      throw away the only signal that separates a frame worth skipping from a
///      device that has to be rebuilt, so [D3d11SwapChain.present] returns the
///      raw code and `D3d11WindowTarget` maps it.
///   2. **The back buffer is a resource this renderer has to hold a view on.**
///      GL's window back buffer is framebuffer 0 - a number that never changes.
///      Here it is an `ID3D11Texture2D` obtained with `GetBuffer` and an
///      `ID3D11RenderTargetView` made from it, both of which are *destroyed and
///      recreated* by every `ResizeBuffers`. So the interface exposes
///      [D3d11SwapChain.backBufferView] as a live getter rather than a value the
///      target may cache: a target that cached it across a resize would render
///      into freed memory.
///   3. **Resizing is a real call that can fail.** `Win32GlSurface.reconfigure`
///      returns null unconditionally because a WGL back buffer belongs to the
///      window. `ResizeBuffers` allocates, and refuses outright while any
///      reference to any back buffer is outstanding - see
///      [D3d11SwapChain.reconfigure].
///
/// ## Why the generation token is here and not invented by the target
///
/// The same reason as in GL, and it is not a detail: a window resizes on the
/// window system's schedule, not the renderer's, so a target that counted only
/// its *own* resizes could reject exactly the frames that do not matter and
/// would swap the dangerous ones. `lib/src/foundation/lifecycle.dart` owns the
/// rule; putting the window's [GenerationToken] in the descriptor is what makes
/// it reach the GPU.
library;

import 'dart:ffi';

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../framebuffer.dart';
import '../../renderer.dart';

/// The window-system half of a presenting Direct3D 11 target.
///
/// The renderer draws; something else owns the buffers and shows them. On
/// Windows that something is an `IDXGISwapChain1` created over a window handle
/// by `IDXGIFactory2::CreateSwapChainForHwnd`. It is reduced to this interface
/// so that `D3d11WindowTarget` contains no platform branch at all and names no
/// window type - the implementation lives where those are legal,
/// `lib/src/backends/win32/d3d11/win32_d3d11_surface.dart`.
///
/// Every method reports failure by returning something, never by throwing. A
/// present that throws unwinds through the frame loop; a present that reports
/// becomes a [PresentResult] with a named diagnostic, which is what section 6.6
/// asks for.
abstract interface class D3d11SwapChain {
  /// The `ID3D11RenderTargetView` over the current back buffer, or `nullptr`.
  ///
  /// A live getter and never a cached value, because `ResizeBuffers` destroys
  /// the view and the texture underneath it. `nullptr` is the honest answer
  /// after a failed resize or a disposed chain, and the target turns it into a
  /// named present failure rather than handing a null pointer to
  /// `OMSetRenderTargets` - which does not fault, it silently renders nowhere.
  Pointer<Void> get backBufferView;

  /// Shows the back buffer. Returns the raw `HRESULT` from `Present`.
  ///
  /// Raw and unmapped on purpose; see the library comment. The three answers
  /// the caller must tell apart are `S_OK`, `DXGI_STATUS_OCCLUDED` (a success
  /// code meaning the frame was discarded because the window is not visible)
  /// and the `DXGI_ERROR_DEVICE_*` family.
  int present();

  /// Asks for [interval] vertical blanks between presents. 0 disables vsync.
  ///
  /// Unlike WGL, where vsync is an extension the driver may not export, this is
  /// an argument to `Present` itself and is therefore always available. It is
  /// still allowed to answer false - a chain that has been disposed cannot
  /// promise anything - so a caller that needs to know whether frames are paced
  /// must check rather than assume.
  bool setSyncInterval(int interval);

  /// Brings the back buffer to [pixelWidth] x [pixelHeight].
  ///
  /// Returns null on success, or the reason it could not.
  ///
  /// ## The call every D3D11 backend gets wrong once
  ///
  /// `ResizeBuffers` fails with `DXGI_ERROR_INVALID_CALL` unless **every**
  /// outstanding reference to **every** back buffer has been released first.
  /// Three kinds of reference exist and all three count:
  ///
  ///   * the `ID3D11RenderTargetView` the implementation made,
  ///   * the `ID3D11Texture2D` that `GetBuffer` handed back to make it,
  ///   * and anything the **immediate context** still has bound, which holds a
  ///     reference the driver counts even though no Dart object does.
  ///
  /// The first two belong to the implementation, which releases them here. The
  /// third belongs to the device, which is why `D3d11WindowTarget.resize` calls
  /// `D3d11RenderDevice.unbindTargets` *before* this method and why that method
  /// exists at all. The failure is not subtle once it happens and is impossible
  /// to guess before: the resize returns an error code, the old buffers stay,
  /// and every frame afterwards is drawn at the wrong size.
  ///
  /// It is not a promise that the *next* present is the right size. The window
  /// may resize again a microsecond later, which is what the generation token
  /// is for.
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  });

  /// Whether this swap chain can still be presented to.
  ///
  /// False after the window it belongs to was destroyed. Checked before a
  /// present so a dead window becomes a named failure instead of an access
  /// violation inside the driver.
  bool get isPresentable;
}

/// A window a Direct3D 11 device can present into.
///
/// Handed to `D3d11RenderDevice.createTarget`, which builds a
/// `D3d11WindowTarget` from it. The device refuses anything it does not
/// recognise with a named [UnsupportedCapabilityError] rather than quietly
/// falling back to an offscreen target that would render every frame correctly
/// and show none of them.
final class D3d11WindowSurfaceDescriptor implements NativeSurfaceDescriptor {
  D3d11WindowSurfaceDescriptor({
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

  /// `d3d11-window`. Diagnostics only - `NativeSurfaceDescriptor.kind`
  /// documents that branching on it is how backend assumptions get into common
  /// code, and `D3d11RenderDevice.createTarget` type-tests instead.
  @override
  String get kind => 'd3d11-window';

  /// The window, as whatever integer the platform calls one.
  ///
  /// See the library comment for why this is an `int`. Nothing in
  /// `lib/src/rendering` may interpret it; it exists so the target can name the
  /// window in a diagnostic and so a caller can prove two descriptors refer to
  /// the same window.
  final int nativeHandle;

  /// Physical pixels, already multiplied by [scale] by whoever built this.
  ///
  /// Physical because that is what `RSSetViewports` and `RSSetScissorRects`
  /// take. A descriptor carrying logical units would push the multiplication
  /// into the draw loop, where getting it wrong produces a renderer that is
  /// subtly soft on a HiDPI monitor and sharp everywhere else.
  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  /// Physical pixels per logical unit, from the monitor the window is on.
  @override
  final double scale;

  /// The pixel format the swap chain's buffers were created with.
  ///
  /// Carried for diagnostics and for a caller comparing a window surface
  /// against a memory one. Nothing reads these pixels back - that is the whole
  /// point of a window target - so this never drives a swizzle here the way it
  /// does in `D3d11OffscreenTarget._readPixels`.
  final PixelFormat format;

  /// How the back buffer reaches the screen.
  final D3d11SwapChain swapChain;

  /// The *window's* lifetime counter, not the target's.
  ///
  /// The window invalidates it on every resize, scale change and close. The
  /// target folds [GenerationToken.current] into its own generation, so a frame
  /// recorded before a resize is rejected on present with
  /// [PresentStatus.stale] instead of being drawn into a back buffer the driver
  /// has already reallocated.
  ///
  /// Shared, not copied. A snapshot would be a number that was true once.
  final GenerationToken generation;

  /// Free text for probe reports and bug reports - an adapter name, a window
  /// title, `hidden test window`. Never parsed.
  final String description;

  /// The same window at a new size.
  ///
  /// Returns a new descriptor rather than mutating, because a descriptor is the
  /// record of what a frame was recorded against and a mutable one could not
  /// serve as that record. The [swapChain] and the [generation] are shared with
  /// the original on purpose: they belong to the window, which did not change.
  D3d11WindowSurfaceDescriptor resized({
    required int pixelWidth,
    required int pixelHeight,
    double? scale,
  }) =>
      D3d11WindowSurfaceDescriptor(
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
  String toString() => 'D3d11WindowSurfaceDescriptor(0x'
      '${nativeHandle.toUnsigned(64).toRadixString(16)}, '
      '${pixelWidth}x$pixelHeight @${scale}x, $description)';
}
