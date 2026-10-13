/// What every command module is given, and the conditions they share.
library;

import 'package:dart_ui/commands.dart';

import '../explorer_host.dart';
import '../explorer_model.dart';

/// The explorer as a command sees it.
final class ExplorerContext {
  const ExplorerContext(this.model, this.host);

  final ExplorerModel model;
  final ExplorerHost host;

  String? needsSelection(CommandArgs _) =>
      model.selectedEntries.isEmpty ? 'nothing is selected' : null;

  String? needsFolder(CommandArgs _) =>
      model.canCreateHere ? null : 'not in a folder';

  String? needsOneSelected(CommandArgs args) =>
      needsSelection(args) ??
      (model.selectedEntries.length == 1 ? null : 'select one item');
}
