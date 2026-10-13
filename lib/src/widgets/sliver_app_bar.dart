/// `SliverAppBar` and `FlexibleSpaceBar`: the application bar of a
/// [CustomScrollView], built from [SliverPersistentHeader].
///
/// The bar is a persistent header whose delegate lays out three layers at the
/// header's current extent: the [SliverAppBar.flexibleSpace] filling the whole
/// bar behind, the toolbar row (leading, title, actions) at the top, and the
/// [SliverAppBar.bottom] widget at the bottom. A [FlexibleSpaceBar] placed in
/// the flexible space learns how far the bar has collapsed through
/// [FlexibleSpaceBarSettings], which the delegate publishes on every shrink
/// offset, and moves its title from large over the expanded bar to toolbar
/// size in the collapsed one.
///
/// ## Differences from Flutter, stated once
///
///   * `bottom` is a plain widget plus [SliverAppBar.bottomHeight]: there is no
///     `PreferredSizeWidget` here to carry the height;
///   * [SliverAppBar.toolbarHeight] defaults to the theme's toolbar height -
///     the one `Toolbar` uses, a control plus a gap either side - not 56;
///   * no `snap`: the persistent header has no notion of a scroll that ended
///     and no animation driving its floating offset, so a half-revealed
///     floating bar stays where the scroll left it;
///   * no shadows exist in this renderer, so "elevated" (scrolled under, or
///     [SliverAppBar.forceElevated]) draws a hairline in
///     [SliverAppBar.dividerColor] along the bottom edge, the way `Toolbar`
///     separates itself;
///   * a custom [SliverAppBar.foregroundColor] reaches the actions by
///     overriding the theme's `foreground` for the bar's subtree, because
///     `IconButton` takes its colour from the theme and not from `IconTheme`;
///   * no `stretch`, `primary`, `automaticallyImplyLeading`, `shape` or
///     status-bar padding.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../graphics/color.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_custom_layout.dart';
import '../layout/render_flex.dart';
import '../layout/render_stack.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'custom_layout.dart';
import 'directionality.dart';
import 'icon.dart';
import 'layout_builder.dart';
import 'proxy.dart';
import 'slivers.dart';
import 'theme.dart';
import 'widget.dart';

/// The toolbar height a theme implies: one control tall with a gap of air
/// above and below - the height of `Toolbar`, so an app bar and a toolbar in
/// the same window line up.
double _themeToolbarHeight(ThemeData theme) =>
    theme.effectiveControlHeight + theme.effectiveGap * 2;

// ---------------------------------------------------------------------------
// SliverAppBar
// ---------------------------------------------------------------------------

/// An application bar inside a [CustomScrollView] that expands, collapses,
/// stays ([pinned]) or comes back on the first scroll up ([floating]).
///
/// ```dart
/// CustomScrollView(
///   slivers: <Widget>[
///     SliverAppBar(
///       pinned: true,
///       expandedHeight: 160,
///       flexibleSpace: const FlexibleSpaceBar(title: Text('Inbox')),
///       actions: <Widget>[IconButton(icon: ..., onPressed: ...)],
///     ),
///     SliverList.builder(itemCount: 100, itemBuilder: ...),
///   ],
/// )
/// ```
///
/// Its extent runs from [maxExtent] (fully expanded, nothing scrolled) down
/// to [minExtent]; a pinned bar stays at that minimum with the content
/// scrolling underneath, any other scrolls away entirely.
final class SliverAppBar extends StatelessWidget {
  const SliverAppBar({
    super.key,
    this.leading,
    this.title,
    this.actions,
    this.flexibleSpace,
    this.bottom,
    this.bottomHeight = 0.0,
    this.expandedHeight,
    this.toolbarHeight,
    this.collapsedHeight,
    this.leadingWidth,
    this.pinned = false,
    this.floating = false,
    this.backgroundColor,
    this.foregroundColor,
    this.centerTitle = false,
    this.titleSpacing = 16.0,
    this.actionsPadding,
    this.forceElevated = false,
    this.dividerColor,
  })  : assert(
          bottom == null || bottomHeight > 0,
          'a bottom widget needs its bottomHeight: there is no '
          'PreferredSizeWidget to ask',
        ),
        assert(bottomHeight >= 0, 'bottomHeight cannot be negative');

  /// Shown before the title, centred in a [leadingWidth] wide slot.
  final Widget? leading;

