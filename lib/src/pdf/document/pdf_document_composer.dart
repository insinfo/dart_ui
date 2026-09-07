import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../format/pdf_object.dart';
import '../sign/pdf_signature_inspector.dart';
import 'pdf_document.dart';
import 'pdf_page.dart';

/// Lossless page-level PDF merge, split and metadata editing.
///
/// Page content is not rasterized. Indirect object graphs are imported into a
/// fresh file, references are remapped, and original encoded stream bytes are
/// retained so JPEG/JPX/font data does not suffer a decode/re-encode cycle.
final class PdfDocumentComposer {
  PdfDocumentComposer({
    this.title,
    this.author,
    this.creator = 'dart_ui',
    this.compressStreams = false,
    this.allowSignatureInvalidation = false,
  });

  final String? title;
  final String? author;
  final String creator;
  final bool compressStreams;
  final bool allowSignatureInvalidation;
  final List<PdfPage> _pages = <PdfPage>[];

  void addPage(PdfPage page) {
    final annotations = page.dict.getArray('Annots', page.resolver);
    if (!allowSignatureInvalidation && annotations != null) {
      for (var index = 0; index < annotations.length; index++) {
        if (_isSignatureAnnotation(
          annotations.getResolved(index, page.resolver),
          page.resolver,
        )) {
          throw const PdfSignedDocumentModificationException();
        }
      }
    }
    _pages.add(page);
  }

  void addDocument(PdfDocument document, {Iterable<int>? pages}) {
    final signatures = const PdfSignatureInspector().inspect(document.rawBytes);
    if (signatures.isNotEmpty && !allowSignatureInvalidation) {
      throw const PdfSignedDocumentModificationException();
    }
    final selected = pages ??
        Iterable<int>.generate(document.pageCount, (index) => index + 1);
    for (final number in selected) {
      addPage(document.getPage(number));
    }
  }

  Uint8List build() => _PdfGraphWriter(
        pages: _pages,
        title: title,
        author: author,
        creator: creator,
        compressStreams: compressStreams,
        stripSignatures: allowSignatureInvalidation,
      ).build();

  static Uint8List merge(
    Iterable<PdfDocument> documents, {
    String? title,
    String? author,
    bool allowSignatureInvalidation = false,
  }) {
    final composer = PdfDocumentComposer(
      title: title,
      author: author,
      allowSignatureInvalidation: allowSignatureInvalidation,
    );
    for (final document in documents) {
      composer.addDocument(document);
    }
    return composer.build();
  }

  static List<Uint8List> split(
    PdfDocument document, {
    bool allowSignatureInvalidation = false,
  }) {
    final result = <Uint8List>[];
    for (var number = 1; number <= document.pageCount; number++) {
      final composer = PdfDocumentComposer(
        allowSignatureInvalidation: allowSignatureInvalidation,
      )..addDocument(document, pages: <int>[number]);
      result.add(composer.build());
    }
    return result;
  }

  /// Rewrites one document and Flate-compresses unfiltered streams whenever
  /// doing so actually reduces their size.
  static Uint8List optimize(
    PdfDocument document, {
    bool allowSignatureInvalidation = false,
  }) =>
      (PdfDocumentComposer(
        compressStreams: true,
        allowSignatureInvalidation: allowSignatureInvalidation,
      )..addDocument(document))
          .build();
}

final class PdfSignedDocumentModificationException implements Exception {
  const PdfSignedDocumentModificationException();

  @override
  String toString() => 'PDF contains digital signatures; rewriting it would '
      'invalidate them. Pass allowSignatureInvalidation: true explicitly.';
}

final class _PendingObject {
  const _PendingObject(this.object, this.resolver);
  final PdfObject object;
  final PdfResolver? resolver;
}

final class _PdfGraphWriter {
  _PdfGraphWriter({
    required this.pages,
    required this.title,
    required this.author,
    required this.creator,
    required this.compressStreams,
    required this.stripSignatures,
  });

  final List<PdfPage> pages;
  final String? title;
  final String? author;
  final String creator;
  final bool compressStreams;
  final bool stripSignatures;
  final List<_PendingObject?> _objects = <_PendingObject?>[null];
  final Map<(PdfResolver, int, int), int> _imported =
      <(PdfResolver, int, int), int>{};

  int _reserve() {
    _objects.add(null);
    return _objects.length - 1;
  }

  int _add(PdfObject object, PdfResolver? resolver) {
    final number = _reserve();
    _objects[number] = _PendingObject(object, resolver);
    return number;
  }

