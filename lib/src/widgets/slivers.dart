/// `CustomScrollView` and the `Sliver*` widgets.
///
/// `ListView` builds only its window, but it is one list: it cannot have a
/// header that stays put while the list under it moves, a grid followed by a
/// list in the same scroll, or a footer that sits at the bottom of a short
/// page. Those are compositions of differently-behaved pieces in one scroll,
/// and the pieces are slivers - see `layout/render_sliver.dart` for the
/// protocol and why a sliver here is a box with a second contract.
///
/// ## Building during layout, and why it has to
///
/// `ListView` decides its window during build, from the scroll offset and an
/// estimate, and rebuilds when the offset changes. That cannot work for a
/// sliver list: where the list *starts* in the scroll depends on the slivers
/// before it - a header that has shrunk, a box whose height is whatever its
/// text wraps to - and none of that is known until those slivers have been
/// laid out. So [SliverList] and [SliverGrid] build their children from inside
/// layout. Their render object asks for a range of indices; the
/// [SliverMultiBoxAdaptorElement] creates the missing ones and drops the rest
/// inside `BuildOwner.buildDuringLayout`, the escape hatch `LayoutBuilder` was
/// built on. Scrolling is then a layout, not a rebuild: nothing above the
/// sliver's element is rebuilt when the offset moves, and a frame that
/// scrolled by less than a row builds nothing at all.
///
/// Each child is wrapped in a render-object widget of this file's own, keyed
/// by index on the render side. That wrapper is what lets the element tell the
/// render object *which* index a new render child is: an item widget may be a
/// component whose render object appears a build pass later, or is replaced
/// by a `setState` deep inside it, and either way it arrives through the
/// wrapper, whose index never changes.
///
/// ## Differences from Flutter, stated once
///
///   * `axis:` rather than `scrollDirection:`, the name `ListView` here
///     already uses, and a [ScrollPosition] as the controller;
///   * a child delegate needs a `childCount`; an endless builder list is not
///     supported, because the extent of the content has to be known for the
///     scrollbar and for the estimate of rows not measured yet;
///   * [SliverList] measures rows and **estimates** the rest at
///     [SliverList.estimatedItemExtent] instead of averaging what it has seen,
///     and keeps the row at the top of the viewport still when an estimate
///     above it is corrected;
///   * `cacheExtent` defaults to zero, as in `ListView`, so the number of
///     children built is a number a test can predict;
///   * `SliverAppBar` (`sliver_app_bar.dart`) is a [SliverPersistentHeader]
///     with its own delegate, and has no `snap`: the header does not know
///     when a scroll has ended;
///   * no `NestedScrollView`, and no keep-alive.
library;

import 'dart:collection';

import '../geometry/offset.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_proxy_box.dart';
import '../layout/render_sliver.dart';
import '../layout/render_viewport.dart';
import '../platform/input_events.dart';
import '../scheduler/ui_dispatcher.dart';
import '../semantics/semantics.dart';
import 'element.dart';
import 'errors.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'keyboard_router.dart';
import 'pointer_router.dart';
import 'scroll_view.dart';
import 'scrollbar.dart';
import 'widget.dart';

// ---------------------------------------------------------------------------
// The scroll view
// ---------------------------------------------------------------------------

/// A scroll view made of slivers.
///
/// ```dart
/// CustomScrollView(
///   slivers: <Widget>[
///     SliverPersistentHeader(pinned: true, delegate: MyHeader()),
///     SliverList.builder(
///       itemCount: 100000,
///       itemBuilder: (BuildContext context, int index) => Text('Row $index'),
///     ),
///     const SliverFillRemaining(hasScrollBody: false, child: Footer()),
///   ],
/// )
/// ```
///
/// Input is the same as every scroll view here: the wheel through the pointer
/// signal resolver (the innermost scrollable wins a notch and chains what it
/// could not use outwards), drag with momentum, and a [Scrollbar]. It also
/// takes focus when clicked somewhere that did not focus something else, or
/// by Tab, and then answers the arrow keys, Page Up/Down and Home/End.
final class CustomScrollView extends StatefulWidget {
  const CustomScrollView({
    super.key,
    required this.slivers,
    this.controller,
    this.axis = ScrollAxis.vertical,
    this.reverse = false,
    this.cacheExtent = 0.0,
    this.scrollbar = ScrollbarVisibility.always,
    this.scrollbarThickness,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.focusable = true,
    this.dispatcher,
  });

