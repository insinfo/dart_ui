/// What a command needs from the window it runs in - and what a command
/// line or a test provides without one.
library;

import 'file_system.dart';

/// The window, as the commands see it.
abstract interface class ExplorerHost {
  /// Puts the keyboard in the address bar, path selected - Ctrl+L.
  void focusAddress();

  void showFolderOptions();
  void showCommands();
  void renameSelection();
  void openTerminal(String directory);

  /// Puts the keyboard in the search box - Ctrl+F.
  void focusSearch();

  /// Shows the Properties of [entries].
  void showProperties(List<FileEntry> entries);

  /// Puts [text] on the system clipboard - Copy as path.
  void copyText(String text);

  /// Closes the window - closing its last tab.
  void closeWindow();
}

/// A host with no window: what tests and scripts run the commands with.
final class HeadlessExplorerHost implements ExplorerHost {
  final List<String> calls = <String>[];
  String? clipboardText;

  @override
  void focusAddress() => calls.add('address');

  @override
  void showFolderOptions() => calls.add('options');

  @override
  void showCommands() => calls.add('commands');
  @override
  void renameSelection() => calls.add('renameSelection');
  @override
  void openTerminal(String directory) => calls.add('terminal $directory');

  @override
  void focusSearch() => calls.add('search');

  @override
  void showProperties(List<FileEntry> entries) =>
      calls.add('properties ${entries.length}');

  @override
  void copyText(String text) => clipboardText = text;

  @override
  void closeWindow() => calls.add('close');
}