  /// The toolbar's primary label, usually a [Text]. Styled with the theme's
  /// `titleMedium` in [foregroundColor].
  final Widget? title;

  /// Shown after the title, in a row.
  final List<Widget>? actions;

  /// Fills the whole bar behind the toolbar and [bottom], at every extent -
  /// usually a [FlexibleSpaceBar].
  final Widget? flexibleSpace;

  /// Shown across the bottom of the bar, under the toolbar - a tab strip, a
  /// search field. [bottomHeight] tall.
  final Widget? bottom;

  /// The height of [bottom]; Flutter reads this from a `PreferredSizeWidget`.
  final double bottomHeight;

  /// The bar's height with nothing scrolled. Null is the collapsed height:
  /// a bar that does not expand.
  final double? expandedHeight;

  /// The height of the toolbar row. Null takes the theme's toolbar height,
  /// one control plus a gap either side (48 at the standard density).
  final double? toolbarHeight;

  /// The height the bar collapses to. Null is the toolbar plus [bottom].
  final double? collapsedHeight;

  /// The width of the [leading] slot. Null makes it square with the toolbar.
  final double? leadingWidth;

  /// Whether the bar stays at the top at its collapsed height while the
  /// content scrolls underneath.
  final bool pinned;

  /// Whether the bar comes back as soon as the user scrolls towards the
  /// start, wherever in the content that is.
  final bool floating;

  /// The fill behind everything. Null takes the theme's `surfaceAlternate`,
  /// the colour of `Toolbar`.
  final Color? backgroundColor;

  /// The colour of the title, icons and actions. Null takes the theme's
  /// `foreground`.
  final Color? foregroundColor;

  /// Whether the title is centred in the bar rather than placed after the
  /// leading slot. It still never overlaps leading or actions.
  final bool centerTitle;

  /// The space either side of the title.
  final double titleSpacing;

  /// Space around the actions row. Null leaves the theme's gap at the end
  /// edge, so the last action does not touch the window edge.
  final EdgeInsets? actionsPadding;

  /// Draws the elevated look - the bottom hairline - even when nothing is
  /// scrolled underneath.
  final bool forceElevated;

  /// The hairline drawn along the bottom edge while elevated. Null takes the
  /// theme's `border`.
  final Color? dividerColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double resolvedToolbarHeight =
        toolbarHeight ?? _themeToolbarHeight(theme);
    return SliverPersistentHeader(
      pinned: pinned,
      floating: floating,
      delegate: _SliverAppBarDelegate(
        leading: leading,
        title: title,
        actions: actions,
        flexibleSpace: flexibleSpace,
        bottom: bottom,
        bottomHeight: bottom == null ? 0.0 : bottomHeight,
        expandedHeight: expandedHeight,
        toolbarHeight: resolvedToolbarHeight,
        collapsedHeight: collapsedHeight,
        leadingWidth: leadingWidth ?? resolvedToolbarHeight,
        pinned: pinned,
        floating: floating,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        centerTitle: centerTitle,
        titleSpacing: titleSpacing,
        actionsPadding: actionsPadding,
        forceElevated: forceElevated,
        dividerColor: dividerColor,
      ),
    );
  }
}

