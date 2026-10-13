import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:file_explorer/src/engine/demo_disk.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/ui/app.dart';
import 'package:file_explorer/src/ui/explorer_window.dart';
import 'package:test/test.dart';

/// The window on the made-up disk, with no screen.
final class _Harness {
  _Harness({ViewMode mode = ViewMode.details}) {
    model = ExplorerModel(
      fs: demoDisk(),
      places: kDemoPlaces,
      start: const FolderLocation('/Users/ana/Documents'),
    )..viewMode = mode;
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(1280, 800)),
      ),
    );
    owner.updateRoot(PopupScope(
      host: InTreePopupHost(),
      child: FileExplorerApp(
        model: model,
        onReady: (ExplorerWindowState w) => window = w,
        onClose: () => closed = true,
      ),
    ));
  }

  late final ExplorerModel model;
  late final BuildOwner owner;
  late ExplorerWindowState window;
  bool closed = false;

  CommandRegistry get registry => window.registry;

  Future<void> settle() async {
    for (var pass = 0; pass < 12; pass++) {
      await Future<void>.delayed(Duration.zero);
      await model.idle;
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  List<T> renders<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  List<String> get texts => <String>[
        for (final RenderText t in renders<RenderText>()) t.text,
      ];

  void key(int logicalKey, {Set<KeyModifier> modifiers = const {}}) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: modifiers,
    ));
  }

  void dispose() {
    owner.dispose();
    model.dispose();
  }
}

Set<KeyModifier> get _command =>
    <KeyModifier>{platformEditingConvention.commandModifier};

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('Details lists the folder, folders first, with Explorer columns',
      () async {
    final _Harness h = _Harness();
    await h.settle();
    final List<String> shown = h.texts;
    expect(shown.indexOf('Adobe'), lessThan(shown.indexOf('After Dark.mp3')));
    expect(shown, contains('20 items'));
    h.dispose();
  });

  test('Ctrl+T opens a Home tab; Ctrl+W closes it; the last closes the window',
      () async {
    final _Harness h = _Harness();
    await h.settle();
    h.key(logicalKeyT, modifiers: _command);
    await h.settle();
    expect(h.model.tabs, hasLength(2));
    expect(h.texts, contains('Quick access'));
    h.key(logicalKeyW, modifiers: _command);
    await h.settle();
    expect(h.model.tabs, hasLength(1));
    h.key(logicalKeyW, modifiers: _command);
    expect(h.closed, isTrue);
    h.dispose();
  });

  test('F2 puts a field over the name; Enter renames', () async {
    final _Harness h = _Harness();
    await h.settle();
    h.registry.execute('select.byName', <String, Object?>{'prefix': 'license'});
    // The keys are bound as the window last built them.
    await h.settle();
    h.key(logicalKeyF2);
    await h.settle();
    final RenderTextField field = h
        .renders<RenderTextField>()
        .firstWhere((RenderTextField f) => f.controller.value == 'license.txt');
    expect(field.controller.selectionStart, 0);
    expect(field.controller.selectionEnd, 'license'.length,
        reason: 'the name is selected without its extension');
    field.onSubmitted!('LICENSE-MIT.txt');
    await h.settle();
    expect(h.texts, contains('LICENSE-MIT.txt'));
    h.dispose();
  });

  test('the icon views draw every item', () async {
    final _Harness h = _Harness(mode: ViewMode.largeIcons);
    await h.settle();
    expect(h.texts, containsAll(<String>['Adobe', 'license.txt']));
    h.dispose();
  });

  test('the engine imports no widget and no dart:io', () {
    for (final FileSystemEntity f
        in Directory('lib/src/engine').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String source = f.readAsStringSync();
      expect(source, isNot(contains("import 'dart:io'")), reason: f.path);
      expect(source, isNot(contains('package:dart_ui/dart_ui.dart')),
          reason: '${f.path} - the engine takes commands.dart only');
    }
  });
}
