/// `ole32.dll`, the drag-and-drop half, plus the two structures OLE passes data
/// in.
///
/// Kept out of `win32_api.dart` deliberately. That file opens kernel32, user32
/// and gdi32 - the three libraries the *window* needs - and a backend that
/// could not open them cannot run at all. ole32 is not in that class: a process
/// with no OLE has a perfectly good window and merely no drag and drop, and the
/// probe has to be able to say exactly that. So this is a separate loader in
/// the shape `UiaCore` already uses, with its own cached result and its own
/// diagnostics.
///
/// ## `OleInitialize`, not `CoInitializeEx`
///
/// `RegisterDragDrop` fails with `CO_E_NOTINITIALIZED` unless OLE - not merely
/// COM - has been initialised on the calling thread. `OleInitialize` does what
/// `CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)` does *and* starts the
/// OLE subsystems (the clipboard, the drag-drop registry, the object table),
/// which is why the two are not interchangeable here even though the
/// accessibility bridge in this directory only needs the latter.
///
/// Both are reference counted per thread and both are happy to be called after
/// the other, with one exception this file has to handle rather than assert
/// away: a thread already initialised as *multi-threaded* answers
/// `RPC_E_CHANGED_MODE` and stays multi-threaded. Drag and drop needs an STA,
/// so that answer is a refusal, not a success - and it is recorded as one
/// instead of being retried in another mode, which would break whatever put the
/// thread into the MTA in the first place.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/com.dart';
import '../../foundation/diagnostics.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// `DROPEFFECT_*`, the bitmask an `IDropTarget` writes into `*pdwEffect`.
const int dropEffectNone = 0;
const int dropEffectCopy = 1;
const int dropEffectMove = 2;
const int dropEffectLink = 4;

/// `DROPEFFECT_SCROLL`. Never requested here, but it arrives *set* in the
/// effect the source offers when it wants auto-scrolling, so it has to be
/// masked off before the remaining bits are interpreted - otherwise a
/// copy-only source reads as offering an unknown effect.
const int dropEffectScroll = 0x80000000;

/// `MK_*`, the key state passed to every `IDropTarget` method.
const int mkLButton = 0x0001;
const int mkRButton = 0x0002;
const int mkShiftKey = 0x0004;
const int mkControlKey = 0x0008;
const int mkMButton = 0x0010;
const int mkAlt = 0x0020;

/// `TYMED_HGLOBAL`. The only medium this backend asks for: every format it
/// understands - text and a file list - is delivered in global memory, and
/// asking for `TYMED_ISTREAM` as well would mean a second delivery path for
/// data that arrives identically.
const int tymedHGlobal = 1;

/// `DVASPECT_CONTENT`.
const int dvAspectContent = 1;

/// `DATADIR_GET` / `DATADIR_SET`, the direction `IDataObject::EnumFormatEtc`
/// is asked about.
///
/// The two are not symmetric and a source must not pretend they are: `GET` asks
/// what this object can *hand over*, `SET` asks what it would *accept* through
/// `SetData`. A drag source accepts nothing, so it enumerates for `GET` and
/// refuses `SET` rather than returning the same list twice - which would
/// advertise a `SetData` that answers `E_NOTIMPL`.
const int dataDirGet = 1;
const int dataDirSet = 2;

/// `DV_E_FORMATETC`: the object has no such format. The documented answer from
/// `QueryGetData` and `GetData`, and *not* `S_FALSE` - a caller that switches
/// on the HRESULT treats `S_FALSE` as a success with nothing in the medium.
const int dvErrorFormatEtc = -2147221404; // 0x80040064

/// `DV_E_TYMED`: the format exists but not in a medium the caller asked for.
/// Distinct from [dvErrorFormatEtc] because it tells a caller to ask again with
/// a wider `tymed` rather than to give up on the format.
const int dvErrorTymed = -2147221399; // 0x80040069

