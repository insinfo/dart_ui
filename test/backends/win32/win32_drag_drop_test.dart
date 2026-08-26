/// The Win32 drop target, exercised through its own COM vtable.
///
/// What a test on this machine can and cannot prove, stated up front because
/// the difference matters:
///
///  * **Real, and proved here.** The `IDropTarget` vtable exists, its
///    `NativeCallable` trampolines are reachable, its ABI matches (a `POINTL`
///    passed by value in one register arrives with x and y in the right
///    halves), `QueryInterface`/`AddRef`/`Release` behave as COM requires, a
///    genuine `IDataObject` - itself a Dart COM server, so the whole exchange
///    is two hand-built vtables calling each other - is read through
///    `GetData`/`QueryGetData` and its `HGLOBAL` really is locked, translated
///    and freed. `RegisterDragDrop` and `RevokeDragDrop` really run against a
///    real hidden `HWND`.
///  * **Not proved here, and it cannot be.** That Windows *calls* the vtable
///    during a user's drag. That needs a second process to drag from and a
///    mouse to drag with. The calls are therefore made from Dart with exactly
///    the arguments OLE passes, which pins everything except the fact that OLE
///    is the caller.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/uia/com_server.dart';
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_drag_drop.dart';
import 'package:dart_ui/src/backends/win32/win32_ole.dart';
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/drag_drop.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

const NativeWindowId _windowId = NativeWindowId(1);

