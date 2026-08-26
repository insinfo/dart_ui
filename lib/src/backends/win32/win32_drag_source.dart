/// The Win32 drag **source**: `IDataObject`, `IEnumFORMATETC` and
/// `IDropSource`, all three implemented in Dart.
///
/// `win32_drag_drop.dart` is the destination half - it is *called* by whatever
/// is dragging over this window. This file is the mirror image and it is the
/// harder one, because a source has to answer questions rather than ask them:
/// once `DoDragDrop` is running, Explorer, Word or whatever is under the cursor
/// will call into these vtables at will, from inside the modal loop, and every
/// answer has to be correct before it returns.
///
/// ## Three objects, because OLE asks three different questions
///
///  * **`IDataObject`** is the payload. `GetData` hands over an `HGLOBAL` the
///    receiver then owns; `QueryGetData` answers "do you have this format" for
///    a target that probes; `EnumFormatEtc` answers it for a target that does
///    not.
///  * **`IEnumFORMATETC`** exists because *Explorer enumerates*. A source that
///    implements only `QueryGetData` works with half the targets in the world
///    and mysteriously does nothing on the other half, which is exactly the
///    kind of bug that gets diagnosed as "drag and drop is flaky".
///  * **`IDropSource`** is the loop's steering: it is asked on every mouse
///    message whether to keep going, and it decides when the drag ends.
///
/// ## Every slot is declared with its real signature
///
/// The unimplemented methods return `E_NOTIMPL` or
/// [oleErrorAdviseNotSupported], but they are still bound with the argument
/// list the header gives them - `SetData` really is
/// `(FORMATETC*, STGMEDIUM*, BOOL)` and `DAdvise` really is
/// `(FORMATETC*, DWORD, IAdviseSink*, DWORD*)`. The test double in
/// `win32_drag_drop_test.dart` gets away with binding them all as one-pointer
/// stubs because nothing ever calls them; a real drop target in another process
/// *does* call them, and a callee whose declared shape does not match the
/// caller's is undefined behaviour whether or not it looks at the arguments.
///
/// ## The payload is a snapshot, and it has to be
///
/// `IDataObject::GetData` is synchronous and is reached from inside the modal
/// loop, where no Dart microtask can run - so there is no way to await a
/// [LazyDragData] there. Every format is therefore materialised into plain
/// bytes *before* `DoDragDrop` is entered; see
/// [win32MaterialiseDragPayload]. The port already documents this asymmetry in
/// `DragRequest.data`.
///
/// ## Translation is the destination's, run backwards
///
///  * `text/plain;charset=utf-8` becomes `CF_UNICODETEXT`: UTF-8 in, UTF-16
///    out, NUL-terminated, because that is what every Windows target reads.
///  * `text/uri-list` becomes `CF_HDROP`: the URIs are parsed, the `file://`
///    ones are turned back into paths, and the paths go into a `DROPFILES`
///    block with `fWide = 1` and a double-NUL at the end.
///
/// A URI that names no local file - a `http://` one dropped from a browser -
/// has no `CF_HDROP` spelling at all and is skipped rather than turned into a
/// nonsense path, which is the same rule `DragDataReading.readFilePaths`
/// applies on the way in.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/com.dart';
import '../../platform/drag_drop.dart';
import 'uia/com_server.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_ole.dart';

// ---------------------------------------------------------------------------
// Payload encoding
// ---------------------------------------------------------------------------

/// A `CF_UNICODETEXT` block: [text] as NUL-terminated UTF-16.
///
/// The terminator is not optional and is not padding. A `CF_UNICODETEXT`
/// receiver scans for the NUL rather than asking `GlobalSize`, for the reason
/// `win32ReadUnicodeTextAt` documents on the reading side - the allocation is
/// rounded up and the extra bytes are whatever the heap last had there. A
/// block without it delivers the text plus a random tail.
Uint8List win32BuildUnicodeText(String text) {
  final List<int> units = <int>[...text.codeUnits, 0];
  final Uint8List block = Uint8List(units.length * 2);
  final ByteData view = ByteData.sublistView(block);
  for (int index = 0; index < units.length; index++) {
    view.setUint16(index * 2, units[index], Endian.little);
  }
  return block;
}

