/// Transport controls and the playback clock, shared with the audio isolate.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import '../windows/wasapi_bindings.dart';

const int _blockMagic = 0x4b555044; // "DPUK"
const int _blockVersion = 2;

// Header.
const int _magicOffset = 0;
const int _versionOffset = 4;
const int _lockOffset = 8; // SRWLOCK, pointer sized.

// Control: written by the owning isolate, read by the playback isolate under
// the lock, because a seek is two fields that have to agree with each other.
const int _playRequestedOffset = 16;
const int _quitRequestedOffset = 20;
const int _seekSequenceOffset = 24;
const int _seekFrameOffset = 32;

// Published: written only by the playback isolate. Every field is a single
// naturally aligned 32- or 64-bit slot with one writer, which is the same
// contract `WasapiSharedTelemetryBlock` documents - independent values, read
// without a lock, eventually consistent. Nothing here is transactional: the
// reader never needs two of these to agree.
const int _positionFramesOffset = 40;
const int _appliedSeekOffset = 48;
const int _stateOffset = 56;
const int _deviceSampleRateOffset = 60;
const int _deviceChannelsOffset = 64;
const int _reservedOffset = 68;
const int _deviceFrameCountOffset = 72;

// Producer side, written only by the decode isolate of a streaming player and
// read by both the pump and the owner. Absent - and left at their initial
// values - for a player over a clip that is already in memory.
const int _producerSequenceOffset = 80;
const int _producerOriginOffset = 88;
const int _producerEndedOffset = 96;
const int _producerReserved = 100;
const int _producerTotalFramesOffset = 104;
const int _blockBytes = 112;

/// The value [WasapiPlaybackControlBlock.producerSequence] holds while the ring
/// holds nothing the pump may play: before the first prebuffer, and between a
/// seek being issued and the producer having refilled at the new position.
///
/// Negative rather than zero because zero is a legitimate seek sequence - the
/// one every player starts at - and a pump that treated "not filled yet" and
/// "filled, at the start" as the same state would render the ring's leftovers
/// from before a seek.
const int producerSequenceIdle = -1;

/// What the playback isolate is doing, as seen from the isolate that owns the
/// player.
enum PlaybackState {
  /// Spawned; the output stream has not been negotiated yet.
  starting,

  /// The stream is open and the clip is in the device's format.
  ready,

  /// The engine is running and the clock is advancing.
  rendering,

  /// The clip played to its end and the endpoint has drained.
  ended,

  /// The stream could not be opened, or the pump threw. Playback is over.
  failed;

  static PlaybackState fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : PlaybackState.failed;
}

/// A mutable holder for one read of the control fields.
///
/// Reused by the pump so that reading the transport state every engine period
/// allocates nothing on the realtime path.
final class PlaybackControlSnapshot {
  bool playRequested = false;
  bool quitRequested = false;
  int seekSequence = 0;
  int seekFrame = 0;
}

/// The one piece of memory the player and its playback isolate share.
///
/// Two directions, two disciplines:
///
///   * **Controls travel down** under an SRW lock, exactly like
///     `WasapiSharedParameterBlock`. A seek is a frame *and* a sequence number
///     and the pump must never see one without the other, which is precisely
///     what a lock is for; the pump uses the try-acquire form so a transport
///     change on the UI thread can never make the audio thread wait.
///   * **The clock travels up** lock-free, as single-writer aligned slots. A
///     lock here would be the wrong shape: the reader is a UI frame asking
///     "where are we?" dozens of times a second and it is always happy with
///     the answer from a moment ago.
///
/// The frame counter is a signed 64-bit integer rather than the float32 the
/// existing telemetry block carries, because float32 stops being able to count
/// individual frames somewhere around six minutes of 48 kHz audio, and this
/// counter has to stay exact for the length of a film.
final class WasapiPlaybackControlBlock with DisposableMixin {
  WasapiPlaybackControlBlock._(this._memory, this._api, this._ownsMemory);

