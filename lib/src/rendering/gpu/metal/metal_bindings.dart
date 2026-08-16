/// Metal, bound by hand, to the checklist section 11.4 sets for a binding
/// package.
///
/// # NOTHING IN THIS FILE HAS BEEN EXECUTED ON A MAC
///
/// It was written on Windows. No Metal call in this framework has ever run.
/// What *is* verified is stated per item below and covered by
/// `test/rendering/gpu/metal/metal_bindings_test.dart`, which runs anywhere;
/// everything else is a transcription with a stated source. Section 6.6 -
/// faked capability is worse than absent capability - is the reason that
/// distinction is drawn item by item instead of once at the top.
///
/// ## Section 11.4's checklist, answered
///
/// | Item | Here |
/// |---|---|
/// | Generator config file | **None.** No generator ran - see below. |
/// | Header version / commit | [kMetalBindingProvenance] |
/// | Reproducible script | **None.** See below. |
/// | Manual override list | The whole file. [kMetalUnverifiedEncodings] names the transcriptions with no upstream to check against. |
/// | Symbol test | [kMetalRequiredSymbols], asserted only on macOS |
/// | Size test | every struct in this file, asserted on any platform |
/// | Offset test | every struct field, by writing a sentinel and finding it |
/// | Minimal call test | macOS only, skipped elsewhere with a stated reason |
/// | Ignored-API report | [kMetalDeliberatelyUnbound] |
/// | Ownership documentation | [MetalSelector.returnsOwned], one row per selector |
///
/// **Why there is no generator config and no script.** `ffigen` needs
/// `libclang`, which is not installed on this machine and was not to be
/// installed; its C++ support is experimental in any case, and `metal-cpp` is
/// C++. So the two checklist items that presuppose a generator are answered
/// "none" rather than fabricated. The mitigation is the rest of the list: the
/// transcription is *data* here - [kMetalSelectors] - so it can be compared
/// against [ObjCSendShape] by a test rather than reviewed by eye.
///
/// ## Where the signatures came from
///
/// Apple publishes `metal-cpp`, a C++ projection of Metal in which every
/// method carries its real selector and its real parameter types. That is a far
/// better source than prose documentation, and it is what the selector strings
/// and enum values below were read from. It is **not** used to generate
/// anything: it is the authority the hand transcription is checked against.
///
/// The consultation was over a public mirror of those headers rather than the
/// zip Apple distributes from developer.apple.com, because this machine has no
/// Xcode. That is a weaker provenance than a pinned commit of a vendored
/// header and it is recorded as such in [kMetalBindingProvenance].
///
/// ## Two constants the POC had wrong, and what that proves
///
/// `poc/poc_07_metal/lib/metal_bindings.dart` declares:
///
/// ```dart
/// const int mtlLoadActionClear = 0;   // real value: 2
/// const int mtlStoreActionStore = 0;  // real value: 1
/// ```
///
/// Both are wrong. `MTLLoadAction` is `DontCare = 0, Load = 1, Clear = 2` and
/// `MTLStoreAction` is `DontCare = 0, Store = 1, MultisampleResolve = 2`. The
/// POC therefore asked for *don't care* on both ends of a pass whose entire
/// purpose was to clear and keep a colour - and it printed "POC-07 finished
/// successfully", because a pass that discards its contents is not an error.
/// On a tiler, `DontCare` on the load frequently *looks* right, since the tile
/// memory often happens to be what the previous frame left.
///
/// That is the argument for this file existing at all. An enum constant is
/// pure data, a wrong one fails silently, and a table of them next to the
/// declared source is checkable by a human in a way that five scattered
/// `const int`s are not.
///
/// ## Nothing is opened at import time
///
/// As in `objc_runtime.dart` and `backends/macos/io_surface.dart`: the
/// framework handles are lazy top-level finals, so importing this on Windows -
/// which every test in this repository does - costs nothing and throws
/// nothing.
library;

import 'dart:ffi';

import '../../../ffi/objc_runtime.dart';
import '../gpu_pipeline.dart';
import '../gpu_texture.dart';
import 'metal_shaders.dart';

// ---------------------------------------------------------------------------
// Provenance - checklist item "header version / commit"
// ---------------------------------------------------------------------------

/// Where the selectors, encodings and enum values below were read from.
///
/// Deliberately a string constant rather than a comment: a test prints it on
/// failure, so a mismatch report says which source the transcription claimed
/// to follow.
const String kMetalBindingProvenance =
    'metal-cpp headers (MTLDevice.hpp, MTLTexture.hpp, MTLRenderPass.hpp, '
    'MTLRenderPipeline.hpp, MTLRenderCommandEncoder.hpp, MTLCommandBuffer.hpp, '
    'MTLVertexDescriptor.hpp, MTLPixelFormat.hpp, MTLResource.hpp), read on '
    '16 August 2026 from a public mirror of Apple\'s distribution rather than '
    'from a pinned vendored copy - this machine has no Xcode. Enum values and '
    'selector spellings come from there; the Objective-C type encodings in '
    'kMetalSelectors are hand-derived from the C++ parameter types and have no '
    'upstream string to be compared against off a Mac.';

