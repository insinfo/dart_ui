/// Presentation policy: how a finished frame reaches the display.
///
/// `renderer.dart` already says what happened to a frame ([PresentResult]).
/// This file says what the application *asked for* before the frame was ever
/// drawn, which is a different question and the one a real-time application
/// actually has an opinion about.
///
/// ## Three modes, and why exactly these three
///
/// The vocabulary is Vulkan's, because Vulkan is the only one of the four
/// APIs this framework targets that named the choice honestly, and because
/// every other API's options map onto it without loss:
///
///   * [PresentMode.fifo] - the frame waits for the vertical blank and every
///     frame is shown. No tearing, and the loop is throttled to the refresh
///     rate. This is `wglSwapIntervalEXT(1)`, `DXGI` `SyncInterval: 1`,
///     `VK_PRESENT_MODE_FIFO_KHR`, and `glXSwapIntervalEXT(1)`.
///   * [PresentMode.mailbox] - the frame waits for the vertical blank to be
///     *displayed*, but the application does not wait to produce the next one:
///     a newer frame replaces an undisplayed one in a queue of depth one. No
///     tearing, latency bounded by one refresh instead of by one frame time.
///     This is `VK_PRESENT_MODE_MAILBOX_KHR` and `DXGI_SWAP_EFFECT_FLIP_DISCARD`
///     with a waitable object; it is the mode a game wants and the mode WGL
///     and GDI cannot express at all.
///   * [PresentMode.immediate] - the frame is scanned out the moment it is
///     ready, tearing included. `wglSwapIntervalEXT(0)`, `SyncInterval: 0`,
///     `VK_PRESENT_MODE_IMMEDIATE_KHR`. The right answer for a benchmark and
///     for a latency-critical input test, and the wrong one for anything a
///     user looks at for an hour.
///
/// ## The rule this file exists to enforce
///
/// **A backend that cannot do what was asked says so, by name.** It does not
/// substitute the nearest thing it can do and report success. That is stated
/// as a rule rather than left to taste because the failure it prevents is
/// invisible: an application that asked for [PresentMode.mailbox], silently
/// got [PresentMode.fifo] and then measured its own input latency will
/// conclude the *framework* is slow, and no log anywhere will contradict it.
/// [PresentModeOutcome.accepted] is therefore false whenever the applied mode
/// is not the requested one, and the diagnostic names both.
///
/// ## What is implemented and what is a seam
///
/// This section used to describe two implementations in
/// `win32_present_mode.dart`. **That file did not exist**, and neither did any
/// other implementation of [PresentPacer]: the only class in this repository
/// that implemented it was [UnpacedPresentation], below, which exists for
/// surfaces that cannot pace at all. Every application asking for a mode was
/// therefore asking nobody. The two below are the real ones.
///
/// Implemented in this repository today:
///
///   * **Every GL window** - `GlSwapChainPresentPacer`, in
///     `rendering/gpu/gl/gl_present_pacer.dart`, written against
///     `GlSwapChain.setSwapInterval` rather than against Win32. That seam is
///     already `wglSwapIntervalEXT` on Win32, `glXSwapIntervalEXT` on X11 and
///     `eglSwapInterval` on EGL, so one implementation paces all three.
///     [PresentMode.fifo] and [PresentMode.immediate] are real;
///     [PresentMode.mailbox] is refused by name, because a swap *interval* is
///     a count of vertical blanks and no value of it means "replace the queued
///     frame". `GlWindowTarget` implements [PresentPacer] by delegating to it,
///     so an owner holding a bare `RenderTarget` type-tests and gets it.
///   * **The Win32 CPU (GDI) path** - `GdiPresentPacer`, in
///     `backends/win32/win32_present_mode.dart`, wired into
///     `Win32CpuPresenter`. Under the desktop compositor a `BitBlt` is already
///     tear-free but unthrottled, so fifo is "block until the compositor's
///     next present" (`DwmFlush`) and immediate is "do not block". Mailbox is
///     refused by name: one DIB blitted over in place is not a queue anything
///     can replace a frame in. It starts in [PresentMode.immediate] because
///     that is what the path *did* before it had a pacer, and wiring a
///     contract in must not change behaviour nobody asked to change.
///
/// Measured in a real window on Intel UHD Graphics, 60 Hz panel, by
/// `tool/present_mode_smoke.dart`: fifo 60.0 fps, immediate 1564.3 fps, and
/// `DwmFlush` blocking 14.8 ms - one refresh interval. A headless run cannot
/// produce any of those three numbers, which is why the tool exists next to
/// `test/rendering/present_mode_test.dart` rather than instead of it.
///
/// Contract only, seam left open deliberately because other work is live in
/// those directories:
///
///   * **D3D12** - `IDXGISwapChain3::Present1(syncInterval, flags)`. fifo is
///     `syncInterval: 1`; immediate is `syncInterval: 0` plus
///     `DXGI_PRESENT_ALLOW_TEARING`, which additionally requires the swap
///     chain to have been created with `DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING`
///     and the factory to have reported `AllowTearing` support - a backend
///     that cannot set the flag must refuse immediate rather than fall back
///     to 0 without it, which silently becomes fifo. mailbox is
///     `DXGI_SWAP_EFFECT_FLIP_DISCARD` with `BufferCount >= 3` and the
///     frame-latency waitable object. **This is the one backend here where
///     mailbox is implementable**, and implementing it means changing swap
///     chain *creation*, not the present call.
///   * **Vulkan** - `vkGetPhysicalDeviceSurfacePresentModesKHR` enumerates
///     what the surface really supports, and only `VK_PRESENT_MODE_FIFO_KHR`
///     is guaranteed. [PresentPacer.supportedPresentModes] is meant to be
///     filled from that enumeration rather than from a static table, which is
///     the entire reason it is a `Set` on the instance and not a constant on
///     the class. Note that `vulkan_swapchain.dart` *already* selects
///     `VK_PRESENT_MODE_MAILBOX_KHR` when `VulkanPresentPolicy.lowLatency`
///     asks and the surface reports it - so mailbox is real on that backend
///     and simply not yet reachable through this vocabulary.
///
/// Both seams are a [PresentPacer] implementation next to the backend and
/// nothing else: no core file needs to change to add them.
library;

