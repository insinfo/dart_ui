/// Flutter's menu widgets - [MenuController], [MenuAnchor], [MenuItemButton],
/// [SubmenuButton] and [MenuBar] - over this framework's popup host.
///
/// The names and the constructor arguments are Flutter's on purpose. An
/// application being ported is a large body of code whose menus are already
/// written; every argument that had to be renamed is a mechanical edit somebody
/// has to make and can get wrong, and every widget that had to be restructured
/// is a redesign. So `MenuAnchor(menuChildren: ..., builder: ...)` means here
/// what it means there, and the places that differ are the ones where keeping
/// the name would have meant lying about the behaviour - each is called out at
/// the member it affects.
///
/// ## What this file is, structurally
///
/// A thin arrangement of three things that already exist, and it is thin on
/// purpose:
///
///   * [PopupHost] decides *where the pixels go* - an overlay inside the owner
///     window, or a window of the popup's own. Nothing here knows which, which
///     is what lets the same menu flip against the screen on a backend with
///     popup windows and against the client area on one without;
///   * [PopupStack], through the host, owns *dismissal ordering*: closing a
///     popup closes its children, and a click inside a popup closes everything
///     above it and stops there. Those two rules are the whole of "clicking a
///     parent menu closes only the submenu", and re-deriving them here would
///     have given menus a second, disagreeing opinion about it;
///   * [ControlBehavior] owns *what a control does* - press, hover, keyboard
///     activation, the focus ring, and the single [ControlBehavior.activate]
///     path that a click, Enter and an assistive client's invoke all funnel
///     through, so the three cannot drift apart.
///
/// ## The keyboard cursor is not focus
///
/// Flutter gives every [MenuItemButton] a [FocusNode] and moves real focus
/// between them. This repository does not, for the reason `RenderContextMenuItem`
/// states: an item owns no focus node, the surface holds the keyboard for the
/// whole menu, and the highlight *is* the keyboard cursor - published as
/// [SemanticsState.focused] on the row, because an assistive client needs to
/// know which row it is on and not which render object owns the keys. Two
/// cursors, one the mouse drives and one the arrows drive, is how a user presses
/// Enter and gets the command their pointer is *not* on.
///
/// The consequence for the ported API is [MenuItemButton.requestFocusOnHover]:
/// it still decides whether hovering moves the cursor onto the row - the
/// behaviour the flag is named after - and no [FocusNode] changes hands.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../semantics/semantics.dart';
import 'basic.dart' show DefaultTextStyle, RenderText, SizedBox;
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'popup.dart';
import 'popup_host.dart';
import 'theme.dart';
import 'widget.dart';

// ---------------------------------------------------------------------------
// The controller
// ---------------------------------------------------------------------------

/// Opens and closes the menu of the [MenuAnchor] or [SubmenuButton] it was
/// handed to.
///
/// A plain listenable rather than a `ChangeNotifier`, which this framework does
/// not have: the shape is [ContextMenuController]'s - a list of callbacks with
/// [addListener] and [removeListener] - so an application that already listens
/// to one listens to the other the same way.
///
/// The controller holds no state of its own. [isOpen] asks the anchor, because
/// the anchor owns the [PopupHandle]; a controller that cached the flag would
/// go stale the moment the menu was dismissed by a click outside, which is the
/// most common way a menu closes and the one route the controller is never told
/// about directly.
final class MenuController {
  MenuController();

  _MenuAnchorDelegate? _anchor;
  final List<void Function()> _listeners = <void Function()>[];

  /// Whether the menu this controller drives is showing.
  ///
  /// False when nothing is attached, which is the honest answer rather than an
  /// error: a builder may read this while building the very anchor that is
  /// about to attach it.
  bool get isOpen => _anchor?.isMenuOpen ?? false;

  /// Shows the menu.
  ///
  /// [position] is Flutter's: an offset in the anchor's own coordinate space
  /// that replaces the anchor rect, so the menu opens at a point instead of
  /// under a control. It overrides [MenuAnchor.alignmentOffset], as it does
  /// there - a menu asked to appear at a point must not then be pushed off it
  /// by the anchor's own nudge.
  ///
  /// Throws when no anchor is attached. Silently doing nothing was the other
  /// option and it is worse: a menu that never appears looks exactly like a
  /// menu whose items are all disabled, and the fix - open it after the frame
  /// that mounted the anchor - is not discoverable from either symptom.
  void open({Offset? position}) {
    final _MenuAnchorDelegate? anchor = _anchor;
    if (anchor == null) {
      throw StateError(
        'MenuController.open() was called before the controller was attached '
        'to a MenuAnchor or a SubmenuButton.\n'
        'A controller attaches while its anchor builds, so open() has to come '
        'after the frame that mounted it.',
      );
    }
    anchor.openMenu(position: position);
  }

  /// Hides the menu and every submenu opened from it.
  ///
  /// A no-op when nothing is showing or nothing is attached: "close what is not
  /// open" is a request that has already been satisfied, and the several routes
  /// into dismissal race by nature.
  void close() => _anchor?.closeMenu();

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void _attach(_MenuAnchorDelegate anchor) => _anchor = anchor;

  void _detach(_MenuAnchorDelegate anchor) {
    if (identical(_anchor, anchor)) _anchor = null;
  }
}

/// What a [MenuController] talks to: the state of a widget that owns a popup.
abstract interface class _MenuAnchorDelegate {
  bool get isMenuOpen;

  void openMenu({Offset? position});

  void closeMenu();
}

// ---------------------------------------------------------------------------
// The chain: what a menu's content knows about the popup it lives in
// ---------------------------------------------------------------------------

/// The [PopupHandle] of the popup a menu's content is built into.
///
/// A mutable holder rather than the handle itself, because of the order the two
/// come into existence in: [PopupHost.open] takes a builder, and the handle it
/// returns does not exist until that builder could already have been called.
/// The holder is created first, handed to the content through [_MenuScope], and
/// filled the instant `open` returns - which is before any build of the popup's
/// content, so nothing ever reads it empty.
final class _HandleHolder {
  PopupHandle? handle;

  /// Closes the outermost popup of this chain, which closes every popup below
  /// it, deepest first.
  ///
  /// What choosing a command does. An item that closed only its own menu would
  /// leave the menu bar's dropdown standing after the user picked something out
  /// of a submenu three levels down, which no desktop does.
  void closeChain() {
    PopupHandle? node = handle;
    if (node == null || !node.isOpen) return;
    while (node!.parent != null) {
      node = node.parent;
    }
    node.close();
  }
}

/// Published above a menu's children so they can find the popup they are in and
/// the shape of the strip they sit in.
///
/// It is re-published inside the popup's own builder rather than inherited from
/// the anchor, and it has to be: a popup's content is built under the host's
/// layer, not under the widget that opened it, so *no* inherited widget from the
/// calling tree reaches it. [PopupSpec.builder] says so, and it is the single
/// easiest thing to get wrong here - the symptom is a submenu that opens as a
/// root popup and outlives the menu it came from.
final class _MenuScope extends InheritedWidget {
  const _MenuScope({
    required this.holder,
    required this.horizontal,
    required this.passThrough,
    required super.child,
  });

  final _HandleHolder holder;

  /// The one region of window content this chain's popups stay out of the way
  /// of, or null for a chain that is modal everywhere.
  ///
  /// Non-null for everything a [MenuBar] opens, and it has to be. A menu makes
  /// the layer modal - that is what stops the press which closes it from also
  /// pressing the button it landed on - but the bar **is** window content, so
  /// a layer that were modal everywhere would take the pointer away from the
  /// bar itself. Hovering a sibling to switch menus, and clicking the open
  /// menu's own button to close it, both need the bar to keep receiving the
  /// pointer while its dropdown is up.
  ///
  /// So the bar hands its own rect down here and [PopupSpec.passThrough]
  /// carries it to the layer, which is "modal, except there". Win32 spends a
  /// menu-mode tracking loop to get the same two behaviours at once.
  final Rect? Function()? passThrough;

  /// Whether the children of this scope are laid out left to right.
  ///
  /// True only inside a [MenuBar]'s own strip. It decides which way a
  /// [SubmenuButton] opens - downward from the bottom edge in a bar, sideways
  /// from the right edge in a menu - and whether Left and Right walk siblings
  /// or descend into a submenu.
  final bool horizontal;

  static _MenuScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MenuScope>();

  @override
  bool updateShouldNotify(_MenuScope oldWidget) =>
      !identical(oldWidget.holder, holder) ||
      oldWidget.horizontal != horizontal ||
      !identical(oldWidget.passThrough, passThrough);
}

