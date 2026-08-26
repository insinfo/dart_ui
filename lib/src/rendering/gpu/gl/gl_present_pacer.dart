/// [PresentPacer] over a [GlSwapChain].
///
/// `present_mode.dart` described this as "WGL on Win32 - `wglSwapIntervalEXT`,
/// in `win32_present_mode.dart`". It is written here instead, and the move is
/// the point rather than a filing decision: swap-interval control is not a
/// Win32 concept. `GlSwapChain.setSwapInterval` is already implemented three
/// times - `wglSwapIntervalEXT` on Win32, `glXSwapIntervalEXT` on X11 and
/// `eglSwapInterval` on EGL - and all three answer the same two questions the
/// same way. A pacer written against the seam is one implementation for every
/// GL window this framework can open; a pacer written in the Win32 backend
/// would have needed copying twice and would have drifted.
///
/// ## The mapping, and the one mode that is refused
///
///   * [PresentMode.fifo] is `setSwapInterval(1)`. The swap then blocks until
///     the vertical blank and every frame is shown.
///   * [PresentMode.immediate] is `setSwapInterval(0)`. The swap returns as
///     soon as the driver has taken the buffer, and the picture may tear.
///   * [PresentMode.mailbox] is **refused by name** on every GL window, and
///     the reason is structural rather than a gap in this file. Mailbox is a
///     property of how a swap chain *rotates its buffers*: a newer frame
///     replaces a queued-but-undisplayed one. `WGL_EXT_swap_control`,
///     `GLX_EXT_swap_control` and `eglSwapInterval` all take a single integer
///     that says how many blanks to wait for, and there is no value of that
///     integer that means "replace what is queued". Vulkan can express it
///     (`VK_PRESENT_MODE_MAILBOX_KHR`, chosen in `vulkan_swapchain.dart` when
///     the surface reports it) and DXGI can approximate it
///     (`DXGI_SWAP_EFFECT_FLIP_DISCARD` with three buffers and a waitable
///     object). GL cannot, on any of the three window systems here.
///
/// A negative interval - `EXT_swap_control_tear`'s adaptive vsync - is
/// deliberately not offered. It is fifo that degrades to immediate under
/// budget, which is a *fourth* mode, and inventing a fourth mode inside a
/// three-mode contract is how a caller ends up unable to say what it got.
///
/// ## Refusal is the common answer, not the exceptional one
///
/// [GlSwapChain.setSwapInterval] returns false where the platform has no
/// control at all - a remote desktop session, a driver without the extension.
/// That is turned into a refusal naming the call, which is the whole reason
/// [PresentPacer.supportedPresentModes] is an instance property: the same code
/// path here supports both modes on a local GPU and neither over RDP, and no
/// static table could know which one it is on.
library;

import '../../present_mode.dart';
import 'gl_surface_descriptor.dart';

/// Paces a GL window through its swap chain's swap interval.
final class GlSwapChainPresentPacer implements PresentPacer {
  GlSwapChainPresentPacer(
    this._swapChain, {
    this.surfaceDescription = 'a GL window',
  });

  final GlSwapChain _swapChain;

  /// Named in every refusal, so a report says which surface answered.
  final String surfaceDescription;

  /// The mode in force.
  ///
  /// Starts at [PresentMode.fifo] because that is what a GL window is created
  /// with on all three platforms unless something changes it, and a pacer
  /// whose initial answer is a guess would report the wrong `applied` mode in
  /// the first refusal it ever produced.
  PresentMode _mode = PresentMode.fifo;

  /// Whether any request has been honoured yet.
  ///
  /// The distinction matters for [supportedPresentModes], which has to *ask*
  /// the driver to find out and must not leave the interval changed by having
  /// asked - so probing restores what was in force.
  bool _probed = false;
  Set<PresentMode> _supported = const <PresentMode>{};

  @override
  Set<PresentMode> get supportedPresentModes {
    if (_probed) return _supported;
    _probed = true;
    // Ask for both, then put back what was in force. `setSwapInterval` is the
    // only honest probe there is: neither WGL nor EGL exposes "can you" apart
    // from "do it", and a static table keyed on the extension string would
    // still be wrong over a remote session where the extension is present and
    // the request is ignored.
    final bool immediate = _swapChain.setSwapInterval(0);
    final bool fifo = _swapChain.setSwapInterval(1);
    _supported = <PresentMode>{
      if (fifo) PresentMode.fifo,
      if (immediate) PresentMode.immediate,
    };
    if (_mode == PresentMode.immediate && immediate) {
      _swapChain.setSwapInterval(0);
    }
    return _supported;
  }

  @override
  PresentMode get presentMode => _mode;

  @override
  PresentModeOutcome requestPresentMode(PresentMode mode) {
    switch (mode) {
      case PresentMode.mailbox:
        return PresentModeOutcome.refused(
          mode,
          applied: _mode,
          reason: 'swap-interval control takes a count of vertical blanks and '
              'has no value meaning "replace the queued frame"; mailbox is a '
              'swap chain buffer-rotation mode that WGL, GLX and EGL cannot '
              'express',
          detail: 'Vulkan expresses it as VK_PRESENT_MODE_MAILBOX_KHR and DXGI '
              'as FLIP_DISCARD with a waitable object; $surfaceDescription is '
              'neither',
        );
      case PresentMode.fifo:
        return _apply(
            mode,
            1,
            'wglSwapIntervalEXT / glXSwapIntervalEXT / '
            'eglSwapInterval(1)');
      case PresentMode.immediate:
        return _apply(
            mode,
            0,
            'wglSwapIntervalEXT / glXSwapIntervalEXT / '
            'eglSwapInterval(0)');
    }
  }

  PresentModeOutcome _apply(PresentMode mode, int interval, String call) {
    if (!_swapChain.setSwapInterval(interval)) {
      return PresentModeOutcome.refused(
        mode,
        applied: _mode,
        reason: '$call returned false on $surfaceDescription, which is what a '
            'driver without the swap-control extension and a remote desktop '
            'session both look like from here',
      );
    }
    _mode = mode;
    return PresentModeOutcome.honoured(mode, detail: call);
  }

  /// Always false, and the reason is [PresentPacer.awaitVerticalBlank]'s
  /// second bullet: under [PresentMode.fifo] the swap call itself blocks, so
  /// waiting here as well would halve the frame rate rather than pace it.
  /// Under [PresentMode.immediate] waiting would contradict the mode.
  @override
  bool awaitVerticalBlank() => false;

  @override
  String toString() => 'GlSwapChainPresentPacer(${_mode.name}, '
      '$surfaceDescription)';
}
