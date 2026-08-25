/// Linux native video decoding through GStreamer's stable C ABI.
///
/// The pipeline deliberately ends in an appsink that negotiates BGRA. This
/// keeps GStreamer responsible for container demuxing, codec selection and
/// colour conversion while the portable renderer receives the same packed
/// frame contract as the fallback decoder.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../ffi/native_memory.dart';
import 'video_decoder.dart';
import 'video_frame.dart';
import 'video_frame_ring_buffer.dart';

const int _gstFormatTime = 3;
const int _gstStateNull = 1;
const int _gstStatePaused = 3;
const int _gstStatePlaying = 4;
const int _gstStateChangeFailure = 0;
const int _gstStateChangeSuccess = 1;
const int _gstStateChangeNoPreroll = 3;
const int _gstSeekFlagFlush = 1;
const int _gstSeekFlagKeyUnit = 1 << 2;
const int _nanosecondsPerSecond = 1000000000;

/// Opens [path] with the system GStreamer installation.
///
/// This is intentionally a separate entry point from the cross-platform
/// adapter. The caller can select it first on Linux and retain a process-based
/// decoder as a fallback without making native library discovery fatal.
Future<VideoDecoder> openLinuxNativeVideoDecoder(
  String path,
  VideoDecoderOptions options,
) async {
  if (!Platform.isLinux) {
    throw const VideoDecoderException(
      'native-open',
      'the GStreamer backend is available only on Linux',
    );
  }
  options.validate();
  final File input = File(path);
  if (!await input.exists()) {
    throw VideoDecoderException('native-open', 'file does not exist: $path');
  }
  final _GStreamerApi? api = _GStreamerApi.tryBind();
  if (api == null) {
    throw const VideoDecoderException(
      'native-open',
      'GStreamer 1.0 and the appsink library are not installed',
    );
  }
  try {
    return _GStreamerVideoDecoder.open(
      input.absolute.path,
      options,
      api,
    );
  } on VideoDecoderException {
    rethrow;
  } on Object catch (error) {
    throw VideoDecoderException(
      'native-open',
      'could not create the GStreamer decoding pipeline',
      cause: error,
    );
  }
}

final class _GStreamerVideoDecoder implements VideoDecoder {
  _GStreamerVideoDecoder._(
    this._api,
    this._pipeline,
    this._sink,
    this.info,
    int frameByteCount,
  )   : _frameByteCount = frameByteCount,
        _frameRing = NativeVideoFrameRing(
          slotCount: 3,
          bytesPerSlot: frameByteCount,
        ),
        _streamId = _nextStreamId++;

  static int _nextStreamId = 0x47535400;

