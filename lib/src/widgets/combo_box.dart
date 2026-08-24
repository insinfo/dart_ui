/// The combo box: one value chosen from a list shown in a popup.
///
/// Section 29.4 lists it among the controls a business application cannot do
/// without - there is no form without a combo box - and it is built here out of
/// pieces that already exist rather than out of new ones:
///
///   * [PopupPositioner] places the drop-down, flipping it above the field when
///     there is no room below and sliding it back inside the window when there
///     is no room beside. Nothing in this file computes a placement itself;
///   * [ListBox] *is* the drop-down's list, so a combo box over ten thousand
///     rows virtualizes for free and its items report "item 3 of 10000" to a
///     screen reader like every other list in the framework;
///   * [ControlBehavior] gives the closed field its hover, pressed, focus and
///     pointer-capture behaviour, so the eleven states section 29.3 enumerates
///     are the same eleven every other control has.
///
/// ## Highlight is not selection
///
/// The distinction the rest of this file is organized around. While the popup
/// is open the arrow keys move a *highlight*; the value only changes when the
/// user commits with Enter or a click. Escape closes the popup and restores the
/// value the field had when it opened - it does **not** commit the highlighted
/// row. A combo box that committed on highlight would make arrowing through a
/// list of countries fire a form's `onChanged` once per country, and Escape
/// would have nothing left to restore.
///
/// ## Why a scope is required
///
/// A drop-down has to paint over whatever is beneath it, and a render object
/// can only paint inside its own subtree - a popup drawn by the field itself
/// would be painted *under* every sibling that comes after it in the parent's
/// paint order, and a click on it would be hit-tested against that sibling
/// first. So the popup is hosted by [ComboBoxScope], exactly as a context menu
/// is hosted by `ContextMenuScope`, and for exactly the same reason. Missing
/// scope is a [MissingComboBoxScopeError] naming the fix, on the same reasoning
/// `Directionality.of` throws: a silent fallback would look right on the
/// author's screen and be wrong in the one layout that produced it.
///
/// ## Declared absent
///
/// * **`EditableComboBox`** - the variant whose field is a text box the user can
///   type an arbitrary value into. It is a text field, a filter over the item
///   list, and a "value not in the list" policy, none of which this control
///   has; it is named here so its absence is a decision rather than an
///   oversight.
/// * **Multi-character type-ahead.** Typing `br` selects the first item
///   starting with `b` and then the first starting with `r`, rather than
///   `Brazil`. A prefix buffer needs a timeout, a timeout needs a clock in the
///   input path, and there is none - see `animation/clock.dart` for why one
///   will not be invented here.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../layout/render_viewport.dart';
import '../platform/input_events.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'control.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'keyboard_router.dart';
import 'list_box.dart';
import 'pointer_router.dart';
import 'popup.dart';
import 'semantics.dart';
import 'style.dart';
import 'theme.dart';
import 'widget.dart';

/// `VK_F4`, which opens and closes a combo box on every Windows toolkit.
const int logicalKeyF4 = 0x73;

/// One row of a [ComboBox].
///
/// The label is separate from the value on purpose: a form binds an
/// identifier - a country code, a database row id - and shows a name, and a
/// control that made the two the same string would force every caller to map
/// back and forth.
final class ComboBoxItem<T> {
  const ComboBoxItem({
    required this.value,
    required this.label,
    this.enabled = true,
  });

  final T value;
  final String label;

  /// Whether this row can be selected. A disabled row is still shown, still
  /// counted by the list's accessibility, and skipped by every keyboard move.
  final bool enabled;

  @override
  String toString() => 'ComboBoxItem($label)';
}

/// Thrown when a [ComboBox] is built with no [ComboBoxScope] above it.
final class MissingComboBoxScopeError extends Error {
  MissingComboBoxScopeError(this.requestedBy);

  final String requestedBy;

  @override
  String toString() => 'No ComboBoxScope ancestor found for $requestedBy.\n'
      "A combo box's drop-down is painted by a scope high in the tree, because "
      'a popup drawn inside the field would be painted under the widgets that '
      'follow it and clicked through to them.\n'
      'Wrap the window content in one:\n'
      '\n'
      '  ComboBoxScope(\n'
      '    child: ...,\n'
      '  )\n';
}

// ---------------------------------------------------------------------------
// The overlay
// ---------------------------------------------------------------------------

