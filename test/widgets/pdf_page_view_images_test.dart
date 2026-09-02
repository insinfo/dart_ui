@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:j2k/j2k.dart' as jp2;
import 'package:test/test.dart';

import '../../tool/make_jpx_pdf.dart';

/// Encoded images in a page are decoded off the painting thread.
///
/// The first paint shows a placeholder where the image will be; the codec
/// runs in a background isolate and the page repaints with the pixels when
/// it is done. Packed-sample images keep decoding inline.
void main() {
  test('a JPX image paints a placeholder first and the pixels afterwards',
      () async {
    final Uint8List image = jp2.encodeJpeg2000Pixels(
      Uint8List.fromList(List<int>.filled(4 * 2 * 3, 0)..[0] = 255),
      width: 4,
      height: 2,
      components: 3,
      options: const jp2.Jpeg2000EncodeOptions(wrapInJp2: true),
    );
    final PdfPage page = PdfDocument.fromBytes(buildJpxPdf(image)).getPage(1);

    const Size viewport = Size(4, 2);
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(PdfPageView(page: page));
    addTearDown(owner.dispose);
    pipeline.flushLayout();

    int paint() {
      final DisplayList list = DisplayList();
      pipeline.flushPaint(list);
      final Framebuffer surface = Framebuffer.allocate(width: 4, height: 2)
        ..clear(0, 0, 0, 255);
      rasterizeDisplayList(list, surface);
      final int offset = surface.offsetOf(0, 0);
      return surface.pixels[offset + 3] << 24 |
          surface.pixels[offset + 2] << 16 |
          surface.pixels[offset + 1] << 8 |
          surface.pixels[offset];
    }

    // First paint: the placeholder, because the codec has not run yet.
    expect(paint(), 0xFFE6E6E6);

    // The isolate finishes and the page asks to be repainted.
    final Stopwatch waited = Stopwatch()..start();
    var pixel = paint();
    while (
        pixel != 0xFFFF0000 && waited.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      pixel = paint();
    }
    expect(pixel, 0xFFFF0000,
        reason: 'the decoded red pixel after ${waited.elapsed}');
  });
}
