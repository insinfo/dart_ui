/// Presentation pacing for the Win32 GDI path.
///
/// §68.3 of the roadmap named this file as the place where `PresentMode.fifo`
/// and `PresentMode.immediate` were "real on the Win32 CPU (GDI) path". The
/// file did not exist, and neither did any other implementation of
/// [PresentPacer] outside `UnpacedPresentation` in the contract itself - so
/// the mode a caller asked for went nowhere at all, which is the failure
/// `present_mode.dart` opens by describing. This is the implementation the
/// text was written against.
///
/// ## What a GDI window can and cannot promise
///
/// A `BitBlt` from a DIB section into a window's device context is not a swap
/// chain. There is no back buffer the window system hands out and no vertical
/// blank the call itself waits for. Under the Desktop Window Manager - on by
/// default since Windows 8 and not switchable off since - the *compositor*
/// takes what the window holds and shows it tear-free at its own cadence, so:
///
///   * [PresentMode.fifo] is honoured as "block until the compositor's next
///     present", which is exactly `DwmFlush`. The blit itself never tears
///     under the DWM; what the wait adds is the *throttle*, without which the
///     producer runs as fast as the CPU allows and every frame but the last
///     of each compositor interval is composited over and discarded.
///   * [PresentMode.immediate] is honoured as "do not block". The picture
///     still does not tear, because the compositor will not show a half-blitted
///     window, so this is the one mode where the honest answer is *better*
///     than the mode's own promise. That is reported and not silently
///     upgraded: [PresentMode.immediate] promises "as soon as it is ready",
///     which this delivers.
///   * [PresentMode.mailbox] is **refused by name**. Mailbox means a queue of
///     depth one that a newer frame replaces, and that is a property of a swap
///     chain's buffer rotation. GDI has no queue here to replace anything in:
///     there is one DIB, the blit overwrites it, and the compositor samples
///     whatever is there. The nearest thing - "do not block, the compositor
///     drops what it did not use" - is already what [PresentMode.immediate]
///     does on this path, so answering mailbox with it would be the silent
///     substitution the contract exists to forbid.
///
/// ## DWM off, and why that is a refusal too
///
/// `DwmIsCompositionEnabled` can report false: a remote desktop session, a
/// machine with the compositor disabled by policy. There is then no
/// compositor present to wait for, `DwmFlush` returns immediately or fails,
/// and nothing about the path is tear-free. [supportedPresentModes] drops
/// [PresentMode.fifo] in that case rather than accepting a request it would
/// answer with a call that does nothing - a refusal naming the compositor is
/// information; a `DwmFlush` that returns instantly is not.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../rendering/present_mode.dart';

/// The two `dwmapi.dll` entry points this path needs.
///
/// Loaded lazily and tolerantly: `dwmapi.dll` is present on every Windows this
/// framework targets, but a stripped container image is not a reason to throw
/// from a constructor. A failure to load leaves [isAvailable] false, and every
/// mode but [PresentMode.immediate] is then refused with the load error as the
/// reason.
final class DwmApi {
  DwmApi._(this._flush, this._isCompositionEnabled, this.loadError);

  /// Opens `dwmapi.dll`, or records why it could not be opened.
  factory DwmApi.open({
    DynamicLibrary Function(String name) open = DynamicLibrary.open,
  }) {
    try {
      final DynamicLibrary library = open('dwmapi.dll');
      return DwmApi._(
        library.lookupFunction<Int32 Function(), int Function()>('DwmFlush'),
        library.lookupFunction<Int32 Function(Pointer<Int32>),
            int Function(Pointer<Int32>)>('DwmIsCompositionEnabled'),
        null,
      );
    } on Object catch (error) {
      return DwmApi._(null, null, '$error');
    }
  }

  final int Function()? _flush;
  final int Function(Pointer<Int32>)? _isCompositionEnabled;

  /// Null when the library loaded; the reason it did not otherwise.
  final String? loadError;

  bool get isAvailable => _flush != null;

