/// XDND, the X11 half of `lib/src/platform/drag_drop.dart`.
///
/// ## Why this file is shaped like `wayland_drag_drop.dart`
///
/// The same split, for the same reason: [X11DragDropClient] is a pointer-free
/// seam over the four X requests the protocol needs, and [X11DragDropManager]
/// is a state machine that knows XDND and nothing about FFI. Everything below
/// is therefore testable on a machine with no X server, which is the only way
/// this code gets covered at all - the ordering rules are the whole difficulty
/// of XDND, and they are exactly the part an integration test cannot pin down.
///
/// [X11DragDropClient] is deliberately **not** an addition to
/// `X11WindowClient`. That interface is implemented by test doubles that have
/// no `noSuchMethod`, so a new member on it breaks every one of them for a
/// capability none of them has. `X11CpuClient` is kept separate for the same
/// reason and this follows it.
///
/// ## The protocol, as this destination implements it
///
/// XDND is not a wire extension: it is a convention over `ClientMessage` and
/// window properties, so all of it is in the core protocol this backend already
/// speaks. A destination window advertises itself by owning an `XdndAware`
/// property whose single 32-bit value is the highest protocol version it
/// understands; a source finds a target by walking the window tree under the
/// pointer looking for that property.
///
/// One drag then looks like this, with our answers on the right:
///
/// | source sends    | carries                                         | we answer      |
/// |-----------------|-------------------------------------------------|----------------|
/// | `XdndEnter`     | source window, version, up to 3 type atoms      | *nothing*      |
/// | `XdndPosition`  | root coordinates, timestamp, suggested action   | `XdndStatus`   |
/// | `XdndLeave`     | source window                                   | *nothing*      |
/// | `XdndDrop`      | source window, timestamp                        | `XdndFinished` |
///
/// and the payload itself is a **selection transfer**: on `XdndDrop` the
/// destination calls `ConvertSelection` on `XdndSelection` with the type it
/// accepted, and the bytes arrive later as a property named by a
/// `SelectionNotify` on our own event queue. That is why
/// [DragData.readBytes] is a future on every platform - see the port's library
/// comment.
///
/// ## The protocol, as this source implements it
///
/// The same table read from the other side, plus the two halves a destination
/// never has to write: *finding* the target, and *serving* the bytes.
///
/// | we send         | carries                                          | the target answers |
/// |-----------------|--------------------------------------------------|--------------------|
/// | `XdndEnter`     | our window, version, up to 3 type atoms          | *nothing*          |
/// | `XdndPosition`  | root coordinates, timestamp, the action we want  | `XdndStatus`       |
/// | `XdndLeave`     | our window                                       | *nothing*          |
/// | `XdndDrop`      | our window, timestamp                            | `XdndFinished`     |
///
///   * **Finding the target** is a `QueryPointer` walk down from the root on
///     every pointer motion, looking for `XdndAware`. It is the only part of
///     XDND that cannot be done without a server, which is why it sits behind
///     [X11DragDropClient.windowUnderPointer] rather than inline: the *choice*
///     of target - which window in the chain, which version, whether an
///     `XdndProxy` redirects it - stays in [X11DragDropManager] where a fake
///     client can drive it.
///   * **Serving the bytes** is ICCCM selection ownership. We take
///     `XdndSelection` with `SetSelectionOwner`, and the destination's
///     `ConvertSelection` reaches us as a `SelectionRequest`: we write the
///     bytes onto *its* window with `ChangeProperty` and then send it a
///     `SelectionNotify` saying where they are. A request for a target we do
///     not offer is answered with `property = None`, which is the specification's
///     refusal - skipping the answer entirely is what hangs the destination,
///     because it is sitting in its own event loop waiting for exactly that
///     event.
///
/// ### Where the source makes a choice the spec leaves open
///
///   * **Ownership is verified, not assumed.** `SetSelectionOwner` is a request
///     with no reply, so the only way to know it took is to ask
///     `GetSelectionOwner` back. A drag whose selection we do not own looks
///     completely normal to the user and delivers nothing at all, so a refused
///     ownership is a [DragDropException] rather than a drag that carries air.
///   * **`XdndFinished` is waited for with a deadline.** The specification's own
///     advice, and the alternative is a source future that never completes
///     because the destination crashed between `XdndDrop` and its answer. The
///     deadline reports [DragAction.none] - never the move the target may or may
///     not have performed - because [DragAction.move] is the answer that tells
///     our caller to delete the original.
///   * **The `XdndStatus` rectangle is honoured.** A target that answers with a
///     rectangle and a clear "send position always" bit is saying it will give
///     the same answer anywhere inside it, and every position we skip inside
///     that rectangle is a round trip removed from the pointer path.
///   * **An action the target names outside our offer is a refusal.** Same rule
///     as the destination half, in the other direction: substituting copy for
///     the move a target asked for loses the file, and substituting move for a
///     link deletes an original the user meant to keep.
///
/// ### Where this implementation makes a choice the spec leaves open
///
///   * **`XdndEnter` carries no position**, and
///     [DropTargetHandler.onDragEnter] needs one. So the enter callback is
///     delivered on the *first* `XdndPosition`, and every later position is an
///     `onDragOver`. The alternative - inventing a position for the enter -
///     would hit-test the drop against a point the pointer was never at.
///   * **Every `XdndPosition` is answered with an `XdndStatus`**, including the
///     refusals and including positions for a session we do not have. A source
///     that gets no status stops sending them and the drag appears to freeze
///     over our window, which the user reads as *our* application hanging.
///   * **The accept rectangle is one pixel** at the pointer, rather than the
///     empty rectangle that also means "always send". A destination whose
///     answer can change per pixel must be asked per pixel, and a non-empty
///     rectangle says so in a way every source implements identically.
///   * **A type the source never advertised is never accepted.** Accepting one
///     makes the `ConvertSelection` that follows go unanswered forever, which
///     hangs the drop rather than failing it.
///   * **`XdndFinished` is sent exactly once per drop**, including when the
///     drop was refused, when the handler threw and when the transfer timed
///     out. Until it arrives the source may not complete a move, so a missing
///     `XdndFinished` is how a drag-and-drop *deletes the user's file without
///     delivering it*.
///
/// ### What is not implemented, named rather than shrugged at
///
///   * **`INCR` transfers.** A payload larger than the server's maximum request
///     size arrives as a property of type `INCR` holding a byte count, followed
///     by one `PropertyNotify` per chunk. This destination detects the `INCR`
///     type and reports the transfer as failed instead of handing the handler
///     the four bytes of the size header as if they were the data.
///   * **The pointer grab.** [X11XdndSource] is driven by the motion the
///     backend already delivers, not by a grab of its own. Without
///     `XGrabPointer` the drag follows the pointer only while it is over a
///     window of this application *or* while the window manager keeps
///     delivering motion, which is true for the ordinary case and not for a
///     drag that crosses another client's window. The seam for it is
///     [X11XdndSource.moveTo]: whoever grabs simply calls it more often.
///   * **The drag icon.** `DragRequest.feedback` is ignored; an X11 drag image
///     is an override-redirect window the source paints and moves itself,
///     which is a second presentation path this backend does not have.
///   * **Modifier state.** XDND reports no modifiers, so
///     [DragSessionEvent.modifiers] is always empty here and a handler that
///     wants Ctrl-copies/Shift-moves has to read the keyboard itself. The
///     source has already applied the convention when it picks the action it
///     suggests in `XdndPosition`.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../platform/drag_drop.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import 'x11_protocol.dart';

// ---------------------------------------------------------------------------
// Atom names
// ---------------------------------------------------------------------------

/// Every atom XDND needs, interned in the connection's one startup batch.
///
/// Spread into `x11WellKnownAtoms` rather than interned lazily because a drag
/// is a live gesture: an `InternAtom` round trip on the first `XdndPosition`
/// would land in the middle of the pointer path, and section 15.4's rule about
/// round trips in the input path is exactly about this.
///
/// `UTF8_STRING` is not repeated here - the connection already interns it for
/// `_NET_WM_NAME`.
const List<String> x11XdndAtoms = <String>[
  'XdndAware',
  'XdndEnter',
  'XdndPosition',
  'XdndStatus',
  'XdndLeave',
  'XdndDrop',
  'XdndFinished',
  'XdndSelection',
  'XdndTypeList',
  'XdndActionList',
  'XdndActionCopy',
  'XdndActionMove',
  'XdndActionLink',
  'XdndActionAsk',
  'XdndActionPrivate',
  'XdndProxy',
  'INCR',
  'TARGETS',
  'text/uri-list',
  'text/plain',
  'text/plain;charset=utf-8',
  xdndDropProperty,
];

