library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_picker_types.dart';

Future<PickedFile?> openFile({
  required String title,
  required List<FilePickerFilter> filters,
  required int ownerWindowHandle,
}) async {
  final List<PickedFile> files = await _pick(filters, multiple: false);
  return files.isEmpty ? null : files.first;
}

Future<List<PickedFile>> openFiles({
  required String title,
  required List<FilePickerFilter> filters,
  required int ownerWindowHandle,
}) =>
    _pick(filters, multiple: true);

/// Always null: a browser exposes no folder paths. See [saveFile].
Future<String?> pickDirectory({
  required String title,
  required int ownerWindowHandle,
}) async =>
    null;

/// The browser's file input, one file or many; empty when cancelled.
Future<List<PickedFile>> _pick(
  List<FilePickerFilter> filters, {
  required bool multiple,
}) {
  final Completer<List<PickedFile>> completer = Completer<List<PickedFile>>();
  final web.HTMLInputElement input =
      web.document.createElement('input') as web.HTMLInputElement;
  input
    ..type = 'file'
    ..multiple = multiple
    ..accept = filters.map((FilePickerFilter value) => value.accept).join(',');
  input.style.display = 'none';
  web.document.body?.append(input);

  void finish(List<PickedFile> value) {
    input.remove();
    if (!completer.isCompleted) completer.complete(value);
  }

  void fail(Object error) {
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
  }

  late final JSFunction onChange;
  late final JSFunction onCancel;
  onChange = ((web.Event event) {
    final web.FileList? list = input.files;
    if (list == null || list.length == 0) {
      finish(const <PickedFile>[]);
      return;
    }
    final List<web.File> chosen = <web.File>[
      for (var i = 0; i < list.length; i++)
        if (list.item(i) case final web.File file) file,
    ];
    Future.wait(<Future<PickedFile>>[
      for (final web.File file in chosen)
        file.arrayBuffer().toDart.then((JSArrayBuffer buffer) => PickedFile(
              name: file.name,
              bytes: buffer.toDart.asUint8List(),
            )),
    ]).then(finish).catchError(fail);
  }).toJS;
  onCancel = ((web.Event event) => finish(const <PickedFile>[])).toJS;
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
