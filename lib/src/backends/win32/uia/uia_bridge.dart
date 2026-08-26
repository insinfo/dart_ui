/// One HWND, one provider tree, and the `WM_GETOBJECT` that connects them.
///
/// ## How a screen reader reaches a window
///
///   1. Narrator (or NVDA, or an `IUIAutomation` client) asks UI Automation
///      for the element at an HWND;
///   2. UI Automation sends that window `WM_GETOBJECT` with
///      `lParam == UiaRootObjectId` (-25);
///   3. the window procedure calls `UiaReturnRawElementProvider` with its
///      `IRawElementProviderSimple` and **returns what that function returned**
///      - the value is a cookie, not a pointer, and interpreting it is a bug;
///   4. UI Automation then calls the provider's methods to walk the tree.
///
/// Step 3 lives in `win32_window.dart`, which carries the arm
/// [getObjectPatch] describes; the constant is kept because it is also what
/// `uia_client_probe.dart` reproduces, and a patch next to the code it patches
/// cannot go stale on its own.
///
/// **Who calls [attach]**: `uia_session.dart`, and only when a client asks.
/// See [onDemandAttach]. Attaching eagerly is still supported and is what the
/// probe does.
///
/// ## The threading problem, stated plainly
///
/// UI Automation calls a server-side provider on a thread it chooses. Every
/// method in `com_server.dart` is a `NativeCallable.isolateLocal`, because
/// that is the only kind that can return an `HRESULT`, and an `isolateLocal`
/// invoked from a foreign thread **aborts the process** - not an exception, not
/// a catchable error, an abort.
///
/// The mitigation is COM's own, and it is why [attach] does what it does:
///
///   * the provider thread enters a single-threaded apartment
///     (`CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)`);
///   * `get_ProviderOptions` returns `ProviderOptions_UseComThreading`, which
///     tells UI Automation the provider has apartment affinity;
///   * COM then marshals a call from any other apartment back to ours, where
///     it is delivered by the message pump - the isolate's own thread.
///
/// That is the documented arrangement and it is what makes this workable at
/// all. What it is **not** is a guarantee this code can enforce: by the time a
/// foreign thread reaches the trampoline, Dart has already aborted, so there is
/// no check to write and no fallback to take. [Win32UiaBridge.threadSafety]
/// reports what was arranged, and the client-side probe under
/// `test/backends/win32/uia/` is what turns the arrangement into evidence.
///
/// Dart 3.6 has no `NativeCallable.isolateGroupBound`; when it does, that is
/// the callable this file should use and the apartment dance becomes optional.
/// This repository already carries that request in `doc/propostas/`.
library;

import 'dart:ffi';
import 'dart:io';

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../widgets/semantics.dart';
import '../win32_api.dart';
import '../win32_constants.dart';
import '../win32_structs.dart';
import 'com_server.dart';
import 'uia_constants.dart';
import 'uia_core.dart';
import 'uia_events.dart';
import 'uia_provider.dart';

export 'uia_constants.dart' show uiaRootObjectId, wmGetobject;

/// What apartment the provider thread ended up in.
enum UiaThreadSafety {
  /// A single-threaded apartment this bridge entered. Cross-apartment calls
  /// are marshalled back here and arrive on the message pump.
  apartmentThreaded,

  /// The thread was already in an STA when [Win32UiaBridge.attach] ran -
  /// somebody else called `CoInitialize` first. Same guarantee.
  alreadyApartmentThreaded,

  /// `CoInitializeEx` answered `RPC_E_CHANGED_MODE`: the thread is in the
  /// multi-threaded apartment and cannot leave it.
  ///
  /// **This is the dangerous state.** A free-threaded apartment means COM does
  /// not marshal, so UI Automation calls the provider directly from its own
  /// thread and the `isolateLocal` trampoline aborts the process. The bridge
  /// refuses to publish a provider in this state and says so.
  multiThreaded,

  /// COM could not be initialised at all.
  unavailable,
}

/// Publishes one window's semantic tree to UI Automation.
final class Win32UiaBridge with DisposableMixin {
  Win32UiaBridge._({
    required this.hwnd,
    required this.core,
    required this.api,
    required this.threadSafety,
    required List<BackendDiagnostic> diagnostics,
  }) : _diagnostics = diagnostics {
    _tree = UiaProviderTree(
      core: core,
      hostProviderFor: _hostProvider,
    );
    _threadId = api.getCurrentThreadId();
    ComServerRegistry.ownerThreadId = _threadId;
  }

