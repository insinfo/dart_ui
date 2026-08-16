/// The Fase 6 gate, run headless.
///
/// Each group here corresponds to one line of the gate in section 24 of the
/// roadmap: the gallery mounts and paints, a golden of it is stable, the whole
/// thing is operable from the keyboard alone, it exposes a semantic tree, and
/// the virtualized list realizes a bounded number of items out of ten thousand.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  // The gallery draws real text, so it draws with a real face - and which face
  // decides how wide every label is. A fixture rather than the machine's UI
  // font: a golden that depended on Segoe UI would mean nothing on the Linux
  // container this suite also has to pass in.
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
      reason: 'the gallery goldens are taken against a fixture font',
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('gallery mounts and paints headless', () {
    test('one widget tree produces one non-trivial display list', () {
      final _Harness harness = _Harness();
      final DisplayList list = harness.frame();

      // Counted by kind rather than in total. A total was a proxy for "the
      // gallery drew something", and a bad one: a label used to be one
      // rectangle per lit pixel and is now one glyph run, so the same picture
      // went from several hundred commands to under a hundred without anything
      // being lost. What the gate actually asks is that both kinds of drawing
      // are there.
      final Map<int, int> counts = _opcodeCounts(list);
      expect(counts[opDrawRect] ?? 0, greaterThan(50));
      expect(counts[opDrawGlyphRun] ?? 0, greaterThan(10),
          reason: 'every labelled control shapes and draws its own run');
      expect(harness.owner.renderRoot, isNotNull);
      harness.dispose();
    });

    test('the text it draws is the text in the tree', () {
      final _Harness harness = _Harness();
      final DisplayList list = harness.frame();

      // A glyph run carries glyph ids, not characters, so the check goes the
      // other way: shape the label the same way the control did and look for
      // that exact sequence of ids. This is what fails if a control ever
      // measures with one face and draws with another.
      final ScaledTypeface font =
          FontRegistry.instance.uiFont(ThemeData.neutralLight.fontSize)!;
      final GlyphRun run = LatinShaper().shape('Dart UI Gallery', font);
      final List<int> wanted = <int>[
        for (int i = 0; i < run.length; i++) run.glyphIds[i],
      ];

      expect(_glyphRuns(list), contains(equals(wanted)));
      harness.dispose();
    });

    test('every control type reaches the render tree', () {
      final _Harness harness = _Harness()
        ..model.menuVisible = true
        ..model.dialogVisible = true
        ..markDirty();
      harness.frame();

      final Set<Type> kinds = harness.renderTypes;
      expect(kinds, contains(RenderButton));
      expect(kinds, contains(RenderToggle));
      expect(kinds, contains(RenderSlider));
      expect(kinds, contains(RenderProgressBar));
      expect(kinds, contains(RenderTextField));
      expect(kinds, contains(RenderListBox));
      expect(kinds, contains(RenderMenu));
      expect(kinds, contains(RenderDialog));
      harness.dispose();
    });

    test('a scrolling gallery clips and reports a scrollbar', () {
      final GalleryModel model = GalleryModel();
      final BuildOwner owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(300, 200)),
        ),
      );
      owner.updateRoot(ScrollingGallery(model: model));
      owner.pipelineOwner.drawFrame(DisplayList());

      // The gallery is taller than 200 px, so there is something to scroll.
      expect(model.scroll.canScroll, isTrue);
      expect(model.scroll.thumb, isNotNull);

      final double before = model.scroll.pixels;
      model.scroll.applyScrollDelta(3, inLines: true);
      expect(model.scroll.pixels, greaterThan(before));
      owner.dispose();
    });
  });

  group('golden suite', () {
    // A golden here is the *display list*, not a PNG. It is the artifact both
    // backends consume, so a stable list is what proves the core is
    // platform-independent; a PNG would additionally be asserting things about
    // the rasterizer, which has its own tests.
    test('the same tree yields a byte-identical display list twice', () {
      final _Harness first = _Harness();
      final _Harness second = _Harness();

      expect(_signature(first.frame()), _signature(second.frame()));
      first.dispose();
      second.dispose();
    });

    test('a rebuild with no model change yields the same list', () {
      final _Harness harness = _Harness();
      final String before = _signature(harness.frame());
      final String after = _signature(harness.frame());

      expect(after, before);
      harness.dispose();
    });

    test('a model change changes the golden', () {
      final _Harness harness = _Harness();
      final String before = _signature(harness.frame());

      harness.model.checked = true;
      harness.markDirty();
      final String after = _signature(harness.frame());

      expect(after, isNot(before));
      harness.dispose();
    });

    test('each theme produces its own stable golden', () {
      final Map<String, String> signatures = <String, String>{};
      for (final ThemeData theme in <ThemeData>[
        ThemeData.neutralLight,
        ThemeData.neutralDark,
        ThemeData.fluentLight,
        ThemeData.highContrastDark,
      ]) {
        final _Harness harness = _Harness(theme: theme);
        signatures[theme.name] = _signature(harness.frame());
        harness.dispose();
      }

      // Four themes, four distinct renderings - a theme that changed nothing
      // visible would be a theme system that does not work.
      expect(signatures.values.toSet(), hasLength(4));
    });

    test('a golden survives being rasterized to real pixels', () async {
      final _Harness harness = _Harness();
      final DisplayList list = harness.frame();
      final RenderDevice device =
          await const CpuRendererBackend().createDevice();
      final MemoryRenderTarget target = device.createTarget(
        MemorySurfaceDescriptor(
          pixelWidth: galleryDesignSize.width.toInt(),
          pixelHeight: galleryDesignSize.height.toInt(),
        ),
      ) as MemoryRenderTarget;

      final result = await target.renderDisplayList(list, clearColor: 0);
      expect(result.isSuccess, isTrue);

      // Not a blank frame: a gallery that painted only its background would
      // produce one colour and pass a weaker check.
      final Framebuffer framebuffer = target.framebuffer;
      final Set<int> colors = <int>{};
      for (int y = 0; y < framebuffer.height; y += 7) {
        for (int x = 0; x < framebuffer.width; x += 7) {
          final int index = framebuffer.offsetOf(x, y);
          colors.add(framebuffer.pixels[index] |
              (framebuffer.pixels[index + 1] << 8) |
              (framebuffer.pixels[index + 2] << 16) |
              (framebuffer.pixels[index + 3] << 24));
        }
      }
      expect(colors.length, greaterThan(3));
      harness.dispose();
    });
  });

  group('keyboard-only operation', () {
    test('Tab walks every control in the gallery, in widget order', () {
      final _Harness harness = _Harness();
      harness.frame();

      final List<FocusNode> ring = harness.owner.focusManager.traversalRing();
      // Button, disabled button (still focusable), toggle, check, switch,
      // three radios, slider, two text fields, list: every interactive
      // control, and nothing that is not one.
      expect(ring.length, greaterThanOrEqualTo(11));

      harness.pressKey(logicalKeyTab);
      final FocusNode? first = harness.owner.focusManager.primaryFocus;
      expect(first, isNotNull);
      expect(first, same(ring.first));

      harness.pressKey(logicalKeyTab);
      expect(harness.owner.focusManager.primaryFocus, same(ring[1]));

      harness.pressKey(logicalKeyTab, shift: true);
      expect(harness.owner.focusManager.primaryFocus, same(ring.first));
      harness.dispose();
    });

    test('Tab wraps at the end of the ring', () {
      final _Harness harness = _Harness();
      harness.frame();
      final List<FocusNode> ring = harness.owner.focusManager.traversalRing();

      for (int i = 0; i < ring.length; i++) {
        harness.pressKey(logicalKeyTab);
      }
      expect(harness.owner.focusManager.primaryFocus, same(ring.last));

      harness.pressKey(logicalKeyTab);
      expect(harness.owner.focusManager.primaryFocus, same(ring.first));
      harness.dispose();
    });

    test('a button is pressed by Space without any pointer', () {
      final _Harness harness = _Harness();
      harness.frame();

      harness.pressKey(logicalKeyTab);
      expect(harness.model.pressCount, 0);

      harness.pressKey(logicalKeySpace);
      expect(harness.model.pressCount, 1);

      harness.pressKey(logicalKeyEnter);
      expect(harness.model.pressCount, 2);
      harness.dispose();
    });

    test('a focus ring is painted for Tab and not for a click', () {
      final _Harness harness = _Harness();
      harness.frame();

      harness.pressKey(logicalKeyTab);
      final FocusNode focused = harness.owner.focusManager.primaryFocus!;
      expect(focused.isFocusVisible, isTrue);

      focused.requestFocus(FocusChangeReason.pointer);
      expect(focused.hasPrimaryFocus, isTrue);
      expect(focused.isFocusVisible, isFalse,
          reason: 'a mouse click focuses without showing a ring');
      harness.dispose();
    });

    test('arrow keys drive the slider and the list without a pointer', () {
      final _Harness harness = _Harness();
      harness.frame();

      final RenderSlider slider = harness.findRender<RenderSlider>();
      slider.focusNode!.requestFocus(FocusChangeReason.traversal);
      final double before = harness.model.sliderValue;
      harness.pressKey(logicalKeyArrowRight);
      expect(harness.model.sliderValue, greaterThan(before));

      final RenderListBox list = harness.findRender<RenderListBox>();
      list.focusNode!.requestFocus(FocusChangeReason.traversal);
      harness.pressKey(logicalKeyArrowDown);
      expect(harness.model.listSelection, 1);
      harness.dispose();
    });
  });

  group('semantics', () {
    test('the gallery exposes a role for every interactive control', () {
      final _Harness harness = _Harness()
        ..model.menuVisible = true
        ..markDirty();
      harness.frame();

      final Set<SemanticsRole> roles = harness.owner
          .buildSemantics()
          .nodes
          .map((SemanticsNode node) => node.role)
          .toSet();

      expect(roles, contains(SemanticsRole.button));
      expect(roles, contains(SemanticsRole.checkbox));
      expect(roles, contains(SemanticsRole.radio));
      expect(roles, contains(SemanticsRole.slider));
      expect(roles, contains(SemanticsRole.textField));
      expect(roles, contains(SemanticsRole.list));
      expect(roles, contains(SemanticsRole.menu));
      harness.dispose();
    });

    test('semantic ids are stable across frames', () {
      final _Harness harness = _Harness();
      harness.frame();
      final SemanticsSnapshot first = harness.owner.buildSemantics();

      harness.model.pressCount++;
      harness.markDirty();
      harness.frame();
      final SemanticsSnapshot second = harness.owner.buildSemantics();

      final Set<int> before =
          first.nodes.map((SemanticsNode node) => node.id).toSet();
      final Set<int> after =
          second.nodes.map((SemanticsNode node) => node.id).toSet();
      // Ids are keyed by render object, and pressing a button replaces none of
      // them, so the id sets must match exactly.
      expect(after, before);
      harness.dispose();
    });

    test('an update reports only what changed', () {
      final _Harness harness = _Harness();
      harness.frame();
      harness.owner.updateSemantics();

      harness.model.checked = true;
      harness.markDirty();
      harness.frame();
      final SemanticsUpdate update = harness.owner.updateSemantics();

      expect(update.added, isEmpty);
      expect(update.removed, isEmpty);
      expect(update.updated, isNotEmpty);
      expect(
        update.updated
            .any((SemanticsNode n) => n.role == SemanticsRole.checkbox),
        isTrue,
      );
      harness.dispose();
    });

    test('the slider announces the value an increment would produce', () {
      final _Harness harness = _Harness();
      harness.frame();
      final RenderSlider slider = harness.findRender<RenderSlider>();

      final SemanticsConfiguration config = slider.describeSemantics();
      expect(config.value, '0.35');
      expect(config.increasedValue, '0.45');
      expect(config.decreasedValue, '0.25');
      expect(config.actions, contains(SemanticsAction.increment));
      harness.dispose();
    });
  });

  group('list virtualization', () {
    test('ten thousand items realize a few dozen render objects', () {
      final _Harness harness = _Harness();
      harness.frame();

      final RenderListBox list = harness.findRender<RenderListBox>();
      expect(list.virtualization.itemCount, 10000);
      expect(list.childCount, lessThan(40),
          reason: 'only the visible window plus cache may exist');
      expect(list.childCount, greaterThan(0));
      harness.dispose();
    });

    test('scrolling changes which items exist, not how many', () {
      final _Harness harness = _Harness();
      harness.frame();
      final int realizedBefore = harness.findRender<RenderListBox>().childCount;

      harness.model.listScroll.jumpTo(4000);
      harness.frame();
      final RenderListBox after = harness.findRender<RenderListBox>();

      // Not the identical count: at the top of the list the leading cache is
      // clipped away, and in the middle it is not. What must hold is that the
      // window stayed bounded while the *indices* moved by thousands.
      expect(after.childCount, closeTo(realizedBefore, 4));
      expect(after.range.firstRealized, greaterThan(100));
      harness.dispose();
    });

    test('the semantic node reports the full count, not the realized one', () {
      final _Harness harness = _Harness();
      harness.frame();

      final SemanticsNode node = harness.owner
          .buildSemantics()
          .nodes
          .firstWhere((SemanticsNode node) => node.role == SemanticsRole.list);
      expect(node.value, '10000 items');
      harness.dispose();
    });
  });

  group('the context menu demonstration', () {
    test('a right-click in the panel opens a menu with its commands', () {
      final _Harness harness = _Harness();
      harness.frame();

      harness.model.contextMenu.open(
        globalPosition: const Offset(30, 300),
        itemsBuilder: () => <MenuItem>[const MenuItem(label: 'placeholder')],
      );
      harness.frame();
      // Opened through the controller with placeholder items and then, in the
      // gallery, re-opened by the region itself: this asserts the *wiring* -
      // a scope exists, it hosts a popup, and the popup reaches the tree.
      expect(harness.renderTypes, contains(RenderContextMenuSurface));

      harness.model.contextMenu.close();
      harness.frame();
      expect(harness.renderTypes, isNot(contains(RenderContextMenuSurface)));
      harness.dispose();
    });

    test('choosing a command changes what the gallery shows', () {
      final _Harness harness = _Harness();
      harness.frame();
      expect(harness.model.lastContextCommand, isEmpty);

      final RenderContextMenuRegion region =
          harness.findRender<RenderContextMenuRegion>();
      final Offset inside = region.localToGlobal(const Offset(4, 4));
      harness.owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: inside,
        button: PointerButton.secondary,
      ));
      harness.frame();

      final RenderContextMenuSurface menu =
          harness.findRender<RenderContextMenuSurface>();
      expect(
        <String>[
          for (final RenderBox child in menu.children)
            if (child is RenderContextMenuItem) child.item.label,
        ],
        <String>['Refresh', 'Duplicate', 'Delete'],
      );

      harness
        ..pressKey(logicalKeyArrowDown)
        ..pressKey(logicalKeyEnter);

      expect(harness.model.lastContextCommand, 'Refresh');
      expect(harness.renderTypes, isNot(contains(RenderContextMenuSurface)));
      harness.dispose();
    });

    test('the tab ring is unchanged: a menu region is not a control', () {
      final _Harness harness = _Harness();
      harness.frame();
      final int before = harness.owner.focusManager.traversalRing().length;

      harness.model.contextMenu.open(
        globalPosition: const Offset(30, 300),
        itemsBuilder: () => <MenuItem>[const MenuItem(label: 'Something')],
      );
      harness.frame();

      expect(
        harness.owner.focusManager.traversalRing().length,
        before,
        reason: 'the popup skips traversal, so Tab keeps its meaning: it moves '
            'to the next control, which is what dismisses the menu',
      );
      harness.dispose();
    });
  });
}

