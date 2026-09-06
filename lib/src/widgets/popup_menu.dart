/// Flutter's popup-menu API - [showMenu], [PopupMenuButton], [PopupMenuItem],
/// [PopupMenuDivider] - over this framework's popup host.
///
/// `menu.dart` already had a menu, and it is a different shape: [MenuItem] is
/// *data*, a label and a callback, which is what a menu bar and a text field's
/// context menu want, because they build their items from a command table.
/// Flutter's popup menu is *widgets* - each entry is a subtree the caller
/// supplies - which is what an application that puts a checkbox, an icon or a
/// two-line row inside a menu entry needs. Neither shape subsumes the other, so
/// this file adds the second one rather than bending the first, and the two
/// share the host underneath.
///
/// ## The contract that matters is the null
///
/// [showMenu] returns a future that completes with the chosen value, or with
/// **null when the menu went away without a choice**. Everything else here is
/// arrangement; that null is the API. [PopupMenuButton.onCanceled] is built
/// entirely from it, and a caller who awaits the future is entitled to be
/// resumed exactly once however the menu closed.
///
/// "However it closed" is the hard part, because those routes race by design:
/// a click outside dismisses through [PopupStack], Escape dismisses through the
/// window, `closeAll` dismisses on deactivation, and choosing an item closes
/// the popup itself - and two of them can describe the same gesture. So the
/// completion is wired to exactly one place, [PopupSpec.onDismiss], which
/// `InTreePopupHandle` already guarantees fires once; the chosen value is
/// recorded on the way past and read there. Completing from the item's tap
/// handler instead would be one line shorter and would throw
/// "Future already completed" the first time a user clicked an item on a menu
/// that was closing.
///
/// ## Position
///
/// [showMenu]'s `position` is a [RelativeRect] against the owner *window*,
/// where Flutter measures against the overlay. That is the same rectangle in
/// every application that fills its window, and it is the only space this
/// framework's popups have in common - see `PopupSpec.anchorRect`, which is
/// documented as the window's logical space precisely because a Wayland client
/// cannot express a screen coordinate. The conversion needs the window's size,
/// which arrives through [MediaQuery]; a tree with no [MediaQuery] gets the
/// named error from `MediaQuery.of` rather than a menu placed against a
/// guessed zero-size window.
library;

import 'dart:async';

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/relative_rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../semantics/semantics.dart';
import 'basic.dart';
import 'control.dart';
import 'element.dart';
import 'icon.dart';
import 'media_query.dart';
import 'popup.dart';
import 'popup_host.dart';
import 'style.dart';
import 'theme.dart';
import 'tooltip.dart';
import 'widget.dart';

/// The smallest a menu row may be, and Flutter's default for
/// [PopupMenuItem.height].
///
/// Kept at Flutter's 48 rather than lowered to this framework's desktop row
/// height: a menu that came out visibly denser than the one in the application
/// being ported is a silent layout change, and a caller who wants the desktop
/// density can say so per item - which they cannot do if the constant lies.
const double kMinInteractiveDimension = 48.0;

/// One entry of a popup menu.
///
/// [height] and [represents] exist for exactly one caller: [showMenu] with an
/// `initialValue`, which walks the entries to find the selected one and lines
/// it up over the requested position. They are on the base class rather than
/// on [PopupMenuItem] because the walk has to skip dividers, and skipping them
/// means asking them how tall they are.
abstract class PopupMenuEntry<T> extends StatelessWidget {
  const PopupMenuEntry({super.key});

  /// The vertical space this entry occupies.
  double get height;

  /// Whether this entry stands for [value].
  bool represents(T? value);
}

/// A selectable row in a popup menu.
///
/// Not `final`, matching Flutter, where `CheckedPopupMenuItem` extends it and
/// applications routinely write their own. The rest of this file is `final`
/// because nothing outside it has a reason to specialize a divider or a
/// surface.
class PopupMenuItem<T> extends PopupMenuEntry<T> {
  const PopupMenuItem({
    super.key,
    this.value,
    this.enabled = true,
    this.onTap,
    this.height = kMinInteractiveDimension,
    required this.child,
  });

  /// What [showMenu] completes with when this row is chosen.
  ///
  /// Null is a legal value and it is indistinguishable, at the future, from a
  /// dismissal. That is Flutter's behaviour and it is left alone: an entry
  /// whose value is null is an entry the caller has said carries no answer.
  final T? value;

  /// Whether the row can be chosen. A disabled row still occupies its space
  /// and still reads as a menu item; it simply never activates.
  final bool enabled;

