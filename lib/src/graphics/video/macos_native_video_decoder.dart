/// Native macOS video decoding through AVFoundation and CoreVideo.
///
/// This adapter asks `AVAssetReader` for BGRA pixel buffers. AVFoundation
/// performs demuxing and selects VideoToolbox when the codec and machine allow
/// it; callers can fall back to the process-based FFmpeg adapter when
/// [openMacosNativeVideoDecoder] reports `native-open`.
library;

import 'dart:ffi';
import 'dart:io';

import '../../ffi/native_memory.dart';
import 'video_decoder.dart';
import 'video_frame.dart';
import 'video_frame_ring_buffer.dart';

/// Opens [path] with AVFoundation, without starting an FFmpeg process.
Future<VideoDecoder> openMacosNativeVideoDecoder(
  String path,
  VideoDecoderOptions options,
) async {
  if (!Platform.isMacOS) {
    throw const VideoDecoderException(
      'native-open',
      'AVFoundation video decoding is available only on macOS',
    );
  }
  options.validate();
  final File file = File(path);
  if (!await file.exists()) {
    throw VideoDecoderException('native-open', 'file does not exist: $path');
  }
  try {
    final _MacVideoBindings bindings = _MacVideoBindings();
    return bindings.open(file.absolute.path, options);
  } on VideoDecoderException {
    rethrow;
  } on Object catch (error) {
    throw VideoDecoderException(
      'native-open',
      'AVFoundation could not open $path',
      cause: error,
    );
  }
}

final class _CMTime extends Struct {
  @Int64()
  external int value;

  @Int32()
  external int timescale;

  @Uint32()
  external int flags;

  @Int64()
  external int epoch;
}

typedef _ObjcNoArgNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcNoArgDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcOnePtrNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcOnePtrDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcTwoPtrNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcTwoPtrDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcIndexNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  UintPtr,
);
typedef _ObjcIndexDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  int,
);
typedef _ObjcIntegerNative = IntPtr Function(
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcIntegerDart = int Function(Pointer<Void>, Pointer<Void>);
typedef _ObjcBoolNative = Uint8 Function(Pointer<Void>, Pointer<Void>);
typedef _ObjcBoolDart = int Function(Pointer<Void>, Pointer<Void>);
typedef _ObjcBoolPtrNative = Uint8 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcBoolPtrDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcVoidNative = Void Function(Pointer<Void>, Pointer<Void>);
typedef _ObjcVoidDart = void Function(Pointer<Void>, Pointer<Void>);
typedef _ObjcVoidPtrNative = Void Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcVoidPtrDart = void Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ObjcCStringNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint8>,
);
typedef _ObjcCStringDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint8>,
);

