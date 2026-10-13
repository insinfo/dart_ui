// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/widgets/page_view.dart):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// `PageView`, `PageController` and `PageScrollPhysics`, as in Flutter.
///
/// A page view is a [CustomScrollView] whose one sliver is a fixed-extent
/// list of pages, each `viewportFraction` of the viewport long, padded so the
/// current page sits in the middle. What makes it a *page* view is where the
/// scroll comes to rest:
///
///  * a drag released between pages springs to the nearest one, or to the
///    next in the direction of a fling ([PageScrollPhysics]);
///  * a wheel notch turns one page, and notches that arrive while a page is
///    still turning add up rather than being lost;
///  * with focus, the arrow keys along the axis and Page Up/Page Down turn
///    one page, Home and End go to the first and the last.
///
/// [PageView.onPageChanged] is driven by the view's own scroll
/// notifications, as in Flutter: it fires when the page nearest the middle
/// changes, during the scroll and not only at its end.
///
/// Differences from Flutter: `itemCount` null means "practically endless"
/// (a very large count) rather than unbounded, and a builder that returns
/// null leaves an empty page instead of ending the view; there is no
/// `PageStorage`, so `keepPage` keeps the page only across a change of
/// axis; the wheel turns pages (Flutter scrolls by the wheel's delta and
/// springs back to the nearest page, which makes a mouse wheel useless);
/// `PageMetrics` and `findChildIndexCallback` are not here.
library;

import 'dart:math' as math;

import '../animation/curves.dart';
import '../animation/simulation.dart';
import '../geometry/offset.dart';
import '../gestures/binding.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/pipeline.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart' show Axis;
import '../layout/render_proxy_box.dart';
import '../layout/render_viewport.dart';
import '../layout/scroll_metrics.dart';
import '../platform/input_events.dart';
import '../scheduler/ui_dispatcher.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'keyboard_router.dart';
import 'layout_builder.dart';
import 'notification_listener.dart';
import 'pointer_router.dart';
import 'scroll_controller.dart';
import 'scroll_notification.dart';
import 'scroll_physics.dart';
import 'scroll_view.dart';
import 'scrollbar.dart';
import 'slivers.dart';
import 'widget.dart';

/// How long a page turns for when the wheel or a key turns it.
const Duration _kPageTurnDuration = Duration(milliseconds: 300);

/// The curve a page turns along when the wheel or a key turns it.
const Curve _kPageTurnCurve = Curves.easeOut;

/// The page count of a `PageView.builder` with no `itemCount`.
const int _kEndlessPageCount = 1 << 31;

/// The `viewportFraction` of the [PageController] each position belongs to,
/// for [PageScrollPhysics]. A position is a layout object and cannot carry
/// it; Flutter has a `_PagePosition` subclass for the same purpose.
final Expando<double> _pageFractions = Expando<double>('page fraction');

/// The extent of one page of [metrics], in pixels.
double _pageExtentOf(ScrollMetrics metrics) {
  final double fraction =
      metrics is ScrollPosition ? _pageFractions[metrics] ?? 1.0 : 1.0;
  return metrics.viewportDimension * fraction;
}

/// Controls a [PageView]: which page it shows, and turning to another.
///
/// ```dart
/// final PageController pages = PageController(viewportFraction: 0.8);
/// PageView(controller: pages, children: slides);
/// pages.nextPage(duration: Duration(milliseconds: 300), curve: Curves.ease);
/// ```
class PageController extends ScrollController {
  PageController({
    this.initialPage = 0,
    this.keepPage = true,
    this.viewportFraction = 1.0,
    super.onAttach,
    super.onDetach,
  }) {
    if (!(viewportFraction > 0.0) || !viewportFraction.isFinite) {
      throw ArgumentError.value(
        viewportFraction,
        'viewportFraction',
        'must be a positive, finite fraction of the viewport',
      );
    }
    if (initialPage < 0) {
      throw ArgumentError.value(initialPage, 'initialPage', 'is negative');
    }
  }

