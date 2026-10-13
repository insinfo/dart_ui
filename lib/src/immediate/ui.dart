/// Immediate-mode UI: the interface is code that runs every frame.
///
/// ```dart
/// ui.heading('Exposição');
/// state.brightness = ui.slider('Brilho', state.brightness, min: -1, max: 1);
/// if (ui.button('Aplicar')) document.apply();
/// ui.horizontal((ui) {
///   state.mask = ui.checkbox('Máscara', state.mask);
///   state.histogram = ui.checkbox('Histograma', state.histogram);
/// });
/// ```
///
/// No widget tree and no `setState`: the application's own variables are the
/// state, and a control's return value says what the user did to it this
/// frame. What has to survive between frames - which control the pointer is
/// pressing, which text field has the keyboard, how far a scroll area is
/// scrolled, whether a section is open - lives in [ImmediateMemory], keyed by
/// an id derived from the control's label and its place in the code.
///
/// The model is egui's and Dear ImGui's. It runs inside the retained
/// framework, in one render object (`ImmediateArea`), so it shares the
/// backends, the event loop, text, fonts and [ThemeData] with the widgets -
/// and controls draw with the same shapes for the same [ControlStyle]. A frame
/// is drawn when input arrives or a control asks for one; nothing redraws at
/// 60 Hz while the interface sits still.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../rendering/text/font_registry.dart';
import '../text/shaper.dart';
import '../text/typeface.dart';
import '../widgets/control.dart';
import '../widgets/theme.dart';

/// The input one frame sees, in the coordinates the frame draws in.
final class ImmediateInput {
  /// Where the pointer is, or null when it is not over the area.
  Offset? pointer;

  /// Whether the primary button is held.
  bool down = false;

  /// The primary button went down during this frame.
  bool pressed = false;

  /// The primary button went up during this frame.
  bool released = false;

  /// Wheel movement this frame, in logical pixels, positive down/right.
  Offset scroll = Offset.zero;

  /// Text typed this frame.
  final StringBuffer text = StringBuffer();

  /// Logical keys pressed this frame (`logicalKey*` constants).
  final List<int> keys = <int>[];

  bool get isEmpty =>
      !pressed &&
      !released &&
      scroll == Offset.zero &&
      text.isEmpty &&
      keys.isEmpty;

  void endFrame() {
    pressed = false;
    released = false;
    scroll = Offset.zero;
    text.clear();
    keys.clear();
  }
}

/// What survives from one frame to the next.
final class ImmediateMemory {
  final Map<int, Object?> _values = <int, Object?>{};

  /// The control under the pointer last frame.
  int? hot;

  /// The control the primary button is pressing.
  int? active;

  /// The control with the keyboard (a text field).
  int? focused;

  /// Where [active] was pressed, for drags.
  Offset? pressOrigin;

  /// The size the content took last frame, for an area with no fixed size.
  Size contentSize = Size.zero;

  T value<T>(int id, T Function() create) =>
      (_values.containsKey(id) ? _values[id] : (_values[id] = create())) as T;

  void set<T>(int id, T value) => _values[id] = value;
}

/// What a control reports about this frame.
final class Response {
  const Response({
    required this.rect,
    required this.hovered,
    required this.pressed,
    required this.clicked,
    required this.dragDelta,
  });

  final Rect rect;
  final bool hovered;

  /// The primary button is held on it.
  final bool pressed;

  /// Released over it after being pressed on it.
  final bool clicked;

  /// Pointer movement while pressed, this frame.
  final Offset dragDelta;
}

/// The painter and font services a frame draws with: the host render object,
/// whose [ControlBehavior] already knows the theme's shapes.
abstract interface class ImmediatePainter {
  ThemeData get theme;
  void paintRoundedFill(
      DisplayList list, Rect rect, Color color, double radius);
  void paintRoundedBorder(
      DisplayList list, Rect rect, Color color, double radius,
      {double width});
  void paintCheckMark(DisplayList list, Rect box, Color color);

  /// Asks for the keyboard when a text field takes focus.
  void requestKeyboardFocus();
}

/// Shared by every [Ui] of one frame.
final class _Frame {
  _Frame(this.list, this.painter, this.input, this.memory, this.lastPointer);