  /// Every attached window, so a static `WM_GETOBJECT` handler can find its
  /// bridge without the window class knowing this type exists.
  static final Map<int, Win32UiaBridge> _bridges = <int, Win32UiaBridge>{};

  /// The bridge for [hwnd], or null when the window has none.
  static Win32UiaBridge? forWindow(int hwnd) => _bridges[hwnd];

  /// How many windows are publishing. The teardown test asserts zero.
  static int get attachedCount => _bridges.length;

  /// Attaches a bridge to [hwnd], or explains why it could not.
  ///
  /// Never throws: a machine without `uiautomationcore.dll`, a thread already
  /// in the multi-threaded apartment and a window that already has a bridge
  /// are all answers, not failures. Section 6.6's rule.
  static UiaAttachResult attach(int hwnd) {
    final Win32UiaBridge? existing = _bridges[hwnd];
    if (existing != null) {
      return UiaAttachResult(bridge: existing, diagnostics: existing.warnings);
    }

    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];
    final UiaCoreLoadResult loaded = UiaCore.load();
    diagnostics.addAll(loaded.diagnostics);
    final UiaCore? core = loaded.core;
    if (core == null) {
      return UiaAttachResult(bridge: null, diagnostics: diagnostics);
    }

    final Win32Api? api = Win32Api.load().api;
    if (api == null) {
      diagnostics.add(
        const BackendDiagnostic.missingLibrary(
          'user32.dll',
          detail: 'a UI Automation bridge needs the window API it describes',
        ),
      );
      return UiaAttachResult(bridge: null, diagnostics: diagnostics);
    }

