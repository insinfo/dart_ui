/// Event-driven WASAPI output stream and its allocation-free pump.
library;

import 'dart:ffi';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import '../audio_device.dart';
import '../audio_format.dart';
import '../audio_gain.dart';
import '../audio_session_volume.dart';
import '../dsp/native_audio_processor.dart';
import '../dsp/native_gain.dart';
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
final class WasapiRenderStream
    with DisposableMixin
    implements AudioStream, AudioSessionVolume {
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

  /// The stream's own level. Read once per engine wakeup, on this thread.
  ///
  /// A plain field rather than anything synchronised: it is written and read
  /// by the same isolate that owns the stream, which is the same isolate the
  /// thread check below already insists on. A player whose transport lives on
  /// another isolate carries its gain down through its own control block and
  /// writes this field from the pump - see `wasapi_playback_control_block.dart`.
  AudioGain _gain = AudioGain.unity;

  /// `ISimpleAudioVolume`, activated on first use and released on dispose.
  ///
  /// Lazily, because most streams never ask: every `GetService` call takes a
  /// reference that has to be balanced, and a stream that only ever renders
  /// should not carry one.
  SimpleAudioVolume? _sessionVolume;

  @override
  final AudioStreamConfiguration configuration;

  @override
  AudioStreamState get state => isDisposed ? AudioStreamState.disposed : _state;

  @override
  AudioGain get gain => _gain;

  /// Sets the stream's level, refusing here rather than on the audio thread
  /// when the negotiated format has no gain kernel.
  ///
  /// Only packed 24-bit reaches the refusal, and only when a caller has asked
  /// for it explicitly through [AudioStreamRequest.preferredFormat] - shared
  /// mode negotiates float32. Refusing at the setter is what makes it a
  /// *named* refusal the caller can see: accepting the value and then
  /// discovering three periods later, on the realtime thread, that there is no
  /// kernel would either kill playback or, worse, pass the samples through
  /// unattenuated, which is a volume control that silently does nothing.
  @override
  set gain(AudioGain value) {
    throwIfDisposed();
    final AudioSampleFormat format = configuration.format.sampleFormat;
    if (!value.isUnity && !nativeGainSupportsFormat(format)) {
      throw AudioCapabilityError(
        backendName: 'WasapiRenderStream',
        capability: 'stream gain on ${format.name}',
        detail: 'no gain kernel exists for packed 24-bit samples; open the '
            'stream in float32 or signed32',
      );
    }
    _gain = value;
  }

  // --- AudioSessionVolume ---------------------------------------------------
  //
  // This application's row in the Windows volume mixer, which is a different
  // thing from [gain] in every way a user can observe: they can move it, it
  // persists across runs, and it covers every stream this process opened. See
  // `audio_session_volume.dart` for why it is a discovered capability rather
  // than a method every backend has to pretend to have.

  SimpleAudioVolume get _session {
    throwIfDisposed();
    _checkThread();
    final SimpleAudioVolume? existing = _sessionVolume;
    if (existing != null) return existing;
    final NativeArena arena = NativeArena();
    try {
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      out.value = nullptr;
      checkHresult(
        _audioClient.getService(iidSimpleAudioVolume.allocateIn(arena), out),
        'IAudioClient::GetService(ISimpleAudioVolume)',
      );
      return _sessionVolume = SimpleAudioVolume(out.value);
    } finally {
      arena.dispose();
    }
  }

  @override
  double get sessionVolume {
    final SimpleAudioVolume session = _session;
    final NativeArena arena = NativeArena();
    try {
      final Pointer<Float> out = arena.allocate<Float>(sizeOf<Float>());
      out.value = 0;
      checkHresult(
        session.getMasterVolume(out),
        'ISimpleAudioVolume::GetMasterVolume',
      );
      return out.value;
    } finally {
      arena.dispose();
    }
  }

  @override
  set sessionVolume(double value) {
    // Clamped rather than rejected: SetMasterVolume answers E_INVALIDARG
    // outside 0..1, and a rejected write would leave the user's slider wherever
    // it happened to be while the caller believed it had moved.
    checkHresult(
      _session.setMasterVolume(value.isNaN ? 0 : value.clamp(0.0, 1.0)),
      'ISimpleAudioVolume::SetMasterVolume',
    );
  }

  @override
  bool get sessionMuted {
    final SimpleAudioVolume session = _session;
    final NativeArena arena = NativeArena();
    try {
      final Pointer<Int32> out = arena.allocate<Int32>(sizeOf<Int32>());
      out.value = 0;
      checkHresult(session.getMute(out), 'ISimpleAudioVolume::GetMute');
      return out.value != 0;
    } finally {
      arena.dispose();
    }
  }

  @override
  set sessionMuted(bool value) {
    checkHresult(_session.setMute(value), 'ISimpleAudioVolume::SetMute');
  }

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

    // The engine signals the period event once more on its way down, and that
    // signal survives Stop/Reset because the event is process state, not client
    // state. Left standing, it makes the first [waitForPeriod] of the next run
    // return before the engine has consumed anything - the buffer is still full
    // of the priming silence below, so the caller sees zero writable frames and
    // reads it as an underrun. Clearing it here makes a wakeup mean 'a period
    // elapsed since this start', which is what the pump assumes.
    if (_api.resetEvent(_audioEvent) == 0) {
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
    // The last stage before the endpoint, and only over the frames the ring
    // actually delivered: the rest is the zero fill above, which no gain can
    // change. `_gain.factor == 1` returns without a memory access, so the
    // normal case costs one compare per wakeup rather than one per sample.
    applyNativeGain(
      _sampleBuffer.value,
      configuration.format.sampleFormat,
      copied * configuration.format.channels,
      _gain.factor,
    );
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
    // After the processor, which is after resampling and after whatever
    // mixing the graph did, so one multiply covers all of it and no earlier
    // stage ever sees an attenuated sample it might make a decision from.
    //
    // Deliberately *not* short-circuited when the gain is silence: the
    // processor still ran and the frames are still released and counted, so
    // the clock keeps advancing and a profiling run at zero volume measures
    // the same program a run at full volume does. Skipping the write would
    // have been the cheaper thing and the wrong one - it was a full-volume
    // profiling run that exposed the absence of this control in the first
    // place, and a "silence" that stops the transport would not be usable for
    // the next one.
    applyNativeFloat32Gain(
      _sampleBuffer.value.cast<Float>(),
      writable * configuration.format.channels,
      _gain.factor,
    );
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
    // Before the client it was obtained from: `GetService` handed back a
    // reference, and releasing the client while this one still points at it is
    // the ordering `ComBag` exists to enforce elsewhere.
    final SimpleAudioVolume? session = _sessionVolume;
    if (session != null) {
      _sessionVolume = null;
      attempt(session.dispose);
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
