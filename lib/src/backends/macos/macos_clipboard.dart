/// The macOS clipboard, through the AppKit host.
///
/// `NSPasteboard` lives in AppKit, and this backend keeps AppKit out of the
/// Dart process on purpose (ADR 0001): the process that owns AppKit is the
/// host, on its main thread. So the clipboard is a request to a host -
/// `CLIPBOARD_READ`, or `CLIPBOARD_APPEND` pieces and a `CLIPBOARD_WRITE` - and
/// the answer comes back on its stdout like everything else it says.
///
/// ## Which host
///
/// The clipboard belongs to the backend, not to a window, so it borrows a
/// host: the first open window whose host announced `clipboard`. Any of them
/// reaches the same general pasteboard. An application with no window open
/// has no host to ask, and says so by name rather than answering null - null
/// would read as "the clipboard is empty", which is the lie the port forbids.
///
/// ## Text as UTF-8 in base64
///
/// Base64 because the protocol is line based and a clipboard's text has
/// newlines in it; UTF-8 because that is the encoding both ends agree on
/// without negotiating. The host decodes into an `NSString` and writes it as
/// `NSPasteboardTypeString`, which is what every other application reads.
///
/// ## HTML and images, when the host announced `clipboard-rich`
///
/// The same trip with a type word: `CLIPBOARD_READ_TYPE png|html|formats` and
/// `CLIPBOARD_WRITE_TYPE png|html`. The conversions happen in the host,
/// because that is where AppKit is:
///
///  * an image is read as `public.png` when the pasteboard has one, and
///    otherwise any bitmap type `NSBitmapImageRep` decodes - TIFF from a
///    screenshot or from Preview, above all - is re-encoded as PNG there, so
///    this side only ever receives one encoding;
///  * an image is written as **PNG and TIFF**, because Preview's "New from
///    Clipboard" and plenty of older applications ask for TIFF first;
///  * HTML is `public.html`, written beside `NSPasteboardTypeString` so a
///    plain-text paste still works.
///
/// A host that did not announce `clipboard-rich` - one built before it - is
/// never sent the commands, because it would answer `UNKNOWN_COMMAND` and
/// leave the request to time out; the operation fails at once, by name.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../platform/clipboard.dart';
import '../../platform/clipboard_formats.dart';
import 'host_process.dart';
import 'host_protocol.dart';

/// Finds a host that can reach the pasteboard right now, or null.
typedef MacosClipboardChannelLookup = MacosClipboardChannel? Function();

/// [RichClipboard] over a [MacosClipboardChannel].
final class MacosClipboard implements RichClipboard {
  MacosClipboard(
    this._lookup, {
    this.timeout = const Duration(seconds: 5),
  });

  final MacosClipboardChannelLookup _lookup;

  /// How long a request may take before it is reported as failed.
  ///
  /// Five seconds because a promised pasteboard type is produced by the
  /// application that owns it, on demand, and that application may be busy.
  /// Past that, the user is better served by an error than by a frozen paste.
  final Duration timeout;

  static const String _backend = 'macos';

  @override
  Future<String?> readText() async {
    final MacosClipboardChannel channel = _channel('readText');
    final (HostClipboardResult, String) answer;
    try {
      answer = await channel.requestClipboardRead(timeout);
    } on Object catch (error) {
      throw _failure('readText', error);
    }
    final (HostClipboardResult result, String base64Text) = answer;
    switch (result) {
      case HostClipboardResult.none:
        return null;
      case HostClipboardResult.text:
        try {
          return utf8.decode(base64.decode(base64Text));
        } on FormatException catch (error) {
          throw ClipboardException(
            operation: 'readText',
            backend: _backend,
            reason: 'the host sent text that is not base64 of UTF-8: '
                '${error.message}',
          );
        }
      case HostClipboardResult.failed:
        throw const ClipboardException(
          operation: 'readText',
          backend: _backend,
          reason: 'the AppKit host could not read the general pasteboard',
        );
      case HostClipboardResult.written:
      case HostClipboardResult.data:
        throw ClipboardException(
          operation: 'readText',
          backend: _backend,
          reason: 'the host answered a text read with ${result.name}',
        );
    }
  }

  @override
  Future<void> writeText(String text) async {
    final MacosClipboardChannel channel = _channel('writeText');
    final HostClipboardResult result;
    try {
      result = await channel.requestClipboardWrite(
        base64.encode(utf8.encode(text)),
        timeout,
      );
    } on Object catch (error) {
      throw _failure('writeText', error);
    }
    if (result != HostClipboardResult.written) {
      throw ClipboardException(
        operation: 'writeText',
        backend: _backend,
        reason: result == HostClipboardResult.failed
            ? 'the general pasteboard refused the text'
            : 'the host answered a write with ${result.name}',
      );
    }
  }

