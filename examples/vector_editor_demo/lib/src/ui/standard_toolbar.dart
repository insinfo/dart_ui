/// The standard icon toolbar, built from command ids.
library;

import 'package:dart_ui/dart_ui.dart';

import 'metrics.dart';

/// One row of icon buttons, grouped by separators. Each button is a command:
/// its icon, its tooltip (label and shortcut, or why it is disabled) and
/// whether it can be pressed all come from the registry.
class StandardToolbar extends StatelessWidget {
  const StandardToolbar({
    super.key,
    required this.registry,
    required this.items,
  });

  final CommandRegistry registry;
  final List<MenuSpecEntry> items;

  @override
  Widget build(BuildContext context) {
    final ChromeMetrics chrome = ChromeMetrics.of(Theme.of(context));
    return Toolbar(
      height: chrome.toolbarHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: ChromeMetrics.barPadding,
        vertical: 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (final MenuSpecEntry item in items)
            if (item is CommandItem)
              _button(item, chrome)
            else
              const ToolbarDivider(height: 18, margin: 4),
        ],
      ),
    );
  }

  Widget _button(CommandItem item, ChromeMetrics chrome) {
    final CommandSpec? command = registry[item.command];
    final CommandArgs args = CommandArgs(item.params);
    final bool enabled = command?.isEnabledWith(args) ?? false;
    final String label = item.label ?? command?.labelWith(args) ?? item.command;
    final KeyGesture? shortcut = command?.shortcut;
    return IconButton(
      icon: Icon(command?.icon ?? PhosphorIcons.circle),
      iconSize: chrome.toolbarIconSize,
      padding: const EdgeInsets.all(5),
      constraints: BoxConstraints(minWidth: chrome.control, minHeight: 26),
      // A disabled command names its reason in the tooltip, so the greyed
      // button explains itself instead of just refusing.
      tooltip: enabled
          ? '$label${shortcut == null ? '' : ' (${shortcut.label()})'}'
          : '$label - ${command?.disabledReasonWith(args) ?? 'not available yet'}',
      onPressed:
          enabled ? () => registry.execute(item.command, item.params) : null,
    );
  }
}
