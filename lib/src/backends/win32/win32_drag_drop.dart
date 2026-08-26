/// `IDropTarget` implemented in Dart, and the Win32 half of the drag-and-drop
/// port.
///
/// ## Why this is a COM *server*, not another FFI call
///
/// Every other Win32 feature in this backend is Dart calling Windows.
/// Drag and drop inverts that: `RegisterDragDrop(hwnd, pDropTarget)` hands the
/// OLE runtime a pointer to an object **it** will call, four methods at a time,
/// while the user is dragging. There is no message to handle and no function to
/// poll - the only way to receive a drop on Windows is to be a COM object.
///
/// `uia/com_server.dart` already builds vtables Windows calls into, for the
/// accessibility provider, and this reuses it rather than hand-rolling a second
/// mechanism. Two method shapes were missing there and were added:
/// [ComObjectStatePointOutMethod] for `DragEnter`/`Drop` and
/// [ComStatePointOutMethod] for `DragOver`.
///
/// ## The reentrancy the port documents, in practice
///
/// `IDropTarget::DragOver` is called from inside the OLE drag loop and must
/// write `*pdwEffect` **before it returns**. The isolate is inside
/// `pumpEvents` -> `DispatchMessageW` at that moment, so no microtask can run:
/// anything after an `await` in a handler is dead code for the duration, which
/// is the same trap `LiveResizeWindow` documents for the modal resize loop.
/// Hence [DropTargetHandler]'s enter/over/leave are synchronous, and hence this
/// file never awaits anything on the way to an answer.
///
/// The drop is the one place a future appears, and it is honest about what it
/// can and cannot do: the bytes are read from `IDataObject` **synchronously,
/// while `Drop` is still on the stack**, into a [MemoryDragData], so the
/// handler's `readBytes` future is already complete when it looks at it. What
/// the future cannot do is change what the source is told: `*pdwEffect` has to
/// be written before `Drop` returns, so it carries the action the last
/// `DragOver` agreed to. A handler that must be able to refuse has to refuse
/// during `DragOver`.
///
/// ## Formats are translated, not merely renamed
///
/// The port speaks MIME types and UTF-8 (see `drag_drop_types.dart`); Windows
/// speaks numeric clipboard formats and UTF-16, and packs a file list into a
/// `DROPFILES` block. So this backend converts the *payload*, not only the
/// name:
///
///  * `CF_UNICODETEXT` becomes `text/plain;charset=utf-8`, re-encoded;
///  * `CF_HDROP` becomes `text/uri-list`, each path turned into a `file://`
///    URI.
///
/// Handing over the raw UTF-16 under a MIME name would produce a `String` full
/// of NUL bytes in every caller that did the obvious thing, and handing over
/// `CF_TEXT` as `text/plain` would hand over ANSI bytes in the machine's code
/// page labelled as something else. Neither is offered.
///
/// ## The other half
///
/// Dragging *out* of this application is `win32_drag_source.dart`: the
/// `IDataObject`, `IEnumFORMATETC` and `IDropSource` that `DoDragDrop` needs,
/// plus the encoders that run the translation above backwards.
/// [Win32DragDropBackend.startDrag] is the seam between the two and lives here,
/// because it is the backend's method.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/com.dart';
import '../../ffi/native_memory.dart';
import '../../foundation/diagnostics.dart';
import '../../geometry/offset.dart';
import '../../platform/drag_drop.dart';
import '../../platform/input_events.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import 'uia/com_server.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_drag_source.dart';
import 'win32_ole.dart';
import 'win32_window.dart';

// ---------------------------------------------------------------------------
// Format and payload translation
// ---------------------------------------------------------------------------

/// The clipboard formats this backend understands, in the order it prefers to
/// advertise them.
///
/// A short list on purpose. `IDataObject::EnumFormatEtc` would report the
/// twenty-odd private formats Explorer and Office attach to every drag
/// (`Shell IDList Array`, `FileGroupDescriptorW`, `Preferred DropEffect`...),
/// and this backend can translate none of them into the port's vocabulary. A
/// format it cannot produce bytes for has no business appearing in
/// [DragData.formats], where a target would match on it and then read null.
const List<int> win32DragFormats = <int>[cfHDrop, cfUnicodeText];

/// The MIME name a clipboard format is offered under, or null when this
/// backend has no translation for it.
String? win32MimeForClipboardFormat(int format) => switch (format) {
      cfUnicodeText => DragFormats.text,
      cfHDrop => DragFormats.uriList,
      _ => null,
    };

/// The clipboard format a MIME name asks for, or 0.
int win32ClipboardFormatForMime(String mime) => switch (mime) {
      DragFormats.text ||
      DragFormats.plainText ||
      DragFormats.utf8String =>
        cfUnicodeText,
      DragFormats.uriList => cfHDrop,
      _ => 0,
    };

