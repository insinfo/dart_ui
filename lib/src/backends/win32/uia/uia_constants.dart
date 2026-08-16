/// The UI Automation numbers and interface identifiers, written down once.
///
/// Every value here comes from `UIAutomationClient.h` / `UIAutomationCore.h`
/// and is spelled with its original name in the doc comment, so a search for
/// `UIA_ButtonControlTypeId` finds the Dart constant that carries it.
///
/// ## Why these are constants and not an enum
///
/// They cross an ABI. A control type is a `long` in a `VARIANT`, a pattern id
/// is a `PATTERNID` argument, and a property id indexes a switch inside
/// UIAutomationCore. An enum would add a `.index` at every call site and would
/// invite the mistake this file exists to prevent, which is renumbering.
///
/// Nothing here is platform-specific at compile time: the file names no Windows
/// type beyond [Guid], which `lib/src/ffi/com.dart` already defines as pure
/// arithmetic. It therefore analyses and imports on Linux and macOS, and the
/// mapping tests that read it run there.
library;

import '../../../ffi/com.dart';

// ---------------------------------------------------------------------------
// WM_GETOBJECT
// ---------------------------------------------------------------------------

/// `WM_GETOBJECT` - the message a client sends to ask a window for an
/// accessibility object.
const int wmGetobject = 0x003D;

/// `UiaRootObjectId` - the `lParam` of a [wmGetobject] that is asking for a UI
/// Automation provider rather than for an MSAA `IAccessible`.
///
/// The value is negative and is the whole discriminator: the same message with
/// `OBJID_CLIENT` (0xFFFFFFFC / -4) is asking for MSAA, and answering that one
/// with a UIA provider is how a window ends up invisible to half the assistive
/// technology on the machine. See [objidClient].
const int uiaRootObjectId = -25;

/// `OBJID_CLIENT` - the MSAA client area. Not answered by this backend; see
/// the "declared absent" list in `uia_bridge.dart`.
const int objidClient = -4;

/// `OBJID_WINDOW` - the window itself, MSAA's non-client object.
const int objidWindow = 0;

// ---------------------------------------------------------------------------
// ProviderOptions
// ---------------------------------------------------------------------------

/// `ProviderOptions_ClientSideProvider`.
const int providerOptionsClientSideProvider = 0x1;

/// `ProviderOptions_ServerSideProvider` - a provider living in the process
/// that owns the UI. Ours.
const int providerOptionsServerSideProvider = 0x2;

/// `ProviderOptions_NonClientAreaProvider`.
const int providerOptionsNonClientAreaProvider = 0x4;

/// `ProviderOptions_OverrideProvider`.
const int providerOptionsOverrideProvider = 0x8;

/// `ProviderOptions_ProviderOwnsSetFocus`.
const int providerOptionsProviderOwnsSetFocus = 0x10;

/// `ProviderOptions_UseComThreading` - "call me on the apartment I was created
/// in".
///
/// This flag is the load-bearing one for a pure-Dart provider and the reason
/// it is documented here rather than at the single call site. Without it UI
/// Automation calls a server-side provider on a thread of its own choosing,
/// and a `NativeCallable.isolateLocal` invoked from a foreign thread
/// **aborts the process** - it is not an exception that can be caught. With
/// it, and with the provider thread in a single-threaded apartment, COM
/// marshals the call back to that apartment and it arrives on the message
/// pump, which is the isolate's own thread.
///
/// See `uia_bridge.dart` for what this does and does not guarantee.
const int providerOptionsUseComThreading = 0x20;

/// `ProviderOptions_RefuseNonClientSupport`.
const int providerOptionsRefuseNonClientSupport = 0x40;

/// `ProviderOptions_UseClientCoordinates`.
const int providerOptionsUseClientCoordinates = 0x100;

// ---------------------------------------------------------------------------
// NavigateDirection
// ---------------------------------------------------------------------------

/// `NavigateDirection_Parent`.
const int navigateDirectionParent = 0;

