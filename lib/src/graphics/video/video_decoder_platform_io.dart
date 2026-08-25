library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'macos_native_video_decoder.dart';
import 'video_decoder.dart';
import 'video_decoder_linux_gstreamer.dart';
import 'video_decoder_windows_mf.dart';
import 'video_frame.dart';

Future<VideoDecoder> openPlatformVideoDecoder(
  String path,
  VideoDecoderOptions options,
) async {
  final File input = File(path);
  if (!await input.exists()) {
    throw VideoDecoderException('open', 'file does not exist: $path');
  }
  options.validate();
  Object? nativeFailure;
  try {
    if (Platform.isWindows) {
      return await openWindowsNativeVideoDecoder(input.absolute.path, options);
    }
    if (Platform.isLinux) {
      return await openLinuxNativeVideoDecoder(input.absolute.path, options);
    }
    if (Platform.isMacOS) {
      return await openMacosNativeVideoDecoder(input.absolute.path, options);
    }
    throw VideoDecoderException(
      'native-open',
      'unsupported operating system: ${Platform.operatingSystem}',
    );
  } on Object catch (error) {
    nativeFailure = error;
  }
  if (!options.enableFfmpegFallback) {
    throw nativeFailure;
  }

  // External processes are deliberately below every native path. They keep
  // uncommon codecs usable, but are never started when the system decoder can
  // open the stream.
  final _NativeVideoProfile profile = _NativeVideoProfile.current();
  final String ffmpeg = await _findTool(
    explicit: options.executable,
    environmentName: 'DART_UI_FFMPEG',
    baseName: Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg',
  );
  final String ffprobe = await _findTool(
    explicit: options.probeExecutable,
    environmentName: 'DART_UI_FFPROBE',
    baseName: Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
    siblingOf: ffmpeg,
  );
  final _ProbeInfo probe = await _probe(ffprobe, input.absolute.path);
  options.validateDecodedFrame(
    width: probe.width,
    height: probe.height,
    bytesPerPixel: 4,
  );
  final bool hardware =
      options.acceleration == VideoDecoderAcceleration.automatic;
  final info = VideoStreamInfo(
    width: probe.width,
    height: probe.height,
    frameRate: probe.frameRate,
    duration: probe.duration,
    codec: probe.codec,
    backend: hardware ? profile.acceleratedName : profile.softwareName,
    hardwareAcceleration: hardware,
  );
  final decoder = _FfmpegVideoDecoder._(
    input.absolute.path,
    ffmpeg,
    info,
    options,
  );
  await decoder._start(Duration.zero);
  return decoder;
}

final class _NativeVideoProfile {
  const _NativeVideoProfile(this.acceleratedName, this.softwareName);

  final String acceleratedName;
  final String softwareName;

  static _NativeVideoProfile current() {
    if (Platform.isWindows) {
      return const _NativeVideoProfile(
        'FFmpeg fallback (Windows hardware auto)',
        'FFmpeg fallback (Windows software)',
      );
    }
    if (Platform.isMacOS) {
      return const _NativeVideoProfile(
        'FFmpeg fallback (macOS hardware auto)',
        'FFmpeg fallback (macOS software)',
      );
    }
    if (Platform.isLinux) {
      return const _NativeVideoProfile(
        'FFmpeg fallback (Linux hardware auto)',
        'FFmpeg fallback (Linux software)',
      );
    }
    throw VideoDecoderException(
      'open',
      'unsupported operating system: ${Platform.operatingSystem}',
    );
  }
}

final class _FfmpegVideoDecoder implements VideoDecoder {
  _FfmpegVideoDecoder._(
    this._path,
    this._ffmpeg,
    this.info,
    this._options,
  ) : _streamId = _nextStreamId++;

  static int _nextStreamId = 1;
  final String _path;
  final String _ffmpeg;
  final VideoDecoderOptions _options;
  final int _streamId;
  Process? _process;
  StreamIterator<List<int>>? _stdout;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  final StringBuffer _stderr = StringBuffer();
  StreamSubscription<String>? _stderrSubscription;
  int _sequence = 0;
  Duration _origin = Duration.zero;
  bool _closed = false;
  bool _reading = false;

  @override
  final VideoStreamInfo info;

  @override
  bool get isClosed => _closed;

