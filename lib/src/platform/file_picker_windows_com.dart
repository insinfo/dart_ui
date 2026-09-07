/// The modern Windows file dialog: `IFileOpenDialog` and `IFileSaveDialog`.
///
/// `GetOpenFileNameW` still works and still opens *a* dialog, but it opens the
/// Windows 2000 one: no navigation pane, no pinned places, no OneDrive, no
/// search box, and a filter string built out of embedded NULs. Everything a
/// user has pinned in Explorer since Vista is invisible to it. The Common Item
/// Dialog replaced it in Vista and is what every shipping application opens
/// today, which is why this file exists.
///
/// ## Why this lives in `platform/` and not in `backends/win32/`
///
/// `test/architecture/layering_test.dart` forbids any core file from importing
/// a backend, and `file_picker_platform_io.dart` is a core file. Putting the
/// COM plumbing under `backends/win32/` would therefore make the picker
/// unreachable from the very file that needs it. The `platform` layer is
/// allowed to import `ffi`, which is where the COM abstraction this file is
/// built on already lives - `Guid`, `comMethod`, `ComObject` and the HRESULT
/// helpers in `lib/src/ffi/com.dart`, plus `NativeArena`. None of that is
/// re-implemented here; this file is a list of vtable slot numbers and the
/// call order the Common Item Dialog documents.
///
/// ## Nothing here throws for a refusal
///
/// Two outcomes are not failures and must not surface as exceptions:
/// [WindowsFileDialogStatus.cancelled], which is the user pressing Escape, and
/// [WindowsFileDialogStatus.unavailable], which is a machine or a session where
/// the dialog could not be created at all. The second one is the fallback
/// signal: `file_picker_platform_io.dart` answers it by running the legacy
/// `GetOpenFileNameW` path, which is kept for exactly this reason.
library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/com.dart';
import '../ffi/native_memory.dart';
import 'file_picker_types.dart';

// ---------------------------------------------------------------------------
// Class and interface identifiers
// ---------------------------------------------------------------------------

/// `CLSID_FileOpenDialog`.
final Guid clsidFileOpenDialog =
    Guid.parse('DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7');

/// `CLSID_FileSaveDialog`.
final Guid clsidFileSaveDialog =
    Guid.parse('C0B4E2F3-BA21-4773-8DBA-335EC946EB8B');

/// `IID_IFileDialog` - the interface whose vtable slots both dialogs share.
///
/// **Do not `QueryInterface` for it.** The shell's own dialog objects answer
/// `E_NOINTERFACE`: measured on Windows 11 build 26200, `CFileOpenBrowser`
/// answers `IUnknown`, `IModalWindow`, `IFileOpenDialog` and `IFileDialog2`,
/// and refuses this one - the intermediate base is simply not in its QI table.
/// The *vtable* inheritance is real and is what every slot number below 27
/// relies on; only the QI is missing. Treating a refusal here as "this is not a
/// file dialog" would send every open through the legacy fallback on a machine
/// where the modern dialog works perfectly.
final Guid iidIFileDialog = Guid.parse('42F85136-DB7E-439C-85F1-E4075D135FC5');

/// `IID_IModalWindow`, the base that *is* in the QI table and is therefore the
/// cheap proof that the pointer really is a shell dialog.
final Guid iidIModalWindow = Guid.parse('B4DB1657-70D7-485E-8E3E-6FCB5A5C1802');

/// `IID_IFileOpenDialog`.
final Guid iidIFileOpenDialog =
    Guid.parse('D57C7288-D4AD-4768-BE02-9D969532D960');

/// `IID_IFileSaveDialog`.
final Guid iidIFileSaveDialog =
    Guid.parse('84BCCD23-5FDE-4CDB-AEA4-AF64B83D78AB');

/// `IID_IShellItem` - what a result is.
final Guid iidIShellItem = Guid.parse('43826D1E-E718-42EE-BC55-A1E261C37BFE');

/// `IID_IShellItemArray` - what a multiple selection is.
final Guid iidIShellItemArray =
    Guid.parse('B63EA76D-1F85-456F-A19C-48159EFA858B');

// ---------------------------------------------------------------------------
// HRESULTs and flags
// ---------------------------------------------------------------------------

