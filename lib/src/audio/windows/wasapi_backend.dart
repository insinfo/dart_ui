/// Windows Audio Session API backend built directly on COM vtables.
library;

import 'dart:ffi';
import 'dart:io';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import '../audio_device.dart';
import '../audio_format.dart';
import 'wasapi_bindings.dart';
import 'wasapi_render_stream.dart';

/// Event-driven Windows audio using `IAudioClient3` shared engine periods.
final class WasapiAudioBackend implements AudioBackend {
  WasapiAudioBackend();

  WasapiNativeApi? _nativeApi;
  Object? _loadError;

  WasapiNativeApi? get _tryApi {
    if (!Platform.isWindows) return null;
    if (_nativeApi != null) return _nativeApi;
    if (_loadError != null) return null;
    try {
      return _nativeApi = WasapiNativeApi.load();
    } on Object catch (error) {
      _loadError = error;
      return null;
    }
  }

  WasapiNativeApi get _api {
    final WasapiNativeApi? value = _tryApi;
    if (value == null) {
      throw AudioBackendException(
        'WASAPI initialization',
        Platform.isWindows
            ? 'required system entry points could not be loaded: $_loadError'
            : 'WASAPI is only available on Windows',
      );
    }
    return value;
  }

  @override
  String get id => 'wasapi-iaudioclient3';

  @override
  String get name => 'Windows Audio Session API (IAudioClient3)';

  @override
  bool get isAvailable => _tryApi != null;

  @override
  List<AudioDeviceInfo> enumerateDevices({
    AudioDeviceDirection direction = AudioDeviceDirection.output,
    AudioDeviceRole role = AudioDeviceRole.multimedia,
  }) {
    final WasapiNativeApi api = _api;
    final NativeArena arena = NativeArena();
    final List<ComObject> objects = <ComObject>[];
    final bool uninitialize = api.initializeApartment();
    try {
      final MmDeviceEnumerator enumerator =
          MmDeviceEnumerator(api.createDeviceEnumerator(arena));
      objects.add(enumerator);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();

      String? defaultId;
      out.value = nullptr;
      final int defaultResult = hresult(enumerator.getDefaultEndpoint(
        _flow(direction),
        _role(role),
        out,
      ));
      if (!failed(defaultResult) && out.value != nullptr) {
        final MmDevice device = MmDevice(out.value);
        try {
          defaultId = _deviceId(api, device, arena);
        } finally {
          device.dispose();
        }
      }

      out.value = nullptr;
      checkHresult(
        enumerator.enumEndpoints(
          _flow(direction),
          wasapiDeviceStateActive,
          out,
        ),
        'IMMDeviceEnumerator::EnumAudioEndpoints',
      );
      final MmDeviceCollection collection = MmDeviceCollection(out.value);
      objects.add(collection);
      final Pointer<Uint32> count = arena.allocate<Uint32>(sizeOf<Uint32>());
      checkHresult(
        collection.getCount(count),
        'IMMDeviceCollection::GetCount',
      );

      final List<AudioDeviceInfo> result = <AudioDeviceInfo>[];
      for (int index = 0; index < count.value; index++) {
        out.value = nullptr;
        checkHresult(
          collection.item(index, out),
          'IMMDeviceCollection::Item($index)',
        );
        final MmDevice device = MmDevice(out.value);
        try {
          final String deviceId = _deviceId(api, device, arena);
          result.add(AudioDeviceInfo(
            id: deviceId,
            name: _deviceName(api, device, arena, fallback: deviceId),
            direction: direction,
            isDefault: deviceId == defaultId,
          ));
        } finally {
          device.dispose();
        }
      }
      return result;
    } finally {
      for (int index = objects.length - 1; index >= 0; index--) {
        objects[index].dispose();
      }
      arena.dispose();
      if (uninitialize) api.coUninitialize();
    }
  }

