/// Direct Dart FFI bindings for the subset of Core Audio used by WASAPI.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import '../audio_format.dart';

final Guid clsidMmDeviceEnumerator =
    Guid.parse('BCDE0395-E52F-467C-8E3D-C4579291692E');
final Guid iidMmDeviceEnumerator =
    Guid.parse('A95664D2-9614-4F35-A746-DE8DB63617E6');
final Guid iidAudioClient3 = Guid.parse('7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42');
final Guid iidAudioRenderClient =
    Guid.parse('F294ACFC-3146-4483-A7BF-ADDCA7C260E2');

final Guid _subtypePcm = Guid.parse('00000001-0000-0010-8000-00AA00389B71');
final Guid _subtypeFloat = Guid.parse('00000003-0000-0010-8000-00AA00389B71');
final Guid _friendlyNameProperty =
    Guid.parse('A45C254E-DF1C-4EFD-8020-67D146A850E0');

const int wasapiDeviceStateActive = 1;
const int wasapiDataFlowRender = 0;
const int wasapiDataFlowCapture = 1;
const int wasapiRoleConsole = 0;
const int wasapiRoleMultimedia = 1;
const int wasapiRoleCommunications = 2;
const int wasapiSharedMode = 0;
const int wasapiStreamFlagEventCallback = 0x00040000;
const int wasapiBufferFlagSilence = 0x2;

const int _waveFormatPcm = 1;
const int _waveFormatFloat = 3;
const int _waveFormatExtensible = 0xfffe;

const int _coinitMultithreaded = 0;
const int _clsctxAll = 23;
const int rpcEChangedMode = -2147417850;

typedef _CoInitializeExNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CoUninitializeNative = Void Function();
typedef _CoCreateInstanceNative = Int32 Function(
  Pointer<Uint8>,
  Pointer<Void>,
  Uint32,
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void>);
typedef _PropVariantClearNative = Int32 Function(Pointer<Uint8>);

typedef _CreateEventNative = IntPtr Function(
  Pointer<Void>,
  Int32,
  Int32,
  Pointer<Uint16>,
);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _SetEventNative = Int32 Function(IntPtr);
typedef _ResetEventNative = Int32 Function(IntPtr);
typedef _WaitForMultipleObjectsNative = Uint32 Function(
  Uint32,
  Pointer<IntPtr>,
  Int32,
  Uint32,
);
typedef _GetCurrentThreadIdNative = Uint32 Function();

typedef _MoveMemoryNative = Void Function(
  Pointer<Void>,
  Pointer<Void>,
  IntPtr,
);
typedef _ZeroMemoryNative = Void Function(Pointer<Void>, IntPtr);

typedef _InitializeLockNative = Void Function(Pointer<Void>);
typedef _AcquireLockNative = Void Function(Pointer<Void>);
typedef _TryAcquireLockNative = Uint8 Function(Pointer<Void>);
typedef _ReleaseLockNative = Void Function(Pointer<Void>);

typedef _AvSetCharacteristicsNative = IntPtr Function(
  Pointer<Uint16>,
  Pointer<Uint32>,
);
typedef _AvRevertCharacteristicsNative = Int32 Function(IntPtr);

