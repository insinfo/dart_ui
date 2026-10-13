/// A breadcrumb address bar - Windows 11 File Explorer's, a browser's
/// location: where you are as a row of clickable steps from the root, each
/// followed by a chevron that lists what lies below it, and a text field in
/// the same place for typing an address.
library;

import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_flex.dart' as layout;
import '../platform/key_gesture.dart';
import '../rendering/text/font_registry.dart';
import '../text/typeface.dart';
import 'basic.dart';
import 'callback_shortcuts.dart';
import 'focus.dart';
import 'gesture_detector.dart';
import 'hover.dart';
import 'icon.dart';
import 'layout_builder.dart';
import 'menu_anchor.dart';
import 'phosphor_icons.dart';
import 'proxy.dart';
import 'text_field.dart';
import 'theme.dart';
import 'widget.dart';

/// One step of a [BreadcrumbBar].
final class BreadcrumbItem {
  const BreadcrumbItem({required this.label, this.icon, this.id});

  final String label;

  /// Drawn before the label; usually only the first step has one.
  final IconData? icon;

  final Object? id;
}

/// Lets the window put a [BreadcrumbBar] into typing mode - Ctrl+L, Alt+D.
final class BreadcrumbController {
  _BreadcrumbBarState? _state;

  /// Shows the address as text, selected, with the keyboard in it.
  void edit() => _state?._beginEdit();

  bool get isEditing => _state?._editing ?? false;
}

/// The address bar. Controlled: it shows [items], root first, and reports
/// a step chosen, a chevron opened and an address typed.
final class BreadcrumbBar extends StatefulWidget {
  const BreadcrumbBar({
    super.key,
    required this.items,
    this.onSelected,
    this.childrenMenu,
    this.editText,
    this.onSubmitted,
    this.leading,
    this.height,
    this.controller,
    this.radius,
    this.trailing,
  });

  final List<BreadcrumbItem> items;

  final BreadcrumbController? controller;

  /// A step was clicked: go there.
  final void Function(int index)? onSelected;

  /// The menu behind the chevron after step [index] - what is inside it.
  /// Built only when that chevron is opened, so a slow listing is paid for
  /// once, by the user who asked. Null shows plain separators.
  final List<Widget> Function(int index)? childrenMenu;

  /// What the field shows when the bar is clicked to type an address - the
  /// full path. Null makes the bar read-only.
  final String? editText;

  /// An address was typed and confirmed with Enter.
  final void Function(String text)? onSubmitted;

  /// Drawn at the start of the bar - the icon of the current location.
  final Widget? leading;

  final double? height;

  /// The corner radius; null for the theme's. Half the height makes the
  /// pill Files and the Windows 11 search box are drawn as.
  final double? radius;

  /// Drawn at the end of the bar, typing mode included - a search button.
  final Widget? trailing;

  @override
  State<BreadcrumbBar> createState() => _BreadcrumbBarState();
}

final class _BreadcrumbBarState extends State<BreadcrumbBar> {
  bool _editing = false;
  final TextEditingController _text = TextEditingController('');
  final FocusNode _field = FocusNode(debugLabel: 'BreadcrumbBar field');

  /// The chevron whose menu is open, or null.
  int? _openChevron;

