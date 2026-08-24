/// The strip of collapsed panel tabs that lives on a window edge.
///
/// This is the piece `docking_flutter` never had and sK1 leans on: the right
/// edge of the window keeps a narrow column of *vertical* tabs, one per opened
/// panel, and the panel body next to them collapses entirely when none is
/// selected. It is how an editor keeps "Transformations" and "Align and
/// Distribute" one click away without spending 300 px on them.
///
/// ## The labels are rotated, and for a while they could not be
///
/// A quarter-turned label is the obvious rendering and the one sK1 uses, and
/// for a while it was not available: both rasterizers refused a glyph run
/// under a rotated transform by name, so a rotated tab would have drawn on a
/// GPU backend and thrown on the software one. This file stacked its
/// characters one above another to stay inside that limit, and said so here.
///
/// The limit is gone. `cpu_renderer.dart` and `gpu_raster_sink.dart` both fill
/// the glyph's outline under the full matrix when a cached mask cannot serve
/// it - see `glyphMasksFit` in `rendering/text/glyph_raster.dart` and ADR 0007
/// - so the two backends draw a turned label to the same pixels. The stacking
/// is gone with it: stacked characters lose every kerning pair and every
/// ligature, and a word set that way is measurably slower to read than the
/// same word turned.
///
/// ## Why this owns a render object instead of composing `Transform`
///
/// [Transform] applies a matrix at paint time and leaves layout alone, which
/// is exactly right for a chevron that turns without reflowing its row and
/// exactly wrong here: a strip 26 px wide has to reserve the label's *width*
/// as its own height, and the child inside a 26 px column would be laid out at
/// 26 px and wrap. The turn has to happen in layout, so it is a render object
/// - [_RenderVerticalLabel] below - and a small one: it measures through the
/// same painter it draws with, swaps the two axes, and emits one matrix.
library;

import '../../geometry/offset.dart';
import '../../geometry/size.dart';
import '../../graphics/color.dart';
import '../../graphics/display_list.dart';
import '../../layout/edge_insets.dart';
import '../../layout/render_box.dart';
import '../../layout/render_flex.dart';
import '../../rendering/text/font_registry.dart';
import '../../text/typeface.dart';
import '../basic.dart';
import '../controls.dart' show Tooltip;
import '../element.dart';
import '../gesture_detector.dart';
import '../icon.dart';
import '../icon_button.dart';
import '../proxy.dart';
import '../theme.dart';
import '../widget.dart';
import 'docking_theme.dart';

/// One collapsed panel in a [CollapsedTabStrip].
final class CollapsedTab {
  const CollapsedTab({
    required this.id,
    required this.label,
    this.icon,
    this.closable = true,
  });

  /// What this tab *is*, stable across rebuilds.
  final Object id;

  /// The name shown down the strip.
  final String label;

  final IconData? icon;

  final bool closable;
}

/// A vertical strip of collapsed panel tabs, pinned to a window edge.
final class CollapsedTabStrip extends StatelessWidget {
  const CollapsedTabStrip({
    super.key,
    required this.tabs,
    required this.selectedId,
    this.onSelected,
    this.onClosed,
    this.width = 26,
    this.labelFontSize = 10,
  });

  final List<CollapsedTab> tabs;

  /// The expanded panel, or null when every panel is collapsed.
  final Object? selectedId;

  /// Reports the tab the user clicked. Clicking the open one asks to collapse
  /// it, which is why this reports an id rather than toggling internally.
  final void Function(Object id)? onSelected;

  final void Function(Object id)? onClosed;

  final double width;
  final double labelFontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final docking = DockingTheme.of(context);
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: docking.headerColor,
          border: BoxBorder(color: docking.borderColor, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: 4),
            for (final tab in tabs)
              _CollapsedTabButton(
                tab: tab,
                selected: tab.id == selectedId,
                width: width,
                labelFontSize: labelFontSize,
                accent: theme.accent,
                surface: docking.activeHeaderColor,
                foreground: docking.foregroundColor,
                selectedForeground: theme.surfaceAlternate,
                onSelected: onSelected,
                onClosed: onClosed,
              ),
          ],
        ),
      ),
    );
  }
}

final class _CollapsedTabButton extends StatelessWidget {
  const _CollapsedTabButton({
    required this.tab,
    required this.selected,
    required this.width,
    required this.labelFontSize,
    required this.accent,
    required this.surface,
    required this.foreground,
    required this.selectedForeground,
    this.onSelected,
    this.onClosed,
  });

  final CollapsedTab tab;
  final bool selected;
  final double width;
  final double labelFontSize;
  final Color accent;
  final Color surface;
  final Color foreground;
  final Color selectedForeground;
  final void Function(Object id)? onSelected;
  final void Function(Object id)? onClosed;