/// The one drop-down a [ComboBoxScope] can show, and the handle on it.
///
/// One at a time, like a context menu: a second combo box opened while the
/// first is down is never something a user asked for, so [open] closes what was
/// showing and runs its `onDismiss`.
///
/// ## Why this is not a [PopupStack]
///
/// `popup.dart` has a stack, and it is the right shape for a *menu chain* -
/// several popups open at once, each dismissible on its own, each placed once
/// when it opened. A combo box has exactly one popup and it is re-placed on
/// every layout, because the window it must stay inside can be resized while it
/// is down. Pushing an immutable [PopupEntry] per frame would fire that entry's
/// dismissal callback once per frame; keeping the entry and letting its
/// placement go stale is the orphaned-popup bug itself. So the placement half of
/// `popup.dart` - [PopupPositioner], [PopupRequest], [PopupDismissPolicy] - is
/// used here, and the stacking half is left to the control that stacks.
final class ComboBoxOverlay {
  ComboBoxOverlay();

  final List<void Function()> _listeners = <void Function()>[];

  Rect Function()? _anchorRect;
  Widget Function()? _builder;
  void Function()? _onDismiss;
  void Function(Size workArea)? _onWorkAreaChanged;
  double? _width;
  PopupDismissPolicy _dismissPolicy = PopupDismissPolicy.lightDismiss;
  PopupPlacement? _placement;
  Size? _workArea;
  bool _open = false;
  int _generation = 0;

  bool get isOpen => _open;

  /// How many times a popup has been opened. A test uses it to tell "still the
  /// same popup" from "closed and reopened", which look identical otherwise.
  int get generation => _generation;

  /// Where the popup ended up in the scope's coordinates, or null when it is
  /// closed or has not been laid out yet.
  PopupPlacement? get placement => _open ? _placement : null;

  /// The area the popup was last placed against - the scope's own box.
  Size? get workArea => _workArea;

  /// The anchor's rect in the scope's coordinates, read live from the field
  /// rather than captured at open time. That is what makes a resized window
  /// re-place the popup against the field's *current* position instead of the
  /// one it had when it opened.
  Rect? get anchorRect => _open ? _anchorRect?.call() : null;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Shows [builder]'s widget under [anchorRect].
  void open({
    required Rect Function() anchorRect,
    required Widget Function() builder,
    double? width,
    PopupDismissPolicy dismissPolicy = PopupDismissPolicy.lightDismiss,
    void Function()? onDismiss,
    void Function(Size workArea)? onWorkAreaChanged,
  }) {
    if (_open) close();
    _anchorRect = anchorRect;
    _builder = builder;
    _width = width;
    _dismissPolicy = dismissPolicy;
    _onDismiss = onDismiss;
    _onWorkAreaChanged = onWorkAreaChanged;
    _placement = null;
    _open = true;
    _generation++;
    _notify();
  }

  /// Rebuilds the popup's content from the builder [open] was given.
  ///
  /// Called when the highlight moves: the popup lives in the scope's subtree,
  /// so the field's own `setState` cannot reach it.
  void refresh() {
    if (!_open) return;
    _notify();
  }

  /// Closes the popup. Returns whether one was open.
  bool close() {
    if (!_open) return false;
    _open = false;
    _anchorRect = null;
    _builder = null;
    _width = null;
    _placement = null;
    _onWorkAreaChanged = null;
    final void Function()? dismissed = _onDismiss;
    _onDismiss = null;
    _notify();
    dismissed?.call();
    return true;
  }

  /// The popup's content for this frame, or null when nothing is showing.
  Widget? buildPopup() => _open ? _builder?.call() : null;

  void _notify() {
    for (final void Function() listener in List<void Function()>.of(
      _listeners,
    )) {
      listener();
    }
  }
}

/// Hosts the drop-down for every [ComboBox] below it.
///
/// Install one around the whole window's content: the subtree it wraps is the
/// area a popup can be placed in, and a scope around half the window would flip
/// a drop-down against that half's edge instead of the window's.
final class ComboBoxScope extends StatefulWidget {
  const ComboBoxScope({super.key, this.overlay, required this.child});

  /// The overlay to publish, or null to own a private one. Passing one is how a
  /// test - or a shell that wants to close every popup on window deactivation -
  /// reaches the drop-down without a pointer.
  final ComboBoxOverlay? overlay;

  final Widget child;

  /// The nearest overlay, or null when no scope is installed.
  static ComboBoxOverlay? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_ComboBoxScopeMarker>()
      ?.overlay;

  /// The nearest overlay, or a failure that names the missing wrapper.
  static ComboBoxOverlay of(BuildContext context) {
    final ComboBoxOverlay? overlay = maybeOf(context);
    if (overlay == null) {
      throw MissingComboBoxScopeError('${context.widget.runtimeType}');
    }
    return overlay;
  }

