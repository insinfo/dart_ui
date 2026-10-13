/// Application shortcuts written once: Cmd on a Mac, Ctrl elsewhere.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const int _keyS = 0x53;
const int _keyZ = 0x5A;
const KeyGesture _save = KeyGesture(_keyS, command: true);

KeyDownEvent _down(int key,
        {bool meta = false, bool control = false, bool shift = false}) =>
    KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: key,
      logicalKey: key,
      modifiers: <KeyModifier>{
        if (meta) KeyModifier.meta,
        if (control) KeyModifier.control,
        if (shift) KeyModifier.shift,
      },
    );

BuildOwner _mount(Widget root) => BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      ),
    )..updateRoot(root);

void main() {
  tearDown(() => debugEditingConventionOverride = null);

  group('KeyGesture.command', () {
    test('is Command on a Mac and Control on a PC', () {
      expect(_save.resolved(EditingConvention.mac),
          const KeyGesture(_keyS, meta: true));
      expect(_save.resolved(EditingConvention.pc),
          const KeyGesture(_keyS, control: true));
      expect(_save.matches(_down(_keyS, meta: true), EditingConvention.mac),
          isTrue);
      expect(_save.matches(_down(_keyS, control: true), EditingConvention.mac),
          isFalse,
          reason: "the Mac's Control chords stay its own");
      expect(_save.matches(_down(_keyS, control: true), EditingConvention.pc),
          isTrue);
    });

    test('is labelled in each platform notation', () {
      const KeyGesture redo = KeyGesture(_keyZ, command: true, shift: true);
      expect(redo.label(EditingConvention.mac), '⇧⌘Z');
      expect(redo.label(EditingConvention.pc), 'Ctrl+Shift+Z');
      expect(const KeyGesture(0x73, alt: true).label(EditingConvention.pc),
          'Alt+F4');
      expect(const KeyGesture(0x22, command: true).label(EditingConvention.mac),
          '⌘⇟');
    });

    test('binds through a ShortcutMap', () {
      debugEditingConventionOverride = EditingConvention.mac;
      final ShortcutMap map =
          ShortcutMap(<KeyGesture, Intent>{_save: const ActivateIntent()});
      expect(map.resolve(_down(_keyS, meta: true)), isA<ActivateIntent>());
      expect(map.resolve(_down(_keyS, control: true)), isNull);
    });
  });

  group('CallbackShortcuts', () {
    for (final (EditingConvention convention, bool meta) in <(
      EditingConvention,
      bool
    )>[(EditingConvention.mac, true), (EditingConvention.pc, false)]) {
      test('runs the command from anywhere in the window (${convention.name})',
          () {
        debugEditingConventionOverride = convention;
        var saves = 0;
        final BuildOwner owner = _mount(CallbackShortcuts(
          bindings: <KeyGesture, void Function()?>{_save: () => saves++},
          child: const SizedBox(),
        ));
        expect(owner.dispatchKeyEvent(_down(_keyS, meta: meta, control: !meta)),
            isTrue);
        expect(saves, 1);
        expect(owner.dispatchKeyEvent(_down(_keyS)), isFalse,
            reason: 'a plain S is typing, not a command');
        expect(saves, 1);
      });
    }

    test('a null callback lets the key through, and unmounting unbinds', () {
      debugEditingConventionOverride = EditingConvention.mac;
      var saves = 0;
      final BuildOwner owner = _mount(CallbackShortcuts(
        bindings: <KeyGesture, void Function()?>{_save: null},
        child: const SizedBox(),
      ));
      expect(owner.dispatchKeyEvent(_down(_keyS, meta: true)), isFalse);

      owner.updateRoot(CallbackShortcuts(
        bindings: <KeyGesture, void Function()?>{_save: () => saves++},
        child: const SizedBox(),
      ));
      expect(owner.dispatchKeyEvent(_down(_keyS, meta: true)), isTrue);
      expect(saves, 1);

      owner.updateRoot(const SizedBox());
      expect(owner.dispatchKeyEvent(_down(_keyS, meta: true)), isFalse);
      expect(saves, 1);
    });
  });
}
