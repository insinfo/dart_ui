import '../format/pdf_object.dart';
import 'pdf_document.dart';

enum PdfFeatureCategory {
  font,
  filter,
  colorSpace,
  pattern,
  shading,
  transparency,
  encryption,
  annotation,
}

enum PdfFeatureSupport { supported, partial, unsupported }

final class PdfFeatureOccurrence {
  const PdfFeatureOccurrence({
    required this.category,
    required this.feature,
    required this.support,
    this.pageNumber,
    this.objectNumber,
    this.detail,
  });

  final PdfFeatureCategory category;
  final String feature;
  final PdfFeatureSupport support;
  final int? pageNumber;
  final int? objectNumber;
  final String? detail;
}

final class PdfFeatureInventoryReport {
  const PdfFeatureInventoryReport(this.occurrences);
  final List<PdfFeatureOccurrence> occurrences;

  bool get isFullySupported => occurrences.every(
        (occurrence) => occurrence.support == PdfFeatureSupport.supported,
      );

  Iterable<PdfFeatureOccurrence> get partial => occurrences.where(
        (occurrence) => occurrence.support == PdfFeatureSupport.partial,
      );

  Iterable<PdfFeatureOccurrence> get unsupported => occurrences.where(
        (occurrence) => occurrence.support == PdfFeatureSupport.unsupported,
      );
}

/// Bounded, metadata-only inventory of rendering and document features.
///
/// Streams are not inflated. Form XObject resources are followed with cycle
/// and depth guards, making this suitable as a fail-visible preflight pass.
final class PdfFeatureInventory {
  const PdfFeatureInventory({this.maxResourceDepth = 32});

  final int maxResourceDepth;

  PdfFeatureInventoryReport inspect(PdfDocument document) {
    final findings = <PdfFeatureOccurrence>[];
    final seen = <String>{};

    void add(
      PdfFeatureCategory category,
      String feature,
      PdfFeatureSupport support, {
      int? page,
      PdfObject? source,
      String? detail,
    }) {
      final objectNumber = source is PdfRef ? source.objNum : null;
      final key = '$category|$feature|$support|$page|$objectNumber|$detail';
      if (!seen.add(key)) return;
      findings.add(PdfFeatureOccurrence(
        category: category,
        feature: feature,
        support: support,
        pageNumber: page,
        objectNumber: objectNumber,
        detail: detail,
      ));
    }

    final resolver = document.xref;
    final encryptionSource = resolver.trailer?['Encrypt'];
    if (encryptionSource != null) {
      final encryption = encryptionSource.resolve(resolver).asDict();
      final revision = encryption?.getNumber('R', resolver)?.toInt();
      add(
        PdfFeatureCategory.encryption,
        'Standard R${revision ?? '?'}',
        revision != null && revision >= 2 && revision <= 5
            ? PdfFeatureSupport.supported
            : revision == 6
                ? PdfFeatureSupport.partial
                : PdfFeatureSupport.unsupported,
        source: encryptionSource,
        detail: revision == 6
            ? 'Algoritmo 2.B suportado; senhas SASLprep não ASCII falham de forma segura.'
            : null,
      );
    }

    for (final page in document.pages) {
      final visitedForms = <int>{};
      _scanStreamObject(page.dict['Contents'], resolver, page.pageNumber, add);
      _scanResources(
        page.resources,
        resolver,
        page.pageNumber,
        add,
        visitedForms,
        0,
      );
      final annotations = page.dict.getArray('Annots', resolver);
      if (annotations != null) {
        for (var i = 0; i < annotations.length; i++) {
          final source = annotations[i];
          final annotation = source.resolve(resolver).asDict();
          final subtype = annotation?.getName('Subtype', resolver)?.name ?? '?';
          const known = <String>{
            'Text',
            'Link',
            'FreeText',
            'Line',
            'Square',
            'Circle',
            'Highlight',
            'Underline',
            'StrikeOut',
            'Ink',
            'Stamp',
            'Widget',
          };
          add(
            PdfFeatureCategory.annotation,
            subtype,
            known.contains(subtype)
                ? PdfFeatureSupport.partial
                : PdfFeatureSupport.unsupported,
            page: page.pageNumber,
            source: source,
            detail: known.contains(subtype)
                ? 'Estrutura reconhecida; suporte de aparência e interação depende do subtipo.'
                : null,
          );
        }
      }
    }
    return PdfFeatureInventoryReport(List.unmodifiable(findings));
  }

