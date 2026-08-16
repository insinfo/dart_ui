/// The Direct3D 12 and DXGI structures this backend passes across the ABI.
///
/// Every one is declared field for field as the SDK header declares it, in
/// declaration order, including the fields this renderer never sets. That is
/// not padding for its own sake: none of these structures carries a size
/// field, so the runtime reads them by offset, and a field left out shifts
/// everything after it. `D3D12_GRAPHICS_PIPELINE_STATE_DESC` is 656 bytes and
/// the input layout sits at offset 552 only because the 328-byte blend
/// description precedes it - drop the two stream-output pointers nobody uses
/// and the input layout lands in the middle of the rasteriser state.
///
/// So the layouts are asserted rather than trusted:
/// `test/backends/win32/d3d12/d3d12_layout_test.dart` checks every `sizeOf`
/// against the number the x64 ABI requires.
///
/// That test is gated on Windows even though the arithmetic needs no GPU and
/// would run anywhere. The gate is a CI rule, not a technical one - every test
/// this backend adds must skip with a declared reason on the Linux and macOS
/// runners, because a test that fails there fails the whole gate, and a
/// `sizeOf` is only guaranteed to match these numbers on a 64-bit host. The
/// cost is stated rather than hidden: a struct that drifts is caught on
/// Windows only.
///
/// ## Size is necessary and not sufficient
///
/// `sizeOf` catches a missing or extra *field*. It does not catch a field at
/// the wrong *offset*, and this file has already had one: the `Texture2D` arm
/// of [D3d12ShaderResourceViewDesc] began four bytes early because the union
/// it lives in is eight-byte aligned, and the total came to 40 bytes either
/// way. See that class for the whole story - it is the reason the layout test
/// also asserts a handful of offsets and not only sizes.
///
/// ## The one deliberate departure
///
/// `D3D12_RESOURCE_BARRIER` and `D3D12_ROOT_PARAMETER` are unions in C. They
/// are flattened here into the widest member with the others expressed as
/// offsets into it, because this backend only ever writes one arm of each -
/// transitions, and (descriptor table | root constants). [D3d12RootParameter]
/// documents which field means what under which `parameterType`.
library;

import 'dart:ffi';

// ---------------------------------------------------------------------------
// Enumerations, as the constants they are on the wire
// ---------------------------------------------------------------------------

/// `D3D_FEATURE_LEVEL`. Declared rather than defaulted: `D3D12CreateDevice`
/// takes a *minimum*, and asking for 11.0 when the renderer needs nothing
/// above it is what lets an older adapter answer at all.
const int d3dFeatureLevel110 = 0xb000;
const int d3dFeatureLevel111 = 0xb100;
const int d3dFeatureLevel120 = 0xc000;
const int d3dFeatureLevel121 = 0xc100;
const int d3dFeatureLevel122 = 0xc200;

/// The levels this backend probes, highest first. The first one that answers
/// is the one reported.
const List<int> kD3dFeatureLevels = <int>[
  d3dFeatureLevel122,
  d3dFeatureLevel121,
  d3dFeatureLevel120,
  d3dFeatureLevel111,
  d3dFeatureLevel110,
];

/// The textual form of a feature level, for [RendererInfo] and probe reports.
String featureLevelName(int level) => switch (level) {
      d3dFeatureLevel110 => '11_0',
      d3dFeatureLevel111 => '11_1',
      d3dFeatureLevel120 => '12_0',
      d3dFeatureLevel121 => '12_1',
      d3dFeatureLevel122 => '12_2',
      _ => '0x${level.toRadixString(16)}',
    };

/// `D3D12_COMMAND_LIST_TYPE_DIRECT`.
const int d3d12CommandListTypeDirect = 0;

/// `D3D12_DESCRIPTOR_HEAP_TYPE`.
const int d3d12DescriptorHeapTypeCbvSrvUav = 0;
const int d3d12DescriptorHeapTypeRtv = 2;

/// `D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE`.
const int d3d12DescriptorHeapFlagShaderVisible = 1;

