/// Semantics to UI Automation: control types, properties and patterns.
///
/// This file is pure Dart. It touches no pointer and loads no library, so the
/// whole mapping - which is where a screen reader's announcement is actually
/// decided - is testable on Linux and macOS as well as on Windows. That is
/// deliberate: the FFI below it can only be tested where COM exists, and a bug
/// in *this* layer is the one that makes Narrator say "button" for a slider.
///
/// ## The rule this file follows where the two vocabularies do not meet
///
/// UI Automation's control types are a closed set. [SemanticsRole] is our own
/// and does not line up with it. Where a role has a genuine UIA equivalent it
/// gets it. Where it does **not**, the role is mapped to
/// `UIA_CustomControlTypeId` and given a `LocalizedControlType` naming it -
/// which is exactly what that control type is for. A screen reader then says
/// the name we chose instead of a name that is wrong, and "dialog" announced as
/// "dialog" beats "dialog" announced as "window" with a Close button a user can
/// press and nothing happens.
///
/// The holes are listed by name in [uiaRoleMap] and asserted by the tests, so
/// adding a role without deciding what it announces as is a test failure and
/// not a silent `generic`.
library;

import '../../../widgets/semantics.dart';
import 'uia_constants.dart';

/// What one [SemanticsRole] becomes on the UI Automation side.
final class UiaRoleMapping {
  const UiaRoleMapping({
    required this.controlType,
    this.localizedControlType,
    this.isDialog = false,
    required this.rationale,
  });

  /// The `UIA_*ControlTypeId` this role reports.
  final int controlType;

  /// The `LocalizedControlType` to report alongside it, or null to let UI
  /// Automation supply the standard one for [controlType].
  ///
  /// Non-null exactly when [controlType] is `UIA_CustomControlTypeId`, because
  /// a custom control that does not name itself announces as nothing at all,
  /// and non-null in no other case, because overriding the localized name of a
  /// standard type replaces a string Windows has already translated with one
  /// we have not.
  final String? localizedControlType;

  /// Whether to answer `UIA_IsDialogPropertyId` with true.
  final bool isDialog;

  /// Why this pairing, in one sentence. Read by the report and by the test
  /// that requires every role to have one.
  final String rationale;

  /// Whether this role had no UI Automation equivalent and is being declared
  /// by name.
  bool get isDeclaredByName => controlType == uiaCustomControlTypeId;

  @override
  String toString() {
    final String type =
        uiaControlTypeNames[controlType] ?? 'controlType $controlType';
    return localizedControlType == null
        ? type
        : '$type as "$localizedControlType"';
  }
}

