/// Opening the four DLLs this backend needs, and binding their exports.
///
/// Two of them are the API, one is the compiler and one is the kernel:
///
///   * `d3d12.dll` - `D3D12CreateDevice`, plus the root-signature serialiser
///     and the debug-layer entry point;
///   * `dxgi.dll` - `CreateDXGIFactory2`, which is where the swap chain and
///     the adapter enumeration come from;
///   * `d3dcompiler_47.dll` - `D3DCompile`. Shipped in System32 on every
///     Windows 10 and 11, which is what makes runtime HLSL compilation a
///     reasonable choice for a pure-Dart framework; see [D3d12Library.open]
///     for what happens when it is missing;
///   * `kernel32.dll` - `CreateEventW` / `WaitForSingleObject` /
///     `CloseHandle`. A fence is waited on through an event object, and there
///     is no way to do that without the kernel.
///
/// ## A missing library is data, not an exception
///
/// The rule `win32_api.dart` states and this file follows: every failure comes
/// back as a [BackendDiagnostic] naming what was missing. A machine without
/// Direct3D 12 - a Windows 8, a container, a virtual machine whose adapter
/// exposes only WDDM 1.3 - has to be told apart from a bug in this code, and a
/// thrown `ArgumentError` from `lookupFunction` tells nobody anything.
///
/// `d3dcompiler_47.dll` is treated as *required*, not optional, and that is a
/// decision worth stating: this backend compiles its HLSL at device creation
/// rather than embedding DXBC, because embedding bytecode would mean either
/// checking a binary blob into the repository or requiring the Windows SDK's
/// `fxc` to build a pure-Dart framework. The cost is that a machine without
/// the compiler DLL gets no Direct3D 12 backend at all, and says so by name.
library;

import 'dart:ffi';

import '../../../foundation/diagnostics.dart';
import 'd3d12_com.dart';

/// `D3D12CreateDevice`.
typedef _CreateDeviceNative = Int32 Function(
  Pointer<Void> adapter,
  Uint32 minimumFeatureLevel,
  Pointer<Guid> riid,
  Pointer<Pointer<Void>> device,
);

/// `D3D12GetDebugInterface`.
typedef _GetDebugInterfaceNative = Int32 Function(
  Pointer<Guid> riid,
  Pointer<Pointer<Void>> debug,
);

/// `D3D12SerializeRootSignature`.
typedef _SerializeRootSignatureNative = Int32 Function(
  Pointer<Void> rootSignature,
  Uint32 version,
  Pointer<Pointer<Void>> blob,
  Pointer<Pointer<Void>> errorBlob,
);

/// `CreateDXGIFactory2`.
typedef _CreateFactoryNative = Int32 Function(
  Uint32 flags,
  Pointer<Guid> riid,
  Pointer<Pointer<Void>> factory,
);

/// `D3DCompile`.
typedef _CompileNative = Int32 Function(
  Pointer<Uint8> source,
  IntPtr sourceSize,
  Pointer<Uint8> sourceName,
  Pointer<Void> defines,
  Pointer<Void> include,
  Pointer<Uint8> entryPoint,
  Pointer<Uint8> target,
  Uint32 flags1,
  Uint32 flags2,
  Pointer<Pointer<Void>> code,
  Pointer<Pointer<Void>> errors,
);

/// The interface identifiers this backend asks for, by name.
///
/// Written as strings and parsed by [writeGuid] rather than as byte literals,
/// because the SDK documents them in this form and a transcription error into
/// sixteen bytes is invisible on review.
abstract final class D3d12Iids {
  static const String device = '189819f1-1db6-4b57-be54-1821339b85f7';
  static const String debug = '344488b7-6846-474b-b989-f027448245e0';
  static const String infoQueue = '0742a90b-c387-483f-b946-30a7e4e61458';
  static const String commandQueue = '0ec870a6-5d7e-4c22-8cfc-5baae07616ed';
  static const String commandAllocator = '6102dee4-af59-4b09-b999-b44d73f09b24';
  static const String graphicsCommandList =
      '5b160d0f-ac1b-4185-8ba8-b3ae42a5a455';
  static const String descriptorHeap = '8efb471d-616c-4f49-90f7-127bb763fa51';
  static const String fence = '0a753dcf-c4d8-4b91-adf6-be5a60d95a76';
  static const String resource = '696442be-a72e-4059-bc79-5b5c98040fad';
  static const String rootSignature = 'c54a6b66-72df-4ee8-8be5-a946a1429214';
  static const String pipelineState = '765a30f3-f624-4c6f-a828-ace948622445';
  static const String dxgiFactory4 = '1bc6ea02-ef36-464f-bf0c-21ca39e5168a';
  static const String dxgiSwapChain3 = '94d99bdb-f1f8-4ab0-b236-7da0170edab1';
  static const String dxgiAdapter1 = '29038f61-3839-4626-91fd-086879011a05';
}