import '../foundation/diagnostics.dart';

/// How a finished frame is handed to the display.
///
/// See the library documentation for the mapping onto each platform API, and
/// for why a backend must refuse rather than substitute.
enum PresentMode {
  /// Wait for the vertical blank; show every frame. No tearing.
  fifo,

  /// Replace the queued-but-undisplayed frame with a newer one. No tearing,
  /// and the producer is never blocked by the display.
  mailbox,

  /// Scan out as soon as the frame is ready. Tears.
  immediate;

  /// Whether this mode promises the frame will not tear.
  bool get isTearFree => this != immediate;

  /// Whether this mode throttles the *producer* to the refresh rate.
  ///
  /// The distinction that matters for a loop: under [fifo] the loop's own
  /// pacing is redundant because the present call blocks, while under
  /// [mailbox] and [immediate] nothing throttles the loop and it will spin at
  /// whatever rate the CPU allows unless something else paces it.
  bool get throttlesProducer => this == fifo;
}

/// What a backend did with a [PresentMode] request.
///
/// Never a bare bool, for the reason `BackendProbeResult` is never a bare
/// bool: "no" without a reason sends the reader to the wrong layer.
final class PresentModeOutcome {
  const PresentModeOutcome({
    required this.requested,
    required this.applied,
    required this.accepted,
    this.diagnostic,
  });

  /// The request was honoured exactly.
  PresentModeOutcome.honoured(PresentMode mode, {String? detail})
      : this(
          requested: mode,
          applied: mode,
          accepted: true,
          diagnostic: detail == null
              ? null
              : BackendDiagnostic(
                  kind: DiagnosticKind.note,
                  message: 'present mode applied',
                  detail: detail,
                ),
        );

  /// The request was refused. [applied] is what remains in force - which is
  /// the *previous* mode, not a silent downgrade the caller never asked for.
  ///
  /// [reason] must name the missing thing: the extension, the API call, the
  /// device capability. "Not supported" is not a reason.
  PresentModeOutcome.refused(
    PresentMode mode, {
    required PresentMode applied,
    required String reason,
    String? detail,
  }) : this(
          requested: mode,
          applied: applied,
          accepted: false,
          diagnostic: BackendDiagnostic(
            kind: DiagnosticKind.unsupportedPlatform,
            message: 'present mode ${mode.name} refused: $reason',
            detail: detail ?? 'still presenting in ${applied.name}',
          ),
        );

