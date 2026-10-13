/// What the Properties dialog says about a selection: the sums it walks the
/// folders for, and the rows of its General tab, worded per language.
library;

import 'file_system.dart';
import 'file_types.dart';
import 'strings.dart';

/// Files, folders and bytes under a selection, folders walked to the bottom.
final class Tally {
  const Tally({this.files = 0, this.folders = 0, this.bytes = 0});

  final int files;
  final int folders;
  final int bytes;

  Tally operator +(Tally other) => Tally(
        files: files + other.files,
        folders: folders + other.folders,
        bytes: bytes + other.bytes,
      );

  @override
  bool operator ==(Object other) =>
      other is Tally &&
      other.files == files &&
      other.folders == folders &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(files, folders, bytes);

  @override
  String toString() => 'Tally($files files, $folders folders, $bytes bytes)';
}

/// Counts what [entries] hold, the folders walked recursively - Windows'
/// "Contains" and the size of a folder.
///
/// [progress] hears the running total as each folder is read, so a dialog
/// open on a large folder counts up as Explorer's does; [cancelled] is asked
/// between folders, and a closed dialog stops the walk there. A folder that
/// cannot be read is skipped, as Explorer skips it.
Future<Tally> tally(
  FileSystem fs,
  List<FileEntry> entries, {
  void Function(Tally running)? progress,
  bool Function()? cancelled,
}) async {
  var total = const Tally();
  final List<String> pending = <String>[];
  for (final FileEntry entry in entries) {
    if (entry.isDirectory) {
      pending.add(entry.path);
    } else {
      total += Tally(files: 1, bytes: entry.size ?? 0);
    }
  }
  while (pending.isNotEmpty) {
    if (cancelled?.call() ?? false) break;
    final String folder = pending.removeLast();
    final List<FileEntry> children;
    try {
      children = await fs.list(folder);
    } on FileSystemError {
      continue;
    }
    for (final FileEntry child in children) {
      if (child.isDirectory) {
        total += const Tally(folders: 1);
        pending.add(child.path);
      } else {
        total += Tally(files: 1, bytes: child.size ?? 0);
      }
    }
    progress?.call(total);
  }
  return total;
}

/// "1,04 KB (1.071 bytes)" - the size and the exact count, as Windows
/// writes both.
String exactSize(int bytes, ExplorerStrings strings) {
  final String count = '${strings.number(bytes)} bytes';
  return bytes < 1024 ? count : '${humanSize(bytes, strings)} ($count)';
}

/// "12 Files, 3 Folders" / "12 arquivos, 3 pastas".
String containsText(Tally tally, ExplorerStrings strings) {
  final bool pt = strings.locale.startsWith('pt');
  String files(int n) => pt
      ? '${strings.number(n)} ${n == 1 ? 'arquivo' : 'arquivos'}'
      : '${strings.number(n)} ${n == 1 ? 'File' : 'Files'}';
  String folders(int n) => pt
      ? '${strings.number(n)} ${n == 1 ? 'pasta' : 'pastas'}'
      : '${strings.number(n)} ${n == 1 ? 'Folder' : 'Folders'}';
  return '${files(tally.files)}, ${folders(tally.folders)}';
}

const List<String> _weekdaysEn = <String>[
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
  'Sunday',
];
const List<String> _weekdaysPt = <String>[
  'segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', //
  'sexta-feira', 'sábado', 'domingo',
];
const List<String> _monthsEn = <String>[
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];
const List<String> _monthsPt = <String>[
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', //
  'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
];

/// The long date Properties shows: "Friday, January 3, 2025, 10:00:00 AM",
/// "sexta-feira, 3 de janeiro de 2025, 10:00:00".
String longDate(DateTime date, ExplorerStrings strings) {
  String two(int n) => n.toString().padLeft(2, '0');
  if (strings.locale.startsWith('pt')) {
    return '${_weekdaysPt[date.weekday - 1]}, ${date.day} de '
        '${_monthsPt[date.month - 1]} de ${date.year}, '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }
  final int hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  return '${_weekdaysEn[date.weekday - 1]}, ${_monthsEn[date.month - 1]} '
      '${date.day}, ${date.year}, $hour:${two(date.minute)}:'
      '${two(date.second)} ${date.hour < 12 ? 'AM' : 'PM'}';
}

/// The title of the dialog: "notes.txt Properties", "Propriedades de
/// notes.txt"; for several items, the first one's name and ", ...".
String propertiesTitle(List<FileEntry> entries, ExplorerStrings strings) {
  final String name =
      entries.length == 1 ? entries.single.name : '${entries.first.name}, ...';
  return strings.locale.startsWith('pt')
      ? 'Propriedades de $name'
      : '$name Properties';
}

/// "Text Document (.txt)", or for several items "Multiple types" unless
/// they share one, and "All of type ...".
String typeText(List<FileEntry> entries, ExplorerStrings strings) {
  final bool pt = strings.locale.startsWith('pt');
  final Set<String> types = <String>{
    for (final FileEntry e in entries) typeNameOf(e, strings),
  };
  if (entries.length > 1) {
    if (types.length > 1) return pt ? 'Vários tipos' : 'Multiple types';
    return pt ? 'Todos do tipo ${types.single}' : 'All of type ${types.single}';
  }
  final FileEntry entry = entries.single;
  return entry.extension.isEmpty
      ? types.single
      : '${types.single} (.${entry.extension})';
}

/// The folder the items are in, or "Various locations" / "Vários locais"
/// when a search gathered them from more than one.
String locationText(
  List<FileEntry> entries,
  FileSystem fs,
  ExplorerStrings strings,
) {
  final Set<String?> folders = <String?>{
    for (final FileEntry e in entries) fs.parentOf(e.path),
  };
  if (folders.length > 1) {
    return strings.locale.startsWith('pt')
        ? 'Vários locais'
        : 'Various locations';
  }
  return folders.single ?? '';
}
