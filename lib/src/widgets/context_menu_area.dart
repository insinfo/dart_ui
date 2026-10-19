/// A right-click menu with everything a menu bar's menus have: submenus,
/// icons, shortcuts, checked items and keyboard navigation.
library;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/render_box.dart';
import '../layout/render_proxy_box.dart';
import '../platform/input_events.dart';
import 'element.dart';
import 'menu_anchor.dart';
import 'pointer_router.dart';
import 'theme.dart';
import 'widget.dart';

/// Opens a menu of [MenuItemButton]s and [SubmenuButton]s where [child] is
/// right-clicked - a canvas's Cut/Copy/Paste/Order ›, a list row's Rename.
///
/// [menuChildren] is called on every build, so the menu shows the state as
/// it is when it opens. [onOpen] runs first with the press position in this
/// widget's coordinates - the place to select what is under the pointer, the
/// way every editor does before showing that object's menu.
final class ContextMenuArea extends StatefulWidget {
  const ContextMenuArea({
    super.key,
    required this.menuChildren,
    this.onOpen,
    this.enabled = true,
    required this.child,
  });

  final List<Widget> Function() menuChildren;
  final void Function(Offset localPosition)? onOpen;

  /// False makes a right click pass through, as if there were no menu.
  final bool enabled;
  final Widget child;

  @override
  State<ContextMenuArea> createState() => _ContextMenuAreaState();
}

final class _ContextMenuAreaState extends State<ContextMenuArea> {
  final MenuController _controller = MenuController();

  void _open(Offset local) {
    if (!widget.enabled) return;
    widget.onOpen?.call(local);
    _controller.open(position: local);
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
        controller: _controller,
        menuChildren: widget.menuChildren(),
        child: _SecondaryPress(
            enabled: widget.enabled, onPress: _open, child: widget.child),
      );
}

final class _SecondaryPress extends SingleChildRenderObjectWidget {
  const _SecondaryPress(
      {required this.enabled, required this.onPress, required super.child});

  final bool enabled;

  final void Function(Offset local) onPress;

  @override
  _RenderSecondaryPress createRenderObject(BuildContext context) =>
      _RenderSecondaryPress(onPress, enabled);

  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderSecondaryPress renderObject) {
    renderObject
      ..onPress = onPress
      ..enabled = enabled;
  }
}

/// Watches for a secondary press without claiming any other event, so the
/// child's own gestures are untouched.
final class _RenderSecondaryPress extends RenderProxyBox
    implements ConditionalPointerEventBarrier {
  _RenderSecondaryPress(this.onPress, this.enabled);

  bool enabled;

  @override
  bool stopsPointerEvent(PointerEvent event) =>
      enabled &&
      event is PointerDownEvent &&
      event.button == PointerButton.secondary;

  void Function(Offset local) onPress;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (!stopsPointerEvent(event)) {
      return;
    }
    onPress(globalToLocal(event.logicalPosition));
  }
}

/// A line between groups of items in a [MenuAnchor], [SubmenuButton] or
/// [ContextMenuArea] menu - not an item: the keyboard and the pointer pass
/// over it.
///
/// It asks for no width of its own, so a menu is as wide as its widest
/// item rather than as wide as the window, and draws across whatever width
/// the menu gives it.
final class MenuDivider extends SingleChildRenderObjectWidget {
  const MenuDivider({super.key});

  @override
  RenderBox createRenderObject(BuildContext context) =>
      _RenderMenuDivider(Theme.of(context));

  @override
  void updateRenderObject(BuildContext context, RenderBox renderObject) {
    (renderObject as _RenderMenuDivider).theme = Theme.of(context);
  }
}

final class _RenderMenuDivider extends RenderBox {
  _RenderMenuDivider(this._theme);

  ThemeData _theme;
  set theme(ThemeData value) {
    if (identical(value, _theme)) return;
    _theme = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    size = constraints.constrain(Size(constraints.minWidth, 9));
  }

  @override
  void paint(DisplayList list, Offset offset) {
    // The menu's own inset (`MenuLook`): in line with the highlight pills
    // on Windows, further in on macOS, where AppKit insets its separators.
    final double inset = MenuLook.of(_theme).separatorInset;
    final double y = offset.dy + (size.height / 2).floorToDouble();
    list.drawRect(offset.dx + inset, y, offset.dx + size.width - inset, y + 1,
        list.addPaint(colorArgb: _theme.borderSubtle.value));
  }
}