/// `D3D12_HEAP_TYPE`.
const int d3d12HeapTypeDefault = 1;
const int d3d12HeapTypeUpload = 2;
const int d3d12HeapTypeReadback = 3;

/// `D3D12_RESOURCE_DIMENSION`.
const int d3d12ResourceDimensionBuffer = 1;
const int d3d12ResourceDimensionTexture2d = 3;

/// `D3D12_TEXTURE_LAYOUT`.
const int d3d12TextureLayoutUnknown = 0;
const int d3d12TextureLayoutRowMajor = 1;

/// `D3D12_RESOURCE_FLAGS`.
const int d3d12ResourceFlagNone = 0;
const int d3d12ResourceFlagAllowRenderTarget = 1;

/// `D3D12_RESOURCE_STATES`. The five this backend transitions between.
const int d3d12ResourceStateCommon = 0;
const int d3d12ResourceStatePresent = 0;
const int d3d12ResourceStateRenderTarget = 4;
const int d3d12ResourceStatePixelShaderResource = 0x80;
const int d3d12ResourceStateCopyDest = 0x400;
const int d3d12ResourceStateCopySource = 0x800;
const int d3d12ResourceStateGenericRead =
    0x1 | 0x2 | 0x40 | 0x80 | 0x200 | 0x800;

/// `D3D12_RESOURCE_BARRIER_TYPE_TRANSITION`.
const int d3d12ResourceBarrierTypeTransition = 0;

/// `D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES`.
const int d3d12ResourceBarrierAllSubresources = 0xFFFFFFFF;

/// `D3D12_BLEND`.
const int d3d12BlendZero = 1;
const int d3d12BlendOne = 2;
const int d3d12BlendInvSrcAlpha = 6;

/// `D3D12_BLEND_OP_ADD`.
const int d3d12BlendOpAdd = 1;

/// `D3D12_LOGIC_OP_NOOP`.
const int d3d12LogicOpNoop = 4;

/// `D3D12_COLOR_WRITE_ENABLE_ALL`.
const int d3d12ColorWriteEnableAll = 15;

/// `D3D12_FILL_MODE_SOLID`, `D3D12_CULL_MODE_NONE`.
const int d3d12FillModeSolid = 3;
const int d3d12CullModeNone = 1;

/// `D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF`.
const int d3d12ConservativeRasterOff = 0;

/// `D3D12_DEPTH_WRITE_MASK_ZERO`, `D3D12_COMPARISON_FUNC_ALWAYS`,
/// `D3D12_STENCIL_OP_KEEP`.
const int d3d12DepthWriteMaskZero = 0;
const int d3d12ComparisonFuncAlways = 8;
const int d3d12StencilOpKeep = 1;

/// `D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA`.
const int d3d12InputPerVertexData = 0;

/// `D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED`.
const int d3d12IndexBufferStripCutDisabled = 0;

/// `D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE` and the IA topology that goes
/// with it. The two are different enumerations and both are needed: the type
/// goes in the pipeline state, the topology in `IASetPrimitiveTopology`.
const int d3d12PrimitiveTopologyTypeTriangle = 3;
const int d3dPrimitiveTopologyTriangleList = 4;

/// `D3D12_PIPELINE_STATE_FLAG_NONE`.
const int d3d12PipelineStateFlagNone = 0;

/// `D3D12_ROOT_PARAMETER_TYPE`.
const int d3d12RootParameterTypeDescriptorTable = 0;
const int d3d12RootParameterTypeConstants = 1;

/// `D3D12_DESCRIPTOR_RANGE_TYPE_SRV`.
const int d3d12DescriptorRangeTypeSrv = 0;

/// `D3D12_SHADER_VISIBILITY`.
const int d3d12ShaderVisibilityAll = 0;
const int d3d12ShaderVisibilityPixel = 5;

/// `D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT`.
const int d3d12RootSignatureFlagAllowInputAssemblerInputLayout = 1;