  @override
  State<ComboBoxScope> createState() => _ComboBoxScopeState();
}

final class _ComboBoxScopeState extends State<ComboBoxScope> {
  late ComboBoxOverlay _overlay;
  late bool _ownsOverlay;

  @override
  void initState() {
    super.initState();
    _ownsOverlay = widget.overlay == null;
    _overlay = widget.overlay ?? ComboBoxOverlay();
    _overlay.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(ComboBoxScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.overlay, widget.overlay)) return;
    _overlay.removeListener(_onChanged);
    _ownsOverlay = widget.overlay == null;
    _overlay = widget.overlay ?? ComboBoxOverlay();
    _overlay.addListener(_onChanged);
  }

  @override
  void dispose() {
    _overlay.removeListener(_onChanged);
    if (_ownsOverlay) _overlay.close();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final Widget? popup = _overlay.buildPopup();
    return _ComboBoxScopeMarker(
      overlay: _overlay,
      child: _ComboBoxLayerWidget(
        overlay: _overlay,
        children: <Widget>[widget.child, if (popup != null) popup],
      ),
    );
  }
}

final class _ComboBoxScopeMarker extends InheritedWidget {
  const _ComboBoxScopeMarker({required this.overlay, required super.child});

  final ComboBoxOverlay overlay;

  @override
  bool updateShouldNotify(_ComboBoxScopeMarker oldWidget) =>
      !identical(overlay, oldWidget.overlay);
}

final class _ComboBoxLayerWidget extends MultiChildRenderObjectWidget {
  const _ComboBoxLayerWidget({required this.overlay, required super.children});

  final ComboBoxOverlay overlay;

  @override
  RenderComboBoxLayer createRenderObject(BuildContext context) =>
      RenderComboBoxLayer()
        ..overlay = overlay
        ..textDirection = Directionality.of(context);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderComboBoxLayer object,
  ) {
    object
      ..overlay = overlay
      ..textDirection = Directionality.of(context);
  }
}

/// The overlay: content underneath, at most one drop-down on top of it.
final class RenderComboBoxLayer extends RenderBoxContainer<BoxParentData>
    implements PointerEventTarget {
  ComboBoxOverlay? _overlay;
  TextDirection _textDirection = TextDirection.leftToRight;
  PopupPlacement? _placement;

  ComboBoxOverlay? get overlay => _overlay;

  set overlay(ComboBoxOverlay? value) {
    if (identical(value, _overlay)) return;
    _overlay = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// Where the popup was placed this frame, or null when nothing is showing.
  PopupPlacement? get placement => _placement;

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
    final ComboBoxOverlay? overlay = _overlay;
    if (popup == null || overlay == null) return;

    final Rect workArea = Rect.fromLTWH(0, 0, size.width, size.height);
    // The anchor arrives in the root's coordinates and is converted here, on
    // the frame it is used: an anchor captured when the popup opened would be
    // stale the moment anything above the field moved or the window resized.
    final Rect anchorGlobal =
        overlay.anchorRect ?? const Rect.fromLTWH(0, 0, 0, 0);
    final Offset anchorTopLeft = globalToLocal(anchorGlobal.topLeft);
    final Rect anchor = Rect.fromLTWH(
      anchorTopLeft.dx,
      anchorTopLeft.dy,
      anchorGlobal.width,
      anchorGlobal.height,
    );

    final double width = overlay._width ?? anchor.width;
    popup.layout(
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: workArea.height,
      ),
      parentUsesSize: true,
    );

    // The drop-down hangs from the field's start edge, which is its right edge
    // in a right-to-left locale. Anything else would leave a wide popup growing
    // away from the control it belongs to.
    final bool rtl = _textDirection.isRightToLeft;
    final PopupPlacement placement = const PopupPositioner().place(
      PopupRequest(
        anchorRect: anchor,
        size: popup.size,
        anchorPoint:
            rtl ? PopupAnchorPoint.bottomRight : PopupAnchorPoint.bottomLeft,
        popupPoint: rtl ? PopupAnchorPoint.topRight : PopupAnchorPoint.topLeft,
        adjustments: const <PopupAdjustment>{
          PopupAdjustment.flipY,
          PopupAdjustment.slideX,
          PopupAdjustment.slideY,
        },
      ),
      workArea,
    );
    _placement = placement;
    popup.parentData!.offset = Offset(placement.rect.left, placement.rect.top);
    overlay._placement = placement;
    final Size previousWorkArea = overlay._workArea ?? size;
    overlay._workArea = size;
    if (previousWorkArea != size) {
      overlay._onWorkAreaChanged?.call(size);
    }
  }

  /// While the drop-down is open only the drop-down is hit-testable.
  ///
  /// The input grab. A click outside an open popup must dismiss it *and stop
  /// there*: letting it through as well is how a user closes a drop-down and
  /// simultaneously presses whatever was behind it.
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

  @override
  bool hitTestSelf(Offset position) => isOpen;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    final PopupPlacement? placement = _placement;
    final ComboBoxOverlay? overlay = _overlay;
    if (placement == null || overlay == null) return;
    if (placement.rect.contains(globalToLocal(event.logicalPosition))) return;
    if (overlay._dismissPolicy != PopupDismissPolicy.lightDismiss) return;
    overlay.close();
  }
}