/// `NavigateDirection_NextSibling`.
const int navigateDirectionNextSibling = 1;

/// `NavigateDirection_PreviousSibling`.
const int navigateDirectionPreviousSibling = 2;

/// `NavigateDirection_FirstChild`.
const int navigateDirectionFirstChild = 3;

/// `NavigateDirection_LastChild`.
const int navigateDirectionLastChild = 4;

// ---------------------------------------------------------------------------
// Control types (UIA_*ControlTypeId)
// ---------------------------------------------------------------------------

const int uiaButtonControlTypeId = 50000;
const int uiaCalendarControlTypeId = 50001;
const int uiaCheckBoxControlTypeId = 50002;
const int uiaComboBoxControlTypeId = 50003;
const int uiaEditControlTypeId = 50004;
const int uiaHyperlinkControlTypeId = 50005;
const int uiaImageControlTypeId = 50006;
const int uiaListItemControlTypeId = 50007;
const int uiaListControlTypeId = 50008;
const int uiaMenuControlTypeId = 50009;
const int uiaMenuBarControlTypeId = 50010;
const int uiaMenuItemControlTypeId = 50011;
const int uiaProgressBarControlTypeId = 50012;
const int uiaRadioButtonControlTypeId = 50013;
const int uiaScrollBarControlTypeId = 50014;
const int uiaSliderControlTypeId = 50015;
const int uiaSpinnerControlTypeId = 50016;
const int uiaStatusBarControlTypeId = 50017;
const int uiaTabControlTypeId = 50018;
const int uiaTabItemControlTypeId = 50019;
const int uiaTextControlTypeId = 50020;
const int uiaToolBarControlTypeId = 50021;
const int uiaToolTipControlTypeId = 50022;
const int uiaTreeControlTypeId = 50023;
const int uiaTreeItemControlTypeId = 50024;
const int uiaCustomControlTypeId = 50025;
const int uiaGroupControlTypeId = 50026;
const int uiaThumbControlTypeId = 50027;
const int uiaDataGridControlTypeId = 50028;
const int uiaDataItemControlTypeId = 50029;
const int uiaDocumentControlTypeId = 50030;
const int uiaSplitButtonControlTypeId = 50031;
const int uiaWindowControlTypeId = 50032;
const int uiaPaneControlTypeId = 50033;
const int uiaHeaderControlTypeId = 50034;
const int uiaHeaderItemControlTypeId = 50035;
const int uiaTableControlTypeId = 50036;
const int uiaTitleBarControlTypeId = 50037;
const int uiaSeparatorControlTypeId = 50038;

