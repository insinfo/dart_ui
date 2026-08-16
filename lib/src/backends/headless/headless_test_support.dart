/// Deterministic tools used by headless tests and golden harnesses.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/clipboard.dart';
import '../../platform/input_events.dart';
import '../../platform/window_events.dart';
import '../../rendering/framebuffer.dart';

/// A framebuffer snapshot with a portable PNG representation.
final class HeadlessScreenshot {
  HeadlessScreenshot.fromFramebuffer(Framebuffer framebuffer)
      : width = framebuffer.width,
        height = framebuffer.height,
        pixels = Uint8List.fromList(framebuffer.toPackedBytes()),
        format = framebuffer.format;

  const HeadlessScreenshot({
    required this.width,
    required this.height,
    required this.pixels,
    this.format = PixelFormat.bgra8888Premultiplied,
  });

  final int width;
  final int height;
  final Uint8List pixels;
  final PixelFormat format;

  /// Encodes rows as RGBA PNG without relying on a native image library.
  Uint8List toPng() {
    final raw = BytesBuilder(copy: false);
    for (var y = 0; y < height; y++) {
      raw.add(const <int>[0]);
      for (var x = 0; x < width; x++) {
        final index = (y * width + x) * 4;
        if (format == PixelFormat.bgra8888Premultiplied) {
          raw.add(<int>[
            pixels[index + 2],
            pixels[index + 1],
            pixels[index],
            pixels[index + 3]
          ]);
        } else {
          raw.add(pixels.sublist(index, index + 4));
        }
      }
    }
    final ihdr = _bytes(
        32,
        (value) => value
          ..addAll(_u32(width))
          ..addAll(_u32(height))
          ..add(8)
          ..add(6)
          ..add(0)
          ..add(0)
          ..add(0));
    return Uint8List.fromList(<int>[
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      ..._chunk('IHDR', ihdr),
      ..._chunk('IDAT', _deflate(raw.takeBytes())),
      ..._chunk('IEND', const <int>[]),
    ]);
  }

  int get checksum => _crc32(pixels);
}

/// Result of comparing two screenshots.
final class GoldenComparison {
  const GoldenComparison({
    required this.match,
    required this.differingPixels,
    required this.maxChannelDelta,
  });

  final bool match;
  final int differingPixels;
  final int maxChannelDelta;

  double differingPercent(int pixelCount) =>
      pixelCount == 0 ? 0 : differingPixels * 100 / pixelCount;
}

GoldenComparison compareGolden(
  HeadlessScreenshot actual,
  HeadlessScreenshot expected, {
  int maxChannelDelta = 0,
  double differingPixelsPercent = 0,
}) {
  if (actual.width != expected.width || actual.height != expected.height) {
    return const GoldenComparison(
      match: false,
      differingPixels: -1,
      maxChannelDelta: -1,
    );
  }
  var differing = 0;
  var maximum = 0;
  for (var i = 0; i < actual.pixels.length; i += 4) {
    var pixelDiffers = false;
    for (var channel = 0; channel < 4; channel++) {
      final delta =
          (actual.pixels[i + channel] - expected.pixels[i + channel]).abs();
      if (delta > maximum) maximum = delta;
      if (delta > maxChannelDelta) pixelDiffers = true;
    }
    if (pixelDiffers) differing++;
  }
  final percent = differing * 100 / (actual.width * actual.height);
  return GoldenComparison(
    match: maximum <= maxChannelDelta && percent <= differingPixelsPercent,
    differingPixels: differing,
    maxChannelDelta: maximum,
  );
}

