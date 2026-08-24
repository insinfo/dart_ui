/// The standard icon toolbar, built from the command catalog.
library;

import 'package:dart_ui/dart_ui.dart';

import 'commands.dart';
import 'metrics.dart';

/// One row of icon buttons, grouped by dividers, driven by [EditorCommand]s.
class StandardToolbar extends StatelessWidget {
  const StandardToolbar({super.key, required this.commands});

  /// `null` entries become dividers, exactly as sK1's toolbar list does.
  final List<EditorCommand?> commands;

  @override
  Widget build(BuildContext context) => Toolbar(
        height: ChromeMetrics.toolbarHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: ChromeMetrics.barPadding,
          vertical: 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            for (final command in commands)
              if (command == null)
                const ToolbarDivider(height: 18, margin: 4)
              else
                IconButton(
                  icon: Icon(command.icon ?? PhosphorIcons.circle),
                  iconSize: ChromeMetrics.toolbarIconSize,
                  padding: const EdgeInsets.all(5),
                  constraints: BoxConstraints(minWidth: 26, minHeight: 26),
                  // A disabled command names its reason in the tooltip, so the
                  // greyed button explains itself instead of just refusing.
                  tooltip: command.enabled
                      ? '${command.label}'
                          '${command.shortcut == null ? '' : ' (${command.shortcut})'}'
                      : '${command.label} - ${command.disabledReason}',
                  onPressed: command.enabled ? command.onInvoke : null,
                ),
          ],
        ),
      );
}