  /// The slivers, in scroll order. Every one must be a sliver; a box goes in
  /// a [SliverToBoxAdapter].
  final List<Widget> slivers;

  /// The position to drive. One is created when this is null, and a caller
  /// that wants to read or set the offset passes its own - its `axis` then
  /// wins over [axis].
  final ScrollPosition? controller;

  final ScrollAxis axis;

  /// Whether the scroll starts at the bottom (or right) and the slivers grow
  /// upwards (or leftwards) - a chat log that opens on its newest message.
  final bool reverse;

  /// How far beyond each edge of the viewport lazy slivers keep children
  /// built. Zero, as in `ListView`; a screenful is the usual choice for a list
  /// whose rows are expensive to build.
  final double cacheExtent;

  final ScrollbarVisibility scrollbar;
  final double? scrollbarThickness;
  final bool dragEnabled;
  final bool mouseDragEnabled;

  /// Whether the view can take keyboard focus to scroll by key. False leaves
  /// the keys to whatever inside it is focused.
  final bool focusable;

  final UiDispatcher? dispatcher;

  @override
  State<CustomScrollView> createState() => _CustomScrollViewState();
}

final class _CustomScrollViewState extends State<CustomScrollView> {
  late final ScrollPosition _position =
      widget.controller ?? ScrollPosition(axis: widget.axis);
  final FocusNode _focusNode = FocusNode(debugLabel: 'CustomScrollView');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _focusNode.canRequestFocus = widget.focusable;
    final Widget scrollable = FocusAttachment(
      node: _focusNode,
      child: Scrollable(
        position: _position,
        reverse: widget.reverse,
        dragEnabled: widget.dragEnabled,
        mouseDragEnabled: widget.mouseDragEnabled,
        dispatcher: widget.dispatcher,
        child: _SliverViewport(
          position: _position,
          reverse: widget.reverse,
          cacheExtent: widget.cacheExtent,
          focusNode: _focusNode,
          children: widget.slivers,
        ),
      ),
    );
    if (widget.scrollbar == ScrollbarVisibility.never) return scrollable;
    return Scrollbar(
      position: _position,
      visibility: widget.scrollbar,
      thickness: widget.scrollbarThickness,
      dispatcher: widget.dispatcher,
      reverse: widget.reverse,
      child: scrollable,
    );
  }
}

final class _SliverViewport extends MultiChildRenderObjectWidget {
  const _SliverViewport({
    required this.position,
    required this.reverse,
    required this.cacheExtent,
    required this.focusNode,
    required super.children,
  });

  final ScrollPosition position;
  final bool reverse;
  final double cacheExtent;
  final FocusNode focusNode;

  @override
  RenderCustomScrollViewport createRenderObject(BuildContext context) =>
      RenderCustomScrollViewport(
        position: position,
        reverse: reverse,
        cacheExtent: cacheExtent,
      )..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderCustomScrollViewport object,
  ) {
    object
      ..position = position
      ..reverse = reverse
      ..cacheExtent = cacheExtent
      ..focusNode = focusNode;
  }
}

