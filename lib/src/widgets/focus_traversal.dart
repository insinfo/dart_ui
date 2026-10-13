/// Flutter's focus traversal policies and groups, over the tab ring in
/// `focus.dart`.
///
/// The ring a window walks with Tab is in visual (paint) order by default -
/// what Flutter calls `WidgetOrderTraversalPolicy`, and what a desktop
/// toolkit does. A [FocusTraversalGroup] puts its subtree under a policy of
/// its own: its members are visited as one block, in the order the policy
/// sorts them, which is how Flutter keeps a toolbar's buttons together and
/// how [OrderedTraversalPolicy] honours [FocusTraversalOrder].
///
/// ## Differences from Flutter
///
/// * With no group, the window keeps the visual order. Flutter's default at
///   the root is `ReadingOrderTraversalPolicy`; for the usual layouts the
///   two agree, and a [FocusTraversalGroup] with no policy does use reading
///   order here too.
/// * Arrow keys are not bound to [FocusTraversalPolicy.inDirection] by
///   default; call it, or bind `DirectionalFocusIntent` in your own
///   `Shortcuts`.
/// * `requestFocusCallback` and the scope-data hooks are not provided.
library;

import '../geometry/rect.dart';
import '../layout/render_box.dart';
import '../text/shaper.dart' show TextDirection;
import 'actions.dart';
import 'actions_widget.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_widget.dart';
import 'widget.dart';

/// Where [node] is on the window, or null when it has no box yet.
///
/// The node's key target when that is a render box; otherwise the first
/// box under the widget that attached it.
Rect? focusNodeRect(FocusNode node) {
  RenderBox? box;
  final Object? target = node.target;
  if (target is RenderBox) {
    box = target;
  } else {
    final BuildContext? context = node.context;
    if (context is Element && context.mounted) {
      final List<RenderBox> found = <RenderBox>[];
      context.collectRenderChildren(found);
      if (found.isNotEmpty) box = found.first;
    }
  }
  if (box == null || !box.hasSize) return null;
  final Rect local = Rect.fromLTWH(0, 0, box.size.width, box.size.height);
  final topLeft = box.localToGlobal(local.topLeft);
  return Rect.fromLTWH(topLeft.dx, topLeft.dy, local.width, local.height);
}

/// Decides the order Tab visits focus nodes in - Flutter's
/// `FocusTraversalPolicy`.
///
/// A subclass implements [sortDescendants]; the moves ([next], [previous],
/// [inDirection]) are the window's, applied from the node given.
abstract class FocusTraversalPolicy {
  const FocusTraversalPolicy();