/// Where an anchored control's rect comes from.
///
/// The `ComboBoxAnchor` idiom, and public for the same reason that one is: the
/// render object registers itself here when it is created, and the rect is read
/// at the moment the menu opens, off the current frame's ancestor offsets.
/// Computing it any earlier anchors the menu to where the control used to be.
final class MenuAnchorBox {
  RenderBox? render;

  Rect? get globalRect {
    final RenderBox? box = render;
    if (box == null || !box.hasSize) return null;
    final Offset topLeft = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      box.size.width,
      box.size.height,
    );
  }
}

// ---------------------------------------------------------------------------
// The half of MenuAnchor and SubmenuButton that is the same
// ---------------------------------------------------------------------------

/// Owning a popup, opening it against a measured rect, and reporting the two
/// ends of its lifetime exactly once each.
mixin _AnchoredMenu<T extends StatefulWidget> on State<T>
    implements _MenuAnchorDelegate {
  final MenuAnchorBox anchorBox = MenuAnchorBox();
  final _HandleHolder holder = _HandleHolder();

  /// The host, captured while building.
  ///
  /// Captured rather than looked up at open time because [PopupHost.of]
  /// registers an inherited dependency, and registering one from inside a
  /// pointer callback subscribes an element to a widget it was not building
  /// against - which is the kind of dependency that survives until something
  /// unrelated rebuilds and then fires at a moment nobody can trace.
  PopupHost? _host;

  /// The ambient [Theme] widget, captured for the same reason and re-published
  /// inside the popup - whose content is built under the host's layer and would
  /// otherwise fall back to whatever theme sits above the whole window, so a
  /// menu opened from a dark panel would come up light.
  Theme? _ambientTheme;

  bool _disposed = false;

  MenuController get effectiveController;

  PopupKind get menuPopupKind;

  /// The window region this chain's popups must not take the pointer from,
  /// or null when the chain is modal everywhere. See [_MenuScope.passThrough];
  /// only a [MenuBar]'s chain answers non-null.
  Rect? Function()? get menuPassThrough => null;

  PopupAnchorPoint get menuAnchorPoint;

  PopupAnchorPoint get menuPopupPoint;

  Offset get menuOffset;

  /// The popup this one opens *from*, or null for a menu anchored in the
  /// window's own tree.
  PopupHandle? resolveParentHandle(PopupHost host);

  void handleMenuOpened();

  void handleMenuClosed();

  Widget buildMenuPopup(BuildContext context);

  @override
  bool get isMenuOpen => holder.handle?.isOpen ?? false;

  /// Re-reads the ambient host and theme. Called from `build`.
  void captureAmbient(BuildContext context) {
    _host = PopupHost.maybeOf(context);
    _ambientTheme = Theme.maybeOf(context);
  }

  @override
  void openMenu({Offset? position}) {
    if (isMenuOpen) return;
    final PopupHost? host = _host;
    if (host == null) {
      throw StateError(
        'A menu was opened with no PopupHost in the tree.\n'
        'Menus need a host to open into. DartUiApp installs one, so an '
        'application built with runApp already has it; a test that mounts a '
        'bare widget tree wraps it in a PopupScope.',
      );
    }
    final Rect anchor = anchorBox.globalRect ?? const Rect.fromLTWH(0, 0, 0, 0);
    final Rect target = position == null
        ? anchor
        : Rect.fromLTWH(
            anchor.left + position.dx, anchor.top + position.dy, 0, 0);
    holder.handle = host.open(PopupSpec(
      anchorRect: target,
      kind: menuPopupKind,
      anchorPoint: menuAnchorPoint,
      popupPoint: menuPopupPoint,
      offset: position == null ? menuOffset : Offset.zero,
      parent: resolveParentHandle(host),
      passThrough: menuPassThrough,
      builder: buildMenuPopup,
      onDismiss: _onDismissed,
    ));
    handleMenuOpened();
    effectiveController._notify();
    if (mounted) setState(() {});
  }

  @override
  void closeMenu() => holder.handle?.close();

  /// Tells an open popup that its content changed.
  ///
  /// The builder closes over this `State`, so it always reads the current
  /// `widget.menuChildren` - but nothing rebuilds the popup on its own, and a
  /// menu whose items were replaced while it was showing would keep showing the
  /// old ones until something unrelated dirtied the layer.
  void refreshMenu() {
    if (isMenuOpen) holder.handle!.markNeedsBuild();
  }

  /// Wraps popup content in the theme captured at the anchor.
  ///
  /// The captured [Theme] *widget* is reused whole rather than rebuilt from its
  /// [ThemeData], so its styles, resources and templates keep their identity:
  /// [Theme.updateShouldNotify] compares those three by reference, and a fresh
  /// set per build would tell every descendant the theme had changed on every
  /// frame the popup redrew.
  Widget themed(Widget child) {
    final Theme? ambient = _ambientTheme;
    if (ambient == null) return child;
    return Theme(
      data: ambient.data,
      styles: ambient.styles,
      resources: ambient.resources,
      templates: ambient.templates,
      child: child,
    );
  }

  void _onDismissed() {
    holder.handle = null;
    handleMenuClosed();
    effectiveController._notify();
    // A dismissal arriving while this state is torn down is the ordinary case -
    // the anchor left the tree and closed its own popup on the way out - and
    // setState on a disposed state throws.
    if (!_disposed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    // The popup would otherwise outlive this widget: it is mounted under the
    // host's layer, not under this element, so nothing else would take it down.
    holder.handle?.close();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// MenuAnchor
// ---------------------------------------------------------------------------

/// Shows [menuChildren] in a popup anchored to itself.
///
/// Flutter's [MenuAnchor], with Flutter's arguments. What differs:
///
///   * `style`, `clipBehavior`, `childFocusNode`, `crossAxisUnconstrained`,
///     `useRootOverlay` and the animation arguments are absent. Most name
///     Material types this framework does not have; `useRootOverlay` names a
///     choice [PopupHost] already makes once for the whole window;
///   * [consumeOutsideTap] defaults to **true** here and false in Flutter. The
///     default that closes a menu *and* presses the button behind it is the one
///     users report as a bug, and this framework already spells the distinction
///     as [PopupKind.dismissalPassesThrough].
final class MenuAnchor extends StatefulWidget {
  const MenuAnchor({
    super.key,
    this.controller,
    required this.menuChildren,
    this.builder,
    this.child,
    this.alignmentOffset = Offset.zero,
    this.onOpen,
    this.onClose,
    this.consumeOutsideTap = true,
  });

  /// An optional controller, so something other than [builder]'s widget can
  /// open and close this menu.
  final MenuController? controller;

  /// The menu itself: usually [MenuItemButton]s and [SubmenuButton]s.
  final List<Widget> menuChildren;

  /// Builds the widget the menu hangs off, handed the controller so it can open
  /// it. [child] is passed through as the third argument, for the part of the
  /// anchor that does not depend on whether the menu is showing.
  final Widget Function(BuildContext, MenuController, Widget?)? builder;

  /// The anchor, when [builder] is null; [builder]'s third argument when it is
  /// not.
  final Widget? child;

  /// A nudge applied after the menu is attached to the anchor's bottom-left.
  final Offset alignmentOffset;

  final void Function()? onOpen;

  final void Function()? onClose;

  /// Whether the press that dismisses this menu is swallowed.
  ///
  /// True - the default here - means it does not also reach whatever was under
  /// it. See [PopupKind.dismissalPassesThrough]: the user aimed at "not the
  /// menu", and pressing the button they happened to dismiss over is not what
  /// they asked for.
  final bool consumeOutsideTap;

  @override
  State<MenuAnchor> createState() => _MenuAnchorState();
}

final class _MenuAnchorState extends State<MenuAnchor>
    with _AnchoredMenu<MenuAnchor> {
  MenuController? _owned;

  @override
  MenuController get effectiveController =>
      widget.controller ?? (_owned ??= MenuController());

  @override
  PopupKind get menuPopupKind =>
      widget.consumeOutsideTap ? PopupKind.menu : PopupKind.dropdown;

  @override
  PopupAnchorPoint get menuAnchorPoint => PopupAnchorPoint.bottomLeft;

  @override
  PopupAnchorPoint get menuPopupPoint => PopupAnchorPoint.topLeft;

  @override
  Offset get menuOffset => widget.alignmentOffset;

  /// Always null: a [MenuAnchor] is anchored in the window's own tree, so its
  /// menu is the root of a chain rather than a link in somebody else's.
  /// Reading [PopupHost.topmost] here - which is what [SubmenuButton] correctly
  /// does - would make this menu a child of whatever unrelated popup happened
  /// to be showing, and dismissing that one would take this menu with it.
  @override
  PopupHandle? resolveParentHandle(PopupHost host) => null;

  @override
  void handleMenuOpened() => widget.onOpen?.call();

  @override
  void handleMenuClosed() => widget.onClose?.call();

  @override
  void initState() {
    super.initState();
    effectiveController._attach(this);
  }

  @override
  void didUpdateWidget(MenuAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      effectiveController._attach(this);
    }
    if (!identical(oldWidget.menuChildren, widget.menuChildren)) refreshMenu();
  }

  @override
  void dispose() {
    effectiveController._detach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    captureAmbient(context);
    final Widget? built = widget.builder == null
        ? widget.child
        : widget.builder!(context, effectiveController, widget.child);
    return _AnchorProbe(
      anchor: anchorBox,
      // A MenuAnchor with neither a builder nor a child is legal in Flutter and
      // means "an anchor with no visible part that a controller can still open
      // against" - a context menu attached to a region, for instance.
      child: built ?? const SizedBox(width: 0, height: 0),
    );
  }

  @override
  Widget buildMenuPopup(BuildContext context) => _MenuScope(
        holder: holder,
        horizontal: false,
        // A standalone anchor has no strip to protect, so its chain is modal
        // everywhere - which is what makes the press that closes it stop there.
        passThrough: null,
        child: themed(_MenuPanel(
          horizontal: false,
          decorated: true,
          autofocus: true,
          onDismiss: closeMenu,
          children: widget.menuChildren,
        )),
      );
}

/// Measures the anchor without changing it.
///
/// A pass-through box rather than a hook on the anchor's own render object,
/// because the anchor is whatever the application handed to [MenuAnchor.child]
/// and this framework does not get to demand an interface of it.
final class _AnchorProbe extends SingleChildRenderObjectWidget {
  const _AnchorProbe({required this.anchor, required super.child});

  final MenuAnchorBox anchor;

  @override
  _RenderAnchorProbe createRenderObject(BuildContext context) =>
      _RenderAnchorProbe(anchor: anchor);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderAnchorProbe object,
  ) =>
      object.anchor = anchor;
}

final class _RenderAnchorProbe extends RenderSingleChildBox {
  _RenderAnchorProbe({required MenuAnchorBox anchor}) : _anchor = anchor {
    anchor.render = this;
  }

  MenuAnchorBox _anchor;

  set anchor(MenuAnchorBox value) {
    if (identical(value, _anchor)) return;
    if (identical(_anchor.render, this)) _anchor.render = null;
    _anchor = value;
    value.render = this;
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(Size.zero);
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    child.parentData!.offset = Offset.zero;
    size = child.size;
  }

  @override
  void detach() {
    // Otherwise the box keeps pointing at a render object that is no longer in
    // any tree, and `globalRect` walks a detached ancestor chain to produce a
    // coordinate in no space at all.
    if (identical(_anchor.render, this)) _anchor.render = null;
    super.detach();
  }
}

// ---------------------------------------------------------------------------
// The panel: the surface a menu's children are laid out on
// ---------------------------------------------------------------------------

/// A menu's own surface: a column of rows in a popup, or the horizontal strip a
/// [MenuBar] draws in the window.
///
/// One widget for both because everything that makes a menu a menu - the
/// keyboard cursor, the arrow keys, which row is highlighted, closing a sibling
/// submenu when the cursor moves off it - is the same in both directions, and
/// two implementations of it would be two chances to get "hovering a sibling
/// switches menus" right.
final class _MenuPanel extends StatefulWidget {
  const _MenuPanel({
    required this.children,
    required this.horizontal,
    required this.decorated,
    required this.autofocus,
    this.focusNode,
    this.onDismiss,
    this.onArrowLeftEscape,
    this.onArrowRightEscape,
  });

  final List<Widget> children;

  /// Left to right rather than top to bottom. A menu bar's strip.
  final bool horizontal;

  /// Whether to paint the raised surface, radius and hairline of a popup.
  ///
  /// False for a menu bar, which is part of the window's own chrome: a bar that
  /// drew a floating panel behind itself would look like a menu that never
  /// closed.
  final bool decorated;

  /// Whether this panel takes the keyboard as soon as it is mounted. True for a
  /// popup, false for a bar - a menu bar sitting in a window must not steal the
  /// keyboard from the document the moment the window opens.
  final bool autofocus;

  /// A node supplied from outside, so the owner can hand the keyboard back to
  /// this panel later. [MenuBar] passes one; a popup owns its own.
  final FocusNode? focusNode;

  /// Escape, and an assistive client's `dismiss`.
  final void Function()? onDismiss;

  /// Left pressed when the highlighted row had no use for it.
  ///
  /// In a submenu that means "go back to the parent"; in a menu bar's dropdown
  /// it means "the previous top-level menu". The panel does not know which of
  /// those it is in, and deliberately: the widget that opened it does.
  final void Function()? onArrowLeftEscape;

  /// Right pressed when the highlighted row is not a submenu.
  final void Function()? onArrowRightEscape;

  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

final class _MenuPanelState extends State<_MenuPanel> {
  FocusNode? _owned;
  FocusNode? _restoreTo;

  /// Tab must not walk into a menu, and Tab pressed while one is up should move
  /// to the next control - which takes the keyboard away, which is what closes
  /// the menu. Both fall out of staying out of the traversal ring.
  FocusNode get _node =>
      widget.focusNode ??
      (_owned ??= FocusNode(debugLabel: 'MenuPanel', skipTraversal: true));

  @override
  Widget build(BuildContext context) {
    _attachFocus(context);
    return _MenuPanelRenderWidget(
      theme: Theme.of(context),
      focusNode: _node,
      horizontal: widget.horizontal,
      decorated: widget.decorated,
      onDismiss: widget.onDismiss,
      onArrowLeftEscape: widget.onArrowLeftEscape,
      onArrowRightEscape: widget.onArrowRightEscape,
      children: widget.children,
    );
  }

  /// Joins the enclosing scope and, for a popup, takes the keyboard - once.
  ///
  /// The request happens here in `build`, and therefore before the render object
  /// that will receive the keys exists. That is not a race: [FocusNode.target]
  /// re-points the router when the render object adopts the node a moment later,
  /// which is precisely what that setter is for.
  void _attachFocus(BuildContext context) {
    final FocusNode node = _node;
    if (node.parent != null) return;
    final FocusScopeNode? scope =
        FocusScope.of(context) ?? _ownerRootScope(context);
    if (scope == null) return;
    _restoreTo = scope.manager?.primaryFocus;
    scope.add(node);
    if (widget.autofocus) node.requestFocus();
  }

  FocusScopeNode? _ownerRootScope(BuildContext context) {
    final Element? element = context is Element ? context : null;
    return element?.owner?.focusManager.rootScope;
  }

  /// Unlike `ContextMenu`, a panel does **not** dismiss itself when it loses
  /// focus. It cannot: opening a submenu moves the keyboard into the submenu's
  /// panel, so a parent that treated focus loss as a dismissal would close the
  /// menu the user just descended into and take the submenu with it. Light
  /// dismiss and Escape already cover every case that rule was there for.
  @override
  void dispose() {
    final FocusNode node = _node;
    // Only give the keyboard back if this panel still holds it. When one menu
    // replaces another - Left and Right across a menu bar - the replacement has
    // often already taken focus by the time this one is torn down, and
    // restoring here would yank the keyboard back out of it.
    final bool held = node.hasPrimaryFocus;
    final FocusNode? restoreTo = _restoreTo;
    _restoreTo = null;
    _owned?.dispose();
    _owned = null;
    if (held &&
        restoreTo != null &&
        restoreTo.parent != null &&
        restoreTo.canRequestFocus) {
      restoreTo.requestFocus(FocusChangeReason.restoration);
    }
    super.dispose();
  }
}

final class _MenuPanelRenderWidget extends MultiChildRenderObjectWidget {
  const _MenuPanelRenderWidget({
    required this.theme,
    required this.focusNode,
    required this.horizontal,
    required this.decorated,
    required this.onDismiss,
    required this.onArrowLeftEscape,
    required this.onArrowRightEscape,
    required super.children,
  });

  final ThemeData theme;
  final FocusNode focusNode;
  final bool horizontal;
  final bool decorated;
  final void Function()? onDismiss;
  final void Function()? onArrowLeftEscape;
  final void Function()? onArrowRightEscape;

  @override
  RenderMenuPanel createRenderObject(BuildContext context) => RenderMenuPanel(
        horizontal: horizontal,
        decorated: decorated,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..onDismiss = onDismiss
        ..onArrowLeftEscape = onArrowLeftEscape
        ..onArrowRightEscape = onArrowRightEscape;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderMenuPanel object,
  ) {
    object
      ..horizontal = horizontal
      ..decorated = decorated
      ..theme = theme
      ..focusNode = focusNode
      ..onDismiss = onDismiss
      ..onArrowLeftEscape = onArrowLeftEscape
      ..onArrowRightEscape = onArrowRightEscape;
  }
}

/// The frame, the row layout, and the keyboard for one menu.
final class RenderMenuPanel extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  RenderMenuPanel({required bool horizontal, required bool decorated})
      : _horizontal = horizontal,
        _decorated = decorated;

  bool _horizontal;
  bool _decorated;
  int _highlighted = -1;

  void Function()? onDismiss;
  void Function()? onArrowLeftEscape;
  void Function()? onArrowRightEscape;

  bool get horizontal => _horizontal;

  set horizontal(bool value) {
    if (value == _horizontal) return;
    _horizontal = value;
    markNeedsLayout();
  }

  bool get decorated => _decorated;

  set decorated(bool value) {
    if (value == _decorated) return;
    _decorated = value;
    markNeedsLayout();
  }

  /// The air above the first row and below the last, inside a popup's frame.
  double get verticalPadding => _decorated ? 4 : 0;

  /// The row the keyboard cursor is on, or -1.
  ///
  /// -1 on opening, deliberately: a menu that pre-selected its first row would
  /// have Enter run a command the user never looked at.
  int get highlightedIndex => _highlighted;

  MenuRowBehavior? get highlightedRow => _rowAt(_highlighted);

  MenuRowBehavior? _rowAt(int index) {
    if (index < 0 || index >= childCount) return null;
    final RenderBox child = childAt(index);
    return child is MenuRowBehavior ? child : null;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void insert(RenderBox child, {required int index}) {
    super.insert(child, index: index);
    if (child is MenuRowBehavior) child.panel = this;
  }

  @override
  void remove(RenderBox child) {
    if (child is MenuRowBehavior) child.panel = null;
    super.remove(child);
    if (_highlighted >= childCount) _highlighted = childCount - 1;
  }

  @override
  void removeAll() {
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      if (child is MenuRowBehavior) child.panel = null;
    }
    super.removeAll();
    _highlighted = -1;
  }

  // -------------------------------------------------------------------------
  // Layout
  // -------------------------------------------------------------------------

  @override
  void performLayout() {
    final double maxWidth =
        constraints.hasBoundedWidth ? constraints.maxWidth : _unbounded;
    final double maxHeight =
        constraints.hasBoundedHeight ? constraints.maxHeight : _unbounded;
    if (_horizontal) {
      _layoutStrip(maxWidth, maxHeight);
    } else {
      _layoutColumn(maxWidth, maxHeight);
    }
  }

  /// A column, laid out twice on purpose.
  ///
  /// Every row is as wide as the widest one, and no row can be asked for its
  /// final width until that maximum is known. The first pass is loose and is
  /// what measures; the second is tight and is what places. Intrinsics would
  /// answer the same question in one pass, but a menu's children are arbitrary
  /// widgets and a widget that has not implemented `computeMaxIntrinsicWidth`
  /// answers zero - which is a menu one pixel wide, not a slower one.
  void _layoutColumn(double maxWidth, double maxHeight) {
    final BoxConstraints loose =
        BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight);
    double width = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(loose, parentUsesSize: true);
      if (child.size.width > width) width = child.size.width;
    }
    width = width.clamp(constraints.minWidth, maxWidth);

    double y = verticalPadding;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(
        BoxConstraints(
          minWidth: width,
          maxWidth: width,
          maxHeight: maxHeight,
        ),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(0, y);
      y += child.size.height;
    }
    size = constraints.constrain(Size(width, y + verticalPadding));
  }

  /// A strip: each row as wide as it wants, all of them as tall as the tallest.
  void _layoutStrip(double maxWidth, double maxHeight) {
    final BoxConstraints loose =
        BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight);
    double height = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(loose, parentUsesSize: true);
      if (child.size.height > height) height = child.size.height;
    }
    double x = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.parentData!.offset =
          Offset(x, ((height - child.size.height) / 2).roundToDouble());
      x += child.size.width;
    }
    size = constraints.constrain(Size(x, height));
  }

  // -------------------------------------------------------------------------
  // Pointer
  // -------------------------------------------------------------------------

  /// Solid to the pointer while it is a popup, so a press on the frame or the
  /// padding does nothing rather than falling through and dismissing. A bar is
  /// window chrome and has no frame of its own to defend.
  @override
  bool hitTestSelf(Offset position) => _decorated;

  /// Deliberately inert.
  ///
  /// [ControlBehavior]'s press-and-release path is *not* run here: rows own
  /// their own clicks, and this panel is on the same hit path as the row under
  /// the pointer, so leaving the inherited behaviour in place would activate
  /// the highlighted command twice - once through the row and once through
  /// this. Swallowing is also what makes a press on the frame do nothing.
  @override
  void handlePointerEvent(PointerEvent event) {}

  /// Moves the keyboard into this panel, for a row that was pressed.
  ///
  /// Rows own no focus node - see the library comment - so nothing else would
  /// bring the keyboard here, and a menu bar clicked with the mouse would then
  /// ignore the arrow keys.
  void takeKeyboard() => focusNode?.requestFocus(FocusChangeReason.pointer);

  /// Puts the cursor on [row], which is how a hovering pointer and the arrow
  /// keys stay in agreement about where it is.
  ///
  /// [fromHover] is what separates the two gestures that both land here. A
  /// pointer arriving on a submenu row inside a menu opens it; a *press* on the
  /// same row must not, because the press is also about to be seen by the popup
  /// layer, which will dismiss what a press outside a popup dismisses -
  /// including a submenu opened microseconds earlier by this very call.
  void highlightRow(MenuRowBehavior row, {required bool fromHover}) {
    for (int i = 0; i < childCount; i++) {
      if (!identical(childAt(i), row)) continue;
      _setHighlighted(
        i,
        // Inside a menu a hover opens the submenu it lands on. In a bar it only
        // switches: the bar is not "active" until something opened it, and a
        // menu bar that dropped a menu at every passing pointer would be
        // unusable.
        opensSubmenu: _horizontal ? _submenuIsOpen : fromHover,
      );
      return;
    }
  }

  bool get _submenuIsOpen => highlightedRow?.isSubmenuOpen ?? false;

  /// Left or Right arrived in a dropdown this strip opened, and the dropdown
  /// had no use for it.
  ///
  /// Only a horizontal strip answers: in a vertical menu those keys mean
  /// "into the submenu" and "back to the parent", and the row that handed them
  /// here has already dealt with both. [_move] carries the open menu along
  /// because a menu *is* showing - that is the only way this call happens.
  void moveAcrossStrip(int delta) {
    if (!_horizontal) return;
    _move(delta);
  }

  void _setHighlighted(int index, {required bool opensSubmenu}) {
    if (index == _highlighted) return;
    final MenuRowBehavior? previous = highlightedRow;
    // Closed *before* the new one opens, and the order is load-bearing: a
    // submenu asks [PopupHost.topmost] for its parent, and while the old
    // submenu is still on the stack the answer is the old submenu rather than
    // this panel's popup. The chain would then hang off the wrong link -
    // closing the real parent would leave an orphan open, and a click in the
    // real parent would not close it.
    if (previous != null && previous.isSubmenuOpen) previous.closeSubmenu();
    previous?.isHighlighted = false;
    _highlighted = index;
    final MenuRowBehavior? next = highlightedRow;
    next?.isHighlighted = true;
    if (opensSubmenu) next?.openSubmenu();
    markNeedsPaint();
  }

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyEscape:
        final void Function()? dismiss = onDismiss;
        if (dismiss == null) return false;
        dismiss();
        return true;
      case logicalKeyHome:
        _move(1, from: -1);
        return true;
      case logicalKeyEnd:
        _move(-1, from: childCount);
        return true;
      case logicalKeyArrowDown:
        if (!_horizontal) {
          _move(1);
          return true;
        }
        // Down on a menu bar drops the highlighted menu, which is what every
        // desktop does and the only way into a bar's menus without the mouse.
        if (_highlighted < 0) _move(1, from: -1);
        return _openHighlighted();
      case logicalKeyArrowUp:
        if (_horizontal) return false;
        _move(-1);
        return true;
      case logicalKeyArrowRight:
        if (_horizontal) {
          _move(1);
          return true;
        }
        if (_openHighlighted()) return true;
        return _escape(onArrowRightEscape);
      case logicalKeyArrowLeft:
        if (_horizontal) {
          _move(-1);
          return true;
        }
        return _escape(onArrowLeftEscape);
    }
    // Space and Enter, through the one activation path every control shares.
    return super.handleKeyEvent(event);
  }

  bool _escape(void Function()? callback) {
    if (callback == null) return false;
    callback();
    return true;
  }

  bool _openHighlighted() {
    final MenuRowBehavior? row = highlightedRow;
    if (row == null || !row.opensSubmenu) return false;
    if (!row.isSubmenuOpen) row.openSubmenu();
    return true;
  }

  @override
  void activate() => highlightedRow?.activateRow();

  /// Moves the cursor by [delta], wrapping, skipping anything that is not an
  /// enabled row.
  ///
  /// A separator or a disabled command is reachable by hover and by an
  /// assistive client - a disabled command is information, and dimming tells a
  /// screen reader nothing - but the arrow keys walk past it, because the arrows
  /// are how a user gets *to* something they can choose.
  void _move(int delta, {int? from}) {
    if (childCount == 0) return;
    final int start = from ?? _highlighted;
    int index = start < 0 ? (delta > 0 ? -1 : childCount) : start;
    // Whether a menu is showing right now decides whether walking the bar drags
    // it along; read before the highlight moves, because moving it closes the
    // one that was open.
    final bool cascade = _horizontal && _submenuIsOpen;
    for (int step = 0; step < childCount; step++) {
      index = (index + delta) % childCount;
      if (index < 0) index += childCount;
      final MenuRowBehavior? row = _rowAt(index);
      if (row == null || !row.enabled) continue;
      _setHighlighted(index, opensSubmenu: cascade);
      return;
    }
  }

  // -------------------------------------------------------------------------
  // Painting and semantics
  // -------------------------------------------------------------------------

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    if (_decorated) {
      // A popup floats above the window, so it takes the raised surface, the
      // large radius and a single hairline - the same treatment `RenderMenu`
      // and `RenderContextMenuSurface` paint, so a menu looks the same however
      // it was built.
      final double radius = theme.cornerRadiusLarge;
      paintRoundedFill(list, rect, theme.surfaceRaised, radius);
      paintRoundedBorder(list, rect, theme.border, radius);
      super.paint(list, offset);
      paintFocusRing(list, rect, radius: radius);
      return;
    }
    super.paint(list, offset);
  }

  @override
  bool performSemanticsAction(SemanticsAction action, {String? value}) {
    if (!enabled) return false;
    switch (action) {
      case SemanticsAction.dismiss:
        final void Function()? dismiss = onDismiss;
        if (dismiss == null) return false;
        dismiss();
        return true;
      case SemanticsAction.activate:
        // Refused rather than reported as done when the cursor is nowhere, or
        // on something that cannot be chosen.
        final MenuRowBehavior? row = highlightedRow;
        if (row == null || !row.enabled) return false;
        return super.performSemanticsAction(action, value: value);
      default:
        return super.performSemanticsAction(action, value: value);
    }
  }

  @override
  SemanticsConfiguration describeSemantics() {
    int rows = 0;
    for (int i = 0; i < childCount; i++) {
      if (childAt(i) is MenuRowBehavior) rows++;
    }
    return SemanticsConfiguration(
      role: SemanticsRole.menu,
      value: '$rows items',
      states: <SemanticsState>{
        // A popup menu holds the pointer, so what is behind it is not reachable
        // by a mouse or by an assistive client. A menu bar is ordinary window
        // chrome and claims neither.
        if (_decorated) SemanticsState.modal,
        if (hasFocus) SemanticsState.focused,
      },
      actions: <SemanticsAction>{
        SemanticsAction.focus,
        if (onDismiss != null) SemanticsAction.dismiss,
      },
      isBlocking: _decorated,
    );
  }
}

