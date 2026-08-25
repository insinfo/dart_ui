/// Windows video decoding through Media Foundation's synchronous Source Reader.
///
/// This is deliberately independent from the FFmpeg adapter. The platform
/// dispatcher can try this entry point first and treat a `native-open` failure
/// as the signal to use its final fallback.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import 'video_decoder.dart';
import 'video_frame.dart';
import 'video_frame_ring_buffer.dart';

const int _mfVersion = 0x00020070;
const int _mfStartupFull = 0;
const int _coinitMultithreaded = 0;
const int _rpcEChangedMode = -2147417850; // 0x80010106

const int _firstVideoStream = 0xfffffffc;
const int _allStreams = 0xfffffffe;
const int _mediaSource = 0xffffffff;
const int _endOfStream = 0x00000002;
const int _streamTick = 0x00000100;
const int _vtI8 = 20;
const int _vtUi8 = 21;

/// How far down a stream's transform chain [_MfSourceReader.decodePath] looks
/// for the decoder. Three would do; eight costs nothing and is only reached
/// on a chain that has no decoder in it at all.
const int _maxProbedTransforms = 8;

/// Slots in the decoder's frame ring.
///
/// Each slot is a whole uncompressed frame - 7.9 MiB at 1080p BGRA - so this
/// is the largest number in the decoder that is ours to choose, and it was
/// measured: every slot costs exactly 7.91 MiB of resident memory at open.
///
/// Three is the ring's documented design point, not a guess. Two is the
/// strict minimum, because a caller displays one frame while the next is
/// being decoded into another slot; three leaves one further acquisition of
/// slack, so a frame that is still being painted or uploaded when the decoder
/// has already moved on is still valid. A caller that wants to read further
/// ahead than that has to say so by copying, which is the contract
/// [NativeVideoFrameRing] states.
const int _ringSlotCount = 3;

final Guid _guidNull = Guid.parse('00000000-0000-0000-0000-000000000000');
final Guid _mfMtMajorType = Guid.parse('48EBA18E-F8C9-4687-BF11-0A74C9F96A8F');
final Guid _mfMediaTypeVideo =
    Guid.parse('73646976-0000-0010-8000-00AA00389B71');
final Guid _mfMtSubtype = Guid.parse('F7E34C9A-42E8-4714-B74B-CB29D72C35E5');
final Guid _mfVideoFormatRgb32 =
    Guid.parse('00000016-0000-0010-8000-00AA00389B71');
final Guid _mfMtFrameSize = Guid.parse('1652C33D-D6B2-4012-B834-72030849A37D');
final Guid _mfMtFrameRate = Guid.parse('C459A2E8-3D2C-4E44-B132-FEE5156C7BB0');
final Guid _mfPdDuration = Guid.parse('6C990D33-BB8E-477A-8598-0D5D96FCD88A');
final Guid _mfSourceReaderEnableVideoProcessing =
    Guid.parse('FB394F3D-CCF1-42EE-BBB3-F9B845D5681D');
final Guid _iidMfMediaSource =
    Guid.parse('279A808D-AEC7-40C8-9C6B-A6B492C78A66');

// The accelerated half of the Source Reader configuration. Setting the D3D
// manager is what lets the pipeline pick a DXVA-capable decoder MFT; the other
// three tell the reader it may keep hardware transforms in the chain and
// convert to RGB32 inside it.
final Guid _mfSourceReaderD3dManager =
    Guid.parse('EC822DA2-E1E9-4B29-A0D8-563C719F5269');
final Guid _mfSourceReaderEnableAdvancedVideoProcessing =
    Guid.parse('0F81DA2C-B537-4672-A8B2-A681B17307A3');
final Guid _mfSourceReaderDisableDxva =
    Guid.parse('AA456CFD-3943-4A1E-A77D-1838C0EA2E35');
final Guid _mfReadWriteEnableHardwareTransforms =
    Guid.parse('A634A91C-822B-41B9-A494-4DE4643612B0');
final Guid _iidD3d10Multithread =
    Guid.parse('9B7E4E00-342C-4106-A19F-4F2704F689F0');
final Guid _iidMfSourceReaderEx =
    Guid.parse('7B981CF0-560E-4116-9875-B099895F23D7');
final Guid _iidMf2DBuffer = Guid.parse('7DC9D5F9-9ED9-44EC-9BBF-0600BB589FBB');

/// `MF_SA_D3D11_AWARE`: the decoder MFT accepts a DXGI device manager and
/// decodes into video memory. Both a full hardware MFT and Microsoft's own
/// H.264 decoder running over DXVA 2.0 report it.
final Guid _mfSaD3d11Aware = Guid.parse('206B4FC8-FCF9-4C51-AFE3-9764369E33A0');

/// `MFT_ENUM_HARDWARE_URL_Attribute`: only a genuine hardware MFT carries it.
final Guid _mftEnumHardwareUrl =
    Guid.parse('2FB866AC-B078-4942-AB6C-003D05CDA674');

/// `MFT_CATEGORY_VIDEO_DECODER`. The chain the Source Reader builds also
/// holds converters, and a converter is D3D11-aware whether or not anything
/// was decoded on the GPU.
final Guid _mftCategoryVideoDecoder =
    Guid.parse('D6C02D4B-6833-45B4-971A-05A4B04BAB91');

// Enough of Direct3D 11 to own a video-capable device. Deliberately declared
// here rather than imported from the renderer's D3D11 backend: this decoder
// must keep working when no renderer has been created, and a device with
// D3D11_CREATE_DEVICE_VIDEO_SUPPORT plus multithread protection is not the
// device the renderer wants.
const int _d3d11SdkVersion = 7;
const int _d3dDriverTypeHardware = 1;
const int _d3d11CreateDeviceBgraSupport = 0x20;
const int _d3d11CreateDeviceVideoSupport = 0x800;
const List<int> _d3dFeatureLevels = <int>[0xb100, 0xb000, 0xa100, 0xa000];

/// Test seam that makes the accelerated path fail at a chosen point.
///
/// A machine with a working Quick Sync decoder never takes the software
/// branch on its own, so the fallback would otherwise be untested exactly
/// where it matters. Never set this outside a test.
enum MediaFoundationHardwareFault {
  /// Normal operation.
  none,

  /// `D3D11CreateDevice` or `MFCreateDXGIDeviceManager` refuses.
  deviceManager,

  /// The Source Reader refuses the accelerated attribute store.
  sourceReader,
}

/// See [MediaFoundationHardwareFault]. Reset it in a test's teardown.
MediaFoundationHardwareFault debugMediaFoundationHardwareFault =
    MediaFoundationHardwareFault.none;

/// What the Source Reader actually ended up doing, as opposed to what it was
/// asked for. [VideoStreamInfo.hardwareAcceleration] is read off this.
enum _MfDecodePath {
  /// No D3D manager was attached: the plain software Source Reader.
  software('software decode'),

  /// A manager was attached but the decoder MFT is not D3D11-aware, so the
  /// frames are still produced on the CPU.
  softwareMft('software decode (D3D11 manager attached)'),

  /// Microsoft's decoder MFT running over DXVA on the attached device.
  dxva('D3D11 DXVA decode'),

  /// A vendor hardware MFT, which is Quick Sync on Intel parts.
  hardwareMft('D3D11 hardware MFT decode'),

  /// The stream carries no compressed video at all, so the chain holds only
  /// converters and there is nothing for a decoder to accelerate.
  noDecoder('uncompressed stream, no decoder'),