/// The name UI Automation itself uses for a control type, for diagnostics and
/// for the test that has to print what it read back.
const Map<int, String> uiaControlTypeNames = <int, String>{
  uiaButtonControlTypeId: 'UIA_ButtonControlTypeId',
  uiaCalendarControlTypeId: 'UIA_CalendarControlTypeId',
  uiaCheckBoxControlTypeId: 'UIA_CheckBoxControlTypeId',
  uiaComboBoxControlTypeId: 'UIA_ComboBoxControlTypeId',
  uiaEditControlTypeId: 'UIA_EditControlTypeId',
  uiaHyperlinkControlTypeId: 'UIA_HyperlinkControlTypeId',
  uiaImageControlTypeId: 'UIA_ImageControlTypeId',
  uiaListItemControlTypeId: 'UIA_ListItemControlTypeId',
  uiaListControlTypeId: 'UIA_ListControlTypeId',
  uiaMenuControlTypeId: 'UIA_MenuControlTypeId',
  uiaMenuBarControlTypeId: 'UIA_MenuBarControlTypeId',
  uiaMenuItemControlTypeId: 'UIA_MenuItemControlTypeId',
  uiaProgressBarControlTypeId: 'UIA_ProgressBarControlTypeId',
  uiaRadioButtonControlTypeId: 'UIA_RadioButtonControlTypeId',
  uiaScrollBarControlTypeId: 'UIA_ScrollBarControlTypeId',
  uiaSliderControlTypeId: 'UIA_SliderControlTypeId',
  uiaSpinnerControlTypeId: 'UIA_SpinnerControlTypeId',
  uiaStatusBarControlTypeId: 'UIA_StatusBarControlTypeId',
  uiaTabControlTypeId: 'UIA_TabControlTypeId',
  uiaTabItemControlTypeId: 'UIA_TabItemControlTypeId',
  uiaTextControlTypeId: 'UIA_TextControlTypeId',
  uiaToolBarControlTypeId: 'UIA_ToolBarControlTypeId',
  uiaToolTipControlTypeId: 'UIA_ToolTipControlTypeId',
  uiaTreeControlTypeId: 'UIA_TreeControlTypeId',
  uiaTreeItemControlTypeId: 'UIA_TreeItemControlTypeId',
  uiaCustomControlTypeId: 'UIA_CustomControlTypeId',
  uiaGroupControlTypeId: 'UIA_GroupControlTypeId',
  uiaThumbControlTypeId: 'UIA_ThumbControlTypeId',
  uiaDataGridControlTypeId: 'UIA_DataGridControlTypeId',
  uiaDataItemControlTypeId: 'UIA_DataItemControlTypeId',
  uiaDocumentControlTypeId: 'UIA_DocumentControlTypeId',
  uiaSplitButtonControlTypeId: 'UIA_SplitButtonControlTypeId',
  uiaWindowControlTypeId: 'UIA_WindowControlTypeId',
  uiaPaneControlTypeId: 'UIA_PaneControlTypeId',
  uiaHeaderControlTypeId: 'UIA_HeaderControlTypeId',
  uiaHeaderItemControlTypeId: 'UIA_HeaderItemControlTypeId',
  uiaTableControlTypeId: 'UIA_TableControlTypeId',
  uiaTitleBarControlTypeId: 'UIA_TitleBarControlTypeId',
  uiaSeparatorControlTypeId: 'UIA_SeparatorControlTypeId',
};

// ---------------------------------------------------------------------------
// Property ids (UIA_*PropertyId)
// ---------------------------------------------------------------------------

const int uiaRuntimeIdPropertyId = 30000;
const int uiaBoundingRectanglePropertyId = 30001;
const int uiaProcessIdPropertyId = 30002;
const int uiaControlTypePropertyId = 30003;
const int uiaLocalizedControlTypePropertyId = 30004;
const int uiaNamePropertyId = 30005;
const int uiaAcceleratorKeyPropertyId = 30006;
const int uiaAccessKeyPropertyId = 30007;
const int uiaHasKeyboardFocusPropertyId = 30008;
const int uiaIsKeyboardFocusablePropertyId = 30009;
const int uiaIsEnabledPropertyId = 30010;
const int uiaAutomationIdPropertyId = 30011;
const int uiaClassNamePropertyId = 30012;
const int uiaHelpTextPropertyId = 30013;
const int uiaClickablePointPropertyId = 30014;
const int uiaCulturePropertyId = 30015;
const int uiaIsControlElementPropertyId = 30016;
const int uiaIsContentElementPropertyId = 30017;
const int uiaLabeledByPropertyId = 30018;
const int uiaIsPasswordPropertyId = 30019;
const int uiaNativeWindowHandlePropertyId = 30020;
const int uiaItemTypePropertyId = 30021;
const int uiaIsOffscreenPropertyId = 30022;
const int uiaOrientationPropertyId = 30023;
const int uiaFrameworkIdPropertyId = 30024;
const int uiaIsRequiredForFormPropertyId = 30025;
const int uiaItemStatusPropertyId = 30026;

