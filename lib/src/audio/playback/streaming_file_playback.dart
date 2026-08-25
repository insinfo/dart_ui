/// Playing a file by keeping a few seconds of it ready, not all of it.
///
/// ## The shape, and why it is three isolates
///
/// ```
///   owner isolate            producer isolate           pump isolate
///   (the app)                (decode + resample)        (WASAPI realtime)
///        |                          |                        |
///        |--- control block --------+------------------------|
///        |    (transport down, clock up, seek handshake)      |
///                                   |                        |
///                                   |--- ring buffer ------->|
///                                       (a few seconds of
///                                        device-format PCM)
/// ```
///
/// The pump is a synchronous, event-driven loop with an engine period of
/// around ten milliseconds to meet, and `IMFSourceReader::ReadSample` is a
/// call that usually returns in under a millisecond and occasionally goes to
/// the disk for fifty. Putting the second inside the first would be a dropout
/// waiting for a cold cache, so decoding gets its own isolate and the two
/// communicate through a bounded ring: the producer fills it when there is
/// room and sleeps when there is not, and the consumer never blocks behind it.
///
/// The owner isolate is the application's. It touches neither the reader nor
/// the stream - only the control block, which is eighty bytes of aligned
/// integers.
///
/// ## What bounds memory
///
/// The ring, and nothing else. It is allocated once at [_ringSeconds] of the
/// device format and never grows, the resampler holds a window of a couple of
/// source frames, and the reader holds one decoded block. A twenty-minute file
/// and a four-second file cost the same.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import '../audio_device.dart';
import '../audio_format.dart';
import '../dsp/native_audio_processor.dart';
import '../windows/media_foundation_audio_reader.dart';
import '../windows/wasapi_backend.dart';
import '../windows/wasapi_bindings.dart';
import '../windows/wasapi_render_stream.dart';
import '../windows/wasapi_shared_ring_buffer.dart';
import 'endpoint_render_clock.dart';
import 'streaming_pcm_resampler.dart';
import 'wasapi_playback_control_block.dart';

/// How much device-format audio the ring holds.
///
/// Four seconds is the trade the whole design turns on. Less, and a producer
/// descheduled behind a disk read or a garbage collection underruns. More, and
/// the memory is wasted - the producer decodes fifty times faster than
/// realtime, so it is never the reason the ring runs dry - and a seek has more
/// to throw away. At 48 kHz stereo float this is 1.5 MB, whatever the file.
const int _ringSeconds = 4;

/// How much must be in the ring before the pump is allowed to start.
///
/// This is the *only* thing standing between `play()` and the first sample, so
/// it is deliberately small: a quarter of a second is around five milliseconds
/// of decoding, and it exists to cover the gap between starting the engine and
/// the producer's next wakeup, not to build a cushion. The cushion is the ring,
/// and it fills while the first quarter second plays.
const Duration _prerollDuration = Duration(milliseconds: 250);

/// How many frames the producer resamples and copies at a time.
///
/// Small on purpose. This is the size of the memcpy the producer performs
/// while holding the ring's lock, and the realtime consumer only ever *tries*
/// that lock - so every frame in a write is a frame of the window in which the
/// pump could come away empty-handed. A thousand frames is a few microseconds.
const int _stagingFrames = 1024;

/// How long the producer sleeps when the ring is full or the source is spent.
const Duration _producerIdle = Duration(milliseconds: 5);

/// Matches `wasapi_pcm_audio_player.dart`: one engine period's latency on a
/// press of play while the engine is stopped and nothing is waking the pump.
const int _idlePollMilliseconds = 10;

/// A backstop only; while running, the period event arrives long first.
const int _pumpTimeoutMilliseconds = 200;

/// How many times the pump retries the ring's lock before rendering silence.
///
/// The producer holds it only for a [_stagingFrames] memcpy, so a failure to
/// acquire means "caught it mid-copy", and the copy is over in microseconds. A
/// handful of retries turns that into no glitch at all; giving up after them
/// is what stops a wedged producer from wedging the audio thread too.
const int _ringAcquireAttempts = 6;

/// The frame count the ring should hold for a given device format.
int ringCapacityFrames(int sampleRate) =>
    math.max(2, sampleRate * _ringSeconds);

// ---------------------------------------------------------------------------
// Producer
// ---------------------------------------------------------------------------

