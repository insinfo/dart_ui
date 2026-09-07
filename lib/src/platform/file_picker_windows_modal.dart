/// Showing a Windows modal dialog without stopping the Dart event loop.
///
/// ## The failure this file exists for
///
/// `IFileDialog::Show` and `GetOpenFileNameW` both run a **nested modal message
/// loop on the calling thread** and do not return until the user dismisses the
/// dialog. Called through `dart:ffi` from the main isolate, that stops far more
/// than the frame in progress: the whole Dart event loop is parked inside the
/// FFI call, so no timer fires, no microtask drains and no pending `await`
/// completes for as long as the dialog is up.
///
/// The video player example is where it was reported. Opening the file dialog
/// froze the picture until the dialog closed, while the sound kept playing
/// perfectly - WASAPI renders on an operating-system thread of its own, which
/// nothing here blocks. That asymmetry is the fingerprint of this cause and not
/// of a stalled renderer: it was `await decoder.readFrame()` that never
/// completed, so no frame was even decoded, let alone presented.
///
/// Measured with `Sleep` from kernel32 standing in for `Show`, because `Show`
/// cannot be run unattended: a 1500 ms blocking FFI call made from the main
/// isolate let **1** tick of a 50 ms periodic timer through, and the same call
/// made through [Isolate.run] let **30** through.
///
/// ## What the detour costs
///
/// A fresh isolate gets an operating-system thread of its own, so
/// `CoInitializeEx(COINIT_APARTMENTTHREADED)` there is correct and the dialog's
/// nested loop pumps *that* thread rather than the one that draws. Measured on
/// Windows 11 build 26200 with `dart run`: the entire create-and-configure
/// sequence - `DynamicLibrary.open` on ole32 and shell32, `CoInitializeEx`,
/// `CoCreateInstance`, every configuration call - took a median 2.5 ms inline
/// and 3.4 ms through [Isolate.run], so the detour adds about **1 ms** before
/// the dialog can appear. An empty [Isolate.run] round trip is ~0.5 ms. Neither
/// is visible next to the shell dialog's own startup.
///
/// ## What the detour takes away, and how it is put back
///
/// Modality. A dialog running on another thread does not block our window, so
/// without help the user could press play, seek, or open a second dialog
/// underneath the first one. Both halves are restored here:
///
///   * [_OwnerGate] disables the owner window for the duration, which is what
///     `EnableWindow` does for a real modal anyway, and re-enables it on
///     **every** exit path including the throwing one. A window left disabled
///     is dead for the rest of the process - a far worse bug than the freeze
///     this file fixes - so the re-enable is in a `finally` and nowhere else.
///   * A latch refuses a second dialog while one is up. It is needed even
///     though the owner is disabled, because a caller may pass no owner at all
///     (`ownerWindowHandle: 0`), and then nothing else would stop a second
///     open.
///
/// ## The one rule for a body passed to [runWindowsModalOffThread]
///
/// **It must be synchronous from end to end.** A Dart isolate is not pinned to
/// an operating-system thread: it may be resumed on a different one after a
/// suspension point. COM apartments and window handles are thread-affine, so an
/// `await` in the middle of the dialog sequence could park
/// `CoInitializeEx`/`Show`/`CoUninitialize` on two different threads, which is
/// undefined at best. Everything between the two ends of the body runs in one
/// uninterrupted synchronous stretch on purpose.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import '../ffi/native_memory.dart';

/// Whether a dialog started by [runWindowsModalOffThread] is still up.
///
/// Per isolate, because the latch it reads is: the caller that owns the window
/// is the one that opens dialogs for it.
bool get isWindowsModalDialogOpen => _dialogInFlight;

bool _dialogInFlight = false;

/// Runs [body] - a blocking, modal Win32 call - on an isolate of its own.
///
/// Returns null, without running [body] at all, when a dialog opened through
/// this function is already up. Callers treat that exactly as they treat a
/// cancel: the user asked for a second dialog and did not get one, and no file
/// was chosen either way.
///
/// [ownerWindowHandle] may be 0, which means "no owner": the dialog then has
/// nothing to be modal to and nothing is disabled. Passing the real `HWND` is
/// strongly preferred - it is what gives the dialog its owner for z-order and
/// what makes the modality above real.
///
/// Errors thrown by [body] cross back and are rethrown here, which is why the
/// gate is reopened in a `finally`.
Future<T?> runWindowsModalOffThread<T>({
  required int ownerWindowHandle,
  required T Function() body,
  String debugName = 'windows-modal-dialog',
}) async {
  if (!Platform.isWindows) {
    // Nothing on the other platforms blocks the event loop: their pickers are
    // `Process.run`, which is already asynchronous. Running the body inline
    // keeps this function usable from shared code without a branch at the call
    // site.
    return body();
  }
  if (_dialogInFlight) return null;
  _dialogInFlight = true;
  final _OwnerGate gate = _OwnerGate.close(ownerWindowHandle);
  try {
    return await Isolate.run<T>(body, debugName: debugName);
  } finally {
    gate.reopen();
    _dialogInFlight = false;
  }
}

