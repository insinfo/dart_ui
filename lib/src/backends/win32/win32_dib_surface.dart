/// The CPU presentation path: a top-down 32-bit DIB section blitted to the
/// window, the arrangement proven in `poc/poc_13_native_dib_present`.
///
/// Why a DIB section and not `StretchDIBits` from a Dart list: a DIB section
/// is memory GDI already owns, so presenting it is one `BitBlt` with no copy.
/// The alternative copies the whole framebuffer into native memory on every
/// frame, and POC-13 measured exactly what that costs. The rasteriser writes
/// straight into the DIB's pixels through a [Framebuffer] that wraps them.
///
/// The pixels are BGRA in memory order, which is
/// [PixelFormat.bgra8888Premultiplied] - the format the framework already
/// committed to. GDI ignores the alpha byte for `BitBlt`, so a premultiplied
/// buffer presents correctly against an opaque window; per-pixel window
/// transparency needs `UpdateLayeredWindow` and is deferred.
library;

import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/renderer.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_coordinates.dart';
import 'win32_diagnostics.dart';
import 'win32_structs.dart';

/// CPU framebuffer and presentation seam consumed by `Win32CpuPresenter`.
///
/// [Win32DibSurface] is the production implementation. The interface keeps
/// resize, expose, stale-generation, and stride behaviour testable on CI
/// hosts that cannot load user32/gdi32.
abstract interface class Win32CpuSurface implements NativeSurfaceDescriptor {
  int get generation;
  Framebuffer get framebuffer;
  BackendDiagnostic? present({Rect? damage});
}

/// A CPU surface over one window's client area.
///
/// Lives exactly as long as one size: a resize disposes this and builds
/// another, which is why it carries the window [generation] that produced it.
/// A frame holding a stale surface can compare generations instead of
/// discovering the truth through a freed pointer.
final class Win32DibSurface with DisposableMixin implements Win32CpuSurface {
  Win32DibSurface._({
    required Win32Api api,
    required this.hwnd,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.scale,
    required this.generation,
    required int memoryDc,
    required int bitmap,
    required int previousBitmap,
    required Pointer<Uint8> pixels,
  })  : _api = api,
        _memoryDc = memoryDc,
        _bitmap = bitmap,
        _pixels = pixels {
    // Reverse order matters here and is not theoretical: deleting the bitmap
    // while it is still selected into the DC leaks it, and GDI reports nothing
    // when you do.
    _resources
      ..add(memoryDc, () => _api.deleteDC(memoryDc))
      ..add(bitmap, () => _api.deleteObject(bitmap))
      ..add(previousBitmap, () => _api.selectObject(memoryDc, previousBitmap));
    framebuffer = Framebuffer.wrap(
      pixels.asTypedList(pixelWidth * pixelHeight * 4),
      width: pixelWidth,
      height: pixelHeight,
      bytesPerRow: pixelWidth * 4,
    );
  }

  /// Builds a surface for a client area of [pixelWidth] x [pixelHeight].
  ///
  /// Throws [Win32Failure] naming the GDI call that failed. GDI does not set
  /// the thread's last error consistently, so the code is reported for what it
  /// is worth and the function name carries the weight.
  static Win32DibSurface create({
    required Win32Api api,
    required int hwnd,
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
    required int generation,
  }) {
    assert(pixelWidth > 0 && pixelHeight > 0);

    final memoryDc = api.createCompatibleDC(0);
    if (memoryDc == 0) {
      throw Win32Failure(
        win32CallFailed(
          'CreateCompatibleDC',
          api.getLastError(),
          kind: DiagnosticKind.surfaceCreationFailed,
          context: 'no memory DC for a ${pixelWidth}x$pixelHeight surface',
        ),
      );
    }

    final info = api.allocator<BitmapInfo>();
    final bits = api.allocator<Pointer<Void>>();
    try {
      info.ref.bmiHeader
        ..biSize = sizeOf<BitmapInfoHeader>()
        ..biWidth = pixelWidth
        // Negative: row 0 first in memory, matching every rasteriser loop.
        ..biHeight = -pixelHeight
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = biRgb
        ..biSizeImage = pixelWidth * pixelHeight * 4;

      final bitmap = api.createDIBSection(
        memoryDc,
        info,
        dibRgbColors,
        bits,
        0,
        0,
      );
      if (bitmap == 0 || bits.value == nullptr) {
        final error = api.getLastError();
        api.deleteDC(memoryDc);
        throw Win32Failure(
          win32CallFailed(
            'CreateDIBSection',
            error,
            kind: DiagnosticKind.surfaceCreationFailed,
            context: '${pixelWidth}x$pixelHeight, 32bpp',
          ),
        );
      }

      final previousBitmap = api.selectObject(memoryDc, bitmap);
      return Win32DibSurface._(
        api: api,
        hwnd: hwnd,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        generation: generation,
        memoryDc: memoryDc,
        bitmap: bitmap,
        previousBitmap: previousBitmap,
        pixels: bits.value.cast<Uint8>(),
      );
    } finally {
      api.allocator
        ..free(bits)
        ..free(info);
    }
  }

