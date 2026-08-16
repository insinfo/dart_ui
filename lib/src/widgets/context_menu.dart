/// The context menu: the popup a secondary click opens, where it was clicked.
///
/// A context menu is a popup with three properties that a [Menu] dropped into a
/// [Stack] does not have, and each of them is why this file exists:
///
///  * **It is placed against a work area, not against a parent widget.** The
///    pointer is a point, not a widget, and a menu opened three pixels from the
///    bottom of that area has to open *upward*. That computation already exists
///    as [PopupPositioner] - flip, then slide, then resize - so nothing here
///    reinvents it; [RenderContextMenuLayer] hands it an anchor and a work area
///    and puts the result in a parent-data offset. Which rectangle the work
///    area is, and why it is the window rather than the screen, is the first
///    limit below.
///  * **It grabs the pointer.** While it is open, a click anywhere else closes
///    it *and does not reach what is underneath*. That is the difference
///    between dismissing a menu and dismissing a menu while also pressing the
///    button behind it, and it is implemented by [RenderContextMenuLayer]
///    refusing to hit-test its content child.
///  * **It is operable from the keyboard.** Arrows, Home/End, Enter, the
///    initial letter and Escape. A menu that answers only the mouse is a menu a
///    keyboard user cannot reach at all, and the secondary *click* is not even
///    the only way in - Shift+F10 and the Menu key open the same popup.
///
/// ## The shape of the API
///
/// Three pieces, and the split is deliberate:
///
///  * [ContextMenuScope] wraps a subtree and owns the one popup that subtree
///    can show. It is the thing an application installs once, near the root.
///  * [ContextMenuController] is the handle: `open`, `refresh`, `close`. Any
///    descendant reaches it with `ContextMenuScope.of(context)`, which is how a
///    control deep in the tree opens a menu without knowing where the overlay
///    lives.
///  * [ContextMenu] is the popup surface itself - the items, the keyboard, the
///    semantics. Public because a caller may want to place one somewhere this
///    file did not anticipate.
///
/// [ContextMenuRegion] is a convenience on top: wrap a subtree, get a menu on
/// secondary press.
///
/// ## The biggest limit, stated first: this menu lives inside the window
///
/// A context menu on a real desktop is **a window of the operating system**,
/// not a node in its opener's tree. That is not a detail of polish; it is the
/// difference between a menu that is aligned to the pointer and one that is
/// shifted or cropped to fit inside its parent. Everything in this file is
/// drawn into the owner window's display list, so:
///
///  * **The work area is the window's client area, not the screen** - see
///    [RenderContextMenuLayer.performLayout], which hands [PopupPositioner] its
///    own box. That is deliberate and it is *not* a bug to be fixed by passing
///    the screen instead: the pixels are emitted inside this window, so a menu
///    positioned against the screen would simply be placed where the window is
///    not, and vanish. Given in-tree drawing, the window is the only rectangle
///    that can be honoured.
///  * **Near an edge, the menu is squeezed rather than free.** In a 360x460
///    window a menu opened three rows from the bottom flips upward and covers
///    the very text the user just selected. Flipping is the least-bad answer
///    available to something that cannot leave the window; it is not the right
///    answer, and no amount of work inside this file makes it one.
///
/// **The named prerequisite for fixing it is multiple native windows**, which a
/// neighbouring agent is implementing right now. When a backend can create an
/// override-redirect popup, [PopupPositioner.surfaceFor] already answers
/// whether a given placement needs one, and [ContextMenuPresentation] is the
/// seam it plugs into - so that migration replaces *where the menu is shown*
/// and touches nothing about what it shows or how it behaves.
///
/// Two things that must be true of that future window, recorded here because
/// they are where the reported bugs in other frameworks' versions of this live:
/// a menu window **must not count as an application window whose closing ends
/// the process** - the report from the Flutter desktop work is exactly that,
/// closing a popup killed the app - and its create/show/destroy sequence races
/// the frame that opened it, so the popup's lifetime must be owned by the
/// controller that opened it rather than by whatever happens to be painting.
///
/// ## What else is deliberately absent
///
///  * **Submenus.** [MenuItem] has no children and this file opens nothing from
///    an item. The machinery is ready for them - [PopupStack] already models an
///    owner chain and closes a parent's submenus with it, and
///    [RenderContextMenuSurface] declines Left/Right rather than swallowing
///    them, so the keys a submenu needs are still free - but a submenu also
///    needs a hover-open delay, a safe triangle toward the child popup, and a
///    second surface with its own grab. None of that is written. An item with
///    children would therefore silently do nothing, which is why [MenuItem] has
///    no such field.
///  * **Scrolling.** A menu taller than its layer is clamped to the layer and
///    slid against the top edge; the items past the bottom cannot be reached.
///    Windows grows a scroll arrow at each end. Nothing here does.
///  * **Layout-aware mnemonics.** Initial-letter navigation reads the virtual
///    key, so it matches A-Z and nothing else: no accented initial, no
///    non-Latin layout. Text arrives through [TextInputEvent], which is routed
///    only to a [TextInputTarget], and a menu is not one.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import 'control.dart';
import 'controls.dart' show MenuItem;
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'keyboard_router.dart';
import 'pointer_router.dart';
import 'popup.dart';
import 'semantics.dart';
import 'theme.dart';
import 'widget.dart';

