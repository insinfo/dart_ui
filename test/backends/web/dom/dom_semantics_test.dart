@TestOn('browser')

/// The half of a DOM backend that a canvas cannot fake at all: real roles, real
/// names, real keyboard focus, in real DOM order.
///
/// The vocabulary comes from `semantics/semantics.dart` and **not** from
/// `ContentHint` - see `dom_semantics_layer.dart` for why that matters and what
/// it cost to find out. These tests build snapshots by hand rather than through
/// a widget tree, because the thing under test is the mapping from a semantic
/// node to an element, and a widget tree would put three layers of unrelated
/// behaviour between the input and the assertion.
library;

import 'package:dart_ui/src/backends/web/dom/dom_semantics_layer.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/semantics/semantics.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'dom_session.dart';

void main() {
  late DomTestHost host;
  late DomSemanticsLayer layer;

  setUp(() {
    host = DomTestHost.open();
    layer = DomSemanticsLayer(host.element);
  });

  tearDown(() {
    layer.clear();
    host.close();
  });

  SemanticsNode node({
    required int id,
    required SemanticsRole role,
    String? label,
    Rect bounds = const Rect.fromLTRB(0, 0, 100, 40),
    Set<SemanticsState> states = const <SemanticsState>{},
    Set<SemanticsAction> actions = const <SemanticsAction>{},
    List<SemanticsNode> children = const <SemanticsNode>[],
  }) =>
      SemanticsNode(
        id: id,
        role: role,
        bounds: bounds,
        label: label,
        states: states,
        actions: actions,
        children: children,
      );

  List<web.Element> query(String selector) {
    final web.NodeList found = host.element.querySelectorAll(selector);
    return <web.Element>[
      for (int i = 0; i < found.length; i++) found.item(i)! as web.Element,
    ];
  }

  group('roles', () {
    test('a button becomes a native <button>, not a div wearing a role', () {
      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.button,
        label: 'Save',
        actions: <SemanticsAction>{SemanticsAction.activate},
      )));

      final List<web.Element> buttons = query('button');
      expect(buttons, hasLength(1));
      expect(buttons.single.getAttribute('aria-label'), 'Save');
      // A native button is focusable, Enter- and Space-activatable and known to
      // assistive technology that predates ARIA; a `[role=button]` div gets
      // none of that for free.
      expect(buttons.single.getAttribute('tabindex'), isNull);
      expect(buttons.single.getAttribute('type'), 'button');
    });

    test('a checkbox carries a tri-state aria-checked', () {
      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.checkbox,
        label: 'Wrap lines',
        states: <SemanticsState>{SemanticsState.mixed},
      )));

      final web.Element box = query('[role=checkbox]').single;
      // Announcing a tri-state control as "checked" tells the user the wrong
      // thing about what pressing it will do.
      expect(box.getAttribute('aria-checked'), 'mixed');

      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.checkbox,
        label: 'Wrap lines',
      )));
      expect(query('[role=checkbox]').single.getAttribute('aria-checked'),
          'false');
    });

    test('generic and text nodes publish nothing and stay transparent', () {
      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.generic,
        children: <SemanticsNode>[
          node(
            id: 2,
            role: SemanticsRole.text,
            label: 'a paragraph',
            children: <SemanticsNode>[
              node(id: 3, role: SemanticsRole.button, label: 'inside'),
            ],
          ),
        ],
      )));

      // The paragraph is already in the visual layer as real text; publishing
      // it here as well would put every sentence in the page into the
      // accessibility tree twice.
      expect(query('[role=text]'), isEmpty);
      // The button under it still attaches, to the nearest ancestor that does
      // publish - which here is the layer root.
      final web.Element button = query('button').single;
      expect(button.parentElement, host.element);
    });

    test('states become the aria attributes a screen reader reads', () {
      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.textField,
        label: 'Name',
        states: <SemanticsState>{
          SemanticsState.required,
          SemanticsState.invalid,
          SemanticsState.readOnly,
        },
      )));

      final web.Element field = query('[role=textbox]').single;
      expect(field.getAttribute('aria-required'), 'true');
      expect(field.getAttribute('aria-invalid'), 'true');
      expect(field.getAttribute('aria-readonly'), 'true');
      expect(field.getAttribute('aria-disabled'), isNull);
    });
  });

  group('geometry and order', () {
    test('a nested node is positioned relative to its parent, not the root',
        () {
      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.list,
        bounds: const Rect.fromLTRB(50, 100, 250, 300),
        children: <SemanticsNode>[
          node(
            id: 2,
            role: SemanticsRole.listItem,
            bounds: const Rect.fromLTRB(60, 120, 240, 160),
          ),
        ],
      )));

      // Bounds arrive in root coordinates and the DOM is nested, so a nested
      // element written with root coordinates would compound every offset down
      // the tree - the symptom being a focus ring that drifts further down the
      // page the deeper the control sits.
      final web.Element item = query('[role=listitem]').single;
      final String style = item.getAttribute('style')!;
      expect(style, contains('left:10px'));
      expect(style, contains('top:20px'));
      expect(style, contains('width:180px'));
    });

    test('DOM order follows tree order, which is what Tab order is', () {
      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.list,
        children: <SemanticsNode>[
          node(id: 2, role: SemanticsRole.button, label: 'first'),
          node(id: 3, role: SemanticsRole.button, label: 'second'),
          node(id: 4, role: SemanticsRole.button, label: 'third'),
        ],
      )));

      expect(
        query('button').map((web.Element e) => e.getAttribute('aria-label')),
        <String>['first', 'second', 'third'],
      );
    });

    test('reordering by id moves the element rather than replacing it', () {
      SemanticsSnapshot snapshot(List<int> order) => SemanticsSnapshot(node(
            id: 1,
            role: SemanticsRole.list,
            children: <SemanticsNode>[
              for (final int id in order)
                node(id: id, role: SemanticsRole.button, label: 'b$id'),
            ],
          ));

      layer.update(snapshot(<int>[2, 3, 4]));
      final web.Element second = query('button')[1];

      layer.update(snapshot(<int>[4, 3, 2]));

      expect(
        query('button').map((web.Element e) => e.getAttribute('aria-label')),
        <String>['b4', 'b3', 'b2'],
      );
      // The middle one did not move in the list and must not have moved in the
      // DOM either: re-inserting a focused element blurs it in some engines,
      // which would make Tab unusable on a page that redraws while tabbing.
      expect(identical(query('button')[1], second), isTrue);
    });
  });

  group('focus', () {
    test('a published control can actually take focus', () {
      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.button,
        label: 'Focus me',
      )));

      final web.HTMLElement button = query('button').single as web.HTMLElement;
      button.focus();

      expect(
        web.document.activeElement,
        button,
        reason: 'this is the assertion no canvas backend can pass',
      );
    });

    test('focus survives a frame that moved and relabelled the control', () {
      SemanticsSnapshot snapshot(String label, double top) =>
          SemanticsSnapshot(node(
            id: 7,
            role: SemanticsRole.button,
            label: label,
            bounds: Rect.fromLTRB(0, top, 100, top + 30),
          ));

      layer.update(snapshot('Save', 0));
      final web.HTMLElement button = query('button').single as web.HTMLElement;
      button.focus();
      expect(web.document.activeElement, button);

      layer.update(snapshot('Save changes', 40));

      expect(identical(query('button').single, button), isTrue);
      expect(button.getAttribute('aria-label'), 'Save changes');
      expect(
        web.document.activeElement,
        button,
        reason: 'the semantic id is stable across frames, so the element is '
            'too, so the focus is',
      );
    });

    test('a control that leaves the tree loses its element and its listeners',
        () {
      layer.update(SemanticsSnapshot(node(
        id: 1,
        role: SemanticsRole.list,
        children: <SemanticsNode>[
          node(id: 2, role: SemanticsRole.button, label: 'going'),
        ],
      )));
      expect(layer.publishedNodeCount, 2);

      layer.update(SemanticsSnapshot(node(id: 1, role: SemanticsRole.list)));

      expect(query('button'), isEmpty);
      expect(layer.publishedNodeCount, 1);
    });
  });

  group('activation', () {
    test('a click on a published button reports the semantic id', () {
      final List<(int, SemanticsAction)> raised = <(int, SemanticsAction)>[];
      layer.onAction =
          (int id, SemanticsAction action) => raised.add((id, action));

      layer.update(SemanticsSnapshot(node(
        id: 42,
        role: SemanticsRole.button,
        label: 'Press',
        actions: <SemanticsAction>{SemanticsAction.activate},
      )));

      // `click()` is what Enter and Space on a focused `<button>` produce, so
      // this is the keyboard path and not a mouse one - which matters, because
      // the whole layer is `pointer-events: none` and a real mouse can never
      // reach it.
      (query('button').single as web.HTMLElement).click();

      expect(raised, <(int, SemanticsAction)>[(42, SemanticsAction.activate)]);
    });

    test('Enter on a role-bearing div raises the same action', () {
      final List<int> raised = <int>[];
      layer.onAction = (int id, SemanticsAction _) => raised.add(id);

      layer.update(SemanticsSnapshot(node(
        id: 9,
        role: SemanticsRole.menuItem,
        label: 'Open',
        actions: <SemanticsAction>{SemanticsAction.activate},
      )));

      final web.Element item = query('[role=menuitem]').single;
      expect(item.getAttribute('tabindex'), '0');
      item.dispatchEvent(
        web.KeyboardEvent('keydown', web.KeyboardEventInit(key: 'Enter')),
      );

      expect(raised, <int>[9]);
    });
  });
}