/// Reads a NUL-terminated UTF-16 string out of global memory.
///
/// The same scan `Win32Clipboard.readText` does, and for the same reason:
/// `GlobalSize` rounds up to the allocation granularity, so it says how much
/// memory there is and not how much text - a difference that shows up as
/// trailing garbage exactly when the text happens to end near a boundary.
String win32ReadUnicodeTextAt(int address) {
  if (address == 0) return '';
  final Pointer<Uint16> pointer = Pointer<Uint16>.fromAddress(address);
  final List<int> units = <int>[];
  for (int index = 0;; index++) {
    final int unit = (pointer + index).value;
    if (unit == 0) break;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}

/// Reads the paths out of a `CF_HDROP` block.
///
/// The layout is a `DROPFILES` header followed by the names, and both of the
/// header's variable parts have to be read rather than assumed:
///
///  * **`pFiles` is the offset of the first name**, not `sizeof(DROPFILES)`.
///    Explorer happens to use twenty, but the field exists precisely so a
///    source may put something in between, and a hardcoded twenty reads the
///    first name half a character in.
///  * **`fWide` says whether the names are UTF-16 or ANSI.** Every modern
///    source sets it, and a source that does not is not thereby entitled to be
///    misread as UTF-16, which produces one CJK character per two ASCII ones.
///
/// The list ends with an empty name - the double NUL - and each name is
/// NUL-terminated.
List<String> win32ReadDropFilesAt(int address) {
  if (address == 0) return const <String>[];
  final Pointer<Uint8> base = Pointer<Uint8>.fromAddress(address);
  final ByteData header =
      ByteData.sublistView(base.asTypedList(OleStructLayout.dropFilesSize));
  final int offset =
      header.getUint32(OleStructLayout.dropFilesOffset, Endian.little);
  final bool wide =
      header.getUint32(OleStructLayout.dropFilesWide, Endian.little) != 0;
  if (offset < OleStructLayout.dropFilesSize) return const <String>[];

  final List<String> paths = <String>[];
  if (wide) {
    final Pointer<Uint16> names = Pointer<Uint16>.fromAddress(address + offset);
    final List<int> units = <int>[];
    for (int index = 0;; index++) {
      final int unit = (names + index).value;
      if (unit != 0) {
        units.add(unit);
        continue;
      }
      if (units.isEmpty) break;
      paths.add(String.fromCharCodes(units));
      units.clear();
    }
  } else {
    final Pointer<Uint8> names = Pointer<Uint8>.fromAddress(address + offset);
    final List<int> bytes = <int>[];
    for (int index = 0;; index++) {
      final int byte = (names + index).value;
      if (byte != 0) {
        bytes.add(byte);
        continue;
      }
      if (bytes.isEmpty) break;
      // Latin-1 rather than UTF-8: an ANSI `CF_HDROP` is in the machine's
      // code page, and Latin-1 at least round-trips the bytes instead of
      // rejecting them. A source this old with a non-ASCII path is beyond
      // rescue from here, and pretending otherwise would hide it.
      paths.add(String.fromCharCodes(bytes));
      bytes.clear();
    }
  }
  return paths;
}

/// `DROPEFFECT_*` bits as the port's actions.
///
/// `DROPEFFECT_SCROLL` is masked off first: a source that wants auto-scrolling
/// ORs it into the effects it offers, and reading it as an unknown action would
/// make an ordinary copy-only drag look like something this backend cannot
/// handle.
Set<DragAction> win32ActionsFromEffect(int effect) {
  final int bits = effect & ~dropEffectScroll;
  return <DragAction>{
    if ((bits & dropEffectCopy) != 0) DragAction.copy,
    if ((bits & dropEffectMove) != 0) DragAction.move,
    if ((bits & dropEffectLink) != 0) DragAction.link,
  };
}

/// One action as its `DROPEFFECT` bit.
///
/// [DragAction.ask] has no Win32 spelling and becomes [dropEffectNone] - a
/// refusal, exactly as `drag_drop_types.dart` says it must, rather than a
/// silent substitution of copy.
int win32EffectForAction(DragAction action) => switch (action) {
      DragAction.copy => dropEffectCopy,
      DragAction.move => dropEffectMove,
      DragAction.link => dropEffectLink,
      DragAction.none || DragAction.ask => dropEffectNone,
    };

/// The whole set as one bitmask, for `DoDragDrop`'s allowed effects.
int win32EffectMask(Set<DragAction> actions) {
  int mask = dropEffectNone;
  for (final DragAction action in actions) {
    mask |= win32EffectForAction(action);
  }
  return mask;
}

/// The modifiers an OLE `grfKeyState` reports.
///
/// Only the three that mean something to a drop; the button bits are in the
/// same word and are deliberately not turned into modifiers, because a drag
/// always has a button down and reporting it would make every drop look like a
/// modified one.
Set<KeyModifier> win32ModifiersFromKeyState(int keyState) => <KeyModifier>{
      if ((keyState & mkControlKey) != 0) KeyModifier.control,
      if ((keyState & mkShiftKey) != 0) KeyModifier.shift,
      if ((keyState & mkAlt) != 0) KeyModifier.alt,
    };

/// The x of a `POINTL` that the ABI packed into one 64-bit register.
///
/// See [ComServerStatePointOutNative] for why it arrives packed. The halves are
/// signed: a desktop whose primary monitor is not top-left has real negative
/// screen coordinates, and reading them unsigned puts the drop four billion
/// pixels to the right.
int win32PointX(int packed) => _signed32(packed & 0xFFFFFFFF);

/// The y of a packed `POINTL`.
int win32PointY(int packed) => _signed32((packed >> 32) & 0xFFFFFFFF);

int _signed32(int value) => value >= 0x80000000 ? value - 0x100000000 : value;

// ---------------------------------------------------------------------------
// IDataObject, from the consuming side
// ---------------------------------------------------------------------------

/// The two `IDataObject` methods this backend calls.
///
/// A thin reader rather than a `ComObject`: the pointer is *borrowed* for the
/// length of one drag and its lifetime belongs to the OLE runtime, so wrapping
/// it in something that releases on dispose would be the wrong ownership
/// entirely. [Win32DropTarget] takes the one reference it needs by hand and
/// gives it back in `DragLeave`/`Drop`.
final class Win32DataObject {
  Win32DataObject(this.pointer, this._api, this._ole)
      : _getData = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Uint8>,
                    Pointer<Uint8>)>(pointer, _slotGetData)
            .asFunction(),
        _queryGetData =
            comMethod<Int32 Function(Pointer<Void>, Pointer<Uint8>)>(
                    pointer, _slotQueryGetData)
                .asFunction();

  /// `IDataObject::GetData` is slot 3, `QueryGetData` slot 5 - after the three
  /// `IUnknown` slots and `GetDataHere`.
  static const int _slotGetData = 3;
  static const int _slotQueryGetData = 5;

  final Pointer<Void> pointer;
  final Win32Api _api;
  final Win32OleApi _ole;

  final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>) _getData;
  final int Function(Pointer<Void>, Pointer<Uint8>) _queryGetData;

  /// Whether [format] can be delivered in global memory.
  bool has(int format) {
    final NativeAllocator? allocator = NativeAllocator.tryBind();
    if (allocator == null) return false;
    final Pointer<Uint8> etc =
        allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
    try {
      writeFormatEtc(etc, format);
      return _queryGetData(pointer, etc) == sOk;
    } finally {
      allocator.free(etc);
    }
  }

  /// The bytes of [format], already translated into the port's encoding, or
  /// null when the source could not produce it.
  Uint8List? read(int format) {
    final NativeAllocator? allocator = NativeAllocator.tryBind();
    final int Function(int)? lock = _api.globalLock;
    final int Function(int)? unlock = _api.globalUnlock;
    if (allocator == null || lock == null || unlock == null) return null;

    final Pointer<Uint8> etc =
        allocator.allocate<Uint8>(OleStructLayout.formatEtcSize);
    final Pointer<Uint8> medium =
        allocator.allocate<Uint8>(OleStructLayout.stgMediumSize);
    try {
      writeFormatEtc(etc, format);
      for (int i = 0; i < OleStructLayout.stgMediumSize; i++) {
        medium[i] = 0;
      }
      if (_getData(pointer, etc, medium) != sOk) return null;
      try {
        final int handle = readStgMediumGlobal(medium);
        if (handle == 0) return null;
        final int address = lock(handle);
        if (address == 0) return null;
        try {
          return _translate(format, address);
        } finally {
          unlock(handle);
        }
      } finally {
        // Always, on every path: the STGMEDIUM owns the HGLOBAL now, and
        // skipping this leaks the payload of every drag the user makes.
        _ole.releaseStgMedium(medium);
      }
    } finally {
      allocator
        ..free(etc)
        ..free(medium);
    }
  }

  Uint8List? _translate(int format, int address) {
    switch (format) {
      case cfUnicodeText:
        return MemoryDragData.text(win32ReadUnicodeTextAt(address))
            .bytesOf(DragFormats.text);
      case cfHDrop:
        final List<String> paths = win32ReadDropFilesAt(address);
        if (paths.isEmpty) return null;
        return MemoryDragData.filePaths(paths).bytesOf(DragFormats.uriList);
      default:
        return null;
    }
  }

  /// Everything this backend can offer out of this data object, read now.
  ///
  /// Called from inside `Drop`, which is the only moment the payload is
  /// guaranteed to be there *and* the last moment the handler could still be
  /// on the platform's stack. The result is plain memory, so the handler may
  /// hold it for as long as it likes.
  MemoryDragData materialise() {
    final Map<String, Uint8List> data = <String, Uint8List>{};
    for (final int format in win32DragFormats) {
      if (!has(format)) continue;
      final Uint8List? bytes = read(format);
      final String? mime = win32MimeForClipboardFormat(format);
      if (bytes != null && mime != null) data[mime] = bytes;
    }
    return MemoryDragData(data);
  }

  /// The formats present, as MIME names, without reading any of them.
  List<String> availableMimeTypes() => <String>[
        for (final int format in win32DragFormats)
          if (has(format))
            if (win32MimeForClipboardFormat(format) case final String mime)
              mime,
      ];
}

