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
    this.height,
    this.padding,
    this.color,
    this.showBorder = true,
  });

  final Widget child;

  /// Null takes the theme's: one control tall plus a gap of air either side,
  /// so a toolbar is as dense as the density says and not 60 px forever.
  final double? height;

  final EdgeInsets? padding;
  final Color? color;

  /// Whether to draw the hairline along the bottom edge.
  ///
  /// The *bottom* edge only. A box drawn on all four sides of every bar is the
  /// Windows 95 look in one line of code: stacked bars then show a two-pixel
  /// double rule where they meet, and the window reads as a pile of boxes
  /// instead of a set of surfaces.
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double barHeight =
        height ?? theme.effectiveControlHeight + theme.effectiveGap * 2;
    return SizedBox(
      height: barHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color ?? theme.surfaceAlternate),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: padding ??
                    EdgeInsets.symmetric(
                      horizontal: theme.effectiveGap,
                      vertical: Spacing.xs,
                    ),
                child: Center(child: child),
              ),
            ),
            if (showBorder)
              SizedBox(
                height: 1,
                child: ColoredBox(color: theme.border),
              ),
          ],
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
    this.spacing = Spacing.xs,
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
  const ToolbarDivider({super.key, this.height, this.margin});

  /// Null takes two thirds of a control's height: a rule as tall as the bar
  /// touches both edges and turns the bar into two boxes.
  final double? height;

  final double? margin;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double gap = margin ?? theme.effectiveGap;
    return SizedBox(
      width: gap * 2 + 1,
      child: Center(
        child: SizedBox(
          width: 1,
          height: height ??
              (theme.effectiveControlHeight * 0.6 / 2).roundToDouble() * 2,
          child: ColoredBox(color: theme.border),
        ),
      ),
    );
  }
}
