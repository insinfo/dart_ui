/// Operating-system resource counters for the process this runs in.
///
/// The class of leak nothing else in this repository can see. A `HWND`, a DIB
/// section, a brush, a `CreateFile` handle and a Direct3D resource are all
/// invisible to the Dart garbage collector, invisible to `getAllocationProfile`
/// and - except for the last - invisible to [NativeAllocator]'s own accounting,
/// because the framework never allocated them: it asked Windows to, and Windows
/// is keeping the tally.
///
/// That tally is readable, exactly, as integers:
///
///   * `GetGuiResources(process, GR_GDIOBJECTS)` - device contexts, bitmaps,
///     brushes, pens, regions, fonts. A window that is recreated on every
///     resize and forgets its DIB section moves this counter by one per resize
///     and nothing else in the process notices until the 10000-object per
///     process quota is hit and `CreateWindowEx` starts failing.
///   * `GetGuiResources(process, GR_USEROBJECTS)` - windows, menus, cursors,
///     icons, accelerator tables, hooks. An `HWND` that is never destroyed
///     lives here.
///   * `GetProcessHandleCount` - every kernel handle: files, events, threads,
///     mutexes, sections, and the D3D/DXGI objects that are kernel objects
///     underneath.
///   * `GetProcessMemoryInfo`'s `PrivateUsage` - committed private bytes. The
///     catch-all: it moves for a leak in a driver, in D3D, in a decoder's own
///     heap, in anything at all that this process committed and did not give
///     back. Coarse and noisy compared to the three above, and the only one
///     that would notice a graphics driver holding a lost swap chain.
///
/// ## Deliberately in-process
///
/// These are read for the *current* process, through the pseudo-handle
/// `GetCurrentProcess()` returns, so a suite measures the run it is doing
/// rather than a child it spawned. That is what makes them work in AOT, where
/// there is no VM Service at all: [ProcessCounters] needs nothing but
/// `dart:ffi`.
///
/// ## Not portable, and it says so
///
/// There is no Linux or macOS equivalent of `GR_GDIOBJECTS` because there is no
/// GDI. [ProcessCounters.isAvailable] is false off Windows and every field of
/// the snapshot is null there rather than zero - a zero would read as "nothing
/// leaked" and be a lie. The X11 and Cocoa equivalents (`/proc/self/fd`,
/// Mach port counts) are named in the roadmap as uncovered rather than
/// pretended here.
library;

import 'dart:ffi';
import 'dart:io';

/// `GetGuiResources` flag: GDI objects.
const int _grGdiObjects = 0;

/// `GetGuiResources` flag: USER objects.
const int _grUserObjects = 1;

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _GetGuiResourcesNative = Uint32 Function(IntPtr, Uint32);
typedef _GetGuiResourcesDart = int Function(int, int);
typedef _GetProcessHandleCountNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetProcessHandleCountDart = int Function(int, Pointer<Uint32>);
typedef _GetProcessMemoryInfoNative = Int32 Function(
    IntPtr, Pointer<Uint8>, Uint32);
typedef _GetProcessMemoryInfoDart = int Function(int, Pointer<Uint8>, int);

/// Binds the counters once and reads them cheaply thereafter.
final class ProcessResourceProbe {
  ProcessResourceProbe._(
    this._process,
    this._getGuiResources,
    this._getProcessHandleCount,
    this._getProcessMemoryInfo,
    this._memoryCounters,
  );

  final int _process;
  final _GetGuiResourcesDart? _getGuiResources;
  final _GetProcessHandleCountDart? _getProcessHandleCount;
  final _GetProcessMemoryInfoDart? _getProcessMemoryInfo;

  /// One reusable `PROCESS_MEMORY_COUNTERS_EX` and one reusable `DWORD`.
  ///
  /// Allocated once and never freed, on purpose: a probe that allocated per
  /// sample would be a leak inside the leak detector, and the numbers it
  /// reported would include its own scratch space.
  final Pointer<Uint8> _memoryCounters;
  final Pointer<Uint32> _handleCount = _scratchHandleCount;

  static final Pointer<Uint32> _scratchHandleCount = calloc(4).cast<Uint32>();

  static ProcessResourceProbe? _instance;
  static bool _attempted = false;

  /// The probe, or null where these counters do not exist.
  static ProcessResourceProbe? tryBind() {
    if (_attempted) return _instance;
    _attempted = true;
    if (!Platform.isWindows) return null;
    try {
      final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
      final int process = kernel32.lookupFunction<_GetCurrentProcessNative,
          _GetCurrentProcessDart>('GetCurrentProcess')();
      _GetGuiResourcesDart? gui;
      try {
        gui = DynamicLibrary.open('user32.dll')
            .lookupFunction<_GetGuiResourcesNative, _GetGuiResourcesDart>(
                'GetGuiResources');
      } on Object {
        gui = null;
      }
      _GetProcessHandleCountDart? handles;
      try {
        handles = kernel32.lookupFunction<_GetProcessHandleCountNative,
            _GetProcessHandleCountDart>('GetProcessHandleCount');
      } on Object {
        handles = null;
      }
      // `K32GetProcessMemoryInfo` is the kernel32 forwarder that exists on
      // Windows 7 and later; psapi.dll's `GetProcessMemoryInfo` is the older
      // spelling and is tried second so a machine missing one still reports.
      _GetProcessMemoryInfoDart? memory;
      for (final (DynamicLibrary library, String symbol) candidate
          in <(DynamicLibrary, String)>[
        (kernel32, 'K32GetProcessMemoryInfo'),
        (DynamicLibrary.open('psapi.dll'), 'GetProcessMemoryInfo'),
      ]) {
        try {
          memory = candidate.$1.lookupFunction<_GetProcessMemoryInfoNative,
              _GetProcessMemoryInfoDart>(candidate.$2);
          break;
        } on Object {
          continue;
        }
      }
      return _instance = ProcessResourceProbe._(
        process,
        gui,
        handles,
        memory,
        calloc(_processMemoryCountersExSize),
      );
    } on Object {
      return null;
    }
  }

