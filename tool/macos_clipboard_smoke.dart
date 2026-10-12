/// Proves the macOS clipboard against the real pasteboard, with a witness.
///
/// The unit tests prove the protocol and the error mapping against a fake
/// channel; they cannot prove that text written here is text another
/// application reads, or the reverse. So every check below has a second
/// opinion from outside this process: `pbpaste` reads what [Clipboard.writeText]
/// wrote, and `pbcopy` writes what [Clipboard.readText] must then return.
///
/// The user's clipboard is saved before the first write and put back at the
/// end, as text - running a smoke on a developer machine should not cost them
/// what they had copied. (A non-text clipboard, an image say, is not restored:
/// `pbpaste` cannot read it back either.)
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

import 'package:dart_ui/dart_ui.dart';

Future<void> main() async {
  if (!Platform.isMacOS) {
    stderr.writeln(
        'MACOS_CLIPBOARD_SMOKE=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }

  final String saved = await _pbpaste();
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
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('MACOS_CLIPBOARD_SMOKE threw: $error')
      ..writeln(stackTrace);
    verdict = 'FAIL';
    if (reason.isEmpty) reason = 'threw ${error.runtimeType}';
  } finally {
    await _pbcopy(saved);
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
