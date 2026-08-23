/// A SPIR-V module builder, in Dart, for the shaders this backend needs.
///
/// ## Why the shaders are not GLSL, and not a checked-in blob either
///
/// Every other backend here hands the driver *source*: `gl_shaders.dart` gives
/// GL a GLSL string and `glCompileShader` compiles it, `d3d11_shaders.dart`
/// gives Direct3D an HLSL string and `d3dcompiler_47.dll` compiles it. Vulkan
/// has no such entry point. `vkCreateShaderModule` takes SPIR-V words and
/// nothing else, and turning GLSL into SPIR-V needs `glslang` or `shaderc` -
/// a native library this repository does not ship, cannot build from Dart, and
/// would have to find on every developer's machine and on CI.
///
/// That leaves two honest options and one dishonest one.
///
///   1. **A pre-compiled blob**, checked in as a `Uint32List` literal or a
///      base64 string, produced once by somebody's local `glslangValidator`.
///      This is what most bindings do, and it is the option the brief calls
///      "debt worse than absence": the words are unreadable, the GLSL that
///      produced them drifts out of the tree or out of date, and regenerating
///      it requires a tool nobody has installed. A reviewer cannot tell a
///      correct blob from a wrong one, and neither can a test.
///   2. **Generating the SPIR-V here**, which is what this file does. SPIR-V
///      is not a compiler target in the difficult sense - it is a flat,
///      regular, fully specified binary form, and the shaders this renderer
///      needs are forty instructions of straight-line arithmetic with no
///      control flow at all. Emitting them directly costs this file and buys:
///      the shader is *readable Dart* that a reviewer can follow instruction
///      by instruction; it is regenerated on every run, so it can never be
///      stale; it needs no tool, so CI on Linux and macOS builds the same
///      words as a developer on Windows; and it is checkable without a GPU,
///      which is what `vulkan_spirv_test.dart` does on every runner.
///   3. Shipping GLSL and hoping for a runtime compiler. There isn't one.
///
/// ## How the output is verified
///
/// Three independent checks, because "it produced some words" is not a result:
///
///   * **Structural, with no GPU** - the magic number, the version, that the
///     declared id bound really exceeds every id used, that every instruction's
///     word count matches its operand list, and that the sections appear in
///     the order the specification's logical layout fixes. A module that fails
///     any of these is malformed in a way a driver is permitted to crash on.
///   * **The driver itself.** `vkCreateShaderModule` and, more usefully,
///     `vkCreateGraphicsPipelines` parse and consume the module; a pipeline
///     that is created at all is a module the driver accepted. With the
///     Khronos validation layer present, the full SPIR-V validator runs over
///     it and reports by name.
///   * **The pixels.** `vulkan_cpu_parity_test.dart` compares what these
///     shaders draw against the CPU rasteriser. An instruction stream that
///     assembles and validates and multiplies the wrong pair of operands is
///     caught there and nowhere else.
///
/// ## What this is not
///
/// It is not a GLSL compiler and must not grow into one. There is no parser,
/// no name resolution and no register allocation: ids are handed out in
/// sequence, every value is written once, and the result is already SSA
/// because straight-line arithmetic in a builder is SSA by construction. The
/// day this renderer needs a loop in a shader is the day to reconsider - and
/// the reconsideration should be a `OpLoopMerge` in [SpirvBuilder], not a
/// dependency on `shaderc`.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// The numbers from the SPIR-V specification, named
// ---------------------------------------------------------------------------

/// `SpvMagicNumber`. The first word of every SPIR-V module.
const int kSpirvMagic = 0x07230203;

/// SPIR-V 1.0, which is what Vulkan 1.0 consumes and what every later Vulkan
/// still accepts. Nothing here needs a later version, and asking for one would
/// refuse drivers for no gain.
const int kSpirvVersion1_0 = 0x00010000;

/// The generator word. The high 16 bits are a vendor id registered with
/// Khronos and the low 16 are the generator's own version; 0 is the reserved
/// "unknown generator" value, which is the honest answer for a builder that is
/// not in the registry.
const int kSpirvGeneratorUnknown = 0;

