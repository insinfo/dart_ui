/// Rate and channel conversion that survives being fed one block at a time.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Converts interleaved float32 PCM to an output rate and channel count while
/// the source is still arriving.
///
/// ## Why this exists next to `NativePcmAudioBuffer.converted`
///
/// `converted` answers the same question for a track that is already in
/// memory, and it is the right answer for a drum hit. It is the wrong answer
/// for a film: it needs the whole source before it can produce the first
/// output sample, and it allocates a second copy of the whole track to put the
/// result in. A twenty-minute soundtrack costs twenty seconds and most of a
/// gigabyte that way, none of which is spent on the first sample the listener
/// actually hears.
///
/// ## The one thing a block resampler must not get wrong
///
/// Resampling block by block is not the same arithmetic as resampling the
/// track, and the difference lives entirely at the block boundaries. Output
/// frame *f* is interpolated between source frames `floor(f * ratio)` and one
/// past it, and when *f* is the first frame of a block those two source frames
/// usually belong to the *previous* block. An implementation that restarts its
/// phase at every block - or that simply cannot see the last frame of the
/// previous one - emits a small step discontinuity at every boundary, which at
/// a few hundred boundaries a second is a continuous buzz, not a click that
/// could be dismissed.
///
/// So this class keeps two things across [addSource] calls: the absolute
/// output frame counter, which is what fixes the interpolation phase, and a
/// window of source frames that still reaches back far enough to cover the
/// pair the next output frame needs.
/// `test/audio/playback/streaming_pcm_resampler_test.dart` asserts the result
/// is identical to `converted` over the whole track, block boundaries
/// included.
///
/// ## The arithmetic is deliberately the same as `converted`'s
///
/// Linear interpolation between neighbouring frames, plus the same channel map
/// - average down to mono, repeat the last channel when widening. Not because
/// linear interpolation is good (it is the cheap end, and a windowed-sinc
/// resampler is the obvious upgrade) but because two paths that disagreed
/// about what 44.1 kHz sounds like at 48 kHz could not be tested against each
/// other, and this one has to be provably the same as the one already shipped.
final class StreamingPcmResampler {
  StreamingPcmResampler({
    required this.sourceSampleRate,
    required this.sourceChannels,
    required this.targetSampleRate,
    required this.targetChannels,
  }) {
    if (sourceSampleRate <= 0) {
      throw RangeError.value(
          sourceSampleRate, 'sourceSampleRate', 'must be positive');
    }
    if (targetSampleRate <= 0) {
      throw RangeError.value(
          targetSampleRate, 'targetSampleRate', 'must be positive');
    }
    if (sourceChannels <= 0) {
      throw RangeError.value(
          sourceChannels, 'sourceChannels', 'must be positive');
    }
    if (targetChannels <= 0) {
      throw RangeError.value(
          targetChannels, 'targetChannels', 'must be positive');
    }
    _ratio = sourceSampleRate / targetSampleRate;
    _window = Float32List(0);
  }

  final int sourceSampleRate;
  final int sourceChannels;
  final int targetSampleRate;
  final int targetChannels;

  late final double _ratio;

  /// Live source frames, interleaved, starting at frame index 0 of the list.
  late Float32List _window;

  /// How many frames of [_window] are live.
  int _windowFrames = 0;

  /// The absolute source frame index of the first live frame in [_window].
  int _windowBase = 0;

  int _sourceFrameCount = 0;
  int _outputFrame = 0;
  bool _sourceEnded = false;
  int _totalOutputFrames = 0;

  /// Output frames emitted since construction or the last [reset].
  int get outputFramesProduced => _outputFrame;

  /// Source frames accepted since construction or the last [reset].
  int get sourceFramesAccepted => _sourceFrameCount;

  /// Whether [endOfSource] has been called.
  bool get isSourceEnded => _sourceEnded;

  /// Whether every output frame this source can produce has been read.
  bool get isFinished => _sourceEnded && _outputFrame >= _totalOutputFrames;

  /// How many source frames are being held for the next interpolation.
  ///
  /// Bounded by whatever the caller feeds between [read] calls plus one frame
  /// of history, which is the point: this never grows with the length of the
  /// file.
  int get pendingSourceFrames => _windowFrames;

  /// Appends [frames] source frames (interleaved, [sourceChannels] wide) from
  /// [input]. Defaults to all of [input].
  void addSource(Float32List input, [int? frames]) {
    if (_sourceEnded) {
      throw StateError('the source was already ended');
    }
    final int count = frames ?? input.length ~/ sourceChannels;
    if (count <= 0) return;
    if (count * sourceChannels > input.length) {
      throw ArgumentError.value(
          frames, 'frames', 'exceeds the samples available in input');
    }
    _reserve(_windowFrames + count);
    _window.setRange(
      _windowFrames * sourceChannels,
      (_windowFrames + count) * sourceChannels,
      input,
    );
    _windowFrames += count;
    _sourceFrameCount += count;
  }

