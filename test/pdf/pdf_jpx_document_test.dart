@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:j2k/j2k.dart' as jp2;
import 'package:test/test.dart';

import '../../tool/make_jpx_pdf.dart';

/// A whole PDF with a `/JPXDecode` image XObject, from the parser to the
/// pixels the page renderer hands the output device.
///
/// The image XObject carries neither `/ColorSpace` nor `/BitsPerComponent`,
/// which ISO 32000-1 allows for JPX and which is what Acrobat and most
/// scanners write; the decoder has to take both from the codestream.
void main() {
  test('a small JPX image reaches the device and decodes to its pixels', () {
    final Uint8List rgb = Uint8List.fromList(<int>[
      255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, //
      0, 0, 0, 128, 128, 128, 200, 100, 50, 10, 20, 30,
    ]);
    final Uint8List image = jp2.encodeJpeg2000Pixels(
      rgb,
      width: 4,
      height: 2,
      components: 3,
      options: const jp2.Jpeg2000EncodeOptions(wrapInJp2: true),
    );
    final Uint8List pdf = buildJpxPdf(image);

    final PdfDocument document = PdfDocument.fromBytes(pdf);
    expect(document.pageCount, 1);
    final PdfPage page = document.getPage(1);
    final _CapturingDevice device = _CapturingDevice();
    page.renderTo(device);

    expect(device.images, hasLength(1));
    final _CapturedImage captured = device.images.single;
    expect(captured.width, 4);
    expect(captured.height, 2);
    expect(sniffImageFormat(captured.bytes), RasterImageFormat.jpeg2000,
        reason: 'the filter chain must pass JPX bytes through untouched');

    final DecodedImage? decoded = decodePdfImage(
      bytes: captured.bytes,
      width: captured.width,
      height: captured.height,
      dictionary: captured.dictionary,
      resolver: page.resolver,
    );
    expect(decoded, isNotNull);
    expect(decoded!.width, 4);
    expect(decoded.height, 2);
    // BGRA, premultiplied; every pixel here is opaque.
    expect(decoded.pixels.sublist(0, 4), <int>[0, 0, 255, 255]);
    expect(decoded.pixels.sublist(4, 8), <int>[0, 255, 0, 255]);
    expect(decoded.pixels.sublist(24, 28), <int>[50, 100, 200, 255]);
  });

  test('test/data/balloon_jpx.pdf renders through the JPEG 2000 decoder', () {
    final File file = File('test/data/balloon_jpx.pdf');
    expect(file.existsSync(), isTrue);
    final PdfDocument document = PdfDocument.fromBytes(file.readAsBytesSync());
    final PdfPage page = document.getPage(1);
    final _CapturingDevice device = _CapturingDevice();
    page.renderTo(device);

    expect(device.images, hasLength(1));
    final _CapturedImage captured = device.images.single;
    expect(captured.width, 2717);
    expect(captured.height, 3701);
    expect(sniffImageFormat(captured.bytes), RasterImageFormat.jpeg2000);

    final DecodedImage? decoded = decodePdfImage(
      bytes: captured.bytes,
      width: captured.width,
      height: captured.height,
      dictionary: captured.dictionary,
      resolver: page.resolver,
    );
    expect(decoded, isNotNull);
    expect(decoded!.width, 2717);
    // An engraving on cream paper with a blue and gold balloon: sampled on a
    // grid, the luminance must span most of the range and no channel may be
    // constant, which neither a blank page nor a garbled decode gives.
    var minLuma = 255;
    var maxLuma = 0;
    var blueSum = 0;
    var redSum = 0;
    var samples = 0;
    for (var y = 100; y < 3701; y += 180) {
      for (var x = 100; x < 2717; x += 130) {
        final int index = (y * 2717 + x) * 4;
        final int blue = decoded.pixels[index];
        final int green = decoded.pixels[index + 1];
        final int red = decoded.pixels[index + 2];
        final int luma = (red * 77 + green * 151 + blue * 28) >> 8;
        if (luma < minLuma) minLuma = luma;
        if (luma > maxLuma) maxLuma = luma;
        blueSum += blue;
        redSum += red;
        samples++;
      }
    }
    expect(maxLuma - minLuma, greaterThan(120),
        reason: 'luma range $minLuma..$maxLuma over $samples samples');
    expect((blueSum - redSum).abs(), greaterThan(samples * 2),
        reason: 'a grey decode would keep the channels equal');
  });
}

final class _CapturedImage {
  const _CapturedImage(this.bytes, this.width, this.height, this.dictionary);

  final Uint8List bytes;
  final int width;
  final int height;
  final PdfDict? dictionary;
}

/// Records what the page asks the device to draw; the pixels are checked
/// by calling the same decoder the rasterising devices use.
final class _CapturingDevice extends PdfMemoryOutputDevice {
  final List<_CapturedImage> images = <_CapturedImage>[];

  @override
  void drawImage(
    Uint8List imageBytes,
    int width,
    int height,
    Rect dstRect,
    PdfGfxState state, {
    PdfDict? imageDictionary,
  }) {
    images.add(_CapturedImage(imageBytes, width, height, imageDictionary));
    super.drawImage(
      imageBytes,
      width,
      height,
      dstRect,
      state,
      imageDictionary: imageDictionary,
    );
  }
}
