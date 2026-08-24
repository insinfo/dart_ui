/// The five interaction bugs the editor shipped with, each pinned by a test
/// that fails on the old code.
///
/// The window drew correctly and every widget existed; what was broken was the
/// route from a pointer to the document. So these tests drive the *real* widget
/// tree with real `PointerDownEvent`/`PointerMoveEvent`/`PointerUpEvent`s and
/// assert on the document and the selection afterwards - not on a controller
/// called directly, which is exactly the layer the bugs were not in.
///
/// The bugs, and the assertion that pins each:
///
///  1. **dragging the star teleported it off the page.** `applyTrafo`
///     *post*-multiplied, so a translation was applied in the object's own
///     local space. A star whose `trafo` scales by 90 moved 90 pt per pt of
///     mouse travel. `star moves by the distance the pointer moved` fails by a
///     factor of the object's scale on the old code.
///  2. **the resize handles could not be grabbed.** The handle tolerance was
///     6.0 *document units*, so at the ~0.9 zoom the editor opens at the target
///     was a 6 pt circle instead of a 6 px one, and the press fell through to
///     the object underneath and moved it instead.
///  3. **double-clicking a text did nothing.** `VectorText.updateBbox` left
///     `cacheBbox` at `Rect.zero` because text has no geometry paths, so the
///     hit test could never find a text object at all - not for a double
///     click, not for a single one.
///  4. **dragging in empty space selected nothing.** There was no marquee: a
///     press on nothing cleared the selection and the drag did nothing.
///  5. **Shift+click replaced the selection instead of extending it.** No
///     modifier ever reached the tool: `PointerEvent` carries none, and the
///     canvas took no keyboard focus, so nothing in the editor knew Shift was
///     down.
///  6. **the middle mouse button did not pan**, and
///  7. **the wheel did not zoom.** Neither event reached anything: the drag
///     recognizers decline a middle-button press by design, and nothing was
///     registered for the wheel signal.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../../examples/vector_editor_demo/app.dart';
import '../../examples/vector_editor_demo/editor_model.dart';
import '../../examples/vector_editor_demo/main_window.dart';

const Size kWindowSize = Size(1400, 880);