/// `D3D_ROOT_SIGNATURE_VERSION_1_0`.
const int d3dRootSignatureVersion10 = 1;

/// `D3D12_FILTER_MIN_MAG_MIP_POINT` and `..._MIN_MAG_MIP_LINEAR`.
const int d3d12FilterMinMagMipPoint = 0;
const int d3d12FilterMinMagMipLinear = 0x15;

/// `D3D12_TEXTURE_ADDRESS_MODE_CLAMP`.
const int d3d12TextureAddressModeClamp = 3;

/// `D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK`.
const int d3d12StaticBorderColorTransparentBlack = 0;

/// `D3D12_SRV_DIMENSION_TEXTURE2D` and the default component mapping.
const int d3d12SrvDimensionTexture2d = 4;

/// `D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING`, expanded.
///
/// The macro in the header encodes four 3-bit component selectors plus a
/// "this really is an encoded mapping" flag at bit 12. The identity mapping is
/// `(0, 1, 2, 3)`, which is what a texture whose channels are already in the
/// right order wants.
const int d3d12DefaultShader4ComponentMapping =
    0 | (1 << 3) | (2 << 6) | (3 << 9) | (1 << 12);

/// `D3D12_TEXTURE_COPY_TYPE`.
const int d3d12TextureCopyTypeSubresourceIndex = 0;
const int d3d12TextureCopyTypePlacedFootprint = 1;

/// The two alignments a placed texture footprint has to honour.
///
/// `D3D12_TEXTURE_DATA_PITCH_ALIGNMENT` and
/// `D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT`. They are constants in the API
/// rather than device properties, which is why this backend computes
/// footprints itself instead of calling `GetCopyableFootprints` for a
/// single-mip, uncompressed, two-dimensional texture - the only kind it
/// creates. Anything else (block-compressed, planar, multi-mip) must go
/// through the API call, and this backend refuses to create one.
const int d3d12TextureDataPitchAlignment = 256;
const int d3d12TextureDataPlacementAlignment = 512;

/// `DXGI_FORMAT`.
const int dxgiFormatUnknown = 0;
const int dxgiFormatR32G32B32A32Float = 2;
const int dxgiFormatR32G32Float = 16;
const int dxgiFormatR8G8B8A8Unorm = 28;
const int dxgiFormatR8Unorm = 61;
const int dxgiFormatR32Uint = 42;

/// `DXGI_USAGE_RENDER_TARGET_OUTPUT`.
const int dxgiUsageRenderTargetOutput = 0x20;

/// `DXGI_SWAP_EFFECT_FLIP_DISCARD`.
///
/// The only swap effect this backend uses. The two older ones (`DISCARD`,
/// `SEQUENTIAL`) are the blt model, which Direct3D 12 does not support at all
/// - a swap chain created with one fails outright rather than falling back.
const int dxgiSwapEffectFlipDiscard = 4;

/// `DXGI_SCALING_STRETCH`, `DXGI_ALPHA_MODE_UNSPECIFIED`.
const int dxgiScalingStretch = 0;
const int dxgiAlphaModeUnspecified = 0;

/// `DXGI_CREATE_FACTORY_DEBUG`.
const int dxgiCreateFactoryDebug = 1;

/// `D3D12_MESSAGE_SEVERITY`. Corruption and error are the two the barrier
/// test treats as failures; warning and below are reported and tolerated.
const int d3d12MessageSeverityCorruption = 0;
const int d3d12MessageSeverityError = 1;
const int d3d12MessageSeverityWarning = 2;

// ---------------------------------------------------------------------------
// Structures
// ---------------------------------------------------------------------------

/// `DXGI_SAMPLE_DESC`.
final class DxgiSampleDesc extends Struct {
  @Uint32()
  external int count;
  @Uint32()
  external int quality;
}

