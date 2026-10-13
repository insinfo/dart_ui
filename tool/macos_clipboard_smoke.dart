/// Proves the macOS clipboard against the real pasteboard, with a witness.
///
/// The unit tests prove the protocol and the error mapping against a fake
/// channel; they cannot prove that text written here is text another
/// application reads, or the reverse. So every check below has a second
/// opinion from outside this process: `pbpaste` reads what [Clipboard.writeText]
/// wrote, and `pbcopy` writes what [Clipboard.readText] must then return.
///
/// HTML and images (`RichClipboard`, since 13/10/2026) have a witness too, and
/// a stricter one: `osascript -l JavaScript` drives `NSPasteboard` through the
/// Objective-C bridge from a separate process, reading back the exact
/// `public.png`/`public.html` bytes this backend wrote and putting
/// `public.png`, `public.tiff` or `public.html` there for it to read. The TIFF
/// case is the one that matters most: a screenshot or a copy from Preview is
/// TIFF, and the host has to convert it to PNG.
///
/// The user's clipboard is saved before the first write and put back at the
/// end, as text - running a smoke on a developer machine should not cost them
/// what they had copied. An empty pasteboard is put back empty. (A non-text
/// clipboard, an image say, is not restored: `pbpaste` cannot read it back
/// either.)
///
/// ```
/// bash lib/src/backends/macos/native/build_host.sh
/// DART_UI_MACOS_HOST=lib/src/backends/macos/native/build/dart_ui_macos_host \
///   dart run tool/macos_clipboard_smoke.dart
/// ```
///
/// Exits 0 on `MACOS_CLIPBOARD_SMOKE=PASS`, 1 on `=FAIL`, and 2 off macOS.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';