/// A [DragData] backed by a live `IDataObject`.
///
/// Its futures are always already complete - `GetData` is synchronous - but it
/// is still a [DragData], because the contract is the contract and a target
/// written against it must not be able to tell which backend it is on.
final class Win32LiveDragData implements DragData {
  Win32LiveDragData(this._object, this.formats);

  final Win32DataObject _object;

  @override
  final List<String> formats;

  final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  /// Set when the drag ends: the borrowed pointer is no longer ours to call,
  /// and a target that kept this object must get null rather than a call into
  /// a released COM object.
  bool _detached = false;

  void detach() => _detached = true;

  @override
  Future<Uint8List?> readBytes(String format) async {
    if (_cache.containsKey(format)) return _cache[format];
    if (_detached || !formats.contains(format)) return null;
    final int clipboardFormat = win32ClipboardFormatForMime(format);
    if (clipboardFormat == 0) return null;
    final Uint8List? bytes = _object.read(clipboardFormat);
    _cache[format] = bytes;
    return bytes;
  }
}

// ---------------------------------------------------------------------------
// IDropTarget
// ---------------------------------------------------------------------------

/// Turns a screen position in physical pixels into client-area logical units.
///
/// A function rather than a window reference so that the drop target can be
/// tested without an `HWND`, and so that this file never has to know how the
/// window keeps its origin up to date.
typedef Win32ScreenToClient = Offset Function(int screenX, int screenY);

