/// Direct3D 11 and DXGI, as vtable slots and constants.
///
/// The counterpart of `gl_bindings.dart`, and the same rules apply: only the
/// entry points this renderer calls, every constant written out as the value
/// the SDK header gives it, and nothing that throws during a probe.
///
/// ## Why an interface is a class of `late final` bound methods
///
/// A COM method call is two dereferences and an indirect call. Doing the
/// dereferences per call would cost a pointer chase and an `asFunction` cast
/// inside the draw loop, which runs once per batch. So each interface below
/// binds its methods once, in `late final` fields, and the draw loop calls
/// plain Dart functions. The slot numbers are constants next to the field so a
/// miscount is visible in review rather than at run time - a wrong slot calls
/// whatever method happens to live there, which for `ID3D11DeviceContext` is
/// almost always another `void` method with a compatible-looking signature and
/// therefore does not crash. It draws nothing, silently.
///
/// The inheritance arithmetic is written out for the same reason. `IUnknown`
/// owns slots 0-2, so an interface that derives from it starts at 3;
/// `ID3D11DeviceChild` adds four, so `ID3D11DeviceContext` starts at 7;
/// `IDXGIObject` adds four and `IDXGIDeviceSubObject` one, so
/// `IDXGISwapChain` starts at 8.
///
/// ## Why the signatures come in pairs, and why only one half is public
///
/// Every bound method needs two type aliases: a `_Native…` one spelling the C
/// ABI with `dart:ffi`'s marker types (`Int32`, `IntPtr`, `Uint32`), and a
/// `…Fn` one spelling the Dart signature that `asFunction` produces. The native
/// half appears only inside a `comMethod<…>` type argument, which is an
/// expression, so it stays private. The Dart half is the declared type of a
/// public field and therefore has to be public too - a private type in a public
/// API is exactly what `library_private_types_in_public_api` flags, and the
/// analyzer is right: a caller that wants to hold `D3d11Device.createTexture2D`
/// in a variable has no way to name its type otherwise.
library;

import 'dart:ffi';

import '../../../ffi/com.dart';
import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// `D3D11_SDK_VERSION`. A build-time constant of the SDK, not a runtime
/// version: passing anything else makes `D3D11CreateDevice` return
/// `E_INVALIDARG` with no further explanation.
const int d3d11SdkVersion = 7;

const int d3dDriverTypeUnknown = 0;
const int d3dDriverTypeHardware = 1;
const int d3dDriverTypeReference = 2;
const int d3dDriverTypeSoftware = 3;
const int d3dDriverTypeWarp = 5;

/// Feature levels, most capable first, the order `D3D11CreateDevice` wants.
///
/// 11.1 is listed separately because it is the one that fails *by being
/// listed*: a machine whose D3D11 runtime predates 11.1 answers `E_INVALIDARG`
/// for the whole array rather than skipping the entry, so the create is
/// retried without it. Every other level degrades silently, which is the
/// behaviour the API documents.
const int d3dFeatureLevel11_1 = 0xb100;
const int d3dFeatureLevel11_0 = 0xb000;
const int d3dFeatureLevel10_1 = 0xa100;
const int d3dFeatureLevel10_0 = 0xa000;

/// The levels this renderer accepts, and the floor is deliberate: the shader
/// profiles it compiles are `vs_4_0`/`ps_4_0`, which is exactly feature level
/// 10.0. A 9.x device would need `vs_4_0_level_9_1`, a different constant
/// buffer layout and no `uint` in the shader, and claiming support for it
/// without any of that would produce a device that creates and then fails to
/// compile.
const List<int> kD3d11FeatureLevels = <int>[
  d3dFeatureLevel11_1,
  d3dFeatureLevel11_0,
  d3dFeatureLevel10_1,
  d3dFeatureLevel10_0,
];

String d3dFeatureLevelName(int level) => switch (level) {
      d3dFeatureLevel11_1 => '11_1',
      d3dFeatureLevel11_0 => '11_0',
      d3dFeatureLevel10_1 => '10_1',
      d3dFeatureLevel10_0 => '10_0',
      _ => '0x${level.toRadixString(16)}',
    };

/// `D3D11_CREATE_DEVICE_BGRA_SUPPORT`. Required for interop with Direct2D and
/// for a `B8G8R8A8_UNORM` swap chain to be usable everywhere.
const int d3d11CreateDeviceBgraSupport = 0x20;
const int d3d11CreateDeviceDebug = 0x2;