  /// The page shown first.
  final int initialPage;

  /// Whether a view that recreates its position (a change of axis) keeps the
  /// page it was on. There is no `PageStorage` to keep it across a view that
  /// is rebuilt from scratch.
  final bool keepPage;

  /// How much of the viewport one page takes: 1.0 fills it, 0.8 lets the
  /// neighbours show at the edges.
  final double viewportFraction;

  final Map<ScrollPosition, _PageKeeper> _keepers =
      <ScrollPosition, _PageKeeper>{};

  /// The page shown, as a fraction while it is turning; [initialPage] before
  /// the view has been laid out. Requires exactly one attached view.
  double? get page {
    final ScrollPosition position = this.position;
    return _keepers[position]?.page ?? initialPage.toDouble();
  }

  /// Turns to [page], animating along [curve] for [duration].
  Future<void> animateToPage(
    int page, {
    required Duration duration,
    required Curve curve,
  }) {
    final ScrollPosition position = this.position;
    final _PageKeeper? keeper = _keepers[position];
    if (keeper == null || !keeper.laidOut) {
      keeper?.pendingPage = page.toDouble();
      return Future<void>.value();
    }
    return position.animateTo(
      keeper.pixelsFor(page.toDouble()),
      duration: duration,
      curve: curve,
    );
  }

  /// Shows [page] at once.
  void jumpToPage(int page) {
    final ScrollPosition position = this.position;
    final _PageKeeper? keeper = _keepers[position];
    if (keeper == null || !keeper.laidOut) {
      keeper?.pendingPage = page.toDouble();
      return;
    }
    position.jumpTo(keeper.pixelsFor(page.toDouble()));
  }

  /// Turns to the next page.
  Future<void> nextPage({required Duration duration, required Curve curve}) =>
      animateToPage(page!.round() + 1, duration: duration, curve: curve);

  /// Turns to the previous page.
  Future<void> previousPage({
    required Duration duration,
    required Curve curve,
  }) =>
      animateToPage(page!.round() - 1, duration: duration, curve: curve);

  @override
  ScrollPosition createScrollPosition(
    ScrollAxis axis,
    ScrollPosition? oldPosition,
  ) {
    final ScrollPosition position = ScrollPosition(axis: axis);
    final double? oldPage =
        oldPosition == null ? null : _keepers[oldPosition]?.page;
    _keepers[position] = _PageKeeper(
      position: position,
      viewportFraction: viewportFraction,
      pendingPage: keepPage && oldPage != null
          ? oldPage.roundToDouble()
          : initialPage.toDouble(),
    );
    _pageFractions[position] = viewportFraction;
    return position;
  }

  @override
  void attach(ScrollPosition position) {
    _keepers[position] ??= _PageKeeper(
      position: position,
      viewportFraction: viewportFraction,
      pendingPage: initialPage.toDouble(),
    );
    _pageFractions[position] = viewportFraction;
    position.addListener(_keepers[position]!.onChanged);
    super.attach(position);
  }

  @override
  void detach(ScrollPosition position) {
    final _PageKeeper? keeper = _keepers.remove(position);
    if (keeper != null) position.removeListener(keeper.onChanged);
    super.detach(position);
  }

  @override
  void dispose() {
    for (final MapEntry<ScrollPosition, _PageKeeper> entry
        in _keepers.entries) {
      entry.key.removeListener(entry.value.onChanged);
    }
    _keepers.clear();
    super.dispose();
  }
}

/// Keeps a page view's position on a page across the first layout and every
/// resize: the offset of page 2 depends on the viewport, so a view that
/// grows must move its offset to stay on page 2.
final class _PageKeeper {
  _PageKeeper({
    required this.position,
    required this.viewportFraction,
    required this.pendingPage,
  });

  final ScrollPosition position;
  final double viewportFraction;

  /// The page to show once the viewport is known.
  double pendingPage;

  double? _viewport;
  double _page = 0;

  bool get laidOut => _viewport != null;