  static _GStreamerVideoDecoder open(
    String path,
    VideoDecoderOptions options,
    _GStreamerApi api,
  ) {
    Pointer<_GstElement> pipeline = nullptr;
    Pointer<_GstAppSink> sink = nullptr;
    try {
      final bool initialized = api.initCheck(
            nullptr.cast<Int32>(),
            nullptr.cast<Pointer<Pointer<Uint8>>>(),
            nullptr.cast<Pointer<_GError>>(),
          ) !=
          0;
      if (!initialized) {
        throw const VideoDecoderException(
          'native-open',
          'gst_init_check rejected the current process environment',
        );
      }

      pipeline = using((NativeArena arena) {
        final String description =
            'filesrc location="${_quoteLaunchValue(path)}" ! '
            'decodebin ! videoconvert ! video/x-raw,format=BGRA ! '
            'appsink name=dart_ui_sink sync=false max-buffers=2 drop=false';
        return api.parseLaunch(
          arena.allocateUtf8(description),
          nullptr.cast<Pointer<_GError>>(),
        );
      }).cast<_GstElement>();
      if (pipeline == nullptr) {
        throw const VideoDecoderException(
          'native-open',
          'gst_parse_launch could not construct the decoding pipeline',
        );
      }

      sink = using((NativeArena arena) {
        return api.binGetByName(
          pipeline.cast<_GstBin>(),
          arena.allocateAscii('dart_ui_sink'),
        );
      }).cast<_GstAppSink>();
      if (sink == nullptr) {
        throw const VideoDecoderException(
          'native-open',
          'the GStreamer pipeline did not expose its appsink',
        );
      }

      _changeStateAndWait(api, pipeline, _gstStatePaused);
      final Pointer<_GstSample> preroll = api.appSinkPullPreroll(sink);
      if (preroll == nullptr) {
        throw const VideoDecoderException(
          'native-open',
          'GStreamer produced no video preroll sample',
        );
      }

      late final int width;
      late final int height;
      var frameRate = 30.0;
      try {
        final Pointer<_GstCaps> caps = api.sampleGetCaps(preroll);
        if (caps == nullptr || api.capsGetSize(caps) == 0) {
          throw const VideoDecoderException(
            'native-open',
            'the GStreamer preroll sample has no negotiated video caps',
          );
        }
        final Pointer<_GstStructure> structure = api.capsGetStructure(caps, 0);
        using((NativeArena arena) {
          final Pointer<Int32> widthOut = arena<Int32>();
          final Pointer<Int32> heightOut = arena<Int32>();
          final Pointer<Int32> numeratorOut = arena<Int32>();
          final Pointer<Int32> denominatorOut = arena<Int32>();
          if (api.structureGetInt(
                    structure,
                    arena.allocateAscii('width'),
                    widthOut,
                  ) ==
                  0 ||
              api.structureGetInt(
                    structure,
                    arena.allocateAscii('height'),
                    heightOut,
                  ) ==
                  0) {
            throw const VideoDecoderException(
              'native-open',
              'negotiated GStreamer caps do not contain a frame size',
            );
          }
          width = widthOut.value;
          height = heightOut.value;
          if (api.structureGetFraction(
                    structure,
                    arena.allocateAscii('framerate'),
                    numeratorOut,
                    denominatorOut,
                  ) !=
                  0 &&
              numeratorOut.value > 0 &&
              denominatorOut.value > 0) {
            frameRate = numeratorOut.value / denominatorOut.value;
          }
        });
      } finally {
        api.miniObjectUnref(preroll.cast<_GstMiniObject>());
      }

      final int frameByteCount = options.validateDecodedFrame(
        width: width,
        height: height,
        bytesPerPixel: 4,
      );
      final Duration duration = using((NativeArena arena) {
        final Pointer<Int64> value = arena<Int64>();
        if (api.elementQueryDuration(pipeline, _gstFormatTime, value) == 0 ||
            value.value <= 0) {
          return Duration.zero;
        }
        return Duration(microseconds: value.value ~/ 1000);
      });
      _changeStateAndWait(api, pipeline, _gstStatePlaying);
      return _GStreamerVideoDecoder._(
        api,
        pipeline,
        sink,
        VideoStreamInfo(
          width: width,
          height: height,
          frameRate: frameRate,
          duration: duration,
          codec: 'system-decoder',
          backend: options.acceleration == VideoDecoderAcceleration.software
              ? 'GStreamer 1.0 (native Linux, software preferred)'
              : 'GStreamer 1.0 (native Linux)',
          // decodebin may choose VA-API/V4L2 when present, but GStreamer's
          // public caps do not prove which decoder was selected. Likewise,
          // `software` is a preference here: plugin ranks are controlled by
          // the system and there is no codec-independent decodebin switch that
          // can exclude every hardware plugin safely.
          hardwareAcceleration: false,
        ),
        frameByteCount,
      );
    } catch (_) {
      if (pipeline != nullptr) {
        api.elementSetState(pipeline, _gstStateNull);
      }
      if (sink != nullptr) api.objectUnref(sink.cast<Void>());
      if (pipeline != nullptr) api.objectUnref(pipeline.cast<Void>());
      rethrow;
    }
  }

  final _GStreamerApi _api;
  final Pointer<_GstElement> _pipeline;
  final Pointer<_GstAppSink> _sink;
  final int _frameByteCount;
  final int _streamId;
  int _sequence = 0;
  Duration _origin = Duration.zero;
  bool _closed = false;
  bool _reading = false;
  final NativeVideoFrameRing _frameRing;