const int dxgiFormatUnknown = 0;
const int dxgiFormatR32G32B32A32Float = 2;
const int dxgiFormatR32G32Float = 16;
const int dxgiFormatR8G8B8A8Unorm = 28;
const int dxgiFormatR32Uint = 42;
const int dxgiFormatR8Unorm = 61;
const int dxgiFormatB8G8R8A8Unorm = 87;

const int d3d11UsageDefault = 0;
const int d3d11UsageImmutable = 1;
const int d3d11UsageDynamic = 2;
const int d3d11UsageStaging = 3;

const int d3d11BindVertexBuffer = 0x1;
const int d3d11BindIndexBuffer = 0x2;
const int d3d11BindConstantBuffer = 0x4;
const int d3d11BindShaderResource = 0x8;
const int d3d11BindRenderTarget = 0x20;

const int d3d11CpuAccessWrite = 0x10000;
const int d3d11CpuAccessRead = 0x20000;

const int d3d11MapRead = 1;
const int d3d11MapWrite = 2;
const int d3d11MapReadWrite = 3;
const int d3d11MapWriteDiscard = 4;
const int d3d11MapWriteNoOverwrite = 5;

const int d3d11PrimitiveTopologyTriangleList = 4;

const int d3d11FillSolid = 3;
const int d3d11CullNone = 1;

const int d3d11BlendZero = 1;
const int d3d11BlendOne = 2;
const int d3d11BlendInvSrcAlpha = 6;
const int d3d11BlendOpAdd = 1;
const int d3d11ColorWriteEnableAll = 15;

const int d3d11FilterMinMagMipPoint = 0;
const int d3d11FilterMinMagMipLinear = 0x15;
const int d3d11TextureAddressClamp = 3;
const int d3d11ComparisonNever = 1;

const int d3d11InputPerVertexData = 0;

const int dxgiUsageRenderTargetOutput = 0x20;
const int dxgiScalingStretch = 0;
const int dxgiScalingNone = 1;
const int dxgiSwapEffectDiscard = 0;
const int dxgiSwapEffectSequential = 1;
const int dxgiSwapEffectFlipSequential = 3;
const int dxgiSwapEffectFlipDiscard = 4;
const int dxgiAlphaModeUnspecified = 0;
const int dxgiAlphaModeIgnore = 3;

/// `D3DCOMPILE_*`. See `d3d11_shaders.dart` for why row-major packing is asked
/// for explicitly rather than left at the HLSL default.
const int d3dCompilePackMatrixRowMajor = 1 << 3;
const int d3dCompileEnableStrictness = 1 << 11;
const int d3dCompileOptimizationLevel3 = 1 << 15;

// Interface identifiers. Each is the value in the SDK header; see
// `Guid.parse`'s comment for why they are written in canonical text.
final Guid iidId3d11Texture2D =
    Guid.parse('6f15aaf2-d208-4e89-9ab4-489535d34f9c');
final Guid iidIdxgiDevice = Guid.parse('54ec77fa-1377-44e6-8c32-88fd5f44c84c');
final Guid iidIdxgiAdapter = Guid.parse('2411e7e1-12ac-4ccf-bd14-9798e8534dc9');
final Guid iidIdxgiFactory2 =
    Guid.parse('50c83a1c-e072-4c48-87b0-3630fa36a6d0');
final Guid iidId3d11Device = Guid.parse('db6f6ddb-ac77-4e88-8253-819df9bbf140');

// ---------------------------------------------------------------------------
// Struct sizes and field offsets
// ---------------------------------------------------------------------------
//
// Written as byte offsets rather than as `Struct` subclasses on purpose. A
// `Struct` would be more readable for five of these and worse for the rest:
// `D3D11_BLEND_DESC` is an eight-element array of another struct, and
// `D3D11_INPUT_ELEMENT_DESC` is used as an array too, both of which are
// awkward in `dart:ffi` and neither of which gains any checking from being
// declared - the layout is fixed by the C ABI either way and a wrong offset is
// wrong in both spellings. Keeping them here as constants means the whole
// layout of a descriptor is visible in one screen next to the call that fills
// it.

/// `D3D11_TEXTURE2D_DESC`: 11 `UINT`s, no padding.
const int sizeOfTexture2DDesc = 44;

/// `D3D11_BUFFER_DESC`: 6 `UINT`s.
const int sizeOfBufferDesc = 24;

