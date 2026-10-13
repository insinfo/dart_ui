/// Modal dialogs: what they answer, and what they keep from the window
/// behind them.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const int _keyA = 0x41;
const int _keyTab = 0x09;

KeyDownEvent _down(int key) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: key,
      logicalKey: key,
    );

PointerDownEvent _press(Offset at) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerUpEvent _release(Offset at) => PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

void main() {
  late BuildOwner owner;
  late BuildContext window;
  late int windowTaps;
  late int windowShortcuts;

  Future<void> frame() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  void click(Offset at) {
    owner
      ..dispatchPointerEvent(_press(at))
      ..dispatchPointerEvent(_release(at));
  }

  setUp(() async {
    // Before mounting: the shortcuts resolve Ctrl or Cmd as they mount.
    debugEditingConventionOverride = EditingConvention.pc;
    windowTaps = 0;
    windowShortcuts = 0;
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(800, 600)),
      ),
    )..updateRoot(DartUiApp(
        home: CallbackShortcuts(
          bindings: <KeyGesture, void Function()?>{
            const KeyGesture(_keyA, command: true): () => windowShortcuts++,
          },
          child: GestureDetector(
            behavior: GestureHitTestBehavior.opaque,
            onTap: () => windowTaps++,
            child: Builder(builder: (BuildContext context) {
              window = context;
              return const SizedBox();
            }),
          ),
        ),
      ));
    await frame();
  });

  tearDown(() {
    owner.dispose();
    debugEditingConventionOverride = null;
  });

  Widget confirm(BuildContext context) => Dialog(
        title: 'Delete?',
        actions: <Widget>[
          Button(label: 'Delete', onPressed: () => closeDialog(context, true)),
          Button(label: 'Cancel', onPressed: () => closeDialog(context, false)),
        ],
        child: const Text('The file goes to the Recycle Bin.'),
      );

  test('answers with what its button closed it with', () async {
    bool? answer;
    showDialog<bool>(context: window, builder: confirm)
        .then((bool? value) => answer = value);
    await frame();
    expect(owner.modalDepth, 1);

    final RenderBox delete = _find(owner, 'Delete');
    click(delete
        .localToGlobal(Offset(delete.size.width / 2, delete.size.height / 2)));
    await frame();
    expect(answer, isTrue);
    expect(owner.modalDepth, 0);
  });

  test('the window behind takes no click while it is open', () async {
    showDialog<bool>(context: window, builder: confirm);
    await frame();
    click(const Offset(5, 5));
    await frame();
    expect(windowTaps, 0, reason: 'the barrier took it');
    expect(owner.modalDepth, 1, reason: 'and the dialog stays');
  });

  test('a click outside closes it only when asked to', () async {
    Object? answer = 'open';
    showDialog<bool>(
      context: window,
      builder: confirm,
      barrierDismissible: true,
    ).then((bool? value) => answer = value);
    await frame();
    click(const Offset(5, 5));
    await frame();
    expect(answer, isNull);
    expect(windowTaps, 0);
  });

  test("Escape closes it with no answer; the window's shortcuts are silent",
      () async {
    Object? answer = 'open';
    showDialog<bool>(context: window, builder: confirm)
        .then((bool? value) => answer = value);
    await frame();
    owner.dispatchKeyEvent(const KeyDownEvent(
      windowId: NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: _keyA,
      logicalKey: _keyA,
      modifiers: <KeyModifier>{KeyModifier.control},
    ));
    expect(windowShortcuts, 0, reason: 'Ctrl+A belongs to the window behind');
    owner.dispatchKeyEvent(_down(logicalKeyEscape));
    await frame();
    expect(answer, isNull);
    owner.dispatchKeyEvent(const KeyDownEvent(
      windowId: NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: _keyA,
      logicalKey: _keyA,
      modifiers: <KeyModifier>{KeyModifier.control},
    ));
    expect(windowShortcuts, 1, reason: 'and answers again once it closed');
  });

  test('focus goes in, Tab stays in, and focus comes back', () async {
    final FocusNode before = FocusNode(debugLabel: 'window field');
    owner.focusManager.rootScope.add(before);
    before.requestFocus();
    showDialog<bool>(context: window, builder: confirm);
    await frame();
    final FocusNode? first = owner.focusManager.primaryFocus;
    expect(first, isNot(same(before)), reason: 'the dialog took focus');
    for (var i = 0; i < 5; i++) {
      owner.dispatchKeyEvent(_down(_keyTab));
      expect(owner.focusManager.primaryFocus, isNot(same(before)),
          reason: 'Tab #$i stayed in the dialog');
    }
    owner.dispatchKeyEvent(_down(logicalKeyEscape));
    await frame();
    expect(owner.focusManager.primaryFocus, same(before));
  });

  test('dialogs stack; each closes on its own', () async {
    Object? outer = 'open';
    Object? inner = 'open';
    showDialog<String>(context: window, builder: (_) => const Text('one'))
        .then((String? v) => outer = v);
    await frame();
    late BuildContext second;
    showDialog<String>(
      context: window,
      builder: (BuildContext context) {
        second = context;
        return const Text('two');
      },
    ).then((String? v) => inner = v);
    await frame();
    expect(owner.modalDepth, 2);
    closeDialog(second, 'done');
    await frame();
    expect(inner, 'done');
    expect(outer, 'open');
    expect(owner.modalDepth, 1);
  });
}

RenderBox _find(BuildOwner owner, String label) {
  RenderBox? found;
  void walk(RenderBox node) {
    if (found != null) return;
    if (node is RenderButton && node.label == label) {
      found = node;
      return;
    }
    node.visitChildren(walk);
  }

  walk(owner.renderRoot!);
  if (found == null) throw StateError('no "$label" on screen');
  return found!;
}
