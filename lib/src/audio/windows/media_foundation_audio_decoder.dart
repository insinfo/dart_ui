/// Windows Media Foundation audio decoding through direct Dart FFI.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import '../native/native_pcm_audio_buffer.dart';
import 'wasapi_bindings.dart';

const int _mfVersion = 0x00020070;
const int _mfStartupFull = 0;
const int _firstAudioStream = 0xfffffffd;
const int _allStreams = 0xfffffffe;
const int _endOfStream = 0x00000002;

final Guid _mfMtMajorType = Guid.parse('48EBA18E-F8C9-4687-BF11-0A74C9F96A8F');
final Guid _mfMediaTypeAudio =
    Guid.parse('73647561-0000-0010-8000-00AA00389B71');
final Guid _mfMtSubtype = Guid.parse('F7E34C9A-42E8-4714-B74B-CB29D72C35E5');
final Guid _mfAudioFormatFloat =
    Guid.parse('00000003-0000-0010-8000-00AA00389B71');
final Guid _mfMtAudioChannels =
    Guid.parse('37E48BF5-645E-4C5B-89DE-ADA9E29B696A');
final Guid _mfMtAudioSampleRate =
    Guid.parse('5FAEEAE7-0290-4C31-9E8A-C534F68D9DBA');

typedef _MfStartupNative = Int32 Function(Uint32, Uint32);
typedef _MfShutdownNative = Int32 Function();
typedef _MfCreateMediaTypeNative = Int32 Function(Pointer<Pointer<Void>>);
typedef _MfCreateSourceReaderFromUrlNative = Int32 Function(
  Pointer<Uint16>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

/// Decodes audio formats installed in Windows Media Foundation, including MP3.
///
/// Decoding is synchronous and intended for a worker/audio isolate before its
/// realtime pump starts. The returned float32 PCM buffer has explicit
/// ownership and must be disposed by the caller.
abstract final class MediaFoundationAudioDecoder {
  static NativePcmAudioBuffer decodeFile(String path) {
    final _MediaFoundationApi api = _MediaFoundationApi.load();
    final WasapiNativeApi com = WasapiNativeApi.load();
    final bool ownsApartment = com.initializeApartment();
    bool started = false;
    final NativeArena arena = NativeArena();
    _MfSourceReader? reader;
    _MfAttributes? requestedType;
    _MfAttributes? currentType;
    try {
      checkHresult(api.startup(_mfVersion, _mfStartupFull), 'MFStartup');
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
      reader = _MfSourceReader(readerOut.value);
      checkHresult(
        reader.setStreamSelection(_allStreams, false),
        'IMFSourceReader::SetStreamSelection(all, false)',
      );
      checkHresult(
        reader.setStreamSelection(_firstAudioStream, true),
        'IMFSourceReader::SetStreamSelection(audio, true)',
      );

      final Pointer<Pointer<Void>> typeOut = arena.allocateOutPointer();
      checkHresult(api.createMediaType(typeOut), 'MFCreateMediaType');
      requestedType = _MfAttributes(typeOut.value, 'IMFMediaType');
      requestedType
        ..setGuid(_mfMtMajorType, _mfMediaTypeAudio, arena)
        ..setGuid(_mfMtSubtype, _mfAudioFormatFloat, arena);
      checkHresult(
        reader.setCurrentMediaType(_firstAudioStream, requestedType.pointer),
        'IMFSourceReader::SetCurrentMediaType(float32)',
      );

      typeOut.value = nullptr;
      checkHresult(
        reader.getCurrentMediaType(_firstAudioStream, typeOut),
        'IMFSourceReader::GetCurrentMediaType',
      );
      currentType = _MfAttributes(typeOut.value, 'IMFMediaType');
      final int channels = currentType.getUint32(_mfMtAudioChannels, arena);
      final int sampleRate = currentType.getUint32(_mfMtAudioSampleRate, arena);
      if (channels <= 0 || sampleRate <= 0) {
        throw StateError('Media Foundation returned an invalid PCM format');
      }

      final BytesBuilder pcm = BytesBuilder(copy: false);
      final Pointer<Uint32> actualStream = arena<Uint32>();
      final Pointer<Uint32> flags = arena<Uint32>();
      final Pointer<Int64> timestamp = arena<Int64>();
      final Pointer<Pointer<Void>> sampleOut = arena.allocateOutPointer();
      while (true) {
        sampleOut.value = nullptr;
        flags.value = 0;
        checkHresult(
          reader.readSample(
            _firstAudioStream,
            actualStream,
            flags,
            timestamp,
            sampleOut,
          ),
          'IMFSourceReader::ReadSample',
        );
        if (sampleOut.value != nullptr) {
          final _MfSample sample = _MfSample(sampleOut.value);
          try {
            final Pointer<Pointer<Void>> bufferOut = arena.allocateOutPointer();
            bufferOut.value = nullptr;
            checkHresult(
              sample.convertToContiguousBuffer(bufferOut),
              'IMFSample::ConvertToContiguousBuffer',
            );
            final _MfMediaBuffer buffer = _MfMediaBuffer(bufferOut.value);
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
        if ((flags.value & _endOfStream) != 0) break;
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

final class _MediaFoundationApi {
  _MediaFoundationApi._(DynamicLibrary platform, DynamicLibrary reader)
      : startup =
            platform.lookupFunction<_MfStartupNative, int Function(int, int)>(
                'MFStartup'),
        shutdown = platform
            .lookupFunction<_MfShutdownNative, int Function()>('MFShutdown'),
        createMediaType = platform.lookupFunction<_MfCreateMediaTypeNative,
            int Function(Pointer<Pointer<Void>>)>('MFCreateMediaType'),
        createSourceReaderFromUrl = reader.lookupFunction<
            _MfCreateSourceReaderFromUrlNative,
            int Function(Pointer<Uint16>, Pointer<Void>,
                Pointer<Pointer<Void>>)>('MFCreateSourceReaderFromURL');

  factory _MediaFoundationApi.load() => _MediaFoundationApi._(
        DynamicLibrary.open('mfplat.dll'),
        DynamicLibrary.open('mfreadwrite.dll'),
      );

  final int Function(int, int) startup;
  final int Function() shutdown;
  final int Function(Pointer<Pointer<Void>>) createMediaType;
  final int Function(
    Pointer<Uint16>,
    Pointer<Void>,
    Pointer<Pointer<Void>>,
  ) createSourceReaderFromUrl;
}

typedef _GetUint32Native = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _SetGuidNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);

final class _MfAttributes extends ComObject {
  _MfAttributes(super.pointer, String name) : super(interfaceName: name);

  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>)
      _getUint32 = comMethod<_GetUint32Native>(pointer, 7).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)
      _setGuid = comMethod<_SetGuidNative>(pointer, 24).asFunction();

  int getUint32(Guid key, NativeArena arena) {
    final Pointer<Uint32> value = arena<Uint32>();
    checkHresult(
      _getUint32(pointer, key.allocateIn(arena), value),
      '$interfaceName::GetUINT32($key)',
    );
    return value.value;
  }

  void setGuid(Guid key, Guid value, NativeArena arena) {
    checkHresult(
      _setGuid(pointer, key.allocateIn(arena), value.allocateIn(arena)),
      '$interfaceName::SetGUID($key)',
    );
  }
}

typedef _SetStreamSelectionNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Int32,
);
typedef _GetCurrentMediaTypeNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _SetCurrentMediaTypeNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _ReadSampleNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Int64>,
  Pointer<Pointer<Void>>,
);

final class _MfSourceReader extends ComObject {
  _MfSourceReader(super.pointer) : super(interfaceName: 'IMFSourceReader');

  late final int Function(Pointer<Void>, int, int) _setSelection =
      comMethod<_SetStreamSelectionNative>(pointer, 4).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      _getCurrentType =
      comMethod<_GetCurrentMediaTypeNative>(pointer, 6).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
      _setCurrentType =
      comMethod<_SetCurrentMediaTypeNative>(pointer, 7).asFunction();
  late final int Function(Pointer<Void>, int, int, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Int64>, Pointer<Pointer<Void>>) _readSample =
      comMethod<_ReadSampleNative>(pointer, 9).asFunction();

  int setStreamSelection(int stream, bool selected) =>
      _setSelection(pointer, stream, selected ? 1 : 0);
  int getCurrentMediaType(int stream, Pointer<Pointer<Void>> out) =>
      _getCurrentType(pointer, stream, out);
  int setCurrentMediaType(int stream, Pointer<Void> type) =>
      _setCurrentType(pointer, stream, nullptr, type);
  int readSample(
    int stream,
    Pointer<Uint32> actualStream,
    Pointer<Uint32> flags,
    Pointer<Int64> timestamp,
    Pointer<Pointer<Void>> sample,
  ) =>
      _readSample(
        pointer,
        stream,
        0,
        actualStream,
        flags,
        timestamp,
        sample,
      );
}

typedef _ConvertToBufferNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

final class _MfSample extends ComObject {
  _MfSample(super.pointer) : super(interfaceName: 'IMFSample');

  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _convert =
      comMethod<_ConvertToBufferNative>(pointer, 41).asFunction();

  int convertToContiguousBuffer(Pointer<Pointer<Void>> out) =>
      _convert(pointer, out);
}

typedef _BufferLockNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _BufferUnlockNative = Int32 Function(Pointer<Void>);

final class _MfMediaBuffer extends ComObject {
  _MfMediaBuffer(super.pointer) : super(interfaceName: 'IMFMediaBuffer');

  late final int Function(Pointer<Void>, Pointer<Pointer<Uint8>>,
          Pointer<Uint32>, Pointer<Uint32>) _lock =
      comMethod<_BufferLockNative>(pointer, 3).asFunction();
  late final int Function(Pointer<Void>) _unlock =
      comMethod<_BufferUnlockNative>(pointer, 4).asFunction();

  int lock(
    Pointer<Pointer<Uint8>> bytes,
    Pointer<Uint32> maximum,
    Pointer<Uint32> current,
  ) =>
      _lock(pointer, bytes, maximum, current);
  int unlock() => _unlock(pointer);
}
