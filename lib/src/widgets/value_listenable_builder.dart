/// Rebuilds one part of the tree when a [ValueListenable] changes - and only
/// that part.
library;

import '../foundation/value_notifier.dart';
import 'widget.dart';

/// Builds a widget from a value - Flutter's `ValueWidgetBuilder`.
typedef ValueWidgetBuilder<T> = Widget Function(
    BuildContext context, T value, Widget? child);

/// Builds [builder] with [valueListenable]'s value, again whenever it
/// changes - Flutter's `ValueListenableBuilder`.
///
/// The way to keep a frequent change from rebuilding a whole window: the
/// pointer's coordinates in a status bar, a progress value, a clock. The
/// state that changes often lives in a notifier, and only the widgets that
/// show it listen; [child] is built once and handed back unchanged.
final class ValueListenableBuilder<T> extends StatefulWidget {
  const ValueListenableBuilder({
    super.key,
    required this.valueListenable,
    required this.builder,
    this.child,
  });

  /// Usually a [ValueNotifier]; anything that holds a value and notifies.
  final ValueListenable<T> valueListenable;

  final ValueWidgetBuilder<T> builder;

  /// A part of the subtree that does not depend on the value.
  final Widget? child;

  @override
  State<ValueListenableBuilder<T>> createState() =>
      _ValueListenableBuilderState<T>();
}

final class _ValueListenableBuilderState<T>
    extends State<ValueListenableBuilder<T>> {
  @override
  void initState() {
    super.initState();
    widget.valueListenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(ValueListenableBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.valueListenable, widget.valueListenable)) {
      oldWidget.valueListenable.removeListener(_changed);
      widget.valueListenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.valueListenable.value, widget.child);
}
