/// The Win32 drag *source*, exercised through its own COM vtables.
///
/// What a test on this machine can and cannot prove, stated up front for the
/// same reason `win32_drag_drop_test.dart` states it:
///
///  * **Real, and proved here.** The `CF_HDROP` encoder round-trips through the
///    decoder the destination half already uses, so the two agree about a
///    layout neither of them invented. The `IDataObject`, `IEnumFORMATETC` and
///    `IDropSource` vtables exist and are called *through the vtable* with the
///    argument shapes OLE uses; `GetData` really allocates a moveable
///    `HGLOBAL`, the bytes really survive a `GlobalLock`, and
///    `ReleaseStgMedium` really frees it. `QueryInterface`, `AddRef` and
///    `Release` behave as COM requires on all three objects, and the
///    enumerator's `S_OK`/`S_FALSE` contract is the one a real target loops on.
///  * **Not proved here, and deliberately not attempted.** `DoDragDrop` is
///    never called. It opens a modal message loop, captures the mouse and does
///    not return until a button is released - on a CI machine with no user that
///    is a hang, not a test. Everything up to the call is exercised instead,
///    which pins every object the loop would touch and leaves only "OLE is the
///    caller" unproved. A drop into another application also needs a second
///    application, exactly as the destination half needs a second one to drag
///    from.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/uia/com_server.dart';
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_drag_drop.dart';
import 'package:dart_ui/src/backends/win32/win32_drag_source.dart';
import 'package:dart_ui/src/backends/win32/win32_ole.dart';
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/platform/drag_drop.dart';
import 'package:test/test.dart';