/// Process-wide native entry points. Loading is lazy, so importing the audio
/// barrel remains harmless on a non-Windows VM.
final class WasapiNativeApi {
  WasapiNativeApi._(
    DynamicLibrary ole,
    DynamicLibrary system,
    DynamicLibrary nativeRuntime,
    DynamicLibrary multimediaScheduler,
  )   : coInitializeEx = ole.lookupFunction<_CoInitializeExNative,
            int Function(Pointer<Void>, int)>('CoInitializeEx'),
        coUninitialize =
            ole.lookupFunction<_CoUninitializeNative, void Function()>(
                'CoUninitialize'),
        coCreateInstance = ole.lookupFunction<
            _CoCreateInstanceNative,
            int Function(Pointer<Uint8>, Pointer<Void>, int, Pointer<Uint8>,
                Pointer<Pointer<Void>>)>('CoCreateInstance'),
        coTaskMemFree = ole.lookupFunction<_CoTaskMemFreeNative,
            void Function(Pointer<Void>)>('CoTaskMemFree'),
        propVariantClear = ole.lookupFunction<_PropVariantClearNative,
            int Function(Pointer<Uint8>)>('PropVariantClear'),
        createEvent = system.lookupFunction<_CreateEventNative,
            int Function(Pointer<Void>, int, int, Pointer<Uint16>)>(
          'CreateEventW',
        ),
        closeHandle =
            system.lookupFunction<_CloseHandleNative, int Function(int)>(
                'CloseHandle'),
        setEvent = system
            .lookupFunction<_SetEventNative, int Function(int)>('SetEvent'),
        resetEvent = system
            .lookupFunction<_ResetEventNative, int Function(int)>('ResetEvent'),
        waitForMultipleObjects = system.lookupFunction<
            _WaitForMultipleObjectsNative,
            int Function(int, Pointer<IntPtr>, int, int)>(
          'WaitForMultipleObjects',
        ),
        getCurrentThreadId =
            system.lookupFunction<_GetCurrentThreadIdNative, int Function()>(
          'GetCurrentThreadId',
          isLeaf: true,
        ),
        initializeLock = system.lookupFunction<_InitializeLockNative,
            void Function(Pointer<Void>)>('InitializeSRWLock'),
        acquireLock = system.lookupFunction<_AcquireLockNative,
            void Function(Pointer<Void>)>('AcquireSRWLockExclusive'),
        tryAcquireLock = system
            .lookupFunction<_TryAcquireLockNative, int Function(Pointer<Void>)>(
          'TryAcquireSRWLockExclusive',
          isLeaf: true,
        ),
        releaseLock = system
            .lookupFunction<_ReleaseLockNative, void Function(Pointer<Void>)>(
          'ReleaseSRWLockExclusive',
          isLeaf: true,
        ),
        moveMemory = nativeRuntime.lookupFunction<_MoveMemoryNative,
            void Function(Pointer<Void>, Pointer<Void>, int)>(
          'RtlMoveMemory',
          isLeaf: true,
        ),
        zeroMemory = nativeRuntime.lookupFunction<_ZeroMemoryNative,
            void Function(Pointer<Void>, int)>(
          'RtlZeroMemory',
          isLeaf: true,
        ),
        avSetCharacteristics = multimediaScheduler.lookupFunction<
            _AvSetCharacteristicsNative,
            int Function(Pointer<Uint16>, Pointer<Uint32>)>(
          'AvSetMmThreadCharacteristicsW',
        ),
        avRevertCharacteristics = multimediaScheduler.lookupFunction<
            _AvRevertCharacteristicsNative,
            int Function(int)>('AvRevertMmThreadCharacteristics');

  factory WasapiNativeApi.load() => WasapiNativeApi._(
        DynamicLibrary.open('ole32.dll'),
        DynamicLibrary.open('kernel32.dll'),
        DynamicLibrary.open('ntdll.dll'),
        DynamicLibrary.open('avrt.dll'),
      );

  final int Function(Pointer<Void>, int) coInitializeEx;
  final void Function() coUninitialize;
  final int Function(Pointer<Uint8>, Pointer<Void>, int, Pointer<Uint8>,
      Pointer<Pointer<Void>>) coCreateInstance;
  final void Function(Pointer<Void>) coTaskMemFree;
  final int Function(Pointer<Uint8>) propVariantClear;

  final int Function(Pointer<Void>, int, int, Pointer<Uint16>) createEvent;
  final int Function(int) closeHandle;
  final int Function(int) setEvent;
  final int Function(int) resetEvent;
  final int Function(int, Pointer<IntPtr>, int, int) waitForMultipleObjects;
  final int Function() getCurrentThreadId;

  final void Function(Pointer<Void>) initializeLock;
  final void Function(Pointer<Void>) acquireLock;
  final int Function(Pointer<Void>) tryAcquireLock;
  final void Function(Pointer<Void>) releaseLock;
  final void Function(Pointer<Void>, Pointer<Void>, int) moveMemory;
  final void Function(Pointer<Void>, int) zeroMemory;

  final int Function(Pointer<Uint16>, Pointer<Uint32>) avSetCharacteristics;
  final int Function(int) avRevertCharacteristics;

  /// Enters the multi-threaded COM apartment. The returned value says whether
  /// this call must be paired with [coUninitialize].
  bool initializeApartment() {
    final int result = hresult(coInitializeEx(nullptr, _coinitMultithreaded));
    if (result == rpcEChangedMode) return false;
    checkHresult(result, 'CoInitializeEx(COINIT_MULTITHREADED)');
    return true;
  }

  Pointer<Void> createDeviceEnumerator(NativeArena arena) {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    checkHresult(
      coCreateInstance(
        clsidMmDeviceEnumerator.allocateIn(arena),
        nullptr,
        _clsctxAll,
        iidMmDeviceEnumerator.allocateIn(arena),
        out,
      ),
      'CoCreateInstance(MMDeviceEnumerator)',
    );
    return out.value;
  }
}

typedef _EnumEndpointsNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _GetDefaultEndpointNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _GetDeviceNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint16>,
  Pointer<Pointer<Void>>,
);