/// A `CF_HDROP` block naming [paths]: a `DROPFILES` header followed by the
/// double-NUL-terminated wide name list.
///
/// The exact inverse of `win32ReadDropFilesAt`, and the round trip between the
/// two is what the test asserts - an encoder tested only against its own
/// expectations is an encoder tested against nothing.
///
/// Three details are load-bearing:
///
///  * **`pFiles` is written as the real offset of the first name.** It happens
///    to be `sizeof(DROPFILES)` here because nothing is inserted in between,
///    but the reader is entitled to trust the field rather than the constant
///    and so is every other reader.
///  * **`fWide` is 1.** The names are UTF-16, and a receiver that read them as
///    ANSI because the flag said so would get one character per two bytes.
///  * **The list ends with an empty name**, which is what the trailing extra
///    NUL is. A block that ends with only the last name's own terminator runs
///    the receiver off the end of the allocation.
///
/// [paths] may be empty, and then the block is a header and a single NUL -
/// a well-formed `CF_HDROP` naming nothing, which is what an empty file list
/// is. Whether such a thing should be *offered* is [win32MaterialiseDragPayload]'s
/// decision, not this function's.
Uint8List win32BuildDropFiles(List<String> paths) {
  final List<int> names = <int>[];
  for (final String path in paths) {
    names
      ..addAll(path.codeUnits)
      ..add(0);
  }
  names.add(0);

  final int size = OleStructLayout.dropFilesSize + names.length * 2;
  final Uint8List block = Uint8List(size);
  final ByteData view = ByteData.sublistView(block);
  view.setUint32(
    OleStructLayout.dropFilesOffset,
    OleStructLayout.dropFilesSize,
    Endian.little,
  );
  view.setUint32(OleStructLayout.dropFilesWide, 1, Endian.little);
  for (int index = 0; index < names.length; index++) {
    view.setUint16(
      OleStructLayout.dropFilesSize + index * 2,
      names[index],
      Endian.little,
    );
  }
  return block;
}

/// Every format of [data] that Windows has a spelling for, as clipboard format
/// to bytes, read **now**.
///
/// Asynchronous, and deliberately called before `DoDragDrop` rather than from
/// inside `GetData`: the port's [DragData.readBytes] is a `Future` on every
/// platform, and the one moment a Win32 source cannot await is the moment a
/// target asks for the data. So the whole payload is resolved up front and the
/// COM object serves it out of memory.
///
/// The order is the order a target sees in `EnumFormatEtc`, and a source
/// advertises its *richest* format first: a target that takes files and text
/// should take the files. Hence `CF_HDROP` before `CF_UNICODETEXT`.
Future<Map<int, Uint8List>> win32MaterialiseDragPayload(DragData data) async {
  final Map<int, Uint8List> payload = <int, Uint8List>{};

  final List<String> paths = await data.readFilePaths();
  if (paths.isNotEmpty) payload[cfHDrop] = win32BuildDropFiles(paths);

  final String? text = await data.readText();
  if (text != null) payload[cfUnicodeText] = win32BuildUnicodeText(text);

  return payload;
}

// ---------------------------------------------------------------------------
// IDataObject
// ---------------------------------------------------------------------------

/// Builds an `IEnumFORMATETC` over [formats] starting at [index], returning the
/// pointer whose one reference the caller takes over, or null when one could
/// not be made.
///
/// A callback rather than a direct dependency so that [Win32DragDataObject] does
/// not have to own a [ComServerClass] of a type it knows nothing else about -
/// the enumerator's lifetime belongs to [Win32DragSourceObjects], which is the
/// only thing that can outlive both.
typedef Win32FormatEnumeratorFactory = Pointer<Void>? Function(
  List<int> formats,
  int index,
);

/// The Dart object behind the `IDataObject` this application drags out.
///
/// Holds the materialised payload and nothing else: no window, no handler, no
/// future. Everything it is asked has an answer already in memory, which is the
/// only shape that can survive being called from inside a modal loop.
final class Win32DragDataObject {
  Win32DragDataObject({
    required Map<int, Uint8List> payload,
    required Win32Api api,
    required this.createEnumerator,
  })  : _payload = Map<int, Uint8List>.unmodifiable(payload),
        _api = api;

  final Map<int, Uint8List> _payload;
  final Win32Api _api;