// Opcodes.
const int _opExtInstImport = 11;
const int _opExtInst = 12;
const int _opMemoryModel = 14;
const int _opEntryPoint = 15;
const int _opExecutionMode = 16;
const int _opCapability = 17;
const int _opTypeVoid = 19;
const int _opTypeBool = 20;
const int _opTypeInt = 21;
const int _opTypeFloat = 22;
const int _opTypeVector = 23;
const int _opTypeImage = 25;
const int _opTypeSampledImage = 27;
const int _opTypeStruct = 30;
const int _opTypePointer = 32;
const int _opTypeFunction = 33;
const int _opConstant = 43;
const int _opConstantComposite = 44;
const int _opFunction = 54;
const int _opFunctionEnd = 56;
const int _opVariable = 59;
const int _opLoad = 61;
const int _opStore = 62;
const int _opAccessChain = 65;
const int _opDecorate = 71;
const int _opMemberDecorate = 72;
const int _opVectorShuffle = 79;
const int _opCompositeConstruct = 80;
const int _opCompositeExtract = 81;
const int _opImageSampleImplicitLod = 87;
const int _opImageSampleExplicitLod = 88;
const int _opImageFetch = 95;
const int _opImage = 100;
const int _opConvertFToS = 110;
const int _opConvertSToF = 111;
const int _opFNegate = 127;
const int _opFAdd = 129;
const int _opFSub = 131;
const int _opFMul = 133;
const int _opFDiv = 136;
const int _opVectorTimesScalar = 142;
const int _opDot = 148;
const int _opLogicalOr = 166;
const int _opLogicalAnd = 167;
const int _opSelect = 169;
const int _opIEqual = 170;
const int _opFOrdEqual = 180;
const int _opFOrdLessThan = 184;
const int _opFOrdGreaterThan = 186;
const int _opFOrdLessThanEqual = 188;
const int _opShiftRightLogical = 194;
const int _opBitwiseAnd = 199;
const int _opLabel = 248;
const int _opReturn = 253;

/// `SpvCapabilityShader` - graphics, as opposed to Kernel.
const int kSpirvCapabilityShader = 1;

/// `SpvAddressingModelLogical` / `SpvMemoryModelGLSL450`, which is the pair
/// Vulkan requires of a graphics module.
const int kSpirvAddressingModelLogical = 0;
const int kSpirvMemoryModelGlsl450 = 1;

const int kSpirvExecutionModelVertex = 0;
const int kSpirvExecutionModelFragment = 4;

/// `SpvExecutionModeOriginUpperLeft`, the only origin Vulkan allows a fragment
/// shader to declare.
const int kSpirvExecutionModeOriginUpperLeft = 7;

const int kSpirvStorageClassUniformConstant = 0;
const int kSpirvStorageClassInput = 1;
const int kSpirvStorageClassOutput = 3;
const int kSpirvStorageClassPushConstant = 9;

const int kSpirvDecorationBlock = 2;
const int kSpirvDecorationBuiltIn = 11;
const int kSpirvDecorationLocation = 30;
const int kSpirvDecorationBinding = 33;
const int kSpirvDecorationDescriptorSet = 34;
const int kSpirvDecorationOffset = 35;

const int kSpirvBuiltInPosition = 0;

/// `SpvBuiltInVertexIndex`. Vulkan's `gl_VertexIndex`, which is a *signed*
/// 32-bit integer; the unsigned `VertexId` of OpenGL is a different builtin
/// and is not available to a Vulkan shader at all.
const int kSpirvBuiltInVertexIndex = 42;

/// `SpvImageOperandsLodMask`. Not optional for [SpirvFunction.fetch]: an
/// `OpImageFetch` from a non-multisampled image must state its level, and one
/// that omits the operand is a module the validator rejects.
const int kSpirvImageOperandsLod = 0x2;

const int kSpirvDim2D = 1;
const int kSpirvImageFormatUnknown = 0;

const int kSpirvFunctionControlNone = 0;

/// The name of the extended instruction set `OpExtInst` draws `FMin`, `FMax`
/// and `FClamp` from.
const String kGlslStd450 = 'GLSL.std.450';

