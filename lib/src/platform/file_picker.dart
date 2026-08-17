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
}
