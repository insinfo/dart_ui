/// Drag and drop over `wl_data_device`, both as a destination and a source.
///
/// ## What this file is, now that the port exists
///
/// This used to carry a vocabulary of its own - `WaylandDragData`,
/// `WaylandDragAction`, `WaylandDropResponse`, `WaylandDropTargetHandler` -
/// under a header explaining that defining a cross-backend contract was not a
/// decision the Wayland backend could take alone, and that the local names
/// were shaped so adopting a port later would be *a rename rather than a
/// rewrite*. `lib/src/platform/drag_drop.dart` is that port, and this is the
/// rename: every framework-facing type here is now the shared one, and what
/// stayed is the part that is genuinely Wayland's - the action bitmask, the
/// client seam and the state machine that sequences the protocol.
///
/// ## The two halves of the protocol
///
/// **As a destination** the compositor announces `data_offer`, then `enter`
/// naming the offer and a surface, then `motion`, then either `leave` or
/// `drop`. The client must answer `accept` with a MIME type it will take (or
/// null to refuse), and `set_actions` with what it is prepared to do; only
/// then is the drop allowed. After `drop` the data is read through a pipe,
/// exactly like the clipboard, and `finish` tells the source it may complete
/// a move.
///
/// **As a source** the client creates a `wl_data_source`, offers its MIME
/// types, sets its actions and calls `start_drag` with the serial of the
/// button press that began the gesture. The compositor then asks for the
/// bytes with `send`, reports the negotiated `action`, and ends with either
/// `cancelled` or `dnd_finished`.
///
/// ## The three places Wayland does not fit the port, and what happens there
///
///   * **There is no `link` action.** `wl_data_device_manager`'s enum is
///     copy, move and ask, so [DragAction.link] maps to [wlDndActionNone] -
///     a refusal - and never to a substitute. [waylandDndActionBits] carries
///     the argument.
///   * **There is no screen position.** A Wayland client is never told where
///     its own surfaces sit on the desktop, so
///     [DragSessionEvent.screenPosition] is always null here. The other half
///     of that trade is that [DragSessionEvent.position] needs no conversion
///     at all: the protocol already reports surface-local logical
///     coordinates, which is the one place Wayland is easier than Win32 and
///     XDND.
///   * **Surfaces are not windows.** `wl_data_device.enter` names a
///     `wl_surface` and the port speaks [NativeWindowId]; the two numbering
///     spaces are unrelated. See [WaylandDragDropManager.windowIdForSurface].
library;

import 'dart:async';
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../platform/drag_drop.dart';
import '../../platform/window_events.dart';

/// The protocol operations the manager needs from a connection.
abstract interface class WaylandDragDropClient {
  bool get supportsDragAndDrop;

  /// `wl_data_offer.accept` with the negotiated serial.
  void acceptOffer(int offerId, int serial, String? mimeType);

  /// `wl_data_offer.set_actions`.
  void setOfferActions(int offerId, int actions, int preferredAction);

  /// `wl_data_offer.receive` into a pipe, then read it to EOF.
  Future<Uint8List?> receiveOffer(int offerId, String mimeType);

  /// `wl_data_offer.finish`, which a move needs before the source may delete.
  void finishOffer(int offerId);

  void destroyOffer(int offerId);

  /// Creates a `wl_data_source` offering [mimeTypes] with [actions], and
  /// starts a drag from [originSurfaceId] with [iconSurfaceId] (0 for none).
  /// Returns the source id, or 0 when the drag could not start.
  int startDrag({
    required int originSurfaceId,
    required int iconSurfaceId,
    required List<String> mimeTypes,
    required int actions,
  });

  /// Writes [bytes] to the fd the compositor handed us for a `send`.
  bool sendDragData(int fd, Uint8List bytes);

  void destroyDataSource(int sourceId);
}