    final UiaThreadSafety safety = _enterApartment(diagnostics);
    if (safety == UiaThreadSafety.multiThreaded ||
        safety == UiaThreadSafety.unavailable) {
      // Refusing is the whole point. Publishing here would hand UI Automation
      // a provider it is entitled to call from its own thread, and the first
      // such call takes the process down with no Dart frame in the report.
      diagnostics.add(
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'UI Automation not published: the provider thread is not '
              'in a single-threaded apartment (${safety.name})',
          detail: 'a provider reached from a foreign thread aborts the '
              'process, because NativeCallable.isolateLocal is the only '
              'callable that can return an HRESULT and it is isolate-bound',
        ),
      );
      return UiaAttachResult(bridge: null, diagnostics: diagnostics);
    }

    final Win32UiaBridge bridge = Win32UiaBridge._(
      hwnd: hwnd,
      core: core,
      api: api,
      threadSafety: safety,
      diagnostics: diagnostics,
    );
    _bridges[hwnd] = bridge;
    return UiaAttachResult(bridge: bridge, diagnostics: diagnostics);
  }

  final int hwnd;
  final UiaCore core;
  final Win32Api api;
  final UiaThreadSafety threadSafety;
  final List<BackendDiagnostic> _diagnostics;

  late final UiaProviderTree _tree;
  late final int _threadId;

  /// Notes worth carrying into a probe result.
  List<BackendDiagnostic> get warnings =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  /// The elements. Public so the bridge stays a bridge and the tree stays
  /// testable on its own.
  UiaProviderTree get tree => _tree;

  /// The thread the provider answers on, as `GetCurrentThreadId` reports it.
  int get threadId => _threadId;

  /// Whether anybody is listening. Cheap; the difference between a frame that
  /// costs nothing and one that marshals events into a process that is not
  /// there.
  bool get clientsAreListening => core.uiaClientsAreListening() != 0;

  final UiaEventTranslator _translator = const UiaEventTranslator();

  // -------------------------------------------------------------------------
  // WM_GETOBJECT
  // -------------------------------------------------------------------------

  /// The `LRESULT` for a `WM_GETOBJECT`, or null when the message is not ours.
  ///
  /// Null means "fall through to `DefWindowProcW`", and it is the answer for
  /// every `lParam` other than [uiaRootObjectId] - `OBJID_CLIENT` above all,
  /// which is MSAA asking for an `IAccessible`. Answering that one with a UIA
  /// provider is how a window ends up invisible to half the assistive
  /// technology on the machine; see the MSAA entry in [absentFeatures].
  static int? handleGetObject(int hwnd, int wParam, int lParam) {
    // lParam arrives as an unsigned machine word; UiaRootObjectId is -25.
    if (lParam.toSigned(32) != uiaRootObjectId) return null;
    Win32UiaBridge? bridge = _bridges[hwnd];
    if (bridge != null && bridge.isDisposed) return null;
    // Nobody had built a provider for this window yet. This message is the
    // only honest signal that one is now wanted - it arrives when Narrator
    // starts, when Inspect points here, when any IUIAutomation client calls
    // ElementFromHandle, and never otherwise. See [onDemandAttach].
    bridge ??= onDemandAttach?.call(hwnd);
    if (bridge == null || bridge.isDisposed) return null;
    return bridge.respondToGetObject(wParam, lParam);
  }

  /// Builds a bridge for a window that has none, on the first client request.
  ///
  /// Null - the default - means a window publishes only if somebody attached
  /// to it explicitly, which is the behaviour this class had before the hook
  /// existed. `uia_session.dart` installs the callback that makes activation
  /// lazy, and returning null from it is a supported answer: the
  /// `WM_GETOBJECT` then falls through to `DefWindowProcW` exactly as it does
  /// for an unregistered window.
  ///
  /// Deliberately a hook rather than a direct call into the session: this file
  /// is the layer that knows about COM and `WM_GETOBJECT`, and the layer that
  /// knows about semantic trees sits above it. Inverting that would put a
  /// widget-layer import in the innermost provider file.
  static Win32UiaBridge? Function(int hwnd)? onDemandAttach;

  /// The instance half of [handleGetObject].
  int? respondToGetObject(int wParam, int lParam) {
    throwIfDisposed();
    final Pointer<Void>? root = _tree.root?.pointer;
    if (root == null) return null;
    return core.uiaReturnRawElementProvider(hwnd, wParam, lParam, root);
  }

  // -------------------------------------------------------------------------
  // Publishing
  // -------------------------------------------------------------------------

  /// Republishes the whole tree and refreshes the coordinate transform.
  void publish(SemanticsSnapshot snapshot) {
    throwIfDisposed();
    refreshTransform();
    _tree.publish(snapshot);
  }

  /// Publishes [snapshot] and raises the events [update] describes.
  ///
  /// [before] is the tree as it was; [SemanticsOwner] has already replaced its
  /// own copy by the time an update is in hand, so the caller keeps one.
  ///
  /// Returns the events actually raised, which is fewer than the translator
  /// produced whenever a node has no provider or nobody is listening.
  List<UiaEventRecord> applyUpdate(
    SemanticsUpdate update,
    SemanticsSnapshot snapshot, {
    SemanticsSnapshot? before,
  }) {
    throwIfDisposed();
    final List<UiaEventRecord> events = _translator.translate(
      update,
      before: before,
      after: snapshot,
    );
    publish(snapshot);
    if (events.isEmpty || !clientsAreListening) {
      return const <UiaEventRecord>[];
    }
    final List<UiaEventRecord> raised = <UiaEventRecord>[];
    for (final UiaEventRecord event in events) {
      if (raise(event)) raised.add(event);
    }
    return raised;
  }

  /// Raises one event. Returns whether it reached UI Automation.
  bool raise(UiaEventRecord event) {
    final UiaNodeProvider? provider = _tree.providerFor(event.nodeId);
    if (provider == null) return false;
    final Pointer<Void> pointer = provider.pointer;
    switch (event) {
      case UiaAutomationEventRecord(:final int eventId):
        return core.uiaRaiseAutomationEvent(pointer, eventId) >= 0;
      case UiaStructureChangedRecord(
          :final int changeType,
          :final int? childRuntimeId
        ):
        return _raiseStructureChanged(pointer, changeType, childRuntimeId);
      case UiaPropertyChangedRecord(
          :final int propertyId,
          :final Object? oldValue,
          :final Object? newValue
        ):
        return _raisePropertyChanged(
          pointer,
          propertyId,
          oldValue,
          newValue,
        );
    }
  }

  bool _raiseStructureChanged(
    Pointer<Void> provider,
    int changeType,
    int? childRuntimeId,
  ) {
    if (childRuntimeId == null) {
      return core.uiaRaiseStructureChangedEvent(
            provider,
            changeType,
            nullptr,
            0,
          ) >=
          0;
    }
    final Pointer<Int32> id = api.allocator.allocate<Int32>(8);
    try {
      id[0] = uiaAppendRuntimeId;
      id[1] = childRuntimeId;
      return core.uiaRaiseStructureChangedEvent(provider, changeType, id, 2) >=
          0;
    } finally {
      api.allocator.free(id);
    }
  }

  bool _raisePropertyChanged(
    Pointer<Void> provider,
    int propertyId,
    Object? oldValue,
    Object? newValue,
  ) {
    final raiser = core.uiaRaiseAutomationPropertyChangedEvent;
    if (raiser == null) return false;
    final int size = variantSize;
    final Pointer<Uint8> block = api.allocator.allocate<Uint8>(size * 2);
    final Pointer<Void> oldVariant = block.cast<Void>();
    final Pointer<Void> newVariant =
        Pointer<Void>.fromAddress(block.address + size);
    try {
      core.writeVariant(oldVariant, oldValue);
      core.writeVariant(newVariant, newValue);
      return raiser(provider, propertyId, oldVariant, newVariant) >= 0;
    } finally {
      // The VARIANTs are passed *by value*, so the callee copied whatever it
      // needed and the BSTR or SAFEARRAY inside them is still ours. Skipping
      // this leaks one string per property change, which at sixty frames a
      // second is a leak with a slope.
      core.clearVariant(oldVariant);
      core.clearVariant(newVariant);
      api.allocator.free(block);
    }
  }

  // -------------------------------------------------------------------------
  // Coordinates
  // -------------------------------------------------------------------------

  /// Reads the client area's position and the window's DPI back from Windows.
  ///
  /// Asked rather than cached, for the reason `win32_window.dart` gives about
  /// its own origin: a window can be moved by the shell, by another process or
  /// by a monitor being unplugged, and not all of those route through WM_MOVE
  /// before a client asks where an element is.
  void refreshTransform() {
    final Pointer<Win32Point> point = api.allocator<Win32Point>();
    try {
      point.ref
        ..x = 0
        ..y = 0;
      if (api.clientToScreen(hwnd, point) != 0) {
        _tree.transform
          ..clientOriginX = point.ref.x.toDouble()
          ..clientOriginY = point.ref.y.toDouble();
      }
    } finally {
      api.allocator.free(point);
    }
    final int dpi = api.getDpiForWindow?.call(hwnd) ?? 0;
    _tree.transform.scale = dpi <= 0 ? 1.0 : dpi / defaultScreenDpi;
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  @override
  void onDispose() {
    _bridges.remove(hwnd);
    // Tell UI Automation to drop its own references before we drop ours.
    // Skipping this leaves the client holding elements whose window is gone,
    // which it discovers only by timing out.
    final Pointer<Void>? root = _tree.root?.pointer;
    if (root != null) core.uiaDisconnectProvider(root);
    _tree.dispose();
  }

  // -------------------------------------------------------------------------
  // Host provider
  // -------------------------------------------------------------------------

  Pointer<Void> _hostProvider() {
    final Pointer<Pointer<Void>> out =
        api.allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    try {
      out.value = nullptr;
      if (core.uiaHostProviderFromHwnd(hwnd, out) < 0) return nullptr;
      return out.value;
    } finally {
      api.allocator.free(out);
    }
  }

  // -------------------------------------------------------------------------
  // Apartment
  // -------------------------------------------------------------------------

  static UiaThreadSafety _enterApartment(
    List<BackendDiagnostic> diagnostics,
  ) {
    if (!Platform.isWindows) return UiaThreadSafety.unavailable;
    final _Ole32? ole32 = _Ole32.tryLoad();
    if (ole32 == null) {
      diagnostics.add(
        const BackendDiagnostic.missingLibrary(
          'ole32.dll',
          detail: 'CoInitializeEx is what puts the provider thread in an '
              'apartment UI Automation can marshal into',
        ),
      );
      return UiaThreadSafety.unavailable;
    }
    final int hr = ole32.coInitializeEx(nullptr, _coinitApartmentThreaded);
    return switch (hr.toSigned(32)) {
      0 => UiaThreadSafety.apartmentThreaded,
      1 => UiaThreadSafety.alreadyApartmentThreaded, // S_FALSE
      _rpcChangedMode => UiaThreadSafety.multiThreaded,
      _ => UiaThreadSafety.unavailable,
    };
  }

  static const int _coinitApartmentThreaded = 0x2;
  static const int _rpcChangedMode = -2147417850; // RPC_E_CHANGED_MODE

  /// The features this bridge does **not** provide, by name.
  ///
  /// Read by the report and asserted by a test, so that "absent" stays a
  /// decision somebody wrote down rather than something nobody got to.
  static const Map<String, String> absentFeatures = <String, String>{
    'IAccessible (MSAA)':
        'WM_GETOBJECT with OBJID_CLIENT falls through to DefWindowProcW. UI '
            'Automation supplies an MSAA bridge over any UIA provider, so a '
            'client that only speaks MSAA still sees the tree; a hand-written '
            'IAccessible would be a second, divergent description of the same '
            'window.',
    'IRawElementProviderAdviseEvents':
        'The advise interface lets a provider know which events a client is '
            'actually subscribed to. UiaClientsAreListening answers the '
            'coarse form of the same question at no cost, and is what this '
            'bridge gates on.',
    'IRawElementProviderHwndOverride':
        'Nothing in this framework hosts a child HWND, so there is no window '
            'whose provider would need overriding.',
    'Actions on a node whose widget cannot perform one':
        'Invoke, Toggle and SetValue reach the widget through '
            'UiaProviderTree.actionDispatcher, which uia_session.dart assigns '
            'to SemanticsOwner.performAction. A render object that declares an '
            'action in SemanticsConfiguration but does not implement '
            'SemanticsActionTarget still answers UIA_E_NOTSUPPORTED - the '
            'declaration and the doing are separate, and only the controls '
            'that implement the interface can be operated. See the table in '
            'uia_session.dart for which ones do.',
    'Text ranges, scrolling and numeric ranges':
        'ITextProvider, IScrollProvider and IRangeValueProvider - see '
            'uiaAbsentPatterns in uia_mapping.dart, which names what each '
            'would need from the semantic tree and what the tree has instead.',
  };

  /// The exact change `win32_window.dart` needs, as source.
  ///
  /// Here rather than in a report because a report goes stale and a constant
  /// next to the code it patches does not. One import and one `switch` arm;
  /// `wmGetobject` is re-exported by this library, and `win32_constants.dart`
  /// does not define a name like it, so the import cannot be ambiguous.
  ///
  /// Attaching is deliberately *not* part of the patch: `Win32UiaBridge.attach`
  /// takes an HWND and can be called by whoever owns the window, so nothing
  /// about the accessibility tree has to be known inside `win32_window.dart`.
  /// Without an attached bridge [handleGetObject] answers null and the message
  /// falls through exactly as it does today, which is what makes this change
  /// safe to apply before anything publishes.
  static const String getObjectPatch = '''
// In win32_window.dart, add to the imports:
import 'uia/uia_bridge.dart';

// and one arm to handleMessage's switch, anywhere before `default`:
      case wmGetobject:
        // lParam == UiaRootObjectId (-25) is a UI Automation client asking
        // for a provider. Anything else - OBJID_CLIENT above all - is MSAA
        // and belongs to DefWindowProcW, which is what a null answer means.
        // The returned LRESULT is a cookie from UiaReturnRawElementProvider,
        // not a pointer: return it unchanged.
        final int? provider =
            Win32UiaBridge.handleGetObject(hwnd, wParam, lParam);
        if (provider != null) return provider;
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

// Optional, and only if this file would rather own teardown than leave it to
// whoever called attach(): in the existing `case wmNcdestroy:` arm, before
// whatever it already does,
//     Win32UiaBridge.forWindow(hwnd)?.dispose();
''';
}

/// What [Win32UiaBridge.attach] found.
final class UiaAttachResult {
  const UiaAttachResult({required this.bridge, required this.diagnostics});

  /// Null when a library was missing or the thread's apartment is wrong.
  final Win32UiaBridge? bridge;

  final List<BackendDiagnostic> diagnostics;
}

/// `CoInitializeEx` and its partner, bound lazily.
final class _Ole32 {
  _Ole32._(this.coInitializeEx, this.coUninitialize);

  final int Function(Pointer<Void>, int) coInitializeEx;
  final void Function() coUninitialize;

  static _Ole32? _instance;
  static bool _attempted = false;

  static _Ole32? tryLoad() {
    if (_attempted) return _instance;
    _attempted = true;
    try {
      final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
      return _instance = _Ole32._(
        ole32.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
            int Function(Pointer<Void>, int)>('CoInitializeEx'),
        ole32
            .lookupFunction<Void Function(), void Function()>('CoUninitialize'),
      );
    } on Object {
      return null;
    }
  }
}
