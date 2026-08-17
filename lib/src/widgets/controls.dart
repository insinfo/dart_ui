/// The framework-owned control set.
///
/// Every control here satisfies the criterion in section 29.4 - built from Dart
/// code, measured and arranged by the layout tree, drawn by the CPU backend,
/// hit-tested, hoverable, pressable, focusable by Tab, activatable by
/// Space/Enter, and exposing a role to accessibility - **with no native control
/// anywhere**. A control that delegated any of those to the platform would
/// still look right on Windows and be missing on the other two backends.
///
/// The division of labour: a control widget reads the theme from context and
/// configures a render object; the render object owns state and painting via
/// [ControlBehavior]. Appearance therefore lives in one place and can be
/// replaced by a template without touching the control.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_viewport.dart';
import '../platform/clipboard.dart';
import '../platform/input_events.dart';
import 'context_menu.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'menu.dart';
import 'scrollbar.dart';
import 'semantics.dart';
import 'style.dart';
import 'theme.dart';
import 'widget.dart';

/// The clipboard contract travels with the control that uses it: a caller who
/// installs a [ClipboardScope], writes a test double or handles a paste
/// failure needs [Clipboard] and [ClipboardException] to say anything about it.
export '../foundation/value_notifier.dart';
export '../platform/clipboard.dart';

/// The context menu travels with the controls that raise one. [TextField] opens
/// its own from a secondary click, so a caller who wants that to work needs
/// [ContextMenuScope] - and one who wants a menu of their own needs
/// [ContextMenuRegion] and [MenuItem] together, which is why the two arrive
/// from the same import rather than from opposite ends of the library.
export 'context_menu.dart';
export 'menu.dart';
export 'text_field.dart';

final class Button extends StatefulWidget {
  const Button({
    super.key,
    required this.label,
    this.onPressed,
    this.isDefault = false,
    this.isCancel = false,
    this.styleClasses = const <String>{},
  });

  final String label;
  final void Function()? onPressed;

  /// The button Enter activates when nothing else has focus.
  final bool isDefault;

  /// The button Escape activates.
  final bool isCancel;

  final Set<String> styleClasses;

  @override
  State<Button> createState() => _ButtonState();
}

final class _ButtonState extends State<Button> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Button');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ButtonRenderWidget(
          label: widget.label,
          onPressed: widget.onPressed,
          theme: Theme.of(context),
          focusNode: _focusNode,
          isDefault: widget.isDefault,
          isCancel: widget.isCancel,
          styleClasses: widget.styleClasses,
        ),
      );
}

final class _ButtonRenderWidget extends RenderObjectWidget {
  const _ButtonRenderWidget({
    required this.label,
    required this.onPressed,
    required this.theme,
    required this.focusNode,
    required this.isDefault,
    required this.isCancel,
    required this.styleClasses,
  });

  final String label;
  final void Function()? onPressed;
  final ThemeData theme;
  final FocusNode focusNode;
  final bool isDefault;
  final bool isCancel;
  final Set<String> styleClasses;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderButton createRenderObject(BuildContext context) => RenderButton(
        label: label,
        onPressed: onPressed,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onPressed != null
        ..isDefault = isDefault
        ..isCancel = isCancel
        ..styleClasses = styleClasses;

  @override
  void updateRenderObject(BuildContext context, covariant RenderButton object) {
    object
      ..label = label
      ..onPressed = onPressed
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onPressed != null
      ..isDefault = isDefault
      ..isCancel = isCancel
      ..styleClasses = styleClasses;
  }
}

final class RenderButton extends RenderBox with ControlBehavior {
  RenderButton({required String label, this.onPressed}) : _label = label;

  String _label;
  void Function()? onPressed;
  bool isDefault = false;
  bool isCancel = false;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  @override
  void activate() => onPressed?.call();

