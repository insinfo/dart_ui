/// A WASAPI-driven [PcmAudioPlayer] whose position is the device's own count.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import '../../ffi/native_memory.dart';
import '../audio_device.dart';
import '../audio_format.dart';
import '../dsp/native_pcm_clip_player.dart';
import '../native/native_pcm_audio_buffer.dart';
import '../windows/media_foundation_audio_reader.dart';
import '../windows/wasapi_backend.dart';
import '../windows/wasapi_bindings.dart';
import '../windows/wasapi_render_stream.dart';
import '../windows/wasapi_shared_ring_buffer.dart';
import 'endpoint_render_clock.dart';
import 'media_clock.dart';
import 'pcm_output_format.dart';
import 'streaming_file_playback.dart';
import 'wasapi_playback_control_block.dart';

/// How long the pump waits for a control change while the engine is stopped.
///
/// A paused player is not being woken by anything - the engine event only
/// fires while the client is started - so the pump has to look at the control
/// block on a timer. Ten milliseconds is one engine period's worth of latency
/// on a press of play, which nobody can feel, at a hundred locked reads of
/// eighty bytes a second, which nothing can measure.
const int _idlePollMilliseconds = 10;

/// How long the pump waits for an engine period before looking at the controls
/// again. Only a backstop: while running, the period event arrives long first.
const int _pumpTimeoutMilliseconds = 200;

/// How long [WasapiPcmAudioPlayer.dispose] waits for the pump to acknowledge.
const Duration _shutdownTimeout = Duration(seconds: 3);

/// Plays a decoded clip through WASAPI and reports the position the *endpoint*
/// has reached.
///
/// ## Shape
///
/// One dedicated isolate owns everything native about playback: it opens the
/// `IAudioClient3` stream, converts the clip into the format the engine
/// negotiated, and runs the synchronous event-driven pump. That is not a
/// preference, it is [WasapiRenderStream]'s documented contract - the stream
/// refuses to be driven from a thread other than the one that opened it, and
/// a pump that awaited anything would hand the VM the chance to move it.
///
/// This object lives on the isolate that asked for playback and never touches
/// the stream. The two communicate through one [WasapiPlaybackControlBlock]:
/// transport commands travel down under a lock, the frame counter travels back
/// lock-free.
///
/// ## Why the clock is trustworthy
///
/// [position] is not a `Stopwatch`. It is the count of frames the audio
/// endpoint has actually consumed, worked out at every engine wakeup by
/// [EndpointRenderClock] from what has been released to the endpoint and what
/// `GetCurrentPadding` says is still queued there. If the device stalls, the
/// number stops; if the device runs slightly fast or slow relative to the host
/// clock - which every device does - the number follows the device, because
/// the device is what the listener hears.
final class WasapiPcmAudioPlayer implements PcmAudioPlayer {
  WasapiPcmAudioPlayer._(
    this._block,
    this._receive, {
    required int sampleRate,
    required int channels,
    required int frameCount,
    WasapiSharedRingBuffer? ring,
  })  : _sampleRate = sampleRate,
        _channels = channels,
        _frameCount = frameCount,
        _ring = ring;

