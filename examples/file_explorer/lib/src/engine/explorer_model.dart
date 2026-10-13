/// The explorer's state and everything that changes it - tabs, navigation,
/// selection, the clipboard of files, and the file operations - with no
/// widget in it. A window shows it; a test drives it against a
/// [MemoryFileSystem]; a script could run it with no window at all.
library;

import 'dart:async';

import 'explorer_tab.dart';
import 'file_system.dart';
import 'file_types.dart';
import 'location.dart';
import 'sorting.dart';
import 'strings.dart';

/// Files cut or copied, waiting for Paste.
final class FileClipboard {
  const FileClipboard(this.paths, {required this.cut});

  final List<String> paths;

  /// Cut moves on paste; copy copies.
  final bool cut;
}

/// The explorer.
final class ExplorerModel {
  ExplorerModel({
    required this.fs,
    required this.places,
    this.strings = ExplorerStrings.english,
    Location? start,
  }) {
    pinned = <String>[
      for (final Place place in const <Place>[
        Place.desktop,
        Place.downloads,
        Place.documents,
        Place.pictures,
        Place.music,
        Place.videos,
      ])
        if (places[place] != null) places[place]!,
    ];
    tabs.add(ExplorerTab(start ?? const HomeLocation()));
  }

  final FileSystem fs;

  /// The known folders: where Desktop, Downloads... are on this machine.
  final Map<Place, String> places;

  final ExplorerStrings strings;

  final List<ExplorerTab> tabs = <ExplorerTab>[];
  int activeIndex = 0;

  ExplorerTab get tab => tabs[activeIndex];

  /// Locations of the tabs closed, last closed last - Ctrl+Shift+T.
  final List<Location> closedTabs = <Location>[];

  ViewMode viewMode = ViewMode.details;
  SortField sortField = SortField.name;
  bool ascending = true;
  bool showHidden = false;

  /// File Explorer's "File name extensions": off hides the extension of a
  /// known type only - `report.pdf` reads "report", `data.xyz` stays whole.
  bool showExtensions = true;

  /// "Hide protected operating system files", inverted: system files appear
  /// only with this on, hidden items shown or not.
  bool showProtected = false;

  /// The columns Details shows, in order.
  final List<DetailsColumn> columns = <DetailsColumn>[
    DetailsColumn.name,
    DetailsColumn.dateModified,
    DetailsColumn.type,
    DetailsColumn.size,
  ];

  /// Shows or hides [column]; Name stays.
  void toggleColumn(DetailsColumn column) {
    if (column == DetailsColumn.name) return;
    if (!columns.remove(column)) {
      columns
        ..add(column)
        ..sort(
            (DetailsColumn a, DetailsColumn b) => a.index.compareTo(b.index));
    }
    notify();
  }

  /// [entry]'s name as the view shows it.
  String shownName(FileEntry entry) =>
      showExtensions || !isKnownType(entry) ? entry.name : entry.stem;

  bool _shows(FileEntry e) =>
      (!e.isHidden || showHidden) && (!e.isSystem || showProtected);
  bool navigationPane = true;
  bool detailsPane = false;

  /// The folders pinned to Quick access.
  late List<String> pinned;

  /// Files opened, most recent first.
  final List<FileEntry> recent = <FileEntry>[];

  /// The drives, as last read.
  List<Volume> volumes = const <Volume>[];

  FileClipboard? clipboard;

  /// What the last operation said - an error, or what it did.
  String? message;

  // --- change notification ----------------------------------------------------

  final List<void Function()> _listeners = <void Function()>[];

