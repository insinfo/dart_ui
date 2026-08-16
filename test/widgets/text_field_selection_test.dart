/// Selecting text with the mouse, asserted at offsets.
///
/// Every click position here is computed from the laid-out paragraph -
/// `getCaretRect(offset).left` - rather than written as a pixel, because a
/// pixel is a claim about the metrics of one font file. Computing it means the
/// test says what it means: *press where the caret for offset 6 would be*.
///
/// The font is pinned for the same reason it is pinned in `controls_test.dart`:
/// a proportional face makes every one of these coordinates depend on which
/// face was found, and an unpinned test would assert something different on
/// each machine.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('dragging', () {
    test('a drag selects from where it went down to where it let go', () {
      final _Field field = _Field('hello world');

      field
        ..down(0)
        ..move(5)
        ..up(5);

      expect(field.controller.selectionStart, 0);
      expect(field.controller.selectionEnd, 5);
      expect(field.controller.selectedText, 'hello');
      expect(field.controller.editingValue.selection.isReversed, isFalse);
    });

    test('a backwards drag keeps its direction, base after extent', () {
      final _Field field = _Field('hello world');

      field
        ..down(11)
        ..move(6)
        ..up(6);

      // Base and extent as given, not reordered: which end moved is what the
      // next Shift+Left has to know. `selectedText` still reads in order.
      expect(field.controller.selectionStart, 11);
      expect(field.controller.selectionEnd, 6);
      expect(field.controller.editingValue.selection.isReversed, isTrue);
      expect(field.controller.selectedText, 'world');
    });

    test('a drag past either edge selects to that extreme and stops', () {
      final _Field field = _Field('hello world');

      // Far outside the control on both sides. There is no auto-scroll and
      // nothing to scroll, so the selection saturates at the ends of the text
      // rather than growing while the pointer sits there.
      field
        ..down(5)
        ..moveTo(const Offset(10000, 10));
      expect(field.controller.selectionEnd, 11);

      field.moveTo(const Offset(-10000, 10));
      expect(field.controller.selectionEnd, 0);
      expect(field.controller.selectionStart, 5, reason: 'the anchor held');

      field.up(0);
    });

    test('moves after the release no longer extend anything', () {
      final _Field field = _Field('hello world');

      field
        ..down(0)
        ..move(5)
        ..up(5)
        ..moveTo(const Offset(10000, 10));

      expect(field.controller.selectionEnd, 5);
    });

    test('a move with no press does not select', () {
      final _Field field = _Field('hello world')..moveTo(const Offset(60, 10));

      expect(field.controller.hasSelection, isFalse);
    });
  });

  group('Shift+click', () {
    test('extends from the anchor the previous click left behind', () {
      final _Field field = _Field('hello world');

      field
        ..down(6)
        ..up(6);
      expect(field.controller.hasSelection, isFalse);

      field
        ..shiftDown()
        ..down(11)
        ..up(11);

      expect(field.controller.selectionStart, 6);
      expect(field.controller.selectionEnd, 11);
      expect(field.controller.selectedText, 'world');
    });

    test('extends backwards too, and the anchor stays put', () {
      final _Field field = _Field('hello world');

      field
        ..down(6)
        ..up(6)
        ..shiftDown()
        ..down(0)
        ..up(0);

      expect(field.controller.selectionStart, 6);
      expect(field.controller.selectionEnd, 0);
      expect(field.controller.selectedText, 'hello ');
    });

    test('a click after Shift is released collapses the caret again', () {
      final _Field field = _Field('hello world');

      field
        ..down(6)
        ..up(6)
        ..shiftDown()
        ..down(11)
        ..up(11)
        ..shiftUp()
        ..down(0)
        ..up(0);

      expect(field.controller.hasSelection, isFalse);
      expect(field.controller.selectionEnd, 0);
    });
  });

  group('double and triple click', () {
    test('a double click selects the word under it, not the punctuation', () {
      // `ola` + U+0301 COMBINING ACUTE ACCENT: the accent is part of the word
      // segment and of the grapheme cluster, so the selection is four code
      // units and the comma is not in it.
      final _Field field = _Field('olá, mundo');

      field.doubleClickBetween(1, 2);

      expect(field.controller.selectionStart, 0);
      expect(field.controller.selectionEnd, 4);
      expect(field.controller.selectedText, 'olá');
    });

    test('a double click on the second word takes only that word', () {
      final _Field field = _Field('olá, mundo');

      field.doubleClickBetween(7, 8);

      expect(field.controller.selectionStart, 6);
      expect(field.controller.selectionEnd, 11);
      expect(field.controller.selectedText, 'mundo');
    });

    test('a triple click selects the whole value', () {
      final _Field field = _Field('olá, mundo');

      field
        ..doubleClickBetween(7, 8)
        ..clickAgain(_Field.tripleAt);

      expect(field.controller.selectionStart, 0);
      expect(field.controller.selectionEnd, 11);
      expect(field.controller.selectedText, 'olá, mundo');
    });

    test('a fourth click starts the cycle over at one', () {
      final _Field field = _Field('hello world');

      field
        ..doubleClickBetween(1, 2)
        ..clickAgain(_Field.tripleAt)
        ..clickAgain(_Field.fourthAt);

      // Back to a plain click: a caret, not a selection.
      expect(field.controller.hasSelection, isFalse);
    });

    test('two clicks far apart are two clicks, however fast', () {
      final _Field field = _Field('hello world')
        ..down(0, at: Duration.zero)
        ..up(0, at: Duration.zero)
        // Same instant, but eleven logical units away - past the slop.
        ..downAt(const Offset(90, 10), at: Duration.zero)
        ..upAt(const Offset(90, 10), at: Duration.zero);

      expect(field.controller.hasSelection, isFalse);
    });

    test('two clicks far apart in time are two clicks, however close', () {
      final _Field field = _Field('hello world')
        ..down(2, at: Duration.zero)
        ..up(2, at: Duration.zero)
        ..down(2, at: const Duration(milliseconds: 501))
        ..up(2, at: const Duration(milliseconds: 501));

      expect(field.controller.hasSelection, isFalse);
      expect(field.controller.selectionEnd, 2);
    });
  });

  group('the word a double click selects', () {
    test('is the UAX #29 segment, with the tie at a boundary going right', () {
      expect(TextMotion.wordAt('hello world', 2), const TextRange(0, 5));
      expect(TextMotion.wordAt('hello world', 0), const TextRange(0, 5));
      // Offset 5 is a boundary: the segment that *starts* there is the space.
      expect(TextMotion.wordAt('hello world', 5), const TextRange(5, 6));
      expect(TextMotion.wordAt('hello world', 7), const TextRange(6, 11));
      // At the very end there is no segment to the right, so the last one.
      expect(TextMotion.wordAt('hello world', 11), const TextRange(6, 11));
      expect(TextMotion.wordAt('', 0), const TextRange(0, 0));
    });

    test('keeps a decomposed accent with its letter', () {
      expect(TextMotion.wordAt('olá, mundo', 1), const TextRange(0, 4));
      expect(TextMotion.wordAt('olá, mundo', 4), const TextRange(4, 5));
    });

    test('is one segment for an emoji, not one per surrogate', () {
      // GRINNING FACE is two code units and one cluster.
      const String text = 'a \u{1F600} b';
      final TextRange word = TextMotion.wordAt(text, 2);
      expect(word.start, 2);
      expect(word.end, 4);
      expect(word.textInside(text), '\u{1F600}');
    });
  });
}