/// The owner window, disabled while a dialog belonging to it is up.
///
/// ## Why the re-enable is conditional
///
/// `EnableWindow` answers whether the window was **already** disabled. If it
/// was, the application's own modal bookkeeping owns that state, and switching
/// it back on here would unblock a window somebody else deliberately blocked.
/// So a gate that found the window already disabled remembers nothing and does
/// nothing on the way out.
///
/// ## Why the foreground is restored by hand
///
/// A modal dialog normally re-enables its owner *before* the dialog window is
/// destroyed, and Windows then hands activation back to the owner. Here the
/// dialog is destroyed inside `Show` on the other thread and we only learn
/// about it afterwards, so by the time the owner is enabled again Windows has
/// already chosen somebody else. [reopen] therefore asks for the foreground
/// back - but only when the foreground is still inside this process, so that a
/// user who deliberately alt-tabbed away while the dialog was up is not yanked
/// back, and so that a request Windows would refuse (which flashes the taskbar
/// button instead) is never made.
final class _OwnerGate {
  const _OwnerGate._(this._api, this._hwnd);

  /// Null when this gate did not disable anything and owes nothing.
  final _ModalWindowApi? _api;
  final int _hwnd;

  static const _OwnerGate _inert = _OwnerGate._(null, 0);

  static _OwnerGate close(int hwnd) {
    if (hwnd == 0) return _inert;
    final _ModalWindowApi? api = _ModalWindowApi.instance;
    if (api == null) return _inert;
    // A handle that named a window when the caller captured it and names a
    // destroyed one now: disabling it is a no-op, but remembering it would
    // make `reopen` call `SetForegroundWindow` on a dead window.
    if (api.isWindow(hwnd) == 0) return _inert;
    if (api.enableWindow(hwnd, 0) != 0) return _inert;
    return _OwnerGate._(api, hwnd);
  }

  void reopen() {
    final _ModalWindowApi? api = _api;
    if (api == null) return;
    api.enableWindow(_hwnd, 1);
    if (api.isWindow(_hwnd) == 0) return;
    if (_foregroundIsOurs(api)) api.setForegroundWindow(_hwnd);
  }

  bool _foregroundIsOurs(_ModalWindowApi api) {
    final int foreground = api.getForegroundWindow();
    if (foreground == 0) return true;
    return using<bool>((NativeArena arena) {
      final Pointer<Uint32> owner = arena.allocate<Uint32>(sizeOf<Uint32>());
      owner.value = 0;
      api.getWindowThreadProcessId(foreground, owner);
      return owner.value == api.currentProcessId();
    });
  }
}

typedef _NativeBoolOfHandle = Int32 Function(IntPtr);
typedef _NativeEnableWindow = Int32 Function(IntPtr, Int32);
typedef _NativeGetForegroundWindow = IntPtr Function();
typedef _NativeGetWindowThreadProcessId = Uint32 Function(
    IntPtr, Pointer<Uint32>);
typedef _NativeGetCurrentProcessId = Uint32 Function();

/// The five entry points the modality gate needs, bound once per isolate.
///
/// A missing library is data and not an exception, the same rule the rest of
/// this layer follows: the answer is null and the dialog simply opens without a
/// gate, which is the behaviour that shipped before this file existed.
final class _ModalWindowApi {
  _ModalWindowApi._(DynamicLibrary user32, DynamicLibrary kernel32)
      : enableWindow = user32.lookupFunction<_NativeEnableWindow,
            int Function(int, int)>('EnableWindow'),
        isWindow = user32
            .lookupFunction<_NativeBoolOfHandle, int Function(int)>('IsWindow'),
        setForegroundWindow =
            user32.lookupFunction<_NativeBoolOfHandle, int Function(int)>(
                'SetForegroundWindow'),
        getForegroundWindow = user32.lookupFunction<_NativeGetForegroundWindow,
            int Function()>('GetForegroundWindow'),
        getWindowThreadProcessId = user32.lookupFunction<
            _NativeGetWindowThreadProcessId,
            int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId'),
        currentProcessId = kernel32.lookupFunction<_NativeGetCurrentProcessId,
            int Function()>('GetCurrentProcessId');

  final int Function(int, int) enableWindow;
  final int Function(int) isWindow;
  final int Function(int) setForegroundWindow;
  final int Function() getForegroundWindow;
  final int Function(int, Pointer<Uint32>) getWindowThreadProcessId;
  final int Function() currentProcessId;

  static _ModalWindowApi? _instance;
  static bool _attempted = false;

  static _ModalWindowApi? get instance {
    if (_attempted) return _instance;
    _attempted = true;
    if (!Platform.isWindows) return null;
    try {
      return _instance = _ModalWindowApi._(
        DynamicLibrary.open('user32.dll'),
        DynamicLibrary.open('kernel32.dll'),
      );
    } on Object {
      return null;
    }
  }
}
