import 'package:dart_ui/dart_ui.dart';

typedef NoteChanged = void Function(int note, bool pressed);

const Map<int, int> _logicalKeyToNote = <int, int>{
  0x5A: 0, // Z
  0x53: 1, // S
  0x58: 2, // X
  0x44: 3, // D
  0x43: 4, // C
  0x56: 5, // V
  0x47: 6, // G
  0x42: 7, // B
  0x48: 8, // H
  0x4E: 9, // N
  0x4A: 10, // J
  0x4D: 11, // M
  0x51: 12, // Q
  0x32: 13, // 2
  0x57: 14, // W
  0x33: 15, // 3
  0x45: 16, // E
  0x52: 17, // R
  0x35: 18, // 5
  0x54: 19, // T
  0x36: 20, // 6
  0x59: 21, // Y
  0x37: 22, // 7
  0x55: 23, // U
};

const List<String> _keyLabels = <String>[
  'Z', 'S', 'X', 'D', 'C', 'V', 'G', 'B', 'H', 'N', 'J', 'M',
  'Q', '2', 'W', '3', 'E', 'R', '5', 'T', '6', 'Y', '7', 'U',
];

const List<int> _whiteNotes = <int>[
  0, 2, 4, 5, 7, 9, 11,
  12, 14, 16, 17, 19, 21, 23,
];

const List<int> _blackNotes = <int>[
  1, 3, 6, 8, 10,
  13, 15, 18, 20, 22,
];

const List<int> _blackAfterWhite = <int>[
  1, 2, 4, 5, 6,
  8, 9, 11, 12, 13,
];

final class PianoKeyboard extends StatefulWidget {
  const PianoKeyboard({super.key, required this.onNoteChanged});

  final NoteChanged onNoteChanged;

  @override
  State<PianoKeyboard> createState() => _PianoKeyboardState();
}

final class _PianoKeyboardState extends State<PianoKeyboard> {
  late final FocusNode _focusNode =
      FocusNode(debugLabel: 'Realtime piano keyboard')
        ..addListener(_focusChanged);
  final Map<int, int> _holdCounts = <int, int>{};
  final Set<int> _physicalKeys = <int>{};

  void _focusChanged(FocusNode node) {
    if (!node.hasPrimaryFocus) _releasePhysicalKeys();
    if (mounted) setState(() {});
  }

  bool _handleKey(KeyEvent event) {
    final int? note = _logicalKeyToNote[event.logicalKey];
    if (note == null) return false;
    if (event is KeyDownEvent) {
      if (!event.isRepeat && _physicalKeys.add(event.logicalKey)) {
        _acquire(note);
      }
      return true;
    }
    if (event is KeyUpEvent && _physicalKeys.remove(event.logicalKey)) {
      _release(note);
      return true;
    }
    return false;
  }

  void _pointerNote(int note, bool pressed) {
    if (pressed) {
      _acquire(note);
    } else {
      _release(note);
    }
  }

  void _acquire(int note) {
    final int count = _holdCounts[note] ?? 0;
    _holdCounts[note] = count + 1;
    if (count == 0) widget.onNoteChanged(note, true);
    if (mounted) setState(() {});
  }

  void _release(int note) {
    final int count = _holdCounts[note] ?? 0;
    if (count <= 1) {
      _holdCounts.remove(note);
      if (count == 1) widget.onNoteChanged(note, false);
    } else {
      _holdCounts[note] = count - 1;
    }
    if (mounted) setState(() {});
  }

  void _releasePhysicalKeys() {
    for (final int logicalKey in _physicalKeys) {
      final int? note = _logicalKeyToNote[logicalKey];
      if (note != null) _release(note);
    }
    _physicalKeys.clear();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        autofocus: true,
        child: _PianoKeyboardLeaf(
          activeNotes: Set<int>.unmodifiable(_holdCounts.keys),
          onNoteChanged: _pointerNote,
          onKeyEvent: _handleKey,
          theme: Theme.of(context),
          focusNode: _focusNode,
        ),
      );

  @override
  void dispose() {
    for (final int note in _holdCounts.keys) {
      widget.onNoteChanged(note, false);
    }
    _holdCounts.clear();
    _physicalKeys.clear();
    _focusNode
      ..removeListener(_focusChanged)
      ..dispose();
    super.dispose();
  }
}

final class _PianoKeyboardLeaf extends RenderObjectWidget {
  const _PianoKeyboardLeaf({
    required this.activeNotes,
    required this.onNoteChanged,
    required this.onKeyEvent,
    required this.theme,
    required this.focusNode,
  });

