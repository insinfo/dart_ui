library;

import 'dart:typed_data';

import '../../text/typeface.dart';
import 'font_registry.dart';

final class FrameworkFontLoadResult {
  const FrameworkFontLoadResult({
    required this.uiFontLoaded,
    required this.iconFontLoaded,
    required this.directory,
  });

  final bool uiFontLoaded;
  final bool iconFontLoaded;
  final String? directory;

  bool get isComplete => uiFontLoaded && iconFontLoaded;
}

FrameworkFontLoadResult installFrameworkFontBytes({
  required Uint8List uiFont,
  required Uint8List iconFont,
  required FontRegistry registry,
  String? source,
}) {
  var uiLoaded = false;
  var iconsLoaded = false;
  try {
    registry.useTypeface(
      Typeface.parse(uiFont),
      source: source == null ? 'bundled Roboto' : '$source/Roboto-Regular.ttf',
    );
    uiLoaded = true;
  } on Object {
    uiLoaded = false;
  }
  try {
    registry.registerTypeface(
      Typeface.parse(iconFont),
      family: 'Material Icons',
      source: source == null
          ? 'bundled Material Icons'
          : '$source/MaterialIcons-Regular.ttf',
    );
    iconsLoaded = true;
  } on Object {
    iconsLoaded = false;
  }
  return FrameworkFontLoadResult(
    uiFontLoaded: uiLoaded,
    iconFontLoaded: iconsLoaded,
    directory: source,
  );
}