  /// How a fresh `IEnumFORMATETC` is made. See [Win32FormatEnumeratorFactory].
  final Win32FormatEnumeratorFactory createEnumerator;

  /// The clipboard formats offered, in the order they are advertised.
  List<int> get formats => List<int>.unmodifiable(_payload.keys);

  /// How many times a target really took the data. Diagnostics and tests only.
  int getDataCalls = 0;

  /// `IDataObject::GetData`.
  ///
  /// **A fresh `HGLOBAL` per call, every call.** The `STGMEDIUM` this fills has
  /// a null `pUnkForRelease`, which is COM's way of saying "you own this now,
  /// `ReleaseStgMedium` will `GlobalFree` it" - so handing out the same handle
  /// twice would have the second receiver free memory the first one is still
  /// reading, and handing out a handle this object also holds would have it
  /// freed under us. The bytes are copied; the source keeps its snapshot.
  int getData(Pointer<Uint8> format, Pointer<Uint8> medium) {
    if (format == nullptr || medium == nullptr) return ePointer;
    // Cleared first: a caller is entitled to hand over uninitialised memory,
    // and a failure that left a stale handle in it would be freed by the
    // caller's own cleanup.
    for (int i = 0; i < OleStructLayout.stgMediumSize; i++) {
      medium[i] = 0;
    }
    if ((readFormatEtcTymed(format) & tymedHGlobal) == 0) return dvErrorTymed;
    final Uint8List? bytes = _payload[readFormatEtcFormat(format)];
    if (bytes == null) return dvErrorFormatEtc;

    final int handle = _allocateGlobal(bytes);
    if (handle == 0) return eOutOfMemory;
    writeStgMediumGlobal(medium, handle);
    getDataCalls++;
    return sOk;
  }

  /// `IDataObject::GetDataHere`, which fills a medium the *caller* allocated.
  ///
  /// `E_NOTIMPL` is the ordinary answer for an `HGLOBAL`-only source and is
  /// explicitly allowed: the method exists for `TYMED_ISTORAGE`, where the
  /// caller has a storage it wants written into, and this object has nothing
  /// that shape.
  int getDataHere(Pointer<Uint8> format, Pointer<Uint8> medium) =>
      eNotImplemented;

  /// `IDataObject::QueryGetData`.
  ///
  /// `DV_E_FORMATETC` and not `S_FALSE` for an unknown format: `S_FALSE` is a
  /// success code, and a target that checks with `SUCCEEDED()` - which many do
  /// - would read it as "yes" and then get nothing from `GetData`.
  int queryGetData(Pointer<Uint8> format) {
    if (format == nullptr) return ePointer;
    if ((readFormatEtcTymed(format) & tymedHGlobal) == 0) return dvErrorTymed;
    return _payload.containsKey(readFormatEtcFormat(format))
        ? sOk
        : dvErrorFormatEtc;
  }

  /// `IDataObject::GetCanonicalFormatEtc`.
  ///
  /// This object has no target device, so every `FORMATETC` it is handed is
  /// already canonical. The documented way to say that is to copy the input
  /// out, null the `ptd`, and answer `DATA_S_SAMEFORMATETC` - which is a
  /// success code, so the caller reuses the format it already had.
  int getCanonicalFormatEtc(Pointer<Uint8> input, Pointer<Uint8> output) {
    if (output == nullptr) return ePointer;
    for (int i = 0; i < OleStructLayout.formatEtcSize; i++) {
      output[i] = input == nullptr ? 0 : input[i];
    }
    // The target device pointer is not ours to copy: the caller frees what it
    // allocated, and a duplicate here would be freed twice.
    final ByteData view = ByteData.sublistView(
      output.asTypedList(OleStructLayout.formatEtcSize),
    );
    if (sizeOf<IntPtr>() == 8) {
      view.setUint64(OleStructLayout.formatEtcTargetDevice, 0, Endian.little);
    } else {
      view.setUint32(OleStructLayout.formatEtcTargetDevice, 0, Endian.little);
    }
    return dataStatusSameFormatEtc;
  }

  /// `IDataObject::SetData`. A drag source is read-only.
  int setData(Pointer<Uint8> format, Pointer<Uint8> medium, int release) =>
      eNotImplemented;

