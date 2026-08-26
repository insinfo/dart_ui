/// Drag and drop, as a port the core can name and no backend owns.
///
/// `Capability.dragAndDrop` existed in [Capability] for a long time with
/// nothing behind it, and `lib/src/backends/wayland/wayland_drag_drop.dart`
/// says why in its own header: defining the port is a *cross-backend* decision,
/// because it has to fit three protocols that agree on very little. This file
/// is that decision. The Wayland manager keeps its state machine and now speaks
/// this vocabulary; the Win32 and X11 halves were written against it.
///
/// ## The three protocols, and where they actually disagree
///
/// It is worth stating the shapes side by side, because every compromise below
/// is a consequence of one of these rows.
///
/// |                       | Win32 (OLE)                       | Wayland (`wl_data_device`)      | X11 (XDND)                             |
/// |-----------------------|-----------------------------------|---------------------------------|----------------------------------------|
/// | who drives            | the **source**, inside `DoDragDrop`| the **compositor**              | the **source**, by `ClientMessage`     |
/// | target is told by     | `IDropTarget` calls on our thread | `enter`/`motion`/`drop` events  | `XdndEnter`/`XdndPosition` messages    |
/// | target answers        | `*pdwEffect`, **before returning**| `accept` + `set_actions`        | `XdndStatus` message                   |
/// | data arrives          | `IDataObject::GetData`, **now**   | a pipe fd, later                | a selection property, later            |
/// | formats named by      | integers (`CF_UNICODETEXT`)       | MIME strings                    | atoms, which are MIME strings          |
/// | drop confirmed by     | returning from `Drop`             | `wl_data_offer.finish`          | `XdndFinished`                         |
/// | coordinates in        | screen, physical                  | surface-local, logical          | root window, physical                  |
///
/// Two consequences run through the whole design:
///
///  1. **The answer is synchronous and the data is not.** Every protocol needs
///     an accept/refuse decision inside the event that asked for it, and two of
///     three cannot produce the bytes in that same moment. So
///     [DropTargetHandler.onDragEnter] and [DropTargetHandler.onDragOver]
///     return a [DropResponse] directly, while [DragData.readBytes] is a
///     `Future` everywhere. See `drag_drop_types.dart` for the long version.
///  2. **Win32 is reentrant in a way the others are not.** `IDropTarget`
///     methods arrive while the isolate is inside `pumpEvents`, dispatched out
///     of a message the OLE drag loop posted. Nothing after an `await` in a
///     handler can run before that method must return, exactly as
///     `LiveResizeWindow` documents for the modal resize loop. The Win32
///     implementation therefore reads its `IDataObject` *synchronously* at drop
///     time and hands the handler a [MemoryDragData] whose futures are already
///     complete - it satisfies the async contract instead of being shaped by
///     it.
///
/// ## What a backend that cannot do this returns
///
/// [UnavailableDragDrop], carrying the reason - never null and never a silent
/// no-op. A headless run and (for now) the web backend both take that path, so
/// an application that registers a drop target on them gets a
/// [DragDropException] naming the backend at the moment of registration rather
/// than a drop that mysteriously never arrives.
library;

import '../foundation/diagnostics.dart';
import 'clipboard.dart';
import 'drag_drop_types.dart';
import 'native_window.dart';
import 'window_events.dart';

export 'drag_drop_types.dart';

/// The callbacks a window layer implements to receive drops.
///
/// One handler per registered window. The framework's own implementation is
/// `DragDropController` in `lib/src/widgets/drag_drop.dart`, which fans the
/// session out to whichever [DropTarget] widget is under the pointer; an
/// application that wants the window-level events raw may implement this
/// directly and register it against the backend.
///
/// **Enter, over and leave must not await and must not be expensive.** They
/// run inside the platform's own drag loop - literally so on Win32 - and
/// `onDragOver` arrives at pointer rate. The rule is `WaylandDropTargetHandler`'s
/// and it survives into the port unchanged.
abstract interface class DropTargetHandler {
  /// The pointer entered the window carrying [event]`.data`.
  ///
  /// The answer decides the cursor the user sees, so a target that cannot use
  /// the data must return [DropResponse.reject] rather than accept and then
  /// ignore the drop.
  DropResponse onDragEnter(DragSessionEvent event);

  /// The pointer moved inside the window. Returning a different response than
  /// [onDragEnter] is how a window with several drop zones works.
  DropResponse onDragOver(DragSessionEvent event);

  /// The drag left without dropping, or was cancelled.
  ///
  /// Always arrives exactly once per accepted or refused enter, including when
  /// the drag ends because the source's application died - that is the whole
  /// reason it is a separate callback rather than a null-position `onDragOver`.
  void onDragLeave();