  /// A manager was attached and the reader would not say which MFT it chose.
  /// Only reachable on a system without `IMFSourceReaderEx`.
  unverified('D3D11 manager attached, decoder unverified');

  const _MfDecodePath(this.label);

  final String label;

  bool get isAccelerated => switch (this) {
        _MfDecodePath.dxva ||
        _MfDecodePath.hardwareMft ||
        _MfDecodePath.unverified =>
          true,
        _MfDecodePath.software ||
        _MfDecodePath.softwareMft ||
        _MfDecodePath.noDecoder =>
          false,
      };
}

typedef _MfStartupNative = Int32 Function(Uint32, Uint32);
typedef _MfShutdownNative = Int32 Function();
typedef _MfCreateAttributesNative = Int32 Function(
  Pointer<Pointer<Void>>,
  Uint32,
);
typedef _MfCreateMediaTypeNative = Int32 Function(Pointer<Pointer<Void>>);
typedef _MfCreateSourceReaderFromUrlNative = Int32 Function(
  Pointer<Uint16>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _MfCreateDxgiDeviceManagerNative = Int32 Function(
  Pointer<Uint32>,
  Pointer<Pointer<Void>>,
);
typedef _D3d11CreateDeviceNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Uint32,
  Uint32,
  Pointer<Pointer<Void>>,
  Pointer<Uint32>,
  Pointer<Pointer<Void>>,
);
typedef _CoInitializeExNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CoUninitializeNative = Void Function();
typedef _PropVariantClearNative = Int32 Function(Pointer<_PropVariant>);

/// Opens [path] with the Windows Media Foundation Source Reader.
///
/// No FFmpeg discovery happens here. Failure to initialise or negotiate the
/// native decoder is reported as `native-open`, which is the only failure a
/// caller should interpret as permission to try a separate backend.
Future<VideoDecoder> openWindowsNativeVideoDecoder(
  String path,
  VideoDecoderOptions options,
) async {
  if (!Platform.isWindows) {
    throw const VideoDecoderException(
      'native-open',
      'Media Foundation is only available on Windows',
    );
  }
  options.validate();
  final File input = File(path);
  if (!await input.exists()) {
    throw VideoDecoderException('native-open', 'file does not exist: $path');
  }
  try {
    return _MediaFoundationVideoDecoder.open(input.absolute.path, options);
  } on VideoDecoderException {
    rethrow;
  } on Object catch (error) {
    throw VideoDecoderException(
      'native-open',
      'Media Foundation could not open $path',
      cause: error,
    );
  }
}

final class _MediaFoundationVideoDecoder implements VideoDecoder {
  _MediaFoundationVideoDecoder._({
    required this.info,
    required _MfApi api,
    required _MfSourceReader reader,
    required _MfHardwareContext? hardware,
    required int frameByteCount,
    required bool ownsApartment,
  })  : _api = api,
        _reader = reader,
        _hardware = hardware,
        _frameByteCount = frameByteCount,
        _frameRing = NativeVideoFrameRing(
          slotCount: _ringSlotCount,
          bytesPerSlot: frameByteCount,
        ),
        _ownsApartment = ownsApartment,
        _streamId = _nextStreamId++;

  static int _nextStreamId = 1;

  /// Opens [path], hardware first and software second.
  ///
  /// The two attempts share one `CoInitializeEx`/`MFStartup` pair, so a
  /// machine whose DXVA decoder refuses this file pays for a second Source
  /// Reader negotiation and nothing else. Media Foundation itself is torn
  /// down only when both attempts fail.
  static _MediaFoundationVideoDecoder open(
    String path,
    VideoDecoderOptions options,
  ) {
    final _MfApi api = _MfApi.load();
    var ownsApartment = false;
    var started = false;
    _MfHardwareContext? hardware;
    try {
      final int apartment = hresult(api.coInitializeEx(
        nullptr,
        _coinitMultithreaded,
      ));
      if (apartment == sOk || apartment == sFalse) {
        ownsApartment = true;
      } else if (apartment != _rpcEChangedMode) {
        checkHresult(apartment, 'CoInitializeEx(COINIT_MULTITHREADED)');
      }

      checkHresult(api.startup(_mfVersion, _mfStartupFull), 'MFStartup');
      started = true;

      if (options.acceleration == VideoDecoderAcceleration.automatic) {
        hardware = _MfHardwareContext.tryCreate(api);
      }
      final _MfHardwareContext? accelerated = hardware;
      if (accelerated != null) {
        try {
          final _MediaFoundationVideoDecoder decoder = _negotiate(
            api: api,
            path: path,
            options: options,
            hardware: accelerated,
            ownsApartment: ownsApartment,
          );
          started = false;
          ownsApartment = false;
          hardware = null;
          return decoder;
        } on Object {
          // A codec the fixed-function decoder does not implement, a driver
          // that refuses the surface format, a device lost between creation
          // and negotiation: all of them mean software, none of them mean
          // the file cannot be played.
          accelerated.dispose();
          hardware = null;
        }
      }

      final _MediaFoundationVideoDecoder decoder = _negotiate(
        api: api,
        path: path,
        options: options,
        hardware: null,
        ownsApartment: ownsApartment,
      );
      started = false;
      ownsApartment = false;
      return decoder;
    } on Object catch (error) {
      throw VideoDecoderException(
        'native-open',
        'Media Foundation Source Reader negotiation failed',
        cause: error,
      );
    } finally {
      hardware?.dispose();
      if (started) api.shutdown();
      if (ownsApartment) api.coUninitialize();
    }
  }

