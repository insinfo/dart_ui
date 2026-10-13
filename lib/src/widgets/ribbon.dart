/// The Office ribbon: tabs of command groups, laid out large-icon first and
/// shrunk group by group as the window narrows.
///
/// A [Ribbon] is a strip of [RibbonTab] headers over the selected tab's
/// panel. The panel is a row of [RibbonGroup]s - "Clipboard", "Font",
/// "Paragraph" - separated by hairlines, each with its name underneath and,
/// optionally, a dialog launcher in its corner. A group holds [RibbonItem]s:
/// large buttons with a 32 px icon over a one- or two-line label, small
/// buttons with a 16 px icon beside the label stacked three to a column,
/// toggles, split and drop-down buttons, a gallery, and any other widget
/// through [RibbonControl].
///
/// ## Adaptive size
///
/// What makes a ribbon a ribbon and not a toolbar is what happens when the
/// window is too narrow for it. The rules here are Office's, and they are
/// deterministic so they can be tested ([Ribbon.groupSizesFor]):
///
///  1. every group starts at [RibbonGroupSize.large];
///  2. while the panel does not fit, groups step down **from the right**, one
///     group at a time: first each to [RibbonGroupSize.medium] (a large
///     button becomes a small one with its label, stacked three to a column),
///     then each to [RibbonGroupSize.small] (small buttons lose their
///     labels), and last each to [RibbonGroupSize.collapsed] - one button with
///     the group's icon and name that opens the whole group in a popup;
///  3. a step that would not make a group narrower is skipped, so a group of
///     small buttons does not "shrink" to the size it already was.
///
/// Widths come from measuring the labels with the same face [Text] draws
/// them in, so the decision is made before anything is built, in one pass.
///
/// ## Collapsing
///
/// Ctrl+F1, a double click on a tab, or the chevron at the end of the strip
/// collapses the ribbon to its tab strip. A click on a tab then shows that
/// tab's panel floating over the content below; a click outside, Escape, or
/// running a command from it puts it away.
///
/// ## Keyboard
///
/// The strip is one tab stop - the same contract as [Tabs]: Left and Right
/// move between the tabs, Home and End go to the ends, Down or Tab goes into
/// the panel, where every enabled control is a tab stop in reading order.
/// A ribbon button does **not** take focus when it is clicked: a command
/// acts on the document, and the document should keep the keyboard, which
/// is what Office does. Key tips (Alt and a letter) are not implemented.
///
/// ## Commands
///
/// Every command-like item takes either an `onPressed` callback or a
/// [CommandRegistry] and a command id, exactly as [CommandIconButton] does:
/// the label, the enabled state, the checked state of a toggle and the
/// tooltip ("Bold (Ctrl+B)", or "Paste - the clipboard is empty") come from
/// the registry, so the ribbon cannot disagree with the menus. The registry
/// is read when the ribbon builds; an application rebuilds after its state
/// changes, as it does for every other command surface.
library;

import 'dart:math' as math;

import '../commands/command.dart';
import '../commands/command_registry.dart';
import '../commands/menu_spec.dart' show guardCommandState;
import '../foundation/change_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_flex.dart';
import '../layout/render_proxy_box.dart';
import '../platform/input_events.dart';
import '../rendering/text/font_registry.dart' show FontRegistry, uiTextPainter;
import '../semantics/semantics.dart';
import '../text/shaper.dart' show TextDirection;
import '../text/typeface.dart' show ScaledTypeface;
import 'basic.dart';
import 'command_button.dart' show CommandIconButton;
import 'control.dart';
import 'dialogs.dart' show modalDepthOf;
import 'directionality.dart';
import 'element.dart';
import 'fluent_icons.dart';
import 'flyout.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'icon.dart';
import 'layout_builder.dart';
import 'menu_anchor.dart';
import 'popup.dart';
import 'popup_host.dart';
import 'proxy.dart';
import 'semantics_widgets.dart';
import 'style.dart' show PseudoClass;
import 'theme.dart';
import 'tooltip.dart';
import 'widget.dart';

// ---------------------------------------------------------------------------
// Sizes and metrics
// ---------------------------------------------------------------------------

/// How much room a [RibbonGroup] is given, largest first.
enum RibbonGroupSize {
  /// Large buttons as large buttons, small buttons with their labels.
  large,

  /// Every button small, with its label, three to a column.
  medium,

  /// Every button small, icon only, three to a column.
  small,

  /// The whole group behind one button that opens it in a popup.
  collapsed,
}

/// The measurements a ribbon is drawn with, derived from a [ThemeData] so a
/// compact theme gets a compact ribbon.
final class RibbonMetrics {
  RibbonMetrics(this.theme)
      : rowHeight =
            math.max(22, (theme.effectiveControlHeight * 0.75).roundToDouble()),
        labelStyle = theme.textTheme.bodySmall.copyWith(height: 1.3),
        groupLabelStyle = theme.textTheme.labelSmall,
        tabStyle = theme.textTheme.bodyMedium;

  final ThemeData theme;

  /// One small button, one row of a three-row column.
  final double rowHeight;

  /// The labels of buttons.
  final TextStyle labelStyle;

  /// A group's name under it.
  final TextStyle groupLabelStyle;

  /// A tab's name.
  final TextStyle tabStyle;

  /// The icon of a large button.
  static const double largeIconSize = 32;

  /// The icon of a small button.
  static const double smallIconSize = 16;

  /// Room for a drop-down chevron beside a label.
  static const double chevronWidth = 12;

  /// Between two columns of a group.
  static const double columnGap = 2;

  /// Inside a group, left and right.
  static const double groupPadding = 4;

  /// The hairline between groups and its margins.
  static const double separatorWidth = 9;

  /// Three rows: the height of a large button and of a group's controls.
  double get contentHeight => rowHeight * 3;

  /// The strip of a group's name.
  double get groupLabelHeight => 18;

  /// The panel inside its frame: air, controls, the group names, air.
  double get panelHeight => 4 + contentHeight + 2 + groupLabelHeight + 2;

  /// The tab strip.
  double get tabStripHeight => theme.effectiveControlHeight;

  /// The width [text] is drawn at in [style], rounded up.
  ///
  /// Measured through the same face and painter [Text] lays out with, so a
  /// box sized from this fits the label it holds.
  double measure(String text, TextStyle style) {
    if (text.isEmpty) return 0;
    final double size = style.fontSize ?? theme.fontSize;
    final ScaledTypeface? font = FontRegistry.instance
        .uiFont(size, weight: style.fontWeight?.value ?? 400);
    final double width = font == null
        ? FontRegistry.estimatedSize(text, size).width
        : uiTextPainter.measure(text, font).width;
    return width.ceilToDouble();
  }

  /// [label] as the one or two lines a large button shows: two-word labels
  /// break where the longer line is shortest, as "Format / Painter" does.
  List<String> largeLines(String label) {
    final List<String> words =
        label.split(' ').where((String w) => w.isNotEmpty).toList();
    if (words.length < 2) return <String>[label];
    List<String> best = <String>[label];
    double bestWidth = double.infinity;
    for (var i = 1; i < words.length; i++) {
      final String a = words.sublist(0, i).join(' ');
      final String b = words.sublist(i).join(' ');
      final double width =
          math.max(measure(a, labelStyle), measure(b, labelStyle));
      if (width < bestWidth) {
        bestWidth = width;
        best = <String>[a, b];
      }
    }
    return best;
  }

  /// The width of a large button showing [label], with a chevron when it
  /// opens a menu.
  double largeButtonWidth(String label, {bool chevron = false}) {
    final List<String> lines = largeLines(label);
    double widest = 0;
    for (var i = 0; i < lines.length; i++) {
      double width = measure(lines[i], labelStyle);
      if (chevron && i == lines.length - 1 && lines.length > 1) {
        width += chevronWidth;
      }
      widest = math.max(widest, width);
    }
    if (chevron && lines.length == 1) {
      widest = math.max(widest, chevronWidth);
    }
    return math.max(largeIconSize + 12, widest + 12);
  }

  /// The width of a small button: icon, then the label when [label] is not
  /// null, then a chevron when it opens a menu.
  double smallButtonWidth(String? label, {bool chevron = false}) {
    double width = 4 + smallIconSize + 4;
    if (label != null && label.isNotEmpty) {
      width += measure(label, labelStyle) + 4;
    }
    if (chevron) width += chevronWidth;
    return math.max(rowHeight, width);
  }
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

/// One control of a [RibbonGroup], drawn at the size its group was given.
///
/// An item says how wide it is at each [RibbonGroupSize] and whether it takes
/// a whole column (a large button, a gallery) or one row of three (a small
/// button, a combo box); the group lays the columns out from that.
abstract base class RibbonItem extends StatelessWidget {
  const RibbonItem({super.key});

  /// Whether this item fills a column's full height at [size], rather than
  /// one of its three rows.
  bool isColumnAt(RibbonGroupSize size);

  /// How wide this item is at [size].
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size);

