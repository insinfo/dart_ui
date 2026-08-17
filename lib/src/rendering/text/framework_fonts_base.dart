library;

import 'dart:typed_data';

import '../../text/typeface.dart';
import 'font_registry.dart';

final class FrameworkFontLoadResult {
  const FrameworkFontLoadResult({
    required this.uiFontLoaded,
    required this.iconFontLoaded,
    this.uiVariantFontsLoaded = 0,
    this.tablerIconFontLoaded = false,
    required this.directory,
  });

  final bool uiFontLoaded;
  final bool iconFontLoaded;
  final int uiVariantFontsLoaded;
  final bool tablerIconFontLoaded;
  final String? directory;

  bool get isComplete => uiFontLoaded && iconFontLoaded && tablerIconFontLoaded;
}

FrameworkFontLoadResult installFrameworkFontBytes({
  required Uint8List uiFont,
  required Uint8List iconFont,
  Uint8List? uiMediumFont,
  Uint8List? uiSemiBoldFont,
  Uint8List? tablerIconFont,
  required FontRegistry registry,
  String? source,
}) {
  var uiLoaded = false;
  var iconsLoaded = false;
  var uiVariantsLoaded = 0;
  var tablerLoaded = false;
  try {
    registry.useTypeface(
      Typeface.parse(uiFont),
      source: source == null ? 'bundled Inter' : '$source/Inter-Regular.ttf',
    );
    uiLoaded = true;
  } on Object {
    uiLoaded = false;
  }
  for (final ({Uint8List? bytes, String fileName}) variant
      in <({Uint8List? bytes, String fileName})>[
    (bytes: uiMediumFont, fileName: 'Inter-Medium.ttf'),
    (bytes: uiSemiBoldFont, fileName: 'Inter-SemiBold.ttf'),
  ]) {
    final Uint8List? bytes = variant.bytes;
    if (bytes == null) continue;
    try {
      registry.registerTypeface(
        Typeface.parse(bytes),
        family: 'Inter',
        source: source == null
            ? 'bundled ${variant.fileName}'
            : '$source/${variant.fileName}',
      );
      uiVariantsLoaded++;
    } on Object {
      // A missing optional weight must not discard the usable regular face.
    }
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
  if (tablerIconFont != null) {
    try {
      registry.registerTypeface(
        Typeface.parse(tablerIconFont),
        family: 'Tabler Icons',
        source:
            source == null ? 'bundled Tabler Icons' : '$source/TablerIcons.ttf',
      );
      tablerLoaded = true;
    } on Object {
      tablerLoaded = false;
    }
  }
  return FrameworkFontLoadResult(
    uiFontLoaded: uiLoaded,
    iconFontLoaded: iconsLoaded,
    uiVariantFontsLoaded: uiVariantsLoaded,
    tablerIconFontLoaded: tablerLoaded,
    directory: source,
  );
}