  /// Builds one Source Reader and negotiates BGRA output on it.
  ///
  /// [hardware] decides which attribute store the reader is created with and
  /// nothing else: the media-type negotiation, the frame geometry and the
  /// output contract are identical on both paths, which is what makes the
  /// fallback safe to take at any point before this returns.
  static _MediaFoundationVideoDecoder _negotiate({
    required _MfApi api,
    required String path,
    required VideoDecoderOptions options,
    required _MfHardwareContext? hardware,
    required bool ownsApartment,
  }) {
    final NativeArena arena = NativeArena();
    _MfSourceReader? reader;
    _MfAttributes? readerAttributes;
    _MfAttributes? requestedType;
    _MfAttributes? nativeType;
    _MfAttributes? currentType;
    try {
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      checkHresult(api.createAttributes(out, 4), 'MFCreateAttributes');
      readerAttributes = _MfAttributes(out.value, 'IMFAttributes');
      if (hardware == null) {
        readerAttributes.setUint32(
          _mfSourceReaderEnableVideoProcessing,
          1,
          arena,
        );
      } else {
        if (debugMediaFoundationHardwareFault ==
            MediaFoundationHardwareFault.sourceReader) {
          throw const VideoDecoderException(
            'native-open',
            'injected Source Reader hardware fault',
          );
        }
        // MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING and its ADVANCED sibling
        // are mutually exclusive, and only the advanced one keeps the
        // conversion to RGB32 inside a D3D11 pipeline. Setting both makes
        // MFCreateSourceReaderFromURL fail outright.
        readerAttributes
          ..setUnknown(
            _mfSourceReaderD3dManager,
            hardware.manager.pointer,
            arena,
          )
          ..setUint32(_mfSourceReaderEnableAdvancedVideoProcessing, 1, arena)
          ..setUint32(_mfReadWriteEnableHardwareTransforms, 1, arena)
          ..setUint32(_mfSourceReaderDisableDxva, 0, arena);
      }

      out.value = nullptr;
      checkHresult(
        api.createSourceReaderFromUrl(
          arena.allocateUtf16(path),
          readerAttributes.pointer,
          out,
        ),
        'MFCreateSourceReaderFromURL',
        detail: path,
      );
      reader = _MfSourceReader(out.value);
      checkHresult(
        reader.setStreamSelection(_allStreams, false),
        'IMFSourceReader::SetStreamSelection(all, false)',
      );
      checkHresult(
        reader.setStreamSelection(_firstVideoStream, true),
        'IMFSourceReader::SetStreamSelection(video, true)',
      );

      out.value = nullptr;
      checkHresult(
        reader.getNativeMediaType(_firstVideoStream, 0, out),
        'IMFSourceReader::GetNativeMediaType',
      );
      nativeType = _MfAttributes(out.value, 'IMFMediaType(native)');
      final String codec = nativeType.codecName(_mfMtSubtype, arena);

      out.value = nullptr;
      checkHresult(api.createMediaType(out), 'MFCreateMediaType');
      requestedType = _MfAttributes(out.value, 'IMFMediaType(requested)');
      requestedType
        ..setGuid(_mfMtMajorType, _mfMediaTypeVideo, arena)
        ..setGuid(_mfMtSubtype, _mfVideoFormatRgb32, arena);
      checkHresult(
        reader.setCurrentMediaType(_firstVideoStream, requestedType.pointer),
        'IMFSourceReader::SetCurrentMediaType(RGB32)',
      );

      out.value = nullptr;
      checkHresult(
        reader.getCurrentMediaType(_firstVideoStream, out),
        'IMFSourceReader::GetCurrentMediaType',
      );
      currentType = _MfAttributes(out.value, 'IMFMediaType(current)');
      final int packedSize = currentType.getUint64(_mfMtFrameSize, arena);
      final int width = (packedSize >> 32) & 0xffffffff;
      final int height = packedSize & 0xffffffff;
      final int frameBytes = options.validateDecodedFrame(
        width: width,
        height: height,
        bytesPerPixel: 4,
      );
      double frameRate = 30;
      final int? packedRate = currentType.tryGetUint64(_mfMtFrameRate, arena);
      if (packedRate != null) {
        final int numerator = (packedRate >> 32) & 0xffffffff;
        final int denominator = packedRate & 0xffffffff;
        if (numerator > 0 && denominator > 0) {
          frameRate = numerator / denominator;
        }
      }
      final Duration duration = reader.presentationDuration(api, arena);
      final _MfDecodePath decodePath =
          hardware == null ? _MfDecodePath.software : reader.decodePath(arena);

      final decoder = _MediaFoundationVideoDecoder._(
        info: VideoStreamInfo(
          width: width,
          height: height,
          frameRate: frameRate,
          duration: duration,
          codec: codec,
          backend: 'Windows Media Foundation (native FFI, ${decodePath.label})',
          hardwareAcceleration: decodePath.isAccelerated,
        ),
        api: api,
        reader: reader,
        hardware: hardware,
        frameByteCount: frameBytes,
        ownsApartment: ownsApartment,
      );
      reader = null;
      return decoder;
    } finally {
      currentType?.dispose();
      nativeType?.dispose();
      requestedType?.dispose();
      readerAttributes?.dispose();
      reader?.dispose();
      arena.dispose();
    }
  }

  final _MfApi _api;
  final _MfSourceReader _reader;
  final _MfHardwareContext? _hardware;
  final int _frameByteCount;
  final NativeVideoFrameRing _frameRing;
  final bool _ownsApartment;
  final int _streamId;

  /// Scratch slots and vtable bindings for the read loop, made once.
  final _ReadPath _readPath = _ReadPath();

  /// Every frame this decoder emits has the same geometry and colorimetry, so
  /// the descriptor is built once instead of per frame.
  late final VideoFrameFormat _frameFormat = VideoFrameFormat(
    pixelFormat: VideoPixelFormat.bgra8888,
    width: info.width,
    height: info.height,
    colorSpace: VideoColorSpace.bt709,
    range: VideoColorRange.full,
  );
  Future<void> _tail = Future<void>.value();
  bool _closeRequested = false;
  bool _closed = false;
  bool _eos = false;
  int _sequence = 0;
  Duration? _seekTarget;

  @override
  final VideoStreamInfo info;

  @override
  bool get isClosed => _closeRequested || _closed;

