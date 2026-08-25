/// The fallback half of the platform pair.
///
/// This file imports the stub *directly* rather than through
/// `PcmAudioPlayers`, because on the machine that runs these tests the
/// conditional import always resolves to the `dart:io` half - and the stub is
/// exactly the code that never runs here and must still be correct, since it
/// is what a web build compiles and what a future platform without a backend
/// falls back to.
library;

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/audio/playback/playback_platform_stub.dart' as stub;
import 'package:test/test.dart';

void main() {
  test('a platform with no audio output opens no player', () {
    final NativePcmAudioBuffer pcm = NativePcmAudioBuffer.allocate(
      sampleRate: 48000,
      channels: 2,
      frameCount: 128,
    );
    addTearDown(pcm.dispose);

    expect(stub.openPcmAudioPlayer(pcm), isNull);
    // And it did not take ownership of the clip on the way out.
    expect(pcm.isDisposed, isFalse);
  });

  test('a platform with no audio output streams no file either', () {
    expect(stub.openPcmAudioFilePlayer('anything.mp4'), isNull);
    expect(stub.openPcmAudioFilePlayer(''), isNull);
  });

  test('a platform with no decoder returns no audio track', () {
    expect(stub.decodeMediaAudioTrack('anything.mp4'), isNull);
    expect(stub.decodeMediaAudioTrack(''), isNull);
  });

  test('the facades expose the stub signatures the video player codes to', () {
    // A compile-time assertion as much as a runtime one: if either facade
    // stopped returning a nullable type, the frontend's fallback to a wall
    // clock would stop compiling.
    const PcmAudioPlayer? Function(NativePcmAudioBuffer) open =
        PcmAudioPlayers.open;
    const NativePcmAudioBuffer? Function(String) decode =
        MediaAudioTracks.decodeFile;
    const PcmAudioPlayer? Function(String) openFile = PcmAudioPlayers.openFile;
    expect(open, isNotNull);
    expect(decode, isNotNull);
    expect(openFile, isNotNull);
  });
}
