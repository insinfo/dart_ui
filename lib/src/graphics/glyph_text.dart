/// What text a glyph run came from, kept beside the command stream.
///
/// `drawGlyphRun` carries a font id, an origin and a list of **glyph ids**.
/// That is exactly right for a rasteriser - a glyph id is what indexes an
/// outline - and it is the single thing a DOM backend cannot work with,
/// because the DOM's unit of text is a character and there is no way to put a
/// glyph id into a text node.
///
/// Inverting the font's `cmap` recovers most of it and provably cannot recover
/// all of it: a ligature glyph is a `GSUB` substitution that no code point
/// maps to, so `fi` comes back as U+FB01 in a face that happens to map the
/// presentation form and comes back as *nothing at all* in a face that does
/// not. Text that looks right, copies wrong and does not answer Ctrl+F is the
/// failure this file exists to end.
///
/// ## Why a side table and not an operand
///
/// The same argument `content_hint.dart` makes, and it holds for the same
/// reason: adding operands to `opDrawGlyphRun` would change the wire format,
/// which means every `RasterSink` in this repository acquires a body for
/// something that says nothing about pixels, and the op and float streams a
/// captured frame produces would stop being the streams an uncaptured frame
/// produces. A side table keyed by op-stream offset gives byte-for-byte
/// identical buffers by construction rather than by discipline, and
/// `test/graphics/glyph_text_test.dart` asserts it directly.
///
/// The table is *not* a run-length encoding the way the hint table is. Each
/// entry names exactly one `drawGlyphRun` command - a span whose
/// [GlyphTextSpans.spanStart] is the word offset of that command's header, and
/// which says nothing about the command after it. A reader therefore tests for
/// equality with the offset it is at, not for "the last span at or before it".
///
/// ## Why capture is off by default
///
/// `display_list.dart` opens by saying a steady-state frame allocates nothing,
/// and the GPU backends have no use for any of this. So the model is
/// `RenderDiagnosticsRecorder.disabled`: [GlyphTextCapture.disabled] is a
/// `const` singleton with empty method bodies and no state, so a display list
/// that never captures holds one shared object and allocates nothing per
/// frame, per run or per command. Turning capture off is not an `if` at the
/// call site, it is a call the compiler can see through.
///
/// The one thing a caller *does* guard with [GlyphTextCapture.isRecording] is
/// work it would only do to record: `TextPainter.emitRun` has to scan a run's
/// clusters to decide which characters each emitted command covers, and that
/// scan must not happen on a frame nobody will read it from.
///
/// ## Why storing strings is cheap
///
/// The table holds *references*. Every string it records is a string the
/// widget tree already built and already retains - a label's text, a
/// paragraph's source - and `GlyphRunCache` keys its entries on it, so it
/// outlives the frame either way. Nothing here copies a character; the
/// per-span cost is one pointer and two integers, and the substring is not
/// materialised until a backend asks for it.
library;

import 'dart:typed_data';

/// The recorded text of a display list's glyph runs, read by op offset.
///
/// Deliberately the shape `ContentHintSpans` established, down to the
/// `spanCount` / `spanStart` pair, so a replayer that already walks one side
/// table walks this one the same way.
abstract interface class GlyphTextSpans {
  /// How many glyph-run commands carry recorded text. Zero for every list
  /// built without capture, which is the single integer comparison that makes
  /// a reader's per-command cost nothing on the common frame.
  int get spanCount;

  /// Word offset in the op stream of the `drawGlyphRun` header [index]
  /// describes.
  ///
  /// An exact offset, not the start of a range: see the library comment.
  int spanStart(int index);

  /// The string the run was shaped from.
  ///
  /// The whole string, not the part this command covers - the table stores a
  /// reference to text that already exists rather than a substring it would
  /// have to build. [spanTextStart] and [spanTextEnd] bound the part.
  String spanText(int index);

  /// First UTF-16 offset of [spanText] this command's glyphs came from.
  int spanTextStart(int index);

  /// One past the last UTF-16 offset of [spanText] this command's glyphs came
  /// from.
  int spanTextEnd(int index);

  /// A list that recorded nothing. Const, so the default costs no allocation
  /// and no null test.
  static const GlyphTextSpans empty = _EmptyGlyphTextSpans();
}

final class _EmptyGlyphTextSpans implements GlyphTextSpans {
  const _EmptyGlyphTextSpans();

  @override
  int get spanCount => 0;

  @override
  int spanStart(int index) =>
      throw RangeError.index(index, this, 'index', 'no spans', 0);

  @override
  String spanText(int index) =>
      throw RangeError.index(index, this, 'index', 'no spans', 0);

  @override
  int spanTextStart(int index) =>
      throw RangeError.index(index, this, 'index', 'no spans', 0);