  Future<T> _serialize<T>(FutureOr<T> Function() action) {
    final Completer<T> result = Completer<T>();
    _tail = _tail.then<void>((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  @override
  Future<VideoSample?> readFrame() {
    if (_closeRequested) {
      return Future<VideoSample?>.error(
        StateError('the video decoder is closed'),
      );
    }
    return _serialize<VideoSample?>(() {
      if (_closed) throw StateError('the video decoder is closed');
      if (_eos) return null;
      final _ReadPath path = _readPath;
      final Pointer<Uint32> flags = path.flags;
      final Pointer<Int64> timestamp = path.timestamp;
      final Pointer<Pointer<Void>> sampleOut = path.sampleOut;
      try {
        while (true) {
          flags.value = 0;
          sampleOut.value = nullptr;
          checkHresult(
            _reader.readSample(
              _firstVideoStream,
              path.actualStream,
              flags,
              timestamp,
              sampleOut,
            ),
            'IMFSourceReader::ReadSample',
          );
          if (sampleOut.value != nullptr) {
            final Pointer<Void> sample = sampleOut.value;
            try {
              final int timestamp100ns = timestamp.value;
              final Duration? seekTarget = _seekTarget;
              if (seekTarget != null &&
                  timestamp100ns ~/ 10 < seekTarget.inMicroseconds) {
                continue;
              }
              _seekTarget = null;
              final NativeVideoFrameLease lease = _frameRing.acquire();
              final Uint8List bytes =
                  path.copyContiguousBytes(sample, _frameByteCount, lease);
              // MFVideoFormat_RGB32 is BGRX. dart_ui's BGRA contract requires
              // a defined opaque alpha rather than propagating the spare byte.
              //
              // A byte at a time, and measured that way round: rewriting this
              // as `words[i] |= 0xff000000` over a 32-bit view looks like four
              // times less work but is 1.33x *slower* on a 1080p frame (1.161
              // ms against 0.872 ms), because it turns a pure store into a
              // read-modify-write over the same 8.3 MB.
              for (var i = 3; i < bytes.length; i += 4) {
                bytes[i] = 0xff;
              }
              final int sampleDuration100ns = path.sampleDuration(sample);
              return VideoSample(
                frame: VideoFrame(
                  format: _frameFormat,
                  planes: <VideoPlane>[
                    VideoPlane(
                      bytes: lease.bytes,
                      bytesPerRow: info.width * 4,
                      lifetime: lease,
                    ),
                  ],
                  streamId: _streamId,
                  sequence: _sequence++,
                ),
                timestamp: Duration(microseconds: timestamp100ns ~/ 10),
                duration: sampleDuration100ns > 0
                    ? Duration(microseconds: sampleDuration100ns ~/ 10)
                    : info.nominalFrameDuration,
              );
            } finally {
              path.releaseSample(sample);
            }
          }
          if ((flags.value & _endOfStream) != 0) {
            _eos = true;
            return null;
          }
          if ((flags.value & _streamTick) == 0) {
            throw const VideoDecoderException(
              'decode',
              'Media Foundation returned neither a sample nor stream status',
            );
          }
        }
      } on VideoDecoderException {
        rethrow;
      } on Object catch (error) {
        throw VideoDecoderException(
          'decode',
          'Media Foundation could not decode the next frame',
          cause: error,
        );
      }
    });
  }

  @override
  Future<void> seek(Duration position) {
    if (_closeRequested) {
      return Future<void>.error(StateError('the video decoder is closed'));
    }
    return _serialize<void>(() {
      if (_closed) throw StateError('the video decoder is closed');
      var target = position;
      if (target < Duration.zero) target = Duration.zero;
      if (info.duration > Duration.zero && target > info.duration) {
        target = info.duration;
      }
      final NativeArena arena = NativeArena();
      try {
        final Pointer<_PropVariant> value = arena<_PropVariant>();
        value.ref.vt = _vtI8;
        (value.cast<Uint8>() + 8).cast<Int64>().value =
            target.inMicroseconds * 10;
        checkHresult(
          _reader.setCurrentPosition(_guidNull.allocateIn(arena), value),
          'IMFSourceReader::SetCurrentPosition',
        );
        _sequence = 0;
        _eos = false;
        _seekTarget = target;
        _frameRing.invalidateAll();
      } on Object catch (error) {
        throw VideoDecoderException(
          'seek',
          'Media Foundation could not seek to $target',
          cause: error,
        );
      } finally {
        arena.dispose();
      }
    });
  }

  @override
  Future<void> close() {
    if (_closeRequested) return _tail;
    _closeRequested = true;
    return _serialize<void>(() {
      if (_closed) return;
      _closed = true;
      try {
        // Reader first: it holds references into the device manager, which
        // must outlive every sample the reader still owns.
        _reader.dispose();
        _hardware?.dispose();
      } finally {
        _frameRing.dispose();
        _readPath.dispose();
        try {
          checkHresult(_api.shutdown(), 'MFShutdown');
        } finally {
          if (_ownsApartment) _api.coUninitialize();
        }
      }
    });
  }
}

final class _MfApi {
  _MfApi._(
    DynamicLibrary platform,
    DynamicLibrary readWrite,
    DynamicLibrary ole,
    this.createDxgiDeviceManager,
    this.createD3d11Device,
  )   : startup =
            platform.lookupFunction<_MfStartupNative, int Function(int, int)>(
                'MFStartup'),
        shutdown = platform
            .lookupFunction<_MfShutdownNative, int Function()>('MFShutdown'),
        createAttributes = platform.lookupFunction<_MfCreateAttributesNative,
            int Function(Pointer<Pointer<Void>>, int)>('MFCreateAttributes'),
        createMediaType = platform.lookupFunction<_MfCreateMediaTypeNative,
            int Function(Pointer<Pointer<Void>>)>('MFCreateMediaType'),
        createSourceReaderFromUrl = readWrite.lookupFunction<
            _MfCreateSourceReaderFromUrlNative,
            int Function(Pointer<Uint16>, Pointer<Void>,
                Pointer<Pointer<Void>>)>('MFCreateSourceReaderFromURL'),
        coInitializeEx = ole.lookupFunction<_CoInitializeExNative,
            int Function(Pointer<Void>, int)>('CoInitializeEx'),
        coUninitialize =
            ole.lookupFunction<_CoUninitializeNative, void Function()>(
                'CoUninitialize'),
        propVariantClear = ole.lookupFunction<_PropVariantClearNative,
            int Function(Pointer<_PropVariant>)>('PropVariantClear');

  factory _MfApi.load() {
    final DynamicLibrary platform = DynamicLibrary.open('mfplat.dll');
    return _MfApi._(
      platform,
      DynamicLibrary.open('mfreadwrite.dll'),
      DynamicLibrary.open('ole32.dll'),
      _lookupCreateDxgiDeviceManager(platform),
      _lookupD3d11CreateDevice(),
    );
  }

  /// `MFCreateDXGIDeviceManager` arrived with Windows 8. Its absence is a
  /// reason to decode in software, not a reason to fail to open the file, so
  /// it is looked up separately from the symbols this decoder cannot live
  /// without.
  static int Function(Pointer<Uint32>, Pointer<Pointer<Void>>)?
      _lookupCreateDxgiDeviceManager(DynamicLibrary platform) {
    try {
      return platform.lookupFunction<_MfCreateDxgiDeviceManagerNative,
          int Function(Pointer<Uint32>, Pointer<Pointer<Void>>)>(
        'MFCreateDXGIDeviceManager',
      );
    } on Object {
      return null;
    }
  }

  /// Same reasoning for `d3d11.dll`, which a stripped Windows image or a
  /// Server Core installation can be missing entirely.
  static _D3d11CreateDevice? _lookupD3d11CreateDevice() {
    try {
      return DynamicLibrary.open('d3d11.dll')
          .lookupFunction<_D3d11CreateDeviceNative, _D3d11CreateDevice>(
        'D3D11CreateDevice',
      );
    } on Object {
      return null;
    }
  }

  final int Function(int, int) startup;
  final int Function() shutdown;
  final int Function(Pointer<Pointer<Void>>, int) createAttributes;
  final int Function(Pointer<Pointer<Void>>) createMediaType;
  final int Function(
    Pointer<Uint16>,
    Pointer<Void>,
    Pointer<Pointer<Void>>,
  ) createSourceReaderFromUrl;
  final int Function(Pointer<Void>, int) coInitializeEx;
  final void Function() coUninitialize;
  final int Function(Pointer<_PropVariant>) propVariantClear;

  /// Null when this Windows build has no DXGI device manager.
  final int Function(Pointer<Uint32>, Pointer<Pointer<Void>>)?
      createDxgiDeviceManager;

  /// Null when `d3d11.dll` is not installed.
  final _D3d11CreateDevice? createD3d11Device;
}

typedef _D3d11CreateDevice = int Function(
  Pointer<Void> adapter,
  int driverType,
  Pointer<Void> software,
  int flags,
  Pointer<Uint32> featureLevels,
  int featureLevelCount,
  int sdkVersion,
  Pointer<Pointer<Void>> device,
  Pointer<Uint32> selectedFeatureLevel,
  Pointer<Pointer<Void>> immediateContext,
);

typedef _SetMultithreadProtectedNative = Int32 Function(
  Pointer<Void>,
  Int32,
);
typedef _ResetDeviceNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
);

/// `IMFDXGIDeviceManager`, the handle the Source Reader hands to a decoder MFT
/// so it can allocate its output surfaces on the GPU.
final class _MfDxgiDeviceManager extends ComObject {
  _MfDxgiDeviceManager(super.pointer)
      : super(interfaceName: 'IMFDXGIDeviceManager');

  // IUnknown 0..2, then the methods in alphabetical order: CloseDeviceHandle
  // 3, GetVideoService 4, LockDevice 5, OpenDeviceHandle 6, ResetDevice 7.
  late final int Function(Pointer<Void>, Pointer<Void>, int) _resetDevice =
      comMethod<_ResetDeviceNative>(pointer, 7).asFunction();

  int resetDevice(Pointer<Void> device, int resetToken) =>
      _resetDevice(pointer, device, resetToken);
}

/// `ID3D10Multithread`, queried off the D3D11 device.
final class _D3d10Multithread extends ComObject {
  _D3d10Multithread(super.pointer) : super(interfaceName: 'ID3D10Multithread');

  // IUnknown 0..2, Enter 3, Leave 4, SetMultithreadProtected 5.
  late final int Function(Pointer<Void>, int) _setProtected =
      comMethod<_SetMultithreadProtectedNative>(pointer, 5).asFunction();

  /// Returns the previous setting rather than an HRESULT.
  int setMultithreadProtected(bool value) =>
      _setProtected(pointer, value ? 1 : 0);
}

/// A video-capable Direct3D 11 device and the device manager that publishes it
/// to Media Foundation.
///
/// Everything here is best-effort by construction: [tryCreate] answers null
/// for every failure, and a null answer means the caller negotiates a software
/// Source Reader instead. Nothing in this class throws.
final class _MfHardwareContext {
  _MfHardwareContext._(this._device, this.manager);

  final ComObject _device;
  final _MfDxgiDeviceManager manager;

  static _MfHardwareContext? tryCreate(_MfApi api) {
    if (debugMediaFoundationHardwareFault ==
        MediaFoundationHardwareFault.deviceManager) {
      return null;
    }
    final _D3d11CreateDevice? createDevice = api.createD3d11Device;
    final int Function(Pointer<Uint32>, Pointer<Pointer<Void>>)? createManager =
        api.createDxgiDeviceManager;
    if (createDevice == null || createManager == null) return null;

    final NativeArena arena = NativeArena();
    ComObject? device;
    _MfDxgiDeviceManager? manager;
    try {
      final Pointer<Uint32> levels =
          arena.allocate<Uint32>(4 * _d3dFeatureLevels.length);
      for (var i = 0; i < _d3dFeatureLevels.length; i++) {
        levels[i] = _d3dFeatureLevels[i];
      }
      final Pointer<Pointer<Void>> deviceOut = arena.allocateOutPointer();
      final Pointer<Uint32> selected = arena<Uint32>();

      // Two attempts, exactly as the renderer's backend does: a runtime that
      // predates feature level 11.1 rejects the whole array with E_INVALIDARG
      // rather than skipping the entry it does not know.
      var created = false;
      for (var skip = 0; skip < 2 && !created; skip++) {
        final int hr = hresult(createDevice(
          nullptr,
          _d3dDriverTypeHardware,
          nullptr,
          _d3d11CreateDeviceBgraSupport | _d3d11CreateDeviceVideoSupport,
          Pointer<Uint32>.fromAddress(levels.address + skip * 4),
          _d3dFeatureLevels.length - skip,
          _d3d11SdkVersion,
          deviceOut,
          selected,
          nullptr,
        ));
        if (succeeded(hr) && deviceOut.value != nullptr) {
          created = true;
          break;
        }
        if (hr != eInvalidArg) break;
      }
      // WARP is deliberately not attempted. A software rasteriser would take
      // the accelerated path and then decode on the CPU anyway, more slowly
      // than the Source Reader's own software chain.
      if (!created) return null;
      device = ComObject(deviceOut.value, interfaceName: 'ID3D11Device');

      // Without this the decoder MFT and this isolate touch the immediate
      // context from different threads, which corrupts frames intermittently
      // rather than failing.
      final Pointer<Pointer<Void>> multithreadOut = arena.allocateOutPointer();
      if (failed(device.queryInterfaceInto(
            _iidD3d10Multithread,
            multithreadOut,
          )) ||
          multithreadOut.value == nullptr) {
        return null;
      }
      final _D3d10Multithread multithread =
          _D3d10Multithread(multithreadOut.value);
      try {
        multithread.setMultithreadProtected(true);
      } finally {
        multithread.dispose();
      }

      final Pointer<Uint32> resetToken = arena<Uint32>();
      final Pointer<Pointer<Void>> managerOut = arena.allocateOutPointer();
      if (failed(createManager(resetToken, managerOut)) ||
          managerOut.value == nullptr) {
        return null;
      }
      manager = _MfDxgiDeviceManager(managerOut.value);
      if (failed(manager.resetDevice(device.pointer, resetToken.value))) {
        return null;
      }

      final _MfHardwareContext context = _MfHardwareContext._(device, manager);
      device = null;
      manager = null;
      return context;
    } on Object {
      return null;
    } finally {
      manager?.dispose();
      device?.dispose();
      arena.dispose();
    }
  }

  void dispose() {
    manager.dispose();
    _device.dispose();
  }
}

final class _PropVariant extends Struct {
  @Uint16()
  external int vt;

  @Uint16()
  external int reserved1;

  @Uint16()
  external int reserved2;

  @Uint16()
  external int reserved3;

  @Array(16)
  external Array<Uint8> data;
}

typedef _GetUint64Native = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint64>,
);
typedef _GetGuidNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _SetUint32Native = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
);
typedef _SetGuidNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _GetUint32Native = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _GetItemTypeNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _SetUnknownNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Void>,
);

