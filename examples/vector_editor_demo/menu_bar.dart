/// The application menu bar: the framework's [MenuBar], fed from the
/// command catalog, so every menu has submenus, keyboard navigation (Alt or
/// F10, the arrows, mnemonics), hover switching between menus, icons, check
/// marks and the platform's shortcut notation.
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
  });

  final List<EditorMenu> menus;

  /// One per menu, when something outside the bar needs to open one - a
  /// screenshot tool, a test.
  final List<MenuController> controllers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: ChromeMetrics.menuBarHeight,
      child: ColoredBox(
        color: theme.surfaceAlternate,
        child: MenuBar(
          children: <Widget>[
            for (var i = 0; i < menus.length; i++)
              SubmenuButton(
                controller: i < controllers.length ? controllers[i] : null,
                menuChildren: menuWidgets(menus[i].items),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(menus[i].label),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// [items] as menu widgets: commands, separators (`null`) and submenus.
  static List<Widget> menuWidgets(List<EditorCommand?> items) => <Widget>[
        for (final EditorCommand? item in items)
          if (item == null) const MenuDivider() else item.toMenuWidget(),
      ];
}
