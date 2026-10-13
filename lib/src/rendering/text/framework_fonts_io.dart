library;

import 'dart:io';
import 'dart:isolate';
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
  static const String fluentIconFamily = 'FluentSystemIcons';
  static const String uiFileName = 'Inter-Regular.ttf';
  static const String uiMediumFileName = 'Inter-Medium.ttf';
  static const String uiSemiBoldFileName = 'Inter-SemiBold.ttf';
  static const String iconFileName = 'MaterialIcons-Regular.ttf';
  static const String tablerIconFileName = 'TablerIcons.ttf';
  static const String phosphorIconFileName = 'Phosphor.ttf';
  static const String fluentIconFileName = 'FluentSystemIcons-Resizable.ttf';

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
      fluentIconFont: _readOptional(directory, fluentIconFileName),
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

  static Directory? _findDirectory(String? explicit) {
    final String fonts =
        '${Platform.pathSeparator}assets${Platform.pathSeparator}fonts';
    final String? environment = Platform.environment['DART_UI_FONTS'];
    final List<String> candidates = <String>[
      if (explicit != null) explicit,
      if (environment != null && environment.isNotEmpty) environment,
      // The dart_ui package itself, wherever the program's package config
      // puts it - an application in its own directory that depends on
      // dart_ui by path or from a cache. Without this the fonts were only
      // found when the program happened to run from the dart_ui checkout.
      if (_packageRoot() case final String root) '$root$fonts',
      '${Directory.current.path}$fonts',
      '${File(Platform.script.toFilePath()).parent.path}$fonts',
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

  /// The directory of the dart_ui package, from the running program's
  /// package config; null in a compiled executable, which has none.
  static String? _packageRoot() {
    try {
      final Uri? library = Isolate.resolvePackageUriSync(
          Uri.parse('package:dart_ui/dart_ui.dart'));
      if (library == null || library.scheme != 'file') return null;
      // .../dart_ui/lib/dart_ui.dart -> .../dart_ui
      return File(library.toFilePath()).parent.parent.path;
    } on Object {
      return null;
    }
  }

  static Uint8List? _readOptional(Directory directory, String fileName) {
    final File file =
        File('${directory.path}${Platform.pathSeparator}$fileName');
    return file.existsSync() ? file.readAsBytesSync() : null;
  }
}