/// `D3D11_SUBRESOURCE_DATA`: a pointer then two `UINT`s, padded to 16 on x64.
const int sizeOfSubresourceData = 16;

/// `D3D11_MAPPED_SUBRESOURCE`: a pointer then two `UINT`s.
const int sizeOfMappedSubresource = 16;

/// `D3D11_BOX`: 6 `UINT`s.
const int sizeOfBox = 24;

/// `D3D11_VIEWPORT`: 6 `FLOAT`s.
const int sizeOfViewport = 24;

/// `D3D11_RECT` / `RECT`: 4 `LONG`s.
const int sizeOfRect = 16;

/// `D3D11_RASTERIZER_DESC`: 10 fields of 4 bytes.
const int sizeOfRasterizerDesc = 40;

/// `D3D11_RENDER_TARGET_BLEND_DESC`: 7 enums plus a `UINT8` padded to 4.
const int sizeOfRenderTargetBlendDesc = 32;

/// `D3D11_BLEND_DESC`: two `BOOL`s then eight render-target descriptors.
const int sizeOfBlendDesc = 8 + 8 * sizeOfRenderTargetBlendDesc;

/// `D3D11_SAMPLER_DESC`: 5 enums, 2 floats-and-ints, a 4-float border, 2
/// floats.
const int sizeOfSamplerDesc = 52;

/// `D3D11_INPUT_ELEMENT_DESC`: an `LPCSTR` then six 4-byte fields, aligned to
/// the pointer.
const int sizeOfInputElementDesc = 32;

/// `DXGI_SWAP_CHAIN_DESC1`.
const int sizeOfSwapChainDesc1 = 48;

/// `DXGI_ADAPTER_DESC`: a 128-`WCHAR` description, four `UINT`s, three
/// `SIZE_T`s and a `LUID`.
const int sizeOfAdapterDesc = 304;

// ---------------------------------------------------------------------------
// Library loading
// ---------------------------------------------------------------------------

/// What [D3d11Libraries.open] found on this machine.
final class D3d11LibraryLoad {
  const D3d11LibraryLoad(this.libraries, this.diagnostics);

  /// Null when `d3d11.dll` or `dxgi.dll` was not loadable, which is what a
  /// non-Windows machine and a Windows install without a graphics stack both
  /// look like from here.
  final D3d11Libraries? libraries;

  final List<BackendDiagnostic> diagnostics;

  bool get isLoaded => libraries != null;
}

/// The three DLLs, two required and one not.
final class D3d11Libraries {
  D3d11Libraries._(this.d3d11, this.dxgi, this.compiler);

  final DynamicLibrary d3d11;
  final DynamicLibrary dxgi;

  /// `d3dcompiler_47.dll`, or null.
  ///
  /// Optional in the loader and required by the device, which is not a
  /// contradiction: a probe has to be able to *report* that the compiler is
  /// missing, and it cannot report what the loader threw on. See
  /// `d3d11_shaders.dart` for why runtime compilation was chosen over embedded
  /// bytecode in the first place.
  final DynamicLibrary? compiler;

  static D3d11LibraryLoad? _cached;

  /// Loads the libraries, or names what stopped it. Cached: a selection policy
  /// probes every backend and reopening three DLLs per probe is wasted work.
  static D3d11LibraryLoad open() {
    final cached = _cached;
    if (cached != null) return cached;

    final diagnostics = <BackendDiagnostic>[];
    DynamicLibrary d3d11;
    DynamicLibrary dxgi;
    try {
      d3d11 = DynamicLibrary.open('d3d11.dll');
      dxgi = DynamicLibrary.open('dxgi.dll');
    } on Object catch (error) {
      final result = D3d11LibraryLoad(
        null,
        <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'd3d11.dll / dxgi.dll',
            detail: '$error',
          ),
        ],
      );
      return _cached = result;
    }

    DynamicLibrary? compiler;
    try {
      compiler = DynamicLibrary.open('d3dcompiler_47.dll');
    } on Object catch (error) {
      diagnostics.add(
        BackendDiagnostic.missingLibrary(
          'd3dcompiler_47.dll',
          detail: 'HLSL is compiled at device creation, so without this DLL '
              'the backend has no shaders and refuses to open a device. It '
              'ships with Windows 8.1 and later in System32; on an older '
              'machine it comes with the DirectX end-user runtime. '
              'Loader said: $error',
        ),
      );
    }

    return _cached = D3d11LibraryLoad(
      D3d11Libraries._(d3d11, dxgi, compiler),
      diagnostics,
    );
  }

  /// Drops the cache. Only for tests that want to observe a fresh load.
  static void debugResetCache() => _cached = null;
}

