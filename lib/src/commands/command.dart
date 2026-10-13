/// Commands: every user-visible action of an application, by id.
///
/// A command is what a menu item, a toolbar button, a shortcut, a context
/// menu row, a command palette entry, a test and an automation client all
/// reach for. Declaring it once - id, label, shortcut, parameters, whether it
/// is enabled, what it does - is what keeps those surfaces from disagreeing,
/// and what lets a program be driven without a mouse.
library;

import '../platform/key_gesture.dart';

/// The JSON type a [CommandParam] takes.
enum CommandParamType {
  string,

  /// Any JSON number.
  number,

  /// A JSON number with no fractional part.
  integer,
  boolean,
  list,
  object,

  /// Anything, checked by the command itself.
  any;

  bool accepts(Object? value) => switch (this) {
        string => value is String,
        number => value is num && value.isFinite,
        integer =>
          value is int || (value is double && value == value.truncate()),
        boolean => value is bool,
        list => value is List,
        object => value is Map,
        any => true,
      };
}

/// One parameter a command takes.
final class CommandParam {
  const CommandParam(
    this.name,
    this.type, {
    this.required = false,
    this.description = '',
  });

  final String name;
  final CommandParamType type;
  final bool required;
  final String description;

  Map<String, Object?> describe() => <String, Object?>{
        'name': name,
        'type': type.name,
        'required': required,
        if (description.isNotEmpty) 'description': description,
      };
}

/// A command refusing to run, with a message for whoever asked.
///
/// Thrown by a command's `run` for a refusal it can explain ("nothing is
/// selected"), and by [CommandArgs] for a parameter of the wrong type. The
/// registry turns it, and any other exception, into a failed
/// [CommandOutcome]: a command never takes the application down.
final class CommandError implements Exception {
  const CommandError(this.message);

  final String message;

  @override
  String toString() => 'CommandError: $message';
}

/// The parameters a command was run with, already checked against its
/// [CommandSpec.params].
final class CommandArgs {
  const CommandArgs(this.values);

  static const CommandArgs empty = CommandArgs(<String, Object?>{});

  final Map<String, Object?> values;

  bool has(String name) => values.containsKey(name);

  Object? operator [](String name) => values[name];

  double number(String name, [double? fallback]) {
    final Object? value = values[name];
    if (value is num) return value.toDouble();
    if (value == null && fallback != null) return fallback;
    throw CommandError('`$name` must be a number');
  }

  int integer(String name, [int? fallback]) {
    final Object? value = values[name];
    if (value is int) return value;
    if (value is double && value == value.truncate()) return value.toInt();
    if (value == null && fallback != null) return fallback;
    throw CommandError('`$name` must be a whole number');
  }

  String string(String name, [String? fallback]) {
    final Object? value = values[name];
    if (value is String) return value;
    if (value == null && fallback != null) return fallback;
    throw CommandError('`$name` must be a string');
  }

  bool flag(String name, [bool fallback = false]) {
    final Object? value = values[name];
    if (value is bool) return value;
    if (value == null) return fallback;
    throw CommandError('`$name` must be true or false');
  }

  List<Object?> list(String name) {
    final Object? value = values[name];
    if (value is List) return value.cast<Object?>();
    if (value == null) return const <Object?>[];
    throw CommandError('`$name` must be a list');
  }
}

/// One command: what it is called, how it is reached and what it does.
final class CommandSpec {
  const CommandSpec({
    required this.id,
    required this.label,
    required this.run,
    this.description = '',
    this.shortcut,
    this.alsoShortcuts = const <KeyGesture>[],
    this.params = const <CommandParam>[],
    this.when,
    this.enabled,
    this.disabledReason,
    this.checked,
    this.currentLabel,
  });

  /// Dotted, by area: `file.save`, `object.toCurves`, `view.zoomIn`.
  final String id;

  /// What a menu shows; [currentLabel] when it depends on the state
  /// ("Undo Move").
  final String label;
  final String Function(CommandArgs args)? currentLabel;

  /// One sentence for a tooltip, the command palette and automation.
  final String description;

