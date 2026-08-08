/// Double buffering over the host's `SURFACES` / `PRESENT_SLOT` commands.
///
/// Why this exists at all is a measurement, not a preference. With a single
/// shared surface the process goes on writing into pages the WindowServer may
/// be scanning out, and `doc/logs/PRESENT_PACING_2026-08-08.md` timed that
/// unsynchronised window at **3 339 us - 20% of a 60 Hz frame**. The probe
/// deliberately did not claim to have *seen* a tear; proving one from inside
/// the process is not possible. It measured how wide the window is, and 20% of
/// a frame is too wide to leave open.
///
/// The fix is arithmetic rather than timing: the client writes the slot it did
/// **not** just present. This class is where that arithmetic lives, and it
/// throws rather than trusting callers to remember - the whole point of
/// putting it in code is that hoping does not scale past the first refactor.
library;

import 'dart:typed_data';

import '../../rendering/framebuffer.dart';
import '../../rendering/renderer.dart';
import 'io_surface.dart';

/// Raised when a caller tries to write the surface the compositor was just
/// handed. Not a `StateError`: this one names an invariant with a measured
/// justification, and a reviewer should be able to grep for it.
final class MacosPresentInvariantError extends Error {
  MacosPresentInvariantError(this.message);

  final String message;

  @override
  String toString() => 'MacosPresentInvariantError: $message';
}

/// What a renderer is told about this window's presentable surface.
///
/// One descriptor, not one per slot: which slot a frame lands in is this
/// backend's bookkeeping, and a renderer that could see the slots would sooner
/// or later pick one.
final class MacosSurfaceDescriptor implements NativeSurfaceDescriptor {
  const MacosSurfaceDescriptor({
    required this.pixelWidth,
    required this.pixelHeight,
    required this.scale,
    required this.bytesPerRow,
    required this.slotCount,
  });

  @override
  String get kind => 'iosurface';

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  /// The surface's own stride. Never `pixelWidth * 4`: IOSurface rounds up.
  final int bytesPerRow;

  /// How many buffers rotate behind this descriptor. Diagnostics only.
  final int slotCount;

  @override
  String toString() => 'MacosSurfaceDescriptor(${pixelWidth}x$pixelHeight '
      '@${scale}x, stride $bytesPerRow, $slotCount slots)';
}

/// A rotating set of `IOSurface`s, one of which the host is showing.
///
/// Invariants, all enforced rather than documented:
///
///   * [backSlot] is never [presentedSlot];
///   * only [backSlot] can be written;
///   * [markPresented] accepts only the slot that was actually written.
///
/// [presentedSlot] advances when the present is *sent*, not when the host acks
/// it. That is the moment the host swaps `layer.contents`, so it is the moment
/// the client must stop writing those pages. Waiting for the ack would add the
/// measured 188 us present round trip to every frame for no additional safety.
final class MacosSurfacePool {
  MacosSurfacePool(List<MacosPoolSurface> surfaces)
      : _surfaces = List<MacosPoolSurface>.unmodifiable(surfaces) {
    if (_surfaces.length < 2) {
      throw MacosPresentInvariantError(
        'a pool needs at least two surfaces; got ${_surfaces.length}. '
        'One surface is the 3 339 us tear window measured in '
        'PRESENT_PACING_2026-08-08.',
      );
    }
    for (final surface in _surfaces) {
      if (surface.width != _surfaces.first.width ||
          surface.height != _surfaces.first.height ||
          surface.bytesPerRow != _surfaces.first.bytesPerRow) {
        throw MacosPresentInvariantError(
          'pool surfaces must share geometry; a rotation that changes stride '
          'would silently reinterpret every row',
        );
      }
    }
    _contentSequence = List<int>.filled(_surfaces.length, -1);
  }

  final List<MacosPoolSurface> _surfaces;

  /// Frame number last written into each slot, -1 when never written. Lets a
  /// caller ask whether the buffer it is about to draw into still holds the
  /// frame before last, which with two buffers it usually does.
  late final List<int> _contentSequence;

  int _backSlot = 0;
  int _presentedSlot = -1;
  int _frameCounter = 0;
  bool _disposed = false;

  int get slotCount => _surfaces.length;

  /// The slot the client may write. Never equal to [presentedSlot].
  int get backSlot => _backSlot;

  /// The slot the host was last asked to show, or -1 before the first present.
  int get presentedSlot => _presentedSlot;