/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`, which is what `IModalWindow::Show`
/// returns when the user dismissed the dialog.
///
/// A failure code by the sign bit and not a failure by meaning: treating it as
/// one is how a cancelled open turns into an exception in the caller's face.
const int hresultCancelled = -2147023673; // 0x800704C7

/// `RPC_E_CHANGED_MODE`: the thread is already in the other apartment.
const int rpcErrorChangedMode = -2147417850; // 0x80010106

const int _clsctxInprocServer = 0x1;
const int _coinitApartmentThreaded = 0x2;

/// `COINIT_DISABLE_OLE1DDE`. Documented as recommended for every new caller:
/// without it COM starts the OLE1 DDE support, which the shell dialogs do not
/// use and which costs a hidden window and a broadcast on this thread.
const int _coinitDisableOle1Dde = 0x4;

/// `FILEOPENDIALOGOPTIONS`, the subset this picker sets.
const int _fosOverwritePrompt = 0x00000002;

/// `FOS_FORCEFILESYSTEM`. The one option that is not optional here: without it
/// the user can select a library, a search result or a not-yet-downloaded
/// OneDrive item, and `GetDisplayName(SIGDN_FILESYSPATH)` then fails on a
/// selection the user believes they made.
const int _fosForceFileSystem = 0x00000040;
const int _fosAllowMultiSelect = 0x00000200;
const int _fosPathMustExist = 0x00000800;
const int _fosFileMustExist = 0x00001000;

/// `SIGDN_FILESYSPATH` - the display name that is a path on disk.
const int _sigdnFileSysPath = 0x80058000;

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

/// How a modern-dialog attempt ended.
enum WindowsFileDialogStatus {
  /// The user chose at least one file.
  selected,

  /// The user dismissed the dialog. Not an error.
  cancelled,

  /// The dialog could not be created on this machine or in this session. The
  /// caller must fall back to the legacy dialog rather than report a failure.
  unavailable,

  /// The dialog was created and a call on it failed.
  failed,
}

/// The answer from [showWindowsFileDialog].
final class WindowsFileDialogResult {
  const WindowsFileDialogResult({
    required this.status,
    this.paths = const <String>[],
    this.hresult = sOk,
    this.detail,
  });

  const WindowsFileDialogResult.cancelled()
      : status = WindowsFileDialogStatus.cancelled,
        paths = const <String>[],
        hresult = hresultCancelled,
        detail = null;

  /// The dialog is not reachable; the caller runs the legacy path.
  const WindowsFileDialogResult.unavailable(String this.detail,
      {this.hresult = sOk})
      : status = WindowsFileDialogStatus.unavailable,
        paths = const <String>[];

  final WindowsFileDialogStatus status;

  /// Empty for every status other than [WindowsFileDialogStatus.selected].
  final List<String> paths;

  /// The raw code, already signed, for a caller that reports it.
  final int hresult;

  /// Why the dialog was unavailable or what failed. Never a user-facing
  /// string; it names the API that refused.
  final String? detail;

  /// The single selected path, or null.
  String? get path => paths.isEmpty ? null : paths.first;

  /// Whether the caller must run the legacy `GetOpenFileNameW` path.
  ///
  /// A predicate rather than a comparison at the call site because it is the
  /// one decision this file exists to hand over, and a test asserts it.
  bool get shouldFallBackToLegacy =>
      status == WindowsFileDialogStatus.unavailable;
}

/// Whether [value] is the user pressing Cancel rather than a failure.
bool isCancelledHresult(int value) => hresult(value) == hresultCancelled;

/// One native call made while creating or configuring a dialog, and what it
/// answered.
///
/// Recorded so that everything up to - and deliberately excluding - `Show` can
/// be exercised and reported on a desktop nobody is watching. `Show` is the
/// only step that puts a window in front of a user, and it is the only step
/// this record cannot cover.
///
/// [required] is false for a call whose failure is expected and harmless - the
/// `QueryInterface` for [iidIFileDialog] is one, and a reader who did not know
/// that would file the `E_NOINTERFACE` as a bug.
typedef WindowsFileDialogStep = ({String call, int hresult, bool required});

/// The `COMDLG_FILTERSPEC` rows for [filters].
///
/// Separated from the call because it is the half that can be asserted without
/// a desktop, and because the legacy path's NUL-separated string and this list
/// have to agree on the same patterns - `*.pdf;*.xps`, from
/// [FilePickerFilter.wildcardPattern].
///
/// An empty [filters] becomes the same "All files" row the legacy path
/// substituted, so that a caller that passes nothing still gets a dialog that
/// shows every file instead of one that shows none.
List<({String label, String pattern})> windowsFilterSpecs(
  List<FilePickerFilter> filters,
) {
  final List<FilePickerFilter> effective = filters.isEmpty
      ? const <FilePickerFilter>[
          FilePickerFilter(label: 'All files', extensions: <String>['*']),
        ]
      : filters;
  return <({String label, String pattern})>[
    for (final FilePickerFilter filter in effective)
      (label: filter.label, pattern: filter.wildcardPattern),
  ];
}

/// The extension `IFileDialog::SetDefaultExtension` wants: no leading dot.
///
/// `lpstrDefExt` had the same rule and the same trap - passing `.svg` there
/// produces `drawing..svg`.
String? normalizedDefaultExtension(String? value) {
  if (value == null) return null;
  final String trimmed = value.startsWith('.') ? value.substring(1) : value;
  return trimmed.isEmpty ? null : trimmed;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Opens the Common Item Dialog.
///
/// [save] picks `IFileSaveDialog` over `IFileOpenDialog`; the two share
/// `IFileDialog` for everything except how the result is read.
///
/// Returns [WindowsFileDialogStatus.unavailable] - never throws - when the
/// dialog cannot be created, which is what makes the legacy fallback possible.
WindowsFileDialogResult showWindowsFileDialog({
  required bool save,
  required String title,
  List<FilePickerFilter> filters = const <FilePickerFilter>[],
  String suggestedName = '',
  String? defaultExtension,
  String? initialDirectory,
  bool allowMultiple = false,
  int ownerWindowHandle = 0,
}) {
  if (!Platform.isWindows) {
    return const WindowsFileDialogResult.unavailable(
      'the Common Item Dialog is a Windows API',
    );
  }
  final _ShellDialogApi? api = _ShellDialogApi.instance;
  if (api == null) {
    return const WindowsFileDialogResult.unavailable(
      'ole32.dll or shell32.dll could not be loaded',
    );
  }

  final _Apartment? apartment = _Apartment.enter(api);
  if (apartment == null) {
    return const WindowsFileDialogResult.unavailable(
      'CoInitializeEx refused this thread',
    );
  }
  try {
    return _show(
      api: api,
      save: save,
      title: title,
      filters: filters,
      suggestedName: suggestedName,
      defaultExtension: defaultExtension,
      initialDirectory: initialDirectory,
      allowMultiple: allowMultiple,
      ownerWindowHandle: ownerWindowHandle,
    );
  } finally {
    apartment.leave();
  }
}

/// Creates a dialog, configures it exactly as [showWindowsFileDialog] would,
/// releases it, and reports every HRESULT on the way - **without** calling
/// `Show`.
///
/// The reason this exists is that `Show` is modal and puts a window on
/// somebody's screen, so it cannot run unattended, while everything that can
/// actually be wrong in this file happens before it: a mistyped CLSID, a vtable
/// slot off by one, a filter table whose two `LPCWSTR`s are swapped, an
/// extension the dialog rejects. All of that answers an HRESULT here.
///
/// It does not prove the dialog draws, has the user's pinned places, or returns
/// the file that was clicked. Only a human running `tool/file_dialog_smoke.dart
/// --interactive` proves those.
List<WindowsFileDialogStep> probeWindowsFileDialog({
  required bool save,
  String title = 'probe',
  List<FilePickerFilter> filters = const <FilePickerFilter>[],
  String suggestedName = '',
  String? defaultExtension,
  String? initialDirectory,
  bool allowMultiple = false,
}) {
  final List<WindowsFileDialogStep> trace = <WindowsFileDialogStep>[];
  if (!Platform.isWindows) {
    trace.add((call: 'Platform.isWindows', hresult: eFail, required: true));
    return trace;
  }
  final _ShellDialogApi? api = _ShellDialogApi.instance;
  if (api == null) {
    trace.add((
      call: 'LoadLibrary(ole32.dll, shell32.dll)',
      hresult: eFail,
      required: true,
    ));
    return trace;
  }
  final _Apartment? apartment = _Apartment.enter(api);
  trace.add((
    call: 'CoInitializeEx(APARTMENTTHREADED|DISABLE_OLE1DDE)',
    hresult: apartment?.result ?? eFail,
    required: true,
  ));
  if (apartment == null) return trace;

  final NativeArena arena = NativeArena();
  _FileDialog? dialog;
  try {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    final Guid clsid = save ? clsidFileSaveDialog : clsidFileOpenDialog;
    final Guid iid = save ? iidIFileSaveDialog : iidIFileOpenDialog;
    final int created = hresult(api.coCreateInstance(
      clsid.allocateIn(arena),
      nullptr,
      _clsctxInprocServer,
      iid.allocateIn(arena),
      out,
    ));
    trace.add((
      call: 'CoCreateInstance('
          '${save ? 'CLSID_FileSaveDialog' : 'CLSID_FileOpenDialog'}, '
          '${save ? 'IID_IFileSaveDialog' : 'IID_IFileOpenDialog'})',
      hresult: created,
      required: true,
    ));
    if (failed(created) || out.value == nullptr) return trace;
    dialog = _FileDialog(
      out.value,
      interfaceName: save ? 'IFileSaveDialog' : 'IFileOpenDialog',
    );

    // Two QIs, and only the first has to succeed. IModalWindow is the base the
    // shell dialog really publishes, so it is the proof that CoCreateInstance
    // returned a dialog rather than whatever else the registry pointed at.
    // IFileDialog is recorded next to it because it answers E_NOINTERFACE on a
    // perfectly healthy machine - see the comment on [iidIFileDialog] - and a
    // reader who found that out from a bug report instead of from here would
    // have spent an afternoon on it.
    for (final ({Guid iid, String name, bool required}) probe
        in <({Guid iid, String name, bool required})>[
      (iid: iidIModalWindow, name: 'IID_IModalWindow', required: true),
      (iid: iidIFileDialog, name: 'IID_IFileDialog', required: false),
    ]) {
      final Pointer<Pointer<Void>> base = arena.allocateOutPointer();
      final int queried = dialog.queryInterfaceInto(probe.iid, base);
      trace.add((
        call: 'QueryInterface(${probe.name})',
        hresult: queried,
        required: probe.required,
      ));
      if (succeeded(queried) && base.value != nullptr) {
        ComObject(base.value, interfaceName: probe.name).dispose();
      }
    }

    _configure(
      api: api,
      arena: arena,
      dialog: dialog,
      save: save,
      title: title,
      filters: filters,
      suggestedName: suggestedName,
      defaultExtension: defaultExtension,
      initialDirectory: initialDirectory,
      allowMultiple: allowMultiple,
      trace: trace,
    );
    return trace;
  } finally {
    dialog?.dispose();
    arena.dispose();
    apartment.leave();
  }
}