  static bool get isAvailable => tryBind() != null;

  /// `PROCESS_MEMORY_COUNTERS_EX`: `DWORD cb`, `DWORD PageFaultCount`, then
  /// nine `SIZE_T` fields - peak working set, working set, four quota counters,
  /// pagefile usage, peak pagefile usage, private usage. 80 bytes on 64-bit.
  ///
  /// `cb` has to be the size of *this* structure and not a byte more:
  /// `GetProcessMemoryInfo` validates it, and a `cb` larger than the layout it
  /// knows is `ERROR_BAD_LENGTH` and a buffer of zeros - which reads as "no
  /// growth" and is the worst possible failure for a leak suite.
  static int get _processMemoryCountersExSize => 8 + 9 * sizeOf<IntPtr>();

  /// Offset of `PrivateUsage`, the ninth and last `SIZE_T`.
  static int get _privateUsageOffset => 8 + 8 * sizeOf<IntPtr>();

  /// Offset of `WorkingSetSize`, the **second** `SIZE_T`, after
  /// `PeakWorkingSetSize`.
  ///
  /// Read one field too far in the first version of this file, and the symptom
  /// is worth recording because nothing failed: the call succeeded, private
  /// bytes were right, and the only sign was a working set of 251 KB reported
  /// beside 282 MB of private bytes - the value of `QuotaPeakPagedPoolUsage`,
  /// which is a perfectly plausible-looking number for a counter nobody checks
  /// against another source.
  static int get _workingSetOffset => 8 + sizeOf<IntPtr>();

  /// Reads every counter now.
  ProcessCounters sample() {
    final _GetGuiResourcesDart? gui = _getGuiResources;
    int? gdi;
    int? user;
    if (gui != null) {
      // Reported raw, zero included. An earlier version treated 0 as "the call
      // failed" because 0 is also the documented failure return, and the
      // result was that a console process - which genuinely holds no GDI
      // objects until it makes a window - had its GDI row silently dropped
      // from every table, which is the one row this suite was written for.
      gdi = gui(_process, _grGdiObjects);
      user = gui(_process, _grUserObjects);
    }
    int? handles;
    final _GetProcessHandleCountDart? handleCount = _getProcessHandleCount;
    if (handleCount != null && handleCount(_process, _handleCount) != 0) {
      handles = _handleCount.value;
    }
    int? privateBytes;
    int? workingSetBytes;
    final _GetProcessMemoryInfoDart? memory = _getProcessMemoryInfo;
    if (memory != null) {
      _memoryCounters.cast<Uint32>().value = _processMemoryCountersExSize; // cb
      if (memory(_process, _memoryCounters, _processMemoryCountersExSize) !=
          0) {
        privateBytes =
            (_memoryCounters + _privateUsageOffset).cast<IntPtr>().value;
        workingSetBytes =
            (_memoryCounters + _workingSetOffset).cast<IntPtr>().value;
      }
    }
    return ProcessCounters(
      gdiObjects: gdi,
      userObjects: user,
      handles: handles,
      privateBytes: privateBytes,
      workingSetBytes: workingSetBytes,
    );
  }

  /// A snapshot, or an all-null one where the counters are unavailable, so a
  /// caller never has to branch on the platform.
  static ProcessCounters sampleOrEmpty() =>
      tryBind()?.sample() ?? const ProcessCounters.unavailable();
}

/// The counters at one instant. Null means "not measurable here", never zero.
final class ProcessCounters {
  const ProcessCounters({
    required this.gdiObjects,
    required this.userObjects,
    required this.handles,
    required this.privateBytes,
    required this.workingSetBytes,
  });

  const ProcessCounters.unavailable()
      : gdiObjects = null,
        userObjects = null,
        handles = null,
        privateBytes = null,
        workingSetBytes = null;

  final int? gdiObjects;
  final int? userObjects;
  final int? handles;
  final int? privateBytes;
  final int? workingSetBytes;

  /// The named counters, in report order.
  Map<String, int?> get byName => <String, int?>{
        'gdi objects': gdiObjects,
        'user objects': userObjects,
        'kernel handles': handles,
        'private bytes': privateBytes,
        'working set': workingSetBytes,
      };

  @override
  String toString() => byName.entries
      .map((MapEntry<String, int?> e) => '${e.key}=${e.value ?? '-'}')
      .join(' ');
}

/// Zeroed native memory for the probe's own scratch buffers.
///
/// Deliberately not [NativeAllocator]: this file measures that allocator, and a
/// probe that allocated through the thing it counts would add one block to
/// every reading it took.
Pointer<Uint8> calloc(int byteCount) {
  final DynamicLibrary source = Platform.isWindows
      ? DynamicLibrary.open('ole32.dll')
      : DynamicLibrary.process();
  final Pointer<Void> Function(int) allocate = Platform.isWindows
      ? source.lookupFunction<Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)>('CoTaskMemAlloc')
      : source.lookupFunction<Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)>('malloc');
  final Pointer<Uint8> block = allocate(byteCount).cast<Uint8>();
  block.asTypedList(byteCount).fillRange(0, byteCount, 0);
  return block;
}
