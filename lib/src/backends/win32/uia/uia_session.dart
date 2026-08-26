/// The wiring: a live semantic tree, a real HWND, and a screen reader.
///
/// `uia_bridge.dart` publishes *a* tree to *an* HWND. Everything under this
/// directory was complete in that sense and still invisible to Narrator, for
/// a reason worth naming rather than fixing quietly: nothing in `lib/` ever
/// called [Win32UiaBridge.attach], nothing pumped a [SemanticsUpdate] into it,
/// and [UiaProviderTree.actionDispatcher] was never assigned, so every control
/// pattern answered `UIA_E_NOTSUPPORTED`. Three missing calls, four thousand
/// lines of provider. This file is the three calls.
///
/// ## Activation is lazy, and that is the design
///
/// A UI Automation provider costs a COM apartment, a vtable per interface and
/// a tree rebuild per frame. Almost every window on almost every machine pays
/// that for nobody: no screen reader, no Inspect, no automation client. So
/// [WindowsAccessibility.register] does nothing but remember the window - one
/// map entry, no COM - and the provider is built the first time a client
/// actually asks, which Windows signals by sending `WM_GETOBJECT` with
/// `UiaRootObjectId`.
///
/// That message is the honest trigger. It arrives when Narrator starts, when
/// Inspect points at the window, when any `IUIAutomation` client calls
/// `ElementFromHandle` - and never otherwise. A window that no assistive
/// technology ever looks at runs exactly the code it ran before this file
/// existed.
///
/// ## What [pump] costs when nothing changed
///
/// A rebuild of the semantic tree and a diff against the previous one. The
/// diff is by id, so an unchanged frame produces an empty [SemanticsUpdate]
/// and nothing is published and no event is raised. It is not free - the walk
/// is O(render objects) - which is the other half of why activation is lazy.
///
/// ## What this file does *not* do
///
/// It does not decide when to pump. A window knows when its layout is settled
/// and this file does not, so [pump] is public and called by whoever owns the
/// frame. See the class docs on [WindowsAccessibility] for the one-line hook.
library;

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../semantics/accessibility.dart';
import '../../../semantics/semantics.dart';
import 'uia_bridge.dart';
import 'uia_events.dart';

export '../../../semantics/accessibility.dart' show AccessibilityTreeSource;