  final PresentMode requested;

  /// The mode actually in force after the request.
  final PresentMode applied;

  /// Whether [applied] equals [requested].
  final bool accepted;

  /// The evidence. Non-null on every refusal; optional on success.
  final BackendDiagnostic? diagnostic;

  @override
  String toString() => accepted
      ? 'PresentModeOutcome(${applied.name})'
      : 'PresentModeOutcome(${requested.name} refused -> ${applied.name}: '
          '${diagnostic?.message})';
}

/// The seam between a presentation policy and one platform's swap API.
///
/// Deliberately not part of [SurfacePresenter] and not part of `NativeWindow`.
/// A presenter that cannot pace says so by not implementing this, exactly as
/// `SynchronousSurfacePresenter` and `LiveResizeWindow` do elsewhere in this
/// repository - adding a method to a contract every backend implements, for a
/// capability only some of them have, forces five implementations to write a
/// stub that lies.
///
/// Tested for with a pattern:
///
/// ```dart
/// if (presenter case final PresentPacer pacer) {
///   final outcome = pacer.requestPresentMode(PresentMode.immediate);
///   if (!outcome.accepted) report(outcome.diagnostic!);
/// }
/// ```
abstract interface class PresentPacer {
  /// Every mode this pacer can actually deliver, on this machine, right now.
  ///
  /// An instance property rather than a class constant because the honest
  /// answer depends on what the driver reported: the same WGL code path
  /// supports `immediate` on a local GPU and neither mode over a remote
  /// desktop session, and a static table cannot know which one it is on.
  Set<PresentMode> get supportedPresentModes;

  /// The mode currently in force.
  PresentMode get presentMode;

  /// Asks for [mode]. Never throws; a refusal is a value.
  PresentModeOutcome requestPresentMode(PresentMode mode);

  /// Blocks until the display's next vertical blank, when this pacer both
  /// needs to and can.
  ///
  /// Returns whether it actually waited. False is a legitimate and common
  /// answer, in three different situations that a caller must not distinguish
  /// between:
  ///
  ///   * the mode is [PresentMode.immediate], so waiting would contradict it;
  ///   * the swap call itself already blocks - every GL and Vulkan fifo path -
  ///     so waiting here would halve the frame rate rather than pace it;
  ///   * the platform has no way to wait, which is what the desktop
  ///     compositor being off looks like on Windows.
  ///
  /// A caller pacing a loop must therefore not treat false as an error and
  /// must not spin on it. It means "you are still responsible for your own
  /// timing", which is what the frame loop's own scheduling is for.
  bool awaitVerticalBlank();
}

/// A pacer for a path that cannot pace at all.
///
/// Used by presenters that write into memory - the headless framebuffer, a
/// golden test - where "present" is a copy and there is no display to
/// synchronise with. It accepts [PresentMode.immediate], because that is
/// literally what it does, and refuses the other two by name rather than
/// pretending a `memcpy` is tear-free with respect to a scanout that does not
/// exist.
final class UnpacedPresentation implements PresentPacer {
  UnpacedPresentation({this.surfaceDescription = 'an offscreen surface'});

  /// Named in the refusal, so the reader learns *which* surface could not
  /// pace rather than only that something could not.
  final String surfaceDescription;

  @override
  Set<PresentMode> get supportedPresentModes =>
      const <PresentMode>{PresentMode.immediate};

  @override
  PresentMode get presentMode => PresentMode.immediate;

  @override
  PresentModeOutcome requestPresentMode(PresentMode mode) {
    if (mode == PresentMode.immediate) {
      return PresentModeOutcome.honoured(PresentMode.immediate);
    }
    return PresentModeOutcome.refused(
      mode,
      applied: PresentMode.immediate,
      reason: '$surfaceDescription has no scanout to synchronise with, so '
          'there is no vertical blank to wait for',
    );
  }

  @override
  bool awaitVerticalBlank() => false;

  @override
  String toString() => 'UnpacedPresentation($surfaceDescription)';
}
