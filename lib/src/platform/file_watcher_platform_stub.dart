library;

import 'file_watcher.dart';

bool isSupported() => false;

Stream<FileChange> watch(String path, {required bool recursive}) {
  throw FileWatcherException(
    path: path,
    reason: 'this target has no filesystem to watch',
  );
}
