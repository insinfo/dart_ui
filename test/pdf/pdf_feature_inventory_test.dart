import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/pdf/document/pdf_document.dart';
import 'package:dart_ui/src/pdf/document/pdf_feature_inventory.dart';
import 'package:dart_ui/src/pdf/document/pdf_validator.dart';
import 'package:test/test.dart';

void main() {
  test('inventory reports resource support without decoding streams', () {
    final bytes = _featurePdf();
    final report = const PdfFeatureInventory().inspect(
      PdfDocument.fromBytes(bytes),
    );

    expect(_feature(report, PdfFeatureCategory.font, 'Type3')?.support,
        PdfFeatureSupport.unsupported);
    expect(_feature(report, PdfFeatureCategory.filter, 'JBIG2Decode')?.support,
        PdfFeatureSupport.unsupported);
    expect(_feature(report, PdfFeatureCategory.colorSpace, 'ICCBased')?.support,
        PdfFeatureSupport.partial);
    expect(
        _feature(report, PdfFeatureCategory.pattern, 'PatternType 1')?.support,
        PdfFeatureSupport.supported);
    expect(
        _feature(report, PdfFeatureCategory.shading, 'ShadingType 6')?.support,
        PdfFeatureSupport.partial);
    expect(
        _feature(report, PdfFeatureCategory.transparency, 'blend mode')
            ?.support,
        PdfFeatureSupport.unsupported);
    expect(_feature(report, PdfFeatureCategory.annotation, 'Movie')?.support,
        PdfFeatureSupport.unsupported);
    expect(report.isFullySupported, isFalse);
  });

  test('validator opt-in makes unsupported features fail-visible', () {
    final bytes = _featurePdf();
    final ordinary = const PdfValidator().validate(
      bytes,
      options: const PdfValidationOptions(
        validateContentStreams: false,
        resolveAllObjects: false,
        inspectSignatures: false,
      ),
    );
    expect(ordinary.featureInventory, isNull);

    final preflight = const PdfValidator().validate(
      bytes,
      options: const PdfValidationOptions(
        validateContentStreams: false,
        resolveAllObjects: false,
        inspectSignatures: false,
        inspectFeatures: true,
      ),
    );
    expect(preflight.featureInventory, isNotNull);
    expect(preflight.isValid, isFalse);
    expect(
      preflight.issues,
      contains(predicate<PdfValidationIssue>(
        (issue) => issue.code == 'feature.unsupported.filter',
      )),
    );
    expect(
      preflight.issues,
      contains(predicate<PdfValidationIssue>(
        (issue) =>
            issue.code == 'feature.partial.shading' &&
            issue.severity == PdfValidationSeverity.warning,
      )),
    );
  });
}

PdfFeatureOccurrence? _feature(
  PdfFeatureInventoryReport report,
  PdfFeatureCategory category,
  String feature,
) {
  for (final occurrence in report.occurrences) {
    if (occurrence.category == category && occurrence.feature == feature) {
      return occurrence;
    }
  }
  return null;
}

Uint8List _featurePdf() {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] '
        '/Contents 4 0 R /Annots [8 0 R] /Resources << '
        '/Font << /F1 << /Type /Font /Subtype /Type3 >> >> '
        '/ColorSpace << /CS1 [/ICCBased 9 0 R] >> '
        '/Pattern << /P1 5 0 R >> /Shading << /S1 6 0 R >> '
        '/ExtGState << /GS1 << /ca 0.5 /BM /Multiply >> >> '
        '/XObject << /Im1 7 0 R >> >> >>',
    '<< /Length 0 >>\nstream\n\nendstream',
    '<< /Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 '
        '/BBox [0 0 1 1] /XStep 1 /YStep 1 /Length 0 >>\nstream\n\nendstream',
    '<< /ShadingType 6 /ColorSpace /DeviceRGB /BitsPerCoordinate 8 '
        '/BitsPerComponent 8 /BitsPerFlag 2 /Decode [0 1 0 1 0 1 0 1 0 1] '
        '/Length 0 >>\nstream\n\nendstream',
    '<< /Type /XObject /Subtype /Image /Width 1 /Height 1 '
        '/ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode '
        '/Length 0 >>\nstream\n\nendstream',
    '<< /Type /Annot /Subtype /Movie /Rect [0 0 10 10] >>',
    '<< /N 3 /Length 0 >>\nstream\n\nendstream',
  ];
  final output = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(output.toString()).length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = ascii.encode(output.toString()).length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (var i = 1; i <= objects.length; i++) {
    output.write('${offsets[i].toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF',
  );
  return Uint8List.fromList(ascii.encode(output.toString()));
}