final class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  const _SliverAppBarDelegate({
    required this.leading,
    required this.title,
    required this.actions,
    required this.flexibleSpace,
    required this.bottom,
    required this.bottomHeight,
    required this.expandedHeight,
    required this.toolbarHeight,
    required this.collapsedHeight,
    required this.leadingWidth,
    required this.pinned,
    required this.floating,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.centerTitle,
    required this.titleSpacing,
    required this.actionsPadding,
    required this.forceElevated,
    required this.dividerColor,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
  final Widget? flexibleSpace;
  final Widget? bottom;
  final double bottomHeight;
  final double? expandedHeight;
  final double toolbarHeight;
  final double? collapsedHeight;
  final double leadingWidth;
  final bool pinned;
  final bool floating;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final bool centerTitle;
  final double titleSpacing;
  final EdgeInsets? actionsPadding;
  final bool forceElevated;
  final Color? dividerColor;

  @override
  double get minExtent => collapsedHeight ?? toolbarHeight + bottomHeight;

  @override
  double get maxExtent =>
      math.max(expandedHeight ?? toolbarHeight + bottomHeight, minExtent);

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final double minExtent = this.minExtent;
    final double maxExtent = this.maxExtent;
    // Flutter's arithmetic, without the status bar: how much of the bar is
    // still on screen, and how much of that is the toolbar's.
    final double visibleMainHeight = maxExtent - shrinkOffset;
    final double extraToolbarHeight =
        math.max(minExtent - bottomHeight - toolbarHeight, 0.0);
    final double visibleToolbarHeight =
        visibleMainHeight - bottomHeight - extraToolbarHeight;
    final bool isScrolledUnder = overlapsContent ||
        forceElevated ||
        (pinned && shrinkOffset > maxExtent - minExtent);
    final bool isPinnedWithOpacityFade =
        pinned && floating && bottom != null && extraToolbarHeight == 0.0;
    // A bar that scrolls away fades its toolbar as it goes, rather than
    // showing half an icon row clipped by the window edge.
    final double toolbarOpacity = !pinned || isPinnedWithOpacityFade
        ? (visibleToolbarHeight / toolbarHeight).clamp(0.0, 1.0)
        : 1.0;
    final double bottomOpacity = pinned || bottomHeight <= 0
        ? 1.0
        : (visibleMainHeight / bottomHeight).clamp(0.0, 1.0);
    return FlexibleSpaceBarSettings(
      toolbarOpacity: toolbarOpacity,
      minExtent: minExtent,
      maxExtent: maxExtent,
      currentExtent: math.max(minExtent, maxExtent - shrinkOffset),
      isScrolledUnder: isScrolledUnder,
      hasLeading: leading != null,
      toolbarHeight: toolbarHeight,
      child: _AppBar(
        delegate: this,
        toolbarOpacity: toolbarOpacity,
        bottomOpacity: bottomOpacity,
        isScrolledUnder: isScrolledUnder,
      ),
    );
  }

  @override
  bool shouldRebuild(_SliverAppBarDelegate oldDelegate) =>
      leading != oldDelegate.leading ||
      title != oldDelegate.title ||
      !_sameWidgets(actions, oldDelegate.actions) ||
      flexibleSpace != oldDelegate.flexibleSpace ||
      bottom != oldDelegate.bottom ||
      bottomHeight != oldDelegate.bottomHeight ||
      expandedHeight != oldDelegate.expandedHeight ||
      toolbarHeight != oldDelegate.toolbarHeight ||
      collapsedHeight != oldDelegate.collapsedHeight ||
      leadingWidth != oldDelegate.leadingWidth ||
      pinned != oldDelegate.pinned ||
      floating != oldDelegate.floating ||
      backgroundColor != oldDelegate.backgroundColor ||
      foregroundColor != oldDelegate.foregroundColor ||
      centerTitle != oldDelegate.centerTitle ||
      titleSpacing != oldDelegate.titleSpacing ||
      actionsPadding != oldDelegate.actionsPadding ||
      forceElevated != oldDelegate.forceElevated ||
      dividerColor != oldDelegate.dividerColor;

  static bool _sameWidgets(List<Widget>? a, List<Widget>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The bar at one shrink offset: flexible space behind, toolbar on top,
/// bottom widget at the bottom, hairline when elevated.
final class _AppBar extends StatelessWidget {
  const _AppBar({
    required this.delegate,
    required this.toolbarOpacity,
    required this.bottomOpacity,
    required this.isScrolledUnder,
  });

  final _SliverAppBarDelegate delegate;
  final double toolbarOpacity;
  final double bottomOpacity;
  final bool isScrolledUnder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextDirection direction =
        Directionality.maybeOf(context) ?? TextDirection.leftToRight;
    final Color background = delegate.backgroundColor ?? theme.surfaceAlternate;
    final Color foreground = delegate.foregroundColor ?? theme.foreground;
    final _SliverAppBarDelegate d = delegate;

    final List<Widget> actions = d.actions ?? const <Widget>[];
    final EdgeInsets actionsPadding = d.actionsPadding ??
        (direction.isRightToLeft
            ? EdgeInsets.only(left: theme.effectiveGap)
            : EdgeInsets.only(right: theme.effectiveGap));
    Widget toolbar = CustomMultiChildLayout(
      delegate: _ToolbarLayout(
        centerMiddle: d.centerTitle,
        middleSpacing: d.titleSpacing,
        textDirection: direction,
      ),
      children: <Widget>[
        if (d.leading != null)
          LayoutId(
            id: _ToolbarSlot.leading,
            child: SizedBox(
              width: d.leadingWidth,
              child: Center(child: d.leading),
            ),
          ),
        if (d.title != null)
          LayoutId(
            id: _ToolbarSlot.middle,
            child: DefaultTextStyle(
              style: theme.textTheme.titleMedium.copyWith(color: foreground),
              child: d.title!,
            ),
          ),
        if (actions.isNotEmpty)
          LayoutId(
            id: _ToolbarSlot.trailing,
            child: Padding(
              padding: actionsPadding,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: actions,
              ),
            ),
          ),
      ],
    );
    if (toolbarOpacity < 1.0) {
      toolbar = Opacity(opacity: toolbarOpacity, child: toolbar);
    }

    Widget? bottom = d.bottom;
    if (bottom != null && bottomOpacity < 1.0) {
      bottom = Opacity(opacity: bottomOpacity, child: bottom);
    }

    Widget bar = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (d.flexibleSpace != null) Positioned.fill(child: d.flexibleSpace!),
        Positioned.fill(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Flexible(
                child: SizedBox(height: d.toolbarHeight, child: toolbar),
              ),
              if (bottom != null)
                SizedBox(height: d.bottomHeight, child: bottom),
            ],
          ),
        ),
        if (isScrolledUnder)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 1,
            child: ColoredBox(color: d.dividerColor ?? theme.border),
          ),
      ],
    );

    bar = IconTheme(
      data: IconThemeData(
        color: foreground,
        size: IconTheme.maybeOf(context)?.size,
      ),
      child: DefaultTextStyle(
        style: theme.textTheme.bodyMedium.copyWith(color: foreground),
        child: bar,
      ),
    );
    if (d.foregroundColor != null && d.foregroundColor != theme.foreground) {
      // `IconButton` and the other controls colour themselves from the theme,
      // not from `IconTheme`: the only way the actions follow a custom
      // foreground is a theme that says so.
      final Theme? scope = Theme.maybeOf(context);
      bar = Theme(
        data: theme.copyWith(
          foreground: foreground,
          iconTheme: theme.iconTheme.merge(IconThemeData(color: foreground)),
        ),
        styles: scope?.styles,
        resources: scope?.resources,
        templates: scope?.templates,
        child: bar,
      );
    }

    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: ColoredBox(color: background, child: bar),
    );
  }
}

