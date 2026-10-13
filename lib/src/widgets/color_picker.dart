/// A general colour picker: a saturation/value plane, hue and alpha strips,
/// a preview swatch and a hexadecimal field.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_opcodes.dart' show paintStyleStroke;
import '../graphics/gradient.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart' show CrossAxisAlignment;
import '../platform/input_events.dart';
import '../semantics/semantics.dart';
import 'basic.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'icon.dart';
import 'icon_button.dart';
import 'phosphor_icons.dart';
import 'text_field.dart';
import 'theme.dart';
import 'widget.dart';
import 'window_scope.dart';

/// A colour as hue (0 to 360), saturation and value (0 to 1), and alpha
/// (0 to 1).
///
/// A picker has to keep its colour in this form rather than converting from
/// RGB every time: grey has no hue, so a picker that dragged the value of a
/// red to zero and read the hue back from black would jump the hue strip to
/// 0 the moment the colour went dark.
final class HsvColor {
  const HsvColor(this.alpha, this.hue, this.saturation, this.value);

  factory HsvColor.fromColor(Color color) {
    final double r = color.red / 255;
    final double g = color.green / 255;
    final double b = color.blue / 255;
    final double max = math.max(r, math.max(g, b));
    final double min = math.min(r, math.min(g, b));
    final double delta = max - min;
    double hue = 0;
    if (delta > 0) {
      if (max == r) {
        hue = 60 * (((g - b) / delta) % 6);
      } else if (max == g) {
        hue = 60 * ((b - r) / delta + 2);
      } else {
        hue = 60 * ((r - g) / delta + 4);
      }
    }
    if (hue < 0) hue += 360;
    return HsvColor(
      color.alpha / 255,
      hue,
      max == 0 ? 0 : delta / max,
      max,
    );
  }

  final double alpha;
  final double hue;
  final double saturation;
  final double value;

  Color toColor() {
    final double chroma = value * saturation;
    final double h = (hue % 360) / 60;
    final double x = chroma * (1 - ((h % 2) - 1).abs());
    final (double r, double g, double b) = switch (h.floor()) {
      0 => (chroma, x, 0.0),
      1 => (x, chroma, 0.0),
      2 => (0.0, chroma, x),
      3 => (0.0, x, chroma),
      4 => (x, 0.0, chroma),
      _ => (chroma, 0.0, x),
    };
    final double m = value - chroma;
    int channel(double c) => ((c + m) * 255).round().clamp(0, 255);
    return Color.fromARGB(
      (alpha * 255).round().clamp(0, 255),
      channel(r),
      channel(g),
      channel(b),
    );
  }

  HsvColor withAlpha(double alpha) =>
      HsvColor(alpha.clamp(0.0, 1.0), hue, saturation, value);
  HsvColor withHue(double hue) =>
      HsvColor(alpha, hue.clamp(0.0, 360.0), saturation, value);
  HsvColor withSaturation(double saturation) =>
      HsvColor(alpha, hue, saturation.clamp(0.0, 1.0), value);
  HsvColor withValue(double value) =>
      HsvColor(alpha, hue, saturation, value.clamp(0.0, 1.0));

  @override
  bool operator ==(Object other) =>
      other is HsvColor &&
      other.alpha == alpha &&
      other.hue == hue &&
      other.saturation == saturation &&
      other.value == value;

  @override
  int get hashCode => Object.hash(alpha, hue, saturation, value);

  @override
  String toString() => 'HsvColor(a: $alpha, h: $hue, s: $saturation, '
      'v: $value)';
}

/// `RRGGBB`, or `AARRGGBB` when the colour is not opaque.
String colorToHex(Color color) {
  String two(int channel) => channel.toRadixString(16).padLeft(2, '0');
  final String rgb = '${two(color.red)}${two(color.green)}${two(color.blue)}';
  return (color.alpha == 0xFF ? rgb : '${two(color.alpha)}$rgb').toUpperCase();
}

/// Reads `RGB`, `RRGGBB` or `AARRGGBB`, with or without a leading `#`, or
/// returns null for anything else.
Color? colorFromHex(String text) {
  String hex = text.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
  if (hex.length == 3) {
    hex = hex.split('').map((String digit) => '$digit$digit').join();
  }
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  return Color(int.parse(hex, radix: 16));
}