// The pattern-availability block, 30027..30044, in header order. A renumber
// here is silent: the wrong property simply answers false and the pattern
// looks unsupported.
const int uiaIsDockPatternAvailablePropertyId = 30027;
const int uiaIsExpandCollapsePatternAvailablePropertyId = 30028;
const int uiaIsGridItemPatternAvailablePropertyId = 30029;
const int uiaIsGridPatternAvailablePropertyId = 30030;
const int uiaIsInvokePatternAvailablePropertyId = 30031;
const int uiaIsMultipleViewPatternAvailablePropertyId = 30032;
const int uiaIsRangeValuePatternAvailablePropertyId = 30033;
const int uiaIsScrollPatternAvailablePropertyId = 30034;
const int uiaIsScrollItemPatternAvailablePropertyId = 30035;
const int uiaIsSelectionItemPatternAvailablePropertyId = 30036;
const int uiaIsSelectionPatternAvailablePropertyId = 30037;
const int uiaIsTablePatternAvailablePropertyId = 30038;
const int uiaIsTableItemPatternAvailablePropertyId = 30039;
const int uiaIsTextPatternAvailablePropertyId = 30040;
const int uiaIsTogglePatternAvailablePropertyId = 30041;
const int uiaIsTransformPatternAvailablePropertyId = 30042;
const int uiaIsValuePatternAvailablePropertyId = 30043;
const int uiaIsWindowPatternAvailablePropertyId = 30044;

const int uiaValueValuePropertyId = 30045;
const int uiaValueIsReadOnlyPropertyId = 30046;
const int uiaRangeValueValuePropertyId = 30047;
const int uiaRangeValueIsReadOnlyPropertyId = 30048;
const int uiaRangeValueMinimumPropertyId = 30049;
const int uiaRangeValueMaximumPropertyId = 30050;
const int uiaRangeValueLargeChangePropertyId = 30051;
const int uiaRangeValueSmallChangePropertyId = 30052;

const int uiaExpandCollapseExpandCollapseStatePropertyId = 30070;
const int uiaSelectionItemIsSelectedPropertyId = 30079;
const int uiaSelectionItemSelectionContainerPropertyId = 30080;
const int uiaToggleToggleStatePropertyId = 30086;

const int uiaAriaRolePropertyId = 30101;
const int uiaAriaPropertiesPropertyId = 30102;
const int uiaIsDataValidForFormPropertyId = 30103;
const int uiaControllerForPropertyId = 30104;
const int uiaDescribedByPropertyId = 30105;
const int uiaFullDescriptionPropertyId = 30159;

/// `UIA_IsDialogPropertyId`, Windows 10 1809 and later.
///
/// Older Windows answers `UIA_E_NOTSUPPORTED` to a client asking for it and a
/// provider that returns `VT_EMPTY` is indistinguishable from one that has
/// never heard of it, which is the behaviour we want: the property is set when
/// it is true and left empty otherwise.
const int uiaIsDialogPropertyId = 30174;

const Map<int, String> uiaPropertyNames = <int, String>{
  uiaRuntimeIdPropertyId: 'UIA_RuntimeIdPropertyId',
  uiaBoundingRectanglePropertyId: 'UIA_BoundingRectanglePropertyId',
  uiaControlTypePropertyId: 'UIA_ControlTypePropertyId',
  uiaLocalizedControlTypePropertyId: 'UIA_LocalizedControlTypePropertyId',
  uiaNamePropertyId: 'UIA_NamePropertyId',
  uiaHasKeyboardFocusPropertyId: 'UIA_HasKeyboardFocusPropertyId',
  uiaIsKeyboardFocusablePropertyId: 'UIA_IsKeyboardFocusablePropertyId',
  uiaIsEnabledPropertyId: 'UIA_IsEnabledPropertyId',
  uiaAutomationIdPropertyId: 'UIA_AutomationIdPropertyId',
  uiaHelpTextPropertyId: 'UIA_HelpTextPropertyId',
  uiaIsControlElementPropertyId: 'UIA_IsControlElementPropertyId',
  uiaIsContentElementPropertyId: 'UIA_IsContentElementPropertyId',
  uiaIsPasswordPropertyId: 'UIA_IsPasswordPropertyId',
  uiaIsOffscreenPropertyId: 'UIA_IsOffscreenPropertyId',
  uiaFrameworkIdPropertyId: 'UIA_FrameworkIdPropertyId',
  uiaIsRequiredForFormPropertyId: 'UIA_IsRequiredForFormPropertyId',
  uiaIsDataValidForFormPropertyId: 'UIA_IsDataValidForFormPropertyId',
  uiaValueValuePropertyId: 'UIA_ValueValuePropertyId',
  uiaValueIsReadOnlyPropertyId: 'UIA_ValueIsReadOnlyPropertyId',
  uiaToggleToggleStatePropertyId: 'UIA_ToggleToggleStatePropertyId',
  uiaSelectionItemIsSelectedPropertyId: 'UIA_SelectionItemIsSelectedPropertyId',
  uiaExpandCollapseExpandCollapseStatePropertyId:
      'UIA_ExpandCollapseExpandCollapseStatePropertyId',
  uiaIsDialogPropertyId: 'UIA_IsDialogPropertyId',
  uiaFullDescriptionPropertyId: 'UIA_FullDescriptionPropertyId',
};

