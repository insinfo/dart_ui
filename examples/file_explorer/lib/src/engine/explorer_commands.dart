/// Every command of the explorer, by module.
///
/// "Everything is a command", as in Files and in the vector editor: a
/// toolbar button, a menu row, a key, a test and a script all run the same
/// command by id through [CommandRegistry.execute]. Nothing here imports a
/// widget.
library;

import 'package:dart_ui/commands.dart';

import 'commands/command_context.dart';
import 'commands/file_commands.dart';
import 'commands/navigation_commands.dart';
import 'commands/selection_commands.dart';
import 'commands/tab_commands.dart';
import 'commands/view_commands.dart';
import 'explorer_host.dart';
import 'explorer_model.dart';

export 'commands/command_context.dart' show ExplorerContext;
export 'commands/view_commands.dart' show kSortCommands, kViewModeCommands;

/// A module: the commands of one area.
typedef CommandModule = List<CommandSpec> Function(ExplorerContext context);

const List<CommandModule> kExplorerCommandModules = <CommandModule>[
  navigationCommands,
  tabCommands,
  fileCommands,
  selectionCommands,
  viewCommands,
];

/// Registers every module's commands on [registry].
void registerExplorerCommands(
    CommandRegistry registry, ExplorerModel model, ExplorerHost host) {
  final ExplorerContext context = ExplorerContext(model, host);
  for (final CommandModule module in kExplorerCommandModules) {
    for (final CommandSpec command in module(context)) {
      if (registry.contains(command.id)) {
        throw StateError('two modules register ${command.id}');
      }
      registry.register(command);
    }
  }
}
