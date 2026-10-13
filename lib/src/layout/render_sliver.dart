/// Slivers: pieces of a scrollable that are laid out *by scroll offset*.
///
/// [RenderViewport] scrolls one box. It lays its child out unbounded on the
/// scroll axis and translates it, which is exactly right for a form and exactly
/// wrong for anything that has to behave differently depending on where in the
/// scroll it is: a header that stays pinned while the list under it moves, a
/// list of a hundred thousand rows that must build only the dozen on screen, a
/// footer that fills whatever is left of the viewport. None of those can be
/// expressed as "a box of some height, moved". Each needs to be *told* how far
/// it has been scrolled and how much of the screen is left, and to answer with
/// how much of itself it is painting.
///
/// That question and that answer are the whole protocol, and they are
/// Flutter's, because Flutter's are right:
///
///   * [SliverConstraints] go down - "you have been scrolled by `scrollOffset`
///     into yourself, and `remainingPaintExtent` pixels of the viewport are
///     left for you";
///   * [SliverGeometry] comes up - "I am `scrollExtent` long in scroll space,
///     I paint `paintExtent` pixels, and the next sliver starts
///     `layoutExtent` pixels after my start".
///
/// The two extents are different numbers, and that difference is what a
/// pinned header *is*: scrolled past its own end, it still paints its minimum
/// height (`paintExtent > 0`) while taking up no layout room
/// (`layoutExtent == 0`), so the list after it slides underneath.
///
/// ## How a sliver fits a tree of boxes
///
/// The render tree here is made of [RenderBox]es and nothing else - the
/// pipeline, the relayout boundaries, paint caching and hit testing all speak
/// boxes. A second kind of render object with its own copy of all of that would
/// be the largest single change this framework could make, for a protocol that
/// only one parent ([RenderSliverViewport]) ever drives.
///
/// So a sliver is a box with a second, richer contract on the side, which is
/// what [RenderSliver] adds as a mixin:
///
///   * the viewport calls [RenderSliver.layoutAsSliver] with the
///     [SliverConstraints], which records them and runs an ordinary box
///     [RenderBox.layout] whose constraints are "the viewport's cross extent,
///     and up to the viewport's main extent";
///   * the sliver's box is sized to **what it paints**: the cross extent by
///     [SliverGeometry.paintExtent]. The viewport puts that box where the
///     sliver's painting starts.
///
/// Sizing the box to the painted part is the decision everything else falls out
/// of. Painting, clipping and hit testing are then plain box operations: a
/// list row half scrolled off the top sits at a negative offset inside its
/// sliver's box, the viewport's clip hides the part above, and
/// [RenderBox.hitTest]'s bounds check refuses a press on the hidden half
/// without a line of sliver-specific hit testing.
///
/// ## Lazy children
///
/// [RenderSliverList] and [RenderSliverGrid] create their children *during
/// layout*, because only layout knows which indices the constraints reach. The
/// render layer cannot build a widget, so it asks a [SliverChildManager] -
/// which the widget layer implements on the element - to make exactly a range
/// of indices exist, and the element does it inside
/// `BuildOwner.buildDuringLayout`, the same escape hatch `LayoutBuilder` uses.
///
/// ## What is deliberately not here
///
///   * **a center sliver and growth in both directions.** Flutter's viewport
///     can grow slivers upwards from a `center` for a chat log that loads
///     history above. Here every sliver grows from the leading edge;
///     [RenderSliverViewport.reverse] flips the whole axis, which is what a
///     chat log scrolled from the bottom needs;
///   * **shrink-wrapping.** The viewport is as big as its constraints allow,
///     like [RenderViewport];
///   * **keep-alive.** An item that scrolls out of the cache region is
///     destroyed, state and all - the same rule `ListView` follows here.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import 'box_constraints.dart';
import 'edge_insets.dart';
import 'list_virtualization.dart';
import 'pipeline.dart';
import 'render_box.dart';
import 'render_viewport.dart';

/// What a viewport tells one sliver about where it is in the scroll.
///
/// All extents are in logical pixels along [axis] unless the name says
/// "cross". "Scroll space" is the coordinate a sliver's content has before
/// scrolling - its first pixel is at zero - and "paint space" is the viewport.
final class SliverConstraints {
  const SliverConstraints({
    required this.axis,
    this.reverse = false,
    required this.scrollOffset,
    this.precedingScrollExtent = 0,
    this.overlap = 0,
    required this.remainingPaintExtent,
    required this.crossAxisExtent,
    required this.viewportMainAxisExtent,
    double? remainingCacheExtent,
    this.cacheOrigin = 0,
  }) : remainingCacheExtent = remainingCacheExtent ?? remainingPaintExtent;

  /// The scroll axis.
  final ScrollAxis axis;

  /// Whether the leading edge is the bottom (or the right) of the viewport.
  ///
  /// A sliver lays out the same way either way - its first item has scroll
  /// offset zero - and flips only where it *places* its children, through
  /// [RenderSliver.childBoxOffset].
  final bool reverse;

  /// How far into this sliver the viewport's leading edge is, in scroll space.
  ///
  /// Zero while the sliver starts at or after the leading edge; past its own
  /// [SliverGeometry.scrollExtent] once it has scrolled entirely out.
  final double scrollOffset;

  /// The total scroll extent of every sliver before this one.
  ///
  /// What [SliverFillRemaining]-style slivers subtract from the viewport to
  /// know how much is "remaining".
  final double precedingScrollExtent;

  /// How far an earlier sliver paints *into* this one's leading edge.
  ///
  /// A pinned header scrolled past its end still paints its minimum height
  /// while reporting no layout extent, so the sliver after it starts under it
  /// and is told by how much. A list ignores this - its rows slide under the
  /// header, which is the effect - while a second pinned header uses it to
  /// stack below the first rather than on top of it.
  final double overlap;

  /// How many pixels of the viewport are left from this sliver's leading
  /// edge to the trailing edge.
  final double remainingPaintExtent;

  /// The viewport's extent across the scroll axis, less any cross padding of
  /// an enclosing [RenderSliverPadding].
  final double crossAxisExtent;

  /// The viewport's own extent along the scroll axis.
  final double viewportMainAxisExtent;

  /// How many pixels from [cacheOrigin] the sliver should keep realized.
  ///
  /// The cache is the region before and after the visible one in which a lazy
  /// list keeps children built, so that the row about to scroll in exists
  /// before the frame that shows it.
  final double remainingCacheExtent;

  /// Where the cache region starts relative to [scrollOffset]. Zero or
  /// negative: the cache reaches *back* by at most the viewport's cache extent.
  final double cacheOrigin;

  /// The box constraints for a child that fills the cross axis and may be
  /// anywhere from [minExtent] to [maxExtent] along the scroll axis.
  BoxConstraints asBoxConstraints({
    double minExtent = 0,
    double maxExtent = double.infinity,
    double? crossAxisExtent,
  }) {
    final double cross = crossAxisExtent ?? this.crossAxisExtent;
    return axis == ScrollAxis.vertical
        ? BoxConstraints(
            minWidth: cross,
            maxWidth: cross,
            minHeight: minExtent,
            maxHeight: maxExtent,
          )
        : BoxConstraints(
            minWidth: minExtent,
            maxWidth: maxExtent,
            minHeight: cross,
            maxHeight: cross,
          );
  }

  SliverConstraints copyWith({
    double? scrollOffset,
    double? precedingScrollExtent,
    double? overlap,
    double? remainingPaintExtent,
    double? crossAxisExtent,
    double? remainingCacheExtent,
    double? cacheOrigin,
  }) =>
      SliverConstraints(
        axis: axis,
        reverse: reverse,
        scrollOffset: scrollOffset ?? this.scrollOffset,
        precedingScrollExtent:
            precedingScrollExtent ?? this.precedingScrollExtent,
        overlap: overlap ?? this.overlap,
        remainingPaintExtent: remainingPaintExtent ?? this.remainingPaintExtent,
        crossAxisExtent: crossAxisExtent ?? this.crossAxisExtent,
        viewportMainAxisExtent: viewportMainAxisExtent,
        remainingCacheExtent: remainingCacheExtent ?? this.remainingCacheExtent,
        cacheOrigin: cacheOrigin ?? this.cacheOrigin,
      );