  /// `IDataObject::EnumFormatEtc`.
  ///
  /// The method Explorer actually uses. See the library comment for why
  /// implementing only [queryGetData] leaves a source that works on some
  /// targets and silently does nothing on others.
  int enumFormatEtc(int direction, Pointer<Void> out) {
    if (out == nullptr) return ePointer;
    final Pointer<Pointer<Void>> target = out.cast<Pointer<Void>>();
    target.value = nullptr;
    if (direction != dataDirGet) return eNotImplemented;
    final Pointer<Void>? enumerator = createEnumerator(formats, 0);
    if (enumerator == null) return eOutOfMemory;
    target.value = enumerator;
    return sOk;
  }

  /// `IDataObject::DAdvise`. See [oleErrorAdviseNotSupported].
  int dAdvise(
    Pointer<Uint8> format,
    int flags,
    Pointer<Void> sink,
    Pointer<Uint32> connection,
  ) {
    if (connection != nullptr) connection.value = 0;
    return oleErrorAdviseNotSupported;
  }

  /// `IDataObject::DUnadvise`.
  int dUnadvise(int connection) => oleErrorAdviseNotSupported;

  /// `IDataObject::EnumDAdvise`.
  int enumDAdvise(Pointer<Void> out) {
    if (out != nullptr) out.cast<Pointer<Void>>().value = nullptr;
    return oleErrorAdviseNotSupported;
  }

  /// Moveable global memory holding a copy of [bytes], or 0.
  ///
  /// `GMEM_MOVEABLE` and not `GMEM_FIXED`: the clipboard and drag-and-drop
  /// contracts both say the handle they are given is a moveable one, and a
  /// receiver calls `GlobalLock` on it. A fixed allocation happens to work with
  /// most receivers and fails with the ones that are strict, which is the worst
  /// of both.
  int _allocateGlobal(Uint8List bytes) {
    final int Function(int, int)? alloc = _api.globalAlloc;
    final int Function(int)? lock = _api.globalLock;
    final int Function(int)? unlock = _api.globalUnlock;
    if (alloc == null || lock == null || unlock == null) return 0;

    final int handle = alloc(gmemMoveable, bytes.length);
    if (handle == 0) return 0;
    final int address = lock(handle);
    if (address == 0) {
      _api.globalFree?.call(handle);
      return 0;
    }
    Pointer<Uint8>.fromAddress(address)
        .asTypedList(bytes.length)
        .setAll(0, bytes);
    unlock(handle);
    return handle;
  }
}

/// `IDataObject` in vtable order, every slot declared with its real signature.
///
/// The order is fixed by the header and there is nothing to derive it from, so
/// it is written out with the slot each method lands in:
/// `GetData` 3, `GetDataHere` 4, `QueryGetData` 5, `GetCanonicalFormatEtc` 6,
/// `SetData` 7, `EnumFormatEtc` 8, `DAdvise` 9, `DUnadvise` 10,
/// `EnumDAdvise` 11.
ComInterfaceSpec<Win32DragDataObject> win32DataObjectSpec() =>
    ComInterfaceSpec<Win32DragDataObject>(
      name: 'IDataObject',
      iid: iidIDataObject,
      methods: <ComMethod<Win32DragDataObject>>[
        ComPointerPointerMethod<Win32DragDataObject>(
          'GetData',
          (Win32DragDataObject self, Pointer<Void> format,
                  Pointer<Void> medium) =>
              self.getData(format.cast<Uint8>(), medium.cast<Uint8>()),
        ),
        ComPointerPointerMethod<Win32DragDataObject>(
          'GetDataHere',
          (Win32DragDataObject self, Pointer<Void> format,
                  Pointer<Void> medium) =>
              self.getDataHere(format.cast<Uint8>(), medium.cast<Uint8>()),
        ),
        ComPointerMethod<Win32DragDataObject>(
          'QueryGetData',
          (Win32DragDataObject self, Pointer<Void> format) =>
              self.queryGetData(format.cast<Uint8>()),
        ),
        ComPointerPointerMethod<Win32DragDataObject>(
          'GetCanonicalFormatEtc',
          (Win32DragDataObject self, Pointer<Void> input,
                  Pointer<Void> output) =>
              self.getCanonicalFormatEtc(
                  input.cast<Uint8>(), output.cast<Uint8>()),
        ),
        ComPointerPointerFlagMethod<Win32DragDataObject>(
          'SetData',
          (Win32DragDataObject self, Pointer<Void> format, Pointer<Void> medium,
                  int release) =>
              self.setData(format.cast<Uint8>(), medium.cast<Uint8>(), release),
        ),
        // `dwDirection` is a `DWORD`; `ComIntPointerMethod` declares the slot
        // as `Int32`, which is the same 32-bit argument register on both
        // architectures and the same value for the only two it can hold.
        ComIntPointerMethod<Win32DragDataObject>(
          'EnumFormatEtc',
          (Win32DragDataObject self, int direction, Pointer<Void> out) =>
              self.enumFormatEtc(direction, out),
        ),
        ComPointerIntPointerOutMethod<Win32DragDataObject>(
          'DAdvise',
          (Win32DragDataObject self, Pointer<Void> format, int flags,
                  Pointer<Void> sink, Pointer<Uint32> connection) =>
              self.dAdvise(format.cast<Uint8>(), flags, sink, connection),
        ),
        ComIntMethod<Win32DragDataObject>(
          'DUnadvise',
          (Win32DragDataObject self, int connection) =>
              self.dUnadvise(connection),
        ),
        ComPointerMethod<Win32DragDataObject>(
          'EnumDAdvise',
          (Win32DragDataObject self, Pointer<Void> out) =>
              self.enumDAdvise(out),
        ),
      ],
    );

