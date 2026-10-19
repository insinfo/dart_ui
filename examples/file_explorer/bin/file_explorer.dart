/// The file explorer, Windows 11 style (100% Dart).
///
/// ```
/// dart run bin/file_explorer.dart [folder] [--dark|--light] [--lang=pt|en]
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/strings.dart';
import 'package:file_explorer/src/io/io_file_system.dart';
import 'package:file_explorer/src/io/preferences_store.dart';
import 'package:file_explorer/src/io/thumbnail_loader.dart';
import 'package:file_explorer/src/ui/app.dart';

Future<void> main(List<String> arguments) async {
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();

  final String? lang = arguments
      .where((String a) => a.startsWith('--lang='))
      .map((String a) => a.substring(7))
      .firstOrNull;
  final ExplorerStrings strings =
      ExplorerStrings.forLocale(lang ?? Platform.localeName);
  // `--dark` and `--light` pin the palette; without either, the window
  // follows the system's appearance live (see FileExplorerApp).
  final bool? dark = arguments.contains('--dark')
      ? true
      : arguments.contains('--light')
          ? false
          : null;

  final Map<Place, String> places = <Place, String>{};
  for (final (Place place, StandardFolder folder) in <(Place, StandardFolder)>[
    (Place.home, StandardFolder.home),
    (Place.desktop, StandardFolder.desktop),
    (Place.downloads, StandardFolder.downloads),
    (Place.documents, StandardFolder.documents),
    (Place.pictures, StandardFolder.pictures),
    (Place.music, StandardFolder.music),
    (Place.videos, StandardFolder.videos),
  ]) {
    try {
      final String path = StandardPaths.resolve(folder);
      if (Directory(path).existsSync()) places[place] = path;
    } on Object {
      continue;
    }
  }

  final String? folder =
      arguments.where((String a) => !a.startsWith('--')).firstOrNull;
  final ExplorerModel model = ExplorerModel(
    fs: IoFileSystem(),
    places: places,
    strings: strings,
    start:
        folder == null ? null : FolderLocation(Directory(folder).absolute.path),
  );

  final settings = PreferencesStore(File(
      '${StandardPaths.appData}${Platform.pathSeparator}dart_ui_file_explorer${Platform.pathSeparator}preferences.json'));
  await settings.load(model, restoreSession: folder == null);
  settings.attach(model);
  final ThumbnailWorkers thumbnails = ThumbnailWorkers();
  // Closing the last tab closes the window, and the window's close - its
  // button, Cmd+W, Alt+F4 - ends the application: runApp returns once it is
  // torn down. What main opened, main closes, so the process then ends on
  // its own.
  try {
    await runApp(
      FileExplorerApp(
        model: model,
        dark: dark,
        thumbnailLoader: thumbnails.load,
      ),
      options: ApplicationOptions.fromArguments(
        arguments,
        environment: Platform.environment,
        title: strings.locale.startsWith('pt')
            ? 'Explorador de Arquivos'
            : 'File Explorer',
        size: const Size(1280, 800),
        minimumSize: const Size(640, 420),
        // The tabs take the title bar's place, as in Windows 11 and Finder.
        titleBar: WindowTitleBar.hidden,
      ),
    );
  } finally {
    thumbnails.close();
    await settings.close();
    model.dispose();
  }
}
