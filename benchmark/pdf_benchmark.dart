import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  final bytes = File(options.path).readAsBytesSync();

  for (var index = 0; index < options.warmup; index++) {
    _run(bytes, options);
  }

  final rssBefore = ProcessInfo.currentRss;
  final samples = <String, List<int>>{};
  for (var index = 0; index < options.iterations; index++) {
    final iteration = _run(bytes, options);
    for (final entry in iteration.entries) {
      samples.putIfAbsent(entry.key, () => <int>[]).add(entry.value);
    }
  }
  final rssAfter = ProcessInfo.currentRss;

  final report = <String, Object?>{
    'file': File(options.path).absolute.path,
    'fileBytes': bytes.length,
    'warmup': options.warmup,
    'iterations': options.iterations,
    'rssBefore': rssBefore,
    'rssAfter': rssAfter,
    'rssDelta': rssAfter - rssBefore,
    'operations': <String, Object?>{
      for (final entry in samples.entries) entry.key: _statistics(entry.value),
    },
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(report);
  stdout.writeln(encoded);
  if (options.jsonPath != null) {
    File(options.jsonPath!).writeAsStringSync('$encoded\n');
  }
}

Map<String, int> _run(Uint8List bytes, _Options options) {
  final result = <String, int>{};
  late PdfDocument document;
  result['parse'] = _measure('pdf.parse', () {
    document = PdfDocument.fromBytes(bytes);
  });
  result['pageGeometry'] = _measure('pdf.page_geometry', () {
    for (final page in document.pages) {
      page.size;
    }
  });
  result['imageInventory'] = _measure('pdf.image_inventory', () {
    const PdfImageInventory().inspect(document);
  });
  result['metadataValidation'] = _measure('pdf.metadata_validation', () {
    const PdfValidator().validate(
      bytes,
      options: const PdfValidationOptions.metadataOnly(),
    );
  });
  if (options.fullValidation) {
    result['fullValidation'] = _measure('pdf.full_validation', () {
      const PdfValidator().validate(bytes);
    });
  }
  if (options.renderFirst) {
    result['renderFirst'] = _measure('pdf.render_first', () {
      document.getPage(1).renderToMemory(ignoreContentStreamErrors: true);
    });
  }
  return result;
}

int _measure(String name, void Function() action) {
  final stopwatch = Stopwatch()..start();
  Timeline.timeSync(name, action);
  return stopwatch.elapsedMicroseconds;
}

Map<String, num> _statistics(List<int> values) {
  values.sort();
  final total = values.fold<int>(0, (sum, value) => sum + value);
  return <String, num>{
    'minUs': values.first,
    'medianUs': _percentile(values, 0.50),
    'p95Us': _percentile(values, 0.95),
    'maxUs': values.last,
    'meanUs': total / values.length,
  };
}

int _percentile(List<int> sorted, double percentile) {
  final index = ((sorted.length - 1) * percentile).ceil();
  return sorted[index];
}

final class _Options {
  const _Options({
    required this.path,
    required this.warmup,
    required this.iterations,
    required this.fullValidation,
    required this.renderFirst,
    required this.jsonPath,
  });

  final String path;
  final int warmup;
  final int iterations;
  final bool fullValidation;
  final bool renderFirst;
  final String? jsonPath;

  static _Options parse(List<String> arguments) {
    if (arguments.isEmpty || arguments.contains('--help')) {
      stdout.writeln(
        'Usage: dart run benchmark/pdf_benchmark.dart <file.pdf> '
        '[--warmup=N] [--iterations=N] [--full-validation] '
        '[--render-first] [--json=report.json]',
      );
      exit(arguments.contains('--help') ? 0 : 64);
    }
    int integer(String prefix, int fallback) {
      final value =
          arguments.where((item) => item.startsWith(prefix)).firstOrNull;
      return value == null
          ? fallback
          : int.parse(value.substring(prefix.length));
    }

    String? value(String prefix) {
      final item =
          arguments.where((item) => item.startsWith(prefix)).firstOrNull;
      return item?.substring(prefix.length);
    }

    return _Options(
      path: arguments.firstWhere((item) => !item.startsWith('--')),
      warmup: integer('--warmup=', 3),
      iterations: integer('--iterations=', 10),
      fullValidation: arguments.contains('--full-validation'),
      renderFirst: arguments.contains('--render-first'),
      jsonPath: value('--json='),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
