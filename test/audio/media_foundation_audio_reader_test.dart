/// The cursor half of Media Foundation, held against the whole-file half.
///
/// The reader exists to answer two questions the decoder can only answer by
/// decoding everything: "what format and how long is this?" and "give me the
/// next tenth of a second". So the assertions here are mostly about *not*
/// having read the file: that the duration arrives from the container, that a
/// seek lands where it was asked to, and that reading the same track through
/// the cursor produces the samples the decoder produces.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

String _sample(List<String> parts) =>
    File(parts.join(Platform.pathSeparator)).absolute.path;

final String _mp3 = _sample(<String>[
  'examples',
  'drumer',
  'samples',
  'AK-Mixa-Kit',
  'kick 1.mp3',
]);

final String _wav = _sample(<String>[
  'examples',
  'drumer',
  'drum_sounds',
  'crash-acoustic.wav',
]);

/// Reads [reader] to the end and returns everything it produced.
Float32List _readAll(MediaFoundationAudioReader reader) {
  final List<double> samples = <double>[];
  while (true) {
    final Float32List? chunk = reader.readChunk();
    if (chunk == null) break;
    samples.addAll(chunk);
  }
  return Float32List.fromList(samples);
}

void main() {
  group('MediaFoundationAudioReader', () {
    test('reports the format and the container duration without decoding', () {
      final MediaFoundationAudioReader reader =
          MediaFoundationAudioReader.open(_wav);
      addTearDown(reader.dispose);

      expect(reader.sampleRate, greaterThan(0));
      expect(reader.channels, greaterThan(0));
      expect(reader.duration, greaterThan(const Duration(seconds: 3)));
      expect(reader.duration, lessThan(const Duration(seconds: 5)));
      // Nothing has been read yet, which is the whole point of asking the
      // container instead of the samples.
      expect(reader.isAtEnd, isFalse);
    });

    test('the container duration agrees with what decoding produces', () {
      final NativePcmAudioBuffer decoded =
          MediaFoundationAudioDecoder.decodeFile(_wav);
      addTearDown(decoded.dispose);
      final MediaFoundationAudioReader reader =
          MediaFoundationAudioReader.open(_wav);
      addTearDown(reader.dispose);

      expect(reader.sampleRate, decoded.sampleRate);
      expect(reader.channels, decoded.channels);
      expect(
        reader.duration.inMilliseconds,
        closeTo(decoded.duration.inMilliseconds, 40),
        reason: 'the declared duration should match the decoded length',
      );
    });

    test('reading in blocks yields the same samples as decoding at once', () {
      final NativePcmAudioBuffer decoded =
          MediaFoundationAudioDecoder.decodeFile(_mp3);
      addTearDown(decoded.dispose);
      final MediaFoundationAudioReader reader =
          MediaFoundationAudioReader.open(_mp3);
      addTearDown(reader.dispose);

      final Float32List streamed = _readAll(reader);
      expect(reader.isAtEnd, isTrue);
      expect(streamed.length, decoded.sampleCount);
      final List<double> expected =
          decoded.samples.asTypedList(decoded.sampleCount);
      for (int index = 0; index < expected.length; index++) {
        expect(streamed[index], expected[index],
            reason: 'sample $index differs between the two paths');
      }
    });

    test('more than one block is produced, and none is oversized', () {
      final MediaFoundationAudioReader reader =
          MediaFoundationAudioReader.open(_wav);
      addTearDown(reader.dispose);

      int blocks = 0;
      int frames = 0;
      int largest = 0;
      while (true) {
        final Float32List? chunk = reader.readChunk();
        if (chunk == null) break;
        final int chunkFrames = chunk.length ~/ reader.channels;
        largest = chunkFrames > largest ? chunkFrames : largest;
        frames += chunkFrames;
        blocks++;
      }
      expect(blocks, greaterThan(10),
          reason: 'a four second file read one block at a time is many blocks');
      // If a single block held the whole file this would be a decoder with
      // extra steps, and memory would still scale with the length.
      expect(largest * 4, lessThan(frames),
          reason: 'no single block should hold a quarter of the track');
    });

    test('seek repositions the cursor and reports where it landed', () {
      final MediaFoundationAudioReader reader =
          MediaFoundationAudioReader.open(_wav);
      addTearDown(reader.dispose);

      reader.seek(const Duration(seconds: 2));
      final Float32List? chunk = reader.readChunk();
      expect(chunk, isNotNull);
      expect(
        reader.chunkStart.inMilliseconds,
        closeTo(2000, 100),
        reason: 'a seek lands on the nearest decodable boundary, not further',
      );

      // And what remains is about what is left of the file.
      int frames = chunk!.length ~/ reader.channels;
      while (true) {
        final Float32List? next = reader.readChunk();
        if (next == null) break;
        frames += next.length ~/ reader.channels;
      }
      final Duration remaining = Duration(
        microseconds: frames * 1000000 ~/ reader.sampleRate,
      );
      expect(
        remaining.inMilliseconds,
        closeTo(
            (reader.duration - const Duration(seconds: 2)).inMilliseconds, 150),
      );
    });

    test('seeking back to the start replays the same samples', () {
      final MediaFoundationAudioReader reader =
          MediaFoundationAudioReader.open(_mp3);
      addTearDown(reader.dispose);

      final Float32List first = Float32List.fromList(reader.readChunk()!);
      reader.seek(Duration.zero);
      final Float32List again = reader.readChunk()!;
      expect(again.length, first.length);
      for (int index = 0; index < first.length; index++) {
        expect(again[index], first[index]);
      }
    });

    test('reading past the end keeps answering null', () {
      final MediaFoundationAudioReader reader =
          MediaFoundationAudioReader.open(_mp3);
      addTearDown(reader.dispose);
      _readAll(reader);
      expect(reader.isAtEnd, isTrue);
      expect(reader.readChunk(), isNull);
      expect(reader.readChunk(), isNull);
    });

    test('a file with no audio track is refused rather than played', () {
      expect(
        () => MediaFoundationAudioReader.open('no-such-file.mp4'),
        throwsA(anything),
      );
      expect(
        () => MediaFoundationAudioReader.open(
          File('pubspec.yaml').absolute.path,
        ),
        throwsA(anything),
      );
    });

    test('disposing twice is a no-op, as everything here promises', () {
      final MediaFoundationAudioReader reader =
          MediaFoundationAudioReader.open(_wav)
            ..readChunk()
            ..dispose()
            ..dispose();
      expect(reader.isDisposed, isTrue);
      expect(reader.readChunk, throwsStateError);
    });
  }, skip: Platform.isWindows ? null : 'Media Foundation is Windows-only');
}