  final Set<int> activeNotes;
  final NoteChanged onNoteChanged;
  final bool Function(KeyEvent event) onKeyEvent;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderPianoKeyboard createRenderObject(BuildContext context) =>
      RenderPianoKeyboard(
        activeNotes: activeNotes,
        onNoteChanged: onNoteChanged,
        onKeyEvent: onKeyEvent,
      )
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderPianoKeyboard object,
  ) {
    object
      ..activeNotes = activeNotes
      ..onNoteChanged = onNoteChanged
      ..onKeyEvent = onKeyEvent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

final class RenderPianoKeyboard extends RenderBox with ControlBehavior {
  RenderPianoKeyboard({
    required Set<int> activeNotes,
    required this.onNoteChanged,
    required this.onKeyEvent,
  }) : _activeNotes = activeNotes;

  Set<int> _activeNotes;
  NoteChanged onNoteChanged;
  bool Function(KeyEvent event) onKeyEvent;
  final Map<int, int> _pointerNotes = <int, int>{};

  set activeNotes(Set<int> value) {
    _activeNotes = value;
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
        final int? note = _noteAt(globalToLocal(event.logicalPosition));
        if (note != null) {
          _pointerNotes[event.pointerId] = note;
          onNoteChanged(note, true);
        }
      case PointerMoveEvent():
        final int? previous = _pointerNotes[event.pointerId];
        if (previous == null) return;
        final int? next = _noteAt(globalToLocal(event.logicalPosition));
        if (next == previous) return;
        onNoteChanged(previous, false);
        if (next == null) {
          _pointerNotes.remove(event.pointerId);
        } else {
          _pointerNotes[event.pointerId] = next;
          onNoteChanged(next, true);
        }
      case PointerUpEvent():
        final int? note = _pointerNotes.remove(event.pointerId);
        if (note != null) onNoteChanged(note, false);
      case PointerCancelEvent():
        final int? note = _pointerNotes.remove(event.pointerId);
        if (note != null) onNoteChanged(note, false);
      case PointerScrollEvent():
      case PointerDownEvent():
    }
  }

  int? _noteAt(Offset local) {
    if (!size.contains(local)) return null;
    final double whiteWidth = size.width / _whiteNotes.length;
    final double blackWidth = whiteWidth * 0.62;
    if (local.dy <= size.height * 0.62) {
      for (int index = 0; index < _blackNotes.length; index++) {
        final double center = _blackAfterWhite[index] * whiteWidth;
        if (local.dx >= center - blackWidth / 2 &&
            local.dx <= center + blackWidth / 2) {
          return _blackNotes[index];
        }
      }
    }
    int white = (local.dx / whiteWidth).floor();
    if (white < 0) white = 0;
    if (white >= _whiteNotes.length) white = _whiteNotes.length - 1;
    return _whiteNotes[white];
  }

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.constrainWidth(900);
    final double height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : constraints.constrainHeight(280);
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final double whiteWidth = size.width / _whiteNotes.length;
    final double blackWidth = whiteWidth * 0.62;
    final double blackHeight = size.height * 0.62;
    final int border = list.addPaint(
      colorArgb: const Color(0xFF18263B).value,
      antiAlias: false,
    );
    for (int index = 0; index < _whiteNotes.length; index++) {
      final int note = _whiteNotes[index];
      final Rect rect = Rect.fromLTWH(
        offset.dx + index * whiteWidth,
        offset.dy,
        whiteWidth,
        size.height,
      );
      paintFill(
        list,
        rect,
        _activeNotes.contains(note)
            ? const Color(0xFF73A7FF)
            : const Color(0xFFF5F7FB),
      );
      list.drawRect(rect.right - 1, rect.top, rect.right, rect.bottom, border);
      paintLabel(
        list,
        _keyLabels[note],
        Offset(rect.left + whiteWidth * 0.42, rect.bottom - 30),
        const Color(0xFF172033),
        maxWidth: whiteWidth * 0.5,
      );
    }
    for (int index = 0; index < _blackNotes.length; index++) {
      final int note = _blackNotes[index];
      final double center = offset.dx + _blackAfterWhite[index] * whiteWidth;
      final Rect rect = Rect.fromLTWH(
        center - blackWidth / 2,
        offset.dy,
        blackWidth,
        blackHeight,
      );
      paintRoundedFill(
        list,
        rect,
        _activeNotes.contains(note)
            ? const Color(0xFF2E8CFF)
            : const Color(0xFF101827),
        4,
      );
      paintLabel(
        list,
        _keyLabels[note],
        Offset(rect.left + blackWidth * 0.36, rect.bottom - 27),
        const Color(0xFFF4F8FF),
        maxWidth: blackWidth * 0.55,
      );
    }
    paintFocusRing(
      list,
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      radius: 3,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.generic,
        label: 'Teclado musical de duas oitavas',
        states: <SemanticsState>{
          if (hasFocus) SemanticsState.focused,
        },
        actions: const <SemanticsAction>{SemanticsAction.focus},
      );
}
