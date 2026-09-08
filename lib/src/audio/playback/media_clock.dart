/// The contract a video player synchronizes against.
///
/// A player that drives picture from a wall clock drifts: `Stopwatch` counts
/// the host's idea of a second and the sound card counts its own, and the two
/// are never the same number. Over a few minutes that difference is audible as
/// lip-sync error, and it cannot be corrected by measuring the wall clock more
/// carefully. The fix is to stop treating the wall clock as the reference and
/// ask the device that is actually consuming samples how far it has got, which
/// is what [MediaClock] exposes.
library;

import '../audio_gain.dart';

/// A playback position measured in what an output device has consumed.
abstract interface class MediaClock {
  /// How much of the media has been played.
  ///
  /// Monotonic while running, apart from an explicit reposition. This is
  /// derived from frames the device has taken, so it stops advancing on its
  /// own when the device stalls - which is exactly the moment a video player
  /// must also stop advancing.
  Duration get position;

  /// Whether [position] is expected to keep advancing.
  bool get isRunning;
}

/// Plays one decoded PCM clip and exposes its position as a [MediaClock].
///
/// Implementations own an output stream; a video player uses one of these as
/// its master clock and schedules picture against [position].
abstract interface class PcmAudioPlayer implements MediaClock {
  /// The sample rate of the output device, which is not necessarily the rate
  /// the media was decoded at - see the implementation's conversion notes.
  int get sampleRate;

  /// The channel count of the output device.
  int get channels;

  /// The duration of the clip as it will be played, measured in the output
  /// format.
  Duration get duration;

  /// This player's own level. [AudioGain.unity] by default, which is
  /// bit-identical passthrough.
  ///
  /// Applied at the very end of the chain - after decoding, after resampling,
  /// after mixing - so one multiply covers everything and no earlier stage
  /// sees an attenuated sample it might make a decision from.
  ///
  /// [AudioGain.silence] silences the output; it does **not** pause. The
  /// transport keeps running, the endpoint keeps consuming frames and
  /// [position] keeps advancing, so a run at zero gain exercises the same code
  /// as a run at full volume. That is deliberate: this control exists because
  /// a profiling run played a tone through somebody's speakers at full volume,
  /// and a "silence" that quietly stopped the pump would have measured a
  /// different program than the one being profiled.
  ///
  /// This is *stream gain*: it lives inside this process, it does not appear
  /// in the operating system's volume mixer, and the user cannot change it
  /// from outside. `AudioSessionVolume` is the other thing, and it is a
  /// discovered capability on the backend's stream rather than a member here.
  AudioGain get gain;

  set gain(AudioGain value);

  /// Starts, or resumes, consuming samples.
  void play();

  /// Stops consuming samples. [position] holds its value.
  void pause();

  /// Repositions playback. The next [position] read reflects [to], even before
  /// the output device has acted on it.
  void seek(Duration to);

  /// Releases the output stream and every resource this player allocated. The
  /// PCM buffer handed to the factory is *not* released: the caller owns it.
  Future<void> dispose();
}