  @override
  void performLayout() => size = constraints.constrain(labelledSize(_label));

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintRoundedFill(list, rect, surfaceColor(), theme.cornerRadius);
    if (theme.highContrast || !enabled) {
      paintRoundedBorder(
        list,
        rect,
        enabled ? theme.border : theme.disabledForeground,
        theme.cornerRadius,
      );
    }
    if (isDefault && enabled) {
      paintRoundedBorder(
        list,
        rect,
        theme.focusRing,
        theme.cornerRadius,
      );
    }
    paintCenteredLabel(
      list,
      _label,
      rect,
      enabled ? theme.colorScheme.onPrimary : theme.disabledForeground,
    );
    paintFocusRing(list, rect);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.button,
        label: _label,
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.activate,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

/// A button that carries an on/off value.
final class ToggleButton extends StatefulWidget {
  const ToggleButton({
    super.key,
    required this.label,
    required this.value,
    this.onChanged,
  });

  final String label;
  final bool value;
  final void Function(bool value)? onChanged;

  @override
  State<ToggleButton> createState() => _ToggleButtonState();
}

final class _ToggleButtonState extends State<ToggleButton> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'ToggleButton');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ToggleRenderWidget(
          label: widget.label,
          value: widget.value,
          onChanged: widget.onChanged,
          theme: Theme.of(context),
          focusNode: _focusNode,
          style: ToggleStyle.button,
        ),
      );
}

/// How a two-state control draws itself.
enum ToggleStyle { button, checkBox, radio, switchControl }

final class _ToggleRenderWidget extends RenderObjectWidget {
  const _ToggleRenderWidget({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.theme,
    required this.focusNode,
    required this.style,
    this.tristate = false,
    this.isNull = false,
  });

  final String label;
  final bool value;
  final void Function(bool value)? onChanged;
  final ThemeData theme;
  final FocusNode focusNode;
  final ToggleStyle style;
  final bool tristate;
  final bool isNull;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderToggle createRenderObject(BuildContext context) => RenderToggle(
        label: label,
        value: value,
        style: style,
        onChanged: onChanged,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onChanged != null
        ..isIndeterminate = isNull;

  @override
  void updateRenderObject(BuildContext context, covariant RenderToggle object) {
    object
      ..label = label
      ..value = value
      ..onChanged = onChanged
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onChanged != null
      ..isIndeterminate = isNull;
  }
}

/// The shared render object behind CheckBox, Radio, Switch and ToggleButton.
///
/// One class rather than four, because they differ only in the glyph they draw
/// and the role they report - the state machine, the keyboard activation and
/// the focus handling are identical, and four copies of that is four chances
/// for them to drift.
final class RenderToggle extends RenderBox with ControlBehavior {
  RenderToggle({
    required String label,
    required bool value,
    required this.style,
    this.onChanged,
  })  : _label = label,
        _value = value;

  final ToggleStyle style;
  String _label;
  bool _value;
  bool _indeterminate = false;
  void Function(bool value)? onChanged;

  /// The size of the box or circle drawn beside the label.
  static const double indicatorExtent = 14.0;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  bool get value => _value;

  set value(bool next) {
    if (next == _value) return;
    _value = next;
    markNeedsPaint();
  }

  /// The mixed state of a tri-state check box.
  bool get isIndeterminate => _indeterminate;

  set isIndeterminate(bool next) {
    if (next == _indeterminate) return;
    _indeterminate = next;
    markNeedsPaint();
  }

  @override
  void activate() => onChanged?.call(!_value);

  @override
  void performLayout() {
    if (style == ToggleStyle.button) {
      size = constraints.constrain(labelledSize(_label));
      return;
    }
    final double indicator = style == ToggleStyle.switchControl
        ? indicatorExtent * 1.8
        : indicatorExtent;
    final Size text = measureLabel(_label);
    size = constraints.constrain(Size(
      indicator + (text.width > 0 ? text.width + 6 : 0),
      theme.effectiveControlHeight,
    ));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    switch (style) {
      case ToggleStyle.button:
        paintFill(
          list,
          rect,
          _value ? surfaceColor(normal: theme.accentPressed) : surfaceColor(),
        );
        paintCenteredLabel(list, _label, rect, theme.colorScheme.onPrimary);
        paintFocusRing(list, rect);
      case ToggleStyle.checkBox:
        _paintIndicator(list, rect, square: true);
      case ToggleStyle.radio:
        _paintIndicator(list, rect, square: false);
      case ToggleStyle.switchControl:
        _paintSwitch(list, rect);
    }
  }