  Future<void> _start(Duration position) async {
    final List<String> arguments = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      if (position > Duration.zero) ...<String>[
        '-ss',
        (position.inMicroseconds / Duration.microsecondsPerSecond)
            .toStringAsFixed(6),
      ],
      if (_options.acceleration ==
          VideoDecoderAcceleration.automatic) ...<String>['-hwaccel', 'auto'],
      '-i',
      _path,
      '-map',
      '0:v:0',
      '-an',
      '-sn',
      '-dn',
      '-vsync',
      '0',
      '-pix_fmt',
      'bgra',
      '-f',
      'rawvideo',
      'pipe:1',
    ];
    try {
      _process = await Process.start(
        _ffmpeg,
        arguments,
        mode: ProcessStartMode.normal,
      );
    } on Object catch (error) {
      throw VideoDecoderException('start', 'could not start $_ffmpeg',
          cause: error);
    }
    _stdout = StreamIterator<List<int>>(_process!.stdout);
    _stderr.clear();
    _stderrSubscription = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      if (_stderr.length < 16 * 1024) _stderr.writeln(line);
    });
    _origin = position;
    _sequence = 0;
  }

  @override
  Future<VideoSample?> readFrame() async {
    if (_closed) throw StateError('the video decoder is closed');
    if (_reading) {
      throw StateError('readFrame calls must not overlap');
    }
    _reading = true;
    try {
      final int byteCount = info.width * info.height * 4;
      final Uint8List? bytes = await _readExactly(byteCount);
      if (bytes == null) {
        final int code = await (_process?.exitCode ?? Future<int>.value(0));
        if (code != 0) {
          final String detail = _stderr.toString().trim();
          throw VideoDecoderException(
            'decode',
            detail.isEmpty ? 'ffmpeg exited with code $code' : detail,
          );
        }
        return null;
      }
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
          VideoPlane(bytes: bytes, bytesPerRow: info.width * 4),
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
      _reading = false;
    }
  }

  Future<Uint8List?> _readExactly(int length) async {
    while (_pending.length < length) {
      final StreamIterator<List<int>>? source = _stdout;
      if (source == null || !await source.moveNext()) break;
      _pending.add(source.current);
    }
    if (_pending.length == 0) return null;
    if (_pending.length < length) {
      throw VideoDecoderException(
        'decode',
        'truncated raw frame: got ${_pending.length} of $length bytes',
      );
    }
    final Uint8List all = _pending.takeBytes();
    final Uint8List frame = Uint8List.fromList(all.sublist(0, length));
    if (all.length > length) _pending.add(all.sublist(length));
    return frame;
  }

  @override
  Future<void> seek(Duration position) async {
    if (_closed) throw StateError('the video decoder is closed');
    if (_reading) throw StateError('cannot seek while readFrame is pending');
    Duration target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (info.duration > Duration.zero && target > info.duration) {
      target = info.duration;
    }
    await _stopProcess();
    _pending.clear();
    await _start(target);
  }

  Future<void> _stopProcess() async {
    final Process? process = _process;
    _process = null;
    final StreamIterator<List<int>>? output = _stdout;
    _stdout = null;
    await output?.cancel();
    await _stderrSubscription?.cancel();
    _stderrSubscription = null;
    if (process != null) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _stopProcess();
    _pending.clear();
  }
}

final class _ProbeInfo {
  const _ProbeInfo(
    this.width,
    this.height,
    this.frameRate,
    this.duration,
    this.codec,
  );

  final int width;
  final int height;
  final double frameRate;
  final Duration duration;
  final String codec;
}

Future<_ProbeInfo> _probe(String executable, String path) async {
  final ProcessResult result;
  try {
    result = await Process.run(executable, <String>[
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height,avg_frame_rate,codec_name,duration:format=duration',
      '-of',
      'json',
      path,
    ]).timeout(const Duration(seconds: 15));
  } on Object catch (error) {
    throw VideoDecoderException('probe', 'could not inspect $path',
        cause: error);
  }
  if (result.exitCode != 0) {
    throw VideoDecoderException('probe', '${result.stderr}'.trim());
  }
  try {
    final Object? decoded = jsonDecode('${result.stdout}');
    final Map<String, Object?> root = (decoded as Map).cast<String, Object?>();
    final List<Object?> streams =
        (root['streams'] as List?) ?? const <Object?>[];
    if (streams.isEmpty) {
      throw const FormatException('no video stream');
    }
    final Map<String, Object?> stream =
        (streams.first as Map).cast<String, Object?>();
    final Map<String, Object?> format =
        ((root['format'] as Map?) ?? const <String, Object?>{})
            .cast<String, Object?>();
    final int width = (stream['width'] as num).toInt();
    final int height = (stream['height'] as num).toInt();
    final double rate = _parseRate('${stream['avg_frame_rate'] ?? ''}');
    final double seconds = double.tryParse(
          '${stream['duration'] ?? format['duration'] ?? 0}',
        ) ??
        0;
    if (width <= 0 || height <= 0) throw const FormatException('invalid size');
    return _ProbeInfo(
      width,
      height,
      rate > 0 ? rate : 30,
      Duration(
          microseconds: (seconds * Duration.microsecondsPerSecond).round()),
      '${stream['codec_name'] ?? 'unknown'}',
    );
  } on Object catch (error) {
    throw VideoDecoderException(
      'probe',
      'ffprobe returned malformed stream metadata',
      cause: error,
    );
  }
}

double _parseRate(String value) {
  final List<String> parts = value.split('/');
  if (parts.length == 2) {
    final double numerator = double.tryParse(parts[0]) ?? 0;
    final double denominator = double.tryParse(parts[1]) ?? 0;
    return denominator == 0 ? 0 : numerator / denominator;
  }
  return double.tryParse(value) ?? 0;
}

Future<String> _findTool({
  required String? explicit,
  required String environmentName,
  required String baseName,
  String? siblingOf,
}) async {
  final List<String> candidates = <String>[
    if (explicit != null && explicit.trim().isNotEmpty) explicit,
    if ((Platform.environment[environmentName] ?? '').trim().isNotEmpty)
      Platform.environment[environmentName]!,
    if (siblingOf != null)
      File('${File(siblingOf).parent.path}${Platform.pathSeparator}$baseName')
          .path,
    File('${File(Platform.resolvedExecutable).parent.path}'
            '${Platform.pathSeparator}$baseName')
        .path,
    baseName,
  ];
  Object? lastError;
  for (final String candidate in candidates.toSet()) {
    try {
      final ProcessResult result = await Process.run(
        candidate,
        const <String>['-version'],
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) return candidate;
    } on Object catch (error) {
      lastError = error;
    }
  }
  throw VideoDecoderException(
    'discovery',
    'could not find $baseName; install FFmpeg or set $environmentName',
    cause: lastError,
  );
}
