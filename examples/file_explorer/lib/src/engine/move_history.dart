/// Session-local undo for renames and moves; no target is overwritten.
library;

import 'file_system.dart';

typedef MovedPath = (String from, String to);

final class MoveHistory {
  MoveHistory(this.fs);
  final FileSystem fs;
  final _undo = <List<MovedPath>>[];
  final _redo = <List<MovedPath>>[];
  bool busy = false;
  bool get canUndo => !busy && _undo.isNotEmpty;
  bool get canRedo => !busy && _redo.isNotEmpty;

  void record(List<MovedPath> paths) {
    if (busy || paths.isEmpty) return;
    _undo.add(List.of(paths));
    _redo.clear();
    if (_undo.length > 100) _undo.removeAt(0);
  }

  Future<void> run({bool redo = false}) async {
    if (busy) {
      throw const FileSystemError('An undo operation is already running');
    }
    final source = redo ? _redo : _undo;
    final destination = redo ? _undo : _redo;
    if (source.isEmpty) return;
    final action = source.last;
    final work =
        redo ? action : action.reversed.map((p) => (p.$2, p.$1)).toList();
    busy = true;
    final completed = <MovedPath>[];
    try {
      for (final (from, to) in work) {
        if (await fs.stat(from) == null) {
          throw FileSystemError('Undo source no longer exists', from);
        }
        if (await fs.stat(to) != null) {
          throw FileSystemError('Undo destination already exists', to);
        }
        await fs.move(from, to);
        completed.add((from, to));
      }
      source.removeLast();
      destination.add(action);
    } on Object {
      for (final (from, to) in completed.reversed) {
        await fs.move(to, from);
      }
      rethrow;
    } finally {
      busy = false;
    }
  }
}