// ---------------------------------------------------------------------------
// Pattern ids (UIA_*PatternId)
// ---------------------------------------------------------------------------

const int uiaInvokePatternId = 10000;
const int uiaSelectionPatternId = 10001;
const int uiaValuePatternId = 10002;
const int uiaRangeValuePatternId = 10003;
const int uiaScrollPatternId = 10004;
const int uiaExpandCollapsePatternId = 10005;
const int uiaGridPatternId = 10006;
const int uiaGridItemPatternId = 10007;
const int uiaMultipleViewPatternId = 10008;
const int uiaWindowPatternId = 10009;
const int uiaSelectionItemPatternId = 10010;
const int uiaDockPatternId = 10011;
const int uiaTablePatternId = 10012;
const int uiaTableItemPatternId = 10013;
const int uiaTextPatternId = 10014;
const int uiaTogglePatternId = 10015;
const int uiaTransformPatternId = 10016;
const int uiaScrollItemPatternId = 10017;
const int uiaLegacyIAccessiblePatternId = 10018;
const int uiaItemContainerPatternId = 10019;
const int uiaVirtualizedItemPatternId = 10020;
const int uiaSynchronizedInputPatternId = 10021;

const Map<int, String> uiaPatternNames = <int, String>{
  uiaInvokePatternId: 'IInvokeProvider',
  uiaSelectionPatternId: 'ISelectionProvider',
  uiaValuePatternId: 'IValueProvider',
  uiaRangeValuePatternId: 'IRangeValueProvider',
  uiaScrollPatternId: 'IScrollProvider',
  uiaGridPatternId: 'IGridProvider',
  uiaExpandCollapsePatternId: 'IExpandCollapseProvider',
  uiaSelectionItemPatternId: 'ISelectionItemProvider',
  uiaTogglePatternId: 'IToggleProvider',
  uiaTextPatternId: 'ITextProvider',
  uiaWindowPatternId: 'IWindowProvider',
};

/// The `IsXPatternAvailable` property for a pattern id, or null when the
/// pattern has no such property (none of the ones this backend implements).
const Map<int, int> uiaPatternAvailabilityProperty = <int, int>{
  uiaInvokePatternId: uiaIsInvokePatternAvailablePropertyId,
  uiaSelectionPatternId: uiaIsSelectionPatternAvailablePropertyId,
  uiaValuePatternId: uiaIsValuePatternAvailablePropertyId,
  uiaRangeValuePatternId: uiaIsRangeValuePatternAvailablePropertyId,
  uiaScrollPatternId: uiaIsScrollPatternAvailablePropertyId,
  uiaExpandCollapsePatternId: uiaIsExpandCollapsePatternAvailablePropertyId,
  uiaSelectionItemPatternId: uiaIsSelectionItemPatternAvailablePropertyId,
  uiaTogglePatternId: uiaIsTogglePatternAvailablePropertyId,
  uiaTextPatternId: uiaIsTextPatternAvailablePropertyId,
  uiaWindowPatternId: uiaIsWindowPatternAvailablePropertyId,
};