  /// Opens a player for [pcm], or returns null when this machine has no usable
  /// render endpoint.
  ///
  /// [pcm] is borrowed: it is read by the playback isolate for as long as the
  /// player lives and is never released by it, so it must outlive [dispose].
  static WasapiPcmAudioPlayer? open(NativePcmAudioBuffer pcm) {
    if (!Platform.isWindows) return null;
    if (pcm.isDisposed) {
      throw ArgumentError.value(pcm, 'pcm', 'has already been disposed');
    }
    final WasapiAudioBackend backend = WasapiAudioBackend();
    if (!backend.isAvailable) return null;

    // Probing costs one open/close of a shared-mode client, and buys the
    // player the ability to answer `sampleRate`, `channels` and `duration`
    // the instant it is constructed - which it must, because those are plain
    // getters and the isolate that will really negotiate the format has not
    // even been spawned yet. Everything the probe learns is provisional: the
    // pump republishes the format it actually got.
    final AudioFormat format;
    try {
      if (backend.enumerateDevices().isEmpty) return null;
      final WasapiRenderStream probe =
          backend.openStream(const AudioStreamRequest());
      try {
        format = probe.configuration.format;
      } finally {
        probe.dispose();
      }
    } on Object {
      return null;
    }
    if (format.sampleFormat != AudioSampleFormat.float32) return null;

    final WasapiPlaybackControlBlock block =
        WasapiPlaybackControlBlock.allocate();
    final int frameCount = conformedFrameCount(
      pcm,
      sampleRate: format.sampleRate,
    );
    block.publishDeviceFormat(
      sampleRate: format.sampleRate,
      channels: format.channels,
      frameCount: frameCount,
    );

    final ReceivePort receive = ReceivePort();
    final WasapiPcmAudioPlayer player = WasapiPcmAudioPlayer._(
      block,
      receive,
      sampleRate: format.sampleRate,
      channels: format.channels,
      frameCount: frameCount,
    );
    receive.listen(player._onWorkerFinished);
    player._startWorker(
      playbackIsolateMain,
      <Object>[
        receive.sendPort,
        block.address,
        pcm.samples.address,
        pcm.sampleRate,
        pcm.channels,
        pcm.frameCount,
      ],
      'dart_ui audio playback',
    );
    return player;
  }

  /// Opens a player that streams [path] instead of decoding it first, or
  /// returns null when the file has no playable audio or this machine has no
  /// usable render endpoint.
  ///
  /// ## What is different from [open], and what is not
  ///
  /// Not different: everything a caller can see. Same [MediaClock], same
  /// transport, same rule that [position] is what the endpoint has consumed
  /// rather than what has been written.
  ///
  /// Different: nothing is decoded here. This opens the container, reads the
  /// format and the declared duration out of its metadata, closes it again,
  /// and hands the path to a decode isolate that keeps a few seconds ready in
  /// a ring buffer. The time before the first sample is therefore the time to
  /// parse a container header and decode a quarter of a second - a constant,
  /// where decoding the track first is linear in its length, and the
  /// difference on a twenty-minute film is two minutes and most of a gigabyte.
  ///
  /// The cost of that is a [duration] taken from the container rather than
  /// counted, so it is as accurate as the file says it is - and it is refined
  /// to the exact frame if playback ever runs to the end from the start.
  static WasapiPcmAudioPlayer? openFile(String path) {
    if (!Platform.isWindows) return null;
    final WasapiAudioBackend backend = WasapiAudioBackend();
    if (!backend.isAvailable) return null;

    // `GetMixFormat`, not a whole stream. Opening one here would spin the
    // Windows audio engine up on this isolate - half a second, the first time
    // a process does it - and then the pump would open a second stream anyway.
    // Asking for the format alone lets that half second happen in the pump,
    // *while* the decode isolate is already opening the file and filling the
    // ring, instead of in front of both of them.
    final AudioFormat? format = backend.defaultRenderMixFormat();
    if (format == null) return null;
    if (format.sampleFormat != AudioSampleFormat.float32) return null;

    // One open of the container, for its format and its declared length. This
    // is the whole of the work done before `openFile` returns; the reader is
    // closed again immediately and the decode isolate opens its own, because
    // an `IMFSourceReader` belongs to the isolate that created it.
    final int sourceSampleRate;
    final Duration duration;
    try {
      final MediaFoundationAudioReader probe =
          MediaFoundationAudioReader.open(path);
      try {
        sourceSampleRate = probe.sampleRate;
        duration = probe.duration;
      } finally {
        probe.dispose();
      }
    } on Object {
      return null;
    }
    if (sourceSampleRate <= 0) return null;

    final WasapiPlaybackControlBlock block =
        WasapiPlaybackControlBlock.allocate();
    final WasapiSharedRingBuffer ring;
    try {
      ring = WasapiSharedRingBuffer.allocate(
        capacityFrames: ringCapacityFrames(format.sampleRate),
        bytesPerFrame: format.bytesPerFrame,
      );
    } on Object {
      block.dispose();
      return null;
    }
    block.publishDeviceFormat(
      sampleRate: format.sampleRate,
      channels: format.channels,
      frameCount: durationToFrames(duration, format.sampleRate),
    );

    final ReceivePort receive = ReceivePort();
    final WasapiPcmAudioPlayer player = WasapiPcmAudioPlayer._(
      block,
      receive,
      sampleRate: format.sampleRate,
      channels: format.channels,
      frameCount: durationToFrames(duration, format.sampleRate),
      ring: ring,
    );
    receive.listen(player._onWorkerFinished);
    player._startWorker(
      streamingPlaybackIsolateMain,
      <Object>[receive.sendPort, block.address, ring.address],
      'dart_ui audio playback',
    );
    player._startWorker(
      streamingAudioProducerMain,
      <Object>[
        receive.sendPort,
        block.address,
        ring.address,
        path,
        format.sampleRate,
        format.channels,
      ],
      'dart_ui audio decode',
    );
    return player;
  }

