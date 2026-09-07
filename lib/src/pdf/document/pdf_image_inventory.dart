import '../format/pdf_object.dart';
import 'pdf_document.dart';

/// Metadata for one image XObject, collected without decoding its pixels.
final class PdfImageDescriptor {
  const PdfImageDescriptor({
    required this.objectNumber,
    required this.resourceNames,
    required this.pages,
    required this.width,
    required this.height,
    required this.bitsPerComponent,
    required this.filters,
    required this.encodedBytes,
  });

  /// Indirect object number, or null for an unusual direct image stream.
  final int? objectNumber;
  final Set<String> resourceNames;
  final Set<int> pages;
  final int width;
  final int height;
  final int? bitsPerComponent;
  final List<String> filters;
  final int encodedBytes;
}

/// Enumerates image XObjects without inflating, color-converting or rendering.
///
/// This is intended for fast inspection of very large PDFs. It follows nested
/// Form XObjects, deduplicates shared indirect images and never calls
/// `PdfStream.getDecodedBytes` for images.
final class PdfImageInventory {
  const PdfImageInventory();

  List<PdfImageDescriptor> inspect(PdfDocument document) {
    final found = <Object, _ImageAccumulator>{};
    for (final page in document.pages) {
      final visitedForms = <Object>{};
      _visitResources(
        page.resources,
        page.resolver,
        page.pageNumber,
        found,
        visitedForms,
      );
    }
    return List<PdfImageDescriptor>.unmodifiable(
      found.values.map((image) => image.freeze()),
    );
  }

  void _visitResources(
    PdfDict? resources,
    PdfResolver resolver,
    int pageNumber,
    Map<Object, _ImageAccumulator> found,
    Set<Object> visitedForms,
  ) {
    final xObjects = resources?.getDict('XObject', resolver);
    if (xObjects == null) return;
    for (final entry in xObjects.entries.entries) {
      final raw = entry.value;
      final key = raw is PdfRef
          ? (resolver, raw.objNum, raw.genNum)
          : (resolver, identityHashCode(raw));
      final resolved = raw.resolve(resolver);
      if (resolved is! PdfStream) continue;
      final subtype = resolved.dict.getName('Subtype', resolver)?.name;
      if (subtype == 'Image') {
        final image = found.putIfAbsent(
          key,
          () => _ImageAccumulator(
            objectNumber: raw is PdfRef ? raw.objNum : null,
            width: resolved.dict.getNumber('Width', resolver)?.toInt() ?? 0,
            height: resolved.dict.getNumber('Height', resolver)?.toInt() ?? 0,
            bitsPerComponent:
                resolved.dict.getNumber('BitsPerComponent', resolver)?.toInt(),
            filters: _filterNames(resolved.dict, resolver),
            encodedBytes: resolved.rawBytes.length,
          ),
        );
        image
          ..resourceNames.add(entry.key)
          ..pages.add(pageNumber);
      } else if (subtype == 'Form' && visitedForms.add(key)) {
        _visitResources(
          resolved.dict.getDict('Resources', resolver),
          resolver,
          pageNumber,
          found,
          visitedForms,
        );
      }
    }
  }

  List<String> _filterNames(PdfDict dictionary, PdfResolver resolver) {
    final filter = dictionary.getResolved('Filter', resolver);
    if (filter is PdfName) return <String>[filter.name];
    if (filter is PdfArray) {
      return <String>[
        for (var index = 0; index < filter.length; index++)
          if (filter.getResolved(index, resolver) case final PdfName name)
            name.name,
      ];
    }
    return const <String>[];
  }
}

final class _ImageAccumulator {
  _ImageAccumulator({
    required this.objectNumber,
    required this.width,
    required this.height,
    required this.bitsPerComponent,
    required this.filters,
    required this.encodedBytes,
  });

  final int? objectNumber;
  final Set<String> resourceNames = <String>{};
  final Set<int> pages = <int>{};
  final int width;
  final int height;
  final int? bitsPerComponent;
  final List<String> filters;
  final int encodedBytes;

  PdfImageDescriptor freeze() => PdfImageDescriptor(
        objectNumber: objectNumber,
        resourceNames: Set<String>.unmodifiable(resourceNames),
        pages: Set<int>.unmodifiable(pages),
        width: width,
        height: height,
        bitsPerComponent: bitsPerComponent,
        filters: List<String>.unmodifiable(filters),
        encodedBytes: encodedBytes,
      );
}