  @override
  int spanTextEnd(int index) =>
      throw RangeError.index(index, this, 'index', 'no spans', 0);
}

/// Where a display list sends the text behind a glyph run.
///
/// Two implementations and no third: one that keeps nothing and allocates
/// nothing, and one that keeps a flat table. See the library comment for why
/// the disabled one is a `const` singleton rather than a null field.
abstract interface class GlyphTextCapture {
  /// A capture that keeps nothing and allocates nothing.
  static const GlyphTextCapture disabled = _DisabledGlyphTextCapture();

  /// A capture that keeps a flat, growable table. One object; the arrays reach
  /// the high-water mark of a few frames and stay there, exactly as the
  /// command buffers do.
  factory GlyphTextCapture.recording() = _RecordingGlyphTextCapture;

  /// False for [disabled]. What a caller guards a scan it would only do in
  /// order to record with.
  bool get isRecording;

  /// Records that the command whose header is at [opOffset] draws the glyphs
  /// of `text.substring(start, end)`.
  ///
  /// [text] is retained by reference and never copied.
  void record(int opOffset, String text, int start, int end);

  /// Rewinds to empty, keeping the storage. Called from `DisplayList.reset`.
  void reset();

  /// What has been recorded. [GlyphTextSpans.empty] for [disabled], the same
  /// instance every time.
  GlyphTextSpans get spans;
}

final class _DisabledGlyphTextCapture implements GlyphTextCapture {
  const _DisabledGlyphTextCapture();

  @override
  bool get isRecording => false;

  @override
  void record(int opOffset, String text, int start, int end) {}

  @override
  void reset() {}

  @override
  GlyphTextSpans get spans => GlyphTextSpans.empty;
}

/// The recording capture, which is also its own [GlyphTextSpans] view.
///
/// One class rather than the recorder-plus-view pair `_DisplayListContentHints`
/// uses, because there is nothing to hide here: the recorder is already a
/// separate object from the encoder, so exposing it as the reader's face costs
/// no name on `DisplayList`'s surface and saves an allocation per list.
final class _RecordingGlyphTextCapture
    implements GlyphTextCapture, GlyphTextSpans {
  _RecordingGlyphTextCapture();

  /// Op-stream word offsets, one per span, strictly increasing.
  Uint32List _starts = Uint32List(8);

  /// UTF-16 bounds inside the span's own string, two entries per span:
  /// start then end.
  Uint32List _ranges = Uint32List(16);

  /// The source strings, by reference. A `List<String>` rather than a typed
  /// buffer for the obvious reason, and it is the only object storage here:
  /// the same string appears once per command it is split across, and a
  /// duplicate reference is a word, not a copy.
  final List<String> _texts = <String>[];

  int _count = 0;

  @override
  bool get isRecording => true;

  @override
  void record(int opOffset, String text, int start, int end) {
    // Overwrite instead of appending when the previous span names the same
    // command. That happens when a caller records and then does not emit -
    // the analogue of the empty subtree `_recordHint` collapses - and leaving
    // the stale span would attribute this command's characters to the command
    // after it, which is silent misattribution rather than a visible fault.
    if (_count > 0 && _starts[_count - 1] == opOffset) {
      _texts[_count - 1] = text;
      _ranges[(_count - 1) * 2] = start;
      _ranges[(_count - 1) * 2 + 1] = end;
      return;
    }
    if (_count == _starts.length) {
      final Uint32List starts = Uint32List(_starts.length * 2);
      final Uint32List ranges = Uint32List(_ranges.length * 2);
      starts.setRange(0, _count, _starts);
      ranges.setRange(0, _count * 2, _ranges);
      _starts = starts;
      _ranges = ranges;
    }
    if (_texts.length == _count) {
      _texts.add(text);
    } else {
      _texts[_count] = text;
    }
    _starts[_count] = opOffset;
    _ranges[_count * 2] = start;
    _ranges[_count * 2 + 1] = end;
    _count++;
  }

  @override
  void reset() {
    // The strings are dropped but the list keeps its capacity: holding a
    // frame's worth of text alive after the frame is a leak that grows with
    // how much text the application has ever shown.
    for (var i = 0; i < _count; i++) {
      _texts[i] = '';
    }
    _count = 0;
  }

  @override
  GlyphTextSpans get spans => this;

  @override
  int get spanCount => _count;

  @override
  int spanStart(int index) => _starts[_check(index)];

  @override
  String spanText(int index) => _texts[_check(index)];

  @override
  int spanTextStart(int index) => _ranges[_check(index) * 2];

  @override
  int spanTextEnd(int index) => _ranges[_check(index) * 2 + 1];

  int _check(int index) {
    if (index < 0 || index >= _count) {
      throw RangeError.index(index, this, 'index', 'no such text span', _count);
    }
    return index;
  }
}
