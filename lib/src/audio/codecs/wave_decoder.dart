/// RIFF/WAVE PCM decoder producing realtime-ready native float32 buffers.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../native/native_pcm_audio_buffer.dart';

const int _waveFormatPcm = 0x0001;
const int _waveFormatIeeeFloat = 0x0003;
const int _waveFormatExtensible = 0xfffe;

/// A malformed or unsupported RIFF/WAVE stream.
final class WaveFormatException implements FormatException {
  const WaveFormatException(this.message, [this.offset]);

  @override
  final String message;
  @override
  final int? offset;
  @override
  Object? get source => null;

  @override
  String toString() => offset == null
      ? 'WaveFormatException: $message'
      : 'WaveFormatException at $offset: $message';
}

/// Decodes uncompressed RIFF/WAVE PCM and IEEE-float audio.
///
/// Supported source formats are PCM 8/16/24/32-bit, IEEE float32/float64 and
/// their WAVE_FORMAT_EXTENSIBLE equivalents. Unknown chunks and RIFF padding
/// bytes are skipped, so metadata-rich files remain valid.
abstract final class WaveDecoder {
  static NativePcmAudioBuffer decode(Uint8List bytes) {
    if (bytes.length < 12 || _ascii(bytes, 0, 4) != 'RIFF') {
      throw const WaveFormatException('expected little-endian RIFF header', 0);
    }
    if (_ascii(bytes, 8, 4) != 'WAVE') {
      throw const WaveFormatException('RIFF form is not WAVE', 8);
    }
    final ByteData data = ByteData.sublistView(bytes);
    int? format;
    int? channels;
    int? sampleRate;
    int? blockAlign;
    int? bitsPerSample;
    int? validBitsPerSample;
    int? dataOffset;
    int? dataLength;

    int cursor = 12;
    while (cursor + 8 <= bytes.length) {
      final String id = _ascii(bytes, cursor, 4);
      final int length = data.getUint32(cursor + 4, Endian.little);
      final int content = cursor + 8;
      if (length > bytes.length - content) {
        throw WaveFormatException('chunk $id exceeds the input', cursor);
      }
      if (id == 'fmt ') {
        if (length < 16) {
          throw WaveFormatException(
              'fmt chunk is shorter than 16 bytes', cursor);
        }
        format = data.getUint16(content, Endian.little);
        channels = data.getUint16(content + 2, Endian.little);
        sampleRate = data.getUint32(content + 4, Endian.little);
        blockAlign = data.getUint16(content + 12, Endian.little);
        bitsPerSample = data.getUint16(content + 14, Endian.little);
        validBitsPerSample = bitsPerSample;
        if (format == _waveFormatExtensible) {
          if (length < 40) {
            throw WaveFormatException(
              'WAVE_FORMAT_EXTENSIBLE fmt chunk is shorter than 40 bytes',
              cursor,
            );
          }
          validBitsPerSample = data.getUint16(content + 18, Endian.little);
          // The first DWORD of KSDATAFORMAT_SUBTYPE_* contains the original
          // WAVE format tag. The remaining GUID bytes identify the standard
          // audio subtype namespace.
          format = data.getUint32(content + 24, Endian.little);
        }
      } else if (id == 'data' && dataOffset == null) {
        dataOffset = content;
        dataLength = length;
      }
      cursor = content + length + (length.isOdd ? 1 : 0);
    }

    if (format == null) {
      throw const WaveFormatException('missing fmt chunk');
    }
    if (dataOffset == null || dataLength == null) {
      throw const WaveFormatException('missing data chunk');
    }
    if (channels == null ||
        channels <= 0 ||
        sampleRate == null ||
        sampleRate <= 0) {
      throw const WaveFormatException('invalid channel count or sample rate');
    }
    if (blockAlign == null || blockAlign <= 0 || bitsPerSample == null) {
      throw const WaveFormatException('invalid block alignment or bit depth');
    }
    final int bytesPerSample = (bitsPerSample + 7) ~/ 8;
    if (blockAlign < channels * bytesPerSample) {
      throw const WaveFormatException(
          'block alignment is smaller than one frame');
    }
    if (format != _waveFormatPcm && format != _waveFormatIeeeFloat) {
      throw WaveFormatException(
          'unsupported WAVE format tag 0x${format.toRadixString(16)}');
    }
    if (format == _waveFormatPcm &&
        bitsPerSample != 8 &&
        bitsPerSample != 16 &&
        bitsPerSample != 24 &&
        bitsPerSample != 32) {
      throw WaveFormatException('unsupported PCM depth: $bitsPerSample bits');
    }
    if (format == _waveFormatIeeeFloat &&
        bitsPerSample != 32 &&
        bitsPerSample != 64) {
      throw WaveFormatException(
          'unsupported IEEE-float depth: $bitsPerSample bits');
    }

    final int frames = dataLength ~/ blockAlign;
    final NativePcmAudioBuffer output = NativePcmAudioBuffer.allocate(
      sampleRate: sampleRate,
      channels: channels,
      frameCount: frames,
    );
    try {
      for (int frame = 0; frame < frames; frame++) {
        final int frameOffset = dataOffset + frame * blockAlign;
        for (int channel = 0; channel < channels; channel++) {
          final int offset = frameOffset + channel * bytesPerSample;
          final double sample = format == _waveFormatPcm
              ? _decodePcm(data, offset, bitsPerSample, validBitsPerSample!)
              : _decodeFloat(data, offset, bitsPerSample);
          output.samples[frame * channels + channel] = sample;
        }
      }
      return output;
    } on Object {
      output.dispose();
      rethrow;
    }
  }

  static double _decodePcm(ByteData data, int offset, int bits, int validBits) {
    switch (bits) {
      case 8:
        return (data.getUint8(offset) - 128) / 128.0;
      case 16:
        return data.getInt16(offset, Endian.little) / 32768.0;
      case 24:
        int value = data.getUint8(offset) |
            (data.getUint8(offset + 1) << 8) |
            (data.getUint8(offset + 2) << 16);
        if ((value & 0x800000) != 0) value |= ~0xffffff;
        return value / 8388608.0;
      case 32:
        final int value = data.getInt32(offset, Endian.little);
        if (validBits > 0 && validBits < 32) {
          final int shift = 32 - validBits;
          return (value >> shift) / (1 << (validBits - 1));
        }
        return value / 2147483648.0;
    }
    throw StateError('unreachable PCM depth');
  }

  static double _decodeFloat(ByteData data, int offset, int bits) {
    final double value = bits == 32
        ? data.getFloat32(offset, Endian.little)
        : data.getFloat64(offset, Endian.little);
    if (!value.isFinite) return 0;
    return value.clamp(-1.0, 1.0);
  }

  static String _ascii(Uint8List bytes, int offset, int length) =>
      String.fromCharCodes(bytes.sublist(offset, offset + length));
}