/// The bitmask for one action.
///
/// **[DragAction.link] maps to [wlDndActionNone], which is a refusal.**
/// Wayland's action enum has copy, move and ask and no link at all, and
/// `drag_drop_types.dart` states the rule this obeys: a backend asked for an
/// action its protocol cannot name refuses rather than substitutes, because
/// both substitutions are worse than a refusal. Sending [wlDndActionCopy] for
/// a requested link duplicates a file the user meant to reference, and
/// [wlDndActionMove] deletes the original they meant to keep. A refusal is
/// merely the "not allowed" cursor, which is the truth.
int waylandDndActionBits(DragAction action) => switch (action) {
      DragAction.none || DragAction.link => wlDndActionNone,
      DragAction.copy => wlDndActionCopy,
      DragAction.move => wlDndActionMove,
      DragAction.ask => wlDndActionAsk,
    };

/// The single action a bitmask names, preferring copy when several are set -
/// which is what a compositor does when the user is not holding a modifier.
///
/// Never returns [DragAction.link]: no bit spells it, which is the same gap
/// [waylandDndActionBits] refuses on the way out.
DragAction waylandDndActionFromBits(int bits) {
  if ((bits & wlDndActionCopy) != 0) return DragAction.copy;
  if ((bits & wlDndActionMove) != 0) return DragAction.move;
  if ((bits & wlDndActionAsk) != 0) return DragAction.ask;
  return DragAction.none;
}

/// Every action a `wl_data_offer.source_actions` bitmask names, as the set
/// [DragSessionEvent.allowedActions] wants.
///
/// [wlDndActionNone] is read as *unknown*, not as *nothing*, and answers the
/// copy-only set: `source_actions` arrived with version 3 of the interface and
/// a version 2 source never sends it at all, so reporting an empty allowed set
/// there would make every target that honours the contract refuse a drag the
/// compositor would have completed happily. Copy is the safe reading of an
/// unknown mask because it is the one action that cannot lose the user's data
/// if the guess was wrong - the same argument [resolveDragAction] makes.
Set<DragAction> waylandDndActionSet(int bits) {
  if (bits == wlDndActionNone) return const <DragAction>{DragAction.copy};
  return <DragAction>{
    if ((bits & wlDndActionCopy) != 0) DragAction.copy,
    if ((bits & wlDndActionMove) != 0) DragAction.move,
    if ((bits & wlDndActionAsk) != 0) DragAction.ask,
  };
}

// Local aliases so this file reads without the protocol prefix everywhere.
const int wlDndActionNone = 0;
const int wlDndActionCopy = 1 << 0;
const int wlDndActionMove = 1 << 1;
const int wlDndActionAsk = 1 << 2;

/// What a drag source hands over when the compositor asks for bytes.
///
/// Synchronous, and deliberately so: `wl_data_source.send` arrives with a file
/// descriptor the compositor expects this process to write and close, and a
/// source that returned a future would leave the destination blocked on a pipe
/// with no writer for as long as the microtask took. The source side of
/// [WaylandDragDropBackend] therefore materialises a [DragData] before it
/// starts the drag rather than resolving formats on demand.
typedef WaylandDragDataProvider = Uint8List? Function(String mimeType);

/// The [DragData] behind one live `wl_data_offer`.
///
/// A private class instead of the shared [LazyDragData], which is otherwise
/// exactly this shape, for one reason: `wl_data_offer.finish` may only be sent
/// after a transfer that *produced bytes*, so the manager has to know whether
/// any read succeeded, and [LazyDragData] deliberately keeps its cache to
/// itself. The caching rule is the same one and for the same reason - the
/// receive consumed the offer, so a second call must answer from memory rather
/// than hang on a pipe nobody will write to again.
final class _WaylandOfferData implements DragData {
  _WaylandOfferData({
    required WaylandDragDropClient client,
    required int offerId,
    required this.formats,
  })  : _client = client,
        _offerId = offerId;

  final WaylandDragDropClient _client;
  final int _offerId;

  @override
  final List<String> formats;

  final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  /// Whether any transfer out of this offer actually delivered bytes, which is
  /// the precondition for `finish`.
  bool transferSucceeded = false;

