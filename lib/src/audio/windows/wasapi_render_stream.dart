/// Event-driven WASAPI output stream and its allocation-free pump.
library;

import 'dart:ffi';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import '../audio_device.dart';
import '../audio_format.dart';
import '../dsp/native_audio_processor.dart';
import 'wasapi_bindings.dart';
import 'wasapi_shared_ring_buffer.dart';

const int _waitObject0 = 0;
const int _waitFailed = 0xffffffff;
const int _infinite = 0xffffffff;

/// A shared-mode, event-driven `IAudioClient3` render stream.
///
/// Create and drive this object from one dedicated isolate. [runFromRing]
/// enters a synchronous native wait loop and performs no deliberate Dart heap
/// allocation on a successful period. A producer isolate sends only the ring
/// [WasapiSharedRingBuffer.address] and this stream's [stopHandle].
///
/// Dart 3.6 has no public isolate-to-thread pinning API. The implementation
/// therefore records the native thread that opened COM and refuses a call if
/// the VM resumes it on another thread. Keeping open, pump and dispose in one
/// uninterrupted synchronous isolate entry is the supported realtime path.
final class WasapiRenderStream with DisposableMixin implements AudioStream {
  WasapiRenderStream.internal({
    required WasapiNativeApi api,
    required AudioClient3 audioClient,
    required AudioRenderClient renderClient,
    required this.configuration,
    required int audioEvent,
    required int stopEvent,
    required bool ownsApartment,
  })  : _api = api,
        _audioClient = audioClient,
        _renderClient = renderClient,
        _audioEvent = audioEvent,
        _stopEvent = stopEvent,
        _ownsApartment = ownsApartment,
        _creationThreadId = api.getCurrentThreadId() {
    _padding = _hotArena.allocate<Uint32>(sizeOf<Uint32>());
    _sampleBuffer = _hotArena.allocate<Pointer<Uint8>>(
      sizeOf<Pointer<Uint8>>(),
    );
    _waitHandles = _hotArena.allocate<IntPtr>(2 * sizeOf<IntPtr>());
    _waitHandles[0] = audioEvent;
    _waitHandles[1] = stopEvent;
    _mmcssTaskIndex = _hotArena.allocate<Uint32>(sizeOf<Uint32>());
    _mmcssProfile = _hotArena.allocateUtf16('Pro Audio');
  }

  final WasapiNativeApi _api;
  final AudioClient3 _audioClient;
  final AudioRenderClient _renderClient;
  final int _audioEvent;
  final int _stopEvent;
  final bool _ownsApartment;
  final int _creationThreadId;
  final NativeArena _hotArena = NativeArena();

  late final Pointer<Uint32> _padding;
  late final Pointer<Pointer<Uint8>> _sampleBuffer;
  late final Pointer<IntPtr> _waitHandles;
  late final Pointer<Uint32> _mmcssTaskIndex;
  late final Pointer<Uint16> _mmcssProfile;

  AudioStreamState _state = AudioStreamState.stopped;

  @override
  final AudioStreamConfiguration configuration;

  @override
  AudioStreamState get state => isDisposed ? AudioStreamState.disposed : _state;

  /// Process-local handle that another isolate may signal to stop
  /// [runFromRing]. It is valid until [dispose].
  int get stopHandle {
    throwIfDisposed();
    return _stopEvent;
  }

  @override
  void start() {
    throwIfDisposed();
    _checkThread();
    if (_state == AudioStreamState.running) return;
    if (_api.resetEvent(_stopEvent) == 0) {
      throw const AudioBackendException('ResetEvent', 'native call failed');
    }

    // Prime the endpoint with silence so the first engine wakeup cannot
    // underrun while the producer is still being scheduled.
    _sampleBuffer.value = nullptr;
    checkHresult(
      _renderClient.getBuffer(configuration.bufferFrames, _sampleBuffer),
      'IAudioRenderClient::GetBuffer(prime)',
    );
    checkHresult(
      _renderClient.releaseBuffer(
        configuration.bufferFrames,
        wasapiBufferFlagSilence,
      ),
      'IAudioRenderClient::ReleaseBuffer(prime)',
    );
    checkHresult(_audioClient.start(), 'IAudioClient::Start');
    _state = AudioStreamState.running;
  }

