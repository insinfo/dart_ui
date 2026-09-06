/// Where a popup's pixels go — and the seam that lets one widget work whether
/// they go into the owner's surface or into a window of the popup's own.
///
/// A desktop application shows a stream of short-lived surfaces: context
/// menus, menu-bar dropdowns, combo lists, submenus, tooltips. Each of them
/// has two halves that change for entirely different reasons:
///
///   * **what it shows** — items, keyboard handling, semantics. That is a
///     widget, and it is the same widget on every platform;
///   * **where those pixels land** — composited into the owner window's
///     display list, or presented by a separate override-redirect window that
///     may extend past the owner's bounds.
///
/// Welding the two together is the mistake this file exists to prevent, and
/// the cost of that mistake is visible: a menu near the right edge of the
/// window is *cropped* rather than flipped, because an overlay cannot leave
/// the surface it is drawn into. That is the exact defect the Flutter desktop
/// multi-window work set out to fix, and the fix is not a better overlay — it
/// is a second implementation of this interface.
///
/// ## The two implementations
///
/// [InTreePopupHost] composites into the owner's surface. It is cheap — no
/// second window, no platform round trip, no second frame — and it is bounded
/// by the owner's client area. It is also the only thing that can work on a
/// backend with no windows at all, which is why it is the fallback and not an
/// afterthought: headless and web never gain a native popup, and every widget
/// here has to keep working there.
///
/// `WindowPopupHost`, in the application layer, opens a real
/// [WindowKind.popup] window. It lives up there and not here because it needs
/// `Application` to open a window, and section 8.2 forbids `widgets` from
/// naming the application layer. The seam is what keeps that rule cheap.
///
/// ## What a widget is allowed to assume
///
/// Almost nothing, and deliberately:
///
///   * **not** that it knows where the popup ended up. [PopupHandle.placedRect]
///     is null until the popup has been placed, and on Wayland a client is
///     never told where its window is — the compositor decides and the client
///     is not entitled to ask. A widget that positioned a submenu by reading
///     the parent's screen rect would work on Windows and quietly misplace
///     every submenu under a Wayland compositor;
///   * **not** that opening one is synchronous. The in-tree host places on the
///     next layout; a window host waits for the platform. Both report through
///     the handle;
///   * **not** that the popup can leave the owner window. Ask
///     [PopupHost.escapesOwnerWindow] — the answer decides whether the work
///     area is the screen or the window, and it is the same question
///     [PopupPositioner.surfaceFor] answers per placement.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../platform/native_window.dart' show WindowKind;
import 'element.dart';
import 'overlay.dart' show WidgetBuilder;
import 'pointer_router.dart';
import 'popup.dart';
import 'widget.dart';

/// What a popup *is*, which decides its window kind, its dismissal and
/// whether it may take a click at all.
///
/// The same split [WindowKind] makes for windows, one level up: a menu and a
/// tooltip are both "a surface that floats above the owner", and every other
/// property of the two differs.
enum PopupKind {
  /// A context menu or a menu-bar dropdown. Light dismiss, takes clicks,
  /// keyboard is redirected into it while it is open.
  menu,

  /// A menu opened from a menu. Behaves as [menu]; the distinction exists
  /// because the platform cares: a Wayland `xdg_popup` whose parent is
  /// another popup is a different creation call, and clicking the parent must
  /// close only the child.
  submenu,

  /// A combo box list. Light dismiss like a menu, and the click that closes
  /// it is *delivered* to what is underneath rather than swallowed — closing
  /// a dropdown by clicking a button should press that button, which is what
  /// every desktop does and what a menu deliberately does not do.
  dropdown,

  /// A hover label. Never takes a click — the pointer must reach whatever is
  /// underneath — never takes focus, and never grabs.
  tooltip;

  /// The window kind this popup becomes when it gets a window of its own.
  WindowKind get windowKind =>
      this == PopupKind.tooltip ? WindowKind.tooltip : WindowKind.popup;

