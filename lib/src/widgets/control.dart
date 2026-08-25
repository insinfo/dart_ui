/// The shared behaviour of every framework-owned control.
///
/// Section 29.3 lists what a *button* alone must do: normal, hover, pressed,
/// focused, focus-visible, disabled, default, cancel, pointer capture,
/// keyboard activation, automation invoke. Every other control repeats most of
/// that list. Written once per control it would be eleven chances to get
/// keyboard activation subtly wrong; written here it is one implementation
/// that a control specializes by answering three questions - what does it look
/// like, what does activation mean, and what does it tell a screen reader.
///
/// The mixin form is deliberate: some controls are leaves ([RenderBox]) and
/// some wrap a child ([RenderSingleChildBox]), and a base class would force one
/// of those to inherit machinery it cannot use.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../graphics/display_list_opcodes.dart' show paintStyleStroke;
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../rendering/text/font_registry.dart';
import '../text/shaper.dart';
import '../text/typeface.dart';
import 'focus.dart';
import 'keyboard_router.dart';
import 'pointer_router.dart';
import 'semantics.dart';
import 'style.dart';
import 'theme.dart';

/// Behaviour shared by controls: states, activation, focus and painting.
mixin ControlBehavior on RenderBox
    implements
        PointerEventTarget,
        HoverEventTarget,
        KeyboardEventTarget,
        SemanticsProvider {
  ThemeData _theme = ThemeData.neutralLight;
  FocusNode? _focusNode;
  bool _enabled = true;
  bool _hovered = false;
  bool _pressed = false;
  int? _capturedPointer;

  /// Style classes contributed by the application, matched by
  /// [ClassSelector].
  Set<String> styleClasses = const <String>{};

  ThemeData get theme => _theme;

  set theme(ThemeData value) {
    if (value == _theme) return;
    final bool metricsChanged =
        value.effectiveControlHeight != _theme.effectiveControlHeight ||
            value.effectiveControlPadding != _theme.effectiveControlPadding ||
            // Type size decides how wide a label is, so a theme that changes
            // only the font size still reflows every control that has one.
            value.fontSize != _theme.fontSize;
    _theme = value;
    if (metricsChanged) markNeedsLayout();
    markNeedsPaint();
  }

  /// The focus node this control is driven by, if it participates in focus.
  FocusNode? get focusNode => _focusNode;

  set focusNode(FocusNode? value) {
    if (identical(value, _focusNode)) return;
    final FocusNode? previous = _focusNode;
    if (previous != null) {
      previous.removeListener(_onFocusChanged);
      // Only disown the target if it is still us; a node handed to a
      // replacement render object has already re-pointed.
      if (identical(previous.target, this)) previous.target = null;
    }
    _focusNode = value;
    if (value != null) {
      value.addListener(_onFocusChanged);
      // The node exists before this render object does - it belongs to the
      // control's State - so it learns where to send keys here.
      value.target = this;
      value.canRequestFocus = _enabled;
    }
    markNeedsPaint();
  }

  bool get enabled => _enabled;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    // A control that is disabled while pressed must not fire when the button
    // is released, and must not keep a hover it can no longer respond to.
    if (!value) {
      _pressed = false;
      _hovered = false;
      _capturedPointer = null;
    }
    _focusNode?.canRequestFocus = value;
    markNeedsPaint();
  }

  bool get isHovered => _hovered;

  bool get isPressed => _pressed;

  bool get hasFocus => _focusNode?.hasPrimaryFocus ?? false;

  bool get isFocusVisible => _focusNode?.isFocusVisible ?? false;

  /// The pseudo-classes true for this control right now.
  Set<PseudoClass> get pseudoClasses => <PseudoClass>{
        if (_hovered) PseudoClass.hover,
        if (_pressed) PseudoClass.pressed,
        if (hasFocus) PseudoClass.focused,
        if (isFocusVisible) PseudoClass.focusVisible,
        if (!_enabled) PseudoClass.disabled,
        ...controlStates,
        ..._theme.ambientStates,
      };

  /// Extra pseudo-classes a subclass contributes: `checked`, `selected`,
  /// `expanded`.
  Set<PseudoClass> get controlStates => const <PseudoClass>{};

  /// This control as a style-matching subject.
  StyleTarget styleTarget({StyleTarget? parent}) => StyleTarget(
        type: styleTypeName,
        classes: styleClasses,
        states: pseudoClasses,
        parent: parent,
      );

  /// The name a [TypeSelector] matches. Defaults to the render class name
  /// without the `Render` prefix, so `RenderButton` styles as `Button`.
  String get styleTypeName {
    final String name = runtimeType.toString();
    return name.startsWith('Render') ? name.substring(6) : name;
  }

  /// What pressing this control means. Called by pointer release inside the
  /// control, by Space/Enter, and by an accessibility invoke - one path, so
  /// the three cannot diverge.
  void activate() {}

  /// Whether this control takes focus when clicked. True for anything
  /// interactive; a label or a progress bar says false.
  bool get focusOnPointerDown => _enabled && _focusNode != null;

  // ---------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------

  @override
  void handlePointerEvent(PointerEvent event) {
    if (!_enabled) return;
    switch (event) {
      case PointerMoveEvent():
        // While this control holds the pointer, hover follows whether the
        // pointer is still over it: a pressed button that the pointer has left
        // must stop looking pressed without giving up the capture, so that
        // coming back re-arms it.
        _setHovered(
          _capturedPointer == null ||
              containsGlobalPoint(event.logicalPosition),
        );
        if (_capturedPointer == event.pointerId) {
          _setPressed(containsGlobalPoint(event.logicalPosition));
        }
      case PointerDownEvent(button: PointerButton.primary):
        // Implicit capture (section 27.4): the pointer that pressed owns this
        // control until it is released or cancelled, so a drag that leaves and
        // returns still activates and a *different* pointer cannot finish the
        // press this one started.
        _capturedPointer = event.pointerId;
        _pressed = true;
        if (focusOnPointerDown) {
          _focusNode?.requestFocus(FocusChangeReason.pointer);
        }
        markNeedsPaint();
      case PointerUpEvent(button: PointerButton.primary):
        if (_capturedPointer != event.pointerId) return;
        _capturedPointer = null;
        final bool wasPressed = _pressed;
        _pressed = false;
        markNeedsPaint();
        // The pointer was captured, so this release arrives here even when it
        // landed somewhere else entirely - which is exactly what must *not*
        // activate the control. Dragging off a button and letting go is how
        // every platform lets a user cancel a press they thought better of.
        if (wasPressed && containsGlobalPoint(event.logicalPosition)) {
          activate();
        }
      case PointerCancelEvent():
        if (_capturedPointer != event.pointerId) return;
        _capturedPointer = null;
        _pressed = false;
        markNeedsPaint();
      case PointerScrollEvent():
      case PointerDownEvent():
      case PointerUpEvent():
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (!_enabled || event is! KeyDownEvent) return false;
    if (event.logicalKey == logicalKeySpace ||
        event.logicalKey == logicalKeyEnter) {
      activate();
      return true;
    }
    return false;
  }

  /// Whether a point in the root's coordinate space is inside this control.
  ///
  /// Used instead of hit testing while the pointer is captured: hit testing
  /// answers "what is under this point", and a captured control needs to know
  /// "is this point over *me*", which is a different question the moment the
  /// pointer is over something else.
  bool containsGlobalPoint(Offset global) {
    if (!hasSize) return false;
    return size.contains(globalToLocal(global));
  }

  /// Called when the pointer leaves; a backend that reports leave events wires
  /// this, and a router that does not simply never clears hover.
  void clearHover() => _setHovered(false);

  @override
  void handleHoverChanged(bool hovered) => _setHovered(enabled && hovered);

  void _setHovered(bool value) {
    if (value == _hovered) return;
    _hovered = value;
    markNeedsPaint();
  }

  void _setPressed(bool value) {
    if (value == _pressed) return;
    _pressed = value;
    markNeedsPaint();
  }

  void _onFocusChanged(FocusNode node) => markNeedsPaint();

  // ---------------------------------------------------------------------
  // Painting helpers
  // ---------------------------------------------------------------------

  /// The control's background for its current state.
  ///
  /// The accent ramp, for a *filled* control - a primary button, a checked
  /// box, a slider's track. The neutral ramp is [neutralSurfaceColor].
  Color surfaceColor({Color? normal, Color? hovered, Color? pressed}) {
    if (!_enabled) return _theme.disabledSurface;
    if (_pressed) return pressed ?? _theme.accentPressed;
    if (_hovered) return hovered ?? _theme.accentHovered;
    return normal ?? _theme.accent;
  }

  /// The background of a control that is *not* filled with the accent: a
  /// toolbar button, a list row, a menu item, a tab.
  ///
  /// Returns null when the control is at rest and no [normal] was given, which
  /// means "paint nothing at all". That is the whole point of the neutral
  /// ramp: a toolbar of twenty buttons must be twenty pieces of unbroken
  /// surface until the pointer arrives, not twenty grey rectangles.
  Color? neutralSurfaceColor({
    Color? normal,
    Color? hovered,
    Color? pressed,
    bool selected = false,
  }) {
    if (!_enabled) return normal;
    if (_pressed) return pressed ?? _theme.pressedSurface;
    if (_hovered) return hovered ?? _theme.hoverSurface;
    if (selected) return _theme.accentSubtle;
    return normal;
  }

  /// The radius an ordinary control of this theme is drawn with.
  double get controlRadius => _theme.cornerRadius;

  /// The height of one row of a collection in this theme.
  double get rowHeight => _theme.effectiveRowHeight;

  /// The control's text colour for its current state.
  Color foregroundColor({Color? normal}) =>
      _enabled ? (normal ?? _theme.foreground) : _theme.disabledForeground;

  /// Fills [rect] with [color].
  void paintFill(DisplayList list, Rect rect, Color color) {
    final int paint = list.addPaint(colorArgb: color.value, antiAlias: false);
    list.drawRectangle(rect, paint);
  }

  /// Antialiased fill for modern controls whose theme requests rounded chrome.
  void paintRoundedFill(
    DisplayList list,
    Rect rect,
    Color color,
    double radius,
  ) {
    if (radius <= 0) {
      paintFill(list, rect, color);
      return;
    }
    list.drawRRectUniform(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      radius,
      radius,
      list.addPaint(colorArgb: color.value, antiAlias: true),
    );
  }

  void paintRoundedBorder(
    DisplayList list,
    Rect rect,
    Color color,
    double radius, {
    double width = 1,
  }) {
    if (radius <= 0) {
      paintBorder(list, rect, color, width: width);
      return;
    }
    final double inset = width / 2;
    list.drawRRectUniform(
      rect.left + inset,
      rect.top + inset,
      rect.right - inset,
      rect.bottom - inset,
      radius,
      radius,
      list.addPaint(
        colorArgb: color.value,
        style: paintStyleStroke,
        strokeWidth: width,
        antiAlias: true,
      ),
    );
  }

  /// Strokes a one-pixel border by painting four edges.
  ///
  /// Four fills rather than a stroked rect: the display list's stroke path is
  /// still the rasterizer's concern, and a border must land on exact pixels or
  /// a golden test becomes a comparison of antialiasing.
  void paintBorder(DisplayList list, Rect rect, Color color,
      {double width = 1}) {
    final int paint = list.addPaint(colorArgb: color.value, antiAlias: false);
    list
      ..drawRectangle(
          Rect.fromLTWH(rect.left, rect.top, rect.width, width), paint)
      ..drawRectangle(
          Rect.fromLTWH(rect.left, rect.bottom - width, rect.width, width),
          paint)
      ..drawRectangle(
          Rect.fromLTWH(rect.left, rect.top, width, rect.height), paint)
      ..drawRectangle(
          Rect.fromLTWH(rect.right - width, rect.top, width, rect.height),
          paint);
  }

  /// Paints the focus ring, and only when focus arrived by keyboard.
  ///
  /// This is the `:focus-visible` rule from section 28.3: a ring after every
  /// mouse click is noise, and no ring after Tab makes the keyboard unusable.
  ///
  /// Two rings, not one. The outer ring is the theme's [ThemeData.focusRing];
  /// the inner hairline is the control's own surface, so the ring never
  /// touches the control's edge and stays visible against a background that
  /// happens to be the same colour as the ring. It is the shape every desktop
  /// platform converged on for exactly that reason, and it is what makes a
  /// focused control read as focused on a dark blue toolbar as well as on
  /// white.
  ///
  /// The ring is drawn *outside* the control's box, so it never eats a pixel
  /// of the control it marks, and it follows [radius] - defaulting to the
  /// theme's - so a rounded button does not get a square halo.
  void paintFocusRing(DisplayList list, Rect rect, {double? radius}) {
    if (!isFocusVisible) return;
    final double width = _theme.focusRingWidth;
    final double r = radius ?? _theme.cornerRadius;
    // The separator first: one pixel of the control's own ground, so the ring
    // reads as a ring rather than as a thicker border.
    paintRoundedBorder(
      list,
      rect.inflate(0.5),
      _theme.brightness == ThemeBrightness.dark
          ? _theme.surfaceBase
          : _theme.surfaceAlternate,
      r <= 0 ? 0 : r + 0.5,
      width: 1,
    );
    paintRoundedBorder(
      list,
      rect.inflate(1 + width / 2),
      _theme.focusRing,
      r <= 0 ? 0 : r + 1 + width / 2,
      width: width,
    );
  }

  /// Strokes the polyline through [points] as filled quads.
  ///
  /// Filled and not stroked because a stroked *path* still goes through the
  /// rasterizer's path pipeline, while a quad is four points and a fill - and
  /// the marks this draws (a check mark, a chevron) are two segments each. One
  /// square is dropped at every interior joint so the corner is mitred rather
  /// than notched.
  void paintPolylineMark(
    DisplayList list,
    List<Offset> points,
    double thickness,
    Color color,
  ) =>
      paintPolyline(list, points, thickness, color);

  /// The tick inside a checked check box, sized to [box].
  void paintCheckMark(DisplayList list, Rect box, Color color) {
    final double e = box.width;
    paintPolylineMark(
      list,
      <Offset>[
        Offset(box.left + e * 0.22, box.top + e * 0.52),
        Offset(box.left + e * 0.42, box.top + e * 0.72),
        Offset(box.left + e * 0.78, box.top + e * 0.30),
      ],
      math.max(1.5, e * 0.13),
      color,
    );
  }

  // ---------------------------------------------------------------------
  // Text
  // ---------------------------------------------------------------------

  /// The face labels are drawn in, or null when no font could be found.
  ///
  /// Resolved per call rather than cached on the control: [FontRegistry] does
  /// the caching, and a control that held a face would keep drawing the old one
  /// after an application installed its own.
  ScaledTypeface? get labelFont =>
      FontRegistry.instance.uiFont(_theme.fontSize);

  /// The vertical extent one line of label occupies.
  ///
  /// Falls back to the theme's own estimate with no face, so that the vertical
  /// centring arithmetic below produces the same positions either way.
  double get labelLineHeight =>
      labelFont?.lineHeight ??
      FontRegistry.estimatedLineHeight(_theme.fontSize);

  /// The box [text] occupies as a label, shaped and therefore kerned.
  ///
  /// Measuring through the same painter that draws is the point: a measurement
  /// taken from nominal advances and a drawing that applies kerning disagree by
  /// a pixel or two per pair, which is how a label ends up overflowing the box
  /// reserved for it.
  Size measureLabel(String text) {
    final ScaledTypeface? font = labelFont;
    if (font == null) return FontRegistry.estimatedSize(text, _theme.fontSize);
    return uiTextPainter.measure(text, font);
  }

  /// Paints [text] with its top-left corner at [origin], in [color].
  ///
  /// Nothing is drawn when there is no face. That is the deliberate choice for
  /// the no-font case: [measureLabel] still reserves a box, so the layout is
  /// the one a font would have produced and every other property of the frame
  /// stays meaningful, and the single visible symptom is blank text. A
  /// substitute - notdef boxes, or the fixed-cell bitmap this replaced - would
  /// be indistinguishable from a face that merely lacks these characters, which
  /// is a different failure with a different fix.
  void paintLabel(
    DisplayList list,
    String text,
    Offset origin,
    Color color, {
    double maxWidth = double.infinity,
  }) {
    if (text.isEmpty) return;
    final ScaledTypeface? font = labelFont;
    if (font == null) return;
    // Antialiased: a glyph reaches the rasterizer as a coverage mask either
    // way, and recording the paint as hard-edged would mislead any backend
    // that does honour the flag.
    final int paint = list.addPaint(colorArgb: color.value, antiAlias: true);
    // Shaped once and then both measured and drawn from that one run: shaping
    // to decide whether to clip and shaping again to draw would double the
    // cost of every label on screen.
    final GlyphRun run = uiTextPainter.shapeRun(text, font);
    // Overlong text is clipped rather than truncated glyph by glyph. Dropping
    // glyphs silently changes the string - 'CANCEL' becomes 'CANC' with no sign
    // that anything is missing - while a clip leaves a cut letter, which reads
    // as text that does not fit.
    final bool clip = run.width > maxWidth;
    if (clip) {
      list
        ..save()
        ..clipRectangle(
          Rect.fromLTWH(origin.dx, origin.dy, maxWidth, font.lineHeight),
        );
    }
    uiTextPainter.emitRun(
      list,
      run,
      Offset(origin.dx, origin.dy + font.ascent),
      paint,
    );
    if (clip) list.restore();
  }

  /// Paints [text] centred inside [rect].
  ///
  /// Rounded to whole pixels. The glyph cache keys a mask on its subpixel
  /// bucket, so a label centred on a fractional offset rasterizes its own set
  /// of masks - and two controls of very slightly different width would stop
  /// sharing any of them.
  void paintCenteredLabel(
    DisplayList list,
    String text,
    Rect rect,
    Color color,
  ) {
    if (text.isEmpty) return;
    final Size box = measureLabel(text);
    final double x = (rect.left + (rect.width - box.width) / 2).roundToDouble();
    paintLabel(list, text, Offset(x, labelTopIn(rect)), color,
        maxWidth: rect.width);
  }

  /// The y a label's [paintLabel] origin takes to sit optically centred in
  /// [rect].
  ///
  /// Centred on the *typographic* box - ascent plus descent - and not on the
  /// line box. The difference is the face's line gap, which sits entirely
  /// above the ascent in most families: centring the line box therefore pushes
  /// every label one or two pixels low, and one or two pixels is precisely the
  /// error that makes an interface look amateur. Rounded, because a glyph mask
  /// is cached per subpixel bucket and a label at y = 7.5 rasterises its own
  /// copy of every glyph.
  double labelTopIn(Rect rect) {
    final ScaledTypeface? font = labelFont;
    if (font == null) {
      return (rect.top + (rect.height - labelLineHeight) / 2).roundToDouble();
    }
    final double typographic = font.ascent + font.descent;
    return (rect.top + (rect.height - typographic) / 2).roundToDouble();
  }

  /// The natural size of a control that shows [label] with theme padding.
  Size labelledSize(String label, {double extraWidth = 0}) => Size(
        measureLabel(label).width +
            _theme.effectiveControlPadding * 2 +
            extraWidth,
        _theme.effectiveControlHeight,
      );

  /// The x offset, from the start of the label, of the caret before character
  /// [index] of [text].
  ///
  /// A caret cannot be `index * advance` once the font is proportional, and it
  /// cannot be the width of a re-measured prefix either: kerning between the
  /// characters either side of the caret belongs to the pair, not to the
  /// prefix. Reading the position out of the shaped run is the only way the
  /// caret lands where the glyph actually starts.
  double labelOffsetOfIndex(String text, int index) {
    if (index <= 0) return 0;
    final ScaledTypeface? font = labelFont;
    if (font == null) {
      final int end = index.clamp(0, text.length);
      return FontRegistry.estimatedSize(text.substring(0, end), _theme.fontSize)
          .width;
    }
    final GlyphRun run = uiTextPainter.shapeRun(text, font);
    for (int i = 0; i < run.length; i++) {
      if (run.clusters[i] >= index) return run.xOf(i);
    }
    return run.width;
  }

  /// The character index whose caret sits nearest [dx] in [text].
  ///
  /// Nearest boundary rather than "which glyph contains it", because clicking
  /// the right half of a letter must put the caret after it - the behaviour
  /// every text field on every platform has.
  int labelIndexAtOffset(String text, double dx) {
    final ScaledTypeface? font = labelFont;
    if (font == null || text.isEmpty) return 0;
    final GlyphRun run = uiTextPainter.shapeRun(text, font);
    int best = text.length;
    double bestDistance = (run.width - dx).abs();
    for (int i = 0; i < run.length; i++) {
      final double distance = (run.xOf(i) - dx).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = run.clusters[i];
      }
    }
    return best;
  }

  @override
  void detach() {
    final FocusNode? node = _focusNode;
    if (node != null) {
      node.removeListener(_onFocusChanged);
      if (identical(node.target, this)) node.target = null;
    }
    super.detach();
  }
}