/// Selectors whose type encoding is a derivation rather than a transcription.
///
/// The encoding strings in [kMetalSelectors] are built from `metal-cpp`'s C++
/// parameter types, because `metal-cpp` records types and not encodings. The
/// derivation is mechanical for a word argument and is where a mistake would
/// hide for the rest. On a Mac, `objcMethodTypeEncoding` reads the real string
/// out of the class and the guessing stops; that check is mechanism 3 of
/// `objc_runtime.dart` and it is the one that needs hardware.
const List<String> kMetalUnverifiedEncodings = <String>[
  'every entry in kMetalSelectors',
];

/// C symbols that must resolve for this backend to start.
///
/// Checked only on macOS - a missing-symbol test on Windows would assert that
/// Metal is absent, which proves nothing about the binding.
const List<String> kMetalRequiredSymbols = <String>[
  'MTLCreateSystemDefaultDevice',
];

/// Metal surface this framework deliberately does not bind, and why.
///
/// Checklist item "ignored-API report". The point is that a reader can tell
/// "not needed" from "not noticed": every line here is a decision.
const Map<String, String> kMetalDeliberatelyUnbound = <String, String>{
  'MTLComputeCommandEncoder':
      'this renderer has no compute pass; RendererCapabilities.supportsCompute '
          'is false for every backend in the repository',
  'MTLBlitCommandEncoder':
      'texture uploads go through replaceRegion:, which needs no encoder for '
          'a shared-storage texture',
  'MTLDepthStencilState':
      'the renderer is 2D and painter-ordered; there is no depth buffer, which '
          'is also why the GL backend disables GL_DEPTH_TEST',
  'MTLSamplerState':
      'filtering is a property of the texture in this renderer and is carried '
          'by GpuTextureFilter; if a future change needs dynamic filtering it '
          'will need two sampler states, as d3d12_shaders.dart already had to',
  'MTLHeap / MTLFence / MTLEvent':
      'no manual residency or cross-queue ordering; one queue, one pass chain',
  'MTLSharedEvent':
      'the cross-process completion mechanism ADR 0005 records as the '
          'optimisation to measure, not to adopt now',
  'MTLIndirectCommandBuffer':
      'GpuBatcher emits draw calls on the CPU, and the count is in the tens',
  'MTLCaptureManager':
      'a debugging tool, and one that cannot be exercised from here',
  'MTLArgumentEncoder':
      'argument buffers need Tier 2 and buy nothing at this draw-call count',
};

// ---------------------------------------------------------------------------
// Libraries
// ---------------------------------------------------------------------------

const String _metalPath = '/System/Library/Frameworks/Metal.framework/Metal';
const String _quartzCorePath =
    '/System/Library/Frameworks/QuartzCore.framework/QuartzCore';

DynamicLibrary? _metal;
bool _metalAttempted = false;
Object? _metalError;

/// Metal.framework, or null when this machine has none. Never throws.
DynamicLibrary? tryLoadMetal() {
  if (_metalAttempted) return _metal;
  _metalAttempted = true;
  try {
    _metal = DynamicLibrary.open(_metalPath);
  } on Object catch (error) {
    _metalError = error;
    _metal = null;
  }
  return _metal;
}

/// Why [tryLoadMetal] returned null, or null when it did not.
Object? get metalLoadError => _metalError;

DynamicLibrary? _quartzCore;
bool _quartzCoreAttempted = false;

/// QuartzCore.framework, which declares `CAMetalLayer`. Only the in-process
/// backends need it; see ADR 0005 for why the recommended path does not.
DynamicLibrary? tryLoadQuartzCore() {
  if (_quartzCoreAttempted) return _quartzCore;
  _quartzCoreAttempted = true;
  try {
    _quartzCore = DynamicLibrary.open(_quartzCorePath);
  } on Object {
    _quartzCore = null;
  }
  return _quartzCore;
}

/// `id MTLCreateSystemDefaultDevice(void)`.
///
/// A C entry point, not a message: it is looked up on the framework rather
/// than sent, which is why it is not in [kMetalSelectors].
///
/// **Ownership: +1.** The C name has no `new`/`copy` prefix for
/// [objcSelectorReturnsOwned] to see, and the naming rule does not reach a C
/// function anyway - but Apple documents the returned device as owned by the
/// caller under MRR. It is released once, at device teardown.
final Pointer<ObjCObject> Function() mtlCreateSystemDefaultDevice = () {
  final DynamicLibrary? metal = tryLoadMetal();
  if (metal == null) {
    throw StateError(
      'Metal.framework is not available in this process ($_metalPath could '
      'not be opened: ${_metalError ?? 'no reason reported'}). Guard with '
      'isMetalAvailable before touching anything in metal_bindings.dart',
    );
  }
  return metal.lookupFunction<Pointer<ObjCObject> Function(),
      Pointer<ObjCObject> Function()>('MTLCreateSystemDefaultDevice');
}();

/// Whether Metal.framework and the Objective-C runtime are both present.
bool get isMetalAvailable => isObjCRuntimeAvailable && tryLoadMetal() != null;

// ---------------------------------------------------------------------------
// Enum constants - read from metal-cpp, tested as data
// ---------------------------------------------------------------------------

