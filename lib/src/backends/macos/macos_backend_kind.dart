/// The four macOS windowing backends and what they can do.
///
/// See `doc/MACOS_TRES_BACKENDS.md` for the architecture, the measurements
/// and the reasoning behind each.  This file is the Dart side of that
/// decision: a type the selection layer can switch on, and a capability
/// descriptor each backend fills in during probe.
///
/// Nothing here imports AppKit, SkyLight or any native library.  The
/// dependency rule is the same one every other backend in this project
/// follows: the enum lives in common code so the *selector* can reason
/// about backends it has never loaded.
library;

import '../../foundation/diagnostics.dart';

/// Which macOS windowing strategy is active.
///
/// The names match the keys used in `MACOS_TRES_BACKENDS.md` and in the
/// POC code under `poc/poc_20_macos_three_backends/` on the
/// `exploracao-inicial` branch, so a grep there finds both.
enum MacosBackendKind {
  /// WindowServer directly via SkyLight/CGS private API.
  ///
  /// Does not require the process main thread (thread 0), which is how a
  /// plain `dart compile exe` binary can create a window at all.  Private
  /// API: not forward-compatible by contract, but measured as stable across
  /// macOS 12-15 on both architectures.
  skylight,

  /// AppKit with the main thread hijacked via `SIGUSR2` → `CFRunLoopRun`.
  ///
  /// Creates a real `NSWindow`, but `CFRunLoopRun` is not async-signal-safe
  /// and `[NSApp run]` has produced traps in the spikes.  Experimental,
  /// requires explicit opt-in, and never chosen automatically.
  appkitSignal,

  /// A native Objective-C host process owns the AppKit event loop; the Dart
  /// process is a worker that communicates via pipe + IOSurface.
  ///
  /// The recommended default: correct thread ownership, proven lifecycle,
  /// measurably cheap IPC (22-59 µs round trip, < 0.2% of a 60 Hz frame).
  appkitNativeHost,

  /// AppKit in this process, on the main thread, with Dart as the guest of
  /// the application's run loop: the executable is the Dart AOT runtime
  /// built from source with `tool/mobile/dart_sdk_patches/3.13.5-macos.patch`
  /// (as on iOS, ADR 0010), which handles the main isolate's messages on the
  /// main thread and runs `[NSApp run]`. One process for every window, so
  /// popups are child windows of their owner.
  ///
  /// Chosen automatically only inside that runtime - a `.app` built by
  /// `tool/macos/build_app.dart` - where it is the only AppKit path that
  /// needs neither a second process nor a signal. Implemented by
  /// `MacosEmbeddedWindowingBackend` (`embedded/`), not by the facade.
  appkitEmbedded,
}

/// What a macOS backend reported about itself.
///
/// Separate from [BackendProbeResult] because these properties are macOS-
/// specific and do not belong on the cross-platform contract.  The selection
/// layer wraps this inside a [BackendProbeResult] for the generic machinery.
final class MacosBackendCapabilities {
  const MacosBackendCapabilities({
    required this.kind,
    required this.canCreateWindow,
    required this.hasInput,
    required this.hasIme,
    required this.hasAccessibility,
    required this.hasOrderlyShutdown,
    required this.needsHostBinary,
    this.hostBinaryPath,
    this.diagnostics = const <BackendDiagnostic>[],
  });

  final MacosBackendKind kind;

  /// Whether the backend's window-creation path is available.  False when a
  /// required symbol, library or host binary is missing.
  final bool canCreateWindow;

  /// Whether keyboard and pointer input reaches the Dart process.
  final bool hasInput;

  /// Whether the input-method protocol is wired.
  final bool hasIme;

  /// Whether the accessibility tree can be exposed to VoiceOver.
  final bool hasAccessibility;

  /// Whether the backend can tear down without `_exit`.
  final bool hasOrderlyShutdown;

  /// Whether this backend needs a compiled native host binary.
  /// Only true for [MacosBackendKind.appkitNativeHost].
  final bool needsHostBinary;

  /// When [needsHostBinary] is true, the path the locator resolved.
  /// Null means it was not found, which is a probe failure.
  final String? hostBinaryPath;

  /// Everything worth reporting, successful or not.
  final List<BackendDiagnostic> diagnostics;

  /// Converts to the cross-platform [BackendProbeResult] that
  /// [selectBackend] consumes.
  BackendProbeResult toProbeResult() {
    final capabilities = <Capability>{
      if (canCreateWindow) Capability.window,
      if (hasInput) ...<Capability>[
        Capability.keyboardInput,
        Capability.pointerInput,
        Capability.scrollInput,
      ],
      if (hasIme) Capability.textComposition,
      if (hasAccessibility) Capability.accessibility,
      if (hasOrderlyShutdown) Capability.orderlyShutdown,
      // CPU presentation is always available when a window exists: the
      // IOSurface path or the CoreGraphics fallback provides it.
      if (canCreateWindow) Capability.cpuPresentation,
      // The native-host path maps popup and tooltip to a nonactivating
      // NSPanel. The other strategies cannot create windows yet, so tying the
      // claim to [canCreateWindow] cannot advertise a path that falls through
      // to an ordinary activating NSWindow.
      if (canCreateWindow && kind == MacosBackendKind.appkitNativeHost)
        Capability.nativePopups,
      // The embedded backend's menus are nonactivating NSPanels too - child
      // windows of their owner, in the same process - and as clear as the
      // host's: the layer shows a premultiplied BGRA IOSurface.
      if (canCreateWindow &&
          kind == MacosBackendKind.appkitEmbedded) ...<Capability>[
        Capability.nativePopups,
        Capability.transparentPopups,
        Capability.multipleWindows,
      ],
      // The host's panel is non-opaque and clear (`dart_ui_macos_host.m`,
      // applicationDidFinishLaunching), and the IOSurface it shows is
      // premultiplied BGRA, so a pixel the framework leaves at zero alpha
      // is desktop.
      if (canCreateWindow && kind == MacosBackendKind.appkitNativeHost)
        Capability.transparentPopups,
      // Through the same host: NSPasteboard is AppKit, and the host is the
      // only process here that runs AppKit.
      if (canCreateWindow && kind == MacosBackendKind.appkitNativeHost)
        Capability.clipboardText,
      // PNG/TIFF and HTML, through the same host (`clipboard-rich`). The host
      // is built from this repository, so the claim follows the source; a
      // stale binary is refused by name at the operation, not here.
      if (canCreateWindow && kind == MacosBackendKind.appkitNativeHost)
        Capability.clipboardImage,
      // Both ways: the host's view is the NSDraggingDestination and, since
      // 12/10/2026, the NSDraggingSource too (macos_drag_drop.dart).
      if (canCreateWindow && kind == MacosBackendKind.appkitNativeHost)
        Capability.dragAndDrop,
      // One host process per window, so a window opens like the first one.
      if (canCreateWindow && kind == MacosBackendKind.appkitNativeHost)
        Capability.multipleWindows,
    };

    return BackendProbeResult(
      backendName: 'macos.${kind.name}',
      supported: canCreateWindow,
      capabilities: capabilities,
      diagnostics: diagnostics,
    );
  }

  @override
  String toString() => 'MacosBackendCapabilities(${kind.name}, '
      'window: $canCreateWindow, input: $hasInput, ime: $hasIme, '
      'a11y: $hasAccessibility, shutdown: $hasOrderlyShutdown)';
}
