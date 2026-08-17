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

import '../geometry/offset.dart';
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
  Color surfaceColor({Color? normal, Color? hovered, Color? pressed}) {
    if (!_enabled) return _theme.disabledSurface;
    if (_pressed) return pressed ?? _theme.accentPressed;
    if (_hovered) return hovered ?? _theme.accentHovered;
    return normal ?? _theme.accent;
  }

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
  void paintFocusRing(DisplayList list, Rect rect) {
    if (!isFocusVisible) return;
    paintBorder(
      list,
      Rect.fromLTWH(
        rect.left - 1,
        rect.top - 1,
        rect.width + 2,
        rect.height + 2,
      ),
      _theme.focusRing,
      width: _theme.focusRingWidth,
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
    final GlyphRun run = uiTextPainter.shaper.shape(text, font);
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
    final double y =
        (rect.top + (rect.height - box.height) / 2).roundToDouble();
    paintLabel(list, text, Offset(x, y), color, maxWidth: rect.width);
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
    final GlyphRun run = uiTextPainter.shaper.shape(text, font);
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
    final GlyphRun run = uiTextPainter.shaper.shape(text, font);
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