typedef _NativeD3d11CreateDevice = Int32 Function(
  Pointer<Void> adapter,
  Uint32 driverType,
  Pointer<Void> software,
  Uint32 flags,
  Pointer<Uint32> featureLevels,
  Uint32 featureLevelCount,
  Uint32 sdkVersion,
  Pointer<Pointer<Void>> device,
  Pointer<Uint32> selectedFeatureLevel,
  Pointer<Pointer<Void>> immediateContext,
);
typedef D3d11CreateDeviceFn = int Function(
  Pointer<Void> adapter,
  int driverType,
  Pointer<Void> software,
  int flags,
  Pointer<Uint32> featureLevels,
  int featureLevelCount,
  int sdkVersion,
  Pointer<Pointer<Void>> device,
  Pointer<Uint32> selectedFeatureLevel,
  Pointer<Pointer<Void>> immediateContext,
);

typedef _NativeCreateDxgiFactory1 = Int32 Function(
    Pointer<Uint8> riid, Pointer<Pointer<Void>> factory);
typedef CreateDxgiFactory1Fn = int Function(
    Pointer<Uint8> riid, Pointer<Pointer<Void>> factory);

typedef _NativeD3dCompile = Int32 Function(
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
typedef D3dCompileFn = int Function(
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

/// The free functions: device creation, factory creation, shader compilation.
final class D3d11Api {
  D3d11Api(this.libraries)
      : createDevice = libraries.d3d11
            .lookupFunction<_NativeD3d11CreateDevice, D3d11CreateDeviceFn>(
                'D3D11CreateDevice'),
        createFactory1 = libraries.dxgi
            .lookupFunction<_NativeCreateDxgiFactory1, CreateDxgiFactory1Fn>(
                'CreateDXGIFactory1'),
        compile = libraries.compiler
            ?.lookupFunction<_NativeD3dCompile, D3dCompileFn>('D3DCompile');

  final D3d11Libraries libraries;
  final D3d11CreateDeviceFn createDevice;
  final CreateDxgiFactory1Fn createFactory1;

  /// Null when `d3dcompiler_47.dll` was not loadable.
  final D3dCompileFn? compile;
}

// ---------------------------------------------------------------------------
// ID3D11Device
// ---------------------------------------------------------------------------

typedef _NativeCreate3 = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef Create3Fn = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);

typedef _NativeCreate2 = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef Create2Fn = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);

typedef _NativeCreateShader = Int32 Function(Pointer<Void>, Pointer<Void>,
    IntPtr, Pointer<Void>, Pointer<Pointer<Void>>);
typedef CreateShaderFn = int Function(
    Pointer<Void>, Pointer<Void>, int, Pointer<Void>, Pointer<Pointer<Void>>);

typedef _NativeCreateInputLayout = Int32 Function(Pointer<Void>, Pointer<Void>,
    Uint32, Pointer<Void>, IntPtr, Pointer<Pointer<Void>>);
typedef CreateInputLayoutFn = int Function(Pointer<Void>, Pointer<Void>, int,
    Pointer<Void>, int, Pointer<Pointer<Void>>);

typedef _NativeUint32Getter = Uint32 Function(Pointer<Void>);
typedef Uint32GetterFn = int Function(Pointer<Void>);

typedef _NativeInt32Getter = Int32 Function(Pointer<Void>);
typedef Int32GetterFn = int Function(Pointer<Void>);

typedef _NativeVoidOut = Void Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef VoidOutFn = void Function(Pointer<Void>, Pointer<Pointer<Void>>);

/// `ID3D11Device`, deriving from `IUnknown` (slots 0-2).
final class D3d11Device extends ComObject {
  D3d11Device(super.pointer) : super(interfaceName: 'ID3D11Device');

  static const int _slotCreateBuffer = 3;
  static const int _slotCreateTexture2D = 5;
  static const int _slotCreateShaderResourceView = 7;
  static const int _slotCreateRenderTargetView = 9;
  static const int _slotCreateInputLayout = 11;
  static const int _slotCreateVertexShader = 12;
  static const int _slotCreatePixelShader = 15;
  static const int _slotCreateBlendState = 20;
  static const int _slotCreateRasterizerState = 22;
  static const int _slotCreateSamplerState = 23;
  static const int _slotGetFeatureLevel = 37;
  static const int _slotGetDeviceRemovedReason = 39;
  static const int _slotGetImmediateContext = 40;

