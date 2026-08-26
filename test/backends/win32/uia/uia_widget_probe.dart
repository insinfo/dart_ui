/// Real widgets, a real HWND, and a real UI Automation client that operates
/// them.
///
/// **Not a test file** - no `_test` suffix, so `dart test` does not pick it up.
/// `uia_session_test.dart` runs it as a subprocess and asserts on what it
/// prints, for the reason `uia_client_probe.dart` gives at length: a provider
/// method reached from a foreign thread aborts the VM, and an abort inside the
/// test runner takes every other suite with it.
///
/// ## What this proves that `uia_client_probe.dart` does not
///
/// That probe publishes a hand-written [SemanticsSnapshot] and reads it back.
/// It proves the COM plumbing. It does not touch a widget, and it cannot -
/// there was no path from a widget to an action when it was written.
///
/// This one:
///
///   1. builds **real render objects** from `lib/src/widgets/` - `RenderButton`,
///      `RenderToggle`, `RenderSlider`, `RenderTextField` - and lays them out
///      through a real `PipelineOwner`;
///   2. **registers** the window with [WindowsAccessibility] and does *not*
///      attach a provider, so that the provider appearing at all is evidence
///      that lazy activation fired;
///   3. becomes an `IUIAutomation` client and calls `ElementFromHandle`, which
///      is what makes Windows send the `WM_GETOBJECT` that activates it;
///   4. finds each control **by name** and drives it through the pattern a
///      screen reader would use: `IUIAutomationInvokePattern::Invoke` on the
///      button, `IUIAutomationTogglePattern::Toggle` on the check box,
///      `IUIAutomationValuePattern::SetValue` on the slider and on the text
///      field;
///   5. re-lays out, pumps, and reads the property back through the client to
///      show the widget actually changed.
///
/// Step 4 is the one that was impossible before: every pattern used to answer
/// `UIA_E_NOTSUPPORTED`. A Dart-side counter is printed alongside, so a pass
/// means the client's call reached the widget's own `activate()` - the same
/// method a mouse click and the space bar reach.
///
/// Every step prints one `probe:` line, so a hang or an abort says how far it
/// got rather than only that it failed.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/backends/win32/uia/uia_bridge.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_constants.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_core.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_session.dart';
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_structs.dart';
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/layout/render_flex.dart';
import 'package:dart_ui/src/widgets/controls.dart';
import 'package:dart_ui/src/widgets/semantics.dart';

typedef _WndProcNative = IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr);

late final Win32Api _api;

void _say(String message) => print('probe: $message');

int _wndProc(int hwnd, int msg, int wParam, int lParam) {
  if (msg == wmGetobject) {
    final int? provider = Win32UiaBridge.handleGetObject(hwnd, wParam, lParam);
    if (provider != null) return provider;
  }
  return _api.defWindowProcW(hwnd, msg, wParam, lParam);
}

/// How many times the button's own `onPressed` ran.
int _buttonPresses = 0;