  final DisplayList list;
  final ImmediatePainter painter;
  final ImmediateInput input;
  final ImmediateMemory memory;
  final Offset? lastPointer;
  bool claimedPress = false;
  int? hotThisFrame;
  bool wantsRepaint = false;
}

/// One layout region of an immediate-mode frame.
final class Ui {
  Ui._(this._frame, this._region, this._vertical, this._seed, this._clip,
      [this._theme])
      : _cursor = _region.topLeft;

  /// The root of a frame: [region] in the area's paint coordinates.
  static Ui frame({
    required DisplayList list,
    required ImmediatePainter painter,
    required ImmediateInput input,
    required ImmediateMemory memory,
    required Rect region,
    Offset? lastPointer,
  }) =>
      Ui._(_Frame(list, painter, input, memory, lastPointer), region, true, 17,
          region);

  final _Frame _frame;
  final Rect _region;
  final bool _vertical;
  final int _seed;
  final Rect _clip;
  final ThemeData? _theme;
  Offset _cursor;
  double _crossExtent = 0;
  double _mainExtent = 0;
  int _counter = 0;

  ThemeData get theme => _theme ?? _frame.painter.theme;
  DisplayList get canvas => _frame.list;
  ImmediateInput get input => _frame.input;

  /// Space between controls: the theme's gap.
  double get spacing => theme.effectiveGap;

  /// What this region still has to give, from the cursor on.
  Rect get availableRect => _vertical
      ? Rect.fromLTRB(_region.left, _cursor.dy, _region.right, _region.bottom)
      : Rect.fromLTRB(_cursor.dx, _region.top, _region.right, _region.bottom);

  /// The size the content took so far.
  Size get usedSize => _vertical
      ? Size(_crossExtent, _mainExtent)
      : Size(_mainExtent, _crossExtent);

  /// Draw another frame after this one - an animation, a value that changed
  /// in a way the next frame must show.
  void requestRepaint() => _frame.wantsRepaint = true;

  // -------------------------------------------------------------------------
  // Ids and memory
  // -------------------------------------------------------------------------

  /// The id of the control keyed [key] in this region. Two controls with the
  /// same label in one region need an explicit key to stay apart.
  int idFor(Object key) => Object.hash(_seed, key);

  int _autoId(Object? key, String label) =>
      idFor(key ?? (label.isEmpty ? '#${_counter++}' : label));

  T remember<T>(Object key, T Function() create) =>
      _frame.memory.value<T>(idFor(key), create);

  void store<T>(Object key, T value) => _frame.memory.set<T>(idFor(key), value);

  // -------------------------------------------------------------------------
  // Layout
  // -------------------------------------------------------------------------

  /// Takes [size] from the region at the cursor and returns where it went.
  Rect allocate(Size size) {
    final Rect rect;
    if (_vertical) {
      if (_mainExtent > 0) _cursor = _cursor + Offset(0, spacing);
      rect = Rect.fromLTWH(_region.left, _cursor.dy, size.width, size.height);
      _cursor = Offset(_cursor.dx, rect.bottom);
      _mainExtent = rect.bottom - _region.top;
      _crossExtent = math.max(_crossExtent, size.width);
    } else {
      if (_mainExtent > 0) _cursor = _cursor + Offset(spacing, 0);
      rect = Rect.fromLTWH(_cursor.dx, _region.top, size.width, size.height);
      _cursor = Offset(rect.right, _cursor.dy);
      _mainExtent = rect.right - _region.left;
      _crossExtent = math.max(_crossExtent, size.height);
    }
    return rect;
  }

  /// Empty space along the layout direction.
  void space(double extent) {
    allocate(_vertical ? Size(0, extent) : Size(extent, 0));
  }

  /// Lays [contents] out left to right.
  void horizontal(void Function(Ui ui) contents) =>
      _child(contents, vertical: false);

  /// Lays [contents] out top to bottom - the default, as a nested group.
  void vertical(void Function(Ui ui) contents) =>
      _child(contents, vertical: true);

