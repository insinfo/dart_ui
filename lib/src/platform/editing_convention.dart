/// Which keyboard convention the editing shortcuts follow.
///
/// A text field on a PC copies with Ctrl+C and moves by word with Ctrl+Left;
/// the same field on a Mac copies with Cmd+C, moves by word with Option+Left
/// and jumps to the start with Cmd+Left. Neither is a preference a widget may
/// pick: it is what every other application on that machine does, and a field
/// that disagrees is the one the user's fingers get wrong.
///
/// The backends report modifiers as what was held - Command is
/// [KeyModifier.meta], Control is [KeyModifier.control] - and deciding what a
/// chord *means* is this file's job, once, rather than each backend's. Folding
/// Command into Control in the macOS backend would have made Cmd+C work and
/// broken the Mac's own Control chords at the same time.
library;

import 'editing_convention_platform_stub.dart'
    if (dart.library.io) 'editing_convention_platform_io.dart'
    if (dart.library.js_interop) 'editing_convention_platform_web.dart'
    as platform;
import 'input_events.dart';

/// The two keyboard conventions desktop editing follows.
enum EditingConvention {
  /// Windows and Linux: Control for commands, Control+arrow by word.
  pc,

  /// macOS: Command for commands, Option+arrow by word, Command+arrow to the
  /// edge.
  mac;

  /// The modifier this convention's command shortcuts - copy, paste, undo,
  /// select all - are held with.
  KeyModifier get commandModifier =>
      this == mac ? KeyModifier.meta : KeyModifier.control;

  /// The modifier that turns an arrow or a delete into its word-wise form.
  KeyModifier get wordModifier =>
      this == mac ? KeyModifier.alt : KeyModifier.control;
}

/// The convention of the platform this program runs on.
///
/// [EditingConvention.mac] on macOS and iOS, and in a browser running on
/// either; [EditingConvention.pc] everywhere else.
EditingConvention get platformEditingConvention =>
    debugEditingConventionOverride ?? _detected;

final EditingConvention _detected = platform.detectsApplePlatform()
    ? EditingConvention.mac
    : EditingConvention.pc;

/// Replaces [platformEditingConvention] while set, so a test on one platform
/// can assert the other's shortcuts. Null restores detection.
EditingConvention? debugEditingConventionOverride;