  /// The user dropped. The returned action is what was *actually performed*.
  ///
  /// Returning [DragAction.move] is what lets the source delete its original;
  /// returning [DragAction.none] after having accepted is legitimate and means
  /// "I tried and the transfer failed", which is different from having refused.
  ///
  /// **The future's value reaches the source on Wayland and XDND, and does not
  /// on Win32.** `IDropTarget::Drop` has to write `*pdwEffect` before it
  /// returns, so the Win32 backend reports the action the last [onDragOver]
  /// agreed to and awaits this future only to log a transfer that then failed.
  /// A handler that needs the source to know must therefore refuse *before* the
  /// drop rather than fail after it - which is the truthful order on all three
  /// platforms anyway.
  Future<DragAction> onDrop(DragSessionEvent event);
}

/// A live registration of a [DropTargetHandler] against one window.
///
/// Held by whoever registered it, and revoked before the window is destroyed.
/// On Win32 that ordering is not advisory: `RevokeDragDrop` after the `HWND` is
/// gone leaks the target object and the OLE runtime keeps a pointer into this
/// process's memory.
abstract interface class DropTargetRegistration {
  NativeWindowId get windowId;

  /// Whether the platform still routes drags to this handler.
  bool get isActive;

  /// Stops routing drags here. Idempotent: revoking twice is not an error,
  /// because a window teardown and an explicit revoke race by design.
  Future<void> revoke();
}

/// Everything one platform can do with drag and drop.
///
/// A **separate** interface from [WindowingBackend] for the reason
/// [ClipboardProvider] is separate: that contract is implemented by every
/// backend *and by every test double in the suite*, and adding a required
/// member to it would break each one for a capability most of them do not have.
/// A backend that has drag and drop declares [DragDropProvider]; the rest are
/// unchanged and the shell falls back to [UnavailableDragDrop].
abstract interface class DragDropBackend {
  /// Which implementation this is - `win32`, `xdnd`, `wayland`. Appears in
  /// every [DragDropException] this backend raises.
  String get name;

  /// Whether this backend can start a drag *from* this application.
  ///
  /// Separate from being able to receive one, because the two halves fail
  /// independently: XDND can receive without owning a selection, and a Wayland
  /// compositor with no `wl_data_device_manager` can do neither. The
  /// destination half is not a getter because there is no useful "yes" that is
  /// not just "registration succeeded".
  bool get canStartDrag;

  /// Routes drags over [window] to [handler].
  ///
  /// A future because two of the three registrations are: XDND has to set the
  /// `XdndAware` property and wait for the round trip, and Wayland has to have
  /// bound `wl_data_device_manager` from the registry first. Win32 completes it
  /// on the spot.
  ///
  /// Throws [DragDropException] when the window could not be registered - a
  /// second registration for one window, most often, which is
  /// `DRAGDROP_E_ALREADYREGISTERED` on Win32 and a silently ignored property
  /// change on X11 if nobody checks.
  Future<DropTargetRegistration> registerDropTarget({
    required NativeWindow window,
    required DropTargetHandler handler,
  });

  /// Drags [request]`.data` out of this application, completing with the action
  /// the destination performed - [DragAction.none] when the user cancelled or
  /// dropped on nothing, which is not an error.
  ///
  /// Must be called from inside a pointer gesture: Wayland requires the serial
  /// of the button press that began it and refuses otherwise, and Win32's
  /// `DoDragDrop` runs its own modal loop that only makes sense while a button
  /// is down.
  ///
  /// **`DoDragDrop` does not return until the drag is over**, so on Win32 this
  /// future completes only after the user has released the button, and the
  /// whole Dart isolate is parked inside it in the meantime - no frame is
  /// painted and no timer fires. That is the platform's design, not this
  /// port's; a drag source is a modal gesture on Windows.
  Future<DragAction> startDrag(DragRequest request);
}

/// A windowing backend that can hand out drag and drop.
///
/// Detected with a pattern, never with `is`, exactly as [ClipboardProvider] is:
///
/// ```dart
/// if (backend case final DragDropProvider provider) provider.dragAndDrop;
/// ```
abstract interface class DragDropProvider {
  /// Never null: a backend whose platform has no drag and drop returns an
  /// [UnavailableDragDrop] carrying the reason, so the failure keeps its
  /// explanation instead of collapsing into "nothing was configured".
  DragDropBackend get dragAndDrop;
}

/// What an application asks for when it starts a drag.
final class DragRequest {
  const DragRequest({
    required this.window,
    required this.data,
    this.allowedActions = const <DragAction>{DragAction.copy},
    this.preferredAction = DragAction.copy,
    this.feedback,
  });