  @override
  void stop() {
    if (isDisposed || _state == AudioStreamState.stopped) return;
    _checkThread();
    checkHresult(_audioClient.stop(), 'IAudioClient::Stop');
    checkHresult(_audioClient.reset(), 'IAudioClient::Reset');
    _state = AudioStreamState.stopped;
  }

  /// Signals [runFromRing] from the stream's owning isolate.
  void requestStop() {
    throwIfDisposed();
    if (_api.setEvent(_stopEvent) == 0) {
      throw const AudioBackendException('SetEvent', 'native call failed');
    }
  }

  /// Signals a handle sent to another isolate. Handles are process-local, so
  /// only the integer is transferred through the isolate message.
  static void signalStopHandle(int handle) {
    if (handle == 0 || WasapiNativeApi.load().setEvent(handle) == 0) {
      throw const AudioBackendException('SetEvent', 'native call failed');
    }
  }

  /// Waits for one engine period. Returns false when [requestStop] (or
  /// [signalStopHandle]) was called.
  bool waitForPeriod({int timeoutMilliseconds = _infinite}) {
    throwIfDisposed();
    _checkThread();
    final int result = _api.waitForMultipleObjects(
      2,
      _waitHandles,
      0,
      timeoutMilliseconds,
    );
    if (result == _waitObject0) return true;
    if (result == _waitObject0 + 1) return false;
    if (result == _waitFailed) {
      throw const AudioBackendException(
        'WaitForMultipleObjects',
        'native wait failed',
      );
    }
    return false; // timeout
  }

  /// Copies one engine wakeup from [ring]. Missing frames are zero-filled and
  /// a contended producer never blocks this consumer.
  int renderAvailableFrom(WasapiSharedRingBuffer ring) {
    throwIfDisposed();
    _checkThread();
    _padding.value = 0;
    checkHresult(
      _audioClient.getCurrentPadding(_padding),
      'IAudioClient::GetCurrentPadding',
    );
    final int writable = configuration.bufferFrames - _padding.value;
    if (writable <= 0) return 0;

    _sampleBuffer.value = nullptr;
    checkHresult(
      _renderClient.getBuffer(writable, _sampleBuffer),
      'IAudioRenderClient::GetBuffer',
    );
    final int byteCount = writable * configuration.format.bytesPerFrame;
    _api.zeroMemory(_sampleBuffer.value.cast<Void>(), byteCount);
    final int copied = ring.tryReadFrames(_sampleBuffer.value, writable);
    checkHresult(
      _renderClient.releaseBuffer(
        writable,
        copied == 0 ? wasapiBufferFlagSilence : 0,
      ),
      'IAudioRenderClient::ReleaseBuffer',
    );
    return copied;
  }

  /// Fills one engine wakeup directly through a Dart DSP processor. The
  /// pointer is the WASAPI-owned buffer itself; no intermediate sample copy or
  /// native callback is involved.
  int renderAvailableWith(NativeFloat32AudioProcessor processor) {
    throwIfDisposed();
    _checkThread();
    _checkProcessor(processor);
    _padding.value = 0;
    checkHresult(
      _audioClient.getCurrentPadding(_padding),
      'IAudioClient::GetCurrentPadding',
    );
    final int writable = configuration.bufferFrames - _padding.value;
    if (writable <= 0) return 0;

    _sampleBuffer.value = nullptr;
    checkHresult(
      _renderClient.getBuffer(writable, _sampleBuffer),
      'IAudioRenderClient::GetBuffer',
    );
    final int byteCount = writable * configuration.format.bytesPerFrame;
    _api.zeroMemory(_sampleBuffer.value.cast<Void>(), byteCount);
    try {
      processor.process(_sampleBuffer.value.cast<Float>(), writable);
    } on Object {
      _api.zeroMemory(_sampleBuffer.value.cast<Void>(), byteCount);
      _renderClient.releaseBuffer(writable, wasapiBufferFlagSilence);
      rethrow;
    }
    checkHresult(
      _renderClient.releaseBuffer(writable, 0),
      'IAudioRenderClient::ReleaseBuffer',
    );
    return writable;
  }