  @override
  Future<Set<ClipboardFormat>> availableFormats() async {
    final String? list = await _readType('availableFormats', 'formats');
    if (list == null || list.isEmpty) return <ClipboardFormat>{};
    return <ClipboardFormat>{
      for (final String word in list.split(','))
        if (word == 'text')
          ClipboardFormat.text
        else if (word == 'html')
          ClipboardFormat.html
        else if (word == 'image')
          ClipboardFormat.image,
    };
  }

  @override
  Future<Uint8List?> readImage() async {
    final String? payload = await _readType('readImage', 'png');
    if (payload == null) return null;
    final Uint8List png = _decodeBase64('readImage', payload);
    if (!isPngData(png)) {
      throw const ClipboardException(
        operation: 'readImage',
        backend: _backend,
        reason: 'the host sent image bytes that are not a PNG file',
      );
    }
    return png;
  }

  @override
  Future<String?> readHtml() async {
    final String? payload = await _readType('readHtml', 'html');
    if (payload == null) return null;
    try {
      return utf8.decode(_decodeBase64('readHtml', payload));
    } on FormatException catch (error) {
      throw ClipboardException(
        operation: 'readHtml',
        backend: _backend,
        reason: 'the host sent HTML that is not UTF-8: ${error.message}',
      );
    }
  }

  @override
  Future<void> writeImage(Uint8List png) async {
    requirePngData(png);
    await _writeType('writeImage', 'png', base64.encode(png));
  }

  @override
  Future<void> writeHtml(String html, {String? plainText}) async {
    final String text = plainText ?? plainTextFromHtml(html);
    // Two base64 runs joined by '.', which is outside the base64 alphabet and
    // so splits them unambiguously on the host side.
    await _writeType(
      'writeHtml',
      'html',
      '${base64.encode(utf8.encode(html))}.${base64.encode(utf8.encode(text))}',
    );
  }

  /// A typed read: the payload on [HostClipboardResult.data], null on
  /// [HostClipboardResult.none].
  Future<String?> _readType(String operation, String type) async {
    final MacosClipboardChannel channel = _richChannel(operation);
    final (HostClipboardResult, String) answer;
    try {
      answer = await channel.requestClipboardReadType(type, timeout);
    } on Object catch (error) {
      throw _failure(operation, error);
    }
    final (HostClipboardResult result, String payload) = answer;
    switch (result) {
      case HostClipboardResult.none:
        return null;
      case HostClipboardResult.data:
        return payload;
      case HostClipboardResult.failed:
        throw ClipboardException(
          operation: operation,
          backend: _backend,
          reason: 'the AppKit host could not read $type from the general '
              'pasteboard (an image type that would not decode, or text that '
              'would not encode)',
        );
      case HostClipboardResult.text:
      case HostClipboardResult.written:
        throw ClipboardException(
          operation: operation,
          backend: _backend,
          reason: 'the host answered a $type read with ${result.name}',
        );
    }
  }

  Future<void> _writeType(String operation, String type, String payload) async {
    final MacosClipboardChannel channel = _richChannel(operation);
    final HostClipboardResult result;
    try {
      result = await channel.requestClipboardWriteType(type, payload, timeout);
    } on Object catch (error) {
      throw _failure(operation, error);
    }
    if (result != HostClipboardResult.written) {
      throw ClipboardException(
        operation: operation,
        backend: _backend,
        reason: result == HostClipboardResult.failed
            ? 'the general pasteboard refused the $type data (for an image: '
                'AppKit could not decode the PNG)'
            : 'the host answered a write with ${result.name}',
      );
    }
  }

  Uint8List _decodeBase64(String operation, String payload) {
    try {
      return base64.decode(payload);
    } on FormatException catch (error) {
      throw ClipboardException(
        operation: operation,
        backend: _backend,
        reason: 'the host sent a payload that is not base64: ${error.message}',
      );
    }
  }

  MacosClipboardChannel _richChannel(String operation) {
    final MacosClipboardChannel channel = _channel(operation);
    if (!channel.supportsRichClipboard) {
      throw ClipboardException(
        operation: operation,
        backend: _backend,
        reason: 'the running AppKit host predates HTML and image clipboard '
            'support (it did not announce clipboard-rich); rebuild it with '
            'lib/src/backends/macos/native/build_host.sh',
      );
    }
    return channel;
  }

  MacosClipboardChannel _channel(String operation) {
    final MacosClipboardChannel? channel = _lookup();
    if (channel == null) {
      throw ClipboardException(
        operation: operation,
        backend: _backend,
        reason: 'no AppKit host that supports the clipboard is running: the '
            'pasteboard is reached through a window\'s host process, and this '
            'application has no open window whose host announced it',
      );
    }
    return channel;
  }

  ClipboardException _failure(String operation, Object error) =>
      ClipboardException(
        operation: operation,
        backend: _backend,
        reason: error is TimeoutException
            ? 'the AppKit host did not answer within '
                '${timeout.inMilliseconds} ms'
            : error is StateError
                ? error.message
                : '$error',
      );
}
