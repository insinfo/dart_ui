/// A numeric field with spin buttons.
///
/// A [NumberBox] is *not* a text field that happens to hold digits. The value
/// is a number owned by the caller; the text is a draft of it that exists
/// only while the control is being edited, and the two meet at exactly three
/// moments - Enter, focus loss, and a spin - where the draft is parsed,
/// clamped into `[min, max]` and reported through [NumberBox.onChanged].
/// Escape throws the draft away. That commit discipline is what makes an
/// half-typed `-` or `1.` never reach the owner as garbage.
///
/// Keyboard: Up/Down step by [NumberBox.step], PageUp/PageDown by ten steps,
/// digits and separators are accepted as typed text, Backspace edits the
/// draft, Enter commits, Escape reverts. The spin buttons repeat the same
/// step for the pointer. One tab stop: the buttons belong to the field and
/// take no focus of their own.
///
/// The value is formatted with [NumberBox.decimals] fraction digits - a
/// format choice, deliberately minimal; an application with locale-aware
/// grouping installs its own formatting upstream of the control.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../semantics/semantics.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'keyboard_router.dart';
import 'theme.dart';
import 'widget.dart';

/// A numeric input with +/- spin buttons, validation and clamping.
final class NumberBox extends StatefulWidget {
  const NumberBox({
    super.key,
    required this.value,
    this.onChanged,
    this.min = double.negativeInfinity,
    this.max = double.infinity,
    this.step = 1,
    this.decimals = 0,
    this.enabled = true,
  });

  final double value;
  final void Function(double value)? onChanged;
  final double min;
  final double max;
  final double step;

  /// Fraction digits shown; 0 draws integers.
  final int decimals;

  final bool enabled;

  @override
  State<NumberBox> createState() => _NumberBoxState();
}

final class _NumberBoxState extends State<NumberBox> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'NumberBox')
    ..addListener(_onFocusChanged);

  /// The text being edited, or null when the control just shows the value.
  String? _draft;

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onFocusChanged(FocusNode node) {
    // Focus loss is a commit, exactly like Enter: whatever was typed is the
    // user's last word on the value, and dropping it silently would make
    // Tab destroy work.
    if (!node.hasPrimaryFocus && _draft != null) _commit();
  }

  String _format(double value) => widget.decimals <= 0
      ? value.round().toString()
      : value.toStringAsFixed(widget.decimals);

  String get _displayText => _draft ?? _format(widget.value);

  void _emit(double value) {
    final double clamped = value.clamp(widget.min, widget.max);
    if (clamped != widget.value) widget.onChanged?.call(clamped);
  }

  void _commit() {
    final String? draft = _draft;
    setState(() => _draft = null);
    if (draft == null) return;
    // A comma is accepted as the decimal separator and normalized, because
    // half this project's users type on a Brazilian keyboard.
    final double? parsed = double.tryParse(draft.replaceAll(',', '.'));
    // Unparseable text reverts to the last good value rather than guessing.
    if (parsed != null) _emit(parsed);
  }

  void _revert() => setState(() => _draft = null);

  void _stepBy(double amount) {
    // A step commits the draft first, so typing "5" and pressing Up yields 6
    // rather than stepping the stale value.
    final String? draft = _draft;
    double base = widget.value;
    if (draft != null) {
      base = double.tryParse(draft.replaceAll(',', '.')) ?? base;
      setState(() => _draft = null);
    }
    _emit((base + amount).clamp(widget.min, widget.max));
  }

  void _insert(String text) {
    // Only characters that can appear in a number are accepted; anything
    // else is refused at the door so the draft never needs cleaning.
    final String filtered = String.fromCharCodes(
      text.codeUnits.where((int unit) {
        final String char = String.fromCharCode(unit);
        return (unit >= 0x30 && unit <= 0x39) ||
            char == '-' ||
            char == '.' ||
            char == ',';
      }),
    );
    if (filtered.isEmpty) return;
    // Typing into an untouched field replaces the shown value, the way every
    // spreadsheet cell behaves; further typing extends the draft.
    setState(() => _draft = _draft == null ? filtered : _draft! + filtered);
  }

  void _backspace() {
    final String current = _displayText;
    if (current.isEmpty) return;
    setState(
      () => _draft = current.substring(0, current.length - 1),
    );
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowUp:
        _stepBy(widget.step);
        return true;
      case logicalKeyArrowDown:
        _stepBy(-widget.step);
        return true;
      case logicalKeyPageUp:
        _stepBy(widget.step * 10);
        return true;
      case logicalKeyPageDown:
        _stepBy(-widget.step * 10);
        return true;
      case logicalKeyEnter:
        _commit();
        return true;
      case logicalKeyEscape:
        if (_draft == null) return false;
        _revert();
        return true;
      case logicalKeyBackspace:
        _backspace();
        return true;
      default:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _NumberBoxRenderWidget(
          text: _displayText,
          editing: _draft != null,
          canIncrement: widget.value < widget.max,
          canDecrement: widget.value > widget.min,
          onKeyEvent: _handleKey,
          onTextInput: _insert,
          onStep: _stepBy,
          step: widget.step,
          theme: Theme.of(context),
          focusNode: _focusNode,
          enabled: widget.enabled && widget.onChanged != null,
        ),
      );
}