  /// [descendants] - the traversable members of one group - in the order
  /// Tab should visit them.
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  );

  /// The first node Tab would visit in [currentNode]'s scope.
  FocusNode? findFirstFocus(
    FocusNode currentNode, {
    bool ignoreCurrentFocus = false,
  }) {
    final List<FocusNode> ring = _ring(currentNode);
    return ring.isEmpty ? null : ring.first;
  }

  /// The last node Tab would visit in [currentNode]'s scope.
  FocusNode findLastFocus(
    FocusNode currentNode, {
    bool ignoreCurrentFocus = false,
  }) {
    final List<FocusNode> ring = _ring(currentNode);
    return ring.isEmpty ? currentNode : ring.last;
  }

  /// The node [direction] reaches first from the edge of [currentNode]'s
  /// scope.
  FocusNode? findFirstFocusInDirection(
    FocusNode currentNode,
    TraversalDirection direction,
  ) {
    final List<FocusNode> ring = _ring(currentNode);
    if (ring.isEmpty) return null;
    return switch (direction) {
      TraversalDirection.up ||
      TraversalDirection.left ||
      TraversalDirection.previous =>
        ring.last,
      _ => ring.first,
    };
  }

  /// Moves focus to the node after [currentNode].
  bool next(FocusNode currentNode) =>
      currentNode.manager
          ?.moveFocus(TraversalDirection.next, from: currentNode) ??
      false;

  /// Moves focus to the node before [currentNode].
  bool previous(FocusNode currentNode) =>
      currentNode.manager
          ?.moveFocus(TraversalDirection.previous, from: currentNode) ??
      false;

  /// Moves focus to the nearest node in [direction] on screen.
  ///
  /// Geometric, as Flutter's directional mixin: among the nodes of the ring
  /// lying wholly beyond [currentNode] in that direction, the one that
  /// overlaps it across the direction and is closest along it; failing an
  /// overlap, the closest centre.
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (direction == TraversalDirection.next) return next(currentNode);
    if (direction == TraversalDirection.previous) return previous(currentNode);
    final Rect? from = focusNodeRect(currentNode);
    if (from == null) return false;
    FocusNode? best;
    double bestScore = double.infinity;
    for (final FocusNode node in _ring(currentNode)) {
      if (identical(node, currentNode)) continue;
      final Rect? rect = focusNodeRect(node);
      if (rect == null) continue;
      final bool beyond = switch (direction) {
        TraversalDirection.up => rect.bottom <= from.top + 0.5,
        TraversalDirection.down => rect.top >= from.bottom - 0.5,
        TraversalDirection.left => rect.right <= from.left + 0.5,
        TraversalDirection.right => rect.left >= from.right - 0.5,
        _ => false,
      };
      if (!beyond) continue;
      final bool vertical = direction == TraversalDirection.up ||
          direction == TraversalDirection.down;
      final double along = vertical
          ? (rect.center.dy - from.center.dy).abs()
          : (rect.center.dx - from.center.dx).abs();
      final double across = vertical
          ? (rect.center.dx - from.center.dx).abs()
          : (rect.center.dy - from.center.dy).abs();
      final bool overlaps = vertical
          ? rect.left < from.right && rect.right > from.left
          : rect.top < from.bottom && rect.bottom > from.top;
      // An overlapping candidate beats any that does not; then the nearest.
      final double score = (overlaps ? 0 : 1e9) + along * 1000 + across;
      if (score < bestScore) {
        bestScore = score;
        best = node;
      }
    }
    if (best == null) return false;
    return best.requestFocus(FocusChangeReason.traversal);
  }

  List<FocusNode> _ring(FocusNode node) =>
      node.manager?.traversalRing() ?? const <FocusNode>[];
}

/// Visual order: the order the widgets paint in - Flutter's
/// `WidgetOrderTraversalPolicy`, and this framework's default.
class WidgetOrderTraversalPolicy extends FocusTraversalPolicy {
  WidgetOrderTraversalPolicy();

  @override
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  ) =>
      descendants;
}

/// Reading order: rows from the top, each row in the reading direction -
/// Flutter's `ReadingOrderTraversalPolicy`.
///
/// A row is the nodes whose boxes overlap vertically the topmost remaining
/// one. Right to left when the node's [Directionality] says so.
class ReadingOrderTraversalPolicy extends FocusTraversalPolicy {
  ReadingOrderTraversalPolicy();

  @override
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  ) {
    final List<(FocusNode, Rect)> placed = <(FocusNode, Rect)>[];
    final List<FocusNode> unplaced = <FocusNode>[];
    for (final FocusNode node in descendants) {
      final Rect? rect = focusNodeRect(node);
      if (rect == null) {
        unplaced.add(node);
      } else {
        placed.add((node, rect));
      }
    }
    final List<FocusNode> result = <FocusNode>[];
    final List<(FocusNode, Rect)> remaining = List<(FocusNode, Rect)>.of(
      placed,
    )..sort(((FocusNode, Rect) a, (FocusNode, Rect) b) =>
        a.$2.top.compareTo(b.$2.top));
    while (remaining.isNotEmpty) {
      final Rect first = remaining.first.$2;
      final List<(FocusNode, Rect)> row = <(FocusNode, Rect)>[
        for (final (FocusNode, Rect) entry in remaining)
          if (entry.$2.top < first.bottom && entry.$2.bottom > first.top) entry,
      ];
      remaining.removeWhere(row.contains);
      final bool rtl = _isRtl(row.first.$1);
      row.sort(((FocusNode, Rect) a, (FocusNode, Rect) b) => rtl
          ? b.$2.right.compareTo(a.$2.right)
          : a.$2.left.compareTo(b.$2.left));
      result.addAll(row.map(((FocusNode, Rect) e) => e.$1));
    }
    return result..addAll(unplaced);
  }

  bool _isRtl(FocusNode node) {
    final BuildContext? context = node.context;
    if (context == null || !context.mounted) return false;
    return Directionality.maybeOf(context) == TextDirection.rightToLeft;
  }
}