  @override
  bool operator ==(Object other) =>
      other is SliverConstraints &&
      other.axis == axis &&
      other.reverse == reverse &&
      other.scrollOffset == scrollOffset &&
      other.precedingScrollExtent == precedingScrollExtent &&
      other.overlap == overlap &&
      other.remainingPaintExtent == remainingPaintExtent &&
      other.crossAxisExtent == crossAxisExtent &&
      other.viewportMainAxisExtent == viewportMainAxisExtent &&
      other.remainingCacheExtent == remainingCacheExtent &&
      other.cacheOrigin == cacheOrigin;

  @override
  int get hashCode => Object.hash(
        axis,
        reverse,
        scrollOffset,
        precedingScrollExtent,
        overlap,
        remainingPaintExtent,
        crossAxisExtent,
        viewportMainAxisExtent,
        remainingCacheExtent,
        cacheOrigin,
      );

  @override
  String toString() => 'SliverConstraints(${axis.name}'
      '${reverse ? ', reverse' : ''}, scrollOffset: $scrollOffset, '
      'remainingPaintExtent: $remainingPaintExtent, overlap: $overlap, '
      'cross: $crossAxisExtent, cache: $cacheOrigin+$remainingCacheExtent)';
}

/// What one sliver answers about itself after layout.
final class SliverGeometry {
  const SliverGeometry({
    this.scrollExtent = 0,
    this.paintOrigin = 0,
    this.paintExtent = 0,
    double? layoutExtent,
    this.maxPaintExtent = 0,
    double? hitTestExtent,
    double? cacheExtent,
    this.hasVisualOverflow = false,
    this.scrollOffsetCorrection = 0,
  })  : layoutExtent = layoutExtent ?? paintExtent,
        hitTestExtent = hitTestExtent ?? paintExtent,
        cacheExtent = cacheExtent ?? layoutExtent ?? paintExtent;

  /// Nothing: no extent, nothing painted.
  static const SliverGeometry zero = SliverGeometry();

  /// How long this sliver is in scroll space - what it adds to the content
  /// extent the scrollbar describes.
  final double scrollExtent;

  /// Where painting starts relative to where layout put this sliver. Negative
  /// or positive for headers that paint over their neighbours; zero for
  /// everything else.
  final double paintOrigin;

  /// How many pixels of the viewport this sliver paints, and therefore the
  /// main-axis size of its box.
  final double paintExtent;

  /// How far after this sliver's start the next one is placed. Equal to
  /// [paintExtent] except for headers that overlap what follows.
  final double layoutExtent;

  /// The paint extent this sliver would have with unlimited room.
  final double maxPaintExtent;

  /// The extent along the axis that answers hit tests. Recorded for parity
  /// with Flutter; the box is sized by [paintExtent], which is what hit
  /// testing reads here.
  final double hitTestExtent;

  /// How much of the cache region this sliver consumed.
  final double cacheExtent;

  /// Whether anything is painted outside the box, which a parent clips.
  final bool hasVisualOverflow;

  /// Non-zero to ask the viewport to move its scroll offset by this much and
  /// lay out again; every other field is then ignored.
  ///
  /// The case that needs it is a list of rows whose heights were estimated:
  /// measuring a row *above* the visible ones changes where every visible row
  /// is in scroll space, and only moving the offset by the same amount keeps
  /// the row under the user's eye from jumping.
  final double scrollOffsetCorrection;

  /// Whether the sliver paints anything at all.
  bool get visible => paintExtent > 0;

  @override
  String toString() => 'SliverGeometry(scroll: $scrollExtent, '
      'paint: $paintExtent${paintOrigin == 0 ? '' : ' at $paintOrigin'}, '
      'layout: $layoutExtent'
      '${scrollOffsetCorrection == 0 ? '' : ', correct by $scrollOffsetCorrection'})';
}

/// The thrown answer to a sliver placed where a box was expected, or the
/// other way round.
///
/// Named rather than a cast failure because the mistake is always one of two
/// easy ones - a `SizedBox` straight in `CustomScrollView.slivers`, or a
/// `SliverList` inside a `Column` - and both have a one-word fix.
final class SliverProtocolError extends Error {
  SliverProtocolError(this.message);

  final String message;

  @override
  String toString() => 'SliverProtocolError: $message';
}

/// The sliver half of a render object: [SliverConstraints] in,
/// [SliverGeometry] out, on top of an ordinary [RenderBox].
///
/// A mixin rather than a base class because the single-child slivers want
/// [RenderSingleChildBox]'s child bookkeeping - and with it the element
/// layer's existing way of plugging a render child in - while the lazy lists
/// want their own index-keyed children. Both are still "a sliver", and the
/// viewport tests for exactly that type.
///
/// Subclasses implement [performSliverLayout] and never [performLayout]: the
/// mixin's [performLayout] runs it and sizes the box from the answer.
mixin RenderSliver on RenderBox {
  SliverConstraints? _sliverConstraints;
  SliverGeometry _geometry = SliverGeometry.zero;

  /// The constraints of the current layout. Throws when this sliver was laid
  /// out by something that is not a sliver parent.
  SliverConstraints get sliverConstraints {
    final SliverConstraints? constraints = _sliverConstraints;
    if (constraints == null) {
      throw SliverProtocolError(
        '$runtimeType is a sliver and was laid out as a box. Slivers go '
        'directly in CustomScrollView.slivers (or in a SliverPadding); a box '
        'that has to sit among slivers is wrapped in SliverToBoxAdapter.',
      );
    }
    return constraints;
  }

  /// The answer of the last layout.
  SliverGeometry get geometry => _geometry;

  /// Lays this sliver out under [constraints].
  ///
  /// The box layout underneath is given the cross extent tightly and up to the
  /// viewport's main extent loosely. Those box constraints rarely change while
  /// scrolling, so a change in [constraints] alone has to dirty this node
  /// itself - which is a no-op mark while the parent is inside its own layout,
  /// the only place this is called from.
  void layoutAsSliver(SliverConstraints constraints) {
    if (constraints != _sliverConstraints) {
      _sliverConstraints = constraints;
      markNeedsLayout();
    }
    layout(
      constraints.asBoxConstraints(
        maxExtent: constraints.viewportMainAxisExtent,
      ),
      parentUsesSize: true,
    );
  }

  /// Computes this sliver's geometry and positions its children.
  @protected
  SliverGeometry performSliverLayout();

  @override
  void performLayout() {
    final SliverConstraints constraints = sliverConstraints;
    final SliverGeometry geometry = performSliverLayout();
    _geometry = geometry;
    final double extent = geometry.scrollOffsetCorrection != 0
        ? 0
        : math.max(0.0, geometry.paintExtent);
    size = this.constraints.constrain(
          constraints.axis == ScrollAxis.vertical
              ? Size(constraints.crossAxisExtent, extent)
              : Size(extent, constraints.crossAxisExtent),
        );
  }

  /// How much of the scroll-space interval `[from, to]` is visible.
  ///
  /// Flutter's `calculatePaintOffset`, and the one piece of arithmetic every
  /// sliver needs: the interval is clipped to the visible window
  /// `[scrollOffset, scrollOffset + remainingPaintExtent]`.
  double calculatePaintOffset({required double from, required double to}) {
    final SliverConstraints constraints = sliverConstraints;
    final double a = constraints.scrollOffset;
    final double b =
        constraints.scrollOffset + constraints.remainingPaintExtent;
    return (to.clamp(a, b) - from.clamp(a, b))
        .clamp(0.0, constraints.remainingPaintExtent);
  }

  /// How much of the scroll-space interval `[from, to]` falls in the cache
  /// region, which is the visible window widened by the cache extent.
  double calculateCacheOffset({required double from, required double to}) {
    final SliverConstraints constraints = sliverConstraints;
    final double a = constraints.scrollOffset + constraints.cacheOrigin;
    final double b = a + constraints.remainingCacheExtent;
    return (to.clamp(a, b) - from.clamp(a, b))
        .clamp(0.0, constraints.remainingCacheExtent);
  }

  /// The box offset of a child whose leading edge is [mainAxisPosition]
  /// pixels after this sliver's leading paint edge.
  ///
  /// The one place reversal is applied inside a sliver: in a reversed
  /// viewport the leading edge is the bottom of the box, so the child's top is
  /// measured from there. [paintExtent] is this sliver's box extent - the
  /// geometry about to be returned, which is why it is passed in rather than
  /// read from [geometry].
  Offset childBoxOffset({
    required double mainAxisPosition,
    required double childMainAxisExtent,
    required double paintExtent,
    double crossAxisPosition = 0,
  }) {
    final SliverConstraints constraints = sliverConstraints;
    final double main = constraints.reverse
        ? paintExtent - mainAxisPosition - childMainAxisExtent
        : mainAxisPosition;
    return constraints.axis == ScrollAxis.vertical
        ? Offset(crossAxisPosition, main)
        : Offset(main, crossAxisPosition);
  }

  /// [child]'s extent along the scroll axis.
  double mainAxisExtentOf(RenderBox child) =>
      sliverConstraints.axis == ScrollAxis.vertical
          ? child.size.height
          : child.size.width;

  // A sliver's extent along the axis is a function of the scroll offset, and
  // its extent across it belongs to the viewport, so neither is an intrinsic
  // property. Zero is "take what you are given", the same answer
  // RenderViewport gives on its scroll axis.

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => null;
}