  double get _pageExtent => (_viewport ?? 0) * viewportFraction;

  /// The page shown, or the one that will be once laid out.
  double get page => laidOut ? _page : pendingPage;

  double pixelsFor(double page) => page * _pageExtent;

  /// The page view is about to be laid out in a viewport [viewport] long.
  /// Moving the offset now, before the pages are laid out, means page 0 is
  /// never built for a view that opens on page 1000, and a resize lands on
  /// the same page without a frame on the wrong one.
  void prepare(double viewport) {
    if (viewport <= 0 || !viewport.isFinite || viewport == _viewport) return;
    final double page = laidOut ? _page : pendingPage;
    _viewport = viewport;
    final double target = page * _pageExtent;
    if (target != position.pixels) {
      // During layout, and not a scroll: no notification, and the geometry
      // the viewport reports next clamps a page past the last one.
      position.correctBy(target - position.pixels);
    }
    _page = page;
  }

  void onChanged() {
    if (!position.hasViewportDimension) return;
    final double viewport = position.viewportDimension;
    if (viewport <= 0 || !viewport.isFinite) return;
    if (viewport != _viewport) {
      // A view laid out without [prepare]: correct after the fact. The
      // sliver viewport lays itself out again at the corrected offset.
      final double page = laidOut ? _page : pendingPage;
      _viewport = viewport;
      final double target = page * _pageExtent;
      if (target != position.pixels) {
        position.correctBy(target - position.pixels);
        return;
      }
    }
    final double extent = _pageExtent;
    if (extent > 0) _page = position.pixels / extent;
  }
}

/// Makes a scroll view come to rest on whole pages.
///
/// Its ballistic simulation is a spring from where the drag was released to
/// the page nearest to it - or the next one in the direction of a fling.
/// A page is the viewport, or `viewportFraction` of it for a view driven by
/// a [PageController].
class PageScrollPhysics extends ScrollPhysics {
  const PageScrollPhysics({super.parent});

  @override
  PageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      PageScrollPhysics(parent: buildParent(ancestor));

  double _getPage(ScrollMetrics position) {
    final double extent = _pageExtentOf(position);
    return extent <= 0 ? 0 : position.pixels / extent;
  }

  double _getTargetPixels(
    ScrollMetrics position,
    Tolerance tolerance,
    double velocity,
  ) {
    double page = _getPage(position);
    if (velocity < -tolerance.velocity) {
      page -= 0.5;
    } else if (velocity > tolerance.velocity) {
      page += 0.5;
    }
    return (page.roundToDouble() * _pageExtentOf(position))
        .clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // At an edge, moving outwards: the parent's job (a bounce, or nothing).
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final Tolerance tolerance = toleranceFor(position);
    final double target = _getTargetPixels(position, tolerance, velocity);
    if (target != position.pixels) {
      return SpringSimulation(
        spring: spring,
        start: position.pixels,
        end: target,
        velocity: velocity,
        tolerance: tolerance,
      );
    }
    return null;
  }

  @override
  bool get allowImplicitScrolling => false;
}

/// A scrollable list of pages, each the size of the viewport (or
/// [PageController.viewportFraction] of it), that comes to rest on whole
/// pages.
///
/// ```dart
/// PageView(
///   onPageChanged: (int page) => setState(() => current = page),
///   children: const <Widget>[Intro(), Features(), GetStarted()],
/// )
/// ```
///
/// See the library documentation for the input it answers and how it
/// differs from Flutter's.
class PageView extends StatefulWidget {
  /// A page view of [children].
  PageView({
    super.key,
    this.scrollDirection = Axis.horizontal,
    this.reverse = false,
    this.controller,
    this.physics,
    this.pageSnapping = true,
    this.onPageChanged,
    List<Widget> children = const <Widget>[],
    this.allowImplicitScrolling = false,
    this.padEnds = true,
    this.focusable = true,
    this.dispatcher,
  })  : itemCount = children.length,
        itemBuilder = ((BuildContext context, int index) => children[index]);