enum _ToolbarSlot { leading, middle, trailing }

/// Flutter's `NavigationToolbar` layout: leading at the start edge, actions
/// at the end, and the title after the leading slot - or centred in the whole
/// bar when it fits, pushed aside when it would overlap either side.
final class _ToolbarLayout extends MultiChildLayoutDelegate {
  _ToolbarLayout({
    required this.centerMiddle,
    required this.middleSpacing,
    required this.textDirection,
  });

  final bool centerMiddle;
  final double middleSpacing;
  final TextDirection textDirection;

  @override
  void performLayout(Size size) {
    final bool rtl = textDirection.isRightToLeft;
    final BoxConstraints fullHeight = BoxConstraints(
      maxWidth: size.width,
      minHeight: size.height,
      maxHeight: size.height,
    );
    double leadingWidth = 0;
    if (hasChild(_ToolbarSlot.leading)) {
      leadingWidth = layoutChild(_ToolbarSlot.leading, fullHeight).width;
      positionChild(
        _ToolbarSlot.leading,
        Offset(rtl ? size.width - leadingWidth : 0, 0),
      );
    }
    double trailingWidth = 0;
    if (hasChild(_ToolbarSlot.trailing)) {
      trailingWidth = layoutChild(_ToolbarSlot.trailing, fullHeight).width;
      positionChild(
        _ToolbarSlot.trailing,
        Offset(rtl ? 0 : size.width - trailingWidth, 0),
      );
    }
    if (hasChild(_ToolbarSlot.middle)) {
      final double maxWidth = math.max(
        size.width - leadingWidth - trailingWidth - middleSpacing * 2,
        0.0,
      );
      final Size middle = layoutChild(
        _ToolbarSlot.middle,
        BoxConstraints(maxWidth: maxWidth, maxHeight: size.height),
      );
      final double startMargin = leadingWidth + middleSpacing;
      double start = startMargin;
      if (centerMiddle) {
        start = (size.width - middle.width) / 2;
        if (start + middle.width > size.width - trailingWidth - middleSpacing) {
          start = size.width - trailingWidth - middleSpacing - middle.width;
        }
        if (start < startMargin) start = startMargin;
      }
      final double x = rtl ? size.width - middle.width - start : start;
      positionChild(
        _ToolbarSlot.middle,
        Offset(x, ((size.height - middle.height) / 2).roundToDouble()),
      );
    }
  }