  /// [contents] drawn with [theme] instead of the area's: a preview, or an
  /// application that switches theme at run time. With [background] the
  /// region is filled with the theme's window colour first.
  void themed(ThemeData theme, void Function(Ui ui) contents,
      {bool background = true}) {
    final Rect available = _withGap(availableRect);
    // A themed region with its own background is a page: it gets a margin.
    final double margin = background ? theme.effectiveControlPadding : 0;
    if (background) {
      canvas.drawRectangle(
          available, canvas.addPaint(colorArgb: theme.surfaceBase.value));
    }
    final Ui child = Ui._(
        _frame,
        Rect.fromLTRB(available.left + margin, available.top + margin,
            available.right - margin, available.bottom - margin),
        true,
        Object.hash(_seed, 'themed', _counter++),
        _clip,
        theme);
    contents(child);
    final Size used = child.usedSize;
    allocate(Size(used.width + margin * 2, used.height + margin * 2));
  }

  /// [contents] shifted right by one indent.
  void indent(void Function(Ui ui) contents) {
    final double step = theme.effectiveControlPadding;
    final Rect available = availableRect;
    final Ui child = Ui._(
        _frame,
        Rect.fromLTRB(available.left + step, available.top, available.right,
            available.bottom),
        true,
        Object.hash(_seed, 'indent', _counter++),
        _clip,
        _theme);
    contents(child);
    final Size used = child.usedSize;
    allocate(Size(used.width + step, used.height));
  }

  Ui _child(void Function(Ui ui) contents, {required bool vertical}) {
    final Rect available = availableRect;
    final Ui child = Ui._(_frame, _withGap(available), vertical,
        Object.hash(_seed, _counter++), _clip, _theme);
    contents(child);
    allocate(child.usedSize);
    return child;
  }

  Rect _withGap(Rect available) {
    if (_mainExtent == 0) return available;
    return _vertical
        ? Rect.fromLTRB(available.left, available.top + spacing,
            available.right, available.bottom)
        : Rect.fromLTRB(available.left + spacing, available.top,
            available.right, available.bottom);
  }

  // -------------------------------------------------------------------------
  // Interaction
  // -------------------------------------------------------------------------

  /// Hover, press, click and drag for [rect], tracked under [id].
  Response interact(Rect rect, int id) {
    final ImmediateInput input = _frame.input;
    final ImmediateMemory memory = _frame.memory;
    final Offset? pointer = input.pointer;
    final bool inside =
        pointer != null && rect.contains(pointer) && _clip.contains(pointer);
    final bool hovered =
        inside && (memory.active == null || memory.active == id);
    if (hovered) _frame.hotThisFrame = id;
    if (inside && input.pressed && !_frame.claimedPress) {
      _frame.claimedPress = true;
      memory
        ..active = id
        ..pressOrigin = pointer;
    }
    final bool isActive = memory.active == id;
    final bool clicked = isActive && input.released && inside;
    final Offset? last = _frame.lastPointer;
    final Offset drag = isActive && pointer != null && last != null
        ? pointer - last
        : Offset.zero;
    if (isActive && (input.released || clicked)) _frame.wantsRepaint = true;
    return Response(
      rect: rect,
      hovered: hovered,
      pressed: isActive && input.down,
      clicked: clicked,
      dragDelta: drag,
    );
  }

  // -------------------------------------------------------------------------
  // Text
  // -------------------------------------------------------------------------

  ScaledTypeface? _font(double size) => FontRegistry.instance.uiFont(size);

  Size _measure(String text, double size) {
    final ScaledTypeface? font = _font(size);
    if (font == null) return FontRegistry.estimatedSize(text, size);
    return uiTextPainter.measure(text, font);
  }

  void _paintText(String text, Offset origin, double size, Color color,
      {double maxWidth = double.infinity}) {
    if (text.isEmpty) return;
    final ScaledTypeface? font = _font(size);
    if (font == null) return;
    final DisplayList list = _frame.list;
    final int paint = list.addPaint(colorArgb: color.value, antiAlias: true);
    final GlyphRun run = uiTextPainter.shapeRun(text, font);
    final bool clip = run.width > maxWidth;
    if (clip) {
      list
        ..save()
        ..clipRect(origin.dx, origin.dy, origin.dx + maxWidth,
            origin.dy + font.lineHeight);
    }
    uiTextPainter.emitRun(
        list,
        run,
        Offset(origin.dx.roundToDouble(),
            (origin.dy + font.ascent).roundToDouble()),
        paint);
    if (clip) list.restore();
  }

