/// Commands with no user interface: the registry an application's actions
/// live in, their parameters, shortcuts and menu descriptions.
///
/// Everything here runs without a window, which is the point: an engine
/// that imports only this (and its own model) can be driven by a command
/// line, a test, an automation client or any user interface. Turning menus
/// into widgets is `MenuBuilder`, in `dart_ui.dart`.
library;

export 'src/commands/command.dart';
export 'src/commands/command_registry.dart';
export 'src/commands/menu_spec.dart';
export 'src/platform/editing_convention.dart'
    show EditingConvention, platformEditingConvention;
export 'src/platform/key_gesture.dart';
export 'src/platform/logical_keys.dart';
