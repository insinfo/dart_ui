import 'dart:io';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/file_system.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/search_query.dart';
import 'package:file_explorer/src/io/io_file_system.dart';
import 'package:file_explorer/src/io/preferences_store.dart';
import 'package:test/test.dart';

void main() {
  ExplorerModel make(MemoryFileSystem fs) => ExplorerModel(
      fs: fs, places: const {}, start: const FolderLocation('/docs'));

  test('queries combine quoted names, wildcards, OR, NOT, sizes and dates', () {
    final pdf = FileEntry(
        path: '/report.pdf',
        name: 'Annual Report.pdf',
        isDirectory: false,
        size: 2000000,
        modified: DateTime(2026, 10, 18));
    const png = FileEntry(
        path: '/photo.png', name: 'photo.png', isDirectory: false, size: 30);
    expect(
        SearchQuery(
                '"annual report" AND ext:pdf size:>1MB modified:>=2026-10-01')
            .matches(pdf),
        isTrue);
    expect(SearchQuery('*.pdf OR *.png').matches(png), isTrue);
    expect(SearchQuery('kind:image NOT ext:jpg').matches(png), isTrue);
    expect(SearchQuery('size:<1KB').matches(pdf), isFalse);
    expect(SearchQuery('name:photo?png').matches(png), isTrue);
    expect(SearchQuery('created:>2026-01-01').matches(png), isFalse);
    for (final q in [
      'modified:2026-02-30',
      'size:abc',
      'foo:bar',
      'abc OR',
      'NOT',
      'kind:banana'
    ]) {
      expect(() => SearchQuery(q), throwsFormatException, reason: q);
    }
  });

  test(
      'recursive and current-folder search respect scope and report invalid filters',
      () async {
    final fs = MemoryFileSystem()
      ..addFile('/docs/a.txt')
      ..addFile('/docs/sub/b.txt')
      ..addFile('/docs/.secret.txt');
    final m = make(fs);
    addTearDown(m.dispose);
    await m.refresh();
    await m.search('ext:txt');
    expect(m.tab.visible.map((e) => e.name).toSet(), {'a.txt', 'b.txt'});
    m.preferences['searchSubfolders'] = false;
    await m.search('ext:txt');
    expect(m.tab.visible.map((e) => e.name), ['a.txt']);
    await m.search('unknown:x');
    expect(m.tab.error, contains('Unknown search filter'));
    expect(m.tab.visible, isEmpty);
  });

  test(
      'each folder remembers layout and columns; defaults can be applied and reset',
      () async {
    final fs = MemoryFileSystem()
      ..addFolder('/docs')
      ..addFolder('/pics');
    final m = make(fs);
    addTearDown(m.dispose);
    await m.refresh();
    m.viewMode = ViewMode.content;
    m.toggleColumn(DetailsColumn.size);
    await m.navigate(const FolderLocation('/pics'));
    expect(m.viewMode, ViewMode.details);
    m.viewMode = ViewMode.largeIcons;
    m.sortBy(SortField.extension);
    await m.goBack();
    expect(m.viewMode, ViewMode.content);
    expect(m.columns, isNot(contains(DetailsColumn.size)));
    m.applyViewToAllFolders();
    await m.navigate(const FolderLocation('/pics'));
    expect(m.viewMode, ViewMode.content);
    m.resetFolderViews();
    expect(m.viewMode, ViewMode.details);
    expect(m.columns, contains(DetailsColumn.size));
  });

  test(
      'batch rename preserves extensions and undo/redo never overwrite a collision',
      () async {
    final fs = MemoryFileSystem()
      ..addFile('/docs/a.txt')
      ..addFile('/docs/b.pdf');
    final m = make(fs);
    addTearDown(m.dispose);
    await m.refresh();
    m.selectAll();
    await m.renameSelection('Report');
    expect(fs.contains('/docs/Report (1).txt'), isTrue);
    expect(fs.contains('/docs/Report (2).pdf'), isTrue);
    await m.undo();
    expect(fs.contains('/docs/a.txt'), isTrue);
    expect(fs.contains('/docs/b.pdf'), isTrue);
    await m.undo(redo: true);
    expect(fs.contains('/docs/Report (1).txt'), isTrue);
    fs.addFile('/docs/a.txt');
    await m.undo();
    expect(m.message, contains('already exists'));
    expect(fs.contains('/docs/a.txt'), isTrue);
    expect(fs.contains('/docs/Report (1).txt'), isTrue);
    expect(fs.contains('/docs/Report (2).pdf'), isTrue,
        reason: 'partial undo is rolled back');
  });

  test('privacy clears recent history while favorites remain', () async {
    final fs = MemoryFileSystem()..addFile('/docs/a.txt');
    final m = make(fs);
    addTearDown(m.dispose);
    await m.refresh();
    m.select(['/docs/a.txt']);
    m.toggleFavorites();
    await m.open(m.selectedEntries.single);
    expect(m.recent, hasLength(1));
    final draft = m.preferences.copy()..['showRecent'] = false;
    m.applyPreferences(draft);
    expect(m.recent, isEmpty);
    await m.open(m.selectedEntries.single);
    expect(m.recent, isEmpty);
    m.clearHistory();
    expect(m.favorites, hasLength(1));
    expect(m.exportState()['recent'], isEmpty);
  });

  test(
      'session round trip restores selected tab but explicit paths take precedence',
      () async {
    final fs = MemoryFileSystem()
      ..addFolder('/docs')
      ..addFolder('/pics');
    final m = make(fs);
    addTearDown(m.dispose);
    m.preferences['restoreTabs'] = true;
    m.preferences['compact'] = true;
    await m.newTab(const FolderLocation('/pics'));
    final restored = make(fs);
    addTearDown(restored.dispose);
    restored.restoreState(m.exportState());
    expect(restored.tabs.map((t) => t.location),
        [const FolderLocation('/docs'), const FolderLocation('/pics')]);
    expect(restored.currentFolder, '/pics');
    expect(restored.preferences['compact'], isTrue);
    final explicit = make(fs);
    addTearDown(explicit.dispose);
    explicit.restoreState(m.exportState(), restoreSession: false);
    expect(explicit.currentFolder, '/docs');
  });

  test('closing and moving tabs retain active identity', () async {
    final fs = MemoryFileSystem()
      ..addFolder('/docs')
      ..addFolder('/a')
      ..addFolder('/b');
    final m = make(fs);
    addTearDown(m.dispose);
    await m.newTab(const FolderLocation('/a'));
    await m.newTab(const FolderLocation('/b'));
    final active = m.tab;
    m.moveTab(2, 0);
    expect(m.tab, same(active));
    m.closeOtherTabs();
    expect(m.tabs, [active]);
    await m.reopenClosedTab();
    expect(m.tabs, hasLength(2));
  });

  test('store serializes the latest snapshot and reports bad JSON', () async {
    final dir = await Directory.systemTemp.createTemp('explorer-settings-');
    addTearDown(() => dir.delete(recursive: true));
    final fs = MemoryFileSystem()..addFolder('/docs');
    final m = make(fs);
    addTearDown(m.dispose);
    final file = File('${dir.path}/preferences.json');
    final store = PreferencesStore(file)..attach(m);
    m.preferences['compact'] = true;
    await store.save();
    m.preferences['compact'] = false;
    await store.close();
    final fresh = make(fs);
    addTearDown(fresh.dispose);
    await PreferencesStore(file).load(fresh);
    expect(fresh.preferences['compact'], isFalse);
    await file.writeAsString('{broken');
    final broken = PreferencesStore(file);
    await broken.load(fresh);
    expect(broken.lastError, isNotNull);
  });

  test('text preview is bounded and refuses binary data', () async {
    final dir = await Directory.systemTemp.createTemp('explorer-preview-');
    addTearDown(() => dir.delete(recursive: true));
    final text = File('${dir.path}/big.txt');
    await text.writeAsString('a' * 100000);
    expect((await IoFileSystem().readTextPreview(text.path))!.length, 65536);
    final binary = File('${dir.path}/binary');
    await binary.writeAsBytes([0, 1, 2, 3]);
    expect(await IoFileSystem().readTextPreview(binary.path), isNull);
  });
}
