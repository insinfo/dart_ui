library;

import 'dart:typed_data';

import 'font_registry.dart';
import 'framework_fonts_base.dart';

export 'framework_fonts_base.dart' show FrameworkFontLoadResult;

/// Web implementation. Network assets are asynchronous, so callers fetch the
/// two packaged files and pass their bytes to [installFromBytes].
abstract final class FrameworkFonts {
  static const String uiFamily = 'Roboto';
  static const String iconFamily = 'Material Icons';
  static const String uiFileName = 'Roboto-Regular.ttf';
  static const String iconFileName = 'MaterialIcons-Regular.ttf';

  static FrameworkFontLoadResult install({
    String? assetDirectory,
    FontRegistry? registry,
  }) =>
      const FrameworkFontLoadResult(
        uiFontLoaded: false,
        iconFontLoaded: false,
        directory: null,
      );

  static FrameworkFontLoadResult installFromBytes({
    required Uint8List uiFont,
    required Uint8List iconFont,
    FontRegistry? registry,
    String? source,
  }) =>
      installFrameworkFontBytes(
        uiFont: uiFont,
        iconFont: iconFont,
        registry: registry ?? FontRegistry.instance,
        source: source,
      );
}