WindowsFileDialogResult _show({
  required _ShellDialogApi api,
  required bool save,
  required String title,
  required List<FilePickerFilter> filters,
  required String suggestedName,
  required String? defaultExtension,
  required String? initialDirectory,
  required bool allowMultiple,
  required int ownerWindowHandle,
}) {
  final NativeArena arena = NativeArena();
  _FileDialog? dialog;
  try {
    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    final Guid clsid = save ? clsidFileSaveDialog : clsidFileOpenDialog;
    final Guid iid = save ? iidIFileSaveDialog : iidIFileOpenDialog;
    final int created = hresult(api.coCreateInstance(
      clsid.allocateIn(arena),
      nullptr,
      _clsctxInprocServer,
      iid.allocateIn(arena),
      out,
    ));
    // The documented fallback point. A locked-down session, a Windows older
    // than Vista or a shell whose registration is broken answers here, and the
    // caller then runs GetOpenFileNameW - which needs none of COM - instead of
    // showing the user an error for a dialog they never asked about.
    if (failed(created) || out.value == nullptr) {
      return WindowsFileDialogResult.unavailable(
        'CoCreateInstance(${save ? 'FileSaveDialog' : 'FileOpenDialog'}) '
        'answered ${hresultName(created)}',
        hresult: created,
      );
    }
    dialog = _FileDialog(
      out.value,
      interfaceName: save ? 'IFileSaveDialog' : 'IFileOpenDialog',
    );

    final int configured = _configure(
      api: api,
      arena: arena,
      dialog: dialog,
      save: save,
      title: title,
      filters: filters,
      suggestedName: suggestedName,
      defaultExtension: defaultExtension,
      initialDirectory: initialDirectory,
      allowMultiple: allowMultiple,
    );
    if (failed(configured)) {
      return WindowsFileDialogResult(
        status: WindowsFileDialogStatus.failed,
        hresult: configured,
        detail: 'IFileDialog configuration answered '
            '${hresultName(configured)}',
      );
    }

    final int shown = hresult(dialog.show(ownerWindowHandle));
    if (isCancelledHresult(shown)) {
      return const WindowsFileDialogResult.cancelled();
    }
    if (failed(shown)) {
      return WindowsFileDialogResult(
        status: WindowsFileDialogStatus.failed,
        hresult: shown,
        detail: 'IFileDialog::Show answered ${hresultName(shown)}',
      );
    }

    final List<String> paths = allowMultiple && !save
        ? _readMultiple(api, arena, dialog)
        : _readSingle(api, arena, dialog);
    if (paths.isEmpty) {
      // Show() succeeded, so a selection exists; an empty list here means the
      // item had no file-system path, which FOS_FORCEFILESYSTEM is supposed to
      // prevent. Reported rather than returned as a silent cancel.
      return const WindowsFileDialogResult(
        status: WindowsFileDialogStatus.failed,
        detail: 'the selection had no file-system path',
      );
    }
    return WindowsFileDialogResult(
      status: WindowsFileDialogStatus.selected,
      paths: paths,
    );
  } finally {
    // Both releases run on every path, including the two returns above and a
    // throw out of the middle of the configuration: an IFileDialog that
    // outlives this function keeps the shell's dialog object and its worker
    // thread alive for the rest of the process.
    dialog?.dispose();
    arena.dispose();
  }
}