  /// Whether a click that dismisses this popup is also delivered to whatever
  /// was under the pointer.
  ///
  /// A menu swallows it: the click that closes a menu must not also press the
  /// button behind the menu, because the user was aiming at "not the menu".
  /// A dropdown does not swallow it, and a tooltip never sees a click at all.
  bool get dismissalPassesThrough =>
      this != PopupKind.menu && this != PopupKind.submenu;

  /// Whether the popup is hit-testable. False for a tooltip, which must be
  /// transparent to the pointer.
  bool get takesPointer => this != PopupKind.tooltip;

  /// Whether keyboard events aimed at the owner window are redirected into
  /// this popup while it is open.
  bool get takesKeyboard => this != PopupKind.tooltip;
}

/// Whether popups get windows of their own.
///
/// The equivalent of Avalonia's `OverlayPopups` platform option and of
/// `Popup.ShouldUseOverlayLayer` per popup: the framework picks by default and
/// an application may override, because the trade is real in both directions.
/// A window escapes the owner's bounds and costs a platform surface; an
/// overlay costs nothing and is cropped.
enum PopupPolicy {
  /// A window when the backend can provide one, an overlay otherwise. The
  /// default, and the only value most applications should ever use.
  auto,

  /// Always composite into the owner's surface. What headless and web get
  /// whatever is asked for, and what an application picks when it wants one
  /// surface for capture or recording.
  inTree,

  /// Always open a window, and fail loudly on a backend that cannot. For an
  /// application that would rather know than be silently cropped.
  window,
}

/// One popup that has been opened, and the only handle its opener keeps.
///
/// Deliberately not a widget and not a listenable: it is a *lifetime*. The
/// content is a widget, built by the builder that was handed to
/// [PopupHost.open]; this is the thing that closes it.
abstract interface class PopupHandle {
  /// Whether this popup is still open. False the instant it is dismissed, by
  /// any of the routes in [PopupHost].
  bool get isOpen;

  PopupKind get kind;

  /// The popup this one was opened from, for a submenu chain. Null for a
  /// popup opened from the window itself.
  PopupHandle? get parent;

  /// Where the popup was actually placed, in the owner window's logical
  /// space — or null when that is not yet known, or not knowable.
  ///
  /// Null in three distinct situations, which callers must not conflate:
  /// before the first layout; after the popup was dismissed; and always, on a
  /// backend where the client is not told where its own window is. A caller
  /// that needs the value has to handle null rather than assert on it.
  Rect? get placedRect;

  /// Closes this popup and every popup opened from it, deepest first.
  ///
  /// Idempotent: closing a popup that is already closed is a no-op, because
  /// the routes that dismiss a popup are several and they race — a click
  /// outside and a `popup_done` from the compositor describe the same
  /// dismissal and both arrive.
  void close();

  /// Moves the anchor, for a popup that follows something: a dropdown whose
  /// window moved, a tooltip following the pointer.
  void updateAnchor(Rect anchorRect);

  /// Rebuilds the popup's content. Called when what it shows changed but
  /// where it sits did not.
  void markNeedsBuild();
}

/// One request to open a popup.
///
/// A value object rather than a long parameter list because it crosses a layer
/// boundary: `widgets` builds it and the application layer forwards it to a
/// window. A signature would have to be repeated identically in both, and the
/// two would drift.
final class PopupSpec {
  const PopupSpec({
    required this.anchorRect,
    required this.builder,
    this.kind = PopupKind.menu,
    this.anchorPoint = PopupAnchorPoint.bottomLeft,
    this.popupPoint = PopupAnchorPoint.topLeft,
    this.offset = Offset.zero,
    this.adjustments = const <PopupAdjustment>{
      PopupAdjustment.flipY,
      PopupAdjustment.flipX,
      PopupAdjustment.slideX,
      PopupAdjustment.slideY,
    },
    this.dismissPolicy = PopupDismissPolicy.lightDismiss,
    this.constraints,
    this.parent,
    this.onDismiss,
    this.passThrough,
  });

