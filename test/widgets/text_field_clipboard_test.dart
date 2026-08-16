/// Copy, cut and paste, and above all what happens when one of them fails.
///
/// Two bugs met here and the second is the one that had no test at all:
///
///  1. **Nothing installed a clipboard.** `RenderTextField` starts with an
///     [UnavailableClipboard], which throws on every operation, and no
///     application put a real one in the tree. That half is covered by
///     `test/app/application_clipboard_test.dart`, which drives the *default*
///     path - an application that configures nothing.
///  2. **The failure poisoned the queue.** Operations are serialised through a
///     single `Future` chain, and the chain was extended with a bare `.then()`.
///     A rejected operation therefore left that `Future` holding an error, so
///     every later link short-circuited to the same error and the field's
///     clipboard stopped working *permanently and silently* - while the
///     original error escaped as an unhandled asynchronous error, which is the
///     `_microtaskLoop` stack trace the user saw.
///
/// So the cases below are mostly about the second press after a failure, and
/// about the zone staying clean. A test that only checked the happy path would
/// pass against both the broken and the fixed version.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// Ctrl+letter, as the keyboard reports it.
const int _keyA = 0x41;
const int _keyC = 0x43;
const int _keyV = 0x56;
const int _keyX = 0x58;

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('a clipboard that works', () {
    test('Ctrl+C copies the selection and Ctrl+V pastes it back', () async {
      final FakeClipboard clipboard = FakeClipboard();
      final _Field field = _Field(clipboard, 'hello world');

      field
        ..press(_keyA, control: true)
        ..press(_keyC, control: true);
      await field.settled;

      expect(clipboard.text, 'hello world');
      expect(field.render.lastClipboardError, isNull);

      field
        ..press(_keyA, control: true)
        ..press(_keyV, control: true);
      await field.settled;

      expect(field.controller.value, 'hello world');
      expect(clipboard.reads, 1);
    });

    test('Ctrl+X copies before it deletes', () async {
      final FakeClipboard clipboard = FakeClipboard();
      final _Field field = _Field(clipboard, 'hello world')
        ..press(_keyA, control: true)
        ..press(_keyX, control: true);
      await field.settled;

      expect(clipboard.text, 'hello world');
      expect(field.controller.value, isEmpty);
    });
  });

  group('a clipboard that fails', () {
    test('the next operation still runs - the queue is not poisoned', () async {
      // The regression this file exists for. One failed Ctrl+C used to leave
      // `_clipboardWork` holding a rejected future, and every later `.then()`
      // on it went straight to that error: copy, cut and paste were dead for
      // the life of the field, with nothing on screen to say why.
      //
      // The failure has to be one the field does not already catch by name,
      // because a caught `ClipboardException` never reached the chain - which
      // is exactly why this bug survived: the only failure anybody thought to
      // try was the one that could not reproduce it.
      final _FlakyClipboard clipboard = _FlakyClipboard();
      final _Field field = _Field(clipboard, 'hello world')
        ..press(_keyA, control: true)
        ..press(_keyC, control: true);
      await field.settled;

      expect(field.render.lastClipboardError, isNotNull);
      expect(clipboard.text, isNull);

      field.press(_keyC, control: true);
      await field.settled;

      expect(
        clipboard.text,
        'hello world',
        reason: 'the second copy must reach the clipboard; a poisoned chain '
            'would have skipped the operation entirely',
      );
      expect(field.render.lastClipboardError, isNull);
    });

    test('a named ClipboardException never reaches the queue at all', () async {
      // The other half of the same statement: the two failures the field knows
      // about are handled before the queue sees them, so they leave the chain
      // untouched. Asserted so the containment stays where it is.
      final FakeClipboard clipboard = FakeClipboard()..failWith();
      final _Field field = _Field(clipboard, 'hello world')
        ..press(_keyA, control: true)
        ..press(_keyC, control: true);
      await field.settled;

      expect(field.render.lastClipboardError!.operation, 'OpenClipboard');

      clipboard.recover();
      field.press(_keyC, control: true);
      await field.settled;

      expect(clipboard.text, 'hello world');
      expect(field.render.lastClipboardError, isNull);
    });

    test('a paste after a failed copy still reads the clipboard', () async {
      final FakeClipboard clipboard = FakeClipboard()
        ..seedText('from elsewhere')
        ..failWritesWith(
          const ClipboardException(operation: 'SetClipboardData', reason: 'no'),
        );
      final _Field field = _Field(clipboard, 'hello world')
        ..press(_keyA, control: true)
        ..press(_keyC, control: true)
        ..press(_keyA, control: true)
        ..press(_keyV, control: true);
      await field.settled;

      expect(field.controller.value, 'from elsewhere');
      expect(clipboard.reads, 1);
    });

    test('the failure is observable state, not a thrown exception', () async {
      final FakeClipboard clipboard = FakeClipboard()..failWith();
      final _Field field = _Field(clipboard, 'hello world')
        ..press(_keyA, control: true)
        ..press(_keyC, control: true);

      // Awaiting the queue must not rethrow: the queue completes normally and
      // the reason is a value somebody can read.
      await field.settled;

      final ClipboardException? error = field.render.lastClipboardError;
      expect(error, isNotNull);
      expect(error!.operation, 'OpenClipboard');
      expect(error.reason, contains('holds the clipboard lock'));
    });

    test('an unexpected error is contained and named, not propagated',
        () async {
      // Not a `ClipboardException`: a `Clipboard` implementation with a bug of
      // its own. `_write` and `_read` only catch the two named types, so this
      // is exactly the error that used to escape the chain.
      final _Field field = _Field(_HostileClipboard(), 'hello world')
        ..press(_keyA, control: true)
        ..press(_keyC, control: true);
      await field.settled;

      final ClipboardException? error = field.render.lastClipboardError;
      expect(error, isNotNull);
      expect(error!.reason, contains('Bad state: user32 is on fire'));

      // And the queue is still usable afterwards.
      field.press(_keyV, control: true);
      await field.settled;
      expect(field.render.lastClipboardError, isNotNull);
    });

    test('no asynchronous error escapes to the zone', () async {
      // The user's report was a stack trace through `_microtaskLoop` printed
      // over a running gallery. That is an unhandled asynchronous error, and
      // it is what a future produced by `.then()` with no error handler does
      // when nobody is listening. Nothing here awaits the queue, precisely so
      // that "nobody is listening" is the condition under test.
      final List<Object> escaped = <Object>[];

      await runZonedGuarded(() async {
        final _Field field = _Field(_HostileClipboard(), 'hello world')
          ..press(_keyA, control: true)
          ..press(_keyC, control: true)
          ..press(_keyV, control: true);
        // Long enough for every link of the queue to run and be discarded.
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        // Read only after the fact, so the read cannot be what handles it.
        expect(field.render.lastClipboardError, isNotNull);
      }, (Object error, StackTrace stack) => escaped.add(error));

      // A few more turns outside the zone: an unhandled error is reported one
      // microtask after the future it belongs to is dropped.
      await Future<void>.delayed(Duration.zero);
      expect(escaped, isEmpty);
    });
  });

  group('a field with no clipboard in the tree', () {
    test('fails by name instead of throwing, and stays usable', () async {
      // Mounted with no [ClipboardScope] above it - a control alone in a widget
      // test. This must still be a *named* failure rather than a crash, and it
      // must not disable the field.
      final _Field field = _Field.withoutScope('hello world')
        ..press(_keyA, control: true)
        ..press(_keyC, control: true);
      await field.settled;

      expect(field.render.lastClipboardError, isNotNull);
      expect(
        field.render.lastClipboardError!.reason,
        contains('no ClipboardScope'),
      );
      expect(field.controller.selectedText, 'hello world');
    });
  });
}

