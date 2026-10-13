/// The application menu bar: the framework's [PlatformMenuBar], fed from
/// the editor's menus. In the window it is a [MenuBar] - submenus, keyboard
/// navigation (Alt - F10 is the Shape tool here, as in CorelDRAW - and the
/// arrows), hover switching, icons, check marks
/// and the platform's shortcut notation; on a Mac, when the user asks, the
/// same menus go to the system's menu bar and this takes no room.
library;

import 'package:dart_ui/dart_ui.dart';

import 'metrics.dart';

/// The row of menus.
class EditorMenuBar extends StatelessWidget {
  const EditorMenuBar({super.key, required this.menus, this.native = false});

  final List<PlatformMenu> menus;

  /// Whether to use the system menu bar where there is one.
  final bool native;

  @override
  Widget build(BuildContext context) => PlatformMenuBar(
        native: native,
        height: ChromeMetrics.of(Theme.of(context)).menuBarHeight,
        menus: menus,
        f10Activates: false,
      );
}
