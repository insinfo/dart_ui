library;

import 'dart:typed_data';

import 'font_registry.dart';
import 'framework_fonts_base.dart';

export 'framework_fonts_base.dart' show FrameworkFontLoadResult;

/// Web implementation. Network assets are asynchronous, so callers fetch the
/// two packaged files and pass their bytes to [installFromBytes].
abstract final class FrameworkFonts {
  static const String uiFamily = 'Inter';
  static const String iconFamily = 'Tabler Icons';
  static const String materialIconFamily = 'Material Icons';
  static const String phosphorIconFamily = 'Phosphor';
  static const String uiFileName = 'Inter-Regular.ttf';
  static const String uiMediumFileName = 'Inter-Medium.ttf';
  static const String uiSemiBoldFileName = 'Inter-SemiBold.ttf';
  static const String iconFileName = 'MaterialIcons-Regular.ttf';
  static const String tablerIconFileName = 'TablerIcons.ttf';
  static const String phosphorIconFileName = 'Phosphor.ttf';

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
    Uint8List? uiMediumFont,
    Uint8List? uiSemiBoldFont,
    Uint8List? tablerIconFont,
    Uint8List? phosphorIconFont,
    FontRegistry? registry,
    String? source,
  }) =>
      installFrameworkFontBytes(
        uiFont: uiFont,
        iconFont: iconFont,
        uiMediumFont: uiMediumFont,
        uiSemiBoldFont: uiSemiBoldFont,
        tablerIconFont: tablerIconFont,
        phosphorIconFont: phosphorIconFont,
        registry: registry ?? FontRegistry.instance,
        source: source,
      );
}
