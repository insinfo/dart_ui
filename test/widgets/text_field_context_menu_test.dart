/// The text field's own context menu: Cut / Copy / Paste / Select all.
///
/// Three things are being asserted here and they are not the same thing:
///
///  1. **The caret rule.** A secondary press inside a selection preserves it;
///     outside it moves the caret first. Getting this backwards loses a
///     selection the user was about to copy, silently and with no undo, which
///     is why each direction is its own test.
///  2. **Enablement is the truth about what will happen.** A menu is where a
///     control *states* what is available, so every state - empty selection,
///     selection, read-only, obscured, empty clipboard - is asserted item by
///     item rather than as "the menu opened".
///  3. **The menu and the keyboard are the same operation.** Every command is
///     asserted by the text it produces, next to the identical assertion made
///     through the chord, because "it did not throw" is not evidence that Cut
///     cut anything.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const int _keyA = 0x41;
const int _keyC = 0x43;
const int _keyV = 0x56;
const int _keyX = 0x58;
const int _keyF10 = 0x79;
const int _keyApps = 0x5D;

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('opening', () {
    test('a secondary click opens the menu at the pointer', () async {
      final _Field field = _Field('hello world');
      await field.rightClickAt(3);

      expect(field.labels, <String>['Cut', 'Copy', 'Paste', 'Select all']);
      expect(field.controller.isOpen, isTrue);
    });

    test('Escape closes it and the field keeps the keyboard', () async {
      final _Field field = _Field('hello world');
      await field.rightClickAt(3);

      field
        ..pressKey(logicalKeyEscape)
        ..frame();

      expect(field.surface, isNull);
      expect(
        field.owner.focusedTarget,
        same(field.render),
        reason: 'the field must be typeable again the moment the menu is gone',
      );
    });

    test('a click outside closes it', () async {
      final _Field field = _Field('hello world');
      await field.rightClickAt(3);

      field
        ..primaryDown(const Offset(280, 55))
        ..primaryUp(const Offset(280, 55))
        ..frame();

      expect(field.surface, isNull);
    });

    test('Shift+F10 opens the menu under the caret', () async {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);

      field
        ..pressKey(_keyF10, shift: true)
        ..frame();
      await field.settled;
      field.frame();

      expect(field.surface, isNotNull);
      // Anchored under the caret, not at a pointer that may be anywhere on the
      // screen or nowhere at all. The *placement* then flips upward, because
      // the field fills this 120px-tall window and there is no room below it -
      // which is the work-area rule doing its job, not the anchor being wrong.
      expect(field.controller.anchor.dy, field.render.size.height);
      expect(
        field.controller.anchor.dx,
        closeTo(field.positionOf(5).dx, 0.5),
        reason: 'under the caret, which is at the end of the selection',
      );
      expect(field.controller.placement!.flippedY, isTrue);
      expect(field.controller.placement!.rect.top, greaterThanOrEqualTo(0));
    });

    test('bare F10 is left to the window, and the Menu key opens', () async {
      final _Field field = _Field('hello world');

      expect(field.dispatchKey(_keyF10), isFalse);
      field.frame();
      expect(field.surface, isNull);

      field
        ..pressKey(_keyApps)
        ..frame();
      await field.settled;
      field.frame();
      expect(field.surface, isNotNull);
    });
  });

  group('the caret rule', () {
    test('a right click inside the selection preserves it', () async {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);
      expect(field.controllerText.selectedText, 'hello');

      await field.rightClickAt(2);

      expect(
        field.controllerText.selectedText,
        'hello',
        reason: 'the selection is what the menu is about to act on',
      );
      expect(field.controllerText.selectionStart, 0);
      expect(field.controllerText.selectionEnd, 5);
    });

    test('a right click on the far boundary still counts as inside', () async {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);

      await field.rightClickAt(5);

      expect(field.controllerText.selectedText, 'hello');
    });

    test('a right click outside the selection moves the caret there', () async {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);

      await field.rightClickAt(8);

      expect(field.controllerText.hasSelection, isFalse);
      expect(field.controllerText.selectionEnd, 8);
      expect(field.controllerText.selectionStart, 8);
    });

    test('the selection survives the whole open-and-dismiss cycle', () async {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(6, 11);

      await field.rightClickAt(8);
      expect(field.controllerText.selectedText, 'world');

      field
        ..pressKey(logicalKeyEscape)
        ..frame();

      expect(field.controllerText.selectedText, 'world');
      expect(field.controllerText.selectionStart, 6);
      expect(field.controllerText.selectionEnd, 11);
    });
  });

  group('enablement', () {
    test('with no selection Copy and Cut are off and say why', () async {
      final _Field field = _Field('hello world');
      await field.rightClickAt(3);

      expect(field.itemFor('Copy').enabled, isFalse);
      expect(field.itemFor('Copy').disabledReason, 'nothing is selected');
      expect(field.itemFor('Cut').enabled, isFalse);
      expect(field.itemFor('Select all').enabled, isTrue);
    });

    test('with a selection Copy and Cut come on', () async {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);
      await field.rightClickAt(2);

      expect(field.itemFor('Copy').enabled, isTrue);
      expect(field.itemFor('Cut').enabled, isTrue);
    });

    test('an obscured field refuses Copy and Cut, with the reason', () async {
      final _Field field = _Field('hunter2', obscure: true);
      field.clipboard.seedText('from a password manager');
      field.render.controller.selectAll();
      await field.rightClickAt(2);

      expect(field.itemFor('Copy').enabled, isFalse);
      expect(field.itemFor('Copy').disabledReason, contains('obscured'));
      expect(field.itemFor('Cut').enabled, isFalse);
      expect(
        field.itemFor('Paste').enabled,
        isTrue,
        reason: 'pasting *into* a password field is how password managers work',
      );
    });

    test('a read-only field offers Copy but not Cut or Paste', () async {
      final _Field field = _Field('hello world', readOnly: true);
      field.render.controller.setSelection(0, 5);
      await field.rightClickAt(2);

      expect(field.itemFor('Copy').enabled, isTrue);
      expect(
        field.itemFor('Cut').enabled,
        isFalse,
        reason: 'a row labelled Cut promises the text goes away; in a '
            'read-only field it would not, so the row must not promise it',
      );
      expect(field.itemFor('Cut').disabledReason, 'the field is read-only');
      expect(field.itemFor('Paste').enabled, isFalse);
      expect(field.itemFor('Paste').disabledReason, 'the field is read-only');
    });

    test('an empty field cannot select all', () async {
      final _Field field = _Field('');
      await field.rightClickAt(0);

      expect(field.itemFor('Select all').enabled, isFalse);
      expect(field.itemFor('Select all').disabledReason, 'the field is empty');
    });

    test('an empty clipboard turns Paste off once the probe lands', () async {
      final _Field field = _Field('hello world');
      // Nothing was ever copied, so `readText` answers null.
      field.rightClickNow(3);
      field.frame();

      expect(
        field.itemFor('Paste').enabled,
        isTrue,
        reason: 'optimistic while the answer is in flight: a disabled row is '
            'unreachable, and the guess is right almost every time',
      );

      await field.settled;
      field.frame();

      expect(field.itemFor('Paste').enabled, isFalse);
      expect(
        field.itemFor('Paste').disabledReason,
        'the clipboard holds no text this field can accept',
      );
    });

    test('a clipboard with text keeps Paste on after the probe', () async {
      final _Field field = _Field('hello world');
      field.clipboard.seedText('pasted');

      await field.rightClickAt(3);

      expect(field.itemFor('Paste').enabled, isTrue);
      expect(field.itemFor('Paste').disabledReason, isNotNull);
    });

    test('a probe that fails leaves Paste enabled', () async {
      final _Field field =
          _Field('hello world', clipboard: _HostileClipboard());

      await field.rightClickAt(3);

      expect(
        field.itemFor('Paste').enabled,
        isTrue,
        reason: 'a read that threw is not evidence the clipboard is empty; '
            'treating it as empty turns one fault into a dead Paste forever',
      );
      expect(
        field.render.lastClipboardError,
        isNull,
        reason: 'and a probe is the framework asking, not the user, so a '
            'failed one must not be reported as a failed command',
      );
    });

    test('a read-only field starts no probe at all', () async {
      final _Field field = _Field('hello world', readOnly: true);
      field.clipboard.seedText('pasted');

      await field.rightClickAt(3);

      expect(field.clipboard.reads, 0);
    });
  });

  group('the commands do the same thing the chords do', () {
    test('Copy from the menu puts the same text on the clipboard', () async {
      final _Field menu = _Field('hello world');
      menu.render.controller.setSelection(0, 5);
      await menu.rightClickAt(2);
      await menu.choose('Copy');

      final _Field chord = _Field('hello world');
      chord.render.controller.setSelection(0, 5);
      chord.pressKey(_keyC, control: true);
      await chord.settled;

      expect(menu.clipboard.text, 'hello');
      expect(chord.clipboard.text, 'hello');
      expect(menu.clipboard.text, chord.clipboard.text);
    });

    test('Cut from the menu removes the same text', () async {
      final _Field menu = _Field('hello world');
      menu.render.controller.setSelection(0, 6);
      await menu.rightClickAt(2);
      await menu.choose('Cut');

      final _Field chord = _Field('hello world');
      chord.render.controller.setSelection(0, 6);
      chord.pressKey(_keyX, control: true);
      await chord.settled;

      expect(menu.controllerText.value, 'world');
      expect(chord.controllerText.value, 'world');
      expect(menu.clipboard.text, 'hello ');
    });

    test('Paste from the menu inserts the same text', () async {
      final _Field menu = _Field('hello world')..clipboard.seedText('brave ');
      menu.render.controller.setSelection(6, 6);
      await menu.rightClickAt(6);
      await menu.choose('Paste');

      final _Field chord = _Field('hello world')..clipboard.seedText('brave ');
      chord.render.controller.setSelection(6, 6);
      chord.pressKey(_keyV, control: true);
      await chord.settled;

      expect(menu.controllerText.value, 'hello brave world');
      expect(chord.controllerText.value, 'hello brave world');
    });

    test('Select all from the menu selects the same range', () async {
      final _Field menu = _Field('hello world');
      await menu.rightClickAt(3);
      await menu.choose('Select all');

      final _Field chord = _Field('hello world')
        ..pressKey(_keyA, control: true);

      expect(menu.controllerText.selectedText, 'hello world');
      expect(chord.controllerText.selectedText, 'hello world');
    });

    test('the menu closes when a command runs', () async {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);
      await field.rightClickAt(2);
      await field.choose('Copy');

      expect(field.surface, isNull);
      expect(field.controller.isOpen, isFalse);
    });
  });

  group('the selection stays visible while its own menu is up', () {
    test('the field paints the active selection colour, not the dim one', () {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);
      final int active = ThemeData.neutralLight.selection;

      field.rightClickNow(2);
      field.frame();

      expect(
        field.render.selectionColorFor(
          background: ThemeData.neutralLight.surfaceAlternate,
        ),
        active,
        reason: 'the keyboard is on loan to the menu, not gone elsewhere; '
            'dimming while the user chooses Copy is the worst moment to do it',
      );
    });

    test('and goes back to inactive once the menu closes', () {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);

      field.rightClickNow(2);
      field.frame();
      field.owner.focusManager.rootScope.focusRemembered();
      field.controller.close();
      field.frame();

      // Focus went back to the field on close, so it is active again for the
      // ordinary reason. Take it away and the policy applies.
      field.render.focusNode!.unfocus();
      expect(
        field.render.selectionColorFor(
          background: ThemeData.neutralLight.surfaceAlternate,
        ),
        isNot(ThemeData.neutralLight.selection),
      );
    });
  });

  group('the inactive-selection policy is the application\'s', () {
    test('hidden paints nothing', () {
      final _Field field = _Field(
        'hello world',
        inactiveSelection: InactiveSelectionHighlight.hidden,
      );
      field.render.controller.setSelection(0, 5);
      field.render.focusNode!.unfocus();

      expect(field.render.selectionColorFor(background: 0xFFFFFFFF), isNull);
    });

    test('visible paints the focused colour', () {
      final _Field field = _Field(
        'hello world',
        inactiveSelection: InactiveSelectionHighlight.visible,
      );
      field.render.controller.setSelection(0, 5);
      field.render.focusNode!.unfocus();

      expect(
        field.render.selectionColorFor(background: 0xFFFFFFFF),
        ThemeData.neutralLight.selection,
      );
    });

    test('dimmed is the default, and is between the two colours', () {
      final _Field field = _Field('hello world');
      field.render.controller.setSelection(0, 5);
      field.render.focusNode!.unfocus();

      final int background = ThemeData.neutralLight.surfaceAlternate;
      final int dimmed = field.render.selectionColorFor(
        background: background,
      )!;
      expect(dimmed, isNot(ThemeData.neutralLight.selection));
      expect(dimmed, isNot(background));
    });

    test('no policy ever touches the controller`s range', () {
      for (final InactiveSelectionHighlight policy
          in InactiveSelectionHighlight.values) {
        final _Field field = _Field(
          'hello world',
          inactiveSelection: policy,
        );
        field.render.controller.setSelection(0, 5);
        field.render.focusNode!.unfocus();
        field.frame();

        expect(field.controllerText.selectedText, 'hello',
            reason: '$policy decides a colour, never a selection');
      }
    });
  });
}

