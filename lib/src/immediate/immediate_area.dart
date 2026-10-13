/// Hosts an immediate-mode interface inside the retained framework.
///
/// One render object: input the router delivers is queued, and at paint time
/// the builder runs against that input and draws straight into the frame's
/// display list. A second frame is scheduled only when the first one changed
/// something it could not show - a click whose effect the controls drawn
/// before it missed, a hover that moved, a value being dragged - so an idle
/// interface draws nothing.
library;

import 'dart:async';

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../semantics/semantics.dart';
import '../widgets/control.dart';
import '../widgets/element.dart';
import '../widgets/focus.dart';
import '../widgets/focus_scope.dart';
import '../widgets/keyboard_router.dart';
import '../widgets/theme.dart';
import '../widgets/widget.dart';
import 'ui.dart';

/// What an immediate-mode frame runs.
typedef ImmediateBuilder = void Function(Ui ui);

/// An immediate-mode interface as a widget: [builder] runs on every frame of
/// this area, with a [Ui] that fills it.
///
/// It fills the space it is given. Under an unbounded constraint - in a
/// scrolling column, say - it takes the size its content took last frame.
final class ImmediateArea extends StatefulWidget {
  const ImmediateArea({super.key, required this.builder});

  final ImmediateBuilder builder;

  @override
  State<ImmediateArea> createState() => _ImmediateAreaState();
}

final class _ImmediateAreaState extends State<ImmediateArea> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'ImmediateArea');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ImmediateRenderWidget(
          builder: widget.builder,
          theme: Theme.of(context),
          focusNode: _focusNode,
        ),
      );
}

final class _ImmediateRenderWidget extends RenderObjectWidget {
  const _ImmediateRenderWidget({
    required this.builder,
    required this.theme,
    required this.focusNode,
  });

  final ImmediateBuilder builder;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderImmediate createRenderObject(BuildContext context) =>
      RenderImmediate(builder: builder)
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderImmediate object) {
    object
      ..builder = builder
      ..theme = theme
      ..focusNode = focusNode
      ..markNeedsPaint();
  }
}

/// The render object behind [ImmediateArea].
final class RenderImmediate extends RenderBox
    with ControlBehavior
    implements TextInputTarget, ImmediatePainter {
  RenderImmediate({required this.builder});

  ImmediateBuilder builder;
  final ImmediateInput _input = ImmediateInput();
  final ImmediateMemory memory = ImmediateMemory();
  Offset _paintOrigin = Offset.zero;
  Offset? _lastPointer;
  bool _repaintScheduled = false;
  Object? _lastError;

  /// The error the builder threw on the last frame, if any.
  Object? get lastError => _lastError;

  @override
  void performLayout() {
    final Size wanted = memory.contentSize == Size.zero
        ? const Size(320, 240)
        : memory.contentSize;
    size = constraints.constrain(Size(
      constraints.hasBoundedWidth ? constraints.maxWidth : wanted.width,
      constraints.hasBoundedHeight ? constraints.maxHeight : wanted.height,
    ));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  Offset _local(Offset global) => globalToLocal(global) + _paintOrigin;

  @override
  void handlePointerEvent(PointerEvent event) {
    switch (event) {
      case PointerMoveEvent():
        _input.pointer = _local(event.logicalPosition);
      case PointerDownEvent(button: PointerButton.primary):
        _input
          ..pointer = _local(event.logicalPosition)
          ..down = true
          ..pressed = true;
      case PointerUpEvent(button: PointerButton.primary):
        _input
          ..pointer = _local(event.logicalPosition)
          ..down = false
          ..released = true;
      case PointerCancelEvent():
        _input
          ..down = false
          ..released = true;
      case PointerScrollEvent():
        final double unit =
            event.scrollDeltaUnit == ScrollDeltaUnit.lines ? 40 : 1;
        _input
          ..pointer = _local(event.logicalPosition)
          ..scroll = _input.scroll + event.scrollDelta * unit;
      case PointerDownEvent():
      case PointerUpEvent():
        return;
    }
    markNeedsPaint();
  }

  @override
  void handleHoverChanged(bool hovered) {
    if (hovered) return;
    _input.pointer = null;
    markNeedsPaint();
  }

  /// Keys belong to the focused text field; with none, they go on to the
  /// application's shortcuts.
  @override
  bool handleKeyEvent(KeyEvent event) {
    if (memory.focused == null || event is! KeyDownEvent) return false;
    _input
      ..keys.add(event.logicalKey)
      ..modifiers = event.modifiers;
    markNeedsPaint();
    return true;
  }

  @override
  bool handleTextInput(TextInputEvent event) {
    if (memory.focused == null) return false;
    _input.text.write(event.text);
    markNeedsPaint();
    return true;
  }

  /// One group to assistive technology for now: an immediate frame keeps no
  /// node per control between frames to describe.
  @override
  SemanticsConfiguration describeSemantics() =>
      const SemanticsConfiguration(role: SemanticsRole.generic);

  @override
  void requestKeyboardFocus() =>
      focusNode?.requestFocus(FocusChangeReason.pointer);

  @override
  void paint(DisplayList list, Offset offset) {
    _paintOrigin = offset;
    final Rect region =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    list
      ..save()
      ..clipRect(region.left, region.top, region.right, region.bottom);
    final Ui ui = Ui.frame(
      list: list,
      painter: this,
      input: _input,
      memory: memory,
      region: region,
      lastPointer: _lastPointer,
    );
    var again = false;
    try {
      builder(ui);
      _lastError = null;
    } on Object catch (error) {
      // The frame shows what broke instead of going blank, and keeps going:
      // the next frame may run past it.
      _lastError = error;
      list.drawRectangle(
          region, list.addPaint(colorArgb: const Color(0x33FF0000).value));
    }
    again = ui.finish();
    list.restore();
    final bool hadInput = !_input.isEmpty;
    _lastPointer = _input.pointer;
    _input.endFrame();
    // Input changes state that controls already drawn this frame could not
    // show; one more frame after it lets them.
    if (again || hadInput) _scheduleRepaint();
  }

  void _scheduleRepaint() {
    if (_repaintScheduled) return;
    _repaintScheduled = true;
    scheduleMicrotask(() {
      _repaintScheduled = false;
      if (owner != null) markNeedsPaint();
    });
  }
}