/// In-memory clipboard used by headless applications and tests.
///
/// The whole point of it is to make the three answers a real clipboard can give
/// reachable from a test without a second process:
///
///  * **text**, including text with the `\r\n` a Windows text file carries and
///    the astral characters a code-unit-counting implementation cuts in half;
///  * **nothing** - [readText] returns null, which is *not* the same as the
///    empty string and callers must not conflate them;
///  * **a failure** - [failWith], because on Windows the clipboard is a
///    process-global lock and `OpenClipboard` really does fail while a
///    clipboard-manager utility holds it. That path is the one most likely to
///    be written without a test, and the one where "retry until it works"
///    turns a copy into a hang.
///
/// [writeText] and [readText] are asynchronous because [Clipboard] is; see that
/// contract for why the port cannot be synchronous even though this
/// implementation answers immediately.
final class FakeClipboard implements Clipboard {
  String? _text;
  ClipboardException? _readFailure;
  ClipboardException? _writeFailure;
  int _reads = 0;
  int _writes = 0;

  /// What a paste would find, without going through [readText].
  String? get text => _text;

  /// How many times each direction was actually exercised.
  ///
  /// A copy that is refused must not touch the clipboard at all, and "the text
  /// did not change" cannot prove that - the field might have written the same
  /// string back. These counters can.
  int get reads => _reads;
  int get writes => _writes;

  /// Puts [value] on the clipboard as another application would have, without
  /// counting as a [writes] and without being blocked by [failWith].
  void seedText(String? value) => _text = value;

  /// Makes every subsequent operation fail with [error].
  ///
  /// Defaults to the Windows failure this exists to reproduce: another process
  /// holds the clipboard and `OpenClipboard` returned zero.
  void failWith([ClipboardException? error]) {
    final ClipboardException failure = error ??
        const ClipboardException(
          backend: 'fake',
          operation: 'OpenClipboard',
          reason: 'another process holds the clipboard lock',
        );
    _readFailure = failure;
    _writeFailure = failure;
  }

  /// Fails only reads, or only writes - the asymmetric case where a cut must
  /// not delete the text it could not copy.
  void failReadsWith(ClipboardException error) => _readFailure = error;
  void failWritesWith(ClipboardException error) => _writeFailure = error;

  /// Stops failing. The contents are untouched.
  void recover() {
    _readFailure = null;
    _writeFailure = null;
  }

  @override
  Future<void> writeText(String value) async {
    _writes++;
    final ClipboardException? failure = _writeFailure;
    if (failure != null) throw failure;
    _text = value;
  }

  @override
  Future<String?> readText() async {
    _reads++;
    final ClipboardException? failure = _readFailure;
    if (failure != null) throw failure;
    return _text;
  }

  /// Empties it, as `EmptyClipboard` does. Never a failure here: a test that
  /// wants an empty clipboard should get one.
  Future<void> clear() async => _text = null;
}

/// Client of the deterministic text-input adapter.
abstract interface class TextInputClient {
  void onTextChanged(String text, int selectionStart, int selectionEnd);
}

/// Minimal composition/input adapter. It intentionally does not emulate IME.
///
/// It does emulate the one thing every native backend has and no test had
/// until now: **the platform's text channel**. A headless test that wants to
/// type has to synthesize a [TextInputEvent], because a key event no longer
/// produces text - that was the bug. Injecting `KeyDownEvent(logicalKey: 0x41)`
/// and expecting an `A` is exactly what let the numeric keypad type `abc` for
/// years without a single test noticing.
final class FakeTextInput {
  FakeTextInput({
    this.windowId = const NativeWindowId(1),
    this.generation = 1,
  });

  /// Stamped onto every synthesized event, so it survives the staleness check
  /// in `HeadlessWindow.dispatchInput`.
  final NativeWindowId windowId;
  final int generation;

  final TextInputAssembler _assembler = TextInputAssembler();
  Duration _clock = Duration.zero;

  TextInputClient? _client;
  String _text = '';
  int _selectionStart = 0;
  int _selectionEnd = 0;

  String get text => _text;
  int get selectionStart => _selectionStart;
  int get selectionEnd => _selectionEnd;

  void attach(TextInputClient client) => _client = client;
  void detach(TextInputClient client) {
    if (identical(_client, client)) _client = null;
  }

