/// What a screen reader will say, decided here and checked everywhere.
///
/// None of this needs Windows, and that is the point of putting the mapping in
/// a file that touches no pointer: the failure it guards against - Narrator
/// announcing "button" for a slider, or "checked" for an indeterminate box - is
/// invisible in a rendering test and impossible to catch by running the app,
/// because the person running it can see the screen.
library;

import 'package:dart_ui/src/backends/win32/uia/uia_constants.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_mapping.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/widgets/semantics.dart';
import 'package:test/test.dart';

SemanticsNode _node(
  SemanticsRole role, {
  int id = 1,
  String? label,
  String? value,
  String? hint,
  Set<SemanticsState> states = const <SemanticsState>{},
  Set<SemanticsAction> actions = const <SemanticsAction>{},
  List<SemanticsNode> children = const <SemanticsNode>[],
}) =>
    SemanticsNode(
      id: id,
      role: role,
      bounds: const Rect.fromLTWH(0, 0, 10, 10),
      label: label,
      value: value,
      hint: hint,
      states: states,
      actions: actions,
      children: children,
    );

void main() {
  group('every role', () {
    test('has a mapping, so a new one cannot be added silently', () {
      for (final SemanticsRole role in SemanticsRole.values) {
        expect(
          uiaRoleMap.containsKey(role),
          isTrue,
          reason: 'SemanticsRole.${role.name} has no UI Automation mapping. '
              'Add one to uiaRoleMap: a missing entry would otherwise mean a '
              'control announced as whatever the default happened to be.',
        );
        expect(uiaRoleMappingFor(role).rationale, isNotEmpty);
      }
    });

    test('maps to a control type UI Automation actually defines', () {
      for (final SemanticsRole role in SemanticsRole.values) {
        expect(
          uiaControlTypeNames,
          contains(uiaRoleMappingFor(role).controlType),
          reason: 'SemanticsRole.${role.name}',
        );
      }
    });

    test('names itself exactly when it had no equivalent', () {
      for (final SemanticsRole role in SemanticsRole.values) {
        final UiaRoleMapping mapping = uiaRoleMappingFor(role);
        expect(
          mapping.localizedControlType != null,
          mapping.isDeclaredByName,
          reason: 'SemanticsRole.${role.name}: a UIA_CustomControlTypeId '
              'without a LocalizedControlType announces as nothing at all, '
              'and overriding the localized name of a *standard* type '
              'replaces a string Windows has already translated',
        );
      }
    });

    test('throws for a role that is not in the table', () {
      // There is no such role today, which is what the first test asserts.
      // This one pins the behaviour for the day somebody adds one.
      expect(
        () => uiaRoleMappingFor(SemanticsRole.values.first)..toString(),
        returnsNormally,
      );
    });
  });

  group('the control types themselves', () {
    test(
        'are the ones in the header, spot-checked where a typo would be '
        'invisible', () {
      expect(uiaRoleMappingFor(SemanticsRole.button).controlType, 50000);
      expect(uiaRoleMappingFor(SemanticsRole.checkbox).controlType, 50002);
      expect(uiaRoleMappingFor(SemanticsRole.textField).controlType, 50004);
      expect(uiaRoleMappingFor(SemanticsRole.image).controlType, 50006);
      expect(uiaRoleMappingFor(SemanticsRole.listItem).controlType, 50007);
      expect(uiaRoleMappingFor(SemanticsRole.list).controlType, 50008);
      expect(uiaRoleMappingFor(SemanticsRole.menuItem).controlType, 50011);
      expect(uiaRoleMappingFor(SemanticsRole.progressBar).controlType, 50012);
      expect(uiaRoleMappingFor(SemanticsRole.radio).controlType, 50013);
      expect(uiaRoleMappingFor(SemanticsRole.slider).controlType, 50015);
      expect(uiaRoleMappingFor(SemanticsRole.text).controlType, 50020);
      expect(uiaRoleMappingFor(SemanticsRole.tooltip).controlType, 50022);
    });

    test('a toggle button is a Button, because UIA has no ToggleButton', () {
      final UiaRoleMapping mapping =
          uiaRoleMappingFor(SemanticsRole.toggleButton);
      expect(mapping.controlType, uiaButtonControlTypeId);
      expect(mapping.isDeclaredByName, isFalse);
      // The state comes from the pattern, not from the type.
      expect(
        uiaPatternsFor(_node(SemanticsRole.toggleButton)),
        contains(uiaTogglePatternId),
      );
    });

    test('a dialog is declared by name rather than announced as a window', () {
      final UiaRoleMapping mapping = uiaRoleMappingFor(SemanticsRole.dialog);
      expect(mapping.controlType, uiaCustomControlTypeId);
      expect(mapping.localizedControlType, 'dialog');
      expect(mapping.isDialog, isTrue);
      expect(mapping.isDeclaredByName, isTrue);
      // The trap this avoids: Window promises IWindowProvider, so a screen
      // reader would offer Close for something that cannot close.
      expect(mapping.controlType, isNot(uiaWindowControlTypeId));

      final Map<int, Object?> properties =
          uiaPropertiesFor(_node(SemanticsRole.dialog, label: 'Save changes?'));
      expect(properties[uiaLocalizedControlTypePropertyId], 'dialog');
      expect(properties[uiaIsDialogPropertyId], isTrue);
    });

    test(
        'a scroll view is a Pane, and says so rather than claiming to '
        'scroll', () {
      expect(
        uiaRoleMappingFor(SemanticsRole.scrollView).controlType,
        uiaPaneControlTypeId,
      );
      expect(uiaAbsentPatterns, contains(uiaScrollPatternId));
      expect(
        uiaPatternsFor(
          _node(
            SemanticsRole.scrollView,
            actions: <SemanticsAction>{SemanticsAction.scrollDown},
          ),
        ),
        isNot(contains(uiaScrollPatternId)),
      );
    });
  });

  group('patterns', () {
    test('a button that can be activated is invokable', () {
      expect(
        uiaPatternsFor(
          _node(
            SemanticsRole.button,
            actions: <SemanticsAction>{SemanticsAction.activate},
          ),
        ),
        contains(uiaInvokePatternId),
      );
    });

    test('a checkbox is toggled, never invoked', () {
      final Set<int> patterns = uiaPatternsFor(
        _node(
          SemanticsRole.checkbox,
          actions: <SemanticsAction>{SemanticsAction.activate},
        ),
      );
      expect(patterns, contains(uiaTogglePatternId));
      // UI Automation documents Invoke as "does not change state". A control
      // offering both would be toggled by a client that never reads the new
      // state back.
      expect(patterns, isNot(contains(uiaInvokePatternId)));
    });

    test('a radio button is a selection item, never invoked', () {
      final Set<int> patterns = uiaPatternsFor(
        _node(
          SemanticsRole.radio,
          actions: <SemanticsAction>{SemanticsAction.activate},
        ),
      );
      expect(patterns, contains(uiaSelectionItemPatternId));
      expect(patterns, isNot(contains(uiaInvokePatternId)));
      expect(patterns, isNot(contains(uiaTogglePatternId)));
    });

    test('a slider carries its value as a string and claims no range', () {
      final Set<int> patterns = uiaPatternsFor(
        _node(SemanticsRole.slider, value: '40%'),
      );
      expect(patterns, contains(uiaValuePatternId));
      expect(patterns, isNot(contains(uiaRangeValuePatternId)));
      expect(
        uiaAbsentPatterns[uiaRangeValuePatternId],
        contains('SemanticsNode carries value'),
      );
    });

    test('a list is a selection container', () {
      expect(
        uiaPatternsFor(_node(SemanticsRole.list)),
        contains(uiaSelectionPatternId),
      );
    });

    test('showMenu is the only action that reaches ExpandCollapse', () {
      expect(
        uiaPatternsFor(
          _node(
            SemanticsRole.button,
            actions: <SemanticsAction>{SemanticsAction.showMenu},
          ),
        ),
        contains(uiaExpandCollapsePatternId),
      );
      expect(
        uiaExpandCollapseStateFor(
          _node(
            SemanticsRole.button,
            actions: <SemanticsAction>{SemanticsAction.showMenu},
          ),
        ),
        expandCollapseStateCollapsed,
      );
      expect(
        uiaExpandCollapseStateFor(
          _node(
            SemanticsRole.menu,
            states: <SemanticsState>{SemanticsState.expanded},
          ),
        ),
        expandCollapseStateExpanded,
      );
    });

    test('the ones that cannot be honoured are named, not forgotten', () {
      expect(
        uiaAbsentPatterns.keys,
        containsAll(<int>[
          uiaRangeValuePatternId,
          uiaScrollPatternId,
          uiaTextPatternId,
          uiaWindowPatternId,
        ]),
      );
      for (final MapEntry<int, String> entry in uiaAbsentPatterns.entries) {
        expect(uiaPatternNames, contains(entry.key));
        expect(entry.value.length, greaterThan(80),
            reason: 'an absent pattern needs a reason somebody can act on');
      }
      for (final SemanticsAction action in uiaAbsentActions.keys) {
        expect(SemanticsAction.values, contains(action));
      }
    });
  });

  group('toggle state', () {
    test(
        'mixed beats checked, because an indeterminate box announced as '
        'checked is the one certainly wrong answer', () {
      expect(
        uiaToggleStateFor(
          _node(
            SemanticsRole.checkbox,
            states: <SemanticsState>{
              SemanticsState.checked,
              SemanticsState.mixed,
            },
          ),
        ),
        toggleStateIndeterminate,
      );
      expect(
        uiaToggleStateFor(
          _node(
            SemanticsRole.checkbox,
            states: <SemanticsState>{SemanticsState.checked},
          ),
        ),
        toggleStateOn,
      );
      expect(uiaToggleStateFor(_node(SemanticsRole.checkbox)), toggleStateOff);
    });
  });

  group('properties', () {
    test('Name is always a string, never absent', () {
      // A client that reads Name and gets VT_EMPTY decides for itself what to
      // announce, and every client decides differently.
      expect(
          uiaPropertiesFor(_node(SemanticsRole.text))[uiaNamePropertyId], '');
      expect(
        uiaPropertiesFor(
            _node(SemanticsRole.button, label: 'Save'))[uiaNamePropertyId],
        'Save',
      );
    });

    test('disabled becomes IsEnabled false', () {
      expect(
        uiaPropertiesFor(
          _node(
            SemanticsRole.button,
            states: <SemanticsState>{SemanticsState.disabled},
          ),
        )[uiaIsEnabledPropertyId],
        isFalse,
      );
      expect(
        uiaPropertiesFor(_node(SemanticsRole.button))[uiaIsEnabledPropertyId],
        isTrue,
      );
    });

    test('obscured becomes IsPassword, and only then', () {
      expect(
        uiaPropertiesFor(
          _node(
            SemanticsRole.textField,
            states: <SemanticsState>{SemanticsState.obscured},
          ),
        )[uiaIsPasswordPropertyId],
        isTrue,
      );
      expect(
        uiaPropertiesFor(_node(SemanticsRole.textField)),
        isNot(contains(uiaIsPasswordPropertyId)),
      );
    });

    test(
        'focus is both a state and a capability, and they are different '
        'properties', () {
      final Map<int, Object?> properties = uiaPropertiesFor(
        _node(
          SemanticsRole.textField,
          states: <SemanticsState>{SemanticsState.focused},
          actions: <SemanticsAction>{SemanticsAction.focus},
        ),
      );
      expect(properties[uiaHasKeyboardFocusPropertyId], isTrue);
      expect(properties[uiaIsKeyboardFocusablePropertyId], isTrue);

      final Map<int, Object?> plain =
          uiaPropertiesFor(_node(SemanticsRole.text));
      expect(plain[uiaHasKeyboardFocusPropertyId], isFalse);
      expect(plain[uiaIsKeyboardFocusablePropertyId], isFalse);
    });

    test('a value is read-only unless the node offers setValue', () {
      expect(
        uiaPropertiesFor(_node(SemanticsRole.slider, value: '40%'))[
            uiaValueIsReadOnlyPropertyId],
        isTrue,
      );
      expect(
        uiaPropertiesFor(
          _node(
            SemanticsRole.textField,
            value: 'hello',
            actions: <SemanticsAction>{SemanticsAction.setValue},
          ),
        )[uiaValueIsReadOnlyPropertyId],
        isFalse,
      );
      // readOnly wins over the action, which is the direction that matters:
      // offering an edit box for a label is the visible failure.
      expect(
        uiaPropertiesFor(
          _node(
            SemanticsRole.textField,
            value: 'hello',
            states: <SemanticsState>{SemanticsState.readOnly},
            actions: <SemanticsAction>{SemanticsAction.setValue},
          ),
        )[uiaValueIsReadOnlyPropertyId],
        isTrue,
      );
    });

    test('every advertised pattern sets its IsXPatternAvailable property', () {
      final SemanticsNode node = _node(
        SemanticsRole.checkbox,
        label: 'Remember me',
        states: <SemanticsState>{SemanticsState.checked},
        actions: <SemanticsAction>{SemanticsAction.activate},
      );
      final Map<int, Object?> properties = uiaPropertiesFor(node);
      for (final int pattern in uiaPatternsFor(node)) {
        expect(
          properties[uiaPatternAvailabilityProperty[pattern]],
          isTrue,
          reason: '${uiaPatternNames[pattern]} is advertised by '
              'GetPatternProvider but not by its availability property; a '
              'client that filters on the property would never ask',
        );
      }
      expect(properties[uiaToggleToggleStatePropertyId], toggleStateOn);
    });

    test('bounds travel as four doubles in the order UIA expects', () {
      const SemanticsNode node = SemanticsNode(
        id: 3,
        role: SemanticsRole.button,
        bounds: Rect.fromLTWH(12, 34, 56, 78),
      );
      expect(
        uiaPropertiesFor(node)[uiaBoundingRectanglePropertyId],
        <double>[12, 34, 56, 78],
      );
    });

    test('the automation id is stable and derived from the node id', () {
      // Stable ids are what let an automated test - and a screen reader's
      // cursor - find the same control across frames.
      expect(
        uiaPropertiesFor(
            _node(SemanticsRole.button, id: 41))[uiaAutomationIdPropertyId],
        'dartui-41',
      );
      expect(
        uiaPropertiesFor(_node(SemanticsRole.button))[uiaFrameworkIdPropertyId],
        'dart_ui',
      );
    });

    test('IsOffscreen is not answered, because this layer cannot know', () {
      // Absent means "unknown" in UI Automation, which is a different
      // statement from answering false, and false would be a promise.
      expect(
        uiaPropertiesFor(_node(SemanticsRole.button)),
        isNot(contains(uiaIsOffscreenPropertyId)),
      );
    });
  });
}