  /// Whether the overflow menu of collapsed steps is open.
  bool _overflowOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    // Clicking away from the field leaves the address as it was.
    _field.addListener(_onFocus);
  }

  void _onFocus(FocusNode node) {
    if (!node.hasPrimaryFocus) _endEdit();
  }

  @override
  void didUpdateWidget(BreadcrumbBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Going somewhere else - a click in a navigation pane, Back - leaves
    // the address being typed: what was half typed was about the place the
    // window just left.
    if (_editing && oldWidget.editText != widget.editText) {
      _editing = false;
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      if (identical(oldWidget.controller?._state, this)) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller?._state, this)) {
      widget.controller?._state = null;
    }
    _field
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  void _beginEdit() {
    final String? text = widget.editText;
    if (text == null) return;
    setState(() {
      _editing = true;
      _text
        ..value = text
        ..selectAll();
    });
    _field.requestFocus();
  }

  void _endEdit() {
    if (!_editing) return;
    setState(() => _editing = false);
  }

  void _submit(String text) {
    _endEdit();
    widget.onSubmitted?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double height = widget.height ?? theme.effectiveControlHeight;
    final double radius = widget.radius ?? theme.cornerRadius;
    final Widget body = _editing
        ? CallbackShortcuts(
            bindings: <KeyGesture, void Function()?>{
              const KeyGesture(logicalKeyEscape): _endEdit,
            },
            child: TextField(
              controller: _text,
              focusNode: _field,
              onSubmitted: _submit,
              decorated: false,
            ),
          )
        : GestureDetector(
            behavior: GestureHitTestBehavior.opaque,
            // The empty part of the bar types an address, as in Explorer.
            onTap: _beginEdit,
            child: Padding(
              padding: EdgeInsets.only(left: radius > 8 ? 10 : 6, right: 6),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    _steps(theme, constraints.maxWidth - 12),
              ),
            ),
          );
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceAlternate,
          border: BoxBorder(
              color: _editing ? theme.accent : theme.border, width: 1),
          radius: radius,
        ),
        child: Row(
          crossAxisAlignment: layout.CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: _editing
                  ? Padding(
                      padding: EdgeInsets.only(left: radius > 8 ? 6 : 0),
                      child: body,
                    )
                  : body,
            ),
            if (widget.trailing != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Center(child: widget.trailing!),
              ),
          ],
        ),
      ),
    );
  }

  /// The widths a step and its chevron take - measured with the label face,
  /// so what fits is decided by the text that will be drawn.
  double _stepWidth(ThemeData theme, BreadcrumbItem item) {
    final double size = theme.fontSize;
    final ScaledTypeface? font = FontRegistry.instance.uiFont(size);
    final double text = font == null
        ? FontRegistry.estimatedSize(item.label, size).width
        : uiTextPainter.measure(item.label, font).width;
    final double icon = item.icon == null ? 0 : theme.iconSize + 6;
    return text + icon + 16 + (widget.childrenMenu == null ? 14 : 22);
  }

  Widget _steps(ThemeData theme, double available) {
    final List<BreadcrumbItem> items = widget.items;
    double room = available - (widget.leading == null ? 0 : theme.iconSize + 8);
    // From the current step backwards, as many as fit; the rest collapse
    // into the overflow menu at the front.
    var first = items.length;
    final double overflow = theme.iconSize + 22;
    for (var i = items.length - 1; i >= 0; i--) {
      final double width = _stepWidth(theme, items[i]);
      final double reserve = i > 0 ? overflow : 0;
      if (width + reserve > room && first < items.length) break;
      room -= width;
      first = i;
    }
    return Row(
      crossAxisAlignment: layout.CrossAxisAlignment.center,
      children: <Widget>[
        if (widget.leading != null) ...<Widget>[
          widget.leading!,
          const SizedBox(width: 6),
        ],
        if (first > 0) _overflowButton(theme, first),
        for (var i = first; i < items.length; i++) ...<Widget>[
          Flexible(child: _step(theme, i)),
          _chevron(theme, i),
        ],
      ],
    );
  }

  Widget _step(ThemeData theme, int index) {
    final BreadcrumbItem item = widget.items[index];
    final bool current = index == widget.items.length - 1;
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: () => widget.onSelected?.call(index),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: hovered ? theme.hoverSurface : null,
            radius: theme.cornerRadiusSmall,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              mainAxisSize: layout.MainAxisSize.min,
              crossAxisAlignment: layout.CrossAxisAlignment.center,
              children: <Widget>[
                if (item.icon != null) ...<Widget>[
                  Icon(item.icon!, color: theme.foregroundSecondary),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    item.label,
                    style: theme.textTheme.bodyMedium,
                    color: current ? theme.foreground : theme.foreground,
                    maxLines: 1,
                    ellipsis: '…',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chevron(ThemeData theme, int index) {
    final List<Widget> Function(int index)? menu = widget.childrenMenu;
    final Widget glyph = Icon(PhosphorIcons.caretRight,
        size: theme.iconSize - 4, color: theme.foregroundSecondary);
    if (menu == null) {
      return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3), child: glyph);
    }
    final bool open = _openChevron == index;
    return MenuAnchor(
      menuChildren: open ? menu(index) : const <Widget>[],
      onClose: () {
        if (mounted && _openChevron == index) {
          setState(() => _openChevron = null);
        }
      },
      builder: (BuildContext context, MenuController controller, _) =>
          _ChevronButton(
        open: open,
        glyph: open
            ? Icon(PhosphorIcons.caretDown,
                size: theme.iconSize - 4, color: theme.foregroundSecondary)
            : glyph,
        onPressed: () {
          setState(() => _openChevron = index);
          controller.open();
        },
      ),
    );
  }

  Widget _overflowButton(ThemeData theme, int hidden) => MenuAnchor(
        menuChildren: _overflowOpen
            ? <Widget>[
                for (var i = hidden - 1; i >= 0; i--)
                  MenuItemButton(
                    leadingIcon: widget.items[i].icon == null
                        ? null
                        : Icon(widget.items[i].icon!),
                    onPressed: () => widget.onSelected?.call(i),
                    child: Text(widget.items[i].label),
                  ),
              ]
            : const <Widget>[],
        onClose: () {
          if (mounted) setState(() => _overflowOpen = false);
        },
        builder: (BuildContext context, MenuController controller, _) =>
            _ChevronButton(
          open: _overflowOpen,
          glyph: Icon(PhosphorIcons.caretDoubleLeft,
              size: theme.iconSize - 2, color: theme.foregroundSecondary),
          onPressed: () {
            setState(() => _overflowOpen = true);
            controller.open();
          },
        ),
      );
}

final class _ChevronButton extends StatelessWidget {
  const _ChevronButton({
    required this.open,
    required this.glyph,
    required this.onPressed,
  });

  final bool open;
  final Widget glyph;
  final void Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: open
                ? theme.pressedSurface
                : hovered
                    ? theme.hoverSurface
                    : null,
            radius: theme.cornerRadiusSmall,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: glyph,
          ),
        ),
      ),
    );
  }
}