/// Picks a colour: drag in the plane for saturation and value, along the
/// strips for hue and alpha, or type the hexadecimal code.
///
/// Every part is a focusable control: the arrow keys move the plane's
/// cursor and the strips' thumbs in steps, so the whole picker works without
/// a mouse. [onChanged] receives every intermediate colour of a drag; the
/// picker is controlled, so [value] is what it shows.
final class ColorPicker extends StatefulWidget {
  const ColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.showAlpha = true,
    this.planeSize = 180,
  });

  final Color value;
  final void Function(Color value)? onChanged;

  /// Whether the alpha strip is shown and the hex field accepts `AARRGGBB`.
  final bool showAlpha;

  /// The side of the saturation/value square.
  final double planeSize;

  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

final class _ColorPickerState extends State<ColorPicker> {
  late HsvColor _hsv = HsvColor.fromColor(widget.value);
  late final TextEditingController _hex =
      TextEditingController(colorToHex(widget.value));
  final FocusNode _planeFocus = FocusNode(debugLabel: 'ColorPicker plane');
  final FocusNode _hueFocus = FocusNode(debugLabel: 'ColorPicker hue');
  final FocusNode _alphaFocus = FocusNode(debugLabel: 'ColorPicker alpha');

  @override
  void initState() {
    super.initState();
    _hex.addListener(_hexEdited);
  }

  @override
  void didUpdateWidget(ColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Resynchronise only when the colour really moved: the HSV kept here
    // holds the hue a grey cannot, and converting back from RGB would lose it.
    if (widget.value != _hsv.toColor()) _hsv = HsvColor.fromColor(widget.value);
    final String hex = colorToHex(widget.value);
    if (colorFromHex(_hex.value) != widget.value) _writeHex(hex);
  }

  @override
  void dispose() {
    _hex.removeListener(_hexEdited);
    _planeFocus.dispose();
    _hueFocus.dispose();
    _alphaFocus.dispose();
    super.dispose();
  }

  /// True while the picker itself rewrites the hex field, so the listener
  /// does not read its own write back as typing - which would re-derive the
  /// colour from RGB and throw away the hue of a grey.
  bool _writingHex = false;

  void _writeHex(String hex) {
    if (_hex.value == hex) return;
    _writingHex = true;
    try {
      _hex.value = hex;
    } finally {
      _writingHex = false;
    }
  }

  void _hexEdited(String text) {
    if (_writingHex) return;
    Color? parsed = colorFromHex(text);
    if (parsed == null) return;
    if (!widget.showAlpha) parsed = parsed.withAlpha(0xFF);
    if (parsed == widget.value) return;
    _hsv = HsvColor.fromColor(parsed);
    widget.onChanged?.call(parsed);
  }

  /// The platform's eyedropper; the colour it brings back becomes the value,
  /// opaque unless this picker shows alpha.
  Future<void> _sample(WindowController window) async {
    final Color? picked = await window.sampleScreenColor();
    if (picked == null || !mounted || widget.onChanged == null) return;
    _set(
        HsvColor.fromColor(widget.showAlpha ? picked : picked.withAlpha(0xFF)));
  }

