import 'dart:io';

import 'package:file_explorer/src/engine/columns.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/file_system.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/sorting.dart';
import 'package:file_explorer/src/engine/strings.dart';
import 'package:file_explorer/src/io/io_file_system.dart';
import 'package:file_explorer/src/io/windows_file_attributes.dart';
import 'package:test/test.dart';

void main() {
  const en = ExplorerStrings.english;
  test('catalog has unique persistent keys, translated labels and real values',
      () {
    expect(DetailsColumn.values.map((c) => c.id).toSet().length,
        DetailsColumn.values.length);
    final e = FileEntry(
        path: r'C:\docs\report.pdf',
        name: 'report.pdf',
        isDirectory: false,
        size: 12345,
        accessed: DateTime(2026, 10, 19),
        permissions: 'r--r--r--',
        isReadOnly: true,
        isHidden: true,
        nativeAttributes: 32);
    expect(e.folderPath, r'C:\docs');
    expect(columnText(DetailsColumn.extension, e, en), '.pdf');
    expect(columnText(DetailsColumn.fullPath, e, en), e.path);
    expect(columnText(DetailsColumn.sizeBytes, e, en), '12,345');
    expect(columnText(DetailsColumn.permissions, e, en), 'r--r--r--');
    expect(columnText(DetailsColumn.dateAccessed, e, en), isNotEmpty);
    expect(columnText(DetailsColumn.attributes, e, en), 'RHA');
    expect(columnText(DetailsColumn.readOnly, e, ExplorerStrings.portuguese),
        'Sim');
    for (final c in DetailsColumn.values) {
      expect(c.label(en), isNotEmpty);
      expect(c.label(ExplorerStrings.portuguese), isNotEmpty);
      expect(() => c.sortField, returnsNormally);
    }
    const missing =
        FileEntry(path: '/folder', name: 'folder', isDirectory: true);
    for (final c in [
      DetailsColumn.dateAccessed,
      DetailsColumn.permissions,
      DetailsColumn.readOnly,
      DetailsColumn.linkTarget,
      DetailsColumn.sizeBytes
    ]) {
      expect(columnText(c, missing, en), '', reason: c.name);
    }
    expect(
        const FileEntry(
                path: r'C:\file.txt', name: 'file.txt', isDirectory: false)
            .folderPath,
        r'C:\');
    expect(
        const FileEntry(path: '/file.txt', name: 'file.txt', isDirectory: false)
            .folderPath,
        '/');
  });

  test(
      'column order and widths survive folder navigation and state restoration',
      () async {
    final fs = MemoryFileSystem()
      ..addFolder('/docs')
      ..addFolder('/pics');
    final m = ExplorerModel(
        fs: fs, places: const {}, start: const FolderLocation('/docs'));
    addTearDown(m.dispose);
    await m.refresh();
    m.configureColumns([
      DetailsColumn.name,
      DetailsColumn.extension,
      DetailsColumn.sizeBytes
    ], {
      'extension': 245,
      'sizeBytes': 130,
      'name': double.nan,
      'invalid': 999
    });
    expect(m.columnWidths, {'extension': 245, 'sizeBytes': 130});
    await m.navigate(const FolderLocation('/pics'));
    expect(m.columns, isNot(contains(DetailsColumn.extension)));
    await m.navigate(const FolderLocation('/docs'));
    expect(m.columns,
        [DetailsColumn.name, DetailsColumn.extension, DetailsColumn.sizeBytes]);
    expect(m.columnWidths['extension'], 245);
    m.configureColumns(m.columns, m.columnWidths);
    expect(m.columns, hasLength(3), reason: 'aliased inputs are safe');
    final restored = ExplorerModel(
        fs: fs, places: const {}, start: const FolderLocation('/docs'));
    addTearDown(restored.dispose);
    restored.restoreState(m.exportState(), restoreSession: false);
    expect(restored.columns, m.columns);
    expect(restored.columnWidths, m.columnWidths);
    await m.search('report');
    m.configureColumns([DetailsColumn.name], {});
    expect(m.visibleColumns, [DetailsColumn.name],
        reason: 'a chosen search column can be hidden');
  });

  test(
      'new sortable fields compare numbers and timestamps rather than formatted text',
      () {
    final a = FileEntry(
        path: '/one/a.pdf',
        name: 'a.pdf',
        isDirectory: false,
        size: 20,
        accessed: DateTime(2026, 1, 2));
    final b = FileEntry(
        path: '/two/b.txt',
        name: 'b.txt',
        isDirectory: false,
        size: 3,
        accessed: DateTime(2026, 1, 1));
    expect(sortEntries([a, b], SortField.sizeBytes, true, en), [b, a]);
    expect(sortEntries([a, b], SortField.dateAccessed, true, en), [b, a]);
    expect(sortEntries([a, b], SortField.extension, true, en), [a, b]);
    for (final field in SortField.values) {
      expect(sortEntries([a, b], field, true, en), hasLength(2));
    }
  });

  test('disk listing supplies access time, mode and bytes from the actual file',
      () async {
    final dir = await Directory.systemTemp.createTemp('explorer-columns-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}${Platform.pathSeparator}report-💾.txt')
        .writeAsString('data');
    final stat = await file.stat();
    final e = (await IoFileSystem().list(dir.path)).single;
    expect(e.size, 4);
    expect(e.permissions, stat.modeString());
    expect(e.accessed, stat.accessed);
    expect(e.created, Platform.isWindows ? stat.changed : null);
    expect(e.changed, Platform.isWindows ? null : stat.changed);
    expect(e.folderPath, dir.path);
  });

  test('symbolic link targets come from the file system', () async {
    final dir = await Directory.systemTemp.createTemp('explorer-link-columns-');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/source.txt').writeAsString('source');
    await Link('${dir.path}/alias.txt').create('source.txt');
    final link = (await IoFileSystem().list(dir.path))
        .firstWhere((e) => e.name == 'alias.txt');
    expect(link.isSymbolicLink, isTrue);
    expect(link.linkTarget, 'source.txt');
  },
      skip: Platform.isWindows
          ? 'symbolic links require Windows privileges'
          : false);

  test(
      'Windows attributes use Unicode native paths and real hidden/read-only bits',
      () async {
    final dir = await Directory.systemTemp.createTemp('explorer-attributes-');
    final file =
        await File('${dir.path}\\arquivo-💾.txt').writeAsString('data');
    try {
      final result = await Process.run('attrib', ['+R', '+H', file.path]);
      expect(result.exitCode, 0);
      final e = (await IoFileSystem().list(dir.path)).single;
      expect(e.isReadOnly, isTrue);
      expect(e.isHidden, isTrue);
      expect(readWindowsFileAttributes(file.path)! & 3, 3);
      final nested = Directory([
        dir.path,
        ...List.filled(9, 'long-folder-name-0123456789')
      ].join(Platform.pathSeparator));
      await nested.create(recursive: true);
      final longFile =
          await File('${nested.path}${Platform.pathSeparator}wide-💾.txt')
              .writeAsString('data');
      expect(longFile.path.length, greaterThan(260));
      expect(
          readWindowsFileAttributes(
              longFile.path.replaceAll(Platform.pathSeparator, '/')),
          isNotNull);
    } finally {
      await Process.run('attrib', ['-R', '-H', file.path]);
      await dir.delete(recursive: true);
    }
  }, skip: Platform.isWindows ? false : 'needs Windows file attributes');
}
