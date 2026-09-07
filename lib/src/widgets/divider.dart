/// A rule between two pieces of content.
library;

import '../graphics/color.dart';
import '../layout/edge_insets.dart';
import 'basic.dart';
import 'proxy.dart';
import 'theme.dart';
import 'widget.dart';

/// A horizontal rule that fills the width it is given.
///
/// The migration guide used to say "use a 1 px box with `theme.border`", which
/// works and is wrong in two small ways every time somebody writes it: the
/// colour is the wrong one - [ThemeData.borderSubtle] is the divider *inside* a
/// surface, and [ThemeData.border] is the edge *between* two - and the box has
/// no breathing room, so a list of rows ends up with its separators touching
/// the text above them.
///
/// So the shape follows Flutter's, which had the same problem and solved it the
/// same way: the widget occupies [height] and paints a [thickness]-thick line
/// centred in it, which is why `Divider(height: 32)` adds 32 px of vertical
/// space with a hairline in the middle rather than a 32 px-thick bar.
///
/// The [color] default is the theme's, resolved at build time, so a divider
/// inside a dark panel does not need to be told.
final class Divider extends StatelessWidget {
  const Divider({
    super.key,
    this.height = 16,
    this.thickness = 1,
    this.indent = 0,
    this.endIndent = 0,
    this.color,
  })  : assert(height >= 0, 'height cannot be negative'),
        assert(thickness >= 0, 'thickness cannot be negative');

  /// The vertical extent this widget occupies, line and space together.
  final double height;

  /// How thick the line itself is. Zero draws nothing and keeps the space,
  /// which is how a list turns its separators off without changing its metrics.
  final double thickness;

  /// Inset at the leading edge, and at the trailing edge.
  ///
  /// Physical left/right, not logical start/end: this framework's [EdgeInsets]
  /// is physical and the directional resolution happens above. Flutter's
  /// `indent`/`endIndent` are equally physical here.
  final double indent;
  final double endIndent;

  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Center(
          child: Padding(
            padding: EdgeInsets.only(left: indent, right: endIndent),
            child: SizedBox(
              height: thickness,
              child: ColoredBox(
                color: color ?? Theme.of(context).borderSubtle,
              ),
            ),
          ),
        ),
      );
}

/// A vertical rule that fills the height it is given.
///
/// The transposed twin of [Divider], and Flutter's naming: [width] is the space
/// occupied, [thickness] the line drawn inside it, [indent] and [endIndent] the
/// insets at the top and bottom.
final class VerticalDivider extends StatelessWidget {
  const VerticalDivider({
    super.key,
    this.width = 16,
    this.thickness = 1,
    this.indent = 0,
    this.endIndent = 0,
    this.color,
  })  : assert(width >= 0, 'width cannot be negative'),
        assert(thickness >= 0, 'thickness cannot be negative');

  final double width;
  final double thickness;
  final double indent;
  final double endIndent;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: Center(
          child: Padding(
            padding: EdgeInsets.only(top: indent, bottom: endIndent),
            child: SizedBox(
              width: thickness,
              child: ColoredBox(
                color: color ?? Theme.of(context).borderSubtle,
              ),
            ),
          ),
        ),
      );
}
