import 'dart:convert';
import 'dart:typed_data';

import '../annot/pdf_annotation.dart';
import '../format/pdf_object.dart';
import '../sign/pdf_signature_inspector.dart';
import 'pdf_document.dart';

/// Thrown when an incremental update cannot be represented safely.
final class PdfIncrementalUpdateException implements Exception {
  const PdfIncrementalUpdateException(this.message);

  final String message;

  @override
  String toString() => 'PdfIncrementalUpdateException: $message';
}

/// Appends metadata and annotations without rewriting the original PDF bytes.
///
/// Every operation creates a new classic cross-reference section whose
/// trailer points at the previous revision through `/Prev`. Existing bytes are
/// retained byte-for-byte, which is essential for audit trails and signatures.
/// Updates to signed documents are rejected by default: although an existing
/// signature can still validate its earlier revision, it no longer covers the
/// complete file after an append. Pass [allowSignedDocumentUpdate] only after
/// the caller has obtained explicit authorization for that change.
final class PdfIncrementalWriter {
  PdfIncrementalWriter(
    this.document, {
    this.allowSignedDocumentUpdate = false,
  });

  final PdfDocument document;
  final bool allowSignedDocumentUpdate;

  /// Updates entries in the document information dictionary.
  ///
  /// A `null` value removes the entry. Other, unmentioned entries are kept.
  Uint8List updateMetadata(Map<String, String?> values) {
    if (values.isEmpty) return Uint8List.fromList(document.rawBytes);
    _checkWritable();
    final trailer = _trailer;
    final existingInfoObject = trailer['Info'];
    final existingInfo = trailer.getResolved('Info', document.xref);
    final info = PdfDict(existingInfo is PdfDict
        ? Map<String, PdfObject>.from(existingInfo.entries)
        : <String, PdfObject>{});
    for (final entry in values.entries) {
      if (entry.value == null) {
        info.entries.remove(entry.key);
      } else {
        info[entry.key] = PdfString.fromString(entry.value!);
      }
    }
    final infoRef = existingInfoObject is PdfRef
        ? existingInfoObject
        : PdfRef(_nextObjectNumber, 0);
    return _append(<PdfRef, PdfObject>{infoRef: info}, infoReference: infoRef);
  }

  /// Adds [annotation] to [pageNumber] and creates its appearance as an
  /// indirect Form XObject.
  Uint8List addAnnotation(
    PdfAnnotation annotation, {
    int pageNumber = 1,
  }) {
    _checkWritable();
    final page = document.getPage(pageNumber);
    final pageRef = page.reference;
    if (pageRef == null) {
      throw const PdfIncrementalUpdateException(
        'incremental annotation updates require an indirect page dictionary',
      );
    }
    final originalPage = document.xref.resolveRef(pageRef);
    if (originalPage is! PdfDict) {
      throw const PdfIncrementalUpdateException(
        'the target page dictionary could not be resolved',
      );
    }

    var next = _nextObjectNumber;
    final annotationRef = PdfRef(next++, 0);
    final appearanceRef = PdfRef(next, 0);
    final annotationDict = annotation.toDict(page.height);
    final appearanceDictionary = annotationDict.getDict('AP');
    final appearance = appearanceDictionary?['N'];
    if (appearance is! PdfStream) {
      throw const PdfIncrementalUpdateException(
        'the annotation did not produce a normal appearance stream',
      );
    }
    annotationDict
      ..['P'] = pageRef
      ..['AP'] = PdfDict(<String, PdfObject>{'N': appearanceRef});

    final updatedPage =
        PdfDict(Map<String, PdfObject>.from(originalPage.entries));
    final originalAnnots = originalPage['Annots'];
    final resolvedAnnots = originalPage.getResolved('Annots', document.xref);
    final annotations = resolvedAnnots is PdfArray
        ? List<PdfObject>.from(resolvedAnnots.elements)
        : <PdfObject>[];
    annotations.add(annotationRef);
    // Replacing an indirect /Annots array in the page dictionary is valid and
    // avoids mutating an object that might be shared by malformed inputs.
    updatedPage['Annots'] = PdfArray(annotations);
    if (originalAnnots is PdfNull) {
      updatedPage['Annots'] = PdfArray(<PdfObject>[annotationRef]);
    }
    return _append(<PdfRef, PdfObject>{
      pageRef: updatedPage,
      annotationRef: annotationDict,
      appearanceRef: appearance,
    });
  }

  PdfDict get _trailer {
    final trailer = document.xref.trailer;
    if (trailer == null) {
      throw const PdfIncrementalUpdateException('PDF has no usable trailer');
    }
    return trailer;
  }

  int get _nextObjectNumber {
    final declared = _trailer.getNumber('Size')?.toInt() ?? 0;
    final highest = document.xref.entries.keys.fold<int>(
      declared > 0 ? declared - 1 : 0,
      (value, object) => object > value ? object : value,
    );
    return highest + 1;
  }

  void _checkWritable() {
    if (_trailer.containsKey('Encrypt')) {
      throw const PdfIncrementalUpdateException(
        'encrypted PDFs must be decrypted before an incremental update',
      );
    }
    if (allowSignedDocumentUpdate) return;
    try {
      if (const PdfSignatureInspector().inspect(document.rawBytes).isNotEmpty) {
        throw const PdfIncrementalUpdateException(
          'PDF contains digital signatures; an appended revision would no '
          'longer be covered by the latest signature. Set '
          'allowSignedDocumentUpdate only with explicit authorization',
        );
      }
    } on PdfIncrementalUpdateException {
      rethrow;
    } on FormatException {
      throw const PdfIncrementalUpdateException(
        'PDF contains a malformed signature envelope; refusing to update it',
      );
    }
  }

