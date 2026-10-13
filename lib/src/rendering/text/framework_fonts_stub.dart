library;

import 'dart:typed_data';

import '../../assets/embedded_assets.dart';
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
  static const String fluentIconFamily = 'FluentSystemIcons';
  static const String uiFileName = 'Inter-Regular.ttf';
  static const String uiMediumFileName = 'Inter-Medium.ttf';
  static const String uiSemiBoldFileName = 'Inter-SemiBold.ttf';
  static const String iconFileName = 'MaterialIcons-Regular.ttf';
  static const String tablerIconFileName = 'TablerIcons.ttf';
  static const String phosphorIconFileName = 'Phosphor.ttf';
  static const String fluentIconFileName = 'FluentSystemIcons-Resizable.ttf';

  /// The key a framework font is embedded under by `dart_ui build`.
  static String embeddedKey(String fileName) => 'dart_ui/fonts/$fileName';

  /// With no file system the only fonts there can be are embedded ones.
  static FrameworkFontLoadResult install({
    String? assetDirectory,
    FontRegistry? registry,
  }) {
    final Uint8List? ui = EmbeddedAssets.bytes(embeddedKey(uiFileName));
    final Uint8List? icons = EmbeddedAssets.bytes(embeddedKey(iconFileName));
    if (ui == null || icons == null) {
      return const FrameworkFontLoadResult(
        uiFontLoaded: false,
        iconFontLoaded: false,
        directory: null,
      );
    }
    Uint8List? embedded(String fileName) =>
        EmbeddedAssets.bytes(embeddedKey(fileName));
    return installFromBytes(
      uiFont: ui,
      iconFont: icons,
      uiMediumFont: embedded(uiMediumFileName),
      uiSemiBoldFont: embedded(uiSemiBoldFileName),
      tablerIconFont: embedded(tablerIconFileName),
      phosphorIconFont: embedded(phosphorIconFileName),
      fluentIconFont: embedded(fluentIconFileName),
      registry: registry,
      source: 'embedded',
    );
  }

  static FrameworkFontLoadResult installFromBytes({
    required Uint8List uiFont,
    required Uint8List iconFont,
    Uint8List? uiMediumFont,
    Uint8List? uiSemiBoldFont,
    Uint8List? tablerIconFont,
    Uint8List? phosphorIconFont,
    Uint8List? fluentIconFont,
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
        fluentIconFont: fluentIconFont,
        registry: registry ?? FontRegistry.instance,
        source: source,
      );
}
