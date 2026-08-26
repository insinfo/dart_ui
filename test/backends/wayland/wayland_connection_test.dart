import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/wayland/wayland_connection.dart';
import 'package:dart_ui/src/backends/wayland/wayland_events.dart';
import 'package:dart_ui/src/backends/wayland/wayland_positioner.dart';
import 'package:dart_ui/src/backends/wayland/wayland_protocol.dart';
import 'package:dart_ui/src/backends/wayland/wayland_shm.dart';
import 'package:dart_ui/src/backends/wayland/wayland_transport.dart';
import 'package:dart_ui/src/backends/wayland/wayland_wire.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/clipboard.dart';
import 'package:dart_ui/src/widgets/popup.dart';
import 'package:test/test.dart';

const String _sampleKeymap = '''
xkb_keymap {
xkb_keycodes { <AC01> = 38; };
xkb_symbols { key <AC01> { [ a, A ] }; };
};
''';

void main() {
  late _FakeCompositor compositor;
  late _FakeAllocator allocator;

  setUp(() {
    compositor = _FakeCompositor();
    allocator = _FakeAllocator();
  });

  WaylandConnection openOk() {
    final attempt = WaylandConnection.open(
      transport: compositor,
      allocator: allocator,
    );
    expect(attempt.succeeded, isTrue, reason: attempt.diagnostics.join('\n'));
    final connection = attempt.connection! as WaylandConnection;
    // The seat capabilities arrive during the final handshake roundtrip and
    // queue get_pointer/get_keyboard. Flush them here so each test starts
    // with an idle protocol connection and can inspect only its own requests.
    connection.flush();
    return connection;
  }

  group('handshake', () {
    test('binds the required globals over two roundtrips', () {
      final connection = openOk();

      expect(connection.isValid, isTrue);
      expect(
        connection.globalInterfaces,
        containsAll(<String>[
          'wl_compositor',
          'wl_shm',
          'wl_seat',
          'wl_output',
          'xdg_wm_base',
        ]),
      );
      expect(compositor.boundInterfaces,
          containsAll(<String>['wl_compositor', 'wl_shm', 'xdg_wm_base']));
      expect(connection.shmFormats, contains(wlShmFormatArgb8888));
      expect(connection.supportsShmPresentation, isTrue);
      connection.dispose();
      expect(compositor.isDisposed, isTrue);
    });

    test('a compositor without xdg_wm_base is refused with the reason', () {
      compositor.advertiseWmBase = false;
      final attempt = WaylandConnection.open(
        transport: compositor,
        allocator: allocator,
      );

      expect(attempt.succeeded, isFalse);
      expect(
        attempt.diagnostics.map((d) => d.message),
        anyElement(contains('lacks required globals')),
      );
      expect(compositor.isDisposed, isTrue,
          reason: 'a refused connection must not leak its transport');
    });

    test('missing wl_shm keeps the connection but not CPU presentation', () {
      compositor.advertiseShm = false;
      final connection = openOk();

      expect(connection.supportsShmPresentation, isFalse);
      expect(() => connection.createShmBuffer(pixelWidth: 4, pixelHeight: 4),
          throwsStateError);
    });

    test('output scale feeds the buffer scale hint', () {
      compositor.outputScale = 2;
      final connection = openOk();
      expect(connection.bufferScaleHint, 2);
    });
  });

  group('toplevel lifecycle', () {
    test('creation issues the canonical request sequence', () {
      final connection = openOk();
      compositor.requests.clear();
      final ids = connection.createToplevel(const WaylandToplevelRequest(
        width: 640,
        height: 480,
        title: 'janela',
        appId: 'dart_ui',
        resizable: true,
      ));

      final opcodesBySender =
          compositor.requests.map((r) => (r.objectId, r.opcode)).toList();
      expect(opcodesBySender, <(int, int)>[
        (compositor.compositorId, wlCompositorRequestCreateSurface),
        (compositor.wmBaseId, xdgWmBaseRequestGetXdgSurface),
        (ids.xdgSurfaceId, xdgSurfaceRequestGetToplevel),
        (ids.toplevelId, xdgToplevelRequestSetTitle),
        (ids.toplevelId, xdgToplevelRequestSetAppId),
        (ids.surfaceId, wlSurfaceRequestCommit),
      ]);
      final title = WaylandMessageReader(compositor.requests[3].payload);
      expect(title.readString(), 'janela');
    });

    test('a fixed-size toplevel pins min and max to the same box', () {
      final connection = openOk();
      compositor.requests.clear();
      connection.createToplevel(const WaylandToplevelRequest(
        width: 300,
        height: 200,
        title: 't',
        appId: 'dart_ui',
        resizable: false,
      ));

      final sizes = compositor.requests
          .where((r) =>
              r.opcode == xdgToplevelRequestSetMinSize ||
              r.opcode == xdgToplevelRequestSetMaxSize)
          .map((r) {
        final reader = WaylandMessageReader(r.payload);
        return (r.opcode, reader.readInt(), reader.readInt());
      }).toList();
      expect(sizes, <(int, int, int)>[
        (xdgToplevelRequestSetMinSize, 300, 200),
        (xdgToplevelRequestSetMaxSize, 300, 200),
      ]);
    });

    test('configure events surface with the wl_surface id attached', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      compositor.sendToplevelConfigure(ids.toplevelId, 800, 600,
          states: <int>[xdgToplevelStateActivated]);
      compositor.sendSurfaceConfigure(ids.xdgSurfaceId, 7);

      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.xdgToplevelConfigure);
      expect(raw.surfaceId, ids.surfaceId);
      expect(raw.width, 800);
      expect(raw.stateFlags, 1 << xdgToplevelStateActivated);

      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.xdgSurfaceConfigure);
      expect(raw.surfaceId, ids.surfaceId);
      expect(raw.serial, 7);

      expect(connection.pollEventInto(raw), isFalse);
    });

    test('ack_configure goes to the xdg_surface with the serial', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      compositor.requests.clear();
      connection.ackConfigure(ids, 41);
      connection.flush();

      final ack = compositor.requests.single;
      expect(ack.objectId, ids.xdgSurfaceId);
      expect(ack.opcode, xdgSurfaceRequestAckConfigure);
      expect(WaylandMessageReader(ack.payload).readUint(), 41);
    });

    test('close events route through the toplevel mapping', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      compositor.sendToplevelClose(ids.toplevelId);

      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.xdgToplevelClose);
      expect(raw.surfaceId, ids.surfaceId);
    });

    test('destruction tears down role, xdg surface and surface in order', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      compositor.requests.clear();
      connection.destroyToplevel(ids);

      expect(
        compositor.requests.map((r) => (r.objectId, r.opcode)).toList(),
        <(int, int)>[
          (ids.toplevelId, xdgToplevelRequestDestroy),
          (ids.xdgSurfaceId, xdgSurfaceRequestDestroy),
          (ids.surfaceId, wlSurfaceRequestDestroy),
        ],
      );
    });

    test('ids confirmed dead by delete_id are recycled', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      connection.destroyToplevel(ids);
      compositor.sendDeleteId(ids.toplevelId);

      // Drain the delete_id (it produces no window event).
      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isFalse);

      final next = connection.createToplevel(_request());
      expect(
        <int>[next.surfaceId, next.xdgSurfaceId, next.toplevelId],
        contains(ids.toplevelId),
      );
    });
  });

  group('wl_data_device clipboard', () {
    test('binds manager and creates a data device for the seat', () {
      final connection = openOk();

      expect(connection.supportsClipboard, isTrue);
      expect(compositor.boundInterfaces,
          contains(wlDataDeviceManagerInterfaceName));
      expect(compositor.dataDeviceId, isPositive);
    });

    test('refuses ownership before receiving an input serial', () {
      final connection = openOk();

      expect(
        () => connection.setClipboardText('not yet'),
        throwsA(isA<ClipboardException>()),
      );
      expect(compositor.selectionSourceId, 0);
    });

    test('publishes and serves UTF-8 until the source is cancelled', () async {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      compositor.sendPointerEnter(ids.surfaceId, 41, x: 1, y: 2);
      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isTrue);

      connection.setClipboardText('olá ✅');
      final sourceId = compositor.selectionSourceId;
      expect(sourceId, isPositive);
      expect(compositor.selectionSerial, 41);
      expect(compositor.sourceMimes[sourceId],
          containsAll(wlClipboardAcceptedTextMimes));
      expect(await connection.readClipboardText(), 'olá ✅',
          reason: 'our own selection must not deadlock through a pipe');

      compositor.sendSourceSend(sourceId, wlClipboardTextMime, 701);
      expect(connection.pollEventInto(raw), isFalse);
      expect(utf8.decode(compositor.writtenFds[701]!), 'olá ✅');
      expect(compositor.closedFds, contains(701));

      compositor.sendSourceCancelled(sourceId);
      expect(connection.pollEventInto(raw), isFalse);
      expect(
        compositor.requests,
        anyElement(
          isA<_Request>()
              .having((r) => r.objectId, 'objectId', sourceId)
              .having(
                (r) => r.opcode,
                'opcode',
                wlDataSourceRequestDestroy,
              ),
        ),
      );
      expect(await connection.readClipboardText(), isNull);
    });

    test('receives an external UTF-8 offer and closes both pipe ends',
        () async {
      final connection = openOk();
      final offerId = compositor.sendSelectionOffer(
        <String>[wlClipboardTextMime, 'image/png'],
        utf8.encode('externo'),
      );
      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isFalse,
          reason: 'selection protocol events are internal');

      expect(await connection.readClipboardText(), 'externo');
      expect(compositor.lastReceivedOfferId, offerId);
      expect(compositor.lastReceivedMime, wlClipboardTextMime);
      expect(compositor.closedFds, containsAll(<int>[800, 801]));
    });

    test('an offer without a text MIME is an empty clipboard', () async {
      final connection = openOk();
      compositor.sendSelectionOffer(<String>['image/png'], <int>[1, 2, 3]);
      final raw = WaylandRawEvent();
      connection.pollEventInto(raw);

      expect(await connection.readClipboardText(), isNull);
      expect(compositor.pipeCreations, 0,
          reason: 'unsupported data must not open a transfer pipe');
    });

    test('replacing the selection destroys the previous offer', () {
      final connection = openOk();
      final first = compositor.sendSelectionOffer(
        <String>[wlClipboardTextMime],
        utf8.encode('one'),
      );
      final raw = WaylandRawEvent();
      connection.pollEventInto(raw);
      compositor.requests.clear();

      compositor.sendSelectionOffer(
        <String>[wlClipboardTextMime],
        utf8.encode('two'),
      );
      connection.pollEventInto(raw);

      expect(
        compositor.requests,
        contains(
          isA<_Request>()
              .having((r) => r.objectId, 'objectId', first)
              .having((r) => r.opcode, 'opcode', wlDataOfferRequestDestroy),
        ),
      );
    });

    test('a stalled external owner is a failure and still closes its pipe',
        () async {
      final connection = openOk();
      compositor.sendSelectionOffer(
        <String>[wlClipboardTextMime],
        utf8.encode('ignored'),
      );
      compositor.failPipeRead = true;
      final raw = WaylandRawEvent();
      connection.pollEventInto(raw);

      await expectLater(
        connection.readClipboardText(),
        throwsA(isA<ClipboardException>()),
      );
      expect(compositor.closedFds, containsAll(<int>[800, 801]));
    });

    test('a compositor without data-device keeps windows but no clipboard', () {
      compositor.advertiseDataDevice = false;
      final connection = openOk();

      expect(connection.supportsClipboard, isFalse);
      expect(
        () => connection.setClipboardText('x'),
        throwsA(isA<ClipboardException>()),
      );
    });
  });

  group('wl_shm presentation', () {
    test('a buffer costs one pool, one buffer and the pool destroy', () {
      final connection = openOk();
      compositor.requests.clear();
      final buffer = connection.createShmBuffer(pixelWidth: 16, pixelHeight: 8);

      expect(allocator.allocated.single.byteLength, 16 * 8 * 4);
      final createPool = compositor.requests[0];
      expect(createPool.objectId, compositor.shmId);
      expect(createPool.opcode, wlShmRequestCreatePool);
      expect(createPool.fds, <int>[allocator.allocated.single.fd],
          reason: 'the pool fd must ride as ancillary data');
      final poolReader = WaylandMessageReader(createPool.payload);
      final poolId = poolReader.readNewId();
      expect(poolReader.readInt(), 16 * 8 * 4);

      final createBuffer = compositor.requests[1];
      expect(createBuffer.objectId, poolId);
      final bufferReader = WaylandMessageReader(createBuffer.payload);
      bufferReader.readNewId();
      expect(bufferReader.readInt(), 0); // offset
      expect(bufferReader.readInt(), 16); // width
      expect(bufferReader.readInt(), 8); // height
      expect(bufferReader.readInt(), 64); // stride
      expect(bufferReader.readUint(), wlShmFormatArgb8888);

      expect(compositor.requests[2].objectId, poolId);
      expect(compositor.requests[2].opcode, wlShmPoolRequestDestroy);

      expect(buffer.framebuffer.width, 16);
      expect(buffer.framebuffer.pixels, same(allocator.allocated.single.bytes));
    });

    test('present attaches, damages in buffer pixels and commits', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      final buffer = connection.createShmBuffer(pixelWidth: 16, pixelHeight: 8);
      compositor.requests.clear();

      final failure = connection.presentShmBuffer(
        surfaceId: ids.surfaceId,
        buffer: buffer,
        damage: const WaylandCpuDamage(x: 1, y: 2, width: 3, height: 4),
        bufferScale: 1,
      );

      expect(failure, isNull);
      expect(
        compositor.requests.map((r) => (r.objectId, r.opcode)).toList(),
        <(int, int)>[
          (ids.surfaceId, wlSurfaceRequestAttach),
          (ids.surfaceId, wlSurfaceRequestDamageBuffer),
          (ids.surfaceId, wlSurfaceRequestCommit),
        ],
      );
      final damage = WaylandMessageReader(compositor.requests[1].payload);
      expect(
        <int>[
          damage.readInt(),
          damage.readInt(),
          damage.readInt(),
          damage.readInt(),
        ],
        <int>[1, 2, 3, 4],
      );
    });

    test('a scaled present sets the buffer scale first', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      final buffer = connection.createShmBuffer(pixelWidth: 16, pixelHeight: 8);
      compositor.requests.clear();

      connection.presentShmBuffer(
        surfaceId: ids.surfaceId,
        buffer: buffer,
        damage: const WaylandCpuDamage(x: 0, y: 0, width: 16, height: 8),
        bufferScale: 2,
      );

      expect(compositor.requests.first.opcode, wlSurfaceRequestSetBufferScale);
      expect(
        WaylandMessageReader(compositor.requests.first.payload).readInt(),
        2,
      );
    });

    test('destroying a buffer frees protocol object and memory', () {
      final connection = openOk();
      final buffer = connection.createShmBuffer(pixelWidth: 4, pixelHeight: 4);
      compositor.requests.clear();
      connection.destroyShmBuffer(buffer);
      connection.destroyShmBuffer(buffer); // idempotent

      expect(compositor.requests.single.opcode, wlBufferRequestDestroy);
      expect(allocator.allocated.single.isDisposed, isTrue);

      final failure = connection.presentShmBuffer(
        surfaceId: 3,
        buffer: buffer,
        damage: const WaylandCpuDamage(x: 0, y: 0, width: 1, height: 1),
        bufferScale: 1,
      );
      expect(failure, isNotNull, reason: 'a released buffer must be refused');
    });
  });

  group('input routing', () {
    test('pointer focus attaches surface ids to focus-free events', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      connection.flush(); // deliver get_pointer from the capabilities event
      compositor.sendPointerEnter(ids.surfaceId, 10, x: 4.5, y: 5.5);
      compositor.sendPointerMotion(100, x: 6.0, y: 7.0);
      compositor.sendPointerButton(11, 120, btnLeft, pressed: true);
      compositor.sendPointerLeave(ids.surfaceId, 12);
      compositor.sendPointerMotion(130, x: 1.0, y: 1.0);

      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.pointerEnter);
      expect(raw.surfaceId, ids.surfaceId);
      expect(raw.x, 4.5);

      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.pointerMotion);
      expect(raw.surfaceId, ids.surfaceId);
      expect(raw.x, 6.0);

      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.pointerButton);
      expect(raw.key, btnLeft);
      expect(raw.x, 6.0, reason: 'buttons reuse the last motion position');

      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.pointerLeave);

      expect(connection.pollEventInto(raw), isFalse,
          reason: 'motion without focus must be dropped, not misrouted');
    });

    test('the keymap fd is mapped, parsed and closed', () {
      allocator.sharedMemory[555] = _keymapBytes();
      compositor.keymapFd = 555;
      compositor.keymapSize = _keymapBytes().length;
      final connection = openOk();
      connection.flush(); // deliver get_keyboard
      // Let the keymap event arrive.
      final raw = WaylandRawEvent();
      connection.pollEventInto(raw);

      expect(connection.keymap, isNotNull);
      expect(connection.keymap!.source, 'xkb-v1');
      expect(compositor.closedFds, contains(555));
    });

    test('an unreadable keymap falls back to evdev US and says so', () {
      compositor.keymapFd = 556; // not registered with the allocator
      compositor.keymapSize = 128;
      final connection = openOk();
      connection.flush();
      final raw = WaylandRawEvent();
      connection.pollEventInto(raw);

      expect(connection.keymap!.source, 'evdev-us-fallback');
      expect(connection.recentErrors, isNotEmpty);
    });

    test('modifiers update connection state without surfacing events', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      connection.flush();
      compositor.sendKeyboardEnter(ids.surfaceId, 20);
      compositor.sendKeyboardModifiers(21, depressed: 0x01);
      compositor.sendKeyboardKey(22, 300, 30, pressed: true);

      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.keyboardEnter);
      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.keyboardKey);
      expect(raw.surfaceId, ids.surfaceId);
      expect(raw.key, 30);
      expect(connection.modifiers.shift, isTrue);
    });
  });

  group('popups', () {
    WaylandPositionerSpec spec({
      int width = 180,
      int height = 240,
      Set<PopupAdjustment> adjustments = const <PopupAdjustment>{
        PopupAdjustment.flipY,
        PopupAdjustment.slideX,
      },
    }) =>
        WaylandPositionerSpec.fromRequest(PopupRequest(
          anchorRect: const Rect.fromLTWH(10, 20, 100, 30),
          size: Size(width.toDouble(), height.toDouble()),
          adjustments: adjustments,
        ));

    test('creation configures a positioner and consumes it at once', () {
      final connection = openOk();
      final parent = connection.createToplevel(_request());
      // A grab needs an input serial; give the connection one.
      connection.flush();
      compositor.requests.clear();

      final popup = connection.createPopup(WaylandPopupRequest(
        parent: parent,
        positioner: spec(),
        grab: false,
      ));

      final opcodes =
          compositor.requests.map((r) => (r.objectId, r.opcode)).toList();
      // The positioner's id is the new_id inside create_positioner, not the
      // sender - the sender is xdg_wm_base.
      final positionerId =
          WaylandMessageReader(compositor.requests.first.payload).readNewId();
      expect(opcodes, <(int, int)>[
        (compositor.wmBaseId, xdgWmBaseRequestCreatePositioner),
        (positionerId, xdgPositionerRequestSetSize),
        (positionerId, xdgPositionerRequestSetAnchorRect),
        (positionerId, xdgPositionerRequestSetAnchor),
        (positionerId, xdgPositionerRequestSetGravity),
        (positionerId, xdgPositionerRequestSetConstraintAdjustment),
        (compositor.compositorId, wlCompositorRequestCreateSurface),
        (compositor.wmBaseId, xdgWmBaseRequestGetXdgSurface),
        (popup.xdgSurfaceId, xdgSurfaceRequestGetPopup),
        (positionerId, xdgPositionerRequestDestroy),
        (popup.surfaceId, wlSurfaceRequestCommit),
      ]);
    });

    test('the positioner carries the translated geometry', () {
      final connection = openOk();
      final parent = connection.createToplevel(_request());
      compositor.requests.clear();
      connection.createPopup(WaylandPopupRequest(
        parent: parent,
        positioner: spec(width: 200, height: 300),
        grab: false,
      ));

      final positionerId =
          WaylandMessageReader(compositor.requests.first.payload).readNewId();
      final size = compositor.requests.firstWhere((r) =>
          r.objectId == positionerId &&
          r.opcode == xdgPositionerRequestSetSize);
      final sizeReader = WaylandMessageReader(size.payload);
      expect(sizeReader.readInt(), 200);
      expect(sizeReader.readInt(), 300);

      final rect = compositor.requests.firstWhere((r) =>
          r.objectId == positionerId &&
          r.opcode == xdgPositionerRequestSetAnchorRect);
      final rectReader = WaylandMessageReader(rect.payload);
      expect(
        <int>[
          rectReader.readInt(),
          rectReader.readInt(),
          rectReader.readInt(),
          rectReader.readInt(),
        ],
        <int>[10, 20, 100, 30],
      );
    });

    test('get_popup names the parent xdg_surface', () {
      final connection = openOk();
      final parent = connection.createToplevel(_request());
      compositor.requests.clear();
      final popup = connection.createPopup(WaylandPopupRequest(
        parent: parent,
        positioner: spec(),
        grab: false,
      ));

      final getPopup = compositor.requests.firstWhere((r) =>
          r.objectId == popup.xdgSurfaceId &&
          r.opcode == xdgSurfaceRequestGetPopup);
      final reader = WaylandMessageReader(getPopup.payload);
      expect(reader.readNewId(), popup.toplevelId);
      expect(reader.readObject(), parent.xdgSurfaceId,
          reason: 'a popup is parented to the xdg_surface, not the toplevel');
    });

    test('a grab is skipped, with a reason, until the user has acted', () {
      final connection = openOk();
      final parent = connection.createToplevel(_request());
      compositor.requests.clear();

      final popup = connection.createPopup(WaylandPopupRequest(
        parent: parent,
        positioner: spec(),
      ));

      expect(
        compositor.requests.where((r) =>
            r.objectId == popup.toplevelId && r.opcode == xdgPopupRequestGrab),
        isEmpty,
        reason: 'grabbing without an input serial kills the connection',
      );
      expect(connection.recentErrors.last, contains('no input serial'));
    });

    test('a grab is taken with the latest input serial once one exists', () {
      final connection = openOk();
      final parent = connection.createToplevel(_request());
      connection.flush();
      compositor.sendPointerEnter(parent.surfaceId, 10, x: 1, y: 1);
      compositor.sendPointerButton(77, 100, btnLeft, pressed: true);
      final raw = WaylandRawEvent();
      while (connection.pollEventInto(raw)) {}
      compositor.requests.clear();

      final popup = connection.createPopup(WaylandPopupRequest(
        parent: parent,
        positioner: spec(),
      ));

      final grab = compositor.requests.firstWhere((r) =>
          r.objectId == popup.toplevelId && r.opcode == xdgPopupRequestGrab);
      final reader = WaylandMessageReader(grab.payload);
      expect(reader.readObject(), compositor.seatId);
      expect(reader.readUint(), 77,
          reason: 'the grab must quote the serial of the click that opened it');
    });

    test('configure surfaces the compositor placement, not the request', () {
      final connection = openOk();
      final parent = connection.createToplevel(_request());
      final popup = connection.createPopup(WaylandPopupRequest(
        parent: parent,
        positioner: spec(),
        grab: false,
      ));
      // The compositor flipped the popup upwards and narrowed it.
      compositor.sendPopupConfigure(popup.toplevelId, 10, -240, 180, 200);

      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.popupConfigure);
      expect(raw.surfaceId, popup.surfaceId);
      expect(raw.x, 10);
      expect(raw.y, -240);
      expect(raw.width, 180);
      expect(raw.height, 200);
    });

    test('popup_done dismisses the whole nested chain, deepest first', () {
      final connection = openOk();
      final parent = connection.createToplevel(_request());
      final menu = connection.createPopup(WaylandPopupRequest(
        parent: parent,
        positioner: spec(),
        grab: false,
      ));
      final submenu = connection.createPopup(WaylandPopupRequest(
        parent: menu,
        positioner: spec(),
        grab: false,
      ));
      final subsubmenu = connection.createPopup(WaylandPopupRequest(
        parent: submenu,
        positioner: spec(),
        grab: false,
      ));

      compositor.sendPopupDone(menu.toplevelId);

      final dismissed = <int>[];
      final raw = WaylandRawEvent();
      while (connection.pollEventInto(raw)) {
        if (raw.type == WaylandRawEventType.popupDone) {
          dismissed.add(raw.surfaceId);
        }
      }
      expect(dismissed, <int>[
        subsubmenu.surfaceId,
        submenu.surfaceId,
        menu.surfaceId,
      ]);
    });

    test('destroying a popup uses xdg_popup.destroy, not toplevel.destroy', () {
      final connection = openOk();
      final parent = connection.createToplevel(_request());
      final popup = connection.createPopup(WaylandPopupRequest(
        parent: parent,
        positioner: spec(),
        grab: false,
      ));
      compositor.requests.clear();

      connection.destroyToplevel(popup);

      expect(
        compositor.requests.map((r) => (r.objectId, r.opcode)).toList(),
        <(int, int)>[
          (popup.toplevelId, xdgPopupRequestDestroy),
          (popup.xdgSurfaceId, xdgSurfaceRequestDestroy),
          (popup.surfaceId, wlSurfaceRequestDestroy),
        ],
      );
    });

    test('a popup without xdg_wm_base cannot be created', () {
      compositor.advertiseWmBase = false;
      final attempt = WaylandConnection.open(
        transport: compositor,
        allocator: allocator,
      );
      expect(attempt.succeeded, isFalse,
          reason: 'no shell means no windows at all, popups included');
    });
  });

  group('xdg-decoration', () {
    test('is advertised and negotiated to server-side when available', () {
      final connection = openOk();
      expect(connection.supportsServerSideDecorations, isTrue);

      final ids = connection.createToplevel(_request());
      compositor.requests.clear();
      connection.requestServerSideDecoration(ids);

      final get = compositor.requests.firstWhere(
          (r) => r.opcode == xdgDecorationManagerRequestGetToplevelDecoration);
      final reader = WaylandMessageReader(get.payload);
      reader.readNewId();
      expect(reader.readObject(), ids.toplevelId);

      final setMode = compositor.requests.firstWhere((r) =>
          r.objectId == compositor.lastDecorationId &&
          r.opcode == xdgToplevelDecorationRequestSetMode);
      expect(
        WaylandMessageReader(setMode.payload).readUint(),
        xdgToplevelDecorationModeServerSide,
      );
    });

    test('the configure answer reaches the window as a raw event', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      connection.requestServerSideDecoration(ids);
      compositor.sendDecorationConfigure(
        compositor.lastDecorationId,
        xdgToplevelDecorationModeServerSide,
      );

      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.type, WaylandRawEventType.decorationConfigure);
      expect(raw.surfaceId, ids.surfaceId);
      expect(raw.state, xdgToplevelDecorationModeServerSide);
    });

    test('a compositor that answers client-side is reported as such', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      connection.requestServerSideDecoration(ids);
      compositor.sendDecorationConfigure(
        compositor.lastDecorationId,
        xdgToplevelDecorationModeClientSide,
      );

      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isTrue);
      expect(raw.state, xdgToplevelDecorationModeClientSide);
    });

    test('without the global, the request is a silent no-op', () {
      compositor.advertiseDecoration = false;
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      compositor.requests.clear();

      connection.requestServerSideDecoration(ids);

      expect(connection.supportsServerSideDecorations, isFalse);
      expect(compositor.requests, isEmpty,
          reason: 'the framework draws its own frame instead');
    });

    test('destroying the toplevel destroys its decoration first', () {
      final connection = openOk();
      final ids = connection.createToplevel(_request());
      connection.requestServerSideDecoration(ids);
      final decorationId = compositor.lastDecorationId;
      compositor.requests.clear();

      connection.destroyToplevel(ids);

      expect(
        compositor.requests.first,
        isA<_Request>()
            .having((r) => r.objectId, 'objectId', decorationId)
            .having(
                (r) => r.opcode, 'opcode', xdgToplevelDecorationRequestDestroy),
      );
    });
  });

  group('failure paths', () {
    test('wl_display.error poisons the connection with the story', () {
      final connection = openOk();
      compositor.sendDisplayError(7, wlDisplayErrorInvalidMethod, 'bad call');
      final raw = WaylandRawEvent();
      expect(connection.pollEventInto(raw), isFalse);

      expect(connection.isValid, isFalse);
      expect(connection.recentErrors.single, contains('invalid_method'));
      expect(connection.recentErrors.single, contains('bad call'));
    });

    test('ping is answered with pong immediately', () {
      final connection = openOk();
      compositor.requests.clear();
      compositor.sendPing(99);
      final raw = WaylandRawEvent();
      connection.pollEventInto(raw);

      final pong = compositor.requests.single;
      expect(pong.objectId, compositor.wmBaseId);
      expect(pong.opcode, xdgWmBaseRequestPong);
      expect(WaylandMessageReader(pong.payload).readUint(), 99);
    });
  });
}