/// `GLSLstd450FMin`, `FMax` and `FClamp`, which are the only three needed.
///
/// Written out rather than transcribing the whole set for the same reason
/// `vulkan_constants.dart` gives: a number nobody uses is a number nobody
/// checks.
const int kGlslStd450Floor = 8;
const int kGlslStd450Fract = 10;
const int kGlslStd450Sqrt = 31;
const int kGlslStd450FMin = 37;
const int kGlslStd450FMax = 40;
const int kGlslStd450FClamp = 43;

// ---------------------------------------------------------------------------
// The builder
// ---------------------------------------------------------------------------

/// A SPIR-V module under construction.
///
/// Instructions go into the section the specification's logical layout puts
/// them in, and [assemble] concatenates the sections in that order. Getting
/// the order wrong is one of the few ways to produce words that a validator
/// rejects and a permissive driver silently mis-reads, so the caller cannot
/// choose it: there is no "emit raw instruction" method.
final class SpirvBuilder {
  final List<int> _capabilities = <int>[];
  final List<int> _extImports = <int>[];
  final List<int> _memoryModel = <int>[];
  final List<int> _entryPoints = <int>[];
  final List<int> _executionModes = <int>[];
  final List<int> _decorations = <int>[];
  final List<int> _declarations = <int>[];
  final List<int> _functions = <int>[];

  /// Ids start at 1: 0 is not a valid SPIR-V id, and the header's bound is
  /// "one past the largest id", so a module whose bound is 1 declares nothing.
  int _nextId = 1;

  /// Types and constants are interned. Not as an optimisation - a module with
  /// two `OpTypeFloat 32` instructions is *invalid*, because SPIR-V requires
  /// the aggregate and scalar type declarations to be unique.
  final Map<String, int> _interned = <String, int>{};

  int get idBound => _nextId;

  /// A fresh id. Handed out in sequence, never reused.
  int freshId() => _nextId++;

  void capability(int capability) =>
      _write(_capabilities, _opCapability, <int>[capability]);

  /// Imports an extended instruction set and returns the id [extInst] takes.
  int extInstImport(String name) {
    final int id = freshId();
    _write(_extImports, _opExtInstImport, <int>[id, ...literalString(name)]);
    return id;
  }

  void memoryModel(int addressing, int memory) =>
      _write(_memoryModel, _opMemoryModel, <int>[addressing, memory]);

  /// Declares an entry point.
  ///
  /// [interface] must list every Input and Output variable the entry point
  /// touches, transitively. SPIR-V 1.0 requires exactly those two storage
  /// classes and no others; a module that also lists its uniforms is invalid
  /// under 1.0 even though 1.4 made it legal, which is the sort of difference
  /// that makes a shader work on one driver and not the next.
  void entryPoint(int model, int function, String name, List<int> interface) =>
      _write(_entryPoints, _opEntryPoint,
          <int>[model, function, ...literalString(name), ...interface]);

  void executionMode(int function, int mode) =>
      _write(_executionModes, _opExecutionMode, <int>[function, mode]);

  void decorate(int target, int decoration, [List<int> operands = const []]) =>
      _write(_decorations, _opDecorate, <int>[target, decoration, ...operands]);

  void memberDecorate(int structure, int member, int decoration,
          [List<int> operands = const []]) =>
      _write(_decorations, _opMemberDecorate,
          <int>[structure, member, decoration, ...operands]);

  // -- types -----------------------------------------------------------------

  int typeVoid() => _intern('void', (int id) {
        _write(_declarations, _opTypeVoid, <int>[id]);
      });

  int typeInt(int width, {required bool signed}) =>
      _intern('int$width${signed ? 's' : 'u'}', (int id) {
        _write(_declarations, _opTypeInt, <int>[id, width, signed ? 1 : 0]);
      });

  int typeFloat(int width) => _intern('float$width', (int id) {
        _write(_declarations, _opTypeFloat, <int>[id, width]);
      });