  /// Called after every change, so a window rebuilds.
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notify() {
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Completes when the active tab has finished loading - what a test waits
  /// on after a navigation.
  Future<void> get idle => _pending ?? Future<void>.value();
  Future<void>? _pending;

  // --- where things are -------------------------------------------------------

  /// The folder the active tab is in, or null for Home and This PC.
  String? get currentFolder => folderOf(tab.location);

  String? folderOf(Location location) => switch (location) {
        FolderLocation(:final String path) => path,
        SearchLocation(:final String root) => root,
        _ => null,
      };

  /// The name a tab and the address bar give [location].
  String titleOf(Location location) => switch (location) {
        HomeLocation() => strings.home,
        ThisPcLocation() => strings.thisPc,
        FolderLocation(:final String path) => _nameOfFolder(path),
        SearchLocation(:final String root, :final String query) =>
          '$query - ${strings.searchResults} ${_nameOfFolder(root)}',
      };

  String _nameOfFolder(String path) {
    for (final MapEntry<Place, String> place in places.entries) {
      if (place.value == path) return placeName(place.key);
    }
    return fs.nameOf(path);
  }

  /// The localized name of a known folder.
  String placeName(Place place) => switch (place) {
        Place.home => fs.nameOf(places[Place.home] ?? strings.home),
        Place.desktop => strings.desktop,
        Place.downloads => strings.downloads,
        Place.documents => strings.documents,
        Place.pictures => strings.pictures,
        Place.music => strings.music,
        Place.videos => strings.videos,
      };

  /// The known folder at [path], if it is one.
  Place? placeAt(String path) {
    for (final MapEntry<Place, String> place in places.entries) {
      if (place.value == path) return place.key;
    }
    return null;
  }

  // --- navigation -------------------------------------------------------------

  bool get canGoBack => tab.back.isNotEmpty;
  bool get canGoForward => tab.forward.isNotEmpty;
  bool get canGoUp => switch (tab.location) {
        // Above a root is This PC.
        FolderLocation() || SearchLocation() => true,
        _ => false,
      };

  /// Shows [to] in the active tab, remembering where it was.
  Future<void> navigate(Location to) {
    final ExplorerTab t = tab;
    if (t.location == to) return refresh();
    t.back.add(t.location);
    t.forward.clear();
    t.location = to;
    return _load(t);
  }

  Future<void> goBack() {
    final ExplorerTab t = tab;
    if (t.back.isEmpty) return idle;
    t.forward.add(t.location);
    t.location = t.back.removeLast();
    return _load(t);
  }

  Future<void> goForward() {
    final ExplorerTab t = tab;
    if (t.forward.isEmpty) return idle;
    t.back.add(t.location);
    t.location = t.forward.removeLast();
    return _load(t);
  }

  /// The folder above, This PC above a drive, the searched folder above a
  /// search.
  Future<void> goUp() {
    final Location at = tab.location;
    final String? folder = switch (at) {
      FolderLocation(:final String path) => path,
      _ => null,
    };
    if (at is SearchLocation) return navigate(FolderLocation(at.root));
    if (folder == null) return idle;
    final String? parent = fs.parentOf(folder);
    return navigate(
            parent == null ? const ThisPcLocation() : FolderLocation(parent))
        .then((_) {
      // Coming up out of a folder selects it, as Explorer does.
      if (tab.visible.any((FileEntry e) => e.path == folder)) {
        tab.selection
          ..clear()
          ..add(folder);
        tab.focused = folder;
        notify();
      }
    });
  }

  Future<void> refresh() => _load(tab, keepSelection: true);

  /// Opens [entry]: a folder in this tab, a file in its application.
  Future<void> open(FileEntry entry) async {
    if (entry.isDirectory) return navigate(FolderLocation(entry.path));
    try {
      await fs.open(entry.path);
      recent
        ..removeWhere((FileEntry e) => e.path == entry.path)
        ..insert(0, entry);
      if (recent.length > 20) recent.removeLast();
      notify();
    } on Object catch (error) {
      _fail(error);
    }
  }

  /// Searches the current folder and everything below it for [query].
  Future<void> search(String query) {
    final String trimmed = query.trim();
    final String? root = currentFolder;
    if (root == null) return idle;
    if (trimmed.isEmpty) return navigate(FolderLocation(root));
    return navigate(SearchLocation(root, trimmed));
  }

  Future<void> _load(ExplorerTab t, {bool keepSelection = false}) {
    final int generation = ++t.generation;
    t
      ..loading = true
      ..error = null
      ..renaming = null;
    if (!keepSelection) {
      t.selection.clear();
      t.focused = null;
    }
    t.watcher?.cancel();
    t.watcher = null;
    notify();
    final Future<void> work = _fill(t, generation).whenComplete(() {
      if (generation != t.generation) return;
      t.loading = false;
      notify();
    });
    if (identical(t, tab)) _pending = work;
    return work;
  }

  Future<void> _fill(ExplorerTab t, int generation) async {
    switch (t.location) {
      case HomeLocation():
        t.entries = const <FileEntry>[];
        _resort(t);
      case ThisPcLocation():
        volumes = await fs.volumes();
        if (generation != t.generation) return;
        t.entries = const <FileEntry>[];
        _resort(t);
      case FolderLocation(:final String path):
        try {
          final List<FileEntry> listed = await fs.list(path);
          if (generation != t.generation) return;
          t.entries = listed;
          _resort(t);
          t.watcher = fs.watch(path)?.listen((_) {
            if (generation == t.generation) unawaited(_relist(t, generation));
          });
        } on Object catch (error) {
          if (generation != t.generation) return;
          t
            ..entries = const <FileEntry>[]
            ..visible = const <FileEntry>[]
            ..error = error is FileSystemError ? error.message : '$error';
        }
      case SearchLocation(:final String root, :final String query):
        t.entries = <FileEntry>[];
        await _search(t, generation, root, query.toLowerCase());
    }
  }

  /// The listing again after a change on disk, keeping the selection.
  Future<void> _relist(ExplorerTab t, int generation) async {
    final Location at = t.location;
    if (at is! FolderLocation) return;
    try {
      final List<FileEntry> listed = await fs.list(at.path);
      if (generation != t.generation) return;
      t.entries = listed;
      _resort(t);
      notify();
    } on Object {
      return;
    }
  }

  /// Breadth first, so near matches come first; shown as they are found.
  Future<void> _search(
      ExplorerTab t, int generation, String root, String query) async {
    final List<String> queue = <String>[root];
    var found = 0;
    var sinceShown = 0;
    while (queue.isNotEmpty && found < 5000) {
      final String folder = queue.removeAt(0);
      final List<FileEntry> listed;
      try {
        listed = await fs.list(folder);
      } on Object {
        continue;
      }
      if (generation != t.generation) return;
      for (final FileEntry entry in listed) {
        if (!_shows(entry)) continue;
        if (entry.isDirectory) queue.add(entry.path);
        if (entry.name.toLowerCase().contains(query)) {
          t.entries = <FileEntry>[...t.entries, entry];
          found++;
          sinceShown++;
        }
      }
      if (sinceShown > 0) {
        sinceShown = 0;
        _resort(t);
        notify();
      }
    }
    _resort(t);
  }

  /// Sorts and filters [t]'s entries into what the view shows.
  void _resort(ExplorerTab t) {
    final List<FileEntry> shown = <FileEntry>[
      for (final FileEntry e in t.entries)
        if (_shows(e)) e,
    ];
    t.visible = sortEntries(shown, sortField, ascending, strings);
    final Set<String> present = <String>{for (final e in t.visible) e.path};
    t.selection.removeWhere((String p) => !present.contains(p));
  }

  /// Sorts every tab by [field]; the same field again flips the direction.
  void sortBy(SortField field, {bool? ascending}) {
    if (ascending != null) {
      this.ascending = ascending;
    } else if (field == sortField) {
      this.ascending = !this.ascending;
    } else {
      this.ascending = true;
    }
    sortField = field;
    for (final ExplorerTab t in tabs) {
      _resort(t);
    }
    notify();
  }

  void setShowProtected(bool value) {
    showProtected = value;
    for (final ExplorerTab t in tabs) {
      _resort(t);
    }
    notify();
  }

  void setShowHidden(bool value) {
    showHidden = value;
    for (final ExplorerTab t in tabs) {
      _resort(t);
    }
    notify();
  }

  // --- tabs ---------------------------------------------------------------------

  /// Opens a tab at [at] (Home by default) and switches to it.
  Future<void> newTab([Location at = const HomeLocation()]) {
    tabs.insert(activeIndex + 1, ExplorerTab(at));
    activeIndex++;
    return _load(tab);
  }

  /// Closes tab [index]; the last tab's closing is refused - the window
  /// closes instead.
  bool closeTab(int index) {
    if (tabs.length == 1) return false;
    final ExplorerTab closing = tabs.removeAt(index);
    closedTabs.add(closing.location);
    closing.dispose();
    if (activeIndex > index || activeIndex >= tabs.length) {
      activeIndex = (activeIndex - 1).clamp(0, tabs.length - 1);
    }
    notify();
    return true;
  }

  void selectTab(int index) {
    if (index < 0 || index >= tabs.length || index == activeIndex) return;
    activeIndex = index;
    _pending = null;
    notify();
  }

  Future<void> reopenClosedTab() {
    if (closedTabs.isEmpty) return idle;
    return newTab(closedTabs.removeLast());
  }

  Future<void> duplicateTab() => newTab(tab.location);

  // --- selection ----------------------------------------------------------------

  void select(Iterable<String> paths, {String? focused}) {
    tab.selection
      ..clear()
      ..addAll(paths);
    tab.focused = focused ?? (paths.isEmpty ? null : paths.last);
    notify();
  }

  void selectAll() => select(<String>[for (final e in tab.visible) e.path]);

  void clearSelection() => select(const <String>[]);

  void invertSelection() => select(<String>[
        for (final FileEntry e in tab.visible)
          if (!tab.selection.contains(e.path)) e.path,
      ]);

  /// Selects the next visible item whose name starts with [prefix], after
  /// the focused one - typing a name to jump to it.
  bool selectByPrefix(String prefix) {
    final List<FileEntry> items = tab.visible;
    if (items.isEmpty || prefix.isEmpty) return false;
    final String p = prefix.toLowerCase();
    final int from = items.indexWhere((e) => e.path == tab.focused);
    // A single repeated letter cycles; a longer prefix stays on a match.
    final int start = p.length == 1 ? from + 1 : (from < 0 ? 0 : from);
    for (var k = 0; k < items.length; k++) {
      final FileEntry e = items[(start + k) % items.length];
      if (e.name.toLowerCase().startsWith(p)) {
        select(<String>[e.path]);
        return true;
      }
    }
    return false;
  }

  List<FileEntry> get selectedEntries => tab.selectedEntries;

  // --- file operations ------------------------------------------------------

  bool get canCreateHere => tab.location is FolderLocation;

  bool _taken(String folder, String name) =>
      tab.entries.any((FileEntry e) => fs.caseInsensitive
          ? e.name.toLowerCase() == name.toLowerCase()
          : e.name == name);

  /// Makes "New folder" (or "New folder (2)"...) here, selects it and puts
  /// it in rename. Returns its path.
  Future<String?> newFolder() => _create(strings.newFolder, '', true);

  /// Makes an empty "New Text Document.txt".
  Future<String?> newTextDocument() =>
      _create(strings.newTextDocument, '.txt', false);

  Future<String?> _create(String base, String extension, bool folder) async {
    final String? here = currentFolder;
    if (here == null || tab.location is! FolderLocation) return null;
    await idle;
    final String name =
        freshName(base, (String n) => _taken(here, n), extension: extension);
    final String path = fs.join(here, name);
    try {
      if (folder) {
        await fs.createFolder(path);
      } else {
        await fs.createFile(path);
      }
    } on Object catch (error) {
      _fail(error);
      return null;
    }
    await _load(tab, keepSelection: true);
    select(<String>[path]);
    tab.renaming = path;
    notify();
    return path;
  }

  /// Starts an in-place rename of the focused selected item.
  void beginRename() {
    final List<FileEntry> picked = selectedEntries;
    if (picked.isEmpty) return;
    tab.renaming = tab.focused != null && tab.selection.contains(tab.focused)
        ? tab.focused
        : picked.first.path;
    notify();
  }

  void cancelRename() {
    if (tab.renaming == null) return;
    tab.renaming = null;
    notify();
  }

  /// Renames [path] to [newName]; returns the new path, or null when it was
  /// refused (the reason is in [message]).
  Future<String?> rename(String path, String newName) async {
    tab.renaming = null;
    final String name = newName.trim();
    if (name.isEmpty || name == fs.nameOf(path)) {
      notify();
      return path;
    }
    try {
      final String renamed = await fs.rename(path, name);
      await _load(tab, keepSelection: true);
      select(<String>[renamed]);
      return renamed;
    } on Object catch (error) {
      _fail(error);
      return null;
    }
  }

  /// Sends the selection to the trash.
  Future<int> deleteSelection() async {
    final List<FileEntry> picked = selectedEntries;
    var done = 0;
    for (final FileEntry entry in picked) {
      try {
        await fs.trash(entry.path);
        done++;
      } on Object catch (error) {
        _fail(error);
        break;
      }
    }
    await _load(tab);
    return done;
  }

  void cutSelection() => _toClipboard(cut: true);

  void copySelection() => _toClipboard(cut: false);

  void _toClipboard({required bool cut}) {
    final List<FileEntry> picked = selectedEntries;
    if (picked.isEmpty) return;
    clipboard =
        FileClipboard(<String>[for (final e in picked) e.path], cut: cut);
    message = null;
    notify();
  }

  bool get canPaste => clipboard != null && canCreateHere;

  /// Copies or moves the clipboard's files into the current folder; a name
  /// already there gets " - Copy". Returns the new paths.
  Future<List<String>> paste() async {
    final FileClipboard? from = clipboard;
    final String? here = currentFolder;
    if (from == null || here == null || !canCreateHere) {
      return const <String>[];
    }
    await idle;
    final List<String> made = <String>[];
    final Set<String> names = <String>{for (final e in tab.entries) e.name};
    for (final String path in from.paths) {
      final FileEntry? source = await fs.stat(path);
      if (source == null) continue;
      final bool sameFolder = fs.parentOf(path) == here;
      if (from.cut && sameFolder) continue;
      final String name = copyName(source.name, names.contains,
          isDirectory: source.isDirectory);
      final String target = fs.join(here, name);
      try {
        if (from.cut) {
          await fs.move(path, target);
        } else {
          await fs.copy(path, target);
        }
        names.add(name);
        made.add(target);
      } on Object catch (error) {
        _fail(error);
        break;
      }
    }
    if (from.cut) clipboard = null;
    await _load(tab, keepSelection: true);
    select(made);
    return made;
  }

  /// "Copy as path": every selected path in quotes, one per line.
  String get selectionAsPaths =>
      selectedEntries.map((FileEntry e) => '"${e.path}"').join('\n');

  void pin(String path) {
    if (pinned.contains(path)) return;
    pinned.add(path);
    notify();
  }

  void unpin(String path) {
    if (pinned.remove(path)) notify();
  }

  void _fail(Object error) {
    message = error is FileSystemError ? error.toString() : '$error';
    notify();
  }

  // --- the status bar -------------------------------------------------------

  /// "12 items", and "3 items selected  4.50 MB" when files are selected.
  (String, String?) get statusText {
    final int count = switch (tab.location) {
      HomeLocation() => pinned.length + recent.length,
      ThisPcLocation() => volumes.length,
      _ => tab.visible.length,
    };
    final List<FileEntry> picked = selectedEntries;
    if (picked.isEmpty) return (strings.itemCount(count), null);
    final int bytes = picked.fold<int>(
        0, (int sum, FileEntry e) => sum + (e.isDirectory ? 0 : e.size ?? 0));
    final bool anyFile = picked.any((FileEntry e) => !e.isDirectory);
    return (
      strings.itemCount(count),
      '${strings.selectedCount(picked.length)}'
          '${anyFile ? '  ${humanSize(bytes, strings)}' : ''}',
    );
  }

  void dispose() {
    for (final ExplorerTab t in tabs) {
      t.dispose();
    }
    _listeners.clear();
  }
}