/// The virtual key of the dedicated Menu key, between right Alt and right Ctrl
/// on most keyboards. Windows' `VK_APPS`; every backend normalizes to these.
const int logicalKeyContextMenu = 0x5D;

/// `VK_F10`. Shift+F10 is the other keyboard route into a context menu, and the
/// only one on a keyboard that has no Menu key.
const int logicalKeyF10 = 0x79;

/// Produces the items for one showing of a menu.
///
/// A function rather than a list because enablement is a snapshot of state that
/// can change *while the menu is open* - see [ContextMenuController.refresh],
/// which is what an asynchronous clipboard probe calls when its answer lands.
typedef ContextMenuItemsBuilder = List<MenuItem> Function();

// ---------------------------------------------------------------------------
// The controller
// ---------------------------------------------------------------------------

/// The one context menu a [ContextMenuScope] can show, and the handle on it.
///
/// One at a time, on purpose: a second context menu opened while the first is
/// up is never what a user asked for, so [open] closes whatever was showing
/// first and runs its `onClosed`. That is also what makes "right-click
/// somewhere else" behave - the click dismisses, and the press opens again.
final class ContextMenuController {
  ContextMenuController();

  final List<void Function()> _listeners = <void Function()>[];

  /// The overlay that will actually show the popup, once one is mounted.
  ///
  /// Held so [open] can convert a pointer position - which arrives in the
  /// window's coordinates - into the layer's own space. Doing it here rather
  /// than during layout is what makes the conversion exact: at the moment a
  /// pointer event is delivered, every ancestor offset is the current frame's.
  RenderContextMenuLayer? _layer;

  ContextMenuItemsBuilder? _builder;
  List<MenuItem> _items = const <MenuItem>[];
  Offset _anchor = Offset.zero;
  void Function()? _onClosed;
  bool _open = false;

  bool get isOpen => _open;

  /// The items currently showing. Empty when closed.
  List<MenuItem> get items => List<MenuItem>.unmodifiable(_items);

  /// Where the menu was asked to appear, in the layer's coordinates.
  Offset get anchor => _anchor;

  /// Where the menu actually ended up, or null when it is closed or has not
  /// been laid out yet.
  ///
  /// The whole [PopupPlacement], not just a rect: a caller - or a test - that
  /// wants to know whether the menu had to flip or slide to fit reads it here.
  PopupPlacement? get placement => _open ? _layer?.placement : null;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Shows [itemsBuilder]'s items with their top-left corner at
  /// [globalPosition], adjusted so the popup stays on screen.
  ///
  /// [onClosed] runs exactly once, whether the menu was dismissed by Escape, by
  /// a click outside, by focus moving away, by an item being chosen, or by
  /// another menu taking its place.
  void open({
    required Offset globalPosition,
    required ContextMenuItemsBuilder itemsBuilder,
    void Function()? onClosed,
  }) {
    if (_open) close();
    final RenderContextMenuLayer? layer = _layer;
    _anchor = layer == null || !layer.hasSize
        ? globalPosition
        : layer.globalToLocal(globalPosition);
    _builder = itemsBuilder;
    _items = itemsBuilder();
    _onClosed = onClosed;
    _open = true;
    _notify();
  }

  /// Rebuilds the items from the builder [open] was given.
  ///
  /// The point of a builder existing at all. A menu's enablement is a snapshot,
  /// and one of the facts it snapshots - whether the clipboard holds text - is
  /// only knowable asynchronously. The answer arrives after the menu is on
  /// screen, and this is how it gets there. A no-op when nothing is showing, so
  /// a late answer to a menu the user already dismissed cannot reopen it.
  void refresh() {
    if (!_open) return;
    _items = _builder!();
    _notify();
  }

  /// Closes the menu. Returns whether one was open.
  bool close() {
    if (!_open) return false;
    _open = false;
    _builder = null;
    _items = const <MenuItem>[];
    final void Function()? closed = _onClosed;
    _onClosed = null;
    _notify();
    closed?.call();
    return true;
  }

  void _notify() {
    for (final void Function() listener in List<void Function()>.of(
      _listeners,
    )) {
      listener();
    }
  }

  void _attach(RenderContextMenuLayer layer) => _layer = layer;

  void _detach(RenderContextMenuLayer layer) {
    if (identical(_layer, layer)) _layer = null;
  }
}

// ---------------------------------------------------------------------------
// Presentation: the seam between what a menu shows and where it is shown
// ---------------------------------------------------------------------------

