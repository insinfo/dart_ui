/// Reading and writing drawings: the formats, without any dialog.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import 'editor_model.dart';

/// The formats the editor writes, by extension.
const List<String> kWritableFormats = <String>['svg', 'pdf', 'cdr'];

/// The extension of [path], lower case; `svg` when it has none.
String formatOf(String path) {
  final int dot = path.lastIndexOf('.');
  final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
  if (dot < 0 || dot < slash) return 'svg';
  return path.substring(dot + 1).toLowerCase();
}

/// The file name of [path].
String basenameOf(String path) {
  final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

/// A drawing from the bytes of a file called [name]: CorelDRAW by its
/// extension, SVG otherwise.
VectorDocument readDrawing(String name, Uint8List bytes) {
  if (name.toLowerCase().endsWith('.cdr')) {
    return CdrDocument.fromBytes(bytes).toVectorDocument();
  }
  // utf8, not String.fromCharCodes: an SVG is a text file and its <title> or
  // a text element may hold anything, and reading it a byte per character
  // mangles every accented letter in it.
  return VectorSvgCodec.importFromSvg(utf8.decode(bytes, allowMalformed: true));
}

/// [session]'s drawing encoded as [format].
Uint8List encodeDrawing(DocumentSession session, String format) =>
    switch (format) {
      'svg' => Uint8List.fromList(
          utf8.encode(VectorSvgCodec.exportToSvg(session.document))),
      'pdf' => VectorPdfExporter.exportToPdf(session.document),
      'cdr' => CdrTranslator.toCdrBytes(session.document),
      _ => throw CommandError('cannot write $format; '
          'the formats are ${kWritableFormats.join(', ')}'),
    };

/// Writes [session] to [path] as [format].
///
/// Only the format the editor saves in, SVG, makes [path] the document's
/// file; a PDF or CDR export leaves the document where it was.
void writeDrawing(DocumentSession session, String path, String format) {
  File(path).writeAsBytesSync(encodeDrawing(session, format));
  if (format == 'svg') {
    session
      ..filePath = path
      ..name = basenameOf(path)
      ..modified = false;
  }
}
