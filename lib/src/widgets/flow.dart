/// [Flow]: children placed at paint time by an application's
/// [FlowDelegate]. See `layout/render_flow.dart` for why a flow positions in
/// paint and what that buys an animation.
///
/// ```dart
/// final class FanOut extends FlowDelegate {
///   FanOut(this.progress) : super(repaint: progress);
///
///   final Animation<double> progress;
///
///   @override
///   void paintChildren(FlowPaintingContext context) {
///     for (int i = context.childCount - 1; i >= 0; i--) {
///       final double dx = i * 48 * progress.value;
///       context.paintChild(i, transform: Transform2D.translation(dx, 0));
///     }
///   }
///
///   @override
///   bool shouldRepaint(FanOut oldDelegate) => progress != oldDelegate.progress;
/// }
/// ```
library;

import '../layout/render_flow.dart';
import 'element.dart';
import 'proxy.dart' show RepaintBoundary;
import 'widget.dart';

/// Lays [children] out and paints them with [delegate].
///
/// The default constructor wraps every child in a [RepaintBoundary], as
/// Flutter's does: a flow exists to move children every frame without
/// changing them, and a boundary lets a moved child replay its retained
/// recording under a translation instead of walking its subtree again. Use
/// [Flow.unwrapped] when the children change as often as they move, or are
/// boundaries already.
///
/// The flow always clips to its own box - Flutter's default, `Clip.hardEdge`.
/// There is no `clipBehavior`: this framework has no `Clip` enum, and the
/// clip is what keeps hit testing in step with what is on screen.
final class Flow extends MultiChildRenderObjectWidget {
  Flow({
    super.key,
    required this.delegate,
    List<Widget> children = const <Widget>[],
  }) : super(children: _wrapAll(children));

  /// A flow whose children are used as given, with no [RepaintBoundary]
  /// around each.
  const Flow.unwrapped({
    super.key,
    required this.delegate,
    super.children,
  });

  final FlowDelegate delegate;

  /// Keys the boundary after its child, so that reordering keyed children
  /// moves the boundaries with them; an unkeyed child's boundary is keyed by
  /// its index, which is what an unkeyed child is matched by anyway.
  static List<Widget> _wrapAll(List<Widget> children) => <Widget>[
        for (int i = 0; i < children.length; i++)
          RepaintBoundary(
            key: children[i].key == null
                ? ValueKey<int>(i)
                : ValueKey<Key>(children[i].key!),
            child: children[i],
          ),
      ];

  @override
  RenderFlow createRenderObject(BuildContext context) =>
      RenderFlow(delegate: delegate);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderFlow renderObject,
  ) =>
      renderObject.delegate = delegate;
}