final class _MacVideoBindings {
  _MacVideoBindings()
      : _objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib'),
        _coreMedia = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreMedia.framework/CoreMedia',
        ),
        _coreVideo = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreVideo.framework/CoreVideo',
        ),
        _coreFoundation = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
        ) {
    // Loading the framework registers AVAssetReader and AVURLAsset with the
    // Objective-C runtime. Calls themselves then travel through objc_msgSend.
    DynamicLibrary.open(
      '/System/Library/Frameworks/AVFoundation.framework/AVFoundation',
    );
    _getClass = _objc.lookupFunction<Pointer<Void> Function(Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Uint8>)>('objc_getClass');
    _selector = _objc.lookupFunction<Pointer<Void> Function(Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Uint8>)>('sel_registerName');
    final Pointer<NativeFunction<Void Function()>> send =
        _objc.lookup<NativeFunction<Void Function()>>('objc_msgSend');
    _noArg = send.cast<NativeFunction<_ObjcNoArgNative>>().asFunction();
    _onePtr = send.cast<NativeFunction<_ObjcOnePtrNative>>().asFunction();
    _twoPtr = send.cast<NativeFunction<_ObjcTwoPtrNative>>().asFunction();
    _index = send.cast<NativeFunction<_ObjcIndexNative>>().asFunction();
    _integer = send.cast<NativeFunction<_ObjcIntegerNative>>().asFunction();
    _bool = send.cast<NativeFunction<_ObjcBoolNative>>().asFunction();
    _boolPtr = send.cast<NativeFunction<_ObjcBoolPtrNative>>().asFunction();
    _void = send.cast<NativeFunction<_ObjcVoidNative>>().asFunction();
    _voidPtr = send.cast<NativeFunction<_ObjcVoidPtrNative>>().asFunction();
    _cstring = send.cast<NativeFunction<_ObjcCStringNative>>().asFunction();

    _sampleImageBuffer = _coreMedia.lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>(
      'CMSampleBufferGetImageBuffer',
    );
    _sampleTimestamp = _coreMedia.lookupFunction<
        _CMTime Function(Pointer<Void>), _CMTime Function(Pointer<Void>)>(
      'CMSampleBufferGetPresentationTimeStamp',
    );
    _sampleDuration = _coreMedia.lookupFunction<_CMTime Function(Pointer<Void>),
        _CMTime Function(Pointer<Void>)>('CMSampleBufferGetDuration');
    _timeSeconds = _coreMedia.lookupFunction<Double Function(_CMTime),
        double Function(_CMTime)>('CMTimeGetSeconds');
    _cfRelease = _coreFoundation.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('CFRelease');
    _lock = _coreVideo.lookupFunction<Int32 Function(Pointer<Void>, Uint64),
        int Function(Pointer<Void>, int)>('CVPixelBufferLockBaseAddress');
    _unlock = _coreVideo.lookupFunction<Int32 Function(Pointer<Void>, Uint64),
        int Function(Pointer<Void>, int)>('CVPixelBufferUnlockBaseAddress');
    _baseAddress = _coreVideo.lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('CVPixelBufferGetBaseAddress');
    _width = _coreVideo.lookupFunction<UintPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CVPixelBufferGetWidth');
    _height = _coreVideo.lookupFunction<UintPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CVPixelBufferGetHeight');
    _bytesPerRow = _coreVideo.lookupFunction<UintPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CVPixelBufferGetBytesPerRow');
    _memcpy = DynamicLibrary.process().lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>, UintPtr),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int)>('memcpy');
  }

  final DynamicLibrary _objc;
  final DynamicLibrary _coreMedia;
  final DynamicLibrary _coreVideo;
  final DynamicLibrary _coreFoundation;

  late final Pointer<Void> Function(Pointer<Uint8>) _getClass;
  late final Pointer<Void> Function(Pointer<Uint8>) _selector;
  late final _ObjcNoArgDart _noArg;
  late final _ObjcOnePtrDart _onePtr;
  late final _ObjcTwoPtrDart _twoPtr;
  late final _ObjcIndexDart _index;
  late final _ObjcIntegerDart _integer;
  late final _ObjcBoolDart _bool;
  late final _ObjcBoolPtrDart _boolPtr;
  late final _ObjcVoidDart _void;
  late final _ObjcVoidPtrDart _voidPtr;
  late final _ObjcCStringDart _cstring;

  late final Pointer<Void> Function(Pointer<Void>) _sampleImageBuffer;
  late final _CMTime Function(Pointer<Void>) _sampleTimestamp;
  late final _CMTime Function(Pointer<Void>) _sampleDuration;
  late final double Function(_CMTime) _timeSeconds;
  late final void Function(Pointer<Void>) _cfRelease;
  late final int Function(Pointer<Void>, int) _lock;
  late final int Function(Pointer<Void>, int) _unlock;
  late final Pointer<Void> Function(Pointer<Void>) _baseAddress;
  late final int Function(Pointer<Void>) _width;
  late final int Function(Pointer<Void>) _height;
  late final int Function(Pointer<Void>) _bytesPerRow;
  late final Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int) _memcpy;

  Pointer<Void> _sel(String name, NativeArena arena) =>
      _selector(arena.allocateAscii(name));

  Pointer<Void> _cls(String name, NativeArena arena) =>
      _getClass(arena.allocateAscii(name));

  void _release(Pointer<Void> object, NativeArena arena) {
    if (object != nullptr) _void(object, _sel('release', arena));
  }

  _MacNativeVideoDecoder open(String path, VideoDecoderOptions options) {
    final NativeArena arena = NativeArena();
    Pointer<Void> asset = nullptr;
    _ReaderSession? session;
    _NativeDecodedFrame? first;
    try {
      final Pointer<Void> pool = _noArg(
        _noArg(_cls('NSAutoreleasePool', arena), _sel('alloc', arena)),
        _sel('init', arena),
      );
      try {
        final Pointer<Void> pathString = _cstring(
          _cls('NSString', arena),
          _sel('stringWithUTF8String:', arena),
          arena.allocateUtf8(path),
        );
        final Pointer<Void> url = _onePtr(
          _cls('NSURL', arena),
          _sel('fileURLWithPath:', arena),
          pathString,
        );
        asset = _twoPtr(
          _noArg(_cls('AVURLAsset', arena), _sel('alloc', arena)),
          _sel('initWithURL:options:', arena),
          url,
          nullptr,
        );
        if (asset == nullptr) {
          throw const VideoDecoderException(
            'native-open',
            'AVURLAsset rejected the input URL',
          );
        }
        session = _newReader(asset, arena);
        first = _readFrame(session, arena, options: options);
        if (first == null) {
          throw const VideoDecoderException(
            'native-open',
            'the asset has no decodable video samples',
          );
        }
        options.validateDecodedFrame(
          width: first.width,
          height: first.height,
          bytesPerPixel: 4,
        );
        return _MacNativeVideoDecoder._(
          this,
          options,
          asset,
          session,
          first,
        );
      } finally {
        _void(pool, _sel('drain', arena));
      }
    } on Object {
      if (session != null) _closeSession(session, arena);
      first?.ring.dispose();
      _release(asset, arena);
      rethrow;
    } finally {
      arena.dispose();
    }
  }

  _ReaderSession _newReader(Pointer<Void> asset, NativeArena arena) {
    // `tracksWithMediaType:` takes one argument; use the actual AV media-type
    // string rather than relying on a data-symbol lookup across SDK versions.
    final Pointer<Void> video = _cstring(
      _cls('NSString', arena),
      _sel('stringWithUTF8String:', arena),
      arena.allocateAscii('vide'),
    );
    final Pointer<Void> videoTracks =
        _onePtr(asset, _sel('tracksWithMediaType:', arena), video);
    final int count = _integer(videoTracks, _sel('count', arena));
    if (count <= 0) {
      throw const VideoDecoderException(
        'native-open',
        'the asset contains no video track',
      );
    }
    final Pointer<Void> track =
        _index(videoTracks, _sel('objectAtIndex:', arena), 0);

    final Pointer<Void> number = _integerObject(
      _cls('NSNumber', arena),
      0x42475241, // kCVPixelFormatType_32BGRA ('BGRA')
      arena,
    );
    final Pointer<Void> key = _coreVideo
        .lookup<Pointer<Void>>('kCVPixelBufferPixelFormatTypeKey')
        .value;
    final Pointer<Void> settings = _twoPtr(
      _cls('NSDictionary', arena),
      _sel('dictionaryWithObject:forKey:', arena),
      number,
      key,
    );
    final Pointer<Void> output = _twoPtr(
      _noArg(_cls('AVAssetReaderTrackOutput', arena), _sel('alloc', arena)),
      _sel('initWithTrack:outputSettings:', arena),
      track,
      settings,
    );
    if (output == nullptr) {
      throw const VideoDecoderException(
        'native-open',
        'AVAssetReaderTrackOutput could not be created',
      );
    }
    final Pointer<Void> reader = _twoPtr(
      _noArg(_cls('AVAssetReader', arena), _sel('alloc', arena)),
      _sel('initWithAsset:error:', arena),
      asset,
      nullptr,
    );
    if (reader == nullptr) {
      _release(output, arena);
      throw const VideoDecoderException(
        'native-open',
        'AVAssetReader could not be created',
      );
    }
    if (_boolPtr(reader, _sel('canAddOutput:', arena), output) == 0) {
      _release(output, arena);
      _release(reader, arena);
      throw const VideoDecoderException(
        'native-open',
        'AVAssetReader refused the BGRA track output',
      );
    }
    _voidPtr(reader, _sel('addOutput:', arena), output);
    if (_bool(reader, _sel('startReading', arena)) == 0) {
      _release(output, arena);
      _release(reader, arena);
      throw const VideoDecoderException(
        'native-open',
        'AVAssetReader failed to start reading',
      );
    }
    return _ReaderSession(reader, output);
  }

  Pointer<Void> _integerObject(
    Pointer<Void> numberClass,
    int value,
    NativeArena arena,
  ) {
    final Pointer<
            NativeFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Uint32)>>
        send =
        _objc.lookup<NativeFunction<Void Function()>>('objc_msgSend').cast();
    return send.asFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int)>()(
        numberClass, _sel('numberWithUnsignedInt:', arena), value);
  }

  _NativeDecodedFrame? _readFrame(
    _ReaderSession session,
    NativeArena arena, {
    required VideoDecoderOptions options,
    NativeVideoFrameRing? ring,
  }) {
    final Pointer<Void> sample =
        _noArg(session.output, _sel('copyNextSampleBuffer', arena));
    if (sample == nullptr) {
      final int status = _integer(session.reader, _sel('status', arena));
      if (status == 3) {
        throw const VideoDecoderException(
          'decode',
          'AVAssetReader reported a decoding failure',
        );
      }
      return null;
    }
    try {
      final Pointer<Void> pixelBuffer = _sampleImageBuffer(sample);
      if (pixelBuffer == nullptr) {
        throw const VideoDecoderException(
          'decode',
          'video sample did not contain a CVPixelBuffer',
        );
      }
      final int lockStatus = _lock(pixelBuffer, 1); // read-only
      if (lockStatus != 0) {
        throw VideoDecoderException(
          'decode',
          'CVPixelBufferLockBaseAddress failed with $lockStatus',
        );
      }
      try {
        final int width = _width(pixelBuffer);
        final int height = _height(pixelBuffer);
        final int stride = _bytesPerRow(pixelBuffer);
        final Pointer<Void> base = _baseAddress(pixelBuffer);
        if (width <= 0 ||
            height <= 0 ||
            stride < width * 4 ||
            base == nullptr) {
          throw const VideoDecoderException(
            'decode',
            'CVPixelBuffer returned invalid BGRA geometry',
          );
        }
        final int frameBytes = options.validateDecodedFrame(
          width: width,
          height: height,
          bytesPerPixel: 4,
        );
        final NativeVideoFrameRing storage = ring ??
            NativeVideoFrameRing(slotCount: 3, bytesPerSlot: frameBytes);
        if (storage.bytesPerSlot != frameBytes) {
          throw VideoDecoderException(
            'decode',
            'the stream changed dimensions to ${width}x$height; native frame '
                'ring slots cannot be resized while published frames may '
                'still reference them',
          );
        }
        final NativeVideoFrameLease lease = storage.acquire();
        final Pointer<Uint8> destination = lease.pointer;
        final int packedStride = width * 4;
        for (var row = 0; row < height; row++) {
          _memcpy(
            Pointer<Void>.fromAddress(
              destination.address + row * packedStride,
            ),
            Pointer<Void>.fromAddress(base.address + row * stride),
            packedStride,
          );
        }
        final double seconds = _timeSeconds(_sampleTimestamp(sample));
        final double durationSeconds = _timeSeconds(_sampleDuration(sample));
        return _NativeDecodedFrame(
          width,
          height,
          storage,
          lease,
          _duration(seconds),
          _duration(durationSeconds),
        );
      } finally {
        _unlock(pixelBuffer, 1);
      }
    } finally {
      _cfRelease(sample);
    }
  }

  void _closeSession(_ReaderSession session, NativeArena arena) {
    _void(session.reader, _sel('cancelReading', arena));
    _release(session.output, arena);
    _release(session.reader, arena);
  }
}

