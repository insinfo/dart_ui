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
///
/// ## HTML and images
///
/// Windows has no `text/html` and no `image/png`, so both are spelled the way
/// the applications that matter spell them (`win32_clipboard_formats.dart`
/// does the translating, in pure Dart, where it is tested):
///
///  * **HTML** is the registered format `HTML Format` - UTF-8 behind a header
///    of byte offsets - written together with `CF_UNICODETEXT`, so a paste
///    into Notepad still gets the words;
///  * **an image** is written as the registered `PNG` format, which browsers,
///    Office and image editors read and which keeps the alpha channel, **and**
///    as `CF_DIB`, which every Windows application since 3.0 reads. It is read
///    back from `PNG` when present, then `CF_DIBV5`, then `CF_DIB` - Windows
///    synthesises the latter from `CF_BITMAP`, which is what PrintScreen puts
///    there - and a bitmap is converted to PNG on the way out.
///
/// The conversions happen with the clipboard **closed**: the lock is held only
/// to copy bytes in or out, because every other application on the desktop
/// waits on it.
///
/// **Verification.** The CF_HTML header and the DIB conversion are unit-tested
/// on every platform (`win32_clipboard_formats_test.dart`). The FFI calls in
/// this file have only run where the text clipboard's have - the round trip in
/// `win32_clipboard_test.dart` is skipped off Windows - so HTML and images
/// through a real Windows clipboard are, as of 13/10/2026, unproven.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../graphics/image/image_errors.dart';
import '../../platform/clipboard.dart';
import '../../platform/clipboard_formats.dart';
import 'win32_api.dart';
import 'win32_clipboard_formats.dart';
import 'win32_constants.dart';

final class Win32Clipboard implements RichClipboard {
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

  @override
  Future<Set<ClipboardFormat>> availableFormats() async {
    _requireRich('availableFormats');
    // IsClipboardFormatAvailable does not take the lock, so this cannot fail
    // because another process holds it - which is exactly why a paste menu
    // should use it instead of a read.
    bool has(int format) =>
        format != 0 && api.isClipboardFormatAvailable!(format) != 0;
    return <ClipboardFormat>{
      if (has(cfUnicodeText)) ClipboardFormat.text,
      if (has(_format(win32HtmlFormatName))) ClipboardFormat.html,
      if (has(_format(win32PngFormatName)) || has(cfDibV5) || has(cfDib))
        ClipboardFormat.image,
    };
  }

  @override
  Future<String?> readHtml() async {
    _requireRich('readHtml');
    final int format = _format(win32HtmlFormatName);
    _open();
    final Uint8List? bytes;
    try {
      bytes = _readBytes(format);
    } finally {
      api.closeClipboard!();
    }
    return bytes == null ? null : decodeCfHtml(bytes);
  }

  @override
  Future<void> writeHtml(String html, {String? plainText}) async {
    _requireRich('writeHtml');
    final int format = _format(win32HtmlFormatName);
    final Uint8List framed = encodeCfHtml(html);
    final String text = plainText ?? plainTextFromHtml(html);
    _open();
    try {
      if (api.emptyClipboard!() == 0) _fail('EmptyClipboard');
      _setBytes(format, framed, nulTerminated: true);
      _setUnicodeText(text);
    } finally {
      api.closeClipboard!();
    }
  }

  @override
  Future<Uint8List?> readImage() async {
    _requireRich('readImage');
    final int pngFormat = _format(win32PngFormatName);
    _open();
    Uint8List? png;
    Uint8List? dib;
    try {
      png = pngFormat == 0 ? null : _readBytes(pngFormat);
      // A writer that registered "PNG" and put something else under it is not
      // trusted over the bitmap Windows can vouch for.
      if (png != null && !isPngData(png)) png = null;
      if (png == null) dib = _readBytes(cfDibV5) ?? _readBytes(cfDib);
    } finally {
      api.closeClipboard!();
    }
    if (png != null) return png;
    if (dib == null) return null;
    try {
      return win32DibToPng(dib);
    } on FormatException catch (error) {
      throw ClipboardException(
        backend: 'win32',
        operation: 'readImage',
        reason: 'the clipboard holds a bitmap this backend cannot convert to '
            'PNG: ${error.message}',
      );
    }
  }

  @override
  Future<void> writeImage(Uint8List png) async {
    requirePngData(png);
    _requireRich('writeImage');
    final Uint8List dib;
    try {
      dib = win32PngToDib(png);
    } on ImageDecodeException catch (error) {
      throw ArgumentError.value(
          '${png.length} bytes', 'png', 'does not decode: ${error.message}');
    }
    final int pngFormat = _format(win32PngFormatName);
    if (pngFormat == 0) _fail('RegisterClipboardFormatW');
    _open();
    try {
      if (api.emptyClipboard!() == 0) _fail('EmptyClipboard');
      _setBytes(pngFormat, png);
      _setBytes(cfDib, dib);
    } finally {
      api.closeClipboard!();
    }
  }

  /// The identifier Windows assigned to a registered format, or 0.
  ///
  /// Not cached: `RegisterClipboardFormatW` is idempotent and cheap, and a
  /// cache would be one more piece of state to keep honest across a session
  /// whose format table nobody else in this process can change anyway.
  int _format(String name) {
    final Pointer<Uint16> wide = api.toUtf16(name);
    try {
      return api.registerClipboardFormat!(wide);
    } finally {
      api.heapRelease(wide);
    }
  }

  /// A copy of the block stored under [format], or null when there is none.
  /// The clipboard must be open.
  Uint8List? _readBytes(int format) {
    final int handle = api.getClipboardData!(format);
    if (handle == 0) return null;
    final int size = api.globalSize!(handle);
    final int address = api.globalLock!(handle);
    if (address == 0) return null;
    try {
      return Uint8List.fromList(
          Pointer<Uint8>.fromAddress(address).asTypedList(size));
    } finally {
      api.globalUnlock!(handle);
    }
  }

  /// Hands [bytes] to the clipboard under [format]. The clipboard must be open
  /// and emptied.
  void _setBytes(int format, Uint8List bytes, {bool nulTerminated = false}) {
    final int length = bytes.length + (nulTerminated ? 1 : 0);
    final int handle = api.globalAlloc!(gmemMoveable, length);
    if (handle == 0) _fail('GlobalAlloc');
    var owned = true;
    try {
      final int address = api.globalLock!(handle);
      if (address == 0) _fail('GlobalLock');
      final Uint8List view =
          Pointer<Uint8>.fromAddress(address).asTypedList(length);
      view.setAll(0, bytes);
      if (nulTerminated) view[bytes.length] = 0;
      api.globalUnlock!(handle);
      if (api.setClipboardData!(format, handle) == 0) {
        _fail('SetClipboardData');
      }
      // Windows owns a handle it accepted.
      owned = false;
    } finally {
      if (owned) api.globalFree!(handle);
    }
  }

  void _setUnicodeText(String value) {
    final Uint16List units = Uint16List(value.length + 1)
      ..setAll(0, value.codeUnits);
    _setBytes(cfUnicodeText, units.buffer.asUint8List());
  }

  void _requireRich(String operation) {
    _requireSupported();
    if (!api.richClipboardSupported) {
      throw ClipboardException(
        backend: 'win32',
        operation: operation,
        reason: 'RegisterClipboardFormatW, GlobalSize or '
            'IsClipboardFormatAvailable did not bind, so HTML and images '
            'cannot cross this clipboard; text still can',
      );
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