void main() {
  group('payload encoders', () {
    late NativeAllocator allocator;

    setUp(() {
      final NativeAllocator? bound = NativeAllocator.tryBind();
      if (bound == null) fail('no native allocator on this platform');
      allocator = bound;
    });

    test('CF_HDROP round-trips through the decoder the drop side uses', () {
      final List<String> paths = <String>[
        r'C:\tmp\a.txt',
        r'C:\tmp\b\c.txt',
        r'D:\one more.bin',
      ];
      _withNative(allocator, win32BuildDropFiles(paths), (int address) {
        expect(win32ReadDropFilesAt(address), paths);
      });
    });

    test('a non-ASCII path survives the encoder unchanged', () {
      // Two of these are outside the BMP-free part of Latin-1 and one is a
      // surrogate pair, which is where a `length`-versus-`codeUnits` mistake
      // shows up as a truncated name.
      final List<String> paths = <String>[
        r'C:\tmp\caf\u00e9 \u00fcber.txt',
        'C:\\tmp\\\u65e5\u672c\u8a9e.txt',
        'C:\\tmp\\emoji \u{1F600}.txt',
      ];
      _withNative(allocator, win32BuildDropFiles(paths), (int address) {
        expect(win32ReadDropFilesAt(address), paths);
      });
    });

    test('a single path is still double-NUL terminated', () {
      final Uint8List block = win32BuildDropFiles(<String>[r'C:\a.txt']);
      // header + 8 wide chars + name NUL + list NUL
      expect(block.length, OleStructLayout.dropFilesSize + (8 + 1 + 1) * 2);
      _withNative(allocator, block, (int address) {
        expect(win32ReadDropFilesAt(address), <String>[r'C:\a.txt']);
      });
    });

    test('an empty list is a well-formed block naming nothing', () {
      _withNative(allocator, win32BuildDropFiles(const <String>[]),
          (int address) {
        expect(win32ReadDropFilesAt(address), isEmpty);
      });
    });

    test('the header says wide, and says where the names start', () {
      final Uint8List block = win32BuildDropFiles(<String>[r'C:\a.txt']);
      final ByteData header = ByteData.sublistView(block);
      expect(
        header.getUint32(OleStructLayout.dropFilesOffset, Endian.little),
        OleStructLayout.dropFilesSize,
        reason: 'pFiles is the real offset of the first name, not a guess',
      );
      expect(
        header.getUint32(OleStructLayout.dropFilesWide, Endian.little),
        1,
        reason: 'names read as ANSI would be one character per two bytes',
      );
    });

    test('CF_UNICODETEXT round-trips and stops at the NUL', () {
      const String text = 'caf\u00e9 \u00fcber alles';
      final Uint8List block = win32BuildUnicodeText(text);
      expect(block.length, (text.length + 1) * 2);
      _withNative(allocator, block, (int address) {
        expect(win32ReadUnicodeTextAt(address), text);
      });
    });

    test('empty text is a lone terminator, not an empty block', () {
      final Uint8List block = win32BuildUnicodeText('');
      expect(block.length, 2);
      _withNative(allocator, block, (int address) {
        expect(win32ReadUnicodeTextAt(address), isEmpty);
      });
    });

    test('a text payload materialises as CF_UNICODETEXT only', () async {
      final Map<int, Uint8List> payload =
          await win32MaterialiseDragPayload(MemoryDragData.text('hello'));
      expect(payload.keys, <int>[cfUnicodeText]);
      _withNative(allocator, payload[cfUnicodeText]!, (int address) {
        expect(win32ReadUnicodeTextAt(address), 'hello');
      });
    });

    test('a uri-list payload materialises as CF_HDROP, files first', () async {
      final Map<int, Uint8List> payload = await win32MaterialiseDragPayload(
        MemoryDragData(<String, Uint8List>{
          DragFormats.uriList: Uint8List.fromList(
            utf8.encode('file:///C:/tmp/a.txt\r\nfile:///C:/tmp/b.txt\r\n'),
          ),
          DragFormats.text: Uint8List.fromList(utf8.encode('two files')),
        }),
      );
      expect(payload.keys, <int>[cfHDrop, cfUnicodeText],
          reason: 'a source advertises its richest format first');
      _withNative(allocator, payload[cfHDrop]!, (int address) {
        expect(
          win32ReadDropFilesAt(address),
          <String>[r'C:\tmp\a.txt', r'C:\tmp\b.txt'],
        );
      });
    });

    test('a URI that names no local file is skipped, not invented', () async {
      final Map<int, Uint8List> payload = await win32MaterialiseDragPayload(
        MemoryDragData(<String, Uint8List>{
          DragFormats.uriList: Uint8List.fromList(
            utf8.encode('https://example.com/x\r\n'),
          ),
        }),
      );
      expect(payload, isEmpty,
          reason: 'there is no CF_HDROP spelling for an http URI');
    });
  });

  group('IDataObject, through its own vtable', () {
    late Win32Api api;
    late Win32OleApi ole;
    late NativeAllocator allocator;
    late Win32DragSourceObjects objects;

    setUp(() {
      if (!Platform.isWindows) return;
      final Win32Api? loaded = Win32Api.load().api;
      final Win32OleApi? loadedOle = Win32OleApi.load().api;
      if (loaded == null || loadedOle == null) return;
      api = loaded;
      ole = loadedOle;
      allocator = NativeAllocator.tryBind()!;
      objects = Win32DragSourceObjects(
        payload: <int, Uint8List>{
          cfHDrop: win32BuildDropFiles(<String>[r'C:\tmp\a.txt']),
          cfUnicodeText: win32BuildUnicodeText('caf\u00e9 drag'),
        },
        api: api,
      );
    });

    tearDown(() {
      if (!Platform.isWindows) return;
      objects.dispose();
    });

    test('QueryInterface answers IDataObject and IUnknown with one identity',
        () {
      final Pointer<Pointer<Void>> out =
          allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
      final Pointer<Uint8> iid = allocator.allocate<Uint8>(16);
      try {
        iidIDataObject.writeTo(iid);
        expect(_queryInterface(objects.dataObjectPointer, iid, out), sOk);
        expect(out.value, objects.dataObjectPointer);
        _release(objects.dataObjectPointer);

        iidIUnknown.writeTo(iid);
        expect(_queryInterface(objects.dataObjectPointer, iid, out), sOk);
        expect(out.value, objects.dataObjectPointer,
            reason: 'IUnknown must be the same pointer from every interface');
        _release(objects.dataObjectPointer);

        iidIDropSource.writeTo(iid);
        expect(
          _queryInterface(objects.dataObjectPointer, iid, out),
          eNoInterface,
        );
        expect(out.value, nullptr);
      } finally {
        allocator
          ..free(out)
          ..free(iid);
      }
    }, skip: _skipReason);

    test('QueryGetData answers for what it has and DV_E_ for what it has not',
        () {
      final Pointer<Uint8> etc =
          allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
      try {
        writeFormatEtc(etc, cfUnicodeText);
        expect(_queryGetData(objects.dataObjectPointer, etc), sOk);

        writeFormatEtc(etc, cfHDrop);
        expect(_queryGetData(objects.dataObjectPointer, etc), sOk);

        writeFormatEtc(etc, cfText);
        expect(_queryGetData(objects.dataObjectPointer, etc), dvErrorFormatEtc,
            reason: 'S_FALSE is a success code and reads as yes');

        // A caller that asks for a medium this object does not produce is told
        // so distinctly, so it can widen its tymed rather than give up.
        writeFormatEtc(etc, cfUnicodeText);
        ByteData.sublistView(
          etc.asTypedList(OleStructLayout.formatEtcSize),
        ).setUint32(OleStructLayout.formatEtcTymed, 4, Endian.little);
        expect(_queryGetData(objects.dataObjectPointer, etc), dvErrorTymed);
      } finally {
        allocator.free(etc);
      }
    }, skip: _skipReason);

    test('GetData hands over a real HGLOBAL that ReleaseStgMedium frees', () {
      final Pointer<Uint8> etc =
          allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
      final Pointer<Uint8> medium =
          allocator.allocate<Uint8>(OleStructLayout.stgMediumSize);
      try {
        // Deliberately dirty, so a GetData that forgot to clear the medium
        // would be caught by the failure path below.
        for (int i = 0; i < OleStructLayout.stgMediumSize; i++) {
          medium[i] = 0xEE;
        }
        writeFormatEtc(etc, cfUnicodeText);
        expect(_getData(objects.dataObjectPointer, etc, medium), sOk);
        expect(objects.dataObject.getDataCalls, 1);

        final int handle = readStgMediumGlobal(medium);
        expect(handle, isNot(0));
        final int address = api.globalLock!(handle);
        expect(address, isNot(0));
        expect(win32ReadUnicodeTextAt(address), 'caf\u00e9 drag');
        api.globalUnlock!(handle);

        ole.releaseStgMedium(medium);
        expect(readStgMediumGlobal(medium), 0,
            reason: 'ReleaseStgMedium frees the HGLOBAL and clears the medium');
      } finally {
        allocator
          ..free(etc)
          ..free(medium);
      }
    }, skip: _skipReason);

    test('every GetData allocates a fresh handle, because the receiver owns it',
        () {
      final Pointer<Uint8> etc =
          allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
      final Pointer<Uint8> first =
          allocator.allocate<Uint8>(OleStructLayout.stgMediumSize);
      final Pointer<Uint8> second =
          allocator.allocate<Uint8>(OleStructLayout.stgMediumSize);
      try {
        writeFormatEtc(etc, cfHDrop);
        expect(_getData(objects.dataObjectPointer, etc, first), sOk);
        expect(_getData(objects.dataObjectPointer, etc, second), sOk);
        final int a = readStgMediumGlobal(first);
        final int b = readStgMediumGlobal(second);
        expect(a, isNot(0));
        expect(b, isNot(0));
        expect(a, isNot(b),
            reason: 'the same handle twice means the second receiver frees '
                'memory the first is still reading');
        expect(
          win32ReadDropFilesAt(api.globalLock!(b)),
          <String>[r'C:\tmp\a.txt'],
        );
        api.globalUnlock!(b);
        ole
          ..releaseStgMedium(first)
          ..releaseStgMedium(second);
      } finally {
        allocator
          ..free(etc)
          ..free(first)
          ..free(second);
      }
    }, skip: _skipReason);

    test('GetData for an unheld format fails and leaves the medium empty', () {
      final Pointer<Uint8> etc =
          allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
      final Pointer<Uint8> medium =
          allocator.allocate<Uint8>(OleStructLayout.stgMediumSize);
      try {
        for (int i = 0; i < OleStructLayout.stgMediumSize; i++) {
          medium[i] = 0xEE;
        }
        writeFormatEtc(etc, cfText);
        expect(
          _getData(objects.dataObjectPointer, etc, medium),
          dvErrorFormatEtc,
        );
        expect(readStgMediumGlobal(medium), 0,
            reason: 'a stale handle here would be freed by the caller');
        expect(objects.dataObject.getDataCalls, 0);
      } finally {
        allocator
          ..free(etc)
          ..free(medium);
      }
    }, skip: _skipReason);

    test('the read-only and advise slots refuse by name', () {
      final Pointer<Uint8> etc =
          allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
      final Pointer<Uint8> medium =
          allocator.allocate<Uint8>(OleStructLayout.stgMediumSize);
      final Pointer<Uint32> connection = allocator.allocate<Uint32>(4);
      try {
        writeFormatEtc(etc, cfUnicodeText);
        for (int i = 0; i < OleStructLayout.stgMediumSize; i++) {
          medium[i] = 0;
        }
        expect(
          _setData(objects.dataObjectPointer, etc, medium, 1),
          eNotImplemented,
        );
        connection.value = 0xDEAD;
        expect(
          _dAdvise(objects.dataObjectPointer, etc, 0, nullptr, connection),
          oleErrorAdviseNotSupported,
        );
        expect(connection.value, 0);
        expect(
          _dUnadvise(objects.dataObjectPointer, 7),
          oleErrorAdviseNotSupported,
        );
      } finally {
        allocator
          ..free(etc)
          ..free(medium)
          ..free(connection);
      }
    }, skip: _skipReason);

    test('GetCanonicalFormatEtc says the format is already canonical', () {
      final Pointer<Uint8> input =
          allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
      final Pointer<Uint8> output =
          allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
      try {
        writeFormatEtc(input, cfHDrop);
        expect(
          _getCanonicalFormatEtc(objects.dataObjectPointer, input, output),
          dataStatusSameFormatEtc,
        );
        expect(readFormatEtcFormat(output), cfHDrop);
      } finally {
        allocator
          ..free(input)
          ..free(output);
      }
    }, skip: _skipReason);
  });

  group('IEnumFORMATETC, through its own vtable', () {
    late Win32Api api;
    late NativeAllocator allocator;
    late Win32DragSourceObjects objects;
    late Pointer<Void> enumerator;
    late Pointer<Uint8> buffer;
    late Pointer<Uint32> fetched;

    /// Four slots, so that asking for more than there are has somewhere to go.
    const int slots = 4;

    setUp(() {
      if (!Platform.isWindows) return;
      final Win32Api? loaded = Win32Api.load().api;
      if (loaded == null) return;
      api = loaded;
      allocator = NativeAllocator.tryBind()!;
      objects = Win32DragSourceObjects(
        payload: <int, Uint8List>{
          cfHDrop: win32BuildDropFiles(<String>[r'C:\a.txt']),
          cfUnicodeText: win32BuildUnicodeText('x'),
        },
        api: api,
      );
      buffer = allocator.allocate<Uint8>(OleStructLayout.formatEtcSize * slots);
      fetched = allocator.allocate<Uint32>(4);

      final Pointer<Pointer<Void>> out =
          allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
      try {
        expect(
          _enumFormatEtc(objects.dataObjectPointer, dataDirGet, out.cast()),
          sOk,
        );
        enumerator = out.value;
        expect(enumerator, isNot(nullptr));
      } finally {
        allocator.free(out);
      }
    });

    tearDown(() {
      if (!Platform.isWindows) return;
      _release(enumerator);
      allocator
        ..free(buffer)
        ..free(fetched);
      objects.dispose();
    });

    test('Next enumerates every offered format and then says S_FALSE', () {
      fetched.value = 0xFFFF;
      expect(_next(enumerator, slots, buffer.cast(), fetched), sFalse,
          reason: 'a short read must end the caller\'s loop');
      expect(fetched.value, 2);
      expect(_formatsIn(buffer, 2), <int>[cfHDrop, cfUnicodeText]);

      // And once exhausted it stays exhausted.
      expect(_next(enumerator, 1, buffer.cast(), fetched), sFalse);
      expect(fetched.value, 0);
    }, skip: _skipReason);

    test('a full read is S_OK, and pceltFetched may be null for one', () {
      expect(_next(enumerator, 2, buffer.cast(), fetched), sOk);
      expect(fetched.value, 2);

      expect(_reset(enumerator), sOk);
      expect(_next(enumerator, 1, buffer.cast(), nullptr), sOk,
          reason: 'null pceltFetched is legal when exactly one was asked for');
      expect(_formatsIn(buffer, 1), <int>[cfHDrop]);

      expect(_next(enumerator, 2, buffer.cast(), nullptr), eInvalidArg,
          reason: 'a short read with nowhere to report it is unanswerable');
    }, skip: _skipReason);

    test('the FORMATETC it writes is the one GetData accepts', () {
      expect(_next(enumerator, 1, buffer.cast(), fetched), sOk);
      final ByteData view = ByteData.sublistView(
        buffer.asTypedList(OleStructLayout.formatEtcSize),
      );
      expect(readFormatEtcTymed(buffer), tymedHGlobal);
      expect(
        view.getUint32(OleStructLayout.formatEtcAspect, Endian.little),
        dvAspectContent,
      );
      expect(
        view.getInt32(OleStructLayout.formatEtcIndex, Endian.little),
        -1,
        reason: 'lindex 0 asks for page zero of something with no pages',
      );
      expect(_queryGetData(objects.dataObjectPointer, buffer), sOk);
    }, skip: _skipReason);

    test('Skip moves the cursor and Reset puts it back', () {
      expect(_skip(enumerator, 1), sOk);
      expect(_next(enumerator, 1, buffer.cast(), fetched), sOk);
      expect(_formatsIn(buffer, 1), <int>[cfUnicodeText]);

      expect(_reset(enumerator), sOk);
      expect(_next(enumerator, 1, buffer.cast(), fetched), sOk);
      expect(_formatsIn(buffer, 1), <int>[cfHDrop]);

      expect(_reset(enumerator), sOk);
      expect(_skip(enumerator, 9), sFalse,
          reason: 'skipping past the end is S_FALSE, not an error');
      expect(_next(enumerator, 1, buffer.cast(), fetched), sFalse);
      expect(fetched.value, 0);
    }, skip: _skipReason);

    test('Clone is an independent cursor at the same place', () {
      expect(_skip(enumerator, 1), sOk);
      final Pointer<Pointer<Void>> out =
          allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
      try {
        expect(_clone(enumerator, out.cast()), sOk);
        final Pointer<Void> copy = out.value;
        expect(copy, isNot(nullptr));
        expect(copy, isNot(enumerator));
        try {
          expect(_next(copy, 1, buffer.cast(), fetched), sOk);
          expect(_formatsIn(buffer, 1), <int>[cfUnicodeText],
              reason: 'the clone starts where the original stood');
          // Moving the clone must not move the original.
          expect(_reset(copy), sOk);
          expect(_next(enumerator, 1, buffer.cast(), fetched), sOk);
          expect(_formatsIn(buffer, 1), <int>[cfUnicodeText]);
        } finally {
          _release(copy);
        }
      } finally {
        allocator.free(out);
      }
    }, skip: _skipReason);

    test('QueryInterface answers IEnumFORMATETC and IUnknown alike', () {
      final Pointer<Pointer<Void>> out =
          allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
      final Pointer<Uint8> iid = allocator.allocate<Uint8>(16);
      try {
        iidIEnumFormatEtc.writeTo(iid);
        expect(_queryInterface(enumerator, iid, out), sOk);
        expect(out.value, enumerator);
        _release(enumerator);

        iidIUnknown.writeTo(iid);
        expect(_queryInterface(enumerator, iid, out), sOk);
        expect(out.value, enumerator);
        _release(enumerator);

        iidIDataObject.writeTo(iid);
        expect(_queryInterface(enumerator, iid, out), eNoInterface);
      } finally {
        allocator
          ..free(out)
          ..free(iid);
      }
    }, skip: _skipReason);

    test('EnumFormatEtc refuses the SET direction rather than lying', () {
      final Pointer<Pointer<Void>> out =
          allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
      try {
        out.value = Pointer<Void>.fromAddress(0xDEAD);
        expect(
          _enumFormatEtc(objects.dataObjectPointer, dataDirSet, out.cast()),
          eNotImplemented,
          reason: 'this object accepts nothing through SetData',
        );
        expect(out.value, nullptr);
      } finally {
        allocator.free(out);
      }
    }, skip: _skipReason);
  });

  group('IDropSource, through its own vtable', () {
    late Win32Api api;
    late NativeAllocator allocator;
    late Win32DragSourceObjects objects;

    setUp(() {
      if (!Platform.isWindows) return;
      final Win32Api? loaded = Win32Api.load().api;
      if (loaded == null) return;
      api = loaded;
      allocator = NativeAllocator.tryBind()!;
      objects = Win32DragSourceObjects(
        payload: <int, Uint8List>{
          cfUnicodeText: win32BuildUnicodeText('x'),
        },
        api: api,
      );
    });

    tearDown(() {
      if (!Platform.isWindows) return;
      objects.dispose();
    });

    test('Escape cancels, whatever the buttons are doing', () {
      expect(
        _queryContinueDrag(objects.dropSourcePointer, 1, mkLButton),
        dragDropStatusCancel,
      );
      expect(
        _queryContinueDrag(objects.dropSourcePointer, 1, 0),
        dragDropStatusCancel,
      );
    }, skip: _skipReason);

    test('releasing the initiating button drops', () {
      expect(
        _queryContinueDrag(objects.dropSourcePointer, 0, 0),
        dragDropStatusDrop,
      );
      expect(
        _queryContinueDrag(objects.dropSourcePointer, 0, mkControlKey),
        dragDropStatusDrop,
        reason: 'a modifier is not the button',
      );
    }, skip: _skipReason);

    test('the button still down continues the loop', () {
      expect(_queryContinueDrag(objects.dropSourcePointer, 0, mkLButton), sOk);
      expect(
        _queryContinueDrag(
            objects.dropSourcePointer, 0, mkLButton | mkShiftKey),
        sOk,
      );
      expect(objects.dropSource.queryContinueCalls, 2);
    }, skip: _skipReason);

    test('a right-drag ends on the right button, not the left', () {
      final Win32DropSource source =
          Win32DropSource(initiatingButton: mkRButton);
      expect(source.queryContinueDrag(0, mkRButton), sOk);
      expect(source.queryContinueDrag(0, mkLButton), dragDropStatusDrop,
          reason: 'a source hardcoded to MK_LBUTTON would drop immediately');
      expect(source.queryContinueDrag(1, mkRButton), dragDropStatusCancel);
    });

    test('GiveFeedback asks Windows for the standard cursors', () {
      expect(
        _giveFeedback(objects.dropSourcePointer, dropEffectMove),
        dragDropStatusUseDefaultCursors,
      );
      expect(objects.dropSource.lastEffect, dropEffectMove);
      expect(
        _giveFeedback(objects.dropSourcePointer, dropEffectNone),
        dragDropStatusUseDefaultCursors,
      );
      expect(objects.dropSource.lastEffect, dropEffectNone);
    }, skip: _skipReason);

    test('QueryInterface answers IDropSource and IUnknown alike', () {
      final Pointer<Pointer<Void>> out =
          allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
      final Pointer<Uint8> iid = allocator.allocate<Uint8>(16);
      try {
        iidIDropSource.writeTo(iid);
        expect(_queryInterface(objects.dropSourcePointer, iid, out), sOk);
        expect(out.value, objects.dropSourcePointer);
        _release(objects.dropSourcePointer);

        iidIUnknown.writeTo(iid);
        expect(_queryInterface(objects.dropSourcePointer, iid, out), sOk);
        expect(out.value, objects.dropSourcePointer);
        _release(objects.dropSourcePointer);

        iidIDropTarget.writeTo(iid);
        expect(
          _queryInterface(objects.dropSourcePointer, iid, out),
          eNoInterface,
          reason: 'a drag source is not a drop target',
        );
      } finally {
        allocator
          ..free(out)
          ..free(iid);
      }
    }, skip: _skipReason);

    test('AddRef and Release move the count the Dart side keeps', () {
      expect(_addRef(objects.dropSourcePointer), 2);
      expect(_release(objects.dropSourcePointer), 1);
    }, skip: _skipReason);
  });

  group('the backend', () {
    test('canStartDrag is true once ole32 and GlobalAlloc are there', () {
      final Win32Api? api = Win32Api.load().api;
      final Win32OleApi? ole = Win32OleApi.load().api;
      if (api == null || ole == null) fail('ole32 and kernel32 are expected');
      final Win32DragDropBackend backend =
          Win32DragDropBackend(api: api, ole: ole);
      expect(backend.canStartDrag, isTrue);
    }, skip: _skipReason);
  });
}

