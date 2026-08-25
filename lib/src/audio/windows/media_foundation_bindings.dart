/// The Media Foundation COM surface both audio paths dispatch through.
///
/// Extracted from `media_foundation_audio_decoder.dart` when the streaming
/// reader arrived, for one reason: a vtable slot number is a magic integer with
/// no compiler behind it, and two files that each keep their own copy of
/// `ReadSample is slot 9` will eventually disagree - silently, because calling
/// the wrong slot with the wrong signature does not fail, it corrupts. One
/// declaration per method, used by everything, is the only version of this
/// that stays correct.
///
/// Nothing here decides policy. Whether a failure is an exception or a null,
/// how much is read at a time, what format is requested - all of that belongs
/// to the callers.
library;

import 'dart:ffi';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';

/// `MF_VERSION` for the SDK this binds.
const int mfVersion = 0x00020070;

/// `MFSTARTUP_FULL`.
const int mfStartupFull = 0;

/// `MF_SOURCE_READER_FIRST_AUDIO_STREAM`.
const int mfFirstAudioStream = 0xfffffffd;

/// `MF_SOURCE_READER_ALL_STREAMS`.
const int mfAllStreams = 0xfffffffe;

/// `MF_SOURCE_READER_MEDIASOURCE`, the pseudo-stream that carries the
/// container's own attributes - which is where the duration lives.
const int mfMediaSourceStream = 0xffffffff;

/// `MF_SOURCE_READERF_*`, the flags `ReadSample` reports through.
const int mfSourceReaderError = 0x00000001;
const int mfSourceReaderEndOfStream = 0x00000002;
const int mfSourceReaderCurrentMediaTypeChanged = 0x00000020;
const int mfSourceReaderStreamTick = 0x00000100;

/// `VT_I8` and `VT_UI8`, the only two `PROPVARIANT` shapes this file reads or
/// writes. Both are inline 64-bit values with nothing to free, which is why no
/// `PropVariantClear` appears anywhere here.
const int variantTypeInt64 = 20;
const int variantTypeUint64 = 21;

/// A `PROPVARIANT` is 16 bytes of header and union on x86 and 24 on x64; 32
/// zeroed bytes is comfortably more than either and costs nothing in an arena.
const int propVariantBytes = 32;

final Guid mfMtMajorType = Guid.parse('48EBA18E-F8C9-4687-BF11-0A74C9F96A8F');
final Guid mfMediaTypeAudio =
    Guid.parse('73647561-0000-0010-8000-00AA00389B71');
final Guid mfMtSubtype = Guid.parse('F7E34C9A-42E8-4714-B74B-CB29D72C35E5');
final Guid mfAudioFormatFloat =
    Guid.parse('00000003-0000-0010-8000-00AA00389B71');
final Guid mfMtAudioChannels =
    Guid.parse('37E48BF5-645E-4C5B-89DE-ADA9E29B696A');
final Guid mfMtAudioSampleRate =
    Guid.parse('5FAEEAE7-0290-4C31-9E8A-C534F68D9DBA');

/// `MF_PD_DURATION`, in 100-nanosecond units. The whole reason a twenty-minute
/// file no longer has to be decoded to find out how long it is.
final Guid mfPdDuration = Guid.parse('6C990D33-BB8E-477A-8598-0D5D96FCD88A');

/// `GUID_NULL`, the "default time format" `SetCurrentPosition` wants.
final Guid guidNull = Guid.parse('00000000-0000-0000-0000-000000000000');