  /// Whether the desktop compositor is running.
  ///
  /// False - not an error - when the call is missing or fails, because every
  /// caller here treats "no compositor" and "cannot ask about the compositor"
  /// the same way: there is nothing to synchronise with either way.
  bool get isCompositionEnabled {
    final int Function(Pointer<Int32>)? query = _isCompositionEnabled;
    if (query == null) return false;
    // This repository's own allocator, never `package:ffi`: the framework has
    // no dependencies and `calloc` would be one.
    final NativeAllocator? allocator = NativeAllocator.tryBind();
    if (allocator == null) return false;
    final Pointer<Int32> slot = allocator.allocate<Int32>(sizeOf<Int32>());
    try {
      slot.value = 0;
      // S_OK is 0. Any failure HRESULT leaves the answer unusable.
      if (query(slot) != 0) return false;
      return slot.value != 0;
    } on Object {
      return false;
    } finally {
      allocator.release(slot);
    }
  }

  /// Blocks until the compositor's next present. Returns whether it waited.
  bool flush() {
    final int Function()? flushCall = _flush;
    if (flushCall == null) return false;
    try {
      return flushCall() == 0;
    } on Object {
      return false;
    }
  }
}

/// [PresentPacer] for a window presented with `BitBlt` under the DWM.
///
/// Constructed with the surface it paces named, so a refusal says *which*
/// window could not do what was asked rather than only that something could
/// not - the same reason [UnpacedPresentation] takes a description.
final class GdiPresentPacer implements PresentPacer {
  GdiPresentPacer({
    DwmApi? dwm,
    this.surfaceDescription = 'a GDI window',
  }) : _dwm = dwm ?? DwmApi.open();

  final DwmApi _dwm;
  final String surfaceDescription;

  /// [PresentMode.immediate], because that is what the GDI path *does* before
  /// anybody asks it for anything: `BitBlt` returns as soon as the bits are
  /// copied and nothing throttles the producer.
  ///
  /// This is not a default in the sense of a preference. `PresentModeOutcome`
  /// reports `applied` as "what remains in force", so a pacer whose starting
  /// value did not match the behaviour would make its own first refusal a lie
  /// - and wiring it into a presenter would silently *change* how every
  /// existing window presents, which is not what implementing a contract is
  /// allowed to do. An owner that wants the compositor's cadence asks for
  /// [PresentMode.fifo] and finds out whether it got it.
  PresentMode _mode = PresentMode.immediate;

  /// Whether the compositor was running when this pacer was asked.
  ///
  /// Queried on each call rather than cached: a remote desktop session can
  /// start and end while a process runs, and a cached "yes" would leave the
  /// loop waiting on a `DwmFlush` that no longer waits.
  bool get isComposited => _dwm.isCompositionEnabled;

  @override
  Set<PresentMode> get supportedPresentModes => <PresentMode>{
        PresentMode.immediate,
        if (isComposited) PresentMode.fifo,
      };

  @override
  PresentMode get presentMode => _mode;

  @override
  PresentModeOutcome requestPresentMode(PresentMode mode) {
    switch (mode) {
      case PresentMode.immediate:
        _mode = PresentMode.immediate;
        return PresentModeOutcome.honoured(
          PresentMode.immediate,
          detail: 'the blit is not throttled; under the desktop compositor it '
              'is still tear-free, which is more than immediate promises',
        );
      case PresentMode.fifo:
        if (!_dwm.isAvailable) {
          return PresentModeOutcome.refused(
            mode,
            applied: _mode,
            reason: 'dwmapi.dll could not be loaded, so there is no '
                'compositor clock to wait on',
            detail: _dwm.loadError,
          );
        }
        if (!isComposited) {
          return PresentModeOutcome.refused(
            mode,
            applied: _mode,
            reason: 'DwmIsCompositionEnabled reports the desktop compositor '
                'is off on $surfaceDescription, so DwmFlush would return '
                'without waiting for anything',
          );
        }
        _mode = PresentMode.fifo;
        return PresentModeOutcome.honoured(
          PresentMode.fifo,
          detail: 'paced by DwmFlush, the desktop compositor\'s present',
        );
      case PresentMode.mailbox:
        return PresentModeOutcome.refused(
          mode,
          applied: _mode,
          reason: 'mailbox is a swap chain replacing a queued-but-undisplayed '
              'buffer, and $surfaceDescription has no such queue - one DIB is '
              'blitted over in place',
          detail: 'immediate is the closest this path can do and is offered '
              'under its own name rather than substituted for this one',
        );
    }
  }

  @override
  bool awaitVerticalBlank() {
    if (_mode != PresentMode.fifo) return false;
    return _dwm.flush();
  }

  @override
  String toString() => 'GdiPresentPacer(${_mode.name}, '
      'composited: $isComposited)';
}
