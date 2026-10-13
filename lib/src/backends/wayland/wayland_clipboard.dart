/// The portable clipboard facade over a Wayland data-device connection.
///
/// Text goes through [WaylandSelectionClient]; HTML and images through
/// [WaylandMimeSelectionClient], as the MIME types every Wayland toolkit uses
/// for them - `text/html` and `image/png`. An HTML copy offers the text MIME
/// types too, with a plain-text alternative behind them, so a terminal pasting
/// it still gets the words.
///
/// **Verification.** Against the fake compositor in
/// `test/backends/wayland/wayland_connection_test.dart` only: as of 13/10/2026
/// no HTML or image has crossed a real compositor.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../platform/clipboard.dart';
import '../../platform/clipboard_formats.dart';
import 'wayland_connection.dart';
import 'wayland_protocol.dart';

/// Adapts [WaylandSelectionClient]'s protocol operations to the application
/// clipboard contract.
final class WaylandClipboard implements RichClipboard {
  const WaylandClipboard(this.client);

  final WaylandSelectionClient client;

  @override
  Future<String?> readText() => client.readClipboardText();

  @override
  Future<void> writeText(String text) async => client.setClipboardText(text);

  @override
  Future<Set<ClipboardFormat>> availableFormats() async =>
      clipboardFormatsForMimes(
        _rich('availableFormats').clipboardMimeTypes,
        textMimes: wlClipboardAcceptedTextMimes,
      );

  @override
  Future<Uint8List?> readImage() async {
    final Uint8List? png =
        await _rich('readImage').readClipboardMime(clipboardPngMime);
    if (png != null && !isPngData(png)) {
      throw ClipboardException(
        operation: 'readImage',
        backend: 'wayland',
        reason: 'the selection owner sent ${png.length} bytes as image/png '
            'that are not a PNG file',
      );
    }
    return png;
  }

  @override
  Future<void> writeImage(Uint8List png) async {
    requirePngData(png);
    _rich('writeImage').setClipboardData(<String, Uint8List>{
      clipboardPngMime: Uint8List.fromList(png),
    });
  }

  @override
  Future<String?> readHtml() async {
    final WaylandMimeSelectionClient rich = _rich('readHtml');
    // `text/html` itself first; a charset-qualified spelling only when that is
    // all the owner offers.
    final Set<String> offered = rich.clipboardMimeTypes;
    final String? mime = offered.contains(clipboardHtmlMime)
        ? clipboardHtmlMime
        : offered.where(isHtmlMime).firstOrNull;
    if (mime == null) return null;
    final Uint8List? bytes = await rich.readClipboardMime(mime);
    return bytes == null ? null : decodeClipboardHtml(bytes);
  }

  @override
  Future<void> writeHtml(String html, {String? plainText}) async {
    final Uint8List text =
        Uint8List.fromList(utf8.encode(plainText ?? plainTextFromHtml(html)));
    _rich('writeHtml').setClipboardData(<String, Uint8List>{
      clipboardHtmlMime: Uint8List.fromList(utf8.encode(html)),
      for (final String mime in wlClipboardAcceptedTextMimes) mime: text,
    });
  }

  WaylandMimeSelectionClient _rich(String operation) {
    final WaylandSelectionClient candidate = client;
    if (candidate is WaylandMimeSelectionClient) return candidate;
    throw ClipboardException(
      operation: operation,
      backend: 'wayland',
      reason: 'this selection client carries text only '
          '(${candidate.runtimeType} is not a WaylandMimeSelectionClient)',
    );
  }
}
