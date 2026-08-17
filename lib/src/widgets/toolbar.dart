/// Reusable application toolbars with stable desktop alignment.
library;

import '../graphics/color.dart';
import '../layout/edge_insets.dart';
import '../layout/render_flex.dart';
import 'basic.dart';
import 'proxy.dart';
import 'theme.dart';
import 'widget.dart';

/// A themed, fixed-height surface for primary application actions.
///
/// Controls are vertically centred by the toolbar itself, so icon buttons,
/// labels and text fields with different intrinsic heights share one baseline
/// instead of making each application correct the same alignment by hand.
final class Toolbar extends StatelessWidget {
  const Toolbar({
    super.key,
    required this.child,
    this.height = 60,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.color,
    this.showBorder = true,
  });

  final Widget child;
  final double height;
  final EdgeInsets padding;
  final Color? color;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? theme.surfaceAlternate,
        border: showBorder ? BoxBorder(color: theme.border, width: 1) : null,
      ),
      child: SizedBox(
        height: height,
        child: Padding(
          padding: padding,
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// A compact row of related toolbar controls.
final class ToolbarGroup extends StatelessWidget {
  const ToolbarGroup({
    super.key,
    this.children = const <Widget>[],
    this.spacing = 4,
  });

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (var index = 0; index < children.length; index++) ...<Widget>[
            if (index > 0) SizedBox(width: spacing),
            children[index],
          ],
        ],
      );
}

/// A subtle separator between action groups.
final class ToolbarDivider extends StatelessWidget {
  const ToolbarDivider({super.key, this.height = 24, this.margin = 8});

  final double height;
  final double margin;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: margin * 2 + 1,
        child: Center(
          child: SizedBox(
            width: 1,
            height: height,
            child: ColoredBox(color: Theme.of(context).border),
          ),
        ),
      );
}
