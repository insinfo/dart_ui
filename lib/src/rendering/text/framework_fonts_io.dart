library;

import 'dart:io';
import 'dart:typed_data';

import 'font_registry.dart';
import 'framework_fonts_base.dart';

export 'framework_fonts_base.dart' show FrameworkFontLoadResult;

/// Locates and installs the fonts distributed with dart_ui.
abstract final class FrameworkFonts {
  static const String uiFamily = 'Roboto';
  static const String iconFamily = 'Material Icons';
  static const String uiFileName = 'Roboto-Regular.ttf';
  static const String iconFileName = 'MaterialIcons-Regular.ttf';

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
      iconFont: File(
        '${directory.path}${Platform.pathSeparator}$iconFileName',
      ).readAsBytesSync(),
      registry: target,
      source: directory.path,
    );
  }

  /// Installs already-loaded assets. This is also the web loading contract.
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
}