final class _NumberBoxRenderWidget extends RenderObjectWidget {
  const _NumberBoxRenderWidget({
    required this.text,
    required this.editing,
    required this.canIncrement,
    required this.canDecrement,
    required this.onKeyEvent,
    required this.onTextInput,
    required this.onStep,
    required this.step,
    required this.theme,
    required this.focusNode,
    required this.enabled,
  });

  final String text;
  final bool editing;
  final bool canIncrement;
  final bool canDecrement;
  final bool Function(KeyEvent event) onKeyEvent;
  final void Function(String text) onTextInput;
  final void Function(double amount) onStep;
  final double step;
  final ThemeData theme;
  final FocusNode focusNode;
  final bool enabled;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderNumberBox createRenderObject(BuildContext context) => RenderNumberBox()
    ..text = text
    ..editing = editing
    ..canIncrement = canIncrement
    ..canDecrement = canDecrement
    ..onKeyEvent = onKeyEvent
    ..onTextInput = onTextInput
    ..onStep = onStep
    ..step = step
    ..theme = theme
    ..focusNode = focusNode
    ..enabled = enabled;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderNumberBox object,
  ) {
    object
      ..text = text
      ..editing = editing
      ..canIncrement = canIncrement
      ..canDecrement = canDecrement
      ..onKeyEvent = onKeyEvent
      ..onTextInput = onTextInput
      ..onStep = onStep
      ..step = step
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = enabled;
  }
}