/// `DATA_S_SAMEFORMATETC`, the answer `GetCanonicalFormatEtc` gives when the
/// format it was handed is already canonical - which it always is for an object
/// with no target device.
const int dataStatusSameFormatEtc = 262448; // 0x00040130

/// `OLE_E_ADVISENOTSUPPORTED`. What `DAdvise`/`DUnadvise`/`EnumDAdvise` answer
/// on a data object that does not do change notifications, which is every drag
/// source: the payload is a snapshot taken before the modal loop started and
/// cannot change while it runs.
const int oleErrorAdviseNotSupported = -2147221501; // 0x80040003

/// Clipboard formats. `CF_HDROP` is what Explorer drags files as, and it is
/// the *only* thing Explorer offers that names files.
const int cfText = 1;
const int cfHDrop = 15;

/// `DRAGDROP_E_ALREADYREGISTERED` - this HWND already has a drop target.
const int dragDropErrorAlreadyRegistered = -2147221247; // 0x80040101
/// `DRAGDROP_E_NOTREGISTERED`.
const int dragDropErrorNotRegistered = -2147221248; // 0x80040100
/// `DRAGDROP_S_DROP`, returned by `IDropSource::QueryContinueDrag` to drop.
const int dragDropStatusDrop = 262400; // 0x00040100
/// `DRAGDROP_S_CANCEL`.
const int dragDropStatusCancel = 262401; // 0x00040101
/// `DRAGDROP_S_USEDEFAULTCURSORS`, the answer `GiveFeedback` gives when it
/// wants the OLE cursors rather than one of its own.
const int dragDropStatusUseDefaultCursors = 262402; // 0x00040102

/// `RPC_E_CHANGED_MODE`: the thread is already in the multi-threaded
/// apartment. Spelled here as well as in `uia_bridge.dart` because the two
/// loaders are deliberately independent.
const int rpcErrorChangedMode = -2147417850; // 0x80010106

/// `CO_E_NOTINITIALIZED`.
const int coErrorNotInitialized = -2147221008; // 0x800401F0

final Guid iidIDropTarget = Guid.parse('00000122-0000-0000-C000-000000000046');
final Guid iidIDropSource = Guid.parse('00000121-0000-0000-C000-000000000046');
final Guid iidIDataObject = Guid.parse('0000010E-0000-0000-C000-000000000046');
final Guid iidIEnumFormatEtc =
    Guid.parse('00000103-0000-0000-C000-000000000046');

// ---------------------------------------------------------------------------
// Structure layouts
// ---------------------------------------------------------------------------

/// The offsets of `FORMATETC` and `STGMEDIUM`, derived rather than hardcoded.
///
/// Both structures contain pointers, so both change size between 32-bit and
/// 64-bit Windows, and both have a field whose offset moves with the pointer
/// alignment. Writing `32` for the size of a `FORMATETC` would be right on x64
/// and wrong by twelve bytes on x86 - and the failure mode is not a crash but
/// `GetData` reading `tymed` out of `lindex`, which reports "the medium is not
/// supported" for data that was there all along.
abstract final class OleStructLayout {
  static final int _pointerSize = sizeOf<IntPtr>();

  /// `FORMATETC { CLIPFORMAT cfFormat; DVTARGETDEVICE* ptd; DWORD dwAspect;
  /// LONG lindex; DWORD tymed; }`
  static int get formatEtcSize =>
      _align(_pointerSize * 2 + 12, _pointerSize);
  static int get formatEtcFormat => 0;
  static int get formatEtcTargetDevice => _pointerSize;
  static int get formatEtcAspect => _pointerSize * 2;
  static int get formatEtcIndex => _pointerSize * 2 + 4;
  static int get formatEtcTymed => _pointerSize * 2 + 8;

  /// `STGMEDIUM { DWORD tymed; union { HGLOBAL hGlobal; ... }; IUnknown*
  /// pUnkForRelease; }`
  static int get stgMediumSize => _pointerSize * 3;
  static int get stgMediumTymed => 0;
  static int get stgMediumHandle => _pointerSize;
  static int get stgMediumRelease => _pointerSize * 2;