  Uint8List _append(
    Map<PdfRef, PdfObject> objects, {
    PdfRef? infoReference,
  }) {
    final previousXref = _findStartXref(document.rawBytes);
    if (previousXref < 0) {
      throw const PdfIncrementalUpdateException(
        'incremental updates require a valid startxref',
      );
    }
    final output = BytesBuilder(copy: false)..add(document.rawBytes);
    if (document.rawBytes.isNotEmpty && document.rawBytes.last != 0x0a) {
      output.addByte(0x0a);
    }
    final offsets = <PdfRef, int>{};
    final ordered = objects.entries.toList()
      ..sort((a, b) => a.key.objNum.compareTo(b.key.objNum));
    for (final entry in ordered) {
      offsets[entry.key] = output.length;
      output.add(ascii.encode('${entry.key.objNum} ${entry.key.genNum} obj\n'));
      final value = entry.value;
      if (value is PdfStream) {
        final dict = PdfDict(Map<String, PdfObject>.from(value.dict.entries))
          ..['Length'] = PdfNumber(value.rawBytes.length);
        output
          ..add(ascii.encode('${_serialize(dict)}\nstream\n'))
          ..add(value.rawBytes)
          ..add(ascii.encode('\nendstream'));
      } else {
        output.add(ascii.encode(_serialize(value)));
      }
      output.add(ascii.encode('\nendobj\n'));
    }

    final xrefOffset = output.length;
    final xref = StringBuffer('xref\n');
    for (final entry in offsets.entries) {
      xref
        ..writeln('${entry.key.objNum} 1')
        ..writeln('${entry.value.toString().padLeft(10, '0')} '
            '${entry.key.genNum.toString().padLeft(5, '0')} n ');
    }
    final trailer = _trailer;
    final maxObject = offsets.keys.fold<int>(
        0,
        (value, reference) =>
            reference.objNum > value ? reference.objNum : value);
    final oldSize = trailer.getNumber('Size')?.toInt() ?? 0;
    final size = oldSize > maxObject + 1 ? oldSize : maxObject + 1;
    final root = trailer['Root'];
    if (root is! PdfRef) {
      throw const PdfIncrementalUpdateException(
        'incremental updates require an indirect catalog',
      );
    }
    xref.write('trailer\n<< /Size $size /Root $root');
    final info = infoReference ?? trailer['Info'];
    if (info != null) xref.write(' /Info ${_serialize(info)}');
    final id = trailer['ID'];
    if (id != null) xref.write(' /ID ${_serialize(id)}');
    xref
      ..write(' /Prev $previousXref >>\n')
      ..write('startxref\n$xrefOffset\n%%EOF\n');
    output.add(ascii.encode(xref.toString()));
    return output.takeBytes();
  }
}

String _serialize(PdfObject object) {
  if (object is PdfNull) return 'null';
  if (object is PdfBoolean) return object.value ? 'true' : 'false';
  if (object is PdfNumber) return _number(object.value);
  if (object is PdfName) return '/${_name(object.name)}';
  if (object is PdfRef) return object.toString();
  if (object is PdfString) {
    final hex = object.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '<$hex>';
  }
  if (object is PdfArray) {
    return '[${object.elements.map(_serialize).join(' ')}]';
  }
  if (object is PdfDict) {
    return '<< ${object.entries.entries.map((entry) => '/${_name(entry.key)} ${_serialize(entry.value)}').join(' ')} >>';
  }
  throw PdfIncrementalUpdateException(
    'cannot serialize ${object.runtimeType} inside an incremental object',
  );
}

String _name(String value) {
  const delimiters = <int>{
    0x00,
    0x09,
    0x0a,
    0x0c,
    0x0d,
    0x20,
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
    0x7d,
  };
  final result = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if (byte < 0x21 || byte > 0x7e || delimiters.contains(byte)) {
      result.write('#${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    } else {
      result.writeCharCode(byte);
    }
  }
  return result.toString();
}

String _number(num value) {
  if (!value.isFinite) {
    throw const PdfIncrementalUpdateException('PDF numbers must be finite');
  }
  if (value is int || value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value
      .toStringAsFixed(6)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

int _findStartXref(Uint8List bytes) {
  final marker = ascii.encode('startxref');
  for (var offset = bytes.length - marker.length; offset >= 0; offset--) {
    var matches = true;
    for (var index = 0; index < marker.length; index++) {
      if (bytes[offset + index] != marker[index]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    var cursor = offset + marker.length;
    while (cursor < bytes.length &&
        (bytes[cursor] == 0x20 ||
            bytes[cursor] == 0x0a ||
            bytes[cursor] == 0x0d)) {
      cursor++;
    }
    var value = 0;
    var found = false;
    while (cursor < bytes.length &&
        bytes[cursor] >= 0x30 &&
        bytes[cursor] <= 0x39) {
      found = true;
      value = value * 10 + bytes[cursor] - 0x30;
      cursor++;
    }
    return found ? value : -1;
  }
  return -1;
}
