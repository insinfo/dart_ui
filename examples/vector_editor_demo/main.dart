/// Entry point for the Vector Editor Demo application (100% Pure Dart).
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import 'app.dart';

void main(List<String> arguments) {
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();

  final options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'Vector Editor (100% Pure Dart)',
  );

  VectorDocument? initialDoc;
  String? initialName;

  // Check if a file was passed as argument (.cdr, .svg)
  for (final arg in arguments) {
    if (!arg.startsWith('--') && File(arg).existsSync()) {
      try {
        final bytes = File(arg).readAsBytesSync();
        if (arg.toLowerCase().endsWith('.cdr')) {
          final cdrDoc = CdrDocument.fromBytes(bytes);
          initialDoc = cdrDoc.toVectorDocument();
        } else if (arg.toLowerCase().endsWith('.svg')) {
          final svgXml = File(arg).readAsStringSync();
          initialDoc = VectorSvgCodec.importFromSvg(svgXml);
        }
        if (initialDoc != null) {
          final separator = arg.lastIndexOf(RegExp(r'[\/]'));
          initialName = separator < 0 ? arg : arg.substring(separator + 1);
        }
      } catch (_) {
        // Fallback to default template if file cannot be loaded
      }
      break;
    }
  }

  runApp(
    VectorEditorApp(initialDoc: initialDoc, initialName: initialName),
    options: options,
  );
}