  /// What the popup attaches to, **in the owner window's logical coordinate
  /// space** — the space `RenderBox.localToGlobal` produces.
  ///
  /// The owner window's space and not the screen's, because it is the only
  /// space that exists on every backend: a Wayland client cannot express a
  /// screen coordinate, and its `xdg_positioner` takes exactly this rect.
  /// A host that has screen coordinates converts; one that does not, does not
  /// have to invent them.
  final Rect anchorRect;

  /// Builds the popup's content. Called in whatever tree the host chose, so it
  /// must not close over a `BuildContext` from the calling tree.
  final WidgetBuilder builder;

  final PopupKind kind;
  final PopupAnchorPoint anchorPoint;
  final PopupAnchorPoint popupPoint;
  final Offset offset;
  final Set<PopupAdjustment> adjustments;
  final PopupDismissPolicy dismissPolicy;

  /// Constraints for the content, or null for "as large as it wants, up to the
  /// work area". A dropdown that must match its field's width passes tight
  /// width and loose height here.
  final BoxConstraints? constraints;

  /// The popup this one opens from. Closing the parent closes this one, and a
  /// click in the parent closes this one and stops there.
  final PopupHandle? parent;

  /// Called when the popup is dismissed by any route, including
  /// [PopupHandle.close]. Fires exactly once.
  final void Function()? onDismiss;

  /// A region of the owner's content that keeps receiving the pointer even
  /// while this popup is modal — "modal, except here".
  ///
  /// **A menu bar is the reason this exists.** A menu's layer takes the
  /// content out of the hit path entirely, so that the click which closes the
  /// menu cannot also press the button behind it. A menu *bar* breaks that
  /// rule for exactly one rectangle: the bar itself has to keep receiving the
  /// pointer while its dropdown is up, or hovering a sibling cannot switch
  /// menus and clicking the open one cannot close it — the two behaviours a
  /// user notices immediately when they are missing.
  ///
  /// Without this the only way to build a bar is to make its whole chain
  /// non-modal, which trades one visible wrong behaviour for another: a click
  /// anywhere else in the window would then press what it landed on *as well
  /// as* closing the menu.
  ///
  /// A callback rather than a [Rect] because the bar moves: the window is
  /// resized, the bar reflows, and a rect captured at open time would leave a
  /// hole in the wrong place. It is read during hit testing, so it must be
  /// cheap and must not allocate.
  ///
  /// In the same space as [anchorRect]. Null — the usual case — means the
  /// popup is modal everywhere or modal nowhere, as its [kind] decides.
  final Rect? Function()? passThrough;

  PopupSpec copyWith({Rect? anchorRect, BoxConstraints? constraints}) =>
      PopupSpec(
        anchorRect: anchorRect ?? this.anchorRect,
        builder: builder,
        kind: kind,
        anchorPoint: anchorPoint,
        popupPoint: popupPoint,
        offset: offset,
        adjustments: adjustments,
        dismissPolicy: dismissPolicy,
        constraints: constraints ?? this.constraints,
        parent: parent,
        onDismiss: onDismiss,
        passThrough: passThrough,
      );
}

/// Where a window's popups go.
///
/// One per window. See the library comment for why there are two
/// implementations and what a caller may assume about either.
abstract interface class PopupHost {
  /// Whether a popup opened here may be drawn outside the owner window.
  ///
  /// False for anything composited into the owner's display list. The answer
  /// decides whether the work area handed to [PopupPositioner] is the screen
  /// or the window, so a widget that lays out its own popup content — a menu
  /// deciding whether to scroll — has to read it rather than assume.
  bool get escapesOwnerWindow;

  /// How many popups are open, across every chain.
  int get openCount;

  /// The innermost open popup, or null. What Escape closes and where the
  /// keyboard is redirected.
  PopupHandle? get topmost;

  /// Opens a popup. The returned handle is the only way to close it.
  PopupHandle open(PopupSpec spec);

  /// Closes every open popup, deepest first.
  ///
  /// What happens when the window loses activation, when the owner is being
  /// destroyed, or when a route change makes every open menu meaningless.
  void closeAll();