  @override
  Widget build(BuildContext context) {
    final foregroundColor = selected ? selectedForeground : foreground;
    return Tooltip(
      message: selected ? 'Collapse ${tab.label}' : 'Open ${tab.label}',
      child: GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: () => onSelected?.call(tab.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? accent : surface,
              radius: 3,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  if (tab.icon != null) ...<Widget>[
                    Icon(tab.icon!, size: 13, color: foregroundColor),
                    const SizedBox(height: 4),
                  ],
                  _VerticalLabel(
                    tab.label,
                    color: foregroundColor,
                    fontSize: labelFontSize,
                  ),
                  if (tab.closable && onClosed != null) ...<Widget>[
                    const SizedBox(height: 2),
                    IconButton(
                      icon: const Icon(Icons.close),
                      iconSize: 11,
                      padding: EdgeInsets.zero,
                      color: foregroundColor,
                      tooltip: 'Close ${tab.label}',
                      onPressed: () => onClosed!(tab.id),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One line of text turned a quarter turn, reading bottom to top.
///
/// The direction is the one every editor with a vertical tab strip uses on a
/// left or right edge - VS Code, IntelliJ, sK1 - and it is not arbitrary: read
/// upward, the first character of the label is nearest the tab's own bottom
/// edge, which is where the eye arrives from the strip below it.
final class _VerticalLabel extends RenderObjectWidget {
  const _VerticalLabel(
    this.text, {
    required this.color,
    required this.fontSize,
  });

  final String text;
  final Color color;
  final double fontSize;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  _RenderVerticalLabel createRenderObject(BuildContext context) =>
      _RenderVerticalLabel(text: text, color: color, fontSize: fontSize);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderVerticalLabel renderObject,
  ) {
    renderObject
      ..text = text
      ..color = color
      ..fontSize = fontSize;
  }
}

/// Lays out a line of text along the vertical axis and paints it turned.
///
/// The whole of the turn is the matrix in [paint], and it is worth reading
/// once rather than trusting: the label is laid out in its own space, where
/// `u` runs along the text and `v` across it, and this box maps `(u, v)` to
/// `(v, height - u)`. So the text starts at the box's *bottom* left corner and
/// runs upward, and `v` - the descent side of the line - grows to the right.
///
/// Nothing here is drawn as a path or an image: it is an ordinary glyph run
/// under an ordinary transform, so it is shaped once, kerned, and rasterized
/// by whichever backend the window is using. That is the point of the change
/// that made this file possible.
final class _RenderVerticalLabel extends RenderBox {
  _RenderVerticalLabel({
    required String text,
    required Color color,
    required double fontSize,
  })  : _text = text,
        _color = color,
        _fontSize = fontSize;

  String _text;
  Color _color;
  double _fontSize;

  String get text => _text;

  set text(String value) {
    if (value == _text) return;
    _text = value;
    markNeedsLayout();
  }

  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double get fontSize => _fontSize;

  set fontSize(double value) {
    if (value == _fontSize) return;
    _fontSize = value;
    markNeedsLayout();
  }

  /// The face the strip's font size resolves to, or null on a machine with no
  /// fonts at all - which reserves a box and draws nothing, the same failure
  /// shape `RenderText` chooses, so a missing font looks like missing text
  /// rather than like a collapsed strip.
  ScaledTypeface? get _font => FontRegistry.instance.uiFont(_fontSize);

  /// The label's size *unturned*: shaped width by line height.
  ///
  /// Through the same painter [paint] draws with, so the box reserved and the
  /// run drawn cannot disagree - which for a turned label would show as the
  /// last letter clipped off the top.
  Size get _naturalSize {
    final ScaledTypeface? face = _font;
    return face == null
        ? FontRegistry.estimatedSize(_text, _fontSize)
        : uiTextPainter.measure(_text, face);
  }

  @override
  void performLayout() {
    final Size natural = _naturalSize;
    // The swap that [Transform] cannot do: the label's width becomes this
    // box's height, so the column above reserves the room the turned text
    // needs and the tabs below it start after the label rather than on top of
    // it.
    size = constraints.constrain(Size(natural.height, natural.width));
  }

  @override
  double computeMinIntrinsicWidth(double height) => _naturalSize.height;

  @override
  double computeMaxIntrinsicWidth(double height) => _naturalSize.height;

  @override
  double computeMinIntrinsicHeight(double width) => _naturalSize.width;

  @override
  double computeMaxIntrinsicHeight(double width) => _naturalSize.width;

  /// The strip's tap target is the whole tab, so the label itself must not
  /// take hits - the same answer `RenderText` gives.
  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    final ScaledTypeface? face = _font;
    if (_text.isEmpty || face == null) return;
    final Size natural = _naturalSize;
    // Centred along both axes of the *turned* box: along its height the label
    // may be shorter than the room the constraints gave, and across its width
    // the line box may be narrower than the strip.
    final double alongText = (size.height - natural.width) / 2;
    final double acrossText = (size.width - natural.height) / 2;

    list
      ..save()
      // (u, v) -> (v, height - u), then the box's own offset. Written out
      // rather than composed from a rotation and two translations because the
      // six numbers are what a reader has to check, and a composition hides
      // them behind three matrices.
      ..transform(0, -1, 1, 0, offset.dx, offset.dy + size.height);
    uiTextPainter.paintInBox(
      list,
      _text,
      face,
      Offset(alongText, acrossText),
      list.addPaint(colorArgb: _color.value, antiAlias: true),
    );
    list.restore();
  }
}
