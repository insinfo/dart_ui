/// Opening the DLLs the Direct2D backend needs, and binding their exports.
///
/// Three libraries, each with a stated reason:
///
///   * `d2d1.dll` - `D2D1CreateFactory`, the single entry point the whole API
///     hangs off. Shipped with every Windows since 7.
///   * `gdi32.dll` - `CreateDIBSection` and friends. Only the offscreen
///     readback surface uses them: a DC render target bound to a DIB section
///     is the one Direct2D target whose pixels the CPU can read back without
///     involving WIC or a Direct3D staging texture, and readable pixels are
///     what golden tests are made of.
///   * `kernel32.dll` - the process heap, for the same zeroing-allocator
///     `d3d12_library.dart` builds and for the same reason: this framework
///     carries no `package:ffi` dependency, and Direct2D structures have
///     fields this backend never sets that must be zero.
///
/// ## A missing library is data, not an exception
///
/// The rule `win32_api.dart` states and `d3d12_library.dart` follows: every
/// failure comes back as a [BackendDiagnostic] naming what was missing, so a
/// probe report can tell "this machine has no Direct2D" apart from a bug.
library;

import 'dart:ffi';

import '../../../foundation/diagnostics.dart';
import '../d3d12/d3d12_com.dart';
import 'd2d1_structs.dart';

/// `D2D1CreateFactory`.
typedef _CreateFactoryNative = Int32 Function(
  Uint32 factoryType,
  Pointer<Guid> riid,
  Pointer<Void> factoryOptions,
  Pointer<Pointer<Void>> factory,
);

typedef D2d1CreateFactoryDart = int Function(
  int factoryType,
  Pointer<Guid> riid,
  Pointer<Void> factoryOptions,
  Pointer<Pointer<Void>> factory,
);

/// The interface identifiers this backend asks for, in the textual form the
/// headers document, parsed by [writeGuid] so a transcription error fails at
/// the constant instead of as `E_NOINTERFACE` hours later.
abstract final class D2d1Iids {
  static const String factory = '06152247-6f50-465a-9245-118bfd3b6007';
}

/// [hresultText], extended with the Direct2D codes that table does not know.
String d2dHresultText(int hr) {
  final String? name = d2dHresultNames[hr.toUnsigned(32)];
  if (name == null) return hresultText(hr);
  final String hex =
      '0x${hr.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase()}';
  return '$hex ($name)';
}

/// What [D2d1Library.open] found, whether or not it succeeded.
final class D2d1LibraryLoad {
  const D2d1LibraryLoad({required this.library, required this.diagnostics});

  /// Null when a required DLL or export was missing; [diagnostics] says which.
  final D2d1Library? library;

  final List<BackendDiagnostic> diagnostics;

  bool get isLoaded => library != null;
}

/// The bound entry points, loaded once per process.
final class D2d1Library {
  D2d1Library._({
    required DynamicLibrary d2d1,
    required DynamicLibrary gdi32,
    required DynamicLibrary kernel32,
  }) {
    createFactory =
        d2d1.lookupFunction<_CreateFactoryNative, D2d1CreateFactoryDart>(
            'D2D1CreateFactory');

    createCompatibleDc = gdi32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('CreateCompatibleDC');
    createDibSection = gdi32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Win32BitmapInfoHeader>,
            Uint32, Pointer<Pointer<Void>>, Pointer<Void>, Uint32),
        Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Win32BitmapInfoHeader>,
            int,
            Pointer<Pointer<Void>>,
            Pointer<Void>,
            int)>('CreateDIBSection');
    selectObject = gdi32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>('SelectObject');
    deleteObject = gdi32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('DeleteObject');
    deleteDc = gdi32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('DeleteDC');
    gdiFlush =
        gdi32.lookupFunction<Int32 Function(), int Function()>('GdiFlush');

    final int Function() getProcessHeap = kernel32
        .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
    final Pointer<Void> Function(int, int, int) heapAlloc =
        kernel32.lookupFunction<Pointer<Void> Function(IntPtr, Uint32, IntPtr),
            Pointer<Void> Function(int, int, int)>('HeapAlloc');
    final int Function(int, int, Pointer<Void>) heapFree =
        kernel32.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>),
            int Function(int, int, Pointer<Void>)>('HeapFree');
    allocator = _ProcessHeapAllocator(getProcessHeap(), heapAlloc, heapFree);
  }

  static D2d1LibraryLoad? _cached;

  /// Loads and binds, or names what stopped it.
  ///
  /// Cached like `Win32Api.load`, because selection probes every backend and
  /// reopening DLLs per probe is work nobody asked for.
  static D2d1LibraryLoad open() {
    final D2d1LibraryLoad? cached = _cached;
    if (cached != null) return cached;
    final D2d1LibraryLoad result = _open();
    _cached = result;
    return result;
  }

  /// Drops the cache. Only for tests that want a fresh load.
  static void debugResetCache() => _cached = null;

  static D2d1LibraryLoad _open() {
    final DynamicLibrary d2d1;
    try {
      d2d1 = DynamicLibrary.open('d2d1.dll');
    } on Object catch (error) {
      return D2d1LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'd2d1.dll',
            detail: '$error. Direct2D shipped with Windows 7; a machine '
                'without it has no Direct2D at all and the CPU presenter is '
                'the answer, not a retry',
          ),
        ],
      );
    }

    final DynamicLibrary gdi32;
    final DynamicLibrary kernel32;
    try {
      gdi32 = DynamicLibrary.open('gdi32.dll');
      kernel32 = DynamicLibrary.open('kernel32.dll');
    } on Object catch (error) {
      return D2d1LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'gdi32.dll / kernel32.dll',
            detail: '$error',
          ),
        ],
      );
    }

    try {
      return D2d1LibraryLoad(
        library: D2d1Library._(d2d1: d2d1, gdi32: gdi32, kernel32: kernel32),
        diagnostics: const <BackendDiagnostic>[],
      );
    } on ArgumentError catch (error) {
      return D2d1LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingSymbol(
            '$error',
            detail: 'a required export was absent from d2d1.dll, gdi32.dll '
                'or kernel32.dll',
          ),
        ],
      );
    }
  }

  late final D2d1CreateFactoryDart createFactory;

  // GDI, for the offscreen readback surface only.
  late final Pointer<Void> Function(Pointer<Void>) createCompatibleDc;
  late final Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Win32BitmapInfoHeader>,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Void>,
      int) createDibSection;
  late final Pointer<Void> Function(Pointer<Void>, Pointer<Void>) selectObject;
  late final int Function(Pointer<Void>) deleteObject;
  late final int Function(Pointer<Void>) deleteDc;
  late final int Function() gdiFlush;

  /// Zeroing scratch memory for the structures handed across the ABI. See
  /// `d3d12_library.dart` for why the process heap and why zeroed.
  late final Allocator allocator;
}

/// `HEAP_ZERO_MEMORY`.
const int _heapZeroMemory = 0x00000008;

final class _ProcessHeapAllocator implements Allocator {
  const _ProcessHeapAllocator(this._heap, this._alloc, this._free);

  final int _heap;
  final Pointer<Void> Function(int, int, int) _alloc;
  final int Function(int, int, Pointer<Void>) _free;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final Pointer<Void> pointer = _alloc(_heap, _heapZeroMemory, byteCount);
    if (pointer == nullptr) {
      throw StateError('HeapAlloc failed for $byteCount bytes');
    }
    return pointer.cast<T>();
  }

  @override
  void free(Pointer<NativeType> pointer) {
    if (pointer == nullptr) return;
    _free(_heap, 0, pointer.cast<Void>());
  }
}
