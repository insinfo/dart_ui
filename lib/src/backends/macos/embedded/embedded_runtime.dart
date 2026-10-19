/// Whether this process is the Dart runtime embedded in a macOS app, the
/// fourth macOS backend's precondition (`doc/MACOS_TRES_BACKENDS.md`,
/// backend 4, `appkitEmbedded`).
///
/// The app's executable is `dartaotruntime` built from the Dart SDK's sources
/// with `tool/mobile/dart_sdk_patches/3.13.5-macos.patch`. As a `.app`'s
/// executable - or with `DART_UI_MAIN_THREAD_LOOP=1` - that runtime handles
/// the main isolate's messages on the process main thread, from a source of
/// the main `CFRunLoop`, with the isolate entered there for good. Two
/// functions it exports say so and hand over the run loop:
///
///   * `Dart_DartUiMainThreadLoop()` - 1 when the mode is on;
///   * `Dart_DartUiRunApplication()` - asks the runtime to run
///     `[NSApp run]` once the current message is handled.
///
/// The `Dart_` prefix is the only one the executable exports
/// (`-exported_symbol _Dart_*`), not a claim to the embedding API.
///
/// Nothing here touches AppKit; the stock `dart` and `dartaotruntime` simply
/// lack the symbols, and a process on another OS answers [isActive] false.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

/// The symbol whose presence marks the patched runtime.
const String macosEmbeddedLoopSymbol = 'Dart_DartUiMainThreadLoop';

/// The symbol that starts `[NSApp run]` on the main run loop.
const String macosEmbeddedRunApplicationSymbol = 'Dart_DartUiRunApplication';

/// What [MacosEmbeddedRuntime.status] found, in the words a probe reports.
enum MacosEmbeddedRuntimeStatus {
  /// A supported embedded loop adapter keeps this isolate on thread 0.
  /// The default detector recognizes the patched SDK runtime; a backend may
  /// supply an independently validated adapter through its constructor hooks.
  active,

  /// Not macOS.
  notMacos,

  /// A stock runtime: `dart run`, `dart compile exe`, the standalone
  /// `dartaotruntime`.
  stockRuntime,

  /// The patched runtime started from a terminal on a plain snapshot,
  /// without `DART_UI_MAIN_THREAD_LOOP=1`: the main isolate runs on a pool
  /// thread as in the stock runtime.
  loopOff,

  /// The mode is on but this isolate is not on the main thread - a helper
  /// isolate asking. AppKit must not be called from it.
  notMainThread;

  /// Whether the embedded backend may run.
  bool get isActive => this == active;

  /// One line for the probe's diagnostic.
  String get description => switch (this) {
        active => 'embedded runtime: main isolate on the main thread',
        notMacos => 'not macOS',
        stockRuntime => 'not the dart_ui embedded runtime (no '
            '$macosEmbeddedLoopSymbol in the process); build a .app with '
            'tool/macos/build_app.dart',
        loopOff => 'the embedded runtime runs a plain snapshot; open the .app '
            'or set DART_UI_MAIN_THREAD_LOOP=1',
        notMainThread => 'this isolate is not on the main thread',
      };
}

/// Decides [MacosEmbeddedRuntimeStatus] from the facts, so the rule is
/// testable on any machine.
MacosEmbeddedRuntimeStatus classifyMacosEmbeddedRuntime({
  required bool isMacOS,
  required bool hasLoopSymbol,
  required int loopValue,
  required bool onMainThread,
}) {
  if (!isMacOS) return MacosEmbeddedRuntimeStatus.notMacos;
  if (!hasLoopSymbol) return MacosEmbeddedRuntimeStatus.stockRuntime;
  if (loopValue != 1) return MacosEmbeddedRuntimeStatus.loopOff;
  if (!onMainThread) return MacosEmbeddedRuntimeStatus.notMainThread;
  return MacosEmbeddedRuntimeStatus.active;
}

/// The running process, read through `DynamicLibrary.process()`.
abstract final class MacosEmbeddedRuntime {
  static MacosEmbeddedRuntimeStatus? _status;

  /// Read once: none of the facts changes while the process lives.
  static MacosEmbeddedRuntimeStatus get status => _status ??= _read();

  /// Whether the embedded backend can run in this isolate.
  static bool get isActive => status.isActive;

  static MacosEmbeddedRuntimeStatus _read() {
    if (!Platform.isMacOS) return MacosEmbeddedRuntimeStatus.notMacos;
    try {
      final DynamicLibrary process = DynamicLibrary.process();
      final bool hasSymbol = process.providesSymbol(macosEmbeddedLoopSymbol);
      final int value = hasSymbol
          ? process.lookupFunction<IntPtr Function(), int Function()>(
              macosEmbeddedLoopSymbol)()
          : 0;
      final bool main =
          process.lookupFunction<Int32 Function(), int Function()>(
                  'pthread_main_np')() ==
              1;
      return classifyMacosEmbeddedRuntime(
        isMacOS: true,
        hasLoopSymbol: hasSymbol,
        loopValue: value,
        onMainThread: main,
      );
    } on Object {
      return MacosEmbeddedRuntimeStatus.stockRuntime;
    }
  }

  /// Asks the runtime to run `[NSApp run]` once the current message is
  /// handled. `NSApplication` must exist by then; the runtime does nothing
  /// when it does not.
  static void requestRunApplication() {
    DynamicLibrary.process().lookupFunction<Void Function(), void Function()>(
        macosEmbeddedRunApplicationSymbol)();
  }
}
