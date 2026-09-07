@TestOn('browser')

/// What the display list turns into, and - the half that matters more - what
/// the *second* frame does not turn into.
///
/// A DOM backend is only worth having if it edits its tree instead of rebuilding
/// it, so the assertions here are as much about `lastCreated == 0` as about the
/// markup. Every test that checks structure is paired with one that checks the
/// same structure survives a redraw with the node identity intact.
library;

import 'package:dart_ui/src/backends/web/dom/dom_scene.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'dom_session.dart';

void main() {
  late DomTestHost host;
  late DomScene scene;

  setUp(() {
    host = DomTestHost.open();
    scene = DomScene(host.element);
  });

  tearDown(() => host.close());

  List<web.Element> childrenOf(web.Element element) => <web.Element>[
        for (int i = 0; i < element.children.length; i++)
          element.children.item(i)!,
      ];

  group('boxes', () {
    test('a filled rect becomes one absolutely positioned div', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF3366CC);
      list.drawRect(10, 20, 110, 70, paint);

      scene.update(list);

      final List<web.Element> children = childrenOf(host.element);
      expect(children, hasLength(1));
      final web.Element box = children.single;
      expect(box.tagName.toLowerCase(), 'div');
      final String style = box.getAttribute('style')!;
      expect(style, contains('left:10px'));
      expect(style, contains('top:20px'));
      expect(style, contains('width:100px'));
      expect(style, contains('height:50px'));
      expect(style, contains('background-color:rgb(51,102,204)'));
      // The pointer must never stop here: the framework owns hit testing and
      // the canvas underneath is where its listeners are.
      expect(style, contains('pointer-events:none'));
    });

    test('a translucent paint keeps its alpha as a fraction', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0x80FF0000);
      list.drawRect(0, 0, 10, 10, paint);

      scene.update(list);

      expect(
        childrenOf(host.element).single.getAttribute('style'),
        contains('rgba(255,0,0,0.502'),
      );
    });

    test('a stroke grows the box by half the width on every side', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(
        colorArgb: 0xFF000000,
        style: paintStyleStroke,
        strokeWidth: 4,
      );
      list.drawRect(20, 20, 120, 60, paint);

      scene.update(list);

      // A stroke is centred on the geometric edge. Placing the border inside
      // the geometric rectangle - the obvious mistake - would give left:20px
      // and width:100px, and would draw a visibly thinner outline.
      final String style = childrenOf(host.element).single.getAttribute(
            'style',
          )!;
      expect(style, contains('left:18px'));
      expect(style, contains('top:18px'));
      expect(style, contains('width:104px'));
      expect(style, contains('height:44px'));
      expect(style, contains('border:4px solid'));
      expect(style, contains('box-sizing:border-box'));
    });

    test('a rounded rect carries all eight radii in CSS order', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF112233);
      list.drawRRect(0, 0, 100, 50, 1, 2, 3, 4, 5, 6, 7, 8, paint);

      scene.update(list);

      expect(
        childrenOf(host.element).single.getAttribute('style'),
        contains('border-radius:1px 3px 5px 7px / 2px 4px 6px 8px'),
      );
    });
  });

  group('structure', () {
    test('a transform becomes a nested group with a CSS matrix', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..save()
        ..transform(2, 0, 0, 2, 30, 40);
      list.drawRect(0, 0, 10, 10, paint);
      list.restore();

      scene.update(list);

      final web.Element group = childrenOf(host.element).single;
      final String style = group.getAttribute('style')!;
      expect(style, contains('transform:matrix(2,0,0,2,30,40)'));
      // The default `transform-origin` is the element's centre, which would
      // make every rotation orbit the middle of a box that has no size.
      expect(style, contains('transform-origin:0 0'));
      expect(childrenOf(group), hasLength(1));
    });

    test('a restore closes the group and later siblings go back outside', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..save()
        ..transform(1, 0, 0, 1, 5, 5);
      list.drawRect(0, 0, 1, 1, paint);
      list.restore();
      list.drawRect(0, 0, 2, 2, paint);

      scene.update(list);

      final List<web.Element> top = childrenOf(host.element);
      expect(top, hasLength(2), reason: 'the group, then the sibling after it');
      expect(childrenOf(top[0]), hasLength(1));
      expect(top[1].getAttribute('style'), contains('width:2px'));
    });

    test('a clip becomes overflow:hidden with the origin restored inside', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..save()
        ..clipRect(40, 30, 140, 130);
      list.drawRect(0, 0, 200, 200, paint);
      list.restore();

      scene.update(list);

      final web.Element clip = childrenOf(host.element).single;
      final String clipStyle = clip.getAttribute('style')!;
      expect(clipStyle, contains('overflow:hidden'));
      expect(clipStyle, contains('left:40px'));
      expect(clipStyle, contains('width:100px'));

      // The inner element undoes the clip's own offset, so the coordinates
      // inside a clip are still the ones the display list wrote. Without it
      // every clipped child would be displaced by the clip's origin.
      final web.Element content = childrenOf(clip).single;
      expect(content.getAttribute('style'), contains('left:-40px'));
      expect(content.getAttribute('style'), contains('top:-30px'));
      final web.Element box = childrenOf(content).single;
      expect(box.getAttribute('style'), contains('left:0px'));
    });

    test('saveLayer becomes an isolated group with the paint alpha', () {
      final DisplayList list = DisplayList();
      final int layerPaint = list.addPaint(colorArgb: 0x80000000);
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.saveLayer(0, 0, 100, 100, layerPaint);
      list.drawRect(0, 0, 10, 10, paint);
      list.restore();

      scene.update(list);

      final web.Element layer = childrenOf(host.element).single;
      final String style = layer.getAttribute('style')!;
      expect(style, contains('opacity:0.502'));
      // Without a stacking context the opacity applies per element, so two
      // overlapping children show through each other - the exact artefact
      // saveLayer exists to prevent.
      expect(style, contains('isolation:isolate'));
    });
  });

  group('reconciliation', () {
    test('an identical second frame creates nothing and writes nothing', () {
      DisplayList build() {
        final DisplayList list = DisplayList();
        final int paint = list.addPaint(colorArgb: 0xFF00FF00);
        list
          ..save()
          ..clipRect(0, 0, 50, 50);
        list.drawRect(1, 2, 3, 4, paint);
        list.restore();
        list.drawRect(5, 6, 7, 8, paint);
        return list;
      }

      scene.update(build());
      expect(scene.lastCreated, greaterThan(0));
      final web.Element clipBefore = childrenOf(host.element).first;
      final String styleBefore = clipBefore.getAttribute('style')!;

      scene.update(build());

      expect(scene.lastCreated, 0, reason: 'a steady frame must reuse');
      expect(scene.lastRemoved, 0);
      expect(scene.lastReused, greaterThan(0));
      expect(
        identical(childrenOf(host.element).first, clipBefore),
        isTrue,
        reason: 'the element must be the same object, not an equal one: '
            'focus, selection and scroll live on the node, not on its markup',
      );
      expect(clipBefore.getAttribute('style'), styleBefore);
    });

    test('a moved box reuses its element and only the style changes', () {
      DisplayList build(double left) {
        final DisplayList list = DisplayList();
        final int paint = list.addPaint(colorArgb: 0xFF000000);
        list.drawRect(left, 0, left + 10, 10, paint);
        return list;
      }

      scene.update(build(0));
      final web.Element before = childrenOf(host.element).single;
      scene.update(build(25));

      expect(scene.lastCreated, 0);
      expect(identical(childrenOf(host.element).single, before), isTrue);
      expect(before.getAttribute('style'), contains('left:25px'));
    });

    test('a slot whose kind changes is replaced, not mutated', () {
      final DisplayList first = DisplayList();
      final int paint = first.addPaint(colorArgb: 0xFF000000);
      first.drawRect(0, 0, 10, 10, paint);
      scene.update(first);
      final web.Element before = childrenOf(host.element).single;

      final DisplayList second = DisplayList();
      final int paint2 = second.addPaint(colorArgb: 0xFF000000);
      second
        ..save()
        ..transform(1, 0, 0, 1, 0, 0);
      second.drawRect(0, 0, 10, 10, paint2);
      second.restore();
      scene.update(second);

      expect(identical(childrenOf(host.element).single, before), isFalse);
      expect(scene.lastCreated, greaterThan(0));
    });

    test('a shorter frame removes the tail and leaves the head alone', () {
      final DisplayList first = DisplayList();
      final int paint = first.addPaint(colorArgb: 0xFF000000);
      for (int i = 0; i < 4; i++) {
        first.drawRect(i * 10, 0, i * 10 + 5, 5, paint);
      }
      scene.update(first);
      final web.Element head = childrenOf(host.element).first;

      final DisplayList second = DisplayList();
      final int paint2 = second.addPaint(colorArgb: 0xFF000000);
      second.drawRect(0, 0, 5, 5, paint2);
      scene.update(second);

      expect(childrenOf(host.element), hasLength(1));
      expect(identical(childrenOf(host.element).single, head), isTrue);
      expect(scene.lastRemoved, 3);
    });
  });

  group('refusals', () {
    test('a gradient is refused by name and counted, not approximated', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(
        colorArgb: 0xFF000000,
        gradient: LinearGradient(
          startX: 0,
          startY: 0,
          endX: 100,
          endY: 0,
          stops: const <GradientStop>[
            GradientStop(0, 0xFFFF0000),
            GradientStop(1, 0xFF0000FF),
          ],
        ),
      );
      list.drawRect(0, 0, 100, 10, paint);

      final List<DomRefusal> seen = <DomRefusal>[];
      scene.onRefusal = seen.add;
      scene.update(list);

      expect(childrenOf(host.element), isEmpty);
      expect(scene.refusals['gradient fill'], 1);
      expect(seen, hasLength(1));
      expect(seen.single.why, contains('spread'));
    });

    test('a difference clip is refused rather than drawn as an intersect', () {
      final DisplayList list = DisplayList();
      list
        ..save()
        ..clipRect(0, 0, 10, 10, op: clipOpDifference);
      list.restore();

      scene.update(list);

      expect(scene.refusals['clipRect(difference)'], 1);
    });

    test('the refusal callback fires once per reason, not once per command',
        () {
      final DisplayList list = DisplayList();
      for (int i = 0; i < 3; i++) {
        list
          ..save()
          ..clipRect(0, 0, 10, 10, op: clipOpDifference);
        list.restore();
      }

      int calls = 0;
      scene.onRefusal = (_) => calls++;
      scene.update(list);

      expect(calls, 1);
      expect(scene.refusals['clipRect(difference)'], 3);
    });
  });
}
