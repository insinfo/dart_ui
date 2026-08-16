/// Text editing, asserted at offsets rather than at "it did not throw".
///
/// Every string here is written with explicit `\u` escapes for anything above
/// ASCII. A test that relies on the editor it was typed in having stored `á`
/// decomposed rather than precomposed is a test that changes meaning when
/// somebody reformats the file, and the whole point of these cases is *which*
/// encoding is present.
///
/// The four shapes that break a code-unit caret, and their exact lengths:
///
///  * `\u{1F600}` GRINNING FACE - one code point, **two** code units.
///  * `\u{1F468}‍\u{1F469}‍\u{1F467}` family - five code points,
///    **eight** code units, one cluster held together by GB11.
///  * `\u{1F1E7}\u{1F1F7}` the flag of Brazil - two regional indicators, **four**
///    code units, one cluster by GB12/GB13. Two flags in a row are two
///    clusters, not one blob, which is the rule's parity condition.
///  * `á` decomposed a-acute - two code points, **two** code units, one
///    cluster by GB9.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// GRINNING FACE: the surrogate-pair case.
const String _emoji = '\u{1F600}';

/// A ZWJ family: five emoji code points joined into one cluster.
const String _family = '\u{1F468}‍\u{1F469}‍\u{1F467}';

/// The flag of Brazil: two regional indicators.
const String _flagBR = '\u{1F1E7}\u{1F1F7}';

/// The flag of Japan, so a pair of flags can prove the parity rule.
const String _flagJP = '\u{1F1EF}\u{1F1F5}';

/// Decomposed a-acute.
const String _aAcute = 'á';

/// Two Hebrew letters: strong right-to-left, for the bidi cases.
const String _hebrew = 'אב';