// ---------------------------------------------------------------------------
// The viewport
// ---------------------------------------------------------------------------

/// Lays a sequence of slivers out along one axis and scrolls them.
///
/// The algorithm is Flutter's `layoutChildSequence` for the forward direction:
/// walk the slivers in order, telling each how far into it the scroll offset
/// reaches and how much screen is left, and advance by what each reports. The
/// content extent handed to the [ScrollPosition] is the sum of every sliver's
/// [SliverGeometry.scrollExtent] - including the ones past the end of the
/// screen, which are still laid out (with nothing left to paint) precisely so
/// that a lazy list's full length reaches the scrollbar.
///
/// Open for extension like [RenderViewport]: the widget layer adds keyboard,
/// focus and accessibility, which this layer cannot name.
class RenderSliverViewport extends RenderBoxContainer<BoxParentData> {
  RenderSliverViewport({
    required ScrollPosition position,
    bool reverse = false,
    double cacheExtent = 0,
  })  : _position = position,
        _reverse = reverse,
        _cacheExtent = cacheExtent;

  /// How many times one layout may be restarted by a scroll offset
  /// correction before the last answer is accepted.
  ///
  /// Each correction comes from measuring rows that were estimated, and a row
  /// is measured once, so a real list converges in one or two. The bound is
  /// for a list whose rows change size every time they are laid out, which
  /// would otherwise hang the frame.
  static const int maxCorrections = 10;

