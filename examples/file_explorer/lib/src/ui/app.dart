/// The application widget: the theme around the window.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';
import 'explorer_window.dart';
import 'thumbnails.dart';

/// The explorer, themed.
///
/// Light or dark follows the desktop *live* unless [dark] pins it: the
/// application rebuilds every window's [MediaQuery] when the system switches
/// (`WM_SETTINGCHANGE` on Windows, AppKit's appearance notification on
/// macOS), and the theme here is picked from
/// [MediaQueryData.platformBrightness]. Outside an application - a widget
/// test that mounted the explorer with no [MediaQuery] - it is light, the
/// same answer a desktop that reports nothing gets.
class FileExplorerApp extends StatelessWidget {
  const FileExplorerApp({
    super.key,
    required this.model,
    this.dark,
    this.onReady,
    this.onClose,
    this.thumbnailLoader,
  });

  final ExplorerModel model;

  /// True or false pins the palette (`--dark`, `--light`, a screenshot tool);
  /// null follows the system.
  final bool? dark;
  final void Function(ExplorerWindowState window)? onReady;
  final void Function()? onClose;
  final ThumbnailLoader? thumbnailLoader;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.leftToRight,
        child: _FollowSystemBrightness(
          pinned: switch (dark) {
            null => null,
            true => Brightness.dark,
            false => Brightness.light,
          },
          builder: (Brightness brightness) => Theme(
            // Files and Windows 11 set their text at 14 px.
            data: (brightness == Brightness.dark
                    ? ThemeData.fluentDark
                    : ThemeData.fluentLight)
                .adaptedToPlatform()
                .copyWith(fontSize: 14),
            child: ExplorerWindow(
              model: model,
              onReady: onReady,
              onClose: onClose,
              thumbnailLoader: thumbnailLoader,
            ),
          ),
        ),
      );
}

/// Builds [builder]'s subtree for the desktop's brightness, and only rebuilds
/// it when that brightness changes.
///
/// Why not just read [MediaQuery] in [FileExplorerApp.build]: [MediaQuery]
/// here is one inherited widget for the whole query, so anything that reads
/// the brightness is also rebuilt on every step of a window resize. Rebuilt,
/// [FileExplorerApp] would hand out a new [Theme] - and a new [Theme] notifies
/// every control in the window, because its style registries are compared by
/// identity - turning a live resize into a full rebuild per frame. So this
/// widget depends on the query, and returns the *same* subtree object while
/// the brightness is unchanged; the framework skips an identical child
/// without looking inside it, which makes a resize cost this one build.
class _FollowSystemBrightness extends StatefulWidget {
  const _FollowSystemBrightness({required this.builder, this.pinned});

  /// When set, the system is not consulted at all.
  final Brightness? pinned;
  final Widget Function(Brightness brightness) builder;

  @override
  State<_FollowSystemBrightness> createState() =>
      _FollowSystemBrightnessState();
}

class _FollowSystemBrightnessState extends State<_FollowSystemBrightness> {
  Brightness? _builtFor;
  Widget? _built;

  @override
  void didUpdateWidget(_FollowSystemBrightness oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new builder may close over a new model or callback.
    _built = null;
  }

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = widget.pinned ??
        MediaQuery.maybePlatformBrightnessOf(context) ??
        Brightness.light;
    if (_built == null || brightness != _builtFor) {
      _builtFor = brightness;
      _built = widget.builder(brightness);
    }
    return _built!;
  }
}
