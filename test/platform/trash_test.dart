import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/platform/trash_platform_io.dart' as trash_io;
import 'package:test/test.dart';

void main() {
  group('trashinfo bookkeeping (pure)', () {
    test('paths are percent-encoded per octet with / kept literal', () {
      expect(encodeTrashPath('/home/isaque/a b.txt'), '/home/isaque/a%20b.txt');
      expect(encodeTrashPath('/home/isaque/relatório.pdf'),
          '/home/isaque/relat%C3%B3rio.pdf');
      expect(encodeTrashPath('/plain/path-with_safe.chars~'),
          '/plain/path-with_safe.chars~');
    });

    test('deletion dates are local YYYY-MM-DDThh:mm:ss', () {
      final DateTime moment = DateTime(2026, 8, 22, 9, 5, 3);
      expect(formatTrashDeletionDate(moment), '2026-08-22T09:05:03');
    });

    test('the .trashinfo content is the spec layout, byte for byte', () {
      expect(
        buildTrashInfo(
          originalPath: '/home/isaque/velho arquivo.txt',
          deletedAt: DateTime(2026, 1, 2, 3, 4, 5),
        ),
        '[Trash Info]\n'
        'Path=/home/isaque/velho%20arquivo.txt\n'
        'DeletionDate=2026-01-02T03:04:05\n',
      );
    });

    test('collisions count upward in the platform naming style', () {
      final Set<String> taken = <String>{'report.pdf', 'report.2.pdf'};
      expect(disambiguateTrashName('free.pdf', taken.contains), 'free.pdf');
      expect(
          disambiguateTrashName('report.pdf', taken.contains), 'report.3.pdf');
      expect(
        disambiguateTrashName('report.pdf', <String>{'report.pdf'}.contains,
            separator: ' '),
        'report 2.pdf',
        reason: 'the Finder style appends after the stem with a space',
      );
      expect(
        disambiguateTrashName('.bashrc', <String>{'.bashrc'}.contains),
        '.bashrc.2',
        reason: 'a dotfile has no extension to split on',
      );
    });
  });

  group('freedesktop trash (real filesystem, injected root)', () {
    late Directory sandbox;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('dart_ui_trash_test');
    });

    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    String forwardSlashes(String path) => path.replaceAll(r'\', '/');

    test('moves the file into files/ and writes the matching info file',
        () async {
      final String root = forwardSlashes(sandbox.path);
      final File victim = File('$root/victim.txt')..writeAsStringSync('bytes');
      await trash_io.moveToFreedesktopTrash(
        forwardSlashes(victim.path),
        trashRoot: '$root/Trash',
        now: DateTime(2026, 8, 22, 10, 30),
      );

      expect(victim.existsSync(), isFalse);
      expect(File('$root/Trash/files/victim.txt').readAsStringSync(), 'bytes');
      final String info =
          File('$root/Trash/info/victim.txt.trashinfo').readAsStringSync();
      expect(info, startsWith('[Trash Info]\n'));
      // The root is a Windows temp path in this suite, and its drive colon
      // is (correctly) percent-encoded, so compare against the encoder.
      expect(info, contains('Path=${encodeTrashPath('$root/victim.txt')}'));
      expect(info, contains('DeletionDate=2026-08-22T10:30:00'));
    });

    test('a second file of the same name gets the next free name', () async {
      final String root = forwardSlashes(sandbox.path);
      for (var round = 0; round < 2; round++) {
        File('$root/victim.txt').writeAsStringSync('round $round');
        await trash_io.moveToFreedesktopTrash(
          '$root/victim.txt',
          trashRoot: '$root/Trash',
        );
      }
      expect(
          File('$root/Trash/files/victim.txt').readAsStringSync(), 'round 0');
      expect(
          File('$root/Trash/files/victim.2.txt').readAsStringSync(), 'round 1');
      expect(
          File('$root/Trash/info/victim.2.txt.trashinfo').existsSync(), isTrue);
    });

    test('a directory is trashed whole', () async {
      final String root = forwardSlashes(sandbox.path);
      Directory('$root/folder/nested').createSync(recursive: true);
      File('$root/folder/nested/inner.txt').writeAsStringSync('x');
      await trash_io.moveToFreedesktopTrash(
        '$root/folder',
        trashRoot: '$root/Trash',
      );
      expect(Directory('$root/folder').existsSync(), isFalse);
      expect(File('$root/Trash/files/folder/nested/inner.txt').existsSync(),
          isTrue);
    });
  });

  group('macOS trash naming (real filesystem, injected directory)', () {
    test('collides into "name 2.ext", the Finder way', () async {
      final Directory sandbox =
          Directory.systemTemp.createTempSync('dart_ui_mac_trash_test');
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final String root = sandbox.path.replaceAll(r'\', '/');

      for (var round = 0; round < 2; round++) {
        File('$root/a.txt').writeAsStringSync('round $round');
        await trash_io.moveToMacTrash('$root/a.txt',
            trashDirectory: '$root/.Trash');
      }
      expect(File('$root/.Trash/a.txt').readAsStringSync(), 'round 0');
      expect(File('$root/.Trash/a 2.txt').readAsStringSync(), 'round 1');
    });
  });

  group('the public port', () {
    test('a missing path is a named failure, not a platform call', () {
      expect(
        () => Trash.moveToTrash(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'never-existed-${DateTime.now().microsecondsSinceEpoch}.txt',
        ),
        throwsA(isA<TrashException>()),
      );
    });

    test('windows really recycles a temp file', () async {
      if (!Platform.isWindows) return;
      final File victim = File(
        '${Directory.systemTemp.path}\\dart_ui_recycle_'
        '${DateTime.now().microsecondsSinceEpoch}.txt',
      )..writeAsStringSync('created by dart_ui trash_test; safe to delete');

      await Trash.moveToTrash(victim.path);

      expect(victim.existsSync(), isFalse,
          reason: 'the file must be gone from its original path');
    });
  });
}