void main() {
  group('the caret moves by grapheme cluster, not by code unit', () {
    test('an astral emoji is one step and one backspace', () {
      // 'a' + emoji + 'b' is four code units and three clusters. A code-unit
      // caret needed two presses to cross the emoji and landed between the
      // surrogates on the way.
      final controller = TextEditingController('a$_emoji' 'b');
      expect(controller.value.length, 4);

      expect(controller.selectionEnd, 4, reason: 'starts at the end');
      controller.moveCaret(-1);
      expect(controller.selectionEnd, 3);
      controller.moveCaret(-1);
      expect(controller.selectionEnd, 1, reason: 'skipped the whole pair');
      controller.moveCaret(-1);
      expect(controller.selectionEnd, 0);

      controller.moveCaret(2);
      expect(controller.selectionEnd, 3);

      controller.moveCaretToEnd();
      controller.deleteBackward();
      expect(controller.value, 'a$_emoji');
      controller.deleteBackward();
      expect(
        controller.value,
        'a',
        reason: 'the whole emoji went, not one surrogate',
      );
      expect(controller.selectionEnd, 1);
    });

    test('deleting forward over an emoji takes both surrogates', () {
      final controller = TextEditingController('$_emoji' 'z')..collapseTo(0);

      controller.deleteForward();

      expect(controller.value, 'z');
      expect(controller.selectionEnd, 0);
    });

    test('a ZWJ family is one cluster of eight code units', () {
      final controller = TextEditingController('x${_family}y');
      expect(controller.value.length, 10);

      controller.collapseTo(9);
      controller.deleteBackward();

      expect(
        controller.value,
        'xy',
        reason: 'all five code points and both joiners went together',
      );
      expect(controller.selectionEnd, 1);
    });

    test('a flag is one cluster and two flags are two', () {
      final controller = TextEditingController('$_flagBR$_flagJP');
      expect(controller.value.length, 8);

      controller.moveCaretToEnd();
      expect(controller.selectionEnd, 8);
      controller.moveCaret(-1);
      expect(
        controller.selectionEnd,
        4,
        reason: 'GB12/GB13 pair the indicators, so a run of four is two flags',
      );

      controller.moveCaretToEnd();
      controller.deleteBackward();
      expect(controller.value, _flagBR, reason: 'one flag, not one indicator');
      controller.deleteBackward();
      expect(controller.value, '');
    });

    test('decomposed a-acute loses its accent with its letter', () {
      final controller = TextEditingController('m${_aAcute}s');
      expect(controller.value.length, 4);

      controller.collapseTo(3);
      controller.deleteBackward();

      expect(
        controller.value,
        'ms',
        reason: 'deleting only U+0301 would leave the accent on the m',
      );
      expect(controller.selectionEnd, 1);
    });

    test('moveCaret takes a cluster count, so -3 is three presses', () {
      final controller = TextEditingController('$_emoji$_flagBR$_aAcute');
      expect(controller.value.length, 8);

      controller.moveCaretToEnd();
      controller.moveCaret(-3);

      expect(controller.selectionEnd, 0);
    });

    test('shift-arrow extends by a cluster and keeps its anchor', () {
      final controller = TextEditingController('a$_family');
      controller.collapseTo(1);

      controller.moveCaret(1, extend: true);

      expect(controller.selectionStart, 1, reason: 'the anchor did not move');
      expect(controller.selectionEnd, 9);
      expect(controller.selectedText, _family);
    });
  });

  group('word motion', () {
    // Punctuation, a decimal number and an underscore identifier, because each
    // is a rule a "split on spaces" implementation gets wrong: WB6/WB7 hold
    // `3.14` together, WB13a holds `gamma_delta` together, and the comma is its
    // own segment rather than part of the word before it.
    const String text = 'alpha, beta 3.14 gamma_delta';

    test('Ctrl+Right stops at each segment and skips the spaces', () {
      final controller = TextEditingController(text)..collapseTo(0);
      expect(text.length, 28);

      final stops = <int>[];
      while (controller.selectionEnd < text.length) {
        controller.moveCaretByWord(1);
        stops.add(controller.selectionEnd);
      }

      expect(stops, <int>[5, 7, 12, 17, 28]);
      expect(text.substring(5, 6), ',');
      expect(text.substring(12, 16), '3.14');
      expect(text.substring(17, 28), 'gamma_delta');
    });

    test('Ctrl+Left walks back over the same stops', () {
      final controller = TextEditingController(text)..moveCaretToEnd();

      final stops = <int>[];
      while (controller.selectionEnd > 0) {
        controller.moveCaretByWord(-1);
        stops.add(controller.selectionEnd);
      }

      expect(stops, <int>[17, 12, 7, 5, 0]);
    });

    test('a word step never lands inside a cluster', () {
      // `WordBreaks` has its own regional-indicator parity rule, so a pair of
      // flags is one segment as well as one cluster.
      final controller = TextEditingController('$_flagBR $_flagJP')
        ..collapseTo(0);

      controller.moveCaretByWord(1);
      expect(controller.selectionEnd, 5, reason: 'past the flag and the space');
      controller.moveCaretByWord(1);
      expect(controller.selectionEnd, 9);
    });

    test('Ctrl+Shift+Left extends without moving the anchor', () {
      final controller = TextEditingController(text)..moveCaretToEnd();

      controller.moveCaretByWord(-1, extend: true);

      expect(controller.selectionStart, 28);
      expect(controller.selectionEnd, 17);
      expect(controller.selectedText, 'gamma_delta');
      expect(controller.hasSelection, isTrue);
    });

    test('direction zero is not read as a step in some direction', () {
      final controller = TextEditingController(text)..collapseTo(7);

      controller.moveCaretByWord(0);

      expect(controller.selectionEnd, 7);
    });
  });

  group('word deletion', () {
    const String text = 'alpha, beta 3.14 gamma_delta';

    test('Ctrl+Backspace at the end removes the last word', () {
      final controller = TextEditingController(text)..moveCaretToEnd();

      controller.deleteWordBackward();

      expect(controller.value, 'alpha, beta 3.14 ');
      expect(controller.selectionEnd, 17);
      expect(controller.canUndo, isTrue);
    });

    test('Ctrl+Backspace takes the whitespace in front of the word with it',
        () {
      final controller = TextEditingController('one two')..moveCaretToEnd();

      controller
        ..deleteWordBackward()
        ..deleteWordBackward();

      expect(controller.value, '', reason: 'the space went with "two"');
      expect(controller.selectionEnd, 0);
    });

    test('Ctrl+Backspace at offset zero does nothing at all', () {
      final controller = TextEditingController(text)..collapseTo(0);

      controller.deleteWordBackward();

      expect(controller.value, text);
      expect(controller.selectionEnd, 0);
      expect(
        controller.canUndo,
        isFalse,
        reason: 'a no-op edit must not fill the undo stack',
      );
    });

    test('Ctrl+Delete at the end does nothing, and at the start eats a word',
        () {
      final controller = TextEditingController(text)..moveCaretToEnd();
      controller.deleteWordForward();
      expect(controller.value, text);
      expect(controller.canUndo, isFalse);

      controller.collapseTo(0);
      controller.deleteWordForward();
      expect(controller.value, ', beta 3.14 gamma_delta');
      expect(controller.selectionEnd, 0);
    });

    test('word deletion over a family emoji removes the whole cluster', () {
      final controller = TextEditingController('hi $_family')..moveCaretToEnd();

      controller.deleteWordBackward();

      // The space stays: the segment immediately behind the caret is the family
      // itself, so there is no whitespace between the caret and the word being
      // deleted. Skipping blanks happens on the way *to* a word, not after it.
      expect(controller.value, 'hi ');
      expect(controller.selectionEnd, 3);
    });

    test('word deletion replaces the selection when there is one', () {
      final controller = TextEditingController('alpha beta')
        ..setSelection(0, 5);

      controller.deleteWordBackward();

      expect(controller.value, ' beta');
      expect(controller.selectionEnd, 0);
    });
  });

  group('TextEditingValue invariants', () {
    test('a selection offset past the end is refused', () {
      expect(
        () => TextEditingValue(
          text: 'abc',
          selection: const TextSelection.collapsed(4),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a caret between surrogates is refused', () {
      expect(
        () => TextEditingValue(
          text: _emoji,
          selection: const TextSelection.collapsed(1),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            contains('grapheme cluster'),
          ),
        ),
      );
    });

    test('a selection end inside a decomposed cluster is refused', () {
      expect(
        () => TextEditingValue(
          text: 'm${_aAcute}s',
          selection: const TextSelection(baseOffset: 0, extentOffset: 2),
        ),
        throwsA(isA<ArgumentError>()),
      );
      // The cluster's own boundaries are fine, so this is a rejection of the
      // middle and not of the whole idea of selecting an accented letter.
      expect(
        TextEditingValue(
          text: 'm${_aAcute}s',
          selection: const TextSelection(baseOffset: 0, extentOffset: 3),
        ).selection.end,
        3,
      );
    });

    test('a selection inside a ZWJ family is refused at every interior offset',
        () {
      for (int offset = 1; offset < _family.length; offset++) {
        expect(
          () => TextEditingValue(
            text: _family,
            selection: TextSelection.collapsed(offset),
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'offset $offset is inside the family cluster',
        );
      }
      expect(
        TextEditingValue(
          text: _family,
          selection: const TextSelection.collapsed(8),
        ).selection.extentOffset,
        8,
      );
    });

    test('a reversed selection is kept reversed rather than normalised', () {
      final value = TextEditingValue(
        text: 'abcdef',
        selection: const TextSelection(baseOffset: 4, extentOffset: 1),
      );

      expect(value.selection.baseOffset, 4);
      expect(value.selection.extentOffset, 1);
      expect(value.selection.isReversed, isTrue);
      expect(value.selection.start, 1);
      expect(value.selection.end, 4);
    });

    test('a collapsed composing region is refused', () {
      expect(
        () => TextEditingValue(text: 'abc', composing: const TextRange(1, 1)),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            contains('collapsed'),
          ),
        ),
      );
    });

    test('an inverted composing region is refused', () {
      expect(
        () => TextEditingValue(text: 'abc', composing: const TextRange(2, 1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a composing region past the end is refused', () {
      expect(
        () => TextEditingValue(text: 'abc', composing: const TextRange(1, 9)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a half-negative composing range is refused', () {
      expect(
        () => TextEditingValue(text: 'abc', composing: const TextRange(-1, 2)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a composing region cutting a cluster is refused', () {
      expect(
        () => TextEditingValue(
          text: 'm${_aAcute}s',
          composing: const TextRange(1, 2),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TextRange.empty is the only spelling of "not composing"', () {
      final value = TextEditingValue(text: 'abc');

      expect(value.composing, TextRange.empty);
      expect(value.composing.isValid, isFalse);
      expect(value.isComposing, isFalse);
      expect(value.composingText, '');
      expect(TextRange.empty.toString(), 'TextRange.empty');
    });

    test('a valid value round-trips through equality and copyWith', () {
      final value = TextEditingValue(
        text: 'abcd',
        selection: const TextSelection(baseOffset: 1, extentOffset: 3),
        composing: const TextRange(1, 3),
      );

      expect(value.composingText, 'bc');
      expect(value, value.copyWith());
      expect(
        value.copyWith(selection: const TextSelection.collapsed(0)) == value,
        isFalse,
      );
      expect(value.hashCode, value.copyWith().hashCode);
    });

    test('the error names the cluster the offset fell into', () {
      // A message that says only "offset 1 is invalid" sends the reader to the
      // wrong place; naming the cluster names the cause.
      expect(
        () => TextEditingValue(
          text: _aAcute,
          selection: const TextSelection.collapsed(1),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            // The message spells the code point out rather than printing it:
            // a bare combining acute renders as an accent on the quotation
            // mark, and tells the reader nothing.
            contains('0301'),
          ),
        ),
      );
    });
  });

  group('the controller keeps its selection on cluster boundaries', () {
    test('setSelection snaps an interior offset down to the cluster start', () {
      final controller = TextEditingController('a$_emoji' 'b')
        ..setSelection(2, 2);

      expect(
        controller.selectionEnd,
        1,
        reason: 'offset 2 is between the surrogates',
      );
      expect(controller.selectionStart, 1);
    });

    test('setSelection snaps both ends of a range', () {
      final controller = TextEditingController('x${_family}y')
        ..setSelection(3, 7);

      expect(controller.selectionStart, 1);
      expect(controller.selectionEnd, 1);
    });

    test('a shrinking value leaves the caret on a boundary, not mid-cluster',
        () {
      final controller = TextEditingController('abcdef')..collapseTo(3);

      // Offset 3 is a perfectly ordinary boundary in 'abcdef' and lands between
      // the surrogates of the emoji in the replacement.
      controller.value = 'ab$_emoji';

      expect(controller.selectionEnd, 2);
      expect(controller.editingValue.selection.extentOffset, 2);
    });

    test('typing in front of a combining mark puts the caret after it', () {
      // The one case where snapping *down* would be wrong: the caret would land
      // in front of the character the user just typed.
      final controller = TextEditingController('́')..collapseTo(0);

      controller.replaceSelection('a');

      expect(controller.value, _aAcute);
      expect(
        controller.selectionEnd,
        2,
        reason: 'the insertion joined the accent into one cluster',
      );
    });

    test('every controller state is a legal TextEditingValue', () {
      final controller = TextEditingController('$_emoji$_family$_flagBR');
      controller.moveCaretToEnd();
      while (controller.selectionEnd > 0) {
        // Reading editingValue runs the constructor's checks, so this loop is
        // an assertion that no caret position the controller can reach is
        // illegal.
        expect(controller.editingValue.text, controller.value);
        controller.moveCaret(-1);
      }
      expect(controller.selectionEnd, 0);
    });
  });

  group('the IME composing contract', () {
    test('a composition session updates in place and commits once', () {
      final controller = TextEditingController('ab')..moveCaretToEnd();

      controller.replaceComposingRegion('n');
      expect(controller.value, 'abn');
      expect(controller.composing, const TextRange(2, 3));
      expect(controller.selectionEnd, 3);
      expect(controller.isComposing, isTrue);

      // The next keystroke of the conversion replaces the *region*, not the
      // selection: the provisional text is one thing that keeps changing.
      controller.replaceComposingRegion('に');
      expect(controller.value, 'abに');
      expect(controller.composing, const TextRange(2, 3));

      controller.commitText('日');
      expect(controller.value, 'ab日');
      expect(controller.composing, TextRange.empty);
      expect(controller.selectionEnd, 3);

      // One undo entry for the whole session, not one per keystroke.
      controller.undo();
      expect(controller.value, 'ab');
      expect(controller.canUndo, isFalse);
    });

    test('the caret can sit inside the composing text', () {
      final controller = TextEditingController('')..collapseTo(0);

      controller.replaceComposingRegion('abcd', caretOffset: 2);

      expect(controller.value, 'abcd');
      expect(controller.composing, const TextRange(0, 4));
      expect(controller.selectionEnd, 2);
    });

    test('an empty composition string ends the region without ending the text',
        () {
      final controller = TextEditingController('xy')..collapseTo(1);
      controller.replaceComposingRegion('ab');
      expect(controller.value, 'xaby');

      controller.replaceComposingRegion('');

      expect(controller.value, 'xy');
      expect(controller.composing, TextRange.empty);
      expect(controller.selectionEnd, 1);
    });

    test('commitComposing accepts the text and moves the caret to its end', () {
      final controller = TextEditingController('ab')..collapseTo(1);
      controller.replaceComposingRegion('XY');
      controller.setSelection(2, 2);

      controller.commitComposing();

      expect(controller.value, 'aXYb');
      expect(controller.composing, TextRange.empty);
      expect(controller.selectionEnd, 3, reason: 'the end of the region');
    });

    test('clearComposing drops the region and leaves the caret alone', () {
      final controller = TextEditingController('ab')..collapseTo(1);
      controller.replaceComposingRegion('XY');
      controller.setSelection(2, 2);

      controller.clearComposing();

      expect(controller.value, 'aXYb');
      expect(controller.composing, TextRange.empty);
      expect(controller.selectionEnd, 2, reason: 'unlike commitComposing');
    });

    test('an ordinary edit clears the composing region', () {
      final controller = TextEditingController('ab')..moveCaretToEnd();
      controller.replaceComposingRegion('XY');
      expect(controller.isComposing, isTrue);

      controller.deleteBackward();

      expect(controller.value, 'abX');
      expect(controller.composing, TextRange.empty);
    });

    test('replacing the whole text clears the composing region', () {
      final controller = TextEditingController('ab')..moveCaretToEnd();
      controller.replaceComposingRegion('XY');

      controller.value = 'zzz';

      expect(controller.composing, TextRange.empty);
      expect(controller.selectionEnd, lessThanOrEqualTo(3));
    });

    test('undo never restores a composing region', () {
      final controller = TextEditingController('ab')..moveCaretToEnd();
      controller.replaceComposingRegion('XY');
      controller.commitComposing();
      expect(controller.value, 'abXY');

      controller.undo();

      expect(controller.value, 'ab');
      expect(
        controller.composing,
        TextRange.empty,
        reason: 'no live IME session stands behind a restored region',
      );
    });

    test('editingValue is the atomic apply point a backend writes through', () {
      final controller = TextEditingController('hello');

      controller.editingValue = TextEditingValue(
        text: 'hell\u{1F600}',
        selection: const TextSelection.collapsed(6),
        composing: const TextRange(4, 6),
      );

      expect(controller.value, 'hell\u{1F600}');
      expect(controller.selectionEnd, 6);
      expect(controller.composing, const TextRange(4, 6));
      expect(controller.composing.textInside(controller.value), _emoji);
      // Assignment, not a user edit: no undo entry, like `value =`.
      expect(controller.canUndo, isFalse);
    });

    test('a backend cannot hand over a region that cuts a cluster', () {
      // The Win32 and macOS bridges speak UTF-16 natively; an X11 bridge
      // converting from UTF-8 is where a bad offset would come from, and this
      // is the line it would fail on.
      expect(
        () => TextEditingController('x').editingValue = TextEditingValue(
          text: 'x$_emoji',
          composing: const TextRange(1, 2),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('a mounted TextField routes the editing keys', () {
    setUpAll(() {
      expect(
        FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
        isTrue,
      );
    });
    tearDownAll(FontRegistry.instance.reset);

    test('Ctrl+Left and Ctrl+Right move by word', () {
      final controller = TextEditingController('alpha beta gamma');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;
      owner.requestKeyboardFocus(field);

      expect(controller.selectionEnd, 16);
      owner.dispatchKeyEvent(_key(logicalKeyArrowLeft, control: true));
      expect(controller.selectionEnd, 11);
      owner.dispatchKeyEvent(_key(logicalKeyArrowLeft, control: true));
      expect(controller.selectionEnd, 6);

      owner.dispatchKeyEvent(_key(logicalKeyArrowRight, control: true));
      expect(controller.selectionEnd, 11);
    });

    test('Ctrl+Shift+Left extends the selection by a word', () {
      final controller = TextEditingController('alpha beta');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;
      owner.requestKeyboardFocus(field);

      owner.dispatchKeyEvent(
        _key(logicalKeyArrowLeft, control: true, shift: true),
      );

      expect(controller.selectionStart, 10);
      expect(controller.selectionEnd, 6);
      expect(controller.selectedText, 'beta');
    });

    test('Ctrl+Backspace and Ctrl+Delete delete by word', () {
      final controller = TextEditingController('alpha beta gamma');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;
      owner.requestKeyboardFocus(field);

      owner.dispatchKeyEvent(_key(logicalKeyBackspace, control: true));
      expect(controller.value, 'alpha beta ');

      controller.collapseTo(0);
      owner.dispatchKeyEvent(_key(logicalKeyDelete, control: true));
      expect(controller.value, 'beta ');
    });

    test('a read-only field swallows Ctrl+Backspace without editing', () {
      final controller = TextEditingController('alpha beta');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller, readOnly: true));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;

      expect(
        field.handleKeyEvent(_key(logicalKeyBackspace, control: true)),
        isTrue,
        reason: 'letting it through would fire an application shortcut',
      );
      expect(controller.value, 'alpha beta');
    });

    test('an unhandled Ctrl chord is still declined', () {
      final controller = TextEditingController('alpha');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;

      expect(field.handleKeyEvent(_key(0x53, control: true)), isFalse);
    });

    test('plain Backspace still deletes one cluster through the key path', () {
      final controller = TextEditingController('a$_family');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;
      owner.requestKeyboardFocus(field);

      owner.dispatchKeyEvent(_key(logicalKeyBackspace));

      expect(controller.value, 'a');
    });
  });

  group('the caret and the selection come from a laid-out paragraph', () {
    // DejaVu rather than Roboto because these cases need Hebrew coverage; the
    // point of the group is text whose visual order is not its logical order.
    setUpAll(() {
      expect(
        FontRegistry.instance.useFontFile('test/fonts/DejaVuSans.ttf'),
        isTrue,
      );
    });
    tearDownAll(FontRegistry.instance.reset);

    test('a selection crossing a direction boundary is more than one box', () {
      final controller = TextEditingController('ab$_hebrew')
        ..setSelection(1, 3);
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      final list = DisplayList();
      owner.pipelineOwner.drawFrame(list);
      final field = owner.renderRoot! as RenderTextField;

      final Paragraph laid = field.paragraph!;
      final List<TextBox> boxes = laid.getBoxesForSelection(1, 3);
      expect(
        boxes.length,
        2,
        reason: 'the "b" and the Hebrew letter are not adjacent on screen',
      );
      expect(boxes.first.direction, TextDirection.leftToRight);
      expect(boxes.last.direction, TextDirection.rightToLeft);
      // Disjoint, which is the whole reason one rectangle cannot do: the gap
      // between them holds the *unselected* second Hebrew letter.
      expect(boxes.first.rect.right, lessThan(boxes.last.rect.left));

      // And the field painted both of them.
      final int painted = _selectionRects(list, ThemeData.neutralLight);
      expect(painted, 2);
    });

    test('a plain left-to-right selection is still one box', () {
      final controller = TextEditingController('abcd')..setSelection(1, 3);
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      final list = DisplayList();
      owner.pipelineOwner.drawFrame(list);

      expect(_selectionRects(list, ThemeData.neutralLight), 1);
    });

    test('affinity puts the caret on two different sides of one offset', () {
      final controller = TextEditingController('ab$_hebrew');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;

      final Paragraph laid = field.paragraph!;
      final double upstream = laid
          .getCaretRect(
            const TextPosition(2, affinity: TextAffinity.upstream),
          )
          .left;
      final double downstream = laid
          .getCaretRect(
            const TextPosition(2),
          )
          .left;

      // Offset 2 is the trailing edge of "ab" and the leading - that is, right
      // hand - edge of the Hebrew run, and those are different places.
      expect(upstream, lessThan(downstream));
      expect(upstream, greaterThan(0));
    });

    test('a hit test snaps to a cluster and records the side it hit', () {
      final controller = TextEditingController('a$_emoji' 'b');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;

      final Paragraph laid = field.paragraph!;
      // Far right of the text: the end, upstream.
      final TextPosition end = laid.getPositionForOffset(const Offset(1000, 0));
      expect(end.offset, 4);
      expect(end.affinity, TextAffinity.upstream);

      // Every position the paragraph can report is a legal caret, which is what
      // lets the pointer handler hand it straight to the controller.
      for (double x = -20; x < 200; x += 1.0) {
        final TextPosition hit = laid.getPositionForOffset(Offset(x, 0));
        expect(
          hit.offset,
          isNot(2),
          reason: 'offset 2 is between the surrogates',
        );
        controller.collapseToPosition(hit);
        expect(controller.selectionEnd, hit.offset);
      }
    });

    test('a pointer press places the caret through the paragraph', () {
      final controller = TextEditingController('abcd')..collapseTo(0);
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());

      // Inside the field and well to the right of the text, so the hit test
      // clamps to the end of the line rather than missing the control.
      owner.dispatchPointerEvent(_pointerDown(const Offset(150, 10)));

      expect(controller.selectionEnd, 4);
      expect(controller.affinity, TextAffinity.upstream);
    });

    test('the composing region is underlined, once per visual box', () {
      final controller = TextEditingController('ab')..moveCaretToEnd();
      controller.replaceComposingRegion('XY');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      final list = DisplayList();
      owner.pipelineOwner.drawFrame(list);
      final field = owner.renderRoot! as RenderTextField;

      final int underlines = _rectsWithColor(
        list,
        ThemeData.neutralLight.foreground,
      ).where((DrawRectCommand rect) => rect.bottom - rect.top == 1).length;
      // One underline under "XY"; the caret is a separate rectangle and is
      // taller than one pixel, so the height filter separates them.
      expect(underlines, 1);
      expect(field.controller.composing, const TextRange(2, 4));
    });
  });
}

/// The rectangles the field painted in the theme's selection colour.
int _selectionRects(DisplayList list, ThemeData theme) {
  // Asserted rather than assumed: if the selection colour ever equals the
  // surface or the border, this count would silently include the background.
  expect(theme.selection, isNot(theme.surfaceAlternate));
  expect(theme.selection, isNot(theme.border));
  return _rectsWithColor(list, theme.selection).length;
}

List<DrawRectCommand> _rectsWithColor(DisplayList list, int color) =>
    expandDisplayList(list)
        .whereType<DrawRectCommand>()
        .where((DrawRectCommand rect) => list.paintColor(rect.paintId) == color)
        .toList();

BuildOwner _owner({Size size = const Size(200, 60)}) => BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );

PointerDownEvent _pointerDown(Offset at) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

KeyDownEvent _key(int logicalKey, {bool control = false, bool shift = false}) =>
    KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: <KeyModifier>{
        if (control) KeyModifier.control,
        if (shift) KeyModifier.shift,
      },
    );