/// `DXGI_SWAP_CHAIN_DESC1`. 48 bytes.
final class DxgiSwapChainDesc1 extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int format;
  @Int32()
  external int stereo;
  external DxgiSampleDesc sampleDesc;
  @Uint32()
  external int bufferUsage;
  @Uint32()
  external int bufferCount;
  @Uint32()
  external int scaling;
  @Uint32()
  external int swapEffect;
  @Uint32()
  external int alphaMode;
  @Uint32()
  external int flags;
}

/// `DXGI_ADAPTER_DESC1`. Read for the adapter string in [RendererInfo].
final class DxgiAdapterDesc1 extends Struct {
  @Array(128)
  external Array<Uint16> description;
  @Uint32()
  external int vendorId;
  @Uint32()
  external int deviceId;
  @Uint32()
  external int subSysId;
  @Uint32()
  external int revision;
  @IntPtr()
  external int dedicatedVideoMemory;
  @IntPtr()
  external int dedicatedSystemMemory;
  @IntPtr()
  external int sharedSystemMemory;
  @Uint32()
  external int adapterLuidLow;
  @Int32()
  external int adapterLuidHigh;
  @Uint32()
  external int flags;
}

/// `D3D12_COMMAND_QUEUE_DESC`.
final class D3d12CommandQueueDesc extends Struct {
  @Uint32()
  external int type;
  @Int32()
  external int priority;
  @Uint32()
  external int flags;
  @Uint32()
  external int nodeMask;
}

/// `D3D12_DESCRIPTOR_HEAP_DESC`.
final class D3d12DescriptorHeapDesc extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int numDescriptors;
  @Uint32()
  external int flags;
  @Uint32()
  external int nodeMask;
}

/// `D3D12_HEAP_PROPERTIES`.
final class D3d12HeapProperties extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int cpuPageProperty;
  @Uint32()
  external int memoryPoolPreference;
  @Uint32()
  external int creationNodeMask;
  @Uint32()
  external int visibleNodeMask;
}

/// `D3D12_RESOURCE_DESC`. 56 bytes; `alignment` sits at offset 8 because it is
/// a `UINT64` following a `UINT`.
final class D3d12ResourceDesc extends Struct {
  @Uint32()
  external int dimension;
  @Uint64()
  external int alignment;
  @Uint64()
  external int width;
  @Uint32()
  external int height;
  @Uint16()
  external int depthOrArraySize;
  @Uint16()
  external int mipLevels;
  @Uint32()
  external int format;
  external DxgiSampleDesc sampleDesc;
  @Uint32()
  external int layout;
  @Uint32()
  external int flags;
}

/// `D3D12_RESOURCE_BARRIER`, flattened to its transition arm.
///
/// The C declaration is a union of transition, aliasing and UAV barriers. All
/// three start with the same `Type`/`Flags` pair and all three fit in 24
/// bytes, so writing the transition fields at their union offsets is the same
/// bytes the compiler would have laid down - and this backend issues no other
/// kind. A future aliasing barrier adds a second view over the same 32 bytes
/// rather than changing this one.
final class D3d12ResourceBarrier extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int flags;
  external Pointer<Void> resource;
  @Uint32()
  external int subresource;
  @Uint32()
  external int stateBefore;
  @Uint32()
  external int stateAfter;
  @Uint32()
  external int tail;
}

/// `D3D12_VIEWPORT`.
final class D3d12Viewport extends Struct {
  @Float()
  external double topLeftX;
  @Float()
  external double topLeftY;
  @Float()
  external double width;
  @Float()
  external double height;
  @Float()
  external double minDepth;
  @Float()
  external double maxDepth;
}

/// `D3D12_RECT`, which is Win32's `RECT`. Half-open and y-down, exactly like
/// the device-space rectangles the batcher produces - so a scissor needs no
/// coordinate conversion at all on this API. See `d3d12_shaders.dart`.
final class D3d12Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

/// `D3D12_VERTEX_BUFFER_VIEW`.
final class D3d12VertexBufferView extends Struct {
  @Uint64()
  external int bufferLocation;
  @Uint32()
  external int sizeInBytes;
  @Uint32()
  external int strideInBytes;
}

