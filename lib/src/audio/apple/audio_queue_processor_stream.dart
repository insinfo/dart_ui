/// An Audio Queue that pulls its samples from a DSP graph.
///
/// The Apple counterpart of `WasapiRenderStream.runWithProcessor`: the same
/// [NativeFloat32AudioProcessor] - a synthesizer, a clip player followed by
/// an equalizer and analyzers - fills each buffer the queue hands back. The
/// difference is who waits. WASAPI blocks a dedicated isolate on the device
/// period; here CoreAudio calls a `NativeCallable.listener`, so the processor
/// runs as an ordinary event on the isolate that opened the stream, between
/// its other work.
///
/// That makes this a buffered stream, not a low-latency one: the queue holds
/// [AudioQueueProcessorStream.bufferCount] buffers so a busy event loop does
/// not starve it, and what the processor computes is heard that much later.
/// Right for music and analysis; an instrument wants an AudioUnit render
/// callback instead.
library;

import 'dart:ffi';

import '../../foundation/lifecycle.dart';
import '../dsp/native_audio_processor.dart';
import 'audio_toolbox.dart';

final class AudioQueueProcessorStream with DisposableMixin {
  AudioQueueProcessorStream._(
    this._toolbox,
    this.processor,
    this.periodFrames,
    this.bufferCount,
  );

  /// Opens a queue at the processor's rate and channel count, primed with
  /// [bufferCount] buffers of [periodFrames] each, or returns null where
  /// there is no AudioToolbox or no output. Nothing sounds until [start].
  static AudioQueueProcessorStream? open(
    NativeFloat32AudioProcessor processor, {
    int periodFrames = 2048,
    int bufferCount = 3,
  }) {
    if (periodFrames <= 0 || bufferCount <= 0) {
      throw ArgumentError('periodFrames and bufferCount must be positive');
    }
    final AudioToolboxApi? toolbox = AudioToolboxApi.instance;
    if (toolbox == null) return null;
    final AudioQueueProcessorStream stream = AudioQueueProcessorStream._(
        toolbox, processor, periodFrames, bufferCount);
    if (!stream._createQueue()) {
      stream._callback.close();
      return null;
    }
    return stream;
  }

  final AudioToolboxApi _toolbox;

  /// What fills the buffers; it stays owned by the caller.
  final NativeFloat32AudioProcessor processor;
  final int periodFrames;
  final int bufferCount;
  late final NativeCallable<AudioQueueOutputCallbackNative> _callback =
      NativeCallable<AudioQueueOutputCallbackNative>.listener(_bufferReturned);
  Pointer<Void> _queue = nullptr;
  bool _running = false;

  int get sampleRate => processor.sampleRate;
  int get channels => processor.channels;

  /// How far ahead of the speaker the processor runs, at most.
  Duration get latency => Duration(
      microseconds: periodFrames *
          bufferCount *
          Duration.microsecondsPerSecond ~/
          sampleRate);

  bool get isRunning => _running;

  /// Frames the device has played since the queue first started.
  int get playedFrames {
    if (_queue == nullptr) return 0;
    return (_toolbox.sampleTime(_queue) ?? 0).round();
  }

  /// Starts or resumes the device.
  void start() {
    throwIfDisposed();
    if (_running) return;
    _running = _toolbox.start(_queue, nullptr) == 0;
  }

  /// Pauses the device; the queued buffers wait and play on [start].
  void pause() {
    throwIfDisposed();
    if (!_running) return;
    _toolbox.pause(_queue);
    _running = false;
  }

  /// Output volume of the queue itself, 0 to 1.
  set volume(double value) {
    throwIfDisposed();
    _toolbox.setParameter(
        _queue, kAudioQueueParamVolume, value.clamp(0.0, 1.0));
  }

  bool _createQueue() {
    final Pointer<Void>? queue = _toolbox.newFloat32Output(
      sampleRate: processor.sampleRate,
      channels: processor.channels,
      callback: _callback,
      userData: 0,
    );
    if (queue == null) return false;
    _queue = queue;
    var primed = 0;
    for (var i = 0; i < bufferCount; i++) {
      final Pointer<Void>? buffer =
          _toolbox.newBuffer(_queue, periodFrames * 4 * processor.channels);
      if (buffer == null) break;
      _fill(buffer);
      primed++;
    }
    if (primed == 0) {
      _toolbox.dispose(_queue, 1);
      _queue = nullptr;
      return false;
    }
    return true;
  }

  void _fill(Pointer<Void> buffer) {
    processor.process(audioQueueBufferData(buffer), periodFrames);
    setAudioQueueBufferBytes(buffer, periodFrames * 4 * processor.channels);
    _toolbox.enqueue(_queue, buffer, 0, nullptr);
  }

  void _bufferReturned(
      Pointer<Void> userData, Pointer<Void> queue, Pointer<Void> buffer) {
    if (isDisposed || queue != _queue) return;
    _fill(buffer);
  }

  @override
  void onDispose() {
    if (_queue != nullptr) {
      _toolbox.dispose(_queue, 1);
      _queue = nullptr;
    }
    _running = false;
    _callback.close();
  }
}
