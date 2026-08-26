/// The text field under an input method, headless.
///
/// Everything here runs against a scripted [TextInputBackend] rather than a
/// real IME, which is what makes it run on any machine: the platform half is
/// covered by `win32_ime_test.dart` (a real input context) and
/// `wayland_text_input_test.dart` (the protocol state machine). What is left is
/// the part *both* platforms rely on and neither can test - what the field does
/// when it is told there is a preedit.
///
/// The cases are the ones that decide whether a Japanese sentence can be typed:
/// a preedit that lands in the document and is marked provisional, a caret that
/// stays inside it, a commit that ends it, a cancel that leaves nothing behind,
/// and a plain keystroke that does not become a second opinion about it.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  late HeadlessWindowingBackend backend;
  late NativeWindow window;

  setUp(() async {
    backend = HeadlessWindowingBackend();
    await backend.initialize();
    window = await backend.createWindow(
      const WindowOptions(title: 'ime', size: Size(200, 60)),
    );
  });

  tearDown(() async {
    await backend.shutdown();
  });

  /// A mounted, focused field with [input] behind it.
  ({
    RenderTextField field,
    TextEditingController controller,
    FocusNode focus,
    BuildOwner owner,
  }) mount(
    _ScriptedTextInput input, {
    bool obscure = false,
    bool readOnly = false,
    String initial = '',
  }) {
    final TextEditingController controller = TextEditingController(initial);
    final FocusNode focus = FocusNode(debugLabel: 'ime field');
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 60)),
      ),
    );
    owner.updateRoot(
      TextInputScope(
        textInput: input,
        window: window,
        child: TextField(
          controller: controller,
          focusNode: focus,
          obscure: obscure,
          readOnly: readOnly,
        ),
      ),
    );
    owner.pipelineOwner.drawFrame(DisplayList());
    final RenderTextField field = owner.renderRoot! as RenderTextField;
    focus.requestFocus();
    return (field: field, controller: controller, focus: focus, owner: owner);
  }

  group('attaching', () {
    test(
        'a field takes the input method when it takes focus, and gives it '
        'back when it loses it', () {
      final input = _ScriptedTextInput();
      final bound = mount(input);

      expect(input.attachments, 1);
      expect(bound.field.isTextInputAttached, isTrue);
      expect(input.connection!.enables, 1);

      bound.focus.unfocus();

      expect(bound.field.isTextInputAttached, isFalse);
      expect(input.connection!.detached, isTrue);
      expect(
        input.connection!.disables,
        greaterThan(0),
        reason: 'disable before detach: on Win32 detaching restores the '
            'window default context, and a live composition would be handed '
            'to nobody',
      );
    });

    test('a field with no scope above it composes nothing and still types', () {
      final TextEditingController controller = TextEditingController();
      final FocusNode focus = FocusNode();
      final BuildOwner owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(200, 60)),
        ),
      )..updateRoot(TextField(controller: controller, focusNode: focus));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderTextField field = owner.renderRoot! as RenderTextField;
      focus.requestFocus();

      expect(field.isTextInputAttached, isFalse);
      expect(field.textInputError, isNull);

      field.handleTextInput(FakeTextInput().typeText('a'));
      expect(
        controller.value,
        'a',
        reason: 'plain typing comes from the platform keyboard, never through '
            'the input method',
      );
    });

    test('a backend that cannot compose is never attached to', () {
      final input = _ScriptedTextInput(supportsComposition: false);
      final bound = mount(input);

      expect(input.attachments, 0);
      expect(bound.field.isTextInputAttached, isFalse);
      expect(
        bound.field.textInputError,
        isNull,
        reason: 'asked rather than tried: a known platform fact must not turn '
            'into a per-focus-change exception',
      );
    });

    test('an obscured field never composes', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, obscure: true);

      expect(
        bound.field.textInputConfiguration.isSensitive,
        isTrue,
        reason: 'handing a password to an input-method process is the same '
            'leak as putting it on the clipboard',
      );
      expect(bound.field.surroundingText.text, isEmpty);
    });

    test('a read-only field is not composed into either', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, readOnly: true, initial: 'fixed');

      expect(bound.field.textInputConfiguration.isSensitive, isTrue);
      expect(bound.field.surroundingText.text, isEmpty);
    });
  });

  group('a preedit', () {
    test('lands in the document and is marked provisional', () {
      final input = _ScriptedTextInput();
      final bound = mount(input);

      bound.field.updateComposition(ImeComposition(text: 'にほん'));

      expect(bound.controller.value, 'にほん');
      expect(bound.controller.isComposing, isTrue);
      expect(bound.controller.composing.start, 0);
      expect(bound.controller.composing.end, 3);
    });

    test('keeps the caret where the method put it, inside the preedit', () {
      final input = _ScriptedTextInput();
      final bound = mount(input);

      bound.field.updateComposition(
        ImeComposition(text: 'abcd', cursorStart: 2, cursorEnd: 2),
      );

      expect(
        bound.controller.selectionEnd,
        2,
        reason: 'a Japanese method converting a phrase puts the caret between '
            'clauses, not at the end',
      );
    });

    test('replaces the previous preedit rather than appending to it', () {
      final input = _ScriptedTextInput();
      final bound = mount(input);

      bound.field
        ..updateComposition(ImeComposition(text: 'に'))
        ..updateComposition(ImeComposition(text: 'にほ'))
        ..updateComposition(ImeComposition(text: 'にほん'));

      expect(bound.controller.value, 'にほん');
      expect(bound.controller.composing.end, 3);
    });

    test('a whole composing session is one undo entry', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'x');
      bound.controller.moveCaretToEnd();

      bound.field
        ..updateComposition(ImeComposition(text: 'に'))
        ..updateComposition(ImeComposition(text: 'にほ'))
        ..commitText('日本');
      bound.controller.undo();

      expect(
        bound.controller.value,
        'x',
        reason: 'one Ctrl+Z undoes a conversion the user experienced as one '
            'action, not one hiragana of it',
      );
    });

    test('an empty composition ends it and takes the provisional text with it',
        () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'ab');
      bound.controller.moveCaretToEnd();

      bound.field
        ..updateComposition(ImeComposition(text: 'cd'))
        ..updateComposition(ImeComposition.none);

      expect(
        bound.controller.value,
        'ab',
        reason: 'those characters were never accepted by anybody',
      );
      expect(bound.controller.isComposing, isFalse);
    });

    test('the preedit is kept out of the surrounding text', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'hello');
      bound.controller.moveCaretToEnd();

      bound.field.updateComposition(ImeComposition(text: 'にほん'));

      final ImeSurroundingText surrounding = bound.field.surroundingText;
      expect(
        surrounding.text,
        'hello',
        reason: 'the provisional characters belong to the input method, not to '
            'the document; sending them back makes the method see its own '
            'output as context, and on Wayland is a protocol violation',
      );
      expect(surrounding.cursor, 5);
    });

    test('the caret rectangle follows the caret and is not the whole field',
        () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'hello world');

      bound.controller.moveCaretToStart();
      final Rect atStart = bound.field.caretRect;
      bound.controller.moveCaretToEnd();
      final Rect atEnd = bound.field.caretRect;

      expect(atEnd.left, greaterThan(atStart.left));
      expect(
        atEnd.width,
        lessThan(50),
        reason: 'the candidate window opens below this rectangle; handing over '
            'the whole control would put the list under the wrong place',
      );
      expect(atEnd.height, greaterThan(0));
    });

    test('an edit tells the platform the caret moved', () {
      final input = _ScriptedTextInput();
      final bound = mount(input);
      final int before = input.connection!.stateUpdates;

      bound.field.handleTextInput(FakeTextInput().typeText('a'));

      expect(
        input.connection!.stateUpdates,
        greaterThan(before),
        reason: 'the candidate window follows the caret, and contextual '
            'conversion needs the words around it',
      );
    });

    test('applying a composition does not push state back at the platform', () {
      final input = _ScriptedTextInput();
      final bound = mount(input);
      final int before = input.connection!.stateUpdates;

      bound.field.updateComposition(ImeComposition(text: 'ab'));

      expect(
        input.connection!.stateUpdates,
        before,
        reason: 'a Wayland commit bumps the count every done event is compared '
            'against; pushing from inside the callbacks a single done makes '
            'would leave the client ahead of the compositor and make the next '
            'delete_surrounding_text look stale',
      );
    });
  });

  group('committing and cancelling', () {
    test('a commit replaces the preedit and ends the composition', () {
      final input = _ScriptedTextInput();
      final bound = mount(input);

      bound.field
        ..updateComposition(ImeComposition(text: 'にほんご'))
        ..commitText('日本語');

      expect(bound.controller.value, '日本語');
      expect(bound.controller.isComposing, isFalse);
      expect(bound.controller.selectionEnd, 3);
    });

    test('a commit with nothing composing replaces the selection', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'abcd');
      bound.controller.selectAll();

      bound.field.commitText('X');

      expect(bound.controller.value, 'X');
    });

    test('Escape cancels the composition and leaves no text behind', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'ab');
      bound.controller.moveCaretToEnd();
      bound.field.updateComposition(ImeComposition(text: 'にほん'));

      final bool claimed = bound.field.handleKeyEvent(_key(logicalKeyEscape));

      expect(claimed, isTrue);
      expect(input.connection!.cancels, 1);
      expect(bound.controller.value, 'ab');
      expect(bound.controller.isComposing, isFalse);
    });

    test('Escape with nothing composing is left for whatever is dismissible',
        () {
      final input = _ScriptedTextInput();
      final bound = mount(input);

      expect(
        bound.field.handleKeyEvent(_key(logicalKeyEscape)),
        isFalse,
        reason: 'a field that ate every Escape strands a keyboard user inside '
            'a dialog they cannot dismiss',
      );
    });

    test('losing focus cancels rather than commits', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'ab');
      bound.controller.moveCaretToEnd();
      bound.field.updateComposition(ImeComposition(text: 'cd'));

      bound.focus.unfocus();

      expect(
        bound.controller.value,
        'ab',
        reason: 'the characters were provisional and the user moved somewhere '
            'else; committing inserts text nobody accepted',
      );
    });

    test('a plain keystroke during a composition cancels it first', () {
      final input = _ScriptedTextInput();
      final bound = mount(input);
      bound.field.updateComposition(ImeComposition(text: 'にほ'));

      bound.field.handleTextInput(FakeTextInput().typeText('x'));

      expect(input.connection!.cancels, 1);
      expect(
        bound.controller.value,
        'x',
        reason: 'the character must not land inside the underlined span with '
            'the IME still owning a range it no longer recognises',
      );
      expect(bound.controller.isComposing, isFalse);
    });
  });

  group('delete_surrounding_text', () {
    test('removes the requested units on both sides of the caret', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'abcdef');
      bound.controller.setSelection(3, 3);

      bound.field.deleteSurroundingText(beforeLength: 2, afterLength: 1);

      expect(
        bound.controller.value,
        'aef',
        reason: 'bc before the caret and d after it',
      );
      expect(bound.controller.selectionEnd, 1, reason: 'where they met');
    });

    test('a request larger than the document deletes what exists', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, initial: 'ab');
      bound.controller.setSelection(1, 1);

      bound.field.deleteSurroundingText(beforeLength: 99, afterLength: 99);

      expect(
        bound.controller.value,
        isEmpty,
        reason: 'refusing leaves the input method\'s idea of the text '
            'permanently ahead of this one\'s, and the next thing it sends '
            'lands in the wrong place',
      );
    });

    test('never cuts a surrogate pair in half', () {
      final input = _ScriptedTextInput();
      // GRINNING FACE is two code units; a one-unit deletion before the caret
      // would leave an unpaired surrogate that encodes nothing.
      final bound = mount(input, initial: 'a\u{1F600}b');
      bound.controller.setSelection(3, 3);

      bound.field.deleteSurroundingText(beforeLength: 1, afterLength: 0);

      expect(bound.controller.value, 'ab');
    });

    test('a read-only field refuses', () {
      final input = _ScriptedTextInput();
      final bound = mount(input, readOnly: true, initial: 'abc');

      bound.field.deleteSurroundingText(beforeLength: 1, afterLength: 0);

      expect(bound.controller.value, 'abc');
    });
  });

  group('dead keys', () {
    test('an accent typed as one composed character arrives whole', () {
      // The Win32 path: Windows applies the dead key itself and delivers the
      // composed character as a single WM_CHAR. There is nothing for the field
      // to do but insert it - and nothing it is entitled to re-derive.
      final input = _ScriptedTextInput();
      final bound = mount(input);
      final fake = FakeTextInput();

      bound.field
        ..handleTextInput(fake.typeText('á'))
        ..handleTextInput(fake.typeText('ç'))
        ..handleTextInput(fake.typeText('ã'));

      expect(bound.controller.value, 'áçã');
    });

    test('an accent that arrives decomposed leaves the caret past the cluster',
        () {
      // The X11/Wayland path once a compose engine resolves `dead_acute` `a`
      // into a decomposed pair: `a` + U+0301 is two code units and one
      // grapheme cluster, and a caret between them is an offset
      // `TextEditingValue` refuses to exist with.
      final input = _ScriptedTextInput();
      final bound = mount(input);

      bound.field.handleTextInput(FakeTextInput().typeText('á'));

      expect(bound.controller.value, 'á');
      expect(bound.controller.selectionEnd, 2);
      bound.controller.deleteBackward();
      expect(
        bound.controller.value,
        isEmpty,
        reason: 'one backspace removes the whole cluster, not the accent off '
            'a letter that then attaches to whatever precedes it',
      );
    });
  });
}

KeyDownEvent _key(int logicalKey) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: 0,
      logicalKey: logicalKey,
    );

/// A [TextInputBackend] that records what the field asked of it.
final class _ScriptedTextInput implements TextInputBackend {
  _ScriptedTextInput({this.supportsComposition = true});

  @override
  String get name => 'scripted';

  @override
  final bool supportsComposition;

  @override
  bool get usesSurroundingText => true;

  int attachments = 0;
  _ScriptedConnection? connection;

  @override
  TextInputConnection attach({
    required NativeWindow window,
    required TextInputClient client,
  }) {
    attachments++;
    return connection = _ScriptedConnection(window.id);
  }
}

final class _ScriptedConnection implements TextInputConnection {
  _ScriptedConnection(this.windowId);

  @override
  final NativeWindowId windowId;

  int enables = 0;
  int disables = 0;
  int cancels = 0;
  int stateUpdates = 0;
  bool detached = false;

  @override
  bool get isAttached => !detached;

  @override
  bool get isEnabled => enables > disables;

  @override
  void enable() => enables++;

  @override
  void disable() => disables++;

  @override
  void cancelComposition() => cancels++;

  @override
  void updateEditingState() => stateUpdates++;

  @override
  void detach() => detached = true;
}