void main() {
  setUpAll(() {
    final fonts = FrameworkFonts.install();
    expect(fonts.uiFontLoaded, isTrue);
  });
  tearDownAll(FontRegistry.instance.reset);

  // -------------------------------------------------------------------------
  // Bug 1 - the star flew off the page
  // -------------------------------------------------------------------------

  group('bug 1: dragging an object applies a document-space delta', () {
    test('a scaled polygon moves by the pointer distance, not by scale times it',
        () {
      // The bug in isolation, at the model layer, so the failure names the
      // cause rather than the symptom. A star built exactly as the sample
      // document builds it.
      final star = VectorPolygon(
        cornersNum: 5,
        coef1: 1,
        coef2: 0.5,
        trafo: <double>[90, 0, 0, 90, 420, 145],
      )..update();
      final before = star.cacheBbox;

      star.applyTrafo(<double>[1, 0, 0, 1, 10, -20]);

      expect(star.cacheBbox.left, closeTo(before.left + 10, 1e-9),
          reason: 'a 10 pt drag must move the star 10 pt, whatever it scales');
      expect(star.cacheBbox.top, closeTo(before.top - 20, 1e-9));
      expect(star.cacheBbox.width, closeTo(before.width, 1e-9),
          reason: 'a move must not resize');
    });

    test('dragging the star in the window keeps it on the page', () {
      final harness = _Harness();
      final star = harness.star;
      final before = star.cacheBbox;

      harness.dragDocument(before.center, before.center + const Offset(40, 25));

      final after = star.cacheBbox;
      expect(after.width, closeTo(before.width, 0.5));
      expect(after.center.dx - before.center.dx, closeTo(40, 1.0));
      expect(after.center.dy - before.center.dy, closeTo(25, 1.0));
      // The regression that was reported: the star left the page entirely.
      expect(harness.page.rect.inflate(200).contains(after.center), isTrue,
          reason: 'the star must still be near the page after a 40 pt drag');
      expect(harness.model.selection.selectedObjects, contains(star));
      harness.dispose();
    });

    test('a drag is one undoable step, not one per pointer move', () {
      final harness = _Harness();
      final star = harness.star;
      final before = star.cacheBbox;

      harness.dragDocument(
        before.center,
        before.center + const Offset(40, 0),
        steps: 8,
      );
      expect(star.cacheBbox.center.dx - before.center.dx, closeTo(40, 1.0));

      harness.model.undo();
      expect(star.cacheBbox.center.dx, closeTo(before.center.dx, 0.5),
          reason: 'one undo must put the whole drag back');
      harness.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Bug 2 - the resize handles
  // -------------------------------------------------------------------------

  group('bug 2: the selection handles resize', () {
    test('a handle is grabbable in screen pixels, not document units', () {
      final harness = _Harness();
      harness.model.selection.select(harness.rectangle);
      harness.frame();

      final bounds = harness.model.selection.selectionBounds;
      // Four screen pixels away from the bottom-right handle: a miss under the
      // old six-document-unit rule at this zoom, a hit under a screen rule.
      final near = harness.canvasState
              .toGlobal(Offset(bounds.right, bounds.bottom)) +
          const Offset(3, 3);
      expect(
        harness.model.selection.hitTestHandle(
          harness.canvasState.toDocument(near),
          tolerance: SelectionManager.handleGrabPixels / harness.session.zoom,
        ),
        TransformHandle.bottomRight,
      );
      harness.dispose();
    });

    test('dragging the bottom-right handle scales from the top-left anchor',
        () {
      final harness = _Harness();
      harness.model.selection.select(harness.rectangle);
      harness.frame();

      final before = harness.rectangle.cacheBbox;
      harness.dragDocument(
        Offset(before.right, before.bottom),
        Offset(before.right + 80, before.bottom + 45),
      );

      final after = harness.rectangle.cacheBbox;
      expect(after.left, closeTo(before.left, 0.5),
          reason: 'the opposite corner is the anchor and must not move');
      expect(after.top, closeTo(before.top, 0.5));
      expect(after.width, greaterThan(before.width + 60));
      expect(after.height, greaterThan(before.height + 30));
      harness.dispose();
    });

    test('Shift keeps the aspect ratio while resizing', () {
      final harness = _Harness();
      harness.model.selection.select(harness.rectangle);
      harness.frame();

      final before = harness.rectangle.cacheBbox;
      final ratio = before.width / before.height;
      harness.dragDocument(
        Offset(before.right, before.bottom),
        Offset(before.right + 120, before.bottom + 4),
        modifiers: const <KeyModifier>{KeyModifier.shift},
      );

      final after = harness.rectangle.cacheBbox;
      expect(after.width / after.height, closeTo(ratio, 0.02));
      expect(after.width, greaterThan(before.width));
      harness.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Bug 3 - double click to edit text
  // -------------------------------------------------------------------------

  group('bug 3: text is selectable and editable in the canvas', () {
    test('a text object has a bounding box at all', () {
      final harness = _Harness();
      final box = harness.text.cacheBbox;
      expect(box.width, greaterThan(10),
          reason: 'text with no bbox can never be hit-tested');
      expect(box.height, greaterThan(4));
      expect(box.contains(Offset(box.center.dx, box.center.dy)), isTrue);
      harness.dispose();
    });

    test('clicking a text selects it', () {
      final harness = _Harness();
      harness.tapDocument(harness.text.cacheBbox.center);
      expect(harness.model.selection.selectedObjects, <Object>[harness.text]);
      harness.dispose();
    });

    test('double-clicking a text enters edit mode, typing changes it', () {
      final harness = _Harness();
      final text = harness.text;
      final original = text.textContent;

      harness.doubleTapDocument(text.cacheBbox.center);
      expect(harness.canvasState.isEditingText, isTrue,
          reason: 'a double click on a text must open the caret');

      // The caret lands where the click did - which is the point of a caret -
      // so the test steers it to a known place before typing.
      harness.key(logicalKeyEnd);
      harness.type('!');
      expect(text.textContent, isNot(original));
      expect(text.textContent, endsWith('!'));

      harness.key(logicalKeyEscape);
      expect(harness.canvasState.isEditingText, isFalse);
      harness.dispose();
    });

    test('Escape during editing restores the text and the edit is undoable',
        () {
      final harness = _Harness();
      final text = harness.text;
      final original = text.textContent;

      harness.doubleTapDocument(text.cacheBbox.center);
      harness.key(logicalKeyEnd);
      harness.type('XYZ');
      expect(text.textContent, '${original}XYZ');
      harness.key(logicalKeyEscape);
      expect(text.textContent, original,
          reason: 'Escape abandons the edit, the way sK1 does');

      harness.doubleTapDocument(text.cacheBbox.center);
      harness.key(logicalKeyEnd);
      harness.type('ok');
      harness.tapDocument(const Offset(20, 20)); // click outside commits
      expect(harness.canvasState.isEditingText, isFalse);
      expect(text.textContent, '${original}ok');

      harness.model.undo();
      expect(text.textContent, original,
          reason: 'a committed edit is one undo step');
      harness.dispose();
    });

    test('Backspace and arrow keys move a real caret', () {
      final harness = _Harness();
      final text = harness.text;
      final original = text.textContent;

      harness.doubleTapDocument(text.cacheBbox.center);
      harness.key(logicalKeyHome);
      harness.type('A');
      expect(text.textContent, 'A$original');
      harness.key(logicalKeyBackspace);
      expect(text.textContent, original);
      harness.key(logicalKeyEscape);
      harness.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Bug 4 - the marquee
  // -------------------------------------------------------------------------

  group('bug 4: rubber band selection', () {
    test('a drag in empty space selects everything it encloses', () {
      final harness = _Harness();
      final all = harness.page.children
          .whereType<VectorLayer>()
          .expand((layer) => layer.children)
          .whereType<SelectableObject>()
          .toList();
      expect(all.length, greaterThanOrEqualTo(4));

      var bounds = all.first.cacheBbox;
      for (final object in all.skip(1)) {
        bounds = bounds.union(object.cacheBbox);
      }

      harness.dragDocument(
        bounds.topLeft - const Offset(20, 20),
        bounds.bottomRight + const Offset(20, 20),
      );

      expect(harness.model.selection.count, all.length);
      harness.dispose();
    });

    test('the default rule is enclosure, sK1\'s is_bbox_in_rect', () {
      final harness = _Harness();
      final rect = harness.rectangle.cacheBbox;

      // A band that only clips the left half of the rectangle.
      harness.dragDocument(
        Offset(rect.left - 30, rect.top - 10),
        Offset(rect.center.dx, rect.bottom + 10),
      );
      expect(harness.model.selection.hasSelection, isFalse,
          reason: 'a partly covered object is not enclosed');

      // Ctrl switches to sK1\'s overlap rule.
      harness.dragDocument(
        Offset(rect.left - 30, rect.top - 10),
        Offset(rect.center.dx, rect.bottom + 10),
        modifiers: const <KeyModifier>{KeyModifier.control},
      );
      expect(harness.model.selection.selectedObjects,
          contains(harness.rectangle));
      harness.dispose();
    });

    test('the band is painted while the drag is in progress', () {
      final harness = _Harness();
      final rect = harness.rectangle.cacheBbox;
      harness.pressDocument(Offset(rect.left - 60, rect.top - 40));
      harness.moveToDocument(Offset(rect.right + 60, rect.bottom + 40));
      expect(harness.canvasState.marqueeRect, isNotNull);
      harness.releaseDocument(Offset(rect.right + 60, rect.bottom + 40));
      expect(harness.canvasState.marqueeRect, isNull);
      harness.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Bug 5 - Shift, multiple selection, grouping
  // -------------------------------------------------------------------------

  group('bug 5: Shift extends the selection and grouping follows', () {
    test('Shift+click adds to the selection and clicking again removes it', () {
      final harness = _Harness();
      harness.tapDocument(harness.rectangle.cacheBbox.center);
      expect(harness.model.selection.count, 1);

      harness.tapDocument(
        harness.circle.cacheBbox.center,
        modifiers: const <KeyModifier>{KeyModifier.shift},
      );
      expect(harness.model.selection.count, 2);
      expect(harness.model.selection.selectedObjects,
          containsAll(<Object>[harness.rectangle, harness.circle]));

      harness.tapDocument(
        harness.circle.cacheBbox.center,
        modifiers: const <KeyModifier>{KeyModifier.shift},
      );
      expect(harness.model.selection.count, 1,
          reason: 'Shift toggles, the way sK1\'s add(xor) does');
      harness.dispose();
    });

    test('a plain click after a Shift+click replaces the selection', () {
      final harness = _Harness();
      harness.tapDocument(harness.rectangle.cacheBbox.center);
      harness.tapDocument(
        harness.circle.cacheBbox.center,
        modifiers: const <KeyModifier>{KeyModifier.shift},
      );
      harness.tapDocument(harness.star.cacheBbox.center);
      expect(harness.model.selection.selectedObjects, <Object>[harness.star]);
      harness.dispose();
    });

    test('two Shift-selected objects can be grouped and ungrouped', () {
      final harness = _Harness();
      harness.tapDocument(harness.rectangle.cacheBbox.center);
      harness.tapDocument(
        harness.circle.cacheBbox.center,
        modifiers: const <KeyModifier>{KeyModifier.shift},
      );
      expect(harness.model.selection.count, 2);

      harness.model.group();
      harness.frame();
      final group = harness.model.singleSelection;
      expect(group, isA<VectorGroup>());
      expect((group! as VectorGroup).children, hasLength(2));

      // And the group moves as one, still in document space.
      final before = group.cacheBbox;
      harness.dragDocument(before.center, before.center + const Offset(15, 10));
      expect(group.cacheBbox.center.dx - before.center.dx, closeTo(15, 1.0));
      expect(group.cacheBbox.width, closeTo(before.width, 0.5));

      harness.model.ungroup();
      harness.frame();
      expect(harness.layer.children, contains(harness.rectangle));
      expect(harness.layer.children, contains(harness.circle));
      harness.dispose();
    });

    test('Shift+drag on empty space adds the enclosed objects', () {
      final harness = _Harness();
      harness.tapDocument(harness.star.cacheBbox.center);
      expect(harness.model.selection.count, 1);

      final rect = harness.rectangle.cacheBbox;
      harness.dragDocument(
        rect.topLeft - const Offset(15, 15),
        rect.bottomRight + const Offset(15, 15),
        modifiers: const <KeyModifier>{KeyModifier.shift},
      );
      expect(harness.model.selection.count, 2);
      expect(harness.model.selection.selectedObjects,
          containsAll(<Object>[harness.star, harness.rectangle]));
      harness.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Bug 6 - middle button pan, and space-drag
  // -------------------------------------------------------------------------

  group('bug 6: panning with the middle button', () {
    test('a middle-button drag moves the viewport and not the document', () {
      final harness = _Harness();
      final pan = harness.session.pan;
      final starBefore = harness.star.cacheBbox;

      harness.dragGlobal(
        harness.canvasCentre,
        harness.canvasCentre + const Offset(60, -35),
        button: PointerButton.middle,
      );

      expect(harness.session.pan.dx - pan.dx, closeTo(60, 0.5));
      expect(harness.session.pan.dy - pan.dy, closeTo(-35, 0.5));
      expect(harness.star.cacheBbox, starBefore,
          reason: 'panning must not touch the artwork');
      harness.dispose();
    });

    test('the middle button pans even over an object, in any tool', () {
      final harness = _Harness();
      harness.model.tool = ToolMode.rectangle;
      harness.frame();
      final pan = harness.session.pan;
      final count = harness.layer.children.length;

      harness.dragGlobal(
        harness.canvasState.toGlobal(harness.star.cacheBbox.center),
        harness.canvasState.toGlobal(harness.star.cacheBbox.center) +
            const Offset(-40, 20),
        button: PointerButton.middle,
      );

      expect(harness.session.pan.dx - pan.dx, closeTo(-40, 0.5));
      expect(harness.layer.children.length, count,
          reason: 'a middle drag must not draw a rectangle');
      harness.dispose();
    });

    test('holding space turns the primary drag into a pan', () {
      final harness = _Harness();
      harness.tapDocument(harness.star.cacheBbox.center);
      final pan = harness.session.pan;
      final starBefore = harness.star.cacheBbox;

      harness.keyDown(logicalKeySpace);
      harness.dragGlobal(
        harness.canvasState.toGlobal(harness.star.cacheBbox.center),
        harness.canvasState.toGlobal(harness.star.cacheBbox.center) +
            const Offset(25, 25),
      );
      harness.keyUp(logicalKeySpace);

      expect(harness.session.pan.dx - pan.dx, closeTo(25, 0.5));
      expect(harness.star.cacheBbox, starBefore);
      harness.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Bug 7 - the wheel
  // -------------------------------------------------------------------------

  group('bug 7: the wheel zooms about the cursor', () {
    test('a wheel notch changes the zoom', () {
      final harness = _Harness();
      final zoom = harness.session.zoom;
      harness.wheel(harness.canvasCentre, const Offset(0, -1));
      expect(harness.session.zoom, greaterThan(zoom));
      harness.wheel(harness.canvasCentre, const Offset(0, 1));
      harness.wheel(harness.canvasCentre, const Offset(0, 1));
      expect(harness.session.zoom, lessThan(zoom));
      harness.dispose();
    });

    test('the document point under the cursor stays under the cursor', () {
      final harness = _Harness();
      final focus = harness.canvasCentre + const Offset(120, -60);
      final before = harness.canvasState.toDocument(focus);

      harness.wheel(focus, const Offset(0, -1));
      harness.wheel(focus, const Offset(0, -1));

      final after = harness.canvasState.toDocument(focus);
      expect(after.dx, closeTo(before.dx, 0.5));
      expect(after.dy, closeTo(before.dy, 0.5));
      harness.dispose();
    });

    test('fractional trackpad deltas accumulate instead of snapping', () {
      final harness = _Harness();
      final zoom = harness.session.zoom;
      for (var i = 0; i < 10; i++) {
        harness.wheel(harness.canvasCentre, const Offset(0, -0.1));
      }
      // Ten tenths of a notch must equal about one notch, not ten of them.
      final tenTenths = harness.session.zoom / zoom;

      harness.model.setZoom(zoom);
      harness.frame();
      harness.wheel(harness.canvasCentre, const Offset(0, -1));
      final oneNotch = harness.session.zoom / zoom;

      expect(tenTenths, closeTo(oneNotch, oneNotch * 0.05));
      harness.dispose();
    });

    test('a horizontal wheel delta pans instead of zooming', () {
      final harness = _Harness();
      final zoom = harness.session.zoom;
      final pan = harness.session.pan;
      harness.wheel(harness.canvasCentre, const Offset(1, 0));
      expect(harness.session.zoom, zoom);
      expect(harness.session.pan.dx, isNot(pan.dx));
      harness.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// The harness
// ---------------------------------------------------------------------------

/// Mounts the real editor window headless and drives it like a display would.
final class _Harness {
  _Harness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(kWindowSize),
      ),
    );
    owner.updateRoot(const VectorEditorApp());
    frame();
    // Every test below starts from the select tool with nothing selected.
    model
      ..tool = ToolMode.select
      ..deselect();
    frame();
  }

  late final BuildOwner owner;

  DisplayList frame({int maxPasses = 10}) {
    var list = DisplayList();
    for (var pass = 0; pass < maxPasses; pass++) {
      list = DisplayList();
      owner.buildScope();
      owner.pipelineOwner.drawFrame(list);
      if (!owner.hasScheduledBuilds) return list;
    }
    throw StateError('the editor never settled in $maxPasses frames');
  }

  T _findState<T extends State>() {
    T? found;
    void walk(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is T) {
        found = element.state as T;
        return;
      }
      element.visitChildren(walk);
    }

    walk(owner.rootElement!);
    return found ?? (throw StateError('no $T is mounted'));
  }

  MainWindowState get windowState => _findState<MainWindowState>();
  VectorCanvasState get canvasState => _findState<VectorCanvasState>();
  EditorModel get model => windowState.model;
  DocumentSession get session => model.active;
  VectorPage get page => session.page;
  VectorLayer get layer => session.layer;

  Offset get canvasCentre => canvasState.viewportRect.center;

  List<SelectableObject> get objects =>
      layer.children.whereType<SelectableObject>().toList();

  VectorText get text => objects.whereType<VectorText>().first;
  VectorRectangle get rectangle => objects.whereType<VectorRectangle>().first;
  VectorCircle get circle => objects.whereType<VectorCircle>().first;
  VectorPolygon get star => objects.whereType<VectorPolygon>().first;

  int _pointerId = 0;
  int _millis = 0;

  Duration get _now => Duration(milliseconds: _millis += 10);

  void _down(Offset global, PointerButton button, {int clickCount = 1}) {
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointerId,
      kind: PointerKind.mouse,
      logicalPosition: global,
      button: button,
      clickCount: clickCount,
    ));
  }

  void _move(Offset global) {
    owner.dispatchPointerEvent(PointerMoveEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointerId,
      kind: PointerKind.mouse,
      logicalPosition: global,
    ));
  }

  void _up(Offset global, PointerButton button) {
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointerId,
      kind: PointerKind.mouse,
      logicalPosition: global,
      button: button,
    ));
    _pointerId++;
  }

  // --- keyboard -----------------------------------------------------------

  void keyDown(int logicalKey, {Set<KeyModifier> modifiers = const {}}) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: modifiers,
    ));
    frame();
  }

  void keyUp(int logicalKey, {Set<KeyModifier> modifiers = const {}}) {
    owner.dispatchKeyEvent(KeyUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: modifiers,
    ));
    frame();
  }

  void key(int logicalKey, {Set<KeyModifier> modifiers = const {}}) {
    keyDown(logicalKey, modifiers: modifiers);
    keyUp(logicalKey, modifiers: modifiers);
  }

  void type(String text) {
    owner.dispatchTextInputEvent(TextInputEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      text: text,
    ));
    frame();
  }

  /// Holds [modifiers] for the duration of [body], the way a real user does:
  /// the key transition arrives first and the pointer sequence follows.
  void _withModifiers(Set<KeyModifier> modifiers, void Function() body) {
    if (modifiers.isEmpty) {
      body();
      return;
    }
    // Shift/Ctrl press: virtual keys 0x10 and 0x11.
    for (final modifier in modifiers) {
      keyDown(modifier == KeyModifier.shift ? 0x10 : 0x11,
          modifiers: modifiers);
    }
    body();
    for (final modifier in modifiers) {
      keyUp(modifier == KeyModifier.shift ? 0x10 : 0x11,
          modifiers: const <KeyModifier>{});
    }
  }

  // --- pointer gestures ---------------------------------------------------

  void tapGlobal(Offset global,
      {Set<KeyModifier> modifiers = const {}, int clickCount = 1}) {
    _withModifiers(modifiers, () {
      _down(global, PointerButton.primary, clickCount: clickCount);
      _up(global, PointerButton.primary);
    });
    frame();
  }

  void dragGlobal(
    Offset from,
    Offset to, {
    int steps = 6,
    Set<KeyModifier> modifiers = const {},
    PointerButton button = PointerButton.primary,
  }) {
    _withModifiers(modifiers, () {
      _down(from, button);
      for (var step = 1; step <= steps; step++) {
        _move(Offset(
          from.dx + (to.dx - from.dx) * step / steps,
          from.dy + (to.dy - from.dy) * step / steps,
        ));
      }
      _up(to, button);
    });
    frame();
  }

  void wheel(Offset global, Offset delta) {
    owner.dispatchPointerEvent(PointerScrollEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: global,
      scrollDelta: delta,
      scrollDeltaUnit: ScrollDeltaUnit.lines,
    ));
    frame();
  }

  // --- the same, in document coordinates ----------------------------------

  Offset _toGlobal(Offset document) => canvasState.toGlobal(document);

  void tapDocument(Offset document,
          {Set<KeyModifier> modifiers = const {}}) =>
      tapGlobal(_toGlobal(document), modifiers: modifiers);

  void doubleTapDocument(Offset document) {
    final global = _toGlobal(document);
    tapGlobal(global);
    tapGlobal(global, clickCount: 2);
  }

  void dragDocument(
    Offset from,
    Offset to, {
    int steps = 6,
    Set<KeyModifier> modifiers = const {},
  }) =>
      dragGlobal(_toGlobal(from), _toGlobal(to),
          steps: steps, modifiers: modifiers);

  void pressDocument(Offset document) {
    _down(_toGlobal(document), PointerButton.primary);
    frame();
  }

  void moveToDocument(Offset document, {int steps = 6}) {
    final target = _toGlobal(document);
    for (var step = 1; step <= steps; step++) {
      _move(target);
    }
    frame();
  }

  void releaseDocument(Offset document) {
    _up(_toGlobal(document), PointerButton.primary);
    frame();
  }

  void dispose() => owner.dispose();
}
