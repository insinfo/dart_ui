/// The incremental update (31.4), turned into events and checked everywhere.
///
/// The diff is already correct - `SemanticsOwner` has its own tests. What this
/// file checks is the translation, where the interesting failures are ones a
/// running application never shows: an event raised on a node that no longer
/// exists (silently dropped by UI Automation, so the client never learns), a
/// thousand `ChildAdded`s for one route change (a screen reader a second
/// behind), a focus move that produces a property change and no focus event
/// (the reading cursor stays where it was).
library;

import 'package:dart_ui/src/backends/win32/uia/uia_constants.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_events.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/semantics/semantics.dart';
import 'package:test/test.dart';

SemanticsNode _node(
  int id,
  SemanticsRole role, {
  String? label,
  String? value,
  Rect bounds = const Rect.fromLTWH(0, 0, 10, 10),
  Set<SemanticsState> states = const <SemanticsState>{},
  Set<SemanticsAction> actions = const <SemanticsAction>{},
  List<SemanticsNode> children = const <SemanticsNode>[],
}) =>
    SemanticsNode(
      id: id,
      role: role,
      bounds: bounds,
      label: label,
      value: value,
      states: states,
      actions: actions,
      children: children,
    );

/// A root with [children], as `SemanticsOwner` would build it.
SemanticsSnapshot _tree(List<SemanticsNode> children) => SemanticsSnapshot(
      _node(0, SemanticsRole.generic, children: children),
    );

Iterable<T> _of<T>(List<UiaEventRecord> events) => events.whereType<T>();