// ---------------------------------------------------------------------------
// The control
// ---------------------------------------------------------------------------

/// A control that shows one value and picks another from a drop-down list.
///
/// Controlled, like every other value-bearing control in the framework: the
/// widget shows [value] and reports intent through [onChanged]. A null
/// [onChanged] is what disables it.
final class ComboBox<T> extends StatefulWidget {
  const ComboBox({
    super.key,
    required this.items,
    required this.value,
    this.onChanged,
    this.label,
    this.placeholder = '',
    this.itemExtent,
    this.maxVisibleItems = 8,
    this.popupWidth,
    this.styleClasses = const <String>{},
  });

  final List<ComboBoxItem<T>> items;

  /// The currently selected value, or null when nothing is selected.
  final T? value;

  /// Called with the newly committed value. Null disables the control.
  final void Function(T value)? onChanged;

  /// The accessible name - what a screen reader announces before the value.
  /// The visible text is the *value*, so this is what says "Country".
  final String? label;

  /// What the closed field shows when [value] matches no item.
  final String placeholder;

  /// The height of one row, or null for the theme's.
  ///
  /// Null is the right answer for almost every caller: a list whose rows are a
  /// number the caller made up is a list that ignores the density switch, and
  /// a window that mixes one of those with a themed one has two row rhythms in
  /// it. A number is for the rare list whose rows are not text.
  final double? itemExtent;

  /// How many rows the drop-down shows before it scrolls.
  final int maxVisibleItems;

  /// The drop-down's width. Defaults to the field's own width, which is what
  /// every desktop combo box does.
  final double? popupWidth;

  final Set<String> styleClasses;

  @override
  State<ComboBox<T>> createState() => _ComboBoxState<T>();
}

