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
/// ## Text only, as UTF-8 in base64
///
/// Base64 because the protocol is line based and a clipboard's text has
/// newlines in it; UTF-8 because that is the encoding both ends agree on
/// without negotiating. The host decodes into an `NSString` and writes it as
/// `NSPasteboardTypeString`, which is what every other application reads.
library;

import 'dart:async';
import 'dart:convert';

import '../../platform/clipboard.dart';
import 'host_process.dart';
import 'host_protocol.dart';

/// Finds a host that can reach the pasteboard right now, or null.
typedef MacosClipboardChannelLookup = MacosClipboardChannel? Function();

/// [Clipboard] over a [MacosClipboardChannel].
final class MacosClipboard implements Clipboard {
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
        throw const ClipboardException(
          operation: 'readText',
          backend: _backend,
          reason: 'the host answered a read as if it were a write',
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