/// A mounted [TextField] with helpers that speak in offsets rather than pixels.
final class _Field {
  _Field(String text) : controller = TextEditingController(text) {
    owner.updateRoot(TextField(controller: controller));
    owner.pipelineOwner.drawFrame(DisplayList());
    render = owner.renderRoot! as RenderTextField;
    owner.requestKeyboardFocus(render);
  }

  /// Timestamps for the second and later clicks of a multi-click. Well inside
  /// the 500 ms window, and identical for every test that uses them.
  static const Duration doubleAt = Duration(milliseconds: 100);
  static const Duration tripleAt = Duration(milliseconds: 200);
  static const Duration fourthAt = Duration(milliseconds: 300);

  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 60))),
  );
  final TextEditingController controller;
  late final RenderTextField render;

  double get _padding => ThemeData.neutralLight.effectiveControlPadding;

  /// Where the caret for [offset] is drawn, in the window's coordinates.
  Offset positionOf(int offset) => Offset(
        render.paragraph!.getCaretRect(TextPosition(offset)).left + _padding,
        10,
      );

  /// Halfway between two caret positions: a point inside a character, which is
  /// where a double click actually lands.
  Offset between(int a, int b) =>
      Offset((positionOf(a).dx + positionOf(b).dx) / 2, 10);

  void down(int offset, {Duration at = Duration.zero}) =>
      downAt(positionOf(offset), at: at);

  void up(int offset, {Duration at = Duration.zero}) =>
      upAt(positionOf(offset), at: at);

  void move(int offset) => moveTo(positionOf(offset));

  void downAt(Offset position, {Duration at = Duration.zero}) =>
      owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: at,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
      ));

  void upAt(Offset position, {Duration at = Duration.zero}) =>
      owner.dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: at,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
      ));

  void moveTo(Offset position, {Duration at = Duration.zero}) =>
      owner.dispatchPointerEvent(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: at,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
      ));

  /// Two clicks at the same point, the second inside the double-click window.
  void doubleClickBetween(int a, int b) {
    _lastClick = between(a, b);
    downAt(_lastClick);
    upAt(_lastClick);
    downAt(_lastClick, at: doubleAt);
    upAt(_lastClick, at: doubleAt);
  }

  /// One more click at the same point, at [at].
  void clickAgain(Duration at) {
    downAt(_lastClick, at: at);
    upAt(_lastClick, at: at);
  }

  /// Presses and holds Shift, as the keyboard would report it.
  ///
  /// A real Shift press is a key event like any other; the field learns the
  /// modifier state from it because pointer events carry none.
  void shiftDown() => render.handleKeyEvent(const KeyDownEvent(
        windowId: NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: 0x10,
        logicalKey: 0x10,
        modifiers: <KeyModifier>{KeyModifier.shift},
      ));

  void shiftUp() => render.handleKeyEvent(const KeyUpEvent(
        windowId: NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: 0x10,
        logicalKey: 0x10,
      ));

  Offset _lastClick = Offset.zero;
}