/// Mounts the gallery in a headless owner and drives it like a window would.
final class _Harness {
  _Harness({ThemeData theme = ThemeData.neutralLight})
      : model = GalleryModel(),
        _theme = theme {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(galleryDesignSize),
      ),
    );
    owner.updateRoot(Gallery(model: model, theme: _theme));
  }

  final GalleryModel model;
  final ThemeData _theme;
  late final BuildOwner owner;

  /// Rebuilds the root, which is what a real frame does after input.
  void markDirty() => owner.updateRoot(Gallery(model: model, theme: _theme));

  /// Runs frames until the tree stops scheduling work, and returns the last
  /// one.
  ///
  /// A single build+draw is not a settled frame here, and pretending otherwise
  /// would make the goldens flaky for a real reason: the virtualized list
  /// realizes items against an *estimated* viewport until layout measures the
  /// real one, then rebuilds with the true window. Every frame after that is
  /// identical, which is exactly the property a golden should assert.
  DisplayList frame({int maxPasses = 8}) {
    DisplayList list = DisplayList();
    for (int pass = 0; pass < maxPasses; pass++) {
      list = DisplayList();
      owner.buildScope();
      owner.pipelineOwner.drawFrame(list);
      if (!owner.hasScheduledBuilds) return list;
    }
    throw StateError('the gallery never settled in $maxPasses frames');
  }

  void pressKey(int logicalKey, {bool shift = false}) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: shift ? const <KeyModifier>{KeyModifier.shift} : const {},
    ));
    // A real frame follows every input; without it the tree would be one
    // build behind what the test asserts.
    frame();
  }

  Set<Type> get renderTypes {
    final Set<Type> types = <Type>{};
    void walk(RenderBox node) {
      types.add(node.runtimeType);
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return types;
  }

  T findRender<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is T) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    if (found == null) throw StateError('no $T in the gallery render tree');
    return found!;
  }

  void dispose() => owner.dispose();
}