  void _paintIndicator(DisplayList list, Rect rect, {required bool square}) {
    final double top =
        (rect.top + (rect.height - indicatorExtent) / 2).roundToDouble();
    final Rect box =
        Rect.fromLTWH(rect.left, top, indicatorExtent, indicatorExtent);
    paintFill(
        list, box, enabled ? theme.surfaceAlternate : theme.disabledSurface);
    paintBorder(
      list,
      box,
      isHovered && enabled ? theme.accentHovered : theme.border,
    );
    if (_indeterminate) {
      // A mixed check box is a bar, not a tick: a partially checked group is
      // not the same claim as a checked one and must not look like it.
      paintFill(
        list,
        Rect.fromLTWH(box.left + 3, box.top + indicatorExtent / 2 - 1,
            indicatorExtent - 6, 2),
        enabled ? theme.accent : theme.disabledForeground,
      );
    } else if (_value) {
      final Color mark = enabled ? theme.accent : theme.disabledForeground;
      if (square) {
        paintFill(
          list,
          Rect.fromLTWH(box.left + 3, box.top + 3, indicatorExtent - 6,
              indicatorExtent - 6),
          mark,
        );
      } else {
        // A circle is still a rect here: the rasterizer owns round shapes, and
        // an inset square reads correctly at 14 px until it does.
        paintFill(
          list,
          Rect.fromLTWH(box.left + 4, box.top + 4, indicatorExtent - 8,
              indicatorExtent - 8),
          mark,
        );
      }
    }
    paintLabel(
      list,
      _label,
      Offset(
        box.right + 6,
        (rect.top + (rect.height - labelLineHeight) / 2).roundToDouble(),
      ),
      foregroundColor(),
    );
    paintFocusRing(list, rect);
  }

  void _paintSwitch(DisplayList list, Rect rect) {
    const double width = indicatorExtent * 1.8;
    final double top =
        (rect.top + (rect.height - indicatorExtent) / 2).roundToDouble();
    final Rect track = Rect.fromLTWH(rect.left, top, width, indicatorExtent);
    paintFill(
      list,
      track,
      !enabled
          ? theme.disabledSurface
          : _value
              ? theme.accent
              : theme.surface,
    );
    paintBorder(list, track, theme.border);
    const double thumb = indicatorExtent - 4;
    paintFill(
      list,
      Rect.fromLTWH(
        _value ? track.right - thumb - 2 : track.left + 2,
        top + 2,
        thumb,
        thumb,
      ),
      enabled ? theme.surfaceAlternate : theme.disabledForeground,
    );
    paintLabel(
      list,
      _label,
      Offset(
        track.right + 6,
        (rect.top + (rect.height - labelLineHeight) / 2).roundToDouble(),
      ),
      foregroundColor(),
    );
    paintFocusRing(list, rect);
  }

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_value) PseudoClass.checked,
      };

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: switch (style) {
          ToggleStyle.checkBox => SemanticsRole.checkbox,
          ToggleStyle.radio => SemanticsRole.radio,
          ToggleStyle.switchControl => SemanticsRole.toggleButton,
          ToggleStyle.button => SemanticsRole.toggleButton,
        },
        label: _label,
        value: _indeterminate
            ? 'mixed'
            : _value
                ? 'checked'
                : 'unchecked',
        states: <SemanticsState>{
          if (_indeterminate)
            SemanticsState.mixed
          else if (_value)
            SemanticsState.checked,
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.activate,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

/// A two- or three-state check box.
final class CheckBox extends StatefulWidget {
  const CheckBox({
    super.key,
    required this.value,
    this.label = '',
    this.onChanged,
    this.tristate = false,
  });

  /// Null means mixed, which is only legal when [tristate].
  final bool? value;
  final String label;
  final void Function(bool value)? onChanged;
  final bool tristate;

  @override
  State<CheckBox> createState() => _CheckBoxState();
}

final class _CheckBoxState extends State<CheckBox> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'CheckBox');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ToggleRenderWidget(
          label: widget.label,
          value: widget.value ?? false,
          isNull: widget.value == null,
          tristate: widget.tristate,
          onChanged: widget.onChanged,
          theme: Theme.of(context),
          focusNode: _focusNode,
          style: ToggleStyle.checkBox,
        ),
      );
}

