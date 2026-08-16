/// Which items exist, given a scroll offset.
///
/// This is the planner that was written inside `list_box.dart` and could not be
/// reused: a `ListBox` is a *selectable* list of rows, and a scrollable form, a
/// log view or a grid of thumbnails needs the same arithmetic with none of the
/// selection. So the arithmetic lives here, on its own, with no widget, no
/// render tree and no clock in it - which is also what makes every off-by-one
/// in it directly testable. An item flickering at the edge of a scroll is a
/// wrong index, and a wrong index should fail as a number, not as a picture.
///
/// ## The two extent models, and what each costs
///
/// A virtualized list has to answer three questions - *how tall is the whole
/// thing*, *which item is at this offset*, and *where does item i start* -
/// before it knows how tall any item is. There are exactly two honest answers,
/// and this class implements both because they have genuinely different costs:
///
///  * **Uniform extents.** Every item is [estimatedExtent] tall. `offsetOf` is
///    a multiply, `indexAt` is a divide, `totalExtent` is a multiply: **O(1)
///    time, O(1) memory, no cache at all**. This is the path a list of fixed
///    rows must take, and it is why a 100 000-item list costs nothing to
///    scroll.
///  * **Variable extents.** Each item has its own extent, and positions come
///    from a prefix-sum cache. The cache is **O(n) memory** and is filled
///    **lazily**: `offsetOf(i)` and `indexAt(offset)` extend it only as far as
///    they need, so scrolling the first screen of a 100 000-item list sums a
///    few dozen entries and not a hundred thousand. Once summed, `offsetOf` is
///    **O(1)** and `indexAt` is **O(log n)** (a binary search over the summed
///    prefix). [setExtent] - the call a list makes when an item is finally
///    measured - is **O(1)**, and invalidates only the suffix after it: the
///    next query re-sums from that index, which is **O(n - i)** in the worst
///    case and **O(1) amortized** when items are measured in scroll order,
///    which is the order they are laid out in. [totalExtent] stays **O(1)** in
///    both modes - it is a running sum, not a walk - because a viewport asks
///    for it on every single layout.
///
/// The asymmetry is the point. Nothing forces a caller onto the expensive path,
/// and a caller that needs it pays for exactly the part of the list it has
/// looked at.
library;

/// The window of items that must exist for one scroll offset.
final class RealizedRange {
  const RealizedRange({
    required this.firstVisible,
    required this.lastVisible,
    required this.firstRealized,
    required this.lastRealized,
    required this.leadingExtent,
  });

  /// The first and last item actually inside the viewport.
  final int firstVisible;
  final int lastVisible;

  /// The realized window, which includes the cache on both sides.
  final int firstRealized;
  final int lastRealized;

  /// The distance from the start of the content to [firstRealized], which is
  /// what positions the realized block inside a viewport that believes the
  /// whole list is present.
  final double leadingExtent;

  int get realizedCount =>
      lastRealized < firstRealized ? 0 : lastRealized - firstRealized + 1;

  bool contains(int index) => index >= firstRealized && index <= lastRealized;

  @override
  bool operator ==(Object other) =>
      other is RealizedRange &&
      other.firstVisible == firstVisible &&
      other.lastVisible == lastVisible &&
      other.firstRealized == firstRealized &&
      other.lastRealized == lastRealized &&
      other.leadingExtent == leadingExtent;

  @override
  int get hashCode => Object.hash(
        firstVisible,
        lastVisible,
        firstRealized,
        lastRealized,
        leadingExtent,
      );

  @override
  String toString() => 'RealizedRange(visible $firstVisible..$lastVisible, '
      'realized $firstRealized..$lastRealized)';
}

/// Turns a scroll offset into a set of indices to realize.
///
/// Extents may be uniform or per-item. Uniform is the fast path and answers in
/// constant time; a variable-extent list accumulates a prefix sum once and then
/// binary-searches it, so scrolling stays logarithmic rather than linear in the
/// item count. See the library doc for the exact cost of each.
final class ListVirtualization {
  ListVirtualization({
    required this.itemCount,
    required this.estimatedExtent,
    this.cacheExtent = 0,
    List<double>? extents,
  }) : _extents = extents {
    if (_extents != null && _extents.length != itemCount) {
      throw ArgumentError.value(
        _extents.length,
        'extents',
        'must have one entry per item ($itemCount)',
      );
    }
    final List<double>? extents = _extents;
    if (extents != null) {
      _prefixSums = List<double>.filled(itemCount + 1, 0);
      // The total is maintained incrementally from here on - see [totalExtent].
      double running = 0;
      for (int i = 0; i < itemCount; i++) {
        running += extents[i];
      }
      _total = running;
    }
  }

  /// A variable-extent list that starts out believing every item is
  /// [estimatedExtent] tall.
  ///
  /// This is the constructor a list of *measured* items uses: it can lay the
  /// whole thing out, scrollbar and all, before a single item has been built,
  /// and then replaces each estimate with the real extent through [setExtent]
  /// as the item is laid out. The estimate is what stops the scrollbar
  /// appearing only after the user has scrolled to the end.
  ListVirtualization.estimated({
    required int itemCount,
    required double estimatedExtent,
    double cacheExtent = 0,
  }) : this(
          itemCount: itemCount,
          estimatedExtent: estimatedExtent,
          cacheExtent: cacheExtent,
          extents: List<double>.filled(itemCount, estimatedExtent),
        );

  final int itemCount;

  /// The extent assumed for an item whose real extent is not known.
  ///
  /// This is what makes a 10 000-item list have a scrollbar before a single
  /// item has been measured; it is an estimate and the scrollbar corrects as
  /// items are realized.
  final double estimatedExtent;

