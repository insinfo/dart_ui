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
import 'move_history.dart';
import 'preferences.dart';
import 'search_query.dart';
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
/// What dropping files on a folder does - the explorer's own word for it,
/// so the engine needs no widget type.
enum DropEffect { none, copy, move }

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
    _defaultView = viewSettings;
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
  ExplorerPreferences preferences = ExplorerPreferences();
  bool get showHidden => preferences['showHidden'];
  set showHidden(bool value) => preferences['showHidden'] = value;
  bool get showExtensions => preferences['showExtensions'];
  set showExtensions(bool value) => preferences['showExtensions'] = value;
  bool get showProtected => preferences['showProtected'];
  set showProtected(bool value) => preferences['showProtected'] = value;

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
  bool get navigationPane => preferences['navigationPane'];
  set navigationPane(bool value) => preferences['navigationPane'] = value;
  bool get detailsPane => preferences['detailsPane'];
  set detailsPane(bool value) => preferences['detailsPane'] = value;
  final List<FileEntry> favorites = [];
  final Map<String, Map<String, Object?>> folderViews = {};
  Map<String, Object?>? _defaultView;

  final Map<String, double> columnWidths = {};
  Map<String, Object?> get viewSettings => {
        'widths': Map<String, double>.of(columnWidths),
        'mode': viewMode.name,
        'sort': sortField.name,
        'ascending': ascending,
        'columns': columns.map((c) => c.name).toList(),
      };

  void _readView(Map<String, Object?> view) {
    columnWidths.clear();
    final widths = view['widths'];
    if (widths is Map) {
      for (final entry in widths.entries) {
        if (entry.key is String &&
            entry.value is num &&
            (entry.value as num).isFinite) {
          columnWidths[entry.key as String] =
              (entry.value as num).toDouble().clamp(60, 2000);
        }
      }
    }

    viewMode =
        ViewMode.values.where((e) => e.name == view['mode']).firstOrNull ??
            ViewMode.details;
    sortField =
        SortField.values.where((e) => e.name == view['sort']).firstOrNull ??
            SortField.name;
    ascending = view['ascending'] is bool ? view['ascending'] as bool : true;
    final names = view['columns'];
    if (names is List) {
      columns
        ..clear()
        ..add(DetailsColumn.name);
      for (final name in names) {
        final c = DetailsColumn.values.where((c) => c.name == name).firstOrNull;
        if (c != null && !columns.contains(c)) columns.add(c);
      }
    }
  }

  void _rememberView() {
    final folder = currentFolder;
    if (preferences['rememberFolderViews'] && folder != null) {
      folderViews[folder] = viewSettings;
      if (folderViews.length > 500) folderViews.remove(folderViews.keys.first);
    }
  }

  void _restoreView(Location at) {
    _defaultView ??= viewSettings;
    final folder = folderOf(at);
    _readView(preferences['rememberFolderViews'] && folderViews[folder] != null
        ? folderViews[folder]!
        : _defaultView!);
  }

  void applyViewToAllFolders() {
    _defaultView = viewSettings;
    folderViews.clear();
    notify();
  }

  void resetFolderViews() {
    folderViews.clear();
    _defaultView = {
      'mode': 'details',
      'sort': 'name',
      'ascending': true,
      'columns': ['name', 'dateModified', 'type', 'size']
    };
    _readView(_defaultView!);
    for (final t in tabs) {
      _resort(t);
    }
    notify();
  }

  void applyPreferences(ExplorerPreferences value) {
    preferences = value.copy();
    if (!preferences['showRecent']) recent.clear();
    if (!preferences['rememberFolderViews']) folderViews.clear();
    for (final t in tabs) {
      _resort(t);
    }
    notify();
  }

  void clearHistory() {
    recent.clear();
    closedTabs.clear();
    for (final t in tabs) {
      t.back.clear();
      t.forward.clear();
    }
    notify();
  }

  void toggleFavorites() {
    final files = selectedEntries.where((e) => !e.isDirectory).toList();
    final remove = files.every((e) => favorites.contains(e));
    for (final e in files) {
      favorites.remove(e);
      if (!remove) favorites.add(e);
    }
    notify();
  }

  void removeFavorite(FileEntry entry) {
    favorites.remove(entry);
    notify();
  }

  /// Cancel only the active search; preserve results already found.
  void cancelSearch() {
    if (tab.location is! SearchLocation || !tab.loading) return;
    tab.generation++;
    tab.loading = false;
    notify();
  }

  void closeOtherTabs({int? except, bool left = false, bool right = false}) {
    final keep = except ?? activeIndex;
    for (var i = tabs.length - 1; i >= 0; i--) {
      if (i != keep &&
          (!left && !right || left && i < keep || right && i > keep)) {
        closeTab(i);
      }
    }
  }

  void moveTab(int from, int to) {
    if (from < 0 ||
        to < 0 ||
        from >= tabs.length ||
        to >= tabs.length ||
        from == to) {
      return;
    }
    final active = tab;
    final moving = tabs.removeAt(from);
    tabs.insert(to, moving);
    activeIndex = tabs.indexOf(active);
    notify();
  }

  Map<String, Object?> exportState() {
    _rememberView();
    return {
      'version': 1,
      'options': preferences.toJson(),
      'view': viewSettings,
      'defaultView': _defaultView ?? viewSettings,
      'folderViews': folderViews,
      'pinned': pinned,
      'favorites': favorites.map(_entryJson).toList(),
      'recent':
          preferences['showRecent'] ? recent.map(_entryJson).toList() : [],
      'tabs': tabs.map((t) => _locationJson(t.location)).toList(),
      'activeTab': activeIndex
    };
  }

  void restoreState(Map<String, Object?> data, {bool restoreSession = true}) {
    final options = data['options'];
    if (options is Map) {
      preferences = ExplorerPreferences(Map<String, Object?>.from(options));
    }
    final view = data['view'];
    if (view is Map) _readView(Map<String, Object?>.from(view));
    final defaults = data['defaultView'];
    _defaultView =
        defaults is Map ? Map<String, Object?>.from(defaults) : viewSettings;
    final folders = data['folderViews'];
    if (folders is Map && preferences['rememberFolderViews']) {
      for (final key in folders.keys.take(500)) {
        if (key is String && folders[key] is Map) {
          folderViews[key] = Map<String, Object?>.from(folders[key] as Map);
        }
      }
    }
    if (data['pinned'] is List) {
      pinned = (data['pinned'] as List).whereType<String>().take(100).toList();
    }
    void entries(Object? source, List<FileEntry> into) {
      if (source is! List) return;
      for (final item in source.take(100)) {
        if (item is Map && item['path'] is String) {
          final path = item['path'] as String;
          into.add(FileEntry(
              path: path,
              name: fs.nameOf(path),
              isDirectory: false,
              size: item['size'] is int ? item['size'] as int : null));
        }
      }
    }

    favorites.clear();
    recent.clear();
    entries(data['favorites'], favorites);
    if (preferences['showRecent']) entries(data['recent'], recent);
    if (!restoreSession) {
      _restoreView(tab.location);
      return;
    }
    final session = data['tabs'];
    if (preferences['restoreTabs'] && session is List && session.isNotEmpty) {
      for (final t in tabs) {
        t.dispose();
      }
      tabs
        ..clear()
        ..addAll(session.take(30).map((v) => ExplorerTab(_readLocation(v))));
      activeIndex = data['activeTab'] is int
          ? (data['activeTab'] as int).clamp(0, tabs.length - 1)
          : 0;
    } else {
      tab.location = preferences['startThisPc']
          ? const ThisPcLocation()
          : const HomeLocation();
    }
    _restoreView(tab.location);
  }

  Map<String, Object?> _entryJson(FileEntry e) =>
      {'path': e.path, 'size': e.size};
  Map<String, Object?> _locationJson(Location at) => switch (at) {
        FolderLocation(:final path) => {'kind': 'folder', 'path': path},
        SearchLocation(:final root, :final query) => {
            'kind': 'search',
            'path': root,
            'query': query
          },
        ThisPcLocation() => {'kind': 'pc'},
        _ => {'kind': 'home'},
      };
  Location _readLocation(Object? value) {
    if (value is! Map) return const HomeLocation();
    if (value['kind'] == 'pc') return const ThisPcLocation();
    if (value['path'] is String) {
      if (value['kind'] == 'search' && value['query'] is String) {
        return SearchLocation(
            value['path'] as String, value['query'] as String);
      }
      if (value['kind'] == 'folder') {
        return FolderLocation(value['path'] as String);
      }
    }
    return const HomeLocation();
  }

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
    _rememberView();
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
    _rememberView();
    _restoreView(to);
    t.back.add(t.location);
    t.forward.clear();
    t.location = to;
    return _load(t);
  }

  Future<void> goBack() {
    final ExplorerTab t = tab;
    if (t.back.isEmpty) return idle;
    t.forward.add(t.location);
    _rememberView();
    t.location = t.back.removeLast();
    _restoreView(t.location);
    return _load(t);
  }

  Future<void> goForward() {
    final ExplorerTab t = tab;
    if (t.forward.isEmpty) return idle;
    t.back.add(t.location);
    _rememberView();
    t.location = t.forward.removeLast();
    _restoreView(t.location);
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
    if (entry.isDirectory) {
      return preferences['openFoldersInNewTab']
          ? newTab(FolderLocation(entry.path))
          : navigate(FolderLocation(entry.path));
    }
    try {
      await fs.open(entry.path);
      if (preferences['showRecent']) {
        recent
          ..removeWhere((FileEntry e) => e.path == entry.path)
          ..insert(0, entry);
      }
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
        try {
          t.searchTruncated = false;
          await _search(t, generation, root, SearchQuery(query));
        } on FormatException catch (error) {
          t.error = error.message;
          _resort(t);
        }
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
      ExplorerTab t, int generation, String root, SearchQuery query) async {
    final List<String> queue = <String>[root];
    var index = 0;
    var found = 0;
    final visited = <String>{};
    var sinceShown = 0;
    while (index < queue.length && found < 5000) {
      final String folder = queue[index++];
      if (!visited.add(folder)) continue;
      final List<FileEntry> listed;
      try {
        listed = await fs.list(folder);
      } on Object {
        continue;
      }
      if (generation != t.generation) return;
      for (final FileEntry entry in listed) {
        if (!_shows(entry)) continue;
        if (entry.isDirectory && preferences['searchSubfolders']) {
          queue.add(entry.path);
        }
        if (query.matches(entry)) {
          t.entries.add(entry);
          found++;
          sinceShown++;
          if (found >= 5000) {
            t.searchTruncated = true;
            break;
          }
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
  Future<void> newTab([Location? at]) {
    _rememberView();
    final next = at ??
        (preferences['startThisPc']
            ? const ThisPcLocation()
            : const HomeLocation());
    _restoreView(next);
    tabs.insert(activeIndex + 1, ExplorerTab(next));
    activeIndex++;
    return _load(tab);
  }

  /// Closes tab [index]; the last tab's closing is refused - the window
  /// closes instead.
  bool closeTab(int index) {
    if (tabs.length == 1) return false;
    _rememberView();
    final ExplorerTab closing = tabs.removeAt(index);
    closedTabs.add(closing.location);
    closing.dispose();
    if (activeIndex > index || activeIndex >= tabs.length) {
      activeIndex = (activeIndex - 1).clamp(0, tabs.length - 1);
    }
    _restoreView(tab.location);
    _resort(tab);
    notify();
    return true;
  }

  void selectTab(int index) {
    if (index < 0 || index >= tabs.length || index == activeIndex) return;
    _rememberView();
    activeIndex = index;
    _restoreView(tab.location);
    _resort(tab);
    _pending = null;
    if (tab.entries.isEmpty && !tab.loading) {
      unawaited(_load(tab));
    }
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

  late final MoveHistory history = MoveHistory(fs);
  Future<void> undo({bool redo = false}) async {
    final work = history.run(redo: redo);
    notify();
    try {
      await work;
      await refresh();
    } on Object catch (error) {
      _fail(error);
    }
    notify();
  }

  Future<void> renameSelection(String base) async {
    final picked = selectedEntries;
    if (picked.isEmpty || base.trim().isEmpty) return;
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(base) || base == '.' || base == '..') {
      _fail(const FileSystemError('Invalid base name'));
      return;
    }
    final moves = <MovedPath>[];
    try {
      final plans = <(FileEntry, String)>[];
      for (var i = 0; i < picked.length; i++) {
        final e = picked[i];
        final suffix = e.extension.isEmpty ? '' : '.${e.extension}';
        final name = '${base.trim()} (${i + 1})$suffix';
        final target = fs.join(fs.parentOf(e.path)!, name);
        if (target != e.path && await fs.stat(target) != null) {
          throw FileSystemError('Already exists', target);
        }
        plans.add((e, name));
      }
      for (final (e, name) in plans) {
        if (e.name == name) continue;
        final target = await fs.rename(e.path, name);
        moves.add((e.path, target));
      }
      history.record(moves);
      await refresh();
      select([for (final p in moves) p.$2]);
    } on Object catch (error) {
      for (final (from, to) in moves.reversed) {
        await fs.move(to, from);
      }
      _fail(error);
    }
  }

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
      history.record([(path, renamed)]);
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
    final List<String> made = await _transfer(from.paths, here, move: from.cut);
    if (from.cut) clipboard = null;
    await _load(tab, keepSelection: true);
    select(made);
    return made;
  }

  /// The paths being dragged out of this window, while the drag runs - so a
  /// drop back into it knows what it carries before the drop, and can refuse
  /// to put a folder inside itself.
  List<String>? dragging;

  /// The volume [path] is on: the longest volume path it is under, or its
  /// root.
  String volumeOf(String path) {
    String best = fs.ancestry(path).first;
    for (final Volume volume in volumes) {
      final String root = volume.path;
      final bool under = fs.caseInsensitive
          ? path.toLowerCase().startsWith(root.toLowerCase())
          : path.startsWith(root);
      if (under && root.length > best.length) best = root;
    }
    return best;
  }

  /// What dropping [paths] on [folder] does, as Explorer decides it: Ctrl
  /// copies and Shift moves; otherwise a move within one drive and a copy
  /// onto another. Nothing goes into itself or into what it contains, and
  /// a move into the folder it is already in does nothing. [paths] null is
  /// a drag from another application, whose files are not known until the
  /// drop: it copies unless Shift says move.
  DropEffect dropEffect(
    String folder,
    List<String>? paths, {
    bool control = false,
    bool shift = false,
    bool canMove = true,
  }) {
    DropEffect wanted;
    if (control) {
      wanted = DropEffect.copy;
    } else if (shift) {
      wanted = DropEffect.move;
    } else if (paths == null || paths.isEmpty) {
      wanted = DropEffect.copy;
    } else {
      final String target = volumeOf(folder);
      wanted = paths.every((String p) => volumeOf(p) == target)
          ? DropEffect.move
          : DropEffect.copy;
    }
    if (wanted == DropEffect.move && !canMove) wanted = DropEffect.copy;
    for (final String path in paths ?? const <String>[]) {
      if (_isWithin(folder, path)) return DropEffect.none;
      if (wanted == DropEffect.move && fs.parentOf(path) == folder) {
        return DropEffect.none;
      }
    }
    return wanted;
  }

  /// Whether [path] is [ancestor] or inside it.
  bool _isWithin(String path, String ancestor) {
    final String a = fs.caseInsensitive ? ancestor.toLowerCase() : ancestor;
    final String p = fs.caseInsensitive ? path.toLowerCase() : path;
    if (p == a) return true;
    final String prefix = a.endsWith(fs.separator) ? a : '$a${fs.separator}';
    return p.startsWith(prefix);
  }

  /// Drops [paths] on [folder]: copies or moves them there, and selects
  /// them when that is the folder on screen. Returns the new paths.
  Future<List<String>> drop(
    String folder,
    List<String> paths, {
    required bool move,
  }) async {
    await idle;
    final List<String> made = await _transfer(paths, folder, move: move);
    final bool onScreen = currentFolder == folder;
    await _load(tab, keepSelection: !onScreen);
    if (onScreen) select(made);
    return made;
  }

  /// Copies or moves [paths] into [folder], a taken name getting " - Copy";
  /// a move into the folder a file is already in is skipped. Stops at the
  /// first failure, whose reason goes to [message].
  Future<List<String>> _transfer(
    List<String> paths,
    String folder, {
    required bool move,
  }) async {
    final List<String> made = <String>[];
    final moves = <MovedPath>[];
    final Set<String> names;
    try {
      names = <String>{
        for (final FileEntry e in await fs.list(folder)) e.name,
      };
    } on Object catch (error) {
      _fail(error);
      return made;
    }
    for (final String path in paths) {
      final FileEntry? source = await fs.stat(path);
      if (source == null) continue;
      if (move && fs.parentOf(path) == folder) continue;
      if (_isWithin(folder, path)) continue;
      final String name = copyName(source.name, names.contains,
          isDirectory: source.isDirectory, copy: strings.copy);
      final String target = fs.join(folder, name);
      try {
        if (move) {
          await fs.move(path, target);
          moves.add((path, target));
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
    history.record(moves);
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

  bool archiveBusy = false;
  Future<void> archiveSelection({bool extract = false}) async {
    final source = fs;
    final picked = selectedEntries;
    final folder = currentFolder;
    final origin = tab;
    if (archiveBusy ||
        source is! ArchiveFileSystem ||
        folder == null ||
        picked.isEmpty) {
      return;
    }
    final archive = source as ArchiveFileSystem;
    archiveBusy = true;
    message = null;
    notify();
    try {
      final names = {for (final e in await fs.list(folder)) e.name};
      final base = picked.length == 1 ? picked.first.stem : 'Archive';
      final name =
          freshName(base, names.contains, extension: extract ? '' : '.zip');
      final target = fs.join(folder, name);
      if (extract) {
        await archive.extractArchive(picked.single.path, target);
      } else {
        await archive.createArchive(picked.map((e) => e.path).toList(), target);
      }
      if (tabs.contains(origin) && folderOf(origin.location) == folder) {
        await _load(origin, keepSelection: true);
        if (identical(tab, origin)) select([target]);
      }
    } on Object catch (error) {
      _fail(error);
    } finally {
      archiveBusy = false;
      notify();
    }
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