  /// `OpTypeBool`. A *value* type only: SPIR-V forbids a bool in any storage
  /// class a shader interface can reach, and nothing below wants one there. It
  /// exists so [SpirvFunction.select] has a condition to take.
  int typeBool() => _intern('bool', (int id) {
        _write(_declarations, _opTypeBool, <int>[id]);
      });

  int typeVector(int component, int count) =>
      _intern('vec$component:$count', (int id) {
        _write(_declarations, _opTypeVector, <int>[id, component, count]);
      });

  int typeStruct(List<int> members) =>
      _intern('struct${members.join(",")}', (int id) {
        _write(_declarations, _opTypeStruct, <int>[id, ...members]);
      });

  int typePointer(int storageClass, int type) =>
      _intern('ptr$storageClass:$type', (int id) {
        _write(_declarations, _opTypePointer, <int>[id, storageClass, type]);
      });

  int typeFunction(int returnType, List<int> parameters) =>
      _intern('fn$returnType(${parameters.join(",")})', (int id) {
        _write(_declarations, _opTypeFunction,
            <int>[id, returnType, ...parameters]);
      });

  /// A 2D, non-arrayed, single-sampled, sampled image of [sampledType].
  ///
  /// The `Sampled` operand is 1, meaning "will be used with a sampler". Zero
  /// would mean "unknown at compile time", which Vulkan forbids, and 2 would
  /// mean a storage image. Getting it wrong produces a module that fails
  /// pipeline creation with a message about the descriptor type not matching.
  int typeImage2D(int sampledType) => _intern('image2d$sampledType', (int id) {
        _write(_declarations, _opTypeImage, <int>[
          id,
          sampledType,
          kSpirvDim2D,
          0, // Depth: not a depth image
          0, // Arrayed
          0, // MS
          1, // Sampled: used with a sampler
          kSpirvImageFormatUnknown,
        ]);
      });

  int typeSampledImage(int imageType) => _intern('sampled$imageType', (int id) {
        _write(_declarations, _opTypeSampledImage, <int>[id, imageType]);
      });

  // -- constants -------------------------------------------------------------

  /// A 32-bit float constant, interned on its **bit pattern**.
  ///
  /// On the bits and not on the Dart double, because `-0.0 == 0.0` in Dart and
  /// the two are different constants in SPIR-V.
  int constantFloat(int floatType, double value) {
    final int bits = _floatBits(value);
    return _intern('cf$floatType:$bits', (int id) {
      _write(_declarations, _opConstant, <int>[floatType, id, bits]);
    });
  }

  int constantInt(int intType, int value) =>
      _intern('ci$intType:$value', (int id) {
        _write(
            _declarations, _opConstant, <int>[intType, id, value & 0xFFFFFFFF]);
      });

  int constantComposite(int type, List<int> components) =>
      _intern('cc$type:${components.join(",")}', (int id) {
        _write(_declarations, _opConstantComposite,
            <int>[type, id, ...components]);
      });

  /// A module-scope variable. Function-scope variables are deliberately absent:
  /// nothing here needs one, and one emitted in the wrong place inside a block
  /// is invalid SPIR-V.
  int variable(int pointerType, int storageClass) {
    final int id = freshId();
    _write(_declarations, _opVariable, <int>[pointerType, id, storageClass]);
    return id;
  }

  // -- functions -------------------------------------------------------------

  /// Opens a function and its first block, and returns a writer for the body.
  ///
  /// One function per module here, always `main`. The writer is what carries
  /// the instruction helpers, so nothing can emit an arithmetic instruction
  /// outside a block by accident.
  SpirvFunction beginFunction(int returnType, int functionType, int id) {
    _write(_functions, _opFunction,
        <int>[returnType, id, kSpirvFunctionControlNone, functionType]);
    _write(_functions, _opLabel, <int>[freshId()]);
    return SpirvFunction._(this);
  }

  /// The assembled module, header first.
  Uint32List assemble() {
    final List<int> words = <int>[
      kSpirvMagic,
      kSpirvVersion1_0,
      kSpirvGeneratorUnknown,
      idBound,
      0, // reserved: instruction schema
      ..._capabilities,
      ..._extImports,
      ..._memoryModel,
      ..._entryPoints,
      ..._executionModes,
      ..._decorations,
      ..._declarations,
      ..._functions,
    ];
    return Uint32List.fromList(words);
  }

