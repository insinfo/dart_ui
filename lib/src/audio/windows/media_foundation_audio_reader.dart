/// A cursor over a media file's audio track, rather than a copy of it.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'media_foundation_bindings.dart';
import 'wasapi_bindings.dart';

/// How many 100-nanosecond ticks make a second, which is Media Foundation's
/// unit for every timestamp and every duration it reports.
const int _ticksPerSecond = 10000000;

/// Reads the first audio stream of a media file incrementally.
///
/// ## What this is, next to `MediaFoundationAudioDecoder`
///
/// The same `IMFSourceReader`, opened the same way, asked for the same float32
/// PCM. The difference is entirely one of shape: the decoder runs `ReadSample`
/// in a loop until end of stream and hands back one buffer holding the whole
/// track, and this hands back **one block per call** and keeps the reader open
/// between them.
///
/// That difference is the whole point. A twenty-minute soundtrack is around
/// two hundred million float samples; materialising it costs twenty seconds of
/// decoding and, with the intermediate copy the builder needs, several
/// gigabytes of peak memory - all of it spent before the listener hears
/// anything, and all of it proportional to a length nobody chose. A cursor
/// costs one block.
///
/// ## Threading
///
/// `IMFSourceReader` in synchronous mode is called from whatever thread the
/// caller is on, and this class does not serialise anything, so one reader
/// belongs to one isolate and that isolate must not `await` between calls -
/// the same discipline `WasapiRenderStream` documents, for the same reason:
/// the Dart VM is free to move an isolate to another OS thread at a suspension
/// point, and COM apartment state lives on the thread.
///
/// ## Errors
///
/// This throws. The "a silent film still has to play" policy of turning every
/// failure into null belongs one layer up, in the playback platform code,
/// because it is a policy about playback and not about reading.
final class MediaFoundationAudioReader with DisposableMixin {
  MediaFoundationAudioReader._(
    this._api,
    this._com,
    this._reader,
    this._ownsApartment, {
    required this.sampleRate,
    required this.channels,
    required this.duration,
  });

  /// Opens [path] and positions the cursor at its start.
  ///
  /// The format reported is the decoder's *output* format - float32, at the
  /// track's own sample rate and channel count - because that is what
  /// `SetCurrentMediaType` negotiated, not what the file happens to contain.
  factory MediaFoundationAudioReader.open(String path) {
    final MediaFoundationApi api = MediaFoundationApi.load();
    final WasapiNativeApi com = WasapiNativeApi.load();
    final bool ownsApartment = com.initializeApartment();
    final NativeArena arena = NativeArena();
    bool started = false;
    bool success = false;
    MfSourceReader? reader;
    MfAttributes? requestedType;
    MfAttributes? currentType;
    try {
      checkHresult(api.startup(mfVersion, mfStartupFull), 'MFStartup');
      started = true;
      final Pointer<Pointer<Void>> readerOut = arena.allocateOutPointer();
      checkHresult(
        api.createSourceReaderFromUrl(
          arena.allocateUtf16(path),
          nullptr,
          readerOut,
        ),
        'MFCreateSourceReaderFromURL',
        detail: path,
      );
      reader = MfSourceReader(readerOut.value);
      checkHresult(
        reader.setStreamSelection(mfAllStreams, false),
        'IMFSourceReader::SetStreamSelection(all, false)',
      );
      checkHresult(
        reader.setStreamSelection(mfFirstAudioStream, true),
        'IMFSourceReader::SetStreamSelection(audio, true)',
      );

      final Pointer<Pointer<Void>> typeOut = arena.allocateOutPointer();
      checkHresult(api.createMediaType(typeOut), 'MFCreateMediaType');
      requestedType = MfAttributes(typeOut.value, 'IMFMediaType');
      requestedType
        ..setGuid(mfMtMajorType, mfMediaTypeAudio, arena)
        ..setGuid(mfMtSubtype, mfAudioFormatFloat, arena);
      checkHresult(
        reader.setCurrentMediaType(mfFirstAudioStream, requestedType.pointer),
        'IMFSourceReader::SetCurrentMediaType(float32)',
      );

      typeOut.value = nullptr;
      checkHresult(
        reader.getCurrentMediaType(mfFirstAudioStream, typeOut),
        'IMFSourceReader::GetCurrentMediaType',
      );
      currentType = MfAttributes(typeOut.value, 'IMFMediaType');
      final int channels = currentType.getUint32(mfMtAudioChannels, arena);
      final int sampleRate = currentType.getUint32(mfMtAudioSampleRate, arena);
      if (channels <= 0 || sampleRate <= 0) {
        throw StateError('Media Foundation returned an invalid PCM format');
      }

      // The container's own duration, which is what makes `duration` free.
      // Decoding twenty minutes of audio to count its frames is the single
      // most expensive way to learn a number the file already states.
      final int? ticks = reader.getUint64PresentationAttribute(
        mfMediaSourceStream,
        mfPdDuration,
        arena,
      );
      final Duration duration = ticks == null || ticks <= 0
          ? Duration.zero
          : Duration(microseconds: ticks ~/ 10);

      final MediaFoundationAudioReader opened = MediaFoundationAudioReader._(
        api,
        com,
        reader,
        ownsApartment,
        sampleRate: sampleRate,
        channels: channels,
        duration: duration,
      );
      // From here the reader owns the source reader, the `MFStartup` count and
      // the apartment; `dispose` releases all three, in that order.
      success = true;
      return opened;
    } finally {
      currentType?.dispose();
      requestedType?.dispose();
      arena.dispose();
      if (!success) {
        reader?.dispose();
        if (started) checkHresult(api.shutdown(), 'MFShutdown');
        if (ownsApartment) com.coUninitialize();
      }
    }
  }