String? get _skipReason =>
    Platform.isWindows ? null : 'the Win32 drag source needs Windows';

/// Runs [body] with [bytes] copied into native memory, and frees it after.
void _withNative(
  NativeAllocator allocator,
  Uint8List bytes,
  void Function(int address) body,
) {
  final Pointer<Uint8> block = allocator.allocate<Uint8>(bytes.length);
  try {
    block.asTypedList(bytes.length).setAll(0, bytes);
    body(block.address);
  } finally {
    allocator.free(block);
  }
}

/// The clipboard formats of the first [count] `FORMATETC`s at [buffer].
List<int> _formatsIn(Pointer<Uint8> buffer, int count) => <int>[
      for (int i = 0; i < count; i++)
        readFormatEtcFormat(
          Pointer<Uint8>.fromAddress(
            buffer.address + i * OleStructLayout.formatEtcSize,
          ),
        ),
    ];

// ---------------------------------------------------------------------------
// Calling the vtables the way OLE would
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

// IDataObject: GetData 3, GetDataHere 4, QueryGetData 5,
// GetCanonicalFormatEtc 6, SetData 7, EnumFormatEtc 8, DAdvise 9,
// DUnadvise 10, EnumDAdvise 11.

int _getData(Pointer<Void> self, Pointer<Uint8> etc, Pointer<Uint8> medium) =>
    comMethod<ComServerPointerPointerNative>(self, 3).asFunction<
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>()(
        self, etc.cast(), medium.cast());