WaylandToplevelRequest _request() => const WaylandToplevelRequest(
      width: 640,
      height: 480,
      title: 'test',
      appId: 'dart_ui',
      resizable: true,
    );

Uint8List _keymapBytes() =>
    Uint8List.fromList(<int>[..._sampleKeymap.codeUnits, 0]);

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final class _FakeShmMemory implements WaylandShmMemory {
  _FakeShmMemory(this.fd, this.byteLength) : bytes = Uint8List(byteLength);

  @override
  final int fd;
  final int byteLength;

  @override
  final Uint8List bytes;

  @override
  bool isDisposed = false;

  @override
  void dispose() => isDisposed = true;
}

final class _FakeAllocator implements WaylandShmAllocator {
  final List<_FakeShmMemory> allocated = <_FakeShmMemory>[];
  final Map<int, Uint8List> sharedMemory = <int, Uint8List>{};
  int _nextFd = 100;

  @override
  bool get isAvailable => true;

  @override
  WaylandShmMemory allocate(int byteLength) {
    final memory = _FakeShmMemory(_nextFd++, byteLength);
    allocated.add(memory);
    return memory;
  }

  @override
  Uint8List? readSharedMemory(int fd, int byteLength) {
    final bytes = sharedMemory[fd];
    if (bytes == null) return null;
    return Uint8List.fromList(bytes);
  }
}