/// A text field inside a context-menu scope, with a fake clipboard.
final class _Field {
  _Field(
    String text, {
    bool obscure = false,
    bool readOnly = false,
    InactiveSelectionHighlight inactiveSelection =
        InactiveSelectionHighlight.dimmed,
    Clipboard? clipboard,
  })  : controllerText = TextEditingController(text),
        _clipboard = clipboard ?? FakeClipboard() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 120)),
      ),
    );
    owner.updateRoot(
      ClipboardScope(
        clipboard: _clipboard,
        child: ContextMenuScope(
          controller: controller,
          child: TextField(
            controller: controllerText,
            obscure: obscure,
            readOnly: readOnly,
            inactiveSelection: inactiveSelection,
          ),
        ),
      ),
    );
    frame();
    render = _find<RenderTextField>()!;
    render.focusNode!.requestFocus();
  }

  final TextEditingController controllerText;
  final Clipboard _clipboard;

  /// The fake, for the tests that seed it or count its calls. Reading it from
  /// a field built with a different double is a test bug, and fails loudly.
  FakeClipboard get clipboard => _clipboard as FakeClipboard;
  final ContextMenuController controller = ContextMenuController();
  late final BuildOwner owner;
  late final RenderTextField render;

  Future<void> get settled => render.clipboardSettled;

  double get _padding => ThemeData.neutralLight.effectiveControlPadding;

  /// Where the caret for [offset] is drawn, in the window's coordinates.
  Offset positionOf(int offset) => Offset(
        render.paragraph!.getCaretRect(TextPosition(offset)).left + _padding,
        10,
      );

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  /// A right click at text [offset], with the clipboard probe settled.
  Future<void> rightClickAt(int offset) async {
    rightClickNow(offset);
    frame();
    await settled;
    frame();
  }

  /// The same click, without waiting for the probe: for the tests that are
  /// about what the menu says *before* the answer arrives.
  void rightClickNow(int offset) {
    final Offset position = positionOf(offset);
    _down(position, PointerButton.secondary);
    _up(position, PointerButton.secondary);
  }

  RenderContextMenuSurface? get surface => _find<RenderContextMenuSurface>();

  List<MenuItem> get items => <MenuItem>[
        for (final RenderBox child in surface?.children ?? const <RenderBox>[])
          if (child is RenderContextMenuItem) child.item,
      ];

  List<String> get labels =>
      <String>[for (final MenuItem item in items) item.label];

  MenuItem itemFor(String label) =>
      items.firstWhere((MenuItem item) => item.label == label);

  /// Clicks the row labelled [label] and settles whatever it started.
  Future<void> choose(String label) async {
    final RenderContextMenuSurface menu = surface!;
    RenderContextMenuItem? target;
    for (final RenderBox child in menu.children) {
      if (child is RenderContextMenuItem && child.item.label == label) {
        target = child;
      }
    }
    final Offset centre = target!.localToGlobal(
      const Offset(4, RenderContextMenuItem.itemHeight / 2),
    );
    _down(centre, PointerButton.primary);
    _up(centre, PointerButton.primary);
    frame();
    await settled;
    frame();
  }

  void primaryDown(Offset position) => _down(position, PointerButton.primary);

  void primaryUp(Offset position) => _up(position, PointerButton.primary);

  void _down(Offset position, PointerButton button) =>
      owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: button,
      ));

  void _up(Offset position, PointerButton button) =>
      owner.dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: button,
      ));

  void pressKey(int logicalKey, {bool control = false, bool shift = false}) {
    dispatchKey(logicalKey, control: control, shift: shift);
    frame();
  }

  bool dispatchKey(int logicalKey,
          {bool control = false, bool shift = false}) =>
      owner.dispatchKeyEvent(KeyDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: logicalKey,
        logicalKey: logicalKey,
        modifiers: <KeyModifier>{
          if (control) KeyModifier.control,
          if (shift) KeyModifier.shift,
        },
      ));

  T? _find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (node is T) found ??= node;
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return found;
  }
}

/// A [Clipboard] whose every call throws something the field has never heard
/// of: the shape of a backend with a bug, or a platform call that failed in a
/// way the port did not anticipate.
final class _HostileClipboard implements Clipboard {
  @override
  Future<String?> readText() async => throw StateError('user32 is on fire');

  @override
  Future<void> writeText(String text) async =>
      throw StateError('user32 is on fire');
}
