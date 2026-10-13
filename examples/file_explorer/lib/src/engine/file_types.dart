/// What a file is - its kind, the type name Explorer's Type column shows -
/// and how sizes and dates are written.
library;

import 'file_system.dart';
import 'strings.dart';

/// The families of files the explorer draws an icon for.
enum FileKind {
  folder,
  drive,
  text,
  document,
  spreadsheet,
  presentation,
  pdf,
  image,
  audio,
  video,
  archive,
  code,
  executable,
  font,
  generic,
}

const Map<String, FileKind> _kinds = <String, FileKind>{
  'txt': FileKind.text,
  'md': FileKind.text,
  'log': FileKind.text,
  'csv': FileKind.spreadsheet,
  'rtf': FileKind.document,
  'doc': FileKind.document,
  'docx': FileKind.document,
  'odt': FileKind.document,
  'xls': FileKind.spreadsheet,
  'xlsx': FileKind.spreadsheet,
  'ods': FileKind.spreadsheet,
  'ppt': FileKind.presentation,
  'pptx': FileKind.presentation,
  'odp': FileKind.presentation,
  'key': FileKind.presentation,
  'pdf': FileKind.pdf,
  'png': FileKind.image,
  'jpg': FileKind.image,
  'jpeg': FileKind.image,
  'gif': FileKind.image,
  'bmp': FileKind.image,
  'webp': FileKind.image,
  'svg': FileKind.image,
  'ico': FileKind.image,
  'heic': FileKind.image,
  'tif': FileKind.image,
  'tiff': FileKind.image,
  'cdr': FileKind.image,
  'mp3': FileKind.audio,
  'wav': FileKind.audio,
  'flac': FileKind.audio,
  'ogg': FileKind.audio,
  'm4a': FileKind.audio,
  'aac': FileKind.audio,
  'mp4': FileKind.video,
  'mov': FileKind.video,
  'mkv': FileKind.video,
  'avi': FileKind.video,
  'webm': FileKind.video,
  'wmv': FileKind.video,
  'zip': FileKind.archive,
  'rar': FileKind.archive,
  '7z': FileKind.archive,
  'tar': FileKind.archive,
  'gz': FileKind.archive,
  'tgz': FileKind.archive,
  'dart': FileKind.code,
  'js': FileKind.code,
  'ts': FileKind.code,
  'py': FileKind.code,
  'java': FileKind.code,
  'c': FileKind.code,
  'cpp': FileKind.code,
  'h': FileKind.code,
  'cs': FileKind.code,
  'go': FileKind.code,
  'rs': FileKind.code,
  'json': FileKind.code,
  'yaml': FileKind.code,
  'yml': FileKind.code,
  'xml': FileKind.code,
  'html': FileKind.code,
  'css': FileKind.code,
  'sh': FileKind.code,
  'exe': FileKind.executable,
  'msi': FileKind.executable,
  'app': FileKind.executable,
  'bat': FileKind.executable,
  'cmd': FileKind.executable,
  'dmg': FileKind.executable,
  'ttf': FileKind.font,
  'otf': FileKind.font,
  'woff': FileKind.font,
};

/// Type names Windows shows for common extensions, by language.
const Map<String, (String, String)> _typeNames = <String, (String, String)>{
  'txt': ('Text Document', 'Documento de Texto'),
  'md': ('Markdown File', 'Arquivo Markdown'),
  'pdf': ('PDF Document', 'Documento PDF'),
  'doc': (
    'Microsoft Word 97-2003 Document',
    'Documento do Microsoft Word 97-2003'
  ),
  'docx': ('Microsoft Word Document', 'Documento do Microsoft Word'),
  'xlsx': ('Microsoft Excel Worksheet', 'Planilha do Microsoft Excel'),
  'pptx': (
    'Microsoft PowerPoint Presentation',
    'Apresentação do Microsoft PowerPoint'
  ),
  'png': ('PNG File', 'Arquivo PNG'),
  'jpg': ('JPG File', 'Arquivo JPG'),
  'jpeg': ('JPEG File', 'Arquivo JPEG'),
  'gif': ('GIF File', 'Arquivo GIF'),
  'svg': ('SVG Document', 'Documento SVG'),
  'mp3': ('MP3 File', 'Arquivo MP3'),
  'mp4': ('MP4 File', 'Arquivo MP4'),
  'zip': ('Compressed (zipped) Folder', 'Pasta compactada'),
  'exe': ('Application', 'Aplicativo'),
  'json': ('JSON File', 'Arquivo JSON'),
  'dart': ('Dart File', 'Arquivo Dart'),
  'html': ('HTML Document', 'Documento HTML'),
  'csv': (
    'Microsoft Excel Comma Separated Values File',
    'Arquivo de Valores Separados por Vírgula do Microsoft Excel'
  ),
  'ttf': ('TrueType font file', 'Arquivo de fonte TrueType'),
};

/// What [entry] is.
FileKind kindOf(FileEntry entry) => entry.isDirectory
    ? FileKind.folder
    : _kinds[entry.extension] ?? FileKind.generic;

/// The Type column: "File folder", "Text Document", "XYZ File", "File".
String typeNameOf(FileEntry entry, ExplorerStrings strings) {
  if (entry.isDirectory) return strings.fileFolder;
  final String ext = entry.extension;
  if (ext.isEmpty) return strings.file;
  final (String, String)? known = _typeNames[ext];
  if (known != null) {
    return strings.locale.startsWith('pt') ? known.$2 : known.$1;
  }
  return strings.fileOfType(ext);
}

/// The Size column: kilobytes rounded up, with thousands marks - "1 KB",
/// "1,234 KB" - the way Explorer's Details view writes every file size.
String sizeColumn(int? bytes, ExplorerStrings strings) {
  if (bytes == null) return '';
  final int kb = bytes == 0 ? 0 : (bytes + 1023) ~/ 1024;
  final String digits = kb.toString();
  final String mark = strings.locale.startsWith('pt') ? '.' : ',';
  final StringBuffer out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(mark);
    out.write(digits[i]);
  }
  return '$out KB';
}

/// A size as the status bar and Properties write it: "512 bytes",
/// "4.50 MB", "1.20 GB" (with a comma in Portuguese).
String humanSize(int bytes, ExplorerStrings strings) {
  final bool pt = strings.locale.startsWith('pt');
  if (bytes < 1024) return '$bytes bytes';
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final String text = value >= 100
      ? value.toStringAsFixed(0)
      : value >= 10
          ? value.toStringAsFixed(1)
          : value.toStringAsFixed(2);
  return '${pt ? text.replaceAll('.', ',') : text} ${units[unit]}';
}

/// The Date modified column: "13/10/2026 02:21" in Portuguese,
/// "10/13/2026 2:21 AM" in English.
String dateColumn(DateTime? date, ExplorerStrings strings) {
  if (date == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  if (strings.locale.startsWith('pt')) {
    return '${two(date.day)}/${two(date.month)}/${date.year} '
        '${two(date.hour)}:${two(date.minute)}';
  }
  final int hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  return '${date.month}/${date.day}/${date.year} '
      '$hour:${two(date.minute)} ${date.hour < 12 ? 'AM' : 'PM'}';
}
