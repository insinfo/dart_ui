import 'dart:io';
import 'dart:typed_data';

/// External proof that a backend really put pixels on screen.
///
/// Everything a backend reports about its own framebuffer is self-reported:
/// the same process that drew the frame says the frame exists. `screencapture`
/// only succeeds for a CGSWindowID the WindowServer actually owns, so a capture
/// that comes back with the expected colour is evidence from outside the
/// process - the same witness for all three backends.
///
/// PNG would need a decoder; `sips` converts the capture to BMP, whose header
/// is small enough to parse here without a dependency.
class PixelSample {
  const PixelSample(this.red, this.green, this.blue);

  final int red;
  final int green;
  final int blue;

  /// Colour management on the capture path shifts values by a few units, and
  /// window shadows/rounded corners never touch the centre pixel, so a loose
  /// per-channel tolerance is enough to tell "our frame" from "the desktop".
  bool matches(PixelSample expected, {int tolerance = 48}) =>
      (red - expected.red).abs() <= tolerance &&
      (green - expected.green).abs() <= tolerance &&
      (blue - expected.blue).abs() <= tolerance;

  @override
  String toString() => '$red,$green,$blue';
}

class WindowPixelWitnessResult {
  const WindowPixelWitnessResult({
    required this.captured,
    required this.width,
    required this.height,
    this.centre,
    this.failure,
  });

  final bool captured;
  final int width;
  final int height;
  final PixelSample? centre;
  final String? failure;
}

class WindowPixelWitness {
  const WindowPixelWitness({required this.workDirectory});

  final String workDirectory;

  /// Photographs [windowId] and returns its centre pixel.
  ///
  /// Synchronous on purpose: the SkyLight backend calls this between run-loop
  /// slices, where an `await` could resume the isolate on a different OS
  /// thread and pump a different CFRunLoop.
  WindowPixelWitnessResult capture(int windowId, {String label = 'window'}) {
    final png = '$workDirectory/$label-$windowId.png';
    final bmp = '$workDirectory/$label-$windowId.bmp';
    Directory(workDirectory).createSync(recursive: true);

    final shot = Process.runSync(
      'screencapture',
      ['-x', '-o', '-l$windowId', png],
    );
    if (shot.exitCode != 0 || !File(png).existsSync()) {
      return WindowPixelWitnessResult(
        captured: false,
        width: 0,
        height: 0,
        failure: 'screencapture exit=${shot.exitCode} ${shot.stderr}',
      );
    }

    final convert = Process.runSync(
      'sips',
      ['-s', 'format', 'bmp', png, '--out', bmp],
    );
    if (convert.exitCode != 0 || !File(bmp).existsSync()) {
      return WindowPixelWitnessResult(
        captured: true,
        width: 0,
        height: 0,
        failure: 'sips exit=${convert.exitCode} ${convert.stderr}',
      );
    }

    return _readCentrePixel(File(bmp).readAsBytesSync());
  }
}

WindowPixelWitnessResult _readCentrePixel(Uint8List bytes) {
  if (bytes.length < 54 || bytes[0] != 0x42 || bytes[1] != 0x4D) {
    return const WindowPixelWitnessResult(
      captured: true,
      width: 0,
      height: 0,
      failure: 'not a BMP',
    );
  }
  final data = ByteData.sublistView(bytes);
  final pixelOffset = data.getUint32(10, Endian.little);
  final width = data.getInt32(18, Endian.little);
  final rawHeight = data.getInt32(22, Endian.little);
  final bitsPerPixel = data.getUint16(28, Endian.little);
  final compression = data.getUint32(30, Endian.little);
  final height = rawHeight.abs();
  final topDown = rawHeight < 0;

  if (width <= 0 || height <= 0) {
    return WindowPixelWitnessResult(
      captured: true,
      width: width,
      height: height,
      failure: 'degenerate BMP size',
    );
  }
  // 0 = BI_RGB, 3 = BI_BITFIELDS. sips emits the standard BGRA masks for the
  // latter, so both decode identically here.
  if (compression != 0 && compression != 3) {
    return WindowPixelWitnessResult(
      captured: true,
      width: width,
      height: height,
      failure: 'compressed BMP ($compression)',
    );
  }
  if (bitsPerPixel != 24 && bitsPerPixel != 32) {
    return WindowPixelWitnessResult(
      captured: true,
      width: width,
      height: height,
      failure: 'unsupported bpp $bitsPerPixel',
    );
  }

  final stride = ((width * bitsPerPixel + 31) ~/ 32) * 4;
  final x = width ~/ 2;
  final y = height ~/ 2;
  final row = topDown ? y : height - 1 - y;
  final index = pixelOffset + row * stride + x * (bitsPerPixel ~/ 8);
  if (index + 2 >= bytes.length) {
    return WindowPixelWitnessResult(
      captured: true,
      width: width,
      height: height,
      failure: 'centre pixel outside the BMP payload',
    );
  }

  return WindowPixelWitnessResult(
    captured: true,
    width: width,
    height: height,
    centre: PixelSample(bytes[index + 2], bytes[index + 1], bytes[index]),
  );
}