/// `MTLPixelFormat`. Values from `MTLPixelFormat.hpp`.
abstract final class MtlPixelFormat {
  static const int invalid = 0;

  /// `MTLPixelFormatA8Unorm`. **Not** what the coverage atlases use - see
  /// [r8Unorm].
  static const int a8Unorm = 1;

  /// `MTLPixelFormatR8Unorm` = 10.
  ///
  /// The format for both the mask atlas and the glyph atlas. `r8Unorm` and not
  /// `a8Unorm` because the shaders sample `.r`, exactly as the GLSL and the
  /// HLSL do (`texture(uTexture, vTexCoord).r`). An `A8Unorm` texture returns
  /// its value in `.a` and zero in `.r`, so every mask would sample as fully
  /// transparent and nothing would draw - a failure that looks like a broken
  /// rasteriser rather than a wrong format constant.
  static const int r8Unorm = 10;

  static const int rgba8Unorm = 70;
  static const int rgba8UnormSrgb = 71;

  /// `MTLPixelFormatBGRA8Unorm` = 80. What an `IOSurface` from
  /// `surface_pool.dart` carries: its FourCC is `'BGRA'`
  /// (`kMacosPixelFormatBgra`), and the two must agree or
  /// `newTextureWithDescriptor:iosurface:plane:` returns nil.
  static const int bgra8Unorm = 80;

  static const int bgra8UnormSrgb = 81;
}

/// `MTLLoadAction`. **See the library comment**: the POC had `clear` as 0.
abstract final class MtlLoadAction {
  static const int dontCare = 0;
  static const int load = 1;
  static const int clear = 2;
}

/// `MTLStoreAction`. **See the library comment**: the POC had `store` as 0.
abstract final class MtlStoreAction {
  static const int dontCare = 0;
  static const int store = 1;
  static const int multisampleResolve = 2;
  static const int storeAndMultisampleResolve = 3;
  static const int unknown = 4;
  static const int customSampleDepthStore = 5;
}

/// `MTLStorageMode`, the raw mode. For a resource *option* the same value is
/// shifted; see [MtlResourceOptions].
abstract final class MtlStorageMode {
  static const int shared = 0;
  static const int managed = 1;
  static const int private = 2;
  static const int memoryless = 3;
}

/// `MTLResourceOptions`. The storage mode occupies bits 4..7, which is why
/// `managed` is 16 here and 1 in [MtlStorageMode].
///
/// Passing an [MtlStorageMode] value where a [MtlResourceOptions] is expected
/// is silent: `MTLStorageModePrivate` (2) read as a resource option is
/// `CPUCacheModeWriteCombined | ...`, not a storage mode at all. The two are
/// separate classes here for that reason.
abstract final class MtlResourceOptions {
  static const int storageModeShared = 0;
  static const int cpuCacheModeDefaultCache = 0;
  static const int cpuCacheModeWriteCombined = 1;
  static const int storageModeManaged = 16;
  static const int storageModePrivate = 32;
  static const int storageModeMemoryless = 48;
  static const int hazardTrackingModeDefault = 0;
  static const int hazardTrackingModeUntracked = 256;
  static const int hazardTrackingModeTracked = 512;
}

/// `MTLTextureUsage`, a bit set.
abstract final class MtlTextureUsage {
  static const int unknown = 0;
  static const int shaderRead = 1;
  static const int shaderWrite = 2;
  static const int renderTarget = 4;
  static const int pixelFormatView = 16;
}

/// `MTLTextureType`.
abstract final class MtlTextureType {
  static const int type1D = 0;
  static const int type1DArray = 1;
  static const int type2D = 2;
  static const int type2DArray = 3;
  static const int type2DMultisample = 4;
  static const int typeCube = 5;
  static const int typeCubeArray = 6;
  static const int type3D = 7;
}

/// `MTLBlendFactor`. Only three members are reachable from
/// [GpuBlendFactor]; the rest are here so that a future blend mode is looked
/// up rather than guessed.
abstract final class MtlBlendFactor {
  static const int zero = 0;
  static const int one = 1;
  static const int sourceColor = 2;
  static const int oneMinusSourceColor = 3;
  static const int sourceAlpha = 4;
  static const int oneMinusSourceAlpha = 5;
  static const int destinationColor = 6;
  static const int oneMinusDestinationColor = 7;
  static const int destinationAlpha = 8;
  static const int oneMinusDestinationAlpha = 9;
  static const int sourceAlphaSaturated = 10;
}

/// `MTLBlendOperation`.
abstract final class MtlBlendOperation {
  static const int add = 0;
  static const int subtract = 1;
  static const int reverseSubtract = 2;
  static const int min = 3;
  static const int max = 4;
}

/// `MTLPrimitiveType`.
abstract final class MtlPrimitiveType {
  static const int point = 0;
  static const int line = 1;
  static const int lineStrip = 2;

  /// What every batch draws. `GpuBatcher` emits indexed triangles.
  static const int triangle = 3;
  static const int triangleStrip = 4;
}

