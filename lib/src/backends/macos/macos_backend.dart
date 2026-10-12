/// The macOS windowing backend, per section 20 of the roadmap.
///
/// This is the entry point for macOS windowing: it implements the
/// cross-platform [WindowingBackend] contract and delegates to whichever of
/// the three macOS backends the selection layer chose.
///
/// The three backends — SkyLight, AppKit signal hijack and AppKit native
/// host — are documented in `MACOS_TRES_BACKENDS.md`.  This file knows
/// which one to instantiate; the code above it does not, and must not.
///
/// ## Lifecycle
///
/// [probe] runs before [initialize] and reports what is available.
/// [initialize] creates the selected backend.
/// [createWindow] delegates to it.
/// [shutdown] tears down in reverse order.
///
/// Every public method on this class is reachable from two paths: the happy
/// path through the application, and the teardown path through the
/// framework's shutdown.  Both must work, and neither may leave native
/// handles behind.  That is `lifecycle.dart`'s rule, and it applies to the
/// backend as much as to the window.
library;

import 'dart:async';
import 'dart:io' show Platform;

import '../../foundation/diagnostics.dart';
import '../../geometry/offset.dart';
import '../../platform/backend_selection.dart';
import '../../platform/clipboard.dart';
import '../../platform/drag_drop.dart';
import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import '../../platform/window_events.dart';
import 'host_locator.dart';
import 'host_process.dart';
import 'host_supervisor.dart' show MacosHostStarter;
import 'macos_backend_kind.dart';
import 'macos_backend_selection.dart';
import 'macos_clipboard.dart';
import 'macos_drag_drop.dart';
import 'macos_text_input.dart';
import 'macos_window.dart';
import 'spare_host.dart';