/// One option of a mutually exclusive group.
final class Radio<T> extends StatefulWidget {
  const Radio({
    super.key,
    required this.value,
    required this.groupValue,
    this.label = '',
    this.onChanged,
  });

  final T value;
  final T? groupValue;
  final String label;
  final void Function(T value)? onChanged;

  @override
  State<Radio<T>> createState() => _RadioState<T>();
}

final class _RadioState<T> extends State<Radio<T>> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Radio');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final void Function(T value)? onChanged = widget.onChanged;
    return FocusAttachment(
      node: _focusNode,
      child: _ToggleRenderWidget(
        label: widget.label,
        value: widget.value == widget.groupValue,
        // Selecting an already-selected radio is a no-op, not a deselect: a
        // radio group has no empty state once one option is chosen.
        onChanged:
            onChanged == null ? null : (bool _) => onChanged(widget.value),
        theme: Theme.of(context),
        focusNode: _focusNode,
        style: ToggleStyle.radio,
      ),
    );
  }
}

/// An on/off switch.
final class Switch extends StatefulWidget {
  const Switch({
    super.key,
    required this.value,
    this.label = '',
    this.onChanged,
  });

  final bool value;
  final String label;
  final void Function(bool value)? onChanged;

  @override
  State<Switch> createState() => _SwitchState();
}

final class _SwitchState extends State<Switch> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Switch');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ToggleRenderWidget(
          label: widget.label,
          value: widget.value,
          onChanged: widget.onChanged,
          theme: Theme.of(context),
          focusNode: _focusNode,
          style: ToggleStyle.switchControl,
        ),
      );
}

// ---------------------------------------------------------------------------
// Slider and progress
// ---------------------------------------------------------------------------

final class Slider extends StatefulWidget {
  const Slider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.step = 0.1,
    this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final void Function(double value)? onChanged;

  @override
  State<Slider> createState() => _SliderState();
}

final class _SliderState extends State<Slider> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Slider');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _SliderRenderWidget(
          value: widget.value,
          min: widget.min,
          max: widget.max,
          step: widget.step,
          onChanged: widget.onChanged,
          theme: Theme.of(context),
          focusNode: _focusNode,
        ),
      );
}