  /// Called when the row is chosen, before the menu completes.
  final void Function()? onTap;

  /// The minimum height of the row.
  @override
  final double height;

  final Widget child;

  @override
  bool represents(T? value) => value == this.value;

  @override
  Widget build(BuildContext context) {
    final _PopupMenuScope? scope = _PopupMenuScope.maybeOf(context);
    final Object? initial = scope?.initialValue;
    return _PopupMenuItemSurface(
      theme: Theme.of(context),
      minHeight: height,
      enabled: enabled,
      // `is T` rather than a cast: the scope carries the initial value as an
      // Object? because it is shared by every entry type in the menu, and a
      // cast would throw on a menu whose entries do not all agree about T.
      selected: initial is T && represents(initial),
      onActivate: () {
        onTap?.call();
        scope?.select(value);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: child,
      ),
    );
  }
}

/// A horizontal rule between groups of entries.
///
/// `PopupMenuEntry<Never>` so that one divider can sit in a menu of any value
/// type: [Never] is a subtype of every type, so `PopupMenuDivider` is a
/// `PopupMenuEntry<T>` for every `T` with no cast at the call site. That is
/// also why [represents] takes `void` - the widened parameter keeps the
/// override sound when [showMenu] asks a divider about a value of the menu's
/// own type.
final class PopupMenuDivider extends PopupMenuEntry<Never> {
  const PopupMenuDivider({super.key, this.height = 16});

  @override
  final double height;

  @override
  bool represents(void value) => false;

  @override
  Widget build(BuildContext context) =>
      _PopupMenuDividerSurface(theme: Theme.of(context), height: height);
}

// ---------------------------------------------------------------------------
// showMenu
// ---------------------------------------------------------------------------

/// Opens a popup menu at [position] and completes with what the user chose.
///
/// Completes with null when the menu was dismissed without a choice, exactly
/// once, whichever route closed it. See the library comment for why that is
/// wired through [PopupSpec.onDismiss] and not through the item's tap.
///
/// [elevation] is accepted and ignored: this framework's popup surfaces have no
/// shadow to raise - `BoxDecoration` declares shadows absent by name - so the
/// argument exists so that a Flutter call site compiles, and doing nothing is
/// more honest than mapping it onto some other visual property.
Future<T?> showMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  double? elevation,
  String? semanticLabel,
}) {
  // `of` and not `maybeOf`: a menu that silently opened nothing would read as
  // a broken control, and the fix - wrap the tree in a host - is not
  // discoverable from a menu that never appeared. The opposite call is right
  // for a tooltip, and `popup_host.dart` says why.
  final PopupHost host = PopupHost.of(context);
  final Size window = MediaQuery.of(context).size;
  final Rect anchor = position.toRect(
    Rect.fromLTWH(0, 0, window.width, window.height),
  );

  final Completer<T?> completer = Completer<T?>();
  T? chosen;
  PopupHandle? handle;

  final PopupSpec spec = PopupSpec(
    anchorRect: anchor,
    kind: PopupKind.menu,
    // Top-left to top-left: `position` already describes the rectangle the
    // menu should occupy, so the menu starts where the caller put it rather
    // than hanging off an edge of it.
    anchorPoint: PopupAnchorPoint.topLeft,
    popupPoint: PopupAnchorPoint.topLeft,
    // The whole set. A menu near the right edge of the window must flip rather
    // than be cropped, and near the bottom it must slide; a tooltip can afford
    // to be fussier because it carries no commands.
    adjustments: const <PopupAdjustment>{
      PopupAdjustment.flipY,
      PopupAdjustment.flipX,
      PopupAdjustment.slideX,
      PopupAdjustment.slideY,
    },
    offset: Offset(0, -_selectedEntryCentre(items, initialValue)),
    onDismiss: () {
      // The single completion point. `InTreePopupHandle` fires this exactly
      // once however the popup left the stack, so the guard below is belt and
      // braces for a host that is less careful.
      if (!completer.isCompleted) completer.complete(chosen);
    },
    builder: (BuildContext popupContext) => _PopupMenuScope(
      initialValue: initialValue,
      select: (Object? value) {
        chosen = value as T?;
        // Closing is what completes the future; recording the value first is
        // what makes it complete with something other than null.
        handle?.close();
      },
      child: _PopupMenuSurface(
        theme: Theme.of(popupContext),
        semanticLabel: semanticLabel,
        children: List<Widget>.of(items),
      ),
    ),
  );

  handle = host.open(spec);
  return completer.future;
}