  Uint8List build() {
    final catalogNumber = _reserve();
    final pagesNumber = _reserve();
    final pageNumbers = <int>[];
    for (final page in pages) {
      final entries = Map<String, PdfObject>.from(page.dict.entries)
        ..remove('Parent')
        ..['Type'] = const PdfName('Page')
        ..['Parent'] = PdfRef(pagesNumber, 0);
      if (stripSignatures) {
        final annotations = page.dict.getArray('Annots', page.resolver);
        if (annotations != null) {
          entries['Annots'] = PdfArray(<PdfObject>[
            for (var index = 0; index < annotations.length; index++)
              if (!_isSignatureAnnotation(
                annotations.getResolved(index, page.resolver),
                page.resolver,
              ))
                annotations[index],
          ]);
        }
      }
      pageNumbers.add(_add(PdfDict(entries), page.resolver));
    }
    _objects[pagesNumber] = _PendingObject(
      PdfDict(<String, PdfObject>{
        'Type': const PdfName('Pages'),
        'Count': PdfNumber(pageNumbers.length),
        'Kids': PdfArray(<PdfObject>[
          for (final number in pageNumbers) PdfRef(number, 0),
        ]),
      }),
      null,
    );
    _objects[catalogNumber] = _PendingObject(
      PdfDict(<String, PdfObject>{
        'Type': const PdfName('Catalog'),
        'Pages': PdfRef(pagesNumber, 0),
      }),
      null,
    );
    final infoNumber = _add(
      PdfDict(<String, PdfObject>{
        if (title != null) 'Title': PdfString.fromString(title!),
        if (author != null) 'Author': PdfString.fromString(author!),
        'Creator': PdfString.fromString(creator),
        'Producer': PdfString.fromString('dart_ui PDF composer'),
      }),
      null,
    );

    // Serializing may discover more referenced objects, so this loop grows.
    final serialized = <int, Uint8List>{};
    for (var number = 1; number < _objects.length; number++) {
      final pending = _objects[number]!;
      serialized[number] = _serializeObject(pending.object, pending.resolver);
    }

    final output = BytesBuilder()
      ..add(latin1.encode('%PDF-1.7\n%\xE2\xE3\xCF\xD3\n'));
    final offsets = <int>[0];
    for (var number = 1; number < _objects.length; number++) {
      offsets.add(output.length);
      output
        ..add(ascii.encode('$number 0 obj\n'))
        ..add(serialized[number]!)
        ..add(ascii.encode('\nendobj\n'));
    }
    final xref = output.length;
    output.add(ascii.encode('xref\n0 ${_objects.length}\n'));
    output.add(ascii.encode('0000000000 65535 f \n'));
    for (final offset in offsets.skip(1)) {
      output.add(
          ascii.encode('${offset.toString().padLeft(10, '0')} 00000 n \n'));
    }
    output.add(ascii.encode(
      'trailer\n<< /Size ${_objects.length} /Root $catalogNumber 0 R '
      '/Info $infoNumber 0 R >>\nstartxref\n$xref\n%%EOF\n',
    ));
    return output.takeBytes();
  }

  Uint8List _serializeObject(PdfObject object, PdfResolver? resolver) {
    // A signature dictionary may still be reachable through an AcroForm or
    // another annotation-related object in malformed or incremental files.
    // Never copy stale CMS bytes after the caller explicitly chose to rewrite
    // a signed document.
    if (stripSignatures &&
        object is PdfDict &&
        _isSignatureDictionary(object, resolver)) {
      return Uint8List.fromList(ascii.encode('null'));
    }
    if (object is PdfStream) {
      var streamBytes = object.rawBytes;
      final dictionary = Map<String, PdfObject>.from(object.dict.entries)
        ..remove('Length');
      if (compressStreams && dictionary['Filter'] == null) {
        final compressed = const ZLibEncoder().encodeBytes(streamBytes);
        if (compressed.length < streamBytes.length) {
          streamBytes = compressed;
          dictionary['Filter'] = const PdfName('FlateDecode');
        }
      }
      dictionary['Length'] = PdfNumber(streamBytes.length);
      final output = BytesBuilder()
        ..add(ascii.encode(_serialize(PdfDict(dictionary), resolver)))
        ..add(ascii.encode('\nstream\n'))
        ..add(streamBytes)
        ..add(ascii.encode('\nendstream'));
      return output.takeBytes();
    }
    return Uint8List.fromList(ascii.encode(_serialize(object, resolver)));
  }

  String _serialize(PdfObject object, PdfResolver? resolver) {
    if (object is PdfNull) return 'null';
    if (object is PdfBoolean) return object.value ? 'true' : 'false';
    if (object is PdfNumber) return object.value.toString();
    if (object is PdfName) return '/${_escapeName(object.name)}';
    if (object is PdfString) {
      return '<${object.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}>';
    }
    if (object is PdfRef) {
      if (resolver == null) return '${object.objNum} 0 R';
      final key = (resolver, object.objNum, object.genNum);
      final existing = _imported[key];
      if (existing != null) return '$existing 0 R';
      final target = resolver.resolveRef(object);
      if (target == null) return 'null';
      final number = _reserve();
      _imported[key] = number;
      _objects[number] = _PendingObject(target, resolver);
      return '$number 0 R';
    }
    if (object is PdfArray) {
      return '[${object.elements.map((item) => _serialize(item, resolver)).join(' ')}]';
    }
    if (object is PdfStream) {
      final number = _add(object, resolver);
      return '$number 0 R';
    }
    if (object is PdfDict) {
      return '<< ${object.entries.entries.map((entry) => '/${_escapeName(entry.key)} ${_serialize(entry.value, resolver)}').join(' ')} >>';
    }
    throw UnsupportedError('cannot serialize ${object.runtimeType}');
  }

  String _escapeName(String name) => name.codeUnits.map((unit) {
        final safe = unit >= 0x21 &&
            unit <= 0x7e &&
            !const <int>[
              0x23,
              0x25,
              0x28,
              0x29,
              0x2f,
              0x3c,
              0x3e,
              0x5b,
              0x5d,
              0x7b,
              0x7d
            ].contains(unit);
        return safe
            ? String.fromCharCode(unit)
            : '#${unit.toRadixString(16).padLeft(2, '0')}';
      }).join();
}

bool _isSignatureAnnotation(PdfObject? object, PdfResolver resolver) {
  if (object is! PdfDict) return false;
  if (object.getName('FT', resolver)?.name == 'Sig') return true;
  final value = object.getResolved('V', resolver);
  return value is PdfDict && value.getName('Type', resolver)?.name == 'Sig';
}

bool _isSignatureDictionary(PdfDict object, PdfResolver? resolver) {
  if (object.getName('Type', resolver)?.name == 'Sig') return true;
  return object.containsKey('ByteRange') && object.containsKey('Contents');
}