/// A finite stand-in for an unbounded axis.
///
/// A menu laid out under infinite constraints would measure a label at infinity
/// and produce a NaN somewhere downstream. No real menu is wider or taller than
/// this, and a popup host always passes bounded constraints anyway - this is
/// only what a bare mount gets.
const double _unbounded = 4096;

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

/// What a [RenderMenuPanel] needs of the things it lays out.
///
/// A mixin rather than an interface because every one of these is also a
/// [ControlBehavior], and the highlight, the panel back-pointer and the hover
/// wiring are the same code in both rows.
mixin MenuRowBehavior on ControlBehavior {
  /// The panel this row belongs to, set when it is adopted and cleared when it
  /// is removed. Null while the row is between parents.
  RenderMenuPanel? panel;

  bool _highlighted = false;

  /// Whether the keyboard cursor is on this row.
  bool get isHighlighted => _highlighted;

  set isHighlighted(bool value) {
    if (value == _highlighted) return;
    _highlighted = value;
    markNeedsPaint();
  }

  /// Whether this row has a submenu at all. False for a command.
  bool get opensSubmenu => false;

  bool get isSubmenuOpen => false;

  void openSubmenu() {}

  void closeSubmenu() {}

  /// Whether hovering moves the panel's keyboard cursor here.
  bool get followsHover => true;

  /// What choosing this row means. Separate from [ControlBehavior.activate] so
  /// the panel can drive a row it is not the pointer target of - Enter on the
  /// highlighted row, or an assistive client's invoke on the menu.
  void activateRow();

  @override
  void activate() => activateRow();

  /// A row never takes the keyboard; the panel holds it for the whole menu,
  /// which is what keeps arrow navigation in one place.
  @override
  bool get focusOnPointerDown => false;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (event is PointerDownEvent) {
      panel
        ?..takeKeyboard()
        ..highlightRow(this, fromHover: false);
      return;
    }
    // Hover moves the keyboard cursor too. Two cursors - one the mouse drives
    // and one the arrows drive - is how a user presses Enter and gets the
    // command their pointer is not on.
    if (event is PointerMoveEvent && followsHover) {
      panel?.highlightRow(this, fromHover: true);
    }
  }

  /// `focus` on a row is the keyboard cursor moving onto it, which is what the
  /// row publishes as its focused state. `activate` goes through [activateRow],
  /// and a disabled row answers false rather than a success that did nothing.
  @override
  bool performSemanticsAction(SemanticsAction action, {String? value}) {
    switch (action) {
      case SemanticsAction.focus:
        final RenderMenuPanel? owner = panel;
        if (owner == null) return false;
        owner.highlightRow(this, fromHover: false);
        return true;
      case SemanticsAction.activate:
        if (!enabled) return false;
        return super.performSemanticsAction(action, value: value);
      default:
        return super.performSemanticsAction(action, value: value);
    }
  }

  /// The row's label, gathered from whatever text its children draw.
  ///
  /// A [MenuItemButton]'s child is an arbitrary widget, so there is no string to
  /// read off the widget the way `MenuItem.label` gives one. Walking for the
  /// text that is actually painted is the only answer that cannot disagree with
  /// what the user sees, and it is why the row merges its descendants: the text
  /// belongs *to* the menu item, not beside it.
  String? get rowLabel {
    final StringBuffer buffer = StringBuffer();
    void walk(RenderBox node) {
      if (node is RenderText && node.text.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(node.text);
      }
      node.visitChildren(walk);
    }

    visitChildren(walk);
    return buffer.isEmpty ? null : buffer.toString();
  }

  /// The pill behind the row the cursor is on.
  ///
  /// `RenderMenu`'s treatment - the subtle accent, inset from the popup's edge -
  /// rather than `RenderContextMenuItem`'s filled primary. The filled one
  /// repaints its label in `onPrimary`, and this row's label is a widget whose
  /// colour this render object does not own; a subtle ground keeps whatever
  /// colour that widget chose readable, which a saturated one would not.
  void paintRowHighlight(DisplayList list, Rect rect) {
    if (!_highlighted) return;
    paintRoundedFill(
      list,
      Rect.fromLTWH(
        rect.left + _highlightInset,
        rect.top + 1,
        rect.width - _highlightInset * 2,
        rect.height - 2,
      ),
      theme.accentSubtle,
      theme.cornerRadiusSmall,
    );
  }

  /// A highlight that ran edge to edge inside a rounded popup would cut its own
  /// corners off; inset by this it is a pill sitting inside the menu, which is
  /// the shape every current desktop draws.
  static const double _highlightInset = 4;
}