/// An order given to a widget for [OrderedTraversalPolicy] - Flutter's
/// `FocusOrder`.
abstract class FocusOrder implements Comparable<FocusOrder> {
  const FocusOrder();

  @override
  int compareTo(FocusOrder other) {
    if (other.runtimeType != runtimeType) {
      throw ArgumentError(
        'the focus orders $this and $other are of different types and '
        'cannot be compared; put each kind in its own FocusTraversalGroup',
      );
    }
    return doCompare(other);
  }

  /// Compares with [other], which is of this type.
  int doCompare(covariant FocusOrder other);
}

/// An order by number - Flutter's `NumericFocusOrder`.
class NumericFocusOrder extends FocusOrder {
  const NumericFocusOrder(this.order);

  final double order;

  @override
  int doCompare(NumericFocusOrder other) => order.compareTo(other.order);

  @override
  String toString() => 'NumericFocusOrder($order)';
}

/// An order by string - Flutter's `LexicalFocusOrder`.
class LexicalFocusOrder extends FocusOrder {
  const LexicalFocusOrder(this.order);

  final String order;

  @override
  int doCompare(LexicalFocusOrder other) => order.compareTo(other.order);

  @override
  String toString() => 'LexicalFocusOrder($order)';
}

/// Gives the focusable widgets below an [order] for
/// [OrderedTraversalPolicy] - Flutter's `FocusTraversalOrder`.
class FocusTraversalOrder extends InheritedWidget {
  const FocusTraversalOrder({
    super.key,
    required this.order,
    required super.child,
  });

  final FocusOrder order;

  /// The order above [context]; throws when there is none.
  static FocusOrder of(BuildContext context) {
    final FocusOrder? order = maybeOf(context);
    if (order == null) {
      throw StateError('FocusTraversalOrder.of() was called with a context '
          'that does not contain a FocusTraversalOrder widget.');
    }
    return order;
  }

  static FocusOrder? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FocusTraversalOrder>()?.order;

  @override
  bool updateShouldNotify(FocusTraversalOrder oldWidget) =>
      order != oldWidget.order;
}

/// Visits the nodes with a [FocusTraversalOrder] in that order, then the
/// rest in the [secondary] policy's order - Flutter's
/// `OrderedTraversalPolicy`.
class OrderedTraversalPolicy extends FocusTraversalPolicy {
  OrderedTraversalPolicy({this.secondary});

  /// The order for nodes without one; reading order when null.
  final FocusTraversalPolicy? secondary;

  @override
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  ) {
    final Iterable<FocusNode> sorted =
        (secondary ?? ReadingOrderTraversalPolicy())
            .sortDescendants(descendants, currentNode);
    final List<(FocusNode, FocusOrder)> ordered = <(FocusNode, FocusOrder)>[];
    final List<FocusNode> unordered = <FocusNode>[];
    for (final FocusNode node in sorted) {
      final BuildContext? context = node.context;
      final FocusOrder? order = context == null || !context.mounted
          ? null
          : FocusTraversalOrder.maybeOf(context);
      if (order == null) {
        unordered.add(node);
      } else {
        ordered.add((node, order));
      }
    }
    _stableSort(ordered);
    return <FocusNode>[
      for (final (FocusNode, FocusOrder) entry in ordered) entry.$1,
      ...unordered,
    ];
  }

  static void _stableSort(List<(FocusNode, FocusOrder)> list) {
    final List<int> index = List<int>.generate(list.length, (int i) => i);
    index.sort((int a, int b) {
      final int byOrder = list[a].$2.compareTo(list[b].$2);
      return byOrder != 0 ? byOrder : a.compareTo(b);
    });
    final List<(FocusNode, FocusOrder)> copy =
        List<(FocusNode, FocusOrder)>.of(list);
    for (int i = 0; i < index.length; i++) {
      list[i] = copy[index[i]];
    }
  }
}