/// A [RenderSliverViewport] with the parts the layout layer cannot name:
/// keyboard scrolling, focus on click, and a node in the semantic tree.
///
/// The semantic node is a [SemanticsRole.list] whose value is the number of
/// items across every lazy sliver, the *full* count rather than the realized
/// one - the same answer `ListBox` gives, so that an assistive client can say
/// "row 3 of 100000" about a list whose rows mostly do not exist.
final class RenderCustomScrollViewport extends RenderSliverViewport
    implements
        PointerEventTarget,
        KeyboardEventTarget,
        SemanticsProvider,
        SemanticsActionTarget {
  RenderCustomScrollViewport({
    required super.position,
    super.reverse,
    super.cacheExtent,
  });

  FocusNode? _focusNode;

  /// The node that routes keys here. Owned by the scroll view's state.
  FocusNode? get focusNode => _focusNode;

  set focusNode(FocusNode? value) {
    if (identical(value, _focusNode)) return;
    final FocusNode? previous = _focusNode;
    if (previous != null && identical(previous.target, this)) {
      previous.target = null;
    }
    _focusNode = value;
    value?.target = this;
  }

  bool get hasFocus => _focusNode?.hasPrimaryFocus ?? false;

  bool get _vertical => axis == ScrollAxis.vertical;

  /// +1 when a movement towards the trailing edge of the screen increases
  /// the offset, -1 when [reverse] makes it decrease it.
  double get _sign => reverse ? -1.0 : 1.0;

  /// How many items the lazy slivers hold in total, realized or not.
  int get itemCount {
    int count = 0;
    void visit(RenderBox sliver) {
      if (sliver is RenderSliverMultiBoxAdaptor) {
        count += sliver.childManager.childCount;
      } else if (sliver is RenderSliverPadding) {
        final RenderBox? child = sliver.child;
        if (child != null) visit(child);
      }
    }

    for (int i = 0; i < childCount; i++) {
      visit(childAt(i));
    }
    return count;
  }

  // The blank part of a viewport is still the viewport: a click there focuses
  // it, and the wheel over it scrolls.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent || event.button != PointerButton.primary) {
      return;
    }
    final FocusNode? node = _focusNode;
    if (node == null || !node.canRequestFocus) return;
    // Pointer events reach the deepest target first, so a button inside the
    // view has already taken focus by the time the press bubbles up here.
    // Taking it back would make every focusable thing in a scroll view
    // unfocusable by mouse.
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
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final ScrollPosition position = this.position;
    final double before = position.pixels;
    final int key = event.logicalKey;
    final int forward = _vertical ? logicalKeyArrowDown : logicalKeyArrowRight;
    final int backward = _vertical ? logicalKeyArrowUp : logicalKeyArrowLeft;
    if (key == forward) {
      position.applyDelta(defaultLineExtent * _sign);
    } else if (key == backward) {
      position.applyDelta(-defaultLineExtent * _sign);
    } else if (key == logicalKeyPageDown) {
      position.pageBy(reverse ? -1 : 1);
    } else if (key == logicalKeyPageUp) {
      position.pageBy(reverse ? 1 : -1);
    } else if (key == logicalKeyHome) {
      // Home is the top of the *screen*, which in a reversed view is the
      // far end of the content.
      position.jumpTo(reverse ? position.maxScrollExtent : 0);
    } else if (key == logicalKeyEnd) {
      position.jumpTo(reverse ? 0 : position.maxScrollExtent);
    } else {
      return false;
    }
    // A key that moved nothing - Page Down at the end - is declined, so it
    // can still mean something to whatever handles keys after this.
    return position.pixels != before;
  }

  bool get _canScrollTowardsTrailing =>
      reverse ? !position.atStart : !position.atEnd;

  bool get _canScrollTowardsLeading =>
      reverse ? !position.atEnd : !position.atStart;

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.list,
        value: '$itemCount items',
        states: <SemanticsState>{
          if (hasFocus) SemanticsState.focused,
        },
        actions: <SemanticsAction>{
          if (_focusNode?.canRequestFocus ?? false) SemanticsAction.focus,
          if (_canScrollTowardsTrailing)
            _vertical
                ? SemanticsAction.scrollDown
                : SemanticsAction.scrollRight,
          if (_canScrollTowardsLeading)
            _vertical ? SemanticsAction.scrollUp : SemanticsAction.scrollLeft,
        },
      );

  /// A scroll action pages, as in `ListBox`; the answer is whether the
  /// position moved, which at either end it does not.
  @override
  bool performSemanticsAction(SemanticsAction action, {String? value}) {
    final int pages;
    switch (action) {
      case SemanticsAction.focus:
        final FocusNode? node = _focusNode;
        if (node == null || !node.canRequestFocus) return false;
        return node.requestFocus();
      case SemanticsAction.scrollDown when _vertical:
      case SemanticsAction.scrollRight when !_vertical:
        pages = reverse ? -1 : 1;
      case SemanticsAction.scrollUp when _vertical:
      case SemanticsAction.scrollLeft when !_vertical:
        pages = reverse ? 1 : -1;
      default:
        return false;
    }
    final double before = position.pixels;
    position.pageBy(pages);
    return position.pixels != before;
  }
}

// ---------------------------------------------------------------------------
// Single-child slivers
// ---------------------------------------------------------------------------

/// A box among slivers: laid out in full, scrolled like content.
final class SliverToBoxAdapter extends SingleChildRenderObjectWidget {
  const SliverToBoxAdapter({super.key, super.child});

