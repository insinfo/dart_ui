/// A scrolling list whose items animate in and out - Flutter's
/// `AnimatedList`.
///
/// The list is told about changes, not handed a new list: after adding an
/// item to the data, call [AnimatedListState.insertItem] with its index;
/// before removing one, call [AnimatedListState.removeItem] with a builder
/// for how it looks while it leaves - the item is already gone from the
/// data, so the list cannot build it from there. Reach the state through a
/// `GlobalKey<AnimatedListState>`.
///
/// It scrolls with [ListView.builder] underneath and builds only the window
/// it shows. With no [AnimationScope] above it, or under reduced motion,
/// items appear and disappear at once.
library;

import '../animation/animation.dart';
import '../animation/clock.dart';
import '../layout/render_viewport.dart' show ScrollAxis, ScrollPosition;
import 'animation_scope.dart';
import 'routes.dart' show kAlwaysCompletedAnimation;
import 'scroll_view.dart';
import 'theme.dart';
import 'widget.dart';

/// Builds item [index] of the data with [animation], which runs from 0 to 1
/// as the item arrives and is 1 while it stays.
typedef AnimatedListItemBuilder = Widget Function(
    BuildContext context, int index, Animation<double> animation);

/// Builds an item that has left the data, with [animation] running from 1
/// to 0 as it goes.
typedef AnimatedListRemovedItemBuilder = Widget Function(
    BuildContext context, Animation<double> animation);

final class AnimatedList extends StatefulWidget {
  const AnimatedList({
    super.key,
    required this.itemBuilder,
    this.initialItemCount = 0,
    this.estimatedItemExtent = 40.0,
    this.controller,
    this.axis = ScrollAxis.vertical,
  });

  final AnimatedListItemBuilder itemBuilder;

  /// How many items the data starts with; they are simply there.
  final int initialItemCount;

  final double estimatedItemExtent;
  final ScrollPosition? controller;
  final ScrollAxis axis;

  @override
  State<AnimatedList> createState() => AnimatedListState();
}

/// One row of the list: an item of the data, or one leaving.
final class _Row {
  _Row({this.controller, this.removed});

  /// The arrival or the departure in progress; null for a row at rest.
  AnimationController? controller;

  /// How a departing row is built; null for a row of the data.
  final AnimatedListRemovedItemBuilder? removed;

  bool get leaving => removed != null;
}

final class AnimatedListState extends State<AnimatedList> {
  late final List<_Row> _rows = <_Row>[
    for (int i = 0; i < widget.initialItemCount; i++) _Row(),
  ];

  /// How many items of the data the list shows - not counting the ones
  /// still leaving.
  int get itemCount => _rows.where((_Row row) => !row.leaving).length;

  AnimationClock? get _clock =>
      Theme.of(context).reducedMotion ? null : AnimationScope.maybeOf(context);

  /// The row of data item [index], or the end of the rows for one past the
  /// last.
  int _rowOf(int index) {
    int seen = 0;
    for (int row = 0; row < _rows.length; row++) {
      if (_rows[row].leaving) continue;
      if (seen == index) return row;
      seen++;
    }
    if (seen == index) return _rows.length;
    throw RangeError.range(index, 0, seen, 'index');
  }

  /// An item was added to the data at [index]; it grows in over
  /// [duration].
  void insertItem(int index,
      {Duration duration = const Duration(milliseconds: 300)}) {
    final AnimationClock? clock = _clock;
    final AnimationController? controller =
        clock == null || duration <= Duration.zero
            ? null
            : (AnimationController(clock: clock, duration: duration)
              ..addListener(_tick));
    final _Row row = _Row(controller: controller);
    setState(() => _rows.insert(_rowOf(index), row));
    if (controller == null) return;
    controller
      ..addStatusListener((AnimationStatus status) {
        if (status != AnimationStatus.completed) return;
        _settle(row);
      })
      ..forward(from: 0);
  }

  /// The item at [index] is leaving the data; [builder] draws it as it
  /// shrinks away over [duration].
  void removeItem(int index, AnimatedListRemovedItemBuilder builder,
      {Duration duration = const Duration(milliseconds: 300)}) {
    final int at = _rowOf(index);
    if (at >= _rows.length) throw RangeError.index(index, _rows, 'index');
    final _Row old = _rows[at];
    final AnimationClock? clock = _clock;
    if (clock == null || duration <= Duration.zero) {
      _dispose(old);
      setState(() => _rows.removeAt(at));
      return;
    }
    // From where an arrival has got to, so an item removed while it grows
    // shrinks from that size.
    final double from = old.controller?.value ?? 1;
    _dispose(old);
    final AnimationController controller = AnimationController(
      clock: clock,
      duration: duration,
      initialValue: from,
    )..addListener(_tick);
    final _Row leaving = _Row(controller: controller, removed: builder);
    setState(() => _rows[at] = leaving);
    controller
      ..addStatusListener((AnimationStatus status) {
        if (status != AnimationStatus.dismissed) return;
        _dispose(leaving);
        if (mounted) setState(() => _rows.remove(leaving));
      })
      ..reverse();
  }

  void _settle(_Row row) {
    _dispose(row);
    if (mounted) setState(() {});
  }

  void _dispose(_Row row) {
    row.controller
      ?..removeListener(_tick)
      ..dispose();
    row.controller = null;
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _rows.forEach(_dispose);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
        itemCount: _rows.length,
        estimatedItemExtent: widget.estimatedItemExtent,
        controller: widget.controller,
        axis: widget.axis,
        itemBuilder: (BuildContext context, int rowIndex) {
          final _Row row = _rows[rowIndex];
          final Animation<double> animation =
              row.controller ?? kAlwaysCompletedAnimation;
          final AnimatedListRemovedItemBuilder? removed = row.removed;
          if (removed != null) return removed(context, animation);
          int index = 0;
          for (int i = 0; i < rowIndex; i++) {
            if (!_rows[i].leaving) index++;
          }
          return widget.itemBuilder(context, index, animation);
        },
      );
}
