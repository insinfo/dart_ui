/// Matching a decoded clip to the format the output device negotiated.
library;

import 'dart:math' as math;

import '../native/native_pcm_audio_buffer.dart';

/// A clip in the output device's format, and whether it was newly allocated.
///
/// The distinction matters because the common case - a 48 kHz stereo file on a
/// 48 kHz stereo endpoint - needs no copy at all, and copying a two-hour film's
/// audio track to change nothing about it would cost hundreds of megabytes for
/// the privilege.
final class ConformedPcmBuffer {
  const ConformedPcmBuffer(this.buffer, {required this.ownsBuffer});

  final NativePcmAudioBuffer buffer;

  /// True when [buffer] was allocated by [conformPcmBuffer] and must be
  /// released by whoever asked for it.
  final bool ownsBuffer;

  /// Releases [buffer] only if this object introduced it.
  void disposeIfOwned() {
    if (ownsBuffer) buffer.dispose();
  }
}

/// Returns [source] in [sampleRate]/[channels], converting only if needed.
///
/// ## What the conversion is, and what it is not
///
/// This delegates to [NativePcmAudioBuffer.converted], which is **linear
/// interpolation** between the two neighbouring source frames, plus a channel
/// map that averages down to mono and repeats the last channel when widening.
/// That is the cheap end of resampling and it is a deliberate choice: it is
/// exact when the rates match, it introduces no latency and no ringing, and its
/// error is high-frequency imaging near Nyquist - which for the job this
/// package's playback path does (getting a 44.1 kHz film soundtrack onto a
/// 48 kHz endpoint at the right *pitch and duration*) is inaudible next to the
/// alternative of not converting at all, which is a 9% pitch error and an
/// audio clock that runs 9% fast. A windowed-sinc resampler would measure
/// better and is the obvious upgrade; it is not needed to make the clock
/// correct, which is what this path exists for.
///
/// The conversion happens once, before the stream starts, and never on the
/// realtime thread.
ConformedPcmBuffer conformPcmBuffer(
  NativePcmAudioBuffer source, {
  required int sampleRate,
  required int channels,
}) {
  if (source.sampleRate == sampleRate && source.channels == channels) {
    return ConformedPcmBuffer(source, ownsBuffer: false);
  }
  return ConformedPcmBuffer(
    source.converted(sampleRate: sampleRate, channels: channels),
    ownsBuffer: true,
  );
}

/// The frame count [conformPcmBuffer] will produce for these arguments.
///
/// The player has to report [PcmAudioPlayer.duration] the moment it is opened,
/// before the playback isolate has negotiated anything or converted a sample,
/// and the duration that matters is the one measured in output frames. This
/// repeats the length rule of [NativePcmAudioBuffer.converted] rather than
/// allocating a buffer to ask it.
int conformedFrameCount(
  NativePcmAudioBuffer source, {
  required int sampleRate,
}) {
  if (source.sampleRate == sampleRate) return source.frameCount;
  // Mirrors the length rule of `converted`, floor of one frame included, so
  // the reported duration is the buffer the isolate will really play.
  return math.max(
      1, (source.frameCount * sampleRate / source.sampleRate).round());
}
