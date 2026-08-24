/// Menus: the item model, the popup menu and its render object.
///
/// Split out of `controls.dart` for the reason stated in `text_field.dart`:
/// this is a block that separate pieces of work reach for at once, and
/// [MenuItem] in particular is needed by anything that offers a menu -
/// `context_menu.dart` builds one, and a text field builds its own.
///
/// `controls.dart` re-exports this file, so no existing import changes.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'semantics.dart';
import 'theme.dart';
import 'widget.dart';

/// One entry of a [Menu] or a [ContextMenu].
final class MenuItem {
  const MenuItem({
    required this.label,
    this.onSelected,
    this.enabled = true,
    this.isSeparator = false,
    this.disabledReason,
    this.shortcut,
    this.mnemonic,
  });

  const MenuItem.separator()
      : label = '',
        onSelected = null,
        enabled = false,
        isSeparator = true,
        disabledReason = null,
        shortcut = null,
        mnemonic = null;

  final String label;
  final void Function()? onSelected;
  final bool enabled;
  final bool isSeparator;

  /// Why this command is unavailable right now, for assistive technology.
  ///
  /// A dimmed item tells a sighted user *that* something is unavailable and
  /// never *why*; the reason is usually the only thing they actually need
  /// ("nothing is selected", "the field is read-only"). A screen reader has no
  /// dimming to go on at all, so without this it gets neither half.
  /// [RenderContextMenuItem] reports it as the node's hint.
  final String? disabledReason;

  /// The accelerator to show at the right of the row, as text: `Ctrl+C`.
  ///
  /// Display only. This does **not** bind anything - the control that owns the
  /// command already binds it - and writing a chord here that nothing listens
  /// for produces a menu that advertises a shortcut which does nothing.
  final String? shortcut;

  /// The letter that jumps to this item, when it is not [label]'s first one.
  final String? mnemonic;

  /// The letter initial-letter navigation matches, which is [mnemonic] or the
  /// first character of [label].
  String get mnemonicLetter {
    final String? explicit = mnemonic;
    if (explicit != null && explicit.isNotEmpty) return explicit[0];
    return label.isEmpty ? '' : label[0];
  }
}

/// A vertical list of commands, keyboard-navigable.
final class Menu extends StatefulWidget {
  const Menu({super.key, required this.items});

  final List<MenuItem> items;

  @override
  State<Menu> createState() => _MenuState();
}

final class _MenuState extends State<Menu> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Menu');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _MenuRenderWidget(
          items: widget.items,
          theme: Theme.of(context),
          focusNode: _focusNode,
        ),
      );
}

final class _MenuRenderWidget extends RenderObjectWidget {
  const _MenuRenderWidget({
    required this.items,
    required this.theme,
    required this.focusNode,
  });

  final List<MenuItem> items;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderMenu createRenderObject(BuildContext context) =>
      RenderMenu(items: items)
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(BuildContext context, covariant RenderMenu object) {
    object
      ..items = items
      ..theme = theme
      ..focusNode = focusNode;
  }
}

final class RenderMenu extends RenderBox with ControlBehavior {
  RenderMenu({required List<MenuItem> items}) : _items = items;

  /// The height of one command row.
  ///
  /// The theme's row height, so a menu is as dense as the list beside it. A
  /// menu with its own 20 px constant was a menu that stayed 20 px while every
  /// other collection in the window followed the density switch.
  double get itemHeight => theme.effectiveRowHeight;

  /// A separator is a hairline with a half-row of air either side of it.
  double get separatorHeight => (theme.effectiveGap * 2 + 1).roundToDouble();

  /// The inset of a highlighted row from the pop-up's edge.
  ///
  /// A highlight that runs edge to edge inside a rounded pop-up cuts its own
  /// corners off; inset by the gap it becomes a rounded pill sitting inside
  /// the menu, which is the shape every current desktop menu draws.
  double get highlightInset => 4;

  List<MenuItem> _items;
  int _highlighted = -1;

  List<MenuItem> get items => _items;

  set items(List<MenuItem> value) {
    _items = value;
    _highlighted = _highlighted.clamp(-1, value.length - 1);
    markNeedsLayout();
  }

  /// The item the keyboard cursor is on, or -1.
  int get highlightedIndex => _highlighted;

  /// The gap between the widest label and the accelerator column.
  ///
  /// Without it "Fit zoom to page" and "Shift+F4" would touch, and the eye
  /// would read them as one string.
  double get shortcutGap => Spacing.xl;

  /// The air above the first row and below the last.
  double get verticalPadding => 4;