final class _ReaderSession {
  const _ReaderSession(this.reader, this.output);
  final Pointer<Void> reader;
  final Pointer<Void> output;
}

final class _NativeDecodedFrame {
  const _NativeDecodedFrame(
    this.width,
    this.height,
    this.ring,
    this.lease,
    this.timestamp,
    this.duration,
  );
  final int width;
  final int height;
  final NativeVideoFrameRing ring;
  final NativeVideoFrameLease lease;
  final Duration timestamp;
  final Duration duration;
}

final class _MacNativeVideoDecoder implements VideoDecoder {
  _MacNativeVideoDecoder._(
    this._bindings,
    this._options,
    this._asset,
    this._session,
    _NativeDecodedFrame first,
  )   : _streamId = _nextStreamId++,
        _ring = first.ring,
        info = VideoStreamInfo(
          width: first.width,
          height: first.height,
          frameRate: first.duration > Duration.zero
              ? Duration.microsecondsPerSecond / first.duration.inMicroseconds
              : 30,
          duration: Duration.zero,
          codec: 'avfoundation',
          backend: 'AVFoundation / VideoToolbox',
          hardwareAcceleration: true,
        ) {
    _pending = _sample(first);
  }

  static int _nextStreamId = 0x4D414300;
  final _MacVideoBindings _bindings;
  final VideoDecoderOptions _options;
  final Pointer<Void> _asset;
  final NativeVideoFrameRing _ring;
  _ReaderSession _session;
  final int _streamId;
  int _sequence = 0;
  bool _closed = false;
  bool _reading = false;
  VideoSample? _pending;