  int _intern(String key, void Function(int id) emit) {
    final int? existing = _interned[key];
    if (existing != null) return existing;
    final int id = freshId();
    emit(id);
    _interned[key] = id;
    return id;
  }

  static void _write(List<int> section, int opcode, List<int> operands) {
    section
      ..add(((operands.length + 1) << 16) | opcode)
      ..addAll(operands);
  }

  static int _floatBits(double value) {
    final Float32List one = Float32List(1)..[0] = value;
    return one.buffer.asUint32List()[0];
  }
}

/// The body of a SPIR-V function: one block of straight-line instructions.
///
/// Every method returns the id of the value it produced, so the caller writes
/// what reads as expression code and gets SSA out of it.
final class SpirvFunction {
  SpirvFunction._(this._module);

  final SpirvBuilder _module;

  int load(int type, int pointer) => _value(_opLoad, type, <int>[pointer]);

  void store(int pointer, int value) =>
      SpirvBuilder._write(_module._functions, _opStore, <int>[pointer, value]);

  int accessChain(int pointerType, int base, List<int> indices) =>
      _value(_opAccessChain, pointerType, <int>[base, ...indices]);

  int add(int type, int a, int b) => _value(_opFAdd, type, <int>[a, b]);
  int subtract(int type, int a, int b) => _value(_opFSub, type, <int>[a, b]);
  int multiply(int type, int a, int b) => _value(_opFMul, type, <int>[a, b]);
  int divide(int type, int a, int b) => _value(_opFDiv, type, <int>[a, b]);

  /// `OpVectorTimesScalar`, which is not the same instruction as [multiply]:
  /// `OpFMul` on a vector and a scalar is invalid, because SPIR-V has no
  /// implicit broadcast.
  int scale(int type, int vector, int scalar) =>
      _value(_opVectorTimesScalar, type, <int>[vector, scalar]);

  int extract(int type, int composite, int index) =>
      _value(_opCompositeExtract, type, <int>[composite, index]);

  int construct(int type, List<int> components) =>
      _value(_opCompositeConstruct, type, components);

  int shuffle(int type, int a, int b, List<int> components) =>
      _value(_opVectorShuffle, type, <int>[a, b, ...components]);

  int sample(int type, int sampledImage, int coordinate) =>
      _value(_opImageSampleImplicitLod, type, <int>[sampledImage, coordinate]);

  /// `OpImageSampleExplicitLod` with a Lod operand, which is what the HLSL
  /// twin's `SampleLevel` is.
  ///
  /// Explicit rather than implicit because every image this renderer samples
  /// has exactly one level, so the two give the same texel - and an explicit
  /// level needs no derivatives, which keeps the fetch legal wherever it ends
  /// up standing.
  int sampleLod(int type, int sampledImage, int coordinate, int lod) => _value(
      _opImageSampleExplicitLod,
      type,
      <int>[sampledImage, coordinate, kSpirvImageOperandsLod, lod]);

  /// `OpImage`: the image inside a sampled image.
  ///
  /// [fetch] needs one, because a fetch bypasses the sampler entirely and
  /// SPIR-V spells that by taking the image operand rather than the pair.
  int image(int imageType, int sampledImage) =>
      _value(_opImage, imageType, <int>[sampledImage]);

  /// `OpImageFetch` at [lod], which is GLSL's `texelFetch`.
  ///
  /// [coordinate] is an integer vector and [image] is an image, not a sampled
  /// image - pass [SpirvFunction.image] of the loaded descriptor. The whole
  /// point over [sample] is that no filtering, no normalisation and no
  /// addressing mode stands between the coordinate and the texel.
  int fetch(int type, int image, int coordinate, int lod) => _value(
      _opImageFetch, type, <int>[image, coordinate, kSpirvImageOperandsLod, lod]);

  int negate(int type, int value) => _value(_opFNegate, type, <int>[value]);

