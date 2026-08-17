import 'dart:typed_data';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../export/pdf_canvas_recorder.dart';

/// Tipo de campo de formulário interativo PDF (AcroForms).
enum PdfFormFieldType {
  text('Tx'),
  button('Btn'),
  choice('Ch'),
  signature('Sig');

  final String pdfCode;
  const PdfFormFieldType(this.pdfCode);
}

/// Campo de formulário interativo base do PDF.
abstract class PdfFormField {
  final String name;
  final PdfFormFieldType type;
  final Rect rect;
  int flags;
  dynamic value;
  dynamic defaultValue;

  PdfFormField({
    required this.name,
    required this.type,
    required this.rect,
    this.flags = 0,
    this.value,
    this.defaultValue,
  });

  /// Gera a aparência visual do campo após preenchimento do valor.
  Uint8List generateAppearanceStream(double pageHeight);
}

/// Campo de entrada de texto (`/Tx`).
class PdfTextField extends PdfFormField {
  String get text => value?.toString() ?? '';
  set text(String val) => value = val;

  final bool isMultiline;
  final bool isPassword;
  final int? maxLength;
  final double fontSize;
  final int textColor;

  PdfTextField({
    required super.name,
    required super.rect,
    String initialText = '',
    this.isMultiline = false,
    this.isPassword = false,
    this.maxLength,
    this.fontSize = 12.0,
    this.textColor = 0xFF000000,
  }) : super(
          type: PdfFormFieldType.text,
          value: initialText,
        );

  @override
  Uint8List generateAppearanceStream(double pageHeight) {
    final rec = PdfCanvasRecorder(pageHeight: rect.height);
    rec.drawRect(
      Rect.fromLTWH(0, 0, rect.width, rect.height),
      fillColor: 0xFFFFFFFF,
      strokeColor: 0xFF94A3B8,
      strokeWidth: 1.0,
    );

    final displayText = isPassword ? '*' * text.length : text;
    if (displayText.isNotEmpty) {
      rec.drawText(
        displayText,
        Offset(4, rect.height - fontSize - 4),
        fontSize: fontSize,
        color: textColor,
      );
    }

    return rec.toBytes();
  }
}

/// Campo de botão ou caixa de seleção (`/Btn`).
class PdfButtonField extends PdfFormField {
  final bool isPushButton;
  final bool isCheckbox;
  final bool isRadio;

  bool get isChecked => value == true || value == 'Yes' || value == 'On';
  set isChecked(bool val) => value = val;

  PdfButtonField({
    required super.name,
    required super.rect,
    this.isPushButton = false,
    this.isCheckbox = true,
    this.isRadio = false,
    bool initialChecked = false,
  }) : super(
          type: PdfFormFieldType.button,
          value: initialChecked,
        );

  @override
  Uint8List generateAppearanceStream(double pageHeight) {
    final rec = PdfCanvasRecorder(pageHeight: rect.height);
    rec.drawRect(
      Rect.fromLTWH(0, 0, rect.width, rect.height),
      fillColor: 0xFFFFFFFF,
      strokeColor: 0xFF475569,
      strokeWidth: 1.5,
    );

    if (isChecked) {
      // Desenha marcação de check interno
      rec.drawLine(
        Offset(3, rect.height / 2),
        Offset(rect.width / 2 - 1, 3),
        strokeColor: 0xFF2563EB,
        strokeWidth: 2.0,
      );
      rec.drawLine(
        Offset(rect.width / 2 - 1, 3),
        Offset(rect.width - 3, rect.height - 3),
        strokeColor: 0xFF2563EB,
        strokeWidth: 2.0,
      );
    }

    return rec.toBytes();
  }
}

/// Gerenciador de formulários interativos AcroForms no documento PDF.
class PdfAcroForm {
  final Map<String, PdfFormField> _fields = {};

  Map<String, PdfFormField> get fields => _fields;

  /// Adiciona um campo ao formulário.
  void addField(PdfFormField field) {
    _fields[field.name] = field;
  }

  /// Retorna o campo pelo nome.
  PdfFormField? operator [](String name) => _fields[name];

  /// Define o valor de um campo por nome.
  void setFieldValue(String name, dynamic value) {
    final field = _fields[name];
    if (field != null) {
      field.value = value;
    }
  }

  /// Lista de todos os campos de texto.
  Iterable<PdfTextField> get textFields =>
      _fields.values.whereType<PdfTextField>();

  /// Lista de todos os botões/checkboxes.
  Iterable<PdfButtonField> get buttonFields =>
      _fields.values.whereType<PdfButtonField>();
}