/// One request the client sent, with the fds that rode along.
final class _Request {
  _Request(this.objectId, this.opcode, this.payload, this.fds);

  final int objectId;
  final int opcode;
  final Uint8List payload;
  final List<int> fds;
}

/// An in-memory transport whose other end is a scripted mini-compositor: it
/// parses the client's requests on flush, answers the handshake, and lets the
/// test inject events. No socket, no FFI, no Linux.
final class _FakeCompositor implements WaylandTransport {
  bool advertiseWmBase = true;
  bool advertiseDecoration = true;
  bool advertiseShm = true;
  bool advertiseDataDevice = true;
  bool failPipeRead = false;
  int outputScale = 1;
  int keymapFd = -1;
  int keymapSize = 0;

  final List<_Request> requests = <_Request>[];
  final List<int> closedFds = <int>[];
  final List<String> boundInterfaces = <String>[];

  int registryId = 0;
  int compositorId = 0;
  int shmId = 0;
  int seatId = 0;
  int wmBaseId = 0;
  int outputId = 0;
  int pointerId = 0;
  int keyboardId = 0;
  int dataDeviceManagerId = 0;
  int decorationManagerId = 0;
  int lastDecorationId = 0;
  int dataDeviceId = 0;
  int selectionSourceId = 0;
  int selectionSerial = 0;
  int lastReceivedOfferId = 0;
  String? lastReceivedMime;
  int pipeCreations = 0;