/// The field: text on the start side, two stacked spin arrows at the end.
final class RenderNumberBox extends RenderBox
    with ControlBehavior
    implements TextInputTarget {
  /// The width of the spin-button column.
  /// The width of the spin-button column.
  ///
  /// Two thirds of the control, so the two little chevrons stay a comfortable
  /// pointer target as the density changes instead of staying 18 px forever.
  double get spinExtent =>
      (theme.effectiveControlHeight * 0.66).roundToDouble();

  String _text = '';
  bool _editing = false;
  bool _canIncrement = true;
  bool _canDecrement = true;
  bool Function(KeyEvent event)? onKeyEvent;
  void Function(String text)? onTextInput;
  void Function(double amount)? onStep;
  double step = 1;

  String get text => _text;

  set text(String value) {
    if (value == _text) return;
    _text = value;
    markNeedsPaint();
  }

  bool get editing => _editing;

  set editing(bool value) {
    if (value == _editing) return;
    _editing = value;
    markNeedsPaint();
  }

  bool get canIncrement => _canIncrement;

  set canIncrement(bool value) {
    if (value == _canIncrement) return;
    _canIncrement = value;
    markNeedsPaint();
  }

  bool get canDecrement => _canDecrement;

  set canDecrement(bool value) {
    if (value == _canDecrement) return;
    _canDecrement = value;
    markNeedsPaint();
  }

  Rect get _incrementRect => Rect.fromLTWH(
        size.width - spinExtent,
        0,
        spinExtent,
        size.height / 2,
      );

  Rect get _decrementRect => Rect.fromLTWH(
        size.width - spinExtent,
        size.height / 2,
        spinExtent,
        size.height / 2,
      );

  @override
  void performLayout() => size = constraints.constrain(
        Size(128, theme.effectiveControlHeight),
      );

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    if (event is PointerDownEvent && event.button == PointerButton.primary) {
      final Offset local = globalToLocal(event.logicalPosition);
      // Spin on the press, not the release: a spinner that steps on release
      // cannot ever repeat, and pressing is the gesture's meaning.
      if (_incrementRect.contains(local)) {
        if (_canIncrement) onStep?.call(step);
      } else if (_decrementRect.contains(local)) {
        if (_canDecrement) onStep?.call(-step);
      }
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) => onKeyEvent?.call(event) ?? false;

  @override
  bool handleTextInput(TextInputEvent event) {
    if (!enabled) return false;
    onTextInput?.call(event.text);
    return true;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    final double radius = theme.cornerRadius;
    paintRoundedFill(
      list,
      rect,
      enabled ? theme.surfaceAlternate : theme.disabledSurface,
      radius,
    );
    paintRoundedBorder(
      list,
      rect,
      !enabled
          ? theme.disabledForeground
          : hasFocus
              ? theme.accent
              : isHovered
                  ? theme.foregroundSecondary
                  : theme.borderStrong,
      radius,
      width: hasFocus ? 1.5 : 1,
    );

    final double padding = theme.effectiveControlPadding;
    // One padding, not two: the spin column already carries its own air on the
    // side it sits on, and charging the text for it as well is what made a
    // narrow spin box clip "297.0" into "297.(".
    final double textWidth =
        (size.width - spinExtent - padding).clamp(0.0, double.infinity);
    paintLabel(
      list,
      _text,
      Offset((rect.left + padding).roundToDouble(), labelTopIn(rect)),
      foregroundColor(),
      maxWidth: textWidth,
    );
    // A caret after the draft, so editing is visibly editing.
    if (_editing && hasFocus) {
      final double caretX =
          (rect.left + padding + measureLabel(_text).width + 1)
              .clamp(rect.left, rect.left + padding + textWidth);
      paintFill(
        list,
        Rect.fromLTWH(
          caretX.roundToDouble(),
          rect.top + 4,
          1,
          size.height - 8,
        ),
        theme.foreground,
      );
    }

    _paintSpinButton(list, _incrementRect.shift(offset), up: true);
    _paintSpinButton(list, _decrementRect.shift(offset), up: false);
    paintFocusRing(list, rect, radius: radius);
  }

  void _paintSpinButton(DisplayList list, Rect rect, {required bool up}) {
    final bool armed = enabled && (up ? _canIncrement : _canDecrement);
    // No box around the spinner. Two bordered half-height boxes stapled to the
    // right edge of a field is the 1995 spin control; the two chevrons alone,
    // on the field's own surface, is what a current one looks like - and the
    // hit rectangles are unchanged, so nothing gets harder to click.
    if (isHovered && armed) {
      paintRoundedFill(
        list,
        Rect.fromLTWH(rect.left, rect.top + 1, rect.width - 2, rect.height - 2),
        theme.hoverSurface,
        theme.cornerRadiusSmall,
      );
    }
    const double span = 3;
    final double centerX = (rect.left + rect.width / 2).roundToDouble();
    final double centerY = (rect.top + rect.height / 2).roundToDouble();
    paintPolylineMark(
      list,
      <Offset>[
        Offset(centerX - span, centerY + (up ? span / 2 : -span / 2)),
        Offset(centerX, centerY + (up ? -span / 2 : span / 2)),
        Offset(centerX + span, centerY + (up ? span / 2 : -span / 2)),
      ],
      1.5,
      armed ? theme.foregroundSecondary : theme.disabledForeground,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.textField,
        value: _text,
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
