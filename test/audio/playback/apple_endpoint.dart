import 'package:dart_ui/audio.dart';

/// Whether an Audio Queue actually starts on this Mac: a runner with no
/// output device creates the queue and then fails to start it.
bool appleQueueStarts() {
  final NativePcmAudioBuffer silence = NativePcmAudioBuffer.allocate(
      sampleRate: 48000, channels: 1, frameCount: 4800);
  try {
    final AudioQueuePcmPlayer? player = AudioQueuePcmPlayer.open(silence);
    if (player == null) return false;
    player.play();
    final bool started = player.isRunning;
    player.dispose();
    return started;
  } on Object {
    return false;
  } finally {
    silence.dispose();
  }
}