/// `MTLIndexType`.
///
/// **Weaker provenance than everything else in this file.** `MTLIndexType` was
/// not among the headers read; these are the values from the Metal
/// documentation and they have not been checked against `metal-cpp` here. The
/// value that matters is [uint32], because `GpuVertexBuffer` emits a
/// `Uint32List` and `gpu_pipeline.dart` states that a backend without 32-bit
/// indices must refuse in its probe rather than truncate. Reading `uint32` as
/// `uint16` would halve every index and draw a shredded mesh.
abstract final class MtlIndexType {
  static const int uint16 = 0;
  static const int uint32 = 1;
}

/// `MTLVertexFormat`. Only the two the vertex layout uses are named.
abstract final class MtlVertexFormat {
  static const int float = 28;
  static const int float2 = 29;
  static const int float3 = 30;
  static const int float4 = 31;
}

/// `MTLVertexStepFunction`.
abstract final class MtlVertexStepFunction {
  static const int constant = 0;
  static const int perVertex = 1;
  static const int perInstance = 2;
}

/// `MTLCommandBufferStatus`, the value `-[MTLCommandBuffer status]` returns.
///
/// [completed] is the one the presenter waits for: ADR 0005 makes
/// `PRESENT_SLOT` conditional on it, because `commit` only enqueues and the
/// GPU is still writing the shared surface when it returns.
abstract final class MtlCommandBufferStatus {
  static const int notEnqueued = 0;
  static const int enqueued = 1;
  static const int committed = 2;
  static const int scheduled = 3;
  static const int completed = 4;
  static const int error = 5;
}

/// `MTLCullMode`. The renderer draws both faces; recorded because
/// `GpuBatcher`'s quads are clockwise in a y-down device space, which is
/// counter-clockwise once flipped, and a backend that enabled culling on a
/// guess would drop every quad.
abstract final class MtlCullMode {
  static const int none = 0;
  static const int front = 1;
  static const int back = 2;
}

// ---------------------------------------------------------------------------
// Structs - checklist items "size test" and "offset test"
// ---------------------------------------------------------------------------

/// `MTLOrigin` - three `NSUInteger`s.
final class MtlOrigin extends Struct {
  @UintPtr()
  external int x;
  @UintPtr()
  external int y;
  @UintPtr()
  external int z;
}

/// `MTLSize` - three `NSUInteger`s.
final class MtlSize extends Struct {
  @UintPtr()
  external int width;
  @UintPtr()
  external int height;
  @UintPtr()
  external int depth;
}

/// `MTLRegion` - an [MtlOrigin] then an [MtlSize], both **by value**.
///
/// ## Why this exists when the call uses [ObjCWord6]
///
/// `replaceRegion:` is sent through [ObjCSendShape.voidReturnRegionLevelBytesStride],
/// whose aggregate argument is a flat six-word [ObjCWord6]. That is only
/// correct if the nested struct and the flat one have the same layout - which
/// they do here, and which is exactly the kind of claim that is true until it
/// is not.
///
/// The Direct3D 12 work in this repository already paid for the general
/// version of this mistake: `D3D12_SHADER_RESOURCE_VIEW_DESC` has an 8-byte
/// aligned union, so its `Texture2D` arm starts at offset **16 and not 12** -
/// and because the struct is 40 bytes either way, `sizeOf` would never have
/// noticed. Only an offset test catches that class of error.
///
/// So this type is declared and then *tested against* [ObjCWord6] field by
/// field, by writing a sentinel and finding which byte it landed on. It is
/// never sent; it is the control.
final class MtlRegion extends Struct {
  external MtlOrigin origin;
  external MtlSize size;
}

/// `MTLClearColor` - four `double`s. See [ObjCDouble4] for why a struct and
/// not two words, and `objc_runtime.dart`'s shape table for the POC comment
/// that got it wrong.
final class MtlClearColor extends Struct {
  @Double()
  external double red;
  @Double()
  external double green;
  @Double()
  external double blue;
  @Double()
  external double alpha;
}

/// `MTLViewport` - six `double`s.
final class MtlViewport extends Struct {
  @Double()
  external double originX;
  @Double()
  external double originY;
  @Double()
  external double width;
  @Double()
  external double height;
  @Double()
  external double znear;
  @Double()
  external double zfar;
}

/// `MTLScissorRect` - four `NSUInteger`s. Same 32 bytes as [MtlClearColor] and
/// a different journey through the ABI; see [ObjCWord4].
final class MtlScissorRect extends Struct {
  @UintPtr()
  external int x;
  @UintPtr()
  external int y;
  @UintPtr()
  external int width;
  @UintPtr()
  external int height;
}

/// `CGSize` - two `double`s, taken by `-[CAMetalLayer setDrawableSize:]`.
final class CgSize extends Struct {
  @Double()
  external double width;
  @Double()
  external double height;
}

// ---------------------------------------------------------------------------
// Struct builders, in the ABI types the senders take
// ---------------------------------------------------------------------------

/// An `MTLClearColor` as the [ObjCDouble4] `setClearColor:` is sent with.
///
/// Components are **unpremultiplied 0..1 doubles**, which is Metal's
/// convention and not this framework's: `FrameRequest.clearColor` is a
/// premultiplied BGRA int. The conversion belongs to the caller and is stated
/// here because doing it twice, or not at all, both produce a plausible
/// picture in the wrong colour.
ObjCDouble4 mtlClearColor(
  double red,
  double green,
  double blue,
  double alpha,
) =>
    objcDouble4(red, green, blue, alpha);

