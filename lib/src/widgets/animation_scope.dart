/// Ambient frame clock for implicitly animated widgets.
library;

import '../animation/clock.dart';
import 'widget.dart';

final class AnimationScope extends InheritedWidget {
  const AnimationScope({
    super.key,
    required this.clock,
    required super.child,
  });

  final AnimationClock clock;

  static AnimationClock of(BuildContext context) {
    final AnimationScope? scope =
        context.dependOnInheritedWidgetOfExactType<AnimationScope>();
    if (scope == null) {
      throw StateError('No AnimationScope found above this widget.');
    }
    return scope.clock;
  }

  static AnimationClock? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AnimationScope>()?.clock;

  @override
  bool updateShouldNotify(AnimationScope oldWidget) =>
      !identical(clock, oldWidget.clock);
}