Future<void> main() async {
  if (!Platform.isMacOS) {
    stderr.writeln(
        'MACOS_CLIPBOARD_SMOKE=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }

  final String saved = await _pbpaste();
  final bool savedEmpty = (await _pasteboardTypes()).isEmpty;
  var verdict = 'PASS';
  var reason = '';
  void record(String key, bool passed, String detail) {
    stdout.writeln('$key=${passed ? 'PASS' : 'FAIL'} $detail');
    if (!passed && verdict == 'PASS') {
      verdict = 'FAIL';
      reason = key;
    }
  }

  Application? application;
  try {
    application = await Application.start(
      rootWidget: const ColoredBox(color: Color(0xFF1B1D21)),
      backends: PlatformBackendResolver.defaultBackends(),
      presentations: PlatformBackendResolver.defaultPresentations(),
      options: ApplicationOptions(
        title: 'dart_ui clipboard smoke',
        size: const Size(200, 120),
        visible: false,
        environment: Platform.environment,
      ),
    );
    final Application app = application;
    final Clipboard clipboard = app.clipboard;
    stdout.writeln('CLIPBOARD_BACKEND backend=${app.backend.name} '
        'clipboard=${clipboard.runtimeType}');

    // --- written here, read by another process ------------------------------
    const String accented = 'olá, mundo\n— segunda linha\tcom tab 🌍';
    await clipboard.writeText(accented);
    final String seen = await _pbpaste();
    record('CLIPBOARD_WRITE', seen == accented,
        'chars=${accented.length} pbpasteMatches=${seen == accented}');

    // --- written by another process, read here ------------------------------
    const String foreign = 'from pbcopy: ação\r\nCRLF kept';
    await _pbcopy(foreign);
    final String? read = await clipboard.readText();
    record('CLIPBOARD_READ', read == foreign,
        'chars=${foreign.length} matches=${read == foreign}');

    // --- larger than one protocol line, both ways ----------------------------
    // Several 6000-character base64 pieces each way, with a multi-byte
    // character on what would be a piece boundary if pieces were cut in bytes
    // of text rather than characters of base64.
    final String large =
        List<String>.generate(4000, (int i) => 'linha $i ç\n').join();
    await clipboard.writeText(large);
    final String largeSeen = await _pbpaste();
    final String? largeRead = await clipboard.readText();
    final int bytes = utf8.encode(large).length;
    record(
        'CLIPBOARD_LARGE',
        largeSeen == large && largeRead == large,
        'bytes=$bytes base64Pieces=${(base64.encode(utf8.encode(large)).length / 6000).ceil()} '
            'pbpasteMatches=${largeSeen == large} readMatches=${largeRead == large}');

    // --- the empty string is text, not "no clipboard" ------------------------
    await clipboard.writeText('');
    final String? empty = await clipboard.readText();
    record('CLIPBOARD_EMPTY', empty == '',
        'read=${empty == null ? 'null' : '"$empty"'}');

    if (clipboard is! RichClipboard) {
      record('CLIPBOARD_RICH', false, 'type=${clipboard.runtimeType}');
    } else {
      await _richChecks(clipboard, record);
    }
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('MACOS_CLIPBOARD_SMOKE threw: $error')
      ..writeln(stackTrace);
    verdict = 'FAIL';
    if (reason.isEmpty) reason = 'threw ${error.runtimeType}';
  } finally {
    if (savedEmpty) {
      await _pasteboardClear();
    } else {
      await _pbcopy(saved);
    }
    final Application? app = application;
    if (app != null) {
      app.dispose();
      await app.closed;
    }
  }

  stdout.writeln(
      'MACOS_CLIPBOARD_SMOKE=$verdict${verdict == 'PASS' ? '' : ' $reason'}');
  exitCode = verdict == 'PASS' ? 0 : 1;
}

Future<String> _pbpaste() async {
  final ProcessResult result =
      await Process.run('pbpaste', const <String>[], stdoutEncoding: utf8);
  return result.stdout as String;
}

Future<void> _pbcopy(String text) async {
  final Process process = await Process.start('pbcopy', const <String>[]);
  process.stdin.add(utf8.encode(text));
  await process.stdin.close();
  await process.exitCode;
}

/// Images and HTML, each direction witnessed through `NSPasteboard` in
/// another process.
Future<void> _richChecks(
  RichClipboard clipboard,
  void Function(String key, bool passed, String detail) record,
) async {
  // Translucent, so the alpha channel has to survive; and not square, so a
  // transposed width and height cannot pass.
  final Uint8List translucent = _image(64, 40, (int x, int y) {
    return (x * 4) << 16 | (y * 6) << 8 | 0x80 | 0x7F << 24;
  });
  final Uint8List opaque = _image(48, 30, (int x, int y) {
    return 0xFF000000 | (x * 5) << 16 | (255 - y * 8) << 8 | (x ^ y) & 0xFF;
  });

  // --- an image written here, read by another process ----------------------
  await clipboard.writeImage(translucent);
  final List<String> types = await _pasteboardTypes();
  final Uint8List? seenPng = await _pasteboardData('public.png');
  record(
      'CLIPBOARD_IMAGE_WRITE',
      seenPng != null &&
          _same(seenPng, translucent) &&
          types.contains('public.tiff') &&
          !types.contains('public.utf8-plain-text'),
      'bytes=${translucent.length} types=${types.join(',')} '
          'pngMatches=${seenPng != null && _same(seenPng, translucent)}');
  final Set<ClipboardFormat> imageFormats = await clipboard.availableFormats();
  record(
      'CLIPBOARD_FORMATS_IMAGE',
      imageFormats.length == 1 && imageFormats.contains(ClipboardFormat.image),
      'formats=${imageFormats.map((f) => f.name).join(',')}');
  final String? noText = await clipboard.readText();
  record('CLIPBOARD_IMAGE_HAS_NO_TEXT', noText == null,
      'readText=${noText == null ? 'null' : '"$noText"'}');

  // --- a PNG written by another process, read here -------------------------
  await _pasteboardSet(<String, Uint8List>{'public.png': opaque});
  final Uint8List? readPng = await clipboard.readImage();
  record('CLIPBOARD_IMAGE_READ_PNG', readPng != null && _same(readPng, opaque),
      'bytes=${readPng?.length} matches=${readPng != null && _same(readPng, opaque)}');

  // --- only TIFF on the pasteboard: the host converts --------------------
  final Uint8List tiff = await _toTiff(opaque);
  await _pasteboardSet(<String, Uint8List>{'public.tiff': tiff});
  final Uint8List? converted = await clipboard.readImage();
  final bool pixelsMatch =
      converted != null && _samePixels(decodePng(converted), decodePng(opaque));
  record(
      'CLIPBOARD_IMAGE_READ_TIFF',
      converted != null && isPng(converted) && pixelsMatch,
      'tiffBytes=${tiff.length} pngBytes=${converted?.length} '
          'pixelsMatch=$pixelsMatch');

  // --- HTML written here, read by another process -------------------------
  const String html = '<p>olá <b>mundo</b> &amp; 🌍</p>';
  await clipboard.writeHtml(html, plainText: 'olá mundo & 🌍');
  final Uint8List? seenHtml = await _pasteboardData('public.html');
  final String plain = await _pbpaste();
  record(
      'CLIPBOARD_HTML_WRITE',
      seenHtml != null &&
          utf8.decode(seenHtml) == html &&
          plain == 'olá mundo & 🌍',
      'htmlMatches=${seenHtml != null && utf8.decode(seenHtml) == html} '
          'pbpaste="$plain"');
  final Set<ClipboardFormat> htmlFormats = await clipboard.availableFormats();
  record(
      'CLIPBOARD_FORMATS_HTML',
      htmlFormats.length == 2 &&
          htmlFormats.containsAll(
              <ClipboardFormat>[ClipboardFormat.html, ClipboardFormat.text]),
      'formats=${htmlFormats.map((f) => f.name).join(',')}');
  await clipboard.writeHtml('<h1>Título</h1><p>corpo</p>');
  final String derived = await _pbpaste();
  record('CLIPBOARD_HTML_DERIVED_TEXT', derived == 'Título\n\ncorpo',
      'pbpaste="${derived.replaceAll('\n', '\\n')}"');

  // --- HTML written by another process, read here ------------------------
  const String foreign = '<html><body><i>de fora</i> çã</body></html>';
  await _pasteboardSet(<String, Uint8List>{
    'public.html': Uint8List.fromList(utf8.encode(foreign))
  });
  final String? readHtml = await clipboard.readHtml();
  final Uint8List? noImage = await clipboard.readImage();
  record('CLIPBOARD_HTML_READ', readHtml == foreign && noImage == null,
      'matches=${readHtml == foreign} readImage=${noImage == null ? 'null' : 'bytes'}');

  // --- a large image, both ways --------------------------------------------
  // Noise does not compress, so this is megabytes of base64 in hundreds of
  // protocol lines each way - inside the five-second request timeout or not.
  int seed = 0x2545F491;
  final Uint8List noisy = _image(1024, 768, (int x, int y) {
    seed ^= seed << 13 & 0xFFFFFFFF;
    seed ^= seed >> 17;
    seed ^= seed << 5 & 0xFFFFFFFF;
    return 0xFF000000 | seed & 0xFFFFFF;
  });
  final Stopwatch timer = Stopwatch()..start();
  await clipboard.writeImage(noisy);
  final int writeMs = timer.elapsedMilliseconds;
  final Uint8List? noisySeen = await _pasteboardData('public.png');
  timer.reset();
  final Uint8List? noisyRead = await clipboard.readImage();
  final int readMs = timer.elapsedMilliseconds;
  record(
      'CLIPBOARD_IMAGE_LARGE',
      noisySeen != null &&
          _same(noisySeen, noisy) &&
          noisyRead != null &&
          _same(noisyRead, noisy),
      'bytes=${noisy.length} writeMs=$writeMs readMs=$readMs');

  // --- text replaces an image ----------------------------------------------
  await clipboard.writeImage(opaque);
  await clipboard.writeText('só texto');
  final Uint8List? gone = await clipboard.readImage();
  final String? goneHtml = await clipboard.readHtml();
  record(
      'CLIPBOARD_TEXT_REPLACES_RICH',
      gone == null && goneHtml == null,
      'readImage=${gone == null ? 'null' : 'bytes'} '
          'readHtml=${goneHtml == null ? 'null' : 'text'}');
}

Uint8List _image(int width, int height, int Function(int x, int y) argb) {
  final Uint8List rgba = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int value = argb(x, y);
      final int offset = (y * width + x) * 4;
      rgba[offset] = value >> 16 & 0xFF;
      rgba[offset + 1] = value >> 8 & 0xFF;
      rgba[offset + 2] = value & 0xFF;
      rgba[offset + 3] = value >> 24 & 0xFF;
    }
  }
  return encodePng(width: width, height: height, pixels: rgba);
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _samePixels(DecodedImage a, DecodedImage b) {
  if (a.width != b.width || a.height != b.height) return false;
  for (int y = 0; y < a.height; y++) {
    for (int x = 0; x < a.width; x++) {
      if (a.argbAt(x, y) != b.argbAt(x, y)) return false;
    }
  }
  return true;
}

/// [png] as TIFF, converted by `sips` - AppKit's own codecs, but in another
/// process, so the TIFF is not one this backend produced.
Future<Uint8List> _toTiff(Uint8List png) async {
  final Directory scratch =
      await Directory.systemTemp.createTemp('dart_ui_clipboard_smoke');
  try {
    final File source = File('${scratch.path}/in.png');
    await source.writeAsBytes(png);
    final String target = '${scratch.path}/out.tiff';
    final ProcessResult result = await Process.run(
        'sips', <String>['-s', 'format', 'tiff', source.path, '--out', target]);
    if (result.exitCode != 0) {
      throw StateError('sips failed: ${result.stderr}');
    }
    return File(target).readAsBytes();
  } finally {
    await scratch.delete(recursive: true);
  }
}

// --- the witness: NSPasteboard from another process, through JXA ----------

Future<String> _jxa(String script,
    [List<String> args = const <String>[]]) async {
  final ProcessResult result = await Process.run(
    'osascript',
    <String>['-l', 'JavaScript', '-e', script, ...args],
    stdoutEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('osascript failed: ${result.stderr}');
  }
  return (result.stdout as String).trimRight();
}

Future<List<String>> _pasteboardTypes() async {
  final String joined = await _jxa(r"""
ObjC.import('AppKit');
var types = $.NSPasteboard.generalPasteboard.types;
var out = [];
for (var i = 0; i < types.count; i++) out.push(types.objectAtIndex(i).js);
out.join(',');
""");
  return joined.isEmpty ? <String>[] : joined.split(',');
}

Future<Uint8List?> _pasteboardData(String type) async {
  final String encoded = await _jxa(r"""
function run(argv) {
  ObjC.import('AppKit');
  var data = $.NSPasteboard.generalPasteboard.dataForType(argv[0]);
  if (data.isNil()) return '-';
  return data.base64EncodedStringWithOptions(0).js;
}
""", <String>[type]);
  return encoded == '-' ? null : base64.decode(encoded);
}

Future<void> _pasteboardSet(Map<String, Uint8List> items) async {
  final List<String> args = <String>[
    for (final MapEntry<String, Uint8List> item in items.entries) ...<String>[
      item.key,
      base64.encode(item.value),
    ],
  ];
  await _jxa(r"""
function run(argv) {
  ObjC.import('AppKit');
  var pb = $.NSPasteboard.generalPasteboard;
  pb.clearContents;
  for (var i = 0; i < argv.length; i += 2) {
    var data = $.NSData.alloc.initWithBase64EncodedStringOptions(argv[i + 1], 0);
    pb.setDataForType(data, argv[i]);
  }
  return 'ok';
}
""", args);
}

Future<void> _pasteboardClear() async {
  await _jxa(r"""
ObjC.import('AppKit');
$.NSPasteboard.generalPasteboard.clearContents;
'ok';
""");
}