  /// `DROPFILES { DWORD pFiles; POINT pt; BOOL fNC; BOOL fWide; }` - twenty
  /// bytes on every architecture, because every field is four bytes.
  static const int dropFilesSize = 20;
  static const int dropFilesOffset = 0;
  static const int dropFilesWide = 16;

  static int _align(int value, int alignment) =>
      (value + alignment - 1) & ~(alignment - 1);
}

/// Fills a `FORMATETC` at [target] for [format] in global memory.
void writeFormatEtc(Pointer<Uint8> target, int format) {
  final ByteData view = ByteData.sublistView(
    target.asTypedList(OleStructLayout.formatEtcSize),
  );
  for (int i = 0; i < OleStructLayout.formatEtcSize; i++) {
    target[i] = 0;
  }
  view.setUint16(OleStructLayout.formatEtcFormat, format, Endian.little);
  view.setUint32(OleStructLayout.formatEtcAspect, dvAspectContent,
      Endian.little);
  // -1 means "the whole thing"; 0 would ask for page zero of a paginated
  // object, which text is not and a file list certainly is not.
  view.setInt32(OleStructLayout.formatEtcIndex, -1, Endian.little);
  view.setUint32(OleStructLayout.formatEtcTymed, tymedHGlobal, Endian.little);
}

/// The clipboard format a `FORMATETC` names.
int readFormatEtcFormat(Pointer<Uint8> source) => ByteData.sublistView(
      source.asTypedList(OleStructLayout.formatEtcSize),
    ).getUint16(OleStructLayout.formatEtcFormat, Endian.little);

/// The `tymed` bitmask a `FORMATETC` asks for.
int readFormatEtcTymed(Pointer<Uint8> source) => ByteData.sublistView(
      source.asTypedList(OleStructLayout.formatEtcSize),
    ).getUint32(OleStructLayout.formatEtcTymed, Endian.little);

/// The `hGlobal` out of a filled `STGMEDIUM`, or 0 when the medium is not
/// global memory - which is not a failure, only a medium this backend did not
/// ask for and will not touch.
int readStgMediumGlobal(Pointer<Uint8> medium) {
  final ByteData view = ByteData.sublistView(
    medium.asTypedList(OleStructLayout.stgMediumSize),
  );
  if (view.getUint32(OleStructLayout.stgMediumTymed, Endian.little) !=
      tymedHGlobal) {
    return 0;
  }
  return _readPointerField(view, OleStructLayout.stgMediumHandle);
}

/// Writes an `hGlobal` medium whose ownership passes to the caller.
///
/// `pUnkForRelease` is left null, which is COM's way of saying "call
/// `ReleaseStgMedium` and it will `GlobalFree` this for you". Setting it to
/// something would make the receiver call back into us to release, which is a
/// promise this backend cannot keep once the drag has ended.
void writeStgMediumGlobal(Pointer<Uint8> medium, int handle) {
  final ByteData view = ByteData.sublistView(
    medium.asTypedList(OleStructLayout.stgMediumSize),
  );
  view.setUint32(OleStructLayout.stgMediumTymed, tymedHGlobal, Endian.little);
  _writePointerField(view, OleStructLayout.stgMediumHandle, handle);
  _writePointerField(view, OleStructLayout.stgMediumRelease, 0);
}

int _readPointerField(ByteData view, int offset) =>
    sizeOf<IntPtr>() == 8
        ? view.getUint64(offset, Endian.little)
        : view.getUint32(offset, Endian.little);

void _writePointerField(ByteData view, int offset, int value) {
  if (sizeOf<IntPtr>() == 8) {
    view.setUint64(offset, value, Endian.little);
  } else {
    view.setUint32(offset, value & 0xFFFFFFFF, Endian.little);
  }
}

// ---------------------------------------------------------------------------
// The library
// ---------------------------------------------------------------------------

/// What [Win32OleApi.load] found, whether or not it succeeded.
final class Win32OleLoadResult {
  const Win32OleLoadResult({required this.api, required this.diagnostics});