  /// Spawns one worker isolate and folds its outcome into [_finished].
  void _startWorker(
    void Function(List<Object>) entry,
    List<Object> message,
    String debugName,
  ) {
    _pendingWorkers++;
    _spawns.add(
      Isolate.spawn(entry, message, debugName: debugName).then<Isolate?>(
        (Isolate isolate) => isolate,
        onError: (Object error, StackTrace stack) {
          _failure ??= '$debugName could not be spawned: $error';
          _onWorkerFinished(null);
          return null;
        },
      ),
    );
  }

  final WasapiPlaybackControlBlock _block;
  final ReceivePort _receive;
  final Completer<void> _finished = Completer<void>();

  /// The ring a streaming player's two isolates share, or null for a clip that
  /// was already in memory. Owned here, and freed only once both have stopped.
  final WasapiSharedRingBuffer? _ring;

  final List<Future<Isolate?>> _spawns = <Future<Isolate?>>[];
  int _pendingWorkers = 0;
  int _sampleRate;
  int _channels;
  int _frameCount;
  int _positionFrames = 0;
  int _seekSequence = 0;
  int _pendingSeekFrame = 0;
  bool _playRequested = false;
  bool _disposed = false;
  String? _failure;

  /// Why playback stopped, when it stopped by itself. Null while healthy.
  ///
  /// Not part of [PcmAudioPlayer]: a caller that cannot open a device gets a
  /// null player, and one whose device disappears mid-film gets a clock that
  /// stops. This is here so that the reason is visible to a log or a debugger
  /// instead of being swallowed inside an isolate.
  String? get failure => _failure;

  @override
  int get sampleRate {
    _refresh();
    return _sampleRate;
  }

  @override
  int get channels {
    _refresh();
    return _channels;
  }

  @override
  Duration get duration {
    _refresh();
    return framesToDuration(_frameCount, _sampleRate);
  }

  @override
  Duration get position {
    _refresh();
    if (!_disposed) {
      // A seek is answered locally until the pump acknowledges it. Without
      // this the caller would read the *old* position for up to one engine
      // period after seeking, which is exactly the moment a video player is
      // deciding which picture to show.
      _positionFrames = _block.appliedSeekSequence < _seekSequence
          ? _pendingSeekFrame
          : _block.positionFrames;
    }
    return framesToDuration(_positionFrames, _sampleRate);
  }

  @override
  bool get isRunning {
    if (_disposed || !_playRequested) return false;
    final PlaybackState state = _block.state;
    return state != PlaybackState.ended && state != PlaybackState.failed;
  }

  @override
  void play() {
    if (_disposed) return;
    _playRequested = true;
    _block.requestPlaying(true);
  }

  @override
  void pause() {
    if (_disposed) return;
    _playRequested = false;
    _block.requestPlaying(false);
  }