/// `D3D12_INDEX_BUFFER_VIEW`.
final class D3d12IndexBufferView extends Struct {
  @Uint64()
  external int bufferLocation;
  @Uint32()
  external int sizeInBytes;
  @Uint32()
  external int format;
}

/// `D3D12_RANGE`, the read range handed to `Map` and `Unmap`.
final class D3d12Range extends Struct {
  @IntPtr()
  external int begin;
  @IntPtr()
  external int end;
}

/// `D3D12_SHADER_BYTECODE`.
final class D3d12ShaderBytecode extends Struct {
  external Pointer<Void> shaderBytecode;
  @IntPtr()
  external int bytecodeLength;
}

/// `D3D12_STREAM_OUTPUT_DESC`. Never populated; present for its 32 bytes.
final class D3d12StreamOutputDesc extends Struct {
  external Pointer<Void> soDeclaration;
  @Uint32()
  external int numEntries;
  external Pointer<Uint32> bufferStrides;
  @Uint32()
  external int numStrides;
  @Uint32()
  external int rasterizedStream;
}

/// `D3D12_RENDER_TARGET_BLEND_DESC`. 40 bytes: nine 32-bit fields and a byte,
/// padded out.
final class D3d12RenderTargetBlendDesc extends Struct {
  @Int32()
  external int blendEnable;
  @Int32()
  external int logicOpEnable;
  @Uint32()
  external int srcBlend;
  @Uint32()
  external int destBlend;
  @Uint32()
  external int blendOp;
  @Uint32()
  external int srcBlendAlpha;
  @Uint32()
  external int destBlendAlpha;
  @Uint32()
  external int blendOpAlpha;
  @Uint32()
  external int logicOp;
  @Uint8()
  external int renderTargetWriteMask;
}

/// `D3D12_BLEND_DESC`. 328 bytes, eight render targets whether or not they
/// are used.
final class D3d12BlendDesc extends Struct {
  @Int32()
  external int alphaToCoverageEnable;
  @Int32()
  external int independentBlendEnable;
  @Array(8)
  external Array<D3d12RenderTargetBlendDesc> renderTarget;
}

/// `D3D12_RASTERIZER_DESC`.
final class D3d12RasterizerDesc extends Struct {
  @Uint32()
  external int fillMode;
  @Uint32()
  external int cullMode;
  @Int32()
  external int frontCounterClockwise;
  @Int32()
  external int depthBias;
  @Float()
  external double depthBiasClamp;
  @Float()
  external double slopeScaledDepthBias;
  @Int32()
  external int depthClipEnable;
  @Int32()
  external int multisampleEnable;
  @Int32()
  external int antialiasedLineEnable;
  @Uint32()
  external int forcedSampleCount;
  @Uint32()
  external int conservativeRaster;
}

/// `D3D12_DEPTH_STENCILOP_DESC`.
final class D3d12DepthStencilOpDesc extends Struct {
  @Uint32()
  external int stencilFailOp;
  @Uint32()
  external int stencilDepthFailOp;
  @Uint32()
  external int stencilPassOp;
  @Uint32()
  external int stencilFunc;
}

/// `D3D12_DEPTH_STENCIL_DESC`.
final class D3d12DepthStencilDesc extends Struct {
  @Int32()
  external int depthEnable;
  @Uint32()
  external int depthWriteMask;
  @Uint32()
  external int depthFunc;
  @Int32()
  external int stencilEnable;
  @Uint8()
  external int stencilReadMask;
  @Uint8()
  external int stencilWriteMask;
  external D3d12DepthStencilOpDesc frontFace;
  external D3d12DepthStencilOpDesc backFace;
}

/// `D3D12_INPUT_ELEMENT_DESC`.
final class D3d12InputElementDesc extends Struct {
  external Pointer<Uint8> semanticName;
  @Uint32()
  external int semanticIndex;
  @Uint32()
  external int format;
  @Uint32()
  external int inputSlot;
  @Uint32()
  external int alignedByteOffset;
  @Uint32()
  external int inputSlotClass;
  @Uint32()
  external int instanceDataStepRate;
}