/// `WAIT_OBJECT_0` and `WAIT_TIMEOUT`, from `winbase.h`.
const int kWaitObject0 = 0;
const int kWaitTimeout = 258;

/// `INFINITE`.
const int kWaitInfinite = 0xFFFFFFFF;

/// What [D3d12Library.open] found, whether or not it succeeded.
final class D3d12LibraryLoad {
  const D3d12LibraryLoad({required this.library, required this.diagnostics});

  /// Null when a required DLL or export was missing; [diagnostics] says which.
  final D3d12Library? library;

  final List<BackendDiagnostic> diagnostics;

  bool get isLoaded => library != null;
}

/// The bound entry points, loaded once per process.
final class D3d12Library {
  D3d12Library._({
    required DynamicLibrary d3d12,
    required DynamicLibrary dxgi,
    required DynamicLibrary compiler,
    required DynamicLibrary kernel32,
  })  : _d3d12 = d3d12,
        _dxgi = dxgi,
        _compiler = compiler,
        _kernel32 = kernel32 {
    createDevice =
        _d3d12.lookupFunction<_CreateDeviceNative, D3d12CreateDeviceDart>(
            'D3D12CreateDevice');
    serializeRootSignature = _d3d12.lookupFunction<
        _SerializeRootSignatureNative,
        D3d12SerializeRootSignatureDart>('D3D12SerializeRootSignature');
    createFactory2 =
        _dxgi.lookupFunction<_CreateFactoryNative, D3d12CreateFactoryDart>(
            'CreateDXGIFactory2');
    compile = _compiler
        .lookupFunction<_CompileNative, D3d12CompileDart>('D3DCompile');
    createEventW = _kernel32.lookupFunction<
        IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Uint16>),
        int Function(Pointer<Void>, int, int, Pointer<Uint16>)>('CreateEventW');
    waitForSingleObject = _kernel32.lookupFunction<
        Uint32 Function(IntPtr, Uint32),
        int Function(int, int)>('WaitForSingleObject');
    closeHandle =
        _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle');
    final int Function() getProcessHeap = _kernel32
        .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
    final Pointer<Void> Function(int, int, int) heapAlloc =
        _kernel32.lookupFunction<Pointer<Void> Function(IntPtr, Uint32, IntPtr),
            Pointer<Void> Function(int, int, int)>('HeapAlloc');
    final int Function(int, int, Pointer<Void>) heapFree =
        _kernel32.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>),
            int Function(int, int, Pointer<Void>)>('HeapFree');
    allocator = _ProcessHeapAllocator(getProcessHeap(), heapAlloc, heapFree);

    // Optional: the debug layer lives in `d3d12sdklayers.dll`, which is part
    // of the "Graphics Tools" optional feature rather than the base OS. The
    // *export* exists in d3d12.dll either way, so this lookup all but always
    // succeeds and the failure surfaces later as a
    // DXGI_ERROR_SDK_COMPONENT_MISSING from the call - see
    // `D3d12DebugLayer.enable`.
    try {
      getDebugInterface = _d3d12.lookupFunction<_GetDebugInterfaceNative,
          D3d12GetDebugInterfaceDart>('D3D12GetDebugInterface');
    } on ArgumentError {
      getDebugInterface = null;
    }
  }

  final DynamicLibrary _d3d12;
  final DynamicLibrary _dxgi;
  final DynamicLibrary _compiler;
  final DynamicLibrary _kernel32;

  static D3d12LibraryLoad? _cached;

  /// Loads and binds, or names what stopped it.
  ///
  /// Cached like `Win32Api.load` is, and for the same reason: a selection
  /// policy probes every backend, and reopening four DLLs per probe is work
  /// nobody asked for.
  static D3d12LibraryLoad open() {
    final D3d12LibraryLoad? cached = _cached;
    if (cached != null) return cached;
    final D3d12LibraryLoad result = _open();
    _cached = result;
    return result;
  }

  /// Drops the cache. Only for tests that want a fresh load.
  static void debugResetCache() => _cached = null;

  static D3d12LibraryLoad _open() {
    DynamicLibrary d3d12;
    DynamicLibrary dxgi;
    try {
      d3d12 = DynamicLibrary.open('d3d12.dll');
      dxgi = DynamicLibrary.open('dxgi.dll');
    } on Object catch (error) {
      return D3d12LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'd3d12.dll / dxgi.dll',
            detail: '$error. Direct3D 12 shipped with Windows 10; a machine '
                'without these has no Direct3D 12 at all and the CPU or '
                'OpenGL backend is the answer, not a retry',
          ),
        ],
      );
    }

    final DynamicLibrary compiler;
    try {
      compiler = DynamicLibrary.open('d3dcompiler_47.dll');
    } on Object catch (error) {
      return D3d12LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'd3dcompiler_47.dll',
            detail: '$error. This backend compiles its HLSL at device '
                'creation rather than embedding DXBC bytecode, so the '
                'compiler is required and not optional; see the library '
                'comment of d3d12_library.dart for why that trade was made',
          ),
        ],
      );
    }

    final DynamicLibrary kernel32;
    try {
      kernel32 = DynamicLibrary.open('kernel32.dll');
    } on Object catch (error) {
      return D3d12LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary('kernel32.dll', detail: '$error'),
        ],
      );
    }

    try {
      return D3d12LibraryLoad(
        library: D3d12Library._(
          d3d12: d3d12,
          dxgi: dxgi,
          compiler: compiler,
          kernel32: kernel32,
        ),
        diagnostics: const <BackendDiagnostic>[],
      );
    } on ArgumentError catch (error) {
      return D3d12LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingSymbol(
            '$error',
            detail: 'a required export was absent from one of d3d12.dll, '
                'dxgi.dll, d3dcompiler_47.dll or kernel32.dll',
          ),
        ],
      );
    }
  }

  late final D3d12CreateDeviceDart createDevice;
  late final D3d12SerializeRootSignatureDart serializeRootSignature;
  late final D3d12CreateFactoryDart createFactory2;
  late final D3d12CompileDart compile;

  /// Null when `d3d12.dll` does not export it, which should not happen on any
  /// Windows that has the DLL at all.
  D3d12GetDebugInterfaceDart? getDebugInterface;

  late final int Function(Pointer<Void>, int, int, Pointer<Uint16>)
      createEventW;
  late final int Function(int, int) waitForSingleObject;
  late final int Function(int) closeHandle;

  /// Zeroing scratch memory for the structures handed across the ABI.
  ///
  /// The process heap rather than `malloc`, for the reason `win32_api.dart`
  /// gives: this framework has no `package:ffi` dependency, and a windowing or
  /// rendering backend is not the place to add one. `HEAP_ZERO_MEMORY` is not
  /// a convenience here - a Direct3D structure has fields this renderer never
  /// sets, and every one of them has to be zero or the runtime reads garbage
  /// out of a field whose enumeration has no zero-is-invalid rule.
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

typedef D3d12CreateDeviceDart = int Function(
  Pointer<Void> adapter,
  int minimumFeatureLevel,
  Pointer<Guid> riid,
  Pointer<Pointer<Void>> device,
);

typedef D3d12GetDebugInterfaceDart = int Function(
  Pointer<Guid> riid,
  Pointer<Pointer<Void>> debug,
);

typedef D3d12SerializeRootSignatureDart = int Function(
  Pointer<Void> rootSignature,
  int version,
  Pointer<Pointer<Void>> blob,
  Pointer<Pointer<Void>> errorBlob,
);

typedef D3d12CreateFactoryDart = int Function(
  int flags,
  Pointer<Guid> riid,
  Pointer<Pointer<Void>> factory,
);

typedef D3d12CompileDart = int Function(
  Pointer<Uint8> source,
  int sourceSize,
  Pointer<Uint8> sourceName,
  Pointer<Void> defines,
  Pointer<Void> include,
  Pointer<Uint8> entryPoint,
  Pointer<Uint8> target,
  int flags1,
  int flags2,
  Pointer<Pointer<Void>> code,
  Pointer<Pointer<Void>> errors,
);
