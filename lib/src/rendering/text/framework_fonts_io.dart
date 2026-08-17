library;

import 'dart:io';
import 'dart:typed_data';

import 'font_registry.dart';
import 'framework_fonts_base.dart';

export 'framework_fonts_base.dart' show FrameworkFontLoadResult;

/// Locates and installs the fonts distributed with dart_ui.
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

  /// Loads from a source checkout or an explicitly packaged asset directory.
  static FrameworkFontLoadResult install({
    String? assetDirectory,
    FontRegistry? registry,
  }) {
    final FontRegistry target = registry ?? FontRegistry.instance;
    final Directory? directory = _findDirectory(assetDirectory);
    if (directory == null) {
      return const FrameworkFontLoadResult(
        uiFontLoaded: false,
        iconFontLoaded: false,
        directory: null,
      );
    }
    return installFromBytes(
      uiFont: File(
        '${directory.path}${Platform.pathSeparator}$uiFileName',
      ).readAsBytesSync(),
      uiMediumFont: _readOptional(directory, uiMediumFileName),
      uiSemiBoldFont: _readOptional(directory, uiSemiBoldFileName),
      iconFont: File(
        '${directory.path}${Platform.pathSeparator}$iconFileName',
      ).readAsBytesSync(),
      tablerIconFont: _readOptional(directory, tablerIconFileName),
      phosphorIconFont: _readOptional(directory, phosphorIconFileName),
      registry: target,
      source: directory.path,
    );
  }

  /// Installs already-loaded assets. This is also the web loading contract.
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

  static Directory? _findDirectory(String? explicit) {
    final List<String> candidates = <String>[
      if (explicit != null) explicit,
      '${Directory.current.path}${Platform.pathSeparator}assets${Platform.pathSeparator}fonts',
      '${File(Platform.script.toFilePath()).parent.path}${Platform.pathSeparator}assets${Platform.pathSeparator}fonts',
    ];
    for (final String path in candidates) {
      final Directory directory = Directory(path);
      if (File('${directory.path}${Platform.pathSeparator}$uiFileName')
              .existsSync() &&
          File('${directory.path}${Platform.pathSeparator}$iconFileName')
              .existsSync()) {
        return directory;
      }
    }
    return null;
  }

  static Uint8List? _readOptional(Directory directory, String fileName) {
    final File file =
        File('${directory.path}${Platform.pathSeparator}$fileName');
    return file.existsSync() ? file.readAsBytesSync() : null;
  }
}