  /// Shown in menus and bound at the window; [alsoShortcuts] are bound only.
  final KeyGesture? shortcut;
  final List<KeyGesture> alsoShortcuts;

  final List<CommandParam> params;

  /// Why the command cannot run now with these parameters, or null when it
  /// can - one function for both questions, so "disabled" and "why" cannot
  /// disagree. Preferred over [enabled] with [disabledReason].
  final String? Function(CommandArgs args)? when;

  /// Null means always enabled. Given the parameters a row or a caller
  /// would run it with - "Delete layer 3" can be possible when "Delete
  /// layer 1" is not.
  final bool Function(CommandArgs args)? enabled;

  /// Why it is disabled now - read only while [enabled] says false.
  final String Function(CommandArgs args)? disabledReason;

  /// Non-null for a toggle; the function returns whether it is on.
  final bool Function(CommandArgs args)? checked;

  /// Does the work. Returns a JSON-serialisable result or null; throws
  /// [CommandError] to refuse with a reason.
  final Object? Function(CommandArgs args) run;

  /// This command with another [label] or [description] - a translation:
  /// the id, the keys and the behaviour stay, so a script written against
  /// one language runs in every other.
  ///
  /// [reason] translates what [when] and [disabledReason] answer, so a
  /// disabled button's tooltip speaks the language its label does
  /// ("Copiar - nenhum item selecionado", not "Copiar - nothing is
  /// selected"). Whether the command is enabled does not change.
  CommandSpec copyWith({
    String? label,
    String? description,
    String Function(String reason)? reason,
  }) {
    final String? Function(CommandArgs args)? why = when;
    final String Function(CommandArgs args)? because = disabledReason;
    return CommandSpec(
      id: id,
      label: label ?? this.label,
      run: run,
      description: description ?? this.description,
      shortcut: shortcut,
      alsoShortcuts: alsoShortcuts,
      params: params,
      when: reason == null || why == null
          ? why
          : (CommandArgs args) {
              final String? text = why(args);
              return text == null ? null : reason(text);
            },
      enabled: enabled,
      disabledReason: reason == null || because == null
          ? because
          : (CommandArgs args) => reason(because(args)),
      checked: checked,
      currentLabel: currentLabel,
    );
  }

  bool get isEnabled => isEnabledWith(CommandArgs.empty);
  bool? get isChecked => isCheckedWith(CommandArgs.empty);
  String get labelNow => labelWith(CommandArgs.empty);

  bool isEnabledWith(CommandArgs args) {
    final String? Function(CommandArgs args)? why = when;
    if (why != null && why(args) != null) return false;
    return enabled?.call(args) ?? true;
  }

  bool? isCheckedWith(CommandArgs args) => checked?.call(args);
  String labelWith(CommandArgs args) => currentLabel?.call(args) ?? label;
  String? disabledReasonWith(CommandArgs args) =>
      when?.call(args) ?? disabledReason?.call(args);
}

/// How a run ended: [ok] with a [result], or not with an [error].
final class CommandOutcome {
  const CommandOutcome.success([this.result])
      : ok = true,
        error = null,
        completion = null;

  const CommandOutcome.failure(String this.error)
      : ok = false,
        result = null,
        completion = null;

  /// A command whose `run` returned a `Future`: it started, and
  /// [completion] says how it ended - with its result, or as a failure for
  /// whatever it threw, a [CommandError] included.
  const CommandOutcome.started(Future<CommandOutcome> this.completion)
      : ok = true,
        result = null,
        error = null;

  final bool ok;
  final Object? result;
  final String? error;

  /// How an asynchronous command ended; null for one that ran to the end
  /// before [CommandRegistry.execute] returned.
  final Future<CommandOutcome>? completion;

  /// Whether the command is still running.
  bool get isPending => completion != null;

  Map<String, Object?> toJson() => ok
      ? <String, Object?>{
          'ok': true,
          'result': result,
          if (isPending) 'pending': true,
        }
      : <String, Object?>{'ok': false, 'error': error};

  @override
  String toString() => isPending
      ? 'started'
      : ok
          ? 'ok($result)'
          : 'failed($error)';
}
