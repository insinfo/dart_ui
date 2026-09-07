/// Has a client this project did not write paste a large payload out of us.
///
/// ## Why a second connection from this process would not do
///
/// `test/backends/x11/x11_clipboard_test.dart` drives the INCR owner against
/// a fake requestor and reaches the cases no real client produces on demand -
/// a requestor that stops reading, a payload that is an exact multiple of the
/// chunk size, two conversions at once. What it cannot do is disagree with us.
/// If this project misread ICCCM about *when* the requestor deletes the
/// property, a requestor written from the same misreading deletes it at the
/// same wrong moment and the two halves agree perfectly while every real
/// application hangs. That bias survives any number of in-process tests,
/// including one opening a second X connection: same authors, same reading.
///
/// So the interop half is `xclip`, which was written by somebody else against
/// the same specification, and the assertion is byte equality over a payload
/// far past what one `ChangeProperty` can carry.
///
/// ## What it proves, and what it does not
///
/// Proves: a stranger asking for `CLIPBOARD` as `UTF8_STRING` receives every
/// byte, in order, through the INCR protocol - the `INCR` announcement, one
/// chunk per `PropertyNotify(Deleted)`, the zero-length terminator - and that
/// the transfer really was incremental rather than fitting in one property
/// after all ([X11ClipboardManager.incrementalTransfersStarted]).
///
/// Does not prove: that GTK or Qt behave like `xclip`. They use the same
/// protocol and different code, and this repository has never been pasted
/// from by either.
///
/// The read direction is reported too, and **never fails this run**: the
/// reader half was already implemented and is not what this smoke was written
/// to change, so a regression there must be attributable to whoever touches
/// it rather than to this file.
///
/// ```
/// DISPLAY=:99 dart run tool/x11_clipboard_interop_smoke.dart
/// ```
///
/// Exit 0 when the round trip matched, 1 when it did not, 2 when this machine
/// cannot host the run - no Linux, no display, no `xclip`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/x11/x11_backend.dart';
import 'package:dart_ui/src/backends/x11/x11_clipboard.dart';

/// A payload chosen to break three things at once if they are broken.
///
///   * far past [X11ClipboardManager.defaultSingleShotBytes], so the INCR
///     branch is the only way it can be served;
///   * **not** a multiple of the chunk size, because the exact-multiple case
///     is covered by the unit suite and this one should differ from it;
///   * multi-byte UTF-8 throughout, so any place that confuses a character
///     count with a byte count truncates visibly instead of by one character
///     in a million.
String _payload() {
  const String unit = 'linha ção—λ 0123456789 ';
  final StringBuffer buffer = StringBuffer();
  var line = 0;
  while (buffer.length < 900 * 1024) {
    buffer.write('${line++} $unit\n');
  }
  return buffer.toString();
}

