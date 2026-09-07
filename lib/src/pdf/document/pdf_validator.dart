import 'dart:convert';
import 'dart:typed_data';

import '../format/pdf_object.dart';
import '../format/pdf_xref.dart';
import '../sign/pdf_signature_inspector.dart';
import 'pdf_document.dart';

enum PdfValidationSeverity { warning, error }

final class PdfValidationIssue {
  const PdfValidationIssue(this.code, this.message, this.severity);
  final String code;
  final String message;
  final PdfValidationSeverity severity;
}

final class PdfValidationReport {
  const PdfValidationReport(this.issues, this.pageCount, this.signatureCount);
  final List<PdfValidationIssue> issues;
  final int pageCount;
  final int signatureCount;
  bool get isValid =>
      !issues.any((issue) => issue.severity == PdfValidationSeverity.error);
}

/// Bounded structural validation for parsed PDF files.
///
/// This checks syntax, references, page geometry, decoded content streams and
/// signature envelopes. It is not PDF/A conformance or certificate trust
/// validation, which require a named profile and external trust/revocation
/// data.
final class PdfValidator {
  const PdfValidator();

  PdfValidationReport validate(Uint8List bytes) {
    final issues = <PdfValidationIssue>[];
    if (bytes.length < 5 || latin1.decode(bytes.sublist(0, 5)) != '%PDF-') {
      issues.add(const PdfValidationIssue(
        'header.invalid',
        'O arquivo não começa com um cabeçalho PDF.',
        PdfValidationSeverity.error,
      ));
      return PdfValidationReport(List.unmodifiable(issues), 0, 0);
    }
    if (!latin1.decode(bytes, allowInvalid: true).contains('%%EOF')) {
      issues.add(const PdfValidationIssue(
        'eof.missing',
        'O marcador %%EOF está ausente.',
        PdfValidationSeverity.warning,
      ));
    }
    PdfDocument document;
    try {
      document = PdfDocument.fromBytes(bytes);
    } on Object catch (error) {
      issues.add(PdfValidationIssue(
        'structure.invalid',
        'A estrutura do documento não pôde ser lida: $error',
        PdfValidationSeverity.error,
      ));
      return PdfValidationReport(List.unmodifiable(issues), 0, 0);
    }
    if (document.pageCount == 0) {
      issues.add(const PdfValidationIssue(
        'pages.empty',
        'O documento não contém páginas.',
        PdfValidationSeverity.warning,
      ));
    }
    for (final page in document.pages) {
      final box = page.cropBox;
      if (!box.left.isFinite ||
          !box.top.isFinite ||
          !box.right.isFinite ||
          !box.bottom.isFinite ||
          box.width <= 0 ||
          box.height <= 0) {
        issues.add(PdfValidationIssue(
          'page.box.invalid',
          'A página ${page.pageNumber} possui uma caixa inválida.',
          PdfValidationSeverity.error,
        ));
      }
      try {
        page.getContentsBytes();
      } on Object catch (error) {
        issues.add(PdfValidationIssue(
          'page.contents.invalid',
          'O conteúdo da página ${page.pageNumber} falhou: $error',
          PdfValidationSeverity.error,
        ));
      }
    }
    for (final entry in document.xref.entries.values) {
      if (entry.type == PdfXRefEntryType.free) continue;
      try {
        final value = document.xref.resolveRef(
          PdfRef(entry.objNum, entry.genNum),
        );
        if (value == null) {
          issues.add(PdfValidationIssue(
            'xref.unresolved',
            'O objeto ${entry.objNum} não pôde ser resolvido.',
            PdfValidationSeverity.error,
          ));
        }
      } on Object catch (error) {
        issues.add(PdfValidationIssue(
          'xref.invalid',
          'O objeto ${entry.objNum} é inválido: $error',
          PdfValidationSeverity.error,
        ));
      }
    }
    var signatures = 0;
    try {
      signatures = const PdfSignatureInspector().inspect(bytes).length;
    } on FormatException catch (error) {
      issues.add(PdfValidationIssue(
        'signature.invalid',
        'Envelope de assinatura inválido: $error',
        PdfValidationSeverity.error,
      ));
    }
    return PdfValidationReport(
      List<PdfValidationIssue>.unmodifiable(issues),
      document.pageCount,
      signatures,
    );
  }
}
