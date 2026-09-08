import 'dart:typed_data';

import '../format/pdf_object.dart';
import 'pdf_matrix.dart';

/// Parsed tiling pattern (ISO 32000-2, PatternType 1).
final class PdfTilingPattern {
  const PdfTilingPattern._({
    required this.paintType,
    required this.tilingType,
    required this.bbox,
    required this.xStep,
    required this.yStep,
    required this.matrix,
    required this.resources,
    required this.contents,
  });

  final int paintType;
  final int tilingType;
  final List<double> bbox;
  final double xStep;
  final double yStep;
  final PdfMatrix matrix;
  final PdfDict? resources;
  final Uint8List contents;

  bool get isColored => paintType == 1;

  static PdfTilingPattern? parse(PdfObject? object, PdfResolver? resolver) {
    final resolved = object?.resolve(resolver);
    if (resolved is! PdfStream) return null;
    final dict = resolved.dict;
    if (dict.getNumber('PatternType', resolver)?.toInt() != 1) return null;
    final paintType = dict.getNumber('PaintType', resolver)?.toInt();
    final tilingType = dict.getNumber('TilingType', resolver)?.toInt();
    final bounds = dict.getArray('BBox', resolver);
    final xStep = dict.getNumber('XStep', resolver)?.toDouble();
    final yStep = dict.getNumber('YStep', resolver)?.toDouble();
    if ((paintType != 1 && paintType != 2) ||
        tilingType == null ||
        tilingType < 1 ||
        tilingType > 3 ||
        bounds == null ||
        bounds.length < 4 ||
        xStep == null ||
        yStep == null ||
        !xStep.isFinite ||
        !yStep.isFinite ||
        xStep.abs() < 1e-9 ||
        yStep.abs() < 1e-9) {
      return null;
    }
    final bbox = <double>[
      for (var i = 0; i < 4; i++)
        bounds.getNumber(i, resolver)?.toDouble() ?? double.nan,
    ];
    if (bbox.any((value) => !value.isFinite) ||
        bbox[2] <= bbox[0] ||
        bbox[3] <= bbox[1]) {
      return null;
    }
    final values = dict.getArray('Matrix', resolver);
    final matrix = values != null && values.length >= 6
        ? PdfMatrix(
            values.getNumber(0, resolver)?.toDouble() ?? 1,
            values.getNumber(1, resolver)?.toDouble() ?? 0,
            values.getNumber(2, resolver)?.toDouble() ?? 0,
            values.getNumber(3, resolver)?.toDouble() ?? 1,
            values.getNumber(4, resolver)?.toDouble() ?? 0,
            values.getNumber(5, resolver)?.toDouble() ?? 0,
          )
        : PdfMatrix.identity;
    if (matrix.invert() == null) return null;
    return PdfTilingPattern._(
      paintType: paintType!,
      tilingType: tilingType,
      bbox: List.unmodifiable(bbox),
      xStep: xStep,
      yStep: yStep,
      matrix: matrix,
      resources: dict.getDict('Resources', resolver),
      contents: resolved.getDecodedBytes(resolver),
    );
  }
}