// ---------------------------------------------------------------------------
// MenuItemButton
// ---------------------------------------------------------------------------

/// One command in a menu.
///
/// Flutter's [MenuItemButton]. What differs:
///
///   * [shortcut] is a `String`, not a `MenuSerializableShortcut`. That is the
///     shape `MenuItem.shortcut` already has here, and it carries the same
///     warning: this is **display only**. It binds nothing, and writing a chord
///     here that nothing listens for produces a menu advertising a shortcut
///     that does not work;
///   * [requestFocusOnHover] moves the keyboard *cursor*, not focus - see the
///     library comment;
///   * `closeOnActivate` is absent, and activation always closes the chain.
///     Flutter's flag exists for menus that stay up while a checkbox item is
///     toggled; that is worth adding when something needs it, and defaulting to
///     the other behaviour in the meantime would be the surprising half.
final class MenuItemButton extends StatelessWidget {
  const MenuItemButton({
    super.key,
    this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    this.shortcut,
    this.requestFocusOnHover = true,
    required this.child,
  });

  /// What choosing this command does. **Null disables the item**, which is
  /// Flutter's convention and already this framework's - a [Button] with no
  /// `onPressed` is disabled for the same reason.
  final void Function()? onPressed;

  final Widget? leadingIcon;

  final Widget? trailingIcon;