  factory WasapiPlaybackControlBlock.allocate() {
    final Pointer<Uint8> memory =
        NativeAllocator.instance.allocate<Uint8>(_blockBytes);
    final WasapiNativeApi api = WasapiNativeApi.load();
    memory.cast<Uint32>()[_magicOffset ~/ 4] = _blockMagic;
    memory.cast<Uint32>()[_versionOffset ~/ 4] = _blockVersion;
    memory.cast<Int64>()[_producerSequenceOffset ~/ 8] = producerSequenceIdle;
    api.initializeLock(Pointer<Void>.fromAddress(memory.address + _lockOffset));
    return WasapiPlaybackControlBlock._(memory, api, true);
  }

  /// Attaches to a block allocated in this process by another isolate.
  factory WasapiPlaybackControlBlock.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(address);
    if (memory.cast<Uint32>()[_magicOffset ~/ 4] != _blockMagic ||
        memory.cast<Uint32>()[_versionOffset ~/ 4] != _blockVersion) {
      throw StateError('address does not contain a dart_ui playback block');
    }
    return WasapiPlaybackControlBlock._(memory, WasapiNativeApi.load(), false);
  }

  final Pointer<Uint8> _memory;
  final WasapiNativeApi _api;
  final bool _ownsMemory;

  int get address {
    throwIfDisposed();
    return _memory.address;
  }

  Pointer<Void> get _lock =>
      Pointer<Void>.fromAddress(_memory.address + _lockOffset);

  int _u32(int offset) => _memory.cast<Uint32>()[offset ~/ 4];
  void _setU32(int offset, int value) =>
      _memory.cast<Uint32>()[offset ~/ 4] = value;
  int _i64(int offset) => _memory.cast<Int64>()[offset ~/ 8];
  void _setI64(int offset, int value) =>
      _memory.cast<Int64>()[offset ~/ 8] = value;

  // --- Control side, owned by the player -----------------------------------

  /// Asks the pump to run or to hold. Applied at the next engine period.
  void requestPlaying(bool playing) {
    throwIfDisposed();
    _api.acquireLock(_lock);
    try {
      _setU32(_playRequestedOffset, playing ? 1 : 0);
    } finally {
      _api.releaseLock(_lock);
    }
  }

  /// Asks the pump to tear the stream down and exit.
  void requestQuit() {
    throwIfDisposed();
    _api.acquireLock(_lock);
    try {
      _setU32(_quitRequestedOffset, 1);
    } finally {
      _api.releaseLock(_lock);
    }
  }

  /// Publishes a reposition and returns its sequence number.
  ///
  /// The counter is what makes a seek reliable: two seeks to the same frame
  /// are two distinct commands, and the player can tell whether the pump has
  /// acted on the latest one by comparing it with [appliedSeekSequence].
  int requestSeek(int frame) {
    throwIfDisposed();
    _api.acquireLock(_lock);
    try {
      final int sequence = _i64(_seekSequenceOffset) + 1;
      _setI64(_seekFrameOffset, frame);
      _setI64(_seekSequenceOffset, sequence);
      return sequence;
    } finally {
      _api.releaseLock(_lock);
    }
  }

  // --- Control side, read by the pump --------------------------------------

  /// Copies the controls into [out] without waiting.
  ///
  /// Returns false when the player owns the lock, in which case the pump keeps
  /// the snapshot it already had and reads again next period - a transport
  /// change is never lost, only ever late by one buffer.
  bool tryReadControl(PlaybackControlSnapshot out) {
    throwIfDisposed();
    if (_api.tryAcquireLock(_lock) == 0) return false;
    try {
      out.playRequested = _u32(_playRequestedOffset) != 0;
      out.quitRequested = _u32(_quitRequestedOffset) != 0;
      out.seekSequence = _i64(_seekSequenceOffset);
      out.seekFrame = _i64(_seekFrameOffset);
      return true;
    } finally {
      _api.releaseLock(_lock);
    }
  }

  // --- Published side ------------------------------------------------------

  /// The media frame the device is playing.
  int get positionFrames {
    throwIfDisposed();
    return _i64(_positionFramesOffset);
  }

  set positionFrames(int value) {
    throwIfDisposed();
    _setI64(_positionFramesOffset, value);
  }

  /// The sequence number of the last seek the pump acted on.
  int get appliedSeekSequence {
    throwIfDisposed();
    return _i64(_appliedSeekOffset);
  }

  set appliedSeekSequence(int value) {
    throwIfDisposed();
    _setI64(_appliedSeekOffset, value);
  }

  PlaybackState get state {
    throwIfDisposed();
    return PlaybackState.fromCode(_u32(_stateOffset));
  }

  set state(PlaybackState value) {
    throwIfDisposed();
    _setU32(_stateOffset, value.index);
  }

  int get deviceSampleRate {
    throwIfDisposed();
    return _u32(_deviceSampleRateOffset);
  }

  int get deviceChannels {
    throwIfDisposed();
    return _u32(_deviceChannelsOffset);
  }

  /// The clip's length in output frames, after conversion.
  int get deviceFrameCount {
    throwIfDisposed();
    return _i64(_deviceFrameCountOffset);
  }

  set deviceFrameCount(int value) {
    throwIfDisposed();
    _setI64(_deviceFrameCountOffset, value);
  }

  /// Publishes the negotiated output format. Written once by the player with
  /// the format it probed, and again by the pump with what it really got.
  void publishDeviceFormat({
    required int sampleRate,
    required int channels,
    required int frameCount,
  }) {
    throwIfDisposed();
    publishDeviceRate(sampleRate: sampleRate, channels: channels);
    _setI64(_deviceFrameCountOffset, frameCount);
  }

  /// Publishes the rate and channel count without touching the length.
  ///
  /// The streaming pump needs this half on its own: it learns the real device
  /// format when it opens the stream, but the length it would have to pass to
  /// [publishDeviceFormat] belongs to the container and was published by the
  /// owner before either worker isolate existed. Passing a length it does not
  /// know would mean reading one field only to write it back.
  void publishDeviceRate({required int sampleRate, required int channels}) {
    throwIfDisposed();
    _setU32(_deviceSampleRateOffset, sampleRate);
    _setU32(_deviceChannelsOffset, channels);
    _setU32(_reservedOffset, 0);
  }

  // --- Producer side, for a streaming player -------------------------------

  /// Which seek generation the ring's contents belong to, or
  /// [producerSequenceIdle] while it holds nothing playable.
  ///
  /// This is the whole handshake between the decode isolate and the pump. The
  /// pump renders only while this equals the seek sequence it has itself
  /// applied, which covers both directions of the race a seek creates: the
  /// producer refilling before the pump has noticed the seek (the pump would
  /// otherwise play post-seek audio at the pre-seek position) and the pump
  /// restarting before the producer has refilled (it would play the ring's
  /// stale tail).
  int get producerSequence {
    throwIfDisposed();
    return _i64(_producerSequenceOffset);
  }

  set producerSequence(int value) {
    throwIfDisposed();
    _setI64(_producerSequenceOffset, value);
  }

  /// The media frame the first frame currently in the ring corresponds to.
  int get producerOriginFrame {
    throwIfDisposed();
    return _i64(_producerOriginOffset);
  }

  set producerOriginFrame(int value) {
    throwIfDisposed();
    _setI64(_producerOriginOffset, value);
  }

  /// Whether the producer has pushed the last frame of the source into the
  /// ring for the current sequence.
  bool get producerEnded {
    throwIfDisposed();
    return _u32(_producerEndedOffset) != 0;
  }

  set producerEnded(bool value) {
    throwIfDisposed();
    _setU32(_producerEndedOffset, value ? 1 : 0);
    _setU32(_producerReserved, 0);
  }

  /// The exact output frame the source ends at, valid once [producerEnded].
  ///
  /// The pump stops on this rather than on the length derived from the
  /// container's declared duration, because the two differ by a few frames on
  /// most compressed formats and stopping on the wrong one either truncates
  /// the last buffer or leaves the clock waiting for frames that will never
  /// arrive.
  int get producerTotalFrames {
    throwIfDisposed();
    return _i64(_producerTotalFramesOffset);
  }

  set producerTotalFrames(int value) {
    throwIfDisposed();
    _setI64(_producerTotalFramesOffset, value);
  }

  @override
  void onDispose() {
    if (_ownsMemory) {
      _setU32(_magicOffset, 0);
      NativeAllocator.instance.free(_memory);
    }
  }
}