  @override
  void seek(Duration to) {
    if (_disposed) return;
    _refresh();
    int frame = durationToFrames(to, _sampleRate);
    // A container that declares no duration leaves nothing to clamp against;
    // the decoder will simply report end of stream early, which is the same
    // answer arrived at one buffer later.
    if (_frameCount > 0 && frame > _frameCount) frame = _frameCount;
    _pendingSeekFrame = frame;
    _positionFrames = frame;
    _seekSequence = _block.requestSeek(frame);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _refresh();
    _block.requestQuit();
    final List<Isolate?> isolates = await Future.wait(_spawns);
    final List<Isolate> live =
        isolates.whereType<Isolate>().toList(growable: false);
    if (live.isEmpty) {
      _receive.close();
      _block.dispose();
      _ring?.dispose();
      return;
    }
    try {
      await _finished.future.timeout(_shutdownTimeout);
      _receive.close();
      _block.dispose();
      _ring?.dispose();
    } on TimeoutException {
      // A worker is stuck inside a native call and killing the isolates is the
      // only lever left. The shared memory is then leaked on purpose: a few
      // megabytes are cheaper than freeing memory a thread might still be
      // writing to, and that thread is the one holding the audio device.
      _failure = 'a playback isolate did not stop within $_shutdownTimeout';
      for (final Isolate isolate in live) {
        isolate.kill(priority: Isolate.immediate);
      }
      _receive.close();
    }
  }

  /// One worker has stopped. [_finished] waits for all of them, because the
  /// ring and the control block outlive whichever finishes first.
  void _onWorkerFinished(Object? message) {
    if (message is String) _failure ??= message;
    _pendingWorkers--;
    if (_pendingWorkers <= 0 && !_finished.isCompleted) _finished.complete();
  }

  /// Pulls whatever the pump has published. Cheap: four aligned loads.
  void _refresh() {
    if (_disposed) return;
    final int rate = _block.deviceSampleRate;
    if (rate <= 0) return;
    _sampleRate = rate;
    _channels = _block.deviceChannels;
    _frameCount = _block.deviceFrameCount;
  }

  @override
  String toString() => 'WasapiPcmAudioPlayer($_sampleRate Hz, $_channels ch, '
      '${framesToDuration(_frameCount, _sampleRate)}'
      '${_failure == null ? '' : ', failed: $_failure'})';
}

/// The playback isolate's entry point.
///
/// The message is a flat list because everything in it either is an integer or
/// is a [SendPort]: `[sendPort, controlBlockAddress, samplesAddress,
/// sourceSampleRate, sourceChannels, sourceFrameCount]`. Native memory crosses
/// an isolate boundary as an address and nothing else.
void playbackIsolateMain(List<Object> message) {
  final SendPort port = message[0] as SendPort;
  final int blockAddress = message[1] as int;
  final int samplesAddress = message[2] as int;
  final int sourceSampleRate = message[3] as int;
  final int sourceChannels = message[4] as int;
  final int sourceFrameCount = message[5] as int;

  WasapiPlaybackControlBlock? block;
  Object? failure;
  try {
    block = WasapiPlaybackControlBlock.attach(blockAddress);
    _pump(
      block,
      samplesAddress: samplesAddress,
      sourceSampleRate: sourceSampleRate,
      sourceChannels: sourceChannels,
      sourceFrameCount: sourceFrameCount,
    );
  } on Object catch (error) {
    failure = error;
    try {
      block?.state = PlaybackState.failed;
    } on Object {
      // The block itself is unusable; the message below is all that is left.
    }
  } finally {
    // Attached, so this releases nothing - the player owns the allocation and
    // frees it only after this message arrives.
    block?.dispose();
    port.send(failure?.toString());
  }
}