final class _SliderRenderWidget extends RenderObjectWidget {
  const _SliderRenderWidget({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.theme,
    required this.focusNode,
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final void Function(double value)? onChanged;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderSlider createRenderObject(BuildContext context) => RenderSlider(
        value: value,
        min: min,
        max: max,
        step: step,
        onChanged: onChanged,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onChanged != null;

  @override
  void updateRenderObject(BuildContext context, covariant RenderSlider object) {
    object
      ..value = value
      ..min = min
      ..max = max
      ..step = step
      ..onChanged = onChanged
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onChanged != null;
  }
}

final class RenderSlider extends RenderBox with ControlBehavior {
  RenderSlider({
    required double value,
    required double min,
    required double max,
    required this.step,
    this.onChanged,
  })  : _value = value,
        _min = min,
        _max = max;

  static const double trackThickness = 4.0;
  static const double thumbExtent = 12.0;

  double _value;
  double _min;
  double _max;
  double step;
  void Function(double value)? onChanged;

  double get value => _value;

  set value(double next) {
    if (next == _value) return;
    _value = next;
    markNeedsPaint();
  }

  double get min => _min;

  set min(double next) {
    if (next == _min) return;
    _min = next;
    markNeedsPaint();
  }

  double get max => _max;

  set max(double next) {
    if (next == _max) return;
    _max = next;
    markNeedsPaint();
  }

  /// Where the value sits in its range, 0 to 1. Guards a zero-width range,
  /// which would otherwise divide by zero on a slider with min == max.
  double get normalized {
    final double range = _max - _min;
    if (range <= 0) return 0;
    return ((_value - _min) / range).clamp(0.0, 1.0);
  }

  void _emit(double next) {
    final double clamped = next.clamp(_min, _max);
    if (clamped == _value) return;
    onChanged?.call(clamped);
  }

  @override
  void activate() {}

  @override
  void performLayout() => size = constraints.constrain(
        Size(140, theme.effectiveControlHeight),
      );

  @override
  bool hitTestSelf(Offset position) => true;

  /// True from the press until the release, whether or not the pointer is
  /// still over the slider.
  ///
  /// [ControlBehavior.isPressed] cannot serve here: it deliberately goes false
  /// when a captured pointer wanders off, so the control stops *looking*
  /// pressed. A slider must keep *tracking* in exactly that situation - a
  /// mouse drifting above or below the track is the normal way people drag one
  /// - so the two states are genuinely different and need separate fields.
  bool _dragging = false;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    switch (event) {
      // Pressing anywhere on the track jumps there and starts a drag, which is
      // what a scrollbar-style slider does on all three targets.
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
    // The pointer is captured by now, so its position may be anywhere on
    // screen - including well outside this control. Converting into this
    // slider's own space and then clamping onto the track is what lets the
    // drag continue when the mouse is above, below, or past the end of it.
    final Offset local = globalToLocal(event.logicalPosition);
    final double usable =
        (size.width - thumbExtent).clamp(1.0, double.infinity);
    final double fraction =
        ((local.dx - thumbExtent / 2) / usable).clamp(0.0, 1.0);
    _emit(_min + fraction * (_max - _min));
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (!enabled || event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowLeft || logicalKeyArrowDown:
        _emit(_value - step);
        return true;
      case logicalKeyArrowRight || logicalKeyArrowUp:
        _emit(_value + step);
        return true;
      case logicalKeyHome:
        _emit(_min);
        return true;
      case logicalKeyEnd:
        _emit(_max);
        return true;
      case logicalKeyPageDown:
        _emit(_value - step * 5);
        return true;
      case logicalKeyPageUp:
        _emit(_value + step * 5);
        return true;
      default:
        return false;
    }
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final double centerY =
        (offset.dy + size.height / 2 - trackThickness / 2).roundToDouble();
    final Rect track = Rect.fromLTWH(
      offset.dx,
      centerY,
      size.width,
      trackThickness,
    );
    paintFill(list, track, enabled ? theme.surface : theme.disabledSurface);
    paintBorder(list, track, theme.border);
    final double usable =
        (size.width - thumbExtent).clamp(0.0, double.infinity);
    final double thumbLeft = (offset.dx + usable * normalized).roundToDouble();
    paintFill(
      list,
      Rect.fromLTWH(offset.dx, centerY, thumbLeft - offset.dx, trackThickness),
      enabled ? theme.accent : theme.disabledForeground,
    );
    final Rect thumb = Rect.fromLTWH(
      thumbLeft,
      (offset.dy + size.height / 2 - thumbExtent / 2).roundToDouble(),
      thumbExtent,
      thumbExtent,
    );
    paintFill(
      list,
      thumb,
      !enabled
          ? theme.disabledForeground
          : isPressed
              ? theme.accentPressed
              : isHovered
                  ? theme.accentHovered
                  : theme.accent,
    );
    paintBorder(list, thumb, theme.border);
    paintFocusRing(
      list,
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.slider,
        value: _value.toStringAsFixed(2),
        increasedValue: (_value + step).clamp(_min, _max).toStringAsFixed(2),
        decreasedValue: (_value - step).clamp(_min, _max).toStringAsFixed(2),
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.increment,
                SemanticsAction.decrement,
                SemanticsAction.setValue,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
      );
}

/// A determinate progress bar.
final class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value});

  /// 0 to 1.
  final double value;

  @override
  Widget build(BuildContext context) =>
      _ProgressRenderWidget(value: value, theme: Theme.of(context));
}

final class _ProgressRenderWidget extends RenderObjectWidget {
  const _ProgressRenderWidget({required this.value, required this.theme});