int _queryGetData(Pointer<Void> self, Pointer<Uint8> etc) =>
    comMethod<ComServerPointerNative>(self, 5)
            .asFunction<int Function(Pointer<Void>, Pointer<Void>)>()(
        self, etc.cast());

int _getCanonicalFormatEtc(
  Pointer<Void> self,
  Pointer<Uint8> input,
  Pointer<Uint8> output,
) =>
    comMethod<ComServerPointerPointerNative>(self, 6).asFunction<
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>()(
        self, input.cast(), output.cast());

int _setData(
  Pointer<Void> self,
  Pointer<Uint8> etc,
  Pointer<Uint8> medium,
  int release,
) =>
    comMethod<ComServerPointerPointerFlagNative>(self, 7).asFunction<
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int)>()(
        self, etc.cast(), medium.cast(), release);

int _enumFormatEtc(Pointer<Void> self, int direction, Pointer<Void> out) =>
    comMethod<ComServerIntPointerNative>(self, 8)
        .asFunction<int Function(Pointer<Void>, int, Pointer<Void>)>()(
      self,
      direction,
      out,
    );

int _dAdvise(
  Pointer<Void> self,
  Pointer<Uint8> etc,
  int flags,
  Pointer<Void> sink,
  Pointer<Uint32> connection,
) =>
    comMethod<ComServerPointerIntPointerOutNative>(self, 9).asFunction<
        int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Void>,
            Pointer<Uint32>)>()(self, etc.cast(), flags, sink, connection);