/// The Dart object behind one window's `IDropTarget`.
///
/// Every method returns an `HRESULT` and none of them throws: a Dart exception
/// crossing back into the OLE drag loop is undefined behaviour, so
/// [ComServerClass] turns one into `E_FAIL` and a [ComServerFault]. What this
/// class adds on top is the *state* the four methods share - the borrowed data
/// object, the effect the last `DragOver` agreed to - because `Drop` has to
/// answer with a value it was told two calls ago.
final class Win32DropTarget {
  Win32DropTarget({
    required this.handler,
    required this.windowId,
    required this.screenToClient,
    required Win32Api api,
    required Win32OleApi ole,
  })  : _api = api,
        _ole = ole;

  final DropTargetHandler handler;
  final NativeWindowId windowId;
  final Win32ScreenToClient screenToClient;

  final Win32Api _api;
  final Win32OleApi _ole;

  Win32DataObject? _data;
  Win32LiveDragData? _live;
  DropResponse _response = const DropResponse.reject();

  /// The last effect written into `*pdwEffect`, which is what `Drop` must
  /// repeat. Readable for the test that proves the negotiation happened.
  int get negotiatedEffect => win32EffectForAction(_response.action);

  /// Whether a drag is currently over this window.
  bool get isDragging => _data != null;

  /// Drops that have completed, with the action the handler reported. Bounded,
  /// and only for diagnostics: `Drop` cannot wait for it.
  final List<DragAction> completedDrops = <DragAction>[];

  /// `IDropTarget::DragEnter`.
  int dragEnter(
    Pointer<Void> dataObject,
    int keyState,
    int packedPoint,
    Pointer<Uint32> effect,
  ) {
    if (effect == nullptr) return ePointer;
    final int allowed = effect.value;
    _releaseData();
    if (dataObject == nullptr) {
      effect.value = dropEffectNone;
      return eInvalidArg;
    }
    // The runtime's pointer is borrowed for the drag; one reference of our own
    // means a source that releases early cannot pull it out from under a
    // handler that is still reading.
    _addRef(dataObject);
    final Win32DataObject data = Win32DataObject(dataObject, _api, _ole);
    _data = data;
    final Win32LiveDragData live =
        Win32LiveDragData(data, data.availableMimeTypes());
    _live = live;
    _response = handler.onDragEnter(
      _event(live, keyState, packedPoint, allowed),
    );
    effect.value = _effectFor(_response, allowed);
    return sOk;
  }