  /// The top a line of [size] text takes to sit centred in [rect].
  double _textTop(Rect rect, double size) {
    final ScaledTypeface? font = _font(size);
    final double height = font == null
        ? FontRegistry.estimatedLineHeight(size)
        : font.ascent + font.descent;
    return (rect.top + (rect.height - height) / 2).roundToDouble();
  }

  // -------------------------------------------------------------------------
  // Controls
  // -------------------------------------------------------------------------

  /// A line of text.
  void label(String text, {Color? color, bool secondary = false}) {
    final double size = theme.fontSize;
    final Size measured = _measure(text, size);
    final Rect rect =
        allocate(Size(measured.width, math.max(measured.height, size * 1.4)));
    _paintText(text, Offset(rect.left, _textTop(rect, size)), size,
        color ?? (secondary ? theme.foregroundSecondary : theme.foreground));
  }

  /// A title for what follows.
  void heading(String text) {
    final double size = (theme.fontSize * 1.45).roundToDouble();
    final Size measured = _measure(text, size);
    final Rect rect = allocate(Size(measured.width, size * 1.5));
    _paintText(
        text, Offset(rect.left, _textTop(rect, size)), size, theme.foreground);
  }

  /// A thin line across the region.
  void separator() {
    final Rect rect = allocate(_vertical
        ? Size(_region.width, 1)
        : Size(1, theme.effectiveControlHeight));
    canvas.drawRectangle(
        rect, canvas.addPaint(colorArgb: theme.borderSubtle.value));
  }

  /// A push button. True on the frame it was clicked.
  bool button(String text, {bool enabled = true, Object? key}) {
    final int id = _autoId(key, text);
    final double height = theme.effectiveControlHeight;
    final Size measured = _measure(text, theme.fontSize);
    final Rect rect = allocate(Size(
        (measured.width + theme.effectiveControlPadding * 2).roundToDouble(),
        height));
    final Response response = enabled ? interact(rect, id) : _inert(rect);
    final double radius = theme.controlStyle == ControlStyle.material
        ? height / 2
        : theme.cornerRadius;
    final Color fill = !enabled
        ? theme.disabledSurface
        : response.pressed
            ? theme.accentPressed
            : response.hovered
                ? theme.accentHovered
                : theme.accent;
    _frame.painter.paintRoundedFill(canvas, rect, fill, radius);
    final Size box = measured;
    _paintText(
        text,
        Offset((rect.left + (rect.width - box.width) / 2).roundToDouble(),
            _textTop(rect, theme.fontSize)),
        theme.fontSize,
        enabled ? theme.colorScheme.onPrimary : theme.disabledForeground);
    return enabled && response.clicked;
  }

  /// A check box; returns the value after this frame's click.
  bool checkbox(String text, bool value, {bool enabled = true, Object? key}) {
    final int id = _autoId(key, text);
    final double box = ((theme.fontSize + 3) / 2).roundToDouble() * 2;
    final Size measured = _measure(text, theme.fontSize);
    final Rect rect = allocate(Size(box + spacing + measured.width,
        math.max(box, theme.effectiveControlHeight)));
    final Response response = enabled ? interact(rect, id) : _inert(rect);
    final bool next = response.clicked ? !value : value;
    final Rect boxRect = Rect.fromLTWH(rect.left,
        (rect.top + (rect.height - box) / 2).roundToDouble(), box, box);
    final double radius = switch (theme.controlStyle) {
      ControlStyle.material => 2,
      ControlStyle.cupertino => box / 2,
      ControlStyle.standard => theme.cornerRadiusSmall,
    };
    if (next) {
      _frame.painter.paintRoundedFill(canvas, boxRect,
          enabled ? theme.accent : theme.disabledForeground, radius);
      _frame.painter
          .paintCheckMark(canvas, boxRect, theme.colorScheme.onPrimary);
    } else {
      _frame.painter.paintRoundedFill(
          canvas,
          boxRect,
          response.hovered ? theme.hoverSurface : theme.surfaceAlternate,
          radius);
      _frame.painter.paintRoundedBorder(canvas, boxRect,
          enabled ? theme.borderStrong : theme.disabledForeground, radius,
          width: theme.controlStyle == ControlStyle.material ? 2 : 1);
    }
    _paintText(
        text,
        Offset(boxRect.right + spacing, _textTop(rect, theme.fontSize)),
        theme.fontSize,
        enabled ? theme.foreground : theme.disabledForeground);
    return next;
  }

