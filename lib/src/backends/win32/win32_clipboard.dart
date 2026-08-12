/// Unicode text clipboard adapter using user32/kernel32 directly.
library;

import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import 'win32_api.dart';
import 'win32_constants.dart';

final class Win32Clipboard {
  const Win32Clipboard(this.api);

  final Win32Api api;

  bool get isSupported => api.clipboardSupported;

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

  Future<String?> readText() async {
    _requireSupported();
    _open();
    try {
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
        return String.fromCharCodes(units);
      } finally {
        api.globalUnlock!(handle);
      }
    } finally {
      api.closeClipboard!();
    }
  }

  void _open() {
    if (api.openClipboard!(0) == 0) _fail('OpenClipboard');
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

  Never _fail(String function) => throw StateError('$function failed');
}
