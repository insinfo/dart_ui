/// `debugPrint`: Flutter's rate-limited `print`, under its own name.
///
/// Packages log through `debugPrint` rather than `print` for two reasons
/// that hold here too: a burst of output must not be dropped by a terminal
/// or a log pipe that cannot keep up, and an application can silence or
/// redirect every package's logging at once by replacing [debugPrint].
library;

import 'dart:async';
import 'dart:collection';

/// The signature of [debugPrint]: a message and an optional wrap width.
typedef DebugPrintCallback = void Function(String? message, {int? wrapWidth});

/// Prints [message], throttled; replace it to redirect or silence logging.
///
/// Defaults to [debugPrintThrottled], as in Flutter. Unlike Flutter, it is
/// not a no-op in release builds either way - Flutter's is not, and neither
/// is this one; wrap expensive messages in `if (kDebugMode)`.
DebugPrintCallback debugPrint = debugPrintThrottled;

/// Prints [message] immediately, wrapped at [wrapWidth] when given.
void debugPrintSynchronously(String? message, {int? wrapWidth}) {
  for (final String line in _lines(message, wrapWidth)) {
    // The one place output reaches stdout on purpose.
    // ignore: avoid_print
    print(line);
  }
}

/// Prints [message] at most [_capacity] characters per [_pause], queueing
/// the rest, so a large dump is delivered whole rather than truncated.
void debugPrintThrottled(String? message, {int? wrapWidth}) {
  _queue.addAll(_lines(message, wrapWidth));
  if (!_scheduled) _drain();
}

/// Completes once every line queued by [debugPrintThrottled] has printed.
Future<void> get debugPrintDone => _done?.future ?? Future<void>.value();

const int _capacity = 12 * 1024;
const Duration _pause = Duration(seconds: 1);

final Queue<String> _queue = Queue<String>();
bool _scheduled = false;
int _printedInWindow = 0;
Stopwatch? _window;
Completer<void>? _done;

void _drain() {
  final Stopwatch window = _window ??= Stopwatch()..start();
  if (window.elapsed > _pause) {
    window.reset();
    _printedInWindow = 0;
  }
  while (_queue.isNotEmpty && _printedInWindow < _capacity) {
    final String line = _queue.removeFirst();
    _printedInWindow += line.length;
    // ignore: avoid_print
    print(line);
  }
  if (_queue.isEmpty) {
    _scheduled = false;
    _done?.complete();
    _done = null;
    return;
  }
  _scheduled = true;
  _done ??= Completer<void>();
  Timer(_pause - window.elapsed, () {
    window.reset();
    _printedInWindow = 0;
    _drain();
  });
}

Iterable<String> _lines(String? message, int? wrapWidth) sync* {
  final String text = message ?? 'null';
  for (final String line in text.split('\n')) {
    if (wrapWidth == null || wrapWidth <= 0 || line.length <= wrapWidth) {
      yield line;
      continue;
    }
    // Wrapped at spaces, continuation lines indented like the original.
    final String leading = RegExp(r'^ *').firstMatch(line)!.group(0)!;
    // An indent wider than half a line would leave no room to make progress.
    final String indent = leading.length * 2 < wrapWidth ? leading : '';
    String rest = line;
    bool first = true;
    while (rest.length > wrapWidth) {
      int cut = rest.lastIndexOf(' ', wrapWidth);
      if (cut <= indent.length) cut = wrapWidth;
      yield rest.substring(0, cut);
      rest = '$indent${rest.substring(cut).trimLeft()}';
      first = false;
    }
    if (rest.trim().isNotEmpty || first) yield rest;
  }
}