/// How far down the menu the entry standing for [initialValue] sits.
///
/// Flutter lines the selected entry up with the requested position, so that a
/// menu reopened on a value comes up with that value under the pointer instead
/// of forcing the eye back to the top. Zero when nothing is selected, which is
/// the ordinary case and costs nothing.
double _selectedEntryCentre<T>(List<PopupMenuEntry<T>> items, T? initialValue) {
  if (initialValue == null) return 0;
  double y = 0;
  for (final PopupMenuEntry<T> entry in items) {
    if (entry.represents(initialValue)) return y + entry.height / 2;
    y += entry.height;
  }
  return 0;
}

/// Carries the menu's completion callback down to entries the caller built.
///
/// Deliberately not generic. The entries in one menu all carry the menu's own
/// type argument, but a [PopupMenuDivider] among them carries `Never` instead,
/// and an inherited widget looked up by exact type would have to agree with
/// every entry about that argument. `Object?` in, cast once at the top, where
/// the type argument is actually known.
final class _PopupMenuScope extends InheritedWidget {
  const _PopupMenuScope({
    required this.select,
    required this.initialValue,
    required super.child,
  });

  final void Function(Object? value) select;
  final Object? initialValue;

  static _PopupMenuScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PopupMenuScope>();

  @override
  bool updateShouldNotify(_PopupMenuScope oldWidget) =>
      !identical(oldWidget.select, select) ||
      oldWidget.initialValue != initialValue;
}

// ---------------------------------------------------------------------------
// PopupMenuButton
// ---------------------------------------------------------------------------

/// A control that opens a popup menu under itself.
///
/// The item list is built on demand rather than held, which is Flutter's shape
/// and the right one: what a menu offers usually depends on what is selected
/// at the moment it is opened, and a held list is a list that goes stale.
final class PopupMenuButton<T> extends StatefulWidget {
  const PopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.initialValue,
    this.onSelected,
    this.onCanceled,
    this.tooltip,
    this.child,
    this.icon,
    this.offset = Offset.zero,
    this.enabled = true,
  });

  final List<PopupMenuEntry<T>> Function(BuildContext context) itemBuilder;

  /// The value the menu comes up on, lined up with the button.
  final T? initialValue;

  final void Function(T value)? onSelected;

  /// Called when the menu closed with no choice - which is [showMenu]'s null
  /// and nothing else.
  final void Function()? onCanceled;

  final String? tooltip;

  /// What the button shows. [child] wins over [icon]; with neither, a vertical
  /// ellipsis, as in Flutter.
  final Widget? child;
  final Widget? icon;

  /// Shifts the menu from the button's own rectangle.
  final Offset offset;

  final bool enabled;

  @override
  State<PopupMenuButton<T>> createState() => _PopupMenuButtonState<T>();
}

final class _PopupMenuButtonState<T> extends State<PopupMenuButton<T>> {
  _RenderPopupMenuButtonTarget? _box;

  @override
  Widget build(BuildContext context) {
    Widget content = widget.child ??
        widget.icon ??
        // A family that is not installed resolves to no face and draws
        // nothing, rather than throwing - see `RenderIcon.font` - so this
        // default is safe in an application that never registered an icon
        // font, which is the state a freshly ported Flutter application is in.
        const Icon(Icons.moreVert);
    final String? tooltip = widget.tooltip;
    if (tooltip != null) {
      content = Tooltip(message: tooltip, child: content);
    }
    return _PopupMenuButtonTarget(
      theme: Theme.of(context),
      enabled: widget.enabled,
      onAttached: (_RenderPopupMenuButtonTarget box) => _box = box,
      onActivate: _open,
      child: content,
    );
  }

  void _open() {
    final _RenderPopupMenuButtonTarget? box = _box;
    if (box == null || !box.hasSize) return;
    final Size window = MediaQuery.of(context).size;
    final Offset topLeft = box.localToGlobal(Offset.zero) + widget.offset;
    // The button's own rectangle, expressed against the window. It goes out as
    // a RelativeRect and comes straight back as a Rect inside `showMenu`,
    // which looks like a round trip and is one on purpose: `position` is the
    // public seam, and a caller who wants a menu somewhere else passes their
    // own RelativeRect to the same function.
    final RelativeRect position = RelativeRect.fromSize(
      Rect.fromLTWH(topLeft.dx, topLeft.dy, box.size.width, box.size.height),
      window,
    );
    final List<PopupMenuEntry<T>> items = widget.itemBuilder(context);
    if (items.isEmpty) return;
    unawaited(showMenu<T>(
      context: context,
      position: position,
      items: items,
      initialValue: widget.initialValue,
    ).then((T? value) {
      if (!mounted) return;
      if (value == null) {
        widget.onCanceled?.call();
      } else {
        widget.onSelected?.call(value);
      }
    }));
  }
}