  /// The host for [context]'s window.
  ///
  /// Throws a named error when there is none, rather than returning null:
  /// a menu that silently opened nothing would read as a broken control, and
  /// the fix — wrap the tree — is not discoverable from a menu that does not
  /// appear. Use [maybeOf] where absence is a legitimate answer, which for a
  /// tooltip it is.
  static PopupHost of(BuildContext context) {
    final PopupHost? host = maybeOf(context);
    if (host == null) {
      throw StateError(
        'No PopupHostScope found in the widget tree.\n'
        'Menus, dropdowns and tooltips need a host to open into. One is '
        'installed by DartUiApp, so an application built with runApp already '
        'has it; a test that mounts a bare widget tree does not.\n'
        'Wrap the subtree in a PopupHostScope, or mount it under DartUiApp.',
      );
    }
    return host;
  }

  /// The host for [context]'s window, or null when there is none.
  ///
  /// The honest answer for a widget that has something useful to do without a
  /// popup — a [Tooltip] outside a host is its child, which is exactly the
  /// behaviour a platform without popups should get.
  static PopupHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PopupHostScope>()?.host;
}

/// Publishes the [PopupHost] for everything below it.
///
/// Per window, never shared: a popup has a position, and a position only means
/// something inside one window. Two windows sharing a host would fight over
/// where the menu is, and closing one would leave the other pointing at a
/// dismissed popup — the same reason `ContextMenuScope` is per window.
final class PopupHostScope extends InheritedWidget {
  const PopupHostScope({super.key, required this.host, required super.child});

  final PopupHost host;

  @override
  bool updateShouldNotify(PopupHostScope oldWidget) =>
      !identical(oldWidget.host, host);
}

// ---------------------------------------------------------------------------
// The in-tree host
// ---------------------------------------------------------------------------

/// Composites popups into the owner window's own surface.
///
/// The cheap host, the portable one, and the only one that can exist on a
/// backend with no windows. It is bounded by the owner's client area: a menu
/// that would not fit is flipped and slid by [PopupPositioner] against the
/// window rather than against the screen, and one that fits nowhere is
/// clipped. That is the trade, and [escapesOwnerWindow] is how a caller reads
/// which side of it they are on.
///
/// The ordering and the dismissal semantics are [PopupStack]'s, which already
/// models a submenu chain and already knows that a click inside a parent menu
/// closes its children and nothing else. This host is that stack plus the
/// widgets, so the two cannot disagree about what "dismiss" means.
final class InTreePopupHost implements PopupHost {
  InTreePopupHost();

  final PopupStack _stack = PopupStack();
  final List<InTreePopupHandle> _handles = <InTreePopupHandle>[];
  final List<void Function()> _listeners = <void Function()>[];

  /// The layer currently rendering this host's popups, if one is mounted.
  RenderPopupLayer? _layer;

  @override
  bool get escapesOwnerWindow => false;

  @override
  int get openCount => _handles.length;

  @override
  PopupHandle? get topmost => _handles.isEmpty ? null : _handles.last;

  /// The open popups, outermost first. Read by [PopupLayer] to build children.
  List<InTreePopupHandle> get handles =>
      List<InTreePopupHandle>.unmodifiable(_handles);

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  @override
  PopupHandle open(PopupSpec spec) {
    // A popup opened from a popup that has since closed is a race, not a
    // caller error: the pointer moved onto a submenu trigger in the same frame
    // the parent was dismissed. Refusing loudly would crash on a legal
    // sequence, so it opens as a root popup and the chain simply has one level.
    final PopupHandle? parent = spec.parent;
    final int? ownerId =
        parent is InTreePopupHandle && parent.isOpen ? parent._entryId : null;

    late final InTreePopupHandle handle;
    final int id = _stack.open(
      // The placement is a placeholder until the first layout: the content has
      // not been measured, so its size is unknown and any rect here would be a
      // guess. `RenderPopupLayer.performLayout` replaces it with the measured
      // one, which is why `placedRect` is null rather than wrong until then.
      placement: const PopupPlacement(
        rect: Rect.fromLTRB(0, 0, 0, 0),
        flippedX: false,
        flippedY: false,
        slidX: false,
        slidY: false,
        resized: false,
      ),
      surfaceKind: PopupSurfaceKind.sameSurface,
      dismissPolicy: spec.dismissPolicy,
      // In-tree popups never grab: there is no platform grab to take, and the
      // stack's own hit ordering is what stops a click reaching underneath.
      grabsInput: false,
      ownerId: ownerId,
      onDismiss: () => handle._onStackDismissed(),
    );
    handle = InTreePopupHandle(host: this, entryId: id, spec: spec);
    _handles.add(handle);
    _notify();
    return handle;
  }