/// `D3D12_INPUT_LAYOUT_DESC`.
final class D3d12InputLayoutDesc extends Struct {
  external Pointer<D3d12InputElementDesc> inputElementDescs;
  @Uint32()
  external int numElements;
}

/// `D3D12_CACHED_PIPELINE_STATE`. Never populated.
final class D3d12CachedPipelineState extends Struct {
  external Pointer<Void> cachedBlob;
  @IntPtr()
  external int cachedBlobSizeInBytes;
}

/// `D3D12_GRAPHICS_PIPELINE_STATE_DESC`. 656 bytes.
final class D3d12GraphicsPipelineStateDesc extends Struct {
  external Pointer<Void> rootSignature;
  external D3d12ShaderBytecode vs;
  external D3d12ShaderBytecode ps;
  external D3d12ShaderBytecode ds;
  external D3d12ShaderBytecode hs;
  external D3d12ShaderBytecode gs;
  external D3d12StreamOutputDesc streamOutput;
  external D3d12BlendDesc blendState;
  @Uint32()
  external int sampleMask;
  external D3d12RasterizerDesc rasterizerState;
  external D3d12DepthStencilDesc depthStencilState;
  external D3d12InputLayoutDesc inputLayout;
  @Uint32()
  external int ibStripCutValue;
  @Uint32()
  external int primitiveTopologyType;
  @Uint32()
  external int numRenderTargets;
  @Array(8)
  external Array<Uint32> rtvFormats;
  @Uint32()
  external int dsvFormat;
  external DxgiSampleDesc sampleDesc;
  @Uint32()
  external int nodeMask;
  external D3d12CachedPipelineState cachedPso;
  @Uint32()
  external int flags;
}

/// `D3D12_DESCRIPTOR_RANGE`.
final class D3d12DescriptorRange extends Struct {
  @Uint32()
  external int rangeType;
  @Uint32()
  external int numDescriptors;
  @Uint32()
  external int baseShaderRegister;
  @Uint32()
  external int registerSpace;
  @Uint32()
  external int offsetInDescriptorsFromTableStart;
}

/// `D3D12_ROOT_PARAMETER`, flattened.
///
/// The union at offset 8 is 16 bytes wide. Which fields mean what depends on
/// [parameterType]:
///
///   * `DESCRIPTOR_TABLE`: [field8] is `NumDescriptorRanges`, [fieldC] is the
///     pointer's alignment padding, and [field10] is `pDescriptorRanges`.
///   * `32BIT_CONSTANTS`: [field8] is `ShaderRegister`, [fieldC] is
///     `RegisterSpace`, and the low half of [field10] is `Num32BitValues`.
final class D3d12RootParameter extends Struct {
  @Uint32()
  external int parameterType;
  @Uint32()
  external int reserved;
  @Uint32()
  external int field8;
  @Uint32()
  external int fieldC;
  @Uint64()
  external int field10;
  @Uint32()
  external int shaderVisibility;
  @Uint32()
  external int tail;
}

/// `D3D12_STATIC_SAMPLER_DESC`.
final class D3d12StaticSamplerDesc extends Struct {
  @Uint32()
  external int filter;
  @Uint32()
  external int addressU;
  @Uint32()
  external int addressV;
  @Uint32()
  external int addressW;
  @Float()
  external double mipLodBias;
  @Uint32()
  external int maxAnisotropy;
  @Uint32()
  external int comparisonFunc;
  @Uint32()
  external int borderColor;
  @Float()
  external double minLod;
  @Float()
  external double maxLod;
  @Uint32()
  external int shaderRegister;
  @Uint32()
  external int registerSpace;
  @Uint32()
  external int shaderVisibility;
}