  late final Create3Fn createBuffer =
      comMethod<_NativeCreate3>(pointer, _slotCreateBuffer).asFunction();
  late final Create3Fn createTexture2D =
      comMethod<_NativeCreate3>(pointer, _slotCreateTexture2D).asFunction();
  late final Create3Fn createShaderResourceView =
      comMethod<_NativeCreate3>(pointer, _slotCreateShaderResourceView)
          .asFunction();
  late final Create3Fn createRenderTargetView =
      comMethod<_NativeCreate3>(pointer, _slotCreateRenderTargetView)
          .asFunction();
  late final CreateInputLayoutFn createInputLayout =
      comMethod<_NativeCreateInputLayout>(pointer, _slotCreateInputLayout)
          .asFunction();
  late final CreateShaderFn createVertexShader =
      comMethod<_NativeCreateShader>(pointer, _slotCreateVertexShader)
          .asFunction();
  late final CreateShaderFn createPixelShader =
      comMethod<_NativeCreateShader>(pointer, _slotCreatePixelShader)
          .asFunction();
  late final Create2Fn createBlendState =
      comMethod<_NativeCreate2>(pointer, _slotCreateBlendState).asFunction();
  late final Create2Fn createRasterizerState =
      comMethod<_NativeCreate2>(pointer, _slotCreateRasterizerState)
          .asFunction();
  late final Create2Fn createSamplerState =
      comMethod<_NativeCreate2>(pointer, _slotCreateSamplerState).asFunction();
  late final Uint32GetterFn getFeatureLevel =
      comMethod<_NativeUint32Getter>(pointer, _slotGetFeatureLevel)
          .asFunction();

  /// `GetDeviceRemovedReason`. `S_OK` while the device is alive; one of the
  /// `DXGI_ERROR_DEVICE_*` codes once it is not.
  ///
  /// The only reliable way to tell a device that was removed from one that
  /// merely failed a call: every subsequent call on a removed device fails
  /// too, with codes that describe the call rather than the removal.
  late final Int32GetterFn getDeviceRemovedReason =
      comMethod<_NativeInt32Getter>(pointer, _slotGetDeviceRemovedReason)
          .asFunction();

  late final VoidOutFn getImmediateContext =
      comMethod<_NativeVoidOut>(pointer, _slotGetImmediateContext).asFunction();
}

// ---------------------------------------------------------------------------
// ID3D11DeviceContext
// ---------------------------------------------------------------------------

typedef _NativeSetShader = Void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint32);
typedef SetShaderFn = void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, int);

typedef _NativeSetSlots = Void Function(
    Pointer<Void>, Uint32, Uint32, Pointer<Pointer<Void>>);
typedef SetSlotsFn = void Function(
    Pointer<Void>, int, int, Pointer<Pointer<Void>>);

typedef _NativeSetOne = Void Function(Pointer<Void>, Pointer<Void>);
typedef SetOneFn = void Function(Pointer<Void>, Pointer<Void>);

typedef _NativeSetUint = Void Function(Pointer<Void>, Uint32);
typedef SetUintFn = void Function(Pointer<Void>, int);

typedef _NativeSetArray = Void Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef SetArrayFn = void Function(Pointer<Void>, int, Pointer<Void>);

typedef _NativeMap = Int32 Function(
    Pointer<Void>, Pointer<Void>, Uint32, Uint32, Uint32, Pointer<Void>);
typedef MapFn = int Function(
    Pointer<Void>, Pointer<Void>, int, int, int, Pointer<Void>);

typedef _NativeUnmap = Void Function(Pointer<Void>, Pointer<Void>, Uint32);
typedef UnmapFn = void Function(Pointer<Void>, Pointer<Void>, int);

typedef _NativeUpdateSubresource = Void Function(Pointer<Void>, Pointer<Void>,
    Uint32, Pointer<Void>, Pointer<Void>, Uint32, Uint32);
typedef UpdateSubresourceFn = void Function(
    Pointer<Void>, Pointer<Void>, int, Pointer<Void>, Pointer<Void>, int, int);