// ---------------------------------------------------------------------------
// Enumerated pattern values
// ---------------------------------------------------------------------------

/// `ToggleState_Off`.
const int toggleStateOff = 0;

/// `ToggleState_On`.
const int toggleStateOn = 1;

/// `ToggleState_Indeterminate` - the third state of a tri-state checkbox,
/// which is what [SemanticsState.mixed] means.
const int toggleStateIndeterminate = 2;

/// `ExpandCollapseState_Collapsed`.
const int expandCollapseStateCollapsed = 0;

/// `ExpandCollapseState_Expanded`.
const int expandCollapseStateExpanded = 1;

/// `ExpandCollapseState_PartiallyExpanded`.
const int expandCollapseStatePartiallyExpanded = 2;

/// `ExpandCollapseState_LeafNode`.
const int expandCollapseStateLeafNode = 3;

// ---------------------------------------------------------------------------
// Event ids (UIA_*EventId)
// ---------------------------------------------------------------------------

const int uiaToolTipOpenedEventId = 20000;
const int uiaToolTipClosedEventId = 20001;
const int uiaStructureChangedEventId = 20002;
const int uiaMenuOpenedEventId = 20003;
const int uiaAutomationPropertyChangedEventId = 20004;
const int uiaAutomationFocusChangedEventId = 20005;
const int uiaAsyncContentLoadedEventId = 20006;
const int uiaMenuClosedEventId = 20007;
const int uiaLayoutInvalidatedEventId = 20008;
const int uiaInvokeInvokedEventId = 20009;
const int uiaSelectionItemElementAddedToSelectionEventId = 20010;
const int uiaSelectionItemElementRemovedFromSelectionEventId = 20011;
const int uiaSelectionItemElementSelectedEventId = 20012;
const int uiaSelectionInvalidatedEventId = 20013;
const int uiaTextTextSelectionChangedEventId = 20014;
const int uiaTextTextChangedEventId = 20015;
const int uiaWindowWindowOpenedEventId = 20016;
const int uiaWindowWindowClosedEventId = 20017;

const Map<int, String> uiaEventNames = <int, String>{
  uiaToolTipOpenedEventId: 'UIA_ToolTipOpenedEventId',
  uiaToolTipClosedEventId: 'UIA_ToolTipClosedEventId',
  uiaStructureChangedEventId: 'UIA_StructureChangedEventId',
  uiaMenuOpenedEventId: 'UIA_MenuOpenedEventId',
  uiaAutomationPropertyChangedEventId: 'UIA_AutomationPropertyChangedEventId',
  uiaAutomationFocusChangedEventId: 'UIA_AutomationFocusChangedEventId',
  uiaMenuClosedEventId: 'UIA_MenuClosedEventId',
  uiaLayoutInvalidatedEventId: 'UIA_LayoutInvalidatedEventId',
  uiaInvokeInvokedEventId: 'UIA_Invoke_InvokedEventId',
  uiaSelectionItemElementSelectedEventId:
      'UIA_SelectionItem_ElementSelectedEventId',
  uiaWindowWindowOpenedEventId: 'UIA_Window_WindowOpenedEventId',
  uiaWindowWindowClosedEventId: 'UIA_Window_WindowClosedEventId',
};

/// `StructureChangeType_ChildAdded`.
const int structureChangeTypeChildAdded = 0;

/// `StructureChangeType_ChildRemoved`.
const int structureChangeTypeChildRemoved = 1;

/// `StructureChangeType_ChildrenInvalidated`.
const int structureChangeTypeChildrenInvalidated = 2;

/// `StructureChangeType_ChildrenBulkAdded`.
const int structureChangeTypeChildrenBulkAdded = 3;

/// `StructureChangeType_ChildrenBulkRemoved`.
const int structureChangeTypeChildrenBulkRemoved = 4;

/// `StructureChangeType_ChildrenReordered`.
const int structureChangeTypeChildrenReordered = 5;

// ---------------------------------------------------------------------------
// HRESULTs UI Automation adds
// ---------------------------------------------------------------------------

