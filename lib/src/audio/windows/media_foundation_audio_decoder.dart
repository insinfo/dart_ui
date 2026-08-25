/// Windows Media Foundation audio decoding through direct Dart FFI.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import '../native/native_pcm_audio_buffer.dart';
import 'media_foundation_bindings.dart';
import 'wasapi_bindings.dart';

/// Decodes audio formats installed in Windows Media Foundation, including MP3.
///
/// Decoding is synchronous and materialises the **whole** track, which is the
/// right shape for a sound effect and the wrong one for a film: the cost is
/// linear in the length of the file, both in time before the first sample and
/// in memory for all of them. `MediaFoundationAudioReader` is the incremental
/// form and is what the file playback path uses; this one stays because a
/// caller that wants the samples themselves - an analyser, an encoder, a drum
/// pad - genuinely does want all of them at once.
///
/// The returned float32 PCM buffer has explicit ownership and must be disposed
/// by the caller.
abstract final class MediaFoundationAudioDecoder {
  static NativePcmAudioBuffer decodeFile(String path) {
    final MediaFoundationApi api = MediaFoundationApi.load();
    final WasapiNativeApi com = WasapiNativeApi.load();
    final bool ownsApartment = com.initializeApartment();
    bool started = false;
    final NativeArena arena = NativeArena();
    MfSourceReader? reader;
    MfAttributes? requestedType;
    MfAttributes? currentType;
    try {
      checkHresult(api.startup(mfVersion, mfStartupFull), 'MFStartup');
      started = true;
      final Pointer<Pointer<Void>> readerOut = arena.allocateOutPointer();
      checkHresult(
        api.createSourceReaderFromUrl(
          arena.allocateUtf16(path),
          nullptr,
          readerOut,
        ),
        'MFCreateSourceReaderFromURL',
        detail: path,
      );
      reader = MfSourceReader(readerOut.value);
      checkHresult(
        reader.setStreamSelection(mfAllStreams, false),
        'IMFSourceReader::SetStreamSelection(all, false)',
      );
      checkHresult(
        reader.setStreamSelection(mfFirstAudioStream, true),
        'IMFSourceReader::SetStreamSelection(audio, true)',
      );

      final Pointer<Pointer<Void>> typeOut = arena.allocateOutPointer();
      checkHresult(api.createMediaType(typeOut), 'MFCreateMediaType');
      requestedType = MfAttributes(typeOut.value, 'IMFMediaType');
      requestedType
        ..setGuid(mfMtMajorType, mfMediaTypeAudio, arena)
        ..setGuid(mfMtSubtype, mfAudioFormatFloat, arena);
      checkHresult(
        reader.setCurrentMediaType(mfFirstAudioStream, requestedType.pointer),
        'IMFSourceReader::SetCurrentMediaType(float32)',
      );

      typeOut.value = nullptr;
      checkHresult(
        reader.getCurrentMediaType(mfFirstAudioStream, typeOut),
        'IMFSourceReader::GetCurrentMediaType',
      );
      currentType = MfAttributes(typeOut.value, 'IMFMediaType');
      final int channels = currentType.getUint32(mfMtAudioChannels, arena);
      final int sampleRate = currentType.getUint32(mfMtAudioSampleRate, arena);
      if (channels <= 0 || sampleRate <= 0) {
        throw StateError('Media Foundation returned an invalid PCM format');
      }

      // IMFMediaBuffer owns the bytes only while it is locked. BytesBuilder
      // with copy:false may retain the Uint8List view past Unlock/Release,
      // which turns longer MP3 files into reused native memory and audible
      // noise. Copy every chunk while the buffer is still locked so the final
      // PCM is genuinely owned by the decoder.
      final BytesBuilder pcm = BytesBuilder(copy: true);
      final Pointer<Uint32> actualStream = arena<Uint32>();
      final Pointer<Uint32> flags = arena<Uint32>();
      final Pointer<Int64> timestamp = arena<Int64>();
      final Pointer<Pointer<Void>> sampleOut = arena.allocateOutPointer();
      while (true) {
        sampleOut.value = nullptr;
        flags.value = 0;
        checkHresult(
          reader.readSample(
            mfFirstAudioStream,
            actualStream,
            flags,
            timestamp,
            sampleOut,
          ),
          'IMFSourceReader::ReadSample',
        );
        if (sampleOut.value != nullptr) {
          final MfSample sample = MfSample(sampleOut.value);
          try {
            final Pointer<Pointer<Void>> bufferOut = arena.allocateOutPointer();
            bufferOut.value = nullptr;
            checkHresult(
              sample.convertToContiguousBuffer(bufferOut),
              'IMFSample::ConvertToContiguousBuffer',
            );
            final MfMediaBuffer buffer = MfMediaBuffer(bufferOut.value);
            try {
              final Pointer<Pointer<Uint8>> bytesOut = arena<Pointer<Uint8>>();
              final Pointer<Uint32> maximum = arena<Uint32>();
              final Pointer<Uint32> current = arena<Uint32>();
              checkHresult(
                buffer.lock(bytesOut, maximum, current),
                'IMFMediaBuffer::Lock',
              );
              try {
                if (current.value > 0) {
                  pcm.add(bytesOut.value.asTypedList(current.value));
                }
              } finally {
                checkHresult(buffer.unlock(), 'IMFMediaBuffer::Unlock');
              }
            } finally {
              buffer.dispose();
            }
          } finally {
            sample.dispose();
          }
        }
        if ((flags.value & mfSourceReaderEndOfStream) != 0) break;
      }
      final Uint8List bytes = pcm.takeBytes();
      final int bytesPerFrame = channels * sizeOf<Float>();
      final int frames = bytes.length ~/ bytesPerFrame;
      final NativePcmAudioBuffer output = NativePcmAudioBuffer.allocate(
        sampleRate: sampleRate,
        channels: channels,
        frameCount: frames,
      );
      output.samples
          .cast<Uint8>()
          .asTypedList(frames * bytesPerFrame)
          .setAll(0, bytes.take(frames * bytesPerFrame));
      return output;
    } finally {
      currentType?.dispose();
      requestedType?.dispose();
      reader?.dispose();
      arena.dispose();
      if (started) checkHresult(api.shutdown(), 'MFShutdown');
      if (ownsApartment) com.coUninitialize();
    }
  }
}