final class _MfAttributes extends ComObject {
  _MfAttributes(super.pointer, String name) : super(interfaceName: name);

  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>)
      _getItemType = comMethod<_GetItemTypeNative>(pointer, 4).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>)
      _getUint32 = comMethod<_GetUint32Native>(pointer, 7).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint64>)
      _getUint64 = comMethod<_GetUint64Native>(pointer, 8).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)
      _getGuid = comMethod<_GetGuidNative>(pointer, 10).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, int) _setUint32 =
      comMethod<_SetUint32Native>(pointer, 21).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)
      _setGuid = comMethod<_SetGuidNative>(pointer, 24).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>)
      _setUnknown = comMethod<_SetUnknownNative>(pointer, 27).asFunction();

  int getUint64(Guid key, NativeArena arena) {
    final Pointer<Uint64> value = arena<Uint64>();
    checkHresult(
      _getUint64(pointer, key.allocateIn(arena), value),
      '$interfaceName::GetUINT64($key)',
    );
    return value.value;
  }

  int? tryGetUint64(Guid key, NativeArena arena) {
    final Pointer<Uint64> value = arena<Uint64>();
    final int result = _getUint64(pointer, key.allocateIn(arena), value);
    return failed(result) ? null : value.value;
  }

  void setUint32(Guid key, int value, NativeArena arena) {
    checkHresult(
      _setUint32(pointer, key.allocateIn(arena), value),
      '$interfaceName::SetUINT32($key)',
    );
  }

  int? tryGetUint32(Guid key, NativeArena arena) {
    final Pointer<Uint32> value = arena<Uint32>();
    final int result = _getUint32(pointer, key.allocateIn(arena), value);
    return failed(result) ? null : value.value;
  }

  /// Whether [key] is present at all, whatever its type. Used for attributes
  /// whose value is irrelevant and whose presence is the signal.
  bool hasItem(Guid key, NativeArena arena) {
    final Pointer<Uint32> type = arena<Uint32>();
    return succeeded(_getItemType(pointer, key.allocateIn(arena), type));
  }

  /// Stores an interface pointer. The attribute store takes its own
  /// reference, so the caller keeps owning [value].
  void setUnknown(Guid key, Pointer<Void> value, NativeArena arena) {
    checkHresult(
      _setUnknown(pointer, key.allocateIn(arena), value),
      '$interfaceName::SetUnknown($key)',
    );
  }

  void setGuid(Guid key, Guid value, NativeArena arena) {
    checkHresult(
      _setGuid(pointer, key.allocateIn(arena), value.allocateIn(arena)),
      '$interfaceName::SetGUID($key)',
    );
  }

  String codecName(Guid key, NativeArena arena) {
    final Pointer<Uint8> value = arena.allocate<Uint8>(16);
    if (failed(_getGuid(pointer, key.allocateIn(arena), value))) {
      return 'unknown';
    }
    final Uint8List bytes = value.asTypedList(4);
    final String fourcc = String.fromCharCodes(bytes);
    final bool printable =
        bytes.every((int byte) => byte >= 0x20 && byte < 0x7f);
    return printable ? fourcc.trim().toLowerCase() : 'media-foundation';
  }
}

