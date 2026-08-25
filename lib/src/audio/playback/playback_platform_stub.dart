/// The playback path for Dart platforms with no native audio output.
///
/// Everything here answers null. That is the contract the video player is
/// built on: a machine without an audio device, or a Dart target that cannot
/// have one, must fall back to a wall clock rather than fail to play the film.
library;

import '../native/native_pcm_audio_buffer.dart';
import 'media_clock.dart';

PcmAudioPlayer? openPcmAudioPlayer(NativePcmAudioBuffer pcm) => null;

PcmAudioPlayer? openPcmAudioFilePlayer(String path) => null;

NativePcmAudioBuffer? decodeMediaAudioTrack(String path) => null;