/// Publishes one window's live semantic tree to UI Automation.
///
/// The whole integration, from the owner of a Win32 window, is:
///
/// ```dart
/// // once, when the window is created - costs one map entry:
/// WindowsAccessibility.register(
///   hwnd,
///   (owner: buildOwner.semanticsOwner, root: () => buildOwner.renderRoot),
/// );
///
/// // once per frame, after layout has run:
/// WindowsAccessibility.forWindow(hwnd)?.pump();
///
/// // once, when the window is destroyed:
/// WindowsAccessibility.unregister(hwnd);
/// ```
///
/// [forWindow] answers null until a client has asked, so the per-frame line
/// is a null check and nothing else on a machine with no assistive technology
/// running.
final class WindowsAccessibility
    with DisposableMixin
    implements WindowAccessibility {
  WindowsAccessibility._({
    required this.hwnd,
    required this.bridge,
    required AccessibilityTreeSource source,
  }) : _source = source {
    // The line that turns every declared action into a performable one. Until
    // this is assigned, `IInvokeProvider::Invoke` on a button answers
    // UIA_E_NOTSUPPORTED - the button announces itself correctly and cannot be
    // pressed, which is the failure mode that reads as "accessibility exists"
    // right up until somebody tries to use it.
    bridge.tree.actionDispatcher = _perform;
  }

  /// Windows that would publish if asked, and the tree each would publish.
  static final Map<int, AccessibilityTreeSource> _registered =
      <int, AccessibilityTreeSource>{};

  /// Windows that have been asked and are publishing.
  static final Map<int, WindowsAccessibility> _live =
      <int, WindowsAccessibility>{};

  /// Diagnostics from an activation that failed, kept per window so the
  /// reason survives to be reported rather than being discarded inside a
  /// `WM_GETOBJECT` that had nowhere to return it.
  static final Map<int, List<BackendDiagnostic>> _failures =
      <int, List<BackendDiagnostic>>{};

  /// Whether the `WM_GETOBJECT` hook has been installed on [Win32UiaBridge].
  static bool _hooked = false;

  /// Remembers that [hwnd] has a semantic tree worth publishing.
  ///
  /// Cheap by construction: no COM, no provider, no tree walk. The window
  /// becomes visible to assistive technology only when a client asks for it.
  static void register(int hwnd, AccessibilityTreeSource source) {
    _registered[hwnd] = source;
    if (_hooked) return;
    _hooked = true;
    Win32UiaBridge.onDemandAttach = _activate;
  }

  /// Forgets [hwnd] and tears down its provider if one was built.
  ///
  /// Called from the window's destruction path. Skipping it leaves a client
  /// holding elements for a window that is gone, which it discovers by timing
  /// out rather than by being told.
  static void unregister(int hwnd) {
    _registered.remove(hwnd);
    _failures.remove(hwnd);
    _live.remove(hwnd)?.dispose();
  }

  /// The live session for [hwnd], or null while nobody has asked.
  static WindowsAccessibility? forWindow(int hwnd) => _live[hwnd];

  /// Whether [hwnd] would publish if a client asked.
  static bool isRegistered(int hwnd) => _registered.containsKey(hwnd);

  /// How many windows are publishing. The teardown test asserts zero.
  static int get liveCount => _live.length;

  /// Why [hwnd] could not publish, if it was asked and could not.
  ///
  /// Empty is the answer for a window that was never asked, which is not the
  /// same as a window that was asked and succeeded - [forWindow] separates
  /// those two.
  static List<BackendDiagnostic> failureFor(int hwnd) =>
      List<BackendDiagnostic>.unmodifiable(
        _failures[hwnd] ?? const <BackendDiagnostic>[],
      );

  /// Builds the provider for [hwnd] on first demand.
  ///
  /// Returns null - and leaves the `WM_GETOBJECT` to `DefWindowProcW` - for a
  /// window nobody registered, and for one where [Win32UiaBridge.attach]
  /// refused: a missing `uiautomationcore.dll`, or the multi-threaded
  /// apartment that would abort the process on the first provider call.
  /// Refusing is a supported outcome; see section 6.6.
  static Win32UiaBridge? _activate(int hwnd) {
    final WindowsAccessibility? already = _live[hwnd];
    if (already != null) return already.bridge;
    final AccessibilityTreeSource? source = _registered[hwnd];
    if (source == null) return null;

    final UiaAttachResult result = Win32UiaBridge.attach(hwnd);
    final Win32UiaBridge? bridge = result.bridge;
    if (bridge == null) {
      _failures[hwnd] = result.diagnostics;
      return null;
    }
    final session = WindowsAccessibility._(
      hwnd: hwnd,
      bridge: bridge,
      source: source,
    );
    _live[hwnd] = session;
    // The client that sent this WM_GETOBJECT is about to read the tree, and a
    // bridge with nothing published answers null and looks like a window with
    // no provider. Publishing here rather than waiting for the next frame is
    // what makes the very first question answerable.
    session.pump();
    return bridge;
  }

  final int hwnd;
  final Win32UiaBridge bridge;
  final AccessibilityTreeSource _source;

  int _pumps = 0;
  int _publishes = 0;
  int _eventsRaised = 0;

  /// How many times [pump] ran, how many of those published a change, and how
  /// many UI Automation events reached the runtime. Read by tests and by the
  /// diagnostics overlay; a publish count that stays at one while the window
  /// visibly changes is the signature of a pump that is not being called.
  ({int pumps, int publishes, int events}) get counters =>
      (pumps: _pumps, publishes: _publishes, events: _eventsRaised);

  /// Rebuilds the semantic tree, publishes what changed and raises the events.
  ///
  /// Call after layout: [SemanticsNode.bounds] come from `RenderBox.size` and
  /// an unlaid-out tree either carries last frame's geometry or has none at
  /// all. Cheap and side-effect-free when nothing changed - the diff is empty
  /// and neither [Win32UiaBridge.publish] nor any event runs.
  ///
  /// Returns the events actually raised, which is empty whenever no client is
  /// listening even if the tree did change.
  @override
  List<UiaEventRecord> pump() {
    if (isDisposed) return const <UiaEventRecord>[];
    _pumps++;
    final SemanticsOwner owner = _source.owner;
    // Held before the rebuild: the owner replaces its own snapshot in
    // `update`, and the event translator needs the previous one to say what a
    // property changed *from*.
    final SemanticsSnapshot before = owner.snapshot;
    final SemanticsUpdate update = owner.update(_source.root());
    if (update.isEmpty) return const <UiaEventRecord>[];
    _publishes++;
    final List<UiaEventRecord> raised = bridge.applyUpdate(
      update,
      owner.snapshot,
      before: before,
    );
    _eventsRaised += raised.length;
    return raised;
  }

  /// Publishes the tree unconditionally, ignoring the diff.
  ///
  /// For the cases a diff cannot see: the window moved, so every element's
  /// screen bounds changed while no semantic property did. [pump] is the
  /// ordinary path.
  @override
  void republish() {
    if (isDisposed) return;
    final SemanticsOwner owner = _source.owner;
    owner.build(_source.root());
    bridge.publish(owner.snapshot);
    _publishes++;
  }

  /// The dispatcher handed to [UiaProviderTree.actionDispatcher].
  ///
  /// Every guard that matters lives one layer down, in
  /// [SemanticsOwner.performAction]: a stale id, an action the node never
  /// declared and a render object that cannot perform one are all false here.
  bool _perform(int nodeId, SemanticsAction action, {String? value}) {
    if (isDisposed) return false;
    return _source.owner.performAction(nodeId, action, value: value);
  }

  @override
  void onDispose() {
    _live.remove(hwnd);
    bridge.tree.actionDispatcher = null;
    if (!bridge.isDisposed) bridge.dispose();
  }

  /// Drops every registration and every live session.
  ///
  /// For tests and for an orderly process shutdown; a session outliving its
  /// window is a provider pointing at a dead HWND.
  static void reset() {
    for (final WindowsAccessibility session in _live.values.toList()) {
      session.dispose();
    }
    _live.clear();
    _registered.clear();
    _failures.clear();
    // The hook goes with them. Leaving it installed would be harmless today -
    // `_activate` answers null for a window nobody registered - but it would
    // outlive the backend that put it there, and a stale callback into a
    // stopped message loop is the kind of thing that is only harmless until it
    // is not.
    Win32UiaBridge.onDemandAttach = null;
    _hooked = false;
  }
}