  @override
  final VideoStreamInfo info;

  @override
  bool get isClosed => _closed;

  VideoSample _sample(_NativeDecodedFrame decoded) {
    decoded.lease.validate();
    _options.validateDecodedFrame(
      width: decoded.width,
      height: decoded.height,
      bytesPerPixel: 4,
    );
    final Duration duration = decoded.duration > Duration.zero
        ? decoded.duration
        : info.nominalFrameDuration;
    return VideoSample(
      frame: VideoFrame(
        format: VideoFrameFormat(
          pixelFormat: VideoPixelFormat.bgra8888,
          width: decoded.width,
          height: decoded.height,
          colorSpace: VideoColorSpace.bt709,
          range: VideoColorRange.full,
        ),
        planes: <VideoPlane>[
          // The plane is the ring slot's cached external view, not a managed
          // allocation made for this frame. It is valid for three acquisitions
          // (the ring depth), until seek, or until decoder close.
          VideoPlane(
            bytes: decoded.lease.bytes,
            bytesPerRow: decoded.width * 4,
            lifetime: decoded.lease,
          ),
        ],
        streamId: _streamId,
        sequence: _sequence++,
      ),
      timestamp: decoded.timestamp,
      duration: duration,
    );
  }

  @override
  Future<VideoSample?> readFrame() async {
    if (_closed) throw StateError('the video decoder is closed');
    if (_reading) throw StateError('readFrame calls must not overlap');
    _reading = true;
    try {
      final VideoSample? pending = _pending;
      if (pending != null) {
        _pending = null;
        return pending;
      }
      return using((NativeArena arena) {
        final _NativeDecodedFrame? decoded = _bindings._readFrame(
          _session,
          arena,
          options: _options,
          ring: _ring,
        );
        return decoded == null ? null : _sample(decoded);
      });
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_closed) throw StateError('the video decoder is closed');
    if (_reading) throw StateError('cannot seek while readFrame is pending');
    final Duration target = position < Duration.zero ? Duration.zero : position;
    using((NativeArena arena) {
      _bindings._closeSession(_session, arena);
      _ring.invalidateAll();
      _session = _bindings._newReader(_asset, arena);
      _pending = null;
      _sequence = 0;
      while (true) {
        final _NativeDecodedFrame? decoded = _bindings._readFrame(
          _session,
          arena,
          options: _options,
          ring: _ring,
        );
        if (decoded == null) break;
        if (decoded.timestamp >= target) {
          _pending = _sample(decoded);
          break;
        }
      }
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    using((NativeArena arena) {
      _bindings._closeSession(_session, arena);
      _bindings._release(_asset, arena);
      // Cancellation precedes the free, so CoreVideo cannot still be writing.
      // Published planes intentionally share this lifetime and must not be
      // retained after the decoder is closed.
      _ring.dispose();
    });
    _pending = null;
  }
}

Duration _duration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return Duration.zero;
  return Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );
}