  void _scanResources(
    PdfDict? resources,
    PdfResolver resolver,
    int page,
    void Function(PdfFeatureCategory, String, PdfFeatureSupport,
            {int? page, PdfObject? source, String? detail})
        add,
    Set<int> visitedForms,
    int depth,
  ) {
    if (resources == null || depth > maxResourceDepth) return;
    final fonts = resources.getDict('Font', resolver);
    if (fonts != null) {
      for (final entry in fonts.entries.entries) {
        final font = entry.value.resolve(resolver).asDict();
        final subtype = font?.getName('Subtype', resolver)?.name ?? '?';
        add(PdfFeatureCategory.font, subtype, _fontSupport(subtype),
            page: page, source: entry.value);
      }
    }
    final spaces = resources.getDict('ColorSpace', resolver);
    if (spaces != null) {
      for (final entry in spaces.entries.entries) {
        final family = _familyName(entry.value, resolver);
        add(PdfFeatureCategory.colorSpace, family, _colorSupport(family),
            page: page, source: entry.value);
      }
    }
    final patterns = resources.getDict('Pattern', resolver);
    if (patterns != null) {
      for (final entry in patterns.entries.entries) {
        final pattern = entry.value.resolve(resolver);
        final type =
            pattern.asStream()?.dict.getNumber('PatternType', resolver) ??
                pattern.asDict()?.getNumber('PatternType', resolver);
        final name = 'PatternType ${type?.toInt() ?? '?'}';
        add(
          PdfFeatureCategory.pattern,
          name,
          type?.toInt() == 1
              ? PdfFeatureSupport.supported
              : type?.toInt() == 2
                  ? PdfFeatureSupport.partial
                  : PdfFeatureSupport.unsupported,
          page: page,
          source: entry.value,
        );
        _scanStreamObject(entry.value, resolver, page, add);
      }
    }
    final shadings = resources.getDict('Shading', resolver);
    if (shadings != null) {
      for (final entry in shadings.entries.entries) {
        final value = entry.value.resolve(resolver);
        final type =
            value.asStream()?.dict.getNumber('ShadingType', resolver) ??
                value.asDict()?.getNumber('ShadingType', resolver);
        final number = type?.toInt();
        add(
          PdfFeatureCategory.shading,
          'ShadingType ${number ?? '?'}',
          number == 2 || number == 3
              ? PdfFeatureSupport.supported
              : number != null && number >= 1 && number <= 7
                  ? PdfFeatureSupport.partial
                  : PdfFeatureSupport.unsupported,
          page: page,
          source: entry.value,
          detail: number != null && (number == 1 || number >= 4)
              ? 'Renderização aproximada ou limitada por tesselação.'
              : null,
        );
        _scanStreamObject(entry.value, resolver, page, add);
      }
    }
    final states = resources.getDict('ExtGState', resolver);
    if (states != null) {
      for (final entry in states.entries.entries) {
        final state = entry.value.resolve(resolver).asDict();
        if (state == null) continue;
        if (state['CA'] != null || state['ca'] != null) {
          add(PdfFeatureCategory.transparency, 'constant alpha',
              PdfFeatureSupport.supported,
              page: page, source: entry.value);
        }
        if (state['BM'] != null) {
          add(PdfFeatureCategory.transparency, 'blend mode',
              PdfFeatureSupport.unsupported,
              page: page, source: entry.value);
        }
        if (state['SMask'] != null) {
          add(PdfFeatureCategory.transparency, 'soft mask',
              PdfFeatureSupport.unsupported,
              page: page, source: entry.value);
        }
      }
    }
    final xObjects = resources.getDict('XObject', resolver);
    if (xObjects != null) {
      for (final entry in xObjects.entries.entries) {
        _scanStreamObject(entry.value, resolver, page, add);
        final stream = entry.value.resolve(resolver).asStream();
        if (stream?.dict.getName('Subtype', resolver)?.name != 'Form') continue;
        if (stream!.dict['Group'] != null) {
          add(PdfFeatureCategory.transparency, 'transparency group',
              PdfFeatureSupport.unsupported,
              page: page, source: entry.value);
        }
        final number =
            entry.value is PdfRef ? (entry.value as PdfRef).objNum : null;
        if (number != null && !visitedForms.add(number)) continue;
        _scanResources(stream.dict.getDict('Resources', resolver), resolver,
            page, add, visitedForms, depth + 1);
      }
    }
  }

