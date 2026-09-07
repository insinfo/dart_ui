@TestOn('browser')

/// The fixtures every DOM-backend test file shares: a container in the real
/// document, and one parsed face.
///
/// Not a test file - a helper, in the shape
/// `test/rendering/gpu/webgl/webgl_session.dart` established, and it keeps that
/// file's two rules for the same reasons:
///
///   * every file in this directory carries `@TestOn('browser')`, so a plain
///     `dart test` - which is what CI runs - never compiles them at all;
///   * [fontSkipReason] is a **string**, never a bool. A run that skipped has
///     to say why instead of looking like a run that passed. Here the thing
///     that can go missing is the font file: a browser test cannot open a path,
///     so it fetches, and a fetch depends on what the test server chose to
///     serve. Every caller prints the reason and passes it to
///     `markTestSkipped`.
///
/// ## Why the container is in the document and not detached
///
/// A detached subtree is never laid out, and half of what this backend is for
/// only exists once layout has happened: `getBoundingClientRect` answers zeroes,
/// `document.activeElement` cannot be moved into it, `window.getSelection`
/// refuses to anchor in it, and `TextMetrics` is unaffected but the spans that
/// use it are. Testing a DOM backend against a detached tree would assert the
/// markup and none of the behaviour.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// A live container, removed by [close].
final class DomTestHost {
  DomTestHost._(this.element);

  final web.HTMLElement element;

  /// Appends a container to the document body.
  ///
  /// Positioned and sized rather than left to flow, because the presenter
  /// positions its own host absolutely inside it and an unpositioned parent
  /// would send every element to the page origin - which is a real bug in the
  /// backend and would be invisible in a test whose container had no box.
  static DomTestHost open({double width = 800, double height = 600}) {
    final web.HTMLElement element =
        web.document.createElement('div') as web.HTMLElement;
    element.setAttribute(
      'style',
      'position:relative;left:0;top:0;'
          'width:${width}px;height:${height}px;overflow:hidden',
    );
    web.document.body!.append(element);
    return DomTestHost._(element);
  }

  void close() => element.remove();
}

/// The face the text tests draw with, or the reason there is none.
final class DomTestFont {
  DomTestFont._(this.typeface, this.skipReason);

  /// Null when the file could not be fetched or parsed. [skipReason] says
  /// which.
  final Typeface? typeface;

  final String? skipReason;

  static DomTestFont? _cached;

  /// Fetches and parses a face, once per page.
  ///
  /// The URL is **relative and climbs four levels**, which looks wrong and is
  /// the only thing that works. `dart test -p chrome` serves the page at
  /// `/<hash>/test/backends/web/dom/<file>.html`, so an absolute `/assets/...`
  /// misses the hash segment and answers 404 while `../../../../assets/...`
  /// resolves to the package root. Both were measured; the absolute form is
  /// kept in the list so that a future harness which serves the root directly
  /// still finds the file rather than skipping the whole suite.
  static Future<DomTestFont> load() async {
    final DomTestFont? cached = _cached;
    if (cached != null) return cached;
    const List<String> candidates = <String>[
      '../../../../assets/fonts/Roboto-Regular.ttf',
      '/assets/fonts/Roboto-Regular.ttf',
      '../../../../web/fonts/Roboto-Regular.ttf',
    ];
    final List<String> failures = <String>[];
    for (final String url in candidates) {
      try {
        final web.Response response = await web.window.fetch(url.toJS).toDart;
        if (!response.ok) {
          failures.add('$url -> HTTP ${response.status}');
          continue;
        }
        final JSArrayBuffer buffer = await response.arrayBuffer().toDart;
        final Uint8List bytes = buffer.toDart.asUint8List();
        if (bytes.isEmpty) {
          failures.add('$url -> empty');
          continue;
        }
        return _cached = DomTestFont._(Typeface.parse(bytes), null);
      } on Object catch (error) {
        failures.add('$url -> $error');
      }
    }
    return _cached = DomTestFont._(
      null,
      'no font could be fetched, so the glyph-run tests cannot run: '
      '${failures.join('; ')}',
    );
  }
}

/// The one place a skip is turned into a message.
///
/// Returns true when the caller should stop. Printing as well as marking,
/// because `markTestSkipped` is easy to miss in a long run and the whole point
/// of the string reason is that somebody reads it.
bool skipIfMissing(String? reason) {
  if (reason == null) return false;
  printOnFailure(reason);
  markTestSkipped(reason);
  return true;
}
