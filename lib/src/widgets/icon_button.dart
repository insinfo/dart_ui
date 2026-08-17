/// A Flutter-shaped icon button backed by dart_ui's control system.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'icon.dart';
import 'semantics.dart';
import 'theme.dart';
import 'widget.dart';

final class IconButton extends StatefulWidget {
  const IconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 20,
    this.color,
    this.disabledColor,
    this.padding = const EdgeInsets.all(8),
    this.constraints,
  });

  final Widget icon;
  final void Function()? onPressed;
  final String? tooltip;
  final double iconSize;
  final int? color;
  final int? disabledColor;
  final EdgeInsets padding;
  final BoxConstraints? constraints;

  @override
  State<IconButton> createState() => _IconButtonState();
}

final class _IconButtonState extends State<IconButton> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'IconButton');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int foreground = widget.onPressed == null
        ? widget.disabledColor ?? theme.disabledForeground
        : widget.color ?? theme.iconTheme.color ?? theme.foreground;
    return FocusAttachment(
      node: _focusNode,
      child: _IconButtonRenderWidget(
        onPressed: widget.onPressed,
        tooltip: widget.tooltip,
        padding: widget.padding,
        additionalConstraints:
            widget.constraints ?? BoxConstraints(minWidth: 40, minHeight: 40),
        theme: theme,
        focusNode: _focusNode,
        child: IconTheme(
          data: IconThemeData(color: foreground, size: widget.iconSize),
          child: widget.icon,
        ),
      ),
    );
  }
}

final class _IconButtonRenderWidget extends SingleChildRenderObjectWidget {
  const _IconButtonRenderWidget({
    required this.onPressed,
    required this.tooltip,
    required this.padding,
    required this.additionalConstraints,
    required this.theme,
    required this.focusNode,
    required super.child,
  });

  final void Function()? onPressed;
  final String? tooltip;
  final EdgeInsets padding;
  final BoxConstraints additionalConstraints;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderIconButton createRenderObject(BuildContext context) => RenderIconButton(
        onPressed: onPressed,
        padding: padding,
        additionalConstraints: additionalConstraints,
        tooltip: tooltip,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onPressed != null;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderIconButton object,
  ) {
    object
      ..onPressed = onPressed
      ..padding = padding
      ..additionalConstraints = additionalConstraints
      ..tooltip = tooltip
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onPressed != null;
  }
}

final class RenderIconButton extends RenderSingleChildBox with ControlBehavior {
  RenderIconButton({
    required this.onPressed,
    required EdgeInsets padding,
    required BoxConstraints additionalConstraints,
    this.tooltip,
    super.child,
  })  : _padding = padding,
        _additionalConstraints = additionalConstraints;

  void Function()? onPressed;
  String? tooltip;
  EdgeInsets _padding;
  BoxConstraints _additionalConstraints;

  EdgeInsets get padding => _padding;

  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  BoxConstraints get additionalConstraints => _additionalConstraints;

  set additionalConstraints(BoxConstraints value) {
    if (value == _additionalConstraints) return;
    _additionalConstraints = value;
    markNeedsLayout();
  }

  @override
  void activate() => onPressed?.call();

  @override
  void performLayout() {
    final BoxConstraints effective =
        _additionalConstraints.enforce(constraints);
    final RenderBox? child = this.child;
    if (child == null) {
      size = effective.constrain(Size(
        _padding.horizontal,
        _padding.vertical,
      ));
      return;
    }
    child.layout(effective.deflate(_padding), parentUsesSize: true);
    size = effective.constrain(Size(
      child.size.width + _padding.horizontal,
      child.size.height + _padding.vertical,
    ));
    child.parentData!.offset = Offset(
      math.max(_padding.left, (size.width - child.size.width) / 2),
      math.max(_padding.top, (size.height - child.size.height) / 2),
    );
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    if (isPressed || isHovered) {
      final int fill = isPressed ? theme.disabledSurface : theme.surface;
      list.drawRRectUniform(
        rect.left,
        rect.top,
        rect.right,
        rect.bottom,
        theme.cornerRadius,
        theme.cornerRadius,
        list.addPaint(colorArgb: fill, antiAlias: true),
      );
    }
    if (isFocusVisible) {
      paintFocusRing(list, rect);
    }
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.button,
        label: tooltip,
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.activate,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}
