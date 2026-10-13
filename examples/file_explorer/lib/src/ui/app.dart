/// The application widget: the theme around the window.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';
import 'explorer_window.dart';

/// The explorer, themed.
class FileExplorerApp extends StatelessWidget {
  const FileExplorerApp({
    super.key,
    required this.model,
    this.dark = false,
    this.onReady,
    this.onClose,
  });

  final ExplorerModel model;
  final bool dark;
  final void Function(ExplorerWindowState window)? onReady;
  final void Function()? onClose;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.leftToRight,
        child: Theme(
          data: (dark ? ThemeData.fluentDark : ThemeData.fluentLight)
              .adaptedToPlatform(),
          child: ExplorerWindow(
            model: model,
            onReady: onReady,
            onClose: onClose,
          ),
        ),
      );
}
