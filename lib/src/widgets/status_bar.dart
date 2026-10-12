/// The strip of status fields along the bottom of a desktop window.
library;

import '../layout/edge_insets.dart';
import '../layout/render_flex.dart' show CrossAxisAlignment, MainAxisSize;
import 'basic.dart';
import 'icon.dart';
import 'theme.dart';
import 'tooltip.dart';
import 'widget.dart';

/// A status bar: a raised strip with a rule along its top, holding
/// [StatusBarItem]s from left to right.
///
/// The height follows the theme - three quarters of a control, never less
/// than a line of caption text and its padding - so a dense theme gets a dense
/// bar. Put the free-text message in a [StatusBarItem.message], which takes
/// the room the fixed fields leave.
final class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.children, this.height});

  final List<Widget> children;

  /// Overrides the theme-derived height.
  final double? height;

  /// The height a [StatusBar] takes under [theme] when none is given.
  static double defaultHeight(ThemeData theme) {
    final double fromControl = theme.effectiveControlHeight * 0.75;
    final double fromText = theme.textTheme.base + 10;
    return (fromControl > fromText ? fromControl : fromText).roundToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: height ?? defaultHeight(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(height: 1, child: ColoredBox(color: theme.border)),
          Expanded(
            child: ColoredBox(
              color: theme.surfaceAlternate,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: theme.effectiveGap),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: children,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One field of a [StatusBar]: an optional icon, a caption-sized text, and a
/// thin separator after it.
///
/// Give it a [width] when its text changes length - coordinates, a zoom
/// level - so the fields after it do not slide left and right as digits come
/// and go. [StatusBarItem.message] instead takes all the room left over.
final class StatusBarItem extends StatelessWidget {
  const StatusBarItem({
    super.key,
    required this.text,
    this.icon,
    this.width,
    this.tooltip,
    this.separator = true,
  }) : _expands = false;

  /// The free-text field: no separator, and as wide as what is left.
  const StatusBarItem.message({super.key, required this.text, this.icon})
      : width = null,
        tooltip = null,
        separator = false,
        _expands = true;

  final String text;
  final IconData? icon;
  final double? width;
  final String? tooltip;

  /// Whether a rule follows the field.
  final bool separator;

  final bool _expands;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double gap = theme.effectiveGap;
    final IconData? icon = this.icon;
    final Widget label = Text(
      text,
      style: theme.textTheme.labelSmall,
      color: _expands ? theme.foregroundSecondary : theme.foreground,
    );
    Widget field = Row(
      mainAxisSize:
          this.width == null && !_expands ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: theme.iconSize, color: theme.foregroundSecondary),
          SizedBox(width: gap / 2),
        ],
        if (this.width != null || _expands) Expanded(child: label) else label,
        if (separator) ...<Widget>[
          SizedBox(width: gap),
          SizedBox(
            width: 1,
            height: theme.iconSize,
            child: ColoredBox(color: theme.borderSubtle),
          ),
          SizedBox(width: gap),
        ],
      ],
    );
    final double? width = this.width;
    if (width != null) field = SizedBox(width: width, child: field);
    final String? tooltip = this.tooltip;
    if (tooltip != null) field = Tooltip(message: tooltip, child: field);
    return _expands ? Expanded(child: field) : field;
  }
}