  /// The format the shared engine mixes at, without opening a stream.
  ///
  /// ## Why this exists next to [openStream]
  ///
  /// A caller that only needs to *know* the format - to size a buffer, to
  /// report a duration in output frames, to decide whether resampling is
  /// needed - can get it from `IAudioClient::GetMixFormat`, which is a
  /// property read. [openStream] answers the same question as a side effect of
  /// `InitializeSharedAudioStream`, and that call spins the Windows audio
  /// engine up for the process: measured at around half a second the first
  /// time it happens and a few tens of milliseconds afterwards.
  ///
  /// Paying that in the isolate that is *about* to render is unavoidable.
  /// Paying it twice - once to probe and once to render - is not, and the
  /// difference is the half second between asking for a file and hearing it.
  ///
  /// Returns null when there is no endpoint to ask, which is the same "no
  /// audio output is a state, not an error" rule the rest of this path
  /// follows.
  AudioFormat? defaultRenderMixFormat({
    AudioDeviceRole role = AudioDeviceRole.multimedia,
  }) {
    final WasapiNativeApi? api = _tryApi;
    if (api == null) return null;
    final NativeArena arena = NativeArena();
    final bool uninitialize = api.initializeApartment();
    MmDeviceEnumerator? enumerator;
    MmDevice? device;
    AudioClient3? audioClient;
    Pointer<Uint8> allocatedFormat = nullptr;
    try {
      enumerator = MmDeviceEnumerator(api.createDeviceEnumerator(arena));
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      out.value = nullptr;
      if (failed(enumerator.getDefaultEndpoint(
        wasapiDataFlowRender,
        _role(role),
        out,
      ))) {
        return null;
      }
      device = MmDevice(out.value);

      out.value = nullptr;
      if (failed(device.activateAudioClient3(
        iidAudioClient3.allocateIn(arena),
        out,
      ))) {
        return null;
      }
      audioClient = AudioClient3(out.value);

      final Pointer<Pointer<Uint8>> formatOut =
          arena.allocate<Pointer<Uint8>>(sizeOf<Pointer<Uint8>>());
      formatOut.value = nullptr;
      if (failed(audioClient.getMixFormat(formatOut)) ||
          formatOut.value == nullptr) {
        return null;
      }
      allocatedFormat = formatOut.value;
      return WasapiWaveFormat.read(allocatedFormat).format;
    } on Object {
      return null;
    } finally {
      if (allocatedFormat != nullptr) {
        api.coTaskMemFree(allocatedFormat.cast<Void>());
      }
      audioClient?.dispose();
      device?.dispose();
      enumerator?.dispose();
      arena.dispose();
      if (uninitialize) api.coUninitialize();
    }
  }