  @override
  bool shouldRelayout(_ToolbarLayout oldDelegate) =>
      centerMiddle != oldDelegate.centerMiddle ||
      middleSpacing != oldDelegate.middleSpacing ||
      textDirection != oldDelegate.textDirection;
}

// ---------------------------------------------------------------------------
// FlexibleSpaceBar
// ---------------------------------------------------------------------------

/// How a [FlexibleSpaceBar]'s background moves as the bar collapses.
enum CollapseMode {
  /// Scrolls at a quarter of the collapse, so it seems further away than the
  /// content.
  parallax,

  /// Stays put; the bar's bottom edge slides up over it.
  pin,

  /// Scrolls with the bar.
  none,
}

/// What a [SliverAppBar] tells the [FlexibleSpaceBar] inside it about its
/// current state.
///
/// Published on every shrink offset; a widget that wants to react to the
/// bar collapsing reads it with [FlexibleSpaceBarSettings.maybeOf].
final class FlexibleSpaceBarSettings extends InheritedWidget {
  const FlexibleSpaceBarSettings({
    super.key,
    required this.toolbarOpacity,
    required this.minExtent,
    required this.maxExtent,
    required this.currentExtent,
    this.isScrolledUnder,
    this.hasLeading,
    this.toolbarHeight,
    required super.child,
  });

  /// How opaque the toolbar is: below one while a non-pinned bar scrolls
  /// away.
  final double toolbarOpacity;

  /// The bar's collapsed extent.
  final double minExtent;

  /// The bar's expanded extent.
  final double maxExtent;

  /// The bar's extent now, between [minExtent] and [maxExtent].
  final double currentExtent;

  /// Whether content is scrolled underneath the bar.
  final bool? isScrolledUnder;

  /// Whether the bar has a leading widget, which the title must clear.
  final bool? hasLeading;

  /// The height of the toolbar row, whose centre is where a collapsed title
  /// lands. Not in Flutter, whose toolbar is always 56 tall; null treats the
  /// whole of [minExtent] as the toolbar.
  final double? toolbarHeight;

  /// The nearest settings, or null outside an app bar.
  static FlexibleSpaceBarSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();

  @override
  bool updateShouldNotify(FlexibleSpaceBarSettings oldWidget) =>
      toolbarOpacity != oldWidget.toolbarOpacity ||
      minExtent != oldWidget.minExtent ||
      maxExtent != oldWidget.maxExtent ||
      currentExtent != oldWidget.currentExtent ||
      isScrolledUnder != oldWidget.isScrolledUnder ||
      hasLeading != oldWidget.hasLeading ||
      toolbarHeight != oldWidget.toolbarHeight;
}

/// The flexible space of a [SliverAppBar]: a background that parallaxes and
/// fades as the bar collapses, and a title that shrinks from
/// [expandedTitleScale] times its size at the bottom of the expanded bar to
/// toolbar size, centred in the collapsed toolbar.
final class FlexibleSpaceBar extends StatelessWidget {
  const FlexibleSpaceBar({
    super.key,
    this.title,
    this.background,
    this.centerTitle,
    this.titlePadding,
    this.collapseMode = CollapseMode.parallax,
    this.expandedTitleScale = 1.5,
  }) : assert(expandedTitleScale >= 1, 'the expanded title cannot be smaller');

  /// Usually a [Text]; styled with the theme's `titleMedium` in the ambient
  /// text colour (the app bar's foreground).
  final Widget? title;

  /// Fills the expanded bar behind the title - usually an image.
  final Widget? background;

  /// Null is false: a desktop title starts after the leading slot.
  final bool? centerTitle;

  /// Where the title sits in the bar, from its edges. Null puts it after the
  /// leading slot (or at the start margin) horizontally, and vertically
  /// where it lands centred in the toolbar once collapsed.
  final EdgeInsets? titlePadding;

  final CollapseMode collapseMode;