// ---------------------------------------------------------------------------
// IEnumFORMATETC
// ---------------------------------------------------------------------------

/// The Dart object behind an `IEnumFORMATETC`.
///
/// One cursor over a fixed list. Cloning really does produce an independent
/// cursor at the same position, because that is what `Clone` promises and a
/// target that clones to look ahead and then keeps reading from the original
/// would otherwise skip formats.
final class Win32FormatEnumerator {
  Win32FormatEnumerator(
    List<int> formats, {
    required this.clone,
    int index = 0,
  })  : formats = List<int>.unmodifiable(formats),
        _index = index;

  /// The formats enumerated, in advertisement order.
  final List<int> formats;

  /// How a clone is made; see [Win32FormatEnumeratorFactory].
  final Win32FormatEnumeratorFactory clone;

  int _index;

  /// Where the cursor is. Readable so a test can prove `Skip` and `Reset`
  /// moved it rather than merely returning the right HRESULT.
  int get index => _index;

  /// `IEnumFORMATETC::Next`.
  ///
  /// `S_OK` **only** when all [count] were fetched, `S_FALSE` otherwise -
  /// including when some but not all were. That is the enumerator contract
  /// everywhere in COM and it is what ends a caller's loop; answering `S_OK`
  /// after a short read makes a target ask again forever.
  ///
  /// [fetched] may legitimately be null, but only when exactly one element was
  /// asked for. Anything else with a null count is `E_INVALIDARG`, because the
  /// caller would have no way to learn it got a short read.
  int next(int count, Pointer<Void> buffer, Pointer<Uint32> fetched) {
    if (count != 0 && buffer == nullptr) return ePointer;
    if (fetched == nullptr && count != 1) return eInvalidArg;

    int written = 0;
    while (written < count && _index < formats.length) {
      writeFormatEtc(
        Pointer<Uint8>.fromAddress(
          buffer.address + written * OleStructLayout.formatEtcSize,
        ),
        formats[_index],
      );
      _index++;
      written++;
    }
    if (fetched != nullptr) fetched.value = written;
    return written == count ? sOk : sFalse;
  }

  /// `IEnumFORMATETC::Skip`. `S_FALSE` when it ran off the end, and the cursor
  /// stops there rather than going past it.
  int skip(int count) {
    final int remaining = formats.length - _index;
    if (count <= remaining) {
      _index += count;
      return sOk;
    }
    _index = formats.length;
    return sFalse;
  }

  /// `IEnumFORMATETC::Reset`.
  int reset() {
    _index = 0;
    return sOk;
  }

  /// `IEnumFORMATETC::Clone`. The copy starts where this one is now.
  int cloneInto(Pointer<Void> out) {
    if (out == nullptr) return ePointer;
    final Pointer<Pointer<Void>> target = out.cast<Pointer<Void>>();
    target.value = nullptr;
    final Pointer<Void>? copy = clone(formats, _index);
    if (copy == null) return eOutOfMemory;
    target.value = copy;
    return sOk;
  }
}