  @override
  Future<Uint8List?> readBytes(String format) async {
    // Asking for a type the source never advertised makes the receive hang
    // forever rather than fail, so it is answered here and never sent.
    if (!formats.contains(format)) return null;
    if (_cache.containsKey(format)) return _cache[format];
    final Uint8List? bytes = await _client.receiveOffer(_offerId, format);
    _cache[format] = bytes;
    if (bytes != null) transferSucceeded = true;
    return bytes;
  }

  @override
  String toString() =>
      'WaylandOfferData(offer $_offerId: ${formats.join(', ')})';
}

/// The state machine for both halves of a drag.
///
/// One instance per connection. It is a state machine rather than a set of
/// callbacks because the protocol's ordering rules are real: `accept` before
/// `drop`, `set_actions` before the action is known, `finish` only after a
/// successful read, and an offer destroyed exactly once. Getting any of them
/// wrong hangs the *other* application, which is the failure mode that makes
/// drag and drop notoriously flaky.
final class WaylandDragDropManager {
  WaylandDragDropManager(this._client);

  final WaylandDragDropClient _client;

  /// Where drags go. [WaylandDragDropBackend] installs a router here that fans
  /// out to per-window handlers; a test drives one handler directly.
  DropTargetHandler? handler;

  /// Turns the `wl_surface` id the protocol reports into the window id the
  /// port speaks.
  ///
  /// The manager only ever sees surfaces - `wl_data_device.enter` names a
  /// `wl_surface` and nothing else - while [DragSessionEvent] must carry a
  /// [NativeWindowId], and the two numbering spaces are unrelated: surface ids
  /// come from the connection's object allocator, window ids from the
  /// backend's own counter. Assuming they coincide would deliver drops to the
  /// wrong window as soon as a process opens a second one, so the real lookup
  /// is installed from outside and the identity below is only what a manager
  /// driven directly - in a test, or by an embedder with one surface - falls
  /// back to.
  NativeWindowId Function(int surfaceId)? windowIdForSurface;

  /// Called when a drag *this* client started has ended, with the action the
  /// destination performed - [DragAction.none] for a cancelled drag.
  ///
  /// The protocol reports the end in three different ways (`dnd_finished`,
  /// `cancelled`, or this client starting another drag) and
  /// [DragDropBackend.startDrag] has to complete its future on all three, so
  /// they funnel through the single teardown that all three reach.
  void Function(DragAction action)? onSourceDragEnded;

  // --- destination state ---------------------------------------------------

  /// The offer announced but not yet entered; the protocol sends
  /// `data_offer` before `enter`, with the MIME list in between.
  int _pendingOfferId = 0;
  final List<String> _pendingMimeTypes = <String>[];
  int _pendingSourceActions = wlDndActionNone;

  /// The offer currently under the pointer.
  int _activeOfferId = 0;
  List<String> _activeMimeTypes = const <String>[];
  _WaylandOfferData? _activeData;
  int _enterSerial = 0;
  int _activeSurfaceId = 0;
  String? _acceptedMime;
  DragAction _negotiatedAction = DragAction.none;

  /// The last position the compositor reported, because `wl_data_device.drop`
  /// carries none: a drop happens wherever the last `enter` or `motion` left
  /// the pointer, and a [DragSessionEvent] must still say where.
  Offset _lastPosition = Offset.zero;

  /// True between `drop` and the handler's transfer completing, when the offer
  /// must not be destroyed - the pipe is still being read out of it.
  bool _dropInFlight = false;

  // --- source state --------------------------------------------------------

  int _sourceId = 0;
  WaylandDragDataProvider? _sourceProvider;
  List<String> _sourceMimeTypes = const <String>[];
  DragAction _sourceAction = DragAction.none;
  bool _sourceDropPerformed = false;

  /// Whether the compositor bound a data device at all, which is what both
  /// halves of a drag need.
  bool get supportsDragAndDrop => _client.supportsDragAndDrop;

  /// Whether a drag started by this client is in flight.
  bool get isDragging => _sourceId != 0;