/// Where a context menu's pixels go.
///
/// **This exists before it is needed, on purpose.** A context menu has two
/// halves that change for entirely different reasons: what it shows (items,
/// keyboard, semantics - the rest of this file) and where those pixels are
/// presented (inside the owner's surface, or in a popup window of its own).
/// Today only the first presentation exists, because a popup window needs
/// multi-window support that is being built right now. If the two halves were
/// welded together, gaining that support would mean rewriting the menu; with
/// the seam here it means writing one more implementation of this interface and
/// changing one argument.
///
/// A presentation answers two questions:
///
///  * [escapesOwnerWindow] - whether a menu shown this way may extend past the
///    owner window. It is the same question [PopupPositioner.surfaceFor]
///    answers per placement, and it is what decides whether the work area may
///    be the screen or must be the window.
///  * [present] - how the content and the popup are combined into one tree.
abstract interface class ContextMenuPresentation {
  /// Whether a menu presented this way may be drawn outside the owner window.
  ///
  /// False for anything composited into the owner's display list, which is
  /// every implementation that exists today.
  bool get escapesOwnerWindow;

  /// Combines the application's [content] with the popup [menu], if any.
  ///
  /// [menu] is null whenever nothing is showing, so an implementation that
  /// hands the popup to a separate window can tear that window down here
  /// instead of building a child.
  Widget present({
    required ContextMenuController controller,
    required Widget content,
    required Widget? menu,
  });
}

/// The only presentation that exists: composited into the owner's surface.
///
/// Cheap - no second window, no second frame, no platform round trip - and
/// bounded by the owner window, which is the trade the library comment above
/// describes in full.
final class InTreeContextMenuPresentation implements ContextMenuPresentation {
  const InTreeContextMenuPresentation();

  @override
  bool get escapesOwnerWindow => false;

  @override
  Widget present({
    required ContextMenuController controller,
    required Widget content,
    required Widget? menu,
  }) =>
      _ContextMenuLayerWidget(
        controller: controller,
        children: <Widget>[content, if (menu != null) menu],
      );
}

// ---------------------------------------------------------------------------
// The scope
// ---------------------------------------------------------------------------

/// Hosts the context menu for everything below it.
///
/// Install one high in the tree - around the whole window's content - because
/// the subtree it wraps is exactly the area the menu can be placed in, and a
/// scope around half the window would flip a menu against that half's edge
/// rather than the window's.
///
/// **Nothing installs one automatically.** A [TextField] with no scope above it
/// answers a secondary click by moving the caret and nothing else, which is a
/// visible no-op rather than a crash - the same choice [ClipboardScope] makes.
final class ContextMenuScope extends StatefulWidget {
  const ContextMenuScope({
    super.key,
    this.controller,
    this.presentation = const InTreeContextMenuPresentation(),
    required this.child,
  });

  /// The controller to publish, or null to own a private one.
  ///
  /// Passing one is how a test - or an application with a menu bar - opens the
  /// menu without a pointer.
  final ContextMenuController? controller;

  /// Where the popup's pixels go. See [ContextMenuPresentation] for why this is
  /// a parameter when only one implementation exists.
  final ContextMenuPresentation presentation;

  final Widget child;

  /// The nearest controller, or null when no scope is installed.
  static ContextMenuController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_ContextMenuMarker>()
      ?.controller;

  /// The nearest controller, or a failure that names the missing wrapper.
  static ContextMenuController of(BuildContext context) {
    final ContextMenuController? controller = maybeOf(context);
    if (controller != null) return controller;
    throw StateError(
      'no ContextMenuScope is installed above this widget; wrap the '
      "application's content in one so a context menu has somewhere to open",
    );
  }

  @override
  State<ContextMenuScope> createState() => _ContextMenuScopeState();
}

final class _ContextMenuScopeState extends State<ContextMenuScope> {
  late ContextMenuController _controller;
  late bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ContextMenuController();
    _controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(ContextMenuScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    _controller.removeListener(_onChanged);
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ContextMenuController();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    // A controller the caller owns may outlive this scope and be handed to
    // another one; a private one goes with the scope, and closing it here runs
    // whatever `onClosed` the opener is still waiting for.
    if (_ownsController) _controller.close();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => _ContextMenuMarker(
        controller: _controller,
        child: widget.presentation.present(
          controller: _controller,
          content: widget.child,
          menu: _controller.isOpen
              ? ContextMenu(
                  items: _controller.items,
                  onDismiss: _controller.close,
                )
              : null,
        ),
      );
}

final class _ContextMenuMarker extends InheritedWidget {
  const _ContextMenuMarker({required this.controller, required super.child});

  final ContextMenuController controller;

  @override
  bool updateShouldNotify(_ContextMenuMarker oldWidget) =>
      !identical(controller, oldWidget.controller);
}

// ---------------------------------------------------------------------------
// The overlay layer
// ---------------------------------------------------------------------------

final class _ContextMenuLayerWidget extends MultiChildRenderObjectWidget {
  const _ContextMenuLayerWidget({
    required this.controller,
    required super.children,
  });

  final ContextMenuController controller;