  /// `OpDot`. Not [multiply] followed by extracts: a dot product of two
  /// vectors has a *scalar* result type, which `OpFMul` cannot produce.
  int dot(int type, int a, int b) => _value(_opDot, type, <int>[a, b]);

  int bitwiseAnd(int type, int a, int b) =>
      _value(_opBitwiseAnd, type, <int>[a, b]);

  int shiftRight(int type, int value, int shift) =>
      _value(_opShiftRightLogical, type, <int>[value, shift]);

  int convertToSigned(int type, int value) =>
      _value(_opConvertFToS, type, <int>[value]);

  int convertToFloat(int type, int value) =>
      _value(_opConvertSToF, type, <int>[value]);

  /// `OpFOrdEqual`. *Ordered*, so a NaN operand compares false - which is what
  /// GLSL's `==` does and what every guard below relies on.
  int equalFloat(int boolType, int a, int b) =>
      _value(_opFOrdEqual, boolType, <int>[a, b]);

  int lessThanFloat(int boolType, int a, int b) =>
      _value(_opFOrdLessThan, boolType, <int>[a, b]);

  int greaterThanFloat(int boolType, int a, int b) =>
      _value(_opFOrdGreaterThan, boolType, <int>[a, b]);

  int lessThanOrEqualFloat(int boolType, int a, int b) =>
      _value(_opFOrdLessThanEqual, boolType, <int>[a, b]);

  int equalInt(int boolType, int a, int b) =>
      _value(_opIEqual, boolType, <int>[a, b]);

  int logicalAnd(int boolType, int a, int b) =>
      _value(_opLogicalAnd, boolType, <int>[a, b]);

  int logicalOr(int boolType, int a, int b) =>
      _value(_opLogicalOr, boolType, <int>[a, b]);

  /// `OpSelect`, which is how this builder writes a conditional at all.
  ///
  /// It is not a branch: **both** [whenTrue] and [whenFalse] are evaluated,
  /// and only the result is chosen. That is exactly what makes it usable here
  /// - the builder emits one straight-line block and never has to track which
  /// block it is writing into - and it is also the thing to keep in mind when
  /// reading the shaders: a division that would be `0 / 0` on the path not
  /// taken really does execute and really does produce a NaN. Selecting it
  /// away is safe, because `OpSelect` propagates nothing from the operand it
  /// discards. Guarding *before* the arithmetic, as a branch would, is not
  /// available and is not needed.
  int select(int type, int condition, int whenTrue, int whenFalse) =>
      _value(_opSelect, type, <int>[condition, whenTrue, whenFalse]);

  int extInst(int type, int set, int instruction, List<int> operands) =>
      _value(_opExtInst, type, <int>[set, instruction, ...operands]);

  void returnVoid() {
    SpirvBuilder._write(_module._functions, _opReturn, const <int>[]);
    SpirvBuilder._write(_module._functions, _opFunctionEnd, const <int>[]);
  }

  int _value(int opcode, int type, List<int> operands) {
    final int id = _module.freshId();
    SpirvBuilder._write(
        _module._functions, opcode, <int>[type, id, ...operands]);
    return id;
  }
}

/// A SPIR-V literal string: NUL-terminated, then padded with zeroes to a whole
/// number of words, packed little-endian.
///
/// Exposed because the structural test re-derives the words for `"main"` and
/// `"GLSL.std.450"` independently and compares, which is the only way to check
/// the padding rule without reimplementing it in the test.
List<int> literalString(String value) {
  final List<int> bytes = <int>[];
  for (var i = 0; i < value.length; i++) {
    final int unit = value.codeUnitAt(i);
    if (unit == 0 || unit > 0x7F) {
      throw ArgumentError.value(
          value, 'value', 'a SPIR-V literal string is NUL-terminated ASCII');
    }
    bytes.add(unit);
  }
  bytes.add(0);
  while (bytes.length % 4 != 0) {
    bytes.add(0);
  }
  final List<int> words = <int>[];
  for (var i = 0; i < bytes.length; i += 4) {
    words.add(bytes[i] |
        (bytes[i + 1] << 8) |
        (bytes[i + 2] << 16) |
        (bytes[i + 3] << 24));
  }
  return words;
}