typedef _SetStreamSelectionNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Int32,
);
typedef _GetNativeMediaTypeNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _GetCurrentMediaTypeNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _SetCurrentMediaTypeNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _SetCurrentPositionNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<_PropVariant>,
);
typedef _ReadSampleNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Int64>,
  Pointer<Pointer<Void>>,
);
typedef _GetPresentationAttributeNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint8>,
  Pointer<_PropVariant>,
);
typedef _GetServiceForStreamNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
);
typedef _GetTransformForStreamNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
);
typedef _GetTransformAttributesNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

final class _MfSourceReader extends ComObject {
  _MfSourceReader(super.pointer) : super(interfaceName: 'IMFSourceReader');

  late final int Function(Pointer<Void>, int, int) _setSelection =
      comMethod<_SetStreamSelectionNative>(pointer, 4).asFunction();
  late final int Function(Pointer<Void>, int, int, Pointer<Pointer<Void>>)
      _getNativeType =
      comMethod<_GetNativeMediaTypeNative>(pointer, 5).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      _getCurrentType =
      comMethod<_GetCurrentMediaTypeNative>(pointer, 6).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
      _setCurrentType =
      comMethod<_SetCurrentMediaTypeNative>(pointer, 7).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<_PropVariant>)
      _setPosition =
      comMethod<_SetCurrentPositionNative>(pointer, 8).asFunction();
  late final int Function(Pointer<Void>, int, int, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Int64>, Pointer<Pointer<Void>>) _readSample =
      comMethod<_ReadSampleNative>(pointer, 9).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Uint8>, Pointer<Uint8>,
          Pointer<Pointer<Void>>) _getService =
      comMethod<_GetServiceForStreamNative>(pointer, 11).asFunction();
  late final int Function(
          Pointer<Void>, int, Pointer<Uint8>, Pointer<_PropVariant>)
      _getAttribute =
      comMethod<_GetPresentationAttributeNative>(pointer, 12).asFunction();

  int setStreamSelection(int stream, bool selected) =>
      _setSelection(pointer, stream, selected ? 1 : 0);
  int getNativeMediaType(int stream, int index, Pointer<Pointer<Void>> out) =>
      _getNativeType(pointer, stream, index, out);
  int getCurrentMediaType(int stream, Pointer<Pointer<Void>> out) =>
      _getCurrentType(pointer, stream, out);
  int setCurrentMediaType(int stream, Pointer<Void> type) =>
      _setCurrentType(pointer, stream, nullptr, type);
  int setCurrentPosition(
          Pointer<Uint8> timeFormat, Pointer<_PropVariant> position) =>
      _setPosition(pointer, timeFormat, position);
  int readSample(
    int stream,
    Pointer<Uint32> actualStream,
    Pointer<Uint32> flags,
    Pointer<Int64> timestamp,
    Pointer<Pointer<Void>> sample,
  ) =>
      _readSample(
        pointer,
        stream,
        0,
        actualStream,
        flags,
        timestamp,
        sample,
      );

  /// Which decoder the reader actually put at the head of the video chain.
  ///
  /// Only called once a D3D device manager has been attached, and it exists
  /// because attaching one is a request, not a guarantee: a codec the GPU has
  /// no fixed-function block for still gets a software MFT, and reporting
  /// [VideoStreamInfo.hardwareAcceleration] from the request rather than from
  /// the result is how the old `false` became a lie in the other direction.
  ///
  /// Every failure answers [_MfDecodePath.unverified] rather than throwing:
  /// this is a diagnostic, and a diagnostic must not be able to close a file
  /// that plays.
  _MfDecodePath decodePath(NativeArena arena) {
    // IMFSourceReaderEx is Windows 8 and newer. So is the DXGI device
    // manager, so in practice both are present or neither is.
    final Pointer<Pointer<Void>> readerOut = arena.allocateOutPointer();
    if (failed(queryInterfaceInto(_iidMfSourceReaderEx, readerOut)) ||
        readerOut.value == nullptr) {
      return _MfDecodePath.unverified;
    }
    final _MfSourceReaderEx reader = _MfSourceReaderEx(readerOut.value);
    try {
      // Walk the chain rather than assuming position: a stream that needs no
      // decoding still gets converters, and a converter answers
      // MF_SA_D3D11_AWARE whether or not a single macroblock was decoded on
      // the GPU. Only the transform in the decoder category is evidence.
      for (var index = 0; index < _maxProbedTransforms; index++) {
        final Pointer<Uint8> category = arena.allocate<Uint8>(16);
        final Pointer<Pointer<Void>> transformOut = arena.allocateOutPointer();
        if (failed(reader.getTransformForStream(
              _firstVideoStream,
              index,
              category,
              transformOut,
            )) ||
            transformOut.value == nullptr) {
          return index == 0
              ? _MfDecodePath.unverified
              : _MfDecodePath.noDecoder;
        }
        final _MfTransform transform = _MfTransform(transformOut.value);
        try {
          if (!_guidEquals(category, _mftCategoryVideoDecoder)) continue;
          final _MfAttributes? attributes = transform.tryGetAttributes();
          if (attributes == null) return _MfDecodePath.unverified;
          try {
            if (attributes.hasItem(_mftEnumHardwareUrl, arena)) {
              return _MfDecodePath.hardwareMft;
            }
            return attributes.tryGetUint32(_mfSaD3d11Aware, arena) == 1
                ? _MfDecodePath.dxva
                : _MfDecodePath.softwareMft;
          } finally {
            attributes.dispose();
          }
        } finally {
          transform.dispose();
        }
      }
      return _MfDecodePath.noDecoder;
    } finally {
      reader.dispose();
    }
  }

  Duration presentationDuration(_MfApi api, NativeArena arena) {
    final Pointer<_PropVariant> value = arena<_PropVariant>();
    final int result = _getAttribute(
      pointer,
      _mediaSource,
      _mfPdDuration.allocateIn(arena),
      value,
    );
    if (succeeded(result)) {
      try {
        if (value.ref.vt == _vtI8 || value.ref.vt == _vtUi8) {
          final int ticks = (value.cast<Uint8>() + 8).cast<Int64>().value;
          if (ticks > 0) return Duration(microseconds: ticks ~/ 10);
        }
      } finally {
        api.propVariantClear(value);
      }
    }

    // Some byte-stream sources do not project MF_PD_DURATION through the
    // Source Reader. Its presentation descriptor remains authoritative and
    // keeps the native path independent from ffprobe.
    final Pointer<Pointer<Void>> sourceOut = arena.allocateOutPointer();
    final int serviceResult = _getService(
      pointer,
      _mediaSource,
      _guidNull.allocateIn(arena),
      _iidMfMediaSource.allocateIn(arena),
      sourceOut,
    );
    if (failed(serviceResult) || sourceOut.value == nullptr) {
      return Duration.zero;
    }
    final _MfMediaSource source = _MfMediaSource(sourceOut.value);
    try {
      final Pointer<Pointer<Void>> descriptorOut = arena.allocateOutPointer();
      if (failed(source.createPresentationDescriptor(descriptorOut)) ||
          descriptorOut.value == nullptr) {
        return Duration.zero;
      }
      final _MfAttributes descriptor =
          _MfAttributes(descriptorOut.value, 'IMFPresentationDescriptor');
      try {
        final int? ticks = descriptor.tryGetUint64(_mfPdDuration, arena);
        return ticks == null || ticks <= 0
            ? Duration.zero
            : Duration(microseconds: ticks ~/ 10);
      } finally {
        descriptor.dispose();
      }
    } finally {
      source.dispose();
    }
  }
}