typedef _NativeCopyResource = Void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef CopyResourceFn = void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef _NativeDrawIndexed = Void Function(
    Pointer<Void>, Uint32, Uint32, Int32);
typedef DrawIndexedFn = void Function(Pointer<Void>, int, int, int);

typedef _NativeSetVertexBuffers = Void Function(Pointer<Void>, Uint32, Uint32,
    Pointer<Pointer<Void>>, Pointer<Uint32>, Pointer<Uint32>);
typedef SetVertexBuffersFn = void Function(Pointer<Void>, int, int,
    Pointer<Pointer<Void>>, Pointer<Uint32>, Pointer<Uint32>);

typedef _NativeSetIndexBuffer = Void Function(
    Pointer<Void>, Pointer<Void>, Uint32, Uint32);
typedef SetIndexBufferFn = void Function(
    Pointer<Void>, Pointer<Void>, int, int);

typedef _NativeSetRenderTargets = Void Function(
    Pointer<Void>, Uint32, Pointer<Pointer<Void>>, Pointer<Void>);
typedef SetRenderTargetsFn = void Function(
    Pointer<Void>, int, Pointer<Pointer<Void>>, Pointer<Void>);

typedef _NativeSetBlendState = Void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Float>, Uint32);
typedef SetBlendStateFn = void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Float>, int);

typedef _NativeClearRtv = Void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Float>);
typedef ClearRtvFn = void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Float>);

typedef _NativeVoidNullary = Void Function(Pointer<Void>);
typedef VoidNullaryFn = void Function(Pointer<Void>);

/// `ID3D11DeviceContext`, deriving from `ID3D11DeviceChild` (slots 3-6), which
/// derives from `IUnknown` (0-2). Its own methods therefore start at 7.
final class D3d11DeviceContext extends ComObject {
  D3d11DeviceContext(super.pointer)
      : super(interfaceName: 'ID3D11DeviceContext');

  static const int _slotVsSetConstantBuffers = 7;
  static const int _slotPsSetShaderResources = 8;
  static const int _slotPsSetShader = 9;
  static const int _slotPsSetSamplers = 10;
  static const int _slotVsSetShader = 11;
  static const int _slotDrawIndexed = 12;
  static const int _slotMap = 14;
  static const int _slotUnmap = 15;
  static const int _slotPsSetConstantBuffers = 16;
  static const int _slotIaSetInputLayout = 17;
  static const int _slotIaSetVertexBuffers = 18;
  static const int _slotIaSetIndexBuffer = 19;
  static const int _slotIaSetPrimitiveTopology = 24;
  static const int _slotOmSetRenderTargets = 33;
  static const int _slotOmSetBlendState = 35;
  static const int _slotRsSetState = 43;
  static const int _slotRsSetViewports = 44;
  static const int _slotRsSetScissorRects = 45;
  static const int _slotCopyResource = 47;
  static const int _slotUpdateSubresource = 48;
  static const int _slotClearRenderTargetView = 50;
  static const int _slotFlush = 111;