final class MmDeviceEnumerator extends ComObject {
  MmDeviceEnumerator(super.pointer)
      : super(interfaceName: 'IMMDeviceEnumerator');

  late final int Function(Pointer<Void>, int, int, Pointer<Pointer<Void>>)
      _enumEndpoints = comMethod<_EnumEndpointsNative>(pointer, 3).asFunction();
  late final int Function(Pointer<Void>, int, int, Pointer<Pointer<Void>>)
      _getDefaultEndpoint =
      comMethod<_GetDefaultEndpointNative>(pointer, 4).asFunction();
  late final int Function(
          Pointer<Void>, Pointer<Uint16>, Pointer<Pointer<Void>>) _getDevice =
      comMethod<_GetDeviceNative>(pointer, 5).asFunction();

  int enumEndpoints(int flow, int stateMask, Pointer<Pointer<Void>> out) =>
      _enumEndpoints(pointer, flow, stateMask, out);
  int getDefaultEndpoint(int flow, int role, Pointer<Pointer<Void>> out) =>
      _getDefaultEndpoint(pointer, flow, role, out);
  int getDevice(Pointer<Uint16> id, Pointer<Pointer<Void>> out) =>
      _getDevice(pointer, id, out);
}

typedef _CollectionCountNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint32>,
);
typedef _CollectionItemNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Void>>,
);

final class MmDeviceCollection extends ComObject {
  MmDeviceCollection(super.pointer)
      : super(interfaceName: 'IMMDeviceCollection');

  late final int Function(Pointer<Void>, Pointer<Uint32>) _getCount =
      comMethod<_CollectionCountNative>(pointer, 3).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>) _item =
      comMethod<_CollectionItemNative>(pointer, 4).asFunction();

  int getCount(Pointer<Uint32> out) => _getCount(pointer, out);
  int item(int index, Pointer<Pointer<Void>> out) => _item(pointer, index, out);
}

typedef _DeviceActivateNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _OpenPropertyStoreNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _DeviceGetIdNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Uint16>>,
);

final class MmDevice extends ComObject {
  MmDevice(super.pointer) : super(interfaceName: 'IMMDevice');

  late final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Void>,
          Pointer<Pointer<Void>>) _activate =
      comMethod<_DeviceActivateNative>(pointer, 3).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      _openPropertyStore =
      comMethod<_OpenPropertyStoreNative>(pointer, 4).asFunction();
  late final int Function(Pointer<Void>, Pointer<Pointer<Uint16>>) _getId =
      comMethod<_DeviceGetIdNative>(pointer, 5).asFunction();

  int activateAudioClient3(
    Pointer<Uint8> iid,
    Pointer<Pointer<Void>> out,
  ) =>
      _activate(pointer, iid, _clsctxAll, nullptr, out);
  int openPropertyStore(Pointer<Pointer<Void>> out) =>
      _openPropertyStore(pointer, 0, out);
  int getId(Pointer<Pointer<Uint16>> out) => _getId(pointer, out);
}

typedef _PropertyGetValueNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);

final class PropertyStore extends ComObject {
  PropertyStore(super.pointer) : super(interfaceName: 'IPropertyStore');

  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)
      _getValue = comMethod<_PropertyGetValueNative>(pointer, 5).asFunction();

  String friendlyName(WasapiNativeApi api, NativeArena arena) {
    // PROPERTYKEY is GUID followed by DWORD pid, with 4 bytes trailing padding
    // under the 64-bit ABI. The callee only reads the first 20 bytes.
    final Pointer<Uint8> key = arena.allocate<Uint8>(24);
    _friendlyNameProperty.writeTo(key);
    key.cast<Uint32>()[4] = 14;
    final Pointer<Uint8> value = arena.allocate<Uint8>(24);
    checkHresult(_getValue(pointer, key, value),
        'IPropertyStore::GetValue(PKEY_Device_FriendlyName)');
    try {
      final int variantType = value.cast<Uint16>().value;
      if (variantType != 31) return '';
      final Pointer<Uint16> text = Pointer<Pointer<Uint16>>.fromAddress(
        value.address + 8,
      ).value;
      return readUtf16(text);
    } finally {
      api.propVariantClear(value);
    }
  }
}

typedef _AudioUintOutNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint32>,
);
typedef _AudioInt64OutNative = Int32 Function(
  Pointer<Void>,
  Pointer<Int64>,
);
typedef _AudioFormatSupportNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint8>,
  Pointer<Pointer<Uint8>>,
);
typedef _AudioGetMixFormatNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
);
typedef _AudioVoidNative = Int32 Function(Pointer<Void>);
typedef _AudioSetEventNative = Int32 Function(Pointer<Void>, IntPtr);
typedef _AudioGetServiceNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
);
typedef _AudioEnginePeriodNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _AudioInitializeSharedNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Uint8>,
  Pointer<Uint8>,
);

