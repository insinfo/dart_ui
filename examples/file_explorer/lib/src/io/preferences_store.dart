/// Per-user preferences, written in order with an atomic replacement.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../engine/explorer_model.dart';

final class PreferencesStore {
  PreferencesStore(this.file);
  final File file;
  Timer? _timer;
  Future<void> _writes = Future.value();
  ExplorerModel? _model;
  String? lastError;

  Future<void> load(ExplorerModel model, {bool restoreSession = true}) async {
    try {
      if (!await file.exists()) return;
      if (await file.length() > 4 * 1024 * 1024) {
        throw const FormatException('Preferences are too large');
      }
      final data = jsonDecode(await file.readAsString());
      if (data is Map<String, dynamic>) {
        model.restoreState(data, restoreSession: restoreSession);
      }
    } on Object catch (error) {
      lastError = '$error';
    }
  }

  void attach(ExplorerModel model) {
    _model = model;
    model.addListener(_changed);
  }

  void _changed() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 350), save);
  }

  Future<void> save() {
    final model = _model;
    if (model == null) return _writes;
    final contents = jsonEncode(model.exportState());
    _writes = _writes.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.$pid.tmp');
        await temporary.writeAsString(contents, flush: true);
        await temporary.rename(file.path);
        lastError = null;
      } on Object catch (error) {
        lastError = '$error';
      }
    });
    return _writes;
  }

  Future<void> close() async {
    _timer?.cancel();
    _model?.removeListener(_changed);
    await save();
    _model = null;
  }
}
