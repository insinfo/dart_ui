/// Wraps a JP2/J2K file in a one-page PDF whose only image XObject uses
/// `/JPXDecode`, so the PDF reader's JPEG 2000 path can be exercised with a
/// real file.
///
/// ```
/// dart run tool/make_jpx_pdf.dart input.jp2 output.pdf
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:j2k/j2k.dart' as jp2;

void main(List<String> args) {
  if (args.length != 2) {
    stderr
        .writeln('usage: dart run tool/make_jpx_pdf.dart input.jp2 output.pdf');
    exit(64);
  }
  final Uint8List image = File(args[0]).readAsBytesSync();
  final Uint8List pdf = buildJpxPdf(image);
  File(args[1]).writeAsBytesSync(pdf);
  final info = jp2.probeJpeg2000(image);
  print('${args[1]}: ${pdf.length} bytes, image ${info.width}x${info.height}, '
      '${info.components} component(s)');
}

/// A minimal PDF 1.5 file: catalog, page tree, one page the size of the
/// image in points, a content stream drawing it full-page, and the image
/// XObject carrying [jp2Bytes] untouched under `/JPXDecode`.
Uint8List buildJpxPdf(Uint8List jp2Bytes, {int? smaskInData}) {
  final info = jp2.probeJpeg2000(jp2Bytes);
  final int width = info.width;
  final int height = info.height;
  final String content = 'q $width 0 0 $height 0 0 cm /Im0 Do Q';
  final Uint8List contentBytes = ascii.encode(content);

  final BytesBuilder out = BytesBuilder();
  final List<int> offsets = <int>[];
  void write(String text) => out.add(latin1.encode(text));
  void startObject(int number) {
    offsets.add(out.length);
    write('$number 0 obj\n');
  }

  write('%PDF-1.5\n%\xE2\xE3\xCF\xD3\n');

  startObject(1);
  write('<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');

  startObject(2);
  write('<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');

  startObject(3);
  write('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] '
      '/Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>\n'
      'endobj\n');

  startObject(4);
  write('<< /Length ${contentBytes.length} >>\nstream\n');
  out.add(contentBytes);
  write('\nendstream\nendobj\n');

  startObject(5);
  // No /ColorSpace and no /BitsPerComponent on purpose: ISO 32000-1 lets a
  // JPX image take both from the codestream, which is the common case in the
  // wild and the one a reader must handle.
  write('<< /Type /XObject /Subtype /Image /Width $width /Height $height '
      '/Filter /JPXDecode'
      '${smaskInData == null ? '' : ' /SMaskInData $smaskInData'}'
      ' /Length ${jp2Bytes.length} >>\nstream\n');
  out.add(jp2Bytes);
  write('\nendstream\nendobj\n');

  final int xref = out.length;
  write('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
  for (final int offset in offsets) {
    write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  write('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n');
  return out.toBytes();
}
