import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

import 'drum_kit.dart';

typedef PadTriggered = void Function(int pad, double velocity);

final class DrumPadGrid extends StatefulWidget {
  const DrumPadGrid({super.key, required this.onTriggered});

  final PadTriggered onTriggered;

  @override
  State<DrumPadGrid> createState() => _DrumPadGridState();
}

final class _DrumPadGridState extends State<DrumPadGrid> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Drum pad grid');
  final Set<int> _activePads = <int>{};
  final Map<int, Timer> _flashTimers = <int, Timer>{};

  void _trigger(int pad) {
    widget.onTriggered(pad, 1);
    _flashTimers.remove(pad)?.cancel();
    setState(() => _activePads.add(pad));
    _flashTimers[pad] = Timer(const Duration(milliseconds: 105), () {
      _flashTimers.remove(pad);
      if (mounted) setState(() => _activePads.remove(pad));
    });
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.isRepeat) return false;
    for (int pad = 0; pad < drumKit.length; pad++) {
      if (drumKit[pad].logicalKey == event.logicalKey) {
        _trigger(pad);
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        autofocus: true,
        child: _DrumPadGridLeaf(
          activePads: Set<int>.unmodifiable(_activePads),
          onTriggered: _trigger,
          onKeyEvent: _handleKey,
          theme: Theme.of(context),
          focusNode: _focusNode,
        ),
      );

  @override
  void dispose() {
    for (final Timer timer in _flashTimers.values) {
      timer.cancel();
    }
    _flashTimers.clear();
    _focusNode.dispose();
    super.dispose();
  }
}

final class _DrumPadGridLeaf extends RenderObjectWidget {
  const _DrumPadGridLeaf({
    required this.activePads,
    required this.onTriggered,
    required this.onKeyEvent,
    required this.theme,
    required this.focusNode,
  });

  final Set<int> activePads;
  final void Function(int pad) onTriggered;
  final bool Function(KeyEvent event) onKeyEvent;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderDrumPadGrid createRenderObject(BuildContext context) =>
      RenderDrumPadGrid(
        activePads: activePads,
        onTriggered: onTriggered,
        onKeyEvent: onKeyEvent,
      )
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDrumPadGrid object,
  ) {
    object
      ..activePads = activePads
      ..onTriggered = onTriggered
      ..onKeyEvent = onKeyEvent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

final class RenderDrumPadGrid extends RenderBox with ControlBehavior {
  RenderDrumPadGrid({
    required Set<int> activePads,
    required this.onTriggered,
    required this.onKeyEvent,
  }) : _activePads = activePads;

  Set<int> _activePads;
  void Function(int pad) onTriggered;
  bool Function(KeyEvent event) onKeyEvent;
  final Map<int, int> _pointerPads = <int, int>{};

  set activePads(Set<int> value) {
    _activePads = value;
    markNeedsPaint();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool handleKeyEvent(KeyEvent event) => onKeyEvent(event);

  @override
  void handlePointerEvent(PointerEvent event) {
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        focusNode?.requestFocus(FocusChangeReason.pointer);
        final int? pad = _padAt(globalToLocal(event.logicalPosition));
        if (pad != null) {
          _pointerPads[event.pointerId] = pad;
          onTriggered(pad);
        }
      case PointerMoveEvent():
        final int? previous = _pointerPads[event.pointerId];
        if (previous == null) return;
        final int? pad = _padAt(globalToLocal(event.logicalPosition));
        if (pad == null) {
          _pointerPads.remove(event.pointerId);
        } else if (pad != previous) {
          _pointerPads[event.pointerId] = pad;
          onTriggered(pad);
        }
      case PointerUpEvent():
        _pointerPads.remove(event.pointerId);
      case PointerCancelEvent():
        _pointerPads.remove(event.pointerId);
      case PointerScrollEvent():
      case PointerDownEvent():
    }
  }

  int get _columns => size.width < 720 ? 3 : 4;
  int get _rows => (drumKit.length / _columns).ceil();

  int? _padAt(Offset local) {
    if (!size.contains(local)) return null;
    const double gap = 12;
    final double padWidth = (size.width - gap * (_columns - 1)) / _columns;
    final double padHeight = (size.height - gap * (_rows - 1)) / _rows;
    final int column = (local.dx / (padWidth + gap)).floor();
    final int row = (local.dy / (padHeight + gap)).floor();
    if (column < 0 || column >= _columns || row < 0 || row >= _rows) {
      return null;
    }
    final Rect rect = Rect.fromLTWH(
      column * (padWidth + gap),
      row * (padHeight + gap),
      padWidth,
      padHeight,
    );
    if (!rect.contains(local)) return null;
    final int pad = row * _columns + column;
    return pad < drumKit.length ? pad : null;
  }

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.constrainWidth(920);
    final double height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : constraints.constrainHeight(360);
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(DisplayList list, Offset offset) {
    const double gap = 12;
    final double padWidth = (size.width - gap * (_columns - 1)) / _columns;
    final double padHeight = (size.height - gap * (_rows - 1)) / _rows;
    for (int pad = 0; pad < drumKit.length; pad++) {
      final int row = pad ~/ _columns;
      final int column = pad % _columns;
      final Rect rect = Rect.fromLTWH(
        offset.dx + column * (padWidth + gap),
        offset.dy + row * (padHeight + gap),
        padWidth,
        padHeight,
      );
      final DrumPadSpec spec = drumKit[pad];
      final Color accent = Color(spec.color);
      final bool active = _activePads.contains(pad);
      paintRoundedFill(
        list,
        rect,
        active ? accent : const Color(0xFF111F32),
        12,
      );
      paintRoundedBorder(
        list,
        rect,
        active ? const Color(0xFFFFFFFF) : const Color(0xFF223650),
        12,
        width: active ? 2 : 1,
      );
      paintRoundedFill(
        list,
        Rect.fromLTWH(rect.left + 14, rect.top + 13, 34, 4),
        accent,
        2,
      );
      paintLabel(
        list,
        spec.name,
        Offset(rect.left + 14, rect.top + 28),
        active ? const Color(0xFF07111F) : const Color(0xFFF4F8FF),
        maxWidth: rect.width - 72,
      );
      paintLabel(
        list,
        spec.subtitle,
        Offset(rect.left + 14, rect.top + 54),
        active ? const Color(0xFF18283A) : const Color(0xFF91A4BE),
        maxWidth: rect.width - 28,
      );
      final Rect key = Rect.fromLTWH(rect.right - 44, rect.top + 16, 28, 28);
      paintRoundedFill(
        list,
        key,
        active ? const Color(0x3307111F) : const Color(0xFF1C2D44),
        6,
      );
      paintCenteredLabel(
        list,
        spec.keyLabel,
        key,
        active ? const Color(0xFF07111F) : accent,
      );
    }
    paintFocusRing(
      list,
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      radius: 12,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.generic,
        label: 'Bateria digital com doze pads',
        states: <SemanticsState>{if (hasFocus) SemanticsState.focused},
        actions: const <SemanticsAction>{SemanticsAction.focus},
      );
}