/// The property on **our** window that a dropped selection is converted into.
///
/// Private to this framework rather than one of the XDND atoms: the property is
/// the destination's own scratch space, and naming it after ourselves means two
/// toolkits inside one process cannot collide on it.
const String xdndDropProperty = '_DART_UI_XDND_DROP';

// ---------------------------------------------------------------------------
// The seam
// ---------------------------------------------------------------------------

/// One property value, with the type the owner actually gave it.
///
/// The type is not decoration. A `GetProperty` that names the expected type and
/// gets a different one succeeds with an **empty** value, so a transfer that
/// arrived as `INCR` would look exactly like a source that sent nothing. Asking
/// for [xcbGetPropertyTypeAny] and comparing the type here is what turns that
/// into a named failure.
final class X11PropertyValue {
  const X11PropertyValue({
    required this.type,
    required this.format,
    required this.bytes,
  });

  /// The property's type atom.
  final int type;

  /// 8, 16 or 32 - the unit the server stored the value in.
  final int format;

  /// A copy of the value. A copy because the reply it came from is freed
  /// before this returns, and a view into freed memory is a crash that shows
  /// up as corrupt drop data three frames later.
  final Uint8List bytes;
}

/// The X requests [X11DragDropManager] needs from a connection.
///
/// No pointer crosses this seam: only `int`, `String`, `Uint8List` and
/// [Offset]. That is what makes the state machine testable on Windows, and it
/// is the same contract `X11CpuClient` keeps.
abstract interface class X11DragDropClient {
  /// An atom from the connection's interned cache. Zero when it is not there,
  /// which makes every comparison against it false rather than accidentally
  /// true.
  int atom(String name);

  /// The name of an interned atom, or null when the server does not know it.
  ///
  /// Needed because XDND names types by atom and this framework's contract
  /// names them by MIME string: a source advertising `application/x-my-thing`
  /// has to reach the handler under that name, and only the server can spell it
  /// back. Implementations cache, because the same handful of atoms recurs for
  /// every drag on the desktop.
  String? atomName(int atom);

  /// `ChangeProperty` with format 32, mode Replace.
  void setWindowProperty32(
    int window,
    int property,
    int type,
    List<int> values,
  );

  /// `DeleteProperty`.
  void deleteWindowProperty(int window, int property);

  /// `SendEvent` of a 32-byte `ClientMessage` with format 32 and five words.
  ///
  /// [destination] is who receives it; [window] is the event's own `window`
  /// field, which XDND sets to the recipient for every message a destination
  /// sends. They are separate parameters because they are separate fields, and
  /// collapsing them would make the source half - where they differ - unable to
  /// use this.
  ///
  /// Sent with propagate false and an empty event mask, which is what delivers
  /// the event to the destination window itself rather than to whichever of its
  /// ancestors happens to have selected for something.
  void sendClientMessage({
    required int destination,
    required int window,
    required int type,
    required List<int> data,
  });

  /// `ConvertSelection`. The answer arrives later as a `SelectionNotify`.
  void convertSelection({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  });

  /// `GetProperty`, optionally deleting the property as it is read.
  ///
  /// Deleting is not tidiness: it is how the *source* learns the transfer was
  /// taken, and it is required to advance an `INCR` transfer. Pass
  /// [xcbGetPropertyTypeAny] for [type] to read the value whatever type it has.
  X11PropertyValue? readPropertyBytes(
    int window,
    int property, {
    required int type,
    bool delete = false,
  });

  /// The 32-bit words of a property - `XdndTypeList`, `XdndActionList`.
  /// Empty when the property is absent, of another format, or unreadable.
  List<int> readPropertyCardinals(
    int window,
    int property, {
    required int type,
  });

  /// `GetSelectionOwner`, or [xcbNone] when nobody owns it.
  int getSelectionOwner(int selection);

  /// `SetSelectionOwner`, which the source half needs to own `XdndSelection`.
  void setSelectionOwner(int owner, int selection, int time);

  /// `ChangeProperty` with format 8, mode Replace - how a selection owner
  /// hands over the bytes a `SelectionRequest` asked for.
  void setWindowPropertyBytes(
    int window,
    int property,
    int type,
    Uint8List bytes,
  );

  /// `SendEvent` of a `SelectionNotify`, which answers a `SelectionRequest`.
  ///
  /// [property] is [xcbNone] to refuse, and refusing *out loud* is required:
  /// the requestor is blocked on its own event queue waiting for this.
  void sendSelectionNotify({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  });

  /// `QueryPointer` on [window], or null when the pointer is on another
  /// screen or the request failed.
  ///
  /// The source half's only way to ask what is under the cursor: X answers one
  /// level at a time, so finding a drop target is a descent. See
  /// [X11XdndSource].
  X11PointerLocation? queryPointer(int window);

  /// Pushes the queued requests to the server. A drag is a live gesture: a
  /// status that sits in the output buffer is a status the source never sees.
  int flush();

  /// Records a protocol failure on the connection's bounded error ring.
  void recordError(String message);
}

/// Root-window device pixels to logical units inside a window's client area.
///
/// Injected rather than reached for, because `XdndPosition` is the one place in
/// this backend where a *root* coordinate in *physical* pixels has to become
/// the same logical client-area offset a `PointerEvent` carries, and the object
/// that knows both the window origin and the scale is `X11Window` - which this
/// file must not depend on if the state machine is to stay testable.
typedef X11RootToClient = Offset Function(int xcbWindow, int rootX, int rootY);

/// Device pixels per logical unit for one window, for [DragSessionEvent
/// .screenPosition].
typedef X11WindowScaleLookup = double Function(int xcbWindow);

// ---------------------------------------------------------------------------
// The destination state machine
// ---------------------------------------------------------------------------

/// XDND as a destination: one instance per connection.
///
/// A state machine rather than a set of callbacks because the ordering rules
/// are real and asymmetric - a status for every position, a type that was
/// advertised, one `XdndFinished` per drop, a transfer that outlives a leave.
/// Getting any of them wrong hangs the *other* application, which is the
/// failure mode that makes drag and drop notoriously flaky.
final class X11DragDropManager {
  X11DragDropManager(
    this._client, {
    required X11RootToClient rootToClient,
    X11WindowScaleLookup? scaleOf,
    Duration transferTimeout = const Duration(seconds: 10),
  })  : _rootToClient = rootToClient,
        _scaleOf = scaleOf ?? _unitScale,
        _transferTimeout = transferTimeout;

  static double _unitScale(int xcbWindow) => 1;

  final X11DragDropClient _client;
  final X11RootToClient _rootToClient;
  final X11WindowScaleLookup _scaleOf;

  /// How long a `ConvertSelection` may go unanswered before the drop is
  /// reported as failed.
  ///
  /// A source is entitled to exit while the user is dragging out of it, and
  /// when it does the `SelectionNotify` simply never arrives. Without this the
  /// handler's `onDrop` future never completes, so `XdndFinished` is never
  /// sent - and the machine is stuck in a session that no later drag can
  /// replace.
  final Duration _transferTimeout;

  /// The one handler drops are routed to. Shared across every registered
  /// window, exactly as the Wayland manager's is; the window a drag is over is
  /// named by [DragSessionEvent.windowId].
  DropTargetHandler? handler;

  /// Framework ids of the windows advertising `XdndAware`.
  final Map<int, NativeWindowId> _windows = <int, NativeWindowId>{};

  // --- the live session ----------------------------------------------------

  /// Bumped on every enter so that a callback belonging to a finished drag can
  /// be recognised and dropped instead of mutating the current one.
  int _sessionId = 0;

  int _sourceWindow = 0;
  int _targetWindow = 0;
  NativeWindowId _targetWindowId = const NativeWindowId(0);
  int _sourceVersion = 0;
  List<String> _formats = const <String>[];
  Set<DragAction> _sourceActions = const <DragAction>{};
  Set<DragAction> _allowedActions = const <DragAction>{};
  DragData? _data;

  String? _acceptedFormat;
  DragAction _acceptedAction = DragAction.none;

  /// Whether [DropTargetHandler.onDragEnter] has been delivered, and therefore
  /// whether an `onDragLeave` is still owed. Cleared by the drop, which is the
  /// other way a session ends.
  bool _enterDelivered = false;