  final Map<int, Set<String>> sourceMimes = <int, Set<String>>{};
  final Map<int, Uint8List> writtenFds = <int, Uint8List>{};
  final Map<int, Uint8List> _selectionBytesByOffer = <int, Uint8List>{};
  final Map<int, int> _readFdByWriteFd = <int, int>{};
  final Map<int, Uint8List> _pipeBytesByReadFd = <int, Uint8List>{};
  int _nextServerId = 0xff000001;
  int _nextPipeReadFd = 800;

  final WaylandWireDecoder _outDecoder = WaylandWireDecoder();
  final WaylandWireMessage _outMessage = WaylandWireMessage();
  final List<int> _pendingOutFds = <int>[];
  final BytesBuilder _inbound = BytesBuilder(copy: true);
  final List<int> _inboundFds = <int>[];
  final WaylandMessageWriter _events = WaylandMessageWriter();

  bool _disposed = false;

  @override
  bool get isOpen => !_disposed;

  @override
  bool get isDisposed => _disposed;

  @override
  void dispose() => _disposed = true;

  @override
  void queueMessage(Uint8List bytes, List<int> fds) {
    _outDecoder.addBytes(bytes);
    _pendingOutFds.addAll(fds);
  }

  @override
  bool flush() {
    while (_outDecoder.nextMessage(_outMessage)) {
      final payload = Uint8List.fromList(_outMessage.payload);
      final fds = _takeFdsFor(_outMessage.objectId, _outMessage.opcode);
      requests.add(
        _Request(_outMessage.objectId, _outMessage.opcode, payload, fds),
      );
      _handleRequest(_outMessage.objectId, _outMessage.opcode, payload, fds);
    }
    return true;
  }

