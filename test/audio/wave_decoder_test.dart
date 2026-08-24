import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

void main() {
  test('decodes signed 24-bit mono PCM and skips odd metadata chunks', () {
    final Uint8List wave = _wave(
      format: 1,
      channels: 1,
      sampleRate: 44100,
      bits: 24,
      samples: <int>[
        0x00,
        0x00,
        0x80,
        0x00,
        0x00,
        0x00,
        0xff,
        0xff,
        0x7f,
      ],
      addOddJunk: true,
    );
    final NativePcmAudioBuffer decoded = WaveDecoder.decode(wave);
    addTearDown(decoded.dispose);

    expect(decoded.sampleRate, 44100);
    expect(decoded.channels, 1);
    expect(decoded.frameCount, 3);
    expect(decoded.sampleAt(0, 0), -1);
    expect(decoded.sampleAt(1, 0), 0);
    expect(decoded.sampleAt(2, 0), closeTo(1, 0.000001));
  });

  test('decodes IEEE float32 and sanitizes non-finite values', () {
    final ByteData payload = ByteData(12)
      ..setFloat32(0, -0.25, Endian.little)
      ..setFloat32(4, double.nan, Endian.little)
      ..setFloat32(8, 1.5, Endian.little);
    final NativePcmAudioBuffer decoded = WaveDecoder.decode(
      _wave(
        format: 3,
        channels: 1,
        sampleRate: 48000,
        bits: 32,
        samples: payload.buffer.asUint8List(),
      ),
    );
    addTearDown(decoded.dispose);

    expect(decoded.samples.asTypedList(3), <double>[-0.25, 0, 1]);
  });

  test('converts sample rate and duplicates mono into stereo offline', () {
    final NativePcmAudioBuffer source = NativePcmAudioBuffer.allocate(
      sampleRate: 2,
      channels: 1,
      frameCount: 2,
    );
    source.samples[0] = 0;
    source.samples[1] = 1;
    final NativePcmAudioBuffer converted = source.converted(
      sampleRate: 4,
      channels: 2,
    );
    addTearDown(() {
      converted.dispose();
      source.dispose();
    });

    expect(converted.frameCount, 4);
    expect(
        converted.samples.asTypedList(8), <double>[0, 0, 0.5, 0.5, 1, 1, 1, 1]);
  });

  test('rejects compressed WAVE data by format tag', () {
    expect(
      () => WaveDecoder.decode(
        _wave(
          format: 0x55,
          channels: 2,
          sampleRate: 44100,
          bits: 16,
          samples: <int>[0, 0, 0, 0],
        ),
      ),
      throwsA(isA<WaveFormatException>()),
    );
  });
}

Uint8List _wave({
  required int format,
  required int channels,
  required int sampleRate,
  required int bits,
  required List<int> samples,
  bool addOddJunk = false,
}) {
  final int blockAlign = channels * ((bits + 7) ~/ 8);
  final int junkBytes = addOddJunk ? 10 : 0; // 8 header + 1 byte + padding.
  final int dataPadding = samples.length.isOdd ? 1 : 0;
  final int total = 12 + 24 + junkBytes + 8 + samples.length + dataPadding;
  final Uint8List output = Uint8List(total);
  final ByteData data = ByteData.sublistView(output);
  void ascii(int offset, String value) {
    for (int i = 0; i < value.length; i++) {
      output[offset + i] = value.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, total - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, format, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * blockAlign, Endian.little);
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, bits, Endian.little);
  int cursor = 36;
  if (addOddJunk) {
    ascii(cursor, 'JUNK');
    data.setUint32(cursor + 4, 1, Endian.little);
    output[cursor + 8] = 7;
    cursor += 10;
  }
  ascii(cursor, 'data');
  data.setUint32(cursor + 4, samples.length, Endian.little);
  output.setRange(cursor + 8, cursor + 8 + samples.length, samples);
  return output;
}
