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

  group('a double click the platform counted', () {
    // These are the widget half of the double-click fix. The backend half is
    // `test/backends/win32/win32_mouse_input_test.dart`, which proves the
    // second press exists at all; this proves the field believes the count the
    // platform put on it rather than re-deciding with a constant of its own.
    //
    // Why that matters: `GetDoubleClickTime()` is a *user* setting, raised by
    // people whose hands do not manage two clicks in 500 ms. A field that
    // measured the interval itself would silently ignore it, and the person
    // who most needed the setting would be the one it stopped working for.

    test('selects the word even when the field would have timed out', () {
      final _Field field = _Field('hello world')..osDoubleClickBetween(1, 2);

      expect(field.controller.selectedText, 'hello');
      expect(field.controller.selectionStart, 0);
      expect(field.controller.selectionEnd, 5);
    });

    test('stops at the punctuation, in the middle of the value', () {
      // Three seconds after the first press, so nothing but the reported count
      // can be doing the work here.
      final _Field field = _Field('olá, mundo')..osDoubleClickBetween(7, 8);

      expect(field.controller.selectedText, 'mundo');
      expect(field.controller.selectionStart, 6);
      expect(field.controller.selectionEnd, 11);
    });

    test('keeps a decomposed accent with the letter it sits on', () {
      // `ola` + U+0301 COMBINING ACUTE ACCENT: four code units, one word, and
      // the comma is not part of it. A selection that ended at 3 would cut a
      // grapheme cluster in half.
      final _Field field = _Field('olá, mundo')..osDoubleClickBetween(1, 2);

      expect(field.controller.selectionStart, 0);
      expect(field.controller.selectionEnd, 4);
      expect(field.controller.selectedText, 'olá');
    });

    test('takes a whole emoji, not one of its surrogates', () {
      // GRINNING FACE is two code units and one segment. Selecting 2..3 would
      // be half a character, which `TextEditingValue` refuses outright.
      final _Field field = _Field('a \u{1F600} b')..osDoubleClickBetween(2, 4);

      expect(field.controller.selectionStart, 2);
      expect(field.controller.selectionEnd, 4);
      expect(field.controller.selectedText, '\u{1F600}');
    });

    test('a platform double click still cycles back on the fourth', () {
      final _Field field = _Field('hello world')
        ..osDoubleClickBetween(1, 2)
        // Third: no platform count, inside the fallback window.
        ..clickAgainAt(const Duration(seconds: 3, milliseconds: 100))
        // Fourth: the platform counted this pair too, and four clicks start
        // over at one - which is what Windows itself does.
        ..clickAgainAt(
          const Duration(seconds: 3, milliseconds: 200),
          clickCount: 2,
        );

      expect(field.controller.hasSelection, isFalse);
    });

    test('a third click after a platform double selects the whole value', () {
      final _Field field = _Field('olá, mundo')
        ..osDoubleClickBetween(7, 8)
        ..clickAgainAt(const Duration(seconds: 3, milliseconds: 100));

      expect(field.controller.selectionStart, 0);
      expect(field.controller.selectionEnd, 11);
      expect(field.controller.selectedText, 'olá, mundo');
    });

    test('a press with no reported count is still measured by the field', () {
      // The fallback has to keep working: X11 reports no count at all, and a
      // field that only believed a platform count would never double click
      // there.
      final _Field field = _Field('hello world')..doubleClickBetween(7, 8);

      expect(field.controller.selectedText, 'world');
    });
  });

  group('a selection in a field that lost the keyboard', () {
    // The reported bug: clicking into a second field left the first one still
    // painting its selection at full strength, so two fields looked selected
    // at once and nothing on screen said which one a keystroke would reach.
    // The caret already checked `hasFocus`; the selection did not.
    //
    // The policy is *dimmed, not hidden* - what Windows and macOS do - so the
    // range stays visible for the select-then-click-a-toolbar-button flow, and
    // the controller is never touched.

    test('is not painted in the active selection colour', () {
      final _TwoFields fields = _TwoFields('hello world', 'second field')
        ..doubleClickFirst()
        ..clickSecond();

      final DisplayList list = fields.paint();
      expect(
        _rectsWithColor(list, ThemeData.neutralLight.selection),
        isEmpty,
        reason: 'the field that has the keyboard has no selection, and the '
            'field that has a selection does not have the keyboard',
      );
    });

    test('is still painted, in a colour between selection and surface', () {
      final _TwoFields fields = _TwoFields('hello world', 'second field')
        ..doubleClickFirst()
        ..clickSecond();

      final DisplayList list = fields.paint();
      final int dimmed = _dimmed(ThemeData.neutralLight);
      expect(
        _rectsWithColor(list, dimmed),
        isNotEmpty,
        reason: 'hiding the range would lose what a formatting command would '
            'apply to',
      );
    });

    test('the controller still holds the range, unchanged', () {
      final _TwoFields fields = _TwoFields('hello world', 'second field')
        ..doubleClickFirst();

      final int start = fields.firstController.selectionStart;
      final int end = fields.firstController.selectionEnd;
      expect(fields.firstController.selectedText, 'hello');

      fields.clickSecond();

      expect(fields.firstController.selectionStart, start);
      expect(fields.firstController.selectionEnd, end);
      expect(
        fields.firstController.selectedText,
        'hello',
        reason: 'losing the range on focus loss would break selecting text and '
            'then clicking a button that acts on it',
      );
    });

    test('comes back to full strength when the field is clicked again', () {
      final _TwoFields fields = _TwoFields('hello world', 'second field')
        ..doubleClickFirst()
        ..clickSecond()
        ..doubleClickFirst();

      final DisplayList list = fields.paint();
      expect(
          _rectsWithColor(list, ThemeData.neutralLight.selection), isNotEmpty);
      expect(_rectsWithColor(list, _dimmed(ThemeData.neutralLight)), isEmpty);
    });

    test('the focused field paints a caret and the other does not', () {
      // The other half of the same signal, asserted so the two cannot drift:
      // exactly one field shows a caret at any time.
      final _TwoFields fields = _TwoFields('hello world', 'second field')
        ..doubleClickFirst()
        ..clickSecond();

      final DisplayList list = fields.paint();
      final List<DrawRectCommand> carets =
          _rectsWithColor(list, ThemeData.neutralLight.foreground)
              .where((DrawRectCommand rect) => rect.right - rect.left == 1)
              .toList();
      expect(carets, hasLength(1));
      // And it is in the second field, which is the one below.
      expect(carets.single.top, greaterThan(fields.second.size.height / 2));
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

  void downAt(
    Offset position, {
    Duration at = Duration.zero,
    int clickCount = 1,
  }) =>
      owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: at,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
        clickCount: clickCount,
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

  /// One more click at the same point, at [at], optionally carrying the count
  /// the platform put on it.
  void clickAgainAt(Duration at, {int clickCount = 1}) {
    downAt(_lastClick, at: at, clickCount: clickCount);
    upAt(_lastClick, at: at);
  }

  /// Two clicks at one point where the **platform** reported the second as the
  /// second, which is what a Win32 `WM_LBUTTONDBLCLK` arrives as.
  ///
  /// The timestamps are deliberately far enough apart that the field's own
  /// 500 ms fallback would call them two separate clicks: the point of the
  /// case is that the platform's answer, made with the user's configured
  /// interval, is the one that decides.
  void osDoubleClickBetween(int a, int b) {
    _lastClick = between(a, b);
    downAt(_lastClick);
    upAt(_lastClick);
    downAt(_lastClick, at: const Duration(seconds: 3), clickCount: 2);
    upAt(_lastClick, at: const Duration(seconds: 3));
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

/// Two stacked [TextField]s in one tree, so focus can move between them.
///
/// One [BuildOwner] rather than two, because focus is per owner: two owners
/// would each have their own focused control and the case under test - one
/// field losing the keyboard to another - could not happen at all.
final class _TwoFields {
  _TwoFields(String first, String second)
      : firstController = TextEditingController(first),
        secondController = TextEditingController(second) {
    owner.updateRoot(
      Column(
        children: <Widget>[
          TextField(controller: firstController),
          TextField(controller: secondController),
        ],
      ),
    );
    owner.pipelineOwner.drawFrame(DisplayList());

    final List<RenderTextField> found = <RenderTextField>[];
    void walk(RenderBox node) {
      if (node is RenderTextField) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    expect(found, hasLength(2));
    this.first = found.first;
    this.second = found.last;
  }

  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(220, 120)),
    ),
  );
  final TextEditingController firstController;
  final TextEditingController secondController;
  late final RenderTextField first;
  late final RenderTextField second;

  /// A fresh frame, so the assertions read what the *current* focus paints.
  DisplayList paint() {
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);
    return list;
  }

  /// Double clicks inside the first word of the top field, which both focuses
  /// it - a press requests focus, as it does in a real window - and selects.
  void doubleClickFirst() {
    final Offset at = _inside(first, 1, 2);
    _down(at, Duration.zero);
    _up(at);
    _down(at, const Duration(milliseconds: 100));
    _up(at);
  }

  /// One click in the bottom field: the keyboard moves, and nothing tells the
  /// first field to throw its selection away.
  void clickSecond() {
    final Offset at = _inside(second, 0, 1);
    _down(at, const Duration(seconds: 5));
    _up(at);
  }

  /// A point between the carets for [a] and [b] of [field], in the owner's
  /// coordinates - computed rather than written down, for the reason at the
  /// top of this file.
  Offset _inside(RenderTextField field, int a, int b) {
    final double padding = ThemeData.neutralLight.effectiveControlPadding;
    double caret(int offset) =>
        field.paragraph!.getCaretRect(TextPosition(offset)).left;
    return field.localToGlobal(
      Offset(padding + (caret(a) + caret(b)) / 2, field.size.height / 2),
    );
  }

  void _down(Offset at, Duration timestamp) =>
      owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: timestamp,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: PointerButton.primary,
      ));

  void _up(Offset at) => owner.dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: PointerButton.primary,
      ));
}

/// The unfocused selection colour: half way between the theme's selection and
/// the field's own fill, per channel.
///
/// Recomputed here rather than read off the render object, so the test states
/// the policy instead of echoing whatever the implementation happens to do.
int _dimmed(ThemeData theme) {
  int mix(int shift) =>
      (((theme.selection >> shift) & 0xFF) +
          ((theme.surfaceAlternate >> shift) & 0xFF)) ~/
      2;
  return (((theme.selection >> 24) & 0xFF) << 24) |
      (mix(16) << 16) |
      (mix(8) << 8) |
      mix(0);
}

List<DrawRectCommand> _rectsWithColor(DisplayList list, int color) =>
    expandDisplayList(list)
        .whereType<DrawRectCommand>()
        .where((DrawRectCommand rect) => list.paintColor(rect.paintId) == color)
        .toList();
