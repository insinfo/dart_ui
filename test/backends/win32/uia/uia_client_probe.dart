/// Reads the semantic tree back the way Narrator does, in its own process.
///
/// **Not a test file** - the name has no `_test` suffix on purpose, so
/// `dart test` does not pick it up. `uia_bridge_test.dart` runs it as a
/// subprocess and asserts on what it prints.
///
/// ## Why a subprocess
///
/// Because the failure mode is an abort, not an exception. Every provider
/// method is a `NativeCallable.isolateLocal`, and an `isolateLocal` invoked
/// from a thread that is not the isolate's takes the whole process down at the
/// VM level - no Dart frame, no `catch`, no test failure, just a dead runner
/// and every other suite in it. Running this in a child process turns that
/// outcome into an exit code the parent can report calmly, and is the only
/// honest way to *measure* whether the apartment arrangement in
/// `uia_bridge.dart` actually holds on this machine.
///
/// ## What it does
///
///   1. registers a window class with a `WndProc` that answers `WM_GETOBJECT`
///      exactly as `win32_window.dart` will once the patch in
///      `Win32UiaBridge.getObjectPatch` is applied;
///   2. creates a real HWND and publishes a three-node semantic tree to it;
///   3. becomes a UI Automation **client** in the same process -
///      `CoCreateInstance(CLSID_CUIAutomation)` - and asks for the element at
///      that HWND, which is what makes Windows send the `WM_GETOBJECT`;
///   4. reads the root's name, then walks to the first child and reads its
///      name and control type.
///
/// Every step prints one `probe:` line, so a hang or an abort says how far it
/// got rather than only that it failed.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/backends/win32/uia/uia_bridge.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_constants.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_core.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_events.dart';
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_structs.dart';
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/widgets/semantics.dart';

typedef _WndProcNative = IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr);

late final Win32Api _api;

// `print`, not `stdout.writeln` + `flush`: flushing returns a Future and
// leaves the sink bound, so the next synchronous write throws "StreamSink is
// bound to a stream" - in the middle of a probe whose whole job is to survive
// long enough to say where it stopped.
void _say(String message) => print('probe: $message');