/// The Win32 half of [AccessibilityHost], installed by `win32_backend.dart`.
///
/// A thin object over [WindowsAccessibility]'s statics rather than a second
/// design: the state is keyed by HWND and there is exactly one HWND namespace
/// per process, so a per-instance table would be a way of pretending
/// otherwise. What this type buys is that `application.dart` holds an
/// interface from `lib/src/platform/` and never learns that UI Automation
/// exists.
final class WindowsUiaAccessibilityHost implements AccessibilityHost {
  const WindowsUiaAccessibilityHost();

  @override
  String get apiName => 'UI Automation';

  @override
  void register(int nativeHandle, AccessibilityTreeSource source) =>
      WindowsAccessibility.register(nativeHandle, source);

  @override
  WindowAccessibility? forWindow(int nativeHandle) =>
      WindowsAccessibility.forWindow(nativeHandle);

  @override
  void unregister(int nativeHandle) =>
      WindowsAccessibility.unregister(nativeHandle);
}

/// Makes this process's Win32 windows readable by assistive technology.
///
/// Idempotent, and cheap: it installs one object. Nothing is built, no COM is
/// initialised and no window is touched until a client asks - see the
/// `Activation is lazy` note at the top of this file.
void installWindowsUiaAccessibility() =>
    platformAccessibility ??= const WindowsUiaAccessibilityHost();

/// Undoes [installWindowsUiaAccessibility] and drops every live session.
///
/// For a backend's teardown and for tests. Leaving a host installed after its
/// backend is gone would let a window register against a provider whose
/// message loop has stopped.
void removeWindowsUiaAccessibility() {
  if (platformAccessibility is WindowsUiaAccessibilityHost) {
    platformAccessibility = null;
  }
  WindowsAccessibility.reset();
}