  /// The item at [size]. Called with the size of the group it is in.
  Widget buildAt(
      BuildContext context, RibbonMetrics metrics, RibbonGroupSize size);

  /// The icon a collapsed group shows when it names none of its own.
  IconData? get groupIcon => null;

  @override
  Widget build(BuildContext context) {
    final _RibbonItemScope? scope = _RibbonItemScope.maybeOf(context);
    return buildAt(
      context,
      scope?.metrics ?? RibbonMetrics(Theme.of(context)),
      scope?.size ?? RibbonGroupSize.large,
    );
  }
}

/// The state a command-like item shows: from its own fields, or from the
/// registry.
typedef _CommandView = ({
  bool enabled,
  bool checked,
  String label,
  String? tooltip,
  void Function()? run,
});

/// What [RibbonButton], [RibbonToggleButton] and [RibbonSplitButton] share:
/// an icon, a label, and either a callback or a command.
abstract base class _RibbonCommandItem extends RibbonItem {
  const _RibbonCommandItem({
    super.key,
    required this.icon,
    this.label,
    this.onPressed,
    this.registry,
    this.command,
    this.params = const <String, Object?>{},
    this.tooltip,
    this.iconColor,
    required this.large,
  }) : assert(label != null || command != null,
            'a ribbon button needs a label or a command to take one from');

  final IconData icon;

  /// The label; null takes the command's.
  final String? label;

  /// What a press does, when the item is not bound to a [command].
  final void Function()? onPressed;

  /// Where [command] is looked up and run.
  final CommandRegistry? registry;

  /// The command id this item runs; with [registry], it decides the label,
  /// whether the item is enabled or checked, and the tooltip.
  final String? command;

  /// What the command is run with.
  final Map<String, Object?> params;

  /// Replaces the tooltip; null shows the label (and the command's shortcut).
  final String? tooltip;

  /// Tints the icon - Office's coloured glyphs. Null draws it in the text
  /// colour.
  final Color? iconColor;

  /// Whether this is a large button (32 px icon over its label) when its
  /// group has room for one.
  final bool large;

  @override
  IconData? get groupIcon => icon;

  /// Whether the item is on, when it is not bound to a command.
  bool get _localChecked => false;

  /// What a press does, when the item is not bound to a command.
  void Function()? get _localRun => onPressed;

  _CommandView _view() {
    final CommandRegistry? registry = this.registry;
    final String? id = command;
    if (registry != null && id != null) {
      final CommandSpec? spec = registry[id];
      final CommandArgs args = CommandArgs(params);
      final bool enabled = spec != null &&
          guardCommandState(() => spec.isEnabledWith(args), false);
      final bool checked = spec != null &&
          (guardCommandState(() => spec.isCheckedWith(args), null) ?? false);
      final String name = label ??
          (spec == null
              ? id
              : guardCommandState(() => spec.labelWith(args), spec.label));
      return (
        enabled: enabled,
        checked: checked,
        label: name,
        tooltip: tooltip ??
            CommandIconButton.tooltipOf(registry, id,
                params: params, label: label),
        run: enabled ? () => registry.execute(id, params) : null,
      );
    }
    final void Function()? run = _localRun;
    return (
      enabled: run != null,
      checked: _localChecked,
      label: label ?? id ?? '',
      tooltip: tooltip ?? label,
      run: run,
    );
  }

  /// The label this item shows - its own, or its command's.
  String get _labelText {
    if (label != null) return label!;
    return _view().label;
  }

  bool _largeAt(RibbonGroupSize size) => large && size == RibbonGroupSize.large;

  @override
  bool isColumnAt(RibbonGroupSize size) => _largeAt(size);
}

/// A button that runs a command: large (32 px icon over the label) or small
/// (16 px icon beside it).
final class RibbonButton extends _RibbonCommandItem {
  /// A small button: one row of a three-row column.
  const RibbonButton({
    super.key,
    required super.icon,
    super.label,
    super.onPressed,
    super.registry,
    super.command,
    super.params,
    super.tooltip,
    super.iconColor,
  }) : super(large: false);

  /// A large button: a whole column, with the label under the icon on one or
  /// two lines.
  const RibbonButton.large({
    super.key,
    required super.icon,
    super.label,
    super.onPressed,
    super.registry,
    super.command,
    super.params,
    super.tooltip,
    super.iconColor,
  }) : super(large: true);

  @override
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size) =>
      _commandWidth(this, metrics, size, chevron: false);

  @override
  Widget buildAt(
      BuildContext context, RibbonMetrics metrics, RibbonGroupSize size) {
    final _CommandView view = _view();
    return _RibbonButtonFace(
      metrics: metrics,
      mode: _faceMode(this, size),
      icon: icon,
      iconColor: iconColor,
      label: view.label,
      enabled: view.enabled,
      checked: view.checked,
      tooltip: view.tooltip,
      role: SemanticsRole.button,
      width: widthAt(metrics, size),
      onPressed: view.run,
    );
  }
}

/// A button that is on or off - Bold, Italic, Show Ruler.
///
/// Bound to a command, it is on while the command reports itself checked;
/// otherwise [isChecked] says, and [onChanged] is told the new value.
final class RibbonToggleButton extends _RibbonCommandItem {
  const RibbonToggleButton({
    super.key,
    required super.icon,
    super.label,
    this.isChecked = false,
    this.onChanged,
    super.registry,
    super.command,
    super.params,
    super.tooltip,
    super.iconColor,
  }) : super(large: false);

  const RibbonToggleButton.large({
    super.key,
    required super.icon,
    super.label,
    this.isChecked = false,
    this.onChanged,
    super.registry,
    super.command,
    super.params,
    super.tooltip,
    super.iconColor,
  }) : super(large: true);

  final bool isChecked;
  final void Function(bool value)? onChanged;

  @override
  bool get _localChecked => isChecked;

  @override
  void Function()? get _localRun {
    final void Function(bool value)? changed = onChanged;
    return changed == null ? null : () => changed(!isChecked);
  }

  @override
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size) =>
      _commandWidth(this, metrics, size, chevron: false);

  @override
  Widget buildAt(
      BuildContext context, RibbonMetrics metrics, RibbonGroupSize size) {
    final _CommandView view = _view();
    return _RibbonButtonFace(
      metrics: metrics,
      mode: _faceMode(this, size),
      icon: icon,
      iconColor: iconColor,
      label: view.label,
      enabled: view.enabled,
      checked: view.checked,
      tooltip: view.tooltip,
      role: SemanticsRole.toggleButton,
      width: widthAt(metrics, size),
      onPressed: view.run,
    );
  }
}

/// A button whose face runs a command and whose arrow opens a menu of
/// variants: Paste and its paste options, Underline and its styles.
final class RibbonSplitButton extends _RibbonCommandItem {
  const RibbonSplitButton({
    super.key,
    required super.icon,
    super.label,
    super.onPressed,
    super.registry,
    super.command,
    super.params,
    super.tooltip,
    super.iconColor,
    required this.menuChildren,
  }) : super(large: false);

  const RibbonSplitButton.large({
    super.key,
    required super.icon,
    super.label,
    super.onPressed,
    super.registry,
    super.command,
    super.params,
    super.tooltip,
    super.iconColor,
    required this.menuChildren,
  }) : super(large: true);

  /// The menu the arrow opens: [MenuItemButton]s and [SubmenuButton]s.
  final List<Widget> menuChildren;

  @override
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size) =>
      _commandWidth(this, metrics, size, chevron: true);

  @override
  Widget buildAt(
      BuildContext context, RibbonMetrics metrics, RibbonGroupSize size) {
    final _CommandView view = _view();
    return _RibbonSplitFace(
      metrics: metrics,
      mode: _faceMode(this, size),
      icon: icon,
      iconColor: iconColor,
      label: view.label,
      enabled: view.enabled,
      tooltip: view.tooltip,
      width: widthAt(metrics, size),
      onPressed: view.run,
      menuChildren: menuChildren,
    );
  }
}

/// A button that only opens a menu: Find's options, a list of styles.
final class RibbonDropDownButton extends RibbonItem {
  const RibbonDropDownButton({
    super.key,
    required this.icon,
    required this.label,
    required this.menuChildren,
    this.tooltip,
    this.iconColor,
    this.enabled = true,
  }) : large = false;

  const RibbonDropDownButton.large({
    super.key,
    required this.icon,
    required this.label,
    required this.menuChildren,
    this.tooltip,
    this.iconColor,
    this.enabled = true,
  }) : large = true;

  final IconData icon;
  final String label;
  final List<Widget> menuChildren;
  final String? tooltip;
  final Color? iconColor;
  final bool enabled;
  final bool large;