void _pump(
  WasapiPlaybackControlBlock block, {
  required int samplesAddress,
  required int sourceSampleRate,
  required int sourceChannels,
  required int sourceFrameCount,
}) {
  final WasapiAudioBackend backend = WasapiAudioBackend();
  final WasapiRenderStream stream =
      backend.openStream(const AudioStreamRequest());
  final NativeArena arena = NativeArena();
  ConformedPcmBuffer? conformed;
  NativePcmClipPlayer? clip;
  int mmcss = 0;
  try {
    final AudioFormat format = stream.configuration.format;
    if (format.sampleFormat != AudioSampleFormat.float32 ||
        !format.interleaved) {
      throw AudioBackendException(
        'playback',
        'the endpoint negotiated $format; this player renders interleaved '
            'float32',
      );
    }

    // The decoded clip belongs to the isolate that opened the player. This is
    // a view of it, and the conversion below - when the endpoint did not
    // negotiate the file's own rate or channel count - is the copy that keeps
    // the pitch, and therefore the clock, honest.
    final NativePcmAudioBuffer source = NativePcmAudioBuffer.borrow(
      samples: Pointer<Float>.fromAddress(samplesAddress),
      sampleRate: sourceSampleRate,
      channels: sourceChannels,
      frameCount: sourceFrameCount,
    );
    conformed = conformPcmBuffer(
      source,
      sampleRate: format.sampleRate,
      channels: format.channels,
    );
    final int frameCount = conformed.buffer.frameCount;
    final NativePcmClipPlayer player = NativePcmClipPlayer(conformed.buffer);
    clip = player;
    block.publishDeviceFormat(
      sampleRate: format.sampleRate,
      channels: format.channels,
      frameCount: frameCount,
    );
    block.state = PlaybackState.ready;

    final EndpointRenderClock clock = EndpointRenderClock(
      bufferFrames: stream.configuration.bufferFrames,
    );
    final PlaybackControlSnapshot control = PlaybackControlSnapshot();
    int appliedSeek = 0;
    int published = 0;
    bool running = false;
    // An empty clip is over before it starts; without this the pump would sit
    // there rendering silence at a position that can never reach the end.
    bool ended = frameCount == 0;

    mmcss = WasapiNativeApi.load().avSetCharacteristics(
      arena.allocateUtf16('Pro Audio'),
      arena.allocate<Uint32>(sizeOf<Uint32>()),
    );

    while (true) {
      // On contention the previous snapshot stands: a transport change is
      // never lost, only ever one period late.
      block.tryReadControl(control);
      if (control.quitRequested) break;

      if (control.seekSequence != appliedSeek) {
        appliedSeek = control.seekSequence;
        if (running) {
          // Stop discards what is queued in the endpoint. That is the point:
          // without it, up to a full buffer of pre-seek audio would still be
          // heard after the clock has already jumped.
          stream.stop();
          running = false;
        }
        player
          ..playing = false
          ..seekToFrame(control.seekFrame);
        published = player.positionFrames;
        ended = false;
        block
          ..positionFrames = published
          ..appliedSeekSequence = appliedSeek
          ..state = PlaybackState.ready;
      }

      final bool wantsPlay = control.playRequested && !ended;
      if (wantsPlay && !running) {
        stream.start();
        clock.restart(player.positionFrames);
        player.playing = true;
        running = true;
        block.state = PlaybackState.rendering;
      } else if (!wantsPlay && running) {
        stream.stop();
        running = false;
        player
          ..playing = false
          // Everything written but not heard is about to be discarded by
          // Reset, so the clip cursor goes back to where the needle actually
          // is. The published position can be up to one period behind the
          // device, so a resume may repeat a few milliseconds - which is the
          // right way to be wrong, since the alternative is a silent gap.
          ..seekToFrame(clock.positionFrames);
        published = player.positionFrames;
        block
          ..positionFrames = published
          ..state = ended ? PlaybackState.ended : PlaybackState.ready;
      }

      if (!running) {
        stream.waitForPeriod(timeoutMilliseconds: _idlePollMilliseconds);
        continue;
      }
      if (!stream.waitForPeriod(
        timeoutMilliseconds: _pumpTimeoutMilliseconds,
      )) {
        continue;
      }

      final int rendered = stream.renderAvailableWith(player);
      final int position = clock.onRendered(rendered);
      published = position < frameCount ? position : frameCount;
      block.positionFrames = published;
      // `player.isAtEnd` means the last frame has been *written*; the endpoint
      // still has to play it. Waiting for the clock to reach the end as well
      // is what stops the final buffer from being cut off.
      if (player.isAtEnd && published >= frameCount) ended = true;
    }
  } finally {
    if (mmcss != 0) WasapiNativeApi.load().avRevertCharacteristics(mmcss);
    arena.dispose();
    clip?.dispose();
    // Releases the converted copy, if there was one; never the caller's clip.
    conformed?.disposeIfOwned();
    stream.dispose();
  }
}
