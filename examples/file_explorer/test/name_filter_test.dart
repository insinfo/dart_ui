import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/file_system.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/name_filter.dart';
import 'package:test/test.dart';

void main() {
  test('name buckets cover digits, Latin accents, other scripts and symbols',
      () {
    for (final name in ['apple', 'Home', 'Árvore', 'e\u0301clair', 'ç']) {
      expect(NameRange.of(name), NameRange.aToH, reason: name);
    }
    for (final name in ['Índice', 'OBTS.pdf', 'pasta', 'Ñome']) {
      expect(NameRange.of(name), NameRange.iToP, reason: name);
    }
    for (final name in ['ubuntu.iso', 'Zulu', 'résumé']) {
      expect(NameRange.of(name), NameRange.qToZ, reason: name);
    }
    expect(NameRange.of('7 files'), NameRange.digits);
    for (final name in ['', '_name', '文書', '🗂folder']) {
      expect(NameRange.of(name), NameRange.other, reason: name);
    }
  });

  test('ranges combine, retain choices, refresh and clear on navigation',
      () async {
    final fs = MemoryFileSystem()
      ..addFolder('/files')
      ..addFolder('/other')
      ..addFile('/files/OBTS.pdf')
      ..addFile('/files/ubuntu.iso');
    final model = ExplorerModel(fs: fs, places: const {});
    addTearDown(model.dispose);
    await model.navigate(const FolderLocation('/files'));
    expect(model.availableNameRanges, {NameRange.iToP, NameRange.qToZ});
    model.select(['/files/ubuntu.iso']);
    model.setNameRanges([NameRange.iToP]);
    expect(model.tab.visible.map((e) => e.name), ['OBTS.pdf']);
    expect(model.tab.selection, isEmpty);
    expect(model.availableNameRanges, {NameRange.iToP, NameRange.qToZ});
    model.setNameRanges([NameRange.iToP, NameRange.qToZ]);
    expect(model.tab.visible, hasLength(2));
    model.setNameRanges([NameRange.aToH]);
    expect(model.tab.visible, isEmpty);
    expect(model.availableNameRanges, contains(NameRange.aToH));
    fs.addFile('/files/apple.txt');
    await model.refresh();
    expect(model.tab.visible.map((e) => e.name), ['apple.txt']);
    model.setNameRanges([]);
    expect(model.tab.visible, hasLength(3));
    model.setNameRanges([NameRange.iToP]);
    await model.navigate(const FolderLocation('/other'));
    expect(model.tab.nameRanges, isEmpty);
    await model.goBack();
    expect(model.tab.nameRanges, isEmpty);
    expect(model.tab.visible, hasLength(3));
  });
}