  /// A page view whose pages are built on demand: only the visible ones
  /// (and, with [allowImplicitScrolling], one on either side) exist.
  const PageView.builder({
    super.key,
    this.scrollDirection = Axis.horizontal,
    this.reverse = false,
    this.controller,
    this.physics,
    this.pageSnapping = true,
    this.onPageChanged,
    required this.itemBuilder,
    this.itemCount,
    this.allowImplicitScrolling = false,
    this.padEnds = true,
    this.focusable = true,
    this.dispatcher,
  });

  /// The axis the pages are laid out along. Horizontal by default.
  final Axis scrollDirection;

  /// Whether the first page is at the right (or bottom).
  final bool reverse;

  /// Which page is shown, and the [PageController.viewportFraction]. One is
  /// created when this is null.
  final PageController? controller;

  /// How the view answers a drag; with [pageSnapping] it is wrapped in a
  /// [PageScrollPhysics].
  final ScrollPhysics? physics;

  /// Whether the view comes to rest on whole pages. False makes it an
  /// ordinary horizontal list of page-sized items.
  final bool pageSnapping;

  /// Called with the page nearest the middle of the viewport whenever it
  /// changes.
  final void Function(int index)? onPageChanged;

  /// Builds the page at an index. Called only for pages being shown.
  final Widget? Function(BuildContext context, int index) itemBuilder;

  /// How many pages there are. Null is a practically endless view.
  final int? itemCount;

  /// Whether the pages either side of the visible one are built too, so
  /// they are ready the moment a turn begins.
  final bool allowImplicitScrolling;

  /// Whether the first and last pages may sit in the middle of the
  /// viewport when [PageController.viewportFraction] is below 1.
  final bool padEnds;

  /// Whether the view can take keyboard focus to turn pages by key.
  final bool focusable;

  /// Where the turning animations and the drag's spring run. Falls back to
  /// `GestureScope`; with neither, pages are turned at once.
  final UiDispatcher? dispatcher;

  @override
  State<PageView> createState() => _PageViewState();
}

final class _PageViewState extends State<PageView> {
  final ScrollPositionAttachment _attachment = ScrollPositionAttachment();
  final FocusNode _focusNode = FocusNode(debugLabel: 'PageView');
  PageController? _ownController;
  late int _lastReportedPage = _controller.initialPage;

  /// Where a turn by the wheel or a key is heading, so that the next one
  /// counts from there rather than from the page still turning.
  int? _turnTarget;

  PageController get _controller =>
      widget.controller ?? (_ownController ??= PageController());

  ScrollPosition get _position => _attachment.position;

  int get _pageCount => widget.itemCount ?? _kEndlessPageCount;