  /// The event a backend would emit once its layout translated [text].
  ///
  /// Rejects what no backend is allowed to emit - a control character, an
  /// unpaired surrogate - so that a test cannot prove a behaviour the real
  /// path would never reach. Use [feedCodeUnit] to exercise a character that
  /// arrives in pieces.
  TextInputEvent typeText(String text) {
    if (text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    for (final int rune in text.runes) {
      if (rune <= 0xFFFF && isTextInputControlUnit(rune)) {
        throw ArgumentError.value(
          text,
          'text',
          'control character U+${rune.toRadixString(16).padLeft(4, '0')}: '
              'no backend reports one as text',
        );
      }
      if (rune >= 0xD800 && rune <= 0xDFFF) {
        throw ArgumentError.value(
          text,
          'text',
          'unpaired surrogate: half a character is not text',
        );
      }
    }
    return _event(text);
  }

  /// Feeds one UTF-16 code unit the way `WM_CHAR` does, one message each.
  ///
  /// Returns null while the character is incomplete - the high half of a
  /// surrogate pair - or when the unit is not text at all. This is how a
  /// headless test reproduces an emoji arriving in two pieces, and how it
  /// asserts that Ctrl+A's 0x01 inserts nothing.
  TextInputEvent? feedCodeUnit(int codeUnit) {
    final String? text = _assembler.accept(codeUnit);
    return text == null ? null : _event(text);
  }

  /// Feeds a whole UTF-16 sequence, returning only the completed characters.
  List<TextInputEvent> feedCodeUnits(Iterable<int> codeUnits) {
    final events = <TextInputEvent>[];
    for (final unit in codeUnits) {
      final event = feedCodeUnit(unit);
      if (event != null) events.add(event);
    }
    return events;
  }

  /// Forgets a half-delivered character, as a window losing focus does.
  void resetComposition() => _assembler.reset();

  TextInputEvent _event(String text) {
    // A monotonic synthetic clock: real timestamps come from the OS, and a
    // test that used the wall clock would not be deterministic.
    _clock += const Duration(milliseconds: 1);
    return TextInputEvent(
      windowId: windowId,
      generation: generation,
      timestamp: _clock,
      text: text,
    );
  }

  void setEditingValue(String text, int start, int end) {
    if (start < 0 || end < start || end > text.length) {
      throw RangeError('selection must be within the text');
    }
    _text = text;
    _selectionStart = start;
    _selectionEnd = end;
    _client?.onTextChanged(text, start, end);
  }
}

/// Immutable semantic entry captured by a headless test.
final class SemanticRecord {
  const SemanticRecord({
    required this.id,
    required this.role,
    required this.bounds,
    this.label,
    this.value,
    this.enabled = true,
  });

  final int id;
  final String role;
  final Rect bounds;
  final String? label;
  final String? value;
  final bool enabled;

  @override
  bool operator ==(Object other) =>
      other is SemanticRecord &&
      other.id == id &&
      other.role == role &&
      other.bounds == bounds &&
      other.label == label &&
      other.value == value &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, role, bounds, label, value, enabled);
}

/// Records a stable semantic snapshot without requiring an accessibility API.
final class SemanticRecorder {
  final List<SemanticRecord> _records = <SemanticRecord>[];

  List<SemanticRecord> get records =>
      List<SemanticRecord>.unmodifiable(_records);

  void record(SemanticRecord record) => _records.add(record);

  List<SemanticRecord> snapshot() => records;

  void clear() => _records.clear();
}

/// A JSON-compatible, deterministic input trace.
final class InputReplay {
  InputReplay({required this.window, required List<PlatformInputEvent> events})
      : events = List<PlatformInputEvent>.unmodifiable(events);

