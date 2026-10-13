import 'package:dart_ui/commands.dart';
import 'package:file_explorer/src/engine/explorer_commands.dart';
import 'package:file_explorer/src/engine/explorer_host.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/file_system.dart';
import 'package:file_explorer/src/engine/file_types.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/properties.dart';
import 'package:file_explorer/src/engine/sorting.dart';
import 'package:file_explorer/src/engine/strings.dart';
import 'package:test/test.dart';

/// A small home folder.
MemoryFileSystem disk() => MemoryFileSystem(clock: () => DateTime(2026, 10, 13))
  ..addFolder('/home/ana/Documents')
  ..addFolder('/home/ana/Downloads')
  ..addFile('/home/ana/Documents/report10.txt', size: 2048)
  ..addFile('/home/ana/Documents/report2.txt', size: 100)
  ..addFile('/home/ana/Documents/Budget.xlsx', size: 5 << 20)
  ..addFolder('/home/ana/Documents/Archive')
  ..addFile('/home/ana/Documents/Archive/old report.txt', size: 1)
  ..addFile('/home/ana/Documents/.secret', size: 1);

ExplorerModel explorer(MemoryFileSystem fs) => ExplorerModel(
      fs: fs,
      places: const <Place, String>{
        Place.home: '/home/ana',
        Place.documents: '/home/ana/Documents',
        Place.downloads: '/home/ana/Downloads',
      },
    );

List<String> names(ExplorerModel m) =>
    <String>[for (final FileEntry e in m.tab.visible) e.name];