  void _set(HsvColor next) {
    if (next == _hsv) return;
    setState(() => _hsv = next);
    final Color color = next.toColor();
    _writeHex(colorToHex(color));
    widget.onChanged?.call(color);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double gap = theme.effectiveGap;
    final double strip = theme.effectiveControlHeight * 0.6;
    final bool enabled = widget.onChanged != null;
    // The eyedropper, where the window has the platform's sampler.
    final WindowController? window = WindowScope.of(context);
    final bool canSample = enabled && (window?.canSampleScreenColor ?? false);
    return SizedBox(
      width: widget.planeSize + gap + strip,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: widget.planeSize,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: widget.planeSize,
                  child: FocusAttachment(
                    node: _planeFocus,
                    child: _PlaneWidget(
                      hsv: _hsv,
                      theme: theme,
                      focusNode: _planeFocus,
                      onChanged: enabled ? _set : null,
                    ),
                  ),
                ),
                SizedBox(width: gap),
                SizedBox(
                  width: strip,
                  child: FocusAttachment(
                    node: _hueFocus,
                    child: _StripWidget(
                      channel: _StripChannel.hue,
                      hsv: _hsv,
                      theme: theme,
                      focusNode: _hueFocus,
                      onChanged: enabled ? _set : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.showAlpha) ...<Widget>[
            SizedBox(height: gap),
            SizedBox(
              height: strip,
              child: FocusAttachment(
                node: _alphaFocus,
                child: _StripWidget(
                  channel: _StripChannel.alpha,
                  hsv: _hsv,
                  theme: theme,
                  focusNode: _alphaFocus,
                  onChanged: enabled ? _set : null,
                ),
              ),
            ),
          ],
          SizedBox(height: gap),
          Row(
            children: <Widget>[
              SizedBox(
                width: theme.effectiveControlHeight,
                height: theme.effectiveControlHeight,
                child: _SwatchWidget(color: _hsv.toColor(), theme: theme),
              ),
              SizedBox(width: gap),
              Expanded(
                child: TextField(
                  controller: _hex,
                  label: 'Hex',
                  enabled: enabled,
                ),
              ),
              if (canSample) ...<Widget>[
                SizedBox(width: gap),
                IconButton(
                  icon: const Icon(PhosphorIcons.eyedropper),
                  tooltip: 'Pick a colour from the screen',
                  onPressed: () => _sample(window!),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Saturation/value plane
// ---------------------------------------------------------------------------

final class _PlaneWidget extends RenderObjectWidget {
  const _PlaneWidget({
    required this.hsv,
    required this.theme,
    required this.focusNode,
    required this.onChanged,
  });

  final HsvColor hsv;
  final ThemeData theme;
  final FocusNode focusNode;
  final void Function(HsvColor value)? onChanged;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderColorPlane createRenderObject(BuildContext context) =>
      RenderColorPlane(hsv: hsv)
        ..onChanged = onChanged
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onChanged != null;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderColorPlane object,
  ) {
    object
      ..hsv = hsv
      ..onChanged = onChanged
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onChanged != null;
  }
}

/// Saturation left to right, value bottom to top, at the current hue.
final class RenderColorPlane extends RenderBox with ControlBehavior {
  RenderColorPlane({required HsvColor hsv}) : _hsv = hsv;

  HsvColor _hsv;
  void Function(HsvColor value)? onChanged;

  HsvColor get hsv => _hsv;

  set hsv(HsvColor value) {
    if (value == _hsv) return;
    _hsv = value;
    markNeedsPaint();
  }

  bool _dragging = false;

  /// One arrow press moves the cursor this far, in saturation or value.
  static const double keyStep = 0.02;

  @override
  void performLayout() => size = constraints.constrain(const Size(180, 180));

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        _dragging = true;
      case PointerUpEvent() || PointerCancelEvent():
        _dragging = false;
        return;
      case PointerMoveEvent():
        if (!_dragging) return;
      default:
        return;
    }
    final Offset local = globalToLocal(event.logicalPosition);
    final double width = math.max(size.width, 1);
    final double height = math.max(size.height, 1);
    _emit(
        _hsv.withSaturation(local.dx / width).withValue(1 - local.dy / height));
  }

  void _emit(HsvColor next) {
    if (next == _hsv) return;
    onChanged?.call(next);
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (!enabled || event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowLeft:
        _emit(_hsv.withSaturation(_hsv.saturation - keyStep));
      case logicalKeyArrowRight:
        _emit(_hsv.withSaturation(_hsv.saturation + keyStep));
      case logicalKeyArrowUp:
        _emit(_hsv.withValue(_hsv.value + keyStep));
      case logicalKeyArrowDown:
        _emit(_hsv.withValue(_hsv.value - keyStep));
      default:
        return false;
    }
    return true;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final int hue = HsvColor(1, _hsv.hue, 1, 1).toColor().value;
    list.drawRect(rect.left, rect.top, rect.right, rect.bottom,
        list.addPaint(colorArgb: hue));
    // White to clear across, then clear to black down: the two ramps that
    // turn one hue into every saturation and value of it.
    list.drawRect(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      list.addPaint(
        colorArgb: 0xFFFFFFFF,
        gradient: LinearGradient(
          startX: rect.left,
          startY: rect.top,
          endX: rect.right,
          endY: rect.top,
          stops: const <GradientStop>[
            GradientStop(0, 0xFFFFFFFF),
            GradientStop(1, 0x00FFFFFF),
          ],
        ),
      ),
    );
    list.drawRect(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      list.addPaint(
        colorArgb: 0xFF000000,
        gradient: LinearGradient(
          startX: rect.left,
          startY: rect.top,
          endX: rect.left,
          endY: rect.bottom,
          stops: const <GradientStop>[
            GradientStop(0, 0x00000000),
            GradientStop(1, 0xFF000000),
          ],
        ),
      ),
    );
    final Offset cursor = Offset(
      rect.left + _hsv.saturation * size.width,
      rect.top + (1 - _hsv.value) * size.height,
    );
    _paintCursor(list, cursor, hasFocus ? theme.focusRing : null);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.slider,
        label: 'Saturation and brightness',
        value: '${(_hsv.saturation * 100).round()}%, '
            '${(_hsv.value * 100).round()}%',
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{SemanticsAction.focus}
            : const <SemanticsAction>{},
      );
}

// ---------------------------------------------------------------------------
// Hue and alpha strips
// ---------------------------------------------------------------------------

enum _StripChannel { hue, alpha }

final class _StripWidget extends RenderObjectWidget {
  const _StripWidget({
    required this.channel,
    required this.hsv,
    required this.theme,
    required this.focusNode,
    required this.onChanged,
  });

  final _StripChannel channel;
  final HsvColor hsv;
  final ThemeData theme;
  final FocusNode focusNode;
  final void Function(HsvColor value)? onChanged;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderColorStrip createRenderObject(BuildContext context) =>
      RenderColorStrip(hue: channel == _StripChannel.hue, hsv: hsv)
        ..onChanged = onChanged
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onChanged != null;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderColorStrip object,
  ) {
    object
      ..hsv = hsv
      ..onChanged = onChanged
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onChanged != null;
  }
}

/// The hue strip (vertical, red at the top round to red at the bottom) or
/// the alpha strip (horizontal, clear to opaque over a checkerboard).
final class RenderColorStrip extends RenderBox with ControlBehavior {
  RenderColorStrip({required this.hue, required HsvColor hsv}) : _hsv = hsv;

  /// True for the hue strip, false for alpha.
  final bool hue;

  HsvColor _hsv;
  void Function(HsvColor value)? onChanged;

  HsvColor get hsv => _hsv;

  set hsv(HsvColor value) {
    if (value == _hsv) return;
    _hsv = value;
    markNeedsPaint();
  }

  bool _dragging = false;

  /// The strip's position, 0 to 1 along its length.
  double get fraction => hue ? _hsv.hue / 360 : _hsv.alpha;

  @override
  void performLayout() => size =
      constraints.constrain(hue ? const Size(20, 180) : const Size(180, 20));

  @override
  bool hitTestSelf(Offset position) => true;

  void _emitFraction(double value) {
    final double clamped = value.clamp(0.0, 1.0);
    final HsvColor next =
        hue ? _hsv.withHue(clamped * 360) : _hsv.withAlpha(clamped);
    if (next == _hsv) return;
    onChanged?.call(next);
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        _dragging = true;
      case PointerUpEvent() || PointerCancelEvent():
        _dragging = false;
        return;
      case PointerMoveEvent():
        if (!_dragging) return;
      default:
        return;
    }
    final Offset local = globalToLocal(event.logicalPosition);
    _emitFraction(hue
        ? local.dy / math.max(size.height, 1)
        : local.dx / math.max(size.width, 1));
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (!enabled || event is! KeyDownEvent) return false;
    // A hue degree or an alpha percent per press.
    final double step = hue ? 1 / 360 : 0.01;
    switch (event.logicalKey) {
      case logicalKeyArrowLeft || logicalKeyArrowUp:
        _emitFraction(fraction - step);
      case logicalKeyArrowRight || logicalKeyArrowDown:
        _emitFraction(fraction + step);
      case logicalKeyHome:
        _emitFraction(0);
      case logicalKeyEnd:
        _emitFraction(1);
      default:
        return false;
    }
    return true;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    if (hue) {
      final List<GradientStop> stops = <GradientStop>[
        for (int i = 0; i <= 6; i++)
          GradientStop(i / 6, HsvColor(1, i * 60.0, 1, 1).toColor().value),
      ];
      list.drawRect(
        rect.left,
        rect.top,
        rect.right,
        rect.bottom,
        list.addPaint(
          colorArgb: 0xFFFFFFFF,
          gradient: LinearGradient(
            startX: rect.left,
            startY: rect.top,
            endX: rect.left,
            endY: rect.bottom,
            stops: stops,
          ),
        ),
      );
      final double y = rect.top + fraction * size.height;
      _paintThumb(list, Rect.fromLTRB(rect.left, y - 2, rect.right, y + 2));
      return;
    }
    _paintCheckerboard(list, rect, theme);
    final int opaque = _hsv.withAlpha(1).toColor().value;
    list.drawRect(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      list.addPaint(
        colorArgb: 0xFFFFFFFF,
        gradient: LinearGradient(
          startX: rect.left,
          startY: rect.top,
          endX: rect.right,
          endY: rect.top,
          stops: <GradientStop>[
            GradientStop(0, opaque & 0x00FFFFFF),
            GradientStop(1, opaque),
          ],
        ),
      ),
    );
    final double x = rect.left + fraction * size.width;
    _paintThumb(list, Rect.fromLTRB(x - 2, rect.top, x + 2, rect.bottom));
  }

  void _paintThumb(DisplayList list, Rect thumb) {
    final Rect outer = Rect.fromLTRB(
        thumb.left - 1, thumb.top - 1, thumb.right + 1, thumb.bottom + 1);
    list.drawRect(outer.left, outer.top, outer.right, outer.bottom,
        list.addPaint(colorArgb: 0xFF000000));
    list.drawRect(
        thumb.left,
        thumb.top,
        thumb.right,
        thumb.bottom,
        list.addPaint(
            colorArgb: hasFocus ? theme.focusRing.value : 0xFFFFFFFF));
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.slider,
        label: hue ? 'Hue' : 'Opacity',
        value: hue ? '${_hsv.hue.round()}°' : '${(_hsv.alpha * 100).round()}%',
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{SemanticsAction.focus}
            : const <SemanticsAction>{},
      );
}

// ---------------------------------------------------------------------------
// Preview swatch
// ---------------------------------------------------------------------------

final class _SwatchWidget extends RenderObjectWidget {
  const _SwatchWidget({required this.color, required this.theme});

  final Color color;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  _RenderSwatch createRenderObject(BuildContext context) =>
      _RenderSwatch(color, theme);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSwatch object,
  ) {
    object
      ..color = color
      ..theme = theme;
  }
}

final class _RenderSwatch extends RenderBox {
  _RenderSwatch(this._color, this._theme);

  Color _color;
  ThemeData _theme;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  set theme(ThemeData value) {
    if (identical(value, _theme)) return;
    _theme = value;
    markNeedsPaint();
  }

  @override
  void performLayout() => size = constraints.constrain(const Size(32, 32));

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    list.drawRect(rect.left, rect.top, rect.right, rect.bottom,
        list.addPaint(colorArgb: _theme.border.value));
    final Rect inner = Rect.fromLTRB(
        rect.left + 1, rect.top + 1, rect.right - 1, rect.bottom - 1);
    _paintCheckerboard(list, inner, _theme);
    list.drawRect(inner.left, inner.top, inner.right, inner.bottom,
        list.addPaint(colorArgb: _color.value));
  }
}

// ---------------------------------------------------------------------------
// Shared painting
// ---------------------------------------------------------------------------

/// The grey-and-white squares that make transparency visible.
void _paintCheckerboard(DisplayList list, Rect rect, ThemeData theme) {
  const double cell = 6;
  final int light = list.addPaint(colorArgb: 0xFFFFFFFF);
  final int dark = list.addPaint(colorArgb: 0xFFCCCCCC);
  list.drawRect(rect.left, rect.top, rect.right, rect.bottom, light);
  int row = 0;
  for (double y = rect.top; y < rect.bottom; y += cell, row++) {
    int column = 0;
    for (double x = rect.left; x < rect.right; x += cell, column++) {
      if ((row + column).isOdd) {
        list.drawRect(x, y, math.min(x + cell, rect.right),
            math.min(y + cell, rect.bottom), dark);
      }
    }
  }
}

/// A ring the cursor sits in: black outside white, legible on any colour.
void _paintCursor(DisplayList list, Offset at, Color? focusRing) {
  const double radius = 6;
  final int outer = list.addPaint(
    colorArgb: focusRing?.value ?? 0xFF000000,
    style: paintStyleStroke,
    strokeWidth: 3,
  );
  final int inner = list.addPaint(
    colorArgb: 0xFFFFFFFF,
    style: paintStyleStroke,
    strokeWidth: 1.5,
  );
  for (final int paint in <int>[outer, inner]) {
    list.drawRRectUniform(at.dx - radius, at.dy - radius, at.dx + radius,
        at.dy + radius, radius, radius, paint);
  }
}
