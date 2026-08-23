import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/x11/x11_drag_drop.dart';
import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_libc.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/drag_drop.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

const String _textMime = 'text/plain;charset=utf-8';
const String _uriMime = 'text/uri-list';
const String _pngMime = 'image/png';
const String _privateMime = 'application/x-dart-ui-test';

/// Our window, the source's window, and the framework id they map to.
const int _ourWindow = 0x0a00001;
const int _sourceWindow = 0x0b00002;
const NativeWindowId _ourWindowId = NativeWindowId(7);

/// The scale and origin the injected converter pretends the window has: the
/// client area starts at root 100,50 device pixels and there are two device
/// pixels per logical unit.
const int _originX = 100;
const int _originY = 50;
const double _scale = 2;

void main() {
  late _FakeDragDropClient client;
  late _RecordingHandler handler;
  late X11DragDropManager manager;

  setUp(() {
    client = _FakeDragDropClient();
    handler = _RecordingHandler();
    manager = X11DragDropManager(
      client,
      rootToClient: (int window, int rootX, int rootY) => Offset(
        (rootX - _originX) / _scale,
        (rootY - _originY) / _scale,
      ),
      scaleOf: (int window) => _scale,
      transferTimeout: const Duration(milliseconds: 20),
    )..handler = handler;
    manager.registerWindow(_ourWindow, _ourWindowId);
    client.messages.clear();
    client.properties.clear();
    client.flushes = 0;
  });

  // -------------------------------------------------------------------------
  // Driving the protocol
  // -------------------------------------------------------------------------

  bool enter({
    int window = _ourWindow,
    int source = _sourceWindow,
    int version = xdndVersion,
    List<String> types = const <String>[_textMime],
    bool moreTypes = false,
  }) {
    if (moreTypes) {
      client.putCardinals(
        source,
        client.atom('XdndTypeList'),
        <int>[for (final String type in types) client.atom(type)],
      );
    }
    final List<int> inline = <int>[
      for (var index = 0; index < 3; index++)
        index < types.length && !moreTypes ? client.atom(types[index]) : xcbNone,
    ];
    return manager.handleClientMessage(
      window: window,
      messageType: client.atom('XdndEnter'),
      format: xdndClientMessageFormat,
      data0: source,
      data1: (version << xdndEnterVersionShift) |
          (moreTypes ? xdndEnterMoreTypesBit : 0),
      data2: inline[0],
      data3: inline[1],
      data4: inline[2],
    );
  }

  bool position({
    int window = _ourWindow,
    int source = _sourceWindow,
    int rootX = 140,
    int rootY = 90,
    int time = 4321,
    DragAction action = DragAction.copy,
  }) {
    return manager.handleClientMessage(
      window: window,
      messageType: client.atom('XdndPosition'),
      format: xdndClientMessageFormat,
      data0: source,
      data1: 0,
      data2: ((rootX & 0xffff) << 16) | (rootY & 0xffff),
      data3: time,
      data4: client.actionAtom(action),
    );
  }

  bool leave({int window = _ourWindow, int source = _sourceWindow}) {
    return manager.handleClientMessage(
      window: window,
      messageType: client.atom('XdndLeave'),
      format: xdndClientMessageFormat,
      data0: source,
      data1: 0,
      data2: 0,
      data3: 0,
      data4: 0,
    );
  }

  bool drop({
    int window = _ourWindow,
    int source = _sourceWindow,
    int time = 9999,
  }) {
    return manager.handleClientMessage(
      window: window,
      messageType: client.atom('XdndDrop'),
      format: xdndClientMessageFormat,
      data0: source,
      data1: 0,
      data2: time,
      data3: 0,
      data4: 0,
    );
  }

  /// Plays the `SelectionNotify` the server sends once the source has written
  /// the payload into our property.
  bool answerConversion(List<int> payload, {int? type}) {
    final _Conversion conversion = client.conversions.last;
    client.putBytes(
      conversion.requestor,
      conversion.property,
      X11PropertyValue(
        type: type ?? conversion.target,
        format: 8,
        bytes: Uint8List.fromList(payload),
      ),
    );
    return manager.handleSelectionNotify(
      requestor: conversion.requestor,
      selection: conversion.selection,
      target: conversion.target,
      property: conversion.property,
    );
  }

  /// Lets the microtasks a drop handler is suspended on run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  // -------------------------------------------------------------------------

  group('registration', () {
    test('advertises XdndAware as one ATOM word holding the version', () {
      final _FakeDragDropClient fresh = _FakeDragDropClient();
      X11DragDropManager(
        fresh,
        rootToClient: (int w, int x, int y) => Offset.zero,
      ).registerWindow(_ourWindow, _ourWindowId);

      final _PropertyWrite write = fresh.propertyWrites.single;
      expect(write.window, _ourWindow);
      expect(write.property, fresh.atom('XdndAware'));
      expect(write.type, xcbAtomAtom);
      expect(write.values, <int>[xdndVersion]);
      expect(fresh.flushes, 1,
          reason: 'a source can only find a target the server already knows '
              'about');
    });

    test('unregistering deletes the property and stops consuming events', () {
      manager.unregisterWindow(_ourWindow);

      expect(client.deletedProperties.single.property, client.atom('XdndAware'));
      expect(manager.isRegistered(_ourWindow), isFalse);
      expect(enter(), isFalse);
      expect(handler.enters, isEmpty);
    });

    test('unregistering a window that was never registered does nothing', () {
      manager.unregisterWindow(0x777);
      expect(client.deletedProperties, isEmpty);
    });

    test('a message for another window is not consumed', () {
      expect(enter(window: 0x999), isFalse);
      expect(manager.hasActiveSession, isFalse);
    });

    test('a ClientMessage of another format is not XDND', () {
      expect(
        manager.handleClientMessage(
          window: _ourWindow,
          messageType: client.atom('XdndEnter'),
          format: 8,
          data0: _sourceWindow,
          data1: xdndVersion << xdndEnterVersionShift,
          data2: client.atom(_textMime),
          data3: 0,
          data4: 0,
        ),
        isFalse,
      );
    });
  });

  group('entering', () {
    test('takes the three inline types, in the order they were offered', () {
      expect(enter(types: <String>[_uriMime, _textMime]), isTrue);

      expect(manager.hasActiveSession, isTrue);
      expect(manager.sourceWindow, _sourceWindow);
      expect(manager.targetWindow, _ourWindow);
      expect(manager.offeredFormats, <String>[_uriMime, _textMime]);
      expect(client.messages, isEmpty,
          reason: 'XdndEnter has no reply; the source is waiting to send a '
              'position');
      expect(handler.enters, isEmpty,
          reason: 'XdndEnter carries no position, so there is nothing to '
              'hit-test an enter against yet');
    });

    test('reads XdndTypeList when more than three types are offered', () {
      expect(
        enter(
          types: <String>[_uriMime, _textMime, _pngMime, _privateMime],
          moreTypes: true,
        ),
        isTrue,
      );

      expect(
        manager.offeredFormats,
        <String>[_uriMime, _textMime, _pngMime, _privateMime],
      );
    });

    test('a type this connection cannot name is skipped, not guessed at', () {
      final int unknown = client.atom(_pngMime);
      client.forgetAtomName(unknown);

      enter(types: <String>[_uriMime, _pngMime]);

      expect(manager.offeredFormats, <String>[_uriMime]);
    });

    test('an enter offering nothing nameable starts no session', () {
      final int unknown = client.atom(_pngMime);
      client.forgetAtomName(unknown);

      expect(enter(types: <String>[_pngMime]), isTrue);

      expect(manager.hasActiveSession, isFalse);
      expect(client.errors.single, contains('advertised no type'));
    });

    test('a source below version 3 is refused rather than misread', () {
      expect(enter(version: 2), isTrue);

      expect(manager.hasActiveSession, isFalse);
      expect(client.errors.single, contains('protocol version 2'));
    });

    test('the negotiated version is the lower of the two', () {
      enter(version: 3);
      expect(manager.negotiatedVersion, 3);

      enter(version: 7);
      expect(manager.negotiatedVersion, xdndVersion,
          reason: 'a source claiming a version we do not know is answered in '
              'the one we do');
    });

    test('a second enter ends the first session with a leave', () {
      enter();
      position();
      expect(handler.enters, hasLength(1));

      enter(source: 0x0c00003);

      expect(handler.leaves, 1);
      expect(manager.sourceWindow, 0x0c00003);
    });
  });

  group('position and status', () {
    test('the first position is an enter and every later one is an over', () {
      handler.response = const DropResponse(acceptedFormat: _textMime);
      enter();

      position(rootX: 140, rootY: 90);
      position(rootX: 160, rootY: 110);

      expect(handler.enters, hasLength(1));
      expect(handler.overs, hasLength(1));
      expect(handler.enters.single.windowId, _ourWindowId);
      expect(handler.enters.single.data.formats, <String>[_textMime]);
    });

    test('accepting answers with the accept bit, a rectangle and the action',
        () {
      handler.response = const DropResponse(
        acceptedFormat: _textMime,
        action: DragAction.move,
      );
      enter();

      position(rootX: 140, rootY: 90, action: DragAction.move);

      final _ClientMessage status = client.messages.single;
      expect(status.type, client.atom('XdndStatus'));
      expect(status.destination, _sourceWindow);
      expect(status.window, _sourceWindow,
          reason: 'a message a destination sends names its recipient in the '
              'window field');
      expect(status.data[0], _ourWindow);
      expect(status.data[1] & xdndStatusAcceptBit, xdndStatusAcceptBit);
      expect(status.data[1] & xdndStatusWantPositionBit, 0);
      expect(status.data[2], (140 << 16) | 90);
      expect(status.data[3], (1 << 16) | 1,
          reason: 'an answer that can change per pixel must be asked per pixel');
      expect(status.data[4], client.atom('XdndActionMove'));
      expect(manager.acceptedFormat, _textMime);
      expect(manager.acceptedAction, DragAction.move);
    });

    test('refusing clears the accept bit and names no action', () {
      handler.response = const DropResponse.reject();
      enter();

      position();

      final _ClientMessage status = client.messages.single;
      expect(status.data[1] & xdndStatusAcceptBit, 0);
      expect(status.data[4], xcbNone);
      expect(manager.acceptedFormat, isNull);
    });

    test('a type the source never advertised cannot be accepted', () {
      // Accepting one makes the ConvertSelection after the drop go unanswered
      // forever, which hangs the drop instead of failing it.
      handler.response = const DropResponse(acceptedFormat: _pngMime);
      enter(types: <String>[_textMime]);

      position();

      expect(client.messages.single.data[1] & xdndStatusAcceptBit, 0);
      expect(manager.acceptedFormat, isNull);
    });

    test('an action outside XdndActionList is a refusal, not a substitution',
        () {
      client.putCardinals(
        _sourceWindow,
        client.atom('XdndActionList'),
        <int>[client.atom('XdndActionCopy')],
      );
      handler.response = const DropResponse(
        acceptedFormat: _textMime,
        action: DragAction.move,
      );
      enter();

      position();

      expect(client.messages.single.data[1] & xdndStatusAcceptBit, 0,
          reason: 'substituting copy for a requested move loses the file');
      expect(handler.enters.single.allowedActions, <DragAction>{
        DragAction.copy,
      });
    });

    test('without XdndActionList the position action is the whole offer', () {
      handler.response = const DropResponse(acceptedFormat: _textMime);
      enter();

      position(action: DragAction.link);

      expect(handler.enters.single.allowedActions, <DragAction>{
        DragAction.link,
      });
      expect(handler.enters.single.suggestedAction, DragAction.link);
    });

    test('a position with no session is still answered', () {
      // A source that gets no status stops sending them, and the drag freezes
      // over our window - which reads as this application hanging.
      expect(position(), isTrue);

      final _ClientMessage status = client.messages.single;
      expect(status.type, client.atom('XdndStatus'));
      expect(status.data[1] & xdndStatusAcceptBit, 0);
      expect(handler.enters, isEmpty);
    });

    test('a position from another source is answered but not tracked', () {
      enter();
      position(source: 0x0c00003);

      expect(client.messages.single.data[1] & xdndStatusAcceptBit, 0);
      expect(handler.enters, isEmpty);
    });

    test('with no handler installed the drag is refused', () {
      manager.handler = null;
      enter();

      position();

      expect(client.messages.single.data[1] & xdndStatusAcceptBit, 0);
    });
  });

  group('leaving', () {
    test('tells the handler once and drops the session', () {
      handler.response = const DropResponse(acceptedFormat: _textMime);
      enter();
      position();

      expect(leave(), isTrue);

      expect(handler.leaves, 1);
      expect(manager.hasActiveSession, isFalse);
    });

    test('a leave before any position owes no callback', () {
      enter();

      leave();

      expect(handler.leaves, 0);
      expect(manager.hasActiveSession, isFalse);
    });

    test('a leave with no drag in flight does nothing', () {
      leave();
      expect(handler.leaves, 0);
    });
  });

  group('dropping', () {
    setUp(() {
      handler
        ..response = const DropResponse(acceptedFormat: _textMime)
        ..readFormat = _textMime;
    });

    test('converts the selection with the drop timestamp and finishes',
        () async {
      enter();
      position();
      client.messages.clear();

      expect(drop(time: 555), isTrue);

      final _Conversion conversion = client.conversions.single;
      expect(conversion.requestor, _ourWindow);
      expect(conversion.selection, client.atom('XdndSelection'));
      expect(conversion.target, client.atom(_textMime));
      expect(conversion.property, client.atom(xdndDropProperty));
      expect(conversion.time, 555,
          reason: 'CurrentTime would resolve the owner as of now, not as of '
              'the button release');
      expect(manager.isTransferPending, isTrue);

      answerConversion(<int>[104, 105]);
      await settle();

      expect(handler.droppedBytes, <int>[104, 105]);
      final _ClientMessage finished = client.messages.single;
      expect(finished.type, client.atom('XdndFinished'));
      expect(finished.data[0], _ourWindow);
      expect(finished.data[1] & xdndFinishedAcceptedBit,
          xdndFinishedAcceptedBit);
      expect(finished.data[2], client.atom('XdndActionCopy'));
      expect(manager.hasActiveSession, isFalse);
      expect(manager.isTransferPending, isFalse);
    });

    test('the property is read with delete, which is how the source is told',
        () async {
      enter();
      position();
      drop();
      answerConversion(<int>[1]);
      await settle();

      expect(client.reads.single.delete, isTrue);
      expect(client.reads.single.type, xcbGetPropertyTypeAny,
          reason: 'naming a type the owner did not use reads back empty, '
              'which is indistinguishable from an empty payload');
    });

    test('a refused drop finishes with the accept bit clear and leaves',
        () async {
      handler.response = const DropResponse.reject();
      enter();
      position();
      client.messages.clear();

      expect(drop(), isTrue);
      await settle();

      expect(client.conversions, isEmpty);
      final _ClientMessage finished = client.messages.single;
      expect(finished.type, client.atom('XdndFinished'));
      expect(finished.data[1] & xdndFinishedAcceptedBit, 0);
      expect(finished.data[2], xcbNone);
      expect(handler.leaves, 1);
      expect(handler.drops, isEmpty);
      expect(manager.hasActiveSession, isFalse);
    });

    test('a drop with no session is still finished', () {
      expect(drop(), isTrue);

      final _ClientMessage finished = client.messages.single;
      expect(finished.type, client.atom('XdndFinished'));
      expect(finished.data[1] & xdndFinishedAcceptedBit, 0);
    });

    test('a handler that performs nothing reports an unaccepted finish',
        () async {
      handler
        ..readFormat = null
        ..dropAction = DragAction.none;
      enter();
      position();
      client.messages.clear();

      drop();
      await settle();

      expect(client.messages.single.data[1] & xdndFinishedAcceptedBit, 0);
    });

    test('XdndFinished is sent exactly once, however the drop is repeated',
        () async {
      enter();
      position();
      client.messages.clear();

      drop();
      answerConversion(<int>[7]);
      await settle();
      // A source that never saw the first finish and drops again finds no
      // session, and gets exactly one more answer - not a second for the
      // session that already ended.
      final int afterFirst = client.messages.length;
      expect(afterFirst, 1);

      drop();
      expect(client.messages, hasLength(2));
      expect(
        client.messages
            .where((_ClientMessage each) =>
                each.type == client.atom('XdndFinished'))
            .length,
        2,
      );
    });

    test('an owner that refuses the conversion completes the read with null',
        () async {
      enter();
      position();
      drop();

      final _Conversion conversion = client.conversions.single;
      expect(
        manager.handleSelectionNotify(
          requestor: conversion.requestor,
          selection: conversion.selection,
          target: conversion.target,
          property: xcbNone,
        ),
        isTrue,
      );
      await settle();

      expect(handler.droppedBytes, isNull);
      expect(client.errors.single, contains('refused to convert'));
    });

    test('an INCR reply is a named failure, not four bytes of payload',
        () async {
      enter();
      position();
      drop();

      answerConversion(<int>[0, 0, 1, 0], type: client.atom('INCR'));
      await settle();

      expect(handler.droppedBytes, isNull);
      expect(client.errors.single, contains('INCR'));
      expect(client.messages.last.data[1] & xdndFinishedAcceptedBit, 0,
          reason: 'a transfer that produced nothing did not perform the move');
    });

    test('a SelectionNotify for another transfer is not consumed', () {
      enter();
      position();
      drop();

      expect(
        manager.handleSelectionNotify(
          requestor: 0x999,
          selection: client.atom('XdndSelection'),
          target: client.atom(_textMime),
          property: client.atom(xdndDropProperty),
        ),
        isFalse,
      );
      expect(manager.isTransferPending, isTrue);
    });

    test('a SelectionNotify with no transfer pending is not consumed', () {
      expect(
        manager.handleSelectionNotify(
          requestor: _ourWindow,
          selection: client.atom('XdndSelection'),
          target: client.atom(_textMime),
          property: client.atom(xdndDropProperty),
        ),
        isFalse,
      );
    });

    test('a leave mid-transfer does not pull the property out from under it',
        () async {
      enter();
      position();
      drop();
      expect(manager.isTransferPending, isTrue);

      leave();
      expect(manager.isTransferPending, isTrue);
      expect(manager.targetWindow, _ourWindow);

      answerConversion(<int>[3]);
      await settle();
      expect(handler.droppedBytes, <int>[3]);
    });

    test('a source that never answers times out and still finishes', () async {
      enter();
      position();
      client.messages.clear();

      drop();
      expect(manager.isTransferPending, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(handler.droppedBytes, isNull);
      expect(manager.isTransferPending, isFalse);
      expect(client.errors.single, contains('never answered'));
      expect(client.messages.single.type, client.atom('XdndFinished'));
      expect(manager.hasActiveSession, isFalse,
          reason: 'a source that went away must not wedge the machine');
    });

    test('abortPendingTransfer releases a wedged read', () async {
      enter();
      position();
      drop();

      manager.abortPendingTransfer('the test said so');
      await settle();

      expect(handler.droppedBytes, isNull);
      expect(manager.isTransferPending, isFalse);
      expect(client.errors.single, contains('the test said so'));
    });

    test('a second read waits for the first rather than racing the property',
        () async {
      handler
        ..readFormat = null
        ..parallelFormats = <String>[_textMime, _uriMime];
      enter(types: <String>[_textMime, _uriMime]);
      position();
      drop();

      expect(client.conversions, hasLength(1),
          reason: 'two conversions into one property would race, and both '
              'would read the wrong bytes');
      answerConversion(<int>[1, 2]);
      await settle();

      expect(client.conversions, hasLength(2));
      answerConversion(<int>[3]);
      await settle();

      expect(handler.parallelResults[0], <int>[1, 2]);
      expect(handler.parallelResults[1], <int>[3]);
    });

    test('a read before the drop is refused rather than converted', () async {
      handler.response = const DropResponse(acceptedFormat: _textMime);
      enter();
      position();

      expect(await handler.enters.single.data.readBytes(_textMime), isNull);
      expect(client.conversions, isEmpty);
    });

    test('a drop handler that throws still finishes the drop', () async {
      handler
        ..readFormat = null
        ..throwOnDrop = true;
      enter();
      position();
      client.messages.clear();

      drop();
      await settle();

      expect(client.messages.single.type, client.atom('XdndFinished'));
      expect(client.messages.single.data[1] & xdndFinishedAcceptedBit, 0);
      expect(client.errors.single, contains('drop handler failed'));
    });

    test('disposing mid-drop finishes the source and releases the read',
        () async {
      enter();
      position();
      client.messages.clear();

      drop();
      manager.dispose();
      await settle();

      expect(handler.droppedBytes, isNull);
      expect(client.messages.single.type, client.atom('XdndFinished'));
      expect(client.messages.single.data[1] & xdndFinishedAcceptedBit, 0);
      expect(manager.hasActiveSession, isFalse);
    });
  });

  group('action translation', () {
    test('every action the protocol names survives the round trip', () {
      const Map<DragAction, String> expected = <DragAction, String>{
        DragAction.copy: 'XdndActionCopy',
        DragAction.move: 'XdndActionMove',
        DragAction.link: 'XdndActionLink',
        DragAction.ask: 'XdndActionAsk',
      };
      for (final MapEntry<DragAction, String> entry in expected.entries) {
        handler.response = const DropResponse(acceptedFormat: _textMime);
        client.messages.clear();
        enter();
        position(action: entry.key);

        expect(handler.enters.last.suggestedAction, entry.key);
        handler.response = DropResponse(
          acceptedFormat: _textMime,
          action: entry.key,
        );
        client.messages.clear();
        position(action: entry.key);
        expect(client.messages.single.data[4], client.atom(entry.value));
      }
    });

    test('an action this destination does not know reads as copy', () {
      // The specification's own advice for XdndActionPrivate: copy is the
      // choice that cannot lose data if the guess was wrong.
      handler.response = const DropResponse(acceptedFormat: _textMime);
      enter();

      manager.handleClientMessage(
        window: _ourWindow,
        messageType: client.atom('XdndPosition'),
        format: xdndClientMessageFormat,
        data0: _sourceWindow,
        data1: 0,
        data2: 0,
        data3: 0,
        data4: client.atom('XdndActionPrivate'),
      );

      expect(handler.enters.single.suggestedAction, DragAction.copy);
    });
  });

  group('coordinates', () {
    test('root physical pixels become logical client and screen positions', () {
      handler.response = const DropResponse(acceptedFormat: _textMime);
      enter();

      position(rootX: 140, rootY: 90);

      final DragSessionEvent event = handler.enters.single;
      expect(event.position, const Offset(20, 20),
          reason: 'root 140,90 is 40,40 device pixels into a client area that '
              'starts at 100,50, and there are two pixels per logical unit');
      expect(event.screenPosition, const Offset(70, 45));
    });
  });

  group('X11DragDropBackend', () {
    late _FakeNativeWindow window;
    late X11DragDropBackend backend;

    setUp(() {
      window = _FakeNativeWindow(_ourWindowId);
      backend = X11DragDropBackend(
        manager: manager,
        xcbWindowOf: (NativeWindow each) =>
            each is _FakeNativeWindow ? each.xcbWindow : 0,
      );
      manager.unregisterWindow(_ourWindow);
      client.deletedProperties.clear();
      client.propertyWrites.clear();
    });

    test('registering installs the handler and advertises the window',
        () async {
      final DropTargetRegistration registration =
          await backend.registerDropTarget(
        window: window,
        handler: handler,
      );

      expect(registration.windowId, _ourWindowId);
      expect(registration.isActive, isTrue);
      expect(client.propertyWrites.single.property, client.atom('XdndAware'));
      expect(manager.handler, same(handler));
    });

    test('a second registration for one window is refused, not doubled',
        () async {
      await backend.registerDropTarget(window: window, handler: handler);

      await expectLater(
        backend.registerDropTarget(window: window, handler: handler),
        throwsA(isA<DragDropException>()
            .having((DragDropException error) => error.backend, 'backend',
                'xdnd')
            .having((DragDropException error) => error.reason, 'reason',
                contains('already has an XdndAware drop target'))),
      );
    });

    test('a window this backend does not own is refused by name', () async {
      await expectLater(
        backend.registerDropTarget(
          window: _FakeNativeWindow(const NativeWindowId(99), xcbWindow: 0),
          handler: handler,
        ),
        throwsA(isA<DragDropException>().having(
          (DragDropException error) => error.reason,
          'reason',
          contains('not a live X11 window'),
        )),
      );
    });

    test('a second handler for the connection is refused', () async {
      await backend.registerDropTarget(window: window, handler: handler);

      await expectLater(
        backend.registerDropTarget(
          window: _FakeNativeWindow(const NativeWindowId(8), xcbWindow: 0x55),
          handler: _RecordingHandler(),
        ),
        throwsA(isA<DragDropException>().having(
          (DragDropException error) => error.reason,
          'reason',
          contains('already routes drops to another handler'),
        )),
      );
    });

    test('revoking deletes the property and is idempotent', () async {
      final DropTargetRegistration registration =
          await backend.registerDropTarget(
        window: window,
        handler: handler,
      );

      await registration.revoke();
      await registration.revoke();

      expect(registration.isActive, isFalse);
      expect(client.deletedProperties, hasLength(1));
      expect(manager.handler, isNull);
      expect(manager.isRegistered(_ourWindow), isFalse);
    });

    test('the source side refuses by name rather than failing silently', () {
      expect(backend.canStartDrag, isFalse);
      expect(backend.name, 'xdnd');
      expect(
        backend.startDrag(DragRequest(
          window: window,
          data: MemoryDragData.text('hello'),
        )),
        throwsA(isA<DragDropException>()
            .having((DragDropException error) => error.operation, 'operation',
                'startDrag')
            .having((DragDropException error) => error.reason, 'reason',
                contains('XdndSelection'))),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Native decoding
  // -------------------------------------------------------------------------

  group('X11RawEvent.decodeFrom', () {
    test('a ClientMessage carries all five XDND words', () {
      _withNativeEvent((Pointer<Uint8> event) {
        event[0] = xcbClientMessage;
        event[1] = xdndClientMessageFormat;
        writeU32(event, 4, 0x0a00001);
        writeU32(event, 8, 0x101);
        writeU32(event, 12, 0x0b00002);
        writeU32(event, 16, (5 << 24) | 1);
        writeU32(event, 20, 0x00640032);
        writeU32(event, 24, 0xcafe);
        writeU32(event, 28, 0x202);

        final X11RawEvent raw = X11RawEvent()..decodeFrom(event);

        expect(raw.type, xcbClientMessage);
        expect(raw.detail, xdndClientMessageFormat);
        expect(raw.window, 0x0a00001);
        expect(raw.atom, 0x101);
        expect(raw.data0, 0x0b00002);
        expect(raw.data1, (5 << 24) | 1);
        expect(raw.data2, 0x00640032);
        expect(raw.data3, 0xcafe);
        expect(raw.data4, 0x202);
      });
    });

    test('SelectionNotify reads a timestamp at byte 4, not a window', () {
      _withNativeEvent((Pointer<Uint8> event) {
        event[0] = xcbSelectionNotify;
        writeU32(event, 4, 0x11223344);
        writeU32(event, 8, 0x0a00001);
        writeU32(event, 12, 0x301);
        writeU32(event, 16, 0x302);
        writeU32(event, 20, 0x303);

        final X11RawEvent raw = X11RawEvent()..decodeFrom(event);

        expect(raw.timestamp, 0x11223344);
        expect(raw.window, 0x0a00001,
            reason: 'the requestor is the window a selection reply is for');
        expect(raw.requestor, 0x0a00001);
        expect(raw.selection, 0x301);
        expect(raw.target, 0x302);
        expect(raw.property, 0x303);
      });
    });

    test('SelectionRequest separates the owner from the requestor', () {
      _withNativeEvent((Pointer<Uint8> event) {
        event[0] = xcbSelectionRequest;
        writeU32(event, 4, 77);
        writeU32(event, 8, 0x0a00001);
        writeU32(event, 12, 0x0b00002);
        writeU32(event, 16, 0x401);
        writeU32(event, 20, 0x402);
        writeU32(event, 24, 0x403);

        final X11RawEvent raw = X11RawEvent()..decodeFrom(event);

        expect(raw.timestamp, 77);
        expect(raw.window, 0x0a00001);
        expect(raw.requestor, 0x0b00002);
        expect(raw.selection, 0x401);
        expect(raw.target, 0x402);
        expect(raw.property, 0x403);
      });
    });

    test('SelectionClear names the owner and the selection', () {
      _withNativeEvent((Pointer<Uint8> event) {
        event[0] = xcbSelectionClear;
        writeU32(event, 4, 88);
        writeU32(event, 8, 0x0a00001);
        writeU32(event, 12, 0x501);

        final X11RawEvent raw = X11RawEvent()..decodeFrom(event);

        expect(raw.timestamp, 88);
        expect(raw.window, 0x0a00001);
        expect(raw.selection, 0x501);
        expect(raw.target, 0);
        expect(raw.property, 0);
      });
    });

    test('the reused record forgets the previous event selection fields', () {
      final X11RawEvent raw = X11RawEvent();
      _withNativeEvent((Pointer<Uint8> event) {
        event[0] = xcbSelectionNotify;
        writeU32(event, 4, 1);
        writeU32(event, 8, 2);
        writeU32(event, 12, 3);
        writeU32(event, 16, 4);
        writeU32(event, 20, 5);
        raw.decodeFrom(event);
      });
      expect(raw.selection, 3);

      _withNativeEvent((Pointer<Uint8> event) {
        event[0] = xcbClientMessage;
        event[1] = xdndClientMessageFormat;
        writeU32(event, 4, 9);
        writeU32(event, 12, 11);
        raw.decodeFrom(event);
      });

      expect(raw.selection, 0);
      expect(raw.target, 0);
      expect(raw.property, 0);
      expect(raw.requestor, 0);
      expect(raw.data0, 11);
      expect(raw.data1, 0);
      expect(raw.data4, 0);
    });
  });

  group('XDND source', () {
    const int rootWindow = 0x1;
    const int originWindow = 0x2000;
    const int targetWindow = 0x3000;

    late _FakeDragDropClient client;
    late X11XdndSource source;

    setUp(() {
      client = _FakeDragDropClient();
      source = X11XdndSource(
        client,
        finishTimeout: const Duration(milliseconds: 20),
      );
      client.selectionOwner = originWindow;
    });

    Future<DragAction> start({
      Map<String, Uint8List>? payload,
      Set<DragAction> actions = const <DragAction>{DragAction.copy},
      DragAction preferred = DragAction.copy,
      int time = 900,
    }) =>
        source.start(
          originWindow: originWindow,
          rootWindow: rootWindow,
          payload: payload ??
              <String, Uint8List>{
                'text/uri-list': Uint8List.fromList(<int>[102, 105]),
              },
          actions: actions,
          preferred: preferred,
          time: time,
        );

    /// Puts an XDND-aware [targetWindow] one level below the root.
    void placeTarget({int version = xdndVersion}) => client.putXdndTarget(
          parent: rootWindow,
          window: targetWindow,
          version: version,
        );

    _ClientMessage lastOfType(String name) => client.messages
        .lastWhere((_ClientMessage m) => m.type == client.atom(name));

    bool hasType(String name) =>
        client.messages.any((_ClientMessage m) => m.type == client.atom(name));

    void status({
      int window = targetWindow,
      bool accept = true,
      DragAction action = DragAction.copy,
      int rectX = 0,
      int rectY = 0,
      int rectWidth = 0,
      int rectHeight = 0,
      bool alwaysSend = false,
    }) {
      source.handleClientMessage(
        type: client.atom('XdndStatus'),
        window: originWindow,
        data: <int>[
          window,
          (accept ? xdndStatusAcceptBit : 0) |
              (alwaysSend ? xdndStatusWantPositionBit : 0),
          ((rectX & 0xFFFF) << 16) | (rectY & 0xFFFF),
          ((rectWidth & 0xFFFF) << 16) | (rectHeight & 0xFFFF),
          client.actionAtom(action),
        ],
      );
    }

    group('taking the selection', () {
      test('ownership is taken and verified before the drag exists', () {
        final Future<DragAction> drag = start(time: 4321);
        expect(source.isDragging, isTrue);
        expect(client.selectionOwner, originWindow);
        expect(drag, isA<Future<DragAction>>());
        source.cancel();
      });

      test('a selection another client holds is a named failure', () {
        client
          ..selectionOwner = 0x9999
          ..refuseSelectionOwner = true;
        expect(
          () => start(),
          throwsA(
            isA<DragDropException>().having(
              (DragDropException e) => e.operation,
              'operation',
              'SetSelectionOwner',
            ),
          ),
          reason: 'a drag that does not own XdndSelection can never be '
              'converted, so it must not appear to start',
        );
        expect(source.isDragging, isFalse);
      });

      test('an empty payload is refused', () {
        expect(
          () => start(payload: <String, Uint8List>{}),
          throwsA(isA<DragDropException>()),
        );
      });

      test('a second drag cannot run while one is in flight', () {
        start();
        expect(() => start(), throwsA(isA<DragDropException>()));
        source.cancel();
      });

      test('three types or fewer travel inline, with no XdndTypeList', () {
        start(payload: <String, Uint8List>{
          'text/uri-list': Uint8List(1),
          'text/plain': Uint8List(1),
        });
        expect(
          client.propertyWrites
              .where((_PropertyWrite w) => w.property == client.atom('XdndTypeList')),
          isEmpty,
        );
        source.cancel();
      });

      test('more than three types are published as XdndTypeList', () {
        start(payload: <String, Uint8List>{
          'text/uri-list': Uint8List(1),
          'text/plain': Uint8List(1),
          'text/plain;charset=utf-8': Uint8List(1),
          'text/html': Uint8List(1),
        });
        final _PropertyWrite write = client.propertyWrites.singleWhere(
          (_PropertyWrite w) => w.property == client.atom('XdndTypeList'),
        );
        expect(write.window, originWindow);
        expect(write.type, xcbAtomAtom);
        expect(write.values, hasLength(4));
        source.cancel();
      });
    });

    group('finding a target', () {
      test('the descent stops at the deepest XdndAware window', () {
        const int frame = 0x2A00;
        client.putXdndTarget(
            parent: rootWindow, window: frame, version: xdndVersion);
        client.putXdndTarget(
            parent: frame, window: targetWindow, version: xdndVersion);
        start();

        source.moveTo(120, 80, 1000);

        expect(source.targetWindow, targetWindow,
            reason: 'the client window, not the window-manager frame');
        source.cancel();
      });

      test('a bare desktop is no target at all, and no message is sent', () {
        start();
        client.messages.clear();

        source.moveTo(10, 10, 1000);

        expect(source.targetWindow, xcbNone);
        expect(client.messages, isEmpty);
        source.cancel();
      });

      test('a version below the floor is not a target', () {
        placeTarget(version: xdndMinimumVersion - 1);
        start();
        client.messages.clear();

        source.moveTo(10, 10, 1000);

        expect(source.targetWindow, xcbNone,
            reason: 'version 2 has a different XdndEnter layout entirely');
        source.cancel();
      });

      test('the walk cannot spin on a reparenting hierarchy', () {
        // A cycle: every window says its child is itself.
        client.pointerTree[rootWindow] =
            const X11PointerLocation(child: rootWindow, rootX: 0, rootY: 0);
        start();

        source.moveTo(10, 10, 1000);

        expect(client.pointerQueries.length,
            lessThanOrEqualTo(xdndPointerWalkDepthLimit));
        source.cancel();
      });

      test('an XdndProxy that points back at itself is addressed instead', () {
        const int proxy = 0x4000;
        placeTarget();
        client
          ..putCardinals(targetWindow, client.atom('XdndProxy'), <int>[proxy])
          ..putCardinals(proxy, client.atom('XdndProxy'), <int>[proxy])
          ..putCardinals(proxy, client.atom('XdndAware'), <int>[xdndVersion]);
        start();

        source.moveTo(10, 10, 1000);

        expect(source.targetWindow, proxy);
        expect(lastOfType('XdndEnter').destination, proxy);
        source.cancel();
      });

      test('a stale XdndProxy left by a dead client is ignored', () {
        const int proxy = 0x4000;
        placeTarget();
        // No back-reference on the proxy: the specification's own test for a
        // proxy nobody is servicing any more.
        client.putCardinals(
            targetWindow, client.atom('XdndProxy'), <int>[proxy]);
        start();

        source.moveTo(10, 10, 1000);

        expect(source.targetWindow, targetWindow);
        source.cancel();
      });
    });

    group('enter, position and status', () {
      test('entering names the version and the inline types', () {
        placeTarget();
        start(payload: <String, Uint8List>{
          'text/uri-list': Uint8List(1),
          'text/plain': Uint8List(1),
        });

        source.moveTo(50, 60, 1000);

        final _ClientMessage enter = lastOfType('XdndEnter');
        expect(enter.destination, targetWindow);
        expect(enter.data[0], originWindow);
        expect(enter.data[1] >> xdndEnterVersionShift, xdndVersion);
        expect(enter.data[1] & xdndEnterMoreTypesBit, 0);
        expect(enter.data[2], client.atom('text/uri-list'));
        expect(enter.data[3], client.atom('text/plain'));
        expect(enter.data[4], xcbNone);
        source.cancel();
      });

      test('a source speaks down to an older target', () {
        placeTarget(version: 3);
        start();

        source.moveTo(50, 60, 1000);

        expect(lastOfType('XdndEnter').data[1] >> xdndEnterVersionShift, 3);
        source.cancel();
      });

      test('the more-types bit is set only when it is true', () {
        placeTarget();
        start(payload: <String, Uint8List>{
          'text/uri-list': Uint8List(1),
          'text/plain': Uint8List(1),
          'text/plain;charset=utf-8': Uint8List(1),
          'text/html': Uint8List(1),
        });

        source.moveTo(50, 60, 1000);

        expect(
          lastOfType('XdndEnter').data[1] & xdndEnterMoreTypesBit,
          xdndEnterMoreTypesBit,
        );
        source.cancel();
      });

      test('the position carries packed root coordinates and the action', () {
        placeTarget();
        start(
          actions: const <DragAction>{DragAction.copy, DragAction.move},
          preferred: DragAction.move,
        );

        source.moveTo(300, 200, 7777);

        final _ClientMessage position = lastOfType('XdndPosition');
        expect(position.data[0], originWindow);
        expect(position.data[2], (300 << 16) | 200);
        expect(position.data[3], 7777);
        expect(position.data[4], client.actionAtom(DragAction.move));
        source.cancel();
      });

      test('a status is what makes the drop allowed', () {
        placeTarget();
        start();
        source.moveTo(50, 60, 1000);
        expect(source.targetAccepts, isFalse,
            reason: 'nothing is accepted until the target says so');

        status(action: DragAction.move);

        expect(source.targetAccepts, isTrue);
        expect(source.negotiatedAction, DragAction.move);
        source.cancel();
      });

      test('a refusal clears the action as well as the accept bit', () {
        placeTarget();
        start();
        source.moveTo(50, 60, 1000);
        status();
        expect(source.targetAccepts, isTrue);

        status(accept: false, action: DragAction.copy);

        expect(source.targetAccepts, isFalse);
        expect(source.negotiatedAction, DragAction.none);
        source.cancel();
      });

      test('a status from a window we have left is ignored', () {
        placeTarget();
        start();
        source.moveTo(50, 60, 1000);

        status(window: 0xDEAD);

        expect(source.targetAccepts, isFalse);
        source.cancel();
      });

      test('the silent rectangle suppresses redundant positions', () {
        placeTarget();
        start();
        source.moveTo(50, 60, 1000);
        status(rectX: 0, rectY: 0, rectWidth: 400, rectHeight: 400);
        final int sent = client.messages
            .where((_ClientMessage m) => m.type == client.atom('XdndPosition'))
            .length;

        source.moveTo(60, 70, 1001);
        source.moveTo(70, 80, 1002);

        expect(
          client.messages
              .where(
                  (_ClientMessage m) => m.type == client.atom('XdndPosition'))
              .length,
          sent,
          reason: 'the specification asks a source to honour the rectangle',
        );

        source.moveTo(900, 900, 1003);
        expect(
          client.messages
              .where(
                  (_ClientMessage m) => m.type == client.atom('XdndPosition'))
              .length,
          sent + 1,
          reason: 'leaving the rectangle has to be reported',
        );
        source.cancel();
      });

      test('a target that asks for every motion gets every motion', () {
        placeTarget();
        start();
        source.moveTo(50, 60, 1000);
        status(
          rectWidth: 400,
          rectHeight: 400,
          alwaysSend: true,
        );
        final int sent = client.messages
            .where((_ClientMessage m) => m.type == client.atom('XdndPosition'))
            .length;

        source.moveTo(60, 70, 1001);

        expect(
          client.messages
              .where(
                  (_ClientMessage m) => m.type == client.atom('XdndPosition'))
              .length,
          sent + 1,
        );
        source.cancel();
      });

      test('moving to another target leaves the first one', () {
        const int second = 0x5000;
        placeTarget();
        start();
        source.moveTo(50, 60, 1000);
        client.messages.clear();

        client.putXdndTarget(
            parent: rootWindow, window: second, version: xdndVersion);
        source.moveTo(500, 500, 1001);

        final _ClientMessage leave = lastOfType('XdndLeave');
        expect(leave.destination, targetWindow);
        expect(leave.data[0], originWindow);
        expect(lastOfType('XdndEnter').destination, second);
        expect(source.targetWindow, second);
        expect(source.targetAccepts, isFalse,
            reason: 'the new target has not answered yet');
        source.cancel();
      });
    });

    group('dropping', () {
      test('a release on an accepting target drops and awaits the finish',
          () async {
        placeTarget();
        final Future<DragAction> drag = start();
        source.moveTo(50, 60, 1000);
        status(action: DragAction.move);

        source.release(2000);

        final _ClientMessage drop = lastOfType('XdndDrop');
        expect(drop.destination, targetWindow);
        expect(drop.data[0], originWindow);
        expect(drop.data[2], 2000);
        expect(source.isAwaitingFinish, isTrue);

        source.handleClientMessage(
          type: client.atom('XdndFinished'),
          window: originWindow,
          data: <int>[
            targetWindow,
            xdndFinishedAcceptedBit,
            client.actionAtom(DragAction.move),
            0,
            0,
          ],
        );

        expect(await drag, DragAction.move);
        expect(source.isDragging, isFalse);
      });

      test('a release on a target that refused leaves instead of dropping',
          () async {
        placeTarget();
        final Future<DragAction> drag = start();
        source.moveTo(50, 60, 1000);
        status(accept: false);

        source.release(2000);

        expect(hasType('XdndDrop'), isFalse,
            reason: 'dropping on a refusal is how a file vanishes');
        expect(lastOfType('XdndLeave').destination, targetWindow);
        expect(await drag, DragAction.none);
      });

      test('a release over nothing ends the drag with no action', () async {
        final Future<DragAction> drag = start();
        source.moveTo(10, 10, 1000);

        source.release(2000);

        expect(await drag, DragAction.none);
        expect(hasType('XdndDrop'), isFalse);
      });

      test('a finish that says it did not accept performs nothing', () async {
        placeTarget();
        final Future<DragAction> drag = start();
        source.moveTo(50, 60, 1000);
        status(action: DragAction.move);
        source.release(2000);

        source.handleClientMessage(
          type: client.atom('XdndFinished'),
          window: originWindow,
          data: <int>[targetWindow, 0, client.actionAtom(DragAction.move), 0, 0],
        );

        expect(await drag, DragAction.none,
            reason: 'a move the destination did not perform must not make the '
                'source delete its original');
      });

      test('a pre-version-5 finish is trusted for the negotiated action only',
          () async {
        placeTarget(version: 4);
        final Future<DragAction> drag = start(
          actions: const <DragAction>{DragAction.copy, DragAction.move},
        );
        source.moveTo(50, 60, 1000);
        status(action: DragAction.move);
        source.release(2000);

        // Words 1 and 2 are whatever SendEvent padded them with on a version 4
        // destination; reading them would decide the outcome at random.
        source.handleClientMessage(
          type: client.atom('XdndFinished'),
          window: originWindow,
          data: <int>[targetWindow, 0xDEADBEEF, 0xDEADBEEF, 0, 0],
        );

        expect(await drag, DragAction.move);
      });

      test('a finish that never arrives times out rather than wedging',
          () async {
        placeTarget();
        final Future<DragAction> drag = start();
        source.moveTo(50, 60, 1000);
        status();
        source.release(2000);

        expect(await drag, DragAction.none);
        expect(source.isDragging, isFalse,
            reason: 'a destination is entitled to exit mid-drop');
        expect(client.errors.join('\n'), contains('XdndFinished'));
      });

      test('a finish from another window does not end our drag', () async {
        placeTarget();
        final Future<DragAction> drag = start();
        source.moveTo(50, 60, 1000);
        status();
        source.release(2000);

        source.handleClientMessage(
          type: client.atom('XdndFinished'),
          window: originWindow,
          data: <int>[0xBEEF, xdndFinishedAcceptedBit, 0, 0, 0],
        );
        expect(source.isDragging, isTrue);

        // And the timeout still closes it, so nothing is left hanging.
        expect(await drag, DragAction.none);
      });

      test('a cancel ends the drag and tells the target', () async {
        placeTarget();
        final Future<DragAction> drag = start();
        source.moveTo(50, 60, 1000);
        status();

        source.cancel();

        expect(lastOfType('XdndLeave').destination, targetWindow);
        expect(await drag, DragAction.none);
      });
    });

    group('serving the selection', () {
      test('a request for an offered type is answered with the bytes', () {
        start(payload: <String, Uint8List>{
          'text/uri-list': Uint8List.fromList(<int>[1, 2, 3]),
        });

        final bool handled = source.handleSelectionRequest(
          requestor: 0x7000,
          selection: client.atom('XdndSelection'),
          target: client.atom('text/uri-list'),
          property: client.atom(xdndDropProperty),
          time: 3000,
        );

        expect(handled, isTrue);
        final _ByteWrite write = client.byteWrites.single;
        expect(write.window, 0x7000);
        expect(write.property, client.atom(xdndDropProperty));
        expect(write.type, client.atom('text/uri-list'));
        expect(write.bytes, <int>[1, 2, 3]);

        final _SelectionNotify notify = client.selectionNotifies.single;
        expect(notify.requestor, 0x7000);
        expect(notify.property, client.atom(xdndDropProperty));
        expect(notify.time, 3000);
        source.cancel();
      });

      test('a request for a type we do not offer is refused out loud', () {
        start();

        source.handleSelectionRequest(
          requestor: 0x7000,
          selection: client.atom('XdndSelection'),
          target: client.atom('image/png'),
          property: client.atom(xdndDropProperty),
          time: 3000,
        );

        expect(client.byteWrites, isEmpty);
        expect(client.selectionNotifies.single.property, xcbNone,
            reason: 'silence leaves the requestor blocked on its own queue, '
                'which the user reads as the other application hanging');
        source.cancel();
      });

      test('TARGETS lists the atoms this drag offers', () {
        start(payload: <String, Uint8List>{
          'text/uri-list': Uint8List(1),
          'text/plain': Uint8List(1),
        });

        source.handleSelectionRequest(
          requestor: 0x7000,
          selection: client.atom('XdndSelection'),
          target: client.atom('TARGETS'),
          property: client.atom(xdndDropProperty),
          time: 3000,
        );

        final _PropertyWrite write = client.propertyWrites.last;
        expect(write.type, xcbAtomAtom);
        expect(
          write.values,
          containsAll(<int>[
            client.atom('TARGETS'),
            client.atom('text/uri-list'),
            client.atom('text/plain'),
          ]),
        );
        expect(client.selectionNotifies.single.property,
            client.atom(xdndDropProperty));
        source.cancel();
      });

      test('a property of None means "use the target atom", as XDND 0 did', () {
        start();

        source.handleSelectionRequest(
          requestor: 0x7000,
          selection: client.atom('XdndSelection'),
          target: client.atom('text/uri-list'),
          property: xcbNone,
          time: 3000,
        );

        expect(client.byteWrites.single.property, client.atom('text/uri-list'));
        source.cancel();
      });

      test('a request for another selection is not ours', () {
        start();

        expect(
          source.handleSelectionRequest(
            requestor: 0x7000,
            selection: client.atom('PRIMARY'),
            target: client.atom('text/uri-list'),
            property: client.atom(xdndDropProperty),
            time: 3000,
          ),
          isFalse,
        );
        expect(client.selectionNotifies, isEmpty);
        source.cancel();
      });

      test('losing the selection ends the drag', () async {
        placeTarget();
        final Future<DragAction> drag = start();
        source.moveTo(50, 60, 1000);

        expect(
          source.handleSelectionClear(client.atom('XdndSelection')),
          isTrue,
        );

        expect(await drag, DragAction.none);
        expect(source.isDragging, isFalse);
        expect(client.errors.join('\n'), contains('XdndSelection'));
      });

      test('another selection being cleared is none of our business', () {
        start();
        expect(source.handleSelectionClear(client.atom('CLIPBOARD')), isFalse);
        expect(source.isDragging, isTrue);
        source.cancel();
      });
    });

    group('events that are not ours', () {
      test('a client message with no drag in flight is declined', () {
        expect(
          source.handleClientMessage(
            type: client.atom('XdndStatus'),
            window: originWindow,
            data: <int>[targetWindow, 1, 0, 0, 0],
          ),
          isFalse,
          reason: 'the destination machine must still get its turn',
        );
      });

      test('a message of another type is declined', () {
        start();
        expect(
          source.handleClientMessage(
            type: client.atom('XdndEnter'),
            window: originWindow,
            data: <int>[0, 0, 0, 0, 0],
          ),
          isFalse,
        );
        source.cancel();
      });

      test('a truncated message is declined rather than read past its end', () {
        start();
        expect(
          source.handleClientMessage(
            type: client.atom('XdndStatus'),
            window: originWindow,
            data: <int>[targetWindow, 1],
          ),
          isFalse,
        );
        source.cancel();
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Native event scratch, as in `x11_events_test.dart`
// ---------------------------------------------------------------------------

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

final DynamicLibrary _cRuntime = Platform.isWindows
    ? DynamicLibrary.open('ucrtbase.dll')
    : Platform.isMacOS
        ? DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
        : DynamicLibrary.open('libc.so.6');
final _MallocDart _malloc =
    _cRuntime.lookupFunction<_MallocNative, _MallocDart>('malloc');
final _FreeDart _free =
    _cRuntime.lookupFunction<_FreeNative, _FreeDart>('free');

void _withNativeEvent(void Function(Pointer<Uint8> event) body) {
  final Pointer<Void> allocation = _malloc(32);
  if (allocation == nullptr) {
    throw StateError('malloc failed while preparing an X11 test event');
  }
  final Pointer<Uint8> event = allocation.cast<Uint8>();
  for (var index = 0; index < 32; index++) {
    event[index] = 0;
  }
  try {
    body(event);
  } finally {
    _free(allocation);
  }

  // ---------------------------------------------------------------------------
  // The source half
  // ---------------------------------------------------------------------------

}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final class _ClientMessage {
  _ClientMessage({
    required this.destination,
    required this.window,
    required this.type,
    required this.data,
  });

  final int destination;
  final int window;
  final int type;
  final List<int> data;
}

final class _Conversion {
  _Conversion({
    required this.requestor,
    required this.selection,
    required this.target,
    required this.property,
    required this.time,
  });

  final int requestor;
  final int selection;
  final int target;
  final int property;
  final int time;
}

final class _PropertyWrite {
  _PropertyWrite(this.window, this.property, this.type, this.values);

  final int window;
  final int property;
  final int type;
  final List<int> values;
}

final class _PropertyRef {
  const _PropertyRef(this.window, this.property);

  final int window;
  final int property;

  @override
  bool operator ==(Object other) =>
      other is _PropertyRef &&
      other.window == window &&
      other.property == property;

  @override
  int get hashCode => Object.hash(window, property);
}

final class _PropertyRead {
  _PropertyRead(this.window, this.property, this.type, this.delete);

  final int window;
  final int property;
  final int type;
  final bool delete;
}

/// An X server's atom table and property store, minus the server.
final class _FakeDragDropClient implements X11DragDropClient {
  final Map<String, int> _atoms = <String, int>{};
  final Map<int, String> _names = <int, String>{};
  int _nextAtom = 0x100;

  final List<_ClientMessage> messages = <_ClientMessage>[];
  final List<_Conversion> conversions = <_Conversion>[];
  final List<_PropertyWrite> propertyWrites = <_PropertyWrite>[];
  final List<_PropertyRef> deletedProperties = <_PropertyRef>[];
  final List<_PropertyRead> reads = <_PropertyRead>[];
  final List<String> errors = <String>[];
  final Map<_PropertyRef, X11PropertyValue> properties =
      <_PropertyRef, X11PropertyValue>{};
  final Map<_PropertyRef, List<int>> cardinals = <_PropertyRef, List<int>>{};

  int flushes = 0;
  int selectionOwner = xcbNone;

  /// Makes `SetSelectionOwner` a no-op, so the verifying read finds somebody
  /// else still holding it.
  bool refuseSelectionOwner = false;

  // --- the source half's extra surface ------------------------------------

  /// `QueryPointer` answers, keyed by the window asked. A window absent from
  /// the map answers "no child", which is what ends the descent.
  final Map<int, X11PointerLocation> pointerTree = <int, X11PointerLocation>{};

  final List<_ByteWrite> byteWrites = <_ByteWrite>[];
  final List<_SelectionNotify> selectionNotifies = <_SelectionNotify>[];
  final List<int> pointerQueries = <int>[];

  /// Makes [window] an XDND target of [version], reachable by descending from
  /// [parent].
  void putXdndTarget({
    required int parent,
    required int window,
    required int version,
    int rootX = 0,
    int rootY = 0,
  }) {
    pointerTree[parent] = X11PointerLocation(
      child: window,
      rootX: rootX,
      rootY: rootY,
    );
    putCardinals(window, atom('XdndAware'), <int>[version]);
  }

  /// The atom for [action], so a test can spell an `XdndPosition` payload.
  int actionAtom(DragAction action) => switch (action) {
        DragAction.none => xcbNone,
        DragAction.copy => atom('XdndActionCopy'),
        DragAction.move => atom('XdndActionMove'),
        DragAction.link => atom('XdndActionLink'),
        DragAction.ask => atom('XdndActionAsk'),
      };

  /// Makes an atom exist without a name, the way an atom interned by another
  /// client whose name the server refuses to spell back would look.
  void forgetAtomName(int value) => _names.remove(value);

  void putCardinals(int window, int property, List<int> values) =>
      cardinals[_PropertyRef(window, property)] = values;

  void putBytes(int window, int property, X11PropertyValue value) =>
      properties[_PropertyRef(window, property)] = value;

  @override
  int atom(String name) {
    final int? existing = _atoms[name];
    if (existing != null) return existing;
    final int value = _nextAtom++;
    _atoms[name] = value;
    _names[value] = name;
    return value;
  }

  @override
  String? atomName(int value) => _names[value];

  @override
  void setWindowProperty32(
    int window,
    int property,
    int type,
    List<int> values,
  ) =>
      propertyWrites.add(_PropertyWrite(window, property, type, values));

  @override
  void deleteWindowProperty(int window, int property) {
    deletedProperties.add(_PropertyRef(window, property));
    properties.remove(_PropertyRef(window, property));
  }

  @override
  void sendClientMessage({
    required int destination,
    required int window,
    required int type,
    required List<int> data,
  }) =>
      messages.add(_ClientMessage(
        destination: destination,
        window: window,
        type: type,
        data: List<int>.of(data),
      ));

  @override
  void convertSelection({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) =>
      conversions.add(_Conversion(
        requestor: requestor,
        selection: selection,
        target: target,
        property: property,
        time: time,
      ));

  @override
  void setWindowPropertyBytes(
    int window,
    int property,
    int type,
    Uint8List bytes,
  ) =>
      byteWrites.add(_ByteWrite(window, property, type, bytes));

  @override
  void sendSelectionNotify({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) =>
      selectionNotifies.add(_SelectionNotify(
        requestor: requestor,
        selection: selection,
        target: target,
        property: property,
        time: time,
      ));

  @override
  X11PointerLocation? queryPointer(int window) {
    pointerQueries.add(window);
    return pointerTree[window];
  }

  @override
  X11PropertyValue? readPropertyBytes(
    int window,
    int property, {
    required int type,
    bool delete = false,
  }) {
    reads.add(_PropertyRead(window, property, type, delete));
    final _PropertyRef key = _PropertyRef(window, property);
    final X11PropertyValue? value = properties[key];
    if (delete) properties.remove(key);
    return value;
  }

  @override
  List<int> readPropertyCardinals(
    int window,
    int property, {
    required int type,
  }) =>
      cardinals[_PropertyRef(window, property)] ?? const <int>[];

  @override
  int getSelectionOwner(int selection) => selectionOwner;

  @override
  void setSelectionOwner(int owner, int selection, int time) {
    // A real server can refuse, or another client can take the selection back
    // between the set and the read. `refuseSelectionOwner` is how a test plays
    // that race, which is the one the source half has to survive.
    if (refuseSelectionOwner) return;
    selectionOwner = owner;
  }

  @override
  int flush() {
    flushes++;
    return 1;
  }

  @override
  void recordError(String message) => errors.add(message);
}

final class _RecordingHandler implements DropTargetHandler {
  DropResponse response = const DropResponse.reject();

  /// What the handler reports having performed, when the transfer succeeded.
  DragAction dropAction = DragAction.copy;

  /// Which format `onDrop` reads, or null to accept without reading.
  String? readFormat;

  /// Several formats read at once, to prove the transfers are serialised
  /// rather than raced onto one property.
  List<String>? parallelFormats;
  List<Uint8List?> parallelResults = <Uint8List?>[];

  bool throwOnDrop = false;

  final List<DragSessionEvent> enters = <DragSessionEvent>[];
  final List<DragSessionEvent> overs = <DragSessionEvent>[];
  final List<DragSessionEvent> drops = <DragSessionEvent>[];
  int leaves = 0;
  Uint8List? droppedBytes;

  @override
  DropResponse onDragEnter(DragSessionEvent event) {
    enters.add(event);
    return response;
  }

  @override
  DropResponse onDragOver(DragSessionEvent event) {
    overs.add(event);
    return response;
  }

  @override
  void onDragLeave() => leaves++;

  @override
  Future<DragAction> onDrop(DragSessionEvent event) async {
    drops.add(event);
    if (throwOnDrop) throw StateError('synthetic drop failure');
    final List<String>? parallel = parallelFormats;
    if (parallel != null) {
      // Both reads are started before either is awaited, which is what a
      // handler wanting two representations of one drop actually does.
      parallelResults = await Future.wait<Uint8List?>(<Future<Uint8List?>>[
        for (final String format in parallel) event.data.readBytes(format),
      ]);
      return dropAction;
    }
    final String? format = readFormat;
    if (format == null) return dropAction;
    droppedBytes = await event.data.readBytes(format);
    return droppedBytes == null ? DragAction.none : dropAction;
  }
}

/// The smallest thing that satisfies [NativeWindow]; the backend adapter only
/// reads [id] and hands the window to the injected XID lookup.
final class _FakeNativeWindow implements NativeWindow {
  _FakeNativeWindow(this.id, {this.xcbWindow = _ourWindow});

  @override
  final NativeWindowId id;

  final int xcbWindow;

  @override
  int get generation => 0;

  @override
  Size get clientSize => const Size(100, 100);

  @override
  double get renderScale => _scale;

  @override
  double get desktopScale => _scale;

  @override
  WindowState get state => WindowState.normal;

  @override
  List<NativeSurfaceDescriptor> get surfaces =>
      const <NativeSurfaceDescriptor>[];

  @override
  Stream<PlatformWindowEvent> get events => const Stream<
      PlatformWindowEvent>.empty();

  @override
  bool isDisposed = false;

  @override
  void show() {}

  @override
  void hide() {}

  @override
  void close() {}

  @override
  void dispose() => isDisposed = true;

  @override
  void setTitle(String value) {}

  @override
  void setBounds(Rect bounds) {}

  @override
  void setCursor(SystemCursor cursor) {}

  @override
  void requestRedraw([Rect? dirtyRect]) {}

  @override
  Offset screenToClient(Offset screenPosition) => screenPosition;

  @override
  Offset clientToScreen(Offset clientPosition) => clientPosition;
}


final class _ByteWrite {
  _ByteWrite(this.window, this.property, this.type, this.bytes);

  final int window;
  final int property;
  final int type;
  final Uint8List bytes;
}

final class _SelectionNotify {
  _SelectionNotify({
    required this.requestor,
    required this.selection,
    required this.target,
    required this.property,
    required this.time,
  });

  final int requestor;
  final int selection;
  final int target;
  final int property;
  final int time;
}
