/// The application menu bar: the framework's [PlatformMenuBar], fed from
/// the command catalog. In the window it is a [MenuBar] - submenus, keyboard
/// navigation (Alt or F10, the arrows), hover switching, icons, check marks
/// and the platform's shortcut notation; on a Mac, when the user asks, the
/// same menus go to the system's menu bar and this takes no room.
library;

import 'package:dart_ui/dart_ui.dart';

import 'commands.dart';
import 'metrics.dart';

/// The row of menus.
class EditorMenuBar extends StatelessWidget {
  const EditorMenuBar({
    super.key,
    required this.menus,
    this.controllers = const <MenuController>[],
    this.native = false,
  });

  final List<EditorMenu> menus;

  /// One per menu, when something outside the bar needs to open one - a
  /// screenshot tool, a test.
  final List<MenuController> controllers;

  /// Whether to use the system menu bar where there is one.
  final bool native;

  @override
  Widget build(BuildContext context) => PlatformMenuBar(
        native: native,
        height: ChromeMetrics.menuBarHeight,
        menus: <PlatformMenu>[
          for (var i = 0; i < menus.length; i++)
            menus[i].toPlatformMenu(
              controller: i < controllers.length ? controllers[i] : null,
            ),
        ],
      );
}
