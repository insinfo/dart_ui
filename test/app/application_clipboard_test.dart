/// Ctrl+C and Ctrl+V through an application that configured nothing.
///
/// This is the bug's actual shape. `RenderTextField` had working copy, cut and
/// paste and a suite that proved it - by handing the field a clipboard the test
/// had built itself. Nothing installed one in a *real* application:
/// `ApplicationOptions.clipboard` defaulted to null, the shell turned that into
/// an `UnavailableClipboard`, and every clipboard chord in `gallery_win32.dart`
/// failed at the port. Ctrl+A worked, because Ctrl+A never leaves the process.
///
/// So every case here goes through `Application.start` with **no clipboard
/// passed**, and drives the production frame loop and the production event
/// route. The clipboard they exercise is the one the selected backend
/// supplied, which is exactly what a real `main` gets. A test that installed a
/// `ClipboardScope` of its own would be back to proving the thing that was
/// never broken.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const int _keyA = 0x41;
const int _keyC = 0x43;
const int _keyV = 0x56;

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('the default path', () {
    test('the backend supplies the clipboard when nobody else does', () async {
      final controller = TextEditingController('hello world');
      final application = await _start(controller);

      // Not an UnavailableClipboard: the shell asked the backend it selected.
      expect(application.clipboard, isA<FakeClipboard>());
      expect(
        identical(
          application.clipboard,
          (application.backend as HeadlessWindowingBackend).clipboard,
        ),
        isTrue,
      );

      await _stop(application);
    });

    test('Ctrl+C really copies, with nothing configured', () async {
      final controller = TextEditingController('hello world');
      final application = await _start(controller);
      final clipboard = _clipboardOf(application);

      _focusField(application);
      _press(application, _keyA, control: true);
      _press(application, _keyC, control: true);
      await _fieldOf(application).clipboardSettled;

      expect(clipboard.text, 'hello world');
      expect(clipboard.writes, 1);
      expect(_fieldOf(application).lastClipboardError, isNull);

      await _stop(application);
    });

    test('Ctrl+V really pastes, with nothing configured', () async {
      final controller = TextEditingController('');
      final application = await _start(controller);
      // Seeded the way another application would have: not through the field.
      _clipboardOf(application).seedText('pasted from elsewhere');

      _focusField(application);
      _press(application, _keyV, control: true);
      await _fieldOf(application).clipboardSettled;

      expect(controller.value, 'pasted from elsewhere');
      expect(_fieldOf(application).lastClipboardError, isNull);

      await _stop(application);
    });

    test('a round trip through the clipboard survives the frame loop',
        () async {
      final controller = TextEditingController('round trip');
      final application = await _start(controller);

      _focusField(application);
      _press(application, _keyA, control: true);
      _press(application, _keyC, control: true);
      await _fieldOf(application).clipboardSettled;

      // A frame in between, so nothing depends on the operation finishing
      // inside the keystroke that started it.
      await application.drawFrame();

      _press(application, _keyA, control: true);
      _press(application, _keyV, control: true);
      await _fieldOf(application).clipboardSettled;

      expect(controller.value, 'round trip');

      await _stop(application);
    });

    test('a failed copy leaves the next one working', () async {
      final controller = TextEditingController('hello world');
      final application = await _start(controller);
      final clipboard = _clipboardOf(application)..failWith();

      _focusField(application);
      _press(application, _keyA, control: true);
      _press(application, _keyC, control: true);
      await _fieldOf(application).clipboardSettled;

      expect(_fieldOf(application).lastClipboardError, isNotNull);
      expect(clipboard.text, isNull);

      clipboard.recover();
      _press(application, _keyC, control: true);
      await _fieldOf(application).clipboardSettled;

      expect(clipboard.text, 'hello world');
      expect(_fieldOf(application).lastClipboardError, isNull);

      await _stop(application);
    });

    test('the frame loop keeps running after a clipboard failure', () async {
      // The visible symptom was a stack trace printed over the gallery. A
      // clipboard failure must be an event in the application, not an event in
      // the isolate.
      final controller = TextEditingController('hello world');
      final application = await _start(controller);
      _clipboardOf(application).failWith();

      _focusField(application);
      _press(application, _keyA, control: true);
      _press(application, _keyC, control: true);
      _press(application, _keyV, control: true);
      await _fieldOf(application).clipboardSettled;

      await application.run(frameBudget: 3);
      expect(application.framesRejected, 0);
      expect(application.errors, isEmpty);

      await _stop(application);
    });
  });

  group('an explicit clipboard', () {
    test('still wins over the backend it is running on', () async {
      final own = FakeClipboard()..seedText('mine');
      final controller = TextEditingController('');
      final application = await _start(controller, clipboard: own);

      expect(identical(application.clipboard, own), isTrue);

      _focusField(application);
      _press(application, _keyV, control: true);
      await _fieldOf(application).clipboardSettled;

      expect(controller.value, 'mine');
      expect(
        _clipboardOf(application).reads,
        0,
        reason: "the backend's own clipboard was not consulted",
      );

      await _stop(application);
    });
  });
}

Future<Application> _start(
  TextEditingController controller, {
  Clipboard? clipboard,
}) async {
  final application = await Application.start(
    rootWidget: ColoredBox(
      color: 0xFF101010,
      child: TextField(controller: controller),
    ),
    backends: <WindowingBackendEntry>[
      const WindowingBackendEntry(
        name: 'headless',
        create: HeadlessWindowingBackend.new,
      ),
    ],
    options: ApplicationOptions(
      title: 'clipboard',
      size: const Size(200, 60),
      clipboard: clipboard,
    ),
  );
  // One frame so the render tree exists and can be found and focused.
  await application.drawFrame();
  return application;
}

Future<void> _stop(Application application) async {
  application.dispose();
  await application.closed;
}

FakeClipboard _clipboardOf(Application application) =>
    (application.backend as HeadlessWindowingBackend).clipboard;

/// The one [RenderTextField] in the mounted tree.
RenderTextField _fieldOf(Application application) {
  RenderTextField? found;
  void walk(RenderBox node) {
    if (found == null && node is RenderTextField) found = node;
    node.visitChildren(walk);
  }

  walk(application.buildOwner.renderRoot!);
  return found!;
}

/// Gives the field the keyboard the way a click in it would.
void _focusField(Application application) =>
    _fieldOf(application).focusNode!.requestFocus();

/// Sends a key through the production event route, not into the widget.
void _press(
  Application application,
  int logicalKey, {
  bool control = false,
  bool shift = false,
}) {
  final window = application.window as HeadlessWindow;
  window.dispatchInput(KeyDownEvent(
    windowId: window.id,
    generation: window.generation,
    timestamp: Duration.zero,
    physicalKey: logicalKey,
    logicalKey: logicalKey,
    modifiers: <KeyModifier>{
      if (control) KeyModifier.control,
      if (shift) KeyModifier.shift,
    },
  ));
  application.backend.pumpEvents();
}