/// `UIA_E_ELEMENTNOTENABLED` (0x80040200).
const int uiaErrorElementNotEnabled = -2147220992;

/// `UIA_E_ELEMENTNOTAVAILABLE` (0x80040201) - the element existed and does
/// not any more.
///
/// This is the answer a provider for a node the tree has dropped gives to
/// anything that would need the live tree. It is not a failure: a client that
/// held a reference across a rebuild is *expected* to see it, and answering
/// it is the difference between a screen reader noticing and a crash.
const int uiaErrorElementNotAvailable = -2147220991;

/// `UIA_E_NOCLICKABLEPOINT` (0x80040202).
const int uiaErrorNoClickablePoint = -2147220990;

/// `UIA_E_NOTSUPPORTED` (0x80040204).
const int uiaErrorNotSupported = -2147220988;

/// `UiaAppendRuntimeId` - the marker that opens a fragment's runtime id.
///
/// A runtime id whose first element is this constant tells UI Automation to
/// prepend the host window's own id, which is what makes the id unique across
/// the desktop without the provider having to know anything about the desktop.
const int uiaAppendRuntimeId = 3;

// ---------------------------------------------------------------------------
// Interface identifiers
// ---------------------------------------------------------------------------

final Guid iidIRawElementProviderSimple =
    Guid.parse('D6DD68D1-86FD-4332-8666-9ABEDEA2D24C');
final Guid iidIRawElementProviderFragment =
    Guid.parse('F7063DA8-8359-439C-9297-BBC5299A7D87');
final Guid iidIRawElementProviderFragmentRoot =
    Guid.parse('620CE2A5-AB8F-40A9-86CB-DE3C75599B58');
final Guid iidIInvokeProvider =
    Guid.parse('54FCB24B-E18E-47A2-B4D3-ECCBE77599A2');
final Guid iidIToggleProvider =
    Guid.parse('56D00BD0-C4F4-433C-A836-1A52A57E0892');
final Guid iidIValueProvider =
    Guid.parse('C7935180-6FB3-4201-B174-7DF73ADBF64A');
final Guid iidIRangeValueProvider =
    Guid.parse('36DC7AEF-33E6-4691-AFE1-2BE7274B3D33');
final Guid iidISelectionProvider =
    Guid.parse('FB8B03AF-3BDF-48D4-BD36-1A65793BE168');
final Guid iidISelectionItemProvider =
    Guid.parse('2ACAD808-B2D4-452D-A407-91FF1AD167B2');
final Guid iidIExpandCollapseProvider =
    Guid.parse('D847D3A5-CAB0-4A98-8C32-ECB45C59AD24');

/// `CLSID_CUIAutomation` - the *client* object, used only by the readback
/// test. A provider never creates one.
final Guid clsidCUIAutomation =
    Guid.parse('FF48DBA4-60EF-4201-AA87-54103EEF594E');

final Guid iidIUIAutomation =
    Guid.parse('30CBE57D-D9D0-452A-AB13-7AC5AC4825EE');
final Guid iidIUIAutomationElement =
    Guid.parse('D22108AA-8AC5-49A5-837B-37BBB3D7591E');
final Guid iidIUIAutomationTreeWalker =
    Guid.parse('4042C624-389C-4AFC-A630-9DF854A541FC');

// ---------------------------------------------------------------------------
// VARIANT
// ---------------------------------------------------------------------------

const int vtEmpty = 0;
const int vtNull = 1;
const int vtI2 = 2;
const int vtI4 = 3;
const int vtR4 = 4;
const int vtR8 = 5;
const int vtBstr = 8;
const int vtBool = 11;
const int vtUnknown = 13;
const int vtI8 = 20;
const int vtArray = 0x2000;

/// `VARIANT_TRUE`. A `VARIANT_BOOL` is **not** a C `bool`: true is -1 as a
/// signed 16-bit value, and writing 1 gives a value that some clients read as
/// true and some do not.
const int variantTrue = -1;

/// `VARIANT_FALSE`.
const int variantFalse = 0;
