/// CPU-visible X11 surface presented through the core `PutImage` protocol.
///
/// This layer intentionally contains no FFI. [X11CpuClient] owns the native
/// allocation and XCB requests, while [X11PutImageSurface] owns the returned
/// buffer's lifetime and exposes its pixels through the renderer's common
/// [Framebuffer] contract. Keeping that boundary pointer-free makes damage,
/// generation and teardown testable on hosts without an X server.
library;

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/renderer.dart';

/// An allocation suitable for X11 CPU presentation.
///
/// The client that created this object owns its native representation. The
/// surface borrows [framebuffer] until it calls [X11CpuClient.destroyCpuBuffer].
abstract interface class X11CpuBuffer {
  Framebuffer get framebuffer;
}

/// A device-pixel rectangle uploaded from an [X11CpuBuffer].
final class X11CpuDamage {
  const X11CpuDamage({
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
      other is X11CpuDamage &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'X11CpuDamage($x, $y, $width, $height)';
}

/// Native allocation and upload operations needed by [X11PutImageSurface].
///
/// Implementations may turn one [presentCpuBuffer] call into several XCB
/// requests to stay below the server's maximum request size. The region is
/// already clipped and expressed in device pixels.
abstract interface class X11CpuClient {
  /// Whether the connection's visual/depth accepts the framework's canonical
  /// premultiplied BGRA byte layout through core `PutImage`.
  bool get supportsBgraPutImage;

  X11CpuBuffer createCpuBuffer({
    required int xcbWindow,
    required int pixelWidth,
    required int pixelHeight,
  });

  void destroyCpuBuffer(X11CpuBuffer buffer);

  BackendDiagnostic? presentCpuBuffer({
    required int xcbWindow,
    required X11CpuBuffer buffer,
    required X11CpuDamage damage,
  });
}

/// CPU framebuffer and presentation seam exposed by an X11 window.
abstract interface class X11CpuSurface implements NativeSurfaceDescriptor {
  int get generation;
  Framebuffer get framebuffer;
  BackendDiagnostic? present({Rect? damage});
}

/// A tightly packed BGRA framebuffer uploaded to one X11 window.
///
/// One instance belongs to exactly one window size and generation. A resize
/// replaces it instead of mutating it, so a frame holding the previous object
/// can be rejected by identity and [generation] before touching freed memory.
final class X11PutImageSurface with DisposableMixin implements X11CpuSurface {
  X11PutImageSurface._({
    required X11CpuClient client,
    required X11CpuBuffer buffer,
    required this.xcbWindow,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.scale,
    required this.generation,
  })  : _client = client,
        _buffer = buffer;

  /// Allocates a surface or throws without leaking a partially accepted
  /// buffer. Presentation capability is checked before allocation.
  static X11PutImageSurface create({
    required X11CpuClient client,
    required int xcbWindow,
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
    required int generation,
  }) {
    if (!client.supportsBgraPutImage) {
      throw UnsupportedCapabilityError(
        backendName: 'x11',
        capability: Capability.cpuPresentation,
        detail: 'the X11 visual does not accept BGRA PutImage buffers',
      );
    }
    if (xcbWindow == 0) {
      throw ArgumentError.value(xcbWindow, 'xcbWindow', 'must not be XCB_NONE');
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
    if (generation < 0) {
      throw ArgumentError.value(
          generation, 'generation', 'must be non-negative');
    }

    final buffer = client.createCpuBuffer(
      xcbWindow: xcbWindow,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    try {
      final framebuffer = buffer.framebuffer;
      if (framebuffer.width != pixelWidth ||
          framebuffer.height != pixelHeight) {
        throw StateError(
          'X11 CPU buffer geometry is ${framebuffer.width}x'
          '${framebuffer.height}; expected ${pixelWidth}x$pixelHeight',
        );
      }
      if (framebuffer.format != PixelFormat.bgra8888Premultiplied) {
        throw StateError(
          'X11 PutImage needs bgra8888Premultiplied; '
          'got ${framebuffer.format.name}',
        );
      }
      return X11PutImageSurface._(
        client: client,
        buffer: buffer,
        xcbWindow: xcbWindow,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        generation: generation,
      );
    } on Object {
      client.destroyCpuBuffer(buffer);
      rethrow;
    }
  }

  final X11CpuClient _client;
  final X11CpuBuffer _buffer;

  @override
  String get kind => 'x11-put-image';

  final int xcbWindow;

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  /// The window generation for which this allocation was created.
  @override
  final int generation;

  /// The client's native memory, wrapped without a per-frame copy.
  ///
  /// Valid only while this surface is live. Code must not retain the returned
  /// pixel list across a window generation change; `X11CpuPresenter` enforces
  /// that rule by revalidating surface identity and [generation] before every
  /// upload.
  @override
  Framebuffer get framebuffer => _buffer.framebuffer;

  /// Uploads the full buffer, or the outward-rounded intersection of [damage]
  /// with this surface.
  ///
  /// [damage] is in logical client coordinates. Returning null for empty or
  /// fully clipped damage makes a no-op a successful presentation, matching
  /// the Win32 DIB surface contract.
  @override
  BackendDiagnostic? present({Rect? damage}) {
    throwIfDisposed();
    final region = damage == null ? _fullDamage : _deviceDamage(damage);
    if (region == null) return null;
    if (!_client.supportsBgraPutImage) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'X11 BGRA PutImage presentation became unavailable',
      );
    }
    try {
      return _client.presentCpuBuffer(
        xcbWindow: xcbWindow,
        buffer: _buffer,
        damage: region,
      );
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'X11 PutImage presentation threw',
        detail: '$error',
      );
    }
  }

  X11CpuDamage get _fullDamage => X11CpuDamage(
        x: 0,
        y: 0,
        width: pixelWidth,
        height: pixelHeight,
      );

  X11CpuDamage? _deviceDamage(Rect logical) {
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
    return X11CpuDamage(
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
  void onDispose() => _client.destroyCpuBuffer(_buffer);

  @override
  String toString() => 'X11PutImageSurface('
      '${pixelWidth}x$pixelHeight @ $scale, '
      'xid: 0x${xcbWindow.toRadixString(16)}, generation: $generation)';
}
