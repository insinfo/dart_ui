import 'dart:typed_data';

import '../crypto/pdf_encryption.dart';
import '../format/pdf_object.dart';
import '../format/pdf_xref.dart';
import '../sign/pdf_signature_inspector.dart';
import 'pdf_document.dart';
import 'pdf_feature_inventory.dart';

enum PdfValidationSeverity { warning, error }

/// Controls expensive validation passes independently.
///
/// Use [PdfValidationOptions.metadataOnly] to inspect very large files without
/// inflating page content/image streams or resolving every xref entry.
final class PdfValidationOptions {
  const PdfValidationOptions({
    this.validateContentStreams = true,
    this.resolveAllObjects = true,
    this.inspectSignatures = true,
    this.inspectFeatures = false,
  });

  const PdfValidationOptions.metadataOnly()
      : validateContentStreams = false,
        resolveAllObjects = false,
        inspectSignatures = false,
        inspectFeatures = false;

  final bool validateContentStreams;
  final bool resolveAllObjects;
  final bool inspectSignatures;
  final bool inspectFeatures;
}

final class PdfValidationIssue {
  const PdfValidationIssue(this.code, this.message, this.severity);
  final String code;
  final String message;
  final PdfValidationSeverity severity;
}

final class PdfValidationReport {
  const PdfValidationReport(
    this.issues,
    this.pageCount,
    this.signatureCount, [
    this.featureInventory,
  ]);
  final List<PdfValidationIssue> issues;
  final int pageCount;
  final int signatureCount;
  final PdfFeatureInventoryReport? featureInventory;
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

  PdfValidationReport validate(
    Uint8List bytes, {
    PdfValidationOptions options = const PdfValidationOptions(),
    String? password,
    PdfPasswordProvider? passwordProvider,
  }) {
    final issues = <PdfValidationIssue>[];
    if (!_startsWith(bytes, const <int>[0x25, 0x50, 0x44, 0x46, 0x2d])) {
      issues.add(const PdfValidationIssue(
        'header.invalid',
        'O arquivo não começa com um cabeçalho PDF.',
        PdfValidationSeverity.error,
      ));
      return PdfValidationReport(List.unmodifiable(issues), 0, 0);
    }
    // ISO 32000 readers locate the final EOF marker near the end. Restricting
    // this check to the tail avoids materializing a multi-gigabyte String.
    if (!_containsInTail(bytes, const <int>[0x25, 0x25, 0x45, 0x4f, 0x46])) {
      issues.add(const PdfValidationIssue(
        'eof.missing',
        'O marcador %%EOF está ausente.',
        PdfValidationSeverity.warning,
      ));
    }
    PdfDocument document;
    try {
      document = PdfDocument.fromBytes(
        bytes,
        password: password,
        passwordProvider: passwordProvider,
      );
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
      if (options.validateContentStreams) {
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
    }
    if (options.resolveAllObjects) {
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
    }
    var signatures = 0;
    if (options.inspectSignatures) {
      try {
        signatures = const PdfSignatureInspector().inspect(bytes).length;
      } on FormatException catch (error) {
        issues.add(PdfValidationIssue(
          'signature.invalid',
          'Envelope de assinatura inválido: $error',
          PdfValidationSeverity.error,
        ));
      }
    }
    PdfFeatureInventoryReport? inventory;
    if (options.inspectFeatures) {
      inventory = const PdfFeatureInventory().inspect(document);
      for (final feature in inventory.occurrences) {
        if (feature.support == PdfFeatureSupport.supported) continue;
        final location = feature.pageNumber == null
            ? ''
            : ' na página ${feature.pageNumber}';
        issues.add(PdfValidationIssue(
          'feature.${feature.support.name}.${feature.category.name}',
          '${feature.feature}$location: '
              '${feature.detail ?? 'não possui suporte completo.'}',
          feature.support == PdfFeatureSupport.unsupported
              ? PdfValidationSeverity.error
              : PdfValidationSeverity.warning,
        ));
      }
    }
    return PdfValidationReport(
      List<PdfValidationIssue>.unmodifiable(issues),
      document.pageCount,
      signatures,
      inventory,
    );
  }
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

bool _containsInTail(Uint8List bytes, List<int> pattern) {
  final start = bytes.length > 65536 ? bytes.length - 65536 : 0;
  for (var offset = bytes.length - pattern.length; offset >= start; offset--) {
    var matches = true;
    for (var index = 0; index < pattern.length; index++) {
      if (bytes[offset + index] != pattern[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