  @override
  RenderSliverToBoxAdapter createRenderObject(BuildContext context) =>
      RenderSliverToBoxAdapter();
}

/// Insets a sliver. The insets scroll with it.
final class SliverPadding extends SingleChildRenderObjectWidget {
  const SliverPadding({super.key, required this.padding, Widget? sliver})
      : super(child: sliver);

  final EdgeInsets padding;

  @override
  RenderSliverPadding createRenderObject(BuildContext context) =>
      RenderSliverPadding(padding: padding);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverPadding renderObject,
  ) {
    renderObject.padding = padding;
  }
}

/// Fills what is left of the viewport after the slivers before it.
///
/// [hasScrollBody] false is the footer of a short page: the child is at least
/// as tall as the space the preceding slivers left, so it sits at the bottom
/// of the window, and as tall as it wants to be when that is more. True (the
/// default, as in Flutter) makes it exactly one viewport tall.
final class SliverFillRemaining extends SingleChildRenderObjectWidget {
  const SliverFillRemaining({
    super.key,
    this.hasScrollBody = true,
    super.child,
  });

  final bool hasScrollBody;

  @override
  RenderSliverFillRemaining createRenderObject(BuildContext context) =>
      RenderSliverFillRemaining(hasScrollBody: hasScrollBody);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverFillRemaining renderObject,
  ) {
    renderObject.hasScrollBody = hasScrollBody;
  }
}

// ---------------------------------------------------------------------------
// Persistent headers
// ---------------------------------------------------------------------------

/// Describes a header whose content depends on how much of it has scrolled
/// away.
abstract class SliverPersistentHeaderDelegate {
  const SliverPersistentHeaderDelegate();

  /// The extent the header shrinks to - and, when pinned, stays at.
  double get minExtent;

  /// The extent of the header with nothing scrolled away.
  double get maxExtent;

  /// The header for a given [shrinkOffset], from zero (fully expanded) to
  /// [maxExtent]. [overlapsContent] is true while content is scrolled
  /// underneath it, which is when a header usually draws its shadow or
  /// divider.
  ///
  /// Called during layout, whenever the shrink offset changes: keep it cheap,
  /// and do not call `setState` on anything from inside it.
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent);

  /// Whether a new delegate would build something different.
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate);
}

/// A header that shrinks as it scrolls, and optionally stays ([pinned]) or
/// comes back as soon as the user scrolls towards the start ([floating]).
///
/// The pieces a `SliverAppBar` is made of. A pinned header stays at the
/// leading edge at [SliverPersistentHeaderDelegate.minExtent] and the content
/// after it scrolls underneath; the header is painted over that content and
/// is the one a press there reaches.
final class SliverPersistentHeader extends RenderObjectWidget {
  const SliverPersistentHeader({
    super.key,
    required this.delegate,
    this.pinned = false,
    this.floating = false,
  });

  final SliverPersistentHeaderDelegate delegate;
  final bool pinned;
  final bool floating;

  @override
  SliverPersistentHeaderElement createElement() =>
      SliverPersistentHeaderElement(this);

  @override
  RenderSliverPersistentHeader createRenderObject(BuildContext context) =>
      RenderSliverPersistentHeader(
        minExtent: delegate.minExtent,
        maxExtent: delegate.maxExtent,
        pinned: pinned,
        floating: floating,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverPersistentHeader renderObject,
  ) {
    renderObject
      ..minExtent = delegate.minExtent
      ..maxExtent = delegate.maxExtent
      ..pinned = pinned
      ..floating = floating;
  }
}

/// Builds a [SliverPersistentHeader]'s child from inside layout.
///
/// The `LayoutBuilderElement` pattern with a different input: the child is a
/// function of the shrink offset, which only the render object's layout knows.
/// It rebuilds when that offset changes and when something dirtied this
/// element - a new delegate that [SliverPersistentHeaderDelegate.shouldRebuild]
/// accepts, or an inherited dependency the delegate read through this
/// element's context.
final class SliverPersistentHeaderElement extends RenderObjectElement {
  SliverPersistentHeaderElement(SliverPersistentHeader super.widget);

  Element? _child;
  int _buildCount = 0;

  @override
  SliverPersistentHeader get widget => super.widget as SliverPersistentHeader;

  @override
  RenderSliverPersistentHeader get renderObject =>
      super.renderObject as RenderSliverPersistentHeader;