  /// The accelerator drawn at the right of the row, as text: `Ctrl+C`.
  final String? shortcut;

  /// Whether hovering moves the keyboard cursor onto this row.
  final bool requestFocusOnHover;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final _MenuScope? scope = _MenuScope.maybeOf(context);
    final bool enabled = onPressed != null;
    // The row's own colour is pushed down as a default text style rather than
    // painted: the child is an arbitrary widget and this render object cannot
    // recolour it, so a disabled item whose label stayed black would be the one
    // dimming a user cannot see.
    final TextStyle ambient =
        DefaultTextStyle.maybeOf(context) ?? theme.textTheme.bodyMedium;
    return _MenuItemButtonWidget(
      theme: theme,
      shortcut: shortcut,
      enabled: enabled,
      requestFocusOnHover: requestFocusOnHover,
      hasLeading: leadingIcon != null,
      hasTrailing: trailingIcon != null,
      onActivate: () {
        // Closed first, then run. A command that opens a dialog - or another
        // menu - must not have it torn down by the dismissal of the menu it
        // came from, which is the order `ContextMenu` settled on for the same
        // reason.
        scope?.holder.closeChain();
        onPressed?.call();
      },
      children: <Widget>[
        if (leadingIcon != null) leadingIcon!,
        DefaultTextStyle(
          style: ambient.copyWith(
            color: enabled ? theme.foreground : theme.disabledForeground,
          ),
          child: child,
        ),
        if (trailingIcon != null) trailingIcon!,
      ],
    );
  }
}