  /// The id of the offer under the pointer, or 0.
  int get activeOfferId => _activeOfferId;

  /// What the destination side negotiated, for diagnostics and the cursor.
  DragAction get negotiatedAction => _negotiatedAction;

  /// The action the source was told the drop will perform.
  DragAction get sourceAction => _sourceAction;

  /// Whether the source has seen `dnd_drop_performed`.
  bool get sourceDropPerformed => _sourceDropPerformed;

  // -------------------------------------------------------------------------
  // Destination
  // -------------------------------------------------------------------------

  /// `wl_data_device.data_offer`: a new offer object exists but nothing is
  /// known about it yet.
  void onDataOffer(int offerId) {
    // An offer announced while another is still pending means the previous
    // one was for a selection we ignored; drop it rather than leak the object.
    if (_pendingOfferId != 0 && _pendingOfferId != _activeOfferId) {
      _client.destroyOffer(_pendingOfferId);
    }
    _pendingOfferId = offerId;
    _pendingMimeTypes.clear();
    _pendingSourceActions = wlDndActionNone;
  }

  /// `wl_data_offer.offer`: one MIME type the source can produce.
  void onOfferMime(int offerId, String mimeType) {
    if (offerId != _pendingOfferId) return;
    _pendingMimeTypes.add(mimeType);
  }

  /// `wl_data_offer.source_actions`.
  void onOfferSourceActions(int offerId, int actions) {
    if (offerId == _pendingOfferId) {
      _pendingSourceActions = actions;
      return;
    }
    if (offerId == _activeOfferId) _pendingSourceActions = actions;
  }

  /// `wl_data_offer.action`: what the compositor settled on.
  void onOfferAction(int offerId, int action) {
    if (offerId != _activeOfferId) return;
    _negotiatedAction = waylandDndActionFromBits(action);
  }

  /// `wl_data_device.enter`.
  void onDragEnter({
    required int serial,
    required int surfaceId,
    required int offerId,
    required Offset position,
  }) {
    // An enter with no offer means a drag carrying nothing this client can
    // see; there is nothing to accept and nothing to destroy.
    if (offerId == 0) return;
    _activeOfferId = offerId;
    _activeMimeTypes = List<String>.unmodifiable(_pendingMimeTypes);
    _enterSerial = serial;
    _activeSurfaceId = surfaceId;
    _pendingOfferId = 0;
    _dropInFlight = false;
    _lastPosition = position;
    // One instance for the whole session, as the port requires: a target may
    // hold the data from enter to drop, and the cache that makes a second read
    // answer from memory lives in it.
    final _WaylandOfferData data = _WaylandOfferData(
      client: _client,
      offerId: offerId,
      formats: _activeMimeTypes,
    );
    _activeData = data;

    final DropResponse response =
        handler?.onDragEnter(_sessionEvent(data, position)) ??
            const DropResponse.reject();
    _applyResponse(response, force: true);
  }

  /// `wl_data_device.motion`.
  void onDragMotion(Offset position) {
    final _WaylandOfferData? data = _activeData;
    if (_activeOfferId == 0 || data == null) return;
    _lastPosition = position;
    final DropResponse response =
        handler?.onDragOver(_sessionEvent(data, position)) ??
            const DropResponse.reject();
    _applyResponse(response);
  }

  /// The port's view of the drag as it stands right now.
  ///
  /// [DragSessionEvent.screenPosition] stays null and is not guessed at: a
  /// Wayland client is not told where its surfaces are on the desktop and no
  /// request asks, so a number derived from [position] would be a lie a target
  /// could not tell from the truth.
  ///
  /// [DragSessionEvent.modifiers] stays empty for a narrower reason: the data
  /// device carries no modifier state, and the seat's `wl_keyboard.modifiers`
  /// latch is not routed here. A target that wants the Ctrl-copies convention
  /// reads [DragSessionEvent.suggestedAction], which the compositor has
  /// already applied the modifiers to.
  DragSessionEvent _sessionEvent(_WaylandOfferData data, Offset position) {
    final Set<DragAction> allowed = waylandDndActionSet(_pendingSourceActions);
    return DragSessionEvent(
      windowId: windowIdForSurface?.call(_activeSurfaceId) ??
          NativeWindowId(_activeSurfaceId),
      position: position,
      data: data,
      allowedActions: allowed,
      suggestedAction: resolveDragAction(allowed),
    );
  }