int _configure({
  required _ShellDialogApi api,
  required NativeArena arena,
  required _FileDialog dialog,
  required bool save,
  required String title,
  required List<FilePickerFilter> filters,
  required String suggestedName,
  required String? defaultExtension,
  required String? initialDirectory,
  required bool allowMultiple,
  List<WindowsFileDialogStep>? trace,
}) {
  // Every configuration call goes through here so that the unattended probe
  // and the real dialog take exactly one code path. A second, "probe-only"
  // configuration routine would be free to drift out of agreement with this
  // one, and the drift would be invisible until a user opened a dialog.
  int step(String call, int value) {
    final int code = hresult(value);
    trace?.add((call: call, hresult: code, required: true));
    return code;
  }

  int hr = step(
      'IFileDialog::SetTitle',
      dialog.setTitle(
        arena.allocateUtf16(title),
      ));
  if (failed(hr)) return hr;

  final List<({String label, String pattern})> specs =
      windowsFilterSpecs(filters);
  // COMDLG_FILTERSPEC is two LPCWSTRs, so the array is 2n pointers and the
  // strings have to outlive the Show() call - hence the arena rather than a
  // per-string allocation freed at the end of this function.
  final Pointer<Pointer<Uint16>> table = arena
      .allocate<Pointer<Uint16>>(specs.length * 2 * sizeOf<Pointer<Void>>());
  for (int i = 0; i < specs.length; i++) {
    table[i * 2] = arena.allocateUtf16(specs[i].label);
    table[i * 2 + 1] = arena.allocateUtf16(specs[i].pattern);
  }
  hr = step(
    'IFileDialog::SetFileTypes(${specs.length})',
    dialog.setFileTypes(specs.length, table.cast<Void>()),
  );
  if (failed(hr)) return hr;
  // One-based, like nFilterIndex was. Zero is an error, not "the first".
  hr = step('IFileDialog::SetFileTypeIndex(1)', dialog.setFileTypeIndex(1));
  if (failed(hr)) return hr;

  final Pointer<Uint32> options = arena.allocate<Uint32>(sizeOf<Uint32>());
  hr = step('IFileDialog::GetOptions', dialog.getOptions(options));
  if (failed(hr)) return hr;
  // OR into what the dialog already has rather than assigning: the shell puts
  // per-user state in there (FOS_DEFAULTNOMINIMODE and friends), and replacing
  // the word wholesale is how the dialog loses the view the user chose.
  //
  // FOS_NOCHANGEDIR is deliberately absent. It was mandatory for
  // GetOpenFileNameW, which changed the process working directory as a side
  // effect; the Common Item Dialog never does, and the flag is documented as
  // unused.
  int wanted = options.value | _fosForceFileSystem | _fosPathMustExist;
  wanted |= save
      ? _fosOverwritePrompt
      : (_fosFileMustExist | (allowMultiple ? _fosAllowMultiSelect : 0));
  hr = step(
    'IFileDialog::SetOptions(0x${wanted.toRadixString(16)})',
    dialog.setOptions(wanted),
  );
  if (failed(hr)) return hr;

  if (suggestedName.isNotEmpty) {
    hr = step(
      'IFileDialog::SetFileName($suggestedName)',
      dialog.setFileName(arena.allocateUtf16(suggestedName)),
    );
    if (failed(hr)) return hr;
  }
  final String? extension = normalizedDefaultExtension(defaultExtension);
  if (extension != null) {
    hr = step(
      'IFileDialog::SetDefaultExtension($extension)',
      dialog.setDefaultExtension(arena.allocateUtf16(extension)),
    );
    if (failed(hr)) return hr;
  }
  if (initialDirectory != null && initialDirectory.isNotEmpty) {
    // SetFolder and not SetDefaultFolder: the caller asking for a directory
    // means "start here", while SetDefaultFolder is only consulted the first
    // time the user ever opens this dialog. A directory that no longer exists
    // is not a failure - the dialog simply opens where it would have.
    final Pointer<Pointer<Void>> item = arena.allocateOutPointer();
    final int found = step(
      'SHCreateItemFromParsingName($initialDirectory)',
      api.shCreateItemFromParsingName(
        arena.allocateUtf16(initialDirectory),
        nullptr,
        iidIShellItem.allocateIn(arena),
        item,
      ),
    );
    if (succeeded(found) && item.value != nullptr) {
      final ComObject folder =
          ComObject(item.value, interfaceName: 'IShellItem');
      try {
        // Recorded but not propagated: a folder the dialog declined to start
        // in is a worse starting directory, not a failed open.
        step('IFileDialog::SetFolder', dialog.setFolder(folder.pointer));
      } finally {
        folder.dispose();
      }
    }
  }
  return sOk;
}

