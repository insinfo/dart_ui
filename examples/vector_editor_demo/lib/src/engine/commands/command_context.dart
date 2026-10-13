/// What every command module is given, and the conditions they share.
///
/// A module is a function from an [EditorContext] to its commands - the
/// file commands, the layer commands, the shapes. The context is how they
/// reach the editor (dependency injection, not globals), so a module is
/// tested with a model and a host of the test's choosing, and a command
/// line runs the same modules with a host that has no dialogs.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_host.dart';
import '../editor_model.dart';

/// The editor as a command sees it.
final class EditorContext {
  const EditorContext(this.model, this.host);

  final EditorModel model;

  /// Dialogs and the window, for a command run without the parameters that
  /// would let it skip them.
  final EditorHost host;

  // --- conditions -------------------------------------------------------------
  //
  // Each answers why a command cannot run now, or null when it can: the
  // `when` of a CommandSpec. Shared, so "nothing is selected" is worded the
  // same everywhere it is said.

  String? needsDocument(CommandArgs _) =>
      model.hasDocument ? null : 'no document is open';

  String? needsSelection(CommandArgs args) =>
      needsDocument(args) ??
      (model.selection.hasSelection ? null : 'nothing is selected');

  /// At least [count] objects selected.
  String? Function(CommandArgs) needsSelected(int count) => (CommandArgs args) {
        final String? document = needsDocument(args);
        if (document != null) return document;
        final int selected = model.selection.count;
        if (selected >= count) return null;
        return 'at least $count objects must be selected; $selected '
            '${selected == 1 ? 'is' : 'are'}';
      };

  // --- helpers ----------------------------------------------------------------

  /// The selectable objects of the active layer, bottom first - what an
  /// object index in a parameter counts.
  List<SelectableObject> get layerObjects =>
      model.active.layer.children.whereType<SelectableObject>().toList();
}

/// A parameter's string that must be one of [allowed].
String oneOf(CommandArgs args, String name, List<String> allowed) {
  final String value = args.string(name);
  if (!allowed.contains(value)) {
    throw CommandError('`$name` is ${allowed.join(' or ')}; got "$value"');
  }
  return value;
}
