/// Portable folder options. Unknown keys and malformed values are ignored.
library;

final class ExplorerPreferences {
  ExplorerPreferences([Map<String, Object?> values = const {}]) {
    for (final key in defaults.keys) {
      final value = values[key];
      _values[key] = value is bool ? value : defaults[key]!;
    }
  }

  static const defaults = <String, bool>{
    'startThisPc': false,
    'restoreTabs': false,
    'singleClick': false,
    'openFoldersInNewTab': false,
    'showRecent': true,
    'showHidden': false,
    'showExtensions': true,
    'showProtected': false,
    'compact': false,
    'itemCheckboxes': false,
    'showThumbnails': true,
    'showStatusBar': true,
    'showFullPath': false,
    'showFolderTips': true,
    'overlayTooltips': false,
    'rememberFolderViews': true,
    'searchSubfolders': true,
    'navigationPane': true,
    'detailsPane': false,
    'previewPane': false,
  };

  final _values = <String, bool>{};
  bool operator [](String key) => _values[key] ?? false;
  void operator []=(String key, bool value) {
    if (!defaults.containsKey(key)) throw ArgumentError.value(key, 'key');
    _values[key] = value;
  }

  Map<String, bool> toJson() => Map.of(_values);
  ExplorerPreferences copy() => ExplorerPreferences(toJson());
}