  @override
  final VideoStreamInfo info;

  @override
  bool get isClosed => _closed;

  @override
  Future<VideoSample?> readFrame() async {
    if (_closed) throw StateError('the video decoder is closed');
    if (_reading) throw StateError('readFrame calls must not overlap');
    _reading = true;
    try {
      final Pointer<_GstSample> sample = _api.appSinkPullSample(_sink);
      if (sample == nullptr) return null;
      try {
        final Pointer<_GstBuffer> buffer = _api.sampleGetBuffer(sample);
        if (buffer == nullptr) {
          throw const VideoDecoderException(
            'decode',
            'GStreamer returned a sample without a buffer',
          );
        }
        final int available = _api.bufferGetSize(buffer);
        if (available < _frameByteCount) {
          throw VideoDecoderException(
            'decode',
            'truncated GStreamer frame: got $available of '
                '$_frameByteCount bytes',
          );
        }
        final NativeVideoFrameLease lease = _frameRing.acquire();
        final int copied = _api.bufferExtract(
          buffer,
          0,
          lease.pointer.cast<Void>(),
          _frameByteCount,
        );
        if (copied != _frameByteCount) {
          throw VideoDecoderException(
            'decode',
            'GStreamer copied $copied of $_frameByteCount frame bytes',
          );
        }
        final Uint8List bytes = lease.bytes;
        final Duration frameDuration = info.nominalFrameDuration;
        final Duration timestamp = _origin + frameDuration * _sequence;
        final frame = VideoFrame(
          format: VideoFrameFormat(
            pixelFormat: VideoPixelFormat.bgra8888,
            width: info.width,
            height: info.height,
            colorSpace: VideoColorSpace.bt709,
            range: VideoColorRange.full,
          ),
          planes: <VideoPlane>[
            VideoPlane(
              bytes: bytes,
              bytesPerRow: info.width * 4,
              lifetime: lease,
            ),
          ],
          streamId: _streamId,
          sequence: _sequence++,
        );
        return VideoSample(
          frame: frame,
          timestamp: timestamp,
          duration: frameDuration,
        );
      } finally {
        _api.miniObjectUnref(sample.cast<_GstMiniObject>());
      }
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_closed) throw StateError('the video decoder is closed');
    if (_reading) throw StateError('cannot seek while readFrame is pending');
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (info.duration > Duration.zero && target > info.duration) {
      target = info.duration;
    }
    final int nanoseconds = target.inMicroseconds * 1000;
    if (_api.elementSeekSimple(
          _pipeline,
          _gstFormatTime,
          _gstSeekFlagFlush | _gstSeekFlagKeyUnit,
          nanoseconds,
        ) ==
        0) {
      throw VideoDecoderException(
        'seek',
        'GStreamer rejected seek to ${target.inMicroseconds} microseconds',
      );
    }
    _origin = target;
    _sequence = 0;
    _frameRing.invalidateAll();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_reading) throw StateError('cannot close while readFrame is pending');
    _closed = true;
    _api.elementSetState(_pipeline, _gstStateNull);
    _api.objectUnref(_sink.cast<Void>());
    _api.objectUnref(_pipeline.cast<Void>());
    _frameRing.dispose();
  }
}

void _changeStateAndWait(
  _GStreamerApi api,
  Pointer<_GstElement> pipeline,
  int state,
) {
  if (api.elementSetState(pipeline, state) == _gstStateChangeFailure) {
    throw VideoDecoderException(
      'native-open',
      'GStreamer rejected state transition to $state',
    );
  }
  final int result = api.elementGetState(
    pipeline,
    nullptr.cast<Int32>(),
    nullptr.cast<Int32>(),
    10 * _nanosecondsPerSecond,
  );
  if (result != _gstStateChangeSuccess && result != _gstStateChangeNoPreroll) {
    throw VideoDecoderException(
      'native-open',
      'GStreamer did not complete state transition to $state',
    );
  }
}

