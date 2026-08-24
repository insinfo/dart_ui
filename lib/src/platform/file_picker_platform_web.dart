library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_picker_types.dart';

Future<PickedFile?> openFile({
  required String title,
  required List<FilePickerFilter> filters,
  required int ownerWindowHandle,
}) {
  final Completer<PickedFile?> completer = Completer<PickedFile?>();
  final web.HTMLInputElement input =
      web.document.createElement('input') as web.HTMLInputElement;
  input
    ..type = 'file'
    ..multiple = false
    ..accept = filters.map((FilePickerFilter value) => value.accept).join(',');
  input.style.display = 'none';
  web.document.body?.append(input);

  void finish(PickedFile? value) {
    input.remove();
    if (!completer.isCompleted) completer.complete(value);
  }

  late final JSFunction onChange;
  late final JSFunction onCancel;
  onChange = ((web.Event event) {
    final web.FileList? files = input.files;
    if (files == null || files.length == 0) {
      finish(null);
      return;
    }
    final web.File? file = files.item(0);
    if (file == null) {
      finish(null);
      return;
    }
    file.arrayBuffer().toDart.then((JSArrayBuffer buffer) {
      finish(
        PickedFile(
          name: file.name,
          bytes: buffer.toDart.asUint8List(),
        ),
      );
    }).catchError((Object error) {
      input.remove();
      if (!completer.isCompleted) {
        completer.completeError(
          FilePickerException(
            operation: 'File.arrayBuffer',
            platform: 'web',
            reason: '$error',
          ),
        );
      }
    });
  }).toJS;
  onCancel = ((web.Event event) => finish(null)).toJS;
  input
    ..addEventListener('change', onChange)
    ..addEventListener('cancel', onCancel)
    ..click();
  return completer.future;
}

/// Always null: a browser exposes no path to save to.
///
/// Not an exception, because "there is no save dialog here" is a fact about the
/// platform rather than a failure, and a caller that has a download fallback
/// should be able to take it without catching.
Future<String?> saveFile({
  required String title,
  required String suggestedName,
  required List<FilePickerFilter> filters,
  required String? defaultExtension,
  required int ownerWindowHandle,
}) async =>
    null;
