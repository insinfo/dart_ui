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
import '../../examples/vector_editor_demo/metrics.dart';
import '../../examples/vector_editor_demo/toolbox.dart';

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
      final harness = _Harness()..withoutSnapping();
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
      final harness = _Harness()..withoutSnapping();
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
      final harness = _Harness()..withoutSnapping();
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
  // The interactions the README named as decided but not implemented
  // -------------------------------------------------------------------------

  group('the second click swaps the frame for rotate handles', () {
    test('clicking a selected object toggles the frame, and again toggles back',
        () {
      final harness = _Harness();
      final centre = harness.rectangle.cacheBbox.center;

      harness.tapDocument(centre);
      expect(harness.model.selection.handleMode, SelectionHandleMode.scale,
          reason: 'a fresh selection is always a scale frame');

      harness.tapDocument(centre);
      expect(harness.model.selection.handleMode, SelectionHandleMode.rotate);
      expect(harness.model.selection.count, 1,
          reason: 'the second click must not change what is selected');

      harness.tapDocument(centre);
      expect(harness.model.selection.handleMode, SelectionHandleMode.scale);
      harness.dispose();
    });

    test('selecting something else puts the frame back into scale mode', () {
      final harness = _Harness();
      final rectangle = harness.rectangle;
      harness
        ..tapDocument(rectangle.cacheBbox.center)
        ..tapDocument(rectangle.cacheBbox.center);
      expect(harness.model.selection.handleMode, SelectionHandleMode.rotate);

      harness.tapDocument(harness.circle.cacheBbox.center);
      expect(harness.model.selection.handleMode, SelectionHandleMode.scale,
          reason: '"click it again to rotate it" has to mean the thing you '
              'clicked twice');
      harness.dispose();
    });

    test('dragging a corner in rotate mode turns the object', () {
      final harness = _Harness()..withoutSnapping();
      final rectangle = harness.rectangle;
      final Rect before = rectangle.cacheBbox;
      harness
        ..tapDocument(before.center)
        ..tapDocument(before.center);
      expect(harness.model.selection.handleMode, SelectionHandleMode.rotate);

      // The top-right corner, swung a quarter turn about the centre.
      final Offset pivot = before.center;
      final Offset from = Offset(before.right, before.top);
      final Offset to = Offset(
        pivot.dx - (from.dy - pivot.dy),
        pivot.dy + (from.dx - pivot.dx),
      );
      harness.dragDocument(from, to);

      final Rect after = rectangle.cacheBbox;
      expect(after.center.dx, closeTo(before.center.dx, 1.0),
          reason: 'a rotation about the centre must not move the centre');
      expect(after.center.dy, closeTo(before.center.dy, 1.0));
      // A quarter turn swaps the box's width and height.
      expect(after.width, closeTo(before.height, 1.5));
      expect(after.height, closeTo(before.width, 1.5));
      harness.dispose();
    });

    test('a rotation is one undoable step', () {
      final harness = _Harness()..withoutSnapping();
      final rectangle = harness.rectangle;
      final Rect before = rectangle.cacheBbox;
      harness
        ..tapDocument(before.center)
        ..tapDocument(before.center);

      final Offset from = Offset(before.right, before.top);
      harness.dragDocument(from, from + const Offset(0, 40));
      expect(rectangle.cacheBbox.width, isNot(closeTo(before.width, 0.5)),
          reason: 'the drag must have turned it');

      harness.model.undo();
      expect(rectangle.cacheBbox.width, closeTo(before.width, 0.5));
      expect(rectangle.cacheBbox.height, closeTo(before.height, 0.5));
      harness.dispose();
    });

    test('dragging an edge in rotate mode skews, keeping the far edge still',
        () {
      final harness = _Harness()..withoutSnapping();
      final rectangle = harness.rectangle;
      final Rect before = rectangle.cacheBbox;
      harness
        ..tapDocument(before.center)
        ..tapDocument(before.center);

      // The top edge pushed right: the bottom edge is the anchor and must not
      // move, and the box gets wider by the push.
      harness.dragDocument(
        Offset(before.center.dx, before.top),
        Offset(before.center.dx + 30, before.top),
      );

      final Rect after = rectangle.cacheBbox;
      expect(after.bottom, closeTo(before.bottom, 1.0),
          reason: 'a skew from the top edge is anchored on the bottom one');
      expect(after.height, closeTo(before.height, 1.0),
          reason: 'a horizontal skew changes no height');
      expect(after.width, closeTo(before.width + 30, 2.0),
          reason: 'the top edge travelled 30, so the box is 30 wider');
      harness.dispose();
    });

    test('the pivot can be dragged, and rotation follows it', () {
      final harness = _Harness()..withoutSnapping();
      final rectangle = harness.rectangle;
      final Rect before = rectangle.cacheBbox;
      harness
        ..tapDocument(before.center)
        ..tapDocument(before.center);

      // The pivot starts at the centre of the box; drag it onto the top-left
      // corner, which the rotation can then be checked against.
      final Offset corner = Offset(before.left, before.top);
      harness.dragDocument(before.center, corner);
      expect(harness.model.selection.pivot.dx, closeTo(corner.dx, 1.0));
      expect(harness.model.selection.pivot.dy, closeTo(corner.dy, 1.0));
      expect(harness.session.api.canUndo, isFalse,
          reason: 'moving the pivot changes no artwork, so it is not an undo '
              'step');

      // A quarter turn about that corner leaves the corner where it is and
      // swings the rest of the box round it.
      final Offset from = Offset(before.right, before.top);
      final Offset to = Offset(
        corner.dx - (from.dy - corner.dy),
        corner.dy + (from.dx - corner.dx),
      );
      harness.dragDocument(from, to);

      final Rect after = rectangle.cacheBbox;
      expect(after.left, closeTo(corner.dx - before.height, 1.5),
          reason: 'the box swung round the corner, not round its centre');
      expect(after.top, closeTo(corner.dy, 1.5));
      harness.dispose();
    });
  });

  group('Alt+click reaches what is underneath', () {
    test('a plain click takes the top object, Alt+click the one below it', () {
      final harness = _Harness();
      // A small square entirely inside the sample rectangle and added after
      // it, so it is on top and the rectangle is unreachable by a plain click
      // anywhere it covers.
      final Rect box = harness.rectangle.cacheBbox;
      final cover = VectorRectangle(
        startX: box.center.dx - 10,
        startY: box.center.dy - 10,
        rectWidth: 20,
        rectHeight: 20,
        style: const VectorStyle(
          fill: FillDescriptor.solid(Color(0xFF00AA00)),
        ),
      );
      harness.layer.children.add(cover);
      cover.update();
      harness.frame();

      harness.tapDocument(box.center);
      expect(harness.model.singleSelection, same(cover),
          reason: 'the top of the stack is what a plain click takes');

      harness.tapDocument(
        box.center,
        modifiers: const <KeyModifier>{KeyModifier.alt},
      );
      expect(harness.model.singleSelection, same(harness.rectangle),
          reason: 'Alt reaches the object under the selected one');

      // And it cycles: the stack here is two deep, so the next one wraps.
      harness.tapDocument(
        box.center,
        modifiers: const <KeyModifier>{KeyModifier.alt},
      );
      expect(harness.model.singleSelection, same(cover));
      harness.dispose();
    });

    test('Alt+click on empty space still clears the selection', () {
      final harness = _Harness();
      harness.tapDocument(harness.rectangle.cacheBbox.center);
      expect(harness.model.selection.hasSelection, isTrue);

      harness.tapDocument(
        harness.page.rect.bottomRight - const Offset(20, 20),
        modifiers: const <KeyModifier>{KeyModifier.alt},
      );
      expect(harness.model.selection.hasSelection, isFalse);
      harness.dispose();
    });
  });

  group('double-clicking the pick tool selects everything', () {
    test('two clicks on the selection tool icon select the whole page', () {
      final harness = _Harness();
      expect(harness.model.selection.hasSelection, isFalse);

      harness.doubleTapGlobal(harness.toolButtonCentre(0));

      expect(harness.model.selection.count, harness.objects.length);
      expect(harness.model.selection.count, greaterThan(1));
      harness.dispose();
    });

    test('double-clicking a creation tool does not select anything', () {
      final harness = _Harness();
      // The buttons skip the divider, so the rectangle tool's index among the
      // buttons is its index among the non-null entries.
      final List<ToolEntry> buttons =
          kToolEntries.whereType<ToolEntry>().toList();
      final int rectangle =
          buttons.indexWhere((ToolEntry e) => e.mode == ToolMode.rectangle);
      harness.doubleTapGlobal(harness.toolButtonCentre(rectangle));

      expect(harness.model.selection.hasSelection, isFalse,
          reason: 'Select All belongs to the pick tool, not to every tool');
      expect(harness.model.tool, ToolMode.rectangle);
      harness.dispose();
    });
  });

  group('snapping bends the box, not the pointer', () {
    test('a move lands an edge of the box on a grid line', () {
      final harness = _Harness();
      final SnapManager snap = harness.session.snap;
      final rectangle = harness.rectangle;
      final Rect before = rectangle.cacheBbox;

      // A drag that would leave the left edge a couple of points short of a
      // grid line. The snap is allowed six screen pixels, and the shortfall is
      // well inside that.
      final double target =
          ((before.left + 100) / snap.gridSpacing).round() * snap.gridSpacing;
      final double request = target - before.left - 3;
      harness.dragDocument(before.center, before.center + Offset(request, 0));

      final Rect after = rectangle.cacheBbox;
      expect(after.left, closeTo(target, 0.01),
          reason: 'the box edge, not the pointer, is what lands on the grid');
      expect(after.width, closeTo(before.width, 0.01),
          reason: 'a snap during a move must not resize anything');
      harness.dispose();
    });

    test('with snapping off the same drag lands where it was asked to', () {
      final harness = _Harness();
      final SnapManager snap = harness.session.snap;
      final Rect before = harness.rectangle.cacheBbox;
      final double target =
          ((before.left + 100) / snap.gridSpacing).round() * snap.gridSpacing;
      final double request = target - before.left - 3;

      harness
        ..withoutSnapping()
        ..dragDocument(before.center, before.center + Offset(request, 0));

      expect(
        harness.rectangle.cacheBbox.left,
        closeTo(before.left + request, 1),
        reason: 'the Snap switch has to be able to say no',
      );
      harness.dispose();
    });

    test('a resize snaps the dragged edge and leaves the anchored one alone',
        () {
      final harness = _Harness();
      final SnapManager snap = harness.session.snap;
      // A rectangle with no outline, so the assertion can be exact. A stroked
      // object's bounding box includes half its stroke width and the stroke
      // does not scale with the geometry, so *any* resize of one moves the
      // anchored edge of its box by a fraction of a point - a real wart, and a
      // separate one from what this test is about.
      final target = VectorRectangle(
        startX: harness.page.rect.left + 40,
        startY: harness.page.rect.top + 520,
        rectWidth: 100,
        rectHeight: 60,
        style: const VectorStyle(
          fill: FillDescriptor.solid(Color(0xFF888888)),
        ),
      );
      harness.layer.children.add(target);
      target.update();
      harness.frame();

      harness.tapDocument(target.cacheBbox.center);
      final Rect before = target.cacheBbox;

      final double grid =
          ((before.right + 40) / snap.gridSpacing).round() * snap.gridSpacing;
      final double request = grid - before.right - 3;
      harness.dragDocument(
        Offset(before.right, before.center.dy),
        Offset(before.right + request, before.center.dy),
      );

      final Rect after = target.cacheBbox;
      expect(after.right, closeTo(grid, 0.05),
          reason: 'the edge the handle drags is the one that snaps');
      expect(after.left, closeTo(before.left, 0.05),
          reason: 'a resize anchored on the left must not move the left edge - '
              'which is exactly what snapping the pointer would have done');
      harness.dispose();
    });
  });

  group('the hit test follows the outline, not the box', () {
    test('a click in the gap between two points of the star misses it', () {
      final harness = _Harness();
      final star = harness.star;
      final Rect box = star.cacheBbox;

      // The top-left corner of the star's own bounding box: inside the box and
      // a long way outside the shape. A five-pointed star fills a little over
      // half of the square it sits in, and none of that half is here.
      final Offset gap = Offset(box.left + 2, box.top + 2);
      expect(SelectionManager.hits(star, gap, 0), isFalse,
          reason: 'the corner of the box is not the star');

      harness.tapDocument(gap);
      expect(harness.model.selection.hasSelection, isFalse,
          reason: 'clicking the hole in a shape must not select the shape');
      harness.dispose();
    });

    test('a click on the body of the star still selects it', () {
      final harness = _Harness();
      final star = harness.star;

      harness.tapDocument(star.cacheBbox.center);
      expect(harness.model.singleSelection, same(star));
      harness.dispose();
    });

    test('an unfilled shape is grabbable on its outline and hollow inside', () {
      final harness = _Harness();
      final Rect page = harness.page.rect;
      final ring = VectorRectangle(
        startX: page.left + 40,
        startY: page.top + 500,
        rectWidth: 120,
        rectHeight: 80,
        style: const VectorStyle(
          stroke: StrokeDescriptor(color: Color(0xFF000000), width: 2),
        ),
      );
      harness.layer.children.add(ring);
      ring.update();
      harness.frame();

      final Rect box = ring.cacheBbox;
      expect(SelectionManager.hits(ring, box.center, 0), isFalse,
          reason: 'an unfilled rectangle is a frame, and its middle is a hole');
      expect(
        SelectionManager.hits(ring, Offset(box.left + 1, box.center.dy), 2),
        isTrue,
        reason: 'its outline is what a click has to find',
      );
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

  /// The tool box buttons, top to bottom.
  ///
  /// Found by their box rather than by their (private) widget type: a tool
  /// button is the only thing in the tool box that is exactly one control
  /// square, and asking the laid-out tree beats writing the column's
  /// arithmetic out a second time in a test.
  ///
  /// One entry per *position*: a button is a sized box wrapping a decorated
  /// box wrapping a centre, and all three are the same 28 px square, so taking
  /// every match would report three buttons for each one and index five would
  /// land on the second tool.
  List<RenderBox> get toolButtons {
    final Element? toolbox = _elementOfWidget(Toolbox);
    if (toolbox == null) return const <RenderBox>[];
    final List<RenderBox> found = <RenderBox>[];
    final Set<Offset> seen = <Offset>{};
    void walk(Element element) {
      if (element is RenderObjectElement) {
        final RenderBox render = element.renderObject;
        if (render.hasSize &&
            render.size.width == ChromeMetrics.toolboxButtonSize &&
            render.size.height == ChromeMetrics.toolboxButtonSize &&
            seen.add(render.localToGlobal(Offset.zero))) {
          found.add(render);
        }
      }
      element.visitChildren(walk);
    }

    walk(toolbox);
    return found;
  }

  Offset toolButtonCentre(int index) {
    final RenderBox button = toolButtons[index];
    return button.localToGlobal(
      Offset(button.size.width / 2, button.size.height / 2),
    );
  }

  Element? _elementOfWidget(Type type) {
    Element? found;
    void walk(Element element) {
      if (found != null) return;
      if (element.widget.runtimeType == type) {
        found = element;
        return;
      }
      element.visitChildren(walk);
    }

    walk(owner.rootElement!);
    return found;
  }

  /// Two clicks in one run, the way the platform reports them.
  void doubleTapGlobal(Offset global) {
    tapGlobal(global);
    tapGlobal(global, clickCount: 2);
  }

  /// Turns snapping off for a test that measures a drag exactly.
  ///
  /// The editor opens with snapping on, and snapping is *meant* to bend a
  /// drag: `SnapManager.correctionFor` nudges the moved box onto the nearest
  /// grid line within six screen pixels, so a 40 pt drag legitimately lands a
  /// few points away from 40. A test whose subject is the delta arithmetic -
  /// "does a document-space translation reach the object unscaled" - has to
  /// take the magnet out of the way to measure it; the tests whose subject is
  /// the magnet turn it back on.
  void withoutSnapping() {
    model.active.snap
      ..snapToGrid = false
      ..snapToGuides = false;
    model.snapToGrid = false;
    frame();
  }

  void dispose() => owner.dispose();
}