  @override
  RenderContextMenuLayer createRenderObject(BuildContext context) =>
      RenderContextMenuLayer()..controller = controller;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderContextMenuLayer object,
  ) {
    object.controller = controller;
  }
}

/// The overlay: content underneath, at most one popup on top of it.
///
/// Two children at most, and their roles are fixed by position - child 0 is the
/// content, child 1 is the popup - because the popup exists only while the menu
/// is open and a named slot would have to be nullable anyway.
final class RenderContextMenuLayer extends RenderBoxContainer<BoxParentData>
    implements PointerEventTarget {
  ContextMenuController? _controller;
  PopupPlacement? _placement;

  ContextMenuController? get controller => _controller;

  set controller(ContextMenuController? value) {
    if (identical(value, _controller)) return;
    _controller?._detach(this);
    _controller = value;
    value?._attach(this);
  }

  /// Where the popup was placed this frame, or null when nothing is showing.
  PopupPlacement? get placement => _placement;

  /// Whether a popup is currently part of this layer.
  bool get isOpen => childCount > 1;

  RenderBox? get _popup => childCount > 1 ? childAt(1) : null;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void performLayout() {
    _placement = null;
    if (childCount == 0) {
      size = constraints.smallest;
      return;
    }
    final RenderBox content = childAt(0);
    content.layout(constraints, parentUsesSize: true);
    content.parentData!.offset = Offset.zero;
    size = constraints.constrain(content.size);

    final RenderBox? popup = _popup;
    if (popup == null) return;
    // The work area is this layer, which is why the scope belongs high in the
    // tree: a menu can only be flipped against an edge the positioner knows
    // about, and the only edge it knows about is this box's.
    popup.layout(BoxConstraints.loose(size), parentUsesSize: true);
    final Offset anchor = _controller?.anchor ?? Offset.zero;
    final PopupPlacement placement = const PopupPositioner().place(
      PopupRequest(
        // A point, not a box: what a context menu is anchored to is where the
        // pointer was, so every [PopupAnchorPoint] resolves to the same place
        // and only the popup's own corner decides which way it grows.
        anchorRect: Rect.fromLTWH(anchor.dx, anchor.dy, 0, 0),
        size: popup.size,
        adjustments: const <PopupAdjustment>{
          PopupAdjustment.flipY,
          PopupAdjustment.flipX,
          PopupAdjustment.slideX,
          PopupAdjustment.slideY,
        },
      ),
      Rect.fromLTWH(0, 0, size.width, size.height),
    );
    _placement = placement;
    popup.parentData!.offset = Offset(placement.rect.left, placement.rect.top);
  }

  /// While a popup is open, only the popup is hit-testable.
  ///
  /// This is the input grab, and it is the whole reason the layer is a render
  /// object rather than a `Stack`. A click outside an open menu must dismiss it
  /// **and stop there**: delivering it to the content as well is how a user
  /// closes a menu and simultaneously presses the button they were aiming the
  /// dismissal at.
  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    final RenderBox? popup = _popup;
    if (popup == null) return super.hitTestChildren(position, path: path);
    final Offset offset = popup.offsetFromParent;
    return popup.hitTest(
      Offset(position.dx - offset.dx, position.dy - offset.dy),
      path: path,
    );
  }

  /// True only while a popup is open, so the layer is transparent the rest of
  /// the time and a window with no menu showing hit-tests exactly as it did
  /// before this widget was introduced.
  @override
  bool hitTestSelf(Offset position) => isOpen;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    final PopupPlacement? placement = _placement;
    if (placement == null) return;
    // The layer is on the hit path for presses *inside* the popup too, since it
    // is the popup's ancestor. Only the ones outside dismiss.
    if (placement.rect.contains(globalToLocal(event.logicalPosition))) return;
    _controller?.close();
  }

  @override
  void detach() {
    _controller?._detach(this);
    super.detach();
  }
}

// ---------------------------------------------------------------------------
// The popup surface
// ---------------------------------------------------------------------------

/// The menu itself: a column of items that owns the keyboard while it is up.
final class ContextMenu extends StatefulWidget {
  const ContextMenu({
    super.key,
    required this.items,
    this.onDismiss,
    this.visitsDisabledItems = true,
    this.restoresFocus = true,
  });

  final List<MenuItem> items;

  /// Called when the menu should close: Escape, focus loss, or an item chosen.
  final void Function()? onDismiss;

  /// Whether arrow keys stop on disabled items.
  ///
  /// **True by default, and that is the accessibility answer rather than the
  /// tidy one.** A disabled item is information - *Paste is here, and it is
  /// unavailable* - and a screen-reader user who can never put the cursor on it
  /// never learns either half, nor the reason this menu attaches to it as a
  /// hint. Windows menus behave this way; macOS skips. Activation is refused
  /// either way, which is the property that actually matters, so an application
  /// that prefers the shorter walk sets this false and loses nothing but the
  /// announcement.
  final bool visitsDisabledItems;

  /// Whether closing returns the keyboard to whatever held it before.
  ///
  /// True by default: a menu is a detour, and a user who dismisses one expects
  /// to be back in the field they were editing - with Ctrl+C working again.
  final bool restoresFocus;