/// `D3D12_ROOT_SIGNATURE_DESC`.
final class D3d12RootSignatureDesc extends Struct {
  @Uint32()
  external int numParameters;
  @Uint32()
  external int pad0;
  external Pointer<D3d12RootParameter> parameters;
  @Uint32()
  external int numStaticSamplers;
  @Uint32()
  external int pad1;
  external Pointer<D3d12StaticSamplerDesc> staticSamplers;
  @Uint32()
  external int flags;
  @Uint32()
  external int pad2;
}

/// `D3D12_SHADER_RESOURCE_VIEW_DESC` narrowed to its `Texture2D` arm.
///
/// The union after the first three fields is 24 bytes in the general case
/// (`D3D12_BUFFER_SRV` is the widest at 24). The `Texture2D` arm is
/// `{MostDetailedMip, MipLevels, PlaneSlice, ResourceMinLODClamp}` - three
/// UINTs and a float - and the remaining bytes are left zero.
///
/// ## [unionPad] is not decoration, and this is how it was found
///
/// The union's widest member is `D3D12_BUFFER_SRV`, whose first field is a
/// `UINT64`, so **the union is 8-byte aligned and begins at offset 16** - not
/// at 12, where the third `UINT` ends. Without [unionPad] every Texture2D
/// field lands one slot early: `MipLevels` is read as `MostDetailedMip`,
/// `PlaneSlice` as `MipLevels`, and a `MipLevels` of zero is invalid.
///
/// The failure that produced this comment is worth recording, because it is
/// exactly the shape section 6.6 warns about. `CreateShaderResourceView`
/// returns `void`: it cannot report the bad descriptor. The call appeared to
/// succeed, and the *next* thing that touched the device answered
/// `DXGI_ERROR_DEVICE_REMOVED` - so the visible error named a call that was
/// innocent, several stages after the one that was wrong. The total size is 40
/// bytes with or without the pad, so `sizeOf` alone could never have caught
/// it; only the offsets differ.
final class D3d12ShaderResourceViewDesc extends Struct {
  @Uint32()
  external int format;
  @Uint32()
  external int viewDimension;
  @Uint32()
  external int shader4ComponentMapping;

  /// The four bytes that align the union to 8. See the class comment.
  @Uint32()
  external int unionPad;

  @Uint32()
  external int mostDetailedMip;
  @Uint32()
  external int mipLevels;
  @Uint32()
  external int planeSlice;
  @Float()
  external double resourceMinLodClamp;
  @Uint32()
  external int tail0;
  @Uint32()
  external int tail1;
}

/// `D3D12_SUBRESOURCE_FOOTPRINT`.
final class D3d12SubresourceFootprint extends Struct {
  @Uint32()
  external int format;
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int depth;
  @Uint32()
  external int rowPitch;
}

/// `D3D12_PLACED_SUBRESOURCE_FOOTPRINT`.
final class D3d12PlacedSubresourceFootprint extends Struct {
  @Uint64()
  external int offset;
  external D3d12SubresourceFootprint footprint;
}

/// `D3D12_TEXTURE_COPY_LOCATION`, flattened.
///
/// The union at offset 16 holds either a placed footprint (32 bytes) or a
/// subresource index (4). Because the index occupies the first four bytes of
/// the union and [D3d12PlacedSubresourceFootprint.offset] is a little-endian
/// `UINT64` at that same offset, writing the index into `offset` writes it
/// where the runtime reads it.
final class D3d12TextureCopyLocation extends Struct {
  external Pointer<Void> resource;
  @Uint32()
  external int type;
  @Uint32()
  external int pad;
  external D3d12PlacedSubresourceFootprint placedFootprint;
}

/// `D3D12_MESSAGE`, the debug layer's record of one complaint.
final class D3d12Message extends Struct {
  @Uint32()
  external int category;
  @Uint32()
  external int severity;
  @Uint32()
  external int id;
  @Uint32()
  external int pad;
  external Pointer<Uint8> description;
  @IntPtr()
  external int descriptionByteLength;
}

/// Rounds [value] up to the next multiple of [alignment], which must be a
/// power of two.
int alignUp(int value, int alignment) =>
    (value + alignment - 1) & ~(alignment - 1);