final class AudioClient3 extends ComObject {
  AudioClient3(super.pointer) : super(interfaceName: 'IAudioClient3');

  late final int Function(Pointer<Void>, Pointer<Uint32>) _getBufferSize =
      comMethod<_AudioUintOutNative>(pointer, 4).asFunction();
  late final int Function(Pointer<Void>, Pointer<Int64>) _getStreamLatency =
      comMethod<_AudioInt64OutNative>(pointer, 5).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint32>) _getCurrentPadding =
      comMethod<_AudioUintOutNative>(pointer, 6).asFunction();
  late final int Function(
          Pointer<Void>, int, Pointer<Uint8>, Pointer<Pointer<Uint8>>)
      _isFormatSupported =
      comMethod<_AudioFormatSupportNative>(pointer, 7).asFunction();
  late final int Function(Pointer<Void>, Pointer<Pointer<Uint8>>)
      _getMixFormat =
      comMethod<_AudioGetMixFormatNative>(pointer, 8).asFunction();
  late final int Function(Pointer<Void>) _start =
      comMethod<_AudioVoidNative>(pointer, 10).asFunction();
  late final int Function(Pointer<Void>) _stop =
      comMethod<_AudioVoidNative>(pointer, 11).asFunction();
  late final int Function(Pointer<Void>) _reset =
      comMethod<_AudioVoidNative>(pointer, 12).asFunction();
  late final int Function(Pointer<Void>, int) _setEventHandle =
      comMethod<_AudioSetEventNative>(pointer, 13).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>)
      _getService = comMethod<_AudioGetServiceNative>(pointer, 14).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>) _getEnginePeriod =
      comMethod<_AudioEnginePeriodNative>(pointer, 18).asFunction();
  late final int Function(
          Pointer<Void>, int, int, Pointer<Uint8>, Pointer<Uint8>)
      _initializeShared =
      comMethod<_AudioInitializeSharedNative>(pointer, 20).asFunction();

  int getBufferSize(Pointer<Uint32> out) => _getBufferSize(pointer, out);
  int getStreamLatency(Pointer<Int64> out) => _getStreamLatency(pointer, out);
  int getCurrentPadding(Pointer<Uint32> out) =>
      _getCurrentPadding(pointer, out);
  int getMixFormat(Pointer<Pointer<Uint8>> out) => _getMixFormat(pointer, out);
  int isFormatSupported(
    int shareMode,
    Pointer<Uint8> format,
    Pointer<Pointer<Uint8>> closest,
  ) =>
      _isFormatSupported(pointer, shareMode, format, closest);
  int getSharedModeEnginePeriod(
    Pointer<Uint8> format,
    Pointer<Uint32> defaultPeriod,
    Pointer<Uint32> fundamentalPeriod,
    Pointer<Uint32> minimumPeriod,
    Pointer<Uint32> maximumPeriod,
  ) =>
      _getEnginePeriod(pointer, format, defaultPeriod, fundamentalPeriod,
          minimumPeriod, maximumPeriod);
  int initializeSharedAudioStream(
    int flags,
    int periodFrames,
    Pointer<Uint8> format,
  ) =>
      _initializeShared(pointer, flags, periodFrames, format, nullptr);
  int setEventHandle(int handle) => _setEventHandle(pointer, handle);
  int getService(Pointer<Uint8> iid, Pointer<Pointer<Void>> out) =>
      _getService(pointer, iid, out);
  int start() => _start(pointer);
  int stop() => _stop(pointer);
  int reset() => _reset(pointer);
}

typedef _RenderGetBufferNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Uint8>>,
);
typedef _RenderReleaseBufferNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
);

final class AudioRenderClient extends ComObject {
  AudioRenderClient(super.pointer) : super(interfaceName: 'IAudioRenderClient');

  late final int Function(Pointer<Void>, int, Pointer<Pointer<Uint8>>)
      _getBuffer = comMethod<_RenderGetBufferNative>(pointer, 3).asFunction();
  late final int Function(Pointer<Void>, int, int) _releaseBuffer =
      comMethod<_RenderReleaseBufferNative>(pointer, 4).asFunction();

  int getBuffer(int frames, Pointer<Pointer<Uint8>> out) =>
      _getBuffer(pointer, frames, out);
  int releaseBuffer(int frames, int flags) =>
      _releaseBuffer(pointer, frames, flags);
}

