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

  /// True from the commit that attached this buffer until the compositor's
  /// `wl_buffer.release`. Writing into a busy buffer is the tearing the
  /// protocol warns about; [WaylandShmSurface] consults this to rotate.
  bool get isBusy;
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

/// A small swapchain of tightly packed BGRA shm buffers committed to one
/// `wl_surface`.
///
/// One instance belongs to exactly one window size and generation, the same
/// replace-not-mutate rule as `X11PutImageSurface`: a resize creates a new
/// surface for the new configure, so a frame holding the previous object is
/// rejected by identity and [generation] before touching released memory.
///
/// ## Why more than one buffer
///
/// The protocol says a committed buffer belongs to the compositor until it
/// sends `wl_buffer.release`; writing into it meanwhile is exactly the
/// transient tearing the first version of this backend documented as a
/// limitation. The fix is rotation, not copying: [framebuffer] hands the
/// rasteriser a buffer the compositor is *not* holding - the last committed
/// one when it was already released (the common case under compositors that
/// copy shm promptly), a second or third slot when it was not - and only when
/// every slot of a full swapchain is still busy does it fall back to reusing
/// the oldest committed slot, counting that in [busyReuseCount] instead of
/// hiding it.
final class WaylandShmSurface
    with DisposableMixin
    implements WaylandCpuSurface {
  WaylandShmSurface._({
    required WaylandCpuClient client,
    required WaylandShmBufferHandle firstSlot,
    required this.surfaceId,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.scale,
    required this.bufferScale,
    required this.generation,
    required int maximumSlots,
  })  : _client = client,
        _maximumSlots = maximumSlots {
    _slots.add(firstSlot);
  }

  /// Allocates a surface or throws without leaking a partially accepted
  /// buffer. Presentation capability is checked before allocation.
  /// The default swapchain depth. Two slots cover the well-behaved case
  /// (draw into one while the compositor holds the other); the third absorbs
  /// a compositor that holds a frame across a vblank.
  static const int defaultMaximumSlots = 3;

  static WaylandShmSurface create({
    required WaylandCpuClient client,
    required int surfaceId,
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
    required int bufferScale,
    required int generation,
    int maximumSlots = defaultMaximumSlots,
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
    if (maximumSlots < 1) {
      throw ArgumentError.value(maximumSlots, 'maximumSlots', 'must be >= 1');
    }

    final buffer = _allocateSlot(client, pixelWidth, pixelHeight);
    return WaylandShmSurface._(
      client: client,
      firstSlot: buffer,
      surfaceId: surfaceId,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      bufferScale: bufferScale,
      generation: generation,
      maximumSlots: maximumSlots,
    );
  }

  /// Allocates one slot and validates it, or throws without leaking a
  /// partially accepted buffer.
  static WaylandShmBufferHandle _allocateSlot(
    WaylandCpuClient client,
    int pixelWidth,
    int pixelHeight,
  ) {
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
      return buffer;
    } on Object {
      client.destroyShmBuffer(buffer);
      rethrow;
    }
  }

  final WaylandCpuClient _client;
  final int _maximumSlots;

  /// Every slot this surface owns, in allocation order.
  final List<WaylandShmBufferHandle> _slots = <WaylandShmBufferHandle>[];

  /// The slot the rasteriser is currently drawing into, selected by the
  /// [framebuffer] getter and committed by the next [present].
  WaylandShmBufferHandle? _drawTarget;

  /// The slot most recently committed; what an expose re-commits, and the
  /// preferred draw target once the compositor releases it.
  WaylandShmBufferHandle? _lastCommitted;

  /// How many times a frame had to be drawn into a still-busy buffer because
  /// the whole swapchain was held by the compositor. Nonzero means potential
  /// transient tearing - counted instead of silent, per section 6.6.
  int busyReuseCount = 0;

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

  /// How many slots exist right now. Grows on demand up to the maximum.
  int get slotCount => _slots.length;

  /// The buffer the next frame should be rasterised into.
  ///
  /// Selection order: the currently acquired draw target, then the last
  /// committed slot if the compositor has released it, then any other free
  /// slot, then a freshly allocated slot while the swapchain is not full, and
  /// only as a last resort the oldest slot even though it is busy.
  @override
  Framebuffer get framebuffer => _acquireDrawTarget().framebuffer;

  WaylandShmBufferHandle _acquireDrawTarget() {
    throwIfDisposed();
    final acquired = _drawTarget;
    if (acquired != null) return acquired;

    WaylandShmBufferHandle? chosen;
    final lastCommitted = _lastCommitted;
    if (lastCommitted != null && !lastCommitted.isBusy) {
      chosen = lastCommitted;
    } else {
      for (final slot in _slots) {
        if (!slot.isBusy) {
          chosen = slot;
          break;
        }
      }
    }
    if (chosen == null && _slots.length < _maximumSlots) {
      try {
        chosen = _allocateSlot(_client, pixelWidth, pixelHeight);
        _slots.add(chosen);
      } on Object {
        // Growth is an optimisation; failing it degrades to reuse below.
        chosen = null;
      }
    }
    if (chosen == null) {
      // Every slot is still with the compositor. Reusing the oldest is the
      // pre-swapchain behaviour, now counted instead of constant.
      busyReuseCount++;
      chosen = _slots.first;
    }
    _drawTarget = chosen;
    return chosen;
  }

  /// Commits the full buffer, or the outward-rounded intersection of [damage]
  /// with this surface. [damage] is in logical client coordinates; a no-op
  /// (empty or fully clipped damage) is a successful presentation.
  ///
  /// Commits the acquired draw target when one exists (a frame was just
  /// rasterised); otherwise re-commits the last committed slot, which is what
  /// an expose without new pixels means.
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
    final target = _drawTarget ?? _lastCommitted ?? _acquireDrawTarget();
    try {
      final failure = _client.presentShmBuffer(
        surfaceId: surfaceId,
        buffer: target,
        damage: region,
        bufferScale: bufferScale,
      );
      if (failure == null) {
        _lastCommitted = target;
        // Move the committed slot to the back so `_slots.first` stays the
        // least recently committed - the least bad candidate for forced reuse.
        if (_slots.remove(target)) _slots.add(target);
        if (identical(_drawTarget, target)) _drawTarget = null;
      }
      return failure;
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
  void onDispose() {
    // The client defers the actual wl_buffer.destroy of a busy slot until the
    // compositor releases it, which is what makes disposing mid-flight (a
    // resize while a frame is on screen) safe. See
    // `WaylandConnection.destroyShmBuffer`.
    for (final slot in _slots) {
      _client.destroyShmBuffer(slot);
    }
    _slots.clear();
    _drawTarget = null;
    _lastCommitted = null;
  }

  @override
  String toString() => 'WaylandShmSurface('
      '${pixelWidth}x$pixelHeight @ $scale, '
      'surface: $surfaceId, generation: $generation, '
      'slots: ${_slots.length}/$_maximumSlots)';
}