List<String> _readSingle(
  _ShellDialogApi api,
  NativeArena arena,
  _FileDialog dialog,
) {
  final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
  final int hr = hresult(dialog.getResult(out));
  if (failed(hr) || out.value == nullptr) return const <String>[];
  final _ShellItem item = _ShellItem(out.value);
  try {
    final String? path = item.fileSystemPath(api, arena);
    return path == null ? const <String>[] : <String>[path];
  } finally {
    item.dispose();
  }
}

List<String> _readMultiple(
  _ShellDialogApi api,
  NativeArena arena,
  _FileDialog dialog,
) {
  final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
  final int hr = hresult(dialog.getResults(out));
  if (failed(hr) || out.value == nullptr) return const <String>[];
  final _ShellItemArray array = _ShellItemArray(out.value);
  try {
    final Pointer<Uint32> count = arena.allocate<Uint32>(sizeOf<Uint32>());
    if (failed(array.getCount(count))) return const <String>[];
    final List<String> paths = <String>[];
    for (int i = 0; i < count.value; i++) {
      final Pointer<Pointer<Void>> slot = arena.allocateOutPointer();
      if (failed(array.getItemAt(i, slot)) || slot.value == nullptr) continue;
      // One item per iteration, released inside the loop. Collecting them all
      // and releasing at the end would leak every item after the first
      // GetDisplayName that throws.
      final _ShellItem item = _ShellItem(slot.value);
      try {
        final String? path = item.fileSystemPath(api, arena);
        if (path != null) paths.add(path);
      } finally {
        item.dispose();
      }
    }
    return paths;
  } finally {
    array.dispose();
  }
}