  /// How many times the delegate's `build` has run. Scrolling a pinned
  /// header that has already shrunk to its minimum must not raise it.
  int get buildCount => _buildCount;

  @override
  void mount(Element? parent, BuildOwner owner) {
    super.mount(parent, owner);
    renderObject.childBuilder = _build;
  }

  @override
  void update(SliverPersistentHeader newWidget) {
    final SliverPersistentHeaderDelegate previous = widget.delegate;
    super.update(newWidget);
    final SliverPersistentHeaderDelegate delegate = newWidget.delegate;
    if (!identical(previous, delegate) &&
        (previous.runtimeType != delegate.runtimeType ||
            delegate.shouldRebuild(previous))) {
      renderObject.markNeedsChildUpdate();
    }
  }

  @override
  void performRebuild() {
    super.performRebuild();
    renderObject.markNeedsChildUpdate();
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    final Element? child = _child;
    if (child != null) visitor(child);
  }

  @override
  void forgetChild(Element child) {
    if (identical(_child, child)) _child = null;
  }

  @override
  void unmount() {
    renderObject.childBuilder = null;
    _child?.unmount();
    _child = null;
    super.unmount();
  }

  void _build(double shrinkOffset, bool overlapsContent) {
    if (!mounted) return;
    _buildCount++;
    final BuildOwner owner = this.owner!;
    owner.buildDuringLayout(() {
      owner.errorReporter.guard(
        FrameworkPhase.build,
        () => _child = updateChild(
          _child,
          widget.delegate.build(this, shrinkOffset, overlapsContent),
        ),
        widgetPath: debugWidgetPath(),
        context: 'running SliverPersistentHeaderDelegate.build',
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Lazy lists and grids
// ---------------------------------------------------------------------------

/// Supplies the children of a lazy sliver by index.
abstract class SliverChildDelegate {
  const SliverChildDelegate();

  /// How many children there are. Required: the extent of the content is part
  /// of what a lazy sliver reports, and an unknown count has none.
  int get childCount;

  /// The child at [index], or null for none. Called only for indices the
  /// sliver's layout reaches.
  Widget? build(BuildContext context, int index);

  /// Whether a new delegate would build different children from this one.
  bool shouldRebuild(covariant SliverChildDelegate oldDelegate) => true;
}

/// Children from a builder callback - the form that scales: nothing outside
/// the realized window is ever described.
final class SliverChildBuilderDelegate extends SliverChildDelegate {
  const SliverChildBuilderDelegate(this.builder, {required this.childCount});

  final Widget? Function(BuildContext context, int index) builder;

  @override
  final int childCount;

  @override
  Widget? build(BuildContext context, int index) =>
      index < 0 || index >= childCount ? null : builder(context, index);
}

/// Children from a list that already exists. The widgets cost their
/// allocation; their elements and render objects still exist only while they
/// are in the realized window.
final class SliverChildListDelegate extends SliverChildDelegate {
  const SliverChildListDelegate(this.children);

  final List<Widget> children;

  @override
  int get childCount => children.length;

  @override
  Widget? build(BuildContext context, int index) =>
      index < 0 || index >= children.length ? null : children[index];

  @override
  bool shouldRebuild(SliverChildListDelegate oldDelegate) =>
      !identical(children, oldDelegate.children);
}

/// A sliver whose children come from a [SliverChildDelegate] and are built
/// during layout.
abstract class SliverMultiBoxAdaptorWidget extends RenderObjectWidget {
  const SliverMultiBoxAdaptorWidget({super.key, required this.delegate});

  final SliverChildDelegate delegate;

  @override
  SliverMultiBoxAdaptorElement createElement() =>
      SliverMultiBoxAdaptorElement(this);

  @override
  RenderSliverMultiBoxAdaptor createRenderObject(BuildContext context);

  /// The child manager for a render object created with [context], which is
  /// always this widget's own element.
  static SliverChildManager childManagerOf(BuildContext context) =>
      context as SliverMultiBoxAdaptorElement;
}

/// A lazy list of children along the scroll axis, each as long as it wants
/// to be.
///
/// Rows are measured as they are laid out; rows not yet measured are assumed
/// to be [estimatedItemExtent] long, which is what gives the scrollbar a
/// length on the first frame.
final class SliverList extends SliverMultiBoxAdaptorWidget {
  const SliverList({
    super.key,
    required super.delegate,
    this.estimatedItemExtent = 40.0,
  });

  SliverList.builder({
    super.key,
    required Widget Function(BuildContext context, int index) itemBuilder,
    required int itemCount,
    this.estimatedItemExtent = 40.0,
  }) : super(
          delegate:
              SliverChildBuilderDelegate(itemBuilder, childCount: itemCount),
        );

  SliverList.list({
    super.key,
    required List<Widget> children,
    this.estimatedItemExtent = 40.0,
  }) : super(delegate: SliverChildListDelegate(children));

  /// What an unmeasured row is assumed to be.
  final double estimatedItemExtent;

  @override
  RenderSliverList createRenderObject(BuildContext context) => RenderSliverList(
        childManager: SliverMultiBoxAdaptorWidget.childManagerOf(context),
        estimatedItemExtent: estimatedItemExtent,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverList renderObject,
  ) {
    renderObject
      ..itemExtent = null
      ..estimatedItemExtent = estimatedItemExtent;
  }
}

/// A lazy list whose children all have the same extent - the fast path:
/// nothing is measured and every position is a multiplication.
final class SliverFixedExtentList extends SliverMultiBoxAdaptorWidget {
  const SliverFixedExtentList({
    super.key,
    required super.delegate,
    required this.itemExtent,
  });

  SliverFixedExtentList.builder({
    super.key,
    required this.itemExtent,
    required Widget Function(BuildContext context, int index) itemBuilder,
    required int itemCount,
  }) : super(
          delegate:
              SliverChildBuilderDelegate(itemBuilder, childCount: itemCount),
        );

  SliverFixedExtentList.list({
    super.key,
    required this.itemExtent,
    required List<Widget> children,
  }) : super(delegate: SliverChildListDelegate(children));

  final double itemExtent;

  @override
  RenderSliverList createRenderObject(BuildContext context) => RenderSliverList(
        childManager: SliverMultiBoxAdaptorWidget.childManagerOf(context),
        itemExtent: itemExtent,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverList renderObject,
  ) {
    renderObject.itemExtent = itemExtent;
  }
}

/// A lazy grid of equal cells, laid out by [gridDelegate].
final class SliverGrid extends SliverMultiBoxAdaptorWidget {
  const SliverGrid({
    super.key,
    required super.delegate,
    required this.gridDelegate,
  });

  SliverGrid.builder({
    super.key,
    required this.gridDelegate,
    required Widget Function(BuildContext context, int index) itemBuilder,
    required int itemCount,
  }) : super(
          delegate:
              SliverChildBuilderDelegate(itemBuilder, childCount: itemCount),
        );

  /// A fixed number of columns.
  SliverGrid.count({
    super.key,
    required int crossAxisCount,
    double mainAxisSpacing = 0,
    double crossAxisSpacing = 0,
    double childAspectRatio = 1,
    required List<Widget> children,
  })  : gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: mainAxisSpacing,
          crossAxisSpacing: crossAxisSpacing,
          childAspectRatio: childAspectRatio,
        ),
        super(delegate: SliverChildListDelegate(children));

  /// As many columns as fit at no more than [maxCrossAxisExtent] each.
  SliverGrid.extent({
    super.key,
    required double maxCrossAxisExtent,
    double mainAxisSpacing = 0,
    double crossAxisSpacing = 0,
    double childAspectRatio = 1,
    required List<Widget> children,
  })  : gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxCrossAxisExtent,
          mainAxisSpacing: mainAxisSpacing,
          crossAxisSpacing: crossAxisSpacing,
          childAspectRatio: childAspectRatio,
        ),
        super(delegate: SliverChildListDelegate(children));

  final SliverGridDelegate gridDelegate;

  @override
  RenderSliverGrid createRenderObject(BuildContext context) => RenderSliverGrid(
        childManager: SliverMultiBoxAdaptorWidget.childManagerOf(context),
        gridDelegate: gridDelegate,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverGrid renderObject,
  ) {
    renderObject.gridDelegate = gridDelegate;
  }
}

/// The element of a lazy sliver: it owns one child element per realized
/// index and creates and drops them when the render object asks.
///
/// Public because [SliverMultiBoxAdaptorWidget.createElement] returns it, and
/// an unspeakable return type is what `public_surface_test.dart` exists to
/// catch.
final class SliverMultiBoxAdaptorElement extends RenderObjectElement
    implements SliverChildManager {
  SliverMultiBoxAdaptorElement(SliverMultiBoxAdaptorWidget super.widget);

  final SplayTreeMap<int, Element> _items = SplayTreeMap<int, Element>();
  int _itemBuildCount = 0;

  @override
  SliverMultiBoxAdaptorWidget get widget =>
      super.widget as SliverMultiBoxAdaptorWidget;

  @override
  RenderSliverMultiBoxAdaptor get renderObject =>
      super.renderObject as RenderSliverMultiBoxAdaptor;

  /// How many times the delegate has been asked for a child. The number a
  /// laziness test asserts: it grows with what is scrolled past, never with
  /// [childCount].
  int get itemBuildCount => _itemBuildCount;

  /// The indices that currently have an element, ascending.
  List<int> get realizedIndices => _items.keys.toList(growable: false);

  @override
  int get childCount => widget.delegate.childCount;

  @override
  void realizeChildren(int first, int last) {
    if (!mounted) return;
    owner!.buildDuringLayout(() {
      for (final int index in _items.keys.toList(growable: false)) {
        if (index < first || index > last) {
          deactivateChild(_items.remove(index));
        }
      }
      for (int index = first; index <= last; index++) {
        if (!_items.containsKey(index)) _buildItem(index);
      }
    });
  }

  /// Builds - or rebuilds - the child at [index] from the current delegate.
  void _buildItem(int index) {
    owner!.errorReporter.guard(
      FrameworkPhase.build,
      () {
        _itemBuildCount++;
        final Widget? built = widget.delegate.build(this, index);
        final Element? updated = updateChild(
          _items[index],
          built == null ? null : _SliverItem(index: index, child: built),
        );
        if (updated == null) {
          _items.remove(index);
        } else {
          _items[index] = updated;
        }
      },
      widgetPath: debugWidgetPath(),
      context: 'building item $index of ${widget.runtimeType}',
    );
  }

  /// Rebuilds the realized children against the current delegate, in the
  /// build phase; the next layout adjusts the window.
  void _rebuildItems() {
    final int count = childCount;
    for (final int index in _items.keys.toList(growable: false)) {
      if (index >= count) {
        deactivateChild(_items.remove(index));
      } else {
        _buildItem(index);
      }
    }
    renderObject.markNeedsLayout();
  }

  @override
  void update(SliverMultiBoxAdaptorWidget newWidget) {
    final SliverChildDelegate previous = widget.delegate;
    super.update(newWidget);
    final SliverChildDelegate delegate = newWidget.delegate;
    if (identical(previous, delegate)) return;
    if (previous.runtimeType != delegate.runtimeType ||
        delegate.shouldRebuild(previous)) {
      _rebuildItems();
    } else {
      // Same children, possibly a different count: the window may change.
      renderObject.markNeedsLayout();
    }
  }

  @override
  void performRebuild() {
    // An inherited dependency read through this context by the delegate.
    super.performRebuild();
    _rebuildItems();
  }

  @override
  void insertRenderObjectChild(RenderBox child, {int? slot}) {
    if (child is! _RenderSliverItem) {
      throw StateError(
        '${widget.runtimeType} received a ${child.runtimeType}; its children '
        'are always inserted through their index wrapper.',
      );
    }
    renderObject.insertChild(child, child.index);
  }

  @override
  void removeRenderObjectChild(RenderBox child) =>
      renderObject.removeChild(child);

  @override
  void visitChildren(void Function(Element child) visitor) {
    for (final Element child in _items.values) {
      visitor(child);
    }
  }

  @override
  void forgetChild(Element child) {
    _items
        .removeWhere((int index, Element element) => identical(element, child));
  }

  @override
  void unmount() {
    for (final Element child in _items.values.toList(growable: false)) {
      child.unmount();
    }
    _items.clear();
    super.unmount();
  }
}

/// Carries a child's index to the render side.
final class _SliverItem extends SingleChildRenderObjectWidget {
  const _SliverItem({required this.index, required Widget super.child});

  final int index;

  @override
  _RenderSliverItem createRenderObject(BuildContext context) =>
      _RenderSliverItem(index);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSliverItem renderObject,
  ) {
    renderObject.index = index;
  }
}

/// Exactly its child, plus the index it was built for.
final class _RenderSliverItem extends RenderProxyBox {
  _RenderSliverItem(this.index);

  int index;
}
