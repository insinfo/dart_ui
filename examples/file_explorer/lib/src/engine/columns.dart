/// The Details column catalog, independent of widgets and native I/O.
library;

import 'file_system.dart';
import 'file_types.dart';
import 'location.dart';
import 'strings.dart';

extension DetailsColumnInfo on DetailsColumn {
  /// Stable grid identity, retaining existing preference keys.
  String get id => switch (this) {
        DetailsColumn.dateModified => 'date',
        DetailsColumn.dateCreated => 'created',
        DetailsColumn.folderPath => 'location',
        DetailsColumn.fullPath => 'path',
        _ => name,
      };

  String get englishLabel => switch (this) {
        DetailsColumn.name => 'Name',
        DetailsColumn.dateModified => 'Date modified',
        DetailsColumn.type => 'Type',
        DetailsColumn.size => 'Size',
        DetailsColumn.dateCreated => 'Date created',
        DetailsColumn.dateAccessed => 'Date accessed',
        DetailsColumn.dateChanged => 'Metadata changed',
        DetailsColumn.extension => 'File extension',
        DetailsColumn.folderPath => 'Folder path',
        DetailsColumn.fullPath => 'Full path',
        DetailsColumn.sizeBytes => 'Size (bytes)',
        DetailsColumn.attributes => 'Attributes',
        DetailsColumn.permissions => 'Permissions',
        DetailsColumn.hidden => 'Hidden',
        DetailsColumn.readOnly => 'Read-only',
        DetailsColumn.linkTarget => 'Link target',
      };

  String label(ExplorerStrings strings) =>
      strings.commandLabels['column.$name'] ?? englishLabel;

  double get defaultWidth => switch (this) {
        DetailsColumn.name => 320,
        DetailsColumn.size => 100,
        DetailsColumn.folderPath ||
        DetailsColumn.fullPath ||
        DetailsColumn.linkTarget =>
          300,
        DetailsColumn.sizeBytes ||
        DetailsColumn.extension ||
        DetailsColumn.attributes ||
        DetailsColumn.hidden ||
        DetailsColumn.readOnly =>
          110,
        _ => 170,
      };

  SortField get sortField => SortField.values.firstWhere((f) => f.name == name);
}

String entryAttributes(FileEntry entry) => [
      if (entry.isReadOnly == true) 'R',
      if (entry.isHidden) 'H',
      if (entry.isSystem) 'S',
      if (entry.isDirectory) 'D',
      if (entry.isSymbolicLink) 'L',
      if (entry.nativeAttributes case final int bits) ...[
        if ((bits & 32) != 0) 'A',
        if ((bits & 256) != 0) 'T',
        if ((bits & 512) != 0) 'P',
        if ((bits & 2048) != 0) 'C',
        if ((bits & 4096) != 0) 'O',
        if ((bits & 8192) != 0) 'I',
        if ((bits & 16384) != 0) 'E',
      ],
    ].join();

/// Empty text represents an unavailable value, never invented metadata.
String columnText(
    DetailsColumn column, FileEntry entry, ExplorerStrings strings,
    {bool showExtensions = true}) {
  String boolean(bool? value) => value == null
      ? ''
      : strings.locale.startsWith('pt')
          ? (value ? 'Sim' : 'Não')
          : (value ? 'Yes' : 'No');
  return switch (column) {
    DetailsColumn.name =>
      showExtensions || !isKnownType(entry) ? entry.name : entry.stem,
    DetailsColumn.dateModified => dateColumn(entry.modified, strings),
    DetailsColumn.dateCreated => dateColumn(entry.created, strings),
    DetailsColumn.dateAccessed => dateColumn(entry.accessed, strings),
    DetailsColumn.dateChanged => dateColumn(entry.changed, strings),
    DetailsColumn.type => typeNameOf(entry, strings),
    DetailsColumn.size => sizeColumn(entry.size, strings),
    DetailsColumn.sizeBytes =>
      entry.size == null ? '' : strings.number(entry.size!),
    DetailsColumn.extension =>
      entry.extension.isEmpty ? '' : '.${entry.extension}',
    DetailsColumn.folderPath => entry.folderPath,
    DetailsColumn.fullPath => entry.path,
    DetailsColumn.attributes => entryAttributes(entry),
    DetailsColumn.permissions => entry.permissions ?? '',
    DetailsColumn.hidden => boolean(entry.isHidden),
    DetailsColumn.readOnly => boolean(entry.isReadOnly),
    DetailsColumn.linkTarget => entry.linkTarget ?? '',
  };
}