/// `IEnumFORMATETC` in vtable order: `Next` 3, `Skip` 4, `Reset` 5, `Clone` 6.
ComInterfaceSpec<Win32FormatEnumerator> win32FormatEnumeratorSpec() =>
    ComInterfaceSpec<Win32FormatEnumerator>(
      name: 'IEnumFORMATETC',
      iid: iidIEnumFormatEtc,
      methods: <ComMethod<Win32FormatEnumerator>>[
        ComCountPointerOutMethod<Win32FormatEnumerator>(
          'Next',
          (Win32FormatEnumerator self, int count, Pointer<Void> buffer,
                  Pointer<Uint32> fetched) =>
              self.next(count, buffer, fetched),
        ),
        ComIntMethod<Win32FormatEnumerator>(
          'Skip',
          (Win32FormatEnumerator self, int count) => self.skip(count),
        ),
        ComSelfMethod<Win32FormatEnumerator>(
          'Reset',
          (Win32FormatEnumerator self) => self.reset(),
        ),
        ComPointerMethod<Win32FormatEnumerator>(
          'Clone',
          (Win32FormatEnumerator self, Pointer<Void> out) =>
              self.cloneInto(out),
        ),
      ],
    );

// ---------------------------------------------------------------------------
// IDropSource
// ---------------------------------------------------------------------------

/// The Dart object behind the `IDropSource` that steers the modal loop.
///
/// Two methods and three rules, and the rules are not negotiable - they are
/// what every user on Windows has learned drag and drop does:
///
///  1. **Escape cancels.** `DRAGDROP_S_CANCEL`, whatever the buttons are doing.
///  2. **Releasing the button that started the drag drops.**
///     `DRAGDROP_S_DROP`. Which button that was matters: a right-drag - the one
///     that opens the copy/move/shortcut menu on drop - ends when the *right*
///     button comes up, and a source hardcoded to `MK_LBUTTON` would end it
///     immediately, because the left button was never down.
///  3. **Anything else continues.** `S_OK`, and the loop keeps running.
///
/// `GiveFeedback` answers `DRAGDROP_S_USEDEFAULTCURSORS`, which is not a
/// refusal to draw anything - it asks Windows to draw the standard copy, move,
/// link and no-drop cursors. A source that returns `S_OK` there is claiming it
/// set a cursor itself, and one that then does not leaves the user dragging
/// with an arrow that never changes.
final class Win32DropSource {
  Win32DropSource({this.initiatingButton = mkLButton});

  /// The `MK_*` bit of the button the gesture began with. See rule 2.
  final int initiatingButton;

  /// The last effect Windows reported, so a caller can show its own hint. Set
  /// from inside the modal loop, which is the only place it changes.
  int lastEffect = dropEffectNone;

  /// How many times the loop asked. Diagnostics and tests only.
  int queryContinueCalls = 0;

  /// `IDropSource::QueryContinueDrag`.
  int queryContinueDrag(int escapePressed, int keyState) {
    queryContinueCalls++;
    if (escapePressed != 0) return dragDropStatusCancel;
    if ((keyState & initiatingButton) == 0) return dragDropStatusDrop;
    return sOk;
  }

  /// `IDropSource::GiveFeedback`.
  int giveFeedback(int effect) {
    lastEffect = effect;
    return dragDropStatusUseDefaultCursors;
  }
}

/// `IDropSource` in vtable order: `QueryContinueDrag` 3, `GiveFeedback` 4.
ComInterfaceSpec<Win32DropSource> win32DropSourceSpec() =>
    ComInterfaceSpec<Win32DropSource>(
      name: 'IDropSource',
      iid: iidIDropSource,
      methods: <ComMethod<Win32DropSource>>[
        ComIntIntMethod<Win32DropSource>(
          'QueryContinueDrag',
          (Win32DropSource self, int escapePressed, int keyState) =>
              self.queryContinueDrag(escapePressed, keyState),
        ),
        ComIntMethod<Win32DropSource>(
          'GiveFeedback',
          (Win32DropSource self, int effect) => self.giveFeedback(effect),
        ),
      ],
    );

// ---------------------------------------------------------------------------
// One drag's objects, alive together
// ---------------------------------------------------------------------------

