/// The one place an application's commands are registered and run.
library;

import '../platform/key_gesture.dart';
import 'command.dart';

/// Every command of an application, by id.
///
/// [execute] is the only way a command runs: it checks the parameters
/// against the command's declaration, refuses a disabled command, and turns
/// every exception into a failed [CommandOutcome]. Menus, shortcuts, panels,
/// tests and automation clients all go through it, so they all see the same
/// checks and the same errors.
final class CommandRegistry {
  CommandRegistry({this.transaction, this.onExecuted});

  final Map<String, CommandSpec> _commands = <String, CommandSpec>{};

  /// Wraps a batch so it is one undo step: runs `body` and records whatever
  /// it changed under `label`. Null runs the steps one by one.
  Object? Function(String label, Object? Function() body)? transaction;

  /// Told about every run - a status bar, a journal, a test.
  void Function(String id, CommandOutcome outcome)? onExecuted;

  /// Adds [command]; a command with the same id is replaced.
  void register(CommandSpec command) => _commands[command.id] = command;

  void registerAll(Iterable<CommandSpec> commands) {
    for (final CommandSpec command in commands) {
      register(command);
    }
  }

  void unregister(String id) => _commands.remove(id);

  void clear() => _commands.clear();

  CommandSpec? operator [](String id) => _commands[id];

  bool contains(String id) => _commands.containsKey(id);

  Iterable<CommandSpec> get commands => _commands.values;

  Iterable<String> get ids => _commands.keys;

  int get length => _commands.length;

  bool isEnabled(String id) => _commands[id]?.isEnabled ?? false;

  /// Runs [id] with [params].
  ///
  /// Fails, without running anything, when the command is unknown, disabled,
  /// or given a parameter it does not declare, of the wrong type, or missing
  /// a required one.
  CommandOutcome execute(String id, [Map<String, Object?>? params]) {
    final CommandOutcome outcome =
        _run(id, params ?? const <String, Object?>{});
    onExecuted?.call(id, outcome);
    return outcome;
  }

  CommandOutcome _run(String id, Map<String, Object?> params) {
    final CommandSpec? command = _commands[id];
    if (command == null) {
      final String? near = nearest(id, _commands.keys);
      return CommandOutcome.failure(
          'unknown command `$id`${near == null ? '' : '; did you mean `$near`?'}');
    }
    final String? invalid = validate(command, params);
    if (invalid != null) return CommandOutcome.failure(invalid);
    try {
      final CommandArgs args = CommandArgs(params);
      if (!command.isEnabledWith(args)) {
        final String reason =
            command.disabledReasonWith(args) ?? 'not available now';
        return CommandOutcome.failure('`$id` is disabled: $reason');
      }
      final Object? result = command.run(args);
      if (result is Future<Object?>) return _started(id, result);
      return CommandOutcome.success(result);
    } on CommandError catch (error) {
      return CommandOutcome.failure(error.message);
    } on Object catch (error) {
      return CommandOutcome.failure('`$id` failed: $error');
    }
  }

  /// Called when an asynchronous command ends, with how it ended - the
  /// place a window shows the failure of a paste that turned out to have
  /// nothing to paste, since [execute] returned long before.
  void Function(String id, CommandOutcome outcome)? onCompleted;

  /// [running] as a started outcome whose completion never throws: an
  /// error in an asynchronous command is a failure to report, not an
  /// uncaught exception that takes the application down.
  CommandOutcome _started(String id, Future<Object?> running) {
    final Future<CommandOutcome> done = running.then<CommandOutcome>(
      CommandOutcome.success,
      onError: (Object error) => error is CommandError
          ? CommandOutcome.failure(error.message)
          : CommandOutcome.failure('`$id` failed: $error'),
    );
    done.then((CommandOutcome outcome) => onCompleted?.call(id, outcome));
    return CommandOutcome.started(done);
  }

  /// Runs [steps] in order as one undo step, stopping at the first failure.
  ///
  /// The result lists every step's result; a failure names the step.
  CommandOutcome batch(
    List<({String command, Map<String, Object?> params})> steps, {
    String label = 'Batch',
  }) {
    final List<Object?> results = <Object?>[];
    String? failure;
    Object? body() {
      for (var i = 0; i < steps.length; i++) {
        final CommandOutcome outcome =
            execute(steps[i].command, steps[i].params);
        if (!outcome.ok) {
          failure = 'step $i (`${steps[i].command}`): ${outcome.error}';
          return null;
        }
        results.add(outcome.result);
      }
      return null;
    }

    try {
      final wrap = transaction;
      if (wrap == null) {
        body();
      } else {
        wrap(label, body);
      }
    } on Object catch (error) {
      return CommandOutcome.failure('batch failed: $error');
    }
    final String? failed = failure;
    return failed == null
        ? CommandOutcome.success(results)
        : CommandOutcome.failure(failed);
  }

