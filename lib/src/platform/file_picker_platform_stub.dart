library;

import 'file_picker_types.dart';

Future<PickedFile?> openFile({
  required String title,
  required List<FilePickerFilter> filters,
  required int ownerWindowHandle,
}) async {
  throw const FilePickerException(
    operation: 'openFile',
    reason: 'this target has no file-picker implementation',
  );
}