/// What a structural check found in a module. Empty means well-formed.
///
/// A list of sentences rather than a bool, because a module that fails this is
/// failing in a specific way - "instruction at word 42 claims 5 words and the
/// module has 3 left" - and a bare `false` sends the reader back to a hex dump.
List<String> validateSpirvStructure(Uint32List words) {
  final List<String> problems = <String>[];
  if (words.length < 5) {
    return <String>[
      'a SPIR-V module is at least 5 header words, got '
          '${words.length}'
    ];
  }
  if (words[0] != kSpirvMagic) {
    problems.add('magic number is 0x${words[0].toRadixString(16)}, not '
        '0x${kSpirvMagic.toRadixString(16)}');
  }
  if (words[1] != kSpirvVersion1_0) {
    problems.add('version is 0x${words[1].toRadixString(16)}, not SPIR-V 1.0');
  }
  final int bound = words[3];
  if (words[4] != 0) problems.add('the reserved schema word is not zero');

  var offset = 5;
  var count = 0;
  var maxId = 0;
  while (offset < words.length) {
    final int wordCount = words[offset] >> 16;
    if (wordCount == 0) {
      problems.add('instruction at word $offset declares a length of zero');
      break;
    }
    if (offset + wordCount > words.length) {
      problems.add('instruction at word $offset claims $wordCount words and '
          'only ${words.length - offset} remain');
      break;
    }
    // Only instructions whose result-id position the specification fixes are
    // consulted. Scanning every operand instead would sweep up literals - the
    // bit pattern of a float constant, the packed characters of a name - and
    // call them ids, which is how a "check" ends up needing a fudge factor
    // that hides the very error it was written for.
    final int? resultPosition = _resultIdPosition[words[offset] & 0xFFFF];
    if (resultPosition != null && offset + 1 + resultPosition < words.length) {
      final int id = words[offset + 1 + resultPosition];
      if (id > maxId) maxId = id;
    }
    offset += wordCount;
    count++;
  }
  if (count == 0) problems.add('the module declares no instructions');
  if (bound <= maxId) {
    problems.add('the id bound $bound does not exceed the largest result id '
        '$maxId');
  }
  return problems;
}

/// Where the result id sits among the operands, for the opcodes this builder
/// emits that define one.
///
/// Partial on purpose: an opcode that is not here contributes nothing to the
/// bound check, which makes the check *weaker* rather than wrong. Adding an
/// entry is how it gets stronger.
const Map<int, int> _resultIdPosition = <int, int>{
  _opExtInstImport: 0,
  _opTypeVoid: 0,
  _opTypeBool: 0,
  _opTypeInt: 0,
  _opTypeFloat: 0,
  _opTypeVector: 0,
  _opTypeImage: 0,
  _opTypeSampledImage: 0,
  _opTypeStruct: 0,
  _opTypePointer: 0,
  _opTypeFunction: 0,
  _opLabel: 0,
  // These carry a result *type* first and the result id second.
  _opConstant: 1,
  _opConstantComposite: 1,
  _opVariable: 1,
  _opFunction: 1,
  _opLoad: 1,
  _opAccessChain: 1,
  _opExtInst: 1,
  _opVectorShuffle: 1,
  _opCompositeConstruct: 1,
  _opCompositeExtract: 1,
  _opImageSampleImplicitLod: 1,
  _opImageSampleExplicitLod: 1,
  _opImageFetch: 1,
  _opImage: 1,
  _opConvertFToS: 1,
  _opConvertSToF: 1,
  _opFNegate: 1,
  _opFAdd: 1,
  _opFSub: 1,
  _opFMul: 1,
  _opFDiv: 1,
  _opVectorTimesScalar: 1,
  _opDot: 1,
  _opLogicalOr: 1,
  _opLogicalAnd: 1,
  _opSelect: 1,
  _opIEqual: 1,
  _opFOrdEqual: 1,
  _opFOrdLessThan: 1,
  _opFOrdGreaterThan: 1,
  _opFOrdLessThanEqual: 1,
  _opShiftRightLogical: 1,
  _opBitwiseAnd: 1,
};