  /// True from `XdndDrop` until `XdndFinished`. The session's state must
  /// survive a leave arriving in that window, because the pending transfer is
  /// keyed by it.
  bool _dropInFlight = false;
  bool _finishedSent = false;
  int _dropTimestamp = 0;
  int _positionTimestamp = 0;
  int _lastRootX = 0;
  int _lastRootY = 0;

  _X11SelectionTransfer? _transfer;

  /// The source window of the live drag, or 0.
  int get sourceWindow => _sourceWindow;

  /// Our window the drag is over, or 0.
  int get targetWindow => _targetWindow;

  /// The version this destination and the source settled on, or 0.
  int get negotiatedVersion => _sourceVersion;

  /// Every type the source advertised, in the order it offered them.
  List<String> get offeredFormats => _formats;

  /// The type the last [DropResponse] accepted, or null when the drag is
  /// currently refused.
  String? get acceptedFormat => _acceptedFormat;

  /// The action the last [DropResponse] agreed to.
  DragAction get acceptedAction => _acceptedAction;

  bool get hasActiveSession => _sourceWindow != 0;

  /// Whether a `ConvertSelection` is still waiting for its `SelectionNotify`.
  bool get isTransferPending => _transfer != null;

  bool isRegistered(int xcbWindow) => _windows.containsKey(xcbWindow);

  // -------------------------------------------------------------------------
  // Registration
  // -------------------------------------------------------------------------

  /// Advertises [xcbWindow] as an XDND destination.
  ///
  /// The property is the whole registration: a source finds targets by reading
  /// `XdndAware` off the windows under the pointer, so a window without it is
  /// invisible to every drag on the desktop and one with it is visible to all
  /// of them the moment the request reaches the server - hence the [flush].
  void registerWindow(int xcbWindow, NativeWindowId windowId) {
    final int aware = _client.atom('XdndAware');
    if (aware == 0) {
      throw const DragDropException(
        operation: 'registerDropTarget',
        reason: 'the XdndAware atom could not be interned, so no source can '
            'discover this window',
        backend: 'xdnd',
      );
    }
    _windows[xcbWindow] = windowId;
    _client.setWindowProperty32(
      xcbWindow,
      aware,
      xcbAtomAtom,
      const <int>[xdndVersion],
    );
    _client.flush();
  }

  /// Withdraws [xcbWindow]. Idempotent: a teardown and an explicit revoke race
  /// by design, and the property is gone with the window in the common case.
  void unregisterWindow(int xcbWindow) {
    if (_windows.remove(xcbWindow) == null) return;
    final int aware = _client.atom('XdndAware');
    if (aware != 0) _client.deleteWindowProperty(xcbWindow, aware);
    _client.flush();
    if (_targetWindow == xcbWindow) {
      _forceFinishDrop('the drop target was revoked mid-drop');
      _abortTransfer('the drop target was revoked mid-transfer');
      _endSession(deliverLeave: true);
      _clearSession();
    }
  }

  // -------------------------------------------------------------------------
  // Incoming ClientMessages
  // -------------------------------------------------------------------------

  /// Offers one `ClientMessage` to the protocol. Returns whether it was XDND
  /// addressed to a window this manager owns, and therefore consumed.
  ///
  /// The five words are passed as five `int`s rather than as a list because
  /// `XdndPosition` arrives at pointer rate and section 6.5 forbids an
  /// allocation per platform event.
  bool handleClientMessage({
    required int window,
    required int messageType,
    required int format,
    required int data0,
    required int data1,
    required int data2,
    required int data3,
    required int data4,
  }) {
    if (format != xdndClientMessageFormat || messageType == 0) return false;
    if (!_windows.containsKey(window)) return false;
    if (messageType == _client.atom('XdndEnter')) {
      _onEnter(window, data0, data1, data2, data3, data4);
      return true;
    }
    if (messageType == _client.atom('XdndPosition')) {
      _onPosition(window, data0, data2, data3, data4);
      return true;
    }
    if (messageType == _client.atom('XdndLeave')) {
      _onLeave(window, data0);
      return true;
    }
    if (messageType == _client.atom('XdndDrop')) {
      _onDrop(window, data0, data2);
      return true;
    }
    return false;
  }

  void _onEnter(
    int window,
    int data0,
    int data1,
    int data2,
    int data3,
    int data4,
  ) {
    // Whatever came before is over: a source that sends `XdndEnter` has already
    // stopped talking about the previous drag, and a transfer still pending
    // from it can never be answered.
    _forceFinishDrop('a new drag entered before the previous drop finished');
    _abortTransfer('a new drag started before the previous transfer answered');
    _endSession(deliverLeave: true);
    _clearSession();

    final int version = (data1 >> xdndEnterVersionShift) & 0xff;
    if (version < xdndMinimumVersion) {
      // Not answered and not tracked: version 2 and below pack `XdndEnter`
      // differently, so the type atoms below would be read out of the wrong
      // words. A later `XdndPosition` still gets its refusing status.
      _client.recordError(
        'XdndEnter from window 0x${data0.toRadixString(16)} announced '
        'protocol version $version; this destination speaks '
        '$xdndMinimumVersion and up',
      );
      return;
    }

    final List<String> formats = (data1 & xdndEnterMoreTypesBit) != 0
        ? _readTypeList(data0)
        : _inlineFormats(<int>[data2, data3, data4]);
    if (formats.isEmpty) {
      _client.recordError(
        'XdndEnter from window 0x${data0.toRadixString(16)} advertised no '
        'type this connection could name',
      );
      return;
    }

    _sessionId++;
    _sourceWindow = data0;
    _targetWindow = window;
    _targetWindowId = _windows[window]!;
    // We speak the lower of the two versions; a version 3 source must not be
    // sent a version 5 `XdndFinished` payload it will read as garbage.
    _sourceVersion = version < xdndVersion ? version : xdndVersion;
    _formats = List<String>.unmodifiable(formats);
    _sourceActions = _readActionList(data0);
    _allowedActions = _sourceActions;
    final int session = _sessionId;
    _data = LazyDragData(
      _formats,
      (String format) => _readFormat(session, format),
    );
  }

  /// The three type atoms `XdndEnter` carries inline, named.
  List<String> _inlineFormats(List<int> atoms) {
    final List<String> formats = <String>[];
    for (var index = 0; index < xdndEnterInlineTypeCount; index++) {
      final int value = atoms[index];
      if (value == xcbNone) continue;
      final String? name = _client.atomName(value);
      if (name != null && name.isNotEmpty) formats.add(name);
    }
    return formats;
  }

  /// The full list from the `XdndTypeList` property on the source window, set
  /// when the source has more than three types to offer.
  List<String> _readTypeList(int sourceWindow) {
    final int property = _client.atom('XdndTypeList');
    if (property == 0) return const <String>[];
    final List<int> atoms = _client.readPropertyCardinals(
      sourceWindow,
      property,
      type: xcbAtomAtom,
    );
    final List<String> formats = <String>[];
    for (final int value in atoms) {
      if (value == xcbNone) continue;
      final String? name = _client.atomName(value);
      if (name != null && name.isNotEmpty) formats.add(name);
    }
    return formats;
  }

  /// What the source is prepared to do, from `XdndActionList`.
  ///
  /// Optional in the protocol and absent from most sources, which is why an
  /// empty answer is not a refusal: it means "ask me one action at a time
  /// through `XdndPosition`", and the position's own action then stands in for
  /// the whole set.
  Set<DragAction> _readActionList(int sourceWindow) {
    final int property = _client.atom('XdndActionList');
    if (property == 0) return const <DragAction>{};
    final List<int> atoms = _client.readPropertyCardinals(
      sourceWindow,
      property,
      type: xcbAtomAtom,
    );
    if (atoms.isEmpty) return const <DragAction>{};
    final Set<DragAction> actions = <DragAction>{};
    for (final int value in atoms) {
      final DragAction action = _actionFromAtom(value);
      if (action != DragAction.none) actions.add(action);
    }
    return Set<DragAction>.unmodifiable(actions);
  }

