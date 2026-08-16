/// Insets content away from window intrusions described by [MediaQuery].
library;

import 'dart:math' as math;

import '../layout/edge_insets.dart';
import 'basic.dart' show Padding;
import 'media_query.dart';
import 'widget.dart';

/// Adds safe padding on selected sides and consumes it for descendants.
///
/// Consuming the ambient padding is as important as adding the visible
/// [Padding]: without it, two nested safe areas both apply the same system
/// inset. This follows Flutter's contract while remaining useful on desktop,
/// where the application-installed query currently reports zero safe insets.
final class SafeArea extends StatelessWidget {
  const SafeArea({
    super.key,
    this.left = true,
    this.top = true,
    this.right = true,
    this.bottom = true,
    this.minimum = EdgeInsets.zero,
    this.maintainBottomViewPadding = false,
    required this.child,
  });

  final bool left;
  final bool top;
  final bool right;
  final bool bottom;
  final EdgeInsets minimum;

  /// Uses persistent [MediaQueryData.viewPadding] at the bottom even when a
  /// temporary [MediaQueryData.viewInsets] has consumed ordinary padding.
  final bool maintainBottomViewPadding;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final EdgeInsets source = maintainBottomViewPadding
        ? EdgeInsets(
            media.padding.left,
            media.padding.top,
            media.padding.right,
            media.viewPadding.bottom,
          )
        : media.padding;
    final EdgeInsets effective = EdgeInsets.only(
      left: math.max(left ? source.left : 0, minimum.left).toDouble(),
      top: math.max(top ? source.top : 0, minimum.top).toDouble(),
      right: math.max(right ? source.right : 0, minimum.right).toDouble(),
      bottom: math.max(bottom ? source.bottom : 0, minimum.bottom).toDouble(),
    );

    return Padding(
      padding: effective,
      child: MediaQuery(
        data: media.removePadding(
          removeLeft: left,
          removeTop: top,
          removeRight: right,
          removeBottom: bottom,
        ),
        child: child,
      ),
    );
  }
}