  final MediaFoundationApi _api;
  final WasapiNativeApi _com;
  final MfSourceReader _reader;
  final bool _ownsApartment;

  /// The decoder's output sample rate. Not the endpoint's - see
  /// `StreamingPcmResampler` for the bridge between the two.
  int sampleRate;

  /// The decoder's output channel count.
  int channels;

  /// The track's length as the container declares it.
  ///
  /// [Duration.zero] when the container declares none, which happens for live
  /// sources and for files that were truncated mid-write. A caller that needs
  /// a real length in that case has no option but to read to the end.
  final Duration duration;

  final NativeArena _arena = NativeArena();
  late final Pointer<Uint32> _actualStream = _arena<Uint32>();
  late final Pointer<Uint32> _flags = _arena<Uint32>();
  late final Pointer<Int64> _timestamp = _arena<Int64>();
  late final Pointer<Pointer<Void>> _sampleOut = _arena.allocateOutPointer();
  late final Pointer<Pointer<Void>> _bufferOut = _arena.allocateOutPointer();
  late final Pointer<Pointer<Uint8>> _bytesOut = _arena<Pointer<Uint8>>();
  late final Pointer<Uint32> _maximum = _arena<Uint32>();
  late final Pointer<Uint32> _current = _arena<Uint32>();

  Float32List _chunk = Float32List(0);
  bool _atEnd = false;
  int _formatGeneration = 0;
  Duration _chunkStart = Duration.zero;

  /// Whether the last [readChunk] reported end of stream.
  bool get isAtEnd => _atEnd;

  /// Bumped whenever the decoder changed its output format mid-stream.
  ///
  /// Rare, and legal: a container may switch codecs or channel layouts at a
  /// segment boundary. A caller holding a resampler built for the old format
  /// compares this against what it built with and rebuilds when it moved,
  /// which is cheaper and more honest than pretending the format is fixed.
  int get formatGeneration => _formatGeneration;

  /// The presentation time of the block the last [readChunk] returned.
  Duration get chunkStart => _chunkStart;

