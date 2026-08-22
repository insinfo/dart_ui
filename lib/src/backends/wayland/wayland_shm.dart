/// CPU-visible Wayland surface presented through `wl_shm`.
///
/// This layer intentionally contains no FFI, exactly like `x11_surface.dart`:
/// the connection owns the native side (memfd, mmap, the `wl_shm_pool` and
/// `wl_buffer` protocol objects), while [WaylandShmSurface] owns the returned
/// buffer's lifetime and exposes its pixels through the renderer's common
/// [Framebuffer] contract. Keeping the boundary pointer-free makes damage,
/// generation and teardown testable on hosts without a compositor.
library;

import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/renderer.dart';
import 'wayland_protocol.dart';

/// Geometry of one shm pool: stride, byte length and wire format, derived in
/// one place so the create_pool/create_buffer requests and the [Framebuffer]
/// can never disagree about layout.
final class WaylandShmPoolPlan {
  factory WaylandShmPoolPlan({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    if (pixelWidth <= 0) {
      throw ArgumentError.value(pixelWidth, 'pixelWidth', 'must be positive');
    }
    if (pixelHeight <= 0) {
      throw ArgumentError.value(pixelHeight, 'pixelHeight', 'must be positive');
    }
    // wl_shm_pool.create_buffer carries int32 geometry; anything larger than
    // this cannot even be requested. The practical ceiling is the compositor's
    // own texture limit, reported as a protocol error rather than guessed.
    if (pixelWidth > 0x7fff || pixelHeight > 0x7fff) {
      throw RangeError('wl_shm buffers are limited to 32767x32767 pixels');
    }
    final stride = pixelWidth * 4;
    return WaylandShmPoolPlan._(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      strideBytes: stride,
      byteLength: stride * pixelHeight,
      format: wlShmFormatArgb8888,
    );
  }

  const WaylandShmPoolPlan._({
    required this.pixelWidth,
    required this.pixelHeight,
    required this.strideBytes,
    required this.byteLength,
    required this.format,
  });

  final int pixelWidth;
  final int pixelHeight;

  /// Tightly packed: the framework rasteriser assumes `width * 4` and the
  /// compositor is told the same number, so no row-walking loop can diverge.
  final int strideBytes;

  final int byteLength;

  /// `wl_shm.format`. ARGB8888's little-endian memory layout is byte-for-byte
  /// the framework's premultiplied BGRA.
  final int format;

  @override
  String toString() => 'WaylandShmPoolPlan(${pixelWidth}x$pixelHeight, '
      'stride $strideBytes, $byteLength bytes)';
}

/// Anonymous shared memory the compositor can map too.
///
/// The production implementation is a `memfd_create` + `mmap` pair; tests
/// substitute a plain [Uint8List] with a fake descriptor.
abstract interface class WaylandShmMemory implements Disposable {
  /// The descriptor sent with `wl_shm.create_pool`. The transport duplicates
  /// nothing: after the pool is created the compositor holds its own
  /// reference and this one may be closed.
  int get fd;

  /// The client-side mapping, exactly [WaylandShmPoolPlan.byteLength] long.
  Uint8List get bytes;
}

/// Allocates [WaylandShmMemory]. Split from the connection so the shm pool
/// bookkeeping can be exercised without `memfd_create` existing on the host.
abstract interface class WaylandShmAllocator {
  /// False when the host cannot make anonymous shared memory at all, which
  /// rules out CPU presentation before any protocol request is sent.
  bool get isAvailable;

  /// Zero-initialised shared memory, or a thrown [StateError] naming errno.
  WaylandShmMemory allocate(int byteLength);