String _quoteLaunchValue(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

final class _GStreamerApi {
  _GStreamerApi._(
    this.initCheck,
    this.parseLaunch,
    this.binGetByName,
    this.elementSetState,
    this.elementGetState,
    this.elementQueryDuration,
    this.elementSeekSimple,
    this.appSinkPullPreroll,
    this.appSinkPullSample,
    this.sampleGetBuffer,
    this.sampleGetCaps,
    this.capsGetSize,
    this.capsGetStructure,
    this.structureGetInt,
    this.structureGetFraction,
    this.bufferGetSize,
    this.bufferExtract,
    this.miniObjectUnref,
    this.objectUnref,
  );

  static _GStreamerApi? _instance;
  static bool _attempted = false;

  static _GStreamerApi? tryBind() {
    if (_attempted) return _instance;
    _attempted = true;
    if (!Platform.isLinux || !NativeAllocator.isAvailable) return null;
    try {
      final DynamicLibrary core = DynamicLibrary.open('libgstreamer-1.0.so.0');
      final DynamicLibrary app = DynamicLibrary.open('libgstapp-1.0.so.0');
      final DynamicLibrary object = DynamicLibrary.open('libgobject-2.0.so.0');
      return _instance = _GStreamerApi._(
        core.lookupFunction<
            Int32 Function(Pointer<Int32>, Pointer<Pointer<Pointer<Uint8>>>,
                Pointer<Pointer<_GError>>),
            int Function(Pointer<Int32>, Pointer<Pointer<Pointer<Uint8>>>,
                Pointer<Pointer<_GError>>)>('gst_init_check'),
        core.lookupFunction<
            Pointer<_GstElement> Function(
                Pointer<Uint8>, Pointer<Pointer<_GError>>),
            Pointer<_GstElement> Function(
                Pointer<Uint8>, Pointer<Pointer<_GError>>)>('gst_parse_launch'),
        core.lookupFunction<
            Pointer<_GstElement> Function(Pointer<_GstBin>, Pointer<Uint8>),
            Pointer<_GstElement> Function(
                Pointer<_GstBin>, Pointer<Uint8>)>('gst_bin_get_by_name'),
        core.lookupFunction<Int32 Function(Pointer<_GstElement>, Int32),
            int Function(Pointer<_GstElement>, int)>('gst_element_set_state'),
        core.lookupFunction<
            Int32 Function(
                Pointer<_GstElement>, Pointer<Int32>, Pointer<Int32>, Uint64),
            int Function(Pointer<_GstElement>, Pointer<Int32>, Pointer<Int32>,
                int)>('gst_element_get_state'),
        core.lookupFunction<
            Int32 Function(Pointer<_GstElement>, Int32, Pointer<Int64>),
            int Function(Pointer<_GstElement>, int,
                Pointer<Int64>)>('gst_element_query_duration'),
        core.lookupFunction<
            Int32 Function(Pointer<_GstElement>, Int32, Int32, Int64),
            int Function(Pointer<_GstElement>, int, int,
                int)>('gst_element_seek_simple'),
        app.lookupFunction<
            Pointer<_GstSample> Function(Pointer<_GstAppSink>),
            Pointer<_GstSample> Function(
                Pointer<_GstAppSink>)>('gst_app_sink_pull_preroll'),
        app.lookupFunction<
            Pointer<_GstSample> Function(Pointer<_GstAppSink>),
            Pointer<_GstSample> Function(
                Pointer<_GstAppSink>)>('gst_app_sink_pull_sample'),
        core.lookupFunction<
            Pointer<_GstBuffer> Function(Pointer<_GstSample>),
            Pointer<_GstBuffer> Function(
                Pointer<_GstSample>)>('gst_sample_get_buffer'),
        core.lookupFunction<
            Pointer<_GstCaps> Function(Pointer<_GstSample>),
            Pointer<_GstCaps> Function(
                Pointer<_GstSample>)>('gst_sample_get_caps'),
        core.lookupFunction<Uint32 Function(Pointer<_GstCaps>),
            int Function(Pointer<_GstCaps>)>('gst_caps_get_size'),
        core.lookupFunction<
            Pointer<_GstStructure> Function(Pointer<_GstCaps>, Uint32),
            Pointer<_GstStructure> Function(
                Pointer<_GstCaps>, int)>('gst_caps_get_structure'),
        core.lookupFunction<
            Int32 Function(
                Pointer<_GstStructure>, Pointer<Uint8>, Pointer<Int32>),
            int Function(Pointer<_GstStructure>, Pointer<Uint8>,
                Pointer<Int32>)>('gst_structure_get_int'),
        core.lookupFunction<
            Int32 Function(Pointer<_GstStructure>, Pointer<Uint8>,
                Pointer<Int32>, Pointer<Int32>),
            int Function(Pointer<_GstStructure>, Pointer<Uint8>, Pointer<Int32>,
                Pointer<Int32>)>('gst_structure_get_fraction'),
        core.lookupFunction<UintPtr Function(Pointer<_GstBuffer>),
            int Function(Pointer<_GstBuffer>)>('gst_buffer_get_size'),
        core.lookupFunction<
            UintPtr Function(
                Pointer<_GstBuffer>, UintPtr, Pointer<Void>, UintPtr),
            int Function(Pointer<_GstBuffer>, int, Pointer<Void>,
                int)>('gst_buffer_extract'),
        core.lookupFunction<Void Function(Pointer<_GstMiniObject>),
            void Function(Pointer<_GstMiniObject>)>('gst_mini_object_unref'),
        object.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('g_object_unref'),
      );
    } on Object {
      return null;
    }
  }

  final int Function(Pointer<Int32>, Pointer<Pointer<Pointer<Uint8>>>,
      Pointer<Pointer<_GError>>) initCheck;
  final Pointer<_GstElement> Function(Pointer<Uint8>, Pointer<Pointer<_GError>>)
      parseLaunch;
  final Pointer<_GstElement> Function(Pointer<_GstBin>, Pointer<Uint8>)
      binGetByName;
  final int Function(Pointer<_GstElement>, int) elementSetState;
  final int Function(Pointer<_GstElement>, Pointer<Int32>, Pointer<Int32>, int)
      elementGetState;
  final int Function(Pointer<_GstElement>, int, Pointer<Int64>)
      elementQueryDuration;
  final int Function(Pointer<_GstElement>, int, int, int) elementSeekSimple;
  final Pointer<_GstSample> Function(Pointer<_GstAppSink>) appSinkPullPreroll;
  final Pointer<_GstSample> Function(Pointer<_GstAppSink>) appSinkPullSample;
  final Pointer<_GstBuffer> Function(Pointer<_GstSample>) sampleGetBuffer;
  final Pointer<_GstCaps> Function(Pointer<_GstSample>) sampleGetCaps;
  final int Function(Pointer<_GstCaps>) capsGetSize;
  final Pointer<_GstStructure> Function(Pointer<_GstCaps>, int)
      capsGetStructure;
  final int Function(Pointer<_GstStructure>, Pointer<Uint8>, Pointer<Int32>)
      structureGetInt;
  final int Function(Pointer<_GstStructure>, Pointer<Uint8>, Pointer<Int32>,
      Pointer<Int32>) structureGetFraction;
  final int Function(Pointer<_GstBuffer>) bufferGetSize;
  final int Function(Pointer<_GstBuffer>, int, Pointer<Void>, int)
      bufferExtract;
  final void Function(Pointer<_GstMiniObject>) miniObjectUnref;
  final void Function(Pointer<Void>) objectUnref;
}

final class _GstElement extends Opaque {}

final class _GstBin extends Opaque {}

final class _GstAppSink extends Opaque {}

final class _GstSample extends Opaque {}

final class _GstBuffer extends Opaque {}

final class _GstCaps extends Opaque {}

final class _GstStructure extends Opaque {}

final class _GstMiniObject extends Opaque {}

final class _GError extends Opaque {}