  /// Sends the accept/set_actions pair for [response].
  ///
  /// [force] is set on enter: an answer must be sent even when it is "no",
  /// because the compositor shows the refusal cursor only once it has been
  /// told. On motion the pair is deduplicated instead - motion arrives at
  /// pointer rate and the accept is state, not an event.
  void _applyResponse(DropResponse response, {bool force = false}) {
    final String? mime = response.acceptedFormat;
    // Only a type the source actually offers may be accepted; accepting one
    // it never advertised makes the receive() hang forever.
    final String? accepted =
        mime != null && _activeMimeTypes.contains(mime) ? mime : null;
    if (force || accepted != _acceptedMime) {
      _acceptedMime = accepted;
      _client.acceptOffer(_activeOfferId, _enterSerial, accepted);
    }
    final int wanted = accepted == null
        ? wlDndActionNone
        : waylandDndActionBits(response.action);
    // Never ask for an action the source cannot perform: the compositor
    // treats that as a protocol error in version 3.
    final int permitted = _pendingSourceActions == wlDndActionNone
        ? wanted
        : wanted & _pendingSourceActions;
    _client.setOfferActions(_activeOfferId, permitted, permitted);
    if (permitted == wlDndActionNone) {
      _negotiatedAction = DragAction.none;
    }
  }

  /// `wl_data_device.leave`. The offer dies with it.
  void onDragLeave() {
    if (_activeOfferId == 0) return;
    handler?.onDragLeave();
    if (!_dropInFlight) _destroyActiveOffer();
  }

  /// `wl_data_device.drop`.
  ///
  /// The transfer is the handler's to perform, through
  /// [DragData.readBytes] on the session's data: only the handler knows
  /// whether it still wants the bytes by the time the pipe opens, and a read
  /// nobody awaited would leave the source blocked on a pipe with no reader.
  /// The offer stays alive - and `leave` cannot pull it away - until the
  /// handler's future completes.
  void onDrop() {
    final int offerId = _activeOfferId;
    final String? mime = _acceptedMime;
    final _WaylandOfferData? data = _activeData;
    if (offerId == 0 || data == null) return;
    final DropTargetHandler? target = handler;
    if (mime == null || target == null) {
      // Dropped on a target that refused, or on none at all: nothing to read,
      // and the offer is retired immediately so the source stops waiting.
      _destroyActiveOffer();
      return;
    }
    _dropInFlight = true;
    unawaited(_completeDrop(target, offerId, data));
  }

  Future<void> _completeDrop(
    DropTargetHandler target,
    int offerId,
    _WaylandOfferData data,
  ) async {
    DragAction performed = DragAction.none;
    try {
      performed = await target.onDrop(_sessionEvent(data, _lastPosition));
    } finally {
      _dropInFlight = false;
      // finish() is what lets a *move* complete: without it the source may not
      // delete the original, and some compositors keep the drag cursor. It is
      // sent only when the handler reports it did something with bytes that
      // actually arrived - claiming a completed move over a transfer that
      // failed is how a drag and drop loses a file.
      if (performed != DragAction.none && data.transferSucceeded) {
        _client.finishOffer(offerId);
      }
      if (_activeOfferId == offerId) _destroyActiveOffer();
    }
  }

  void _destroyActiveOffer() {
    if (_activeOfferId == 0) return;
    _client.destroyOffer(_activeOfferId);
    _activeOfferId = 0;
    _activeMimeTypes = const <String>[];
    _activeData = null;
    _acceptedMime = null;
    _enterSerial = 0;
    _activeSurfaceId = 0;
    _negotiatedAction = DragAction.none;
    _pendingSourceActions = wlDndActionNone;
  }