  /// Why [params] do not fit [command], or null when they do.
  static String? validate(CommandSpec command, Map<String, Object?> params) {
    final Map<String, CommandParam> declared = <String, CommandParam>{
      for (final CommandParam param in command.params) param.name: param,
    };
    for (final String key in params.keys) {
      if (declared.containsKey(key)) continue;
      final String? near = nearest(key, declared.keys);
      return 'unknown parameter `$key` for `${command.id}`'
          '${near == null ? '' : '; did you mean `$near`?'}';
    }
    for (final CommandParam param in command.params) {
      final Object? value = params[param.name];
      if (!params.containsKey(param.name)) {
        if (param.required) {
          return '`${command.id}` needs `${param.name}` (${param.type.name})';
        }
        continue;
      }
      if (value == null && !param.required) continue;
      if (!param.type.accepts(value)) {
        return '`${param.name}` must be ${_article(param.type)}';
      }
    }
    return null;
  }

  static String _article(CommandParamType type) => switch (type) {
        CommandParamType.integer => 'a whole number',
        CommandParamType.number => 'a number',
        CommandParamType.boolean => 'true or false',
        CommandParamType.string => 'a string',
        CommandParamType.list => 'a list',
        CommandParamType.object => 'an object',
        CommandParamType.any => 'a value',
      };

  /// Every command as JSON: id, label, description, shortcut, parameters,
  /// whether it is enabled (and why not) and checked.
  List<Map<String, Object?>> describe() => <Map<String, Object?>>[
        for (final CommandSpec command in _commands.values) _describe(command),
      ];

  static Map<String, Object?> _describe(CommandSpec command) {
    bool enabled;
    String? reason;
    bool? checked;
    try {
      enabled = command.isEnabled;
      reason = enabled ? null : command.disabledReasonWith(CommandArgs.empty);
      checked = command.isChecked;
    } on Object {
      enabled = false;
    }
    return <String, Object?>{
      'id': command.id,
      'label': command.labelNow,
      if (command.description.isNotEmpty) 'description': command.description,
      if (command.shortcut != null) 'shortcut': command.shortcut!.label(),
      if (command.params.isNotEmpty)
        'params': <Object?>[
          for (final CommandParam param in command.params) param.describe(),
        ],
      'enabled': enabled,
      if (reason != null) 'disabledReason': reason,
      if (checked != null) 'checked': checked,
    };
  }

  /// The window's shortcut table: every [CommandSpec.shortcut] and
  /// [CommandSpec.alsoShortcuts] to a run of that command. A disabled
  /// command's keys map to null, so the key is consumed and nothing runs -
  /// the same as its greyed-out menu item.
  Map<KeyGesture, void Function()?> keyBindings() {
    final Map<KeyGesture, void Function()?> bindings =
        <KeyGesture, void Function()?>{};
    // Whether the command holding each key only applies in a context.
    final Map<KeyGesture, bool> contextual = <KeyGesture, bool>{};
    for (final CommandSpec command in _commands.values) {
      final List<KeyGesture> keys = <KeyGesture>[
        if (command.shortcut != null) command.shortcut!,
        ...command.alsoShortcuts,
      ];
      if (keys.isEmpty) continue;
      final bool hasRequired = command.params.any((p) => p.required);
      final void Function()? run = hasRequired || !_safeEnabled(command)
          ? null
          : () => execute(command.id);
      final bool conditional = command.when != null || command.enabled != null;
      for (final KeyGesture key in keys) {
        // Two commands may share a key - CorelDRAW's B aligns the selection
        // to the bottom and, with nothing selected, picks the pen. The rule
        // is VS Code's `when` clauses: one that can run beats one that
        // cannot, and of two that can, the one that only applies in a
        // context beats the one that always does, while the context holds.
        // Registration order breaks what is left.
        final bool held = bindings.containsKey(key);
        final bool replace = !held ||
            (run != null &&
                (bindings[key] == null ||
                    (conditional && !(contextual[key] ?? false))));
        if (replace) {
          bindings[key] = run;
          contextual[key] = conditional;
        }
      }
    }
    return bindings;
  }

  static bool _safeEnabled(CommandSpec command) {
    try {
      return command.isEnabled;
    } on Object {
      return false;
    }
  }

  /// The candidate closest to [name] by edit distance, when it is close
  /// enough to be a typo; null otherwise.
  static String? nearest(String name, Iterable<String> candidates) {
    String? best;
    var bestDistance = 1 << 30;
    for (final String candidate in candidates) {
      final int distance = _editDistance(name, candidate);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    if (best == null) return null;
    final int limit = name.length <= 4 ? 1 : (name.length / 3).ceil();
    return bestDistance <= limit ? best : null;
  }

  static int _editDistance(String a, String b) {
    if (a == b) return 0;
    List<int> previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final List<int> current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final int cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final int deletion = previous[j] + 1;
        final int insertion = current[j - 1] + 1;
        final int substitution = previous[j - 1] + cost;
        current[j] = deletion < insertion
            ? (deletion < substitution ? deletion : substitution)
            : (insertion < substitution ? insertion : substitution);
      }
      previous = current;
    }
    return previous[b.length];
  }
}