  late final SetSlotsFn vsSetConstantBuffers =
      comMethod<_NativeSetSlots>(pointer, _slotVsSetConstantBuffers)
          .asFunction();
  late final SetSlotsFn psSetConstantBuffers =
      comMethod<_NativeSetSlots>(pointer, _slotPsSetConstantBuffers)
          .asFunction();
  late final SetSlotsFn psSetShaderResources =
      comMethod<_NativeSetSlots>(pointer, _slotPsSetShaderResources)
          .asFunction();
  late final SetSlotsFn psSetSamplers =
      comMethod<_NativeSetSlots>(pointer, _slotPsSetSamplers).asFunction();
  late final SetShaderFn psSetShader =
      comMethod<_NativeSetShader>(pointer, _slotPsSetShader).asFunction();
  late final SetShaderFn vsSetShader =
      comMethod<_NativeSetShader>(pointer, _slotVsSetShader).asFunction();
  late final DrawIndexedFn drawIndexed =
      comMethod<_NativeDrawIndexed>(pointer, _slotDrawIndexed).asFunction();
  late final MapFn map = comMethod<_NativeMap>(pointer, _slotMap).asFunction();
  late final UnmapFn unmap =
      comMethod<_NativeUnmap>(pointer, _slotUnmap).asFunction();
  late final SetOneFn iaSetInputLayout =
      comMethod<_NativeSetOne>(pointer, _slotIaSetInputLayout).asFunction();
  late final SetVertexBuffersFn iaSetVertexBuffers =
      comMethod<_NativeSetVertexBuffers>(pointer, _slotIaSetVertexBuffers)
          .asFunction();
  late final SetIndexBufferFn iaSetIndexBuffer =
      comMethod<_NativeSetIndexBuffer>(pointer, _slotIaSetIndexBuffer)
          .asFunction();
  late final SetUintFn iaSetPrimitiveTopology =
      comMethod<_NativeSetUint>(pointer, _slotIaSetPrimitiveTopology)
          .asFunction();
  late final SetRenderTargetsFn omSetRenderTargets =
      comMethod<_NativeSetRenderTargets>(pointer, _slotOmSetRenderTargets)
          .asFunction();
  late final SetBlendStateFn omSetBlendState =
      comMethod<_NativeSetBlendState>(pointer, _slotOmSetBlendState)
          .asFunction();
  late final SetOneFn rsSetState =
      comMethod<_NativeSetOne>(pointer, _slotRsSetState).asFunction();
  late final SetArrayFn rsSetViewports =
      comMethod<_NativeSetArray>(pointer, _slotRsSetViewports).asFunction();
  late final SetArrayFn rsSetScissorRects =
      comMethod<_NativeSetArray>(pointer, _slotRsSetScissorRects).asFunction();
  late final CopyResourceFn copyResource =
      comMethod<_NativeCopyResource>(pointer, _slotCopyResource).asFunction();
  late final UpdateSubresourceFn updateSubresource =
      comMethod<_NativeUpdateSubresource>(pointer, _slotUpdateSubresource)
          .asFunction();
  late final ClearRtvFn clearRenderTargetView =
      comMethod<_NativeClearRtv>(pointer, _slotClearRenderTargetView)
          .asFunction();
  late final VoidNullaryFn flush =
      comMethod<_NativeVoidNullary>(pointer, _slotFlush).asFunction();
}

// ---------------------------------------------------------------------------
// DXGI
// ---------------------------------------------------------------------------

typedef _NativeGetParent = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef GetParentFn = int Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);

typedef _NativeGetAdapter = Int32 Function(
    Pointer<Void>, Pointer<Pointer<Void>>);
typedef GetAdapterFn = int Function(Pointer<Void>, Pointer<Pointer<Void>>);

typedef _NativeGetDesc = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef GetDescFn = int Function(Pointer<Void>, Pointer<Void>);

typedef _NativeCreateSwapChainForHwnd = Int32 Function(
  Pointer<Void> self,
  Pointer<Void> device,
  IntPtr window,
  Pointer<Void> desc,
  Pointer<Void> fullscreenDesc,
  Pointer<Void> restrictToOutput,
  Pointer<Pointer<Void>> swapChain,
);
typedef CreateSwapChainForHwndFn = int Function(
  Pointer<Void> self,
  Pointer<Void> device,
  int window,
  Pointer<Void> desc,
  Pointer<Void> fullscreenDesc,
  Pointer<Void> restrictToOutput,
  Pointer<Pointer<Void>> swapChain,
);

typedef _NativeMakeWindowAssociation = Int32 Function(
    Pointer<Void>, IntPtr, Uint32);
typedef MakeWindowAssociationFn = int Function(Pointer<Void>, int, int);

/// `IDXGIDevice`: `IDXGIObject` (slots 3-6) over `IUnknown`, own methods at 7.
final class DxgiDevice extends ComObject {
  DxgiDevice(super.pointer) : super(interfaceName: 'IDXGIDevice');

  static const int _slotGetParent = 6;
  static const int _slotGetAdapter = 7;

  late final GetParentFn getParent =
      comMethod<_NativeGetParent>(pointer, _slotGetParent).asFunction();
  late final GetAdapterFn getAdapter =
      comMethod<_NativeGetAdapter>(pointer, _slotGetAdapter).asFunction();
}

/// `IDXGIAdapter`: `IDXGIObject` over `IUnknown`, own methods at 7.
final class DxgiAdapter extends ComObject {
  DxgiAdapter(super.pointer) : super(interfaceName: 'IDXGIAdapter');

  static const int _slotGetParent = 6;
  static const int _slotGetDesc = 8;

  late final GetParentFn getParent =
      comMethod<_NativeGetParent>(pointer, _slotGetParent).asFunction();
  late final GetDescFn getDesc =
      comMethod<_NativeGetDesc>(pointer, _slotGetDesc).asFunction();
}