  void _onPosition(int window, int data0, int data2, int data3, int data4) {
    // Root coordinates are packed into one word, x in the high half. Both
    // halves are unsigned: the root window's origin is 0,0 and nothing on the
    // desktop is to the left of it.
    final int rootX = (data2 >> 16) & 0xffff;
    final int rootY = data2 & 0xffff;
    if (!_isLiveSession(window, data0)) {
      // Answer anyway. A source that gets no status for a position stops
      // sending them, and the drag freezes over our window - which the user
      // reads as this application hanging, not as a refusal.
      _sendStatus(
        source: data0,
        accepted: false,
        action: DragAction.none,
        rootX: rootX,
        rootY: rootY,
      );
      return;
    }
    _positionTimestamp = data3;
    _lastRootX = rootX;
    _lastRootY = rootY;

    final DragAction suggested = _actionFromAtom(data4);
    // With no `XdndActionList` the only thing the source has told us it can do
    // is the action it is suggesting right now.
    _allowedActions = _sourceActions.isNotEmpty
        ? _sourceActions
        : <DragAction>{if (suggested != DragAction.none) suggested};

    final DropTargetHandler? target = handler;
    final DragSessionEvent event = _buildEvent(rootX, rootY, suggested);
    final DropResponse response = target == null
        ? const DropResponse.reject()
        : _enterDelivered
            ? target.onDragOver(event)
            : target.onDragEnter(event);
    if (target != null) _enterDelivered = true;
    _applyResponse(response, rootX, rootY);
  }

  /// Settles the accepted type and action and answers with `XdndStatus`.
  void _applyResponse(DropResponse response, int rootX, int rootY) {
    final String? format = response.acceptedFormat;
    // Accepting a type the source never advertised makes the
    // `ConvertSelection` that follows the drop go unanswered forever.
    final bool known = format != null && _formats.contains(format);
    DragAction action = known ? response.action : DragAction.none;
    // An action outside what the source offered is a refusal, never a silent
    // substitution: swapping copy in for a requested move loses the file, and
    // swapping move in for a link deletes an original the user meant to keep.
    if (action != DragAction.none &&
        _allowedActions.isNotEmpty &&
        !_allowedActions.contains(action)) {
      action = DragAction.none;
    }
    final int actionAtom = _atomForAction(action);
    final bool accepted =
        known && action != DragAction.none && actionAtom != xcbNone;
    _acceptedFormat = accepted ? format : null;
    _acceptedAction = accepted ? action : DragAction.none;
    _sendStatus(
      source: _sourceWindow,
      accepted: accepted,
      action: _acceptedAction,
      rootX: rootX,
      rootY: rootY,
    );
  }

  void _sendStatus({
    required int source,
    required bool accepted,
    required DragAction action,
    required int rootX,
    required int rootY,
  }) {
    final int type = _client.atom('XdndStatus');
    if (type == 0 || source == xcbNone) return;
    _client.sendClientMessage(
      destination: source,
      window: source,
      type: type,
      data: <int>[
        _targetWindow,
        accepted ? xdndStatusAcceptBit : 0,
        // A one-pixel rectangle at the pointer. Not the empty rectangle that
        // also means "always send": a non-empty one is interpreted the same way
        // by every source, and this destination's answer really can change
        // between two adjacent pixels.
        ((rootX & 0xffff) << 16) | (rootY & 0xffff),
        (1 << 16) | 1,
        accepted ? _atomForAction(action) : xcbNone,
      ],
    );
    _client.flush();
  }

  void _onLeave(int window, int source) {
    if (!_isLiveSession(window, source)) return;
    _endSession(deliverLeave: true);
    // The session itself survives while a transfer is still reading out of it;
    // a leave arriving mid-transfer must not pull the property, the timestamp
    // and the session id out from under the pending `SelectionNotify`.
    if (!_dropInFlight) _clearSession();
  }

  void _onDrop(int window, int source, int timestamp) {
    if (!_isLiveSession(window, source)) {
      // Still finish it. A source waiting for `XdndFinished` that never comes
      // cannot complete - or abandon - a move.
      _sendFinished(source: source, accepted: false, action: DragAction.none);
      return;
    }
    final String? format = _acceptedFormat;
    if (format == null) {
      _sendFinished(
        source: source,
        accepted: false,
        action: DragAction.none,
      );
      _endSession(deliverLeave: true);
      _clearSession();
      return;
    }

    // `XdndDrop` carries the timestamp of the button release, and
    // `ConvertSelection` must use it rather than CurrentTime: the server
    // resolves the selection owner as of that moment, which is what stops a
    // late conversion from reading whatever owns the selection now.
    _dropTimestamp = timestamp == xcbCurrentTime ? _positionTimestamp : timestamp;
    _dropInFlight = true;
    _finishedSent = false;
    // The drop answers the enter; no `onDragLeave` is owed for a session that
    // ended in a drop.
    _enterDelivered = false;

    final int session = _sessionId;
    final DropTargetHandler? target = handler;
    if (target == null) {
      _completeDrop(session, DragAction.none);
      return;
    }
    final DragSessionEvent event =
        _buildEvent(_lastRootX, _lastRootY, _acceptedAction);
    Future<DragAction> performed;
    try {
      performed = target.onDrop(event);
    } on Object catch (error) {
      _client.recordError('XDND drop handler threw synchronously: $error');
      _completeDrop(session, DragAction.none);
      return;
    }
    unawaited(performed.then<void>(
      (DragAction action) => _completeDrop(session, action),
      onError: (Object error) {
        _client.recordError('XDND drop handler failed: $error');
        _completeDrop(session, DragAction.none);
      },
    ));
  }

  /// Sends `XdndFinished` and closes the session, exactly once.
  void _completeDrop(int session, DragAction action) {
    if (session != _sessionId) return;
    // The handler is done, so nothing will ever read the bytes still in
    // flight; releasing the transfer here is what stops a source that went
    // away from holding the machine open until the timeout.
    _abortTransfer('the drop handler finished before the transfer answered');
    final bool accepted =
        action != DragAction.none && _atomForAction(action) != xcbNone;
    _sendFinished(
      source: _sourceWindow,
      accepted: accepted,
      action: accepted ? action : DragAction.none,
    );
    _dropInFlight = false;
    _clearSession();
  }

  /// Ends a drop whose handler will never answer, without leaving the source
  /// waiting for an `XdndFinished` that this machine has stopped tracking.
  ///
  /// The alternative - letting the session id make the late `_completeDrop` a
  /// no-op - is how a source ends up holding a half-completed move forever.
  void _forceFinishDrop(String reason) {
    if (!_dropInFlight) return;
    _client.recordError('XDND drop abandoned: $reason');
    _abortTransfer(reason);
    _sendFinished(
      source: _sourceWindow,
      accepted: false,
      action: DragAction.none,
    );
    _dropInFlight = false;
  }

  void _sendFinished({
    required int source,
    required bool accepted,
    required DragAction action,
  }) {
    if (_finishedSent) return;
    _finishedSent = true;
    final int type = _client.atom('XdndFinished');
    if (type == 0 || source == xcbNone) return;
    _client.sendClientMessage(
      destination: source,
      window: source,
      type: type,
      data: <int>[
        _targetWindow,
        // Words 1 and 2 exist only in version 5. A version 3 or 4 source reads
        // just word 0 and infers success, which is precisely why a *move* to
        // such a source must never be reported as performed when it was not -
        // there is no word left to say so in.
        accepted ? xdndFinishedAcceptedBit : 0,
        accepted ? _atomForAction(action) : xcbNone,
        0,
        0,
      ],
    );
    _client.flush();
  }

  // -------------------------------------------------------------------------
  // The selection transfer
  // -------------------------------------------------------------------------

  /// Answers a `SelectionNotify`. Returns whether it belonged to this manager.
  ///
  /// Not routed by window like every other event: a selection reply is about a
  /// *transfer*, and the pair that identifies one is (requestor, property).
  bool handleSelectionNotify({
    required int requestor,
    required int selection,
    required int target,
    required int property,
  }) {
    final _X11SelectionTransfer? transfer = _transfer;
    if (transfer == null) return false;
    if (transfer.requestor != requestor || transfer.target != target) {
      return false;
    }
    final int expected = _client.atom('XdndSelection');
    if (expected != 0 && selection != expected) return false;

    if (property == xcbNone) {
      // The owner refused the conversion - it cannot produce that type after
      // all, or it has already gone away. Routine, not exceptional.
      _settleTransfer(
        transfer,
        null,
        'the source refused to convert ${transfer.format}',
      );
      return true;
    }
    if (property != transfer.property) return false;

    final X11PropertyValue? value = _client.readPropertyBytes(
      requestor,
      property,
      // Any type, not the target atom: naming a type the owner did not use
      // succeeds with an empty value, so a mismatch would be indistinguishable
      // from an empty payload.
      type: xcbGetPropertyTypeAny,
      // Deleting is how the source learns the data was taken.
      delete: true,
    );
    if (value == null) {
      _settleTransfer(
        transfer,
        null,
        'the ${transfer.format} property could not be read back',
      );
      return true;
    }
    final int incr = _client.atom('INCR');
    if (incr != 0 && value.type == incr) {
      // Handing back the four bytes of the size header as if they were the
      // payload is worse than failing: the handler would write a corrupt file.
      _settleTransfer(
        transfer,
        null,
        'the ${transfer.format} payload arrived as an INCR transfer, which '
        'this destination does not implement',
      );
      return true;
    }
    _settleTransfer(transfer, value.bytes, null);
    return true;
  }