final class _PopupMenuButtonTarget extends SingleChildRenderObjectWidget {
  const _PopupMenuButtonTarget({
    required this.theme,
    required this.enabled,
    required this.onAttached,
    required this.onActivate,
    required super.child,
  });

  final ThemeData theme;
  final bool enabled;
  final void Function(_RenderPopupMenuButtonTarget box) onAttached;
  final void Function() onActivate;

  @override
  _RenderPopupMenuButtonTarget createRenderObject(BuildContext context) {
    final _RenderPopupMenuButtonTarget box =
        _RenderPopupMenuButtonTarget(onActivate: onActivate)
          ..theme = theme
          ..enabled = enabled;
    // Same handshake as the tooltip's trigger: the State needs a render object
    // to ask where the button is on screen, and a BuildContext here has no
    // `findRenderObject`.
    onAttached(box);
    return box;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPopupMenuButtonTarget renderObject,
  ) {
    renderObject
      ..onActivate = onActivate
      ..theme = theme
      ..enabled = enabled;
    onAttached(renderObject);
  }
}

final class _RenderPopupMenuButtonTarget extends RenderSingleChildBox
    with ControlBehavior {
  _RenderPopupMenuButtonTarget({required this.onActivate});

  void Function() onActivate;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = child.size;
  }

  /// True so the whole button answers the pointer, including the gaps around
  /// an icon that is not itself hit-testable.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void activate() => onActivate();

  @override
  SemanticsConfiguration describeSemantics() => const SemanticsConfiguration(
        role: SemanticsRole.button,
        actions: <SemanticsAction>{
          SemanticsAction.activate,
          SemanticsAction.showMenu,
        },
      );
}

// ---------------------------------------------------------------------------
// The surface
// ---------------------------------------------------------------------------

final class _PopupMenuSurface extends MultiChildRenderObjectWidget {
  const _PopupMenuSurface({
    required this.theme,
    required this.semanticLabel,
    required super.children,
  });

  final ThemeData theme;
  final String? semanticLabel;

  @override
  _RenderPopupMenuSurface createRenderObject(BuildContext context) =>
      _RenderPopupMenuSurface()
        ..theme = theme
        ..semanticLabel = semanticLabel;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPopupMenuSurface renderObject,
  ) {
    renderObject
      ..theme = theme
      ..semanticLabel = semanticLabel;
  }
}

/// Stacks the entries in a column, all the same width, inside a raised card.
///
/// The width is the widest entry's *intrinsic* width rather than the result of
/// laying every entry out twice: a menu is small, but a two-pass layout here
/// would be a two-pass layout of whatever arbitrary subtree the caller put in
/// each row, and `Text` already answers the intrinsic question for free.
/// Every entry is then laid out at that one width, which is what makes a
/// hovered row a full-width bar instead of a highlight the shape of its label.
final class _RenderPopupMenuSurface extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  String? semanticLabel;

  /// The air above the first row and below the last, matching [RenderMenu].
  double get verticalPadding => 4;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void performLayout() {
    double width = 0;
    for (int i = 0; i < childCount; i++) {
      final double intrinsic = childAt(i).getMaxIntrinsicWidth(
        double.infinity,
      );
      if (intrinsic > width) width = intrinsic;
    }
    width = width.clamp(constraints.minWidth, constraints.maxWidth);

    double y = verticalPadding;
    final BoxConstraints rowConstraints = BoxConstraints(
      minWidth: width,
      maxWidth: width,
    );
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(rowConstraints, parentUsesSize: true);
      child.parentData!.offset = Offset(0, y);
      y += child.size.height;
    }
    size = constraints.constrain(Size(width, y + verticalPadding));
  }

  /// True: a press inside the menu belongs to the menu, and a row that has no
  /// hit target of its own - the gap beside a short label - must not let the
  /// press fall through to whatever the menu is covering.
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
    final double radius = theme.cornerRadiusLarge;
    paintRoundedFill(list, rect, theme.surfaceRaised, radius);
    paintRoundedBorder(list, rect, theme.border, radius);
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.menu,
        label: semanticLabel,
        value: '$childCount items',
      );
}

final class _PopupMenuItemSurface extends SingleChildRenderObjectWidget {
  const _PopupMenuItemSurface({
    required this.theme,
    required this.minHeight,
    required this.enabled,
    required this.selected,
    required this.onActivate,
    required super.child,
  });