  ScrollPosition _position;
  bool _reverse;
  double _cacheExtent;
  bool _listening = false;
  double _scrollExtent = 0;
  int _corrections = 0;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    if (_listening) _position.removeListener(_onScrolled);
    _position = value;
    if (_listening) _position.addListener(_onScrolled);
    markNeedsLayout();
  }

  ScrollAxis get axis => _position.axis;

  /// Whether the scroll starts at the bottom (or right) and grows upwards.
  bool get reverse => _reverse;

  set reverse(bool value) {
    if (value == _reverse) return;
    _reverse = value;
    markNeedsLayout();
  }

  /// How far beyond each edge of the viewport lazy slivers keep children
  /// built, in pixels.
  double get cacheExtent => _cacheExtent;

  set cacheExtent(double value) {
    if (value == _cacheExtent) return;
    _cacheExtent = value;
    markNeedsLayout();
  }

  /// The total scroll extent of the last layout: the sum of every sliver's.
  double get scrollExtent => _scrollExtent;

  /// How many scroll offset corrections the last layout applied. For tests
  /// and diagnostics: a list whose rows are measured as they appear corrects
  /// once when it scrolls up into rows it had only estimated.
  int get lastLayoutCorrections => _corrections;

  /// The slivers, in order.
  List<RenderSliver> get slivers => <RenderSliver>[
        for (int i = 0; i < childCount; i++) _sliverAt(i),
      ];

  RenderSliver _sliverAt(int index) {
    final RenderBox child = childAt(index);
    if (child is RenderSliver) return child;
    throw SliverProtocolError(
      'a ${child.runtimeType} is a box, and a sliver viewport lays out '
      'slivers. Wrap it in a SliverToBoxAdapter.',
    );
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    if (!_listening) {
      _position.addListener(_onScrolled);
      _listening = true;
    }
  }

  @override
  void detach() {
    if (_listening) {
      _position.removeListener(_onScrolled);
      _listening = false;
    }
    super.detach();
  }

  void _onScrolled(ScrollPosition position) => markNeedsLayout();

  // The same intrinsic answer RenderViewport gives on its scroll axis, and on
  // the cross axis too: the slivers' cross extent is whatever this viewport
  // is given, so there is nothing to ask them.
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => null;

  @override
  void performLayout() {
    size = constraints.constrain(
      Size(
        constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.minWidth,
        constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.minHeight,
      ),
    );
    final bool vertical = axis == ScrollAxis.vertical;
    final double mainExtent = vertical ? size.height : size.width;
    final double crossExtent = vertical ? size.width : size.height;
    _corrections = 0;
    for (int attempt = 0; attempt <= maxCorrections; attempt++) {
      final double pixels = _position.pixels;
      final double correction = _layoutSlivers(pixels, mainExtent, crossExtent);
      if (correction != 0 && attempt < maxCorrections) {
        _corrections++;
        _position.correctBy(correction);
        continue;
      }
      _position.applyViewportGeometry(
        viewportExtent: mainExtent,
        contentExtent: _scrollExtent,
      );
      // The geometry re-clamps: a list that turned out shorter than estimated
      // can leave the offset past the new end. The slivers were laid out at
      // the old offset, so they are laid out again at the clamped one.
      if (_position.pixels == pixels) break;
    }
  }

  /// One pass over the slivers at [pixels]. Returns a scroll offset
  /// correction, or zero when the pass is final.
  double _layoutSlivers(double pixels, double mainExtent, double crossExtent) {
    // A negative offset is overscroll at the start: the content is pushed
    // down by it, so the first sliver starts that far into the viewport.
    final double initialLayoutOffset = math.max(0.0, -pixels);
    double scrollOffset = math.max(0.0, pixels);
    final double fullCacheExtent = mainExtent + 2 * _cacheExtent;
    double remainingCacheExtent =
        (fullCacheExtent - (_cacheExtent - pixels)).clamp(0.0, fullCacheExtent);
    double cacheOrigin = (-pixels).clamp(-_cacheExtent, 0.0);
    double layoutOffset = initialLayoutOffset;
    double maxPaintOffset = layoutOffset;
    double precedingScrollExtent = 0;
    double total = 0;

    for (int i = 0; i < childCount; i++) {
      final RenderSliver sliver = _sliverAt(i);
      final double sliverScrollOffset = math.max(0.0, scrollOffset);
      final double correctedCacheOrigin =
          math.max(cacheOrigin, -sliverScrollOffset);
      final double cacheExtentCorrection = cacheOrigin - correctedCacheOrigin;
      sliver.layoutAsSliver(SliverConstraints(
        axis: axis,
        reverse: _reverse,
        scrollOffset: sliverScrollOffset,
        precedingScrollExtent: precedingScrollExtent,
        overlap: maxPaintOffset - layoutOffset,
        remainingPaintExtent: math.max(0.0, mainExtent - layoutOffset),
        crossAxisExtent: crossExtent,
        viewportMainAxisExtent: mainExtent,
        remainingCacheExtent:
            math.max(0.0, remainingCacheExtent + cacheExtentCorrection),
        cacheOrigin: correctedCacheOrigin,
      ));
      final SliverGeometry geometry = sliver.geometry;
      if (geometry.scrollOffsetCorrection != 0) {
        return geometry.scrollOffsetCorrection;
      }
      final double effectiveLayoutOffset = layoutOffset + geometry.paintOrigin;
      // A sliver that is not painted still gets a position, off the leading
      // edge by however far it has scrolled, so that a test reading offsets
      // or a semantics walk never finds a stale one.
      final double paintOffset = geometry.visible || scrollOffset > 0
          ? effectiveLayoutOffset
          : -scrollOffset + initialLayoutOffset;
      final double main = _reverse
          ? mainExtent - paintOffset - geometry.paintExtent
          : paintOffset;
      sliver.parentData!.offset = _alongAxis(main);
      maxPaintOffset = math.max(
        effectiveLayoutOffset + geometry.paintExtent,
        maxPaintOffset,
      );
      scrollOffset -= geometry.scrollExtent;
      precedingScrollExtent += geometry.scrollExtent;
      layoutOffset += geometry.layoutExtent;
      total += geometry.scrollExtent;
      if (geometry.cacheExtent != 0) {
        remainingCacheExtent -= geometry.cacheExtent - cacheExtentCorrection;
        cacheOrigin = math.min(correctedCacheOrigin + geometry.cacheExtent, 0);
      }
    }
    _scrollExtent = total;
    return 0;
  }

  /// [main] as an offset along the axis.
  Offset _alongAxis(double main) =>
      axis == ScrollAxis.vertical ? Offset(0, main) : Offset(main, 0);

  @override
  void paint(DisplayList list, Offset offset) {
    if (childCount == 0) return;
    // Clipping is what makes the sliver-sized boxes work: a row half scrolled
    // off the top paints at a negative offset, and only this clip stops it
    // painting over whatever is above the viewport.
    list.save();
    list.clipRect(
      offset.dx,
      offset.dy,
      offset.dx + size.width,
      offset.dy + size.height,
    );
    // Last to first, so the first sliver paints on top. That is the order a
    // pinned header needs: the rows that slide under it are painted before it.
    for (int i = childCount - 1; i >= 0; i--) {
      final RenderBox child = childAt(i);
      if (!_sliverAt(i).geometry.visible) continue;
      paintChild(list, child, offset);
    }
    list.restore();
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    if (!size.contains(position)) return null;
    // First to last: the reverse of paint, so the sliver painted on top - a
    // pinned header over the rows under it - is the one that is pressed.
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      if (!_sliverAt(i).geometry.visible) continue;
      final Offset childOffset = child.offsetFromParent;
      final RenderBox? hit = child.hitTest(
        Offset(position.dx - childOffset.dx, position.dy - childOffset.dy),
        path: path,
      );
      if (hit != null) return hit;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Single-child slivers
// ---------------------------------------------------------------------------

/// A sliver that holds one box, laid out in full and scrolled.
///
/// The sliver equivalent of the content of a `SingleChildScrollView`: the box
/// is laid out unbounded on the scroll axis, and the sliver reports its whole
/// extent as scroll extent and the visible part of it as paint extent.
final class RenderSliverToBoxAdapter extends RenderSingleChildBox
    with RenderSliver {
  RenderSliverToBoxAdapter({super.child});

  @override
  SliverGeometry performSliverLayout() {
    final SliverConstraints constraints = sliverConstraints;
    final RenderBox? child = this.child;
    if (child == null) return SliverGeometry.zero;
    child.layout(constraints.asBoxConstraints(), parentUsesSize: true);
    final double extent = mainAxisExtentOf(child);
    final double paintExtent = calculatePaintOffset(from: 0, to: extent);
    child.parentData!.offset = childBoxOffset(
      mainAxisPosition: -constraints.scrollOffset,
      childMainAxisExtent: extent,
      paintExtent: paintExtent,
    );
    return SliverGeometry(
      scrollExtent: extent,
      paintExtent: paintExtent,
      cacheExtent: calculateCacheOffset(from: 0, to: extent),
      maxPaintExtent: extent,
      hasVisualOverflow: extent > constraints.remainingPaintExtent ||
          constraints.scrollOffset > 0,
    );
  }
}

/// Insets one sliver by [padding].
///
/// The padding is scroll space too: the leading inset scrolls away before the
/// child starts to, and the trailing one is scrolled into after it ends. So
/// the child is told a scroll offset reduced by the leading inset, a cross
/// extent reduced by the cross insets, and a remaining paint extent reduced by
/// however much of the leading inset is on screen.
final class RenderSliverPadding extends RenderSingleChildBox with RenderSliver {
  RenderSliverPadding({required EdgeInsets padding, super.child})
      : _padding = padding;

  EdgeInsets _padding;

  EdgeInsets get padding => _padding;

  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  RenderSliver? get _sliverChild {
    final RenderBox? child = this.child;
    if (child == null) return null;
    if (child is RenderSliver) return child;
    throw SliverProtocolError(
      'SliverPadding pads a sliver, and its child is a ${child.runtimeType}, '
      'which is a box. Use Padding inside a SliverToBoxAdapter instead.',
    );
  }

  @override
  SliverGeometry performSliverLayout() {
    final SliverConstraints constraints = sliverConstraints;
    final bool vertical = constraints.axis == ScrollAxis.vertical;
    final double before = vertical
        ? (constraints.reverse ? _padding.bottom : _padding.top)
        : (constraints.reverse ? _padding.right : _padding.left);
    final double after = vertical
        ? (constraints.reverse ? _padding.top : _padding.bottom)
        : (constraints.reverse ? _padding.left : _padding.right);
    final double mainAxisPadding = before + after;
    final double crossAxisPadding =
        vertical ? _padding.horizontal : _padding.vertical;
    final double crossAxisLeading = vertical ? _padding.left : _padding.top;

    final RenderSliver? child = _sliverChild;
    if (child == null) {
      final double paintExtent =
          calculatePaintOffset(from: 0, to: mainAxisPadding);
      return SliverGeometry(
        scrollExtent: mainAxisPadding,
        paintExtent: paintExtent,
        maxPaintExtent: mainAxisPadding,
        cacheExtent: calculateCacheOffset(from: 0, to: mainAxisPadding),
      );
    }
    final double beforePaint = calculatePaintOffset(from: 0, to: before);
    child.layoutAsSliver(constraints.copyWith(
      scrollOffset: math.max(0.0, constraints.scrollOffset - before),
      cacheOrigin: math.min(0.0, constraints.cacheOrigin + before),
      overlap: math.max(0.0, constraints.overlap - before),
      remainingPaintExtent: constraints.remainingPaintExtent - beforePaint,
      remainingCacheExtent: constraints.remainingCacheExtent -
          calculateCacheOffset(from: 0, to: before),
      crossAxisExtent:
          math.max(0.0, constraints.crossAxisExtent - crossAxisPadding),
      precedingScrollExtent: before + constraints.precedingScrollExtent,
    ));
    final SliverGeometry childGeometry = child.geometry;
    if (childGeometry.scrollOffsetCorrection != 0) {
      return SliverGeometry(
        scrollOffsetCorrection: childGeometry.scrollOffsetCorrection,
      );
    }
    final double childScroll = childGeometry.scrollExtent;
    final double afterPaint = calculatePaintOffset(
      from: before + childScroll,
      to: mainAxisPadding + childScroll,
    );
    final double paddingPaint = beforePaint + afterPaint;
    final double paddingCache = calculateCacheOffset(from: 0, to: before) +
        calculateCacheOffset(
          from: before + childScroll,
          to: mainAxisPadding + childScroll,
        );
    final double paintExtent = math.min(
      beforePaint +
          math.max(
            childGeometry.paintExtent,
            childGeometry.layoutExtent + afterPaint,
          ),
      constraints.remainingPaintExtent,
    );
    child.parentData!.offset = childBoxOffset(
      mainAxisPosition: beforePaint,
      childMainAxisExtent: childGeometry.paintExtent,
      paintExtent: paintExtent,
      crossAxisPosition: crossAxisLeading,
    );
    return SliverGeometry(
      paintOrigin: childGeometry.paintOrigin,
      scrollExtent: mainAxisPadding + childScroll,
      paintExtent: paintExtent,
      layoutExtent: math.min(
        paddingPaint + childGeometry.layoutExtent,
        paintExtent,
      ),
      cacheExtent: math.min(
        paddingCache + childGeometry.cacheExtent,
        constraints.remainingCacheExtent,
      ),
      maxPaintExtent: mainAxisPadding + childGeometry.maxPaintExtent,
      hasVisualOverflow: childGeometry.hasVisualOverflow,
    );
  }
}

/// A sliver that fills what is left of the viewport after everything before
/// it.
///
/// With [hasScrollBody] false it is the "footer at the bottom of a short
/// page": as tall as the space left below the preceding slivers, or as tall as
/// its child wants if that is more, so a page shorter than the window puts the
/// footer at the window's bottom edge and a longer page scrolls to it. With
/// [hasScrollBody] true it is always exactly one viewport tall - the shape a
/// nested scrollable underneath wants.
final class RenderSliverFillRemaining extends RenderSingleChildBox
    with RenderSliver {
  RenderSliverFillRemaining({bool hasScrollBody = true, super.child})
      : _hasScrollBody = hasScrollBody;

  bool _hasScrollBody;

  bool get hasScrollBody => _hasScrollBody;

  set hasScrollBody(bool value) {
    if (value == _hasScrollBody) return;
    _hasScrollBody = value;
    markNeedsLayout();
  }

  @override
  SliverGeometry performSliverLayout() {
    final SliverConstraints constraints = sliverConstraints;
    final RenderBox? child = this.child;
    final double scrollExtent;
    final double extent;
    if (_hasScrollBody) {
      extent =
          constraints.remainingPaintExtent - math.min(0.0, constraints.overlap);
      scrollExtent = constraints.viewportMainAxisExtent;
    } else {
      double remaining = math.max(
        0.0,
        constraints.viewportMainAxisExtent - constraints.precedingScrollExtent,
      );
      if (child != null) {
        // The intrinsic query is the sanctioned way to ask "how tall do you
        // want to be at this width" without laying the child out twice.
        final double natural = constraints.axis == ScrollAxis.vertical
            ? child.getMaxIntrinsicHeight(constraints.crossAxisExtent)
            : child.getMaxIntrinsicWidth(constraints.crossAxisExtent);
        remaining = math.max(remaining, natural);
      }
      extent = remaining;
      scrollExtent = remaining;
    }
    child?.layout(
      constraints.asBoxConstraints(minExtent: extent, maxExtent: extent),
      parentUsesSize: true,
    );
    final double paintExtent = calculatePaintOffset(from: 0, to: extent);
    if (child != null) {
      child.parentData!.offset = childBoxOffset(
        mainAxisPosition: -constraints.scrollOffset,
        childMainAxisExtent: extent,
        paintExtent: paintExtent,
      );
    }
    return SliverGeometry(
      scrollExtent: scrollExtent,
      paintExtent: paintExtent,
      maxPaintExtent: paintExtent,
      cacheExtent: calculateCacheOffset(from: 0, to: scrollExtent),
      hasVisualOverflow: extent > constraints.remainingPaintExtent ||
          constraints.scrollOffset > 0,
    );
  }
}

/// A header whose height depends on how far it has been scrolled.
///
/// The child is laid out at `maxExtent - shrinkOffset`, never less than
/// [minExtent], where `shrinkOffset` is how much of the header has scrolled
/// away. Three behaviours, chosen by [pinned] and [floating]:
///
///   * **neither** - it scrolls away like any content, shrinking as it goes;
///   * **[pinned]** - it shrinks from [maxExtent] to [minExtent] and then
///     stays at the leading edge, painted over the content that scrolls under
///     it. That is the whole trick: once shrunk it reports a *layout* extent of
///     zero and a *paint* extent of [minExtent];
///   * **[floating]** - it scrolls away, and comes back as soon as the user
///     scrolls back towards the start, from wherever in the content they are.
///
/// [childBuilder] is how the widget layer rebuilds the child for a new shrink
/// offset: the child is a function of a number only layout knows.
final class RenderSliverPersistentHeader extends RenderSingleChildBox
    with RenderSliver {
  RenderSliverPersistentHeader({
    required double minExtent,
    required double maxExtent,
    bool pinned = false,
    bool floating = false,
    super.child,
  })  : _minExtent = minExtent,
        _maxExtent = math.max(minExtent, maxExtent),
        _pinned = pinned,
        _floating = floating;

  double _minExtent;
  double _maxExtent;
  bool _pinned;
  bool _floating;

  /// Asked to rebuild the child for a shrink offset; installed by the
  /// element. Null is legal and means "the child is whatever it is".
  void Function(double shrinkOffset, bool overlapsContent)? childBuilder;

  bool _needsChildUpdate = true;
  double? _lastShrinkOffset;
  bool? _lastOverlapsContent;
  double? _lastActualScrollOffset;
  double _effectiveScrollOffset = 0;
  double _childExtent = 0;

  /// The extent the header shrinks to.
  double get minExtent => _minExtent;

  set minExtent(double value) {
    if (value == _minExtent) return;
    _minExtent = value;
    markNeedsLayout();
  }

  /// The extent the header has when nothing of it has scrolled away.
  double get maxExtent => _maxExtent;

  set maxExtent(double value) {
    if (value == _maxExtent) return;
    _maxExtent = value;
    markNeedsLayout();
  }

  bool get pinned => _pinned;

  set pinned(bool value) {
    if (value == _pinned) return;
    _pinned = value;
    markNeedsLayout();
  }

  bool get floating => _floating;

  set floating(bool value) {
    if (value == _floating) return;
    _floating = value;
    _lastActualScrollOffset = null;
    markNeedsLayout();
  }

  /// The shrink offset the child was last built for.
  double get shrinkOffset => _lastShrinkOffset ?? 0;

  /// The extent the child was last laid out at.
  double get childExtent => _childExtent;

  /// Forces the next layout to rebuild the child even at the same shrink
  /// offset - after a new delegate, or a dependency it read changed.
  void markNeedsChildUpdate() {
    _needsChildUpdate = true;
    markNeedsLayout();
  }

  void _layoutChild(double scrollOffset, {required bool overlapsContent}) {
    final SliverConstraints constraints = sliverConstraints;
    final double shrinkOffset = math.min(scrollOffset, _maxExtent);
    if (_needsChildUpdate ||
        shrinkOffset != _lastShrinkOffset ||
        overlapsContent != _lastOverlapsContent) {
      _needsChildUpdate = false;
      _lastShrinkOffset = shrinkOffset;
      _lastOverlapsContent = overlapsContent;
      childBuilder?.call(shrinkOffset, overlapsContent);
    }
    final RenderBox? child = this.child;
    if (child == null) {
      _childExtent = 0;
      return;
    }
    child.layout(
      constraints.asBoxConstraints(
        maxExtent: math.max(_minExtent, _maxExtent - shrinkOffset),
      ),
      parentUsesSize: true,
    );
    _childExtent = mainAxisExtentOf(child);
  }

  @override
  SliverGeometry performSliverLayout() {
    final SliverConstraints constraints = sliverConstraints;
    final double maxExtent = _maxExtent;
    final SliverGeometry geometry;
    double childPosition = 0;
    if (_floating) {
      final double? last = _lastActualScrollOffset;
      if (last != null &&
          (constraints.scrollOffset < last ||
              _effectiveScrollOffset < maxExtent)) {
        // Scrolling back towards the start reveals the header from wherever
        // it was hidden; scrolling on hides it again. The direction is read
        // off the change in offset, since nothing else here knows it.
        final double delta = last - constraints.scrollOffset;
        if (delta > 0 && _effectiveScrollOffset > maxExtent) {
          _effectiveScrollOffset = maxExtent;
        }
        _effectiveScrollOffset = (_effectiveScrollOffset - delta)
            .clamp(0.0, math.max(0.0, constraints.scrollOffset));
      } else {
        _effectiveScrollOffset = constraints.scrollOffset;
      }
      _layoutChild(
        _effectiveScrollOffset,
        overlapsContent: _effectiveScrollOffset < constraints.scrollOffset,
      );
      final double paintExtent = maxExtent - _effectiveScrollOffset;
      final double layoutExtent = maxExtent - constraints.scrollOffset;
      if (_pinned) {
        final double minAllowed =
            math.min(_minExtent, constraints.remainingPaintExtent);
        final double clampedPaint = paintExtent.clamp(
          minAllowed,
          math.max(minAllowed, constraints.remainingPaintExtent),
        );
        geometry = SliverGeometry(
          scrollExtent: maxExtent,
          paintOrigin: math.min(constraints.overlap, 0.0),
          paintExtent: clampedPaint,
          layoutExtent: layoutExtent.clamp(0.0, clampedPaint),
          maxPaintExtent: maxExtent,
          hasVisualOverflow: true,
        );
      } else {
        geometry = SliverGeometry(
          scrollExtent: maxExtent,
          paintOrigin: math.min(constraints.overlap, 0.0),
          paintExtent: paintExtent.clamp(0.0, constraints.remainingPaintExtent),
          layoutExtent:
              layoutExtent.clamp(0.0, constraints.remainingPaintExtent),
          maxPaintExtent: maxExtent,
          hasVisualOverflow: true,
        );
        childPosition = math.min(0.0, paintExtent - _childExtent);
      }
      _lastActualScrollOffset = constraints.scrollOffset;
    } else if (_pinned) {
      _layoutChild(
        constraints.scrollOffset,
        overlapsContent: constraints.overlap > 0,
      );
      final double effectiveRemaining =
          math.max(0.0, constraints.remainingPaintExtent - constraints.overlap);
      final double layoutExtent =
          (maxExtent - constraints.scrollOffset).clamp(0.0, effectiveRemaining);
      geometry = SliverGeometry(
        scrollExtent: maxExtent,
        // Below whatever an earlier pinned header still paints, so two
        // pinned headers stack instead of covering each other.
        paintOrigin: constraints.overlap,
        paintExtent: math.min(_childExtent, effectiveRemaining),
        layoutExtent: layoutExtent,
        maxPaintExtent: maxExtent,
        cacheExtent: layoutExtent > 0
            ? -constraints.cacheOrigin + layoutExtent
            : layoutExtent,
        hasVisualOverflow: true,
      );
    } else {
      _layoutChild(constraints.scrollOffset, overlapsContent: false);
      final double paintExtent = maxExtent - constraints.scrollOffset;
      geometry = SliverGeometry(
        scrollExtent: maxExtent,
        paintOrigin: math.min(constraints.overlap, 0.0),
        paintExtent: paintExtent.clamp(0.0, constraints.remainingPaintExtent),
        maxPaintExtent: maxExtent,
        hasVisualOverflow: true,
      );
      // Once the header is shorter than its minimum would allow, the child
      // keeps its minimum extent and slides out of the top instead.
      childPosition = math.min(0.0, paintExtent - _childExtent);
    }
    final RenderBox? child = this.child;
    if (child != null) {
      child.parentData!.offset = childBoxOffset(
        mainAxisPosition: childPosition,
        childMainAxisExtent: _childExtent,
        paintExtent: geometry.paintExtent,
      );
    }
    return geometry;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    // A header's child can be taller than what the sliver paints - a floating
    // one half revealed, a scrolling one sliding out - and must not paint over
    // the sliver before it, which is painted underneath.
    list.save();
    list.clipRect(
      offset.dx,
      offset.dy,
      offset.dx + size.width,
      offset.dy + size.height,
    );
    super.paint(list, offset);
    list.restore();
  }
}

// ---------------------------------------------------------------------------
// Lazy multi-child slivers
// ---------------------------------------------------------------------------

/// The widget layer's side of a lazy sliver: it knows how many children there
/// are and can make a range of them exist.
///
/// Implemented by the element, because building a child is element work, and
/// declared here because the render object is the one that knows *which*
/// range. A render object that held a widget builder would have reached into
/// the widget layer; one that holds this interface has not.
abstract interface class SliverChildManager {
  /// How many children the sliver has in total, realized or not.
  int get childCount;

  /// Makes exactly the children `first..last` (inclusive) exist, creating
  /// the missing ones and discarding every other. `last < first` means none.
  ///
  /// Called during layout. Each created child is handed to the render object
  /// through [RenderSliverMultiBoxAdaptor.insertChild] before this returns.
  void realizeChildren(int first, int last);
}

/// Per-child record of a lazy sliver: which index the child is, and where it
/// starts in the sliver's scroll space.
final class SliverMultiBoxAdaptorParentData extends BoxParentData {
  /// The child's index in the sliver's full list.
  int index = 0;

  /// The child's leading edge in the sliver's scroll space.
  double layoutOffset = 0;

  @override
  String toString() =>
      'SliverMultiBoxAdaptorParentData(index: $index, layoutOffset: '
      '$layoutOffset, offset: $offset)';
}

/// A sliver with many box children, of which only those in the cache region
/// exist.
///
/// Children are keyed by index, not by position in a list: the realized set
/// is always a contiguous window, but it slides, and keying by index is what
/// lets a scroll by one row add one child and drop one rather than shift all
/// of them.
abstract class RenderSliverMultiBoxAdaptor extends RenderBox with RenderSliver {
  RenderSliverMultiBoxAdaptor({required SliverChildManager childManager})
      : _childManager = childManager;

  SliverChildManager _childManager;
  final SplayTreeMap<int, RenderBox> _children = SplayTreeMap<int, RenderBox>();

  SliverChildManager get childManager => _childManager;

  set childManager(SliverChildManager value) {
    if (identical(value, _childManager)) return;
    _childManager = value;
    markNeedsLayout();
  }

  /// The realized children, in index order.
  Iterable<RenderBox> get realizedChildren => _children.values;

  /// The indices of the realized children, ascending.
  List<int> get realizedIndices => _children.keys.toList(growable: false);

  /// How many children exist right now - never more than the cache region
  /// reaches, whatever [SliverChildManager.childCount] is.
  int get realizedCount => _children.length;

  /// The realized child at [index], or null when that index is not built.
  RenderBox? childAtIndex(int index) => _children[index];

  /// The index [child] was inserted at.
  int indexOf(RenderBox child) =>
      (child.parentData! as SliverMultiBoxAdaptorParentData).index;

  /// Adopts [child] as the child at [index]. Called by the child manager.
  void insertChild(RenderBox child, int index) {
    final RenderBox? existing = _children[index];
    if (existing != null && !identical(existing, child)) {
      throw StateError(
        '$runtimeType already has a child at index $index; the child manager '
        'must remove it before inserting another.',
      );
    }
    if (identical(existing, child)) return;
    adoptChild(child);
    (child.parentData! as SliverMultiBoxAdaptorParentData).index = index;
    _children[index] = child;
  }

  /// Drops [child]. Called by the child manager.
  void removeChild(RenderBox child) {
    final int index = indexOf(child);
    if (!identical(_children[index], child)) {
      throw StateError('a ${child.runtimeType} is not a child of $runtimeType');
    }
    _children.remove(index);
    dropChild(child);
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! SliverMultiBoxAdaptorParentData) {
      child.parentData = SliverMultiBoxAdaptorParentData();
    }
  }

  @override
  void visitChildren(void Function(RenderBox child) visitor) {
    for (final RenderBox child in _children.values) {
      visitor(child);
    }
  }

  /// Asks the child manager for exactly `first..last`.
  @protected
  void realize(int first, int last) {
    if (last < first) {
      if (_children.isEmpty) return;
    } else if (_children.length == last - first + 1 &&
        _children.firstKey() == first &&
        _children.lastKey() == last) {
      // Already the window. The common case for every frame that scrolled by
      // less than a row, and it must not open a build scope.
      return;
    }
    _childManager.realizeChildren(first, last);
  }

  /// Positions [child], whose leading edge is at [layoutOffset] in this
  /// sliver's scroll space.
  @protected
  void placeChild(
    RenderBox child, {
    required double layoutOffset,
    required double paintExtent,
    double crossAxisPosition = 0,
  }) {
    final SliverMultiBoxAdaptorParentData data =
        child.parentData! as SliverMultiBoxAdaptorParentData;
    data.layoutOffset = layoutOffset;
    data.offset = childBoxOffset(
      mainAxisPosition: layoutOffset - sliverConstraints.scrollOffset,
      childMainAxisExtent: mainAxisExtentOf(child),
      paintExtent: paintExtent,
      crossAxisPosition: crossAxisPosition,
    );
  }

  bool _intersectsBox(RenderBox child) {
    final Offset at = child.offsetFromParent;
    final bool vertical = sliverConstraints.axis == ScrollAxis.vertical;
    final double start = vertical ? at.dy : at.dx;
    final double end =
        start + (vertical ? child.size.height : child.size.width);
    final double extent = vertical ? size.height : size.width;
    return end > 0 && start < extent;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    // The cache region's children are built and laid out but not painted:
    // they are outside this box, and the viewport would clip them anyway.
    for (final RenderBox child in _children.values) {
      if (_intersectsBox(child)) paintChild(list, child, offset);
    }
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    for (final RenderBox child in _children.values) {
      final Offset at = child.offsetFromParent;
      final RenderBox? hit = child.hitTest(
        Offset(position.dx - at.dx, position.dy - at.dy),
        path: path,
      );
      if (hit != null) return hit;
    }
    return null;
  }
}

