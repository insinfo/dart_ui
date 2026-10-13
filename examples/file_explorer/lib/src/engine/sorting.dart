/// Explorer's order: folders before files, names compared the way people
/// count - `file2` before `file10` - and without regard to case.
library;

import 'file_system.dart';
import 'file_types.dart';
import 'location.dart';
import 'strings.dart';

/// Compares [a] and [b] like `StrCmpLogicalW`: runs of digits by their
/// value, everything else by letter, case folded.
int naturalCompare(String a, String b) {
  final String x = a.toLowerCase();
  final String y = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < x.length && j < y.length) {
    final int cx = x.codeUnitAt(i);
    final int cy = y.codeUnitAt(j);
    final bool dx = cx >= 0x30 && cx <= 0x39;
    final bool dy = cy >= 0x30 && cy <= 0x39;
    if (dx && dy) {
      var ei = i;
      while (ei < x.length && _digit(x.codeUnitAt(ei))) {
        ei++;
      }
      var ej = j;
      while (ej < y.length && _digit(y.codeUnitAt(ej))) {
        ej++;
      }
      final String nx = x.substring(i, ei).replaceFirst(RegExp('^0+'), '');
      final String ny = y.substring(j, ej).replaceFirst(RegExp('^0+'), '');
      if (nx.length != ny.length) return nx.length.compareTo(ny.length);
      final int byValue = nx.compareTo(ny);
      if (byValue != 0) return byValue;
      i = ei;
      j = ej;
      continue;
    }
    if (cx != cy) return cx.compareTo(cy);
    i++;
    j++;
  }
  return (x.length - i).compareTo(y.length - j);
}

bool _digit(int c) => c >= 0x30 && c <= 0x39;

/// [entries] in the order [field] and [ascending] ask for, folders first.
List<FileEntry> sortEntries(List<FileEntry> entries, SortField field,
    bool ascending, ExplorerStrings strings) {
  int byName(FileEntry a, FileEntry b) => naturalCompare(a.name, b.name);
  int compare(FileEntry a, FileEntry b) {
    final int primary = switch (field) {
      SortField.name => byName(a, b),
      SortField.dateModified =>
        (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
      SortField.type =>
        naturalCompare(typeNameOf(a, strings), typeNameOf(b, strings)),
      SortField.size => (a.size ?? -1).compareTo(b.size ?? -1),
    };
    final int ordered = primary != 0 ? primary : byName(a, b);
    return ascending ? ordered : -ordered;
  }

  final List<FileEntry> folders = <FileEntry>[
    for (final FileEntry e in entries)
      if (e.isDirectory) e,
  ]..sort(compare);
  final List<FileEntry> files = <FileEntry>[
    for (final FileEntry e in entries)
      if (!e.isDirectory) e,
  ]..sort(compare);
  return <FileEntry>[...folders, ...files];
}