/// The window procedure, containing the exact arm `win32_window.dart` needs.
int _wndProc(int hwnd, int msg, int wParam, int lParam) {
  if (msg == wmGetobject) {
    final int? provider = Win32UiaBridge.handleGetObject(hwnd, wParam, lParam);
    if (provider != null) return provider;
  }
  return _api.defWindowProcW(hwnd, msg, wParam, lParam);
}

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

  final String className = 'DartUiUiaProbe.${api.getCurrentThreadId()}.$pid';
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
  final int atom = api.registerClassExW(descriptor);
  if (atom == 0) {
    _say('failed: RegisterClassExW ${api.getLastError()}');
    exit(3);
  }
  _say('class registered');

  final Pointer<Uint16> title = api.toUtf16('dart_ui UIA probe');
  final int hwnd = api.createWindowExW(
    0,
    namePointer,
    title,
    wsOverlappedWindow,
    100,
    100,
    400,
    300,
    0,
    0,
    instance,
    0,
  );
  if (hwnd == 0) {
    _say('failed: CreateWindowExW ${api.getLastError()}');
    exit(4);
  }
  // Shown, because a window UI Automation is asked about should be one a user
  // could be looking at; a hidden window is a different code path in the
  // client and this probe is about the ordinary one.
  api.showWindow(hwnd, swShowNoActivate);
  _say('hwnd created');

  final UiaAttachResult attached = Win32UiaBridge.attach(hwnd);
  final Win32UiaBridge? bridge = attached.bridge;
  if (bridge == null) {
    for (final diagnostic in attached.diagnostics) {
      _say('diagnostic: $diagnostic');
    }
    _say('failed: no bridge');
    exit(5);
  }
  _say('apartment=${bridge.threadSafety.name}');
  _say('threadId=${bridge.threadId}');

  const SemanticsSnapshot published = SemanticsSnapshot(
    SemanticsNode(
      id: 0,
      role: SemanticsRole.generic,
      bounds: Rect.fromLTWH(0, 0, 400, 300),
      label: 'probe root',
      children: <SemanticsNode>[
        SemanticsNode(
          id: 1,
          role: SemanticsRole.button,
          label: 'Save',
          bounds: Rect.fromLTWH(10, 20, 80, 30),
          actions: <SemanticsAction>{SemanticsAction.activate},
        ),
        SemanticsNode(
          id: 2,
          role: SemanticsRole.checkbox,
          label: 'Remember me',
          bounds: Rect.fromLTWH(10, 60, 120, 20),
          states: <SemanticsState>{SemanticsState.checked},
        ),
      ],
    ),
  );
  bridge.publish(published);
  _say('published');

  // Pump whatever creation queued, so the message loop is known to work
  // before anything depends on it.
  _pump(api, arena);

  final UiaCore core = UiaCore.load().core!;
  final _Client? client = _Client.create(arena);
  if (client == null) {
    _say('failed: CoCreateInstance(CLSID_CUIAutomation)');
    exit(6);
  }
  _say('client created');

  final Pointer<Void> element = client.elementFromHandle(hwnd, arena);
  if (element == nullptr) {
    _say('failed: ElementFromHandle');
    exit(7);
  }
  _say('elementFromHandle ok');
  _say('root.name=${client.name(core, element, arena)}');
  _say('root.controlType=${client.controlType(element, arena)}');

  final Pointer<Void> walker = client.rawViewWalker(arena);
  if (walker == nullptr) {
    _say('failed: get_RawViewWalker');
    exit(8);
  }
  // Every child, not just the first: the element for an HWND is a *merge* of
  // this provider and the window's own non-client provider, so the raw view
  // begins with a UIA_TitleBarControlTypeId that belongs to Windows and not to
  // us. Walking the whole row and reporting each is what lets the assertions
  // name what they are looking for instead of counting positions.
  Pointer<Void> child = _Client.firstChild(walker, element, arena);
  if (child == nullptr) {
    _say('failed: GetFirstChildElement');
    exit(9);
  }
  var index = 0;
  while (child != nullptr && index < 32) {
    _say('child[$index].name=${client.name(core, child, arena)}');
    _say('child[$index].controlType=${client.controlType(child, arena)}');
    _say('child[$index].automationId=${client.stringProperty(
      core,
      child,
      uiaAutomationIdPropertyId,
      arena,
    )}');
    _say('child[$index].toggleState=${client.intProperty(
      child,
      uiaToggleToggleStatePropertyId,
      arena,
    )}');
    final Pointer<Void> next = _Client.nextSibling(walker, child, arena);
    _releaseCom(child);
    child = next;
    index++;
  }
  _say('childCount=$index');

  _say('clientsAreListening=${core.uiaClientsAreListening()}');

  // The incremental half of section 31.4, with a client actually attached:
  // untick the checkbox and let the bridge turn the diff into UI Automation
  // events. What is proved here is the *raising* - that the runtime accepts a
  // property-changed event carrying two VARIANTs and a structure-changed event
  // carrying a runtime id - not that a screen reader reacted, which no
  // automated test can observe.
  const SemanticsSnapshot after = SemanticsSnapshot(
    SemanticsNode(
      id: 0,
      role: SemanticsRole.generic,
      bounds: Rect.fromLTWH(0, 0, 400, 300),
      label: 'probe root',
      children: <SemanticsNode>[
        SemanticsNode(
          id: 1,
          role: SemanticsRole.button,
          label: 'Saved',
          bounds: Rect.fromLTWH(10, 20, 80, 30),
          actions: <SemanticsAction>{SemanticsAction.activate},
          states: <SemanticsState>{SemanticsState.focused},
        ),
      ],
    ),
  );
  final List<UiaEventRecord> raised = bridge.applyUpdate(
    const SemanticsUpdate(
      added: <SemanticsNode>[],
      updated: <SemanticsNode>[
        SemanticsNode(
          id: 1,
          role: SemanticsRole.button,
          label: 'Saved',
          bounds: Rect.fromLTWH(10, 20, 80, 30),
          actions: <SemanticsAction>{SemanticsAction.activate},
          states: <SemanticsState>{SemanticsState.focused},
        ),
      ],
      removed: <int>[2],
    ),
    after,
    before: published,
  );
  _say('eventsRaised=${raised.length}');
  for (final UiaEventRecord event in raised) {
    _say('event=$event');
  }

  _releaseCom(walker);
  _releaseCom(element);
  client.dispose();

  bridge.dispose();
  api.destroyWindow(hwnd);
  api.unregisterClassW(namePointer, instance);
  api.heapRelease(namePointer);
  api.heapRelease(title);
  api.allocator.free(descriptor);
  callable.close();
  arena.dispose();
  _say('done');
}

void _pump(Win32Api api, NativeArena arena) {
  final Pointer<Msg> message = arena.allocate<Msg>(sizeOf<Msg>());
  var guard = 0;
  while (api.peekMessageW(message, 0, 0, 0, pmRemove) != 0 && guard++ < 256) {
    api.translateMessage(message);
    api.dispatchMessageW(message);
  }
}

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

void _releaseCom(Pointer<Void> object) {
  if (object == nullptr) return;
  comMethod<_NativeRefCount>(object, comSlotRelease)
      .asFunction<_DartRefCount>()(object);
}

/// The client half: `IUIAutomation` by vtable slot.
final class _Client {
  _Client._(this._automation);

  final Pointer<Void> _automation;

  // IUIAutomation, after IUnknown's three.
  static const int _slotElementFromHandle = 6;
  static const int _slotRawViewWalker = 16;

  // IUIAutomationElement.
  static const int _slotGetCurrentPropertyValue = 10;

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
      print('probe: CoCreateInstance -> ${hresultName(hr)}');
      return null;
    }
    return _Client._(out.value);
  }

  Pointer<Void> elementFromHandle(int hwnd, NativeArena arena) {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    final int hr = hresult(
      comMethod<_NativeHandleOut>(_automation, _slotElementFromHandle)
          .asFunction<_DartHandleOut>()(_automation, hwnd, out),
    );
    if (hr < 0) {
      print('probe: ElementFromHandle -> ${hresultName(hr)}');
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
      print('probe: get_RawViewWalker -> ${hresultName(hr)}');
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
