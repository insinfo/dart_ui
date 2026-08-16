/// The Windows implementation of the [Clipboard] port: `CF_UNICODETEXT`
/// through user32/kernel32, with no wrapper library.
///
/// Windows is the one target where the clipboard genuinely is synchronous:
/// `OpenClipboard` takes a process-global lock, `GetClipboardData` hands back a
/// global memory handle that is already populated, and both return before the
/// call does. The futures here therefore complete on the spot. They are futures
/// anyway because [Clipboard] is asynchronous for X11 and Wayland, where the
/// data has to be negotiated with another process - see that contract for why
/// shaping the port around this backend would be a mistake.
///
/// **The lock is the failure mode that matters.** `OpenClipboard` fails while
/// any other process holds the clipboard, which happens routinely: clipboard
/// managers open it on every change. The answer here is one attempt and a named
/// [ClipboardException], never a retry loop - a loop turns a failed Ctrl+C into
/// a frozen window - and never a silent null, which would tell the caller the
/// clipboard was empty when it was merely busy.
library;

import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import '../../platform/clipboard.dart';
import 'win32_api.dart';
import 'win32_constants.dart';

final class Win32Clipboard implements Clipboard {
  const Win32Clipboard(this.api);

  final Win32Api api;

  bool get isSupported => api.clipboardSupported;

  @override
  Future<void> writeText(String value) async {
    _requireSupported();
    _open();
    var handle = 0;
    try {
      if (api.emptyClipboard!() == 0) _fail('EmptyClipboard');
      final units = <int>[...value.codeUnits, 0];
      handle = api.globalAlloc!(gmemMoveable, units.length * 2);
      if (handle == 0) _fail('GlobalAlloc');
      final address = api.globalLock!(handle);
      if (address == 0) _fail('GlobalLock');
      Pointer<Uint16>.fromAddress(address)
          .asTypedList(units.length)
          .setAll(0, units);
      api.globalUnlock!(handle);
      if (api.setClipboardData!(cfUnicodeText, handle) == 0) {
        _fail('SetClipboardData');
      }
      // Windows owns a successful CF_UNICODETEXT handle.
      handle = 0;
    } finally {
      if (handle != 0) api.globalFree!(handle);
      api.closeClipboard!();
    }
  }

  @override
  Future<String?> readText() async {
    _requireSupported();
    _open();
    try {
      // Null rather than an exception for both of these: a clipboard holding a
      // bitmap and nothing else is not a failure, it simply has no text, and
      // the port draws that line deliberately.
      final handle = api.getClipboardData!(cfUnicodeText);
      if (handle == 0) return null;
      final address = api.globalLock!(handle);
      if (address == 0) return null;
      try {
        final pointer = Pointer<Uint16>.fromAddress(address);
        final units = <int>[];
        for (var index = 0;; index++) {
          final unit = (pointer + index).value;
          if (unit == 0) break;
          units.add(unit);
        }
        // Returned verbatim, surrogate pairs and CRLF and all: sanitising is
        // the field's policy (`PastedText`), not the transport's, and a
        // transport that quietly rewrote what another application wrote would
        // make the two disagree about what is on the clipboard.
        return String.fromCharCodes(units);
      } finally {
        api.globalUnlock!(handle);
      }
    } finally {
      api.closeClipboard!();
    }
  }

  void _open() {
    if (api.openClipboard!(0) == 0) {
      throw const ClipboardException(
        backend: 'win32',
        operation: 'OpenClipboard',
        reason: 'another process holds the clipboard lock; the clipboard is '
            'process-global on Windows and this call is not retried, because '
            'a retry loop turns a busy clipboard into a frozen window',
      );
    }
  }

  void _requireSupported() {
    if (!isSupported) {
      throw UnsupportedCapabilityError(
        backendName: 'win32',
        capability: Capability.clipboardText,
        detail: 'clipboard symbols are unavailable',
      );
    }
  }

  Never _fail(String function) => throw ClipboardException(
        backend: 'win32',
        operation: function,
        reason: 'the call returned a failure code',
      );
}
