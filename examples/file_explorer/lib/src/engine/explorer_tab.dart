/// One tab: where it is, where it has been, what it lists and what is
/// selected in it.
library;

import 'dart:async';

import 'file_system.dart';
import 'location.dart';

/// The state of one tab. The model owns the tabs and changes them; the
/// window reads them.
final class ExplorerTab {
  ExplorerTab(this.location);

  /// Where the tab is.
  Location location;

  /// Where Back and Forward go, nearest last.
  final List<Location> back = <Location>[];
  final List<Location> forward = <Location>[];

  /// What [location] lists, as the file system reported it.
  List<FileEntry> entries = const <FileEntry>[];

  /// [entries] sorted and filtered - what the view shows, in its order.
  List<FileEntry> visible = const <FileEntry>[];

  /// The selected items, by path.
  final Set<String> selection = <String>{};

  /// The item the keyboard is on, by path.
  String? focused;

  /// The item being renamed in place, by path.
  String? renaming;

  /// Whether a listing or a search is still running.
  bool loading = false;

  /// Why the location could not be listed, or null.
  String? error;

  /// Bumped by every load, so a slow listing that finishes after the tab
  /// moved on is dropped instead of shown.
  int generation = 0;

  /// Refreshes the listing when the folder changes on disk.
  StreamSubscription<void>? watcher;

  /// The visible entries that are selected, in view order.
  List<FileEntry> get selectedEntries => <FileEntry>[
        for (final FileEntry e in visible)
          if (selection.contains(e.path)) e,
      ];

  void dispose() {
    unawaited(watcher?.cancel());
    watcher = null;
  }
}