  /// One option of a group: returns [value] when clicked, else [group].
  T radio<T>(String text, T value, T group, {Object? key}) {
    final int id = _autoId(key ?? 'radio:$text:$value', text);
    final double box = ((theme.fontSize + 3) / 2).roundToDouble() * 2;
    final Size measured = _measure(text, theme.fontSize);
    final Rect rect = allocate(Size(box + spacing + measured.width,
        math.max(box, theme.effectiveControlHeight)));
    final Response response = interact(rect, id);
    final T next = response.clicked ? value : group;
    final bool selected = next == value;
    final Rect boxRect = Rect.fromLTWH(rect.left,
        (rect.top + (rect.height - box) / 2).roundToDouble(), box, box);
    _frame.painter.paintRoundedFill(
        canvas,
        boxRect,
        response.hovered ? theme.hoverSurface : theme.surfaceAlternate,
        box / 2);
    _frame.painter.paintRoundedBorder(
        canvas, boxRect, selected ? theme.accent : theme.borderStrong, box / 2,
        width: selected ? 1.5 : 1);
    if (selected) {
      final double dot = (box * 0.42 / 2).roundToDouble() * 2;
      _frame.painter.paintRoundedFill(
          canvas,
          Rect.fromLTWH(boxRect.left + (box - dot) / 2,
              boxRect.top + (box - dot) / 2, dot, dot),
          theme.accent,
          dot / 2);
    }
    _paintText(
        text,
        Offset(boxRect.right + spacing, _textTop(rect, theme.fontSize)),
        theme.fontSize,
        theme.foreground);
    return next;
  }

  /// An on/off switch, drawn in the theme's [ControlStyle].
  bool toggle(String text, bool value, {Object? key}) {
    final int id = _autoId(key, text);
    final Size track = switch (theme.controlStyle) {
      ControlStyle.cupertino => const Size(51, 31),
      ControlStyle.material => const Size(52, 32),
      ControlStyle.standard => Size(
          (((theme.fontSize + 3) * 1.8) / 2).roundToDouble() * 2,
          ((theme.fontSize + 3) / 2).roundToDouble() * 2),
    };
    final Size measured = _measure(text, theme.fontSize);
    final Rect rect = allocate(Size(track.width + spacing + measured.width,
        math.max(track.height, theme.effectiveControlHeight)));
    final Response response = interact(rect, id);
    final bool next = response.clicked ? !value : value;
    final Rect trackRect = Rect.fromLTWH(
        rect.left,
        (rect.top + (rect.height - track.height) / 2).roundToDouble(),
        track.width,
        track.height);
    final double radius = track.height / 2;
    final bool cupertino = theme.controlStyle == ControlStyle.cupertino;
    _frame.painter.paintRoundedFill(
        canvas,
        trackRect,
        next
            ? theme.toggleActiveColor
            : cupertino
                ? (theme.brightness == Brightness.dark
                    ? const Color(0xFF39393D)
                    : const Color(0xFFE9E9EA))
                : theme.disabledSurface,
        radius);
    if (!next && !cupertino) {
      _frame.painter.paintRoundedBorder(
          canvas, trackRect, theme.borderStrong, radius,
          width: theme.controlStyle == ControlStyle.material ? 2 : 1);
    }
    final double knob = cupertino
        ? track.height - 4
        : theme.controlStyle == ControlStyle.material
            ? (next ? 24 : 16)
            : track.height - 6;
    final double inset = (track.height - knob) / 2;
    final Rect knobRect = Rect.fromLTWH(
        (next ? trackRect.right - knob - inset : trackRect.left + inset)
            .roundToDouble(),
        (trackRect.top + inset).roundToDouble(),
        knob,
        knob);
    if (cupertino) {
      _frame.painter.paintRoundedFill(
          canvas,
          knobRect.translate(0, 1).inflate(0.5),
          const Color(0x26000000),
          knob / 2);
    }
    _frame.painter.paintRoundedFill(
        canvas,
        knobRect,
        cupertino
            ? const Color(0xFFFFFFFF)
            : next
                ? theme.colorScheme.onPrimary
                : theme.borderStrong,
        knob / 2);
    _paintText(
        text,
        Offset(trackRect.right + spacing, _textTop(rect, theme.fontSize)),
        theme.fontSize,
        theme.foreground);
    return next;
  }