/// Parsed WAVEFORMATEX/WAVEFORMATEXTENSIBLE data.
final class WasapiWaveFormat {
  const WasapiWaveFormat({
    required this.format,
    required this.formatTag,
    required this.validBitsPerSample,
  });

  final AudioFormat format;
  final int formatTag;
  final int validBitsPerSample;

  static WasapiWaveFormat read(Pointer<Uint8> pointer) {
    if (pointer == nullptr) {
      throw ArgumentError.value(pointer, 'pointer', 'must not be null');
    }
    ByteData data = ByteData.sublistView(pointer.asTypedList(18));
    final int tag = data.getUint16(0, Endian.little);
    final int channels = data.getUint16(2, Endian.little);
    final int sampleRate = data.getUint32(4, Endian.little);
    final int bits = data.getUint16(14, Endian.little);
    final int extra = data.getUint16(16, Endian.little);
    int validBits = bits;
    int? channelMask;
    int effectiveTag = tag;
    if (tag == _waveFormatExtensible && extra >= 22) {
      data = ByteData.sublistView(pointer.asTypedList(40));
      validBits = data.getUint16(18, Endian.little);
      channelMask = data.getUint32(20, Endian.little);
      effectiveTag = data.getUint32(24, Endian.little);
    }
    final AudioSampleFormat sample = switch ((effectiveTag, bits)) {
      (_waveFormatFloat, 32) => AudioSampleFormat.float32,
      (_waveFormatFloat, 64) => AudioSampleFormat.float64,
      (_waveFormatPcm, 8) => AudioSampleFormat.unsigned8,
      (_waveFormatPcm, 16) => AudioSampleFormat.signed16,
      (_waveFormatPcm, 24) => AudioSampleFormat.signed24,
      (_waveFormatPcm, 32) => AudioSampleFormat.signed32,
      _ => throw StateError('unsupported WAVE format tag=$effectiveTag, '
          'bits=$bits'),
    };
    return WasapiWaveFormat(
      format: AudioFormat(
        sampleRate: sampleRate,
        channels: channels,
        sampleFormat: sample,
        channelMask: channelMask,
      ),
      formatTag: tag,
      validBitsPerSample: validBits,
    );
  }

  static Pointer<Uint8> allocate(AudioFormat format, NativeArena arena) {
    if (!format.interleaved) {
      throw ArgumentError.value(
          format,
          'format',
          'WASAPI requires '
              'interleaved PCM in this backend');
    }
    final Pointer<Uint8> pointer = arena.allocate<Uint8>(40);
    final ByteData data = ByteData.sublistView(pointer.asTypedList(40));
    final int bits = format.bytesPerSample * 8;
    data.setUint16(0, _waveFormatExtensible, Endian.little);
    data.setUint16(2, format.channels, Endian.little);
    data.setUint32(4, format.sampleRate, Endian.little);
    data.setUint32(8, format.bytesPerSecond, Endian.little);
    data.setUint16(12, format.bytesPerFrame, Endian.little);
    data.setUint16(14, bits, Endian.little);
    data.setUint16(16, 22, Endian.little);
    data.setUint16(18, bits, Endian.little);
    data.setUint32(
      20,
      format.channelMask ?? defaultChannelMask(format.channels),
      Endian.little,
    );
    final Guid subtype =
        format.sampleFormat.isFloatingPoint ? _subtypeFloat : _subtypePcm;
    subtype.writeTo(Pointer<Uint8>.fromAddress(pointer.address + 24));
    return pointer;
  }

  static int defaultChannelMask(int channels) => switch (channels) {
        1 => 0x4,
        2 => 0x3,
        3 => 0x7,
        4 => 0x33,
        5 => 0x37,
        6 => 0x3f,
        7 => 0x13f,
        8 => 0x63f,
        _ => 0,
      };
}

int chooseWasapiPeriod({
  required int requested,
  required int fundamental,
  required int minimum,
  required int maximum,
}) {
  if (fundamental <= 0 || minimum <= 0 || maximum < minimum) {
    throw ArgumentError('invalid WASAPI engine-period range');
  }
  int value = requested.clamp(minimum, maximum);
  value = ((value + fundamental ~/ 2) ~/ fundamental) * fundamental;
  return value.clamp(minimum, maximum);
}

String readUtf16(Pointer<Uint16> pointer, {int maxCodeUnits = 32768}) {
  if (pointer == nullptr) return '';
  int length = 0;
  while (length < maxCodeUnits && pointer[length] != 0) {
    length++;
  }
  return String.fromCharCodes(pointer.asTypedList(length));
}