final class _MenuItemButtonWidget extends MultiChildRenderObjectWidget {
  const _MenuItemButtonWidget({
    required this.theme,
    required this.shortcut,
    required this.enabled,
    required this.requestFocusOnHover,
    required this.hasLeading,
    required this.hasTrailing,
    required this.onActivate,
    required super.children,
  });

  final ThemeData theme;
  final String? shortcut;
  final bool enabled;
  final bool requestFocusOnHover;
  final bool hasLeading;
  final bool hasTrailing;
  final void Function() onActivate;

  @override
  RenderMenuItemButton createRenderObject(BuildContext context) =>
      RenderMenuItemButton()
        ..theme = theme
        ..shortcut = shortcut
        ..enabled = enabled
        ..requestFocusOnHover = requestFocusOnHover
        ..hasLeading = hasLeading
        ..hasTrailing = hasTrailing
        ..onActivate = onActivate;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderMenuItemButton object,
  ) {
    object
      ..theme = theme
      ..shortcut = shortcut
      ..enabled = enabled
      ..requestFocusOnHover = requestFocusOnHover
      ..hasLeading = hasLeading
      ..hasTrailing = hasTrailing
      ..onActivate = onActivate;
  }
}

/// One command row: an optional leading widget, the label, the accelerator
/// column, and an optional trailing widget.
final class RenderMenuItemButton extends RenderBoxContainer<BoxParentData>
    with ControlBehavior, MenuRowBehavior {
  String? _shortcut;
  bool hasLeading = false;
  bool hasTrailing = false;
  bool requestFocusOnHover = true;
  void Function()? onActivate;

  /// Where the accelerator's right edge sits, decided during layout so paint
  /// does not repeat the arithmetic and get a different answer.
  double _shortcutRight = 0;

  String? get shortcut => _shortcut;

  set shortcut(String? value) {
    if (value == _shortcut) return;
    _shortcut = value;
    markNeedsLayout();
  }

  @override
  bool get followsHover => requestFocusOnHover;

  @override
  void activateRow() {
    // Disabled rows are reachable, readable and inert. The refusal lives here
    // so that every route into activation - a click, Enter, an assistive
    // invoke - is refused by the same line.
    if (!enabled) return;
    onActivate?.call();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  RenderBox? get _leading => hasLeading && childCount > 0 ? childAt(0) : null;

  RenderBox? get _label {
    final int index = hasLeading ? 1 : 0;
    final int end = childCount - (hasTrailing ? 1 : 0);
    return index < end ? childAt(index) : null;
  }

  RenderBox? get _trailing =>
      hasTrailing && childCount > 0 ? childAt(childCount - 1) : null;

  double get _shortcutWidth {
    final String? text = _shortcut;
    if (text == null || text.isEmpty) return 0;
    return measureLabel(text).width;
  }

  @override
  void performLayout() {
    final double padding = theme.effectiveControlPadding;
    final double gap = theme.effectiveGap;
    final double maxWidth =
        constraints.hasBoundedWidth ? constraints.maxWidth : _unbounded;
    final double maxHeight =
        constraints.hasBoundedHeight ? constraints.maxHeight : _unbounded;
    final BoxConstraints loose =
        BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight);

    double tallest = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(loose, parentUsesSize: true);
      if (child.size.height > tallest) tallest = child.size.height;
    }

    double natural = padding * 2;
    final RenderBox? leading = _leading;
    if (leading != null) natural += leading.size.width + gap;
    natural += _label?.size.width ?? 0;
    final double shortcutWidth = _shortcutWidth;
    // The accelerator column is part of the row's width, not an overhang: a row
    // that measured its label alone would clip every shortcut it advertises.
    if (shortcutWidth > 0) natural += _shortcutGap + shortcutWidth;
    final RenderBox? trailing = _trailing;
    if (trailing != null) natural += gap + trailing.size.width;

    size = constraints.constrain(
      Size(natural, tallest > rowHeight ? tallest : rowHeight),
    );

    double x = padding;
    if (leading != null) {
      leading.parentData!.offset = Offset(x, _centre(leading));
      x += leading.size.width + gap;
    }
    final RenderBox? label = _label;
    if (label != null) label.parentData!.offset = Offset(x, _centre(label));

    double right = size.width - padding;
    if (trailing != null) {
      right -= trailing.size.width;
      trailing.parentData!.offset = Offset(right, _centre(trailing));
      right -= gap;
    }
    _shortcutRight = right;
  }

  double _centre(RenderBox child) =>
      ((size.height - child.size.height) / 2).roundToDouble();

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    paintRowHighlight(list, rect);
    super.paint(list, offset);
    final String? text = _shortcut;
    if (text == null || text.isEmpty) return;
    // Dimmer than the command: an accelerator is a reminder, not a second
    // command.
    paintLabel(
      list,
      text,
      Offset(
        offset.dx + _shortcutRight - measureLabel(text).width,
        labelTopIn(rect),
      ),
      enabled ? theme.foregroundSecondary : theme.disabledForeground,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.menuItem,
        label: rowLabel,
        value: _shortcut,
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          // The keyboard cursor, reported as focus: the panel holds the real
          // focus node, and an assistive client needs to know which row it is
          // on, not which render object owns the keyboard.
          if (isHighlighted) SemanticsState.focused,
        },
        actions: <SemanticsAction>{
          SemanticsAction.focus,
          if (enabled) SemanticsAction.activate,
        },
        mergesDescendants: true,
      );

  /// The air between the widest label and the accelerator column. Without it
  /// "Fit zoom to page" and "Shift+F4" touch, and the eye reads them as one
  /// string.
  static const double _shortcutGap = Spacing.xl;
}

// ---------------------------------------------------------------------------
// SubmenuButton
// ---------------------------------------------------------------------------

