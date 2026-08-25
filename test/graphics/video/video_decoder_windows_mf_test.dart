@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/video/video_decoder.dart';
import 'package:dart_ui/src/graphics/video/video_decoder_windows_mf.dart';
import 'package:test/test.dart';

/// The Media Foundation decoder asks Direct3D 11 for a DXVA pipeline and falls
/// back to the Source Reader's software chain when it cannot have one. These
/// tests are about the fallback, because the accelerated path is the one that
/// takes itself on a developer machine while the software path is the one that
/// has to work on the machine with no GPU, the machine whose driver refuses
/// the codec, and the machine where D3D11 is not installed at all.
///
/// The stream they run on is an uncompressed RGB24 AVI written here, so no
/// codec has to be installed and no media file has to be checked in. Point
/// `DART_UI_TEST_VIDEO` at a real compressed file to run the same assertions
/// against one.
void main() {
  late Directory workspace;
  late String syntheticPath;

  setUpAll(() {
    workspace = Directory.systemTemp.createTempSync('dart_ui_mf_video');
    syntheticPath = '${workspace.path}${Platform.pathSeparator}synthetic.avi';
    File(syntheticPath).writeAsBytesSync(_buildUncompressedAvi());
  });

  tearDownAll(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  tearDown(() {
    debugMediaFoundationHardwareFault = MediaFoundationHardwareFault.none;
  });

  test('the synthetic stream decodes end to end on the default path', () async {
    final VideoDecoder decoder = await openWindowsNativeVideoDecoder(
      syntheticPath,
      const VideoDecoderOptions(),
    );
    try {
      expect(decoder.info.width, _width);
      expect(decoder.info.height, _height);
      expect(decoder.info.frameRate, closeTo(_frameRate.toDouble(), 0.001));
      expect(decoder.info.duration.inMilliseconds, greaterThan(0));

      var decoded = 0;
      while (await decoder.readFrame() != null) {
        decoded++;
        if (decoded > _frameCount * 2) break;
      }
      expect(decoded, _frameCount);
    } finally {
      await decoder.close();
    }
  });

  for (final MediaFoundationHardwareFault fault
      in <MediaFoundationHardwareFault>[
    MediaFoundationHardwareFault.deviceManager,
    MediaFoundationHardwareFault.sourceReader,
  ]) {
    test('a ${fault.name} failure falls back to software without throwing',
        () async {
      final _Decoded reference = await _decodeFirstFrame(syntheticPath);

      debugMediaFoundationHardwareFault = fault;
      final _Decoded fallback = await _decodeFirstFrame(syntheticPath);

      expect(fallback.backend, contains('software decode'));
      expect(fallback.hardwareAcceleration, isFalse);
      expect(fallback.width, reference.width);
      expect(fallback.height, reference.height);
      expect(fallback.frameCount, reference.frameCount);
      expect(fallback.pixelFormat, reference.pixelFormat);
      expect(fallback.bytesPerRow, reference.bytesPerRow);
      // The fallback is only worth having if it produces the same picture.
      expect(fallback.firstFrame, orderedEquals(reference.firstFrame));
      // And seek has to keep restarting the sequence on it.
      expect(fallback.sequenceAfterSeek, 0);
    });
  }

  test('every frame the decoder hands out stays BGRA with opaque alpha',
      () async {
    for (final MediaFoundationHardwareFault fault
        in MediaFoundationHardwareFault.values) {
      debugMediaFoundationHardwareFault = fault;
      final _Decoded decoded = await _decodeFirstFrame(syntheticPath);
      expect(
        decoded.pixelFormat,
        'bgra8888',
        reason: 'fault ${fault.name} changed the delivered frame format',
      );
      expect(decoded.bytesPerRow, _width * 4);
      for (var i = 3; i < decoded.firstFrame.length; i += 4) {
        expect(decoded.firstFrame[i], 0xff,
            reason: 'fault ${fault.name} left a transparent pixel at $i');
      }
    }
  });

  test('requesting software acceleration never attaches a D3D manager',
      () async {
    final _Decoded decoded = await _decodeFirstFrame(
      syntheticPath,
      options: const VideoDecoderOptions(
        acceleration: VideoDecoderAcceleration.software,
      ),
    );
    expect(decoded.backend, contains('software decode'));
    expect(decoded.hardwareAcceleration, isFalse);
  });

  test('a real compressed file falls back to the same picture', () async {
    final String? path = Platform.environment['DART_UI_TEST_VIDEO'];
    if (path == null || !File(path).existsSync()) {
      markTestSkipped('set DART_UI_TEST_VIDEO to a video file to run this');
      return;
    }
    final _Decoded reference = await _decodeFirstFrame(path, frames: 1);

    debugMediaFoundationHardwareFault =
        MediaFoundationHardwareFault.deviceManager;
    final _Decoded fallback = await _decodeFirstFrame(path, frames: 1);

    expect(fallback.backend, contains('software decode'));
    expect(fallback.hardwareAcceleration, isFalse);
    expect(fallback.width, reference.width);
    expect(fallback.height, reference.height);
    expect(fallback.pixelFormat, reference.pixelFormat);
    expect(fallback.firstFrame.length, reference.firstFrame.length);
  });
}

final class _Decoded {
  const _Decoded({
    required this.backend,
    required this.hardwareAcceleration,
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.bytesPerRow,
    required this.firstFrame,
    required this.frameCount,
    required this.sequenceAfterSeek,
  });

  final String backend;
  final bool hardwareAcceleration;
  final int width;
  final int height;
  final String pixelFormat;
  final int bytesPerRow;
  final Uint8List firstFrame;
  final int frameCount;
  final int? sequenceAfterSeek;
}

Future<_Decoded> _decodeFirstFrame(
  String path, {
  VideoDecoderOptions options = const VideoDecoderOptions(),
  int frames = _frameCount * 2,
}) async {
  final VideoDecoder decoder =
      await openWindowsNativeVideoDecoder(path, options);
  try {
    final VideoSample? first = await decoder.readFrame();
    expect(first, isNotNull, reason: '$path decoded no frames');
    final Uint8List firstFrame =
        Uint8List.fromList(first!.frame.planes.first.bytes);

    var count = 1;
    while (count < frames && await decoder.readFrame() != null) {
      count++;
    }

    await decoder.seek(Duration.zero);
    final VideoSample? replay = await decoder.readFrame();

    return _Decoded(
      backend: decoder.info.backend,
      hardwareAcceleration: decoder.info.hardwareAcceleration,
      width: decoder.info.width,
      height: decoder.info.height,
      pixelFormat: first.frame.format.pixelFormat.name,
      bytesPerRow: first.frame.planes.first.bytesPerRow,
      firstFrame: firstFrame,
      frameCount: count,
      sequenceAfterSeek: replay?.frame.sequence,
    );
  } finally {
    await decoder.close();
  }
}

const int _width = 64;
const int _height = 64;
const int _frameCount = 10;
const int _frameRate = 25;

/// Writes an uncompressed RGB24 AVI: a RIFF header, one `vids` stream with a
/// `BITMAPINFOHEADER` and BI_RGB frames, and an index.
///
/// Uncompressed on purpose. The point of the file is to be openable by the
/// Media Foundation source resolver on any Windows machine, including one
/// where no H.264 decoder is installed, so that a test about the *fallback*
/// never fails for the unrelated reason that the codec was missing.
Uint8List _buildUncompressedAvi() {
  const int rowBytes = (_width * 3 + 3) & ~3;
  const int frameBytes = rowBytes * _height;
  final BytesBuilder out = BytesBuilder();

  void fourcc(BytesBuilder target, String value) => target.add(value.codeUnits);
  void uint32(BytesBuilder target, int value) {
    final ByteData data = ByteData(4)..setUint32(0, value, Endian.little);
    target.add(data.buffer.asUint8List());
  }

  void uint16Pair(BytesBuilder target, int first, int second) {
    final ByteData data = ByteData(4)
      ..setUint16(0, first, Endian.little)
      ..setUint16(2, second, Endian.little);
    target.add(data.buffer.asUint8List());
  }

  final BytesBuilder mainHeader = BytesBuilder();
  uint32(mainHeader, 1000000 ~/ _frameRate); // dwMicroSecPerFrame
  uint32(mainHeader, frameBytes * _frameRate); // dwMaxBytesPerSec
  uint32(mainHeader, 0); // dwPaddingGranularity
  uint32(mainHeader, 0x10); // dwFlags: AVIF_HASINDEX
  uint32(mainHeader, _frameCount);
  uint32(mainHeader, 0); // dwInitialFrames
  uint32(mainHeader, 1); // dwStreams
  uint32(mainHeader, frameBytes); // dwSuggestedBufferSize
  uint32(mainHeader, _width);
  uint32(mainHeader, _height);
  for (var i = 0; i < 4; i++) {
    uint32(mainHeader, 0); // dwReserved
  }

  final BytesBuilder streamHeader = BytesBuilder();
  fourcc(streamHeader, 'vids');
  fourcc(streamHeader, 'DIB ');
  uint32(streamHeader, 0); // dwFlags
  uint16Pair(streamHeader, 0, 0); // wPriority, wLanguage
  uint32(streamHeader, 0); // dwInitialFrames
  uint32(streamHeader, 1); // dwScale
  uint32(streamHeader, _frameRate); // dwRate
  uint32(streamHeader, 0); // dwStart
  uint32(streamHeader, _frameCount); // dwLength
  uint32(streamHeader, frameBytes); // dwSuggestedBufferSize
  uint32(streamHeader, 0); // dwQuality
  uint32(streamHeader, 0); // dwSampleSize
  uint16Pair(streamHeader, 0, 0); // rcFrame left, top
  uint16Pair(streamHeader, _width, _height); // rcFrame right, bottom

  final BytesBuilder streamFormat = BytesBuilder();
  uint32(streamFormat, 40); // biSize
  uint32(streamFormat, _width);
  uint32(streamFormat, _height);
  uint16Pair(streamFormat, 1, 24); // biPlanes, biBitCount
  uint32(streamFormat, 0); // biCompression: BI_RGB
  uint32(streamFormat, frameBytes); // biSizeImage
  uint32(streamFormat, 0); // biXPelsPerMeter
  uint32(streamFormat, 0); // biYPelsPerMeter
  uint32(streamFormat, 0); // biClrUsed
  uint32(streamFormat, 0); // biClrImportant

  final BytesBuilder streamList = BytesBuilder();
  fourcc(streamList, 'strl');
  fourcc(streamList, 'strh');
  uint32(streamList, streamHeader.length);
  streamList.add(streamHeader.toBytes());
  fourcc(streamList, 'strf');
  uint32(streamList, streamFormat.length);
  streamList.add(streamFormat.toBytes());

  final BytesBuilder headerList = BytesBuilder();
  fourcc(headerList, 'hdrl');
  fourcc(headerList, 'avih');
  uint32(headerList, mainHeader.length);
  headerList.add(mainHeader.toBytes());
  fourcc(headerList, 'LIST');
  uint32(headerList, streamList.length);
  headerList.add(streamList.toBytes());

  fourcc(out, 'RIFF');
  uint32(out, 0); // Patched once the total length is known.
  fourcc(out, 'AVI ');
  fourcc(out, 'LIST');
  uint32(out, headerList.length);
  out.add(headerList.toBytes());

  fourcc(out, 'LIST');
  uint32(out, 4 + _frameCount * (8 + frameBytes));
  final int moviStart = out.length;
  fourcc(out, 'movi');
  final List<int> offsets = <int>[];
  for (var index = 0; index < _frameCount; index++) {
    offsets.add(out.length - moviStart);
    fourcc(out, '00db');
    uint32(out, frameBytes);
    out.add(_syntheticFrame(rowBytes, index));
  }

  fourcc(out, 'idx1');
  uint32(out, _frameCount * 16);
  for (var index = 0; index < _frameCount; index++) {
    fourcc(out, '00db');
    uint32(out, 0x10); // AVIIF_KEYFRAME
    uint32(out, offsets[index]);
    uint32(out, frameBytes);
  }

  final Uint8List bytes = out.toBytes();
  ByteData.sublistView(bytes).setUint32(4, bytes.length - 8, Endian.little);
  return bytes;
}

/// A frame whose content varies with [index], so a decoder that returns the
/// same picture twice can be told from one that is decoding.
Uint8List _syntheticFrame(int rowBytes, int index) {
  final Uint8List bytes = Uint8List(rowBytes * _height);
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      final int at = y * rowBytes + x * 3;
      bytes[at] = (x * 4 + index * 8) & 0xff;
      bytes[at + 1] = (y * 4) & 0xff;
      bytes[at + 2] = (index * 25) & 0xff;
    }
  }
  return bytes;
}