/// Compares a raw 16-byte `GUID` written by a native out-parameter with a
/// [Guid] known here, without allocating a second copy of either.
bool _guidEquals(Pointer<Uint8> raw, Guid guid) {
  final Uint8List expected = guid.toBytes();
  final Uint8List actual = raw.asTypedList(16);
  for (var i = 0; i < 16; i++) {
    if (actual[i] != expected[i]) return false;
  }
  return true;
}

/// The Windows 8 extension of `IMFSourceReader`, for one read-only question:
/// which transforms the reader built for a stream.
final class _MfSourceReaderEx extends ComObject {
  _MfSourceReaderEx(super.pointer) : super(interfaceName: 'IMFSourceReaderEx');

  // IMFSourceReader occupies 3..12; the extension adds SetNativeMediaType 13,
  // AddTransformForStream 14, RemoveAllTransformsForStream 15,
  // GetTransformForStream 16.
  late final int Function(
          Pointer<Void>, int, int, Pointer<Uint8>, Pointer<Pointer<Void>>)
      _getTransform =
      comMethod<_GetTransformForStreamNative>(pointer, 16).asFunction();

  int getTransformForStream(
    int stream,
    int index,
    Pointer<Uint8> category,
    Pointer<Pointer<Void>> out,
  ) =>
      _getTransform(pointer, stream, index, category, out);
}

/// Only the attribute store of an `IMFTransform` is needed here.
final class _MfTransform extends ComObject {
  _MfTransform(super.pointer) : super(interfaceName: 'IMFTransform');

  // GetStreamLimits 3, GetStreamCount 4, GetStreamIDs 5, GetInputStreamInfo
  // 6, GetOutputStreamInfo 7, GetAttributes 8.
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>)
      _getAttributes =
      comMethod<_GetTransformAttributesNative>(pointer, 8).asFunction();

  /// Null when the transform publishes no attribute store, which some
  /// converters legitimately do not.
  _MfAttributes? tryGetAttributes() {
    final NativeArena arena = NativeArena();
    try {
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      if (failed(_getAttributes(pointer, out)) || out.value == nullptr) {
        return null;
      }
      return _MfAttributes(out.value, 'IMFTransform(attributes)');
    } on Object {
      return null;
    } finally {
      arena.dispose();
    }
  }
}

typedef _CreatePresentationDescriptorNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

final class _MfMediaSource extends ComObject {
  _MfMediaSource(super.pointer) : super(interfaceName: 'IMFMediaSource');

  // IUnknown 0..2, IMFMediaEventGenerator 3..6, GetCharacteristics 7.
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _create =
      comMethod<_CreatePresentationDescriptorNative>(pointer, 8).asFunction();

  int createPresentationDescriptor(Pointer<Pointer<Void>> out) =>
      _create(pointer, out);
}

typedef _GetSampleDurationNative = Int32 Function(
  Pointer<Void>,
  Pointer<Int64>,
);
typedef _GetBufferCountNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint32>,
);
typedef _GetBufferByIndexNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _ConvertToBufferNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

/// Every native resource `readFrame` needs, bound once per decoder.
///
/// ## Why this is not three `ComObject`s
///
/// The obvious spelling of the read loop - wrap the sample, wrap its buffer,
/// wrap the buffer's 2D view, let each one bind its own methods and dispose
/// at the end of the frame - was measured at roughly 14 KB of garbage per
/// `readFrame`, which at 25 fps was the single largest allocation source in a
/// playing session. Almost none of it was the frame: it was ~74 `Pointer`
/// boxes, ~35 closures and ~35 contexts per frame, produced by binding the
/// same six vtable slots over and over, plus three `NativeArena`s whose only
/// job was to hold four-byte out-parameters that never change address.
///
/// So every out-parameter is a fixed slot allocated once, and every vtable
/// binding is cached. Nothing here assumes Media Foundation hands out a
/// single implementation: each binding remembers the vtable address it was
/// resolved from and rebinds if an interface ever arrives with a different
/// one, which is correct for a mixed pipeline and costs one pointer read per
/// frame when - as in practice - the vtable is stable.
///
/// The decoder serialises `readFrame` against itself, so one shared set of
/// scratch slots cannot be entered twice concurrently.
final class _ReadPath {
  _ReadPath() {
    actualStream = _arena<Uint32>();
    flags = _arena<Uint32>();
    timestamp = _arena<Int64>();
    sampleOut = _arena.allocateOutPointer();
    _duration = _arena<Int64>();
    _bufferCount = _arena<Uint32>();
    _bufferOut = _arena.allocateOutPointer();
    _viewOut = _arena.allocateOutPointer();
    _contiguousLength = _arena<Uint32>();
    _lockedBytes = _arena<Pointer<Uint8>>();
    _lockedMaximum = _arena<Uint32>();
    _lockedCurrent = _arena<Uint32>();
    _iid2DBuffer = _iidMf2DBuffer.allocateIn(_arena);
  }

  final NativeArena _arena = NativeArena();

  /// `IMFSourceReader::ReadSample` out-parameters, reused every frame.
  late final Pointer<Uint32> actualStream;
  late final Pointer<Uint32> flags;
  late final Pointer<Int64> timestamp;
  late final Pointer<Pointer<Void>> sampleOut;

  late final Pointer<Int64> _duration;
  late final Pointer<Uint32> _bufferCount;
  late final Pointer<Pointer<Void>> _bufferOut;
  late final Pointer<Pointer<Void>> _viewOut;
  late final Pointer<Uint32> _contiguousLength;
  late final Pointer<Pointer<Uint8>> _lockedBytes;
  late final Pointer<Uint32> _lockedMaximum;
  late final Pointer<Uint32> _lockedCurrent;
  late final Pointer<Uint8> _iid2DBuffer;

  /// The vtable pointer an interface pointer's first word holds.
  ///
  /// `Pointer<IntPtr>.value` reads an `int`, so this materialises one box
  /// rather than the two `object.cast<Pointer<IntPtr>>().value` would.
  static int _vtableOf(Pointer<Void> object) =>
      Pointer<IntPtr>.fromAddress(object.address).value;

  // --- IMFSample: GetSampleDuration 37, GetBufferCount 39,
  // GetBufferByIndex 40, ConvertToContiguousBuffer 41. ---
  int _sampleVtable = 0;
  late int Function(Pointer<Void>, Pointer<Int64>) _sampleDuration;
  late int Function(Pointer<Void>, Pointer<Uint32>) _sampleBufferCount;
  late int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      _sampleBufferByIndex;
  late int Function(Pointer<Void>, Pointer<Pointer<Void>>) _sampleConvert;
  late int Function(Pointer<Void>) _sampleRelease;