  @override
  State<ContextMenu> createState() => _ContextMenuState();
}

final class _ContextMenuState extends State<ContextMenu> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'ContextMenu',
    // Tab must not walk *into* a menu, and Tab pressed while one is up moves to
    // the next control - which takes focus away, which closes the menu. That is
    // the behaviour every toolkit has, and it falls out of leaving the ring
    // alone rather than out of a rule about Tab.
    skipTraversal: true,
  );

  FocusNode? _restoreTo;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  Widget build(BuildContext context) {
    _attachFocus(context);
    final ThemeData theme = Theme.of(context);
    return _ContextMenuSurfaceWidget(
      theme: theme,
      focusNode: _focusNode,
      visitsDisabledItems: widget.visitsDisabledItems,
      onDismiss: _dismiss,
      children: <Widget>[
        for (final MenuItem item in widget.items)
          if (item.isSeparator)
            _ContextMenuSeparatorWidget(theme: theme)
          else
            _ContextMenuItemWidget(
              item: item,
              theme: theme,
              onActivate: () => _select(item),
            ),
      ],
    );
  }

  /// Joins the enclosing scope and takes the keyboard, once.
  ///
  /// The focus request happens here, in `build`, and therefore *before* the
  /// render object that will receive the keys exists. That is not a race:
  /// [FocusNode.target] re-points the router when the render object adopts the
  /// node a moment later, which is precisely the case that setter exists for.
  void _attachFocus(BuildContext context) {
    if (_focusNode.parent != null) return;
    final FocusScopeNode? scope =
        FocusScope.of(context) ?? _ownerRootScope(context);
    if (scope == null) return;
    _restoreTo = scope.manager?.primaryFocus;
    scope.add(_focusNode);
    _focusNode.requestFocus();
  }

  FocusScopeNode? _ownerRootScope(BuildContext context) {
    final Element? element = context is Element ? context : null;
    return element?.owner?.focusManager.rootScope;
  }

  void _onFocusChanged(FocusNode node) {
    // Focus moving away is a dismissal: clicking another window's control, Tab,
    // or anything else that takes the keyboard. Guarded against the teardown
    // path, where losing focus is a *consequence* of closing rather than a
    // reason to close again.
    if (_closing || node.hasPrimaryFocus) return;
    _dismiss();
  }

  void _dismiss() {
    if (_closing) return;
    _closing = true;
    widget.onDismiss?.call();
  }

  void _select(MenuItem item) {
    // Closed first, then run. An item that opens another menu - or a dialog -
    // must not have it torn down by the dismissal of the menu it came from.
    _dismiss();
    item.onSelected?.call();
  }

  @override
  void dispose() {
    _closing = true;
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    final FocusNode? restoreTo = _restoreTo;
    _restoreTo = null;
    if (widget.restoresFocus &&
        restoreTo != null &&
        restoreTo.parent != null &&
        restoreTo.canRequestFocus) {
      restoreTo.requestFocus(FocusChangeReason.restoration);
    }
    super.dispose();
  }
}

final class _ContextMenuSurfaceWidget extends MultiChildRenderObjectWidget {
  const _ContextMenuSurfaceWidget({
    required this.theme,
    required this.focusNode,
    required this.visitsDisabledItems,
    required this.onDismiss,
    required super.children,
  });

  final ThemeData theme;
  final FocusNode focusNode;
  final bool visitsDisabledItems;
  final void Function() onDismiss;

  @override
  RenderContextMenuSurface createRenderObject(BuildContext context) =>
      RenderContextMenuSurface()
        ..theme = theme
        ..focusNode = focusNode
        ..visitsDisabledItems = visitsDisabledItems
        ..onDismiss = onDismiss;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderContextMenuSurface object,
  ) {
    object
      ..theme = theme
      ..focusNode = focusNode
      ..visitsDisabledItems = visitsDisabledItems
      ..onDismiss = onDismiss;
  }
}