  factory InputReplay.fromJson(String source,
      {NativeWindowId windowId = const NativeWindowId(1)}) {
    final map = jsonDecode(source) as Map<String, dynamic>;
    if (map['version'] != 1) {
      throw const FormatException('unsupported replay version');
    }
    final window = map['window'] as Map<String, dynamic>;
    final size = Size((window['width'] as num).toDouble(),
        (window['height'] as num).toDouble());
    final events = <PlatformInputEvent>[];
    for (final item in map['events'] as List<dynamic>) {
      final event = item as Map<String, dynamic>;
      final timestamp = Duration(microseconds: (event['t'] as num).toInt());
      final position = Offset((event['x'] as num?)?.toDouble() ?? 0,
          (event['y'] as num?)?.toDouble() ?? 0);
      final type = event['type'] as String;
      if (type == 'pointerMove') {
        events.add(PointerMoveEvent(
            windowId: windowId,
            generation: 1,
            timestamp: timestamp,
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: position));
      } else if (type == 'pointerDown' || type == 'pointerUp') {
        final button = (event['button'] as num?)?.toInt() == 2
            ? PointerButton.secondary
            : PointerButton.primary;
        final common = type == 'pointerDown';
        events.add(common
            ? PointerDownEvent(
                windowId: windowId,
                generation: 1,
                timestamp: timestamp,
                pointerId: 0,
                kind: PointerKind.mouse,
                logicalPosition: position,
                button: button)
            : PointerUpEvent(
                windowId: windowId,
                generation: 1,
                timestamp: timestamp,
                pointerId: 0,
                kind: PointerKind.mouse,
                logicalPosition: position,
                button: button));
      } else {
        throw FormatException('unsupported replay event: $type');
      }
    }
    return InputReplay(window: size, events: events);
  }

  final Size window;
  final List<PlatformInputEvent> events;

  String toJson() => jsonEncode(<String, Object>{
        'version': 1,
        'window': <String, Object>{
          'width': window.width,
          'height': window.height,
          'scale': 1.0
        },
        'events': events.map(_eventJson).toList(growable: false),
      });
}

Map<String, Object> _eventJson(PlatformInputEvent event) {
  final map = <String, Object>{'t': event.timestamp.inMicroseconds};
  if (event is PointerMoveEvent) {
    map.addAll(<String, Object>{
      'type': 'pointerMove',
      'x': event.logicalPosition.dx,
      'y': event.logicalPosition.dy
    });
  } else if (event is PointerDownEvent || event is PointerUpEvent) {
    final pointer = event as PointerEvent;
    final button = event is PointerDownEvent
        ? event.button
        : (event as PointerUpEvent).button;
    map.addAll(<String, Object>{
      'type': event is PointerDownEvent ? 'pointerDown' : 'pointerUp',
      'x': pointer.logicalPosition.dx,
      'y': pointer.logicalPosition.dy,
      'button': button.index + 1
    });
  }
  return map;
}

List<int> _bytes(int length, void Function(List<int>) fill) {
  final result = <int>[];
  fill(result);
  return result;
}

List<int> _u32(int value) => <int>[
      (value >> 24) & 255,
      (value >> 16) & 255,
      (value >> 8) & 255,
      value & 255
    ];

List<int> _chunk(String name, List<int> data) {
  final type = ascii.encode(name);
  return <int>[
    ..._u32(data.length),
    ...type,
    ...data,
    ..._u32(_crc32(Uint8List.fromList(<int>[...type, ...data])))
  ];
}

List<int> _deflate(List<int> data) {
  final output = <int>[120, 1];
  var offset = 0;
  while (offset < data.length) {
    final length = (data.length - offset).clamp(0, 65535);
    final finalBlock = offset + length == data.length;
    output.add(finalBlock ? 1 : 0);
    output.add(length & 255);
    output.add((length >> 8) & 255);
    final inverse = 65535 - length;
    output.add(inverse & 255);
    output.add((inverse >> 8) & 255);
    output.addAll(data.sublist(offset, offset + length));
    offset += length;
  }
  output.addAll(_u32(_adler32(data)));
  return output;
}

int _adler32(List<int> data) {
  var a = 1;
  var b = 0;
  for (final value in data) {
    a = (a + value) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final value in data) {
    crc ^= value;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0);
    }
  }
  return crc ^ 0xFFFFFFFF;
}