  final Win32Api _api;
  final DisposableBag _resources = DisposableBag();

  /// The window this surface presents to.
  final int hwnd;

  final int _memoryDc;
  final int _bitmap;
  final Pointer<Uint8> _pixels;

  @override
  String get kind => 'win32-dib';

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  /// The window generation this surface was created for.
  @override
  final int generation;

  /// The DIB's own memory, wrapped rather than copied.
  ///
  /// Valid only until [dispose]. After that the list points at memory GDI has
  /// freed, which is why the window drops its reference in the same statement
  /// that disposes the surface.
  @override
  late final Framebuffer framebuffer;

  /// Base address of the pixels, for a renderer that wants to hand them to
  /// something other than Dart code.
  int get pixelsAddress => _pixels.address;

  /// Rows are always `width * 4` here: a 32-bpp DIB is inherently DWORD
  /// aligned, so there is no padding to account for.
  int get bytesPerRow => pixelWidth * 4;

  /// The GDI memory DC the bitmap is selected into, for a caller that wants to
  /// blit into it with other GDI calls.
  int get memoryDc => _memoryDc;

  int get bitmap => _bitmap;

  /// Blits the surface (or just [damage]) to the window.
  ///
  /// Returns null on success, or the diagnostic for the call that failed.
  /// Presenting outside `WM_PAINT` is deliberate and legal: the renderer
  /// produces a frame when it has one, not when Windows asks, and `WM_PAINT`
  /// is treated as "the OS lost your pixels" rather than as the render trigger.
  @override
  BackendDiagnostic? present({Rect? damage}) {
    throwIfDisposed();
    var left = 0;
    var top = 0;
    var right = pixelWidth;
    var bottom = pixelHeight;
    if (damage != null) {
      final space = Win32CoordinateSpace(
        clientOriginX: 0,
        clientOriginY: 0,
        scale: scale,
      );
      final physical = space.logicalRectToPhysical(damage);
      left = physical.left.clamp(0, pixelWidth);
      top = physical.top.clamp(0, pixelHeight);
      right = physical.right.clamp(0, pixelWidth);
      bottom = physical.bottom.clamp(0, pixelHeight);
      if (right <= left || bottom <= top) return null;
    }

    final windowDc = _api.getDC(hwnd);
    if (windowDc == 0) {
      return win32CallFailed(
        'GetDC',
        _api.getLastError(),
        context: 'window 0x${hwnd.toRadixString(16)}',
      );
    }
    final blitted = _api.bitBlt(
      windowDc,
      left,
      top,
      right - left,
      bottom - top,
      _memoryDc,
      left,
      top,
      srccopy,
    );
    final error = blitted == 0 ? _api.getLastError() : 0;
    _api.releaseDC(hwnd, windowDc);
    if (blitted == 0) {
      return win32CallFailed(
        'BitBlt',
        error,
        context: '${right - left}x${bottom - top} at ($left, $top)',
      );
    }
    return null;
  }

  @override
  void onDispose() => _resources.dispose();

  @override
  String toString() => 'Win32DibSurface(${pixelWidth}x$pixelHeight @ $scale, '
      'generation: $generation)';
}