  /// Runs the allocation-free consumer loop until the stop event is signalled.
  /// This method intentionally never awaits or yields to a Dart event loop.
  void runFromRing(WasapiSharedRingBuffer ring) {
    throwIfDisposed();
    _checkThread();
    if (ring.bytesPerFrame != configuration.format.bytesPerFrame) {
      throw ArgumentError.value(
        ring.bytesPerFrame,
        'ring.bytesPerFrame',
        'must match stream format (${configuration.format.bytesPerFrame})',
      );
    }
    start();
    final int mmcssHandle =
        _api.avSetCharacteristics(_mmcssProfile, _mmcssTaskIndex);
    try {
      while (waitForPeriod()) {
        renderAvailableFrom(ring);
      }
    } finally {
      if (mmcssHandle != 0) {
        _api.avRevertCharacteristics(mmcssHandle);
      }
      stop();
    }
  }

  /// Runs a direct pointer-based synthesizer/effect graph until the stop event
  /// is signalled. The processor and stream must be created in this isolate.
  void runWithProcessor(NativeFloat32AudioProcessor processor) {
    throwIfDisposed();
    _checkThread();
    _checkProcessor(processor);
    start();
    final int mmcssHandle =
        _api.avSetCharacteristics(_mmcssProfile, _mmcssTaskIndex);
    try {
      while (waitForPeriod()) {
        renderAvailableWith(processor);
      }
    } finally {
      if (mmcssHandle != 0) {
        _api.avRevertCharacteristics(mmcssHandle);
      }
      stop();
    }
  }

  void _checkProcessor(NativeFloat32AudioProcessor processor) {
    final AudioFormat format = configuration.format;
    if (format.sampleFormat != AudioSampleFormat.float32 ||
        processor.sampleRate != format.sampleRate ||
        processor.channels != format.channels) {
      throw ArgumentError.value(
        processor,
        'processor',
        'requires ${format.sampleRate} Hz, ${format.channels} channels, '
            'float32',
      );
    }
  }

  void _checkThread() {
    final int current = _api.getCurrentThreadId();
    if (current != _creationThreadId) {
      throw StateError('WASAPI stream opened on native thread '
          '$_creationThreadId but used on $current. Open, pump and dispose it '
          'inside one synchronous dedicated-isolate entry.');
    }
  }

  @override
  void onDispose() {
    _checkThread();
    Object? firstError;
    StackTrace? firstStack;
    void attempt(void Function() action) {
      try {
        action();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    if (_state == AudioStreamState.running) {
      attempt(() {
        checkHresult(_audioClient.stop(), 'IAudioClient::Stop');
        checkHresult(_audioClient.reset(), 'IAudioClient::Reset');
        _state = AudioStreamState.stopped;
      });
    }
    attempt(_renderClient.dispose);
    attempt(_audioClient.dispose);
    attempt(() {
      if (_api.closeHandle(_stopEvent) == 0) {
        throw const AudioBackendException('CloseHandle', 'stop event failed');
      }
    });
    attempt(() {
      if (_api.closeHandle(_audioEvent) == 0) {
        throw const AudioBackendException('CloseHandle', 'audio event failed');
      }
    });
    attempt(_hotArena.dispose);
    if (_ownsApartment) attempt(_api.coUninitialize);
    _state = AudioStreamState.disposed;
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }
}