  @override
  IconData? get groupIcon => icon;

  @override
  bool isColumnAt(RibbonGroupSize size) =>
      large && size == RibbonGroupSize.large;

  @override
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size) =>
      isColumnAt(size)
          ? metrics.largeButtonWidth(label, chevron: true)
          : metrics.smallButtonWidth(
              size == RibbonGroupSize.small ? null : label,
              chevron: true);

  @override
  Widget buildAt(
      BuildContext context, RibbonMetrics metrics, RibbonGroupSize size) {
    final _FaceMode mode = isColumnAt(size)
        ? _FaceMode.large
        : size == RibbonGroupSize.small
            ? _FaceMode.icon
            : _FaceMode.row;
    final double width = widthAt(metrics, size);
    return MenuAnchor(
      menuChildren: menuChildren,
      builder: (BuildContext context, MenuController controller, _) =>
          _RibbonButtonFace(
        metrics: metrics,
        mode: mode,
        icon: icon,
        iconColor: iconColor,
        label: label,
        enabled: enabled,
        checked: false,
        expanded: controller.isOpen,
        chevron: true,
        closesPopup: false,
        tooltip: tooltip ?? label,
        role: SemanticsRole.button,
        width: width,
        onPressed: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
      ),
    );
  }
}

/// Any widget as a ribbon item - a font name box, a size spinner - one row
/// of a column, [width] wide, with an optional [label] before it.
///
/// [RibbonControl.large] takes a whole column instead.
final class RibbonControl extends RibbonItem {
  const RibbonControl({
    super.key,
    required this.child,
    required this.width,
    this.label,
    this.icon,
  }) : large = false;

  const RibbonControl.large({
    super.key,
    required this.child,
    required this.width,
    this.label,
    this.icon,
  }) : large = true;

  final Widget child;

  /// The width of [child]. Declared rather than measured: the ribbon decides
  /// its layout before it builds anything, and an arbitrary widget can only
  /// say how wide it is by being laid out.
  final double width;

  /// Shown before [child] while the group has room for labels.
  final String? label;

  /// The icon of a collapsed group made only of controls.
  final IconData? icon;

  final bool large;

  @override
  IconData? get groupIcon => icon;

  @override
  bool isColumnAt(RibbonGroupSize size) => large;

  bool _labelled(RibbonGroupSize size) =>
      label != null && !large && size.index < RibbonGroupSize.small.index;

  @override
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size) =>
      width +
      (_labelled(size) ? metrics.measure(label!, metrics.labelStyle) + 6 : 0);

  @override
  Widget buildAt(
      BuildContext context, RibbonMetrics metrics, RibbonGroupSize size) {
    final ThemeData theme = metrics.theme;
    final Widget sized = SizedBox(
      width: width,
      height: large ? metrics.contentHeight : null,
      child: child,
    );
    if (!_labelled(size)) return Center(child: sized);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Text(label!, style: metrics.labelStyle, color: theme.foreground),
        const SizedBox(width: 6),
        sized,
      ],
    );
  }
}

/// A thin vertical rule between controls of one group.
final class RibbonSeparator extends RibbonItem {
  const RibbonSeparator({super.key});

  @override
  bool isColumnAt(RibbonGroupSize size) => true;

  @override
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size) =>
      RibbonMetrics.separatorWidth;

  @override
  Widget buildAt(
          BuildContext context, RibbonMetrics metrics, RibbonGroupSize size) =>
      Center(
        child: SizedBox(
          width: 1,
          height: metrics.contentHeight - 8,
          child: ColoredBox(color: metrics.theme.borderSubtle),
        ),
      );
}

/// One choice of a [RibbonGallery]: a preview (or an icon) over a name.
final class RibbonGalleryItem {
  const RibbonGalleryItem({required this.label, this.icon, this.preview});

  final String label;
  final IconData? icon;

  /// Drawn instead of [icon]: a style's sample text, a colour swatch.
  final Widget? preview;
}

/// A row of visual choices in the ribbon - Styles, Shape Styles - with an
/// arrow that opens all of them.
///
/// Shows [columns] tiles at [RibbonGroupSize.large], [mediumColumns] at
/// [RibbonGroupSize.medium], and becomes a drop-down button below that.
final class RibbonGallery extends RibbonItem {
  const RibbonGallery({
    super.key,
    required this.label,
    required this.items,
    this.icon,
    this.selectedIndex,
    this.onSelected,
    this.columns = 4,
    this.mediumColumns = 2,
    this.itemWidth = 72,
    this.popupColumns = 4,
  });

  /// The gallery's name, on the drop-down button it becomes when narrow.
  final String label;
  final List<RibbonGalleryItem> items;
  final IconData? icon;
  final int? selectedIndex;
  final void Function(int index)? onSelected;
  final int columns;
  final int mediumColumns;
  final double itemWidth;
  final int popupColumns;

  static const double _moreWidth = 18;

  @override
  IconData? get groupIcon => icon;

  int _columnsAt(RibbonGroupSize size) => switch (size) {
        RibbonGroupSize.large => columns,
        RibbonGroupSize.medium => mediumColumns,
        _ => 0,
      };

  @override
  bool isColumnAt(RibbonGroupSize size) => true;

  @override
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size) {
    final int shown = math.min(_columnsAt(size), items.length);
    if (shown == 0) return metrics.largeButtonWidth(label, chevron: true);
    return shown * itemWidth + _moreWidth + 2;
  }

  /// The first tile shown in the ribbon: the start of the row the selected
  /// item is in, so the selection is visible.
  int _firstShown(int shown) {
    final int selected = selectedIndex ?? 0;
    if (shown <= 0 || selected < 0 || selected >= items.length) return 0;
    return (selected ~/ shown) * shown;
  }

  Widget _tile(RibbonMetrics metrics, int index, double height,
      {void Function()? close}) {
    final RibbonGalleryItem item = items[index];
    final ThemeData theme = metrics.theme;
    final void Function(int index)? selected = onSelected;
    final Color foreground =
        selected == null ? theme.disabledForeground : theme.foreground;
    return _RibbonPressable(
      theme: theme,
      enabled: selected != null,
      checked: index == selectedIndex,
      role: SemanticsRole.listItem,
      semanticsLabel: item.label,
      tooltip: item.label,
      width: itemWidth,
      height: height,
      onPressed: selected == null
          ? null
          : () {
              close?.call();
              selected(index);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Center(
                child: item.preview ??
                    (item.icon == null
                        ? const SizedBox()
                        : Icon(item.icon!, size: 24, color: foreground)),
              ),
            ),
            Text(
              item.label,
              style: metrics.labelStyle,
              color: foreground,
              maxLines: 1,
              ellipsis: '…',
            ),
          ],
        ),
      ),
    );
  }

  /// Every item, in the popup the arrow opens. Choosing one closes it, and
  /// the popup the gallery itself is in, when it is in one.
  Widget _all(RibbonMetrics metrics, FlyoutController controller,
      _RibbonPopupScope? outer) {
    final double height = metrics.contentHeight - 4;
    final int perRow = math.max(1, math.min(popupColumns, items.length));
    return SizedBox(
      width: perRow * itemWidth + (perRow - 1) * 2,
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: <Widget>[
          for (var i = 0; i < items.length; i++)
            _tile(metrics, i, height, close: () {
              controller.close();
              outer?.close();
            }),
        ],
      ),
    );
  }

  @override
  Widget buildAt(
      BuildContext context, RibbonMetrics metrics, RibbonGroupSize size) {
    final ThemeData theme = metrics.theme;
    final int shown = math.min(_columnsAt(size), items.length);
    final _RibbonPopupScope? outer = _RibbonPopupScope.maybeOf(context);
    if (shown == 0) {
      return Flyout(
        // Opened by the mouse as often as not: the keyboard stays where it
        // was, and Escape still closes it.
        autofocus: false,
        padding: const EdgeInsets.all(4),
        builder: (BuildContext context, FlyoutController controller) =>
            _RibbonButtonFace(
          metrics: metrics,
          mode: _FaceMode.large,
          icon: icon ?? items.firstOrNull?.icon ?? FluentIcons.grid,
          label: label,
          enabled: items.isNotEmpty,
          checked: false,
          chevron: true,
          closesPopup: false,
          expanded: controller.isOpen,
          tooltip: label,
          role: SemanticsRole.button,
          width: widthAt(metrics, size),
          onPressed: controller.toggle,
        ),
        content: (BuildContext inner, FlyoutController controller) =>
            _all(metrics, controller, outer),
      );
    }
    final int first = _firstShown(shown);
    final double height = metrics.contentHeight - 4;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BoxBorder(color: theme.borderSubtle, width: 1),
          radius: theme.cornerRadiusSmall,
        ),
        child: Row(
          children: <Widget>[
            for (var i = first; i < math.min(first + shown, items.length); i++)
              _tile(metrics, i, height),
            const Spacer(),
            Flyout(
              autofocus: false,
              padding: const EdgeInsets.all(4),
              anchorPoint: PopupAnchorPoint.bottomRight,
              popupPoint: PopupAnchorPoint.topRight,
              builder: (BuildContext context, FlyoutController controller) =>
                  _RibbonPressable(
                theme: theme,
                enabled: items.isNotEmpty,
                role: SemanticsRole.button,
                semanticsLabel: label,
                tooltip: label,
                expanded: controller.isOpen,
                closesPopup: false,
                width: _moreWidth,
                height: height,
                onPressed: controller.toggle,
                child: Center(
                  child: Chevron(
                    size: 10,
                    color: theme.foregroundSecondary,
                  ),
                ),
              ),
              content: (BuildContext inner, FlyoutController controller) =>
                  _all(metrics, controller, outer),
            ),
          ],
        ),
      ),
    );
  }
}

