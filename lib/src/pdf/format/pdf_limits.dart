/// Resource and structural limits used while loading an untrusted PDF.
final class PdfLimits {
  const PdfLimits({
    this.maxObjectNesting = 100,
    this.maxCollectionItems = 1000000,
    this.maxXRefSections = 1024,
    this.maxXRefEntries = 10000000,
    this.maxObjectStreamEntries = 1000000,
    this.maxPageTreeDepth = 256,
    this.maxPages = 1000000,
  });

  final int maxObjectNesting;
  final int maxCollectionItems;
  final int maxXRefSections;
  final int maxXRefEntries;
  final int maxObjectStreamEntries;
  final int maxPageTreeDepth;
  final int maxPages;
}

/// A malformed or resource-hostile PDF rejected at a controlled boundary.
final class PdfFormatException implements Exception {
  const PdfFormatException(this.message, {this.offset});

  final String message;
  final int? offset;

  @override
  String toString() => offset == null
      ? 'PdfFormatException: $message'
      : 'PdfFormatException at byte $offset: $message';
}