  /// [DragData.readBytes] for one format of one session.
  Future<Uint8List?> _readFormat(int session, String format) {
    if (session != _sessionId || !_dropInFlight) {
      // XDND converts the selection only after `XdndDrop`, with the drop's own
      // timestamp; there is nothing to read before that and nothing left to
      // read after the session ended.
      return Future<Uint8List?>.value();
    }
    final int target = _client.atom(format);
    if (target == 0) return Future<Uint8List?>.value();
    final _X11SelectionTransfer? active = _transfer;
    if (active == null) return _convert(session, format, target);
    // One property, one transfer at a time: a second `ConvertSelection` into
    // the same property would race the first one's reply and both would read
    // the wrong bytes.
    return active.completer.future
        .then<Uint8List?>((Uint8List? _) => _readFormat(session, format));
  }

  Future<Uint8List?> _convert(int session, String format, int target) {
    final int property = _client.atom(xdndDropProperty);
    final int selection = _client.atom('XdndSelection');
    if (property == 0 || selection == 0) return Future<Uint8List?>.value();
    final int requestor = _targetWindow;
    final _X11SelectionTransfer transfer = _X11SelectionTransfer(
      session: session,
      requestor: requestor,
      property: property,
      target: target,
      format: format,
    );
    _transfer = transfer;
    // A value left over from a transfer that timed out would otherwise be read
    // as this one's answer.
    _client.deleteWindowProperty(requestor, property);
    _client.convertSelection(
      requestor: requestor,
      selection: selection,
      target: target,
      property: property,
      time: _dropTimestamp,
    );
    _client.flush();
    transfer.timer = Timer(
      _transferTimeout,
      () => _settleTransfer(
        transfer,
        null,
        'the source never answered the $format conversion within '
        '${_transferTimeout.inMilliseconds}ms',
      ),
    );
    return transfer.completer.future;
  }

  void _settleTransfer(
    _X11SelectionTransfer transfer,
    Uint8List? bytes,
    String? failure,
  ) {
    transfer.timer?.cancel();
    transfer.timer = null;
    if (identical(_transfer, transfer)) _transfer = null;
    if (failure != null) _client.recordError('XDND transfer failed: $failure');
    if (!transfer.completer.isCompleted) transfer.completer.complete(bytes);
  }

  /// Releases a transfer nobody will answer. The explicit path out of a wedged
  /// state, and what a teardown uses.
  void abortPendingTransfer([String reason = 'the transfer was abandoned']) =>
      _abortTransfer(reason);

  void _abortTransfer(String reason) {
    final _X11SelectionTransfer? transfer = _transfer;
    if (transfer == null) return;
    _settleTransfer(transfer, null, reason);
  }

  // -------------------------------------------------------------------------
  // Session bookkeeping
  // -------------------------------------------------------------------------

  bool _isLiveSession(int window, int source) =>
      _sourceWindow != 0 && _sourceWindow == source && _targetWindow == window;

  DragSessionEvent _buildEvent(int rootX, int rootY, DragAction suggested) {
    final double scale = _scaleOf(_targetWindow);
    final double safeScale = scale.isFinite && scale > 0 ? scale : 1.0;
    return DragSessionEvent(
      windowId: _targetWindowId,
      position: _rootToClient(_targetWindow, rootX, rootY),
      screenPosition: Offset(rootX / safeScale, rootY / safeScale),
      data: _data ?? MemoryDragData(const <String, Uint8List>{}),
      allowedActions: _allowedActions,
      suggestedAction:
          suggested == DragAction.none ? DragAction.copy : suggested,
    );
  }

  /// Delivers the `onDragLeave` a delivered enter still owes, if any.
  void _endSession({required bool deliverLeave}) {
    if (!_enterDelivered) return;
    _enterDelivered = false;
    if (deliverLeave) handler?.onDragLeave();
  }

  void _clearSession() {
    if (_dropInFlight) return;
    // Bumping the id here rather than only on enter is what makes a callback
    // that belongs to a finished drag - a drop handler resuming after a
    // teardown, most often - recognisable as stale instead of mutating a
    // session it has nothing to do with.
    _sessionId++;
    _sourceWindow = 0;
    _targetWindow = 0;
    _targetWindowId = const NativeWindowId(0);
    _sourceVersion = 0;
    _formats = const <String>[];
    _sourceActions = const <DragAction>{};
    _allowedActions = const <DragAction>{};
    _data = null;
    _acceptedFormat = null;
    _acceptedAction = DragAction.none;
    _finishedSent = false;
    _dropTimestamp = 0;
    _positionTimestamp = 0;
    _lastRootX = 0;
    _lastRootY = 0;
  }

  /// Drops every piece of state, for a connection going away.
  void dispose() {
    _forceFinishDrop('the X11 connection was closed mid-drop');
    _abortTransfer('the X11 connection was closed mid-transfer');
    _endSession(deliverLeave: true);
    _dropInFlight = false;
    _clearSession();
    _windows.clear();
    handler = null;
  }

  DragAction _actionFromAtom(int value) {
    if (value == xcbNone) return DragAction.none;
    if (value == _client.atom('XdndActionCopy')) return DragAction.copy;
    if (value == _client.atom('XdndActionMove')) return DragAction.move;
    if (value == _client.atom('XdndActionLink')) return DragAction.link;
    if (value == _client.atom('XdndActionAsk')) return DragAction.ask;
    // The specification's own advice for `XdndActionPrivate` and for any action
    // a destination does not recognise: treat it as a copy. Copy is the choice
    // that cannot lose data if the guess was wrong.
    return DragAction.copy;
  }

  int _atomForAction(DragAction action) => switch (action) {
        DragAction.none => xcbNone,
        DragAction.copy => _client.atom('XdndActionCopy'),
        DragAction.move => _client.atom('XdndActionMove'),
        DragAction.link => _client.atom('XdndActionLink'),
        DragAction.ask => _client.atom('XdndActionAsk'),
      };
}

/// One `ConvertSelection` waiting for its `SelectionNotify`.
final class _X11SelectionTransfer {
  _X11SelectionTransfer({
    required this.session,
    required this.requestor,
    required this.property,
    required this.target,
    required this.format,
  });

  final int session;
  final int requestor;
  final int property;
  final int target;
  final String format;

  final Completer<Uint8List?> completer = Completer<Uint8List?>();

  /// Fires when the source never answers. Cancelled on every other exit, so a
  /// finished transfer cannot keep the isolate's event loop alive.
  Timer? timer;
}

// ---------------------------------------------------------------------------
// The source state machine
// ---------------------------------------------------------------------------

/// Where the pointer is and what is under it, as `QueryPointer` answers.
final class X11PointerLocation {
  const X11PointerLocation({
    required this.child,
    required this.rootX,
    required this.rootY,
  });

  /// The window one level down that contains the pointer, or [xcbNone] when
  /// this window has no child there - which is what ends the descent.
  final int child;

  final int rootX;
  final int rootY;
}

/// What a drag this client started carries, already serialised.
///
/// A map rather than a [DragData] because the source half runs *inside the
/// event pump*: a `SelectionRequest` has to be answered with bytes before the
/// handler returns, and there is no turn of the Dart event loop between the
/// request arriving and the answer being owed. Materialising up front is the
/// same rule `win32_drag_source.dart` follows and for the same reason.
typedef X11DragPayload = Map<String, Uint8List>;