  final double value;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderProgressBar createRenderObject(BuildContext context) =>
      RenderProgressBar(value: value)..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProgressBar object,
  ) {
    object
      ..value = value
      ..theme = theme;
  }
}

final class RenderProgressBar extends RenderBox with ControlBehavior {
  RenderProgressBar({required double value}) : _value = value;

  double _value;

  double get value => _value;

  set value(double next) {
    if (next == _value) return;
    _value = next;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() => size = constraints.constrain(const Size(140, 6));

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surface);
    paintBorder(list, rect, theme.border);
    paintFill(
      list,
      Rect.fromLTWH(
        rect.left,
        rect.top,
        (rect.width * _value.clamp(0.0, 1.0)).roundToDouble(),
        rect.height,
      ),
      theme.accent,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.progressBar,
        value: '${(_value.clamp(0.0, 1.0) * 100).round()}%',
      );
}

// ---------------------------------------------------------------------------
// Containers: scroll, dialog, menu, tooltip
// ---------------------------------------------------------------------------

/// Scrolls one child, with a scrollbar and wheel/keyboard handling.
final class ScrollViewer extends StatefulWidget {
  const ScrollViewer({
    super.key,
    required this.child,
    this.axis = ScrollAxis.vertical,
    this.controller,
  });

  final Widget child;
  final ScrollAxis axis;
  final ScrollPosition? controller;

  @override
  State<ScrollViewer> createState() => _ScrollViewerState();
}

final class _ScrollViewerState extends State<ScrollViewer> {
  late final ScrollPosition _position =
      widget.controller ?? ScrollPosition(axis: widget.axis);

  @override
  Widget build(BuildContext context) => Scrollbar(
        position: _position,
        child: _ScrollViewerRenderWidget(
          position: _position,
          theme: Theme.of(context),
          child: widget.child,
        ),
      );
}

final class _ScrollViewerRenderWidget extends SingleChildRenderObjectWidget {
  const _ScrollViewerRenderWidget({
    required this.position,
    required this.theme,
    required super.child,
  });

  final ScrollPosition position;
  final ThemeData theme;

  @override
  RenderScrollViewer createRenderObject(BuildContext context) =>
      RenderScrollViewer(position: position)..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderScrollViewer object,
  ) {
    object
      ..position = position
      ..theme = theme;
  }
}

/// A viewport that also handles wheel, keyboard and scrollbar painting.
final class RenderScrollViewer extends RenderViewport with ControlBehavior {
  RenderScrollViewer({required super.position, super.child});

  @override
  bool get focusOnPointerDown => false;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (event is! PointerScrollEvent) return;
    final double delta = position.axis == ScrollAxis.vertical
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    position.applyScrollDelta(
      delta,
      inLines: event.scrollDeltaUnit == ScrollDeltaUnit.lines,
    );
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowDown:
        return position.applyDelta(defaultLineExtent) == 0;
      case logicalKeyArrowUp:
        return position.applyDelta(-defaultLineExtent) == 0;
      case logicalKeyPageDown:
        return position.pageBy(1) == 0;
      case logicalKeyPageUp:
        return position.pageBy(-1) == 0;
      case logicalKeyHome:
        return position.jumpTo(0);
      case logicalKeyEnd:
        return position.jumpTo(position.maxScrollExtent);
      default:
        return false;
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.scrollView,
        value: position.pixels.toStringAsFixed(0),
        actions: <SemanticsAction>{
          if (position.axis == ScrollAxis.vertical) ...<SemanticsAction>{
            if (!position.atEnd) SemanticsAction.scrollDown,
            if (!position.atStart) SemanticsAction.scrollUp,
          } else ...<SemanticsAction>{
            if (!position.atEnd) SemanticsAction.scrollRight,
            if (!position.atStart) SemanticsAction.scrollLeft,
          },
        },
      );
}

/// A modal surface with a title.
final class Dialog extends StatelessWidget {
  const Dialog({
    super.key,
    required this.title,
    required this.child,
    this.onDismiss,
  });