final class _ComboBoxState<T> extends State<ComboBox<T>> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'ComboBox')
    ..addListener(_onFocusChanged);
  final ComboBoxAnchor _anchor = ComboBoxAnchor();
  final ScrollPosition _scroll = ScrollPosition();

  ComboBoxOverlay? _overlay;
  int _highlighted = -1;
  int _indexOnOpen = -1;
  bool _disposed = false;

  bool get _enabled => widget.onChanged != null && widget.items.isNotEmpty;

  bool get _isOpen => _overlay != null && _overlay!.isOpen;

  /// The index of [ComboBox.value] among the items, or -1.
  int get _selectedIndex {
    for (int i = 0; i < widget.items.length; i++) {
      if (widget.items[i].value == widget.value) return i;
    }
    return -1;
  }

  String get _fieldLabel {
    final int index = _selectedIndex;
    return index < 0 ? widget.placeholder : widget.items[index].label;
  }

  @override
  void didUpdateWidget(ComboBox<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A list that changed underneath an open popup can leave the highlight
    // pointing past its end; a highlight nobody can see is what makes Enter
    // commit something arbitrary.
    if (_highlighted >= widget.items.length) {
      _highlighted = widget.items.isEmpty ? -1 : widget.items.length - 1;
    }
    if (_isOpen && !_enabled) _cancel();
  }

  @override
  void dispose() {
    // Set before the popup is torn down: closing runs [_onDismissed], and a
    // `setState` from inside `dispose` is an error rather than a rebuild.
    _disposed = true;
    if (_isOpen) _overlay!.close();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  /// Focus leaving the field closes the drop-down without committing - Tab out
  /// of a combo box is a "never mind", not a choice.
  ///
  /// Except when focus left by *pointer*, and that exception is load-bearing:
  /// the drop-down's own [ListBox] takes focus when a row is clicked, so
  /// closing on every focus loss would dismiss the popup on the way to
  /// choosing from it. A click has its own dismissal path - the overlay
  /// closes on a press outside the popup - so this handler is only about the
  /// keyboard, which is the only route that can leave silently.
  void _onFocusChanged(FocusNode node) {
    if (node.hasPrimaryFocus || !_isOpen) return;
    final FocusNode? next = node.manager?.primaryFocus;
    if (next != null && next.focusChangeReason == FocusChangeReason.pointer) {
      return;
    }
    _cancel();
  }

  // -------------------------------------------------------------------
  // Opening and closing
  // -------------------------------------------------------------------

  void _openPopup() {
    if (_isOpen || !_enabled) return;
    final ComboBoxOverlay overlay = ComboBoxScope.of(context);
    _overlay = overlay;
    _indexOnOpen = _selectedIndex;
    _highlighted = _selectedIndex >= 0 ? _selectedIndex : _firstEnabled();
    overlay.open(
      anchorRect: () => _anchor.globalRect ?? const Rect.fromLTWH(0, 0, 0, 0),
      builder: _buildPopup,
      width: widget.popupWidth,
      onDismiss: _onDismissed,
    );
    _revealHighlighted();
    setState(() {});
  }

  /// Closes and keeps whatever was committed. Used by Enter and by a click.
  void _closePopup() {
    if (!_isOpen) return;
    _overlay!.close();
  }

  /// Closes without committing: Escape, Alt+Up, focus leaving, the control
  /// being disabled underneath an open popup.
  ///
  /// The restoration itself lives in [_onDismissed] rather than here, because
  /// *every* way of closing that is not a commit has to restore - a click
  /// outside dismisses through the overlay and never passes through this
  /// method, and a highlight left pointing at a row the user did not choose
  /// would be committed by the next Enter.
  void _cancel() {
    if (!_isOpen) return;
    _overlay!.close();
  }

  void _onDismissed() {
    _overlay = null;
    // Back to the value, not to the highlight. A commit has already moved
    // [_indexOnOpen] onto the row it committed, so this is a no-op there and a
    // restoration everywhere else.
    _highlighted = _indexOnOpen;
    if (!_disposed && mounted) setState(() {});
  }

  void _commit(int index) {
    if (index < 0 || index >= widget.items.length) return;
    final ComboBoxItem<T> item = widget.items[index];
    if (!item.enabled) return;
    _highlighted = index;
    _indexOnOpen = index;
    widget.onChanged?.call(item.value);
  }

  void _onPopupSelected(int index) {
    if (index < 0 || index >= widget.items.length) return;
    // Focus returns to the field on *any* press in the list, chosen row or
    // not: the list took focus on the way down, and a combo box whose keyboard
    // has been left inside a popup - one that may be about to close - answers
    // no further arrow key.
    _focusNode.requestFocus(FocusChangeReason.pointer);
    if (!widget.items[index].enabled) {
      // A click on a disabled row is not a choice and must not close the
      // popup either; the user's aim was simply off by one row.
      return;
    }
    _commit(index);
    _closePopup();
  }

  // -------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || !_enabled) return false;
    final bool alt = event.modifiers.contains(KeyModifier.alt);
    switch (event.logicalKey) {
      case logicalKeyF4:
        if (_isOpen) {
          _cancel();
        } else {
          _openPopup();
        }
        return true;
      case logicalKeyArrowDown when alt:
        _openPopup();
        return true;
      case logicalKeyArrowUp when alt:
        _cancel();
        return true;
      case logicalKeyArrowDown:
        _move(1);
        return true;
      case logicalKeyArrowUp:
        _move(-1);
        return true;
      case logicalKeyHome:
        _moveTo(_firstEnabled());
        return true;
      case logicalKeyEnd:
        _moveTo(_lastEnabled());
        return true;
      case logicalKeyPageDown:
        _movePage(1);
        return true;
      case logicalKeyPageUp:
        _movePage(-1);
        return true;
      case logicalKeyEnter:
        if (!_isOpen) return false;
        _commit(_highlighted);
        _closePopup();
        return true;
      case logicalKeySpace:
        if (_isOpen) return false;
        _openPopup();
        return true;
      case logicalKeyEscape:
        if (!_isOpen) return false;
        _cancel();
        return true;
    }
    return false;
  }

  /// Type-ahead, driven by *text* rather than by virtual-key codes.
  ///
  /// A key code is a position on a keyboard; the letter the user pressed is
  /// what a search must match, and on any layout that is not US English the two
  /// are different. Repeating the same letter cycles through the matches, which
  /// is what makes two items starting with `C` both reachable.
  bool _handleTextInput(String text) {
    if (!_enabled || text.isEmpty) return false;
    final String needle = text.substring(0, 1).toLowerCase();
    if (needle.trim().isEmpty) return false;
    final int start = _isOpen ? _highlighted : _selectedIndex;
    final int count = widget.items.length;
    for (int step = 1; step <= count; step++) {
      final int index = (start + step + count) % count;
      final ComboBoxItem<T> item = widget.items[index];
      if (!item.enabled || item.label.isEmpty) continue;
      if (item.label.substring(0, 1).toLowerCase() != needle) continue;
      if (_isOpen) {
        _moveTo(index);
      } else {
        setState(() => _commit(index));
      }
      return true;
    }
    return false;
  }

  void _move(int delta) {
    final int from = _isOpen
        ? (_highlighted < 0 ? -1 : _highlighted)
        : (_selectedIndex < 0 ? -1 : _selectedIndex);
    int index = from;
    for (int step = 0; step < widget.items.length; step++) {
      index += delta;
      if (index < 0 || index >= widget.items.length) return;
      if (widget.items[index].enabled) {
        _moveTo(index);
        return;
      }
    }
  }

  void _movePage(int direction) {
    final int page = widget.maxVisibleItems.clamp(1, 1 << 20);
    final int from = _isOpen ? _highlighted : _selectedIndex;
    final int target =
        (from + direction * page).clamp(0, widget.items.length - 1);
    _moveTo(_nearestEnabled(target, direction));
  }

  /// Moves the highlight when the popup is open, and the *value* when it is
  /// not. That asymmetry is the whole control: a closed combo box is a
  /// spinner over its list, and an open one is a list with a cursor.
  void _moveTo(int index) {
    if (index < 0 || index >= widget.items.length) return;
    if (!widget.items[index].enabled) return;
    if (_isOpen) {
      setState(() => _highlighted = index);
      _revealHighlighted();
      _overlay!.refresh();
      return;
    }
    setState(() => _commit(index));
  }

  int _firstEnabled() {
    for (int i = 0; i < widget.items.length; i++) {
      if (widget.items[i].enabled) return i;
    }
    return -1;
  }

  int _lastEnabled() {
    for (int i = widget.items.length - 1; i >= 0; i--) {
      if (widget.items[i].enabled) return i;
    }
    return -1;
  }

  int _nearestEnabled(int index, int direction) {
    for (int i = index; i >= 0 && i < widget.items.length; i += direction) {
      if (widget.items[i].enabled) return i;
    }
    for (int i = index; i >= 0 && i < widget.items.length; i -= direction) {
      if (widget.items[i].enabled) return i;
    }
    return -1;
  }

  // -------------------------------------------------------------------
  // The popup
  // -------------------------------------------------------------------

  /// The resolved row height, refreshed by every build.
  ///
  /// Cached rather than read through `Theme.of` on demand, because the arrow
  /// keys and the scroll handlers need it outside a build and an inherited
  /// lookup there would register a dependency from the wrong phase. The
  /// starting value is only ever used before the first build.
  double _itemExtent = 28;

  double get _popupHeight {
    final int rows = widget.items.length.clamp(1, widget.maxVisibleItems);
    // Two pixels for the list's own border, so the last row is not cut in half
    // by the frame the list paints around itself.
    return rows * _itemExtent + Spacing.sm;
  }

  ListVirtualization get _virtualization => ListVirtualization(
        itemCount: widget.items.length,
        estimatedExtent: _itemExtent,
      );

  /// Scrolls the drop-down so the highlighted row is visible.
  ///
  /// The combo box owns the keyboard while the popup is down, so the list never
  /// sees the arrow key that moved the highlight and cannot scroll itself. The
  /// arithmetic is [ListVirtualization]'s, not a second copy of it.
  void _revealHighlighted() {
    if (_highlighted < 0) return;
    final double? reveal = _virtualization.scrollToReveal(
      _highlighted,
      scrollOffset: _scroll.pixels,
      viewportExtent: _popupHeight,
    );
    if (reveal != null) _scroll.jumpTo(reveal);
  }

  Widget _buildPopup() => SizedBox(
        height: _popupHeight,
        child: ListBox(
          itemCount: widget.items.length,
          itemExtent: _itemExtent,
          controller: _scroll,
          selectedIndex: _highlighted < 0 ? null : _highlighted,
          onSelected: _onPopupSelected,
          itemBuilder: (BuildContext context, int index) =>
              Text(widget.items[index].label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // Read for the dependency as much as for the value: a scope swapped above
    // this control must rebuild it, and the failure when there is none has to
    // happen here rather than on the first click.
    final ComboBoxOverlay overlay = ComboBoxScope.of(context);
    if (!overlay.isOpen && _overlay != null) _overlay = null;
    _itemExtent = widget.itemExtent ?? Theme.of(context).effectiveRowHeight;
    return FocusAttachment(
      node: _focusNode,
      child: _ComboBoxFieldWidget(
        label: _fieldLabel,
        semanticsLabel: widget.label,
        anchor: _anchor,
        focusNode: _focusNode,
        theme: Theme.of(context),
        textDirection: Directionality.of(context),
        isOpen: _isOpen,
        enabled: _enabled,
        itemCount: widget.items.length,
        selectedIndex: _selectedIndex,
        styleClasses: widget.styleClasses,
        onActivate: () {
          if (_isOpen) {
            _cancel();
          } else {
            _openPopup();
          }
        },
        onKeyEvent: _handleKey,
        onTextInput: _handleTextInput,
      ),
    );
  }
}

/// The live link from the field's render object to whoever needs its position.
///
/// A mutable holder rather than a callback because the render object outlives
/// no build and the [State] owns no render object: the render object registers
/// itself here when it is created and clears the slot when it detaches, and the
/// overlay reads the rect on the frame it places the popup.
final class ComboBoxAnchor {
  RenderComboBoxField? render;

  /// The field's rect in the root's coordinates, or null before it is laid out.
  Rect? get globalRect {
    final RenderComboBoxField? field = render;
    if (field == null || !field.hasSize) return null;
    final Offset topLeft = field.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      field.size.width,
      field.size.height,
    );
  }
}