// ---------------------------------------------------------------------------
// Interfaces
// ---------------------------------------------------------------------------

typedef _NativeShow = Int32 Function(Pointer<Void>, IntPtr);
typedef _NativeSetFileTypes = Int32 Function(
    Pointer<Void>, Uint32, Pointer<Void>);
typedef _NativeSetUint = Int32 Function(Pointer<Void>, Uint32);
typedef _NativeGetUint = Int32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _NativeSetString = Int32 Function(Pointer<Void>, Pointer<Uint16>);
typedef _NativeSetPointer = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _NativeGetPointer = Int32 Function(
    Pointer<Void>, Pointer<Pointer<Void>>);
typedef _NativeGetItemAt = Int32 Function(
    Pointer<Void>, Uint32, Pointer<Pointer<Void>>);
typedef _NativeGetDisplayName = Int32 Function(
    Pointer<Void>, Uint32, Pointer<Pointer<Uint16>>);

/// `IFileDialog`, plus the two slots `IFileOpenDialog` adds after it.
///
/// The slot numbers are the whole interface. They come from the vtable order
/// in `shobjidl_core.h` and a miscount is silent - slot 20 is `GetResult` and
/// slot 21 is `AddPlace`, so being one out calls a method that takes an
/// interface pointer with an out-parameter and corrupts the stack. They are
/// therefore written with the method name next to each one.
final class _FileDialog extends ComObject {
  _FileDialog(super.pointer, {required super.interfaceName});

