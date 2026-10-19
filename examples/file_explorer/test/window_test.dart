import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:file_explorer/src/engine/demo_disk.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/ui/app.dart';
import 'package:file_explorer/src/ui/explorer_window.dart';
import 'package:test/test.dart';

final class _TestWindow implements WindowController, ChildWindow {
  final children = <_TestWindow>[];
  BuildOwner? surface;
  String title = '';
  void Function()? onClosed;
  @override
  bool isOpen = true;
  @override
  HiddenTitleBarWindow? get hiddenTitleBar => null;
  @override
  bool get hasNativeMenuBar => false;
  @override
  void setTitle(String value) => title = value;
  @override
  void close() {
    if (!isOpen) return;
    isOpen = false;
    surface?.dispose();
    onClosed?.call();
  }

  @override
  Future<ChildWindow> openChildWindow(
      {required Widget child,
      String? title,
      Size size = const Size(320, 480),
      Offset? position,
      void Function()? onClosed}) async {
    final window = _TestWindow()
      ..title = title ?? ''
      ..onClosed = onClosed;
    window.surface = BuildOwner(
        pipelineOwner:
            PipelineOwner(rootConstraints: BoxConstraints.tight(size)));
    window.surface!.updateRoot(WindowScope(controller: window, child: child));
    children.add(window);
    return window;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The window on the made-up disk, with no screen.
final class _Harness {
  _Harness({ViewMode mode = ViewMode.details, UiDispatcher? dispatcher}) {
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
    final root = PopupScope(
      host: popupHost,
      child: FileExplorerApp(
        model: model,
        onReady: (ExplorerWindowState w) => window = w,
        onClose: () => closed = true,
      ),
    );
    owner.updateRoot(WindowScope(
        controller: native,
        child: dispatcher == null
            ? root
            : GestureScope(dispatcher: dispatcher, child: root)));
  }

  final native = _TestWindow();
  final popupHost = InTreePopupHost();
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
      for (final window in native.children.where((w) => w.isOpen)) {
        window.surface!.buildScope();
        window.surface!.pipelineOwner.drawFrame(DisplayList());
      }
      if (!owner.hasScheduledBuilds) return;
    }
  }

  List<T> renders<T extends RenderBox>([BuildOwner? target]) {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk((target ?? owner).renderRoot!);
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
    for (final child in native.children) {
      child.close();
    }
    owner.dispose();
    model.dispose();
  }
}