  @override
  WasapiRenderStream openStream(AudioStreamRequest request) {
    if (request.direction != AudioDeviceDirection.output) {
      throw UnsupportedError(
          'capture will be implemented after the IAudioClient3 render path');
    }
    if (request.shareMode != AudioShareMode.shared) {
      throw UnsupportedError(
          'the first IAudioClient3 backend implements shared low-latency mode');
    }

    final WasapiNativeApi api = _api;
    final NativeArena arena = NativeArena();
    final bool uninitialize = api.initializeApartment();
    MmDeviceEnumerator? enumerator;
    MmDevice? device;
    AudioClient3? audioClient;
    AudioRenderClient? renderClient;
    Pointer<Uint8> allocatedFormat = nullptr;
    Pointer<Uint8> allocatedClosest = nullptr;
    int audioEvent = 0;
    int stopEvent = 0;
    var handedOff = false;
    try {
      enumerator = MmDeviceEnumerator(api.createDeviceEnumerator(arena));
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      out.value = nullptr;
      if (request.deviceId == null) {
        checkHresult(
          enumerator.getDefaultEndpoint(
            wasapiDataFlowRender,
            _role(request.role),
            out,
          ),
          'IMMDeviceEnumerator::GetDefaultAudioEndpoint',
        );
      } else {
        checkHresult(
          enumerator.getDevice(arena.allocateUtf16(request.deviceId!), out),
          'IMMDeviceEnumerator::GetDevice',
        );
      }
      device = MmDevice(out.value);

      out.value = nullptr;
      checkHresult(
        device.activateAudioClient3(iidAudioClient3.allocateIn(arena), out),
        'IMMDevice::Activate(IAudioClient3)',
      );
      audioClient = AudioClient3(out.value);

      Pointer<Uint8> waveFormat;
      if (request.preferredFormat == null) {
        final Pointer<Pointer<Uint8>> formatOut =
            arena.allocate<Pointer<Uint8>>(sizeOf<Pointer<Uint8>>());
        formatOut.value = nullptr;
        checkHresult(
          audioClient.getMixFormat(formatOut),
          'IAudioClient::GetMixFormat',
        );
        allocatedFormat = formatOut.value;
        waveFormat = allocatedFormat;
      } else {
        final Pointer<Uint8> requested =
            WasapiWaveFormat.allocate(request.preferredFormat!, arena);
        final Pointer<Pointer<Uint8>> closest =
            arena.allocate<Pointer<Uint8>>(sizeOf<Pointer<Uint8>>());
        closest.value = nullptr;
        final int supported = hresult(audioClient.isFormatSupported(
          wasapiSharedMode,
          requested,
          closest,
        ));
        if (failed(supported)) {
          checkHresult(supported, 'IAudioClient::IsFormatSupported');
        }
        allocatedClosest = closest.value;
        waveFormat = supported == 0 || allocatedClosest == nullptr
            ? requested
            : allocatedClosest;
      }

      final WasapiWaveFormat parsed = WasapiWaveFormat.read(waveFormat);
      final Pointer<Uint32> defaultPeriod =
          arena.allocate<Uint32>(sizeOf<Uint32>());
      final Pointer<Uint32> fundamentalPeriod =
          arena.allocate<Uint32>(sizeOf<Uint32>());
      final Pointer<Uint32> minimumPeriod =
          arena.allocate<Uint32>(sizeOf<Uint32>());
      final Pointer<Uint32> maximumPeriod =
          arena.allocate<Uint32>(sizeOf<Uint32>());
      checkHresult(
        audioClient.getSharedModeEnginePeriod(
          waveFormat,
          defaultPeriod,
          fundamentalPeriod,
          minimumPeriod,
          maximumPeriod,
        ),
        'IAudioClient3::GetSharedModeEnginePeriod',
      );
      final int periodFrames = request.preferredPeriodFrames == null
          ? defaultPeriod.value
          : chooseWasapiPeriod(
              requested: request.preferredPeriodFrames!,
              fundamental: fundamentalPeriod.value,
              minimum: minimumPeriod.value,
              maximum: maximumPeriod.value,
            );

      checkHresult(
        audioClient.initializeSharedAudioStream(
          // IAudioClient3 accepts EVENTCALLBACK as its only stream flag. The
          // broader IAudioClient::Initialize flag set is not valid here.
          wasapiStreamFlagEventCallback,
          periodFrames,
          waveFormat,
        ),
        'IAudioClient3::InitializeSharedAudioStream',
      );

      audioEvent = api.createEvent(nullptr, 0, 0, nullptr.cast<Uint16>());
      stopEvent = api.createEvent(nullptr, 1, 0, nullptr.cast<Uint16>());
      if (audioEvent == 0 || stopEvent == 0) {
        throw const AudioBackendException(
          'CreateEventW',
          'could not create stream synchronization events',
        );
      }
      checkHresult(
        audioClient.setEventHandle(audioEvent),
        'IAudioClient::SetEventHandle',
      );

      out.value = nullptr;
      checkHresult(
        audioClient.getService(iidAudioRenderClient.allocateIn(arena), out),
        'IAudioClient::GetService(IAudioRenderClient)',
      );
      renderClient = AudioRenderClient(out.value);

      final Pointer<Uint32> bufferFrames =
          arena.allocate<Uint32>(sizeOf<Uint32>());
      final Pointer<Int64> latency = arena.allocate<Int64>(sizeOf<Int64>());
      checkHresult(
        audioClient.getBufferSize(bufferFrames),
        'IAudioClient::GetBufferSize',
      );
      checkHresult(
        audioClient.getStreamLatency(latency),
        'IAudioClient::GetStreamLatency',
      );

      final WasapiRenderStream stream = WasapiRenderStream.internal(
        api: api,
        audioClient: audioClient,
        renderClient: renderClient,
        configuration: AudioStreamConfiguration(
          format: parsed.format,
          periodFrames: periodFrames,
          bufferFrames: bufferFrames.value,
          streamLatency: Duration(microseconds: latency.value ~/ 10),
        ),
        audioEvent: audioEvent,
        stopEvent: stopEvent,
        ownsApartment: uninitialize,
      );
      handedOff = true;
      return stream;
    } finally {
      if (allocatedClosest != nullptr) {
        api.coTaskMemFree(allocatedClosest.cast<Void>());
      }
      if (allocatedFormat != nullptr) {
        api.coTaskMemFree(allocatedFormat.cast<Void>());
      }
      device?.dispose();
      enumerator?.dispose();
      arena.dispose();
      if (!handedOff) {
        renderClient?.dispose();
        audioClient?.dispose();
        if (stopEvent != 0) api.closeHandle(stopEvent);
        if (audioEvent != 0) api.closeHandle(audioEvent);
        if (uninitialize) api.coUninitialize();
      }
    }
  }

  static int _flow(AudioDeviceDirection direction) =>
      direction == AudioDeviceDirection.output
          ? wasapiDataFlowRender
          : wasapiDataFlowCapture;

  static int _role(AudioDeviceRole role) => switch (role) {
        AudioDeviceRole.console => wasapiRoleConsole,
        AudioDeviceRole.multimedia => wasapiRoleMultimedia,
        AudioDeviceRole.communications => wasapiRoleCommunications,
      };

  static String _deviceId(
    WasapiNativeApi api,
    MmDevice device,
    NativeArena arena,
  ) {
    final Pointer<Pointer<Uint16>> out =
        arena.allocate<Pointer<Uint16>>(sizeOf<Pointer<Uint16>>());
    out.value = nullptr;
    checkHresult(device.getId(out), 'IMMDevice::GetId');
    try {
      return readUtf16(out.value);
    } finally {
      if (out.value != nullptr) api.coTaskMemFree(out.value.cast<Void>());
    }
  }

  static String _deviceName(
    WasapiNativeApi api,
    MmDevice device,
    NativeArena arena, {
    required String fallback,
  }) {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    out.value = nullptr;
    final int result = hresult(device.openPropertyStore(out));
    if (failed(result) || out.value == nullptr) return fallback;
    final PropertyStore store = PropertyStore(out.value);
    try {
      final String name = store.friendlyName(api, arena);
      return name.isEmpty ? fallback : name;
    } on Object {
      return fallback;
    } finally {
      store.dispose();
    }
  }
}