  late final int Function(Pointer<Void>, int) _show =
      comMethod<_NativeShow>(pointer, 3).asFunction(); // IModalWindow::Show
  late final int Function(Pointer<Void>, int, Pointer<Void>) _setFileTypes =
      comMethod<_NativeSetFileTypes>(pointer, 4).asFunction();
  late final int Function(Pointer<Void>, int) _setFileTypeIndex =
      comMethod<_NativeSetUint>(pointer, 5).asFunction();
  late final int Function(Pointer<Void>, int) _setOptions =
      comMethod<_NativeSetUint>(pointer, 9).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint32>) _getOptions =
      comMethod<_NativeGetUint>(pointer, 10).asFunction();
  late final int Function(Pointer<Void>, Pointer<Void>) _setFolder =
      comMethod<_NativeSetPointer>(pointer, 12).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint16>) _setFileName =
      comMethod<_NativeSetString>(pointer, 15).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint16>) _setTitle =
      comMethod<_NativeSetString>(pointer, 17).asFunction();
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _getResult =
      comMethod<_NativeGetPointer>(pointer, 20).asFunction();
  late final int Function(Pointer<Void>, Pointer<Uint16>) _setDefaultExtension =
      comMethod<_NativeSetString>(pointer, 22).asFunction();

  /// `IFileOpenDialog::GetResults`, the first slot past `IFileDialog`. Only
  /// valid on an object created from `CLSID_FileOpenDialog`.
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _getResults =
      comMethod<_NativeGetPointer>(pointer, 27).asFunction();

  int show(int owner) => _show(pointer, owner);
  int setFileTypes(int count, Pointer<Void> specs) =>
      _setFileTypes(pointer, count, specs);
  int setFileTypeIndex(int index) => _setFileTypeIndex(pointer, index);
  int setOptions(int options) => _setOptions(pointer, options);
  int getOptions(Pointer<Uint32> out) => _getOptions(pointer, out);
  int setFolder(Pointer<Void> item) => _setFolder(pointer, item);
  int setFileName(Pointer<Uint16> name) => _setFileName(pointer, name);
  int setTitle(Pointer<Uint16> title) => _setTitle(pointer, title);
  int getResult(Pointer<Pointer<Void>> out) => _getResult(pointer, out);
  int setDefaultExtension(Pointer<Uint16> extension) =>
      _setDefaultExtension(pointer, extension);
  int getResults(Pointer<Pointer<Void>> out) => _getResults(pointer, out);
}

final class _ShellItem extends ComObject {
  _ShellItem(super.pointer) : super(interfaceName: 'IShellItem');

  late final int Function(Pointer<Void>, int, Pointer<Pointer<Uint16>>)
      _getDisplayName =
      comMethod<_NativeGetDisplayName>(pointer, 5).asFunction();

  /// The item's path on disk, or null when it has none.
  ///
  /// The `LPWSTR` comes from the COM task allocator and is the caller's to
  /// free; a missed `CoTaskMemFree` here leaks one path per file the user ever
  /// opens, which is invisible until an application has been running for a
  /// day.
  String? fileSystemPath(_ShellDialogApi api, NativeArena arena) {
    final Pointer<Pointer<Uint16>> out =
        arena.allocate<Pointer<Uint16>>(sizeOf<Pointer<Void>>());
    out.value = nullptr;
    final int hr = hresult(_getDisplayName(pointer, _sigdnFileSysPath, out));
    if (failed(hr) || out.value == nullptr) return null;
    try {
      final String path = readNativeUtf16(out.value, limit: 32768);
      return path.isEmpty ? null : path;
    } finally {
      api.coTaskMemFree(out.value.cast<Void>());
    }
  }
}

final class _ShellItemArray extends ComObject {
  _ShellItemArray(super.pointer) : super(interfaceName: 'IShellItemArray');

  late final int Function(Pointer<Void>, Pointer<Uint32>) _getCount =
      comMethod<_NativeGetUint>(pointer, 7).asFunction();
  late final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      _getItemAt = comMethod<_NativeGetItemAt>(pointer, 8).asFunction();

  int getCount(Pointer<Uint32> out) => _getCount(pointer, out);
  int getItemAt(int index, Pointer<Pointer<Void>> out) =>
      _getItemAt(pointer, index, out);
}

// ---------------------------------------------------------------------------
// ole32 / shell32
// ---------------------------------------------------------------------------