/// The popup's frame, its column layout, and its keyboard.
final class RenderContextMenuSurface extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  int _highlighted = -1;
  void Function()? onDismiss;

  /// Whether arrow keys stop on disabled items. See [ContextMenu].
  ///
  /// A plain field: changing it moves nothing on screen by itself, it only
  /// changes where the *next* arrow press lands.
  bool visitsDisabledItems = true;

  /// The item the keyboard cursor is on, or -1 when none is.
  ///
  /// -1 on opening, deliberately: a menu that pre-selected its first item would
  /// have Enter activate a command the user never looked at.
  int get highlightedIndex => _highlighted;

  /// The highlighted item, or null.
  RenderContextMenuItem? get highlightedItem {
    if (_highlighted < 0 || _highlighted >= childCount) return null;
    final RenderBox child = childAt(_highlighted);
    return child is RenderContextMenuItem ? child : null;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void insert(RenderBox child, {required int index}) {
    super.insert(child, index: index);
    if (child is RenderContextMenuItem) child.surface = this;
  }

  @override
  void remove(RenderBox child) {
    if (child is RenderContextMenuItem) child.surface = null;
    super.remove(child);
    if (_highlighted >= childCount) _highlighted = childCount - 1;
  }

  @override
  void removeAll() {
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      if (child is RenderContextMenuItem) child.surface = null;
    }
    super.removeAll();
    _highlighted = -1;
  }

  @override
  void performLayout() {
    final double padding = theme.effectiveControlPadding;
    // Two passes over the *intrinsic* sizes rather than two layout passes: the
    // width every item is given is the widest item's, so it has to be known
    // before any of them is laid out.
    double width = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      if (child is! RenderContextMenuItem) continue;
      final double natural = child.naturalWidth;
      if (natural > width) width = natural;
    }
    width = (width + padding * 2).clamp(
      0.0,
      constraints.maxWidth.isFinite ? constraints.maxWidth : double.infinity,
    );

    double y = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(
        BoxConstraints.tightFor(width: width),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(0, y);
      y += child.size.height;
    }
    size = constraints.constrain(Size(width, y));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  /// Solid to the pointer, and inert.
  ///
  /// [ControlBehavior]'s press-and-release path is deliberately *not* run here.
  /// Items own their own clicks, and the surface is on the same hit path as the
  /// item under the pointer - so leaving the inherited behaviour in place made
  /// one click activate the highlighted command twice: once through the item
  /// and once through this. Swallowing the event is also what makes a click on
  /// the menu's border or padding do nothing instead of dismissing.
  @override
  void handlePointerEvent(PointerEvent event) {}

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyEscape:
        onDismiss?.call();
        return true;
      case logicalKeyArrowDown:
        _move(1);
        return true;
      case logicalKeyArrowUp:
        _move(-1);
        return true;
      case logicalKeyHome:
        _move(1, from: -1);
        return true;
      case logicalKeyEnd:
        _move(-1, from: childCount);
        return true;
      case logicalKeyArrowLeft:
      case logicalKeyArrowRight:
        // Declined rather than swallowed: these are the submenu keys, and this
        // menu has no submenus. Claiming them would make a future submenu
        // implementation look like it works while doing nothing.
        return false;
      case logicalKeyTab:
        // Also declined, so traversal moves focus - which closes the menu. See
        // [_ContextMenuState._onFocusChanged].
        return false;
    }
    // A-Z only; see the library comment on why there is no layout-aware
    // mnemonic. Checked before [ControlBehavior] so a letter is never mistaken
    // for an activation.
    if (event.logicalKey >= 0x41 && event.logicalKey <= 0x5A) {
      return _jumpToLetter(String.fromCharCode(event.logicalKey));
    }
    // Space and Enter, through the one activation path every control shares.
    return super.handleKeyEvent(event);
  }

  @override
  void activate() => highlightedItem?.activate();

  /// Moves the highlight by [delta], wrapping, starting from [from].
  ///
  /// Separators are always skipped - there is nothing there to choose - and
  /// disabled items are skipped only when [visitsDisabledItems] is false.
  void _move(int delta, {int? from}) {
    if (childCount == 0) return;
    final int start = from ?? _highlighted;
    int index = start < 0 ? (delta > 0 ? -1 : childCount) : start;
    for (int step = 0; step < childCount; step++) {
      index = (index + delta) % childCount;
      final RenderBox child = childAt(index);
      if (child is! RenderContextMenuItem) continue;
      if (!visitsDisabledItems && !child.item.enabled) continue;
      _setHighlighted(index);
      return;
    }
  }

  /// Moves to the next enabled item whose mnemonic is [letter].
  ///
  /// Never lands on a disabled item, whatever [visitsDisabledItems] says: type-
  /// ahead is a shortcut to *choosing* something, and a shortcut that lands
  /// somewhere unchoosable has failed at the only thing it was for.
  ///
  /// The highlight moves; it does not activate. A unique match that fired
  /// immediately would mean a typo in a menu runs a command, and the command
  /// under a stray keystroke is often Delete.
  bool _jumpToLetter(String letter) {
    if (childCount == 0) return false;
    final String wanted = letter.toUpperCase();
    final int start = _highlighted < 0 ? -1 : _highlighted;
    for (int step = 1; step <= childCount; step++) {
      final int index = (start + step) % childCount;
      final RenderBox child = childAt(index);
      if (child is! RenderContextMenuItem) continue;
      if (!child.item.enabled) continue;
      if (child.item.mnemonicLetter.toUpperCase() != wanted) continue;
      _setHighlighted(index);
      return true;
    }
    return false;
  }

  /// Puts the highlight on [child], which is how a hovering pointer and the
  /// arrow keys stay in agreement about where the cursor is.
  void highlightItem(RenderContextMenuItem child) {
    for (int i = 0; i < childCount; i++) {
      if (identical(childAt(i), child)) {
        _setHighlighted(i);
        return;
      }
    }
  }

  void _setHighlighted(int index) {
    if (index == _highlighted) return;
    highlightedItem?.highlighted = false;
    _highlighted = index;
    highlightedItem?.highlighted = true;
    markNeedsPaint();
  }

  // -------------------------------------------------------------------------
  // Painting and semantics
  // -------------------------------------------------------------------------

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surfaceAlternate);
    paintBorder(list, rect, theme.border);
    super.paint(list, offset);
    paintFocusRing(list, rect);
  }

  @override
  SemanticsConfiguration describeSemantics() {
    int items = 0;
    for (int i = 0; i < childCount; i++) {
      if (childAt(i) is RenderContextMenuItem) items++;
    }
    return SemanticsConfiguration(
      role: SemanticsRole.menu,
      value: '$items items',
      states: <SemanticsState>{
        // A menu holds the pointer grab, so what is behind it is not reachable
        // - by a mouse or by an assistive client. Same declaration a modal
        // dialog makes, for the same reason.
        SemanticsState.modal,
        if (hasFocus) SemanticsState.focused,
      },
      actions: const <SemanticsAction>{
        SemanticsAction.focus,
        SemanticsAction.dismiss,
      },
      isBlocking: true,
    );
  }
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