/// An `MTLViewport` as an [ObjCDouble6].
///
/// [znear] and [zfar] default to 0 and 1. There is no depth buffer, but the
/// viewport still carries the range and leaving it zeroed would give a
/// degenerate `0..0` depth mapping.
ObjCDouble6 mtlViewport({
  required double originX,
  required double originY,
  required double width,
  required double height,
  double znear = 0,
  double zfar = 1,
}) =>
    objcDouble6(originX, originY, width, height, znear, zfar);

/// An `MTLScissorRect` as an [ObjCWord4].
///
/// Metal takes **x, y, width, height**, while `GpuBatch` carries left, top,
/// right, bottom. The subtraction happens here, once, rather than at each call
/// site: passing `right` where `width` is expected scissors far too much and
/// still draws something, which is the hardest kind of wrong to see.
ObjCWord4 mtlScissorRect({
  required int x,
  required int y,
  required int width,
  required int height,
}) =>
    objcWord4(x, y, width, height);

/// A 2D `MTLRegion` as the flat [ObjCWord6] `replaceRegion:` is sent with.
///
/// `z` is 0 and `depth` is **1**, not 0. A depth of zero is an empty region
/// and `replaceRegion:` would copy nothing at all - the upload would silently
/// do nothing and every glyph would render blank.
ObjCWord6 mtlRegion2D({
  required int x,
  required int y,
  required int width,
  required int height,
}) =>
    objcWord6(x, y, 0, width, height, 1);

/// A `CGSize` as an [ObjCDouble2].
ObjCDouble2 cgSize(double width, double height) => objcDouble2(width, height);

// ---------------------------------------------------------------------------
// The selector table - checklist item "ownership documentation"
// ---------------------------------------------------------------------------

/// One Objective-C method this backend sends, with everything needed to send
/// it correctly.
///
/// Data rather than a call site, so that a test on any platform can compare
/// [encoding] against [shape] and [returnsOwned] against
/// [objcSelectorReturnsOwned]. A selector that only ever appeared inside a
/// function body could not be checked by anything but a reader.
final class MetalSelector {
  const MetalSelector(
    this.name,
    this.encoding,
    this.shape, {
    required this.returnsOwned,
    required this.receiver,
  });

  /// The selector, spelled exactly as `sel_registerName` takes it.
  final String name;

  /// The Objective-C type encoding, derived from `metal-cpp`'s C++ parameter
  /// types. See [kMetalUnverifiedEncodings].
  final String encoding;

  /// The trampoline cast a call site must use.
  final ObjCSendShape shape;

  /// Whether the returned object arrives with a **+1** reference the caller
  /// must release.
  ///
  /// This is the field that leaks or crashes when it is wrong, and it is wrong
  /// in a way no compiler sees. It is written here rather than inferred at the
  /// call site so that a test can hold it against
  /// [objcSelectorReturnsOwned] - two independent statements of the same fact,
  /// which is the only check available without a Mac.
  final bool returnsOwned;

  /// Which class or protocol declares it. Diagnostics and the on-Mac
  /// `objcMethodTypeEncoding` check; never branched on.
  final String receiver;
}