  List<int> _takeFdsFor(int objectId, int opcode) {
    // Both shm pool creation and data-offer receive carry one descriptor.
    if ((objectId == shmId && opcode == wlShmRequestCreatePool) ||
        (opcode == wlDataOfferRequestReceive &&
            _selectionBytesByOffer.containsKey(objectId))) {
      final fds = List<int>.of(_pendingOutFds);
      _pendingOutFds.clear();
      return fds;
    }
    return const <int>[];
  }

  @override
  int receive(WaylandWireDecoder decoder, List<int> receivedFds) {
    if (_inbound.isEmpty) return 0;
    final bytes = _inbound.takeBytes();
    decoder.addBytes(bytes);
    receivedFds.addAll(_inboundFds);
    _inboundFds.clear();
    return bytes.length;
  }

  @override
  bool waitForActivity(int timeoutMilliseconds) => false;

  @override
  bool signalWake() => true;

  @override
  void closeFd(int fd) => closedFds.add(fd);

  @override
  ({int readFd, int writeFd})? createPipe() {
    pipeCreations++;
    final readFd = _nextPipeReadFd;
    final writeFd = readFd + 1;
    _nextPipeReadFd += 2;
    _readFdByWriteFd[writeFd] = readFd;
    return (readFd: readFd, writeFd: writeFd);
  }