  @override
  void closeAll() {
    if (_handles.isEmpty) return;
    _stack.closeAll();
    _notify();
  }

  /// Applies a pointer press at [point], in the layer's local space.
  ///
  /// Returns whether the press dismissed anything. It does **not** decide
  /// whether the press also reaches what is underneath — that is settled
  /// earlier, by `RenderPopupLayer.hitTestChildren` leaving the content out of
  /// the hit path for a modal kind. See that method for why the decision
  /// cannot live here: by the time this runs, a button left in the path has
  /// already been pressed.
  bool handlePressOutside(Offset point) {
    if (_handles.isEmpty) return false;
    final bool dismissed = _stack.handleOutsideClick(point);
    if (dismissed) _notify();
    return dismissed;
  }

  /// Closes the innermost popup, for Escape. Returns whether one closed.
  bool dismissTopmost() {
    final bool closed = _stack.dismissTopmost();
    if (closed) _notify();
    return closed;
  }

  void _close(InTreePopupHandle handle) {
    if (!handle.isOpen) return;
    _stack.close(handle._entryId);
    _notify();
  }

  void _forget(InTreePopupHandle handle) {
    _handles.remove(handle);
  }

  void _attach(RenderPopupLayer layer) => _layer = layer;

  void _detach(RenderPopupLayer layer) {
    if (identical(_layer, layer)) _layer = null;
  }
}

/// An [InTreePopupHost]'s live popup.
///
/// Public because a test - and a diagnostic overlay - has a legitimate reason
/// to name the concrete type and read [placedRect] off it; nothing in the
/// framework's own code paths depends on the concrete type, which is the whole
/// point of [PopupHandle].
final class InTreePopupHandle implements PopupHandle {
  InTreePopupHandle({
    required InTreePopupHost host,
    required int entryId,
    required PopupSpec spec,
  })  : _host = host,
        _entryId = entryId,
        _spec = spec;

  final InTreePopupHost _host;
  final int _entryId;
  PopupSpec _spec;
  Rect? _placedRect;
  bool _open = true;
  bool _dismissedFired = false;

  PopupSpec get spec => _spec;

  @override
  bool get isOpen => _open;

  @override
  PopupKind get kind => _spec.kind;

  @override
  PopupHandle? get parent => _spec.parent;

  @override
  Rect? get placedRect => _open ? _placedRect : null;

  @override
  void close() => _host._close(this);

  @override
  void updateAnchor(Rect anchorRect) {
    if (!_open || anchorRect == _spec.anchorRect) return;
    _spec = _spec.copyWith(anchorRect: anchorRect);
    _host._notify();
  }

  @override
  void markNeedsBuild() {
    if (!_open) return;
    _host._notify();
  }

  /// Called by [PopupStack] when this entry leaves the stack, by any route.
  ///
  /// The single point where "closed" becomes true, so that the several routes
  /// into dismissal — an explicit close, a click outside, the parent closing,
  /// the whole host closing — cannot each fire [PopupSpec.onDismiss] again.
  void _onStackDismissed() {
    if (!_open) return;
    _open = false;
    _host._forget(this);
    if (!_dismissedFired) {
      _dismissedFired = true;
      _spec.onDismiss?.call();
    }
  }

  void _recordPlacement(Rect rect) => _placedRect = rect;
}

// ---------------------------------------------------------------------------
// The layer that draws them
// ---------------------------------------------------------------------------

