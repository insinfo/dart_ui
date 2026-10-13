/// Flutter's `Actions` widget and its dispatcher: the intents a subtree can
/// carry out, looked up from where the request comes from.
///
/// The [Intent] and [Action] types are in `actions.dart`, which also keeps
/// this framework's window-level [ActionMap] and [ShortcutMap]; this file is
/// the widget-tree half Flutter apps use - `Actions(actions: {...})`,
/// `Actions.invoke(context, intent)` - and that `Shortcuts` invokes through.
///
/// ## Differences from Flutter
///
/// * A widget that calls [Actions.handler] or [Actions.maybeFind] depends on
///   the nearest [Actions] only: it rebuilds when that one changes, not when
///   an action further out does, nor when an action calls
///   [Action.notifyActionListeners].
/// * `Action.overridable` and `ActionDispatcher` subclasses that intercept
///   invocations are supported only through [ActionDispatcher.invokeAction].
library;

import 'actions.dart';
import 'element.dart';
import 'widget.dart';

/// An [Action] that is told the context it was invoked from - Flutter's
/// `ContextAction`.
abstract class ContextAction<T extends Intent> extends Action<T> {
  const ContextAction();

  @override
  Object? invoke(T intent, [BuildContext? context]);
}

/// Runs actions. The place to intercept every invocation in a subtree -
/// Flutter's `ActionDispatcher`.
class ActionDispatcher {
  const ActionDispatcher();

  /// Invokes [action] with [intent], passing [context] to a [ContextAction].
  Object? invokeAction(
    covariant Action<Intent> action,
    covariant Intent intent, [
    BuildContext? context,
  ]) =>
      action is ContextAction<Intent>
          ? action.invoke(intent, context)
          : action.invoke(intent);

  /// Invokes [action] if it is enabled for [intent]; says whether it was,
  /// and what it returned.
  (bool, Object?) invokeActionIfEnabled(
    covariant Action<Intent> action,
    covariant Intent intent, [
    BuildContext? context,
  ]) {
    if (!action.isEnabled(intent)) return (false, null);
    return (true, invokeAction(action, intent, context));
  }
}

/// The actions a subtree can carry out, by intent type - Flutter's
/// `Actions`.
///
/// Lookups start at the context that asks and go outward: the nearest
/// [Actions] with an action for the intent's type wins, and a disabled one
/// lets [invoke] keep looking further out.
class Actions extends StatelessWidget {
  const Actions({
    super.key,
    this.dispatcher,
    required this.actions,
    required this.child,
  });

  /// Runs this subtree's actions; the one from further out, or a plain
  /// [ActionDispatcher], when null.
  final ActionDispatcher? dispatcher;

  /// Intent type to the action that carries it out here.
  final Map<Type, Action<Intent>> actions;

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _ActionsScope(dispatcher: dispatcher, actions: actions, child: child);

  /// Visits the [Actions] above [context], nearest first, until [visitor]
  /// answers true.
  static void _visit(
    BuildContext context,
    bool Function(_ActionsScope scope) visitor,
  ) {
    if (context is Element && context.widget is _ActionsScope) {
      if (visitor(context.widget as _ActionsScope)) return;
    }
    context.visitAncestorElements((Element element) {
      final Widget widget = element.widget;
      if (widget is _ActionsScope) return !visitor(widget);
      return true;
    });
  }

  static Action<T>? _cast<T extends Intent>(_ActionsScope scope, Type type) {
    final Action<Intent>? action = scope.actions[type];
    return action is Action<T> ? action : null;
  }

  /// The dispatcher for [context]: the nearest [Actions]' own, or a plain
  /// one.
  static ActionDispatcher of(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<_ActionsScope>();
    ActionDispatcher? found;
    _visit(context, (_ActionsScope scope) {
      found = scope.dispatcher;
      return found != null;
    });
    return found ?? const ActionDispatcher();
  }

  /// The nearest action for [intent] (or for [T]), enabled or not; null
  /// when there is none.
  static Action<T>? maybeFind<T extends Intent>(
    BuildContext context, {
    T? intent,
  }) {
    context.dependOnInheritedWidgetOfExactType<_ActionsScope>();
    final Type type = intent?.runtimeType ?? T;
    Action<T>? found;
    _visit(context, (_ActionsScope scope) {
      found = _cast<T>(scope, type);
      return found != null;
    });
    return found;
  }

  /// [maybeFind], throwing when there is no action.
  static Action<T> find<T extends Intent>(BuildContext context, {T? intent}) {
    final Action<T>? action = maybeFind<T>(context, intent: intent);
    if (action == null) {
      throw StateError(
        'Unable to find an action for ${intent?.runtimeType ?? T} in an '
        'Actions widget above ${context.widget.runtimeType}.',
      );
    }
    return action;
  }

  /// A callback that invokes the action for [intent], or null when there is
  /// none or it is disabled - for a button's `onPressed`.
  static void Function()? handler<T extends Intent>(
    BuildContext context,
    T intent,
  ) {
    final Action<T>? action = maybeFind<T>(context, intent: intent);
    if (action == null || !action.isEnabled(intent)) return null;
    return () {
      if (action.isEnabled(intent)) {
        Actions.of(context).invokeAction(action, intent, context);
      }
    };
  }

  /// Invokes the nearest enabled action for [intent]; throws when there is
  /// none, as Flutter's assert does (here in release too).
  static Object? invoke<T extends Intent>(BuildContext context, T intent) {
    final (bool found, Object? result) = _invoke<T>(context, intent);
    if (!found) {
      throw StateError(
        'Unable to find an enabled action for ${intent.runtimeType} in an '
        'Actions widget above ${context.widget.runtimeType}.',
      );
    }
    return result;
  }

  /// Invokes the nearest enabled action for [intent]; null when there is
  /// none.
  static Object? maybeInvoke<T extends Intent>(
    BuildContext context,
    T intent,
  ) =>
      _invoke<T>(context, intent).$2;

  static (bool, Object?) _invoke<T extends Intent>(
    BuildContext context,
    T intent,
  ) {
    final Type type = intent.runtimeType;
    Action<T>? action;
    ActionDispatcher? dispatcher;
    _visit(context, (_ActionsScope scope) {
      final Action<T>? candidate = _cast<T>(scope, type);
      if (candidate != null && candidate.isEnabled(intent)) {
        action = candidate;
        dispatcher = scope.dispatcher;
        return true;
      }
      return false;
    });
    final Action<T>? chosen = action;
    if (chosen == null) return (false, null);
    return (
      true,
      (dispatcher ?? Actions.of(context)).invokeAction(chosen, intent, context),
    );
  }
}

final class _ActionsScope extends InheritedWidget {
  const _ActionsScope({
    required this.dispatcher,
    required this.actions,
    required super.child,
  });

  final ActionDispatcher? dispatcher;
  final Map<Type, Action<Intent>> actions;

  @override
  bool updateShouldNotify(_ActionsScope oldWidget) =>
      !identical(actions, oldWidget.actions) ||
      !identical(dispatcher, oldWidget.dispatcher);
}

/// Runs [ActivateIntent]s - Flutter's `ActivateAction`, the base for a
/// control's own.
abstract class ActivateAction extends Action<ActivateIntent> {}

/// Runs [ButtonActivateIntent]s - Flutter's `ButtonActivateAction`.
abstract class ButtonActivateAction extends Action<ButtonActivateIntent> {}

/// Runs [DismissIntent]s - Flutter's `DismissAction`.
abstract class DismissAction extends Action<DismissIntent> {}