  /// How far beyond the viewport items are kept realized, in pixels.
  ///
  /// Not an optimization: without it, the item entering the viewport is built
  /// during the frame that scrolls to it, which is exactly the frame that has
  /// no time to spare.
  final double cacheExtent;

  final List<double>? _extents;

  /// `_prefixSums[i]` is the offset of item `i`, valid for `i <= _summedTo`.
  ///
  /// Grown forwards only, and truncated by [setExtent] rather than rebuilt, so
  /// measuring items in the order they are laid out costs O(1) each.
  List<double>? _prefixSums;
  int _summedTo = 0;
  double _total = 0;

  bool get hasVariableExtents => _extents != null;

  /// How many entries of the position cache are currently valid.
  ///
  /// Exposed because "did this stay lazy?" is a property worth asserting: a
  /// list that touches the whole cache on every frame has silently become
  /// linear in the item count.
  int get summedThrough => _extents == null ? itemCount : _summedTo;

  /// The total scrollable extent.
  ///
  /// **O(1) in both modes, and that is load-bearing.** A viewport asks for this
  /// on every layout to tell the scroll position how long the content is, so an
  /// implementation that summed the extents would make every frame linear in
  /// the item count and quietly undo the virtualization. For variable extents
  /// the sum is therefore kept as a running total and adjusted by [setExtent],
  /// rather than being recomputed or read off the end of the lazy prefix cache.
  double get totalExtent =>
      _extents == null ? itemCount * estimatedExtent : _total;

  /// The offset of item [index] from the start of the content.
  double offsetOf(int index) {
    final int clamped = index.clamp(0, itemCount);
    if (_extents == null) return clamped * estimatedExtent;
    _sumThrough(clamped);
    return _prefixSums![clamped];
  }

  /// The extent of item [index].
  double extentOf(int index) {
    final List<double>? extents = _extents;
    if (extents == null) return estimatedExtent;
    return extents[index.clamp(0, itemCount - 1)];
  }

  /// Records the extent an item turned out to have. Returns whether it changed.
  ///
  /// Only the suffix of the position cache is invalidated, so a list that
  /// measures items as it lays them out - front to back - never pays more than
  /// O(1) per item. Calling this on a uniform-extent list is a bug in the
  /// caller, not a silently ignored request: uniform means every item has the
  /// same extent, and there is nowhere to put a different one.
  bool setExtent(int index, double extent) {
    final List<double>? extents = _extents;
    if (extents == null) {
      throw StateError(
        'setExtent() needs per-item extents. Build the virtualization with '
        'ListVirtualization.estimated() (or pass `extents:`) when item '
        'extents are measured rather than fixed.',
      );
    }
    RangeError.checkValidIndex(index, extents, 'index', itemCount);
    if (extents[index] == extent) return false;
    _total += extent - extents[index];
    extents[index] = extent;
    // Positions before `index` are unaffected; everything at or after it moves.
    if (_summedTo > index) _summedTo = index;
    return true;
  }

  /// The item at content offset [offset], clamped into range.
  int indexAt(double offset) {
    if (itemCount == 0) return 0;
    final List<double>? sums = _prefixSums;
    if (sums == null) {
      return (offset / estimatedExtent).floor().clamp(0, itemCount - 1);
    }
    // Extend the cache only as far as this offset reaches, then binary search
    // the part that is valid: the last index whose start is <= offset.
    _sumWhileBelow(offset);
    int low = 0;
    int high = _summedTo < itemCount ? _summedTo : itemCount - 1;
    while (low < high) {
      final int mid = (low + high + 1) ~/ 2;
      if (sums[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// The window to realize for a viewport of [viewportExtent] at [scrollOffset].
  RealizedRange rangeFor({
    required double scrollOffset,
    required double viewportExtent,
  }) {
    if (itemCount == 0) {
      return const RealizedRange(
        firstVisible: 0,
        lastVisible: -1,
        firstRealized: 0,
        lastRealized: -1,
        leadingExtent: 0,
      );
    }
    final double top = scrollOffset.clamp(0.0, double.infinity);
    final int firstVisible = indexAt(top);
    final int lastVisible = indexAt(top + viewportExtent);
    final int firstRealized = indexAt(top - cacheExtent);
    final int lastRealized = indexAt(top + viewportExtent + cacheExtent);
    return RealizedRange(
      firstVisible: firstVisible,
      lastVisible: lastVisible,
      firstRealized: firstRealized,
      lastRealized: lastRealized,
      leadingExtent: offsetOf(firstRealized),
    );
  }

  /// The scroll offset that brings [index] fully into view from
  /// [scrollOffset], or null when it already is.
  ///
  /// This is the scroll anchor: keyboard navigation to an item just below the
  /// fold must scroll by exactly one item, not centre the list.
  double? scrollToReveal(
    int index, {
    required double scrollOffset,
    required double viewportExtent,
  }) {
    final double start = offsetOf(index);
    final double end = start + extentOf(index);
    if (start < scrollOffset) return start;
    if (end > scrollOffset + viewportExtent) return end - viewportExtent;
    return null;
  }

  /// Fills the position cache up to and including [index].
  void _sumThrough(int index) {
    final List<double>? sums = _prefixSums;
    if (sums == null) return;
    final List<double> extents = _extents!;
    while (_summedTo < index) {
      sums[_summedTo + 1] = sums[_summedTo] + extents[_summedTo];
      _summedTo++;
    }
  }

  /// Fills the position cache until it passes [offset] or runs out of items.
  void _sumWhileBelow(double offset) {
    final List<double> sums = _prefixSums!;
    final List<double> extents = _extents!;
    while (_summedTo < itemCount && sums[_summedTo] <= offset) {
      sums[_summedTo + 1] = sums[_summedTo] + extents[_summedTo];
      _summedTo++;
    }
  }
}