  /// `IDropTarget::DragOver`.
  int dragOver(int keyState, int packedPoint, Pointer<Uint32> effect) {
    if (effect == nullptr) return ePointer;
    final int allowed = effect.value;
    final Win32LiveDragData? live = _live;
    if (live == null) {
      // A DragOver with no DragEnter is a protocol violation on the other
      // side; answering "nothing" is better than inventing a session.
      effect.value = dropEffectNone;
      return sOk;
    }
    _response =
        handler.onDragOver(_event(live, keyState, packedPoint, allowed));
    effect.value = _effectFor(_response, allowed);
    return sOk;
  }

  /// `IDropTarget::DragLeave`.
  int dragLeave() {
    if (_data == null) return sOk;
    handler.onDragLeave();
    _releaseData();
    _response = const DropResponse.reject();
    return sOk;
  }

  /// `IDropTarget::Drop`.
  ///
  /// Reads the payload here and now - see the library comment - and reports the
  /// action the last `DragOver` settled on, because `*pdwEffect` cannot wait
  /// for the handler's future.
  int drop(
    Pointer<Void> dataObject,
    int keyState,
    int packedPoint,
    Pointer<Uint32> effect,
  ) {
    if (effect == nullptr) return ePointer;
    final int allowed = effect.value;
    final DropResponse response = _response;
    if (!response.isAccepted || _data == null) {
      effect.value = dropEffectNone;
      _finishDrop();
      return sOk;
    }
    final Win32DataObject source = dataObject == nullptr
        ? _data!
        : Win32DataObject(dataObject, _api, _ole);
    final MemoryDragData payload = source.materialise();
    final int performed = _effectFor(response, allowed);
    effect.value = performed;

    final Future<DragAction> result = handler.onDrop(
      _event(payload, keyState, packedPoint, allowed),
    );
    // Recorded rather than awaited: the source has already been told what
    // happened, and blocking here would park the OLE drag loop. A failure
    // after the fact is a diagnostic, not a renegotiation.
    result.then(
      completedDrops.add,
      onError: (Object _) => completedDrops.add(DragAction.none),
    );
    _finishDrop();
    return sOk;
  }

  /// Gives back the borrowed data object, whatever ended the drag.
  void _finishDrop() {
    _releaseData();
    _response = const DropResponse.reject();
  }

  DragSessionEvent _event(
    DragData data,
    int keyState,
    int packedPoint,
    int allowedEffect,
  ) {
    final int screenX = win32PointX(packedPoint);
    final int screenY = win32PointY(packedPoint);
    final Set<DragAction> allowed = win32ActionsFromEffect(allowedEffect);
    final Set<KeyModifier> modifiers = win32ModifiersFromKeyState(keyState);
    return DragSessionEvent(
      windowId: windowId,
      position: screenToClient(screenX, screenY),
      screenPosition: Offset(screenX.toDouble(), screenY.toDouble()),
      data: data,
      allowedActions: allowed,
      suggestedAction: resolveDragAction(
        allowed,
        preferred: dragActionForModifiers(modifiers) ?? DragAction.copy,
      ),
      modifiers: modifiers,
    );
  }

  /// The effect bits for [response], never wider than what the source allows.
  ///
  /// Masking is not a formality. `DoDragDrop` documents that the value written
  /// back must be one of the effects that was offered, and a target that
  /// answers `DROPEFFECT_MOVE` to a copy-only source gets a move it cannot
  /// perform - which on a file drag means the source deletes an original
  /// nobody took.
  int _effectFor(DropResponse response, int allowedEffect) {
    if (!response.isAccepted) return dropEffectNone;
    final int wanted = win32EffectForAction(response.action);
    final int allowed = allowedEffect & ~dropEffectScroll;
    return (wanted & allowed) == 0 ? dropEffectNone : wanted;
  }

  void _releaseData() {
    _live?.detach();
    _live = null;
    final Win32DataObject? data = _data;
    _data = null;
    if (data != null) _release(data.pointer);
  }

  void _addRef(Pointer<Void> object) =>
      comMethod<Uint32 Function(Pointer<Void>)>(object, comSlotAddRef)
          .asFunction<int Function(Pointer<Void>)>()(object);

  void _release(Pointer<Void> object) =>
      comMethod<Uint32 Function(Pointer<Void>)>(object, comSlotRelease)
          .asFunction<int Function(Pointer<Void>)>()(object);
}

