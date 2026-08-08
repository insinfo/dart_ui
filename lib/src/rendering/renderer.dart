/// The renderer contracts of section 9.5, plus the capability report of 9.7.
///
/// The rule these encode: **a control never asks Direct3D or Metal anything.**
/// It asks [RendererCapabilities], which every backend answers in the same
/// vocabulary. That is what lets the same widget code run over a CPU
/// rasteriser in a test and over Metal on a laptop without a single
/// conditional mentioning either.
///
/// The split between backend, device and target mirrors what the platform APIs
/// actually are, rather than flattening them:
///
///   RendererBackend   the API is available on this machine (a DLL loaded,
///                     a driver answered). One per process.
///   RenderDevice      an open connection to a GPU or a CPU raster context.
///                     Devices are lost - a GPU reset, a driver update - and
///                     recreating one must not mean recreating the window.
///   RenderTarget      the pixels for one surface. Bound to a window and dies
///                     with it, while the device outlives both.
library;

import 'dart:async';

import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/rect.dart';
import 'framebuffer.dart';

/// What the caller wants to draw into.
///
/// Deliberately abstract: a Win32 `HWND`, an `IOSurface` id and an X11 shm
/// segment have nothing in common except that a renderer can be asked whether
/// it knows how to present to one. Backends downcast to their own subtype;
/// common code never does.
abstract interface class NativeSurfaceDescriptor {
  /// For diagnostics only - never branch on this. Branching on a name is how
  /// backend-specific assumptions get into common code.
  String get kind;

  int get pixelWidth;
  int get pixelHeight;

  /// Physical pixels per logical unit.
  double get scale;
}

/// A surface that is just memory. The headless backend presents to one, and so
/// does every golden test.
final class MemorySurfaceDescriptor implements NativeSurfaceDescriptor {
  const MemorySurfaceDescriptor({
    required this.pixelWidth,
    required this.pixelHeight,
    this.scale = 1.0,
    this.format = PixelFormat.bgra8888Premultiplied,
  });

  @override
  String get kind => 'memory';

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  final PixelFormat format;
}

/// Identity of a renderer, for logs and for the capability report.
final class RendererInfo {
  const RendererInfo({
    required this.name,
    required this.deviceDescription,
    this.driverVersion,
  });

  /// Stable identifier - `cpu`, `direct2d`, `metal`. Selection policy may match
  /// on this; rendering code may not.
  final String name;

  /// What the machine reported: an adapter string, a GPU model, or just
  /// `software`. Goes straight into bug reports.
  final String deviceDescription;

  final String? driverVersion;

  @override
  String toString() => driverVersion == null
      ? '$name ($deviceDescription)'
      : '$name ($deviceDescription, driver $driverVersion)';
}

/// The abstract questions a control is allowed to ask, from section 9.7.
final class RendererCapabilities {
  const RendererCapabilities({
    required this.supportsPartialPresent,
    required this.supportsMsaa,
    required this.supportsCompute,
    required this.supportsExternalTextures,
    required this.supportsLinearColor,
    required this.maxTextureSize,
    required this.formats,
  });

  /// Whether presenting only the damaged region is honoured. When false, damage
  /// tracking is still worth doing - it saves rasterisation - but the present
  /// itself costs a whole surface.
  final bool supportsPartialPresent;

  final bool supportsMsaa;
  final bool supportsCompute;
  final bool supportsExternalTextures;
  final bool supportsLinearColor;
  final int maxTextureSize;
  final Set<PixelFormat> formats;

  bool supportsFormat(PixelFormat format) => formats.contains(format);
}

/// One frame in progress on a [RenderTarget].
///
/// Holding a [Framebuffer] rather than an opaque handle is what makes the CPU
/// path and the golden tests the same code. A GPU backend maps its staging
/// buffer here, or refuses CPU access and reports it through capabilities.
final class Frame {
  Frame({
    required this.target,
    required this.framebuffer,
    required this.damage,
    required this.generation,
  });

  final RenderTarget target;
  final Framebuffer framebuffer;

  /// The region the caller promised to redraw. A backend without partial
  /// present ignores it; one with it presents exactly this.
  final Rect damage;

  /// The target's lifetime this frame belongs to. A frame presented after its
  /// target was resized or lost must be rejected, not drawn.
  final int generation;
}

/// What the caller wants from [RenderTarget.beginFrame].
final class FrameRequest {
  const FrameRequest({
    this.damage,
    this.clearColor,
  });

  /// Null means "the whole surface is dirty".
  final Rect? damage;

  /// Premultiplied BGRA packed into a 32-bit int, or null to leave the
  /// previous contents. Leaving them is only safe when the backend preserves
  /// them, which [RendererCapabilities.supportsPartialPresent] implies.
  final int? clearColor;
}

enum PresentStatus {
  presented,

  /// The frame was dropped because it belonged to a previous generation. Not
  /// an error: it is what a resize during a frame looks like.
  stale,

  /// The device is gone - GPU reset, driver update, surface destroyed. The
  /// caller must recreate the device, not retry the frame.
  deviceLost,

  failed,
}

final class PresentResult {
  const PresentResult({required this.status, this.diagnostic});

  final PresentStatus status;

  /// Present when [status] is not [PresentStatus.presented]. Names what
  /// happened, per section 6.6 - a failed present that logs nothing is the
  /// hardest kind of rendering bug to chase.
  final BackendDiagnostic? diagnostic;

  bool get isSuccess => status == PresentStatus.presented;
}

/// The pixels of one surface.
abstract interface class RenderTarget implements Disposable {
  NativeSurfaceDescriptor get surface;

  /// Incremented by [resize] and by device loss. Frames carry it so a late
  /// present can be rejected instead of drawn into a buffer that moved.
  int get generation;

  Frame beginFrame(FrameRequest request);
  Future<PresentResult> present(Frame frame);

  void resize(int pixelWidth, int pixelHeight, double scale);
}

/// An open connection to whatever draws.
abstract interface class RenderDevice implements Disposable {
  RendererInfo get info;
  RendererCapabilities get capabilities;

  /// Whether the device is still usable. False after a GPU reset; the owner
  /// must build a new device, and the window survives.
  bool get isLost;

  RenderTarget createTarget(NativeSurfaceDescriptor surface);
}

/// The renderer API as a whole, on this machine.
abstract interface class RendererBackend {
  RendererInfo get info;

  /// Whether this backend can run here, and if not, exactly why. Never a bare
  /// bool: section 6.6 forbids choosing another backend without saying what
  /// was wrong with this one.
  BackendProbeResult probe();

  bool supportsSurface(NativeSurfaceDescriptor surface);

  Future<RenderDevice> createDevice();
}