/// Every [SemanticsRole], and what it announces as.
///
/// Complete by construction: [uiaRoleMappingFor] would throw on a role missing
/// from here, and a test enumerates `SemanticsRole.values` against it so a new
/// role cannot be added without a decision being made about it.
const Map<SemanticsRole, UiaRoleMapping> uiaRoleMap =
    <SemanticsRole, UiaRoleMapping>{
  SemanticsRole.generic: UiaRoleMapping(
    controlType: uiaGroupControlTypeId,
    rationale: 'a node with no role of its own is a grouping of the nodes '
        'under it, which is what UIA_GroupControlTypeId means; Custom would '
        'force a made-up name onto something that has none',
  ),
  SemanticsRole.button: UiaRoleMapping(
    controlType: uiaButtonControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.toggleButton: UiaRoleMapping(
    controlType: uiaButtonControlTypeId,
    rationale: 'UI Automation has no ToggleButton control type and does not '
        'need one: a Button that supports IToggleProvider is the documented '
        'idiom, and Narrator announces "pressed" / "not pressed" from the '
        'toggle state rather than from the control type',
  ),
  SemanticsRole.checkbox: UiaRoleMapping(
    controlType: uiaCheckBoxControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.radio: UiaRoleMapping(
    controlType: uiaRadioButtonControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.slider: UiaRoleMapping(
    controlType: uiaSliderControlTypeId,
    rationale: 'exact equivalent for the control type; the *pattern* is not '
        'exact - see the IRangeValueProvider entry in uiaAbsentPatterns',
  ),
  SemanticsRole.progressBar: UiaRoleMapping(
    controlType: uiaProgressBarControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.textField: UiaRoleMapping(
    controlType: uiaEditControlTypeId,
    rationale: 'UIA calls it Edit; the two names mean the same control',
  ),
  SemanticsRole.list: UiaRoleMapping(
    controlType: uiaListControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.listItem: UiaRoleMapping(
    controlType: uiaListItemControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.menu: UiaRoleMapping(
    controlType: uiaMenuControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.menuItem: UiaRoleMapping(
    controlType: uiaMenuItemControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.dialog: UiaRoleMapping(
    controlType: uiaCustomControlTypeId,
    localizedControlType: 'dialog',
    isDialog: true,
    rationale: 'DECLARED BY NAME. UIA_WindowControlTypeId is the closest type '
        'and is wrong: it promises IWindowProvider, so a screen reader offers '
        'Minimise, Maximise and Close for something that is a region inside '
        'one HWND and can honour none of them. Custom plus the name "dialog" '
        'plus UIA_IsDialogPropertyId announces "dialog" and promises nothing '
        'that is not true',
  ),
  SemanticsRole.tooltip: UiaRoleMapping(
    controlType: uiaToolTipControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.scrollView: UiaRoleMapping(
    controlType: uiaPaneControlTypeId,
    rationale: 'UI Automation has no ScrollView control type because scrolling '
        'is a pattern and not a type; Pane is what browsers and shell '
        'surfaces report for a scrollable region, and it is a name screen '
        'readers already handle. The scrolling itself is absent - see '
        'IScrollProvider in uiaAbsentPatterns',
  ),
  SemanticsRole.image: UiaRoleMapping(
    controlType: uiaImageControlTypeId,
    rationale: 'exact equivalent',
  ),
  SemanticsRole.text: UiaRoleMapping(
    controlType: uiaTextControlTypeId,
    rationale: 'exact equivalent',
  ),
};

/// The mapping for [role]. Throws rather than defaulting, because a default
/// here is a control announced wrongly and nobody noticing.
UiaRoleMapping uiaRoleMappingFor(SemanticsRole role) {
  final UiaRoleMapping? mapping = uiaRoleMap[role];
  if (mapping == null) {
    throw ArgumentError.value(
      role,
      'role',
      'SemanticsRole.${role.name} has no UI Automation mapping; add one to '
          'uiaRoleMap rather than letting it announce as a generic element',
    );
  }
  return mapping;
}

/// The control-pattern interfaces this backend does **not** implement, and
/// why, keyed by the `UIA_*PatternId` a client would ask for.
///
/// Written down rather than left to `GetPatternProvider` returning null,
/// because "unsupported" and "nobody has looked at it" are different states
/// and only one of them is a bug. The report and the tests read this map.
const Map<int, String> uiaAbsentPatterns = <int, String>{
  uiaRangeValuePatternId:
      'IRangeValueProvider needs Value, Minimum, Maximum, LargeChange and '
          'SmallChange as doubles. SemanticsNode carries value, increasedValue '
          'and decreasedValue as *strings* and no bounds at all, so every one '
          'of the five would have to be invented. A slider therefore reports '
          'IValueProvider with the string the widget chose, which is the text '
          'a screen reader would have read anyway, and does not claim a range '
          'it cannot honour.',
  uiaScrollPatternId:
      'IScrollProvider needs HorizontalScrollPercent, VerticalScrollPercent, '
          'HorizontalViewSize, VerticalViewSize and the two Scrollable flags. '
          'SemanticsAction has scrollUp/scrollDown/scrollLeft/scrollRight and '
          'no position or extent, so the pattern cannot be answered even '
          'approximately. scrollView announces as a Pane without it.',
  uiaTextPatternId:
      'ITextProvider is a text-range model: ranges, attributes, embedded '
          'objects, hit testing by character. The semantics tree exposes a '
          'label and a value string per node and no character geometry. A '
          'text field is readable through Name and IValueProvider; caret '
          'navigation by character is absent.',
  uiaWindowPatternId:
      'IWindowProvider belongs to a real top-level window. This provider '
          'describes the contents of one HWND, and the HWND itself is already '
          'described by the host provider returned from '
          'IRawElementProviderSimple::get_HostRawElementProvider.',
  uiaGridPatternId:
      'IGridProvider and ITableProvider need row and column counts. '
          'SemanticsRole has no table, grid, row or cell, so there is nothing '
          'to describe yet.',
};

/// [SemanticsAction]s that reach no UI Automation pattern, and why.
const Map<SemanticsAction, String> uiaAbsentActions = <SemanticsAction, String>{
  SemanticsAction.increment:
      'increment/decrement are IRangeValueProvider::SetValue plus a '
          'SmallChange, and IRangeValueProvider is absent - see '
          'uiaAbsentPatterns. Nothing else in UI Automation steps a value.',
  SemanticsAction.decrement: 'see increment.',
  SemanticsAction.scrollUp:
      'IScrollProvider is absent - see uiaAbsentPatterns.',
  SemanticsAction.scrollDown: 'see scrollUp.',
  SemanticsAction.scrollLeft: 'see scrollUp.',
  SemanticsAction.scrollRight: 'see scrollUp.',
  SemanticsAction.dismiss:
      'UI Automation has no Dismiss pattern. IWindowProvider::Close is the '
          'nearest and belongs to an HWND, not to a region inside one. A '
          'dismissible surface is reachable by its own close button, which is '
          'a Button with activate.',
};

/// The control patterns a node supports, as `UIA_*PatternId` values.
///
/// The precedence rules are UI Automation's own and are not stylistic:
///
///   * a control with a toggle state implements `IToggleProvider` and **not**
///     `IInvokeProvider`, because Invoke is documented as "performs an action
///     that does not change state";
///   * a control that is one of a set implements `ISelectionItemProvider` and
///     not Invoke, for the same reason.
///
/// A checkbox that offered both would be announced as a button that can also
/// be checked, and a client choosing Invoke would toggle it without ever
/// reading the new state.
Set<int> uiaPatternsFor(SemanticsNode node) {
  final Set<int> patterns = <int>{};

  final bool togglable = node.role == SemanticsRole.checkbox ||
      node.role == SemanticsRole.toggleButton;
  final bool selectable = node.role == SemanticsRole.radio ||
      node.role == SemanticsRole.listItem ||
      node.role == SemanticsRole.menuItem ||
      node.states.contains(SemanticsState.selected);

  if (togglable) {
    patterns.add(uiaTogglePatternId);
  } else if (selectable) {
    patterns.add(uiaSelectionItemPatternId);
  } else if (node.actions.contains(SemanticsAction.activate)) {
    patterns.add(uiaInvokePatternId);
  }

  // Value: anything that carries a value string a user can read, and
  // separately anything that can be given one.
  if (node.value != null ||
      node.actions.contains(SemanticsAction.setValue) ||
      node.role == SemanticsRole.textField ||
      node.role == SemanticsRole.slider ||
      node.role == SemanticsRole.progressBar) {
    patterns.add(uiaValuePatternId);
  }

  if (node.states.contains(SemanticsState.expanded) ||
      node.actions.contains(SemanticsAction.showMenu)) {
    patterns.add(uiaExpandCollapsePatternId);
  }

  if (node.role == SemanticsRole.list || node.role == SemanticsRole.menu) {
    patterns.add(uiaSelectionPatternId);
  }

  return patterns;
}

/// `ToggleState` for a node, following [SemanticsState].
///
/// `mixed` wins over `checked` because a tri-state control that is
/// indeterminate may also carry `checked` from whatever it was before, and
/// announcing "checked" for an indeterminate box is the one answer that is
/// certainly wrong.
int uiaToggleStateFor(SemanticsNode node) {
  if (node.states.contains(SemanticsState.mixed)) {
    return toggleStateIndeterminate;
  }
  return node.states.contains(SemanticsState.checked)
      ? toggleStateOn
      : toggleStateOff;
}

/// `ExpandCollapseState` for a node.
int uiaExpandCollapseStateFor(SemanticsNode node) {
  if (node.states.contains(SemanticsState.expanded)) {
    return expandCollapseStateExpanded;
  }
  if (node.actions.contains(SemanticsAction.showMenu)) {
    return expandCollapseStateCollapsed;
  }
  return expandCollapseStateLeafNode;
}

/// Whether the node reports itself selected, for `ISelectionItemProvider`.
///
/// `checked` counts because a radio button in this framework's semantics says
/// `checked` and UI Automation calls the same fact `IsSelected`.
bool uiaIsSelected(SemanticsNode node) =>
    node.states.contains(SemanticsState.selected) ||
    node.states.contains(SemanticsState.checked);

/// The framework identifier every element reports.
const String uiaFrameworkId = 'dart_ui';

/// The properties a node answers, as property id to Dart value.
///
/// Values are Dart types and are turned into `VARIANT`s one layer up: [String]
/// becomes `VT_BSTR`, [bool] becomes `VT_BOOL` (with the `-1` that
/// `VARIANT_TRUE` actually is), [int] becomes `VT_I4`, `List<double>` becomes
/// a `VT_R8 | VT_ARRAY` of four - which is what `BoundingRectangle` is.
///
/// A property that is *absent* from the returned map is answered `VT_EMPTY`,
/// which is UI Automation's "I do not know", and that is a different statement
/// from answering false. `IsOffscreen` is the example: this provider cannot
/// tell whether a node is clipped away by an ancestor, so it says nothing
/// rather than promising the node is visible.
Map<int, Object?> uiaPropertiesFor(SemanticsNode node) {
  final UiaRoleMapping mapping = uiaRoleMappingFor(node.role);
  final Set<int> patterns = uiaPatternsFor(node);

  final Map<int, Object?> properties = <int, Object?>{
    uiaControlTypePropertyId: mapping.controlType,
    // Always a string, never absent: a client that reads Name and gets
    // VT_EMPTY has to decide what to announce, and every one of them decides
    // differently. An unlabelled node is an empty name.
    uiaNamePropertyId: node.label ?? '',
    uiaAutomationIdPropertyId: 'dartui-${node.id}',
    uiaFrameworkIdPropertyId: uiaFrameworkId,
    uiaIsEnabledPropertyId: !node.states.contains(SemanticsState.disabled),
    uiaIsControlElementPropertyId: true,
    uiaIsContentElementPropertyId: true,
    uiaHasKeyboardFocusPropertyId: node.states.contains(SemanticsState.focused),
    uiaIsKeyboardFocusablePropertyId:
        node.actions.contains(SemanticsAction.focus),
  };

  if (mapping.localizedControlType != null) {
    properties[uiaLocalizedControlTypePropertyId] =
        mapping.localizedControlType;
  }
  if (mapping.isDialog) {
    properties[uiaIsDialogPropertyId] = true;
  }
  if (node.hint != null) {
    properties[uiaHelpTextPropertyId] = node.hint;
  }
  if (node.states.contains(SemanticsState.obscured)) {
    properties[uiaIsPasswordPropertyId] = true;
  }
  if (node.states.contains(SemanticsState.required)) {
    properties[uiaIsRequiredForFormPropertyId] = true;
  }
  if (node.states.contains(SemanticsState.invalid)) {
    // Only when it is false. True would claim we validated it.
    properties[uiaIsDataValidForFormPropertyId] = false;
  }

  if (patterns.contains(uiaValuePatternId)) {
    properties[uiaValueValuePropertyId] = node.value ?? '';
    properties[uiaValueIsReadOnlyPropertyId] = _isReadOnly(node);
  }
  if (patterns.contains(uiaTogglePatternId)) {
    properties[uiaToggleToggleStatePropertyId] = uiaToggleStateFor(node);
  }
  if (patterns.contains(uiaSelectionItemPatternId)) {
    properties[uiaSelectionItemIsSelectedPropertyId] = uiaIsSelected(node);
  }
  if (patterns.contains(uiaExpandCollapsePatternId)) {
    properties[uiaExpandCollapseExpandCollapseStatePropertyId] =
        uiaExpandCollapseStateFor(node);
  }

  for (final int pattern in patterns) {
    final int? availability = uiaPatternAvailabilityProperty[pattern];
    if (availability != null) properties[availability] = true;
  }

  // The bounds are in the semantic root's space; the provider converts them to
  // screen coordinates, which is the only space UI Automation accepts.
  properties[uiaBoundingRectanglePropertyId] = <double>[
    node.bounds.left,
    node.bounds.top,
    node.bounds.width,
    node.bounds.height,
  ];

  return properties;
}

/// Whether a node's value can be set.
///
/// A node is read-only unless it says otherwise **and** offers `setValue`.
/// Getting this backwards makes a screen reader offer an edit box for a label.
bool _isReadOnly(SemanticsNode node) {
  if (node.states.contains(SemanticsState.readOnly)) return true;
  if (node.states.contains(SemanticsState.disabled)) return true;
  return !node.actions.contains(SemanticsAction.setValue);
}