  final ThemeData theme;
  final double minHeight;
  final bool enabled;
  final bool selected;
  final void Function() onActivate;

  @override
  _RenderPopupMenuItem createRenderObject(BuildContext context) =>
      _RenderPopupMenuItem(minHeight: minHeight, onActivate: onActivate)
        ..selected = selected
        ..theme = theme
        ..enabled = enabled;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPopupMenuItem renderObject,
  ) {
    renderObject
      ..minHeight = minHeight
      ..onActivate = onActivate
      ..selected = selected
      ..theme = theme
      ..enabled = enabled;
  }
}

final class _RenderPopupMenuItem extends RenderSingleChildBox
    with ControlBehavior {
  _RenderPopupMenuItem({
    required double minHeight,
    required this.onActivate,
  }) : _minHeight = minHeight;

  double _minHeight;
  bool _selected = false;

  void Function() onActivate;

  double get minHeight => _minHeight;

  set minHeight(double value) {
    if (value == _minHeight) return;
    _minHeight = value;
    markNeedsLayout();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  @override
  Set<PseudoClass> get controlStates =>
      _selected ? const <PseudoClass>{PseudoClass.selected} : const {};

  /// A row is never a tab stop. The menu as a whole holds the keyboard while
  /// it is open; a row that could be focused would put a second cursor in it.
  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    final double width = constraints.maxWidth;
    if (child == null) {
      size = Size(width, _minHeight);
      return;
    }
    child.layout(
      BoxConstraints(minWidth: width, maxWidth: width),
      parentUsesSize: true,
    );
    final double height =
        child.size.height > _minHeight ? child.size.height : _minHeight;
    child.parentData!.offset = Offset(0, (height - child.size.height) / 2);
    size = Size(width, height);
  }

  /// True: the whole row is the target, not just the label inside it. A menu
  /// where the click has to land on the text is a menu that feels broken.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void activate() => onActivate();

  @override
  void paint(DisplayList list, Offset offset) {
    if (enabled && (isHovered || _selected)) {
      // Inset, so the highlight is a pill inside the rounded card rather than
      // a bar that cuts the card's own corners off - the same reason
      // [RenderMenu] insets its highlight.
      const double inset = 4;
      paintRoundedFill(
        list,
        Rect.fromLTWH(
          offset.dx + inset,
          offset.dy,
          size.width - inset * 2,
          size.height,
        ),
        _selected ? theme.accentSubtle : theme.hoverSurface,
        theme.cornerRadiusSmall,
      );
    }
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.menuItem,
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (_selected) SemanticsState.selected,
        },
        actions: <SemanticsAction>{
          if (enabled) SemanticsAction.activate,
        },
      );
}

final class _PopupMenuDividerSurface extends RenderObjectWidget {
  const _PopupMenuDividerSurface({required this.theme, required this.height});

  final ThemeData theme;
  final double height;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  _RenderPopupMenuDivider createRenderObject(BuildContext context) =>
      _RenderPopupMenuDivider(height: height)..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPopupMenuDivider renderObject,
  ) {
    renderObject
      ..dividerHeight = height
      ..theme = theme;
  }
}

/// A hairline with air either side, and no hit target at all.
///
/// [hitTestSelf] is left false - the inherited default - which is the whole
/// mechanism behind "a divider is not selectable": it never enters the hit
/// path, so it is never pressed, never activated and never the thing a click
/// chose. Nothing checks a flag; there is simply nothing there to click.
final class _RenderPopupMenuDivider extends RenderBox with ControlBehavior {
  _RenderPopupMenuDivider({required double height}) : _height = height;

  double _height;

  double get dividerHeight => _height;

  set dividerHeight(double value) {
    if (value == _height) return;
    _height = value;
    markNeedsLayout();
  }

  @override
  void performLayout() =>
      size = constraints.constrain(Size(constraints.maxWidth, _height));

  @override
  void paint(DisplayList list, Offset offset) {
    const double inset = 8;
    final Color color = theme.borderSubtle;
    paintFill(
      list,
      Rect.fromLTWH(
        offset.dx + inset,
        (offset.dy + size.height / 2).roundToDouble(),
        size.width - inset * 2,
        1,
      ),
      color,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() =>
      // No role of its own: a separator is a visual grouping cue, and this
      // framework's role list has no member for one. Reporting `generic` with
      // no label keeps it out of the item count a screen reader reads.
      const SemanticsConfiguration(role: SemanticsRole.generic);
}
