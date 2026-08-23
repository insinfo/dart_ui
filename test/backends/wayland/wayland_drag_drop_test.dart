import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/wayland/wayland_drag_drop.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/platform/drag_drop.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

const String _textFormat = DragFormats.text;
const String _uriFormat = DragFormats.uriList;

/// Lets every microtask the drop path scheduled run.
///
/// `wl_data_device.drop` is answered synchronously by the manager and the
/// transfer that follows is not: the handler's future is what the offer's
/// lifetime now hangs on, so a test that asserts on `finish` or `destroy` has
/// to let that future settle first.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeDragClient client;
  late _RecordingHandler handler;
  late WaylandDragDropManager manager;

  setUp(() {
    client = _FakeDragClient();
    handler = _RecordingHandler();
    manager = WaylandDragDropManager(client)..handler = handler;
  });

  /// Plays the announcement the compositor always sends before `enter`.
  void announceOffer(
    int offerId, {
    List<String> mimes = const <String>[_textFormat],
    int sourceActions = wlDndActionCopy | wlDndActionMove,
  }) {
    manager.onDataOffer(offerId);
    for (final String mime in mimes) {
      manager.onOfferMime(offerId, mime);
    }
    manager.onOfferSourceActions(offerId, sourceActions);
  }

  void enter(
    int offerId, {
    int serial = 77,
    int surfaceId = 5,
    Offset position = const Offset(10, 20),
  }) {
    manager.onDragEnter(
      serial: serial,
      surfaceId: surfaceId,
      offerId: offerId,
      position: position,
    );
  }

  group('destination: entering', () {
    test('the handler sees the offered formats and the position', () {
      announceOffer(30, mimes: <String>[_uriFormat, _textFormat]);
      enter(30, surfaceId: 9, position: const Offset(3, 4));

      expect(handler.enters, hasLength(1));
      expect(handler.enters.single.windowId.value, 9);
      expect(handler.enters.single.position, const Offset(3, 4));
      expect(handler.enters.single.data.formats,
          <String>[_uriFormat, _textFormat]);
      expect(manager.activeOfferId, 30);
    });

    test('the position is surface-local and there is no screen position', () {
      announceOffer(30);
      enter(30, position: const Offset(3, 4));

      expect(handler.enters.single.position, const Offset(3, 4));
      expect(handler.enters.single.screenPosition, isNull,
          reason: 'a Wayland client is never told where its surfaces are on '
              'the desktop, and a guessed number would be indistinguishable '
              'from a real one');
    });

    test('accepting sends accept with the enter serial and set_actions', () {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      announceOffer(30);
      enter(30, serial: 99);

      expect(client.accepts.single.offerId, 30);
      expect(client.accepts.single.serial, 99);
      expect(client.accepts.single.mimeType, _textFormat);
      expect(client.actions.single.actions, wlDndActionCopy);
    });

    test('refusing sends a null MIME, which is how a refusal is spelled', () {
      handler.response = const DropResponse.reject();
      announceOffer(30);
      enter(30);

      expect(client.accepts.single.mimeType, isNull);
      expect(client.actions.single.actions, wlDndActionNone);
      expect(manager.negotiatedAction, DragAction.none);
    });

    test('a format the source never offered cannot be accepted', () {
      // Accepting a type the source cannot produce makes receive() hang.
      handler.response = const DropResponse(acceptedFormat: DragFormats.png);
      announceOffer(30, mimes: <String>[_textFormat]);
      enter(30);

      expect(client.accepts.single.mimeType, isNull);
    });

    test('an action the source cannot perform is masked out', () {
      handler.response = const DropResponse(
        acceptedFormat: _textFormat,
        action: DragAction.move,
      );
      announceOffer(30, sourceActions: wlDndActionCopy);
      enter(30);

      expect(client.actions.single.actions, wlDndActionNone,
          reason: 'asking for move when the source only offers copy is a '
              'protocol error in version 3');
    });

    test('a link is refused rather than downgraded to a copy', () {
      handler.response = const DropResponse(
        acceptedFormat: _textFormat,
        action: DragAction.link,
      );
      announceOffer(30, sourceActions: wlDndActionCopy | wlDndActionMove);
      enter(30);

      expect(client.actions.single.actions, wlDndActionNone,
          reason: 'wl_data_device_manager has no link action, and copying a '
              'file the user asked to reference is worse than refusing');
      expect(manager.negotiatedAction, DragAction.none);
    });

    test('an enter with no offer is ignored rather than half-tracked', () {
      enter(0);
      expect(manager.activeOfferId, 0);
      expect(handler.enters, isEmpty);
      expect(client.accepts, isEmpty);
    });

    test('with no handler installed the drag is refused', () {
      manager.handler = null;
      announceOffer(30);
      enter(30);

      expect(client.accepts.single.mimeType, isNull);
    });
  });

  group('destination: the window id', () {
    test('a manager with no resolver falls back to the surface id', () {
      announceOffer(30);
      enter(30, surfaceId: 12);
      expect(handler.enters.single.windowId, const NativeWindowId(12));
    });

    test('the installed resolver decides which window is entered', () {
      manager.windowIdForSurface =
          (int surfaceId) => NativeWindowId(surfaceId + 1000);
      announceOffer(30);
      enter(30, surfaceId: 12);

      expect(handler.enters.single.windowId, const NativeWindowId(1012),
          reason: 'surface ids and window ids are unrelated numbering spaces, '
              'so the backend resolves rather than the manager guessing');
    });
  });

  group('destination: the allowed actions', () {
    test('come from the source actions bitmask', () {
      announceOffer(30, sourceActions: wlDndActionCopy | wlDndActionMove);
      enter(30);

      expect(handler.enters.single.allowedActions,
          <DragAction>{DragAction.copy, DragAction.move});
      expect(handler.enters.single.suggestedAction, DragAction.copy,
          reason: 'copy is what an unmodified drag settles on');
    });

    test('a move-only source suggests a move', () {
      announceOffer(30, sourceActions: wlDndActionMove);
      enter(30);

      expect(handler.enters.single.allowedActions,
          <DragAction>{DragAction.move});
      expect(handler.enters.single.suggestedAction, DragAction.move);
    });

    test('never contain link, which Wayland has no word for', () {
      announceOffer(
        30,
        sourceActions: wlDndActionCopy | wlDndActionMove | wlDndActionAsk,
      );
      enter(30);

      expect(handler.enters.single.allowedActions,
          isNot(contains(DragAction.link)));
    });
  });

  group('destination: moving', () {
    test('a move that changes the answer re-accepts', () {
      handler.response = const DropResponse.reject();
      announceOffer(30);
      enter(30);
      handler.response = const DropResponse(acceptedFormat: _textFormat);

      manager.onDragMotion(const Offset(50, 60));

      expect(client.accepts, hasLength(2));
      expect(client.accepts.last.mimeType, _textFormat);
      expect(handler.moves.single.position, const Offset(50, 60));
    });

    test('a move with an unchanged answer does not re-accept', () {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      announceOffer(30);
      enter(30);
      final int accepts = client.accepts.length;

      manager.onDragMotion(const Offset(1, 1));
      manager.onDragMotion(const Offset(2, 2));

      expect(client.accepts, hasLength(accepts),
          reason: 'accept is state, and motion arrives at pointer rate');
    });

    test('motion outside a drag is ignored', () {
      manager.onDragMotion(const Offset(1, 1));
      expect(handler.moves, isEmpty);
    });

    test('the session data is the same instance from enter to move', () {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      announceOffer(30);
      enter(30);
      manager.onDragMotion(const Offset(1, 1));

      expect(
        identical(handler.moves.single.data, handler.enters.single.data),
        isTrue,
        reason: 'a target may hold the data from enter to drop, and the read '
            'cache lives in it',
      );
    });
  });

  group('destination: the negotiated action', () {
    test('is reported from the compositor answer', () {
      handler.response = const DropResponse(
        acceptedFormat: _textFormat,
        action: DragAction.move,
      );
      announceOffer(30);
      enter(30);

      manager.onOfferAction(30, wlDndActionMove);

      expect(manager.negotiatedAction, DragAction.move);
    });

    test('an action for a stale offer is ignored', () {
      announceOffer(30);
      enter(30);
      manager.onOfferAction(999, wlDndActionMove);
      expect(manager.negotiatedAction, DragAction.none);
    });
  });

  group('destination: leaving', () {
    test('tells the handler and destroys the offer', () {
      announceOffer(30);
      enter(30);

      manager.onDragLeave();

      expect(handler.leaves, 1);
      expect(client.destroyedOffers, <int>[30]);
      expect(manager.activeOfferId, 0);
    });

    test('a leave with no drag in flight does nothing', () {
      manager.onDragLeave();
      expect(handler.leaves, 0);
      expect(client.destroyedOffers, isEmpty);
    });
  });

  group('destination: dropping', () {
    test('reads the accepted format and finishes the offer', () async {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      client.data[_textFormat] = Uint8List.fromList(<int>[104, 105]);
      announceOffer(30);
      enter(30);

      manager.onDrop();
      expect(handler.drops, hasLength(1));
      await settle();

      expect(handler.readBytes.single, <int>[104, 105]);
      expect(client.receives.single.mimeType, _textFormat);
      expect(client.finishedOffers, <int>[30],
          reason: 'without finish() a move can never complete');
      expect(client.destroyedOffers, <int>[30]);
      expect(manager.activeOfferId, 0);
    });

    test('the drop is reported at the last position the pointer was at',
        () async {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      client.data[_textFormat] = Uint8List.fromList(<int>[1]);
      announceOffer(30);
      enter(30, position: const Offset(3, 4));
      manager.onDragMotion(const Offset(50, 60));

      manager.onDrop();
      await settle();

      expect(handler.drops.single.position, const Offset(50, 60),
          reason: 'wl_data_device.drop carries no coordinates of its own');
    });

    test('a drop on a target that refused reads nothing', () {
      handler.response = const DropResponse.reject();
      announceOffer(30);
      enter(30);

      manager.onDrop();

      expect(handler.drops, isEmpty);
      expect(client.receives, isEmpty);
      expect(client.destroyedOffers, <int>[30],
          reason: 'the source must not be left waiting');
    });

    test('a failed transfer does not finish the offer but still cleans up',
        () async {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      // No data registered: the pipe yields null.
      announceOffer(30);
      enter(30);

      manager.onDrop();
      await settle();

      expect(handler.readBytes.single, isNull);
      expect(client.finishedOffers, isEmpty);
      expect(client.destroyedOffers, <int>[30]);
    });

    test('a drop the handler reports it did not perform is not finished',
        () async {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      handler.dropResult = DragAction.none;
      client.data[_textFormat] = Uint8List.fromList(<int>[1]);
      announceOffer(30);
      enter(30);

      manager.onDrop();
      await settle();

      expect(handler.readBytes.single, <int>[1],
          reason: 'the bytes arrived; the target simply did nothing with them');
      expect(client.finishedOffers, isEmpty,
          reason: 'finish() claims a completed transfer, which would let a '
              'move delete an original nobody kept');
      expect(client.destroyedOffers, <int>[30]);
    });

    test('the offer survives until the drop completes', () async {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      client.data[_textFormat] = Uint8List.fromList(<int>[1]);
      final Completer<void> gate = Completer<void>();
      handler.gate = gate;
      announceOffer(30);
      enter(30);
      manager.onDrop();

      // A leave arriving while the pipe is still being read must not pull the
      // offer out from under it.
      manager.onDragLeave();
      expect(client.destroyedOffers, isEmpty);
      await settle();
      expect(client.destroyedOffers, isEmpty,
          reason: 'the handler has not finished with the data yet');

      gate.complete();
      await settle();
      expect(client.destroyedOffers, <int>[30]);
      expect(client.finishedOffers, <int>[30]);
    });

    test('a drop with no drag in flight is ignored', () {
      manager.onDrop();
      expect(handler.drops, isEmpty);
    });

    test('a drop with no handler retires the offer instead of hanging', () {
      handler.response = const DropResponse(acceptedFormat: _textFormat);
      announceOffer(30);
      enter(30);
      manager.handler = null;

      manager.onDrop();

      expect(client.destroyedOffers, <int>[30]);
      expect(client.finishedOffers, isEmpty);
    });
  });

  group('destination: the offer as DragData', () {
    test('preferredFormat follows the caller order, not the source order', () {
      announceOffer(30, mimes: <String>[_textFormat, _uriFormat]);
      enter(30);
      final DragData data = handler.enters.single.data;

      expect(data.preferredFormat(<String>[_uriFormat, _textFormat]),
          _uriFormat);
      expect(data.preferredFormat(<String>[_textFormat, _uriFormat]),
          _textFormat);
    });

    test('a format nobody offers is null', () {
      announceOffer(30, mimes: <String>[_textFormat]);
      enter(30);
      final DragData data = handler.enters.single.data;

      expect(data.preferredFormat(<String>[DragFormats.png]), isNull);
      expect(data.hasFormat(_textFormat), isTrue);
    });

    test('a format the source never offered is never received', () async {
      announceOffer(30, mimes: <String>[_textFormat]);
      enter(30);

      expect(await handler.enters.single.data.readBytes(DragFormats.png),
          isNull);
      expect(client.receives, isEmpty,
          reason: 'receiving a type the source cannot produce hangs forever');
    });

    test('a second read answers from the cache, not from a consumed pipe',
        () async {
      client.data[_textFormat] = Uint8List.fromList(<int>[9]);
      announceOffer(30);
      enter(30);
      final DragData data = handler.enters.single.data;

      expect(await data.readBytes(_textFormat), <int>[9]);
      expect(await data.readBytes(_textFormat), <int>[9]);
      expect(client.receives, hasLength(1),
          reason: 'the transfer consumed the offer; asking again would hang');
    });
  });

  group('destination: offer bookkeeping', () {
    test('an offer superseded before enter is destroyed, not leaked', () {
      manager.onDataOffer(30);
      manager.onOfferMime(30, _textFormat);
      manager.onDataOffer(31);

      expect(client.destroyedOffers, <int>[30]);
    });

    test('formats for a stale offer are not attributed to the live one', () {
      announceOffer(30, mimes: <String>[_textFormat]);
      manager.onOfferMime(999, _uriFormat);
      enter(30);

      expect(handler.enters.single.data.formats, <String>[_textFormat]);
    });

    test('dispose releases the active offer and the handler', () {
      announceOffer(30);
      enter(30);

      manager.dispose();

      expect(client.destroyedOffers, <int>[30]);
      expect(manager.activeOfferId, 0);
    });
  });

  group('source', () {
    test('starting a drag offers every format and the action mask', () {
      final bool started = manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_uriFormat, _textFormat],
        provider: (_) => null,
        actions: <DragAction>{DragAction.copy, DragAction.move},
      );

      expect(started, isTrue);
      expect(manager.isDragging, isTrue);
      final _Drag drag = client.drags.single;
      expect(drag.originSurfaceId, 5);
      expect(drag.mimeTypes, <String>[_uriFormat, _textFormat]);
      expect(drag.actions, wlDndActionCopy | wlDndActionMove);
      expect(drag.iconSurfaceId, 0);
    });

    test('a link contributes no bit to the action mask', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
        actions: <DragAction>{DragAction.copy, DragAction.link},
      );

      expect(client.drags.single.actions, wlDndActionCopy,
          reason: 'there is no link bit, and inventing one would be a '
              'protocol error rather than a feature');
    });

    test('a drag icon surface is passed through', () {
      manager.startDrag(
        originSurfaceId: 5,
        iconSurfaceId: 77,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      expect(client.drags.single.iconSurfaceId, 77);
    });

    test('a compositor without a data device cannot start one', () {
      client.supported = false;
      final bool started = manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      expect(started, isFalse);
      expect(manager.isDragging, isFalse);
      expect(manager.supportsDragAndDrop, isFalse);
    });

    test('a refused start leaves no dangling source', () {
      client.startDragResult = 0;
      final bool started = manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      expect(started, isFalse);
      expect(manager.isDragging, isFalse);
    });

    test('an empty format list is refused', () {
      expect(
        manager.startDrag(
          originSurfaceId: 5,
          mimeTypes: const <String>[],
          provider: (_) => null,
        ),
        isFalse,
      );
    });

    test('send hands over the provider bytes and closes the fd', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (String mime) =>
            mime == _textFormat ? Uint8List.fromList(<int>[7, 8]) : null,
      );

      manager.onSourceSend(client.drags.single.sourceId, _textFormat, 42);

      expect(client.sends.single.fd, 42);
      expect(client.sends.single.bytes, <int>[7, 8]);
    });

    test('a send for a format never offered writes nothing but still closes',
        () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => Uint8List.fromList(<int>[1]),
      );

      manager.onSourceSend(client.drags.single.sourceId, DragFormats.png, 42);

      expect(client.sends.single.bytes, isEmpty,
          reason: 'leaving the fd unwritten would hang the reader');
    });

    test('a send for a stale source is answered with an empty pipe', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => Uint8List.fromList(<int>[1]),
      );

      manager.onSourceSend(4242, _textFormat, 42);

      expect(client.sends.single.bytes, isEmpty);
    });

    test('the negotiated action reaches the source', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      manager.onSourceAction(client.drags.single.sourceId, wlDndActionMove);
      expect(manager.sourceAction, DragAction.move);
    });

    test('drop_performed does not tear the source down', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );

      manager.onSourceDropPerformed(client.drags.single.sourceId);

      expect(manager.sourceDropPerformed, isTrue);
      expect(manager.isDragging, isTrue,
          reason: 'the destination may still be reading the pipe');
      expect(client.destroyedSources, isEmpty);
    });

    test('dnd_finished ends the drag and destroys the source', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      final int sourceId = client.drags.single.sourceId;

      manager.onSourceDropPerformed(sourceId);
      manager.onSourceFinished(sourceId);

      expect(manager.isDragging, isFalse);
      expect(client.destroyedSources, <int>[sourceId]);
    });

    test('cancelled ends the drag with no action', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      final int sourceId = client.drags.single.sourceId;
      manager.onSourceAction(sourceId, wlDndActionCopy);

      manager.onSourceCancelled(sourceId);

      expect(manager.isDragging, isFalse);
      expect(manager.sourceAction, DragAction.none);
      expect(client.destroyedSources, <int>[sourceId]);
    });

    test('events for a source that is not ours are ignored', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );

      manager.onSourceCancelled(4242);
      manager.onSourceFinished(4242);

      expect(manager.isDragging, isTrue);
      expect(client.destroyedSources, isEmpty);
    });

    test('starting a second drag replaces the first', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      final int first = client.drags.single.sourceId;

      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_uriFormat],
        provider: (_) => null,
      );

      expect(client.destroyedSources, <int>[first]);
      expect(manager.isDragging, isTrue);
    });

    test('cancelDrag tears down an in-flight drag', () {
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      manager.cancelDrag();
      expect(manager.isDragging, isFalse);
      expect(client.destroyedSources, hasLength(1));
    });

    test('the end of a drag is reported once, with what was performed', () {
      final List<DragAction> ended = <DragAction>[];
      manager.onSourceDragEnded = ended.add;
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      final int sourceId = client.drags.single.sourceId;

      manager.onSourceAction(sourceId, wlDndActionMove);
      manager.onSourceDropPerformed(sourceId);
      manager.onSourceFinished(sourceId);
      // A second finish for the same, now dead, source must not report again.
      manager.onSourceFinished(sourceId);

      expect(ended, <DragAction>[DragAction.move]);
    });

    test('a cancelled drag ends with none', () {
      final List<DragAction> ended = <DragAction>[];
      manager.onSourceDragEnded = ended.add;
      manager.startDrag(
        originSurfaceId: 5,
        mimeTypes: <String>[_textFormat],
        provider: (_) => null,
      );
      final int sourceId = client.drags.single.sourceId;
      manager.onSourceAction(sourceId, wlDndActionCopy);

      manager.onSourceCancelled(sourceId);

      expect(ended, <DragAction>[DragAction.none]);
    });
  });

  group('action bit translation', () {
    test('each action maps to its own bit and back', () {
      expect(waylandDndActionBits(DragAction.copy), wlDndActionCopy);
      expect(waylandDndActionBits(DragAction.move), wlDndActionMove);
      expect(waylandDndActionBits(DragAction.ask), wlDndActionAsk);
      expect(waylandDndActionBits(DragAction.none), wlDndActionNone);

      expect(waylandDndActionFromBits(wlDndActionMove), DragAction.move);
      expect(waylandDndActionFromBits(wlDndActionNone), DragAction.none);
    });

    test('link maps to none, not to copy', () {
      expect(waylandDndActionBits(DragAction.link), wlDndActionNone,
          reason: 'wl_data_device_manager has no link action, and both '
              'substitutes destroy something the user meant to keep');
    });

    test('copy wins when several bits are set, as an unmodified drag does',
        () {
      expect(
        waylandDndActionFromBits(wlDndActionCopy | wlDndActionMove),
        DragAction.copy,
      );
    });
  });

  group('action set translation', () {
    test('every bit set becomes its action', () {
      expect(
        waylandDndActionSet(wlDndActionCopy | wlDndActionMove),
        <DragAction>{DragAction.copy, DragAction.move},
      );
      expect(waylandDndActionSet(wlDndActionAsk), <DragAction>{DragAction.ask});
    });

    test('an empty mask means unknown, and answers copy', () {
      expect(waylandDndActionSet(wlDndActionNone),
          <DragAction>{DragAction.copy},
          reason: 'source_actions arrived in version 3 and a version 2 source '
              'never sends it; an empty set would refuse every such drag');
    });

    test('never names link', () {
      expect(
        waylandDndActionSet(wlDndActionCopy | wlDndActionMove | wlDndActionAsk),
        isNot(contains(DragAction.link)),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final class _Accept {
  _Accept(this.offerId, this.serial, this.mimeType);
  final int offerId;
  final int serial;
  final String? mimeType;
}

final class _Actions {
  _Actions(this.offerId, this.actions, this.preferred);
  final int offerId;
  final int actions;
  final int preferred;
}

final class _Receive {
  _Receive(this.offerId, this.mimeType);
  final int offerId;
  final String mimeType;
}

final class _Drag {
  _Drag({
    required this.sourceId,
    required this.originSurfaceId,
    required this.iconSurfaceId,
    required this.mimeTypes,
    required this.actions,
  });
  final int sourceId;
  final int originSurfaceId;
  final int iconSurfaceId;
  final List<String> mimeTypes;
  final int actions;
}

final class _Send {
  _Send(this.fd, this.bytes);
  final int fd;
  final Uint8List bytes;
}

final class _FakeDragClient implements WaylandDragDropClient {
  bool supported = true;
  int startDragResult = -1;
  int _nextSourceId = 700;

  final Map<String, Uint8List> data = <String, Uint8List>{};
  final List<_Accept> accepts = <_Accept>[];
  final List<_Actions> actions = <_Actions>[];
  final List<_Receive> receives = <_Receive>[];
  final List<int> finishedOffers = <int>[];
  final List<int> destroyedOffers = <int>[];
  final List<_Drag> drags = <_Drag>[];
  final List<_Send> sends = <_Send>[];
  final List<int> destroyedSources = <int>[];

  @override
  bool get supportsDragAndDrop => supported;

  @override
  void acceptOffer(int offerId, int serial, String? mimeType) =>
      accepts.add(_Accept(offerId, serial, mimeType));

  @override
  void setOfferActions(int offerId, int a, int preferred) =>
      actions.add(_Actions(offerId, a, preferred));

  @override
  Future<Uint8List?> receiveOffer(int offerId, String mimeType) async {
    receives.add(_Receive(offerId, mimeType));
    return data[mimeType];
  }

  @override
  void finishOffer(int offerId) => finishedOffers.add(offerId);

  @override
  void destroyOffer(int offerId) => destroyedOffers.add(offerId);

  @override
  int startDrag({
    required int originSurfaceId,
    required int iconSurfaceId,
    required List<String> mimeTypes,
    required int actions,
  }) {
    if (startDragResult == 0) return 0;
    final int sourceId = _nextSourceId++;
    drags.add(_Drag(
      sourceId: sourceId,
      originSurfaceId: originSurfaceId,
      iconSurfaceId: iconSurfaceId,
      mimeTypes: mimeTypes,
      actions: actions,
    ));
    return sourceId;
  }

  @override
  bool sendDragData(int fd, Uint8List bytes) {
    sends.add(_Send(fd, bytes));
    return true;
  }

  @override
  void destroyDataSource(int sourceId) => destroyedSources.add(sourceId);
}

/// A [DropTargetHandler] that records the sessions it saw and reads the format
/// a test tells it to when a drop arrives.
final class _RecordingHandler implements DropTargetHandler {
  DropResponse response = const DropResponse.reject();

  /// The format [onDrop] transfers, or null to accept a drop and read nothing.
  String? readFormat = _textFormat;

  /// What [onDrop] reports it actually performed.
  DragAction dropResult = DragAction.copy;

  /// Held open by a test that wants to assert on the state *during* a drop.
  Completer<void>? gate;

  final List<DragSessionEvent> enters = <DragSessionEvent>[];
  final List<DragSessionEvent> moves = <DragSessionEvent>[];
  final List<DragSessionEvent> drops = <DragSessionEvent>[];
  final List<Uint8List?> readBytes = <Uint8List?>[];
  int leaves = 0;

  @override
  DropResponse onDragEnter(DragSessionEvent event) {
    enters.add(event);
    return response;
  }

  @override
  DropResponse onDragOver(DragSessionEvent event) {
    moves.add(event);
    return response;
  }

  @override
  void onDragLeave() => leaves++;

  @override
  Future<DragAction> onDrop(DragSessionEvent event) async {
    drops.add(event);
    final String? format = readFormat;
    if (format != null) readBytes.add(await event.data.readBytes(format));
    final Completer<void>? gate = this.gate;
    if (gate != null) await gate.future;
    return dropResult;
  }
}