/// A lazy list of boxes along the scroll axis.
///
/// With [itemExtent] set every child is exactly that long and positions are
/// arithmetic - the fixed-extent fast path. Without it each child is laid out
/// at its natural extent and measured, and the [ListVirtualization] that
/// remembers the measurements also estimates the children not measured yet at
/// [estimatedItemExtent], which is what gives a list of a hundred thousand
/// unmeasured rows a total length on the first frame.
///
/// ## Keeping the anchor still
///
/// Measuring a row that was only estimated moves every row after it. Rows
/// after what the user is reading moving is invisible, but rows *before* it
/// moving would shift the whole screen. So one row is the anchor - the first
/// row already on screen before this layout, see [_anchorFor] - and if its
/// scroll offset changed because rows before it were measured, the layout
/// stops and returns [SliverGeometry.scrollOffsetCorrection] by exactly that
/// much, the viewport moves its offset with it, and the anchor is drawn where
/// it was.
final class RenderSliverList extends RenderSliverMultiBoxAdaptor {
  RenderSliverList({
    required super.childManager,
    double? itemExtent,
    double estimatedItemExtent = 40,
  })  : _itemExtent = itemExtent,
        _estimatedItemExtent = estimatedItemExtent;

  /// The cap on measure-and-extend passes in one layout.
  ///
  /// Each pass realizes the window the current estimates predict and measures
  /// it; a pass that measures nothing new ends the loop, so a real list stops
  /// after one or two. The cap only matters for children that change size on
  /// every layout.
  static const int maxMeasurePasses = 32;