/// Creates and owns macOS windows through the selected backend strategy.
final class MacosWindowingBackend
    implements
        WindowingBackend,
        ScreenProvider,
        ClipboardProvider,
        DragDropProvider,
        TextInputProvider {
  MacosWindowingBackend({
    MacosBackendOptions options = const MacosBackendOptions(),
  }) : _options = options;

  final MacosBackendOptions _options;
  final List<NativeWindow> _windows = <NativeWindow>[];
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  BackendSelection? _selection;
  MacosBackendKind? _activeKind;
  bool _initialized = false;
  bool _quitRequested = false; // ignore: prefer_final_fields
  int _nextWindowId = 1;

  /// A hidden popup host waiting to be adopted; see `spare_host.dart`.
  ///
  /// A future rather than a host because the launch takes ~55 ms and a popup
  /// that arrives during it should wait for the spare already on its way, not
  /// start a second launch beside it. Null until the first popup opens: an
  /// application that never shows a menu never pays for an idle process.
  Future<MacosSpareHost?>? _spare;

  /// The general pasteboard, reached through the host of an open window.
  ///
  /// See `macos_clipboard.dart`. Two refusals by name instead of a clipboard
  /// that fails later for a reason nobody kept: before [initialize], and on
  /// the two strategies that do not create windows, because without a window
  /// there is no AppKit host to ask.
  @override
  Clipboard get clipboard {
    if (!_initialized) {
      return const UnavailableClipboard(
        'the macOS backend has not been initialized, so no AppKit host '
        'exists to reach the pasteboard through',
      );
    }
    if (_activeKind != MacosBackendKind.appkitNativeHost) {
      return UnavailableClipboard(
        'the ${_activeKind?.name} strategy creates no AppKit host, and the '
        'pasteboard is reached through one; only appkitNativeHost has a '
        'clipboard',
      );
    }
    return _clipboard;
  }

  /// Drops of files and text onto a window, through its host's
  /// `NSDraggingDestination`. See `macos_drag_drop.dart`.
  @override
  DragDropBackend get dragAndDrop =>
      _initialized && _activeKind == MacosBackendKind.appkitNativeHost
          ? const MacosDragDropBackend()
          : UnavailableDragDrop(
              name: 'appkit',
              reason: _initialized
                  ? 'the ${_activeKind?.name} strategy creates no AppKit host, '
                      'and drops are received through one'
                  : 'the macOS backend has not been initialized',
            );

  /// The AppKit text input system, reached through each window's host: dead
  /// keys and input methods. See `macos_text_input.dart`.
  @override
  TextInputBackend get textInput =>
      _initialized && _activeKind == MacosBackendKind.appkitNativeHost
          ? const MacosTextInputBackend()
          : UnavailableTextInput(
              name: 'nstextinputclient',
              reason: _initialized
                  ? 'the ${_activeKind?.name} strategy creates no AppKit host, '
                      'and the text input system is reached through one'
                  : 'the macOS backend has not been initialized',
            );

  late final MacosClipboard _clipboard = MacosClipboard(() {
    for (final MacosWindow window in _windows.whereType<MacosWindow>()) {
      final MacosClipboardChannel? channel = window.clipboardChannel;
      if (channel != null) return channel;
    }
    return null;
  });

  /// Which backend was selected, available after [probe].
  MacosBackendKind? get activeKind => _activeKind;

  @override
  String get name =>
      _activeKind != null ? 'macos.${_activeKind!.name}' : 'macos';

  @override
  BackendProbeResult probe() {
    if (!Platform.isMacOS) {
      return BackendProbeResult.unsupported(
        name,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'macOS backend needs macOS',
          detail: 'Platform.operatingSystem=${Platform.operatingSystem}',
        ),
      );
    }

    _selection = selectMacosBackend(_options);
    final selection = _selection!;

    if (!selection.isSuccess) {
      final diagnostics = <BackendDiagnostic>[
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'no macOS backend available',
          detail: selection.describe(),
        ),
        for (final rejection in selection.rejected)
          ...rejection.probe.diagnostics,
      ];
      return BackendProbeResult(
        backendName: name,
        supported: false,
        diagnostics: diagnostics,
      );
    }

    final chosen = selection.chosen!;
    _activeKind = MacosBackendKind.values.firstWhere(
      (k) => chosen.name.endsWith(k.name),
      orElse: () => MacosBackendKind.appkitNativeHost,
    );

    _diagnostics.add(BackendDiagnostic.note(
      'selected macOS backend: ${_activeKind!.name}',
      detail: selection.describe().trim(),
    ));

    return chosen.probe;
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    if (_selection == null) probe();
    if (_activeKind == null) {
      throw BackendSelectionError(
        requested: _options.requested == null
            ? null
            : 'macos.${_options.requested!.name}',
        attempts: _selection == null
            ? const <BackendProbeResult>[]
            : <BackendProbeResult>[
                for (final r in _selection!.rejected) r.probe,
              ],
      );
    }

    // Actual backend-specific initialisation depends on the selected kind.
    // appkitNativeHost: spawn the host process (MacosWindow handles this).
    // skylight: open SkyLight framework and resolve symbols.
    // appkitSignal: install the signal handler.
    //
    // For now, mark initialised and let createWindow perform the lazy setup
    // that MacosWindow already implements for appkitNativeHost.
    _initialized = true;
  }

  @override
  Future<void> shutdown() async {
    if (!_initialized) return;
    _initialized = false;
    _quitRequested = true;

    final Future<MacosSpareHost?>? spare = _spare;
    _spare = null;
    await (await spare)?.dispose();

    final windows = List<NativeWindow>.of(_windows);
    for (final window in windows) {
      window.dispose();
    }
    await Future.wait<void>(
      windows.whereType<MacosWindow>().map((window) => window.teardown),
    );
    _windows.clear();
  }

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    _requireInitialized('createWindow');
    // The MacosWindow class already handles the host process lifecycle for
    // appkitNativeHost.  The other two backends will need their own window
    // implementations; for now we support the recommended default.
    if (_activeKind != MacosBackendKind.appkitNativeHost) {
      throw UnsupportedCapabilityError(
        backendName: name,
        capability: Capability.window,
        detail: '${_activeKind!.name} window creation not yet implemented; '
            'use appkitNativeHost',
      );
    }

    final location = MacosHostLocator.resolve(
      explicitPath: _options.hostBinaryPath,
    );
    _diagnostics.addAll(location.diagnostics);
    final binaryPath = location.binaryPath;
    if (binaryPath == null) {
      throw UnsupportedCapabilityError(
        backendName: name,
        capability: Capability.window,
        detail: 'native AppKit host binary disappeared after probe',
      );
    }

    final spawnOptions = MacosHostSpawnOptions(
      binaryPath: binaryPath,
      logicalWidth: options.size.width,
      logicalHeight: options.size.height,
      title: options.title,
      x: options.position?.dx,
      y: options.position?.dy,
      visible: options.visible,
      decorated: options.decorated,
      resizable: options.resizable,
      kind: MacosHostWindowKind.values.byName(options.kind.name),
    );
    final MacosSpareHost? spare = await _takeSpare(spawnOptions);

    MacosWindow newWindow(MacosHostStarter? starter) => MacosWindow(
          id: NativeWindowId(_nextWindowId++),
          surfaceFactory: createIOSurfacePool,
          clientSize: options.size,
          renderScale: 1,
          desktopScale: 1,
          onDiagnostic: _diagnostics.add,
          onClosed: _onWindowClosed,
          // Production has only the Mach-port rendezvous handoff. Keep
          // surfaces private instead of exposing them system-wide for an
          // unimplemented ID lookup fallback.
          globalSurfaces: false,
          hostStarter: starter,
        );

    MacosWindow window =
        newWindow(spare == null ? null : adoptingStarter(spare));
    var opened = await window.open(spawnOptions: spawnOptions);
    if (!opened && spare != null) {
      // A spare that died between its launch and this adoption - the
      // `macos-14` runner showed one gone by the time its surfaces were sent
      // - must not cost the user the menu. One fresh launch, as if there had
      // been no spare.
      _diagnostics.add(const BackendDiagnostic.note(
        'the spare popup host could not be adopted; launching a fresh one',
      ));
      window.dispose();
      await window.teardown;
      window = newWindow(null);
      opened = await window.open(spawnOptions: spawnOptions);
    }
    if (spawnOptions.kind == MacosHostWindowKind.popup) {
      // The replacement, launched as soon as this popup is open, so that the
      // next one - the submenu about to be hovered into, or the same menu
      // reopened - finds it ready. Not started alongside the popup's own host:
      // that is the one launch the user is waiting on.
      //
      // A 150 ms delay was tried and removed. It rested on the first menu on
      // the macos-14 runner going from 58 ms to ~300 ms once spares existed;
      // the same runner, same job, with and without a spare and the cold run
      // first, gave 217.6 ms and 220.5 ms (run 38231956976) - the runner's
      // cold cost, not the spare's. The delay cost a burst of opens its spare:
      // median 80 ms against 16-32 ms launching at once.
      _launchSpare(binaryPath);
    }
    if (!opened) {
      window.dispose();
      await window.teardown;
      throw StateError('$name.createWindow: native AppKit host did not start');
    }
    _quitRequested = false;
    _windows.add(window);
    return window;
  }

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  @override
  List<ScreenInfo> get screens {
    // NSScreen is queried in the AppKit host, where thread ownership is valid.
    // Every host sees the same desktop, so the first completed handshake is a
    // snapshot; concatenating them would report every monitor once per window.
    for (final MacosWindow window in _windows.whereType<MacosWindow>()) {
      final List<ScreenInfo> snapshot = window.hostScreens;
      if (snapshot.isNotEmpty) return List<ScreenInfo>.unmodifiable(snapshot);
    }
    return const <ScreenInfo>[];
  }

  @override
  ScreenInfo? screenAt(Offset screenPoint) =>
      ScreenInfo.nearest(screens, screenPoint);

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    _requireInitialized('pumpEvents');
    // The pump depends on the active backend:
    // - appkitNativeHost: read from the host process pipe
    // - skylight: read from the SkyLight event port
    // - appkitSignal: pump the CFRunLoop
    //
    // Each is wired when its window implementation lands.
    return !_quitRequested;
  }

  @override
  void wake() {
    // Wake depends on the active backend:
    // - appkitNativeHost: signal the pipe
    // - skylight: write to a self-pipe or CFRunLoopSource
    // - appkitSignal: CFRunLoopWakeUp
  }

  /// Diagnostics collected during probe and initialisation.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  /// Whether this process keeps a spare popup host at all.
  ///
  /// `DART_UI_MACOS_SPARE_HOST=0` turns it off. A diagnostic switch, not a
  /// setting: it exists so the popup smoke can run with and without the spare
  /// on the same runner, in the same job, and say which of the two a timing
  /// belongs to.
  static final bool spareHostEnabled =
      Platform.environment['DART_UI_MACOS_SPARE_HOST'] != '0';

  void _launchSpare(String binaryPath) {
    if (!spareHostEnabled || !_initialized) return;
    _spare ??= MacosSpareHost.launch(binaryPath: binaryPath);
  }

  /// The spare, if there is one that can become a window like [options].
  ///
  /// Taken whether or not it matches: a spare that does not fit this request
  /// is closed here, so the backend never holds two idle processes.
  Future<MacosSpareHost?> _takeSpare(MacosHostSpawnOptions options) async {
    if (options.kind != MacosHostWindowKind.popup) return null;
    final Future<MacosSpareHost?>? pending = _spare;
    if (pending == null) return null;
    _spare = null;
    final MacosSpareHost? spare = await pending;
    if (spare == null) return null;
    if (spare.isAvailable && spare.matches(options)) return spare;
    await spare.dispose();
    return null;
  }

  void _requireInitialized(String operation) {
    if (!_initialized) {
      throw StateError('$name.$operation before initialize()');
    }
  }

  void _onWindowClosed(MacosWindow window) {
    _windows.remove(window);
    if (_windows.isEmpty) _quitRequested = true;
  }

  @override
  String toString() =>
      'MacosWindowingBackend(kind: ${_activeKind?.name ?? "none"}, '
      'initialized: $_initialized, windows: ${_windows.length})';
}