/// The decode isolate's entry point.
///
/// The message is `[sendPort, controlBlockAddress, ringAddress, path,
/// targetSampleRate, targetChannels]`.
///
/// The target format is in the message rather than read back from the pump,
/// and that is a deliberate race with a proof behind it: the owner obtained it
/// from `IAudioClient::GetMixFormat`, and `openStream` with no preferred format
/// negotiates by calling exactly that. The two agree by construction, and the
/// pump refuses to render if they ever do not. Waiting instead would cost the
/// half second the pump spends starting the audio engine - half a second in
/// which this isolate could have opened the file and filled the ring, which is
/// precisely what it now does.
void streamingAudioProducerMain(List<Object> message) {
  final SendPort port = message[0] as SendPort;
  final int blockAddress = message[1] as int;
  final int ringAddress = message[2] as int;
  final String path = message[3] as String;
  final int targetRate = message[4] as int;
  final int targetChannels = message[5] as int;

  WasapiPlaybackControlBlock? block;
  WasapiSharedRingBuffer? ring;
  Object? failure;
  try {
    block = WasapiPlaybackControlBlock.attach(blockAddress);
    ring = WasapiSharedRingBuffer.attach(ringAddress);
    _produce(
      block,
      ring,
      path,
      targetRate: targetRate,
      targetChannels: targetChannels,
    );
  } on Object catch (error) {
    failure = error;
    try {
      block?.state = PlaybackState.failed;
    } on Object {
      // The block itself is unusable; the message below is all that is left.
    }
  } finally {
    // Both are attachments, so these release nothing: the owner allocated the
    // storage and frees it only once this message and the pump's have arrived.
    ring?.dispose();
    block?.dispose();
    port.send(failure?.toString());
  }
}

void _produce(
  WasapiPlaybackControlBlock block,
  WasapiSharedRingBuffer ring,
  String path, {
  required int targetRate,
  required int targetChannels,
}) {
  final PlaybackControlSnapshot control = PlaybackControlSnapshot();
  if (targetRate <= 0 || targetChannels <= 0) {
    throw StateError('the owner probed no usable device format');
  }
  final int bytesPerFrame = targetChannels * sizeOf<Float>();
  if (ring.bytesPerFrame != bytesPerFrame) {
    throw StateError(
      'the ring was sized for ${ring.bytesPerFrame} bytes per frame but the '
      'endpoint negotiated $bytesPerFrame',
    );
  }
  final int prerollFrames = math.min(
    ring.capacityFrames ~/ 2,
    durationToFrames(_prerollDuration, targetRate),
  );

  final MediaFoundationAudioReader reader =
      MediaFoundationAudioReader.open(path);
  final Pointer<Uint8> staging =
      NativeAllocator.instance.allocate<Uint8>(_stagingFrames * bytesPerFrame);
  // A Dart view of the same bytes, so the resampler writes straight into the
  // memory the ring copies from. One buffer, not two, and no sample is ever
  // touched twice on this path.
  final Float32List stagingFloats =
      staging.cast<Float>().asTypedList(_stagingFrames * targetChannels);
  try {
    StreamingPcmResampler resampler = StreamingPcmResampler(
      sourceSampleRate: reader.sampleRate,
      sourceChannels: reader.channels,
      targetSampleRate: targetRate,
      targetChannels: targetChannels,
    );
    int formatGeneration = reader.formatGeneration;
    int appliedSeek = 0;
    int originFrame = 0;
    bool needsOrigin = true;
    bool ended = false;
    bool announced = false;

    void announceIfPrimed() {
      if (announced || needsOrigin) return;
      if (!ended && ring.availableReadFrames < prerollFrames) return;
      block.producerSequence = appliedSeek;
      announced = true;
    }

    while (true) {
      block.tryReadControl(control);
      if (control.quitRequested) break;
      if (block.state == PlaybackState.failed) break;

      if (control.seekSequence != appliedSeek) {
        appliedSeek = control.seekSequence;
        // Withdraw the ring before touching it: the pump renders only while
        // this matches the sequence it has applied, so this one store is what
        // stops a frame of the old position from being heard after the jump.
        block.producerSequence = producerSequenceIdle;
        originFrame = control.seekFrame;
        reader.seek(framesToDuration(originFrame, targetRate));
        resampler.reset();
        ring.clear();
        needsOrigin = true;
        ended = false;
        announced = false;
        block
          ..producerEnded = false
          ..producerOriginFrame = originFrame
          ..producerTotalFrames = 0;
        continue;
      }

      if (ended) {
        announceIfPrimed();
        sleep(_producerIdle);
        continue;
      }

      final int space = ring.availableWriteFrames;
      if (space <= 0) {
        announceIfPrimed();
        sleep(_producerIdle);
        continue;
      }

      final int produced =
          resampler.read(stagingFloats, math.min(space, _stagingFrames));
      if (produced > 0) {
        ring.writeFrames(staging, produced);
        announceIfPrimed();
        continue;
      }
      if (resampler.isFinished) {
        ended = true;
        final int total = originFrame + resampler.outputFramesProduced;
        block
          ..producerTotalFrames = total
          ..producerEnded = true;
        // Only from the start is this the length of the *track*. After a seek
        // it is the length of what was played from there, which says nothing
        // about the part that was skipped.
        if (originFrame == 0) block.deviceFrameCount = total;
        announceIfPrimed();
        continue;
      }

      final Float32List? chunk = reader.readChunk();
      if (chunk == null) {
        resampler.endOfSource();
        continue;
      }
      if (reader.formatGeneration != formatGeneration) {
        // A mid-stream format change. Rebuilding loses the one source frame of
        // interpolation history across the switch, which is right: the old
        // frame is in a format the new one has no relation to.
        formatGeneration = reader.formatGeneration;
        originFrame += resampler.outputFramesProduced;
        resampler = StreamingPcmResampler(
          sourceSampleRate: reader.sampleRate,
          sourceChannels: reader.channels,
          targetSampleRate: targetRate,
          targetChannels: targetChannels,
        );
      }
      if (chunk.isEmpty) {
        // A gap or a stream tick: no samples, and no timestamp worth trusting
        // either. Taking an origin from one would put a seek to ten minutes at
        // zero, so the decision waits for a block that actually carries audio.
        continue;
      }
      if (needsOrigin) {
        // Where the decoder really landed, which for a compressed stream is
        // the nearest frame boundary at or before the request. Publishing the
        // request instead would put every seek up to a frame out of sync.
        originFrame = durationToFrames(reader.chunkStart, targetRate);
        block.producerOriginFrame = originFrame;
        needsOrigin = false;
      }
      resampler.addSource(chunk);
    }
  } finally {
    NativeAllocator.instance.free(staging);
    reader.dispose();
  }
}