  double? _itemExtent;
  double _estimatedItemExtent;
  ListVirtualization? _plan;

  /// The extent of every child, or null for measured children.
  double? get itemExtent => _itemExtent;

  set itemExtent(double? value) {
    if (value == _itemExtent) return;
    _itemExtent = value;
    markNeedsLayout();
  }

  /// What a child not measured yet is assumed to be.
  double get estimatedItemExtent => _estimatedItemExtent;

  set estimatedItemExtent(double value) {
    if (value == _estimatedItemExtent) return;
    _estimatedItemExtent = value;
    markNeedsLayout();
  }

  /// The extents this list has measured or estimated, as of the last layout.
  ListVirtualization? get virtualization => _plan;

  ListVirtualization _planFor(int count) {
    final double? fixed = _itemExtent;
    final ListVirtualization? current = _plan;
    final double estimate = fixed ?? _estimatedItemExtent;
    if (current != null &&
        current.itemCount == count &&
        current.estimatedExtent == estimate &&
        current.hasVariableExtents == (fixed == null)) {
      return current;
    }
    if (fixed != null) {
      return _plan =
          ListVirtualization(itemCount: count, estimatedExtent: fixed);
    }
    // A list whose count changed keeps what it measured for the indices both
    // lists have. Forgetting it would make the scrollbar jump on every append
    // to a chat log.
    final List<double> extents = List<double>.filled(count, estimate);
    if (current != null &&
        current.hasVariableExtents &&
        current.estimatedExtent == estimate) {
      final int kept = math.min(count, current.itemCount);
      for (int i = 0; i < kept; i++) {
        extents[i] = current.extentOf(i);
      }
    }
    return _plan = ListVirtualization(
      itemCount: count,
      estimatedExtent: estimate,
      extents: extents,
    );
  }