final class _ContextMenuItemWidget extends RenderObjectWidget {
  const _ContextMenuItemWidget({
    required this.item,
    required this.theme,
    required this.onActivate,
  });

  final MenuItem item;
  final ThemeData theme;
  final void Function() onActivate;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderContextMenuItem createRenderObject(BuildContext context) =>
      RenderContextMenuItem(item: item)
        ..theme = theme
        ..onActivate = onActivate
        ..enabled = item.enabled;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderContextMenuItem object,
  ) {
    object
      ..item = item
      ..theme = theme
      ..onActivate = onActivate
      ..enabled = item.enabled;
  }
}

/// One command in a [ContextMenu].
///
/// A render object per item rather than one that paints a list, and the reason
/// is accessibility: an item needs a node of its own in the semantic tree, with
/// its own bounds, its own role, its own disabled state and its own hint. A
/// single node saying "menu, four items" is what a screen reader cannot use.
final class RenderContextMenuItem extends RenderBox with ControlBehavior {
  RenderContextMenuItem({required MenuItem item}) : _item = item;

  /// The height of one item. Fixed rather than derived from the theme's control
  /// height: a menu row is not a button, and a 24px-tall row of commands reads
  /// as a list where a 32px one reads as a stack of buttons.
  static const double itemHeight = 20.0;

  /// The gap kept between a label and its accelerator text, so the two never
  /// look like one string.
  static const double shortcutGap = 24.0;

  MenuItem _item;
  bool _highlighted = false;
  void Function()? onActivate;

  /// The surface this item belongs to, set when it is adopted. Null while the
  /// item is between parents.
  RenderContextMenuSurface? surface;

  MenuItem get item => _item;

  set item(MenuItem value) {
    if (identical(value, _item)) return;
    final bool relayout = value.label != _item.label ||
        value.shortcut != _item.shortcut ||
        value.isSeparator != _item.isSeparator;
    _item = value;
    if (relayout) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  bool get highlighted => _highlighted;

  set highlighted(bool value) {
    if (value == _highlighted) return;
    _highlighted = value;
    markNeedsPaint();
  }

  /// The width this item would like: its label, its accelerator, and the gap
  /// that keeps them apart.
  double get naturalWidth {
    double width = measureLabel(_item.label).width;
    final String? shortcut = _item.shortcut;
    if (shortcut != null && shortcut.isNotEmpty) {
      width += shortcutGap + measureLabel(shortcut).width;
    }
    return width;
  }

  /// An item never takes the keyboard; the surface holds it for the whole menu,
  /// which is what keeps arrow navigation in one place.
  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() => size = constraints.constrain(
        Size(naturalWidth + theme.effectiveControlPadding * 2, itemHeight),
      );

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    // Hover moves the keyboard cursor too. Two cursors - one the mouse drives
    // and one the arrows drive - is how a user presses Enter and gets the
    // command their pointer is *not* on.
    if (event is PointerMoveEvent || event is PointerDownEvent) {
      surface?.highlightItem(this);
    }
  }

