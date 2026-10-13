/// Audio output on macOS and iOS, through AudioToolbox's Audio Queue.
///
/// The Windows path renders through WASAPI; this is the same
/// [PcmAudioPlayer] on Apple platforms, from `dart:ffi` alone. The samples are
/// already decoded, float32 and interleaved in a [NativePcmAudioBuffer] -
/// exactly the linear PCM an output queue takes - so the work is keeping a few
/// buffers in the queue: when CoreAudio hands one back, a
/// `NativeCallable.listener` wakes this isolate, which copies the next frames
/// into it and enqueues it again. Three buffers of about 85 ms keep a quarter
/// of a second queued, which is plenty of slack for an event loop.
///
/// Position comes from the queue's own clock (`AudioQueueGetCurrentTime`),
/// so it is the sample being heard, not the one last copied. A seek throws
/// the queue away and starts a new one at the new frame: buffers already
/// queued are gone with it, and callbacks still in flight from the old queue
/// are told apart by a generation number carried as the callback's user data.
library;

import 'dart:ffi';

import '../audio_gain.dart';
import '../native/native_pcm_audio_buffer.dart';
import '../playback/media_clock.dart';
import 'audio_toolbox.dart';

typedef _Ptr = Pointer<Void>;

const int _bufferCount = 3;
const int _framesPerBuffer = 4096;

/// A [PcmAudioPlayer] over an Audio Queue.
final class AudioQueuePcmPlayer implements PcmAudioPlayer {
  AudioQueuePcmPlayer._(this._toolbox, this._pcm, this._ownsPcm);

  /// Opens an output queue for [pcm], or returns null when this machine has
  /// no AudioToolbox or no output. With [ownsPcm] the buffer is disposed with
  /// the player.
  static AudioQueuePcmPlayer? open(NativePcmAudioBuffer pcm,
      {bool ownsPcm = false}) {
    if (pcm.isDisposed) {
      throw ArgumentError.value(pcm, 'pcm', 'has already been disposed');
    }
    final AudioToolboxApi? toolbox = AudioToolboxApi.instance;
    if (toolbox == null || pcm.frameCount == 0) return null;
    final AudioQueuePcmPlayer player =
        AudioQueuePcmPlayer._(toolbox, pcm, ownsPcm);
    if (!player._createQueue()) {
      player._closeCallback();
      return null;
    }
    return player;
  }

  final AudioToolboxApi _toolbox;
  final NativePcmAudioBuffer _pcm;
  final bool _ownsPcm;
  late final NativeCallable<AudioQueueOutputCallbackNative> _callback =
      NativeCallable<AudioQueueOutputCallbackNative>.listener(_bufferReturned);
  _Ptr _queue = nullptr;
  int _generation = 0;
  int _readFrame = 0;
  int _baseFrame = 0;
  int _queued = 0;
  bool _started = false;
  bool _playing = false;
  bool _ended = false;
  bool _disposed = false;
  Duration _heldPosition = Duration.zero;
  AudioGain _gain = AudioGain.unity;

  @override
  int get sampleRate => _pcm.sampleRate;

  @override
  int get channels => _pcm.channels;

  @override
  Duration get duration => _pcm.duration;

  @override
  AudioGain get gain => _gain;

  @override
  set gain(AudioGain value) {
    _gain = value;
    if (_queue != nullptr) {
      _toolbox.setParameter(_queue, kAudioQueueParamVolume, value.factor);
    }
  }

  @override
  bool get isRunning => _playing && !_ended;

  @override
  Duration get position {
    if (!_playing || _queue == nullptr) return _heldPosition;
    final double? sample = _toolbox.sampleTime(_queue);
    if (sample == null) return _heldPosition;
    final int frame = (_baseFrame + sample.round()).clamp(0, _pcm.frameCount);
    return _heldPosition = _frameToDuration(frame);
  }

  @override
  void play() {
    if (_disposed) return;
    if (_ended) seek(Duration.zero);
    if (_playing) return;
    if (_toolbox.start(_queue, nullptr) == 0) {
      _started = true;
      _playing = true;
    }
  }

  @override
  void pause() {
    if (_disposed || !_playing) return;
    _heldPosition = position;
    _toolbox.pause(_queue);
    _playing = false;
  }

  @override
  void seek(Duration to) {
    if (_disposed) return;
    final bool wasPlaying = _playing;
    _disposeQueue();
    final int frame =
        (to.inMicroseconds * _pcm.sampleRate ~/ Duration.microsecondsPerSecond)
            .clamp(0, _pcm.frameCount);
    _readFrame = frame;
    _baseFrame = frame;
    _heldPosition = _frameToDuration(frame);
    _ended = false;
    _playing = false;
    _started = false;
    if (!_createQueue()) return;
    if (wasPlaying) play();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playing = false;
    _disposeQueue();
    _closeCallback();
    if (_ownsPcm) _pcm.dispose();
  }

  Duration _frameToDuration(int frame) => Duration(
      microseconds: frame * Duration.microsecondsPerSecond ~/ _pcm.sampleRate);

  bool _createQueue() {
    _generation++;
    final _Ptr? queue = _toolbox.newFloat32Output(
      sampleRate: _pcm.sampleRate,
      channels: _pcm.channels,
      callback: _callback,
      userData: _generation,
    );
    if (queue == null) return false;
    _queue = queue;
    _toolbox.setParameter(_queue, kAudioQueueParamVolume, _gain.factor);
    _queued = 0;
    for (var i = 0; i < _bufferCount; i++) {
      final _Ptr? buffer =
          _toolbox.newBuffer(_queue, _framesPerBuffer * 4 * _pcm.channels);
      if (buffer == null || !_fill(buffer)) break;
    }
    if (_queued == 0) _ended = true;
    return true;
  }

  /// Copies the next frames into [buffer] and enqueues it; false at the end.
  bool _fill(_Ptr buffer) {
    final int remaining = _pcm.frameCount - _readFrame;
    if (remaining <= 0) return false;
    final int frames =
        remaining < _framesPerBuffer ? remaining : _framesPerBuffer;
    final int floats = frames * _pcm.channels;
    audioQueueBufferData(buffer).asTypedList(floats).setAll(
        0, (_pcm.samples + _readFrame * _pcm.channels).asTypedList(floats));
    setAudioQueueBufferBytes(buffer, floats * 4);
    if (_toolbox.enqueue(_queue, buffer, 0, nullptr) != 0) return false;
    _readFrame += frames;
    _queued++;
    return true;
  }

  void _bufferReturned(_Ptr userData, _Ptr queue, _Ptr buffer) {
    // A callback from a queue a seek already threw away.
    if (_disposed || userData.address != _generation || queue != _queue) return;
    _queued--;
    if (_fill(buffer)) return;
    if (_queued <= 0 && _readFrame >= _pcm.frameCount) {
      // Everything played: stop once the last buffer drained.
      _heldPosition = duration;
      _ended = true;
      _playing = false;
      _toolbox.stop(_queue, 0);
    }
  }

  void _disposeQueue() {
    if (_queue == nullptr) return;
    _generation++;
    _toolbox.dispose(_queue, 1);
    _queue = nullptr;
    _queued = 0;
  }

  bool _closed = false;

  void _closeCallback() {
    if (_closed) return;
    _closed = true;
    _callback.close();
  }

  /// Whether [play] has started the queue at least once since the last seek.
  bool get hasStarted => _started;
}