  /// The title's scale with the bar fully expanded; one when collapsed.
  final double expandedTitleScale;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextDirection direction =
        Directionality.maybeOf(context) ?? TextDirection.leftToRight;
    final FlexibleSpaceBarSettings? settings =
        FlexibleSpaceBarSettings.maybeOf(context);
    // Outside an app bar there is nothing to collapse: draw it expanded.
    final double minExtent = settings?.minExtent ?? 0;
    final double maxExtent = settings?.maxExtent ?? 0;
    final double currentExtent = settings?.currentExtent ?? maxExtent;
    final double toolbarOpacity = settings?.toolbarOpacity ?? 1.0;
    final double deltaExtent = maxExtent - minExtent;
    // 0 expanded, 1 collapsed.
    final double t = settings == null
        ? 0.0
        : deltaExtent <= 0
            ? 1.0
            : (1.0 - (currentExtent - minExtent) / deltaExtent).clamp(0.0, 1.0);

    final List<Widget> children = <Widget>[];

    if (background != null) {
      // Fade out over the last toolbar's worth of the collapse, so a collapsed
      // bar is the plain bar colour and not a sliver of photograph.
      final double fadeWindow = settings?.toolbarHeight ?? minExtent;
      final double fadeStart = deltaExtent <= 0
          ? 0.0
          : math.max(0.0, 1.0 - fadeWindow / deltaExtent);
      final double fade = fadeStart >= 1.0
          ? (t >= 1.0 ? 1.0 : 0.0)
          : ((t - fadeStart) / (1.0 - fadeStart)).clamp(0.0, 1.0);
      final double opacity = 1.0 - fade;
      if (opacity > 0) {
        final double top = switch (collapseMode) {
          CollapseMode.parallax => -(deltaExtent / 4.0) * t,
          CollapseMode.pin => -(maxExtent - currentExtent),
          CollapseMode.none => 0.0,
        };
        Widget layer = background!;
        if (opacity < 1.0) layer = Opacity(opacity: opacity, child: layer);
        children.add(
          settings == null
              ? Positioned.fill(child: layer)
              : Positioned(
                  top: top,
                  left: 0,
                  right: 0,
                  height: maxExtent,
                  child: layer,
                ),
        );
      }
    }

    final Widget? title = this.title;
    if (title != null && toolbarOpacity > 0) {
      final bool center = centerTitle ?? false;
      final Color? ambient = DefaultTextStyle.maybeOf(context)?.color;
      final titleStyle = theme.textTheme.titleMedium
          .copyWith(color: ambient ?? theme.foreground);
      final double scale = expandedTitleScale + (1.0 - expandedTitleScale) * t;
      final EdgeInsets padding =
          titlePadding ?? _defaultPadding(theme, settings, center, direction);
      final Alignment alignment = center
          ? Alignment.bottomCenter
          : direction.isRightToLeft
              ? Alignment.bottomRight
              : Alignment.bottomLeft;
      Widget layer = Padding(
        padding: padding,
        child: Transform(
          transform: Transform2D.scaling(scale, scale),
          alignment: alignment,
          child: Align(
            alignment: alignment,
            child: DefaultTextStyle(
              style: titleStyle,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    // Laid out at the width it will have once scaled, so a
                    // long title wraps or ellipsizes at the bar's edge rather
                    // than past it.
                    SizedBox(
                  width: constraints.maxWidth / scale,
                  child: Align(
                    alignment: alignment,
                    heightFactor: 1,
                    child: title,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (toolbarOpacity < 1.0) {
        layer = Opacity(opacity: toolbarOpacity, child: layer);
      }
      children.add(Positioned.fill(child: layer));
    }

    return ClipRect(child: Stack(fit: StackFit.expand, children: children));
  }

  /// After the leading slot horizontally; vertically, where a toolbar-sized
  /// title is centred in the toolbar row of the collapsed bar.
  static EdgeInsets _defaultPadding(
    ThemeData theme,
    FlexibleSpaceBarSettings? settings,
    bool center,
    TextDirection direction,
  ) {
    final double minExtent = settings?.minExtent ?? 0;
    final double toolbarHeight = settings?.toolbarHeight ?? minExtent;
    final TextStyle style = theme.textTheme.titleMedium;
    final double lineHeight =
        (style.fontSize ?? theme.fontSize) * (style.height ?? 1.2);
    final double bottom = settings == null
        ? 16.0
        : math.max(0.0, minExtent - toolbarHeight) +
            math.max(0.0, ((toolbarHeight - lineHeight) / 2).roundToDouble());
    final double start = center
        ? 0.0
        : (settings?.hasLeading ?? false)
            ? toolbarHeight + 16.0
            : 16.0;
    return direction.isRightToLeft
        ? EdgeInsets.only(right: start, bottom: bottom)
        : EdgeInsets.only(left: start, bottom: bottom);
  }
}
