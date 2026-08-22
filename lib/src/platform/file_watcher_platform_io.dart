library;

import 'dart:io';

import 'file_watcher.dart';

bool isSupported() => FileSystemEntity.isWatchSupported;

Stream<FileChange> watch(String path, {required bool recursive}) {
  if (!FileSystemEntity.isWatchSupported) {
    throw FileWatcherException(
      path: path,
      reason: 'this platform does not deliver filesystem events',
    );
  }
  final FileSystemEntityType type = FileSystemEntity.typeSync(path);
  final Stream<FileSystemEvent> events;
  switch (type) {
    case FileSystemEntityType.directory:
      events = Directory(path)
          .watch(events: FileSystemEvent.all, recursive: recursive);
    case FileSystemEntityType.file:
      events = File(path).watch(events: FileSystemEvent.all);
    case FileSystemEntityType.notFound:
      throw FileWatcherException(
        path: path,
        reason: 'the path does not exist',
      );
    default:
      throw FileWatcherException(
        path: path,
        reason: 'the path is neither a file nor a directory',
      );
  }
  return events.map(_translate);
}

FileChange _translate(FileSystemEvent event) => switch (event) {
      FileSystemCreateEvent() =>
        FileChange(path: event.path, kind: FileChangeKind.create),
      FileSystemModifyEvent() =>
        FileChange(path: event.path, kind: FileChangeKind.modify),
      FileSystemDeleteEvent() =>
        FileChange(path: event.path, kind: FileChangeKind.delete),
      FileSystemMoveEvent(:final String? destination) => FileChange(
          path: event.path,
          kind: FileChangeKind.move,
          destination: destination,
        ),
    };