  // -------------------------------------------------------------------------
  // Source
  // -------------------------------------------------------------------------

  /// Starts a drag carrying whatever [provider] produces for each MIME type.
  ///
  /// Returns false when the compositor refused - most often because there is
  /// no input serial, since Wayland only starts a drag from a real gesture.
  ///
  /// [DragAction.link] contributes no bit to the mask, for the reason
  /// [waylandDndActionBits] gives; a source that offers nothing else therefore
  /// advertises an empty action set, and no destination can complete a drop
  /// from it. That is the honest outcome of asking Wayland for a link.
  bool startDrag({
    required int originSurfaceId,
    required List<String> mimeTypes,
    required WaylandDragDataProvider provider,
    Set<DragAction> actions = const <DragAction>{DragAction.copy},
    int iconSurfaceId = 0,
  }) {
    if (!_client.supportsDragAndDrop || mimeTypes.isEmpty) return false;
    cancelDrag();
    int mask = wlDndActionNone;
    for (final DragAction action in actions) {
      mask |= waylandDndActionBits(action);
    }
    final int sourceId = _client.startDrag(
      originSurfaceId: originSurfaceId,
      iconSurfaceId: iconSurfaceId,
      mimeTypes: mimeTypes,
      actions: mask,
    );
    if (sourceId == 0) return false;
    _sourceId = sourceId;
    _sourceProvider = provider;
    _sourceMimeTypes = List<String>.unmodifiable(mimeTypes);
    _sourceAction = DragAction.none;
    _sourceDropPerformed = false;
    return true;
  }

  /// `wl_data_source.send`: the destination wants the bytes.
  ///
  /// The fd is always closed, whatever happens: leaving it open leaves the
  /// reader blocked forever, which looks to the user like the other
  /// application hung.
  void onSourceSend(int sourceId, String mimeType, int fd) {
    if (sourceId != _sourceId) {
      _client.sendDragData(fd, Uint8List(0));
      return;
    }
    final WaylandDragDataProvider? provider = _sourceProvider;
    final Uint8List? bytes =
        provider == null || !_sourceMimeTypes.contains(mimeType)
            ? null
            : provider(mimeType);
    _client.sendDragData(fd, bytes ?? Uint8List(0));
  }

  /// `wl_data_source.action`: the action the drop will perform.
  void onSourceAction(int sourceId, int action) {
    if (sourceId != _sourceId) return;
    _sourceAction = waylandDndActionFromBits(action);
  }

  /// `wl_data_source.dnd_drop_performed`: the user released the button. The
  /// data may still be being read, so the source is *not* torn down yet.
  void onSourceDropPerformed(int sourceId) {
    if (sourceId != _sourceId) return;
    _sourceDropPerformed = true;
  }

  /// `wl_data_source.dnd_finished`: the destination finished reading. A move
  /// may now delete the original.
  void onSourceFinished(int sourceId) {
    if (sourceId != _sourceId) return;
    _teardownSource();
  }

  /// `wl_data_source.cancelled`: the drag ended with no drop, or the
  /// selection was taken over.
  void onSourceCancelled(int sourceId) {
    if (sourceId != _sourceId) return;
    _sourceAction = DragAction.none;
    _teardownSource();
  }

  /// Abandons a drag this client started.
  void cancelDrag() {
    if (_sourceId == 0) return;
    _teardownSource();
  }

  void _teardownSource() {
    if (_sourceId == 0) return;
    _client.destroyDataSource(_sourceId);
    _sourceId = 0;
    _sourceProvider = null;
    _sourceMimeTypes = const <String>[];
    _sourceDropPerformed = false;
    onSourceDragEnded?.call(_sourceAction);
  }

  /// Drops every piece of state, for a connection going away.
  void dispose() {
    if (_pendingOfferId != 0 && _pendingOfferId != _activeOfferId) {
      _client.destroyOffer(_pendingOfferId);
      _pendingOfferId = 0;
    }
    _dropInFlight = false;
    _destroyActiveOffer();
    _teardownSource();
    handler = null;
  }
}