  @override
  bool writeAllToFd(int fd, Uint8List bytes) {
    writtenFds[fd] = Uint8List.fromList(bytes);
    return true;
  }

  @override
  Uint8List? readAllFromFd(int fd, {int timeoutMilliseconds = 2000}) =>
      failPipeRead ? null : _pipeBytesByReadFd[fd];

  void _handleRequest(
    int objectId,
    int opcode,
    Uint8List payload,
    List<int> fds,
  ) {
    if (objectId == wlDisplayObjectId) {
      final reader = WaylandMessageReader(payload);
      if (opcode == wlDisplayRequestGetRegistry) {
        registryId = reader.readNewId();
        _announceGlobals();
      } else if (opcode == wlDisplayRequestSync) {
        final callbackId = reader.readNewId();
        _event(callbackId, wlCallbackEventDone, (w) => w.putUint(0));
      }
      return;
    }
    if (objectId == registryId && opcode == wlRegistryRequestBind) {
      final reader = WaylandMessageReader(payload);
      reader.readUint(); // name
      final interface = reader.readString();
      reader.readUint(); // version
      final newId = reader.readNewId();
      boundInterfaces.add(interface);
      switch (interface) {
        case wlCompositorInterfaceName:
          compositorId = newId;
        case wlShmInterfaceName:
          shmId = newId;
          _event(
              shmId, wlShmEventFormat, (w) => w.putUint(wlShmFormatArgb8888));
          _event(
              shmId, wlShmEventFormat, (w) => w.putUint(wlShmFormatXrgb8888));
        case wlSeatInterfaceName:
          seatId = newId;
          _event(
            seatId,
            wlSeatEventCapabilities,
            (w) => w.putUint(
              wlSeatCapabilityPointer | wlSeatCapabilityKeyboard,
            ),
          );
        case wlOutputInterfaceName:
          outputId = newId;
          if (outputScale > 1) {
            _event(outputId, wlOutputEventScale, (w) => w.putInt(outputScale));
          }
        case xdgWmBaseInterfaceName:
          wmBaseId = newId;
        case wlDataDeviceManagerInterfaceName:
          dataDeviceManagerId = newId;
        case xdgDecorationManagerInterfaceName:
          decorationManagerId = newId;
      }
      return;
    }
    if (objectId == seatId) {
      final reader = WaylandMessageReader(payload);
      if (opcode == wlSeatRequestGetPointer) {
        pointerId = reader.readNewId();
      } else if (opcode == wlSeatRequestGetKeyboard) {
        keyboardId = reader.readNewId();
        if (keymapFd >= 0) {
          _inboundFds.add(keymapFd);
          _event(keyboardId, wlKeyboardEventKeymap, (w) {
            w.putUint(wlKeyboardKeymapFormatXkbV1);
            w.putFd(keymapFd);
            w.putUint(keymapSize);
          });
        }
      }
    }
    if (decorationManagerId != 0 && objectId == decorationManagerId) {
      if (opcode == xdgDecorationManagerRequestGetToplevelDecoration) {
        lastDecorationId = WaylandMessageReader(payload).readNewId();
      }
      return;
    }
    if (objectId == dataDeviceManagerId) {
      final reader = WaylandMessageReader(payload);
      if (opcode == wlDataDeviceManagerRequestGetDataDevice) {
        dataDeviceId = reader.readNewId();
        reader.readObject(); // seat
      } else if (opcode == wlDataDeviceManagerRequestCreateDataSource) {
        sourceMimes[reader.readNewId()] = <String>{};
      }
      return;
    }
    final sourceMimeSet = sourceMimes[objectId];
    if (sourceMimeSet != null && opcode == wlDataSourceRequestOffer) {
      sourceMimeSet.add(WaylandMessageReader(payload).readString());
      return;
    }
    if (objectId == dataDeviceId && opcode == wlDataDeviceRequestSetSelection) {
      final reader = WaylandMessageReader(payload);
      selectionSourceId = reader.readObject();
      selectionSerial = reader.readUint();
      return;
    }
    if (_selectionBytesByOffer.containsKey(objectId) &&
        opcode == wlDataOfferRequestReceive) {
      final reader = WaylandMessageReader(payload);
      lastReceivedOfferId = objectId;
      lastReceivedMime = reader.readString();
      final writeFd = fds.single;
      final readFd = _readFdByWriteFd[writeFd]!;
      _pipeBytesByReadFd[readFd] = _selectionBytesByOffer[objectId]!;
    }
  }