void main() {
  const UiaEventTranslator translator = UiaEventTranslator();

  group('nothing to say', () {
    test('an empty update produces no events', () {
      expect(
        translator.translate(
          const SemanticsUpdate(
            added: <SemanticsNode>[],
            updated: <SemanticsNode>[],
            removed: <int>[],
          ),
        ),
        isEmpty,
      );
    });
  });

  group('property changes', () {
    test('a renamed button raises exactly one Name change', () {
      final SemanticsNode before = _node(1, SemanticsRole.button, label: 'Ok');
      final SemanticsNode after =
          _node(1, SemanticsRole.button, label: 'Apply');

      final List<UiaEventRecord> events = translator.translate(
        SemanticsUpdate(
          added: const <SemanticsNode>[],
          updated: <SemanticsNode>[after],
          removed: const <int>[],
        ),
        before: _tree(<SemanticsNode>[before]),
        after: _tree(<SemanticsNode>[after]),
      );

      final List<UiaPropertyChangedRecord> changes =
          _of<UiaPropertyChangedRecord>(events).toList();
      expect(changes, hasLength(1));
      expect(changes.single.nodeId, 1);
      expect(changes.single.propertyId, uiaNamePropertyId);
      expect(changes.single.oldValue, 'Ok');
      expect(changes.single.newValue, 'Apply');
    });

    test('a checkbox being ticked reports the toggle state, not the label', () {
      final SemanticsNode before =
          _node(2, SemanticsRole.checkbox, label: 'Remember me');
      final SemanticsNode after = _node(
        2,
        SemanticsRole.checkbox,
        label: 'Remember me',
        states: <SemanticsState>{SemanticsState.checked},
      );

      final List<UiaPropertyChangedRecord> changes =
          _of<UiaPropertyChangedRecord>(
        translator.translate(
          SemanticsUpdate(
            added: const <SemanticsNode>[],
            updated: <SemanticsNode>[after],
            removed: const <int>[],
          ),
          before: _tree(<SemanticsNode>[before]),
          after: _tree(<SemanticsNode>[after]),
        ),
      ).toList();

      expect(
        changes.map((UiaPropertyChangedRecord c) => c.propertyId),
        <int>[uiaToggleToggleStatePropertyId],
      );
      expect(changes.single.oldValue, toggleStateOff);
      expect(changes.single.newValue, toggleStateOn);
    });

    test('a moved node is silent by default and speaks when asked', () {
      final SemanticsNode before = _node(3, SemanticsRole.text, label: 'x');
      final SemanticsNode after = _node(
        3,
        SemanticsRole.text,
        label: 'x',
        bounds: const Rect.fromLTWH(0, 40, 10, 10),
      );
      final SemanticsUpdate update = SemanticsUpdate(
        added: const <SemanticsNode>[],
        updated: <SemanticsNode>[after],
        removed: const <int>[],
      );

      expect(
        translator.translate(
          update,
          before: _tree(<SemanticsNode>[before]),
          after: _tree(<SemanticsNode>[after]),
        ),
        isEmpty,
        reason: 'every scroll moves every node in the subtree; this is the '
            'one property whose changes arrive by the hundred per frame',
      );

      const UiaEventTranslator loud =
          UiaEventTranslator(raiseBoundingRectangleChanges: true);
      final List<UiaPropertyChangedRecord> changes =
          _of<UiaPropertyChangedRecord>(
        loud.translate(
          update,
          before: _tree(<SemanticsNode>[before]),
          after: _tree(<SemanticsNode>[after]),
        ),
      ).toList();
      expect(changes, hasLength(1));
      expect(changes.single.propertyId, uiaBoundingRectanglePropertyId);
      expect(changes.single.newValue, <double>[0, 40, 10, 10]);
    });

    test(
        'a node whose previous state is unknown produces no property '
        'changes', () {
      // Without `before` there is nothing to diff against, and inventing an
      // "old value" of null would tell a client the name had just appeared.
      final List<UiaEventRecord> events = translator.translate(
        SemanticsUpdate(
          added: const <SemanticsNode>[],
          updated: <SemanticsNode>[_node(1, SemanticsRole.button, label: 'A')],
          removed: const <int>[],
        ),
      );
      expect(_of<UiaPropertyChangedRecord>(events), isEmpty);
    });
  });

  group('focus', () {
    test('gaining focus raises the focus event as well as the property', () {
      final SemanticsNode before = _node(5, SemanticsRole.textField);
      final SemanticsNode after = _node(
        5,
        SemanticsRole.textField,
        states: <SemanticsState>{SemanticsState.focused},
      );
      final List<UiaEventRecord> events = translator.translate(
        SemanticsUpdate(
          added: const <SemanticsNode>[],
          updated: <SemanticsNode>[after],
          removed: const <int>[],
        ),
        before: _tree(<SemanticsNode>[before]),
        after: _tree(<SemanticsNode>[after]),
      );

      expect(
        events,
        contains(
          const UiaAutomationEventRecord(5, uiaAutomationFocusChangedEventId),
        ),
      );
      expect(
        _of<UiaPropertyChangedRecord>(events)
            .map((UiaPropertyChangedRecord c) => c.propertyId),
        contains(uiaHasKeyboardFocusPropertyId),
      );
    });

    test('a node that appears already focused still raises it', () {
      // A dialog that opens with focus inside never shows up in `updated`, so
      // a translator that only looked there would leave the reading cursor on
      // whatever was behind it.
      final SemanticsNode added = _node(
        6,
        SemanticsRole.button,
        label: 'Ok',
        states: <SemanticsState>{SemanticsState.focused},
      );
      expect(
        translator.translate(
          SemanticsUpdate(
            added: <SemanticsNode>[added],
            updated: const <SemanticsNode>[],
            removed: const <int>[],
          ),
          after: _tree(<SemanticsNode>[added]),
        ),
        contains(
          const UiaAutomationEventRecord(6, uiaAutomationFocusChangedEventId),
        ),
      );
    });

    test(
        'losing focus raises no focus event, because somewhere else gained '
        'it', () {
      final SemanticsNode before = _node(
        7,
        SemanticsRole.button,
        states: <SemanticsState>{SemanticsState.focused},
      );
      final SemanticsNode after = _node(7, SemanticsRole.button);
      expect(
        _of<UiaAutomationEventRecord>(
          translator.translate(
            SemanticsUpdate(
              added: const <SemanticsNode>[],
              updated: <SemanticsNode>[after],
              removed: const <int>[],
            ),
            before: _tree(<SemanticsNode>[before]),
            after: _tree(<SemanticsNode>[after]),
          ),
        ),
        isEmpty,
      );
    });
  });

  group('structure', () {
    test('an added node announces itself', () {
      final SemanticsNode added = _node(8, SemanticsRole.button, label: 'New');
      final List<UiaStructureChangedRecord> events =
          _of<UiaStructureChangedRecord>(
        translator.translate(
          SemanticsUpdate(
            added: <SemanticsNode>[added],
            updated: const <SemanticsNode>[],
            removed: const <int>[],
          ),
          after: _tree(<SemanticsNode>[added]),
        ),
      ).toList();
      expect(events, hasLength(1));
      expect(events.single.nodeId, 8);
      expect(events.single.changeType, structureChangeTypeChildAdded);
      expect(events.single.childRuntimeId, 8);
    });

    test('a removed node is announced on its parent, which still exists', () {
      final SemanticsNode child = _node(10, SemanticsRole.listItem);
      final SemanticsNode list =
          _node(9, SemanticsRole.list, children: <SemanticsNode>[child]);
      final SemanticsNode emptied = _node(9, SemanticsRole.list);

      final List<UiaStructureChangedRecord> events =
          _of<UiaStructureChangedRecord>(
        translator.translate(
          const SemanticsUpdate(
            added: <SemanticsNode>[],
            updated: <SemanticsNode>[],
            removed: <int>[10],
          ),
          before: _tree(<SemanticsNode>[list]),
          after: _tree(<SemanticsNode>[emptied]),
        ),
      ).toList();

      expect(events, hasLength(1));
      // Raised on the list, naming the item: an event raised on the vanished
      // node itself would have nowhere to be delivered.
      expect(events.single.nodeId, 9);
      expect(events.single.changeType, structureChangeTypeChildRemoved);
      expect(events.single.childRuntimeId, 10);
    });

    test('a removed node whose parent also went falls back to the root', () {
      final SemanticsNode child = _node(12, SemanticsRole.listItem);
      final SemanticsNode list =
          _node(11, SemanticsRole.list, children: <SemanticsNode>[child]);
      final List<UiaStructureChangedRecord> events =
          _of<UiaStructureChangedRecord>(
        translator.translate(
          const SemanticsUpdate(
            added: <SemanticsNode>[],
            updated: <SemanticsNode>[],
            removed: <int>[11, 12],
          ),
          before: _tree(<SemanticsNode>[list]),
          after: _tree(const <SemanticsNode>[]),
        ),
      ).toList();
      expect(events, hasLength(2));
      expect(
        events.map((UiaStructureChangedRecord e) => e.nodeId).toSet(),
        <int>{0},
      );
    });

    test('a whole route change collapses into one invalidation', () {
      final List<SemanticsNode> many = <SemanticsNode>[
        for (int i = 100; i < 140; i++)
          _node(i, SemanticsRole.listItem, label: 'row $i'),
      ];
      final List<UiaEventRecord> events = translator.translate(
        SemanticsUpdate(
          added: many,
          updated: const <SemanticsNode>[],
          removed: const <int>[],
        ),
        after: _tree(many),
      );
      final List<UiaStructureChangedRecord> structural =
          _of<UiaStructureChangedRecord>(events).toList();
      expect(structural, hasLength(1));
      expect(structural.single.nodeId, 0, reason: 'raised on the root');
      expect(
        structural.single.changeType,
        structureChangeTypeChildrenInvalidated,
      );
      // Forty marshalled round trips replaced by one, which is the whole
      // reason the threshold exists.
      expect(events.length, lessThan(many.length));
    });

    test('the threshold is where it says it is', () {
      List<UiaEventRecord> forCount(int count, int threshold) {
        final List<SemanticsNode> nodes = <SemanticsNode>[
          for (int i = 0; i < count; i++) _node(i + 1, SemanticsRole.text),
        ];
        return UiaEventTranslator(bulkThreshold: threshold).translate(
          SemanticsUpdate(
            added: nodes,
            updated: const <SemanticsNode>[],
            removed: const <int>[],
          ),
          after: _tree(nodes),
        );
      }

      expect(_of<UiaStructureChangedRecord>(forCount(3, 3)), hasLength(3));
      expect(_of<UiaStructureChangedRecord>(forCount(4, 3)), hasLength(1));
    });
  });

  group('surfaces that announce themselves', () {
    test('a tooltip and a menu appearing each raise their own event', () {
      final SemanticsNode tooltip =
          _node(20, SemanticsRole.tooltip, label: 'Copy');
      final SemanticsNode menu = _node(21, SemanticsRole.menu);
      final List<UiaEventRecord> events = translator.translate(
        SemanticsUpdate(
          added: <SemanticsNode>[tooltip, menu],
          updated: const <SemanticsNode>[],
          removed: const <int>[],
        ),
        after: _tree(<SemanticsNode>[tooltip, menu]),
      );
      expect(
        events,
        containsAll(<UiaEventRecord>[
          const UiaAutomationEventRecord(20, uiaToolTipOpenedEventId),
          const UiaAutomationEventRecord(21, uiaMenuOpenedEventId),
        ]),
      );
    });
  });
}