/// Puts its subtree under one traversal [policy]: Tab visits the focusable
/// widgets below as one block, in the policy's order - Flutter's
/// `FocusTraversalGroup`.
class FocusTraversalGroup extends StatefulWidget {
  FocusTraversalGroup({
    super.key,
    FocusTraversalPolicy? policy,
    this.descendantsAreFocusable = true,
    this.descendantsAreTraversable = true,
    required this.child,
  }) : policy = policy ?? ReadingOrderTraversalPolicy();

  final FocusTraversalPolicy policy;
  final bool descendantsAreFocusable;
  final bool descendantsAreTraversable;
  final Widget child;

  /// The policy of the nearest group above [context]; throws without one.
  static FocusTraversalPolicy of(BuildContext context) {
    final FocusTraversalPolicy? policy = maybeOf(context);
    if (policy == null) {
      throw StateError('FocusTraversalGroup.of() was called with a context '
          'that does not contain a FocusTraversalGroup.');
    }
    return policy;
  }

  /// The policy of the nearest group above [context], or null.
  static FocusTraversalPolicy? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GroupMarker>()?.policy;

  /// The policy that governs [node]: its nearest group's.
  static FocusTraversalPolicy? maybeOfNode(FocusNode node) {
    for (FocusNode? n = node.parent; n != null; n = n.parent) {
      final FocusTraversalPolicy? policy = _policies[n];
      if (policy != null) return policy;
    }
    return null;
  }

  @override
  State<FocusTraversalGroup> createState() => _FocusTraversalGroupState();
}

final Expando<FocusTraversalPolicy> _policies =
    Expando<FocusTraversalPolicy>('FocusTraversalGroup policy');

class _FocusTraversalGroupState extends State<FocusTraversalGroup> {
  final FocusNode _node = FocusNode(
    debugLabel: 'FocusTraversalGroup',
    canRequestFocus: false,
    skipTraversal: true,
  );

  void _install() {
    final FocusTraversalPolicy policy = widget.policy;
    _policies[_node] = policy;
    _node.traversalSorter = policy.sortDescendants;
  }

  @override
  void initState() {
    super.initState();
    _install();
  }

  @override
  void didUpdateWidget(FocusTraversalGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    _install();
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _GroupMarker(
        policy: widget.policy,
        child: Focus(
          focusNode: _node,
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          descendantsAreFocusable: widget.descendantsAreFocusable,
          descendantsAreTraversable: widget.descendantsAreTraversable,
          child: widget.child,
        ),
      );
}

final class _GroupMarker extends InheritedWidget {
  const _GroupMarker({required this.policy, required super.child});

  final FocusTraversalPolicy policy;

  @override
  bool updateShouldNotify(_GroupMarker oldWidget) =>
      !identical(policy, oldWidget.policy);
}

/// Moves focus in a direction - Flutter's `DirectionalFocusIntent`, for a
/// `Shortcuts` map that binds the arrow keys.
class DirectionalFocusIntent extends Intent {
  const DirectionalFocusIntent(this.direction, {this.ignoreTextFields = true});

  final TraversalDirection direction;

  /// Accepted for Flutter's signature. Arrow keys a text field uses never
  /// reach a shortcut here: the field consumes them first.
  final bool ignoreTextFields;
}

/// Moves focus as a [DirectionalFocusIntent] asks, through the policy that
/// governs the focused node - Flutter's `DirectionalFocusAction`.
///
/// A [ContextAction]: the window whose focus moves is the one the invoking
/// context is in.
class DirectionalFocusAction extends ContextAction<DirectionalFocusIntent> {
  DirectionalFocusAction();

  @override
  Object? invoke(DirectionalFocusIntent intent, [BuildContext? context]) {
    final FocusNode? focused =
        context is Element ? context.owner?.focusManager.primaryFocus : null;
    if (focused == null) return null;
    final FocusTraversalPolicy policy =
        FocusTraversalGroup.maybeOfNode(focused) ??
            ReadingOrderTraversalPolicy();
    policy.inDirection(focused, intent.direction);
    return null;
  }
}