void main() {
  group('pure translation', () {
    test('a packed POINTL splits into signed halves', () {
      // 0x0000_0064_0000_00C8 is x=200, y=100 the way the ABI packs it.
      const int packed = (100 << 32) | 200;
      expect(win32PointX(packed), 200);
      expect(win32PointY(packed), 100);
    });

    test('negative screen coordinates survive, as a left monitor needs', () {
      const int packed = ((-30 & 0xFFFFFFFF) << 32) | (-40 & 0xFFFFFFFF);
      expect(win32PointX(packed), -40);
      expect(win32PointY(packed), -30,
          reason: 'reading them unsigned puts the drop 4 billion pixels away');
    });

    test('DROPEFFECT bits become actions, with SCROLL masked off', () {
      expect(
        win32ActionsFromEffect(dropEffectCopy | dropEffectMove),
        <DragAction>{DragAction.copy, DragAction.move},
      );
      expect(
        win32ActionsFromEffect(dropEffectCopy | dropEffectScroll),
        <DragAction>{DragAction.copy},
      );
      expect(win32ActionsFromEffect(dropEffectNone), isEmpty);
    });

    test('ask has no Win32 spelling and becomes a refusal', () {
      expect(win32EffectForAction(DragAction.ask), dropEffectNone);
      expect(win32EffectForAction(DragAction.link), dropEffectLink);
      expect(
        win32EffectMask(<DragAction>{DragAction.copy, DragAction.link}),
        dropEffectCopy | dropEffectLink,
      );
    });

    test('the key state names only modifiers, never the held button', () {
      expect(
        win32ModifiersFromKeyState(mkLButton | mkControlKey),
        <KeyModifier>{KeyModifier.control},
      );
      expect(
        win32ModifiersFromKeyState(mkShiftKey | mkAlt),
        <KeyModifier>{KeyModifier.shift, KeyModifier.alt},
      );
      expect(win32ModifiersFromKeyState(mkLButton), isEmpty);
    });

    test('formats translate both ways', () {
      expect(win32MimeForClipboardFormat(cfUnicodeText), DragFormats.text);
      expect(win32MimeForClipboardFormat(cfHDrop), DragFormats.uriList);
      expect(win32MimeForClipboardFormat(cfText), isNull,
          reason: 'ANSI text has no honest MIME name here');
      expect(win32ClipboardFormatForMime(DragFormats.uriList), cfHDrop);
      expect(win32ClipboardFormatForMime(DragFormats.plainText), cfUnicodeText);
      expect(win32ClipboardFormatForMime('image/png'), 0);
    });
  });

  group('reading global memory', () {
    late NativeAllocator allocator;

    setUp(() {
      final NativeAllocator? bound = NativeAllocator.tryBind();
      if (bound == null) fail('no native allocator on this platform');
      allocator = bound;
    });

    test('UTF-16 text stops at the NUL, not at the allocation size', () {
      const String text = 'caf\u00e9';
      final Pointer<Uint16> block = allocator.allocate<Uint16>(64);
      try {
        // Fill with rubbish first, so a scan that trusted the block size
        // would come back with it.
        for (int i = 0; i < 32; i++) {
          block[i] = 0x41;
        }
        for (int i = 0; i < text.length; i++) {
          block[i] = text.codeUnitAt(i);
        }
        block[text.length] = 0;
        expect(win32ReadUnicodeTextAt(block.address), text);
      } finally {
        allocator.free(block);
      }
    });

    test('an empty address reads as empty rather than crashing', () {
      expect(win32ReadUnicodeTextAt(0), isEmpty);
      expect(win32ReadDropFilesAt(0), isEmpty);
    });

    test('a wide CF_HDROP yields every path', () {
      final List<String> paths = <String>[r'C:\a.txt', r'C:\b\c.txt'];
      final Pointer<Uint8> block =
          _allocateDropFiles(allocator, paths, wide: true);
      try {
        expect(win32ReadDropFilesAt(block.address), paths);
      } finally {
        allocator.free(block);
      }
    });

    test('an ANSI CF_HDROP is not misread as UTF-16', () {
      final List<String> paths = <String>[r'C:\a.txt'];
      final Pointer<Uint8> block =
          _allocateDropFiles(allocator, paths, wide: false);
      try {
        expect(win32ReadDropFilesAt(block.address), paths);
      } finally {
        allocator.free(block);
      }
    });

    test('a header whose pFiles points inside itself is refused', () {
      final Pointer<Uint8> block = allocator.allocate<Uint8>(64);
      try {
        for (int i = 0; i < 64; i++) {
          block[i] = 0;
        }
        ByteData.sublistView(block.asTypedList(20))
            .setUint32(0, 4, Endian.little);
        expect(win32ReadDropFilesAt(block.address), isEmpty);
      } finally {
        allocator.free(block);
      }
    });
  });

  group('IDropTarget, through its own vtable', () {
    late ComServerClass<Win32DropTarget> targetClass;
    late _RecordingHandler handler;
    late Win32DropTarget target;
    late ComServerObject<Win32DropTarget> object;
    late Win32Api api;
    late Win32OleApi ole;
    late NativeAllocator allocator;

    setUp(() {
      if (!Platform.isWindows) return;
      final Win32Api? loaded = Win32Api.load().api;
      final Win32OleApi? loadedOle = Win32OleApi.load().api;
      if (loaded == null || loadedOle == null) return;
      api = loaded;
      ole = loadedOle;
      allocator = NativeAllocator.tryBind()!;
      handler = _RecordingHandler();
      targetClass = ComServerClass<Win32DropTarget>(
        'Win32DropTarget',
        <ComInterfaceSpec<Win32DropTarget>>[win32DropTargetSpec()],
      );
      target = Win32DropTarget(
        handler: handler,
        windowId: _windowId,
        // A window whose client area starts at (100, 50) on a 2x display:
        // this is exactly the conversion a real window performs, and getting
        // it wrong is the bug the position assertions below exist for.
        screenToClient: (int x, int y) => Offset((x - 100) / 2, (y - 50) / 2),
        api: api,
        ole: ole,
      );
      object = targetClass.instantiate(target);
    });

    tearDown(() {
      if (!Platform.isWindows) return;
      object.dispose();
      targetClass.dispose();
    });

    test('QueryInterface answers IDropTarget and IUnknown with a reference',
        () {
      final Pointer<Pointer<Void>> out =
          allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
      final Pointer<Uint8> iid = allocator.allocate<Uint8>(16);
      try {
        iidIDropTarget.writeTo(iid);
        expect(_queryInterface(object.pointer, iid, out), sOk);
        expect(out.value, object.pointer);
        expect(object.refCount, 2, reason: 'the callee takes the reference');
        expect(_release(object.pointer), 1);

        iidIUnknown.writeTo(iid);
        expect(_queryInterface(object.pointer, iid, out), sOk);
        expect(out.value, object.pointer,
            reason: 'IUnknown must be the same pointer from every interface');
        _release(object.pointer);

        iidIDataObject.writeTo(iid);
        expect(_queryInterface(object.pointer, iid, out), eNoInterface);
        expect(out.value, nullptr);
      } finally {
        allocator
          ..free(out)
          ..free(iid);
      }
    }, skip: _skipReason);

    test('AddRef and Release move the same count the Dart side sees', () {
      expect(object.refCount, 1);
      expect(_addRef(object.pointer), 2);
      expect(object.refCount, 2);
      expect(_release(object.pointer), 1);
    }, skip: _skipReason);

    test('DragEnter reads the data object and converts the position', () {
      final _FakeDataObject data = _FakeDataObject(api, allocator)
        ..text = 'hello';
      handler.response = const DropResponse(
        acceptedFormat: DragFormats.text,
        action: DragAction.copy,
      );
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy | dropEffectMove;
        final int hr = _dragEnter(
          object.pointer,
          data.pointer,
          mkLButton | mkControlKey,
          _packPoint(300, 150),
          effect,
        );

        expect(hr, sOk);
        expect(effect.value, dropEffectCopy);
        expect(handler.enters, hasLength(1));
        final DragSessionEvent event = handler.enters.single;
        expect(event.windowId, _windowId);
        expect(event.position, const Offset(100, 50),
            reason: '(300,150) screen physical at origin (100,50) scale 2');
        expect(event.screenPosition, const Offset(300, 150));
        expect(event.modifiers, <KeyModifier>{KeyModifier.control});
        expect(
          event.allowedActions,
          <DragAction>{DragAction.copy, DragAction.move},
        );
        expect(event.data.formats, contains(DragFormats.text));
        expect(target.isDragging, isTrue);
        expect(data.refCount, greaterThan(1),
            reason: 'the borrowed data object is held for the drag');
      } finally {
        _dragLeave(object.pointer);
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test('the live data really reads through IDataObject::GetData', () async {
      final _FakeDataObject data = _FakeDataObject(api, allocator)
        ..text = 'caf\u00e9 drop';
      handler.response = const DropResponse(
        acceptedFormat: DragFormats.text,
      );
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy;
        _dragEnter(
            object.pointer, data.pointer, 0, _packPoint(100, 50), effect);

        final DragData live = handler.enters.single.data;
        expect(await live.readText(), 'caf\u00e9 drop');
        expect(data.getDataCalls, 1);
        // A second read is answered from the cache, so a target that asks
        // twice does not pay for two GetData round trips.
        expect(await live.readText(), 'caf\u00e9 drop');
        expect(data.getDataCalls, 1);
      } finally {
        _dragLeave(object.pointer);
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test('a file list arrives as a uri-list of file:// URIs', () async {
      final _FakeDataObject data = _FakeDataObject(api, allocator)
        ..files = <String>[r'C:\tmp\a.txt', r'C:\tmp\b.txt'];
      handler.response = const DropResponse(
        acceptedFormat: DragFormats.uriList,
      );
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy;
        _dragEnter(
            object.pointer, data.pointer, 0, _packPoint(100, 50), effect);
        final DragData live = handler.enters.single.data;
        expect(live.formats, contains(DragFormats.uriList));
        expect(
          await live.readFilePaths(),
          <String>[r'C:\tmp\a.txt', r'C:\tmp\b.txt'],
        );
      } finally {
        _dragLeave(object.pointer);
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test('a refusal writes DROPEFFECT_NONE and takes no data', () {
      final _FakeDataObject data = _FakeDataObject(api, allocator)..text = 'x';
      handler.response = const DropResponse.reject();
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy;
        expect(
          _dragEnter(object.pointer, data.pointer, 0, _packPoint(0, 0), effect),
          sOk,
        );
        expect(effect.value, dropEffectNone);
        expect(target.negotiatedEffect, dropEffectNone);
      } finally {
        _dragLeave(object.pointer);
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test('an action the source does not allow is masked to none', () {
      final _FakeDataObject data = _FakeDataObject(api, allocator)..text = 'x';
      handler.response = const DropResponse(
        acceptedFormat: DragFormats.text,
        action: DragAction.move,
      );
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy;
        _dragEnter(object.pointer, data.pointer, 0, _packPoint(0, 0), effect);
        expect(
          effect.value,
          dropEffectNone,
          reason: 'answering MOVE to a copy-only source makes it delete an '
              'original nobody took',
        );
      } finally {
        _dragLeave(object.pointer);
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test('DragOver re-asks and can change the answer', () {
      final _FakeDataObject data = _FakeDataObject(api, allocator)..text = 'x';
      handler.response = const DropResponse.reject();
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy | dropEffectMove;
        _dragEnter(
            object.pointer, data.pointer, 0, _packPoint(100, 50), effect);
        expect(effect.value, dropEffectNone);

        handler.response = const DropResponse(
          acceptedFormat: DragFormats.text,
          action: DragAction.move,
        );
        effect.value = dropEffectCopy | dropEffectMove;
        expect(
          _dragOver(object.pointer, mkShiftKey, _packPoint(120, 70), effect),
          sOk,
        );
        expect(effect.value, dropEffectMove);
        expect(handler.overs.single.position, const Offset(10, 10));
        expect(handler.overs.single.suggestedAction, DragAction.move,
            reason: 'Shift asks for a move on every desktop');
      } finally {
        _dragLeave(object.pointer);
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test(
        'DragOver with no DragEnter answers nothing rather than inventing '
        'a session', () {
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy;
        expect(
          _dragOver(object.pointer, 0, _packPoint(0, 0), effect),
          sOk,
        );
        expect(effect.value, dropEffectNone);
        expect(handler.overs, isEmpty);
      } finally {
        allocator.free(effect);
      }
    }, skip: _skipReason);

    test('DragLeave releases the borrowed data object exactly once', () {
      final _FakeDataObject data = _FakeDataObject(api, allocator)..text = 'x';
      handler.response = const DropResponse(acceptedFormat: DragFormats.text);
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy;
        _dragEnter(object.pointer, data.pointer, 0, _packPoint(0, 0), effect);
        final int held = data.refCount;

        expect(_dragLeave(object.pointer), sOk);
        expect(handler.leaves, 1);
        expect(data.refCount, held - 1);
        expect(target.isDragging, isFalse);

        // A second leave is not an error and must not release again.
        expect(_dragLeave(object.pointer), sOk);
        expect(handler.leaves, 1);
        expect(data.refCount, held - 1);
      } finally {
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test('Drop materialises the payload and reports the negotiated effect',
        () async {
      final _FakeDataObject data = _FakeDataObject(api, allocator)
        ..text = 'dropped'
        ..files = <String>[r'C:\x.txt'];
      handler.response = const DropResponse(
        acceptedFormat: DragFormats.uriList,
        action: DragAction.move,
      );
      handler.dropResult = DragAction.move;
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy | dropEffectMove;
        _dragEnter(
            object.pointer, data.pointer, 0, _packPoint(100, 50), effect);

        effect.value = dropEffectCopy | dropEffectMove;
        expect(
          _drop(object.pointer, data.pointer, 0, _packPoint(140, 90), effect),
          sOk,
        );
        expect(effect.value, dropEffectMove,
            reason: 'Drop answers with what the last DragOver agreed to, '
                'because it cannot wait for the handler');
        expect(handler.drops, hasLength(1));
        // The payload is in memory: its futures are already complete, which
        // is the whole point of reading it inside Drop.
        final DragData payload = handler.drops.single.data;
        expect(payload, isA<MemoryDragData>());
        expect(await payload.readFilePaths(), <String>[r'C:\x.txt']);
        expect(await payload.readText(), 'dropped');
        expect(target.isDragging, isFalse);

        await handler.lastDropCompleted;
        expect(target.completedDrops, <DragAction>[DragAction.move]);
      } finally {
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test('a Drop after a refusal performs nothing', () {
      final _FakeDataObject data = _FakeDataObject(api, allocator)..text = 'x';
      handler.response = const DropResponse.reject();
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy;
        _dragEnter(object.pointer, data.pointer, 0, _packPoint(0, 0), effect);
        effect.value = dropEffectCopy;
        expect(
          _drop(object.pointer, data.pointer, 0, _packPoint(0, 0), effect),
          sOk,
        );
        expect(effect.value, dropEffectNone);
        expect(handler.drops, isEmpty);
      } finally {
        allocator.free(effect);
        data.dispose();
      }
    }, skip: _skipReason);

    test('a null effect pointer is E_POINTER, not a crash', () {
      expect(
        _dragOver(object.pointer, 0, _packPoint(0, 0), nullptr),
        ePointer,
      );
      expect(
        _dragEnter(object.pointer, nullptr, 0, _packPoint(0, 0), nullptr),
        ePointer,
      );
    }, skip: _skipReason);

    test('a handler that throws becomes E_FAIL and a recorded fault', () {
      final _FakeDataObject data = _FakeDataObject(api, allocator)..text = 'x';
      handler.throwOnEnter = true;
      ComServerRegistry.clearFaults();
      final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
      try {
        effect.value = dropEffectCopy;
        expect(
          _dragEnter(object.pointer, data.pointer, 0, _packPoint(0, 0), effect),
          eFail,
          reason: 'a Dart exception must never unwind into the OLE drag loop',
        );
        expect(ComServerRegistry.faults, isNotEmpty);
        expect(ComServerRegistry.faults.last.methodName, 'DragEnter');
      } finally {
        allocator.free(effect);
        data.dispose();
        ComServerRegistry.clearFaults();
      }
    }, skip: _skipReason);
  });

  group('registration against a real HWND', () {
    test('registers, refuses a second target, and revokes', () async {
      final Win32WindowingBackend backend = Win32WindowingBackend();
      await backend.initialize();
      final NativeWindow window = await backend.createWindow(
        const WindowOptions(size: Size(200, 120), visible: false),
      );
      final DragDropBackend dnd = backend.dragAndDrop;
      expect(dnd, isA<Win32DragDropBackend>(),
          reason: 'ole32 is expected to load on a real Windows host');
      try {
        final DropTargetRegistration registration = await dnd
            .registerDropTarget(window: window, handler: _RecordingHandler());
        expect(registration.isActive, isTrue);
        expect(registration.windowId, window.id);

        await expectLater(
          dnd.registerDropTarget(window: window, handler: _RecordingHandler()),
          throwsA(
            isA<DragDropException>()
                .having((DragDropException e) => e.operation, 'operation',
                    'RegisterDragDrop')
                .having((DragDropException e) => e.errorCode, 'errorCode',
                    dragDropErrorAlreadyRegistered),
          ),
        );

        await registration.revoke();
        expect(registration.isActive, isFalse);

        // Revoking twice is not an error: a window teardown and an explicit
        // revoke race by design.
        await registration.revoke();

        // And the window can be registered again once the first target is
        // gone, which is what proves the revoke really reached OLE.
        final DropTargetRegistration second = await dnd.registerDropTarget(
            window: window, handler: _RecordingHandler());
        expect(second.isActive, isTrue);
        await second.revoke();
      } finally {
        window.close();
        await backend.shutdown();
      }
    }, skip: _skipReason);

    test('the probe claims dragAndDrop once ole32 is loadable', () {
      final Win32WindowingBackend backend = Win32WindowingBackend();
      final BackendProbeResult report = backend.probe();
      expect(report.supported, isTrue);
      expect(report.supports(Capability.dragAndDrop), isTrue);
    }, skip: _skipReason);

    test('an uninitialised backend refuses by name rather than half-working',
        () async {
      // Before `initialize` there is no `Win32Api`, so there is nothing to
      // register a window with and nothing to allocate an HGLOBAL from. The
      // answer is an `UnavailableDragDrop` naming that, not a backend that
      // fails later at a moment the caller cannot connect to this one.
      final Win32WindowingBackend backend = Win32WindowingBackend();
      final DragDropBackend dnd = backend.dragAndDrop;
      expect(dnd, isA<UnavailableDragDrop>());
      expect(dnd.canStartDrag, isFalse);
      await expectLater(
        dnd.startDrag(
          DragRequest(window: _NullWindow(), data: MemoryDragData.text('x')),
        ),
        throwsA(
          isA<DragDropException>()
              .having((DragDropException e) => e.backend, 'backend', 'win32'),
        ),
      );
    }, skip: _skipReason);

    test('an initialised backend can start a drag as well as receive one',
        () async {
      final Win32WindowingBackend backend = Win32WindowingBackend();
      await backend.initialize();
      try {
        expect(backend.dragAndDrop.canStartDrag, isTrue,
            reason: 'DoDragDrop and IDropSource are implemented; see '
                'win32_drag_source.dart');
      } finally {
        await backend.shutdown();
      }
    }, skip: _skipReason);
  });
}

String? get _skipReason =>
    Platform.isWindows ? null : 'the Win32 drop target needs Windows';

int _packPoint(int x, int y) => ((y & 0xFFFFFFFF) << 32) | (x & 0xFFFFFFFF);

// ---------------------------------------------------------------------------
// Calling the vtable the way OLE would
// ---------------------------------------------------------------------------

int _queryInterface(
  Pointer<Void> self,
  Pointer<Uint8> iid,
  Pointer<Pointer<Void>> out,
) =>
    comMethod<ComServerQueryInterfaceNative>(self, comSlotQueryInterface)
        .asFunction<
            int Function(Pointer<Void>, Pointer<Uint8>,
                Pointer<Pointer<Void>>)>()(self, iid, out);

int _addRef(Pointer<Void> self) =>
    comMethod<ComServerRefCountNative>(self, comSlotAddRef)
        .asFunction<int Function(Pointer<Void>)>()(self);

int _release(Pointer<Void> self) =>
    comMethod<ComServerRefCountNative>(self, comSlotRelease)
        .asFunction<int Function(Pointer<Void>)>()(self);

int _dragEnter(
  Pointer<Void> self,
  Pointer<Void> data,
  int keyState,
  int point,
  Pointer<Uint32> effect,
) =>
    comMethod<ComServerObjectStatePointOutNative>(self, 3).asFunction<
        int Function(Pointer<Void>, Pointer<Void>, int, int,
            Pointer<Uint32>)>()(self, data, keyState, point, effect);

int _dragOver(
  Pointer<Void> self,
  int keyState,
  int point,
  Pointer<Uint32> effect,
) =>
    comMethod<ComServerStatePointOutNative>(self, 4).asFunction<
            int Function(Pointer<Void>, int, int, Pointer<Uint32>)>()(
        self, keyState, point, effect);

int _dragLeave(Pointer<Void> self) => comMethod<ComServerSelfNative>(self, 5)
    .asFunction<int Function(Pointer<Void>)>()(self);

int _drop(
  Pointer<Void> self,
  Pointer<Void> data,
  int keyState,
  int point,
  Pointer<Uint32> effect,
) =>
    comMethod<ComServerObjectStatePointOutNative>(self, 6).asFunction<
        int Function(Pointer<Void>, Pointer<Void>, int, int,
            Pointer<Uint32>)>()(self, data, keyState, point, effect);

// ---------------------------------------------------------------------------
// A CF_HDROP block, laid out by hand
// ---------------------------------------------------------------------------

Pointer<Uint8> _allocateDropFiles(
  NativeAllocator allocator,
  List<String> paths, {
  required bool wide,
}) {
  final List<int> names = <int>[];
  for (final String path in paths) {
    names.addAll(wide ? path.codeUnits : latin1.encode(path));
    names.add(0);
  }
  names.add(0);
  final int unit = wide ? 2 : 1;
  final int size = OleStructLayout.dropFilesSize + names.length * unit;
  final Pointer<Uint8> block = allocator.allocate<Uint8>(size);
  for (int i = 0; i < size; i++) {
    block[i] = 0;
  }
  final ByteData header =
      ByteData.sublistView(block.asTypedList(OleStructLayout.dropFilesSize));
  header.setUint32(OleStructLayout.dropFilesOffset,
      OleStructLayout.dropFilesSize, Endian.little);
  header.setUint32(OleStructLayout.dropFilesWide, wide ? 1 : 0, Endian.little);
  if (wide) {
    final Pointer<Uint16> tail = Pointer<Uint16>.fromAddress(
        block.address + OleStructLayout.dropFilesSize);
    for (int i = 0; i < names.length; i++) {
      tail[i] = names[i];
    }
  } else {
    for (int i = 0; i < names.length; i++) {
      block[OleStructLayout.dropFilesSize + i] = names[i];
    }
  }
  return block;
}

// ---------------------------------------------------------------------------
// A real IDataObject, implemented in Dart
// ---------------------------------------------------------------------------

/// The three `IDataObject` methods that matter, plus stubs for the rest.
///
/// The unimplemented slots are bound with the one-pointer shape rather than
/// their true signatures. That is safe here and only here: they are never
/// called, and on x64 the caller cleans the argument registers, so a narrower
/// callee cannot corrupt anything. A production `IDataObject` - the one the
/// source half will need - has to declare every slot properly.
final class _FakeDataObject {
  _FakeDataObject(this._api, this._allocator) {
    _class = ComServerClass<_FakeDataObject>(
      'FakeDataObject',
      <ComInterfaceSpec<_FakeDataObject>>[
        ComInterfaceSpec<_FakeDataObject>(
          name: 'IDataObject',
          iid: iidIDataObject,
          methods: <ComMethod<_FakeDataObject>>[
            ComPointerPointerMethod<_FakeDataObject>(
              'GetData',
              (_FakeDataObject self, Pointer<Void> etc, Pointer<Void> medium) =>
                  self._getData(etc.cast(), medium.cast()),
            ),
            ComPointerPointerMethod<_FakeDataObject>(
              'GetDataHere',
              (_FakeDataObject self, Pointer<Void> a, Pointer<Void> b) =>
                  eNotImplemented,
            ),
            ComPointerMethod<_FakeDataObject>(
              'QueryGetData',
              (_FakeDataObject self, Pointer<Void> etc) =>
                  self._queryGetData(etc.cast()),
            ),
            ComPointerPointerMethod<_FakeDataObject>(
              'GetCanonicalFormatEtc',
              (_FakeDataObject self, Pointer<Void> a, Pointer<Void> b) =>
                  eNotImplemented,
            ),
            ComPointerMethod<_FakeDataObject>('SetData',
                (_FakeDataObject self, Pointer<Void> a) => eNotImplemented),
            ComPointerMethod<_FakeDataObject>('EnumFormatEtc',
                (_FakeDataObject self, Pointer<Void> a) => eNotImplemented),
            ComPointerMethod<_FakeDataObject>('DAdvise',
                (_FakeDataObject self, Pointer<Void> a) => eNotImplemented),
            ComPointerMethod<_FakeDataObject>('DUnadvise',
                (_FakeDataObject self, Pointer<Void> a) => eNotImplemented),
            ComPointerMethod<_FakeDataObject>('EnumDAdvise',
                (_FakeDataObject self, Pointer<Void> a) => eNotImplemented),
          ],
        ),
      ],
    );
    _object = _class.instantiate(this);
  }

  final Win32Api _api;
  final NativeAllocator _allocator;

  late final ComServerClass<_FakeDataObject> _class;
  late final ComServerObject<_FakeDataObject> _object;

  String? text;
  List<String>? files;
  int getDataCalls = 0;

  Pointer<Void> get pointer => _object.pointer;

  int get refCount => _object.refCount;

  void dispose() {
    _object.dispose();
    _class.dispose();
  }

  bool _offers(int format) =>
      (format == cfUnicodeText && text != null) ||
      (format == cfHDrop && files != null);

  int _queryGetData(Pointer<Uint8> etc) {
    if (readFormatEtcTymed(etc) & tymedHGlobal == 0) return sFalse;
    return _offers(readFormatEtcFormat(etc)) ? sOk : sFalse;
  }

  int _getData(Pointer<Uint8> etc, Pointer<Uint8> medium) {
    final int format = readFormatEtcFormat(etc);
    if (!_offers(format)) return eFail;
    getDataCalls++;
    final int handle = switch (format) {
      cfUnicodeText => _allocateUnicodeText(text!),
      cfHDrop => _allocateHDrop(files!),
      _ => 0,
    };
    if (handle == 0) return eFail;
    writeStgMediumGlobal(medium, handle);
    return sOk;
  }

  /// Real global memory, so that the reader's `GlobalLock` and the
  /// `ReleaseStgMedium` that frees it are the real calls.
  int _allocateUnicodeText(String value) {
    final List<int> units = <int>[...value.codeUnits, 0];
    final int handle = _api.globalAlloc!(gmemMoveable, units.length * 2);
    if (handle == 0) return 0;
    final int address = _api.globalLock!(handle);
    Pointer<Uint16>.fromAddress(address)
        .asTypedList(units.length)
        .setAll(0, units);
    _api.globalUnlock!(handle);
    return handle;
  }

  int _allocateHDrop(List<String> paths) {
    final Pointer<Uint8> scratch =
        _allocateDropFiles(_allocator, paths, wide: true);
    try {
      final List<int> names = <int>[];
      for (final String path in paths) {
        names
          ..addAll(path.codeUnits)
          ..add(0);
      }
      names.add(0);
      final int size = OleStructLayout.dropFilesSize + names.length * 2;
      final int handle = _api.globalAlloc!(gmemMoveable, size);
      if (handle == 0) return 0;
      final int address = _api.globalLock!(handle);
      Pointer<Uint8>.fromAddress(address)
          .asTypedList(size)
          .setAll(0, scratch.asTypedList(size));
      _api.globalUnlock!(handle);
      return handle;
    } finally {
      _allocator.free(scratch);
    }
  }
}

// ---------------------------------------------------------------------------
// The handler under test
// ---------------------------------------------------------------------------

final class _RecordingHandler implements DropTargetHandler {
  DropResponse response = const DropResponse.reject();
  DragAction dropResult = DragAction.copy;
  bool throwOnEnter = false;

  final List<DragSessionEvent> enters = <DragSessionEvent>[];
  final List<DragSessionEvent> overs = <DragSessionEvent>[];
  final List<DragSessionEvent> drops = <DragSessionEvent>[];
  int leaves = 0;

  Future<DragAction> lastDropCompleted = Future<DragAction>.value(
    DragAction.none,
  );

  @override
  DropResponse onDragEnter(DragSessionEvent event) {
    if (throwOnEnter) throw StateError('handler failed');
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
  Future<DragAction> onDrop(DragSessionEvent event) {
    drops.add(event);
    return lastDropCompleted = Future<DragAction>.value(dropResult);
  }
}

/// A window the port never touches, for the paths that fail before it would.
final class _NullWindow implements NativeWindow {
  @override
  NativeWindowId get id => const NativeWindowId(99);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
