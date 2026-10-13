/// Every document command of the editor, by module.
///
/// "Everything is a command": what a menu item, a toolbar button, a shortcut,
/// a right-click row, a test, a script or an automation client does to a
/// drawing is one of these, run by id through [CommandRegistry.execute].
///
/// Each area is a module of its own under `commands/` - a function from an
/// [EditorContext] to its commands - so the catalogue grows by adding a
/// module, not by growing a file: VectorCraft's ~700 commands live in ~150
/// such files. A window adds its own (theme, panels) beside them; nothing
/// here imports a widget, so the same modules run under a command line.
library;

import 'package:dart_ui/commands.dart';

import 'commands/arrange_commands.dart';
import 'commands/command_context.dart';
import 'commands/document_commands.dart';
import 'commands/edit_commands.dart';
import 'commands/file_commands.dart';
import 'commands/layer_commands.dart';
import 'commands/node_commands.dart';
import 'commands/object_commands.dart';
import 'commands/selection_commands.dart';
import 'commands/shape_commands.dart';
import 'commands/shaping_commands.dart';
import 'commands/view_commands.dart';
import 'editor_host.dart';
import 'editor_model.dart';

export 'commands/command_context.dart' show EditorContext;
export 'commands/view_commands.dart' show kToolCommands, toolCommandOf;

/// A module: the commands of one area, given the editor.
typedef CommandModule = List<CommandSpec> Function(EditorContext context);

/// The editor's modules, in menu order. A new area is one more entry.
const List<CommandModule> kEditorCommandModules = <CommandModule>[
  fileCommands,
  editCommands,
  viewCommands,
  objectCommands,
  arrangeCommands,
  shapingCommands,
  nodeCommands,
  selectionCommands,
  shapeCommands,
  layerCommands,
  documentCommands,
];

/// Registers every module's commands on [registry] against [model], with
/// [host] for what needs a dialog or a window, and makes a batch one undo
/// step of the active document.
void registerEditorCommands(
  CommandRegistry registry,
  EditorModel model,
  EditorHost host,
) {
  final EditorContext context = EditorContext(model, host);
  registry.transaction = (String label, Object? Function() body) =>
      model.hasDocument ? model.active.api.history.group(label, body) : body();
  for (final CommandModule module in kEditorCommandModules) {
    final List<CommandSpec> commands = module(context);
    for (final CommandSpec command in commands) {
      if (registry.contains(command.id)) {
        throw StateError('two modules register ${command.id}');
      }
    }
    registry.registerAll(commands);
  }
}