  @override
  void activate() {
    // Disabled items are reachable, readable and inert. The refusal lives here
    // rather than at the call site so that every route into activation - a
    // click, Enter, an accessibility invoke - is refused by the same line.
    if (!_item.enabled || _item.isSeparator) return;
    onActivate?.call();
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    if (_highlighted) paintFill(list, rect, theme.accent);
    final int color = !_item.enabled
        ? theme.disabledForeground
        : _highlighted
            ? theme.surfaceAlternate
            : theme.foreground;
    final double padding = theme.effectiveControlPadding;
    final double top =
        (rect.top + (rect.height - labelLineHeight) / 2).roundToDouble();
    final String? shortcut = _item.shortcut;
    final double shortcutWidth = shortcut == null || shortcut.isEmpty
        ? 0
        : measureLabel(shortcut).width + shortcutGap;
    paintLabel(
      list,
      _item.label,
      Offset(rect.left + padding, top),
      color,
      maxWidth: (rect.width - padding * 2 - shortcutWidth).clamp(
        0.0,
        double.infinity,
      ),
    );
    if (shortcut != null && shortcut.isNotEmpty) {
      paintLabel(
        list,
        shortcut,
        Offset(rect.right - padding - measureLabel(shortcut).width, top),
        _item.enabled && !_highlighted ? theme.foregroundSecondary : color,
      );
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.menuItem,
        label: _item.label,
        // The *reason* a command is unavailable, not merely that it is. "Copy,
        // dimmed" leaves the user guessing; "Copy, dimmed, the field is
        // obscured" is the whole point of carrying the reason on the item.
        hint: _item.enabled ? null : _item.disabledReason,
        value: _item.shortcut,
        states: <SemanticsState>{
          if (!_item.enabled) SemanticsState.disabled,
          // The keyboard cursor, reported as focus: the menu holds the real
          // focus node, and an assistive client needs to know which row it is
          // on, not which render object owns the keyboard.
          if (_highlighted) SemanticsState.focused,
        },
        actions: <SemanticsAction>{
          SemanticsAction.focus,
          if (_item.enabled) SemanticsAction.activate,
        },
        mergesDescendants: true,
      );

  @override
  void detach() {
    surface = null;
    super.detach();
  }
}

final class _ContextMenuSeparatorWidget extends RenderObjectWidget {
  const _ContextMenuSeparatorWidget({required this.theme});

  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderContextMenuSeparator createRenderObject(BuildContext context) =>
      RenderContextMenuSeparator(color: theme.border);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderContextMenuSeparator object,
  ) {
    object.color = theme.border;
  }
}

/// The rule between two groups of commands.
///
/// Deliberately **not** a [SemanticsProvider]: a separator is a visual grouping
/// cue with no name, no role in this framework's vocabulary and nothing to
/// announce, so it contributes no node at all rather than an empty one for a
/// screen reader to read out as "group".
final class RenderContextMenuSeparator extends RenderBox {
  RenderContextMenuSeparator({required int color}) : _color = color;

  static const double separatorHeight = 5.0;

  int _color;

  int get color => _color;

  set color(int value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void performLayout() => size = constraints.constrain(
        Size(constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
            separatorHeight),
      );

  /// Solid to the pointer, so a click on the gap between two commands is
  /// swallowed by the menu instead of falling through and dismissing it.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final int paint = list.addPaint(colorArgb: _color, antiAlias: false);
    list.drawRectangle(
      Rect.fromLTWH(
        offset.dx + 2,
        (offset.dy + separatorHeight / 2).roundToDouble(),
        (size.width - 4).clamp(0.0, double.infinity),
        1,
      ),
      paint,
    );
  }
}

// ---------------------------------------------------------------------------
// The trigger
// ---------------------------------------------------------------------------

/// Opens a context menu for a secondary press anywhere in [child].
///
/// The convenience half of this file: a caller that just wants "right-click
/// here shows these commands" writes this and never touches a controller.
final class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.itemsBuilder,
    this.opaque = true,
    required this.child,
  });

  final ContextMenuItemsBuilder itemsBuilder;

  /// Whether the whole region answers the pointer, or only the parts of [child]
  /// that are hit-testable themselves.
  ///
  /// True by default, which is the opposite of [GestureDetector]'s choice and
  /// deliberately so: a gesture detector wraps *a control*, while a region
  /// wraps *an area*, and the empty space in a panel is exactly where a user
  /// right-clicks to get the panel's own menu.
  final bool opaque;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ContextMenuController? controller = ContextMenuScope.maybeOf(context);
    return _ContextMenuRegionWidget(
      opaque: opaque,
      onSecondaryPress: controller == null
          ? null
          : (Offset position) => controller.open(
                globalPosition: position,
                itemsBuilder: itemsBuilder,
              ),
      child: child,
    );
  }
}

final class _ContextMenuRegionWidget extends SingleChildRenderObjectWidget {
  const _ContextMenuRegionWidget({
    required this.opaque,
    required this.onSecondaryPress,
    required super.child,
  });

  final bool opaque;
  final void Function(Offset position)? onSecondaryPress;

  @override
  RenderContextMenuRegion createRenderObject(BuildContext context) =>
      RenderContextMenuRegion(opaque: opaque)
        ..onSecondaryPress = onSecondaryPress;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderContextMenuRegion object,
  ) {
    object
      ..opaque = opaque
      ..onSecondaryPress = onSecondaryPress;
  }
}

final class RenderContextMenuRegion extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderContextMenuRegion({required this.opaque});

  /// Whether the whole region answers the pointer. See [ContextMenuRegion].
  bool opaque;

  void Function(Offset position)? onSecondaryPress;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  bool hitTestSelf(Offset position) => opaque;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    if (event.button != PointerButton.secondary) return;
    onSecondaryPress?.call(event.logicalPosition);
  }
}