/// The `IDropTarget` interface description, in vtable order.
///
/// Built once per backend and shared by every window, exactly as
/// `uia_provider.dart` shares its node class.
ComInterfaceSpec<Win32DropTarget> win32DropTargetSpec() =>
    ComInterfaceSpec<Win32DropTarget>(
      name: 'IDropTarget',
      iid: iidIDropTarget,
      methods: <ComMethod<Win32DropTarget>>[
        ComObjectStatePointOutMethod<Win32DropTarget>(
          'DragEnter',
          (Win32DropTarget target, Pointer<Void> data, int state, int point,
                  Pointer<Uint32> effect) =>
              target.dragEnter(data, state, point, effect),
        ),
        ComStatePointOutMethod<Win32DropTarget>(
          'DragOver',
          (Win32DropTarget target, int state, int point,
                  Pointer<Uint32> effect) =>
              target.dragOver(state, point, effect),
        ),
        ComSelfMethod<Win32DropTarget>(
          'DragLeave',
          (Win32DropTarget target) => target.dragLeave(),
        ),
        ComObjectStatePointOutMethod<Win32DropTarget>(
          'Drop',
          (Win32DropTarget target, Pointer<Void> data, int state, int point,
                  Pointer<Uint32> effect) =>
              target.drop(data, state, point, effect),
        ),
      ],
    );

// ---------------------------------------------------------------------------
// The backend
// ---------------------------------------------------------------------------

/// The Win32 implementation of [DragDropBackend].
///
/// One per windowing backend. It owns the `IDropTarget` class (one set of
/// vtables for every window), the OLE apartment reference, and the live
/// registrations.
final class Win32DragDropBackend implements DragDropBackend {
  Win32DragDropBackend({required Win32Api api, required Win32OleApi ole})
      : _api = api,
        _ole = ole,
        _apartment = Win32OleApartment(ole);

  /// Loads ole32 and builds a backend, or explains what stopped it.
  ///
  /// Never throws and never returns null: a machine without the drag-and-drop
  /// entry points gets an [UnavailableDragDrop] naming them, which fails at the
  /// registration a caller can see rather than at some later drop that simply
  /// never arrives.
  static ({DragDropBackend backend, List<BackendDiagnostic> diagnostics})
      create(Win32Api api) {
    final Win32OleLoadResult result = Win32OleApi.load();
    final Win32OleApi? ole = result.api;
    if (ole == null) {
      return (
        backend: const UnavailableDragDrop(
          name: 'win32',
          reason: 'ole32.dll or its drag-and-drop entry points could not be '
              'bound, so RegisterDragDrop is unavailable in this process',
        ),
        diagnostics: result.diagnostics,
      );
    }
    return (
      backend: Win32DragDropBackend(api: api, ole: ole),
      diagnostics: result.diagnostics,
    );
  }

  final Win32Api _api;
  final Win32OleApi _ole;
  final Win32OleApartment _apartment;

  ComServerClass<Win32DropTarget>? _class;
  final List<Win32DropTargetRegistration> _registrations =
      <Win32DropTargetRegistration>[];

  @override
  String get name => 'win32';

  /// Whether a drag can really be started from here.
  ///
  /// This class only exists when ole32 and its drag-and-drop entry points bound
  /// - [create] hands back an [UnavailableDragDrop] otherwise - so the ole32
  /// half of the question is already answered by being here. What is left is
  /// the *payload* half: `IDataObject::GetData` has to hand over an `HGLOBAL`,
  /// and a kernel32 without `GlobalAlloc`/`GlobalLock` (which is also what
  /// stops the clipboard working) could offer formats it can never deliver.
  /// Saying no here is a named refusal; saying yes and then failing inside a
  /// modal loop is not.
  @override
  bool get canStartDrag =>
      _api.globalAlloc != null &&
      _api.globalLock != null &&
      _api.globalUnlock != null;

  /// Every live registration, for a teardown that has to name what was open.
  List<DropTargetRegistration> get registrations =>
      List<DropTargetRegistration>.unmodifiable(_registrations);