void main() {
  if (!Platform.isWindows) {
    _say('skipped: not Windows');
    return;
  }
  final Win32Api? api = Win32Api.load().api;
  if (api == null) {
    _say('failed: user32 did not load');
    exit(2);
  }
  _api = api;

  final NativeArena arena = NativeArena();
  final callable = NativeCallable<_WndProcNative>.isolateLocal(
    _wndProc,
    exceptionalReturn: 0,
  );

  // -------------------------------------------------------------------------
  // A real window
  // -------------------------------------------------------------------------

  final String className = 'DartUiUiaWidgetProbe.${api.getCurrentThreadId()}'
      '.$pid';
  final Pointer<Uint16> namePointer = api.toUtf16(className);
  final int instance = api.getModuleHandleW(nullptr);
  final Pointer<WndClassExW> descriptor = api.allocator<WndClassExW>();
  descriptor.ref
    ..cbSize = sizeOf<WndClassExW>()
    ..style = 0
    ..lpfnWndProc = callable.nativeFunction
    ..cbClsExtra = 0
    ..cbWndExtra = 0
    ..hInstance = instance
    ..hIcon = 0
    ..hCursor = 0
    ..hbrBackground = 0
    ..lpszMenuName = nullptr
    ..lpszClassName = namePointer
    ..hIconSm = 0;
  if (api.registerClassExW(descriptor) == 0) {
    _say('failed: RegisterClassExW ${api.getLastError()}');
    exit(3);
  }
  final Pointer<Uint16> title = api.toUtf16('dart_ui UIA widget probe');
  final int hwnd = api.createWindowExW(
    0,
    namePointer,
    title,
    wsOverlappedWindow,
    100,
    100,
    400,
    320,
    0,
    0,
    instance,
    0,
  );
  if (hwnd == 0) {
    _say('failed: CreateWindowExW ${api.getLastError()}');
    exit(4);
  }
  api.showWindow(hwnd, swShowNoActivate);
  _say('hwnd created');

  // -------------------------------------------------------------------------
  // A real widget tree
  // -------------------------------------------------------------------------

  late final RenderToggle checkBox;
  late final RenderSlider slider;

  final RenderButton button = RenderButton(
    label: 'Save',
    onPressed: () => _buttonPresses++,
  );
  checkBox = RenderToggle(
    label: 'Remember me',
    value: false,
    style: ToggleStyle.checkBox,
    onChanged: (bool value) => checkBox.value = value,
  );
  slider = RenderSlider(
    value: 0.25,
    min: 0,
    max: 1,
    step: 0.05,
    orientation: SliderOrientation.horizontal,
    onChanged: (double value) => slider.value = value,
  );
  final TextEditingController controller = TextEditingController('before');
  final RenderTextField field = RenderTextField(
    controller: controller,
    label: 'Name',
    obscure: false,
    readOnly: false,
  );

  final RenderFlex column = RenderFlex(direction: Axis.vertical)
    ..add(button)
    ..add(checkBox)
    ..add(slider)
    ..add(field);

  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.loose(const Size(380, 300)),
  )..root = column;

  void layout() => pipeline.drawFrame(DisplayList());

  try {
    layout();
  } on Object catch (error) {
    _say('failed: layout threw $error');
    exit(5);
  }
  _say('laid out');

  final SemanticsOwner semantics = SemanticsOwner();

  // -------------------------------------------------------------------------
  // Registered, not attached
  // -------------------------------------------------------------------------

  WindowsAccessibility.register(
    hwnd,
    (owner: semantics, root: () => pipeline.root),
  );
  // The whole point of lazy activation: registering costs a map entry and
  // builds nothing. If this were non-null, the rest of the probe would prove
  // nothing about who activated the provider.
  _say(
      'liveBeforeClient=${WindowsAccessibility.forWindow(hwnd) == null ? 0 : 1}');

  _pump(api, arena);

  // -------------------------------------------------------------------------
  // A real client
  // -------------------------------------------------------------------------

  // A UI Automation *client* needs COM initialised on its own thread, and
  // nothing has done it: the provider side is not built yet, which is exactly
  // what `liveBeforeClient=0` above reports. `uia_client_probe.dart` never
  // had to do this because it attached the bridge eagerly and
  // `Win32UiaBridge.attach` calls `CoInitializeEx` on the way. A real
  // application is in the same position as this probe - `win32_ole.dart`
  // initialises the apartment for drag and drop long before any screen reader
  // shows up - so entering the STA here is the realistic arrangement, not a
  // convenience.
  final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
  final int coInit = hresult(
    ole32.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)>('CoInitializeEx')(nullptr, 0x2),
  );
  _say('coInitializeEx=${hresultName(coInit)}');

  final UiaCore core = UiaCore.load().core!;
  final _Client? client = _Client.create(arena);
  if (client == null) {
    _say('failed: CoCreateInstance(CLSID_CUIAutomation)');
    exit(6);
  }

  final Pointer<Void> element = client.elementFromHandle(hwnd, arena);
  if (element == nullptr) {
    _say('failed: ElementFromHandle');
    for (final diagnostic in WindowsAccessibility.failureFor(hwnd)) {
      _say('diagnostic: $diagnostic');
    }
    exit(7);
  }
  _say('elementFromHandle ok');

  final WindowsAccessibility? session = WindowsAccessibility.forWindow(hwnd);
  if (session == null) {
    for (final diagnostic in WindowsAccessibility.failureFor(hwnd)) {
      _say('diagnostic: $diagnostic');
    }
    _say('failed: the client asked and no session was activated');
    exit(8);
  }
  // Non-zero exactly because the WM_GETOBJECT above ran the on-demand hook.
  _say('liveAfterClient=1');
  _say('apartment=${session.bridge.threadSafety.name}');
  _say('pumpsAfterActivation=${session.counters.pumps}');

  // -------------------------------------------------------------------------
  // The tree, as the client sees it
  // -------------------------------------------------------------------------

  final Pointer<Void> walker = client.rawViewWalker(arena);
  if (walker == nullptr) {
    _say('failed: get_RawViewWalker');
    exit(9);
  }

  /// Every element under the window, in raw-view order.
  ///
  /// A list and not a map keyed by name: the raw view merges the window's own
  /// non-client provider with ours, so it contains elements Windows owns, and
  /// more than one of them can carry an empty name. A map would silently drop
  /// one of a colliding pair - and leak the COM reference to it.
  List<({String name, int controlType, Pointer<Void> element})> readChildren() {
    final found = <({String name, int controlType, Pointer<Void> element})>[];
    Pointer<Void> child = _Client.firstChild(walker, element, arena);
    var index = 0;
    while (child != nullptr && index < 32) {
      found.add((
        name: client.name(core, child, arena),
        controlType: int.tryParse(client.controlType(child, arena)) ?? 0,
        element: child,
      ));
      child = _Client.nextSibling(walker, child, arena);
      index++;
    }
    _say('childCount=$index');
    return found;
  }

  final children = readChildren();
  for (final child in children) {
    _say('child[${child.name}].controlType=${child.controlType}');
  }

  Pointer<Void> byName(String name, int failureCode) {
    for (final child in children) {
      if (child.name == name) return child.element;
    }
    _say('failed: no element named "$name" in '
        '${children.map((c) => c.name).toList()}');
    exit(failureCode);
  }

  // -------------------------------------------------------------------------
  // Invoke: the button
  // -------------------------------------------------------------------------

  final Pointer<Void> buttonElement = byName('Save', 10);
  _say('button.controlType=${client.controlType(buttonElement, arena)}');
  final Pointer<Void> invoke =
      client.pattern(buttonElement, uiaInvokePatternId, arena);
  if (invoke == nullptr) {
    _say('failed: the button offers no IInvokeProvider');
    exit(11);
  }
  _say('button.hasInvokePattern=1');
  final int invokeHr = _Client.call0(invoke, _slotInvoke);
  _say('button.invokeHresult=${hresultName(invokeHr)}');
  // The measurement. `onPressed` is the same callback a mouse click and the
  // space bar reach, so a 1 here is the client having operated the widget and
  // not merely having read it.
  _say('button.presses=$_buttonPresses');
  _releaseCom(invoke);

  // -------------------------------------------------------------------------
  // Toggle: the check box
  // -------------------------------------------------------------------------

  final Pointer<Void> checkElement = byName('Remember me', 12);
  _say('checkBox.toggleBefore=${client.intProperty(
    checkElement,
    uiaToggleToggleStatePropertyId,
    arena,
  )}');
  final Pointer<Void> toggle =
      client.pattern(checkElement, uiaTogglePatternId, arena);
  if (toggle == nullptr) {
    _say('failed: the check box offers no IToggleProvider');
    exit(13);
  }
  final int toggleHr = _Client.call0(toggle, _slotToggle);
  _say('checkBox.toggleHresult=${hresultName(toggleHr)}');
  _say('checkBox.dartValue=${checkBox.value}');
  _releaseCom(toggle);

  // The widget changed; the tree the client reads has not, until a frame runs
  // and the session pumps. This is the seam a window owner is responsible for.
  layout();
  final int eventsFromToggle = session.pump().length;
  _say('checkBox.eventsRaised=$eventsFromToggle');
  _say('checkBox.toggleAfter=${client.intProperty(
    checkElement,
    uiaToggleToggleStatePropertyId,
    arena,
  )}');

  // -------------------------------------------------------------------------
  // SetValue: the slider and the text field
  // -------------------------------------------------------------------------

  // The slider carries no label, so it is the one control found by control
  // type rather than by name.
  final Pointer<Void> sliderElement = children
      .where((c) => c.controlType == uiaSliderControlTypeId)
      .map((c) => c.element)
      .followedBy(<Pointer<Void>>[nullptr]).first;
  if (sliderElement == nullptr) {
    _say('failed: no slider element found');
    exit(15);
  }
  _say('slider.valueBefore=${client.stringProperty(
    core,
    sliderElement,
    uiaValueValuePropertyId,
    arena,
  )}');
  final Pointer<Void> sliderValue =
      client.pattern(sliderElement, uiaValuePatternId, arena);
  if (sliderValue == nullptr) {
    _say('failed: the slider offers no IValueProvider');
    exit(16);
  }
  final Pointer<Void> bstr = core.sysAllocString(api.toUtf16('0.75'));
  final int sliderHr = _Client.call1(sliderValue, _slotSetValue, bstr);
  core.sysFreeString(bstr);
  _say('slider.setValueHresult=${hresultName(sliderHr)}');
  _say('slider.dartValue=${slider.value.toStringAsFixed(2)}');
  _releaseCom(sliderValue);

  layout();
  session.pump();
  _say('slider.valueAfter=${client.stringProperty(
    core,
    sliderElement,
    uiaValueValuePropertyId,
    arena,
  )}');

  final Pointer<Void> fieldElement = byName('Name', 17);
  final Pointer<Void> fieldValue =
      client.pattern(fieldElement, uiaValuePatternId, arena);
  if (fieldValue == nullptr) {
    _say('failed: the text field offers no IValueProvider');
    exit(18);
  }
  final Pointer<Void> text = core.sysAllocString(api.toUtf16('after'));
  final int fieldHr = _Client.call1(fieldValue, _slotSetValue, text);
  core.sysFreeString(text);
  _say('field.setValueHresult=${hresultName(fieldHr)}');
  _say('field.dartValue=${controller.value}');
  _releaseCom(fieldValue);

  layout();
  session.pump();
  _say('field.valueAfter=${client.stringProperty(
    core,
    fieldElement,
    uiaValueValuePropertyId,
    arena,
  )}');

  _say('counters=${session.counters}');

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  for (final child in children) {
    _releaseCom(child.element);
  }
  _releaseCom(walker);
  _releaseCom(element);
  client.dispose();

  WindowsAccessibility.unregister(hwnd);
  _say('liveAfterUnregister=${WindowsAccessibility.liveCount}');

  api.destroyWindow(hwnd);
  api.unregisterClassW(namePointer, instance);
  api.heapRelease(namePointer);
  api.heapRelease(title);
  api.allocator.free(descriptor);
  callable.close();
  arena.dispose();
  ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize')();
  _say('done');
  // Explicit: UI Automation leaves its own threads running in this process and
  // the VM waits for them, so a probe that merely falls off the end of `main`
  // never exits and the parent reports a hang instead of a result.
  exit(0);
}

