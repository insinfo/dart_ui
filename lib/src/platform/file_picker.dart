library;

import 'file_picker_platform_stub.dart'
    if (dart.library.io) 'file_picker_platform_io.dart'
    if (dart.library.js_interop) 'file_picker_platform_web.dart' as platform;
import 'file_picker_types.dart';

export 'file_picker_types.dart';

/// Opens the operating system's file-selection surface.
///
/// The result always carries bytes. Desktop implementations additionally
/// expose the selected path, while browsers correctly leave it null.
abstract final class FilePicker {
  static Future<PickedFile?> openFile({
    String title = 'Open file',
    List<FilePickerFilter> filters = const <FilePickerFilter>[],
    int ownerWindowHandle = 0,
  }) =>
      platform.openFile(
        title: title,
        filters: filters,
        ownerWindowHandle: ownerWindowHandle,
      );

  /// Asks the operating system where to write a file, returning its path.
  ///
  /// A path and not bytes, because saving is the other direction: the caller
  /// still has to write the file, and doing that through this API would mean
  /// buffering an arbitrarily large document in memory to hand it back.
  ///
  /// Null means the user cancelled. **Null on the web means something else and
  /// callers must treat it as such**: a browser has no file system to point
  /// at, so the web implementation always returns null and the caller is
  /// expected to fall back to a download. The two are distinguishable by
  /// platform, not by return value, which is stated here rather than left to be
  /// discovered.
  ///
  /// [defaultExtension] is appended by the platform when the user types a name
  /// with none - `lpstrDefExt` on Windows - so "drawing" becomes "drawing.svg".
  static Future<String?> saveFile({
    String title = 'Save file',
    String suggestedName = '',
    List<FilePickerFilter> filters = const <FilePickerFilter>[],
    String? defaultExtension,
    int ownerWindowHandle = 0,
  }) =>
      platform.saveFile(
        title: title,
        suggestedName: suggestedName,
        filters: filters,
        defaultExtension: defaultExtension,
        ownerWindowHandle: ownerWindowHandle,
      );
}