  @override
  void performLayout() {
    double height = verticalPadding * 2;
    double width = 0;
    double shortcutWidth = 0;
    for (final MenuItem item in _items) {
      height += item.isSeparator ? separatorHeight : itemHeight;
      final double itemWidth = measureLabel(item.label).width;
      if (itemWidth > width) width = itemWidth;
      final String? shortcut = item.shortcut;
      if (shortcut != null && shortcut.isNotEmpty) {
        final double accelerator = measureLabel(shortcut).width;
        if (accelerator > shortcutWidth) shortcutWidth = accelerator;
      }
    }
    // The accelerator column is part of the menu's width, not an overhang: a
    // menu that measured labels only would clip every shortcut it advertises,
    // which is what [MenuItem.shortcut] was doing before this.
    if (shortcutWidth > 0) width += shortcutGap + shortcutWidth;
    size = constraints.constrain(
      Size(width + theme.effectiveControlPadding * 2, height),
    );
  }

  @override
  bool hitTestSelf(Offset position) => true;

  /// The item index at [y] within this menu, or -1.
  int indexAt(double y) {
    double cursor = verticalPadding;
    for (int i = 0; i < _items.length; i++) {
      final double extent =
          _items[i].isSeparator ? separatorHeight : itemHeight;
      if (y >= cursor && y < cursor + extent) {
        return _items[i].isSeparator ? -1 : i;
      }
      cursor += extent;
    }
    return -1;
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (event is PointerMoveEvent) {
      final int index = indexAt(globalToLocal(event.logicalPosition).dy);
      if (index != _highlighted) {
        _highlighted = index;
        markNeedsPaint();
      }
    }
  }

  @override
  void activate() {
    if (_highlighted < 0 || _highlighted >= _items.length) return;
    final MenuItem item = _items[_highlighted];
    if (item.enabled) item.onSelected?.call();
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowDown:
        _moveHighlight(1);
        return true;
      case logicalKeyArrowUp:
        _moveHighlight(-1);
        return true;
      case logicalKeyHome:
        _highlighted = -1;
        _moveHighlight(1);
        return true;
      case logicalKeyEnd:
        _highlighted = _items.length;
        _moveHighlight(-1);
        return true;
      default:
        return super.handleKeyEvent(event);
    }
  }

  /// Moves the highlight by [delta], skipping separators and disabled items.
  void _moveHighlight(int delta) {
    if (_items.isEmpty) return;
    int index = _highlighted;
    for (int step = 0; step < _items.length; step++) {
      index = (index + delta) % _items.length;
      if (index < 0) index += _items.length;
      final MenuItem item = _items[index];
      if (!item.isSeparator && item.enabled) {
        _highlighted = index;
        markNeedsPaint();
        return;
      }
    }
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    // A pop-up floats above the window, so it takes the raised surface, the
    // large radius and a single hairline - not the boxed-in look of a 1 px
    // grey rectangle around a white fill.
    final double radius = theme.cornerRadiusLarge;
    paintRoundedFill(list, rect, theme.surfaceRaised, radius);
    paintRoundedBorder(list, rect, theme.border, radius);
    final double inset = highlightInset;
    double y = offset.dy + verticalPadding;
    for (int i = 0; i < _items.length; i++) {
      final MenuItem item = _items[i];
      if (item.isSeparator) {
        paintFill(
          list,
          Rect.fromLTWH(
            offset.dx + inset,
            (y + separatorHeight / 2).roundToDouble(),
            size.width - inset * 2,
            1,
          ),
          theme.borderSubtle,
        );
        y += separatorHeight;
        continue;
      }
      final Rect row = Rect.fromLTWH(
        offset.dx + inset,
        y,
        size.width - inset * 2,
        itemHeight,
      );
      if (i == _highlighted) {
        paintRoundedFill(
          list,
          row,
          theme.accentSubtle,
          theme.cornerRadiusSmall,
        );
      }
      final Color foreground =
          !item.enabled ? theme.disabledForeground : theme.foreground;
      final double baseline = labelTopIn(row);
      paintLabel(
        list,
        item.label,
        Offset(offset.dx + theme.effectiveControlPadding, baseline),
        foreground,
      );

      // The accelerator, right-aligned in its own column and dimmer than the
      // command: it is a reminder, not a second command.
      final String? shortcut = item.shortcut;
      if (shortcut != null && shortcut.isNotEmpty) {
        final double shortcutWidth = measureLabel(shortcut).width;
        paintLabel(
          list,
          shortcut,
          Offset(
            offset.dx +
                size.width -
                theme.effectiveControlPadding -
                shortcutWidth,
            baseline,
          ),
          !item.enabled
              ? theme.disabledForeground
              : theme.foregroundSecondary,
        );
      }
      y += itemHeight;
    }
    paintFocusRing(list, rect, radius: radius);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.menu,
        value: '${_items.where((MenuItem i) => !i.isSeparator).length} items',
        actions: const <SemanticsAction>{
          SemanticsAction.focus,
          SemanticsAction.dismiss,
        },
      );
}