/// XDND as a **source**: this application dragging something out.
///
/// ## Why this is a separate class from [X11DragDropManager]
///
/// The two halves share a connection and nothing else. A destination is
/// *called*: it reacts to messages another client sends and answers each one.
/// A source *drives*: it walks the window tree on every pointer motion, decides
/// who the target is, and owns a selection it must keep serving until the
/// transfer finishes. Merging them would put two independent state machines
/// behind one set of fields, and the failure that produces - a leave from the
/// destination session clearing the source session's target - is exactly the
/// kind of bug that makes drag and drop flaky in the first place.
///
/// ## The protocol, from this side
///
/// | we send        | carries                                          | we expect       |
/// |----------------|--------------------------------------------------|-----------------|
/// | *(ownership)*  | `SetSelectionOwner(XdndSelection)`               | -               |
/// | `XdndEnter`    | our window, version, up to 3 type atoms          | -               |
/// | `XdndPosition` | root coordinates, timestamp, the action we want  | `XdndStatus`    |
/// | `XdndLeave`    | our window                                       | -               |
/// | `XdndDrop`     | our window, timestamp                            | `XdndFinished`  |
///
/// and the payload leaves through the selection: the destination calls
/// `ConvertSelection` on `XdndSelection`, which reaches us as a
/// `SelectionRequest`, and we write the bytes onto *its* window and answer with
/// a `SelectionNotify`.
///
/// ## The three rules that are not optional
///
///   * **A refusal is a `SelectionNotify` with property `None`.** A destination
///     that asked for a type we cannot produce is waiting on its own event
///     queue; answering nothing hangs *it*, and the user reads that as the
///     other application freezing.
///   * **`XdndFinished` may never arrive.** A destination is entitled to exit
///     mid-drop. Without [finishTimeout] the future this class hands back would
///     never complete, so the widget that started the drag would never learn
///     it ended and would refuse to start another.
///   * **A drop happens only if the last `XdndStatus` accepted.** Sending
///     `XdndDrop` to a target that refused is what makes a file vanish into a
///     window that was never going to take it.
final class X11XdndSource {
  X11XdndSource(
    this._client, {
    Duration finishTimeout = const Duration(seconds: 10),
  }) : _finishTimeout = finishTimeout;

  final X11DragDropClient _client;

  /// How long `XdndFinished` may be waited for before the drag is reported as
  /// having performed nothing.
  final Duration _finishTimeout;

  // --- the live drag -------------------------------------------------------

  int _originWindow = 0;
  int _rootWindow = 0;
  X11DragPayload _payload = const <String, Uint8List>{};
  List<int> _typeAtoms = const <int>[];
  Set<DragAction> _actions = const <DragAction>{};
  DragAction _preferred = DragAction.copy;

  /// The XDND-aware window the pointer is over, or 0. Already proxy-resolved:
  /// a window with an `XdndProxy` is addressed *through* the proxy, and mixing
  /// the two up sends every message to a window that is not listening.
  int _target = 0;
  int _targetVersion = 0;
  bool _entered = false;

  bool _accepted = false;
  DragAction _negotiated = DragAction.none;

  /// The rectangle the last `XdndStatus` said the answer holds inside, in root
  /// coordinates, or null when the destination asked to be told about every
  /// motion.
  ({int x, int y, int width, int height})? _silentRect;

  bool _dropSent = false;
  Timer? _finishTimer;
  Completer<DragAction>? _completer;

  /// Whether a drag started here is still running.
  bool get isDragging => _completer != null;

  /// The XDND window under the pointer, or 0.
  int get targetWindow => _target;

  /// The version this source and the target settled on, or 0.
  int get targetVersion => _targetVersion;

  /// Whether the last `XdndStatus` accepted.
  bool get targetAccepts => _accepted;

  /// The action the target agreed to, or [DragAction.none].
  DragAction get negotiatedAction => _negotiated;

  /// Whether `XdndDrop` has been sent and `XdndFinished` is still owed.
  bool get isAwaitingFinish => _dropSent;

  /// The MIME names this drag is offering, in the order they were advertised.
  List<String> get offeredFormats => List<String>.unmodifiable(_payload.keys);

  // -------------------------------------------------------------------------
  // Starting
  // -------------------------------------------------------------------------

  /// Takes `XdndSelection` and begins a drag from [originWindow].
  ///
  /// Completes when the drag ends: with the action the destination performed,
  /// or [DragAction.none] for a cancel or a drop on nothing - which is the
  /// ordinary outcome and not an error. Throws [DragDropException] only when
  /// the drag could not begin at all.
  Future<DragAction> start({
    required int originWindow,
    required int rootWindow,
    required X11DragPayload payload,
    required Set<DragAction> actions,
    required int time,
    DragAction preferred = DragAction.copy,
  }) {
    if (isDragging) {
      throw const DragDropException(
        operation: 'startDrag',
        reason: 'a drag started by this client is already running; one '
            'selection owner cannot serve two drags',
        backend: 'xdnd',
      );
    }
    if (payload.isEmpty) {
      throw const DragDropException(
        operation: 'startDrag',
        reason: 'the payload offers no format, so there is nothing to drag',
        backend: 'xdnd',
      );
    }
    final int selection = _client.atom('XdndSelection');
    if (selection == xcbNone) {
      throw const DragDropException(
        operation: 'startDrag',
        reason: 'the XdndSelection atom could not be interned, so no drag can '
            'own the selection the payload travels through',
        backend: 'xdnd',
      );
    }

    final List<int> types = <int>[];
    for (final String mime in payload.keys) {
      final int atom = _client.atom(mime);
      // A type the server would not intern cannot be named on the wire, and
      // offering a name no destination can ever ask for would make the drag
      // advertise more than it can deliver.
      if (atom != xcbNone) types.add(atom);
    }
    if (types.isEmpty) {
      throw const DragDropException(
        operation: 'startDrag',
        reason: 'none of the offered formats could be interned as an atom',
        backend: 'xdnd',
      );
    }

    _client
      ..setSelectionOwner(originWindow, selection, time)
      ..flush();
    final int owner = _client.getSelectionOwner(selection);
    if (owner != originWindow) {
      // Losing the race is not hypothetical: another client can take the
      // selection between the two calls, and a source that did not check would
      // drag a payload nobody can ever convert.
      throw DragDropException(
        operation: 'SetSelectionOwner',
        reason: 'XdndSelection is owned by window $owner rather than by '
            '$originWindow, so this drag could not serve its own data',
        backend: 'xdnd',
      );
    }

    _originWindow = originWindow;
    _rootWindow = rootWindow;
    _payload = Map<String, Uint8List>.unmodifiable(payload);
    _typeAtoms = List<int>.unmodifiable(types);
    _actions = Set<DragAction>.unmodifiable(actions);
    _preferred = preferred;
    _target = 0;
    _targetVersion = 0;
    _entered = false;
    _accepted = false;
    _negotiated = DragAction.none;
    _silentRect = null;
    _dropSent = false;

    // Only when there are more than three: the property is what a destination
    // reads *instead of* the inline words, and writing it for a two-type drag
    // is a round trip that buys nothing.
    if (types.length > xdndEnterInlineTypeCount) {
      _client.setWindowProperty32(
        originWindow,
        _client.atom('XdndTypeList'),
        xcbAtomAtom,
        types,
      );
    }
    _client.flush();

    final Completer<DragAction> completer = Completer<DragAction>();
    _completer = completer;
    return completer.future;
  }

  // -------------------------------------------------------------------------
  // Driving
  // -------------------------------------------------------------------------

  /// The pointer moved to root coordinates ([rootX], [rootY]).
  ///
  /// Finds the XDND window under it, sends the enter/leave pair when that
  /// changed, and sends an `XdndPosition` unless the last status said the
  /// answer holds inside a rectangle this point is still in.
  void moveTo(int rootX, int rootY, int time) {
    if (!isDragging || _dropSent) return;
    final _X11XdndTarget found = _findTarget(rootX, rootY);
    if (found.window != _target) {
      _leaveCurrentTarget();
      _target = found.window;
      _targetVersion = found.version;
      _accepted = false;
      _negotiated = DragAction.none;
      _silentRect = null;
      if (_target != xcbNone) _sendEnter();
    }
    if (_target == xcbNone) {
      _client.flush();
      return;
    }
    final ({int x, int y, int width, int height})? rect = _silentRect;
    if (rect != null &&
        rootX >= rect.x &&
        rootY >= rect.y &&
        rootX < rect.x + rect.width &&
        rootY < rect.y + rect.height) {
      // Inside the rectangle the destination promised the same answer for.
      // Honouring it is the one optimisation the specification actually asks a
      // source for, and it is what keeps a drag over a large drop zone from
      // costing a round trip per pointer sample.
      return;
    }
    _sendPosition(rootX, rootY, time);
    _client.flush();
  }