/// A row that opens a menu of its own.
///
/// Flutter's [SubmenuButton], minus the style, focus-node and animation
/// arguments. `trailingIcon` and `submenuIcon` are absent because the row draws
/// its own chevron; a submenu whose arrow the caller could remove is a submenu a
/// user cannot tell from a command.
///
/// Where it opens depends on the strip it is in, which is the whole reason
/// [_MenuScope] carries an orientation: from the bottom edge inside a
/// [MenuBar], and from the right edge inside a menu, where
/// [PopupPositioner]'s `flipX` moves it to the left near the window's edge
/// without anything here having to know how close that is.
final class SubmenuButton extends StatefulWidget {
  const SubmenuButton({
    super.key,
    required this.menuChildren,
    this.controller,
    this.leadingIcon,
    this.onOpen,
    this.onClose,
    required this.child,
  });

  final List<Widget> menuChildren;

  final MenuController? controller;

  final Widget? leadingIcon;

  final void Function()? onOpen;

  final void Function()? onClose;

  final Widget child;

  @override
  State<SubmenuButton> createState() => _SubmenuButtonState();
}

final class _SubmenuButtonState extends State<SubmenuButton>
    with _AnchoredMenu<SubmenuButton> {
  MenuController? _owned;
  bool _inHorizontalStrip = false;

  /// The bar's rect, when this button lives in one - captured from the scope
  /// on every build and handed to every popup this button opens, so that the
  /// whole chain stays out of the strip's way and not just its first level.
  Rect? Function()? _passThrough;

  /// The row itself is the anchor.
  ///
  /// No measuring wrapper here, unlike [MenuAnchor]: a wrapper would sit
  /// between this button and the [RenderMenuPanel] that adopts it, and the
  /// panel identifies its rows by type. A row hidden behind a proxy is a row
  /// the panel never highlights, never arrows onto and never closes the submenu
  /// of - the whole file would look like it worked and do none of it.
  RenderSubmenuButton? get _render {
    final RenderBox? box = anchorBox.render;
    return box is RenderSubmenuButton ? box : null;
  }

  @override
  MenuController get effectiveController =>
      widget.controller ?? (_owned ??= MenuController());

  /// [PopupKind.submenu] in a menu, and deliberately [PopupKind.dropdown] in a
  /// [MenuBar]'s chain.
  ///
  /// The two kinds differ here in exactly one property that matters, and it is
  /// the one a bar cannot have: [PopupKind.dismissalPassesThrough], which
  /// decides whether [RenderPopupLayer] takes the window's content out of the
  /// pointer's reach while the popup is up. See [_MenuScope.modal] for why a
  /// bar must stay reachable and what that costs.
  @override
  PopupKind get menuPopupKind => PopupKind.submenu;

  @override
  Rect? Function()? get menuPassThrough => _passThrough;

  @override
  PopupAnchorPoint get menuAnchorPoint => _inHorizontalStrip
      ? PopupAnchorPoint.bottomLeft
      : PopupAnchorPoint.topRight;

  @override
  PopupAnchorPoint get menuPopupPoint => PopupAnchorPoint.topLeft;

  @override
  Offset get menuOffset => Offset.zero;

  /// The innermost open popup, read at the moment this submenu opens.
  ///
  /// **This is correct because a submenu is always opened from the innermost
  /// open popup, and the framework arranges for that rather than hoping.** Two
  /// rules make it true: a press inside a popup closes everything above it
  /// ([PopupStack.handleOutsideClick]), and moving the panel's cursor off a row
  /// closes that row's submenu before it opens the next
  /// ([RenderMenuPanel._setHighlighted]). By the time this runs, every popup
  /// that was above this button's own is gone, so `topmost` *is* the popup this
  /// button lives in.
  ///
  /// If it were not - if a stale sibling submenu were still on the stack - this
  /// popup would be parented to it, and both of [PopupStack]'s guarantees would
  /// invert: closing the real parent would leave this submenu open with nothing
  /// above it, and a click in the real parent would fail to close it because the
  /// stack would not consider it a descendant.
  ///
  /// Null when the button is not inside a popup at all, which is the [MenuBar]
  /// case: the bar is ordinary window content, so its dropdown is the root of a
  /// chain rather than a link in one.
  @override
  PopupHandle? resolveParentHandle(PopupHost host) => host.topmost;

  @override
  void handleMenuOpened() => widget.onOpen?.call();

  @override
  void handleMenuClosed() => widget.onClose?.call();

  @override
  void initState() {
    super.initState();
    effectiveController._attach(this);
  }

  @override
  void didUpdateWidget(SubmenuButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      effectiveController._attach(this);
    }
    if (!identical(oldWidget.menuChildren, widget.menuChildren)) refreshMenu();
  }

  @override
  void dispose() {
    effectiveController._detach(this);
    super.dispose();
  }

  /// Left in the submenu this button opened.
  ///
  /// Inside a menu that means "back to the parent", which is this popup
  /// closing. In a menu bar's dropdown it means the previous top-level menu, so
  /// the bar's own strip walks instead - which is where "Left and Right move
  /// between top-level menus while a dropdown is open" comes from.
  void _handleArrowLeft() {
    final RenderMenuPanel? owner = _render?.panel;
    if (owner != null && owner.horizontal) {
      owner.moveAcrossStrip(-1);
      return;
    }
    closeMenu();
  }

  void _handleArrowRight() {
    final RenderMenuPanel? owner = _render?.panel;
    if (owner != null && owner.horizontal) {
      owner.moveAcrossStrip(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    captureAmbient(context);
    final ThemeData theme = Theme.of(context);
    final _MenuScope? scope = _MenuScope.maybeOf(context);
    _inHorizontalStrip = scope?.horizontal ?? false;
    _passThrough = scope?.passThrough;
    final TextStyle ambient =
        DefaultTextStyle.maybeOf(context) ?? theme.textTheme.bodyMedium;
    return _SubmenuButtonWidget(
      theme: theme,
      anchor: anchorBox,
      isOpen: isMenuOpen,
      // Only a top-level button toggles. Inside a menu the row is the way
      // *into* the submenu, and a click that shut the thing the user is aiming
      // at would be the opposite of what they asked for.
      toggles: _inHorizontalStrip,
      showsChevron: !_inHorizontalStrip,
      onOpenSubmenu: openMenu,
      onCloseSubmenu: closeMenu,
      children: <Widget>[
        if (widget.leadingIcon != null) widget.leadingIcon!,
        DefaultTextStyle(
          style: ambient.copyWith(color: theme.foreground),
          child: widget.child,
        ),
      ],
    );
  }

  @override
  Widget buildMenuPopup(BuildContext context) => _MenuScope(
        holder: holder,
        horizontal: false,
        passThrough: _passThrough,
        child: themed(_MenuPanel(
          horizontal: false,
          decorated: true,
          autofocus: true,
          onDismiss: closeMenu,
          onArrowLeftEscape: _handleArrowLeft,
          onArrowRightEscape: _handleArrowRight,
          children: widget.menuChildren,
        )),
      );
}

final class _SubmenuButtonWidget extends MultiChildRenderObjectWidget {
  const _SubmenuButtonWidget({
    required this.theme,
    required this.anchor,
    required this.isOpen,
    required this.toggles,
    required this.showsChevron,
    required this.onOpenSubmenu,
    required this.onCloseSubmenu,
    required super.children,
  });

  final ThemeData theme;
  final MenuAnchorBox anchor;
  final bool isOpen;
  final bool toggles;
  final bool showsChevron;
  final void Function() onOpenSubmenu;
  final void Function() onCloseSubmenu;

  @override
  RenderSubmenuButton createRenderObject(BuildContext context) =>
      RenderSubmenuButton(anchor: anchor)
        ..theme = theme
        ..submenuIsOpen = isOpen
        ..toggles = toggles
        ..showsChevron = showsChevron
        ..onOpenSubmenu = onOpenSubmenu
        ..onCloseSubmenu = onCloseSubmenu;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSubmenuButton object,
  ) {
    object
      ..anchor = anchor
      ..theme = theme
      ..submenuIsOpen = isOpen
      ..toggles = toggles
      ..showsChevron = showsChevron
      ..onOpenSubmenu = onOpenSubmenu
      ..onCloseSubmenu = onCloseSubmenu;
  }
}