Future<void> main() async {
  if (!Platform.isLinux) {
    stderr
        .writeln('X11_CLIP_INTEROP=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }
  if ((Platform.environment['DISPLAY'] ?? '').isEmpty) {
    stderr.writeln('X11_CLIP_INTEROP=SKIP reason=DISPLAY is not set');
    exitCode = 2;
    return;
  }
  final String? xclip = _which('xclip');
  if (xclip == null) {
    stderr.writeln('X11_CLIP_INTEROP=SKIP reason=xclip is not on PATH; the '
        'interop half needs a clipboard client this project did not write');
    exitCode = 2;
    return;
  }

  final backend = X11WindowingBackend();
  Object? failure;
  StackTrace? stack;
  try {
    await backend.initialize().timeout(const Duration(seconds: 10));
    final NativeWindow window = await backend
        .createWindow(const WindowOptions(
          size: Size(200, 120),
          title: 'dart_ui X11 clipboard interop smoke',
        ))
        .timeout(const Duration(seconds: 10));

    // Selections need a mapped window and a server timestamp, and the
    // timestamp comes from an event: taking ownership before the first one
    // arrives uses CurrentTime, which a strict server ignores.
    var exposed = false;
    final subscription =
        window.events.listen((event) => exposed |= event is WindowExposedEvent);
    try {
      await _pump(backend, () => exposed, const Duration(seconds: 5));

      final Clipboard clipboard = backend.clipboard;
      final X11ClipboardManager manager = (clipboard as X11Clipboard).manager;
      final String payload = _payload();
      final int bytes = utf8.encode(payload).length;
      stdout.writeln('X11_CLIP_PAYLOAD bytes=$bytes '
          'single_shot_limit=${X11ClipboardManager.defaultSingleShotBytes} '
          'chunk=${X11ClipboardManager.defaultChunkBytes}');
      if (bytes <= X11ClipboardManager.defaultSingleShotBytes) {
        throw StateError('the payload would fit in one ChangeProperty, so '
            'this run would not exercise INCR at all');
      }

      await clipboard.writeText(payload).timeout(const Duration(seconds: 5));
      await _reportPasteOut(backend, manager, xclip, payload, bytes);
      await _reportPasteIn(backend, clipboard, xclip);
    } finally {
      await subscription.cancel();
      window.close();
    }
  } on Object catch (error, trace) {
    failure = error;
    stack = trace;
  }

  try {
    await backend.shutdown().timeout(const Duration(seconds: 10));
  } on Object catch (error, trace) {
    failure ??= error;
    stack ??= trace;
  }

  final Object? captured = failure;
  if (captured != null) {
    stdout.writeln('X11_CLIP_INTEROP=FAIL $captured');
    Error.throwWithStackTrace(captured, stack ?? StackTrace.current);
  }
  stdout.writeln('X11_CLIP_INTEROP=PASS');
}

/// `xclip -o` pastes from us. This is the direction the INCR owner serves.
Future<void> _reportPasteOut(
  X11WindowingBackend backend,
  X11ClipboardManager manager,
  String xclip,
  String payload,
  int bytes,
) async {
  final int startedBefore = manager.incrementalTransfersStarted;
  final _Capture capture = await _runPumping(
    backend,
    xclip,
    const <String>['-selection', 'clipboard', '-o'],
    const Duration(seconds: 20),
  );

  final int started = manager.incrementalTransfersStarted - startedBefore;
  final String got = utf8.decode(capture.stdout, allowMalformed: true);
  final bool identical = got == payload;
  final int prefix = _commonPrefix(got, payload);
  stdout.writeln(
    'X11_CLIP_INCR_OUT=${identical && started > 0 ? 'PASS' : 'FAIL'} '
    'sent=$bytes received=${capture.stdout.length} '
    'incr_transfers=$started exit=${capture.exitCode} '
    'first_difference=${identical ? 'none' : prefix} '
    'pending_after=${manager.pendingTransferCount}',
  );
  if (capture.stderr.isNotEmpty) {
    stdout.writeln('X11_CLIP_INCR_OUT_STDERR ${capture.stderr.trim()}');
  }
  if (!identical) {
    // A truncation is the failure this whole feature exists to prevent, so it
    // is named as one rather than left to a byte count the reader must compare.
    throw StateError(got.length < payload.length
        ? 'xclip received ${got.length} of ${payload.length} characters: the '
            'paste was truncated at $prefix'
        : 'xclip received bytes that differ from what was copied, first at '
            '$prefix');
  }
  if (started == 0) {
    throw StateError('the payload round-tripped without starting an INCR '
        'transfer, so this run proved the single-shot path twice');
  }
}

/// `xclip -i` copies into us, and we read it back.
///
/// **Never fails the run.** The reader half predates this smoke; reporting a
/// regression in it is useful, and failing here would attribute somebody
/// else's break to the INCR owner.
Future<void> _reportPasteIn(
  X11WindowingBackend backend,
  Clipboard clipboard,
  String xclip,
) async {
  try {
    // Smaller than the outgoing payload on purpose: xclip's own INCR *owner*
    // is not what this repository is measuring, and a 900 KiB round trip
    // through a forked xclip daemon is a slower way to learn the same thing.
    final String text = List<String>.generate(4000, (int i) => 'ção $i').join();
    final Process process = await Process.start(
      xclip,
      const <String>['-selection', 'clipboard', '-i'],
    );
    process.stdin.write(text);
    await process.stdin.close();
    // xclip forks a daemon to hold the selection; the foreground process
    // exits immediately and waiting on it is not waiting for ownership.
    await _pump(
      backend,
      () => true,
      const Duration(milliseconds: 250),
      untilDeadline: true,
    );

    String? read;
    Object? error;
    final Future<void> pending = clipboard
        .readText()
        .then((String? value) => read = value, onError: (Object e) {
      error = e;
    });
    var settled = false;
    unawaited(pending.whenComplete(() => settled = true));
    await _pump(backend, () => settled, const Duration(seconds: 10));

    stdout.writeln(
      'X11_CLIP_IN=${read == text ? 'PASS' : 'REPORT'} '
      'sent=${text.length} received=${read?.length ?? -1} '
      '${error == null ? '' : 'error=$error'}',
    );
  } on Object catch (error) {
    stdout.writeln('X11_CLIP_IN=REPORT the read direction could not be '
        'exercised: $error');
  }
}

final class _Capture {
  _Capture(this.stdout, this.stderr, this.exitCode);
  final List<int> stdout;
  final String stderr;
  final int exitCode;
}

/// Runs [executable] while pumping our own X event loop.
///
/// The pumping is the whole trick, and getting it wrong is a deadlock rather
/// than a wrong answer: `xclip -o` blocks on a `SelectionNotify` that only
/// arrives when *we* answer its `SelectionRequest`, and every INCR chunk after
/// that waits on a `PropertyNotify` we only see if we drain the connection.
/// Awaiting the process without pumping hangs both sides until the timeout.
Future<_Capture> _runPumping(
  X11WindowingBackend backend,
  String executable,
  List<String> arguments,
  Duration timeout,
) async {
  final Process process = await Process.start(executable, arguments);
  await process.stdin.close();
  final List<int> out = <int>[];
  final StringBuffer err = StringBuffer();
  var exited = false;
  int? code;
  final Future<void> stdoutDone = process.stdout.forEach(out.addAll);
  final Future<void> stderrDone =
      process.stderr.transform(utf8.decoder).forEach(err.write);
  unawaited(process.exitCode.then((int value) {
    code = value;
    exited = true;
  }));

  await _pump(backend, () => exited, timeout);
  if (!exited) {
    process.kill(ProcessSignal.sigkill);
    throw StateError('$executable ${arguments.join(' ')} did not finish in '
        '${timeout.inSeconds}s; an INCR transfer that stalls looks exactly '
        'like this from the requestor side');
  }
  await stdoutDone;
  await stderrDone;
  return _Capture(out, err.toString(), code ?? -1);
}

/// Pumps the X connection until [predicate] holds or the deadline passes.
///
/// [untilDeadline] keeps pumping for the whole duration instead of stopping at
/// the first true, which is how a caller waits for something that produces no
/// event of its own.
Future<void> _pump(
  X11WindowingBackend backend,
  bool Function() predicate,
  Duration timeout, {
  bool untilDeadline = false,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!untilDeadline && predicate()) return;
    backend.pumpEvents(timeout: const Duration(milliseconds: 5));
    // Yields to the event loop so process output and timers are delivered;
    // without it this spins on the X socket and starves everything else.
    await Future<void>.delayed(Duration.zero);
  }
}

int _commonPrefix(String a, String b) {
  final int limit = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < limit; i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) return i;
  }
  return limit;
}

String? _which(String executable) {
  try {
    final ProcessResult result = Process.runSync('which', <String>[executable]);
    if (result.exitCode != 0) return null;
    final String path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  } on Object {
    return null;
  }
}