  /// The user released the button: drop if the target accepted, leave if not.
  void release(int time) {
    if (!isDragging || _dropSent) return;
    if (_target == xcbNone || !_accepted) {
      // A drop on a target that refused is a drop that would never be
      // finished; the leave is what lets the other client tidy up.
      _leaveCurrentTarget();
      _client.flush();
      _finish(DragAction.none);
      return;
    }
    _dropSent = true;
    _client
      ..sendClientMessage(
        destination: _target,
        window: _target,
        type: _client.atom('XdndDrop'),
        data: <int>[_originWindow, 0, time, 0, 0],
      )
      ..flush();
    _finishTimer = Timer(_finishTimeout, () {
      if (!_dropSent) return;
      _client.recordError(
        'XdndFinished never arrived from window $_target; the destination may '
        'have exited mid-drop, so the drag is reported as having performed '
        'nothing',
      );
      _finish(DragAction.none);
    });
  }

  /// Abandons the drag - Escape, a lost grab, a window going away.
  void cancel() {
    if (!isDragging) return;
    _leaveCurrentTarget();
    _client.flush();
    _finish(DragAction.none);
  }

  // -------------------------------------------------------------------------
  // Events
  // -------------------------------------------------------------------------

  /// A `ClientMessage` addressed to our source window.
  ///
  /// Returns whether it was one of ours, so the caller can go on offering it to
  /// the destination machine when it was not.
  bool handleClientMessage({
    required int type,
    required int window,
    required List<int> data,
  }) {
    if (!isDragging || data.length < xdndClientMessageWordCount) return false;
    if (type == _client.atom('XdndStatus')) {
      _onStatus(data);
      return true;
    }
    if (type == _client.atom('XdndFinished')) {
      _onFinished(data);
      return true;
    }
    return false;
  }

  void _onStatus(List<int> data) {
    // `data.l[0]` is the target window answering. A status from a window we
    // have already left is stale by definition and must not revive it.
    if (data[0] != _target) return;
    _accepted = (data[1] & xdndStatusAcceptBit) != 0;
    _negotiated = _accepted ? _actionFromAtom(data[4]) : DragAction.none;
    if ((data[1] & xdndStatusWantPositionBit) != 0) {
      _silentRect = null;
      return;
    }
    final int width = (data[3] >> 16) & 0xFFFF;
    final int height = data[3] & 0xFFFF;
    // A zero-sized rectangle means "ask again every time", which is the same
    // instruction the want-position bit gives and is spelled both ways in the
    // wild.
    _silentRect = width == 0 || height == 0
        ? null
        : (
            x: (data[2] >> 16) & 0xFFFF,
            y: data[2] & 0xFFFF,
            width: width,
            height: height,
          );
  }

  void _onFinished(List<int> data) {
    if (data[0] != _target || !_dropSent) return;
    // Versions below 5 send only `data.l[0]`; the rest of the message is
    // whatever `SendEvent` padded it with, so reading it would decide at random
    // whether the drop succeeded. Those sources get "the action the last status
    // agreed to", which is the only thing actually known.
    final bool accepted = _targetVersion >= xdndFinishedVersionedReply
        ? (data[1] & xdndFinishedAcceptedBit) != 0
        : true;
    final DragAction performed = !accepted
        ? DragAction.none
        : _targetVersion >= xdndFinishedVersionedReply
            ? _actionFromAtom(data[2])
            : _negotiated;
    _finish(performed);
  }