/// Every message this backend sends, with its declared shape and ownership.
///
/// Ordered by receiver, because that is how `metal-cpp` is organised and a
/// reviewer comparing the two reads them side by side.
const List<MetalSelector> kMetalSelectors = <MetalSelector>[
  // --- NSObject ----------------------------------------------------------
  MetalSelector('alloc', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: true, receiver: 'NSObject'),
  MetalSelector('init', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: true, receiver: 'NSObject'),
  MetalSelector('description', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'NSObject'),
  MetalSelector('UTF8String', '*@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'NSString'),
  MetalSelector('localizedDescription', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'NSError'),
  MetalSelector(
      'objectAtIndexedSubscript:', '@@:Q', ObjCSendShape.pointerReturn1,
      returnsOwned: false, receiver: 'NSArray'),

  // --- MTLDevice ---------------------------------------------------------
  MetalSelector('name', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLDevice'),
  MetalSelector('registryID', 'Q@:', ObjCSendShape.unsignedReturn0,
      returnsOwned: false, receiver: 'MTLDevice'),
  MetalSelector('maxBufferLength', 'Q@:', ObjCSendShape.unsignedReturn0,
      returnsOwned: false, receiver: 'MTLDevice'),
  MetalSelector('hasUnifiedMemory', 'B@:', ObjCSendShape.boolReturn0,
      returnsOwned: false, receiver: 'MTLDevice'),
  MetalSelector('supportsFamily:', 'B@:q', ObjCSendShape.boolReturn1,
      returnsOwned: false, receiver: 'MTLDevice'),
  MetalSelector('newCommandQueue', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: true, receiver: 'MTLDevice'),
  MetalSelector('newLibraryWithSource:options:error:', '@@:@@^@',
      ObjCSendShape.pointerReturn3,
      returnsOwned: true, receiver: 'MTLDevice'),
  MetalSelector('newRenderPipelineStateWithDescriptor:error:', '@@:@^@',
      ObjCSendShape.pointerReturn2,
      returnsOwned: true, receiver: 'MTLDevice'),
  MetalSelector(
      'newTextureWithDescriptor:', '@@:@', ObjCSendShape.pointerReturn1,
      returnsOwned: true, receiver: 'MTLDevice'),
  MetalSelector('newTextureWithDescriptor:iosurface:plane:',
      '@@:@^{__IOSurface=}Q', ObjCSendShape.pointerReturn3,
      returnsOwned: true, receiver: 'MTLDevice'),
  MetalSelector(
      'newBufferWithLength:options:', '@@:QQ', ObjCSendShape.pointerReturn2,
      returnsOwned: true, receiver: 'MTLDevice'),
  MetalSelector('newBufferWithBytes:length:options:', '@@:^vQQ',
      ObjCSendShape.pointerReturn3,
      returnsOwned: true, receiver: 'MTLDevice'),

  // --- MTLLibrary --------------------------------------------------------
  MetalSelector('newFunctionWithName:', '@@:@', ObjCSendShape.pointerReturn1,
      returnsOwned: true, receiver: 'MTLLibrary'),

  // --- MTLBuffer ---------------------------------------------------------
  MetalSelector('contents', '^v@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLBuffer'),
  MetalSelector('length', 'Q@:', ObjCSendShape.unsignedReturn0,
      returnsOwned: false, receiver: 'MTLBuffer'),

  // --- MTLTextureDescriptor ----------------------------------------------
  MetalSelector('texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
      '@@:QQQB', ObjCSendShape.pointerReturn4,
      returnsOwned: false, receiver: 'MTLTextureDescriptor'),
  MetalSelector('setPixelFormat:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLTextureDescriptor'),
  MetalSelector('setWidth:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLTextureDescriptor'),
  MetalSelector('setHeight:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLTextureDescriptor'),
  MetalSelector('setUsage:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLTextureDescriptor'),
  MetalSelector('setStorageMode:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLTextureDescriptor'),

  // --- MTLTexture --------------------------------------------------------
  MetalSelector(
      'replaceRegion:mipmapLevel:withBytes:bytesPerRow:',
      'v@:{MTLRegion={MTLOrigin=QQQ}{MTLSize=QQQ}}Q^vQ',
      ObjCSendShape.voidReturnRegionLevelBytesStride,
      returnsOwned: false,
      receiver: 'MTLTexture'),
  MetalSelector('width', 'Q@:', ObjCSendShape.unsignedReturn0,
      returnsOwned: false, receiver: 'MTLTexture'),
  MetalSelector('height', 'Q@:', ObjCSendShape.unsignedReturn0,
      returnsOwned: false, receiver: 'MTLTexture'),

  // --- MTLRenderPassDescriptor -------------------------------------------
  MetalSelector('renderPassDescriptor', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLRenderPassDescriptor'),
  MetalSelector('colorAttachments', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLRenderPassDescriptor'),
  MetalSelector('setTexture:', 'v@:@', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLRenderPassColorAttachmentDescriptor'),
  MetalSelector('setLoadAction:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLRenderPassColorAttachmentDescriptor'),
  MetalSelector('setStoreAction:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLRenderPassColorAttachmentDescriptor'),
  MetalSelector('setClearColor:', 'v@:{MTLClearColor=dddd}',
      ObjCSendShape.voidReturnDouble4,
      returnsOwned: false, receiver: 'MTLRenderPassColorAttachmentDescriptor'),

  // --- MTLRenderPipelineDescriptor ---------------------------------------
  MetalSelector('setVertexFunction:', 'v@:@', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLRenderPipelineDescriptor'),
  MetalSelector('setFragmentFunction:', 'v@:@', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLRenderPipelineDescriptor'),
  MetalSelector('setVertexDescriptor:', 'v@:@', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLRenderPipelineDescriptor'),
  MetalSelector('setBlendingEnabled:', 'v@:B', ObjCSendShape.voidReturn1,
      returnsOwned: false,
      receiver: 'MTLRenderPipelineColorAttachmentDescriptor'),
  MetalSelector('setSourceRGBBlendFactor:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false,
      receiver: 'MTLRenderPipelineColorAttachmentDescriptor'),
  MetalSelector(
      'setDestinationRGBBlendFactor:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false,
      receiver: 'MTLRenderPipelineColorAttachmentDescriptor'),
  MetalSelector('setSourceAlphaBlendFactor:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false,
      receiver: 'MTLRenderPipelineColorAttachmentDescriptor'),
  MetalSelector(
      'setDestinationAlphaBlendFactor:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false,
      receiver: 'MTLRenderPipelineColorAttachmentDescriptor'),
  MetalSelector('setRgbBlendOperation:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false,
      receiver: 'MTLRenderPipelineColorAttachmentDescriptor'),
  MetalSelector('setAlphaBlendOperation:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false,
      receiver: 'MTLRenderPipelineColorAttachmentDescriptor'),

  // --- MTLVertexDescriptor -----------------------------------------------
  MetalSelector('vertexDescriptor', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLVertexDescriptor'),
  MetalSelector('attributes', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLVertexDescriptor'),
  MetalSelector('layouts', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLVertexDescriptor'),
  MetalSelector('setFormat:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLVertexAttributeDescriptor'),
  MetalSelector('setOffset:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLVertexAttributeDescriptor'),
  MetalSelector('setBufferIndex:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLVertexAttributeDescriptor'),
  MetalSelector('setStride:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLVertexBufferLayoutDescriptor'),
  MetalSelector('setStepFunction:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLVertexBufferLayoutDescriptor'),

  // --- MTLCommandQueue / MTLCommandBuffer --------------------------------
  MetalSelector('commandBuffer', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLCommandQueue'),
  MetalSelector('renderCommandEncoderWithDescriptor:', '@@:@',
      ObjCSendShape.pointerReturn1,
      returnsOwned: false, receiver: 'MTLCommandBuffer'),
  MetalSelector('addCompletedHandler:', 'v@:@?', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLCommandBuffer'),
  MetalSelector('presentDrawable:', 'v@:@', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLCommandBuffer'),
  MetalSelector('commit', 'v@:', ObjCSendShape.voidReturn0,
      returnsOwned: false, receiver: 'MTLCommandBuffer'),
  MetalSelector('waitUntilCompleted', 'v@:', ObjCSendShape.voidReturn0,
      returnsOwned: false, receiver: 'MTLCommandBuffer'),
  MetalSelector('status', 'Q@:', ObjCSendShape.unsignedReturn0,
      returnsOwned: false, receiver: 'MTLCommandBuffer'),
  MetalSelector('error', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'MTLCommandBuffer'),

  // --- MTLRenderCommandEncoder -------------------------------------------
  MetalSelector('setRenderPipelineState:', 'v@:@', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),
  MetalSelector('setViewport:', 'v@:{MTLViewport=dddddd}',
      ObjCSendShape.voidReturnDouble6,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),
  MetalSelector('setScissorRect:', 'v@:{MTLScissorRect=QQQQ}',
      ObjCSendShape.voidReturnWord4,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),
  MetalSelector(
      'setVertexBuffer:offset:atIndex:', 'v@:@QQ', ObjCSendShape.voidReturn3,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),
  MetalSelector(
      'setVertexBytes:length:atIndex:', 'v@:^vQQ', ObjCSendShape.voidReturn3,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),
  MetalSelector(
      'setFragmentBytes:length:atIndex:', 'v@:^vQQ', ObjCSendShape.voidReturn3,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),
  MetalSelector(
      'setFragmentTexture:atIndex:', 'v@:@Q', ObjCSendShape.voidReturn2,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),
  MetalSelector('setCullMode:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),
  MetalSelector(
      'drawIndexedPrimitives:indexCount:indexType:indexBuffer:'
          'indexBufferOffset:',
      'v@:QQQ@Q',
      ObjCSendShape.voidReturn5,
      returnsOwned: false,
      receiver: 'MTLRenderCommandEncoder'),
  MetalSelector('endEncoding', 'v@:', ObjCSendShape.voidReturn0,
      returnsOwned: false, receiver: 'MTLRenderCommandEncoder'),

  // --- CAMetalLayer, for the in-process presenter only -------------------
  MetalSelector('setDevice:', 'v@:@', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector(
      'setDrawableSize:', 'v@:{CGSize=dd}', ObjCSendShape.voidReturnDouble2,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector('setFramebufferOnly:', 'v@:B', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector('setMaximumDrawableCount:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector('nextDrawable', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector('texture', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'CAMetalDrawable'),
];

/// [kMetalSelectors] by name, for a call site that wants the shape it declared
/// rather than one it remembered.
final Map<String, MetalSelector> kMetalSelectorsByName =
    Map<String, MetalSelector>.unmodifiable(<String, MetalSelector>{
  for (final MetalSelector selector in kMetalSelectors) selector.name: selector,
});

// ---------------------------------------------------------------------------
// The uniform block, mirrored - checklist items "size test" and "offset test"
// ---------------------------------------------------------------------------

/// The Dart mirror of the MSL `Uniforms` block in `metal_shaders.dart`.
///
/// Filled and handed to `setVertexBytes:length:atIndex:` and
/// `setFragmentBytes:length:atIndex:`, which take a pointer and a byte count
/// rather than a buffer object - the Metal idiom for a block this small, and
/// the reason there is no `MTLBuffer` for constants.
///
/// Every field is 4-byte aligned and the block is 20 bytes with no padding.
/// That is a property of the *shader* as much as of this struct: MSL's `float2`
/// would have forced 8-byte alignment and made the two disagree while both
/// looked right in isolation. See the library comment of `metal_shaders.dart`.
final class MetalUniforms extends Struct {
  @Float()
  external double viewportWidth;

  @Float()
  external double viewportHeight;

  /// One of [kMetalModeSolid], [kMetalModeCoverageMask],
  /// [kMetalModeTexturedImage].
  @Uint32()
  external int mode;

  /// Always [kMetalYFlipDefault] on this backend. See `metal_shaders.dart`.
  @Uint32()
  external int yFlip;

  /// [kMetalSamplerPoint] or [kMetalSamplerLinear].
  @Uint32()
  external int useLinear;
}

/// One entry of the `MTLVertexDescriptor` this backend builds.
final class MetalVertexAttribute {
  const MetalVertexAttribute({
    required this.attributeIndex,
    required this.format,
    required this.byteOffset,
    required this.name,
  });

  /// Matches the `[[attribute(n)]]` qualifier in the MSL.
  final int attributeIndex;

  /// An [MtlVertexFormat] member.
  final int format;

  /// Byte offset into the interleaved vertex.
  final int byteOffset;

  /// For diagnostics. Never sent.
  final String name;
}

/// The vertex layout, derived from `gpu_pipeline.dart` rather than restated.
///
/// The offsets are `kGpuPositionOffset * 4` and friends, computed here instead
/// of written out, so that a change to the shared layout cannot leave this
/// backend reading the colour where the shape rectangle is. That failure would
/// draw every quad with its coverage rectangle interpreted as a colour -
/// plausible-looking output, entirely wrong.
const List<MetalVertexAttribute> kMetalVertexAttributes =
    <MetalVertexAttribute>[
  MetalVertexAttribute(
    attributeIndex: kMetalAttributePosition,
    format: MtlVertexFormat.float2,
    byteOffset: kGpuPositionOffset * 4,
    name: 'position',
  ),
  MetalVertexAttribute(
    attributeIndex: kMetalAttributeTexCoord,
    format: MtlVertexFormat.float2,
    byteOffset: kGpuTexCoordOffset * 4,
    name: 'texCoord',
  ),
  MetalVertexAttribute(
    attributeIndex: kMetalAttributeColor,
    format: MtlVertexFormat.float4,
    byteOffset: kGpuColorOffset * 4,
    name: 'color',
  ),
  MetalVertexAttribute(
    attributeIndex: kMetalAttributeShapeRect,
    format: MtlVertexFormat.float4,
    byteOffset: kGpuShapeRectOffset * 4,
    name: 'shapeRect',
  ),
];

/// The interleaved vertex stride, in bytes. `MTLVertexBufferLayoutDescriptor`
/// wants it, and it is the shared layout's, not this backend's.
const int kMetalVertexStride = kGpuFloatsPerVertex * 4;

// ---------------------------------------------------------------------------
// Translations from the shared vocabulary
// ---------------------------------------------------------------------------

/// The `MTLBlendFactor` for a [GpuBlendFactor].
///
/// Exhaustive over the enum rather than defaulting: adding a factor to
/// `gpu_pipeline.dart` must be a compile error here, not a silent `zero` that
/// makes one blend mode draw nothing.
int metalBlendFactor(GpuBlendFactor factor) => switch (factor) {
      GpuBlendFactor.zero => MtlBlendFactor.zero,
      GpuBlendFactor.one => MtlBlendFactor.one,
      GpuBlendFactor.oneMinusSrcAlpha => MtlBlendFactor.oneMinusSourceAlpha,
    };

/// The `MTLPixelFormat` for a [GpuTextureFormat].
///
/// [GpuTextureFormat.alpha8] maps to [MtlPixelFormat.r8Unorm] and **not** to
/// `a8Unorm`, because the fragment shader reads `.r` - as the GLSL and the HLSL
/// both do. An `A8Unorm` texture returns its value in `.a` and zero in `.r`, so
/// every mask and every glyph would sample as fully transparent and nothing
/// would draw. The failure looks like a broken rasteriser, not a wrong enum.
int metalPixelFormat(GpuTextureFormat format) => switch (format) {
      GpuTextureFormat.alpha8 => MtlPixelFormat.r8Unorm,
      GpuTextureFormat.rgba8888Premultiplied => MtlPixelFormat.rgba8Unorm,
    };

/// The `useLinear` uniform value for a [GpuTextureFilter].
int metalSamplerSelector(GpuTextureFilter filter) => switch (filter) {
      GpuTextureFilter.nearest => kMetalSamplerPoint,
      GpuTextureFilter.linear => kMetalSamplerLinear,
    };

/// The `mode` uniform value for a [GpuPipelineKind].
///
/// The constants are declared to be equal to the enum's indices, and this
/// still switches rather than calling `.index`: the equality is an invariant
/// that a test asserts, not a fact to be relied on silently at a call site.
int metalPipelineMode(GpuPipelineKind kind) => switch (kind) {
      GpuPipelineKind.solid => kMetalModeSolid,
      GpuPipelineKind.coverageMask => kMetalModeCoverageMask,
      GpuPipelineKind.texturedImage => kMetalModeTexturedImage,
    };

/// The number of drawables a `CAMetalLayer` may hand out.
///
/// Three - the triple buffering section 20 asks for, and the layer's own
/// default. Two would stall the CPU on `nextDrawable` whenever the GPU is a
/// frame behind; the layer refuses anything above three.
///
/// **Only the in-process presenter uses this.** On the `appkitNativeHost`
/// path, which ADR 0005 chose, the layer lives in the host process and the
/// buffering is `surface_pool.dart`'s slot rotation instead.
const int kMetalMaximumDrawableCount = 3;
