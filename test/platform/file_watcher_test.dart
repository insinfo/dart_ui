import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('file watcher', () {
    test('the desktop platforms support watching', () {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        expect(FileWatcher.isSupported, isTrue);
      }
    });

    test('a missing path is refused eagerly, not as a stream error', () {
      expect(
        () => FileWatcher.watch(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'nothing-here-${DateTime.now().microsecondsSinceEpoch}',
        ),
        throwsA(isA<FileWatcherException>()),
      );
    });

    test('creating a file under a watched directory reports a create',
        () async {
      if (!FileWatcher.isSupported) return;
      final Directory sandbox =
          Directory.systemTemp.createTempSync('dart_ui_watch_test');
      addTearDown(() => sandbox.deleteSync(recursive: true));

      // Wait for the create that names born.txt rather than for the first
      // create of any kind: macOS FSEvents also delivers a create for the
      // watched directory itself, which says nothing about the file.
      final Completer<FileChange> firstCreate = Completer<FileChange>();
      final StreamSubscription<FileChange> subscription =
          FileWatcher.watch(sandbox.path).listen((FileChange change) {
        if (change.kind == FileChangeKind.create &&
            change.path.endsWith('born.txt') &&
            !firstCreate.isCompleted) {
          firstCreate.complete(change);
        }
      });
      addTearDown(subscription.cancel);

      // The watch is established asynchronously on some platforms; give the
      // OS a beat before producing the event.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      File('${sandbox.path}${Platform.pathSeparator}born.txt')
          .writeAsStringSync('x');

      final FileChange change =
          await firstCreate.future.timeout(const Duration(seconds: 10));
      expect(change.path, endsWith('born.txt'));
    });

    test('deleting a watched file reports a delete', () async {
      if (!FileWatcher.isSupported) return;
      final Directory sandbox =
          Directory.systemTemp.createTempSync('dart_ui_watch_del_test');
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final File victim =
          File('${sandbox.path}${Platform.pathSeparator}doomed.txt')
            ..writeAsStringSync('x');

      final Completer<FileChange> firstDelete = Completer<FileChange>();
      final StreamSubscription<FileChange> subscription =
          FileWatcher.watch(sandbox.path).listen((FileChange change) {
        if (change.kind == FileChangeKind.delete &&
            change.path.endsWith('doomed.txt') &&
            !firstDelete.isCompleted) {
          firstDelete.complete(change);
        }
      });
      addTearDown(subscription.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      victim.deleteSync();

      final FileChange change =
          await firstDelete.future.timeout(const Duration(seconds: 10));
      expect(change.path, endsWith('doomed.txt'));
    });
  });
}