  static void _scanStreamObject(
    PdfObject? source,
    PdfResolver resolver,
    int page,
    void Function(PdfFeatureCategory, String, PdfFeatureSupport,
            {int? page, PdfObject? source, String? detail})
        add,
  ) {
    if (source == null) return;
    final resolved = source.resolve(resolver);
    if (resolved is PdfArray) {
      for (final item in resolved.elements) {
        _scanStreamObject(item, resolver, page, add);
      }
      return;
    }
    final stream = resolved.asStream();
    if (stream == null) return;
    final filter = stream.dict.getResolved('Filter', resolver);
    final names = <String>[];
    if (filter is PdfName) names.add(filter.name);
    if (filter is PdfArray) {
      for (final value in filter.elements) {
        final name = value.resolve(resolver);
        if (name is PdfName) names.add(name.name);
      }
    }
    for (final name in names) {
      add(PdfFeatureCategory.filter, name, _filterSupport(name),
          page: page, source: source);
    }
  }

  static String _familyName(PdfObject source, PdfResolver resolver) {
    final value = source.resolve(resolver);
    if (value is PdfName) return value.name;
    if (value is PdfArray && value.length > 0) {
      return (value.getResolved(0, resolver) as PdfName?)?.name ?? '?';
    }
    return '?';
  }

  static PdfFeatureSupport _fontSupport(String name) => switch (name) {
        'Type1' || 'TrueType' => PdfFeatureSupport.supported,
        'Type0' => PdfFeatureSupport.partial,
        _ => PdfFeatureSupport.unsupported,
      };

  static PdfFeatureSupport _filterSupport(String name) => switch (name) {
        'FlateDecode' ||
        'Fl' ||
        'LZWDecode' ||
        'LZW' ||
        'ASCII85Decode' ||
        'A85' ||
        'ASCIIHexDecode' ||
        'AHx' ||
        'RunLengthDecode' ||
        'RL' ||
        'CCITTFaxDecode' ||
        'CCF' ||
        'DCTDecode' ||
        'DCT' ||
        'JPXDecode' ||
        'Crypt' =>
          PdfFeatureSupport.supported,
        'JBIG2Decode' => PdfFeatureSupport.unsupported,
        _ => PdfFeatureSupport.unsupported,
      };

  static PdfFeatureSupport _colorSupport(String name) => switch (name) {
        'DeviceGray' ||
        'G' ||
        'DeviceRGB' ||
        'RGB' ||
        'DeviceCMYK' ||
        'CMYK' ||
        'CalGray' ||
        'CalRGB' ||
        'Lab' ||
        'Indexed' ||
        'I' =>
          PdfFeatureSupport.supported,
        'ICCBased' ||
        'Separation' ||
        'DeviceN' ||
        'Pattern' =>
          PdfFeatureSupport.partial,
        _ => PdfFeatureSupport.unsupported,
      };
}