  /// A destination is converting `XdndSelection`: write the bytes and answer.
  ///
  /// Returns whether the request was for our selection.
  bool handleSelectionRequest({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) {
    if (selection != _client.atom('XdndSelection')) return false;
    // A requestor from before XDND version 2 sends property None and means
    // "use the target atom as the property"; honouring it costs one line and
    // refusing it strands an old client.
    final int destination = property == xcbNone ? target : property;
    final int targetsAtom = _client.atom('TARGETS');

    bool written = false;
    if (targetsAtom != xcbNone && target == targetsAtom) {
      _client.setWindowProperty32(
        requestor,
        destination,
        xcbAtomAtom,
        <int>[targetsAtom, ..._typeAtoms],
      );
      written = true;
    } else {
      final String? mime = _client.atomName(target);
      final Uint8List? bytes = mime == null ? null : _payload[mime];
      if (bytes != null) {
        _client.setWindowPropertyBytes(requestor, destination, target, bytes);
        written = true;
      }
    }

    // The refusal is a SelectionNotify with property None, and it is not
    // optional: the requestor is blocked on its own event queue waiting for
    // exactly this, and silence is what makes the *other* application appear
    // to hang.
    _client
      ..sendSelectionNotify(
        requestor: requestor,
        selection: selection,
        target: target,
        property: written ? destination : xcbNone,
        time: time,
      )
      ..flush();
    return true;
  }

  /// Another client took `XdndSelection`. The drag cannot serve its data any
  /// more, so it ends rather than continuing to promise bytes.
  bool handleSelectionClear(int selection) {
    if (!isDragging || selection != _client.atom('XdndSelection')) return false;
    _client.recordError(
      'another client took XdndSelection during a drag started here; the drag '
      'is cancelled because its payload can no longer be converted',
    );
    cancel();
    return true;
  }

  /// Drops every piece of state, for a connection going away.
  void dispose() {
    if (isDragging) {
      _leaveCurrentTarget();
      _finish(DragAction.none);
    }
    _finishTimer?.cancel();
    _finishTimer = null;
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  void _sendEnter() {
    final List<int> inline = <int>[
      for (int i = 0; i < xdndEnterInlineTypeCount; i++)
        i < _typeAtoms.length ? _typeAtoms[i] : xcbNone,
    ];
    final int version = _targetVersion < xdndVersion ? _targetVersion : xdndVersion;
    _client.sendClientMessage(
      destination: _target,
      window: _target,
      type: _client.atom('XdndEnter'),
      data: <int>[
        _originWindow,
        (version << xdndEnterVersionShift) |
            (_typeAtoms.length > xdndEnterInlineTypeCount
                ? xdndEnterMoreTypesBit
                : 0),
        inline[0],
        inline[1],
        inline[2],
      ],
    );
    _entered = true;
  }

  void _sendPosition(int rootX, int rootY, int time) => _client.sendClientMessage(
        destination: _target,
        window: _target,
        type: _client.atom('XdndPosition'),
        data: <int>[
          _originWindow,
          0,
          ((rootX & 0xFFFF) << 16) | (rootY & 0xFFFF),
          time,
          _atomForAction(resolveDragAction(_actions, preferred: _preferred)),
        ],
      );

  void _leaveCurrentTarget() {
    if (_target == xcbNone || !_entered) {
      _target = xcbNone;
      _entered = false;
      return;
    }
    _client.sendClientMessage(
      destination: _target,
      window: _target,
      type: _client.atom('XdndLeave'),
      data: <int>[_originWindow, 0, 0, 0, 0],
    );
    _target = xcbNone;
    _entered = false;
    _accepted = false;
    _negotiated = DragAction.none;
    _silentRect = null;
  }

  /// Walks down from the root looking for the deepest XDND-aware window.
  ///
  /// The descent is the only way to find a target: X has no "who is under the
  /// pointer" question that skips the hierarchy, so a source asks
  /// `QueryPointer` at each level and follows the child it names. The depth
  /// limit is not paranoia about honest servers - it is about a hierarchy being
  /// reparented *underneath the walk*, which would otherwise spin forever
  /// inside one pointer motion.
  _X11XdndTarget _findTarget(int rootX, int rootY) {
    final int awareAtom = _client.atom('XdndAware');
    if (awareAtom == xcbNone) return const _X11XdndTarget(xcbNone, 0);
    int window = _rootWindow;
    _X11XdndTarget best = const _X11XdndTarget(xcbNone, 0);
    for (int depth = 0; depth < xdndPointerWalkDepthLimit; depth++) {
      final _X11XdndTarget? aware = _awarenessOf(window, awareAtom);
      if (aware != null) best = aware;
      final X11PointerLocation? location = _client.queryPointer(window);
      if (location == null || location.child == xcbNone) break;
      window = location.child;
    }
    return best;
  }

  /// The XDND awareness of one window, resolved through `XdndProxy`.
  ///
  /// A proxy is how a toolkit puts one invisible window in charge of a whole
  /// hierarchy's drops. The version is read from the *proxy*, and every message
  /// goes to the proxy, but only if the proxy points back at itself - a stale
  /// `XdndProxy` left behind by a dead client is the classic way a desktop
  /// starts refusing every drop, and checking the back-reference is the
  /// specification's own defence against it.
  _X11XdndTarget? _awarenessOf(int window, int awareAtom) {
    final int proxyAtom = _client.atom('XdndProxy');
    int addressee = window;
    if (proxyAtom != xcbNone) {
      final List<int> proxy = _client.readPropertyCardinals(
        window,
        proxyAtom,
        type: xcbAtomWindow,
      );
      if (proxy.isNotEmpty && proxy.first != xcbNone) {
        final List<int> back = _client.readPropertyCardinals(
          proxy.first,
          proxyAtom,
          type: xcbAtomWindow,
        );
        if (back.isNotEmpty && back.first == proxy.first) {
          addressee = proxy.first;
        }
      }
    }
    final List<int> aware = _client.readPropertyCardinals(
      addressee,
      awareAtom,
      type: xcbAtomAtom,
    );
    if (aware.isEmpty) return null;
    final int version = aware.first;
    if (version < xdndMinimumVersion) return null;
    return _X11XdndTarget(addressee, version);
  }

  void _finish(DragAction action) {
    _finishTimer?.cancel();
    _finishTimer = null;
    final Completer<DragAction>? completer = _completer;
    _completer = null;
    _dropSent = false;
    _target = xcbNone;
    _entered = false;
    _accepted = false;
    _negotiated = DragAction.none;
    _silentRect = null;
    _payload = const <String, Uint8List>{};
    _typeAtoms = const <int>[];
    if (completer != null && !completer.isCompleted) completer.complete(action);
  }

  DragAction _actionFromAtom(int value) {
    if (value == xcbNone) return DragAction.none;
    if (value == _client.atom('XdndActionCopy')) return DragAction.copy;
    if (value == _client.atom('XdndActionMove')) return DragAction.move;
    if (value == _client.atom('XdndActionLink')) return DragAction.link;
    if (value == _client.atom('XdndActionAsk')) return DragAction.ask;
    return DragAction.copy;
  }

  int _atomForAction(DragAction action) => switch (action) {
        DragAction.none => xcbNone,
        DragAction.copy => _client.atom('XdndActionCopy'),
        DragAction.move => _client.atom('XdndActionMove'),
        DragAction.link => _client.atom('XdndActionLink'),
        DragAction.ask => _client.atom('XdndActionAsk'),
      };
}

/// One XDND-aware window and the version it advertises.
final class _X11XdndTarget {
  const _X11XdndTarget(this.window, this.version);

  final int window;
  final int version;
}

// ---------------------------------------------------------------------------
// The port adapter
// ---------------------------------------------------------------------------

/// Resolves a framework window to the XID a drag is registered against, or 0
/// when the window does not belong to this backend.
typedef X11DragDropWindowLookup = int Function(NativeWindow window);

/// [X11DragDropManager] behind the shared [DragDropBackend] port.
///
/// Thin on purpose: everything that can be got wrong is in the manager, where
/// it is tested, and this only translates registration and refusal.
final class X11DragDropBackend implements DragDropBackend {
  X11DragDropBackend({
    required X11DragDropManager manager,
    required X11DragDropWindowLookup xcbWindowOf,
  })  : _manager = manager,
        _xcbWindowOf = xcbWindowOf;

  final X11DragDropManager _manager;
  final X11DragDropWindowLookup _xcbWindowOf;

  /// The source half, or null when this backend was built without one.
  ///
  /// Nullable rather than always present because a connection that could not
  /// intern `XdndSelection` can still *receive* drops perfectly well, and
  /// refusing to build the whole backend over the half that is missing would
  /// lose the half that works.
  X11XdndSource? source;

  /// Where the pointer is, for the motion the source walks the tree on.
  ///
  /// Injected because the drag is driven from the backend's pointer stream and
  /// this class must not reach into `X11Window` - the same rule the
  /// destination's [X11RootToClient] follows.
  int Function()? currentTime;

  final List<X11DropTargetRegistration> _registrations =
      <X11DropTargetRegistration>[];

  @override
  String get name => 'xdnd';

  /// Whether a source machine was wired up and can own `XdndSelection`.
  @override
  bool get canStartDrag => source != null;

  @override
  Future<DropTargetRegistration> registerDropTarget({
    required NativeWindow window,
    required DropTargetHandler handler,
  }) async {
    final int xcbWindow = _xcbWindowOf(window);
    if (xcbWindow == 0) {
      throw DragDropException(
        operation: 'registerDropTarget',
        reason: 'window ${window.id.value} is not a live X11 window of this '
            'backend',
        backend: name,
      );
    }
    if (_manager.isRegistered(xcbWindow)) {
      throw DragDropException(
        operation: 'registerDropTarget',
        reason: 'window ${window.id.value} already has an XdndAware drop '
            'target; revoke it before registering another',
        backend: name,
      );
    }
    final DropTargetHandler? installed = _manager.handler;
    if (installed != null &&
        !identical(installed, handler) &&
        _registrations.any((X11DropTargetRegistration each) => each.isActive)) {
      // The manager routes one handler for the whole connection, exactly as the
      // Wayland one does, and the window a drag is over is named by
      // `DragSessionEvent.windowId`. Replacing it silently would leave the
      // first window registered with the server and dead in this process.
      throw DragDropException(
        operation: 'registerDropTarget',
        reason: 'this connection already routes drops to another handler; '
            'one handler serves every window and dispatches on '
            'DragSessionEvent.windowId',
        backend: name,
      );
    }
    _manager
      ..handler = handler
      ..registerWindow(xcbWindow, window.id);
    final X11DropTargetRegistration registration = X11DropTargetRegistration(
      windowId: window.id,
      xcbWindow: xcbWindow,
      onRevoke: _revoke,
    );
    _registrations.add(registration);
    return registration;
  }

  void _revoke(X11DropTargetRegistration registration) {
    _registrations.remove(registration);
    _manager.unregisterWindow(registration.xcbWindow);
    if (_registrations.isEmpty) _manager.handler = null;
  }

  /// Drags [request]'s payload out of this application.
  ///
  /// The payload is materialised **here**, before the selection is taken: a
  /// `SelectionRequest` is answered from inside the event pump, where no
  /// microtask can run, so a [LazyDragData] that had not been resolved by then
  /// could never be. That is the same rule the Win32 and Wayland sources
  /// follow, for the same reason.
  ///
  /// The future completes when the drag ends - `XdndFinished`, a cancel, or the
  /// finish timeout - with the action the destination reported performing.
  /// [DragAction.none] means the user dropped on nothing, which is not an
  /// error.
  ///
  /// **`DragRequest.feedback` is ignored.** A drag icon on X11 is an
  /// override-redirect window the source moves with the pointer and paints
  /// itself, which is a second presentation path this backend does not have;
  /// the cursor the window manager draws is what the user gets. Ignoring it is
  /// the documented degradation, not a silent one.
  @override
  Future<DragAction> startDrag(DragRequest request) async {
    final X11XdndSource? machine = source;
    if (machine == null) {
      throw DragDropException(
        operation: 'startDrag',
        reason: 'this connection has no XDND source; XdndSelection could not '
            'be interned, so a drag could never serve its own payload',
        backend: name,
      );
    }
    final int originWindow = _xcbWindowOf(request.window);
    if (originWindow == 0) {
      throw DragDropException(
        operation: 'startDrag',
        reason: 'window ${request.window.id.value} is not a live X11 window of '
            'this backend, and XDND needs one to own the selection',
        backend: name,
      );
    }
    final Map<String, Uint8List> payload = <String, Uint8List>{};
    for (final String format in request.data.formats) {
      final Uint8List? bytes = await request.data.readBytes(format);
      if (bytes != null) payload[format] = bytes;
    }
    if (payload.isEmpty) {
      throw DragDropException(
        operation: 'startDrag',
        reason: 'none of the ${request.data.formats.length} offered format(s) '
            'produced any bytes, so there is nothing to drag',
        backend: name,
      );
    }
    return machine.start(
      originWindow: originWindow,
      rootWindow: rootWindow,
      payload: payload,
      actions: request.allowedActions,
      preferred: request.preferredAction,
      time: currentTime?.call() ?? 0,
    );
  }

  /// The screen's root window, which the source's tree walk starts from.
  int rootWindow = 0;
}

/// The live registration [X11DragDropBackend] hands out.
final class X11DropTargetRegistration implements DropTargetRegistration {
  X11DropTargetRegistration({
    required this.windowId,
    required this.xcbWindow,
    required void Function(X11DropTargetRegistration registration) onRevoke,
  }) : _onRevoke = onRevoke;

  @override
  final NativeWindowId windowId;

  final int xcbWindow;
  final void Function(X11DropTargetRegistration registration) _onRevoke;

  @override
  bool isActive = true;

  @override
  Future<void> revoke() async {
    if (!isActive) return;
    isActive = false;
    _onRevoke(this);
  }
}