/// A mounted, focused [TextField] wired to a given clipboard.
final class _Field {
  _Field(Clipboard clipboard, String text)
      : controller = TextEditingController(text) {
    owner.updateRoot(
      ClipboardScope(
        clipboard: clipboard,
        child: TextField(controller: controller),
      ),
    );
    _mount();
  }

  /// The same field with nothing publishing a clipboard above it.
  _Field.withoutScope(String text) : controller = TextEditingController(text) {
    owner.updateRoot(TextField(controller: controller));
    _mount();
  }

  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(200, 60)),
    ),
  );
  final TextEditingController controller;
  late final RenderTextField render;

  void _mount() {
    owner.pipelineOwner.drawFrame(DisplayList());
    render = owner.renderRoot! as RenderTextField;
    render.focusNode!.requestFocus();
  }

  /// Everything queued so far, settled. Never completes with an error.
  Future<void> get settled => render.clipboardSettled;

  void press(int logicalKey, {bool control = false, bool shift = false}) {
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
  }
}

/// A [Clipboard] that throws an unnamed error once and then works.
///
/// The shape of a transient platform fault: the first Ctrl+C fails, the second
/// must not. Nothing about it is clipboard-specific, which is the point - the
/// field cannot enumerate the ways a backend can break.
final class _FlakyClipboard implements Clipboard {
  String? text;
  int _writes = 0;

  @override
  Future<String?> readText() async => text;

  @override
  Future<void> writeText(String value) async {
    if (_writes++ == 0) throw StateError('the first attempt always fails');
    text = value;
  }
}

/// A [Clipboard] that throws something the field has never heard of.
///
/// Stands for the real thing it models: a backend implementation with a bug,
/// or a platform call that fails in a way the port did not anticipate. The
/// field must survive it without taking down the frame loop and without
/// breaking the *next* clipboard operation.
final class _HostileClipboard implements Clipboard {
  @override
  Future<String?> readText() async => throw StateError('user32 is on fire');

  @override
  Future<void> writeText(String text) async =>
      throw StateError('user32 is on fire');
}