Set<KeyModifier> get _command =>
    <KeyModifier>{platformEditingConvention.commandModifier};

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('column chooser remains usable at the minimum window size', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settle();
    h.owner.pipelineOwner.rootConstraints =
        BoxConstraints.tight(const Size(640, 420));
    h.registry.execute('column.choose');
    await h.settle();
    expect(
        h.renders<RenderDialog>().single.size.height, lessThanOrEqualTo(420));
    expect(h.renders<RenderNumberBox>().single.size.height, greaterThan(0));
    h.key(logicalKeyEscape);
    await h.settle();
    expect(h.renders<RenderDialog>(), isEmpty);
  });

  test(
      'column chooser isolates drafts, reorders columns and applies typed widths',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settle();
    RenderToggle check(String label) {
      final annotation = h.renders<RenderSemanticsAnnotations>().firstWhere(
          (s) =>
              s.describeSemantics().role == SemanticsRole.checkbox &&
              s.describeSemantics().label == label);
      final found = <RenderToggle>[];
      void walk(RenderBox node) {
        if (node is RenderToggle) found.add(node);
        node.visitChildren(walk);
      }

      walk(annotation);
      return found.single;
    }

    void button(String name) =>
        h.renders<RenderButton>().firstWhere((b) => b.label == name).activate();
    Future<void> open() async {
      h.registry.execute('column.choose');
      await h.settle();
      expect(h.renders<RenderDialog>().single.title, 'Choose columns');
    }

    await open();
    expect(check('Name').enabled, isFalse);
    check('File extension').activate();
    await h.settle();
    expect(h.model.columns, isNot(contains(DetailsColumn.extension)));
    button('Cancel');
    await h.settle();
    expect(h.model.columns, isNot(contains(DetailsColumn.extension)));
    await open();
    check('File extension').activate();
    await h.settle();
    for (var i = 0; i < DetailsColumn.values.length; i++) {
      final up =
          h.renders<RenderButton>().firstWhere((b) => b.label == 'Move Up');
      if (!up.enabled) break;
      up.activate();
      await h.settle();
    }
    final number = h.renders<RenderNumberBox>().single;
    expect(number.focusNode!.requestFocus(), isTrue);
    h.owner.dispatchTextInputEvent(TextInputEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        text: '245'));
    h.key(logicalKeyEnter);
    await h.settle();
    expect(h.model.columnWidths['extension'], isNull);
    button('Apply');
    await h.settle();
    expect(h.model.columns[1], DetailsColumn.extension);
    expect(h.model.columnWidths['extension'], 245);
    button('Cancel');
    await h.settle();
    final header = h.renders<RenderDataGridHeader>().single;
    expect(header.columns[1].identity, 'extension');
    expect(header.columns[1].width, 245);
    await open();
    final search = h.renders<RenderTextField>().last;
    expect(search.focusNode!.requestFocus(), isTrue);
    h.owner.dispatchTextInputEvent(TextInputEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        text: 'Link target'));
    await h.settle();
    expect(
        h
            .renders<RenderSemanticsAnnotations>()
            .where((s) => s.describeSemantics().role == SemanticsRole.checkbox)
            .map((s) => s.describeSemantics().label),
        ['Link target']);
    check('Link target').activate();
    await h.settle();
    button('OK');
    await h.settle();
    expect(h.model.columns, contains(DetailsColumn.linkTarget));
    await open();
    button('Restore defaults');
    await h.settle();
    expect(h.model.columns, contains(DetailsColumn.linkTarget),
        reason: 'reset is also a draft');
    button('OK');
    await h.settle();
    expect(h.model.columns, [
      DetailsColumn.name,
      DetailsColumn.dateModified,
      DetailsColumn.type,
      DetailsColumn.size
    ]);
    expect(h.model.columnWidths, isEmpty);
    h.registry.execute('column.fitAll');
    await h.settle();
    expect(h.model.columnWidths.keys.toSet(), {'name', 'date', 'type', 'size'});
    expect(
        h.model.columnWidths.values.every((v) => v >= 60 && v <= 2000), isTrue);
  });

  test(
      'navigation divider resizes, clamps, hides and retains the preferred width',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settle();
    RenderSplitView split() => h.renders<RenderSplitView>().single;
    expect(split().firstExtent, 232);
    h.model.select([h.model.tab.visible.first.path]);
    await h.settle();
    final selection = h.model.tab.selection.toSet();

    Future<void> drag(double delta) async {
      final divider = h.renders<RenderSplitDivider>().single;
      final at = divider.localToGlobal(
          Offset(divider.size.width / 2, divider.size.height / 2));
      h.owner.dispatchPointerEvent(PointerDownEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: at,
          button: PointerButton.primary));
      h.owner.dispatchPointerEvent(PointerMoveEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: at + Offset(delta, 0)));
      await h.settle();
      h.owner.dispatchPointerEvent(PointerUpEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: at + Offset(delta, 0),
          button: PointerButton.primary));
      await h.settle();
    }

    await drag(268);
    expect(split().firstExtent, 500);
    expect(h.model.navigationPaneWidth, 500);
    expect(h.model.tab.selection, selection);
    h.owner.pipelineOwner.rootConstraints =
        BoxConstraints.tight(const Size(640, 600));
    await h.settle();
    expect(split().firstExtent, 314);
    expect(split().secondExtent, 320);
    expect(h.model.navigationPaneWidth, 500,
        reason: 'temporary window clamps are not saved');
    h.owner.pipelineOwner.rootConstraints =
        BoxConstraints.tight(const Size(1280, 800));
    await h.settle();
    expect(split().firstExtent, 500);
    await drag(-1000);
    expect(split().firstExtent, 160);
    expect(h.model.navigationPaneWidth, 160);
    await drag(200);
    h.model.navigationPane = false;
    h.model.notify();
    await h.settle();
    expect(h.renders<RenderSplitView>(), isEmpty);
    h.model.navigationPane = true;
    h.model.notify();
    await h.settle();
    expect(split().firstExtent, 360);
  });

  test(
      'screenshot chords preserve the view and layout changes release grid focus',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settle();
    final body = h.renders<RenderDataGridBody>().single;
    expect(body.focusNode!.requestFocus(), isTrue);
    for (final modifiers in <Set<KeyModifier>>[
      {KeyModifier.meta, KeyModifier.shift},
      {KeyModifier.meta, KeyModifier.control, KeyModifier.shift},
    ]) {
      h.key(logicalKeyDigit4, modifiers: modifiers);
      await h.settle();
      expect(h.model.viewMode, ViewMode.details);
    }
    h.key(logicalKeyDigit4,
        modifiers: {KeyModifier.control, KeyModifier.shift});
    await h.settle();
    expect(h.model.viewMode, ViewMode.smallIcons);
    // Previously the router retained the discarded DataGrid's target; even
    // the next modifier press read State.widget after dispose and threw.
    h.key(0x11, modifiers: {KeyModifier.control});
    await h.settle();
  });

  test('a slow click on the selected name edits in place in every layout',
      () async {
    for (final mode in ViewMode.values) {
      final clock = ManualDispatcher();
      final h = _Harness(mode: mode, dispatcher: clock);
      try {
        await h.settle();
        final entry = h.model.tab.visible.first;
        void click(int milliseconds) {
          final label = h
              .renders<RenderText>()
              .firstWhere((t) => t.text == h.model.shownName(entry));
          final position = label.localToGlobal(const Offset(2, 2));
          h.owner.dispatchPointerEvent(PointerDownEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration(milliseconds: milliseconds),
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: position,
              button: PointerButton.primary));
          h.owner.dispatchPointerEvent(PointerUpEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration(milliseconds: milliseconds + 1),
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: position,
              button: PointerButton.primary));
        }

        click(0);
        await h.settle();
        clock.advance(const Duration(milliseconds: 600));
        await h.settle();
        expect(h.model.tab.selection, contains(entry.path),
            reason: '$mode selects first');
        expect(h.model.tab.renaming, isNull,
            reason: '$mode must not rename on first click');
        click(1000);
        clock.advance(const Duration(milliseconds: 500));
        await h.settle();
        expect(h.model.tab.renaming, entry.path,
            reason: '$mode enters rename on the selected name');
        final field = h
            .renders<RenderTextField>()
            .firstWhere((f) => identical(f.controller, h.window.rename));
        final inside = field.localToGlobal(const Offset(12, 12));
        h.owner.dispatchPointerEvent(PointerDownEvent(
            windowId: const NativeWindowId(1),
            generation: 1,
            timestamp: const Duration(milliseconds: 2000),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: inside,
            button: PointerButton.primary));
        h.owner.dispatchPointerEvent(PointerMoveEvent(
            windowId: const NativeWindowId(1),
            generation: 1,
            timestamp: const Duration(milliseconds: 2010),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: inside + const Offset(25, 0)));
        h.owner.dispatchPointerEvent(PointerUpEvent(
            windowId: const NativeWindowId(1),
            generation: 1,
            timestamp: const Duration(milliseconds: 2020),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: inside + const Offset(25, 0),
            button: PointerButton.primary));
        await h.settle();
        expect(h.model.tab.renaming, entry.path,
            reason: '$mode must keep editing during text selection');
        expect(h.window.rename.hasSelection, isTrue,
            reason: '$mode supports drag selection');
        h.owner.dispatchPointerEvent(PointerDownEvent(
            windowId: const NativeWindowId(1),
            generation: 1,
            timestamp: const Duration(milliseconds: 2200),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: inside,
            button: PointerButton.primary,
            clickCount: 2));
        h.owner.dispatchPointerEvent(PointerUpEvent(
            windowId: const NativeWindowId(1),
            generation: 1,
            timestamp: const Duration(milliseconds: 2210),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: inside,
            button: PointerButton.primary));
        await h.settle();
        expect(h.model.tab.renaming, entry.path,
            reason:
                '$mode double-click edits text instead of opening the folder');
        expect(h.model.currentFolder, '/Users/ana/Documents');
        h.window.searchFocus.requestFocus();
        await h.settle();
        expect(h.model.tab.renaming, entry.path,
            reason: '$mode unrelated focus changes do not finish editing');
        h.window.renameFocus.requestFocus();

        h.window.rename.value = 'Discarded draft';
        h.key(logicalKeyEscape);
        await h.settle();
        expect(h.model.tab.renaming, isNull, reason: '$mode Escape cancels');
        expect(await h.model.fs.stat(entry.path), isNotNull);
        h.key(logicalKeyF2);
        await h.settle();
        expect(h.window.rename.value, entry.name,
            reason: '$mode starts a fresh edit');
        h.window.rename.value = 'Renamed folder';
        const outside = Offset(1260, 740);
        h.owner.dispatchPointerEvent(const PointerDownEvent(
            windowId: NativeWindowId(1),
            generation: 1,
            timestamp: Duration(milliseconds: 3000),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: outside,
            button: PointerButton.primary));
        h.owner.dispatchPointerEvent(const PointerUpEvent(
            windowId: NativeWindowId(1),
            generation: 1,
            timestamp: Duration(milliseconds: 3010),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: outside,
            button: PointerButton.primary));
        await h.settle();
        expect(h.model.tab.renaming, isNull,
            reason: '$mode outside click finishes editing');
        expect(await h.model.fs.stat('/Users/ana/Documents/Renamed folder'),
            isNotNull,
            reason: '$mode outside click commits the edited name');
      } finally {
        h.dispose();
      }
    }
  });

  test('Folder Options keeps drafts isolated, applies and can clear history',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settle();
    h.key(logicalKeyComma, modifiers: _command);
    await h.settle();
    expect(h.renders<RenderDialog>().single.title, 'Folder Options');
    h
        .renders<RenderToggle>()
        .firstWhere((c) => c.label == 'Single click to open items')
        .activate();
    expect(h.model.preferences['singleClick'], isFalse);
    h.renders<RenderButton>().firstWhere((b) => b.label == 'Cancel').activate();
    await h.settle();
    expect(h.model.preferences['singleClick'], isFalse);
    h.registry.execute('view.options');
    await h.settle();
    h
        .renders<RenderToggle>()
        .firstWhere((c) => c.label == 'Single click to open items')
        .activate();
    await h.settle();
    h.renders<RenderButton>().firstWhere((b) => b.label == 'Apply').activate();
    await h.settle();
    expect(h.model.preferences['singleClick'], isTrue);
    h.key(logicalKeyEscape);
    await h.settle();
    expect(h.renders<RenderDialog>(), isEmpty);
  });

  test('palette exposes commands and Content view renders metadata', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settle();
    h.key(logicalKeyP, modifiers: {..._command, KeyModifier.shift});
    await h.settle();
    expect(h.renders<RenderDialog>().single.title, 'Commands');
    expect(
        h
            .renders<RenderButton>()
            .any((b) => b.label.contains('Folder Options')),
        isTrue);
    expect(
        h.renders<RenderTextField>().single.focusNode!.hasPrimaryFocus, isTrue);
    h.owner.dispatchTextInputEvent(TextInputEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        text: 'Content'));
    await h.settle();
    h.key(logicalKeyEnter);
    await h.settle();
    expect(h.texts, contains('Adobe'));
    expect(h.renders<RenderDataGridBody>(), isEmpty);
  });

  test(
      'context clicks select the hit file or clear selection for the folder in every layout',
      () async {
    for (final mode in ViewMode.values) {
      final h = _Harness(mode: mode);
      try {
        await h.settle();
        h.model.tab.visible =
            h.model.tab.visible.where((e) => !e.isDirectory).take(2).toList();
        h.model.notify();
        await h.settle();
        final first = h.model.tab.visible[0];
        final second = h.model.tab.visible[1];
        Offset at(String name) => h
            .renders<RenderText>()
            .firstWhere((t) => t.text == name)
            .localToGlobal(const Offset(2, 2));
        void click(Offset p, {PointerButton button = PointerButton.secondary}) {
          h.owner.dispatchPointerEvent(PointerDownEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: p,
              button: button));
          h.owner.dispatchPointerEvent(PointerUpEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: const Duration(milliseconds: 1),
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: p,
              button: button));
        }

        click(at(first.name));
        await h.settle();
        expect(h.model.tab.selection, {first.path},
            reason: '$mode right click selects the hit file');
        expect(h.texts, contains('Rename'));
        h.popupHost.closeAll();
        await h.settle();
        h.model.select([first.path, second.path]);
        await h.settle();
        click(at(first.name));
        await h.settle();
        expect(h.model.tab.selection, {first.path, second.path},
            reason: '$mode preserves a selected group');
        h.popupHost.closeAll();
        await h.settle();
        h.model.select([first.path]);
        await h.settle();
        click(at(second.name));
        await h.settle();
        expect(h.model.tab.selection, {second.path},
            reason: '$mode right click replaces the selection on another file');
        h.popupHost.closeAll();
        await h.settle();
        const blank = Offset(850, 700);
        click(blank);
        await h.settle();
        expect(h.model.tab.selection, isEmpty,
            reason: '$mode right click on blank clears selection');
        expect(h.texts, contains('Refresh'),
            reason: '$mode opens folder actions');
        expect(h.texts, isNot(contains('Rename')),
            reason: '$mode does not reuse the old file menu');
        h.popupHost.closeAll();
        await h.settle();
        h.model.select([first.path]);
        await h.settle();
        click(blank, button: PointerButton.primary);
        await h.settle();
        expect(h.model.tab.selection, isEmpty,
            reason: '$mode left click on blank clears selection');
        expect(h.popupHost.openCount, 0,
            reason: '$mode left click does not open a context menu');
      } finally {
        h.dispose();
      }
    }
  });

  test('folder items have no tooltip or checkbox by default in every layout',
      () async {
    for (final mode in ViewMode.values) {
      final h = _Harness(mode: mode);
      try {
        await h.settle();
        expect(h.renders<RenderToggle>(), isEmpty,
            reason: '$mode has no selection checkboxes by default');
        final entry = h.model.tab.visible.first;
        final label = h
            .renders<RenderText>()
            .firstWhere((t) => t.text == h.model.shownName(entry));
        h.owner.dispatchPointerEvent(PointerMoveEvent(
            windowId: const NativeWindowId(1),
            generation: 1,
            timestamp: Duration.zero,
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: label.localToGlobal(const Offset(2, 2))));
        await h.settle();
        expect(h.renders<RenderTooltip>(), isEmpty,
            reason: '$mode does not show a file tooltip');
      } finally {
        h.dispose();
      }
    }
  });

  test('clicking a checkbox toggles independently of row selection and opening',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settle();
    h.model.preferences['itemCheckboxes'] = true;
    h.model.preferences['singleClick'] = true;
    h.model.notify();
    await h.settle();
    final check = h.renders<RenderToggle>().first;
    final at = check
        .localToGlobal(Offset(check.size.width / 2, check.size.height / 2));
    void click() {
      h.owner.dispatchPointerEvent(PointerDownEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: at,
          button: PointerButton.primary));
      h.owner.dispatchPointerEvent(PointerUpEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: at,
          button: PointerButton.primary));
    }

    click();
    await h.settle();
    expect(h.model.tab.selection, hasLength(1));
    expect(h.model.currentFolder, '/Users/ana/Documents');
    click();
    await h.settle();
    expect(h.model.tab.selection, isEmpty);
  });

  test('Details lists the folder, folders first, with Explorer columns',
      () async {
    final _Harness h = _Harness();
    await h.settle();
    final List<String> shown = h.texts;
    expect(shown.indexOf('Adobe'), lessThan(shown.indexOf('After Dark.mp3')));
    expect(shown, contains('20 items'));
    h.dispose();
  });

  test('New is greyed out where nothing can be made', () async {
    final _Harness h = _Harness();
    await h.settle();
    Color newColor() => h
        .renders<RenderText>()
        .firstWhere((RenderText t) => t.text == 'New')
        .color;
    final Color inFolder = newColor();
    h.registry.execute('nav.home');
    await h.settle();
    expect(newColor(), isNot(inFolder), reason: 'Home makes nothing');
    expect(h.registry.isEnabled('file.newFolder'), isFalse);
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

  test(
      'Alt+Enter opens an independent properties window and preserves owner input',
      () async {
    final h = _Harness();
    await h.settle();
    h.registry.execute('select.byName', <String, Object?>{'prefix': 'annual'});
    await h.settle();
    h.key(logicalKeyEnter, modifiers: const <KeyModifier>{KeyModifier.alt});
    await h.settle();
    final child = h.native.children.single;
    expect(child.title, 'Annual Report 2025.pdf Properties');
    expect(h.renders<RenderText>(child.surface).map((t) => t.text),
        contains('2.30 MB (2,411,724 bytes)'));
    expect(h.owner.modalDepth, 0);
    expect(h.renders<RenderDialog>(), isEmpty);
    h.registry.execute('select.byName', <String, Object?>{'prefix': 'license'});
    await h.settle();
    expect(h.model.tab.selection.single, endsWith('license.txt'));
    expect(child.isOpen, isTrue);
    child.surface!.dispatchKeyEvent(const KeyDownEvent(
        windowId: NativeWindowId(2),
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: logicalKeyEscape,
        logicalKey: logicalKeyEscape));
    await h.settle();
    expect(child.isOpen, isFalse);
    h.dispose();
  });

  test('renaming in Properties renames on OK', () async {
    final _Harness h = _Harness();
    await h.settle();
    h.registry.execute('select.byName', <String, Object?>{'prefix': 'license'});
    h.registry.execute('file.properties');
    await h.settle();
    final child = h.native.children.single;
    final RenderTextField name = h
        .renders<RenderTextField>(child.surface)
        .firstWhere((RenderTextField f) => f.controller.value == 'license.txt');
    name.controller.value = 'COPYING.txt';
    h
        .renders<RenderButton>(child.surface)
        .firstWhere((RenderButton b) => b.label == 'OK')
        .activate();
    await h.settle();
    expect(child.isOpen, isFalse);
    expect(h.texts, contains('COPYING.txt'));
    h.dispose();
  });

  test(
      'properties windows keep separate selections and Cancel discards a draft',
      () async {
    final h = _Harness();
    await h.settle();
    h.registry.execute('select.byName', <String, Object?>{'prefix': 'license'});
    h.registry.execute('file.properties');
    await h.settle();
    final first = h.native.children.single;
    h.renders<RenderTextField>(first.surface).single.controller.value =
        'Discarded.txt';
    h.registry.execute('select.byName', <String, Object?>{'prefix': 'annual'});
    h.registry.execute('file.properties');
    await h.settle();
    expect(h.native.children, hasLength(2));
    expect(h.native.children.last.title, 'Annual Report 2025.pdf Properties');
    h
        .renders<RenderButton>(first.surface)
        .firstWhere((b) => b.label == 'Cancel')
        .activate();
    await h.settle();
    expect(
        await h.model.fs.stat('/Users/ana/Documents/license.txt'), isNotNull);
    expect(await h.model.fs.stat('/Users/ana/Documents/Discarded.txt'), isNull);
    expect(h.native.children.last.isOpen, isTrue);
    h.dispose();
  });

  test('a file dragged onto a folder row lights it, and drops into it',
      () async {
    final _Harness h = _Harness();
    await h.settle();
    RenderDataGridRow rowOf(String name) =>
        h.renders<RenderDataGridRow>().firstWhere((RenderDataGridRow r) {
          bool has = false;
          void walk(RenderBox n) {
            if (n is RenderText && n.text == name) has = true;
            n.visitChildren(walk);
          }

          walk(r);
          return has;
        });
    final RenderDataGridRow folder = rowOf('Project Files');
    final Offset over =
        folder.localToGlobal(Offset(60, folder.size.height / 2));
    const String license = '/Users/ana/Documents/license.txt';
    h.model.dragging = const <String>[license];
    DragSessionEvent at(Offset p) => DragSessionEvent(
          windowId: const NativeWindowId(1),
          position: p,
          data: MemoryDragData.filePaths(const <String>[license]),
          allowedActions: const <DragAction>{DragAction.copy, DragAction.move},
        );

    final DropResponse answer = h.owner.dispatchDragUpdate(at(over));
    expect(answer.action, DragAction.move, reason: 'same drive: a move');
    await h.settle();
    expect(rowOf('Project Files').dropTarget, isTrue);

    final RenderDataGridRow file = rowOf('main.dart');
    final Offset overFile =
        file.localToGlobal(Offset(60, file.size.height / 2));
    expect(h.owner.dispatchDragUpdate(at(overFile)).isAccepted, isFalse,
        reason: 'over a file it is the folder it already is in: no move');

    h.owner.dispatchDragUpdate(at(over));
    expect(await h.owner.dispatchDrop(at(over)), DragAction.move);
    await h.settle();
    expect(await h.model.fs.stat(license), isNull);
    expect(
        await h.model.fs.stat('/Users/ana/Documents/Project Files/license.txt'),
        isNotNull);
    expect(h.texts, isNot(contains('license.txt')));
    h.dispose();
  });

  test('typing a name in the list selects it; a pause starts over', () async {
    final _Harness h = _Harness();
    await h.settle();
    h.owner.dispatchTextInputEvent(TextInputEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      text: 'h',
    ));
    h.owner.dispatchTextInputEvent(TextInputEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      text: 'i',
    ));
    await h.settle();
    expect(h.model.tab.selection,
        <String>{'/Users/ana/Documents/History of Skateboarding.docx'});
    h.dispose();
  });

  test('labels sit in the middle of their rows, as Files centres them',
      () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);
    await h.settle();
    double middle(RenderBox box) =>
        box.localToGlobal(Offset.zero).dy + box.size.height / 2;
    // The nearest box around [label] that is [height] tall: its row.
    RenderBox rowOf(String label, double height) {
      RenderBox? box =
          h.renders<RenderText>().firstWhere((RenderText t) => t.text == label);
      while (box != null && box.size.height < height - .01) {
        box = box.parent;
      }
      return box!;
    }

    // The sidebar's cards and section headers, and the status line.
    for (final (String label, double height) in <(String, double)>[
      ('Home', 28),
      ('Desktop', 28),
      ('Downloads', 28),
      ('Pinned', 28),
      ('Drives', 28),
      ('Settings', 28),
      (h.model.statusText.$1, 36),
    ]) {
      final RenderText text =
          h.renders<RenderText>().firstWhere((RenderText t) => t.text == label);
      final RenderBox row = rowOf(label, height);
      expect(row.size.height, height, reason: label);
      expect(middle(text), closeTo(middle(row), .5), reason: label);
    }
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