  /// The window the gesture started in. Wayland needs its surface, Win32 needs
  /// nothing but records it, XDND needs a window to own `XdndSelection` with.
  final NativeWindow window;

  /// What is being dragged. A [MemoryDragData] is materialised already; a
  /// [LazyDragData] is only asked for a format a destination actually wants -
  /// except on Win32, where `IDataObject::GetData` is synchronous and the
  /// backend therefore resolves every format before entering `DoDragDrop`.
  final DragData data;

  /// What this source is willing to let happen. A destination that asks for
  /// anything outside this set is refused.
  final Set<DragAction> allowedActions;

  /// What should happen when the user expresses no preference.
  final DragAction preferredAction;

  /// The picture that follows the cursor, or null for the platform's default.
  ///
  /// Honoured where the platform has somewhere to put it - a `wl_surface` on
  /// Wayland - and ignored elsewhere rather than emulated: a drag image drawn
  /// into a layered window of our own would follow the cursor a frame late and
  /// through the *wrong* compositor path, which reads as a worse bug than no
  /// image at all.
  final DragFeedbackImage? feedback;
}

/// A picture to drag under the cursor.
///
/// Premultiplied BGRA, tightly packed, the same encoding the CPU presenters
/// take - so a caller can hand over a rasterised widget without a conversion.
final class DragFeedbackImage {
  const DragFeedbackImage({
    required this.width,
    required this.height,
    required this.pixels,
    this.hotspotX = 0,
    this.hotspotY = 0,
  });

  final int width;
  final int height;

  /// `width * height * 4` bytes of premultiplied BGRA.
  final List<int> pixels;

  /// Where the cursor sits inside the picture, in pixels.
  final int hotspotX;
  final int hotspotY;
}

/// The drag and drop of an application whose backend has none.
///
/// Exists so that "this platform cannot do it" is a named failure at the moment
/// of registration rather than a drop that never arrives, and so that callers
/// never have to hold a `DragDropBackend?`.
final class UnavailableDragDrop implements DragDropBackend {
  const UnavailableDragDrop({
    required this.name,
    required this.reason,
  });

  /// The backend that has no drag and drop, so the message names it.
  @override
  final String name;

  final String reason;

  @override
  bool get canStartDrag => false;

  // `async` rather than a bare `throw`, for [UnavailableClipboard]'s reason: a
  // caller that stored the future and awaited it later must still see the
  // error instead of taking it at the call site.
  @override
  Future<DropTargetRegistration> registerDropTarget({
    required NativeWindow window,
    required DropTargetHandler handler,
  }) async =>
      throw DragDropException(
        operation: 'registerDropTarget',
        reason: reason,
        backend: name,
      );

  @override
  Future<DragAction> startDrag(DragRequest request) async =>
      throw DragDropException(
        operation: 'startDrag',
        reason: reason,
        backend: name,
      );
}

/// A drag and drop backend that records what it was asked to do and plays back
/// whatever a test tells it to.
///
/// Lives beside the contract rather than in `test/` for `FakeClipboard`'s
/// reason: a widget test for a drop target needs one, an application harness
/// needs one, and a copy per test file is a copy per test file that drifts.
final class FakeDragDrop implements DragDropBackend {
  FakeDragDrop({this.canStartDrag = true});

  @override
  String get name => 'fake';

  @override
  final bool canStartDrag;

  /// What [startDrag] completes with, so a test can assert a move happened.
  DragAction dragResult = DragAction.copy;

  final List<DragRequest> requests = <DragRequest>[];
  final List<FakeDropTargetRegistration> registrations =
      <FakeDropTargetRegistration>[];

  /// The handler of the newest live registration, which is what a test drives.
  DropTargetHandler? get handler => registrations
      .where((FakeDropTargetRegistration registration) => registration.isActive)
      .map((FakeDropTargetRegistration registration) => registration.handler)
      .lastOrNull;

  @override
  Future<DropTargetRegistration> registerDropTarget({
    required NativeWindow window,
    required DropTargetHandler handler,
  }) async {
    final FakeDropTargetRegistration registration =
        FakeDropTargetRegistration(window.id, handler);
    registrations.add(registration);
    return registration;
  }

  @override
  Future<DragAction> startDrag(DragRequest request) async {
    requests.add(request);
    return dragResult;
  }
}

/// The registration [FakeDragDrop] hands out; a test revokes it to prove the
/// widget layer stops routing.
final class FakeDropTargetRegistration implements DropTargetRegistration {
  FakeDropTargetRegistration(this.windowId, this.handler);

  @override
  final NativeWindowId windowId;

  final DropTargetHandler handler;

  @override
  bool isActive = true;

  @override
  Future<void> revoke() async => isActive = false;
}