  /// Decodes one block, or returns null at end of stream.
  ///
  /// The returned list is a view of a buffer this reader owns and reuses; it
  /// is valid until the next call. An **empty** list is not an end: Media
  /// Foundation reports gaps and stream ticks as samples with no data, and
  /// returning from those promptly is what lets a producer loop check its
  /// transport controls between blocks instead of after them.
  Float32List? readChunk() {
    throwIfDisposed();
    if (_atEnd) return null;
    _sampleOut.value = nullptr;
    _flags.value = 0;
    _timestamp.value = 0;
    checkHresult(
      _reader.readSample(
        mfFirstAudioStream,
        _actualStream,
        _flags,
        _timestamp,
        _sampleOut,
      ),
      'IMFSourceReader::ReadSample',
    );
    final int flags = _flags.value;
    if ((flags & mfSourceReaderCurrentMediaTypeChanged) != 0) {
      _refreshFormat();
    }
    _chunkStart = Duration(microseconds: _timestamp.value ~/ 10);

    int frames = 0;
    if (_sampleOut.value != nullptr) {
      final MfSample sample = MfSample(_sampleOut.value);
      try {
        _bufferOut.value = nullptr;
        checkHresult(
          sample.convertToContiguousBuffer(_bufferOut),
          'IMFSample::ConvertToContiguousBuffer',
        );
        final MfMediaBuffer buffer = MfMediaBuffer(_bufferOut.value);
        try {
          checkHresult(
            buffer.lock(_bytesOut, _maximum, _current),
            'IMFMediaBuffer::Lock',
          );
          try {
            final int bytesPerFrame = channels * sizeOf<Float>();
            frames = _current.value ~/ bytesPerFrame;
            final int samples = frames * channels;
            if (_chunk.length < samples) _chunk = Float32List(samples);
            if (samples > 0) {
              // Copied while the buffer is still locked, for the reason the
              // decoder documents: the bytes are the media buffer's, not ours,
              // and they are recycled the moment it is unlocked.
              _chunk.setRange(
                0,
                samples,
                _bytesOut.value.cast<Float>().asTypedList(samples),
              );
            }
          } finally {
            checkHresult(buffer.unlock(), 'IMFMediaBuffer::Unlock');
          }
        } finally {
          buffer.dispose();
        }
      } finally {
        sample.dispose();
      }
    }
    if ((flags & mfSourceReaderEndOfStream) != 0) _atEnd = true;
    return Float32List.sublistView(_chunk, 0, frames * channels);
  }

  /// Repositions the cursor. The next [readChunk] starts at or just before
  /// [to].
  ///
  /// "Just before" is the honest description: a compressed stream is only
  /// seekable to a frame boundary, so Media Foundation lands on the nearest
  /// one it can decode from and reports where it really landed in
  /// [chunkStart]. A caller synchronising picture uses that, not the request.
  void seek(Duration to) {
    throwIfDisposed();
    final Duration target = to < Duration.zero ? Duration.zero : to;
    final int ticks = target.inMicroseconds *
        (_ticksPerSecond ~/ Duration.microsecondsPerSecond);
    checkHresult(
      _reader.setCurrentPosition(ticks, _arena),
      'IMFSourceReader::SetCurrentPosition',
      detail: '$target',
    );
    _atEnd = false;
    _chunkStart = target;
  }

  void _refreshFormat() {
    final NativeArena arena = NativeArena();
    MfAttributes? currentType;
    try {
      final Pointer<Pointer<Void>> typeOut = arena.allocateOutPointer();
      typeOut.value = nullptr;
      checkHresult(
        _reader.getCurrentMediaType(mfFirstAudioStream, typeOut),
        'IMFSourceReader::GetCurrentMediaType',
      );
      currentType = MfAttributes(typeOut.value, 'IMFMediaType');
      final int newChannels = currentType.getUint32(mfMtAudioChannels, arena);
      final int newRate = currentType.getUint32(mfMtAudioSampleRate, arena);
      if (newChannels <= 0 || newRate <= 0) return;
      if (newChannels == channels && newRate == sampleRate) return;
      channels = newChannels;
      sampleRate = newRate;
      _formatGeneration++;
    } finally {
      currentType?.dispose();
      arena.dispose();
    }
  }

  @override
  void onDispose() {
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

    attempt(() => _reader.flush(mfFirstAudioStream));
    attempt(_reader.dispose);
    attempt(_arena.dispose);
    attempt(() => checkHresult(_api.shutdown(), 'MFShutdown'));
    if (_ownsApartment) attempt(_com.coUninitialize);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }

  @override
  String toString() => 'MediaFoundationAudioReader($sampleRate Hz '
      'x$channels, $duration)';
}