double _commandWidth(
  _RibbonCommandItem item,
  RibbonMetrics metrics,
  RibbonGroupSize size, {
  required bool chevron,
}) {
  final String label = item._labelText;
  if (item._largeAt(size)) {
    return metrics.largeButtonWidth(label, chevron: chevron);
  }
  final double width = metrics.smallButtonWidth(
      size == RibbonGroupSize.small ? null : label,
      chevron: chevron);
  // The arrow of a split button is a part of its own, with a rule between.
  return chevron ? width + 2 : width;
}

_FaceMode _faceMode(_RibbonCommandItem item, RibbonGroupSize size) =>
    item._largeAt(size)
        ? _FaceMode.large
        : size == RibbonGroupSize.small
            ? _FaceMode.icon
            : _FaceMode.row;

// ---------------------------------------------------------------------------
// Groups and tabs
// ---------------------------------------------------------------------------

/// A named set of related items - Clipboard, Font, Paragraph.
final class RibbonGroup {
  const RibbonGroup({
    required this.label,
    required this.items,
    this.icon,
    this.onDialogLauncher,
    this.dialogLauncherTooltip,
  });

  final String label;
  final List<RibbonItem> items;

  /// What the group shows when it is collapsed to one button; null takes the
  /// first item's icon.
  final IconData? icon;

  /// Opens the group's full dialog - Font..., Paragraph... - from the small
  /// arrow in the group's corner. Null shows no arrow.
  final void Function()? onDialogLauncher;

  /// The arrow's tooltip; null says "More [label] options".
  final String? dialogLauncherTooltip;

  IconData get _icon {
    final IconData? own = icon;
    if (own != null) return own;
    for (final RibbonItem item in items) {
      final IconData? glyph = item.groupIcon;
      if (glyph != null) return glyph;
    }
    return FluentIcons.grid;
  }

  /// The columns of [items] at [size]: an item that fills a column is one
  /// on its own, and the rest are stacked three to a column in order.
  List<List<RibbonItem>> columnsAt(RibbonGroupSize size) {
    final List<List<RibbonItem>> columns = <List<RibbonItem>>[];
    List<RibbonItem> run = <RibbonItem>[];
    void flush() {
      if (run.isEmpty) return;
      columns.add(run);
      run = <RibbonItem>[];
    }

    for (final RibbonItem item in items) {
      if (item.isColumnAt(size)) {
        flush();
        columns.add(<RibbonItem>[item]);
        continue;
      }
      run.add(item);
      if (run.length == 3) flush();
    }
    flush();
    return columns;
  }

  /// How wide this group is at [size], padding included.
  double widthAt(RibbonMetrics metrics, RibbonGroupSize size) {
    if (size == RibbonGroupSize.collapsed) {
      return metrics.largeButtonWidth(label, chevron: true) +
          RibbonMetrics.groupPadding * 2;
    }
    double content = 0;
    final List<List<RibbonItem>> columns = columnsAt(size);
    for (var i = 0; i < columns.length; i++) {
      if (i > 0) content += RibbonMetrics.columnGap;
      double widest = 0;
      for (final RibbonItem item in columns[i]) {
        widest = math.max(widest, item.widthAt(metrics, size));
      }
      content += widest;
    }
    final double name = metrics.measure(label, metrics.groupLabelStyle) +
        (onDialogLauncher == null ? 8 : 2 * 16 + 4);
    return math.max(content, name) + RibbonMetrics.groupPadding * 2;
  }
}

/// One tab of a [Ribbon]: its name and its groups.
final class RibbonTab {
  const RibbonTab({
    required this.label,
    required this.groups,
    this.contextualColor,
    this.id,
  });

  final String label;
  final List<RibbonGroup> groups;

  /// Marks a contextual tab - Picture Format, Table Design - that appears
  /// only while its kind of object is selected: its name and underline take
  /// this colour, with a band of it along the top.
  final Color? contextualColor;

  /// What this tab is across rebuilds that changed the list; defaults to the
  /// label.
  final Object? id;

  Object get identity => id ?? label;
}

/// The selected tab and the collapsed state of a [Ribbon], from outside it.
final class RibbonController extends ChangeNotifier {
  RibbonController({int selectedIndex = 0, bool collapsed = false})
      : _selectedIndex = selectedIndex,
        _collapsed = collapsed;

  int _selectedIndex;
  bool _collapsed;

  int get selectedIndex => _selectedIndex;

  set selectedIndex(int value) {
    if (value == _selectedIndex) return;
    _selectedIndex = value;
    notifyListeners();
  }

  /// Whether only the tab strip shows.
  bool get collapsed => _collapsed;

  set collapsed(bool value) {
    if (value == _collapsed) return;
    _collapsed = value;
    notifyListeners();
  }

  void toggleCollapsed() => collapsed = !collapsed;
}

/// A [Ribbon]'s leading button that opens the File view: an accent-filled
/// tab.
final class RibbonBackstageButton extends StatelessWidget {
  const RibbonBackstageButton({
    super.key,
    this.label = 'File',
    required this.onPressed,
  });

  final String label;
  final void Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final RibbonMetrics metrics = RibbonMetrics(theme);
    final double height = metrics.tabStripHeight - 6;
    return Center(
      child: _RibbonPressable(
        theme: theme,
        enabled: onPressed != null,
        role: SemanticsRole.button,
        semanticsLabel: label,
        width: metrics.measure(label, metrics.tabStyle) + 24,
        height: height,
        fill: onPressed == null ? theme.disabledSurface : theme.accent,
        onPressed: onPressed,
        child: Center(
          child: Text(
            label,
            style: metrics.tabStyle,
            color: onPressed == null
                ? theme.disabledForeground
                : _onAccent(theme.accent),
          ),
        ),
      ),
    );
  }
}

/// White or near-black, whichever reads on [background].
Color _onAccent(Color background) {
  final double luminance = (0.299 * background.red +
          0.587 * background.green +
          0.114 * background.blue) /
      255;
  return luminance > 0.6 ? const Color(0xFF111111) : const Color(0xFFFFFFFF);
}

// ---------------------------------------------------------------------------
// The ribbon
// ---------------------------------------------------------------------------

/// Office's command ribbon. See the library comment.
///
/// Controlled or not, for each of its two states: [selectedIndex] and
/// [collapsed] decide when given, [controller] decides when given instead,
/// and the ribbon keeps its own otherwise. [onTabChanged] and
/// [onCollapsedChanged] hear every change the user asks for either way.
final class Ribbon extends StatefulWidget {
  const Ribbon({
    super.key,
    required this.tabs,
    this.selectedIndex,
    this.onTabChanged,
    this.collapsed,
    this.onCollapsedChanged,
    this.controller,
    this.leading,
    this.trailing = const <Widget>[],
    this.showCollapseButton = true,
    this.collapseShortcut = true,
    this.collapseTooltip = 'Collapse the ribbon (Ctrl+F1)',
    this.expandTooltip = 'Pin the ribbon (Ctrl+F1)',
  });

  final List<RibbonTab> tabs;

  /// The selected tab, when the caller owns it.
  final int? selectedIndex;
  final void Function(int index)? onTabChanged;

  /// Whether only the strip shows, when the caller owns it.
  final bool? collapsed;
  final void Function(bool collapsed)? onCollapsedChanged;

  final RibbonController? controller;

  /// Before the tabs: usually a [RibbonBackstageButton].
  final Widget? leading;

  /// After the tabs, at the far end of the strip: Share, Comments, search.
  final List<Widget> trailing;

  /// Whether the strip ends with the chevron that collapses and pins.
  final bool showCollapseButton;

  /// Whether Ctrl+F1 collapses and pins while the ribbon is mounted.
  final bool collapseShortcut;