/// `IDXGIFactory2`: `IDXGIFactory1` (12-13) over `IDXGIFactory` (7-11) over
/// `IDXGIObject` (3-6) over `IUnknown` (0-2). Own methods start at 14.
final class DxgiFactory2 extends ComObject {
  DxgiFactory2(super.pointer) : super(interfaceName: 'IDXGIFactory2');

  static const int _slotMakeWindowAssociation = 8;
  static const int _slotCreateSwapChainForHwnd = 15;

  /// `DXGI_MWA_NO_ALT_ENTER`. Without it DXGI installs its own message hook
  /// and turns Alt+Enter into a fullscreen transition behind the window
  /// owner's back, which is a behaviour change a UI framework must not make
  /// for its embedder.
  static const int noAltEnter = 1 << 1;

  late final MakeWindowAssociationFn makeWindowAssociation =
      comMethod<_NativeMakeWindowAssociation>(
              pointer, _slotMakeWindowAssociation)
          .asFunction();
  late final CreateSwapChainForHwndFn createSwapChainForHwnd =
      comMethod<_NativeCreateSwapChainForHwnd>(
              pointer, _slotCreateSwapChainForHwnd)
          .asFunction();
}

typedef _NativePresent = Int32 Function(Pointer<Void>, Uint32, Uint32);
typedef PresentFn = int Function(Pointer<Void>, int, int);

typedef _NativeGetBuffer = Int32 Function(
    Pointer<Void>, Uint32, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef GetBufferFn = int Function(
    Pointer<Void>, int, Pointer<Uint8>, Pointer<Pointer<Void>>);

typedef _NativeResizeBuffers = Int32 Function(
    Pointer<Void>, Uint32, Uint32, Uint32, Uint32, Uint32);
typedef ResizeBuffersFn = int Function(Pointer<Void>, int, int, int, int, int);

/// `IDXGISwapChain1`: `IDXGISwapChain` (8-17) over `IDXGIDeviceSubObject` (7)
/// over `IDXGIObject` (3-6) over `IUnknown` (0-2).
final class DxgiSwapChain1 extends ComObject {
  DxgiSwapChain1(super.pointer) : super(interfaceName: 'IDXGISwapChain1');

  static const int _slotPresent = 8;
  static const int _slotGetBuffer = 9;
  static const int _slotResizeBuffers = 13;

  late final PresentFn present =
      comMethod<_NativePresent>(pointer, _slotPresent).asFunction();
  late final GetBufferFn getBuffer =
      comMethod<_NativeGetBuffer>(pointer, _slotGetBuffer).asFunction();

  /// `ResizeBuffers`.
  ///
  /// The call every D3D11 backend gets wrong once: it fails with
  /// `DXGI_ERROR_INVALID_CALL` unless **every** reference to **every** back
  /// buffer has been released first - the render-target view, the texture the
  /// view was made from, and anything the immediate context still has bound.
  /// The device context counts: a back buffer left bound as a render target is
  /// an outstanding reference even though no Dart object holds it, which is
  /// why the window target unbinds before it releases. See
  /// `d3d11_window_target.dart`.
  late final ResizeBuffersFn resizeBuffers =
      comMethod<_NativeResizeBuffers>(pointer, _slotResizeBuffers).asFunction();
}

/// `ID3DBlob` (`ID3D10Blob`): compiled bytecode, or a compiler error message.
final class D3dBlob extends ComObject {
  D3dBlob(super.pointer) : super(interfaceName: 'ID3DBlob');

  static const int _slotGetBufferPointer = 3;
  static const int _slotGetBufferSize = 4;

  late final Pointer<Void> Function(Pointer<Void>) _bufferPointer =
      comMethod<Pointer<Void> Function(Pointer<Void>)>(
              pointer, _slotGetBufferPointer)
          .asFunction();
  late final int Function(Pointer<Void>) _bufferSize =
      comMethod<IntPtr Function(Pointer<Void>)>(pointer, _slotGetBufferSize)
          .asFunction();

  Pointer<Void> get bufferPointer => _bufferPointer(pointer);
  int get bufferSize => _bufferSize(pointer);

  /// The blob read as a NUL-terminated ASCII string, for compiler errors.
  String get asText =>
      readNativeAscii(bufferPointer.cast<Uint8>(), limit: bufferSize);
}