int _dUnadvise(Pointer<Void> self, int connection) =>
    comMethod<ComServerIntNative>(self, 10)
        .asFunction<int Function(Pointer<Void>, int)>()(self, connection);

// IEnumFORMATETC: Next 3, Skip 4, Reset 5, Clone 6.

int _next(
  Pointer<Void> self,
  int count,
  Pointer<Void> buffer,
  Pointer<Uint32> fetched,
) =>
    comMethod<ComServerCountPointerOutNative>(self, 3).asFunction<
            int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>)>()(
        self, count, buffer, fetched);

int _skip(Pointer<Void> self, int count) =>
    comMethod<ComServerIntNative>(self, 4)
        .asFunction<int Function(Pointer<Void>, int)>()(self, count);

int _reset(Pointer<Void> self) => comMethod<ComServerSelfNative>(self, 5)
    .asFunction<int Function(Pointer<Void>)>()(self);

int _clone(Pointer<Void> self, Pointer<Void> out) =>
    comMethod<ComServerPointerNative>(self, 6)
        .asFunction<int Function(Pointer<Void>, Pointer<Void>)>()(self, out);

// IDropSource: QueryContinueDrag 3, GiveFeedback 4.

int _queryContinueDrag(Pointer<Void> self, int escapePressed, int keyState) =>
    comMethod<ComServerIntIntNative>(self, 3)
            .asFunction<int Function(Pointer<Void>, int, int)>()(
        self, escapePressed, keyState);

int _giveFeedback(Pointer<Void> self, int effect) =>
    comMethod<ComServerIntNative>(self, 4)
        .asFunction<int Function(Pointer<Void>, int)>()(self, effect);