/// Strokes the polyline through [points] as filled quads.
///
/// Free rather than a method so the widget layer can draw the same mark: the
/// chevron in a combo box is painted by a render object and the one in a
/// calendar's month strip is a widget, and two implementations of one mark is
/// how two chevrons in one window end up different shapes.
///
/// Filled and not stroked because a stroked *path* still goes through the
/// rasterizer's path pipeline, while a quad is four points and a fill - and
/// the marks this draws are two segments each. One square is dropped at every
/// interior joint so the corner is mitred rather than notched.
void paintPolyline(
  DisplayList list,
  List<Offset> points,
  double thickness,
  Color color,
) {
  if (points.length < 2) return;
  final double half = thickness / 2;
  final int paint = list.addPaint(colorArgb: color.value, antiAlias: true);
  for (int i = 0; i < points.length - 1; i++) {
    final Offset a = points[i];
    final Offset b = points[i + 1];
    final double dx = b.dx - a.dx;
    final double dy = b.dy - a.dy;
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) continue;
    final double nx = -dy / length * half;
    final double ny = dx / length * half;
    final PathBuilder quad = PathBuilder()
      ..moveTo(a.dx + nx, a.dy + ny)
      ..lineTo(b.dx + nx, b.dy + ny)
      ..lineTo(b.dx - nx, b.dy - ny)
      ..lineTo(a.dx - nx, a.dy - ny)
      ..close();
    list.drawPath(list.addPath(quad.build()), paint);
  }
  for (int i = 1; i < points.length - 1; i++) {
    final Offset joint = points[i];
    list.drawRectangle(
      Rect.fromLTWH(joint.dx - half, joint.dy - half, thickness, thickness),
      paint,
    );
  }
}

/// Lightens or darkens [color] by [amount] per channel.
Color adjustColor(Color color, int amount) {
  final int value = color.value;
  int channel(int shift) => (((value >> shift) & 0xFF) + amount).clamp(0, 255);
  return Color((value & 0xFF000000) |
      (channel(16) << 16) |
      (channel(8) << 8) |
      channel(0));
}

/// Mixes [a] and [b], with [t] running 0 to 1.
Color blendColor(Color a, Color b, double t) {
  final double ratio = t.clamp(0.0, 1.0);
  int channel(int shift) {
    final int from = (a.value >> shift) & 0xFF;
    final int to = (b.value >> shift) & 0xFF;
    return (from + (to - from) * ratio).round().clamp(0, 255);
  }

  return Color((channel(24) << 24) |
      (channel(16) << 16) |
      (channel(8) << 8) |
      channel(0));
}