  void _announceGlobals() {
    var name = 1;
    void global(String interface, int version) {
      final thisName = name++;
      _event(registryId, wlRegistryEventGlobal, (w) {
        w.putUint(thisName);
        w.putString(interface);
        w.putUint(version);
      });
    }

    global(wlCompositorInterfaceName, 5);
    if (advertiseShm) global(wlShmInterfaceName, 1);
    global(wlSeatInterfaceName, 7);
    global(wlOutputInterfaceName, 3);
    if (advertiseWmBase) global(xdgWmBaseInterfaceName, 4);
    if (advertiseDataDevice) global(wlDataDeviceManagerInterfaceName, 3);
    if (advertiseDecoration) global(xdgDecorationManagerInterfaceName, 1);
  }

  void _event(
    int objectId,
    int opcode,
    void Function(WaylandMessageWriter writer) fill,
  ) {
    _events.begin(objectId, opcode);
    fill(_events);
    _events.fds.clear(); // server fds travel via _inboundFds directly
    _inbound.add(_events.take());
  }

  // -- test-injected events -------------------------------------------------

  int sendSelectionOffer(List<String> mimes, List<int> bytes) {
    final offerId = _nextServerId++;
    _selectionBytesByOffer[offerId] = Uint8List.fromList(bytes);
    _event(
        dataDeviceId, wlDataDeviceEventDataOffer, (w) => w.putNewId(offerId));
    for (final mime in mimes) {
      _event(offerId, wlDataOfferEventOffer, (w) => w.putString(mime));
    }
    _event(
        dataDeviceId, wlDataDeviceEventSelection, (w) => w.putObject(offerId));
    return offerId;
  }

