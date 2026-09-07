/// What a presenting Metal target needs to know about a window, and no more.
///
/// The counterpart of `d3d11_surface_descriptor.dart`, and deliberately the
/// same shape for the same reason: `test/architecture/layering_test.dart`
/// fails the build if any file under `lib/src` outside `backends/` so much as
/// names a platform type. `IOSurface` is such a type. So the window-system
/// half is reduced to the interface below, implemented where naming it is
/// legal - `lib/src/backends/macos/surface_pool.dart` - and the Metal target
/// contains no platform branch at all.
///
/// ## Why this is an IOSurface and not a drawable
///
/// ADR 0005 decided it and the evidence has since caught up. On the only macOS
/// backend that creates a window in `lib/` - `appkitNativeHost` - the
/// `NSWindow`, its view and therefore any `CAMetalLayer` live in **another
/// process**, because ADR 0001 put them there. There is no layer on this side
/// of the boundary to acquire a drawable from. What crosses instead is an
/// `IOSurface`, which the Dart process owns and the host merely shows.
///
/// So "present" here is not `presentDrawable:`. It is: draw into the pages the
/// host is going to scan out, wait for the GPU to actually finish writing
/// them, then send `PRESENT_SLOT`. The middle step is the one that has no
/// analogue in the drawable path and is the reason
/// [MetalPresentSurface.presentBackBuffer] exists as a separate call rather
/// than being folded into the draw.
///
/// Measured on `macos-14` in run
/// [`34165428755`](https://github.com/insinfo/dart_ui/actions/runs/34165428755):
/// `newTextureWithDescriptor:iosurface:plane:` returns a texture under
/// `MTLStorageModeShared`, a completion handler fires at 6.7 ms, and the bytes
/// the GPU wrote read back through `IOSurfaceLock` as `B=128 G=64 R=32 A=255`
/// for a clear of `0xFF204080` - the right pixels, in the right order.
///
/// ## Nothing here is Metal-specific except its name
///
/// The interface would serve any API that can wrap an `IOSurface`. It lives in
/// the Metal directory because Metal is the only renderer that does, and
/// moving it up a layer before a second caller exists would be inventing a
/// generalisation instead of finding one.
library;

import 'dart:ffi';

import '../../renderer.dart';

/// The window-system half of a presenting Metal target.
///
/// The renderer draws; something else owns the buffers and shows them. On
/// macOS that something is `MacosSurfacePool` and the host process behind it.
///
/// Every method reports failure by returning something, never by throwing. A
/// present that throws unwinds through the frame loop; a present that reports
/// becomes a [PresentResult] with a named diagnostic, which is what section
/// 6.6 asks for.
abstract interface class MetalPresentSurface
    implements NativeSurfaceDescriptor {
  /// How many surfaces rotate behind this descriptor.
  ///
  /// At least two, enforced by the pool: one buffer is the 3 339 us tear
  /// window `doc/logs/PRESENT_PACING_2026-08-08.md` measured.
  int get slotCount;

  /// The slot the renderer may draw into now. Never the presented one.
  ///
  /// A live getter and never a value the target may cache across frames, for
  /// the same reason `D3d11SwapChain.backBufferView` is: the rotation happens
  /// underneath, and a target drawing into the slot it remembers would be
  /// writing into the surface the host is showing.
  int get backSlot;

  /// The surface's own stride, which is **not** `pixelWidth * 4`.
  ///
  /// IOSurface rounds the row up for alignment. Reported because a caller that
  /// assumed the product would shear every frame; the probe measured 512 for a
  /// 100-pixel-wide surface where the product is 400.
  int get bytesPerRow;

  /// The `IOSurfaceRef` behind [slot], or `nullptr` when there is none.
  ///
  /// A raw pointer because that is exactly what
  /// `-[MTLDevice newTextureWithDescriptor:iosurface:plane:]` takes, and an
  /// integer or an opaque box would only be unwrapped again at the call. It
  /// confers **no ownership**: the pool owns the surface, Metal retains it for
  /// as long as the texture lives, and the texture must therefore be released
  /// before the pool is torn down.
  ///
  /// `nullptr` is the honest answer for a slot backed by something that is not
  /// an `IOSurface` at all - a test double, for instance - and the target
  /// turns it into a named refusal rather than handing nil to Metal, which
  /// returns nil in turn and would surface three steps later as a pass that
  /// encodes nothing.
  Pointer<Void> surfaceRefForSlot(int slot);

  /// Whether this surface can still be presented to.
  ///
  /// False once the window is gone, or while the host is dead and recovery has
  /// not finished. Checked before a present so a dead window becomes a named
  /// failure instead of a write into pages nobody is showing.
  bool get isPresentable;

  /// The window's lifetime counter, as `lifecycle.dart` defines it.
  ///
  /// The window's own and not the target's, and that distinction is the whole
  /// point: a window resizes on the window system's schedule, so a target that
  /// counted only its own resizes would accept exactly the frames that are
  /// dangerous. A frame drawn before a resize must be dropped, not shown
  /// stretched.
  int get presentGeneration;

  /// Hands the back buffer to whatever shows it.
  ///
  /// **Must only be called once the GPU has finished writing it.** `commit`
  /// enqueues; it does not complete. Presenting between the two hands the host
  /// a half-written surface, and the artefact - tearing inside a single frame
  /// - is load-dependent and intermittent, which is the worst way for a bug to
  /// appear. `MetalWindowTarget` waits on `addCompletedHandler:` before
  /// calling this, which is the ordering ADR 0005 chose over
  /// `waitUntilCompleted` precisely so the CPU is not serialised against the
  /// GPU every frame.
  ///
  /// [generation] is the value the frame was begun with. A present whose
  /// generation no longer matches is dropped with [PresentStatus.stale], which
  /// is not an error: it is what a resize during a frame looks like.
  Future<PresentResult> presentBackBuffer({required int generation});
}