/// Draws an [InTreePopupHost]'s popups above [child].
///
/// Installed once per window, wrapping the whole content. `DartUiApp` installs
/// one, so an application built with `runApp` has it without asking; a test
/// that mounts a bare tree can install one directly.
final class PopupLayer extends StatefulWidget {
  const PopupLayer({super.key, required this.host, required this.child});

  final InTreePopupHost host;
  final Widget child;

  @override
  State<PopupLayer> createState() => _PopupLayerState();
}

final class _PopupLayerState extends State<PopupLayer> {
  @override
  void initState() {
    super.initState();
    widget.host.addListener(_onHostChanged);
  }

  @override
  void didUpdateWidget(PopupLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.host, widget.host)) {
      oldWidget.host.removeListener(_onHostChanged);
      widget.host.addListener(_onHostChanged);
    }
  }

  @override
  void dispose() {
    widget.host.removeListener(_onHostChanged);
    super.dispose();
  }

  void _onHostChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final List<InTreePopupHandle> handles = widget.host.handles;
    return _PopupLayerRenderWidget(
      host: widget.host,
      specs: <PopupSpec>[
        for (final InTreePopupHandle handle in handles) handle.spec
      ],
      handles: handles,
      children: <Widget>[
        widget.child,
        for (final InTreePopupHandle handle in handles)
          // Keyed by the stack entry, so a popup that stays open across a
          // rebuild keeps its element and its state - a submenu opening must
          // not rebuild the menu that opened it from scratch and lose its
          // keyboard cursor.
          _PopupContent(key: ValueKey<int>(handle._entryId), handle: handle),
      ],
    );
  }
}

/// Installs an [InTreePopupHost] and everything needed to use it.
///
/// The one-widget form of "this subtree can open popups": it creates the host,
/// publishes it through [PopupHostScope], and wraps the content in the
/// [PopupLayer] that draws them. `DartUiApp` installs one, so an application
/// has popups without asking for them; a test that mounts a bare tree wraps it
/// in this.
///
/// The scope sits **above** the layer on purpose. Descendants of [child] find
/// the host, and so does the content of an open popup — which is a child of
/// the layer, and is how a menu item can open a submenu into the same host
/// instead of needing a host of its own.
final class PopupScope extends StatefulWidget {
  const PopupScope({super.key, required this.child, this.host});

  final Widget child;

  /// The host to use, or null to own one.
  ///
  /// Passing one is how a test reaches the popups without a pointer, and how
  /// an application that wants a window host installs it — the same seam
  /// `ComboBoxScope.overlay` uses, for the same reason.
  final PopupHost? host;

  @override
  State<PopupScope> createState() => _PopupScopeState();
}

final class _PopupScopeState extends State<PopupScope> {
  InTreePopupHost? _owned;

  PopupHost get _host {
    final PopupHost? supplied = widget.host;
    if (supplied != null) return supplied;
    return _owned ??= InTreePopupHost();
  }

  @override
  Widget build(BuildContext context) {
    final PopupHost host = _host;
    // Only an in-tree host has a layer to draw: a window host puts its pixels
    // in another window, and wrapping the content in a layer that can never
    // have children would cost a render object per window for nothing.
    if (host is! InTreePopupHost) {
      return PopupHostScope(host: host, child: widget.child);
    }
    return PopupHostScope(
      host: host,
      child: PopupLayer(host: host, child: widget.child),
    );
  }
}

final class _PopupContent extends StatelessWidget {
  const _PopupContent({super.key, required this.handle});

  final InTreePopupHandle handle;

  @override
  Widget build(BuildContext context) => handle.spec.builder(context);
}

final class _PopupLayerRenderWidget extends MultiChildRenderObjectWidget {
  const _PopupLayerRenderWidget({
    required this.host,
    required this.specs,
    required this.handles,
    required super.children,
  });

  final InTreePopupHost host;
  final List<PopupSpec> specs;
  final List<InTreePopupHandle> handles;

  @override
  RenderPopupLayer createRenderObject(BuildContext context) => RenderPopupLayer(
        host: host,
        specs: specs,
        handles: handles,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderPopupLayer object,
  ) {
    object
      ..host = host
      ..specs = specs
      ..handles = handles;
  }
}