/// A row that opens a menu: the label, an optional leading widget, and the
/// chevron that says there is more.
final class RenderSubmenuButton extends RenderBoxContainer<BoxParentData>
    with ControlBehavior, MenuRowBehavior {
  RenderSubmenuButton({required MenuAnchorBox anchor}) : _anchor = anchor {
    anchor.render = this;
  }

  MenuAnchorBox _anchor;
  bool _submenuOpen = false;
  bool toggles = false;
  bool showsChevron = true;
  void Function()? onOpenSubmenu;
  void Function()? onCloseSubmenu;

  /// Whether the popup was already showing when the press arrived.
  ///
  /// Recorded on the press rather than read on the release because of dispatch
  /// order: a hit-tested event reaches this row before it reaches
  /// [RenderPopupLayer], which is the ancestor that will dismiss the popup for
  /// being pressed outside. By the time [activateRow] runs on the release, the
  /// menu this press was meant to toggle is already gone, and a button that
  /// asked "is it open?" then would reopen the menu the user just closed.
  bool _wasOpenOnPress = false;

  set anchor(MenuAnchorBox value) {
    if (identical(value, _anchor)) return;
    if (identical(_anchor.render, this)) _anchor.render = null;
    _anchor = value;
    value.render = this;
  }

  bool get submenuIsOpen => _submenuOpen;

  set submenuIsOpen(bool value) {
    if (value == _submenuOpen) return;
    _submenuOpen = value;
    markNeedsPaint();
  }

  @override
  bool get opensSubmenu => true;

  @override
  bool get isSubmenuOpen => _submenuOpen;

  @override
  void openSubmenu() => onOpenSubmenu?.call();

  @override
  void closeSubmenu() => onCloseSubmenu?.call();

  @override
  void activateRow() {
    final bool wasOpen = _wasOpenOnPress || _submenuOpen;
    _wasOpenOnPress = false;
    if (wasOpen && toggles) {
      closeSubmenu();
      return;
    }
    openSubmenu();
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) _wasOpenOnPress = _submenuOpen;
    super.handlePointerEvent(event);
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  double get _chevronExtent => showsChevron ? 12 : 0;

  @override
  void performLayout() {
    final double padding = theme.effectiveControlPadding;
    final double gap = theme.effectiveGap;
    final double maxWidth =
        constraints.hasBoundedWidth ? constraints.maxWidth : _unbounded;
    final double maxHeight =
        constraints.hasBoundedHeight ? constraints.maxHeight : _unbounded;
    final BoxConstraints loose =
        BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight);

    double natural = padding * 2;
    double tallest = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(loose, parentUsesSize: true);
      if (child.size.height > tallest) tallest = child.size.height;
      natural += child.size.width;
      if (i > 0) natural += gap;
    }
    if (showsChevron) natural += gap + _chevronExtent;

    size = constraints.constrain(
      Size(natural, tallest > rowHeight ? tallest : rowHeight),
    );

    double x = padding;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.parentData!.offset = Offset(
        x,
        ((size.height - child.size.height) / 2).roundToDouble(),
      );
      x += child.size.width + gap;
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    // An open submenu keeps its parent row lit even when the pointer has moved
    // off it and into the child menu: without it the user loses the trail back.
    if (_submenuOpen && !isHighlighted) {
      paintRoundedFill(
        list,
        Rect.fromLTWH(
            rect.left + 4, rect.top + 1, rect.width - 8, rect.height - 2),
        theme.accentSubtle,
        theme.cornerRadiusSmall,
      );
    }
    paintRowHighlight(list, rect);
    super.paint(list, offset);
    if (!showsChevron) return;
    // Two mitred strokes, not a solid triangle: the same mark `RenderComboBox`
    // draws, pointing the way the menu will appear.
    final double padding = theme.effectiveControlPadding;
    final double span = (size.height * 0.22).clamp(3.0, 5.0).roundToDouble();
    final double centreX =
        (rect.right - padding - _chevronExtent / 2).roundToDouble();
    final double centreY = (rect.top + rect.height / 2).roundToDouble();
    paintPolylineMark(
      list,
      <Offset>[
        Offset(centreX - span / 2, centreY - span),
        Offset(centreX + span / 2, centreY),
        Offset(centreX - span / 2, centreY + span),
      ],
      1.5,
      enabled ? theme.foregroundSecondary : theme.disabledForeground,
    );
  }

  /// Expand and Collapse are the two directions of one pattern, and each is
  /// declared only when it would change something: a client told an open
  /// submenu could expand, and then reading a state that did not change, would
  /// conclude the control is broken.
  @override
  bool performSemanticsAction(SemanticsAction action, {String? value}) {
    if (!enabled) return false;
    switch (action) {
      case SemanticsAction.showMenu:
        if (_submenuOpen) return false;
        openSubmenu();
        return true;
      case SemanticsAction.dismiss:
        if (!_submenuOpen) return false;
        closeSubmenu();
        return true;
      default:
        return super.performSemanticsAction(action, value: value);
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.menuItem,
        label: rowLabel,
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (isHighlighted) SemanticsState.focused,
          if (_submenuOpen) SemanticsState.expanded,
        },
        actions: <SemanticsAction>{
          SemanticsAction.focus,
          if (enabled) SemanticsAction.activate,
          if (enabled && !_submenuOpen) SemanticsAction.showMenu,
          if (enabled && _submenuOpen) SemanticsAction.dismiss,
        },
        mergesDescendants: true,
      );

  @override
  void detach() {
    if (identical(_anchor.render, this)) _anchor.render = null;
    super.detach();
  }
}

// ---------------------------------------------------------------------------
// MenuBar
// ---------------------------------------------------------------------------

/// A horizontal strip of [SubmenuButton]s: the window's menu bar.
///
/// Flutter's [MenuBar], minus `style`, `clipBehavior` and `controller`.
///
/// The behaviours that make a bar a bar all come out of [RenderMenuPanel] being
/// the same object in both orientations:
///
///   * clicking a top-level item opens its dropdown, and clicking it again
///     closes it, because the press that lands on a bar button is *outside*
///     every popup and the layer dismisses on it - see
///     [RenderSubmenuButton._wasOpenOnPress] for the half of that which is not
///     free;
///   * **once one is open, hovering a sibling switches to it** without closing
///     the bar, because the panel opens the row the cursor moves onto whenever
///     the row it moved off had a menu showing. This is the behaviour that
///     forces a bar's popups to be non-modal to the pointer - see
///     [_MenuScope.modal];
///   * Left and Right walk the strip while a dropdown is open, because the
///     dropdown's panel hands those keys back to the button that opened it;
///   * Escape closes the dropdown and the keyboard returns to the bar, because
///     the dropdown's panel restores focus to whoever held it - which is this
///     bar's node, taken when the button was pressed.
///
/// **Alt and F10 do not focus the bar.** They cannot yet: `focus.dart` defines
/// the virtual-key constants this framework interprets and has no `F10` and no
/// Alt among them, and inventing values in this file would put a second, private
/// key table beside the real one.
final class MenuBar extends StatefulWidget {
  const MenuBar({super.key, required this.children});

  /// The top-level menus, normally [SubmenuButton]s.
  final List<Widget> children;

  @override
  State<MenuBar> createState() => _MenuBarState();
}

final class _MenuBarState extends State<MenuBar> {
  /// The bar is not a popup, so this holder's handle stays null and
  /// [_HandleHolder.closeChain] is a no-op for anything directly inside the
  /// strip. A [MenuItemButton] placed straight into a bar therefore runs its
  /// command and closes nothing, which is the only honest answer: there is no
  /// chain.
  final _HandleHolder _holder = _HandleHolder();

  /// Owned here rather than by the panel so the bar keeps one identity across
  /// rebuilds: a dropdown restores the keyboard to whoever held it, and that has
  /// to still be the same node when the dropdown closes.
  late final FocusNode _focusNode = FocusNode(debugLabel: 'MenuBar');

  /// The strip's own rect, read live.
  ///
  /// This is what makes a bar's dropdown modal to the *window* and not to the
  /// bar: [PopupSpec.passThrough] carries it to [RenderPopupLayer], which then
  /// keeps the strip in the hit path while everything else is out of it. A
  /// rect captured at open time would be wrong the moment the window is
  /// resized and the bar reflows, which is why the region is a callback and
  /// why this is a live probe rather than a stored value.
  final MenuAnchorBox _barBox = MenuAnchorBox();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _MenuScope(
        holder: _holder,
        horizontal: true,
        passThrough: () => _barBox.globalRect,
        child: _AnchorProbe(
          anchor: _barBox,
          child: _MenuPanel(
            horizontal: true,
            decorated: false,
            autofocus: false,
            focusNode: _focusNode,
            children: widget.children,
          ),
        ),
      );
}
