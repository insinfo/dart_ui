/// The playback path for Dart on an operating system.
library;

import 'dart:io';

import '../apple/audio_queue_player.dart';
import '../apple/ext_audio_file_decoder.dart';
import '../native/native_pcm_audio_buffer.dart';
import '../windows/media_foundation_audio_decoder.dart';
import 'media_clock.dart';
import 'wasapi_pcm_audio_player.dart';

bool get _apple => Platform.isMacOS || Platform.isIOS;

/// Opens a player, or returns null when this machine cannot render audio.
///
/// WASAPI on Windows, an Audio Queue on macOS and iOS. On Linux this is null
/// rather than a throw, because "no audio output" is a state a video player
/// has to keep running through, not an error it should crash on.
PcmAudioPlayer? openPcmAudioPlayer(NativePcmAudioBuffer pcm) {
  if (_apple) return AudioQueuePcmPlayer.open(pcm);
  if (!Platform.isWindows) return null;
  return WasapiPcmAudioPlayer.open(pcm);
}

/// Opens a streaming player over [path], or returns null.
///
/// The same "every no is null" rule [decodeMediaAudioTrack] documents, for the
/// same caller: a machine that is not Windows, a file with no audio stream, a
/// codec Windows cannot decode, an unreadable path, a machine with no render
/// endpoint. All of them mean "play this silently off the wall clock".
PcmAudioPlayer? openPcmAudioFilePlayer(String path) {
  if (_apple) {
    // Decoded whole by the system's codecs, then played from memory: the
    // Windows path streams, and this one can when a file is too long to
    // hold, which no example reaches yet.
    final NativePcmAudioBuffer? pcm = ExtAudioFileDecoder.decodeFile(path);
    if (pcm == null) return null;
    final PcmAudioPlayer? player = AudioQueuePcmPlayer.open(pcm, ownsPcm: true);
    if (player == null) pcm.dispose();
    return player;
  }
  if (!Platform.isWindows) return null;
  try {
    return WasapiPcmAudioPlayer.openFile(path);
  } on Object {
    return null;
  }
}

/// Decodes the audio track of [path], or returns null.
///
/// ## Why every failure is null
///
/// The caller is a video player asking "does this file have sound?", and every
/// no is the same answer: a file with no audio stream, a codec Windows has no
/// decoder for, an unreadable path, a machine that is not Windows. Media
/// Foundation reports most of those as an `HRESULT` from somewhere deep in
/// `ReadSample`, and turning that into an exception would mean the video path
/// has to catch it and decide it was benign - which is this function's job,
/// done once, here.
///
/// The consequence is that a genuine decoder bug also arrives as null. That is
/// accepted: the audio track is an optimisation for the clock, and a player
/// that refuses to show a film because its soundtrack could not be decoded is
/// worse than one that plays it silently off the wall clock.
NativePcmAudioBuffer? decodeMediaAudioTrack(String path) {
  if (_apple) return ExtAudioFileDecoder.decodeFile(path);
  if (!Platform.isWindows) return null;
  NativePcmAudioBuffer? decoded;
  try {
    decoded = MediaFoundationAudioDecoder.decodeFile(path);
  } on Object {
    return null;
  }
  if (decoded.frameCount == 0) {
    decoded.dispose();
    return null;
  }
  return decoded;
}
