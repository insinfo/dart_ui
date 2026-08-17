import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('Anotações e Formulários Interativos (AcroForms)', () {
    test('PdfHighlightAnnotation gera Appearance Stream correto', () {
      final annot = PdfHighlightAnnotation(
        rect: const Rect.fromLTWH(50, 100, 200, 20),
        color: 0xFFFFFF00,
        contents: 'Texto destacado',
      );

      final apBytes = annot.generateAppearanceStream(792.0);
      expect(apBytes, isNotEmpty);

      final dict = annot.toDict(792.0);
      expect(dict['Subtype']?.asName()?.name, 'Highlight');
      expect(
          dict['Contents']?.asPdfString()?.toUtf8String(), 'Texto destacado');
    });

    test('PdfTextField manipula valores e gera aparência visual', () {
      final field = PdfTextField(
        name: 'nome_cliente',
        rect: const Rect.fromLTWH(100, 200, 300, 30),
        initialText: 'Carlos Silva',
      );

      expect(field.name, 'nome_cliente');
      expect(field.text, 'Carlos Silva');

      field.text = 'Maria Santos';
      expect(field.text, 'Maria Santos');

      final apBytes = field.generateAppearanceStream(792.0);
      expect(apBytes, isNotEmpty);
    });

    test('PdfButtonField atua como checkbox interativo', () {
      final btn = PdfButtonField(
        name: 'aceito_termos',
        rect: const Rect.fromLTWH(50, 300, 20, 20),
        initialChecked: false,
      );

      expect(btn.isChecked, isFalse);
      btn.isChecked = true;
      expect(btn.isChecked, isTrue);

      final apBytes = btn.generateAppearanceStream(792.0);
      expect(apBytes, isNotEmpty);
    });

    test('PdfAcroForm gerencia coleção de campos por nome', () {
      final form = PdfAcroForm();
      final txt =
          PdfTextField(name: 'email', rect: const Rect.fromLTWH(0, 0, 100, 20));
      final chk = PdfButtonField(
          name: 'newsletter', rect: const Rect.fromLTWH(0, 0, 20, 20));

      form.addField(txt);
      form.addField(chk);

      expect(form['email'], isA<PdfTextField>());
      expect(form['newsletter'], isA<PdfButtonField>());

      form.setFieldValue('email', 'contato@empresa.com');
      expect((form['email'] as PdfTextField).text, 'contato@empresa.com');
    });
  });
}