final class _ComboBoxFieldWidget extends RenderObjectWidget {
  const _ComboBoxFieldWidget({
    required this.label,
    required this.semanticsLabel,
    required this.anchor,
    required this.focusNode,
    required this.theme,
    required this.textDirection,
    required this.isOpen,
    required this.enabled,
    required this.itemCount,
    required this.selectedIndex,
    required this.styleClasses,
    required this.onActivate,
    required this.onKeyEvent,
    required this.onTextInput,
  });

  final String label;
  final String? semanticsLabel;
  final ComboBoxAnchor anchor;
  final FocusNode focusNode;
  final ThemeData theme;
  final TextDirection textDirection;
  final bool isOpen;
  final bool enabled;
  final int itemCount;
  final int selectedIndex;
  final Set<String> styleClasses;
  final void Function() onActivate;
  final bool Function(KeyEvent event) onKeyEvent;
  final bool Function(String text) onTextInput;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderComboBoxField createRenderObject(BuildContext context) =>
      RenderComboBoxField(anchor: anchor)
        ..label = label
        ..semanticsLabel = semanticsLabel
        ..textDirection = textDirection
        ..isOpen = isOpen
        ..itemCount = itemCount
        ..selectedIndex = selectedIndex
        ..onActivate = onActivate
        ..onKeyEvent = onKeyEvent
        ..onTextInput = onTextInput
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = enabled
        ..styleClasses = styleClasses;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderComboBoxField object,
  ) {
    object
      ..anchor = anchor
      ..label = label
      ..semanticsLabel = semanticsLabel
      ..textDirection = textDirection
      ..isOpen = isOpen
      ..itemCount = itemCount
      ..selectedIndex = selectedIndex
      ..onActivate = onActivate
      ..onKeyEvent = onKeyEvent
      ..onTextInput = onTextInput
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = enabled
      ..styleClasses = styleClasses;
  }
}