  final String title;
  final Widget child;
  final void Function()? onDismiss;

  @override
  Widget build(BuildContext context) => _DialogRenderWidget(
        title: title,
        theme: Theme.of(context),
        onDismiss: onDismiss,
        child: child,
      );
}

final class _DialogRenderWidget extends SingleChildRenderObjectWidget {
  const _DialogRenderWidget({
    required this.title,
    required this.theme,
    required this.onDismiss,
    required super.child,
  });

  final String title;
  final ThemeData theme;
  final void Function()? onDismiss;

  @override
  RenderDialog createRenderObject(BuildContext context) =>
      RenderDialog(title: title, onDismiss: onDismiss)..theme = theme;

  @override
  void updateRenderObject(BuildContext context, covariant RenderDialog object) {
    object
      ..title = title
      ..onDismiss = onDismiss
      ..theme = theme;
  }
}

final class RenderDialog extends RenderSingleChildBox with ControlBehavior {
  RenderDialog({required String title, this.onDismiss}) : _title = title;

  static const double titleBarHeight = 22.0;

  String _title;
  void Function()? onDismiss;

  String get title => _title;

  set title(String value) {
    if (value == _title) return;
    _title = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    final double padding = theme.effectiveControlPadding;
    if (child == null) {
      size = constraints.constrain(Size(120, titleBarHeight + padding * 2));
      return;
    }
    child.layout(
      constraints.deflate(EdgeInsets.only(
        left: padding,
        right: padding,
        top: titleBarHeight + padding,
        bottom: padding,
      )),
      parentUsesSize: true,
    );
    child.parentData!.offset = Offset(padding, titleBarHeight + padding);
    size = constraints.constrain(Size(
      child.size.width + padding * 2,
      child.size.height + titleBarHeight + padding * 2,
    ));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == logicalKeyEscape) {
      onDismiss?.call();
      return true;
    }
    return super.handleKeyEvent(event);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surfaceAlternate);
    paintBorder(list, rect, theme.border);
    final Rect titleBar =
        Rect.fromLTWH(rect.left, rect.top, rect.width, titleBarHeight);
    paintFill(list, titleBar, theme.accent);
    paintLabel(
      list,
      _title,
      Offset(
        rect.left + 4,
        (titleBar.top + (titleBarHeight - labelLineHeight) / 2).roundToDouble(),
      ),
      theme.colorScheme.onPrimary,
      maxWidth: rect.width - 8,
    );
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.dialog,
        label: _title,
        states: const <SemanticsState>{SemanticsState.modal},
        actions: const <SemanticsAction>{SemanticsAction.dismiss},
        // A modal hides what is behind it from assistive technology too, which
        // is the accessibility half of "modal" and the half most often missed.
        isBlocking: true,
      );
}

/// A hover label attached to a child.
///
/// The tooltip's own surface is placed by [PopupPositioner] when it is shown;
/// this widget is the trigger and the message, not the window.
final class Tooltip extends StatelessWidget {
  const Tooltip({super.key, required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// The surface a tooltip paints when shown.
final class TooltipSurface extends StatelessWidget {
  const TooltipSurface({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) =>
      _TooltipRenderWidget(message: message, theme: Theme.of(context));
}

final class _TooltipRenderWidget extends RenderObjectWidget {
  const _TooltipRenderWidget({required this.message, required this.theme});

  final String message;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderTooltip createRenderObject(BuildContext context) =>
      RenderTooltip(message: message)..theme = theme;

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderTooltip object) {
    object
      ..message = message
      ..theme = theme;
  }
}

final class RenderTooltip extends RenderBox with ControlBehavior {
  RenderTooltip({required String message}) : _message = message;

  String _message;

  String get message => _message;

  set message(String value) {
    if (value == _message) return;
    _message = value;
    markNeedsLayout();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final Size text = measureLabel(_message);
    size = constraints.constrain(Size(text.width + 8, text.height + 6));
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surface);
    paintBorder(list, rect, theme.border);
    paintCenteredLabel(list, _message, rect, theme.foreground);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.tooltip,
        label: _message,
      );
}