  void _bindSample(Pointer<Void> object) {
    final int vtable = _vtableOf(object);
    if (vtable == _sampleVtable) return;
    _sampleVtable = vtable;
    _sampleDuration =
        comMethod<_GetSampleDurationNative>(object, 37).asFunction();
    _sampleBufferCount =
        comMethod<_GetBufferCountNative>(object, 39).asFunction();
    _sampleBufferByIndex =
        comMethod<_GetBufferByIndexNative>(object, 40).asFunction();
    _sampleConvert = comMethod<_ConvertToBufferNative>(object, 41).asFunction();
    _sampleRelease =
        comMethod<_ReadPathReleaseNative>(object, comSlotRelease).asFunction();
  }

  // --- IMFMediaBuffer: QueryInterface 0, Lock 3, Unlock 4. ---
  int _bufferVtable = 0;
  late int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>)
      _bufferQueryInterface;
  late int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Uint32>,
      Pointer<Uint32>) _bufferLock;
  late int Function(Pointer<Void>) _bufferUnlock;
  late int Function(Pointer<Void>) _bufferRelease;

  void _bindBuffer(Pointer<Void> object) {
    final int vtable = _vtableOf(object);
    if (vtable == _bufferVtable) return;
    _bufferVtable = vtable;
    _bufferQueryInterface =
        comMethod<_ReadPathQueryInterfaceNative>(object, comSlotQueryInterface)
            .asFunction();
    _bufferLock = comMethod<_BufferLockNative>(object, 3).asFunction();
    _bufferUnlock = comMethod<_BufferUnlockNative>(object, 4).asFunction();
    _bufferRelease =
        comMethod<_ReadPathReleaseNative>(object, comSlotRelease).asFunction();
  }

  // --- IMF2DBuffer: GetContiguousLength 7, ContiguousCopyTo 8. ---
  int _viewVtable = 0;
  late int Function(Pointer<Void>, Pointer<Uint32>) _viewContiguousLength;
  late int Function(Pointer<Void>, Pointer<Uint8>, int) _viewCopyTo;
  late int Function(Pointer<Void>) _viewRelease;

  void _bindView(Pointer<Void> object) {
    final int vtable = _vtableOf(object);
    if (vtable == _viewVtable) return;
    _viewVtable = vtable;
    _viewContiguousLength =
        comMethod<_GetContiguousLengthNative>(object, 7).asFunction();
    _viewCopyTo = comMethod<_ContiguousCopyToNative>(object, 8).asFunction();
    _viewRelease =
        comMethod<_ReadPathReleaseNative>(object, comSlotRelease).asFunction();
  }

  /// The sample's duration in 100-nanosecond units, or 0 when it has none.
  int sampleDuration(Pointer<Void> sample) {
    _bindSample(sample);
    return failed(_sampleDuration(sample, _duration)) ? 0 : _duration.value;
  }

  void releaseSample(Pointer<Void> sample) {
    _bindSample(sample);
    _sampleRelease(sample);
  }

  /// Copies one decoded frame into [destination], in as few passes as the
  /// sample allows.
  ///
  /// The fast path matters more than it looks. A DXVA sample's single buffer
  /// lives in video memory, and `ConvertToContiguousBuffer` answers it by
  /// allocating a *second*, system-memory buffer and reading the surface back
  /// into it - which this decoder would then copy a third time into its ring.
  /// `IMF2DBuffer::ContiguousCopyTo` performs the same read-back straight
  /// into the ring slot, so the frame crosses the bus once and lands where it
  /// is needed. Measured on 1080p BGRA over an Intel iGPU: 14.6 ms down to
  /// 4.6 ms per frame.
  ///
  /// Everything about it is optional. A sample carrying more than one buffer,
  /// a buffer with no 2D view, a contiguous length that disagrees with the
  /// negotiated frame size: each falls back to the original two-step copy,
  /// which is still correct for both software and hardware samples.
  Uint8List copyContiguousBytes(
    Pointer<Void> sample,
    int expected,
    NativeVideoFrameLease destination,
  ) {
    final Uint8List? direct = _tryCopy2D(sample, expected, destination);
    if (direct != null) return direct;

    _bindSample(sample);
    _bufferOut.value = nullptr;
    checkHresult(
      _sampleConvert(sample, _bufferOut),
      'IMFSample::ConvertToContiguousBuffer',
    );
    final Pointer<Void> buffer = _bufferOut.value;
    try {
      return _copyByLock(buffer, expected, destination);
    } finally {
      _bindBuffer(buffer);
      _bufferRelease(buffer);
    }
  }

  Uint8List? _tryCopy2D(
    Pointer<Void> sample,
    int expected,
    NativeVideoFrameLease destination,
  ) {
    _bindSample(sample);
    if (failed(_sampleBufferCount(sample, _bufferCount)) ||
        _bufferCount.value != 1) {
      return null;
    }
    _bufferOut.value = nullptr;
    if (failed(_sampleBufferByIndex(sample, 0, _bufferOut)) ||
        _bufferOut.value == nullptr) {
      return null;
    }
    final Pointer<Void> buffer = _bufferOut.value;
    try {
      return _tryContiguousCopyTo(buffer, expected, destination);
    } finally {
      _bindBuffer(buffer);
      _bufferRelease(buffer);
    }
  }

  /// One read-back straight into [destination], or null when this buffer has
  /// no usable 2D view.
  Uint8List? _tryContiguousCopyTo(
    Pointer<Void> buffer,
    int expected,
    NativeVideoFrameLease destination,
  ) {
    _bindBuffer(buffer);
    _viewOut.value = nullptr;
    if (failed(_bufferQueryInterface(buffer, _iid2DBuffer, _viewOut)) ||
        _viewOut.value == nullptr) {
      return null;
    }
    final Pointer<Void> view = _viewOut.value;
    _bindView(view);
    try {
      if (failed(_viewContiguousLength(view, _contiguousLength)) ||
          _contiguousLength.value != expected) {
        return null;
      }
      if (failed(_viewCopyTo(view, destination.pointer, expected))) return null;
      return destination.bytes;
    } finally {
      _viewRelease(view);
    }
  }

  Uint8List _copyByLock(
    Pointer<Void> buffer,
    int expected,
    NativeVideoFrameLease destination,
  ) {
    _bindBuffer(buffer);
    checkHresult(
      _bufferLock(buffer, _lockedBytes, _lockedMaximum, _lockedCurrent),
      'IMFMediaBuffer::Lock',
    );
    try {
      if (_lockedCurrent.value < expected) {
        throw VideoDecoderException(
          'decode',
          'Media Foundation returned ${_lockedCurrent.value} bytes for a '
              '$expected-byte RGB32 frame',
        );
      }
      destination.bytes
          .setRange(0, expected, _lockedBytes.value.asTypedList(expected));
      return destination.bytes;
    } finally {
      checkHresult(_bufferUnlock(buffer), 'IMFMediaBuffer::Unlock');
    }
  }

  void dispose() => _arena.dispose();
}

typedef _ReadPathReleaseNative = Uint32 Function(Pointer<Void>);
typedef _ReadPathQueryInterfaceNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
);
typedef _GetContiguousLengthNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint32>,
);
typedef _ContiguousCopyToNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
);
typedef _BufferLockNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _BufferUnlockNative = Int32 Function(Pointer<Void>);
