/// Files dragged out of the explorer and dropped onto its folders - the
/// platform's drag, so they travel to and from other applications too.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';

/// What a drag of [paths] carries; remembers them in the model while the
/// drag runs, so a drop back into this window knows them before it lands.
DragData dragOut(ExplorerModel model, List<String> paths) {
  model.dragging = List<String>.unmodifiable(paths);
  return MemoryDragData.filePaths(paths);
}

/// A drag that started here has ended; a move done by another application
/// took the files away, so the folder is read again.
void dragEnded(ExplorerModel model, DragAction action) {
  model.dragging = null;
  if (action == DragAction.move) unawaited(model.refresh());
}

/// Ctrl (Option on a Mac) copies, Shift (Command on a Mac) moves: the two
/// conventions, so either hand works on either system.
(bool copy, bool move) _forced(Set<KeyModifier> modifiers) => (
      modifiers.contains(KeyModifier.control) ||
          modifiers.contains(KeyModifier.alt),
      modifiers.contains(KeyModifier.shift) ||
          modifiers.contains(KeyModifier.meta),
    );

DropEffect _effect(
  ExplorerModel model,
  String folder,
  List<String>? paths,
  DragSessionEvent session,
) {
  final (bool copy, bool move) = _forced(session.modifiers);
  return model.dropEffect(
    folder,
    paths,
    control: copy,
    shift: move && !copy,
    canMove: session.allowedActions.contains(DragAction.move),
  );
}

DragAction _action(DropEffect effect) => switch (effect) {
      DropEffect.copy => DragAction.copy,
      DropEffect.move => DragAction.move,
      DropEffect.none => DragAction.none,
    };

/// Whether files dragged over [folder] may drop there, and as what.
DropResponse folderDropResponse(
  ExplorerModel model,
  String folder,
  DropDetails details,
) {
  if (details.data.preferredFormat(const <String>[DragFormats.uriList]) ==
      null) {
    return const DropResponse.reject();
  }
  final DragAction action =
      _action(_effect(model, folder, model.dragging, details.session));
  if (action == DragAction.none ||
      !details.session.allowedActions.contains(action)) {
    return const DropResponse.reject();
  }
  return DropResponse(acceptedFormat: DragFormats.uriList, action: action);
}

/// Drops the dragged files into [folder].
Future<DragAction> dropIntoFolder(
  ExplorerModel model,
  String folder,
  DropDetails details,
) async {
  final List<String> paths =
      model.dragging ?? await details.data.readFilePaths();
  if (paths.isEmpty) return DragAction.none;
  final DropEffect effect = _effect(model, folder, paths, details.session);
  if (effect == DropEffect.none) return DragAction.none;
  final List<String> made =
      await model.drop(folder, paths, move: effect == DropEffect.move);
  return made.isEmpty ? DragAction.none : _action(effect);
}

/// [child] as a place files can be dropped into [folder], lit while they
/// hover - a folder in a list, a row of the sidebar.
Widget folderDropTarget({
  required ExplorerModel model,
  required String folder,
  required Widget child,
  Color? highlight,
}) =>
    DropTarget(
      formats: const <String>[DragFormats.uriList],
      accepts: (DropDetails details) =>
          folderDropResponse(model, folder, details),
      onDrop: (DropDetails details) => dropIntoFolder(model, folder, details),
      highlightColor: highlight,
      child: child,
    );