  /// A horizontal slider; returns the value after this frame's drag.
  double slider(String text, double value,
      {double min = 0, double max = 1, double width = 200, Object? key}) {
    final int id = _autoId(key, text);
    final double thumb = switch (theme.controlStyle) {
      ControlStyle.cupertino => 28,
      ControlStyle.material => 20,
      ControlStyle.standard => 16,
    };
    final Size measured = _measure(text, theme.fontSize);
    final double labelWidth = text.isEmpty ? 0 : measured.width + spacing;
    final Rect rect = allocate(Size(
        labelWidth + width, math.max(thumb, theme.effectiveControlHeight)));
    if (text.isNotEmpty) {
      _paintText(text, Offset(rect.left, _textTop(rect, theme.fontSize)),
          theme.fontSize, theme.foreground);
    }
    final Rect bar =
        Rect.fromLTWH(rect.left + labelWidth, rect.top, width, rect.height);
    final Response response = interact(bar, id);
    var next = value;
    final Offset? pointer = _frame.input.pointer;
    if (response.pressed && pointer != null && max > min) {
      final double t =
          ((pointer.dx - bar.left - thumb / 2) / (bar.width - thumb))
              .clamp(0.0, 1.0);
      next = min + (max - min) * t;
    }
    final double t =
        max > min ? ((next - min) / (max - min)).clamp(0.0, 1.0) : 0;
    final Rect track = Rect.fromLTWH(
        bar.left, (bar.center.dy - 2).roundToDouble(), bar.width, 4);
    _frame.painter.paintRoundedFill(
        canvas,
        track,
        theme.controlStyle == ControlStyle.material
            ? theme.accentSubtle
            : theme.disabledSurface,
        2);
    final double thumbLeft =
        (bar.left + (bar.width - thumb) * t).roundToDouble();
    _frame.painter.paintRoundedFill(
        canvas,
        Rect.fromLTWH(bar.left, track.top, thumbLeft - bar.left + thumb / 2, 4),
        theme.accent,
        2);
    final Rect thumbRect = Rect.fromLTWH(
        thumbLeft, (bar.center.dy - thumb / 2).roundToDouble(), thumb, thumb);
    switch (theme.controlStyle) {
      case ControlStyle.cupertino:
        _frame.painter.paintRoundedFill(
            canvas,
            thumbRect.translate(0, 1).inflate(0.5),
            const Color(0x26000000),
            thumb / 2);
        _frame.painter.paintRoundedFill(
            canvas, thumbRect, const Color(0xFFFFFFFF), thumb / 2);
      case ControlStyle.material:
        _frame.painter.paintRoundedFill(canvas, thumbRect,
            response.pressed ? theme.accentPressed : theme.accent, thumb / 2);
      case ControlStyle.standard:
        _frame.painter.paintRoundedFill(
            canvas, thumbRect, theme.surfaceAlternate, thumb / 2);
        _frame.painter.paintRoundedBorder(canvas, thumbRect,
            response.pressed ? theme.accentPressed : theme.accent, thumb / 2,
            width: 2);
    }
    if (next != value) _frame.wantsRepaint = true;
    return next;
  }

  /// A progress bar, [value] from 0 to 1.
  void progress(double value, {double width = 200}) {
    final Rect rect = allocate(Size(width, 6));
    _frame.painter.paintRoundedFill(canvas, rect, theme.disabledSurface, 3);
    final double filled = (width * value.clamp(0.0, 1.0)).roundToDouble();
    if (filled > 0) {
      _frame.painter.paintRoundedFill(
          canvas,
          Rect.fromLTWH(rect.left, rect.top, filled, rect.height),
          theme.accent,
          3);
    }
  }

