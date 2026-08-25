/// The entry points a media player uses to get an audio master clock.
library;

import '../native/native_pcm_audio_buffer.dart';
import 'media_clock.dart';
import 'playback_platform_stub.dart'
    if (dart.library.io) 'playback_platform_io.dart' as platform;

/// Opens playback for a clip that has already been decoded.
abstract final class PcmAudioPlayers {
  /// Returns a player for [pcm], or null when the platform has no audio
  /// output available.
  ///
  /// Null is a normal answer and covers every case a caller cannot do anything
  /// about: a Dart target with no FFI, an operating system with no backend
  /// here yet, a machine with no active render endpoint, an endpoint that
  /// refuses to open. A video player treats null as "no master clock" and
  /// falls back to the wall clock.
  ///
  /// [pcm] is **borrowed**, not adopted: the player reads it for as long as it
  /// lives and never releases it, so it must outlive
  /// [PcmAudioPlayer.dispose] and be disposed by whoever decoded it.
  ///
  /// The clip is resampled and remixed once, before the stream starts, if the
  /// endpoint negotiated a different rate or channel count - see
  /// `conformPcmBuffer` for what that conversion is and is not. [pcm] itself
  /// is left untouched.
  static PcmAudioPlayer? open(NativePcmAudioBuffer pcm) =>
      platform.openPcmAudioPlayer(pcm);

  /// Returns a player that streams the audio track of [path], or null when
  /// there is nothing to play or nowhere to play it.
  ///
  /// ## Why this and not `decodeFile` followed by [open]
  ///
  /// [open] needs the whole track in memory, so its caller has to decode the
  /// whole track first - and both halves of that cost scale with the length of
  /// the file. A twenty-minute soundtrack measured on the machine this was
  /// written on took twenty-one seconds to decode, another two to resample, and
  /// peaked at four and a half gigabytes of resident memory, all of it before
  /// the first sample was heard. None of that work is about the first sample.
  ///
  /// This path opens the container, reads its format and declared duration out
  /// of the header, and starts a decode isolate that keeps a few seconds ahead
  /// of the endpoint in a ring buffer. Time to the first sample is a constant -
  /// well under a second for a four-second effect and for a twenty-minute film
  /// alike - and memory does not grow with the length of the file.
  ///
  /// [open] remains the right entry point for a clip that is already decoded:
  /// a drum pad triggering the same three hundred milliseconds a hundred times
  /// should not re-open a file to do it.
  ///
  /// Null is a normal answer, and covers the same set of cases [open]'s does
  /// plus one more: a file with no audio stream, or one in a format this
  /// machine has no decoder for. A video player treats null as "no master
  /// clock" and falls back to the wall clock.
  static PcmAudioPlayer? openFile(String path) =>
      platform.openPcmAudioFilePlayer(path);
}

/// Decodes the audio track of a media file.
abstract final class MediaAudioTracks {
  /// Decodes the first audio stream of [path], or returns null.
  ///
  /// Null means "no audio to play": the file has no audio track, the platform
  /// cannot decode it, or the file cannot be read. This never throws for an
  /// absent soundtrack, because a silent film still has to play.
  ///
  /// On Windows this reads through Media Foundation's source reader, so a
  /// container that holds video as well - MP4, MKV - yields its audio track
  /// here without the video being touched. The returned buffer is caller-owned
  /// and must be disposed after the player that borrows it.
  static NativePcmAudioBuffer? decodeFile(String path) =>
      platform.decodeMediaAudioTrack(path);
}