  @override
  void didUpdateWidget(PageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != null && _ownController != null) {
      // The view switches to its caller's controller; the attachment moves
      // the position over in build, and the one made here goes after it.
      final PageController own = _ownController!;
      _ownController = null;
      _attachment.update(widget.controller, widget.scrollDirection);
      own.dispose();
    }
  }

  @override
  void dispose() {
    _attachment.dispose();
    _ownController?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  ScrollPhysics? get _physics => widget.pageSnapping
      ? const PageScrollPhysics().applyTo(widget.physics)
      : widget.physics;

  double get _currentPage {
    final double extent = _pageExtentOf(_position);
    return extent <= 0 ? 0 : _position.pixels / extent;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final void Function(int)? onPageChanged = widget.onPageChanged;
    if (onPageChanged != null &&
        notification.depth == 0 &&
        notification is ScrollUpdateNotification) {
      final ScrollMetrics metrics = notification.metrics;
      final double extent =
          metrics.viewportDimension * _controller.viewportFraction;
      if (extent > 0) {
        final int page = (metrics.pixels / extent).round();
        if (page != _lastReportedPage) {
          _lastReportedPage = page;
          onPageChanged(page);
        }
      }
    }
    return false;
  }

  /// Turns to [page], clamped to the pages there are. Returns false when
  /// there is nowhere to go.
  bool _turnTo(int page) {
    final int target = page.clamp(0, _pageCount - 1);
    final double extent = _pageExtentOf(_position);
    if (extent <= 0) return false;
    final double pixels =
        (target * extent).clamp(0.0, _position.maxScrollExtent);
    if (pixels == _position.pixels && _turnTarget == null) return false;
    if (target == _turnTarget) return false;
    _turnTarget = target;
    _position
        .animateTo(
      pixels,
      duration: _kPageTurnDuration,
      curve: _kPageTurnCurve,
    )
        .whenComplete(() {
      if (_turnTarget == target) _turnTarget = null;
    });
    return true;
  }

  /// The page a turn by [pages] starts from: the one a turn in progress is
  /// heading to, or the nearest one.
  int get _turnOrigin => _turnTarget ?? _currentPage.round();

  bool get _userMayScroll =>
      Scrollable.resolvePhysics(_physics)?.shouldAcceptUserOffset(_position) ??
      true;

  /// Whether a wheel notch of [delta] (along the axis, unreversed) has a page
  /// to turn to - otherwise the notch is left to the view around this one.
  bool _wheelCanTurn(double delta) {
    if (!widget.pageSnapping || delta == 0 || !_userMayScroll) return false;
    final int step = (widget.reverse ? -delta : delta) > 0 ? 1 : -1;
    final int target = _turnOrigin + step;
    return target >= 0 && target < _pageCount;
  }

  void _onWheel(double delta) {
    final int step = (widget.reverse ? -delta : delta) > 0 ? 1 : -1;
    _turnTo(_turnOrigin + step);
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !_userMayScroll) return false;
    final bool vertical = widget.scrollDirection == Axis.vertical;
    final int key = event.logicalKey;
    // Physical arrows: the one pointing at the next page on screen. In a
    // reversed view the next page is to the left (or above).
    final int towardsEnd = vertical
        ? (widget.reverse ? logicalKeyArrowUp : logicalKeyArrowDown)
        : (widget.reverse ? logicalKeyArrowLeft : logicalKeyArrowRight);
    final int towardsStart = vertical
        ? (widget.reverse ? logicalKeyArrowDown : logicalKeyArrowUp)
        : (widget.reverse ? logicalKeyArrowRight : logicalKeyArrowLeft);
    if (key == towardsEnd || key == logicalKeyPageDown) {
      return _turnTo(_turnOrigin + 1);
    }
    if (key == towardsStart || key == logicalKeyPageUp) {
      return _turnTo(_turnOrigin - 1);
    }
    if (key == logicalKeyHome) return _turnTo(0);
    if (key == logicalKeyEnd) return _turnTo(_pageCount - 1);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final ScrollPosition position =
        _attachment.update(_controller, widget.scrollDirection);
    _focusNode.canRequestFocus = widget.focusable;
    final bool vertical = widget.scrollDirection == Axis.vertical;
    final double fraction = _controller.viewportFraction;
    final ScrollPhysics? physics = _physics;
    final int count = _pageCount;
    return FocusAttachment(
      node: _focusNode,
      child: _PageViewInput(
        focusNode: _focusNode,
        vertical: vertical,
        wheelCanTurn: _wheelCanTurn,
        onWheel: _onWheel,
        onKey: _onKey,
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double viewport =
                  vertical ? constraints.maxHeight : constraints.maxWidth;
              if (!viewport.isFinite) {
                throw StateError(
                  'A PageView needs a bounded '
                  '${vertical ? 'height' : 'width'}: its pages are a fraction '
                  'of the viewport, and an unbounded viewport has none. Give '
                  'it a size, or put it in an Expanded.',
                );
              }
              _controller._keepers[position]?.prepare(viewport);
              final double pageExtent = viewport * fraction;
              final double pad = widget.padEnds
                  ? math.max(0.0, (viewport - pageExtent) / 2)
                  : 0;
              Widget pages = SliverFixedExtentList(
                itemExtent: pageExtent,
                delegate: SliverChildBuilderDelegate(
                  widget.itemBuilder,
                  childCount: count,
                ),
              );
              if (pad > 0) {
                pages = SliverPadding(
                  padding: vertical
                      ? EdgeInsets.only(top: pad, bottom: pad)
                      : EdgeInsets.only(left: pad, right: pad),
                  sliver: pages,
                );
              }
              return CustomScrollView(
                controller: position,
                axis: widget.scrollDirection,
                reverse: widget.reverse,
                physics: physics,
                cacheExtent: widget.allowImplicitScrolling ? viewport : 0.0,
                scrollbar: ScrollbarVisibility.never,
                focusable: false,
                wheelEnabled: !widget.pageSnapping,
                dispatcher: widget.dispatcher,
                slivers: <Widget>[pages],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Focus on click, page turns by key, and the wheel, for a [PageView].
final class _PageViewInput extends SingleChildRenderObjectWidget {
  const _PageViewInput({
    required this.focusNode,
    required this.vertical,
    required this.wheelCanTurn,
    required this.onWheel,
    required this.onKey,
    required Widget super.child,
  });

  final FocusNode focusNode;
  final bool vertical;
  final bool Function(double delta) wheelCanTurn;
  final void Function(double delta) onWheel;
  final bool Function(KeyEvent event) onKey;

  @override
  _RenderPageViewInput createRenderObject(BuildContext context) =>
      _RenderPageViewInput()
        ..focusNode = focusNode
        ..vertical = vertical
        ..wheelCanTurn = wheelCanTurn
        ..onWheel = onWheel
        ..onKey = onKey;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPageViewInput renderObject,
  ) {
    renderObject
      ..focusNode = focusNode
      ..vertical = vertical
      ..wheelCanTurn = wheelCanTurn
      ..onWheel = onWheel
      ..onKey = onKey;
  }
}

final class _RenderPageViewInput extends RenderProxyBox
    implements PointerEventTarget, KeyboardEventTarget {
  FocusNode? _focusNode;
  bool vertical = false;
  bool Function(double delta) wheelCanTurn = _never;
  void Function(double delta) onWheel = _ignore;
  bool Function(KeyEvent event) onKey = _declined;

  static bool _never(double delta) => false;
  static void _ignore(double delta) {}
  static bool _declined(KeyEvent event) => false;

  set focusNode(FocusNode value) {
    if (identical(value, _focusNode)) return;
    final FocusNode? previous = _focusNode;
    if (previous != null && identical(previous.target, this)) {
      previous.target = null;
    }
    _focusNode = value;
    value.target = this;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerScrollEvent) {
      final double delta =
          vertical ? event.scrollDelta.dy : event.scrollDelta.dx;
      if (!wheelCanTurn(delta)) return;
      final GestureBinding? binding = GestureBinding.current;
      if (binding == null) {
        onWheel(delta);
        return;
      }
      binding.signalResolver.register(
        event,
        (PointerScrollEvent event) => onWheel(delta),
      );
      return;
    }
    if (event is! PointerDownEvent || event.button != PointerButton.primary) {
      return;
    }
    final FocusNode? node = _focusNode;
    if (node == null || !node.canRequestFocus) return;
    // A press that already focused something inside the page keeps it.
    final Object? focused = node.manager?.primaryFocus?.target;
    if (focused is RenderBox && _contains(focused)) return;
    node.requestFocus(FocusChangeReason.pointer);
  }

  bool _contains(RenderBox node) {
    for (RenderBox? at = node; at != null; at = at.parent) {
      if (identical(at, this)) return true;
    }
    return false;
  }

  @override
  bool handleKeyEvent(KeyEvent event) => onKey(event);

  @override
  void detach() {
    final FocusNode? node = _focusNode;
    if (node != null && identical(node.target, this)) node.target = null;
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _focusNode?.target = this;
  }
}