  /// A one-line text field; returns the text after this frame's typing.
  ///
  /// Click to focus; typing appends, Backspace deletes, Enter or a click
  /// elsewhere ends the edit.
  String textField(String text,
      {Object? key, String hint = '', double width = 220}) {
    final int id = idFor(key ?? 'textField#${_counter++}');
    final ImmediateMemory memory = _frame.memory;
    final Rect rect = allocate(Size(width, theme.effectiveControlHeight));
    final Response response = interact(rect, id);
    if (response.clicked && memory.focused != id) {
      memory.focused = id;
      _frame.painter.requestKeyboardFocus();
    }
    var next = text;
    final bool focused = memory.focused == id;
    if (focused) {
      final ImmediateInput input = _frame.input;
      if (input.text.isNotEmpty) next += input.text.toString();
      for (final int key in input.keys) {
        if (key == 0x08 && next.isNotEmpty) {
          next = String.fromCharCodes(next.runes.toList()..removeLast());
        } else if (key == 0x0D || key == 0x1B) {
          memory.focused = null;
        }
      }
    }
    final double radius =
        theme.controlStyle == ControlStyle.material ? 4 : theme.cornerRadius;
    _frame.painter
        .paintRoundedFill(canvas, rect, theme.surfaceAlternate, radius);
    _frame.painter.paintRoundedBorder(
        canvas,
        rect,
        focused
            ? theme.accent
            : response.hovered
                ? theme.borderStrong
                : theme.border,
        radius,
        width: focused ? 2 : 1);
    final double pad = theme.effectiveControlPadding / 1.5;
    final double top = _textTop(rect, theme.fontSize);
    final bool showHint = next.isEmpty && !focused && hint.isNotEmpty;
    _paintText(showHint ? hint : next, Offset(rect.left + pad, top),
        theme.fontSize, showHint ? theme.foregroundSecondary : theme.foreground,
        maxWidth: rect.width - pad * 2);
    if (focused) {
      final double caretX = rect.left +
          pad +
          math.min(_measure(next, theme.fontSize).width, rect.width - pad * 2);
      canvas.drawRectangle(
          Rect.fromLTWH(caretX.roundToDouble(), top, 1.5,
              (theme.fontSize * 1.2).roundToDouble()),
          canvas.addPaint(colorArgb: theme.accent.value));
    }
    if (next != text) _frame.wantsRepaint = true;
    return next;
  }

  /// A section with a title that opens and closes; [contents] runs only
  /// while it is open.
  bool collapsing(String title, void Function(Ui ui) contents,
      {bool initiallyOpen = false, Object? key}) {
    final int id = _autoId(key, title);
    final bool open = _frame.memory.value<bool>(id, () => initiallyOpen);
    final double size = theme.fontSize;
    final Size measured = _measure(title, size);
    final double arrow = (size * 0.8).roundToDouble();
    final Rect rect = allocate(Size(
        _vertical ? availableRect.width : arrow + spacing + measured.width,
        theme.effectiveControlHeight));
    final Response response = interact(rect, id);
    final bool next = response.clicked ? !open : open;
    if (next != open) _frame.memory.set<bool>(id, next);
    if (response.hovered) {
      _frame.painter.paintRoundedFill(
          canvas, rect, theme.hoverSurface, theme.cornerRadiusSmall);
    }
    // The disclosure triangle, as two strokes: right when closed, down open.
    final Offset c = Offset(rect.left + arrow / 2 + 2, rect.center.dy);
    final double h = arrow / 3;
    paintPolyline(
        canvas,
        next
            ? <Offset>[
                c + Offset(-h, -h / 2),
                c + Offset(0, h / 2),
                c + Offset(h, -h / 2)
              ]
            : <Offset>[
                c + Offset(-h / 2, -h),
                c + Offset(h / 2, 0),
                c + Offset(-h / 2, h)
              ],
        1.5,
        theme.foregroundSecondary);
    _paintText(title, Offset(rect.left + arrow + spacing, _textTop(rect, size)),
        size, theme.foreground);
    if (next) indent(contents);
    return next;
  }