typedef _MfStartupNative = Int32 Function(Uint32, Uint32);
typedef _MfShutdownNative = Int32 Function();
typedef _MfCreateMediaTypeNative = Int32 Function(Pointer<Pointer<Void>>);
typedef _MfCreateSourceReaderFromUrlNative = Int32 Function(
  Pointer<Uint16>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

/// `mfplat.dll` and `mfreadwrite.dll`, bound once per load.
final class MediaFoundationApi {
  MediaFoundationApi._(DynamicLibrary platform, DynamicLibrary reader)
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

  factory MediaFoundationApi.load() => MediaFoundationApi._(
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

/// `IMFAttributes`, which `IMFMediaType` is.
final class MfAttributes extends ComObject {
  MfAttributes(super.pointer, String name) : super(interfaceName: name);

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
typedef _SetCurrentPositionNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint8>,
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
typedef _FlushNative = Int32 Function(Pointer<Void>, Uint32);
typedef _GetPresentationAttributeNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint8>,
  Pointer<Uint8>,
);

/// `IMFSourceReader`, in synchronous mode.
///
/// The slot numbers are the vtable order of the interface as declared in
/// `mfreadwrite.h`: three `IUnknown` methods, then `GetStreamSelection`,
/// `SetStreamSelection`, `GetNativeMediaType`, `GetCurrentMediaType`,
/// `SetCurrentMediaType`, `SetCurrentPosition`, `ReadSample`, `Flush`,
/// `GetServiceForStream`, `GetPresentationAttribute`.
final class MfSourceReader extends ComObject {
  MfSourceReader(super.pointer) : super(interfaceName: 'IMFSourceReader');

  late final int Function(Pointer<Void>, int, int) _setSelection =
      comMethod<_SetStreamSelectionNative>(pointer, 4).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      _getCurrentType =
      comMethod<_GetCurrentMediaTypeNative>(pointer, 6).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
      _setCurrentType =
      comMethod<_SetCurrentMediaTypeNative>(pointer, 7).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)
      _setCurrentPosition =
      comMethod<_SetCurrentPositionNative>(pointer, 8).asFunction();
  late final int Function(Pointer<Void>, int, int, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Int64>, Pointer<Pointer<Void>>) _readSample =
      comMethod<_ReadSampleNative>(pointer, 9).asFunction();
  late final int Function(Pointer<Void>, int) _flush =
      comMethod<_FlushNative>(pointer, 10).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Uint8>, Pointer<Uint8>)
      _getPresentationAttribute =
      comMethod<_GetPresentationAttributeNative>(pointer, 12).asFunction();

  int setStreamSelection(int stream, bool selected) =>
      _setSelection(pointer, stream, selected ? 1 : 0);
  int getCurrentMediaType(int stream, Pointer<Pointer<Void>> out) =>
      _getCurrentType(pointer, stream, out);
  int setCurrentMediaType(int stream, Pointer<Void> type) =>
      _setCurrentType(pointer, stream, nullptr, type);
  int flush(int stream) => _flush(pointer, stream);

  /// `SetCurrentPosition(GUID_NULL, VT_I8 hundredNanoseconds)`.
  ///
  /// The time format GUID and the position both cross as raw byte buffers
  /// because that is what a `REFGUID` and a `REFPROPVARIANT` are on the ABI.
  int setCurrentPosition(int hundredNanoseconds, NativeArena arena) {
    final Pointer<Uint8> variant = arena.allocate<Uint8>(propVariantBytes);
    variant.cast<Uint16>()[0] = variantTypeInt64;
    variant.cast<Int64>()[1] = hundredNanoseconds;
    return _setCurrentPosition(pointer, guidNull.allocateIn(arena), variant);
  }

  /// A 64-bit presentation attribute, or null when the source has none.
  ///
  /// Null rather than a throw because "this container does not declare a
  /// duration" is an ordinary answer for a live stream or a truncated file,
  /// and the caller's fallback (report zero, keep playing) is better than a
  /// stack trace.
  int? getUint64PresentationAttribute(
    int stream,
    Guid attribute,
    NativeArena arena,
  ) {
    final Pointer<Uint8> variant = arena.allocate<Uint8>(propVariantBytes);
    final int hr = hresult(
      _getPresentationAttribute(
        pointer,
        stream,
        attribute.allocateIn(arena),
        variant,
      ),
    );
    if (hr < 0) return null;
    final int type = variant.cast<Uint16>()[0];
    if (type != variantTypeUint64 && type != variantTypeInt64) return null;
    // Both are stored inline in the union, so there is nothing here that
    // `PropVariantClear` would have released.
    return variant.cast<Int64>()[1];
  }

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

/// `IMFSample`.
final class MfSample extends ComObject {
  MfSample(super.pointer) : super(interfaceName: 'IMFSample');

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

/// `IMFMediaBuffer`. The bytes it hands out are only valid between [lock] and
/// [unlock], which is the rule the decoder's copy discipline exists for.
final class MfMediaBuffer extends ComObject {
  MfMediaBuffer(super.pointer) : super(interfaceName: 'IMFMediaBuffer');

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
