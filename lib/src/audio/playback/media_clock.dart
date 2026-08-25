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