  /// [contents] in a box [height] tall that scrolls with the wheel.
  void scrollArea(void Function(Ui ui) contents,
      {required double height, double? width, Object? key}) {
    final int id = idFor(key ?? 'scroll#${_counter++}');
    final Rect available = availableRect;
    final Rect rect = allocate(Size(width ?? available.width, height));
    var offset = _frame.memory.value<double>(id, () => 0.0);
    final double contentHeight =
        _frame.memory.value<double>(Object.hash(id, 'h'), () => 0.0);
    final Offset? pointer = _frame.input.pointer;
    if (pointer != null &&
        rect.contains(pointer) &&
        _frame.input.scroll.dy != 0) {
      offset += _frame.input.scroll.dy;
      _frame.wantsRepaint = true;
    }
    offset = offset.clamp(0.0, math.max(0.0, contentHeight - height));
    _frame.memory.set<double>(id, offset);
    final Rect clip = rect.intersect(_clip);
    canvas
      ..save()
      ..clipRect(clip.left, clip.top, clip.right, clip.bottom);
    final Ui child = Ui._(
        _frame,
        Rect.fromLTWH(
            rect.left, rect.top - offset, rect.width - 10, double.infinity),
        true,
        Object.hash(id, 'content'),
        clip,
        _theme);
    contents(child);
    canvas.restore();
    final double measured = child.usedSize.height;
    if (measured != contentHeight) {
      _frame.memory.set<double>(Object.hash(id, 'h'), measured);
      _frame.wantsRepaint = true;
    }
    if (measured > height) {
      final double thumb = math.max(24, height * height / measured);
      final double top =
          rect.top + (height - thumb) * (offset / (measured - height));
      _frame.painter.paintRoundedFill(
          canvas,
          Rect.fromLTWH(rect.right - 6, top, 4, thumb),
          theme.scrollbarTheme.thumbColor ?? theme.borderStrong,
          2);
    }
  }

  /// [contents] on a raised panel: a group that reads as one thing.
  void panel(void Function(Ui ui) contents, {Object? key}) {
    final int id = idFor(key ?? 'panel#${_counter++}');
    final double pad = theme.effectiveControlPadding;
    // The panel is drawn before its contents, so its size is last frame's;
    // a change is drawn on the next frame, which this one asks for.
    final Size last = _frame.memory.value<Size>(id, () => Size.zero);
    final Rect available = availableRect;
    final Rect origin = _withGap(available);
    if (last != Size.zero) {
      final Rect back =
          Rect.fromLTWH(origin.left, origin.top, last.width, last.height);
      _frame.painter.paintRoundedFill(
          canvas, back, theme.surfaceRaised, theme.cornerRadiusLarge);
      _frame.painter.paintRoundedBorder(
          canvas, back, theme.borderSubtle, theme.cornerRadiusLarge);
    }
    final Ui child = Ui._(
        _frame,
        Rect.fromLTRB(origin.left + pad, origin.top + pad, origin.right - pad,
            origin.bottom),
        true,
        Object.hash(id, 'panel'),
        _clip,
        _theme);
    contents(child);
    final Size used =
        Size(child.usedSize.width + pad * 2, child.usedSize.height + pad * 2);
    if (used != last) {
      _frame.memory.set<Size>(id, used);
      _frame.wantsRepaint = true;
    }
    allocate(used);
  }

  Response _inert(Rect rect) => Response(
        rect: rect,
        hovered: false,
        pressed: false,
        clicked: false,
        dragDelta: Offset.zero,
      );

  // -------------------------------------------------------------------------
  // Frame end
  // -------------------------------------------------------------------------

  /// Settles the frame; true when another one is needed.
  bool finish() {
    final ImmediateInput input = _frame.input;
    final ImmediateMemory memory = _frame.memory;
    // A press on nothing takes the keyboard away from a text field.
    if (input.pressed && !_frame.claimedPress) memory.focused = null;
    if (input.pressed &&
        _frame.claimedPress &&
        memory.active != memory.focused) {
      memory.focused = null;
    }
    if (input.released || !input.down) {
      memory
        ..active = null
        ..pressOrigin = null;
    }
    final bool hotChanged = memory.hot != _frame.hotThisFrame;
    memory
      ..hot = _frame.hotThisFrame
      ..contentSize = usedSize;
    return _frame.wantsRepaint || hotChanged;
  }
}