/// Lays the window's content out, then places each open popup over it.
///
/// Child 0 is the content and takes the incoming constraints. Children 1..N
/// are the open popups, outermost first, each laid out loosely and placed by
/// [PopupPositioner] against **the window's client area** — which is the whole
/// difference between this host and a window one, and the reason a menu here
/// is flipped inside the window instead of extending past it.
final class RenderPopupLayer extends RenderBoxContainer<BoxParentData>
    implements PointerEventTarget {
  RenderPopupLayer({
    required InTreePopupHost host,
    required List<PopupSpec> specs,
    required List<InTreePopupHandle> handles,
  })  : _host = host,
        _specs = specs,
        _handles = handles {
    host._attach(this);
  }

  InTreePopupHost _host;
  List<PopupSpec> _specs;
  List<InTreePopupHandle> _handles;

  InTreePopupHost get host => _host;

  set host(InTreePopupHost value) {
    if (identical(value, _host)) return;
    _host._detach(this);
    _host = value;
    value._attach(this);
    markNeedsLayout();
  }

  set specs(List<PopupSpec> value) {
    _specs = value;
    markNeedsLayout();
  }

  set handles(List<InTreePopupHandle> value) {
    _handles = value;
    markNeedsLayout();
  }

  /// Whether any popup is open. Read by the hit test: a layer with none must be
  /// invisible to the pointer, or every window with a popup host would swallow
  /// the presses that reach nothing.
  bool get isOpen => childCount > 1;

  /// Where each open popup was placed, outermost first. Diagnostics and tests.
  List<Rect> get placements => <Rect>[
        for (int i = 0; i < _handles.length; i++)
          if (_handles[i].placedRect != null) _handles[i].placedRect!,
      ];

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void performLayout() {
    if (childCount == 0) {
      size = constraints.smallest;
      return;
    }
    final RenderBox content = childAt(0);
    content.layout(constraints, parentUsesSize: true);
    content.parentData!.offset = Offset.zero;
    size = constraints.constrain(content.size);

    final Rect workArea = Rect.fromLTWH(0, 0, size.width, size.height);
    for (int i = 1; i < childCount; i++) {
      final RenderBox popup = childAt(i);
      final int specIndex = i - 1;
      if (specIndex >= _specs.length) {
        // The children and the specs are built from the same list in the same
        // frame, so this cannot happen - but laying out against a stale spec
        // would place a popup at the previous one's anchor, which is a
        // misplacement nobody would trace back to here. Skip instead.
        popup.layout(BoxConstraints.loose(size));
        continue;
      }
      final PopupSpec spec = _specs[specIndex];
      popup.layout(
        spec.constraints ?? BoxConstraints.loose(size),
        parentUsesSize: true,
      );
      final PopupPlacement placement = const PopupPositioner().place(
        PopupRequest(
          anchorRect: spec.anchorRect,
          size: popup.size,
          anchorPoint: spec.anchorPoint,
          popupPoint: spec.popupPoint,
          offset: spec.offset,
          adjustments: spec.adjustments,
        ),
        workArea,
      );
      popup.parentData!.offset =
          Offset(placement.rect.left, placement.rect.top);
      if (specIndex < _handles.length) {
        _handles[specIndex]._recordPlacement(placement.rect);
        // The stack holds the placement that dismissal arithmetic reads, so it
        // has to learn the measured rect too: `handleOutsideClick` compares a
        // press against these rects, and against the zero-size placeholder it
        // would treat every press as outside every popup.
        _host._stack.reposition(_handles[specIndex]._entryId, placement);
      }
    }
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    // Topmost popup first, then down the chain, then the content. A submenu
    // sits above its parent and must win the pointer where they overlap.
    for (int i = childCount - 1; i >= 1; i--) {
      final int specIndex = i - 1;
      if (specIndex < _specs.length && !_specs[specIndex].kind.takesPointer) {
        // A tooltip is transparent to the pointer by definition: the hover
        // that produced it is still happening on the control underneath, and
        // a tooltip that swallowed the pointer would dismiss itself the
        // instant it appeared.
        continue;
      }
      final RenderBox popup = childAt(i);
      final Offset offset = popup.offsetFromParent;
      final RenderBox? hit = popup.hitTest(
        Offset(position.dx - offset.dx, position.dy - offset.dy),
        path: path,
      );
      if (hit != null) return hit;
    }
    // Missed every popup. A modal layer stops here and lets [hitTestSelf]
    // claim the press; anything else offers it to the content underneath.
    if (_isModal && !_passesThrough(position)) return null;
    if (childCount == 0) return null;
    final RenderBox content = childAt(0);
    return content.hitTest(position, path: path);
  }

  /// Whether [position] falls in a region an open popup declared as still
  /// belonging to the content. See [PopupSpec.passThrough]; a menu bar is the
  /// reason it exists.
  bool _passesThrough(Offset position) {
    for (final PopupSpec spec in _specs) {
      final Rect? region = spec.passThrough?.call();
      if (region != null && region.contains(position)) return true;
    }
    return false;
  }

  /// Whether an open popup makes this layer modal to the pointer.
  ///
  /// **This is where "the click that closes a menu must not also press the
  /// button behind it" is implemented**, and it is implemented in the hit test
  /// rather than by swallowing the event afterwards — because afterwards is
  /// too late. The router builds the hit path deepest-first and delivers in
  /// that order, so a button left in the path has already been pressed by the
  /// time the event bubbles up to this layer. No return value can undo that.
  ///
  /// So a menu removes the content from the path entirely: [hitTestChildren]
  /// stops at the popups and never reaches child 0 — the same thing
  /// `RenderContextMenuLayer` does, arrived at for the same reason. A dropdown
  /// and a tooltip do not, because for them the pass-through *is* the wanted
  /// behaviour: clicking a button while a combo list is open should close the
  /// list and press the button, which is what every desktop does.
  bool get _isModal {
    for (final PopupSpec spec in _specs) {
      if (!spec.kind.dismissalPassesThrough) return true;
    }
    return false;
  }

  /// Claims a press while any popup is open.
  ///
  /// True even for a non-modal popup and even where the content missed: that
  /// is what puts this layer in the hit path for a press on empty space, which
  /// has to dismiss an open dropdown like any other press outside it. When the
  /// content *did* hit, the layer is in the path anyway — `RenderBox.hitTest`
  /// adds a parent whose children hit — so both routes reach
  /// [handlePointerEvent].
  @override
  bool hitTestSelf(Offset position) {
    if (_specs.isEmpty) return false;
    // A press inside a declared pass-through region is the content's, not
    // this layer's: claiming it here would put the layer ahead of the menu bar
    // in the hit path and dismiss the very menu the press is trying to switch.
    return !_passesThrough(position);
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    if (_specs.isEmpty) return;
    final Offset local = globalToLocal(event.logicalPosition);
    // A press inside a pass-through region belongs to the content and must not
    // dismiss anything here. `RenderBox.hitTest` puts this layer in the path
    // whenever a child was hit, so without this guard a click on a menu bar
    // would close the menu on the way past and the bar's own handler would
    // then reopen it: switching menus would flicker, and clicking the open one
    // would close and immediately reopen instead of toggling shut.
    if (_passesThrough(local)) return;
    _host.handlePressOutside(local);
  }

  @override
  void detach() {
    _host._detach(this);
    super.detach();
  }
}

/// Raised when [PopupPolicy.window] was asked for and the backend has no
/// windows to give.
///
/// A named error rather than a silent fallback: an application that asked for
/// a window said so because being cropped is not acceptable to it, and quietly
/// giving it the thing it refused is how a bug report becomes "it works on my
/// machine".
final class PopupWindowUnavailableError implements Exception {
  const PopupWindowUnavailableError(this.reason);

  /// Why no window was available, in the words of whoever knew - a backend
  /// that never opens windows, or one whose popup creation failed.
  final String reason;

  @override
  String toString() =>
      'PopupWindowUnavailableError: PopupPolicy.window was requested but this '
      'backend cannot open a popup window: $reason';
}