  /// Frames written so far. Doubles as the `PRESENT_SLOT` sequence number, so
  /// a `PRESENT_OK <n>` in a log points at exactly one frame.
  int get frameCounter => _frameCounter;

  bool get isDisposed => _disposed;

  /// Every surface, in slot order. For attaching the pool to a host.
  List<MacosPoolSurface> get surfaces => _surfaces;

  /// Whether the back buffer holds an older frame rather than a blank one.
  ///
  /// True means a caller doing damage-limited drawing must either redraw the
  /// whole surface or copy the missing region: with two buffers the back
  /// buffer's content is two frames old, which is the classic double-buffer
  /// trap and the reason this is exposed instead of assumed.
  bool get backBufferHoldsOlderFrame => _contentSequence[_backSlot] >= 0;

  int contentSequenceOf(int slot) => _contentSequence[slot];

  MacosSurfaceDescriptor describe(double scale) => MacosSurfaceDescriptor(
        pixelWidth: _surfaces.first.width,
        pixelHeight: _surfaces.first.height,
        scale: scale,
        bytesPerRow: _surfaces.first.bytesPerRow,
        slotCount: _surfaces.length,
      );

  /// Runs [write] against the back buffer's pixels, wrapped as a
  /// [Framebuffer] so the CPU rasteriser and the golden tests are the same
  /// code path they are everywhere else.
  ///
  /// The framebuffer is built per call and must not be cached: `IOSurfaceLock`
  /// makes no promise about returning the same base address twice, which is
  /// the warning `Frame.framebuffer` in `renderer.dart` carries for the same
  /// reason.
  void withBackBuffer(void Function(Framebuffer buffer) write) {
    _checkAlive();
    if (_backSlot == _presentedSlot) {
      throw MacosPresentInvariantError(
        'slot $_backSlot was just presented; writing it would race the '
        'compositor',
      );
    }
    final surface = _surfaces[_backSlot];
    surface.withPixels((Uint8List pixels) {
      write(
        Framebuffer.wrap(
          pixels,
          width: surface.width,
          height: surface.height,
          bytesPerRow: surface.bytesPerRow,
        ),
      );
    });
  }

  /// Copies [source] into the back buffer, row by row so a mismatched stride
  /// cannot shear the image.
  ///
  /// Returns false when the geometry does not match, rather than throwing: a
  /// frame that arrives one resize late is normal, and the caller drops it by
  /// generation anyway.
  bool copyIntoBackBuffer(Framebuffer source) {
    _checkAlive();
    final surface = _surfaces[_backSlot];
    if (source.width != surface.width || source.height != surface.height) {
      return false;
    }
    if (source.format != PixelFormat.bgra8888Premultiplied) return false;
    withBackBuffer((destination) {
      if (destination.bytesPerRow == source.bytesPerRow) {
        destination.pixels.setRange(
          0,
          source.bytesPerRow * source.height,
          source.pixels,
        );
        return;
      }
      final rowBytes = source.width * 4;
      for (var y = 0; y < source.height; y++) {
        destination.pixels.setRange(
          y * destination.bytesPerRow,
          y * destination.bytesPerRow + rowBytes,
          source.pixels,
          y * source.bytesPerRow,
        );
      }
    });
    return true;
  }

  /// Records that [slot] has been handed to the host and rotates.
  ///
  /// Returns the sequence number the present should carry. Throws when [slot]
  /// is not the slot that was being written, because presenting anything else
  /// means the bookkeeping and the pixels have already diverged.
  int markPresented(int slot) {
    _checkAlive();
    if (slot != _backSlot) {
      throw MacosPresentInvariantError(
        'presented slot $slot but the back buffer is $_backSlot',
      );
    }
    final sequence = ++_frameCounter;
    _contentSequence[slot] = sequence;
    _presentedSlot = slot;
    _backSlot = (slot + 1) % _surfaces.length;
    return sequence;
  }

  /// Forgets which slot was presented, without touching the pixels.
  ///
  /// Used after a host crash: the surfaces survived (measured - the kernel
  /// refcounts them and Dart still holds a reference), but the *new* host has
  /// shown nothing yet, so the previous presented slot is no longer a page
  /// anybody is scanning out.
  void resetPresentation() {
    _checkAlive();
    _presentedSlot = -1;
  }

  /// Releases the surfaces in reverse acquisition order.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (var index = _surfaces.length - 1; index >= 0; index--) {
      _surfaces[index].dispose();
    }
  }

  void _checkAlive() {
    if (_disposed) {
      throw MacosPresentInvariantError('surface pool used after dispose');
    }
  }
}