/// How many times each opcode appears.
Map<int, int> _opcodeCounts(DisplayList list) {
  final DisplayListReader reader = DisplayListReader(list);
  final Map<int, int> counts = <int, int>{};
  while (reader.moveNext()) {
    counts[reader.opcode] = (counts[reader.opcode] ?? 0) + 1;
  }
  return counts;
}

/// The glyph ids of every run in [list], in draw order.
///
/// The operand layout is the one `opDrawGlyphRun` documents: fontId, paintId,
/// the glyph count, then that many ids.
List<List<int>> _glyphRuns(DisplayList list) {
  final DisplayListReader reader = DisplayListReader(list);
  final List<List<int>> runs = <List<int>>[];
  while (reader.moveNext()) {
    if (reader.opcode != opDrawGlyphRun) continue;
    final int count = reader.intAt(2);
    runs.add(<int>[for (int i = 0; i < count; i++) reader.intAt(3 + i)]);
  }
  return runs;
}

/// A stable signature of a display list: what a golden compares.
String _signature(DisplayList list) {
  final DisplayListReader reader = DisplayListReader(list);
  final StringBuffer buffer = StringBuffer();
  while (reader.moveNext()) {
    buffer.write(reader.opcode);
    buffer.write(':');
    for (int i = 0; i < reader.floatOperandCount; i++) {
      buffer.write(reader.floatAt(i).toStringAsFixed(3));
      buffer.write(',');
    }
    for (int i = 0; i < reader.intOperandCount; i++) {
      buffer.write(reader.intAt(i));
      buffer.write(',');
    }
    buffer.write(';');
  }
  return buffer.toString();
}