  /// The row whose scroll offset this layout must not move.
  ///
  /// The first row that was already built and is still inside the window
  /// the estimates predict: it has been on screen, so it is what the user is
  /// looking at, and rows measured above it must not push it down the screen.
  /// The row at the leading edge would be the wrong choice - when the user
  /// scrolls up into estimated rows, *that* row is the newly built one, and
  /// it is the rows below it, the ones already seen, that would jump. With no
  /// such row - a jump far away, or the first layout - there is nothing on
  /// screen to keep still, and the leading row is used.
  int _anchorFor(ListVirtualization plan, double start, double end) {
    final int leading = plan.indexAt(sliverConstraints.scrollOffset);
    if (_children.isEmpty || end <= start || start >= plan.totalExtent) {
      return leading;
    }
    final int first = plan.indexAt(start);
    final int last = _lastIndexBefore(plan, first, end);
    for (final int index in _children.keys) {
      if (index >= first && index <= last) return index;
    }
    return leading;
  }

  /// The last index whose leading edge is before [end].
  static int _lastIndexBefore(ListVirtualization plan, int first, double end) {
    int index = plan.indexAt(end);
    if (index > first && plan.offsetOf(index) >= end) index--;
    return index;
  }

  @override
  SliverGeometry performSliverLayout() {
    final SliverConstraints constraints = sliverConstraints;
    final int count = _childManager.childCount;
    final ListVirtualization plan = _planFor(count);
    final double? fixed = _itemExtent;
    final double start =
        math.max(0.0, constraints.scrollOffset + constraints.cacheOrigin);
    final double end = constraints.scrollOffset +
        constraints.cacheOrigin +
        constraints.remainingCacheExtent;
    final BoxConstraints childConstraints = constraints.asBoxConstraints(
      minExtent: fixed ?? 0,
      maxExtent: fixed ?? double.infinity,
    );
    if (count == 0) {
      realize(0, -1);
      return SliverGeometry.zero;
    }
    final int anchor = _anchorFor(plan, start, end);
    final double anchorOffset = plan.offsetOf(anchor);

    for (int pass = 0; pass < maxMeasurePasses; pass++) {
      if (end <= start || start >= plan.totalExtent) {
        realize(0, -1);
        break;
      }
      final int first = plan.indexAt(start);
      final int last = _lastIndexBefore(plan, first, end);
      realize(first, last);
      bool remeasured = false;
      for (final MapEntry<int, RenderBox> entry in _children.entries) {
        entry.value.layout(childConstraints, parentUsesSize: true);
        if (fixed == null &&
            plan.setExtent(entry.key, mainAxisExtentOf(entry.value))) {
          remeasured = true;
        }
      }
      if (!remeasured) break;
      final double moved = plan.offsetOf(anchor) - anchorOffset;
      if (moved != 0 && constraints.scrollOffset > 0) {
        return SliverGeometry(scrollOffsetCorrection: moved);
      }
    }

    final double total = plan.totalExtent;
    final double paintExtent = calculatePaintOffset(from: 0, to: total);
    for (final MapEntry<int, RenderBox> entry in _children.entries) {
      placeChild(
        entry.value,
        layoutOffset: plan.offsetOf(entry.key),
        paintExtent: paintExtent,
      );
    }
    return SliverGeometry(
      scrollExtent: total,
      paintExtent: paintExtent,
      cacheExtent: calculateCacheOffset(from: 0, to: total),
      maxPaintExtent: total,
      hasVisualOverflow:
          total > constraints.scrollOffset + constraints.remainingPaintExtent ||
              constraints.scrollOffset > 0,
    );
  }
}

/// Where the cells of a regular grid go.
///
/// Every cell is [childMainAxisExtent] by [childCrossAxisExtent], rows are
/// [mainAxisStride] apart and columns [crossAxisStride], so every question a
/// lazy grid asks - which indices does this offset reach, where is cell `i`,
/// how long is the whole grid - is arithmetic with no per-cell state.
final class SliverGridLayout {
  const SliverGridLayout({
    required this.crossAxisCount,
    required this.mainAxisStride,
    required this.crossAxisStride,
    required this.childMainAxisExtent,
    required this.childCrossAxisExtent,
    this.reverseCrossAxis = false,
  })  : assert(crossAxisCount > 0, 'a grid needs at least one column'),
        assert(mainAxisStride >= 0 && crossAxisStride >= 0);

  final int crossAxisCount;
  final double mainAxisStride;
  final double crossAxisStride;
  final double childMainAxisExtent;
  final double childCrossAxisExtent;