  void sendSourceSend(int sourceId, String mime, int fd) {
    _inboundFds.add(fd);
    _event(sourceId, wlDataSourceEventSend, (w) {
      w.putString(mime);
      w.putFd(fd);
    });
  }

  void sendSourceCancelled(int sourceId) {
    _event(sourceId, wlDataSourceEventCancelled, (_) {});
  }

  void sendToplevelConfigure(
    int toplevelId,
    int width,
    int height, {
    List<int> states = const <int>[],
  }) {
    final array = Uint8List(states.length * 4);
    final data = ByteData.sublistView(array);
    for (var i = 0; i < states.length; i++) {
      data.setUint32(i * 4, states[i], Endian.little);
    }
    _event(toplevelId, xdgToplevelEventConfigure, (w) {
      w.putInt(width);
      w.putInt(height);
      w.putArray(array);
    });
  }

  void sendSurfaceConfigure(int xdgSurfaceId, int serial) {
    _event(xdgSurfaceId, xdgSurfaceEventConfigure, (w) => w.putUint(serial));
  }

  void sendPopupConfigure(
    int popupId,
    int x,
    int y,
    int width,
    int height,
  ) {
    _event(popupId, xdgPopupEventConfigure, (w) {
      w.putInt(x);
      w.putInt(y);
      w.putInt(width);
      w.putInt(height);
    });
  }

  void sendPopupDone(int popupId) {
    _event(popupId, xdgPopupEventPopupDone, (_) {});
  }

  void sendDecorationConfigure(int decorationId, int mode) {
    _event(decorationId, xdgToplevelDecorationEventConfigure,
        (w) => w.putUint(mode));
  }

  void sendToplevelClose(int toplevelId) {
    _event(toplevelId, xdgToplevelEventClose, (_) {});
  }

  void sendDeleteId(int id) {
    _event(wlDisplayObjectId, wlDisplayEventDeleteId, (w) => w.putUint(id));
  }

  void sendDisplayError(int objectId, int code, String message) {
    _event(wlDisplayObjectId, wlDisplayEventError, (w) {
      w.putObject(objectId);
      w.putUint(code);
      w.putString(message);
    });
  }

  void sendPing(int serial) {
    _event(wmBaseId, xdgWmBaseEventPing, (w) => w.putUint(serial));
  }

  void sendPointerEnter(int surfaceId, int serial,
      {required double x, required double y}) {
    _event(pointerId, wlPointerEventEnter, (w) {
      w.putUint(serial);
      w.putObject(surfaceId);
      w.putFixed(x);
      w.putFixed(y);
    });
  }

  void sendPointerLeave(int surfaceId, int serial) {
    _event(pointerId, wlPointerEventLeave, (w) {
      w.putUint(serial);
      w.putObject(surfaceId);
    });
  }

  void sendPointerMotion(int time, {required double x, required double y}) {
    _event(pointerId, wlPointerEventMotion, (w) {
      w.putUint(time);
      w.putFixed(x);
      w.putFixed(y);
    });
  }

  void sendPointerButton(int serial, int time, int button,
      {required bool pressed}) {
    _event(pointerId, wlPointerEventButton, (w) {
      w.putUint(serial);
      w.putUint(time);
      w.putUint(button);
      w.putUint(
          pressed ? wlPointerButtonStatePressed : wlPointerButtonStateReleased);
    });
  }

  void sendKeyboardEnter(int surfaceId, int serial) {
    _event(keyboardId, wlKeyboardEventEnter, (w) {
      w.putUint(serial);
      w.putObject(surfaceId);
      w.putArray(Uint8List(0));
    });
  }

  void sendKeyboardModifiers(int serial, {int depressed = 0}) {
    _event(keyboardId, wlKeyboardEventModifiers, (w) {
      w.putUint(serial);
      w.putUint(depressed);
      w.putUint(0);
      w.putUint(0);
      w.putUint(0);
    });
  }

  void sendKeyboardKey(int serial, int time, int key, {required bool pressed}) {
    _event(keyboardId, wlKeyboardEventKey, (w) {
      w.putUint(serial);
      w.putUint(time);
      w.putUint(key);
      w.putUint(
          pressed ? wlKeyboardKeyStatePressed : wlKeyboardKeyStateReleased);
    });
  }
}
