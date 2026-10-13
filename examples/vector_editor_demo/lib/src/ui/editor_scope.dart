/// The editor's window state, commands and menus, for any widget under it.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'editor_ui.dart';
import 'menus.dart';

/// Gives the widgets of an editor window - and of a panel floating in a
/// window of its own - the same [registry] and [menus]: a row's right-click
/// menu and a toolbar button run the same commands as the menu bar.
final class EditorScope extends InheritedWidget {
  const EditorScope({
    super.key,
    required this.ui,
    required this.registry,
    required this.menus,
    required super.child,
  });

  final EditorUi ui;
  final CommandRegistry registry;
  final EditorMenus menus;

  EditorModel get model => ui.model;

  /// The scope above [context], or null outside an editor window.
  static EditorScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EditorScope>();

  @override
  bool updateShouldNotify(EditorScope oldWidget) =>
      !identical(ui, oldWidget.ui) ||
      !identical(registry, oldWidget.registry) ||
      !identical(menus, oldWidget.menus);
}