void main() {
  test('natural order: report2 before report10, case folded', () {
    final List<String> sorted = <String>['report10', 'Report2', 'report1']
      ..sort(naturalCompare);
    expect(sorted, <String>['report1', 'Report2', 'report10']);
  });

  test('a folder lists folders first, hidden items left out', () async {
    final ExplorerModel m = explorer(disk());
    await m.navigate(const FolderLocation('/home/ana/Documents'));
    expect(names(m), <String>[
      'Archive',
      'Budget.xlsx',
      'report2.txt',
      'report10.txt',
    ]);
    m.setShowHidden(true);
    expect(names(m), contains('.secret'));
    m.sortBy(SortField.size, ascending: false);
    expect(names(m).skip(1).first, 'Budget.xlsx');
  });

  test('back, forward and up; up selects where it came from', () async {
    final ExplorerModel m = explorer(disk());
    await m.navigate(const FolderLocation('/home/ana/Documents'));
    await m.navigate(const FolderLocation('/home/ana/Documents/Archive'));
    await m.goUp();
    expect(m.tab.location, const FolderLocation('/home/ana/Documents'));
    expect(m.tab.selection, <String>{'/home/ana/Documents/Archive'});
    await m.goBack();
    expect(m.tab.location, const FolderLocation('/home/ana/Documents/Archive'));
    await m.goForward();
    expect(m.tab.location, const FolderLocation('/home/ana/Documents'));
    await m.navigate(const FolderLocation('/'));
    await m.goUp();
    expect(m.tab.location, const ThisPcLocation());
  });

  test('New folder twice: "New folder" then "New folder (2)", renaming',
      () async {
    final ExplorerModel m = explorer(disk());
    await m.navigate(const FolderLocation('/home/ana/Downloads'));
    final String? first = await m.newFolder();
    final String? second = await m.newFolder();
    expect(first, '/home/ana/Downloads/New folder');
    expect(second, '/home/ana/Downloads/New folder (2)');
    expect(m.tab.renaming, second);
    expect(await m.rename(second!, 'Photos'), '/home/ana/Downloads/Photos');
    expect(names(m), <String>['New folder', 'Photos']);
    expect(await m.rename('/home/ana/Downloads/Photos', 'New folder'), isNull);
    expect(m.message, contains('Already exists'));
  });

  test('copy and paste into the same folder makes " - Copy"', () async {
    final MemoryFileSystem fs = disk();
    final ExplorerModel m = explorer(fs);
    await m.navigate(const FolderLocation('/home/ana/Documents'));
    m.select(<String>['/home/ana/Documents/report2.txt']);
    m.copySelection();
    await m.paste();
    await m.paste();
    expect(
        names(m),
        containsAll(<String>[
          'report2 - Copy.txt',
          'report2 - Copy (2).txt',
        ]));
    expect(m.tab.selection,
        <String>{'/home/ana/Documents/report2 - Copy (2).txt'});
  });

  test('cut and paste moves, folder and all', () async {
    final MemoryFileSystem fs = disk();
    final ExplorerModel m = explorer(fs);
    await m.navigate(const FolderLocation('/home/ana/Documents'));
    m.select(<String>['/home/ana/Documents/Archive']);
    m.cutSelection();
    await m.navigate(const FolderLocation('/home/ana/Downloads'));
    await m.paste();
    expect(fs.contains('/home/ana/Downloads/Archive/old report.txt'), isTrue);
    expect(fs.contains('/home/ana/Documents/Archive'), isFalse);
    expect(m.clipboard, isNull, reason: 'a cut is pasted once');
  });

  test('delete sends to the trash, never removes outright', () async {
    final MemoryFileSystem fs = disk();
    final ExplorerModel m = explorer(fs);
    await m.navigate(const FolderLocation('/home/ana/Documents'));
    m.select(<String>['/home/ana/Documents/report2.txt']);
    expect(await m.deleteSelection(), 1);
    expect(fs.trashed, <String>['/home/ana/Documents/report2.txt']);
    expect(names(m), isNot(contains('report2.txt')));
  });

  test('search finds matches in subfolders', () async {
    final ExplorerModel m = explorer(disk());
    await m.navigate(const FolderLocation('/home/ana'));
    await m.search('report');
    expect(m.tab.location, isA<SearchLocation>());
    expect(
        names(m),
        containsAll(<String>[
          'old report.txt',
          'report2.txt',
          'report10.txt',
        ]));
    expect(m.titleOf(m.tab.location), startsWith('report - Search Results'));
    await m.goUp();
    expect(m.tab.location, const FolderLocation('/home/ana'));
  });

  test('tabs: new, close, reopen; the last one stays', () async {
    final ExplorerModel m = explorer(disk());
    await m.newTab(const FolderLocation('/home/ana/Documents'));
    expect(m.tabs, hasLength(2));
    expect(m.activeIndex, 1);
    expect(m.closeTab(1), isTrue);
    expect(m.closeTab(0), isFalse);
    await m.reopenClosedTab();
    expect(m.tab.location, const FolderLocation('/home/ana/Documents'));
  });

  test('the status bar counts, and sums the selected files', () async {
    final ExplorerModel m = explorer(disk());
    await m.navigate(const FolderLocation('/home/ana/Documents'));
    expect(m.statusText.$1, '4 items');
    m.select(<String>[
      '/home/ana/Documents/Budget.xlsx',
      '/home/ana/Documents/Archive',
    ]);
    expect(m.statusText.$2, '2 items selected  5.00 MB');
  });

  test('typing a name selects; the same letter again cycles', () async {
    final ExplorerModel m = explorer(disk());
    await m.navigate(const FolderLocation('/home/ana/Documents'));
    m.selectByPrefix('r');
    expect(m.tab.selection, <String>{'/home/ana/Documents/report2.txt'});
    m.selectByPrefix('r');
    expect(m.tab.selection, <String>{'/home/ana/Documents/report10.txt'});
  });

  test('Explorer formats sizes in KB rounded up, dates per language', () {
    const ExplorerStrings pt = ExplorerStrings.portuguese;
    expect(sizeColumn(1, ExplorerStrings.english), '1 KB');
    expect(sizeColumn(1234567, ExplorerStrings.english), '1,206 KB');
    expect(sizeColumn(1234567, pt), '1.206 KB');
    expect(humanSize(5 << 20, pt), '5,00 MB');
    expect(dateColumn(DateTime(2026, 10, 13, 2, 21), pt), '13/10/2026 02:21');
    expect(dateColumn(DateTime(2026, 10, 13, 14, 5), ExplorerStrings.english),
        '10/13/2026 2:05 PM');
  });

  group('as commands', () {
    late MemoryFileSystem fs;
    late ExplorerModel m;
    late CommandRegistry registry;
    late HeadlessExplorerHost host;

    setUp(() async {
      fs = disk();
      m = explorer(fs);
      host = HeadlessExplorerHost();
      registry = CommandRegistry();
      registerExplorerCommands(registry, m, host);
      registry
          .execute('nav.go', <String, Object?>{'path': '/home/ana/Documents'});
      await m.idle;
    });

    test('Back is disabled until there is somewhere to go', () async {
      expect(registry.execute('nav.back').ok, isTrue);
      await m.idle;
      expect(m.tab.location, const HomeLocation());
      expect(registry.execute('nav.back').error, contains('nowhere'));
    });

    test('F2 renames in place; with a name, renames outright', () async {
      registry.execute('select.byName', <String, Object?>{'prefix': 'budget'});
      final KeyGesture f2 = registry['file.rename']!.shortcut!;
      registry.keyBindings()[f2]!();
      expect(m.tab.renaming, '/home/ana/Documents/Budget.xlsx');
      registry.execute('file.rename', <String, Object?>{'name': 'Plan.xlsx'});
      await m.idle;
      expect(fs.contains('/home/ana/Documents/Plan.xlsx'), isTrue);
    });

    test('Copy as path puts quoted paths on the clipboard', () {
      registry.execute('select.byName', <String, Object?>{'prefix': 'report1'});
      expect(registry.execute('file.copyPath').ok, isTrue);
      expect(host.clipboardText, '"/home/ana/Documents/report10.txt"');
    });

    test('Ctrl+Shift+N, then the view keys', () async {
      registry.execute('file.newFolder');
      await Future<void>.delayed(Duration.zero);
      await m.idle;
      expect(fs.contains('/home/ana/Documents/New folder'), isTrue);
      registry.execute('view.largeIcons');
      expect(m.viewMode, ViewMode.largeIcons);
      expect(registry['view.largeIcons']!.isChecked, isTrue);
    });

    test('closing the last tab closes the window', () {
      registry.execute('tab.close');
      expect(host.calls, contains('close'));
    });
  });

  test('in Portuguese every command has a label, and no label is a typo', () {
    final ExplorerModel m = ExplorerModel(
      fs: disk(),
      places: const <Place, String>{},
      strings: ExplorerStrings.portuguese,
    );
    final CommandRegistry registry = CommandRegistry();
    registerExplorerCommands(registry, m, HeadlessExplorerHost());
    final Set<String> ids = <String>{
      for (final Map<String, Object?> c in registry.describe())
        c['id']! as String,
    };
    expect(
        ids.difference(ExplorerStrings.portuguese.commandLabels.keys.toSet()),
        isEmpty,
        reason: 'commands with no Portuguese label');
    expect(
        ExplorerStrings.portuguese.commandLabels.keys.toSet().difference(ids),
        isEmpty,
        reason: 'labels for commands that do not exist');
    expect(registry['file.cut']!.label, 'Recortar');
    expect(registry['file.cut']!.shortcut,
        const KeyGesture(logicalKeyX, command: true),
        reason: 'only the words change');
  });

  test('hidden, protected and known-extension rules, as Windows applies them',
      () async {
    final MemoryFileSystem fs = disk()
      ..addFile('/home/ana/Documents/desktop.ini')
      ..addFile('/home/ana/Documents/data.xyz');
    final ExplorerModel m = explorer(fs);
    await m.navigate(const FolderLocation('/home/ana/Documents'));
    expect(names(m), isNot(contains('desktop.ini')));
    m.setShowHidden(true);
    expect(names(m), contains('.secret'));
    expect(names(m), isNot(contains('desktop.ini')),
        reason: 'a system file needs protected files shown too');
    m.setShowProtected(true);
    expect(names(m), contains('desktop.ini'));

    m.showExtensions = false;
    String shown(String name) =>
        m.shownName(m.tab.visible.firstWhere((FileEntry e) => e.name == name));
    expect(shown('Budget.xlsx'), 'Budget');
    expect(shown('data.xyz'), 'data.xyz', reason: 'an unknown type keeps it');
    expect(shown('Archive'), 'Archive');
  });

  test('Details columns: shown in order, Name stays', () {
    final ExplorerModel m = explorer(disk());
    m.toggleColumn(DetailsColumn.type);
    m.toggleColumn(DetailsColumn.dateCreated);
    m.toggleColumn(DetailsColumn.name);
    expect(m.columns, <DetailsColumn>[
      DetailsColumn.name,
      DetailsColumn.dateModified,
      DetailsColumn.size,
      DetailsColumn.dateCreated,
    ]);
    m.toggleColumn(DetailsColumn.type);
    expect(m.columns.indexOf(DetailsColumn.type), 2);
  });

  test('Properties: a folder counted to the bottom, as it is walked', () async {
    final MemoryFileSystem fs = MemoryFileSystem()
      ..addFile('/p/a.txt', size: 1000)
      ..addFile('/p/sub/b.txt', size: 24)
      ..addFile('/p/sub/deeper/c.bin', size: 1048576)
      ..addFolder('/p/empty');
    final List<Tally> steps = <Tally>[];
    final FileEntry folder = (await fs.stat('/p'))!;
    final Tally total =
        await tally(fs, <FileEntry>[folder], progress: steps.add);
    expect(total, const Tally(files: 3, folders: 3, bytes: 1049600));
    expect(steps.last, total);
    expect(steps.length, greaterThan(1), reason: 'it counts up as it goes');

    var asked = 0;
    final Tally stopped =
        await tally(fs, <FileEntry>[folder], cancelled: () => ++asked > 1);
    expect(stopped.files, lessThan(3), reason: 'a closed dialog stops it');
  });

  test('Properties: sizes in full, long dates, per language', () {
    const ExplorerStrings en = ExplorerStrings.english;
    const ExplorerStrings pt = ExplorerStrings.portuguese;
    expect(exactSize(1071, en), '1.05 KB (1,071 bytes)');
    expect(exactSize(1071, pt), '1,05 KB (1.071 bytes)');
    expect(exactSize(900, en), '900 bytes');
    final DateTime d = DateTime(2025, 1, 3, 10, 0, 5);
    expect(longDate(d, en), 'Friday, January 3, 2025, 10:00:05 AM');
    expect(longDate(d, pt), 'sexta-feira, 3 de janeiro de 2025, 10:00:05');
    expect(containsText(const Tally(files: 1, folders: 2), en),
        '1 File, 2 Folders');
    expect(containsText(const Tally(files: 1200, folders: 0), pt),
        '1.200 arquivos, 0 pastas');
  });

  test(
      'dragging: a move within a drive, a copy onto another, never into itself',
      () {
    final MemoryFileSystem fs = MemoryFileSystem()
      ..addFile('/home/ana/a.txt')
      ..addFolder('/home/ana/Photos/2024')
      ..addFolder('/Volumes/USB/backup');
    final ExplorerModel m = explorer(fs)
      ..volumes = const <Volume>[
        Volume(path: '/', label: 'Macintosh HD'),
        Volume(path: '/Volumes/USB', label: 'USB'),
      ];
    const List<String> file = <String>['/home/ana/a.txt'];
    expect(m.dropEffect('/home/ana/Photos', file), DropEffect.move);
    expect(m.dropEffect('/Volumes/USB/backup', file), DropEffect.copy);
    expect(m.dropEffect('/Volumes/USB/backup', file, shift: true),
        DropEffect.move);
    expect(
        m.dropEffect('/home/ana/Photos', file, control: true), DropEffect.copy);
    expect(
        m.dropEffect('/home/ana/Photos', file, canMove: false), DropEffect.copy,
        reason: 'the source only lets it be copied');
    expect(m.dropEffect('/home/ana', file), DropEffect.none,
        reason: 'moving into the folder it is in does nothing');
    expect(m.dropEffect('/home/ana', file, control: true), DropEffect.copy,
        reason: 'but a copy there is "a - Copy.txt"');
    const List<String> photos = <String>['/home/ana/Photos'];
    expect(m.dropEffect('/home/ana/Photos', photos), DropEffect.none);
    expect(m.dropEffect('/home/ana/Photos/2024', photos), DropEffect.none,
        reason: 'not into what it contains');
    expect(m.dropEffect('/home/ana/Photos', null), DropEffect.copy,
        reason: "another application's files copy unless Shift says move");
  });

  test('dropping moves or copies into the folder, keeping both names',
      () async {
    final MemoryFileSystem fs = MemoryFileSystem()
      ..addFile('/home/ana/a.txt', size: 3)
      ..addFile('/home/ana/Photos/a.txt', size: 9)
      ..addFolder('/home/ana/Docs');
    final ExplorerModel m = explorer(fs);
    await m.navigate(const FolderLocation('/home/ana'));
    final List<String> moved =
        await m.drop('/home/ana/Docs', <String>['/home/ana/a.txt'], move: true);
    expect(moved, <String>['/home/ana/Docs/a.txt']);
    expect(await fs.stat('/home/ana/a.txt'), isNull);
    final List<String> copied = await m.drop(
        '/home/ana/Photos', <String>['/home/ana/Docs/a.txt'],
        move: false);
    expect(copied, <String>['/home/ana/Photos/a - Copy.txt']);
    expect(await fs.stat('/home/ana/Docs/a.txt'), isNotNull);
    expect(m.tab.entries.map((FileEntry e) => e.name), isNot(contains('a.txt')),
        reason: 'the folder on screen was re-read');
  });

  test('a copy is named in the language of the window', () {
    bool taken(String n) => n == 'nota.txt' || n == 'nota - Copia.txt';
    expect(copyName('nota.txt', taken, copy: ExplorerStrings.portuguese.copy),
        'nota - Copia (2).txt');
    expect(
        copyName('nota.txt', (String n) => n == 'nota.txt'), 'nota - Copy.txt');
  });
}