void _pump(Win32Api api, NativeArena arena) {
  final Pointer<Msg> message = arena.allocate<Msg>(sizeOf<Msg>());
  var guard = 0;
  while (api.peekMessageW(message, 0, 0, 0, pmRemove) != 0 && guard++ < 256) {
    api.translateMessage(message);
    api.dispatchMessageW(message);
  }
}

// IUIAutomationInvokePattern / TogglePattern / ValuePattern, after IUnknown.
const int _slotInvoke = 3;
const int _slotToggle = 3;
const int _slotSetValue = 3;

typedef _NativeRefCount = Uint32 Function(Pointer<Void>);
typedef _DartRefCount = int Function(Pointer<Void>);
typedef _NativeOut = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _DartOut = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _NativeHandleOut = Int32 Function(
    Pointer<Void>, IntPtr, Pointer<Pointer<Void>>);
typedef _DartHandleOut = int Function(
    Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _NativeElementOut = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _DartElementOut = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _NativePropertyValue = Int32 Function(
    Pointer<Void>, Int32, Pointer<Void>);
typedef _DartPropertyValue = int Function(Pointer<Void>, int, Pointer<Void>);
typedef _NativePatternOut = Int32 Function(
    Pointer<Void>, Int32, Pointer<Pointer<Void>>);
typedef _DartPatternOut = int Function(
    Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _NativeCall0 = Int32 Function(Pointer<Void>);
typedef _DartCall0 = int Function(Pointer<Void>);
typedef _NativeCall1 = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _DartCall1 = int Function(Pointer<Void>, Pointer<Void>);

void _releaseCom(Pointer<Void> object) {
  if (object == nullptr) return;
  comMethod<_NativeRefCount>(object, comSlotRelease)
      .asFunction<_DartRefCount>()(object);
}

/// The client half: `IUIAutomation` by vtable slot.
final class _Client {
  _Client._(this._automation);

  final Pointer<Void> _automation;

  static const int _slotElementFromHandle = 6;
  static const int _slotRawViewWalker = 16;

  // IUIAutomationElement.
  static const int _slotGetCurrentPropertyValue = 10;
  static const int _slotGetCurrentPattern = 16;

  // IUIAutomationTreeWalker.
  static const int _slotGetFirstChildElement = 4;
  static const int _slotGetNextSiblingElement = 6;

  static _Client? create(NativeArena arena) {
    final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
    final coCreateInstance = ole32.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Void>, Uint32, Pointer<Uint8>,
            Pointer<Pointer<Void>>),
        int Function(Pointer<Uint8>, Pointer<Void>, int, Pointer<Uint8>,
            Pointer<Pointer<Void>>)>('CoCreateInstance');
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    final int hr = hresult(
      coCreateInstance(
        clsidCUIAutomation.allocateIn(arena),
        nullptr,
        1, // CLSCTX_INPROC_SERVER
        iidIUIAutomation.allocateIn(arena),
        out,
      ),
    );
    if (hr < 0 || out.value == nullptr) {
      _say('CoCreateInstance -> ${hresultName(hr)}');
      return null;
    }
    return _Client._(out.value);
  }

  static int call0(Pointer<Void> target, int slot) => hresult(
        comMethod<_NativeCall0>(target, slot).asFunction<_DartCall0>()(target),
      );

  static int call1(Pointer<Void> target, int slot, Pointer<Void> argument) =>
      hresult(
        comMethod<_NativeCall1>(target, slot).asFunction<_DartCall1>()(
            target, argument),
      );

  Pointer<Void> elementFromHandle(int hwnd, NativeArena arena) {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    final int hr = hresult(
      comMethod<_NativeHandleOut>(_automation, _slotElementFromHandle)
          .asFunction<_DartHandleOut>()(_automation, hwnd, out),
    );
    if (hr < 0) {
      _say('ElementFromHandle -> ${hresultName(hr)}');
      return nullptr;
    }
    return out.value;
  }

  Pointer<Void> rawViewWalker(NativeArena arena) {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    final int hr = hresult(
      comMethod<_NativeOut>(_automation, _slotRawViewWalker)
          .asFunction<_DartOut>()(_automation, out),
    );
    if (hr < 0) {
      _say('get_RawViewWalker -> ${hresultName(hr)}');
      return nullptr;
    }
    return out.value;
  }

  /// `IUIAutomationElement::GetCurrentPattern`, or `nullptr` when the element
  /// does not support it - which for this framework means the provider did not
  /// advertise the pattern, and is the answer being measured.
  Pointer<Void> pattern(
    Pointer<Void> element,
    int patternId,
    NativeArena arena,
  ) {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    out.value = nullptr;
    final int hr = hresult(
      comMethod<_NativePatternOut>(element, _slotGetCurrentPattern)
          .asFunction<_DartPatternOut>()(element, patternId, out),
    );
    if (hr < 0) {
      _say('GetCurrentPattern($patternId) -> ${hresultName(hr)}');
      return nullptr;
    }
    return out.value;
  }

  static Pointer<Void> firstChild(
    Pointer<Void> walker,
    Pointer<Void> element,
    NativeArena arena,
  ) =>
      _walk(walker, _slotGetFirstChildElement, element, arena);

  static Pointer<Void> nextSibling(
    Pointer<Void> walker,
    Pointer<Void> element,
    NativeArena arena,
  ) =>
      _walk(walker, _slotGetNextSiblingElement, element, arena);

  static Pointer<Void> _walk(
    Pointer<Void> walker,
    int slot,
    Pointer<Void> element,
    NativeArena arena,
  ) {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    final int hr = hresult(
      comMethod<_NativeElementOut>(walker, slot).asFunction<_DartElementOut>()(
          walker, element, out),
    );
    return hr < 0 ? nullptr : out.value;
  }

  String name(UiaCore core, Pointer<Void> element, NativeArena arena) =>
      stringProperty(core, element, uiaNamePropertyId, arena);

  String stringProperty(
    UiaCore core,
    Pointer<Void> element,
    int propertyId,
    NativeArena arena,
  ) {
    final Pointer<Void> variant =
        arena.allocate<Uint8>(variantSize).cast<Void>();
    final int hr = hresult(
      comMethod<_NativePropertyValue>(element, _slotGetCurrentPropertyValue)
          .asFunction<_DartPropertyValue>()(element, propertyId, variant),
    );
    if (hr < 0) return '<${hresultName(hr)}>';
    final int vt = variant.cast<Uint16>().value;
    if (vt != vtBstr) return '<vt=$vt>';
    final Pointer<Void> bstr = Pointer<Void>.fromAddress(variant.address + 8)
        .cast<Pointer<Void>>()
        .value;
    if (bstr == nullptr) return '';
    final Pointer<Uint16> units = bstr.cast<Uint16>();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 4096 && units[i] != 0; i++) {
      buffer.writeCharCode(units[i]);
    }
    core.sysFreeString(bstr);
    return buffer.toString();
  }

  String intProperty(
    Pointer<Void> element,
    int propertyId,
    NativeArena arena,
  ) {
    final Pointer<Void> variant =
        arena.allocate<Uint8>(variantSize).cast<Void>();
    final int hr = hresult(
      comMethod<_NativePropertyValue>(element, _slotGetCurrentPropertyValue)
          .asFunction<_DartPropertyValue>()(element, propertyId, variant),
    );
    if (hr < 0) return '<${hresultName(hr)}>';
    final int vt = variant.cast<Uint16>().value;
    if (vt != vtI4) return '<vt=$vt>';
    return '${Pointer<Int32>.fromAddress(variant.address + 8).value}';
  }

  String controlType(Pointer<Void> element, NativeArena arena) =>
      intProperty(element, uiaControlTypePropertyId, arena);

  void dispose() => _releaseCom(_automation);
}