  @override
  Future<DropTargetRegistration> registerDropTarget({
    required NativeWindow window,
    required DropTargetHandler handler,
  }) async {
    if (window is! Win32Window) {
      throw DragDropException(
        operation: 'registerDropTarget',
        reason: 'the win32 drag-and-drop backend was handed a '
            '${window.runtimeType}, which has no HWND',
        backend: name,
      );
    }
    final int hwnd = window.handle;
    if (hwnd == 0) {
      throw const DragDropException(
        operation: 'registerDropTarget',
        reason: 'the window has no HWND yet; register after it is created and '
            'before it is destroyed',
        backend: 'win32',
      );
    }
    if (!_apartment.enter()) {
      throw DragDropException(
        operation: 'OleInitialize',
        reason: _apartment.lastResult == rpcErrorChangedMode
            ? 'this thread is in the multi-threaded apartment and OLE drag and '
                'drop needs a single-threaded one; whatever put it there would '
                'break if it were re-initialised, so this is a refusal'
            : 'OLE could not be initialised on this thread',
        backend: name,
        errorCode: _apartment.lastResult,
      );
    }

    final ComServerClass<Win32DropTarget> serverClass =
        _class ??= ComServerClass<Win32DropTarget>(
      'Win32DropTarget',
      <ComInterfaceSpec<Win32DropTarget>>[win32DropTargetSpec()],
    );
    final Win32DropTarget target = Win32DropTarget(
      handler: handler,
      windowId: window.id,
      screenToClient: (int x, int y) {
        // Physical screen pixels to logical client units, through the window's
        // own scale - which is the only correct one on a mixed-DPI desktop,
        // and which `screenToClient` refreshes the origin for.
        final double scale = window.renderScale;
        return window.screenToClient(Offset(x / scale, y / scale));
      },
      api: _api,
      ole: _ole,
    );
    final ComServerObject<Win32DropTarget> object =
        serverClass.instantiate(target);
    final int hresult = _ole.registerDragDrop(hwnd, object.pointer);
    if (failed(hresult)) {
      object.dispose();
      _apartment.leave();
      throw DragDropException(
        operation: 'RegisterDragDrop',
        reason: hresult == dragDropErrorAlreadyRegistered
            ? 'this window already has a drop target; revoke the previous '
                'registration first'
            : 'the OLE runtime refused the registration',
        backend: name,
        errorCode: hresult,
      );
    }
    final Win32DropTargetRegistration registration =
        Win32DropTargetRegistration._(this, window.id, hwnd, object, target);
    _registrations.add(registration);
    return registration;
  }