  /// Declares that no further source will arrive.
  ///
  /// This is what fixes the output length, and therefore the tail: the last
  /// few output frames land past the last source frame and repeat it, which is
  /// exactly what `converted` does at the end of a clip.
  void endOfSource() {
    if (_sourceEnded) return;
    _sourceEnded = true;
    _totalOutputFrames = _sourceFrameCount == 0
        ? 1
        : math.max(
            1,
            (_sourceFrameCount * targetSampleRate / sourceSampleRate).round(),
          );
  }

  /// Writes up to [maxFrames] output frames into [output], starting at frame
  /// [outputOffsetFrames], and returns how many it wrote.
  ///
  /// A return smaller than [maxFrames] means one of two things: the source has
  /// ended and the last frame has been emitted ([isFinished]), or more source
  /// is needed before the next output frame can be interpolated. The caller
  /// tells them apart with [isFinished] and feeds [addSource] otherwise.
  int read(Float32List output, int maxFrames, {int outputOffsetFrames = 0}) {
    if (maxFrames <= 0) return 0;
    int produced = 0;
    while (produced < maxFrames) {
      if (_sourceEnded && _outputFrame >= _totalOutputFrames) break;
      final int base = (outputOffsetFrames + produced) * targetChannels;
      if (_sourceEnded && _sourceFrameCount == 0) {
        // `converted` allocates one frame for an empty clip and never writes
        // it, so the one frame it yields is silence. Match that rather than
        // yielding nothing, or the two frame counts stop agreeing.
        for (int channel = 0; channel < targetChannels; channel++) {
          output[base + channel] = 0;
        }
        produced++;
        _outputFrame++;
        continue;
      }

      final double position = _outputFrame * _ratio;
      int first = position.floor();
      int second = first + 1;
      if (_sourceEnded) {
        final int last = _sourceFrameCount - 1;
        if (first > last) first = last;
        if (second > last) second = last;
      } else if (second >= _windowBase + _windowFrames) {
        break; // The pair this frame needs has not arrived yet.
      }
      final int firstOffset = first - _windowBase;
      final int secondOffset = second - _windowBase;
      if (firstOffset < 0) {
        throw StateError(
          'the resampler window no longer covers source frame $first; that is '
          'a bug in the trimming rule, not in the caller',
        );
      }
      final double fraction = position - first;
      for (int channel = 0; channel < targetChannels; channel++) {
        final double a = _mapped(firstOffset, channel);
        final double b = _mapped(secondOffset, channel);
        output[base + channel] = a + (b - a) * fraction;
      }
      produced++;
      _outputFrame++;
    }
    _trimWindow();
    return produced;
  }

  /// Drops every frame and rewinds the phase, for a reposition.
  ///
  /// The buffer itself is kept: a seek must not cost an allocation, because a
  /// user scrubbing a timeline issues one every frame.
  void reset() {
    _windowFrames = 0;
    _windowBase = 0;
    _sourceFrameCount = 0;
    _outputFrame = 0;
    _sourceEnded = false;
    _totalOutputFrames = 0;
  }

  double _mapped(int frame, int outputChannel) {
    final int base = frame * sourceChannels;
    if (sourceChannels == targetChannels) {
      return _window[base + outputChannel];
    }
    if (sourceChannels == 1) return _window[base];
    if (targetChannels == 1) {
      double sum = 0;
      for (int channel = 0; channel < sourceChannels; channel++) {
        sum += _window[base + channel];
      }
      return sum / sourceChannels;
    }
    return _window[base + math.min(outputChannel, sourceChannels - 1)];
  }

  void _reserve(int frames) {
    final int needed = frames * sourceChannels;
    if (_window.length >= needed) return;
    final Float32List grown = Float32List(
      math.max(needed, math.max(_window.length * 2, 4096 * sourceChannels)),
    );
    grown.setRange(0, _windowFrames * sourceChannels, _window);
    _window = grown;
  }

  /// Drops the source frames no future output frame can reach.
  ///
  /// The frame the *next* output needs is `floor(outputFrame * ratio)`, so
  /// everything before it is dead - and after the source has ended the clamp
  /// keeps the last frame alive, because the tail interpolates against it
  /// repeatedly.
  void _trimWindow() {
    if (_windowFrames == 0) return;
    int keep = (_outputFrame * _ratio).floor();
    final int lastLive = _windowBase + _windowFrames - 1;
    if (keep > lastLive) keep = lastLive;
    final int drop = keep - _windowBase;
    if (drop <= 0) return;
    final int remaining = _windowFrames - drop;
    _window.setRange(
      0,
      remaining * sourceChannels,
      _window,
      drop * sourceChannels,
    );
    _windowFrames = remaining;
    _windowBase = keep;
  }

  @override
  String toString() => 'StreamingPcmResampler($sourceSampleRate Hz '
      'x$sourceChannels -> $targetSampleRate Hz x$targetChannels)';
}
