/// What a Direct3D 12 target needs to know about a window, and nothing more.
///
/// The shape and the reasoning are `gl_surface_descriptor.dart`'s, and the one
/// substantive difference is stated here rather than left to be discovered:
/// **there is no swap chain object in this descriptor.**
///
/// ## Why the handle is an `int`
///
/// [D3d12WindowSurfaceDescriptor.nativeHandle] is a plain integer. The rule is
/// mechanical and not stylistic: `test/architecture/layering_test.dart` fails
/// the build if any file under `lib/src` outside `backends/` so much as names
/// the Win32 window type, and this file is under `lib/src/rendering`. The
/// integer is how the value crosses that line. Nothing here dereferences it;
/// it travels to `DXGIFactory4::CreateSwapChainForHwnd` in
/// `lib/src/backends/win32/d3d12/`, which is the one place allowed to know
/// what it is.
///
/// The consequence is the same one the GL descriptor states out loud: **this
/// file cannot validate the handle.** A stale, freed or simply wrong integer is
/// indistinguishable from a live one here, and the failure surfaces as
/// `DXGI_ERROR_INVALID_CALL` from the swap chain creation - which
/// `D3d12WindowTarget` reports by name rather than throwing.
///
/// ## Why there is no `GlSwapChain` equivalent
///
/// The GL descriptor carries the object that presents it, because on OpenGL
/// the window system owns the back buffer and `SwapBuffers` is a platform call
/// that the renderer must not make itself. Direct3D 12 inverts that: the swap
/// chain is a DXGI object created *by the renderer*, from the command queue
/// the renderer owns, and it cannot exist before the device does. So there is
/// nothing to hand in - the target creates the swap chain in its constructor
/// and owns it for its whole life. Passing one in would mean creating it
/// against a queue the caller would have to have obtained from the device
/// first, which is the same coupling with an extra step.
///
/// ## Why the buffer count is here
///
/// [bufferCount] is a property of the *surface*, not of the device, because it
/// decides how many frames the compositor may hold and therefore how much
/// latency the window has. Two is the flip model's minimum and the default;
/// three trades a frame of latency for tolerance of a late frame. It is
/// declared here so that a caller who wants the trade can make it per window,
/// and so that a reader of a bug report can see which one was in force.
library;

import '../../framebuffer.dart';
import '../../renderer.dart';

/// A window a Direct3D 12 swap chain can present into.
///
/// Handed to `D3d12RenderDevice.createTarget`, which builds a
/// `D3d12WindowTarget` from it. The device refuses anything it does not
/// recognise with a named [UnsupportedCapabilityError] rather than quietly
/// building an offscreen target that would render correctly and show nothing.
final class D3d12WindowSurfaceDescriptor implements NativeSurfaceDescriptor {
  D3d12WindowSurfaceDescriptor({
    required this.nativeHandle,
    required this.pixelWidth,
    required this.pixelHeight,
    this.scale = 1.0,
    this.bufferCount = kDefaultBufferCount,
    this.format = PixelFormat.rgba8888Premultiplied,
    this.description = 'window',
  })  : assert(pixelWidth > 0 && pixelHeight > 0),
        assert(scale > 0),
        assert(
          bufferCount >= 2,
          'DXGI_SWAP_EFFECT_FLIP_DISCARD requires at least two buffers; the '
          'blt-model swap effects that allowed one do not exist in Direct3D 12',
        );

  /// The minimum the flip model allows, and the default.
  ///
  /// Two rather than three because a UI framework that renders on demand
  /// spends most of its life presenting one frame and then waiting, where the
  /// third buffer buys nothing and costs a surface's worth of video memory.
  static const int kDefaultBufferCount = 2;

  /// `d3d12-window`. Diagnostics only - [NativeSurfaceDescriptor.kind]
  /// documents that branching on it is how backend assumptions get into common
  /// code, and the device type-tests instead.
  @override
  String get kind => 'd3d12-window';

  /// The window, as whatever integer the platform calls one. See the library
  /// comment for why this is not a typed handle.
  final int nativeHandle;

  /// Physical pixels, already multiplied by [scale] by whoever built this.
  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  /// Back buffers in the swap chain. See the library comment.
  final int bufferCount;

  /// The pixel format the back buffers carry.
  ///
  /// Defaults to RGBA because that is `DXGI_FORMAT_R8G8B8A8_UNORM`, which is
  /// what this backend creates its swap chains and its offscreen surfaces
  /// with; the value is here for diagnostics and for a caller comparing a
  /// window surface against a memory one.
  final PixelFormat format;

  /// Free text for probe reports and bug reports. Never parsed.
  final String description;

  /// The same window at a new size.
  ///
  /// A new descriptor rather than a mutation, because a descriptor is the
  /// record of what a frame was recorded against and a mutable one could not
  /// serve as that record.
  D3d12WindowSurfaceDescriptor resized({
    required int pixelWidth,
    required int pixelHeight,
    double? scale,
  }) =>
      D3d12WindowSurfaceDescriptor(
        nativeHandle: nativeHandle,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale ?? this.scale,
        bufferCount: bufferCount,
        format: format,
        description: description,
      );

  @override
  String toString() => 'D3d12WindowSurfaceDescriptor(0x'
      '${nativeHandle.toUnsigned(64).toRadixString(16)}, '
      '${pixelWidth}x$pixelHeight @${scale}x, $bufferCount buffers, '
      '$description)';
}