typedef _NativeCoInitializeEx = Int32 Function(Pointer<Void>, Uint32);
typedef _NativeCoUninitialize = Void Function();
typedef _NativeCoCreateInstance = Int32 Function(Pointer<Uint8>, Pointer<Void>,
    Uint32, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef _NativeCoTaskMemFree = Void Function(Pointer<Void>);
typedef _NativeShCreateItemFromParsingName = Int32 Function(
    Pointer<Uint16>, Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);

/// The four `ole32.dll` entry points and the one `shell32.dll` entry point the
/// dialog needs, bound once per process.
///
/// A missing library is data and not an exception, the same rule
/// `win32_api.dart` and `uia_core.dart` follow: the answer is null, the caller
/// reports "unavailable", and the legacy dialog runs.
final class _ShellDialogApi {
  _ShellDialogApi._(DynamicLibrary ole32, DynamicLibrary shell32)
      : coInitializeEx = ole32.lookupFunction<_NativeCoInitializeEx,
            int Function(Pointer<Void>, int)>('CoInitializeEx'),
        coUninitialize =
            ole32.lookupFunction<_NativeCoUninitialize, void Function()>(
                'CoUninitialize'),
        coCreateInstance = ole32.lookupFunction<
            _NativeCoCreateInstance,
            int Function(Pointer<Uint8>, Pointer<Void>, int, Pointer<Uint8>,
                Pointer<Pointer<Void>>)>('CoCreateInstance'),
        coTaskMemFree = ole32.lookupFunction<_NativeCoTaskMemFree,
            void Function(Pointer<Void>)>('CoTaskMemFree'),
        shCreateItemFromParsingName = shell32.lookupFunction<
            _NativeShCreateItemFromParsingName,
            int Function(Pointer<Uint16>, Pointer<Void>, Pointer<Uint8>,
                Pointer<Pointer<Void>>)>('SHCreateItemFromParsingName');

  final int Function(Pointer<Void>, int) coInitializeEx;
  final void Function() coUninitialize;
  final int Function(Pointer<Uint8>, Pointer<Void>, int, Pointer<Uint8>,
      Pointer<Pointer<Void>>) coCreateInstance;
  final void Function(Pointer<Void>) coTaskMemFree;
  final int Function(Pointer<Uint16>, Pointer<Void>, Pointer<Uint8>,
      Pointer<Pointer<Void>>) shCreateItemFromParsingName;

  static _ShellDialogApi? _instance;
  static bool _attempted = false;

  static _ShellDialogApi? get instance {
    if (_attempted) return _instance;
    _attempted = true;
    if (!Platform.isWindows) return null;
    try {
      return _instance = _ShellDialogApi._(
        DynamicLibrary.open('ole32.dll'),
        DynamicLibrary.open('shell32.dll'),
      );
    } on Object {
      return null;
    }
  }
}

/// One `CoInitializeEx`/`CoUninitialize` pair around one dialog.
///
/// ## Why this is not a bool
///
/// The UI Automation bridge already calls `CoInitializeEx` on the thread that
/// pumps the window (see `uia_bridge.dart`), and so does anything that has
/// touched WIC or drag and drop. All three answers have to be told apart, and
/// two of them look like the third if read carelessly:
///
///   * **`S_OK`** - this call opened the apartment. Balance it.
///   * **`S_FALSE`** - the apartment was already open, *and the per-thread
///     reference count was still incremented*. It is a success, and skipping
///     the `CoUninitialize` because "somebody else owns it" leaves COM up for
///     the life of the process. Balance it too.
///   * **`RPC_E_CHANGED_MODE`** - the thread is in the multi-threaded
///     apartment and stays there. The count was **not** incremented, so
///     calling `CoUninitialize` here would drop somebody else's reference and
///     tear their apartment down. Not balanced, and not a failure either: the
///     shell dialog is registered as apartment-threaded, so COM hosts it in
///     its own STA and marshals, which is slower but works. If it does not,
///     `Show` fails and the caller falls back.
final class _Apartment {
  _Apartment._(this._api, {required this.balanced, required this.result});

  final _ShellDialogApi _api;

  /// Whether [leave] owes a `CoUninitialize`.
  final bool balanced;

  /// What `CoInitializeEx` answered, for the probe's report.
  final int result;

  static _Apartment? enter(_ShellDialogApi api) {
    final int hr = hresult(api.coInitializeEx(
      nullptr,
      _coinitApartmentThreaded | _coinitDisableOle1Dde,
    ));
    if (hr == rpcErrorChangedMode) {
      return _Apartment._(api, balanced: false, result: hr);
    }
    if (failed(hr)) return null;
    return _Apartment._(api, balanced: true, result: hr);
  }

  void leave() {
    if (balanced) _api.coUninitialize();
  }
}