/// The closed field: a label, a chevron, and the keyboard.
final class RenderComboBoxField extends RenderBox
    with ControlBehavior
    implements TextInputTarget {
  RenderComboBoxField({required ComboBoxAnchor anchor}) : _anchor = anchor {
    anchor.render = this;
  }

  ComboBoxAnchor _anchor;
  String _label = '';
  String? semanticsLabel;
  TextDirection _textDirection = TextDirection.leftToRight;
  bool _isOpen = false;
  int itemCount = 0;
  int selectedIndex = -1;
  void Function()? onActivate;
  bool Function(KeyEvent event)? onKeyEvent;
  bool Function(String text)? onTextInput;

  ComboBoxAnchor get anchor => _anchor;

  set anchor(ComboBoxAnchor value) {
    if (identical(value, _anchor)) return;
    if (identical(_anchor.render, this)) _anchor.render = null;
    _anchor = value..render = this;
  }

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsPaint();
  }

  bool get isOpen => _isOpen;

  set isOpen(bool value) {
    if (value == _isOpen) return;
    _isOpen = value;
    markNeedsPaint();
  }

  /// The width the chevron and its breathing room occupy.
  ///
  /// Two thirds of a control - the same fraction [RenderExpander] uses, so the
  /// two chevrons in one window are the same drawing at the same size.
  double get chevronExtent =>
      (theme.effectiveControlHeight * 0.66).roundToDouble();

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_isOpen) PseudoClass.expanded,
      };

  @override
  void activate() => onActivate?.call();

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (!enabled) return false;
    if (onKeyEvent?.call(event) ?? false) return true;
    // Deliberately *not* falling through to ControlBehavior's Space/Enter: this
    // control's own handler already decided what those mean, and a second
    // interpretation would open a popup that Enter had just closed.
    return false;
  }

  @override
  bool handleTextInput(TextInputEvent event) =>
      enabled && (onTextInput?.call(event.text) ?? false);

  @override
  void performLayout() => size =
      constraints.constrain(labelledSize(_label, extraWidth: chevronExtent));

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    final double radius = theme.cornerRadius;
    paintRoundedFill(
      list,
      rect,
      enabled
          ? (isPressed || _isOpen
              ? theme.pressedSurface
              : (isHovered ? theme.hoverSurface : theme.surfaceAlternate))
          : theme.disabledSurface,
      radius,
    );
    // The outline of something you can aim at is [borderStrong], not the
    // hairline that separates two surfaces: a combo box drawn with the divider
    // colour disappears into the bar it sits in.
    paintRoundedBorder(
      list,
      rect,
      enabled
          ? (_isOpen ? theme.accent : theme.borderStrong)
          : theme.disabledForeground,
      radius,
      width: _isOpen ? 1.5 : 1,
    );

    final double padding = theme.effectiveControlPadding;
    final bool rtl = _textDirection.isRightToLeft;
    final double textWidth =
        (rect.width - chevronExtent - padding * 2).clamp(0.0, double.infinity);
    final Size labelBox = measureLabel(_label);
    final double textLeft =
        rtl ? rect.right - padding - textWidth : rect.left + padding;
    paintLabel(
      list,
      _label,
      Offset(
        rtl
            ? (textLeft + textWidth - labelBox.width).roundToDouble()
            : textLeft.roundToDouble(),
        labelTopIn(rect),
      ),
      foregroundColor(),
      maxWidth: textWidth,
    );

    _paintChevron(
      list,
      Rect.fromLTWH(
        rtl
            ? rect.left + padding / 2
            : rect.right - chevronExtent - padding / 2,
        rect.top,
        chevronExtent,
        rect.height,
      ),
    );
    paintFocusRing(list, rect, radius: radius);
  }

  /// A downward chevron: two strokes meeting at a point.
  ///
  /// A stack of bars - which is what this drew before - is a solid triangle,
  /// and a solid triangle in a combo box is the single most recognisable mark
  /// of a 1995 interface. Two mitred strokes is the mark every current desktop
  /// draws, and [paintPolylineMark] keeps it on the pixel grid.
  void _paintChevron(DisplayList list, Rect box) {
    final double span = (box.height * 0.28).clamp(3.0, 6.0).roundToDouble();
    final double centreX = (box.left + box.width / 2).roundToDouble();
    final double centreY = (box.top + box.height / 2).roundToDouble();
    final double top = _isOpen ? centreY + span / 2 : centreY - span / 2;
    final double tip = _isOpen ? centreY - span / 2 : centreY + span / 2;
    paintPolylineMark(
      list,
      <Offset>[
        Offset(centreX - span, top),
        Offset(centreX, tip),
        Offset(centreX + span, top),
      ],
      1.5,
      enabled ? theme.foregroundSecondary : theme.disabledForeground,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        // There is no `comboBox` role in `semantics.dart` and this control does
        // not get to add one - the semantic vocabulary is owned by that file.
        // `button` plus `expanded` plus `showMenu` is what the platform bridges
        // map a combo box onto anyway, and the value is the selected item, so a
        // screen reader announces "Country, Brazil, collapsed".
        role: SemanticsRole.button,
        label: semanticsLabel,
        value: _label,
        hint: itemCount == 0
            ? null
            : selectedIndex < 0
                ? '$itemCount items'
                : 'item ${selectedIndex + 1} of $itemCount',
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
          if (_isOpen) SemanticsState.expanded,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.activate,
                SemanticsAction.focus,
                SemanticsAction.showMenu,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );

  @override
  void detach() {
    if (identical(_anchor.render, this)) _anchor.render = null;
    super.detach();
  }
}
