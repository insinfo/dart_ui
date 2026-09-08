/// The measurement behind the "Which encoder" section of `deflate.dart`.
///
/// Two modes, both of which must be run from an AOT binary - `dart run` spends
/// about six seconds front-end compiling this package before `main`, which
/// swamps everything measured here:
///
///   `dart compile exe tool/deflate_bench.dart -o BENCH`
///   `BENCH corpus`
///   `BENCH pdf caminho.pdf [runs]`
///   `BENCH built [pages] [runs]`
///
/// `corpus` re-compresses every `/FlateDecode` stream in `test/data` and
/// `referencias` with both encoders and reports throughput and total size.
/// `pdf` runs `PdfDocumentComposer.optimize` on one real document repeatedly
/// and reports the spread, which is the only number that says whether the
/// encoder is visible at the call site at all.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/graphics/image/deflate.dart';
import 'package:dart_ui/src/graphics/image/inflate.dart';

const int _plenty = 1 << 28;

List<Uint8List> _pdfStreams(String path) {
  final Uint8List file = File(path).readAsBytesSync();
  final String text = String.fromCharCodes(file);
  final List<Uint8List> streams = <Uint8List>[];
  for (final RegExpMatch match
      in RegExp(r'/Length\s+(\d+)[^>]*>>\s*stream\r?\n').allMatches(text)) {
    final int length = int.parse(match.group(1)!);
    if (match.end + length > file.length) continue;
    try {
      streams.add(inflateZlib(
        Uint8List.sublistView(file, match.end, match.end + length),
        maxOutputBytes: _plenty,
        budget: 'bench',
      ));
    } on Object {
      // Not every stream is Flate.
    }
  }
  return streams;
}

void _corpus() {
  final List<String> files = <String>[
    'test/data/sample_jpxdecode_minimal.pdf',
    'test/data/balloon_jpx.pdf',
    ...Directory('referencias')
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((File file) => file.path)
        .where((String path) => path.toLowerCase().endsWith('.pdf')),
  ];
  final List<Uint8List> streams = <Uint8List>[];
  for (final String path in files) {
    try {
      streams.addAll(_pdfStreams(path));
    } on Object {
      continue;
    }
  }
  int raw = 0;
  for (final Uint8List stream in streams) {
    raw += stream.length;
  }
  stdout.writeln('streams: ${streams.length}  raw: $raw bytes '
      '(${(raw / (1 << 20)).toStringAsFixed(1)} MiB)');

  for (final DeflateEncoder encoder in DeflateEncoder.values) {
    int total = 0;
    final Stopwatch clock = Stopwatch()..start();
    for (final Uint8List stream in streams) {
      total += deflateZlib(stream, encoder: encoder).length;
    }
    clock.stop();
    final double seconds = clock.elapsedMicroseconds / 1e6;
    stdout.writeln('${encoder.name.padRight(9)} '
        'bytes: $total  '
        'ratio: ${(total / raw).toStringAsFixed(4)}  '
        'time: ${seconds.toStringAsFixed(3)} s  '
        '${(raw / (1 << 20) / seconds).toStringAsFixed(1)} MiB/s');
  }
}

void _pdf(String path, int runs) {
  final Uint8List bytes = File(path).readAsBytesSync();
  final PdfDocument document = PdfDocument.fromBytes(bytes);
  stdout.writeln('$path  pages: ${document.pageCount}  '
      'input: ${bytes.length} bytes');
  final List<int> samples = <int>[];
  int output = 0;
  for (int run = 0; run < runs; run++) {
    final PdfDocument fresh = PdfDocument.fromBytes(bytes);
    final Stopwatch clock = Stopwatch()..start();
    final Uint8List optimized = PdfDocumentComposer.optimize(fresh);
    clock.stop();
    output = optimized.length;
    samples.add(clock.elapsedMicroseconds);
  }
  samples.sort();
  double ms(int micros) => micros / 1000;
  stdout.writeln('output: $output bytes  runs: $runs  '
      'min: ${ms(samples.first).toStringAsFixed(1)} ms  '
      'median: ${ms(samples[samples.length ~/ 2]).toStringAsFixed(1)} ms  '
      'max: ${ms(samples.last).toStringAsFixed(1)} ms');
}

/// `optimize` over a document this framework composed itself.
///
/// The distinction matters and the numbers say so: a PDF that arrives already
/// `/FlateDecode`-filtered keeps its streams untouched, so the encoder never
/// runs on most of it. A document built here has every content stream
/// uncompressed, which is the case where the encoder is the work.
void _built(int pages, int runs) {
  final PdfDocumentBuilder builder =
      PdfDocumentBuilder(title: 'bench', author: 'dart_ui');
  for (int page = 0; page < pages; page++) {
    final canvas = builder.addPage(width: 595, height: 842);
    for (int line = 0; line < 40; line++) {
      canvas.drawText(
        'pagina ${page + 1} linha $line - texto suficientemente repetido '
        'para que a compressao valha a pena',
        Offset(40, 40 + line * 20),
      );
    }
  }
  final Uint8List bytes = builder.build();
  stdout.writeln('built  pages: $pages  input: ${bytes.length} bytes');
  final List<int> samples = <int>[];
  int output = 0;
  for (int run = 0; run < runs; run++) {
    final PdfDocument fresh = PdfDocument.fromBytes(bytes);
    final Stopwatch clock = Stopwatch()..start();
    final Uint8List optimized = PdfDocumentComposer.optimize(fresh);
    clock.stop();
    output = optimized.length;
    samples.add(clock.elapsedMicroseconds);
  }
  samples.sort();
  stdout.writeln('output: $output bytes  runs: $runs  '
      'min: ${(samples.first / 1000).toStringAsFixed(1)} ms  '
      'median: ${(samples[samples.length ~/ 2] / 1000).toStringAsFixed(1)} ms  '
      'max: ${(samples.last / 1000).toStringAsFixed(1)} ms');
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: deflate_bench corpus | deflate_bench pdf <path>');
    exit(2);
  }
  switch (args.first) {
    case 'corpus':
      _corpus();
    case 'pdf':
      _pdf(args[1], args.length > 2 ? int.parse(args[2]) : 11);
    case 'built':
      _built(
        args.length > 1 ? int.parse(args[1]) : 60,
        args.length > 2 ? int.parse(args[2]) : 11,
      );
    default:
      stderr.writeln('unknown mode ${args.first}');
      exit(2);
  }
}