  /// Null when ole32 or one of its drag-and-drop symbols was missing.
  final Win32OleApi? api;

  final List<BackendDiagnostic> diagnostics;
}

/// The ole32 entry points drag and drop needs.
final class Win32OleApi {
  Win32OleApi._(this._ole32) {
    oleInitialize = _ole32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('OleInitialize');
    oleUninitialize = _ole32
        .lookupFunction<Void Function(), void Function()>('OleUninitialize');
    registerDragDrop = _ole32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>),
        int Function(int, Pointer<Void>)>('RegisterDragDrop');
    revokeDragDrop = _ole32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'RevokeDragDrop');
    releaseStgMedium = _ole32.lookupFunction<Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)>('ReleaseStgMedium');
    doDragDrop = _ole32.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(
            Pointer<Void>, Pointer<Void>, int, Pointer<Uint32>)>('DoDragDrop');
  }

  final DynamicLibrary _ole32;

  late final int Function(Pointer<Void>) oleInitialize;
  late final void Function() oleUninitialize;
  late final int Function(int, Pointer<Void>) registerDragDrop;
  late final int Function(int) revokeDragDrop;
  late final void Function(Pointer<Uint8>) releaseStgMedium;
  late final int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Uint32>)
      doDragDrop;

  static Win32OleLoadResult? _cached;

  /// Loads and binds, or explains what stopped it. Cached like
  /// [Win32Api.load], and for the same reason: a selection policy probes every
  /// backend and reopening the DLL per probe is wasted work.
  static Win32OleLoadResult load() {
    final Win32OleLoadResult? cached = _cached;
    if (cached != null) return cached;

    DynamicLibrary ole32;
    try {
      ole32 = DynamicLibrary.open('ole32.dll');
    } on Object catch (error) {
      return _cached = Win32OleLoadResult(
        api: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary('ole32.dll', detail: '$error'),
        ],
      );
    }
    try {
      return _cached = Win32OleLoadResult(
        api: Win32OleApi._(ole32),
        diagnostics: const <BackendDiagnostic>[],
      );
    } on ArgumentError catch (error) {
      return _cached = Win32OleLoadResult(
        api: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingSymbol(
            'ole32.dll drag-and-drop entry point',
            detail: '${error.message}',
          ),
        ],
      );
    }
  }

  /// Forgets the cached load, so a test can exercise the failure paths.
  static void debugResetCache() => _cached = null;
}

/// `OleInitialize` refcounted for this thread, so that two features on one
/// thread do not uninitialise each other.
///
/// The accessibility bridge calls `CoInitializeEx` and drag and drop calls
/// `OleInitialize`; both are per-thread and both are counted by the OS, so the
/// only thing that must not happen is *this* file calling `OleUninitialize`
/// more often than it called `OleInitialize`. Hence the counter, rather than a
/// bool that a second window would flip back.
final class Win32OleApartment {
  Win32OleApartment(this._api);

  final Win32OleApi _api;

  int _entries = 0;
  int _lastResult = sOk;

  /// The `HRESULT` of the last `OleInitialize`. `S_FALSE` means OLE was
  /// already up on this thread, which is a success.
  int get lastResult => _lastResult;

  bool get isInitialised => _entries > 0;

  /// Enters the apartment, returning false when the thread cannot host OLE.
  ///
  /// The one failure that is really a refusal is [rpcErrorChangedMode]: the
  /// thread is in the multi-threaded apartment, drag and drop needs a
  /// single-threaded one, and re-initialising it the other way would break
  /// whoever put it there. See the library comment.
  bool enter() {
    if (_entries > 0) {
      _entries++;
      return true;
    }
    _lastResult = _api.oleInitialize(nullptr);
    if (failed(_lastResult)) return false;
    _entries = 1;
    return true;
  }

  /// Leaves the apartment once for each [enter] that succeeded.
  void leave() {
    if (_entries == 0) return;
    _entries--;
    if (_entries == 0) _api.oleUninitialize();
  }
}