  final String collapseTooltip;
  final String expandTooltip;

  /// The size each of [groups] is drawn at in a panel [width] wide, by the
  /// rules in the library comment.
  static List<RibbonGroupSize> groupSizesFor(
    List<RibbonGroup> groups,
    ThemeData theme,
    double width,
  ) =>
      _resolveSizes(groups, RibbonMetrics(theme), width);

  @override
  State<Ribbon> createState() => _RibbonState();
}

double _panelWidth(
  List<RibbonGroup> groups,
  RibbonMetrics metrics,
  List<RibbonGroupSize> sizes,
) {
  double total = 0;
  for (var i = 0; i < groups.length; i++) {
    total += groups[i].widthAt(metrics, sizes[i]);
  }
  if (groups.length > 1) {
    total += (groups.length - 1) * RibbonMetrics.separatorWidth;
  }
  return total;
}

List<RibbonGroupSize> _resolveSizes(
  List<RibbonGroup> groups,
  RibbonMetrics metrics,
  double width,
) {
  final List<RibbonGroupSize> sizes = List<RibbonGroupSize>.filled(
      groups.length, RibbonGroupSize.large,
      growable: false);
  const List<RibbonGroupSize> steps = <RibbonGroupSize>[
    RibbonGroupSize.medium,
    RibbonGroupSize.small,
    RibbonGroupSize.collapsed,
  ];
  // Integral pixels: a label measured at 41.6 and a box at 42 must agree.
  final double room = width.floorToDouble();
  for (final RibbonGroupSize step in steps) {
    for (var i = groups.length - 1; i >= 0; i--) {
      if (_panelWidth(groups, metrics, sizes) <= room) return sizes;
      if (sizes[i].index >= step.index) continue;
      final double now = groups[i].widthAt(metrics, sizes[i]);
      final double then = groups[i].widthAt(metrics, step);
      if (then < now) sizes[i] = step;
    }
  }
  return sizes;
}