// ---------------------------------------------------------------------------
// Pump
// ---------------------------------------------------------------------------

/// Hands the endpoint whatever the ring has, and zero for whatever it has not.
final class RingPcmSource
    with DisposableMixin
    implements NativeFloat32AudioProcessor {
  RingPcmSource(
    this._ring, {
    required this.sampleRate,
    required this.channels,
  });

  final WasapiSharedRingBuffer _ring;

  @override
  final int sampleRate;

  @override
  final int channels;

  /// Frames the last [process] took from the ring, as opposed to left silent.
  int deliveredFrames = 0;

  @override
  void process(Pointer<Float> interleavedSamples, int frames) {
    // `renderAvailableWith` has already zeroed the block, so a short read is
    // silence rather than whatever the endpoint buffer held a period ago.
    final Pointer<Uint8> destination = interleavedSamples.cast<Uint8>();
    int delivered = 0;
    for (int attempt = 0; attempt < _ringAcquireAttempts; attempt++) {
      delivered = _ring.tryReadFrames(destination, frames);
      if (delivered > 0) break;
    }
    deliveredFrames = delivered;
  }

  @override
  void onDispose() {}
}

/// The realtime isolate's entry point for a streaming player.
///
/// The message is `[sendPort, controlBlockAddress, ringAddress]`.
void streamingPlaybackIsolateMain(List<Object> message) {
  final SendPort port = message[0] as SendPort;
  final int blockAddress = message[1] as int;
  final int ringAddress = message[2] as int;

  WasapiPlaybackControlBlock? block;
  WasapiSharedRingBuffer? ring;
  Object? failure;
  try {
    block = WasapiPlaybackControlBlock.attach(blockAddress);
    ring = WasapiSharedRingBuffer.attach(ringAddress);
    _streamPump(block, ring);
  } on Object catch (error) {
    failure = error;
    try {
      block?.state = PlaybackState.failed;
    } on Object {
      // The block itself is unusable; the message below is all that is left.
    }
  } finally {
    ring?.dispose();
    block?.dispose();
    port.send(failure?.toString());
  }
}

