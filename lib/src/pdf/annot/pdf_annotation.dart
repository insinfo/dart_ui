import 'dart:typed_data';
import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../export/pdf_canvas_recorder.dart';
import '../format/pdf_object.dart';

/// Subtipo de anotação PDF (ISO 32000).
enum PdfAnnotationSubtype {
  text('Text'),
  link('Link'),
  freeText('FreeText'),
  line('Line'),
  square('Square'),
  circle('Circle'),
  highlight('Highlight'),
  underline('Underline'),
  strikeOut('StrikeOut'),
  ink('Ink'),
  stamp('Stamp'),
  widget('Widget');

  final String pdfName;
  const PdfAnnotationSubtype(this.pdfName);
}

/// Classe base para qualquer anotação interativa em páginas PDF.
abstract class PdfAnnotation {
  final PdfAnnotationSubtype subtype;
  Rect rect;
  int color;
  String? contents;
  int flags;
  Uint8List? appearanceStreamBytes;

  PdfAnnotation({
    required this.subtype,
    required this.rect,
    this.color = 0xFFFF0000,
    this.contents,
    this.flags = 0,
    this.appearanceStreamBytes,
  });

  /// Gera ou atualiza o Appearance Stream (`/AP /N`) para que a anotação renderize em qualquer leitor.
  Uint8List generateAppearanceStream(double pageHeight);

  /// Converte a anotação em um [PdfDict] para serialização no PDF.
  PdfDict toDict(double pageHeight) {
    final apBytes = generateAppearanceStream(pageHeight);
    final apStream = PdfStream(
      PdfDict({
        'Type': const PdfName('XObject'),
        'Subtype': const PdfName('Form'),
        'BBox': PdfArray([
          const PdfNumber(0),
          const PdfNumber(0),
          PdfNumber(rect.width),
          PdfNumber(rect.height),
        ]),
        'Length': PdfNumber(apBytes.length),
      }),
      apBytes,
    );

    final dict = PdfDict({
      'Type': const PdfName('Annot'),
      'Subtype': PdfName(subtype.pdfName),
      'Rect': PdfArray([
        PdfNumber(rect.left),
        PdfNumber(pageHeight - rect.bottom),
        PdfNumber(rect.right),
        PdfNumber(pageHeight - rect.top),
      ]),
      'F': PdfNumber(flags),
      'AP': PdfDict({'N': apStream}),
    });

    if (contents != null) {
      dict['Contents'] = PdfString.fromString(contents!);
    }

    return dict;
  }
}

/// Anotação de realce de texto (Highlight).
class PdfHighlightAnnotation extends PdfAnnotation {
  final List<Rect> quadRects;

  PdfHighlightAnnotation({
    required super.rect,
    this.quadRects = const [],
    super.color = 0xFFFFFF00, // Amarelo
    super.contents,
  }) : super(
          subtype: PdfAnnotationSubtype.highlight,
        );

  @override
  Uint8List generateAppearanceStream(double pageHeight) {
    final rec = PdfCanvasRecorder(pageHeight: rect.height);
    rec.drawRect(
      Rect.fromLTWH(0, 0, rect.width, rect.height),
      fillColor: color & 0x7FFFFFFF, // Transparência a 50%
    );
    return rec.toBytes();
  }
}

/// Anotação de desenho livre à mão livre (Ink / Caneta).
class PdfInkAnnotation extends PdfAnnotation {
  final List<Path> inkPaths;
  final double strokeWidth;

  PdfInkAnnotation({
    required super.rect,
    required this.inkPaths,
    super.color = 0xFF0000FF, // Azul
    this.strokeWidth = 2.0,
    super.contents,
  }) : super(
          subtype: PdfAnnotationSubtype.ink,
        );

  @override
  Uint8List generateAppearanceStream(double pageHeight) {
    final rec = PdfCanvasRecorder(pageHeight: rect.height);
    for (final p in inkPaths) {
      rec.drawPath(p, strokeColor: color, strokeWidth: strokeWidth);
    }
    return rec.toBytes();
  }
}

/// Anotação de texto livre inserido diretamente na página.
class PdfFreeTextAnnotation extends PdfAnnotation {
  final String text;
  final double fontSize;

  PdfFreeTextAnnotation({
    required super.rect,
    required this.text,
    this.fontSize = 12.0,
    super.color = 0xFF000000,
  }) : super(
          subtype: PdfAnnotationSubtype.freeText,
          contents: text,
        );

  @override
  Uint8List generateAppearanceStream(double pageHeight) {
    final rec = PdfCanvasRecorder(pageHeight: rect.height);
    rec.drawText(text, Offset(4, rect.height - fontSize - 4),
        fontSize: fontSize, color: color);
    return rec.toBytes();
  }
}