final class _RibbonState extends State<Ribbon> {
  final FocusNode _stripNode = FocusNode(debugLabel: 'Ribbon tabs');
  final MenuAnchorBox _stripBox = MenuAnchorBox();
  int _ownSelected = 0;
  bool _ownCollapsed = false;
  BuildOwner? _owner;
  PopupHandle? _popup;
  PopupHost? _host;
  Theme? _theme;
  TextDirection? _direction;
  double _popupWidth = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(Ribbon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?.removeListener(_controllerChanged);
      widget.controller?.addListener(_controllerChanged);
    }
    if (!_collapsedNow) _closePopup();
    _popup?.markNeedsBuild();
  }

  @override
  void dispose() {
    _disposed = true;
    widget.controller?.removeListener(_controllerChanged);
    _owner?.removeWindowKeyHandler(_onWindowKey);
    _owner?.removeWindowKeyHandler(_onPopupKey);
    _popup?.close();
    _popup = null;
    _stripNode.dispose();
    super.dispose();
  }

  void _controllerChanged() {
    if (!mounted) return;
    if (!_collapsedNow) _closePopup();
    setState(() {});
    _popup?.markNeedsBuild();
  }

  int get _selected {
    final int raw = widget.controller?.selectedIndex ??
        widget.selectedIndex ??
        _ownSelected;
    if (widget.tabs.isEmpty) return -1;
    return raw.clamp(0, widget.tabs.length - 1);
  }

  bool get _collapsedNow =>
      widget.controller?.collapsed ?? widget.collapsed ?? _ownCollapsed;

  void _select(int index) {
    if (index < 0 || index >= widget.tabs.length || index == _selected) return;
    final RibbonController? controller = widget.controller;
    if (controller != null) {
      controller.selectedIndex = index;
    } else if (widget.selectedIndex == null) {
      setState(() => _ownSelected = index);
    }
    widget.onTabChanged?.call(index);
    _popup?.markNeedsBuild();
  }

  void _setCollapsed(bool value) {
    if (value == _collapsedNow) return;
    if (!value) _closePopup();
    final RibbonController? controller = widget.controller;
    if (controller != null) {
      controller.collapsed = value;
    } else if (widget.collapsed == null) {
      setState(() => _ownCollapsed = value);
    }
    widget.onCollapsedChanged?.call(value);
  }

  void _toggleCollapsed() => _setCollapsed(!_collapsedNow);

  bool _onWindowKey(KeyEvent event) {
    if (!mounted || !widget.collapseShortcut || event is! KeyDownEvent) {
      return false;
    }
    if (event.logicalKey != logicalKeyF1) return false;
    if (!event.modifiers.contains(KeyModifier.control) ||
        event.modifiers.contains(KeyModifier.alt) ||
        event.modifiers.contains(KeyModifier.shift)) {
      return false;
    }
    _toggleCollapsed();
    return true;
  }

  bool _onPopupKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != logicalKeyEscape) {
      return false;
    }
    if (_popup == null) return false;
    _closePopup();
    return true;
  }

  // --- the floating panel of a collapsed ribbon -----------------------------

  bool get isPopupOpen => _popup?.isOpen ?? false;

  void _tabActivated(int index) {
    if (!_collapsedNow) {
      _select(index);
      return;
    }
    if (isPopupOpen && index == _selected) {
      _closePopup();
      return;
    }
    _select(index);
    _openPopup();
  }

  void _openPopup() {
    if (isPopupOpen) {
      _popup!.markNeedsBuild();
      return;
    }
    final PopupHost? host = _host;
    final Rect? strip = _stripBox.globalRect;
    if (host == null || strip == null) return;
    _popupWidth = strip.width;
    _popup = host.open(PopupSpec(
      anchorRect: strip,
      builder: _buildPopup,
      kind: PopupKind.menu,
      adjustments: const <PopupAdjustment>{
        PopupAdjustment.slideX,
        PopupAdjustment.slideY,
      },
      // The strip stays live under the popup: another tab switches the
      // panel, the same tab closes it, a double click pins the ribbon.
      passThrough: () => _stripBox.globalRect,
      onDismiss: _popupDismissed,
    ));
    _owner?.addWindowKeyHandler(_onPopupKey, modalDepth: 1 << 30, first: true);
    if (mounted) setState(() {});
  }

  void _closePopup() => _popup?.close();

  void _popupDismissed() {
    _popup = null;
    _owner?.removeWindowKeyHandler(_onPopupKey);
    if (!_disposed && mounted) setState(() {});
  }

  Widget _buildPopup(BuildContext context) {
    final int selected = _selected;
    Widget content = selected < 0
        ? const SizedBox()
        : Builder(builder: (BuildContext inner) {
            final ThemeData theme = Theme.of(inner);
            return SizedBox(
              width: _popupWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.surfaceRaised,
                  border: BoxBorder(color: theme.border, width: 1),
                  radius: theme.cornerRadiusLarge,
                ),
                child: _RibbonPanel(
                  key: ValueKey<Object>(widget.tabs[selected].identity),
                  tab: widget.tabs[selected],
                  framed: false,
                ),
              ),
            );
          });
    content = _RibbonPopupScope(close: _closePopup, child: content);
    final Theme? theme = _theme;
    if (theme != null) {
      content = Theme(
        data: theme.data,
        styles: theme.styles,
        resources: theme.resources,
        templates: theme.templates,
        child: content,
      );
    }
    final TextDirection? direction = _direction;
    if (direction != null) {
      content = Directionality(textDirection: direction, child: content);
    }
    return content;
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_owner == null && context is Element) {
      _owner = context.owner
        ?..addWindowKeyHandler(_onWindowKey, modalDepth: modalDepthOf(context));
    }
    _host = PopupHost.maybeOf(context);
    _theme = Theme.maybeOf(context);
    _direction = Directionality.maybeOf(context);
    final ThemeData theme = Theme.of(context);
    final RibbonMetrics metrics = RibbonMetrics(theme);
    final int selected = _selected;
    final bool collapsed = _collapsedNow;
    final TextDirection direction = _direction ?? TextDirection.leftToRight;

    final Widget strip = AnchorProbe(
      anchor: _stripBox,
      child: SizedBox(
        height: metrics.tabStripHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (widget.leading != null) ...<Widget>[
                widget.leading!,
                const SizedBox(width: 4),
              ],
              // The tabs give way to the end of the strip: a window too
              // narrow for every tab clips the last ones, never the
              // collapse button or the trailing widgets.
              Expanded(
                child: ClipRect(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      FocusAttachment(
                        node: _stripNode,
                        child: Semantics(
                          role: SemanticsRole.list,
                          value: '${widget.tabs.length} tabs',
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              for (var i = 0; i < widget.tabs.length; i++)
                                _RibbonTabHeader(
                                  key:
                                      ValueKey<Object>(widget.tabs[i].identity),
                                  metrics: metrics,
                                  tab: widget.tabs[i],
                                  index: i,
                                  count: widget.tabs.length,
                                  selected: i == selected &&
                                      (!collapsed || isPopupOpen),
                                  focusNode: i == selected ? _stripNode : null,
                                  onActivate: () => _tabActivated(i),
                                  onDoubleClick: _toggleCollapsed,
                                  onKey: (KeyEvent event) =>
                                      _handleStripKey(event, direction),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ...widget.trailing,
              if (widget.showCollapseButton)
                Center(
                  child: _RibbonPressable(
                    theme: theme,
                    role: SemanticsRole.button,
                    semanticsLabel: collapsed
                        ? widget.expandTooltip
                        : widget.collapseTooltip,
                    tooltip: collapsed
                        ? widget.expandTooltip
                        : widget.collapseTooltip,
                    width: metrics.rowHeight,
                    height: metrics.rowHeight,
                    closesPopup: false,
                    // Ctrl+F1 is its key: Tab goes from the tabs into the
                    // panel, not to the chevron at the far end.
                    skipTraversal: true,
                    onPressed: _toggleCollapsed,
                    child: Center(
                      child: Chevron(
                        direction: collapsed
                            ? ChevronDirection.down
                            : ChevronDirection.up,
                        size: 12,
                        color: theme.foregroundSecondary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(color: theme.surfaceBase),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          strip,
          if (!collapsed && selected >= 0)
            Padding(
              padding: const EdgeInsets(4, 0, 4, 4),
              child: _RibbonPanel(
                key: ValueKey<Object>(widget.tabs[selected].identity),
                tab: widget.tabs[selected],
                framed: true,
              ),
            ),
        ],
      ),
    );
  }

  bool _handleStripKey(KeyEvent event, TextDirection direction) {
    if (event is! KeyDownEvent) return false;
    final bool rtl = direction.isRightToLeft;
    switch (event.logicalKey) {
      case logicalKeyArrowRight:
        _moveTab(rtl ? -1 : 1);
        return true;
      case logicalKeyArrowLeft:
        _moveTab(rtl ? 1 : -1);
        return true;
      case logicalKeyHome:
        _select(0);
        return true;
      case logicalKeyEnd:
        _select(widget.tabs.length - 1);
        return true;
      case logicalKeyArrowDown:
        if (_collapsedNow) {
          _openPopup();
          return true;
        }
        return _stripNode.manager?.moveFocus(TraversalDirection.next) ?? false;
    }
    return false;
  }

  void _moveTab(int delta) {
    final int target = _selected + delta;
    if (target < 0 || target >= widget.tabs.length) return;
    _select(target);
  }
}

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------

/// One tab's groups, each at the size the width allows.
final class _RibbonPanel extends StatelessWidget {
  const _RibbonPanel({super.key, required this.tab, required this.framed});

  final RibbonTab tab;

  /// Whether to draw the panel's own card; the floating panel is framed by
  /// its popup instead.
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final RibbonMetrics metrics = RibbonMetrics(theme);
    final Widget body = SizedBox(
      height: metrics.panelHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ClipRect(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final List<RibbonGroupSize> sizes =
                  _resolveSizes(tab.groups, metrics, constraints.maxWidth);
              return Row(
                children: <Widget>[
                  for (var i = 0; i < tab.groups.length; i++) ...<Widget>[
                    if (i > 0) _GroupSeparator(metrics: metrics),
                    SizedBox(
                      width: tab.groups[i].widthAt(metrics, sizes[i]),
                      child: _RibbonGroupView(
                        group: tab.groups[i],
                        size: sizes[i],
                        metrics: metrics,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
    return Semantics(
      label: tab.label,
      child: framed
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: theme.surfaceAlternate,
                border: BoxBorder(color: theme.borderSubtle, width: 1),
                radius: theme.cornerRadiusLarge,
              ),
              child: body,
            )
          : body,
    );
  }
}

final class _GroupSeparator extends StatelessWidget {
  const _GroupSeparator({required this.metrics});

  final RibbonMetrics metrics;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: RibbonMetrics.separatorWidth,
        child: Center(
          child: SizedBox(
            width: 1,
            height: metrics.panelHeight - 16,
            child: ColoredBox(color: metrics.theme.border),
          ),
        ),
      );
}

/// A group at one size: its columns over its name, or the one button that
/// stands for it.
final class _RibbonGroupView extends StatelessWidget {
  const _RibbonGroupView({
    required this.group,
    required this.size,
    required this.metrics,
  });

  final RibbonGroup group;
  final RibbonGroupSize size;
  final RibbonMetrics metrics;

  @override
  Widget build(BuildContext context) {
    if (size == RibbonGroupSize.collapsed) {
      return _CollapsedGroup(group: group, metrics: metrics);
    }
    final ThemeData theme = metrics.theme;
    final List<List<RibbonItem>> columns = group.columnsAt(size);
    final void Function()? launcher = group.onDialogLauncher;
    final bool rtl = Directionality.maybeOf(context)?.isRightToLeft ?? false;
    return Semantics(
      label: group.label,
      child: Padding(
        padding: const EdgeInsets(
            RibbonMetrics.groupPadding, 4, RibbonMetrics.groupPadding, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: metrics.contentHeight,
              child: _RibbonItemScope(
                size: size,
                metrics: metrics,
                child: Row(
                  children: <Widget>[
                    for (var c = 0; c < columns.length; c++) ...<Widget>[
                      if (c > 0) const SizedBox(width: RibbonMetrics.columnGap),
                      _column(columns[c]),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: metrics.groupLabelHeight,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    left: launcher == null ? 0 : 16,
                    right: launcher == null ? 0 : 16,
                    child: Center(
                      child: Text(
                        group.label,
                        style: metrics.groupLabelStyle,
                        color: theme.foregroundSecondary,
                        maxLines: 1,
                        ellipsis: '…',
                      ),
                    ),
                  ),
                  if (launcher != null)
                    Positioned(
                      left: rtl ? 0 : null,
                      right: rtl ? null : 0,
                      top: 1,
                      width: 16,
                      height: 16,
                      child: _RibbonPressable(
                        theme: theme,
                        role: SemanticsRole.button,
                        semanticsLabel: group.dialogLauncherTooltip ??
                            'More ${group.label} options',
                        tooltip: group.dialogLauncherTooltip ??
                            'More ${group.label} options',
                        width: 16,
                        height: 16,
                        onPressed: launcher,
                        child: Center(
                          child: Icon(
                            FluentIcons.arrowDownRight,
                            size: 12,
                            color: theme.foregroundSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _column(List<RibbonItem> items) {
    double widest = 0;
    for (final RibbonItem item in items) {
      widest = math.max(widest, item.widthAt(metrics, size));
    }
    if (items.length == 1 && items.first.isColumnAt(size)) {
      return SizedBox(
        width: widest,
        height: metrics.contentHeight,
        child: items.first,
      );
    }
    return SizedBox(
      width: widest,
      child: Column(
        children: <Widget>[
          for (final RibbonItem item in items)
            SizedBox(
              height: metrics.rowHeight,
              child: Row(
                children: <Widget>[
                  SizedBox(width: item.widthAt(metrics, size), child: item),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A group with no room: one large button with the group's icon and name,
/// opening the whole group below it.
final class _CollapsedGroup extends StatelessWidget {
  const _CollapsedGroup({required this.group, required this.metrics});

  final RibbonGroup group;
  final RibbonMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final _RibbonPopupScope? outer = _RibbonPopupScope.maybeOf(context);
    return Padding(
      padding: const EdgeInsets(
          RibbonMetrics.groupPadding, 4, RibbonMetrics.groupPadding, 0),
      child: Flyout(
        autofocus: false,
        padding: const EdgeInsets.all(2),
        builder: (BuildContext context, FlyoutController controller) => Align(
          alignment: Alignment.topCenter,
          child: _RibbonButtonFace(
            metrics: metrics,
            mode: _FaceMode.large,
            icon: group._icon,
            label: group.label,
            enabled: group.items.isNotEmpty,
            checked: false,
            chevron: true,
            closesPopup: false,
            expanded: controller.isOpen,
            tooltip: group.label,
            role: SemanticsRole.button,
            width: metrics.largeButtonWidth(group.label, chevron: true),
            onPressed: controller.toggle,
          ),
        ),
        content: (BuildContext inner, FlyoutController controller) {
          return _RibbonPopupScope(
            close: () {
              controller.close();
              outer?.close();
            },
            child: SizedBox(
              width: group.widthAt(metrics, RibbonGroupSize.large),
              height: metrics.panelHeight,
              child: _RibbonGroupView(
                group: group,
                size: RibbonGroupSize.large,
                metrics: metrics,
              ),
            ),
          );
        },
      ),
    );
  }
}

final class _RibbonItemScope extends InheritedWidget {
  const _RibbonItemScope({
    required this.size,
    required this.metrics,
    required super.child,
  });

  final RibbonGroupSize size;
  final RibbonMetrics metrics;

  static _RibbonItemScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RibbonItemScope>();

  @override
  bool updateShouldNotify(_RibbonItemScope oldWidget) =>
      size != oldWidget.size || !identical(metrics, oldWidget.metrics);
}

/// The popup a ribbon control sits in - a collapsed ribbon's panel, a
/// collapsed group - which a command closes as it runs.
final class _RibbonPopupScope extends InheritedWidget {
  const _RibbonPopupScope({required this.close, required super.child});

  final void Function() close;

  static _RibbonPopupScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RibbonPopupScope>();

  @override
  bool updateShouldNotify(_RibbonPopupScope oldWidget) =>
      !identical(close, oldWidget.close);
}

// ---------------------------------------------------------------------------
// Tab headers
// ---------------------------------------------------------------------------

final class _RibbonTabHeader extends StatelessWidget {
  const _RibbonTabHeader({
    super.key,
    required this.metrics,
    required this.tab,
    required this.index,
    required this.count,
    required this.selected,
    required this.focusNode,
    required this.onActivate,
    required this.onDoubleClick,
    required this.onKey,
  });

  final RibbonMetrics metrics;
  final RibbonTab tab;
  final int index;
  final int count;
  final bool selected;
  final FocusNode? focusNode;
  final void Function() onActivate;
  final void Function() onDoubleClick;
  final bool Function(KeyEvent event) onKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = metrics.theme;
    final Color? contextual = tab.contextualColor;
    final TextStyle style = selected
        ? metrics.tabStyle.copyWith(fontWeight: FontWeight.w600)
        : metrics.tabStyle;
    // Measured at the selected weight, so selecting a tab does not move the
    // ones after it.
    final double textWidth = metrics.measure(
        tab.label, metrics.tabStyle.copyWith(fontWeight: FontWeight.w600));
    final Color text =
        contextual ?? (selected ? theme.foreground : theme.foregroundSecondary);
    return _RibbonControlWidget(
      theme: theme,
      focusNode: focusNode,
      enabled: true,
      checked: false,
      fill: null,
      radius: theme.cornerRadiusSmall,
      role: SemanticsRole.listItem,
      semanticsLabel: tab.label,
      selected: selected,
      expanded: null,
      hint: 'tab ${index + 1} of $count',
      onActivate: onActivate,
      onDoubleClick: onDoubleClick,
      onKey: onKey,
      child: SizedBox(
        width: textWidth + 24,
        child: Stack(
          children: <Widget>[
            if (contextual != null)
              Positioned(
                left: 2,
                right: 2,
                top: 0,
                height: 3,
                child: ColoredBox(color: contextual.withAlpha(150)),
              ),
            Positioned.fill(
              child: Center(
                child: Text(tab.label, style: style, color: text),
              ),
            ),
            if (selected)
              Positioned(
                left: 12,
                right: 12,
                bottom: 2,
                height: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: contextual ?? theme.accent,
                    radius: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Button faces
// ---------------------------------------------------------------------------

enum _FaceMode { large, row, icon }

/// A ribbon button's face at one mode: large, small with its label, or icon
/// only.
final class _RibbonButtonFace extends StatelessWidget {
  const _RibbonButtonFace({
    required this.metrics,
    required this.mode,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.checked,
    required this.tooltip,
    required this.role,
    required this.width,
    required this.onPressed,
    this.iconColor,
    this.chevron = false,
    this.expanded,
    this.closesPopup = true,
  });

  final RibbonMetrics metrics;
  final _FaceMode mode;
  final IconData icon;
  final Color? iconColor;
  final String label;
  final bool enabled;
  final bool checked;
  final String? tooltip;
  final SemanticsRole role;
  final double width;
  final void Function()? onPressed;
  final bool chevron;
  final bool? expanded;
  final bool closesPopup;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = metrics.theme;
    final Color foreground =
        enabled ? theme.foreground : theme.disabledForeground;
    final Color glyph = enabled
        ? (iconColor ?? theme.iconTheme.color ?? theme.foreground)
        : theme.disabledForeground;
    final Widget content = switch (mode) {
      _FaceMode.large => _largeContent(metrics, icon, glyph, label, foreground,
          chevron: chevron),
      _FaceMode.row =>
        _rowContent(metrics, icon, glyph, label, foreground, chevron: chevron),
      _FaceMode.icon =>
        _rowContent(metrics, icon, glyph, null, foreground, chevron: chevron),
    };
    return _RibbonPressable(
      theme: theme,
      enabled: enabled && onPressed != null,
      checked: checked,
      role: role,
      semanticsLabel: label,
      tooltip: tooltip,
      expanded: expanded,
      closesPopup: closesPopup,
      width: width,
      height:
          mode == _FaceMode.large ? metrics.contentHeight : metrics.rowHeight,
      onPressed: onPressed,
      child: content,
    );
  }
}

Widget _largeContent(
  RibbonMetrics metrics,
  IconData icon,
  Color glyph,
  String label,
  Color foreground, {
  required bool chevron,
}) {
  final List<String> lines = metrics.largeLines(label);
  final Widget mark = Chevron(size: 10, color: foreground);
  return Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: RibbonMetrics.largeIconSize, color: glyph),
        const SizedBox(height: 3),
        for (var i = 0; i < lines.length; i++)
          if (chevron && i == lines.length - 1 && lines.length > 1)
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Text(lines[i], style: metrics.labelStyle, color: foreground),
                SizedBox(width: RibbonMetrics.chevronWidth, child: mark),
              ],
            )
          else
            Text(lines[i], style: metrics.labelStyle, color: foreground),
        if (chevron && lines.length == 1)
          SizedBox(height: 14, child: Center(child: mark)),
      ],
    ),
  );
}

Widget _rowContent(
  RibbonMetrics metrics,
  IconData icon,
  Color glyph,
  String? label,
  Color foreground, {
  required bool chevron,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Row(
      mainAxisAlignment: label == null && !chevron
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: RibbonMetrics.smallIconSize, color: glyph),
        if (label != null && label.isNotEmpty) ...<Widget>[
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              style: metrics.labelStyle,
              color: foreground,
              maxLines: 1,
              ellipsis: '…',
            ),
          ),
        ] else if (chevron)
          const Spacer(),
        if (chevron)
          SizedBox(
            width: RibbonMetrics.chevronWidth,
            child: Center(child: Chevron(size: 10, color: foreground)),
          ),
      ],
    ),
  );
}

/// The two parts of a split button: the face that runs, and the arrow that
/// opens the menu.
final class _RibbonSplitFace extends StatelessWidget {
  const _RibbonSplitFace({
    required this.metrics,
    required this.mode,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.tooltip,
    required this.width,
    required this.onPressed,
    required this.menuChildren,
    this.iconColor,
  });

  final RibbonMetrics metrics;
  final _FaceMode mode;
  final IconData icon;
  final Color? iconColor;
  final String label;
  final bool enabled;
  final String? tooltip;
  final double width;
  final void Function()? onPressed;
  final List<Widget> menuChildren;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = metrics.theme;
    final Color foreground =
        enabled ? theme.foreground : theme.disabledForeground;
    final Color glyph = enabled
        ? (iconColor ?? theme.iconTheme.color ?? theme.foreground)
        : theme.disabledForeground;
    return MenuAnchor(
      menuChildren: menuChildren,
      builder: (BuildContext context, MenuController controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (mode == _FaceMode.large) {
          const double iconPart = RibbonMetrics.largeIconSize + 8;
          return Column(
            children: <Widget>[
              _RibbonPressable(
                theme: theme,
                enabled: enabled && onPressed != null,
                role: SemanticsRole.button,
                semanticsLabel: label,
                tooltip: tooltip,
                width: width,
                height: iconPart,
                onPressed: onPressed,
                child: Center(
                  child: Icon(icon,
                      size: RibbonMetrics.largeIconSize, color: glyph),
                ),
              ),
              _RibbonPressable(
                theme: theme,
                role: SemanticsRole.button,
                semanticsLabel: '$label options',
                tooltip: tooltip,
                expanded: controller.isOpen,
                closesPopup: false,
                width: width,
                height: metrics.contentHeight - iconPart,
                onPressed: toggle,
                child: _largeLabel(metrics, label, foreground),
              ),
            ],
          );
        }
        const double arrow = RibbonMetrics.chevronWidth + 2;
        return Row(
          children: <Widget>[
            _RibbonPressable(
              theme: theme,
              enabled: enabled && onPressed != null,
              role: SemanticsRole.button,
              semanticsLabel: label,
              tooltip: tooltip,
              width: width - arrow,
              height: metrics.rowHeight,
              onPressed: onPressed,
              child: _rowContent(metrics, icon, glyph,
                  mode == _FaceMode.icon ? null : label, foreground,
                  chevron: false),
            ),
            _RibbonPressable(
              theme: theme,
              role: SemanticsRole.button,
              semanticsLabel: '$label options',
              tooltip: tooltip,
              expanded: controller.isOpen,
              closesPopup: false,
              width: arrow,
              height: metrics.rowHeight,
              onPressed: toggle,
              child: Center(
                child: Chevron(size: 10, color: theme.foreground),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The label half of a large split button: the lines, the chevron after the
/// last.
Widget _largeLabel(RibbonMetrics metrics, String label, Color foreground) {
  final List<String> lines = metrics.largeLines(label);
  final Widget mark = Chevron(size: 10, color: foreground);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: <Widget>[
      const SizedBox(height: 1),
      for (var i = 0; i < lines.length; i++)
        if (i == lines.length - 1 && lines.length > 1)
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Text(lines[i], style: metrics.labelStyle, color: foreground),
              SizedBox(width: RibbonMetrics.chevronWidth, child: mark),
            ],
          )
        else
          Text(lines[i], style: metrics.labelStyle, color: foreground),
      if (lines.length == 1) SizedBox(height: 14, child: Center(child: mark)),
    ],
  );
}

// ---------------------------------------------------------------------------
// The pressable surface every ribbon control is drawn on
// ---------------------------------------------------------------------------

/// A focusable, hoverable surface of a fixed size that runs [onPressed]:
/// what every button, tab and tile of the ribbon is.
final class _RibbonPressable extends StatefulWidget {
  const _RibbonPressable({
    required this.theme,
    required this.role,
    required this.semanticsLabel,
    required this.width,
    required this.height,
    required this.onPressed,
    required this.child,
    this.enabled = true,
    this.checked = false,
    this.expanded,
    this.tooltip,
    this.fill,
    this.closesPopup = true,
    this.skipTraversal = false,
  });

  final ThemeData theme;
  final SemanticsRole role;
  final String semanticsLabel;
  final double width;
  final double height;
  final void Function()? onPressed;
  final Widget child;
  final bool enabled;
  final bool checked;
  final bool? expanded;
  final String? tooltip;
  final Color? fill;

  /// Whether pressing this puts away the popup it is in: true for a
  /// command, false for a control that opens something else.
  final bool closesPopup;

  /// Whether Tab passes this control by - one that has a key of its own.
  final bool skipTraversal;

  @override
  State<_RibbonPressable> createState() => _RibbonPressableState();
}

final class _RibbonPressableState extends State<_RibbonPressable> {
  late final FocusNode _node =
      FocusNode(debugLabel: 'Ribbon ${widget.semanticsLabel}');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final void Function()? pressed = widget.onPressed;
    final bool enabled = widget.enabled && pressed != null;
    final _RibbonPopupScope? popup =
        widget.closesPopup ? _RibbonPopupScope.maybeOf(context) : null;
    _node.skipTraversal = widget.skipTraversal;
    Widget result = FocusAttachment(
      node: _node,
      child: _RibbonControlWidget(
        theme: widget.theme,
        focusNode: _node,
        enabled: enabled,
        checked: widget.checked,
        fill: widget.fill,
        radius: widget.theme.cornerRadiusSmall,
        role: widget.role,
        semanticsLabel: widget.semanticsLabel,
        selected: null,
        expanded: widget.expanded,
        hint: null,
        onActivate: !enabled
            ? null
            : () {
                // Closed first, then run: a command that opens a dialog
                // must not have it torn down with the popup.
                popup?.close();
                pressed();
              },
        onDoubleClick: null,
        onKey: null,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: widget.child,
        ),
      ),
    );
    final String? tooltip = widget.tooltip;
    if (tooltip != null && tooltip.isNotEmpty) {
      result = Tooltip(message: tooltip, child: result);
    }
    return result;
  }
}

final class _RibbonControlWidget extends SingleChildRenderObjectWidget {
  const _RibbonControlWidget({
    required this.theme,
    required this.focusNode,
    required this.enabled,
    required this.checked,
    required this.fill,
    required this.radius,
    required this.role,
    required this.semanticsLabel,
    required this.selected,
    required this.expanded,
    required this.hint,
    required this.onActivate,
    required this.onDoubleClick,
    required this.onKey,
    required super.child,
  });

  final ThemeData theme;
  final FocusNode? focusNode;
  final bool enabled;
  final bool checked;
  final Color? fill;
  final double radius;
  final SemanticsRole role;
  final String semanticsLabel;
  final bool? selected;
  final bool? expanded;
  final String? hint;
  final void Function()? onActivate;
  final void Function()? onDoubleClick;
  final bool Function(KeyEvent event)? onKey;

  @override
  RenderRibbonControl createRenderObject(BuildContext context) =>
      RenderRibbonControl()
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = enabled
        ..checked = checked
        ..fill = fill
        ..radius = radius
        ..role = role
        ..semanticsLabel = semanticsLabel
        ..selected = selected
        ..expanded = expanded
        ..hint = hint
        ..onActivate = onActivate
        ..onDoubleClick = onDoubleClick
        ..onKey = onKey;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderRibbonControl renderObject,
  ) {
    renderObject
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = enabled
      ..checked = checked
      ..fill = fill
      ..radius = radius
      ..role = role
      ..semanticsLabel = semanticsLabel
      ..selected = selected
      ..expanded = expanded
      ..hint = hint
      ..onActivate = onActivate
      ..onDoubleClick = onDoubleClick
      ..onKey = onKey;
  }
}

/// The render object under every ribbon control: hover, press, the checked
/// wash, the focus ring, keyboard activation and its semantic node.
///
/// Public so a test or an automation client can find a ribbon control by
/// [semanticsLabel] and read its state.
final class RenderRibbonControl extends RenderProxyBox with ControlBehavior {
  bool _checked = false;
  Color? _fill;
  double _radius = 4;
  bool _suppressActivation = false;

  /// What the control is to assistive technology.
  SemanticsRole role = SemanticsRole.button;

  /// The control's name: its label, or the tab's.
  String semanticsLabel = '';

  /// A tab's selection; null for anything else.
  bool? selected;

  /// Whether the menu or popup it opens is showing; null when it opens none.
  bool? expanded;

  String? hint;

  void Function()? onActivate;

  /// A second click of a double click, reported as it lands.
  void Function()? onDoubleClick;

  /// Offered each key before the control's own Space and Enter.
  bool Function(KeyEvent event)? onKey;

  /// Whether a toggle is on.
  bool get checked => _checked;

  set checked(bool value) {
    if (value == _checked) return;
    _checked = value;
    markNeedsPaint();
  }

  /// A fill at rest: the File button's accent.
  Color? get fill => _fill;

  set fill(Color? value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsPaint();
  }

  double get radius => _radius;

  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    markNeedsPaint();
  }

  /// A ribbon control leaves the keyboard where it was: the command it runs
  /// acts on the document, and the document should keep focus.
  @override
  bool get focusOnPointerDown => false;

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_checked) PseudoClass.checked,
        if (selected ?? false) PseudoClass.selected,
      };

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void activate() {
    if (_suppressActivation) return;
    onActivate?.call();
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent &&
        event.button == PointerButton.primary &&
        event.clickCount >= 2 &&
        enabled) {
      final void Function()? doubled = onDoubleClick;
      if (doubled != null) {
        // The release that ends a double click is not a third click.
        _suppressActivation = true;
        doubled();
      }
    }
    super.handlePointerEvent(event);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _suppressActivation = false;
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (enabled && (onKey?.call(event) ?? false)) return true;
    return super.handleKeyEvent(event);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final Color? rest = _checked ? theme.accentSubtle : _fill;
    Color? surface = rest;
    if (enabled && isPressed) {
      surface = _fill == null ? theme.pressedSurface : theme.accentPressed;
    } else if (enabled && isHovered) {
      surface = _fill == null
          ? (_checked ? theme.pressedSurface : theme.hoverSurface)
          : theme.accentHovered;
    }
    if (surface != null) paintRoundedFill(list, rect, surface, _radius);
    if (_checked) {
      paintRoundedBorder(list, rect, theme.accent.withAlpha(120), _radius);
    }
    super.paint(list, offset);
    paintFocusRing(list, rect, radius: _radius);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: role,
        label: semanticsLabel,
        hint: hint,
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
          if (_checked) SemanticsState.checked,
          if (selected ?? false) SemanticsState.selected,
          if (expanded ?? false) SemanticsState.expanded,
        },
        actions: enabled
            ? <SemanticsAction>{
                SemanticsAction.activate,
                SemanticsAction.focus,
                if (expanded != null) SemanticsAction.showMenu,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}