void _streamPump(
  WasapiPlaybackControlBlock block,
  WasapiSharedRingBuffer ring,
) {
  final WasapiAudioBackend backend = WasapiAudioBackend();
  final WasapiRenderStream stream =
      backend.openStream(const AudioStreamRequest());
  final NativeArena arena = NativeArena();
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
    if (ring.bytesPerFrame != format.bytesPerFrame) {
      // The owner sized the ring from a probe of the same endpoint moments
      // earlier, so this means the default device changed underneath the open.
      // Failing is honest; resampling into a ring of the wrong stride is not.
      throw AudioBackendException(
        'playback',
        'the ring holds ${ring.bytesPerFrame} bytes per frame but the endpoint '
            'negotiated ${format.bytesPerFrame}',
      );
    }
    if (block.deviceSampleRate != format.sampleRate ||
        block.deviceChannels != format.channels) {
      // The producer is already resampling to the format the owner probed a
      // moment ago through `GetMixFormat`, which is the same call this stream
      // negotiated with. A disagreement means the default endpoint changed
      // underneath the open; playing the ring anyway would be the wrong pitch
      // and, worse, a clock that runs at the wrong speed.
      throw AudioBackendException(
        'playback',
        'the endpoint negotiated ${format.sampleRate} Hz x${format.channels} '
            'but the file is being decoded for ${block.deviceSampleRate} Hz '
            'x${block.deviceChannels}',
      );
    }
    block.publishDeviceRate(
      sampleRate: format.sampleRate,
      channels: format.channels,
    );
    block.state = PlaybackState.ready;

    final EndpointRenderClock clock = EndpointRenderClock(
      bufferFrames: stream.configuration.bufferFrames,
    );
    final RingPcmSource source = RingPcmSource(
      ring,
      sampleRate: format.sampleRate,
      channels: format.channels,
    );
    final PlaybackControlSnapshot control = PlaybackControlSnapshot();
    int appliedSeek = 0;
    int adoptedOrigin = -1;
    int mediaFrame = 0;
    bool running = false;
    bool ended = false;

    mmcss = WasapiNativeApi.load().avSetCharacteristics(
      arena.allocateUtf16('Pro Audio'),
      arena.allocate<Uint32>(sizeOf<Uint32>()),
    );

    while (true) {
      block.tryReadControl(control);
      if (control.quitRequested) break;

      if (control.seekSequence != appliedSeek) {
        appliedSeek = control.seekSequence;
        if (running) {
          // Stop discards what is queued in the endpoint, which is the point:
          // otherwise up to a full buffer of pre-seek audio is still heard
          // after the clock has already jumped.
          stream.stop();
          running = false;
        }
        mediaFrame = control.seekFrame;
        ended = false;
        block
          ..positionFrames = mediaFrame
          ..appliedSeekSequence = appliedSeek
          ..state = PlaybackState.ready;
      }

      // The ring is only playable while the producer says its contents belong
      // to the seek this pump has applied.
      final bool ringReady = block.producerSequence == appliedSeek;
      if (ringReady && adoptedOrigin != appliedSeek && !running) {
        // A compressed stream seeks to a frame boundary, not to the requested
        // microsecond, and the producer reports where it landed. Adopting it
        // is what keeps the clock describing the audio rather than the wish.
        adoptedOrigin = appliedSeek;
        mediaFrame = block.producerOriginFrame;
        block.positionFrames = mediaFrame;
      }

      final bool wantsPlay = control.playRequested && !ended && ringReady;
      if (wantsPlay && !running) {
        stream.start();
        clock.restart(mediaFrame);
        running = true;
        block.state = PlaybackState.rendering;
      } else if (!wantsPlay && running) {
        stream.stop();
        running = false;
        // `Reset` throws away the frames already handed to the endpoint, and
        // unlike a clip player there is no way to put them back in the ring.
        // So the media position moves *forward* over them - by up to one
        // buffer, ten to thirty milliseconds - rather than back. Forward is
        // the truthful direction: those frames are gone, and the next sample
        // the listener hears is the one after them.
        mediaFrame = clock.positionFrames + clock.inFlightFrames;
        block
          ..positionFrames = mediaFrame
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

      final int rendered = stream.renderAvailableWith(source);
      int position = clock.onRendered(rendered);
      if (block.producerEnded) {
        // The producer knows the exact last frame; the length derived from the
        // container's declared duration is a few frames out on most formats.
        final int total = block.producerTotalFrames;
        if (total > 0 && position >= total) {
          position = total;
          ended = true;
        }
      }
      block.positionFrames = position;
    }
  } finally {
    if (mmcss != 0) WasapiNativeApi.load().avRevertCharacteristics(mmcss);
    arena.dispose();
    stream.dispose();
  }
}
