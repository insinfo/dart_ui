/// Getting a typeface into the framework when there is no filesystem.
///
/// ## Why the system font index cannot work here
///
/// `lib/src/platform/system_fonts.dart` finds the fonts already installed by
/// walking `C:\Windows\Fonts`, `/usr/share/fonts` and `/System/Library/Fonts`
/// and reading the `name` table out of each file. Its opening paragraph gives
/// the reason a framework does that rather than shipping a face: fonts are
/// separately licensed, and bundling one means shipping megabytes to draw text
/// in a face the user did not choose.
///
/// A browser offers none of that. There is no directory to walk, no way to
/// enumerate the installed fonts (deliberately - it is a fingerprinting vector
/// every browser has closed), and no way to read the bytes of one even when its
/// name is known. `document.fonts` can *use* a font for DOM text, but this
/// framework rasterises glyph outlines itself and needs the file.
///
/// So on the web the application supplies the bytes. That is not a workaround;
/// it is the only thing the platform allows, and it is what every canvas-based
/// application does.
///
/// ## What "no font" looks like, and why it is not a crash
///
/// If nothing is registered, [FontRegistry.hasUiFont] is false and every label
/// draws blank while every box, border and fill draws normally. That is the
/// framework behaving correctly - `GpuRasterSink` refuses a glyph run it has no
/// face for by name rather than inventing one - but it is visually
/// indistinguishable from a text layout bug, which is why [loadWebTypeface]
/// reports its failures loudly and why the entrypoint should say so when the
/// load fails.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../rendering/text/font_registry.dart';
import '../../text/typeface.dart';

/// Fetches [url] and parses it as a font file.
///
/// Returns null rather than throwing, and the reason is on the returned record:
/// a missing font is a condition an application decides about - a gallery draws
/// blank labels and says so, an application with its own bundled face treats it
/// as fatal - and it is not the kind of thing that should unwind a `main`.
///
/// The fetch is a plain `fetch`, so the usual rules apply and are worth stating
/// because both bite:
///
///   * **Same origin, or CORS.** A font on another origin needs
///     `Access-Control-Allow-Origin`. This is the common failure when a page
///     works locally and not when deployed.
///   * **`file://` is not an origin.** Chrome refuses `fetch` from a page
///     opened as a file unless it was started with
///     `--allow-file-access-from-files`. Serving the directory over HTTP is the
///     ordinary answer.
Future<({Typeface? face, String? failure})> loadWebTypeface(String url) async {
  final web.Response response;
  try {
    response = await web.window.fetch(url.toJS).toDart;
  } on Object catch (error) {
    return (
      face: null,
      failure: 'fetching $url threw: $error. A page opened as a file:// URL '
          'cannot fetch at all unless Chrome was started with '
          '--allow-file-access-from-files; serve the directory over HTTP '
          'instead',
    );
  }
  if (!response.ok) {
    return (
      face: null,
      failure: 'fetching $url answered HTTP ${response.status} '
          '${response.statusText}',
    );
  }

  final Uint8List bytes;
  try {
    final JSArrayBuffer buffer = await response.arrayBuffer().toDart;
    // Through the JS view rather than assuming the buffer aliases Dart memory:
    // under dart2wasm it does not, and a backend that assumed it did would
    // parse an empty font and report a corrupt file.
    bytes = buffer.toDart.asUint8List();
  } on Object catch (error) {
    return (face: null, failure: 'reading the bytes of $url threw: $error');
  }
  if (bytes.isEmpty) {
    return (face: null, failure: '$url is empty');
  }

  try {
    return (face: Typeface.parse(bytes), failure: null);
  } on Object catch (error) {
    return (
      face: null,
      failure: 'parsing $url as a font failed: $error. This framework parses '
          'TrueType and OpenType outlines itself, so a WOFF or WOFF2 file - '
          'which is the format a web page normally uses - will not load. '
          'Serve the .ttf or .otf',
    );
  }
}

/// Loads [url] and makes it the UI font, answering what went wrong if it did
/// not.
///
/// Null on success. The string on failure is meant to be shown or logged
/// verbatim: it names the URL and the reason, which is the difference between
/// "the font did not load" and an afternoon.
Future<String?> useWebUiFont(
  String url, {
  FontRegistry? registry,
}) async {
  final ({Typeface? face, String? failure}) result = await loadWebTypeface(url);
  final Typeface? face = result.face;
  if (face == null) return result.failure ?? 'loading $url failed';
  (registry ?? FontRegistry.instance).useTypeface(face, source: url);
  return null;
}