  /// Whether columns are counted from the trailing cross edge - right to left
  /// in a vertical grid.
  final bool reverseCrossAxis;

  /// The first index whose row reaches [scrollOffset].
  int minChildIndexForScrollOffset(double scrollOffset) => mainAxisStride > 0
      ? crossAxisCount * (scrollOffset ~/ mainAxisStride)
      : 0;

  /// The last index whose row starts before [scrollOffset].
  int maxChildIndexForScrollOffset(double scrollOffset) {
    if (mainAxisStride <= 0) return 0;
    final int rows = (scrollOffset / mainAxisStride).ceil();
    return math.max(0, crossAxisCount * rows - 1);
  }

  /// The leading edge of the row that holds [index].
  double mainAxisOffsetOf(int index) =>
      (index ~/ crossAxisCount) * mainAxisStride;

  /// The cross-axis offset of the column that holds [index], in a cross
  /// extent of [crossAxisExtent].
  double crossAxisOffsetOf(int index, double crossAxisExtent) {
    final double offset = (index % crossAxisCount) * crossAxisStride;
    return reverseCrossAxis
        ? crossAxisExtent - offset - childCrossAxisExtent
        : offset;
  }

  /// The scroll extent of a grid of [childCount] cells: every row's stride
  /// except the last row's trailing spacing.
  double computeMaxScrollOffset(int childCount) {
    if (childCount <= 0) return 0;
    final int rows = (childCount - 1) ~/ crossAxisCount + 1;
    final double spacing = mainAxisStride - childMainAxisExtent;
    return math.max(0.0, rows * mainAxisStride - spacing);
  }
}

/// Decides a grid's [SliverGridLayout] from the constraints it is given.
abstract class SliverGridDelegate {
  const SliverGridDelegate();

  SliverGridLayout getLayout(SliverConstraints constraints);

  /// Whether a new delegate would lay the grid out differently.
  bool shouldRelayout(covariant SliverGridDelegate oldDelegate) => true;
}

/// A fixed number of columns, dividing the cross axis equally.
final class SliverGridDelegateWithFixedCrossAxisCount
    extends SliverGridDelegate {
  const SliverGridDelegateWithFixedCrossAxisCount({
    required this.crossAxisCount,
    this.mainAxisSpacing = 0,
    this.crossAxisSpacing = 0,
    this.childAspectRatio = 1,
    this.mainAxisExtent,
  })  : assert(crossAxisCount > 0, 'a grid needs at least one column'),
        assert(childAspectRatio > 0);

  final int crossAxisCount;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// Cross extent over main extent of each cell, when [mainAxisExtent] is
  /// null.
  final double childAspectRatio;

  /// A fixed main-axis extent for every cell, overriding [childAspectRatio].
  final double? mainAxisExtent;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final double usable = math.max(
      0.0,
      constraints.crossAxisExtent - crossAxisSpacing * (crossAxisCount - 1),
    );
    final double childCross = usable / crossAxisCount;
    final double childMain = mainAxisExtent ?? childCross / childAspectRatio;
    return SliverGridLayout(
      crossAxisCount: crossAxisCount,
      mainAxisStride: childMain + mainAxisSpacing,
      crossAxisStride: childCross + crossAxisSpacing,
      childMainAxisExtent: childMain,
      childCrossAxisExtent: childCross,
    );
  }

  @override
  bool shouldRelayout(SliverGridDelegateWithFixedCrossAxisCount oldDelegate) =>
      oldDelegate.crossAxisCount != crossAxisCount ||
      oldDelegate.mainAxisSpacing != mainAxisSpacing ||
      oldDelegate.crossAxisSpacing != crossAxisSpacing ||
      oldDelegate.childAspectRatio != childAspectRatio ||
      oldDelegate.mainAxisExtent != mainAxisExtent;
}

/// As many columns as fit with none wider than [maxCrossAxisExtent].
///
/// The column count is rounded *up*, so the columns are as wide as possible
/// without exceeding the maximum - a 500-pixel grid with a 150-pixel maximum
/// gets four columns of 125, not three of 150 and a gap.
final class SliverGridDelegateWithMaxCrossAxisExtent
    extends SliverGridDelegate {
  const SliverGridDelegateWithMaxCrossAxisExtent({
    required this.maxCrossAxisExtent,
    this.mainAxisSpacing = 0,
    this.crossAxisSpacing = 0,
    this.childAspectRatio = 1,
    this.mainAxisExtent,
  })  : assert(maxCrossAxisExtent > 0),
        assert(childAspectRatio > 0);

  final double maxCrossAxisExtent;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final double childAspectRatio;
  final double? mainAxisExtent;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final int count = math.max(
      1,
      (constraints.crossAxisExtent / (maxCrossAxisExtent + crossAxisSpacing))
          .ceil(),
    );
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: count,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
      childAspectRatio: childAspectRatio,
      mainAxisExtent: mainAxisExtent,
    ).getLayout(constraints);
  }

  @override
  bool shouldRelayout(SliverGridDelegateWithMaxCrossAxisExtent oldDelegate) =>
      oldDelegate.maxCrossAxisExtent != maxCrossAxisExtent ||
      oldDelegate.mainAxisSpacing != mainAxisSpacing ||
      oldDelegate.crossAxisSpacing != crossAxisSpacing ||
      oldDelegate.childAspectRatio != childAspectRatio ||
      oldDelegate.mainAxisExtent != mainAxisExtent;
}

/// A lazy grid of equal cells.
///
/// Unlike `GridView.builder`, which is a list of rows, the cells here are the
/// children: a cell is built, kept and discarded on its own, and the column
/// count may change with the width without rebuilding a row widget per row.
final class RenderSliverGrid extends RenderSliverMultiBoxAdaptor {
  RenderSliverGrid({
    required super.childManager,
    required SliverGridDelegate gridDelegate,
  }) : _gridDelegate = gridDelegate;

  SliverGridDelegate _gridDelegate;
  SliverGridLayout? _layout;

  SliverGridDelegate get gridDelegate => _gridDelegate;

  set gridDelegate(SliverGridDelegate value) {
    if (identical(value, _gridDelegate)) return;
    final bool relayout = value.runtimeType != _gridDelegate.runtimeType ||
        value.shouldRelayout(_gridDelegate);
    _gridDelegate = value;
    if (relayout) markNeedsLayout();
  }

  /// The layout of the last pass.
  SliverGridLayout? get gridLayout => _layout;

  @override
  SliverGeometry performSliverLayout() {
    final SliverConstraints constraints = sliverConstraints;
    final SliverGridLayout layout =
        _layout = _gridDelegate.getLayout(constraints);
    final int count = _childManager.childCount;
    final double total = layout.computeMaxScrollOffset(count);
    final double start =
        math.max(0.0, constraints.scrollOffset + constraints.cacheOrigin);
    final double end = constraints.scrollOffset +
        constraints.cacheOrigin +
        constraints.remainingCacheExtent;
    if (count == 0 || end <= start || start >= total) {
      realize(0, -1);
    } else {
      final int first =
          math.min(count - 1, layout.minChildIndexForScrollOffset(start));
      final int last =
          math.min(count - 1, layout.maxChildIndexForScrollOffset(end));
      realize(first, last);
    }
    final BoxConstraints cell = constraints.asBoxConstraints(
      minExtent: layout.childMainAxisExtent,
      maxExtent: layout.childMainAxisExtent,
      crossAxisExtent: layout.childCrossAxisExtent,
    );
    final double paintExtent = calculatePaintOffset(from: 0, to: total);
    for (final MapEntry<int, RenderBox> entry in _children.entries) {
      entry.value.layout(cell, parentUsesSize: true);
      placeChild(
        entry.value,
        layoutOffset: layout.mainAxisOffsetOf(entry.key),
        paintExtent: paintExtent,
        crossAxisPosition: layout.crossAxisOffsetOf(
          entry.key,
          constraints.crossAxisExtent,
        ),
      );
    }
    return SliverGeometry(
      scrollExtent: total,
      paintExtent: paintExtent,
      cacheExtent: calculateCacheOffset(from: 0, to: total),
      maxPaintExtent: total,
      hasVisualOverflow:
          total > constraints.scrollOffset + constraints.remainingPaintExtent ||
              constraints.scrollOffset > 0,
    );
  }
}