/// The COM objects one `DoDragDrop` needs, created and destroyed as a unit.
///
/// A class per drag rather than one cached in the backend, unlike the
/// `IDropTarget` class: a drag is a user gesture that happens a few times a
/// minute at most, the vtables cost a handful of `NativeCallable`s to build,
/// and a per-drag class means the enumerators a target leaked are cleaned up
/// when the drag ends instead of accumulating for the life of the process.
///
/// [dispose] must be called on every path out of the drag - the `finally` in
/// `Win32DragDropBackend.startDrag` is that path.
final class Win32DragSourceObjects {
  Win32DragSourceObjects({
    required Map<int, Uint8List> payload,
    required Win32Api api,
    int initiatingButton = mkLButton,
  }) {
    _enumeratorClass = ComServerClass<Win32FormatEnumerator>(
      'Win32FormatEnumerator',
      <ComInterfaceSpec<Win32FormatEnumerator>>[win32FormatEnumeratorSpec()],
    );
    _dataClass = ComServerClass<Win32DragDataObject>(
      'Win32DragDataObject',
      <ComInterfaceSpec<Win32DragDataObject>>[win32DataObjectSpec()],
    );
    _sourceClass = ComServerClass<Win32DropSource>(
      'Win32DropSource',
      <ComInterfaceSpec<Win32DropSource>>[win32DropSourceSpec()],
    );

    dataObject = Win32DragDataObject(
      payload: payload,
      api: api,
      createEnumerator: _newEnumerator,
    );
    dropSource = Win32DropSource(initiatingButton: initiatingButton);
    _dataHandle = _dataClass.instantiate(dataObject);
    _sourceHandle = _sourceClass.instantiate(dropSource);
  }

  late final ComServerClass<Win32FormatEnumerator> _enumeratorClass;
  late final ComServerClass<Win32DragDataObject> _dataClass;
  late final ComServerClass<Win32DropSource> _sourceClass;

  late final ComServerObject<Win32DragDataObject> _dataHandle;
  late final ComServerObject<Win32DropSource> _sourceHandle;

  final List<ComServerObject<Win32FormatEnumerator>> _enumerators =
      <ComServerObject<Win32FormatEnumerator>>[];

  /// The Dart object behind the `IDataObject`, so a test can read what it was
  /// asked without going through the vtable.
  late final Win32DragDataObject dataObject;

  /// The Dart object behind the `IDropSource`.
  late final Win32DropSource dropSource;

  /// The `IDataObject` pointer `DoDragDrop` takes.
  Pointer<Void> get dataObjectPointer => _dataHandle.pointer;

  /// The `IDropSource` pointer `DoDragDrop` takes.
  Pointer<Void> get dropSourcePointer => _sourceHandle.pointer;

  /// How many enumerators have been handed out. Diagnostics and tests.
  int get enumeratorCount => _enumerators.length;

  /// One new `IEnumFORMATETC`, whose single reference belongs to the caller.
  ///
  /// The object is created with a reference count of one and is deliberately
  /// **not** disposed here: that one reference is the client's, exactly as
  /// COM's rule for an out parameter requires. [dispose] releases whatever a
  /// client failed to, which is a backstop rather than the normal path.
  Pointer<Void>? _newEnumerator(List<int> formats, int index) {
    final Win32FormatEnumerator enumerator = Win32FormatEnumerator(
      formats,
      index: index,
      clone: _newEnumerator,
    );
    final ComServerObject<Win32FormatEnumerator> object =
        _enumeratorClass.instantiate(enumerator);
    _enumerators.add(object);
    return object.pointer;
  }

  /// Gives up this side's references and releases the vtables.
  ///
  /// The enumerators go first and unconditionally: `ComServerObject.dispose`
  /// drops one reference and does nothing at all once the count has reached
  /// zero, so a client that released properly is unaffected and one that
  /// leaked is cleaned up. The classes only really tear down when the last
  /// object of each is gone, which is [ComServerClass]'s own rule.
  void dispose() {
    for (final ComServerObject<Win32FormatEnumerator> enumerator
        in _enumerators) {
      enumerator.dispose();
    }
    _enumerators.clear();
    _dataHandle.dispose();
    _sourceHandle.dispose();
    _enumeratorClass.dispose();
    _dataClass.dispose();
    _sourceClass.dispose();
  }
}
