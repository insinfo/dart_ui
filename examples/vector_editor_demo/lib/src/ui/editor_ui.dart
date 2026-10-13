/// What the window adds to the editor: its look, its panels, where its
/// menus are - and the commands that change them.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'workspace.dart';

/// Which look the editor wears.
enum EditorThemeMode {
  system('Follow the system'),
  dark('Dark'),
  light('Light');

  const EditorThemeMode(this.label);

  final String label;
}

/// The window's own state - nothing a document is made of.
///
/// Kept out of [EditorModel] on purpose: the model is the drawing and the
/// editing of it, and runs headless; the theme, the docking layout and the
/// menu bar exist only where there is a window.
final class EditorUi {
  EditorUi(this.model);

  final EditorModel model;

  /// The panels and where they are.
  final EditorWorkspace workspace = EditorWorkspace();

  EditorThemeMode themeMode = EditorThemeMode.system;

  /// Whether the desktop is in dark mode, kept live by the window from
  /// `MediaQuery.platformBrightness`; null when the window has no query to
  /// read - a widget test - and "Follow the system" then stays dark.
  bool? systemDark;

  /// The theme the editor wears: the studio look at the sizes this
  /// desktop's own applications use.
  ThemeData get theme => switch (themeMode) {
        EditorThemeMode.dark => _dark,
        EditorThemeMode.light => _light,
        EditorThemeMode.system => systemDark == false ? _light : _dark,
      };

  static final ThemeData _dark = ThemeData.studioDark.adaptedToPlatform();
  static final ThemeData _light = ThemeData.studioLight.adaptedToPlatform();

  /// Whether the menus are in the system's menu bar (macOS) rather than in
  /// the window - the user's choice, offered where [nativeMenuAvailable].
  bool nativeMenuBar = false;

  /// Whether this window can put its menus in the system's bar; set by the
  /// window as it builds.
  bool nativeMenuAvailable = false;

  /// One per menu of the menu bar, so a tool or a test can open one.
  final List<MenuController> menuControllers =
      List<MenuController>.generate(12, (_) => MenuController());

  /// The property panel last brought into view.
  String? activePanel = PanelIds.transform;

  void setThemeMode(EditorThemeMode mode) {
    themeMode = mode;
    model.refresh('Theme: ${mode.label}');
  }

  void setNativeMenuBar(bool value) {
    nativeMenuBar = value;
    model
        .refresh(value ? 'Menus in the macOS menu bar' : 'Menus in the window');
  }

  /// Shows panel [id], wherever it is - its tab, its window, or docked back.
  void showPanel(String id) {
    activePanel = id;
    if (workspace.isFloating(id)) {
      workspace.dock(id);
    } else {
      workspace.show(id);
    }
    model.refresh('${WorkspacePanels.nameOf(id)} shown');
  }
}

/// Registers the window's commands: theme, panels, menu bar placement.
void registerUiCommands(CommandRegistry registry, EditorUi ui) {
  registry.registerAll(<CommandSpec>[
    for (final EditorThemeMode mode in EditorThemeMode.values)
      CommandSpec(
        id: 'theme.${mode.name}',
        label: 'Theme: ${mode.label}',
        checked: (_) => ui.themeMode == mode,
        run: (_) {
          ui.setThemeMode(mode);
          return null;
        },
      ),
    CommandSpec(
      id: 'view.systemMenuBar',
      label: 'Use the macOS menu bar',
      description: 'Puts the menus in the system menu bar instead of the '
          'window.',
      checked: (_) => ui.nativeMenuBar,
      enabled: (_) => ui.nativeMenuAvailable,
      disabledReason: (_) => 'this platform has no system menu bar',
      run: (_) {
        ui.setNativeMenuBar(!ui.nativeMenuBar);
        return ui.nativeMenuBar;
      },
    ),
    for (final String id in WorkspacePanels.all)
      CommandSpec(
        id: WorkspacePanels.commandOf(id),
        label: WorkspacePanels.nameOf(id),
        currentLabel: (_) => ui.workspace.isFloating(id)
            ? '${WorkspacePanels.nameOf(id)} (dock again)'
            : WorkspacePanels.nameOf(id),
        shortcut: WorkspacePanels.shortcutOf(id),
        alsoShortcuts: id == WorkspacePanels.fillStroke
            ? const <KeyGesture>[KeyGesture(logicalKeyF12)]
            : const <KeyGesture>[],
        checked: (_) =>
            ui.workspace.isDocked(id) || ui.workspace.isFloating(id),
        run: (_) {
          ui.showPanel(id);
          return null;
        },
      ),
    CommandSpec(
      id: 'window.resetWorkspace',
      label: 'Reset workspace',
      run: (_) {
        ui.workspace.reset();
        ui.model.refresh('Workspace reset');
        return null;
      },
    ),
  ]);
}