  /// Maps a descriptor the compositor sent (the xkb keymap). Returns null on
  /// failure; the caller reports it. The mapping is copied, not borrowed.
  Uint8List? readSharedMemory(int fd, int byteLength);
}

/// An allocation suitable for Wayland CPU presentation. The client that
/// created it owns the native pool/buffer objects; the surface borrows
/// [framebuffer] until it calls [WaylandCpuClient.destroyShmBuffer].
abstract interface class WaylandShmBufferHandle {
  Framebuffer get framebuffer;
}

/// A device-pixel rectangle submitted as damage from an shm buffer.
final class WaylandCpuDamage {
  const WaylandCpuDamage({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is WaylandCpuDamage &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'WaylandCpuDamage($x, $y, $width, $height)';
}

/// Native allocation and commit operations needed by [WaylandShmSurface].
abstract interface class WaylandCpuClient {
  /// Whether shm presentation is possible: the `wl_shm` global was bound,
  /// ARGB8888 was advertised and anonymous shared memory can be allocated.
  bool get supportsShmPresentation;

  WaylandShmBufferHandle createShmBuffer({
    required int pixelWidth,
    required int pixelHeight,
  });

  void destroyShmBuffer(WaylandShmBufferHandle buffer);

  /// Attaches [buffer] to [surfaceId], damages [damage] in buffer pixels and
  /// commits. Returns null on success, a diagnostic naming the failure
  /// otherwise.
  BackendDiagnostic? presentShmBuffer({
    required int surfaceId,
    required WaylandShmBufferHandle buffer,
    required WaylandCpuDamage damage,
    required int bufferScale,
  });
}

/// CPU framebuffer and presentation seam exposed by a Wayland window.
abstract interface class WaylandCpuSurface implements NativeSurfaceDescriptor {
  int get generation;
  Framebuffer get framebuffer;
  BackendDiagnostic? present({Rect? damage});
}

/// A tightly packed BGRA shm buffer committed to one `wl_surface`.
///
/// One instance belongs to exactly one window size and generation, the same
/// replace-not-mutate rule as `X11PutImageSurface`: a resize creates a new
/// surface for the new configure, so a frame holding the previous object is
/// rejected by identity and [generation] before touching released memory.
final class WaylandShmSurface with DisposableMixin implements WaylandCpuSurface {
  WaylandShmSurface._({
    required WaylandCpuClient client,
    required WaylandShmBufferHandle buffer,
    required this.surfaceId,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.scale,
    required this.bufferScale,
    required this.generation,
  })  : _client = client,
        _buffer = buffer;

  /// Allocates a surface or throws without leaking a partially accepted
  /// buffer. Presentation capability is checked before allocation.
  static WaylandShmSurface create({
    required WaylandCpuClient client,
    required int surfaceId,
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
    required int bufferScale,
    required int generation,
  }) {
    if (!client.supportsShmPresentation) {
      throw UnsupportedCapabilityError(
        backendName: 'wayland',
        capability: Capability.cpuPresentation,
        detail: 'the compositor offers no usable wl_shm ARGB8888 path',
      );
    }
    if (surfaceId == 0) {
      throw ArgumentError.value(surfaceId, 'surfaceId', 'must not be null');
    }
    if (pixelWidth <= 0) {
      throw ArgumentError.value(pixelWidth, 'pixelWidth', 'must be positive');
    }
    if (pixelHeight <= 0) {
      throw ArgumentError.value(pixelHeight, 'pixelHeight', 'must be positive');
    }
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and positive');
    }
    if (bufferScale < 1) {
      throw ArgumentError.value(bufferScale, 'bufferScale', 'must be >= 1');
    }
    if (generation < 0) {
      throw ArgumentError.value(
          generation, 'generation', 'must be non-negative');
    }

    final buffer = client.createShmBuffer(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    try {
      final framebuffer = buffer.framebuffer;
      if (framebuffer.width != pixelWidth ||
          framebuffer.height != pixelHeight) {
        throw StateError(
          'Wayland shm buffer geometry is ${framebuffer.width}x'
          '${framebuffer.height}; expected ${pixelWidth}x$pixelHeight',
        );
      }
      if (framebuffer.format != PixelFormat.bgra8888Premultiplied) {
        throw StateError(
          'wl_shm ARGB8888 needs bgra8888Premultiplied; '
          'got ${framebuffer.format.name}',
        );
      }
      return WaylandShmSurface._(
        client: client,
        buffer: buffer,
        surfaceId: surfaceId,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        bufferScale: bufferScale,
        generation: generation,
      );
    } on Object {
      client.destroyShmBuffer(buffer);
      rethrow;
    }
  }

  final WaylandCpuClient _client;
  final WaylandShmBufferHandle _buffer;

  @override
  String get kind => 'wayland-shm';

  /// The `wl_surface` protocol id this buffer is committed to.
  final int surfaceId;

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  /// The integer `wl_surface.set_buffer_scale` factor. [pixelWidth] is the
  /// surface's logical width times this.
  final int bufferScale;

  @override
  final int generation;

  @override
  Framebuffer get framebuffer => _buffer.framebuffer;

  /// Commits the full buffer, or the outward-rounded intersection of [damage]
  /// with this surface. [damage] is in logical client coordinates; a no-op
  /// (empty or fully clipped damage) is a successful presentation.
  @override
  BackendDiagnostic? present({Rect? damage}) {
    throwIfDisposed();
    final region = damage == null ? _fullDamage : _deviceDamage(damage);
    if (region == null) return null;
    if (!_client.supportsShmPresentation) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'Wayland shm presentation became unavailable',
      );
    }
    try {
      return _client.presentShmBuffer(
        surfaceId: surfaceId,
        buffer: _buffer,
        damage: region,
        bufferScale: bufferScale,
      );
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'Wayland shm presentation threw',
        detail: '$error',
      );
    }
  }

  WaylandCpuDamage get _fullDamage => WaylandCpuDamage(
        x: 0,
        y: 0,
        width: pixelWidth,
        height: pixelHeight,
      );

  WaylandCpuDamage? _deviceDamage(Rect logical) {
    if (!logical.left.isFinite ||
        !logical.top.isFinite ||
        !logical.right.isFinite ||
        !logical.bottom.isFinite) {
      throw ArgumentError.value(logical, 'damage', 'edges must be finite');
    }
    if (logical.isEmpty) return null;
    final left = _clamp((logical.left * scale).floor(), 0, pixelWidth);
    final top = _clamp((logical.top * scale).floor(), 0, pixelHeight);
    final right = _clamp((logical.right * scale).ceil(), 0, pixelWidth);
    final bottom = _clamp((logical.bottom * scale).ceil(), 0, pixelHeight);
    if (right <= left || bottom <= top) return null;
    return WaylandCpuDamage(
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  static int _clamp(int value, int minimum, int maximum) => value < minimum
      ? minimum
      : value > maximum
          ? maximum
          : value;

  @override
  void onDispose() => _client.destroyShmBuffer(_buffer);

  @override
  String toString() => 'WaylandShmSurface('
      '${pixelWidth}x$pixelHeight @ $scale, '
      'surface: $surfaceId, generation: $generation)';
}