  /// Drags [request]`.data` out of this application.
  ///
  /// ## `DoDragDrop` parks the whole isolate, and that is the platform
  ///
  /// The call below **does not return until the user has released the button**.
  /// It runs its own modal message loop, captures the mouse, and calls back
  /// into `IDropSource` and (from the other side) `IDataObject` while it does.
  /// For the whole of that time the Dart isolate is inside one native frame:
  /// no microtask runs, no timer fires, no frame is painted, and anything this
  /// application scheduled waits. It is the same trap `LiveResizeWindow`
  /// documents for the modal resize loop and the port documents on
  /// [DragDropBackend.startDrag] - repeated here because this is where it
  /// actually happens.
  ///
  /// The consequence for callers is concrete: a drag must be started from
  /// inside a pointer gesture and the application must be prepared to be
  /// frozen until it ends. There is no non-modal `DoDragDrop`.
  ///
  /// ## What is resolved before the loop, and why all of it
  ///
  /// Every format is materialised into bytes first. `IDataObject::GetData` is
  /// synchronous, is called from inside that loop, and the port's `readBytes`
  /// is a `Future` - so a lazy payload asked for at `GetData` time could never
  /// be awaited. See [win32MaterialiseDragPayload].
  ///
  /// ## `request.feedback` is ignored
  ///
  /// Deliberately, and not silently: honouring a drag image on Windows means
  /// `IDragSourceHelper`/`IDragSourceHelper2` - a shell object that has to be
  /// cocreated, handed an `SHDRAGIMAGE` with an HBITMAP this framework would
  /// have to build from the premultiplied BGRA, and then attached to the very
  /// `IDataObject` above, which additionally has to start answering `SetData`
  /// for the private shell formats the helper stores in it. That is a second
  /// COM dance of its own and it is not here. Windows draws its standard
  /// cursors instead, which is what `GiveFeedback` asks for.
  @override
  Future<DragAction> startDrag(DragRequest request) async {
    if (request.window is! Win32Window) {
      throw DragDropException(
        operation: 'startDrag',
        reason: 'the win32 drag-and-drop backend was handed a '
            '${request.window.runtimeType}, which is not one of its windows',
        backend: name,
      );
    }
    if (!canStartDrag) {
      throw DragDropException(
        operation: 'startDrag',
        reason: 'kernel32 did not provide GlobalAlloc/GlobalLock, so an '
            'IDataObject here could name formats it can never hand over',
        backend: name,
      );
    }

    final int effects = win32EffectMask(request.allowedActions);
    if (effects == dropEffectNone) {
      throw DragDropException(
        operation: 'startDrag',
        reason: 'allowedActions names nothing DROPEFFECT can express '
            '(${request.allowedActions}); DragAction.ask has no Win32 '
            'spelling and a drag that allows nothing is a refusal',
        backend: name,
      );
    }

    // Before the apartment and before the loop: the last point at which
    // awaiting anything is possible.
    final Map<int, Uint8List> payload =
        await win32MaterialiseDragPayload(request.data);
    if (payload.isEmpty) {
      throw DragDropException(
        operation: 'startDrag',
        reason: 'none of the offered formats (${request.data.formats}) has a '
            'Windows clipboard spelling this backend can produce; it knows '
            'text/plain and text/uri-list',
        backend: name,
      );
    }

    final NativeAllocator? allocator = NativeAllocator.tryBind();
    if (allocator == null) {
      throw DragDropException(
        operation: 'startDrag',
        reason: 'no native allocator is available in this process',
        backend: name,
      );
    }
    if (!_apartment.enter()) {
      throw DragDropException(
        operation: 'OleInitialize',
        reason: _apartment.lastResult == rpcErrorChangedMode
            ? 'this thread is in the multi-threaded apartment and OLE drag and '
                'drop needs a single-threaded one; whatever put it there would '
                'break if it were re-initialised, so this is a refusal'
            : 'OLE could not be initialised on this thread',
        backend: name,
        errorCode: _apartment.lastResult,
      );
    }

    final Pointer<Uint32> effect = allocator.allocate<Uint32>(4);
    final Win32DragSourceObjects objects = Win32DragSourceObjects(
      payload: payload,
      api: _api,
      // Left button, because that is what a `DragRequest` describes: the port
      // has no field for which button began the gesture, and every drag the
      // widget layer starts is a left-button one. A right-drag would pass
      // `mkRButton` here and is the reason `Win32DropSource` takes it at all.
      initiatingButton: mkLButton,
    );
    try {
      effect.value = dropEffectNone;
      final int result = hresult(
        _ole.doDragDrop(
          objects.dataObjectPointer,
          objects.dropSourcePointer,
          effects,
          effect,
        ),
      );

      if (result == dragDropStatusCancel) {
        // A cancel is not an error: the user pressed Escape or dropped on
        // nothing, which the port spells DragAction.none.
        return DragAction.none;
      }
      if (result == dragDropStatusDrop) {
        final Set<DragAction> performed = win32ActionsFromEffect(effect.value);
        if (performed.isEmpty) return DragAction.none;
        // `*pdwEffect` is one bit in practice, but a target is not forbidden
        // from leaving several set; resolving preferring the requested action
        // is the same rule every other backend applies.
        return resolveDragAction(performed, preferred: request.preferredAction);
      }
      if (failed(result)) {
        throw DragDropException(
          operation: 'DoDragDrop',
          reason: 'the OLE drag loop failed to run',
          backend: name,
          errorCode: result,
        );
      }
      // A success code that is neither DROP nor CANCEL is not documented to
      // happen; reporting "nothing was performed" is the safe reading, because
      // the alternative claims a transfer that may not have occurred.
      return DragAction.none;
    } finally {
      objects.dispose();
      allocator.free(effect);
      _apartment.leave();
    }
  }

  void _forget(Win32DropTargetRegistration registration) {
    _registrations.remove(registration);
    _apartment.leave();
  }

  /// Revokes everything still registered and releases the vtables.
  ///
  /// Called from the backend's shutdown, **before the windows are destroyed**:
  /// `RevokeDragDrop` on a dead `HWND` answers `DRAGDROP_E_NOTREGISTERED` and
  /// leaves the OLE runtime holding a pointer into this process.
  Future<void> dispose() async {
    for (final Win32DropTargetRegistration registration
        in List<Win32DropTargetRegistration>.of(_registrations)) {
      await registration.revoke();
    }
    _class?.dispose();
    _class = null;
  }
}

/// One window's live `IDropTarget`.
final class Win32DropTargetRegistration implements DropTargetRegistration {
  Win32DropTargetRegistration._(
    this._backend,
    this.windowId,
    this.hwnd,
    this._object,
    this.target,
  );

  final Win32DragDropBackend _backend;

  @override
  final NativeWindowId windowId;

  /// The window this target is attached to.
  final int hwnd;

  final ComServerObject<Win32DropTarget> _object;

  /// The Dart object OLE calls into, so a test can drive it directly.
  final Win32DropTarget target;

  bool _active = true;

  @override
  bool get isActive => _active;

  /// The COM identity OLE was handed, for the test that proves the pointer is
  /// a real vtable.
  Pointer<Void> get pointer => _object.pointer;

  @override
  Future<void> revoke() async {
    if (!_active) return;
    _active = false;
    _backend._ole.revokeDragDrop(hwnd);
    // Whatever the runtime answered, our reference goes: a failed revoke on a
    // window that is already gone must not leak the object as well.
    _object.dispose();
    _backend._forget(this);
  }
}
