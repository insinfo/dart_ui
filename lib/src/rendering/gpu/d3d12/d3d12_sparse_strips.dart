/// Direct3D 12 submission contract and HLSL for the backend-neutral
/// sparse-strip plan.
///
/// This is `gl_sparse_strips.dart` transposed, deliberately line for line, for
/// the same reason `d3d12_shaders.dart` is a transposition of `gl_shaders.dart`:
/// the two backends are compared against the *same* CPU rasteriser, so a
/// difference between them has to be a bug in one of them rather than a
/// difference of intent between two shader authors.
///
/// ## What changes on this API, and what deliberately does not
///
/// **The quad, the instance and the coverage semantics do not change.** Six
/// floats per instance - device `x, y, width, height`, then alpha-atlas
/// `x, y` - four vertices of a triangle strip built from the vertex index, an
/// integer `Load` of the alpha page rather than a filtered sample, and the same
/// premultiply-then-scale order for gradients. Every one of those is a
/// correctness decision that was made once in the GL executor and is being
/// re-used, not re-decided.
///
/// **Three things do change, and all three are Direct3D facts:**
///
///   1. *No `uYFlip`.* Direct3D writes render-target row 0 at the top, so the
///      single arithmetic flip in the vertex stage is the whole conversion.
///      See the orientation section of `d3d12_shaders.dart`; the constant does
///      not even exist here because the sparse path has no
///      render-into-texture case that would need it.
///   2. *No attribute rebasing.* Core GL 3.3 has no base-instance draw, so the
///      GL executor re-points `glVertexAttribPointer` before every command.
///      `DrawInstanced` takes a `StartInstanceLocation` that offsets the
///      per-instance fetch, so a command here is one draw call with a first
///      instance and nothing else. [SparseD3d12Submission] therefore exposes
///      [SparseD3d12Submission.commandFirstInstance] directly and has no
///      offset-in-bytes accessor at all.
///   3. *No uniforms.* Every scalar is a 32-bit root constant, packed into one
///      `cbuffer` at `b0`. [kD3d12SparseRootConstantCount] is the length of
///      that packing and is load-bearing twice - it is `Num32BitValues` in the
///      root signature and the count passed to
///      `SetGraphicsRoot32BitConstants`.
///
/// ## Two descriptor tables, not one
///
/// The alpha page and the gradient lookup table are two separate descriptors in
/// the device's flat shader-visible heap, and nothing makes them adjacent: the
/// page is allocated when a frame first needs it and the ramp when a gradient
/// is first drawn. A single two-descriptor table would require them to be
/// contiguous, so there are two single-descriptor tables instead. The cost is
/// one extra root parameter; the alternative was a second descriptor heap whose
/// only job is to hold copies of descriptors that already exist.
library;

import 'dart:typed_data';

import '../vector/sparse_strip_draw_plan.dart';

/// Six floats per instance: device `x, y, width, height`, then alpha-atlas
/// `x, y`. Solid instances leave the atlas origin at zero.
const int kD3d12SparseInstanceFloatCount = 6;
const int kD3d12SparseInstanceStrideBytes = kD3d12SparseInstanceFloatCount * 4;
const int kD3d12SparseQuadRectOffsetBytes = 0;
const int kD3d12SparseAtlasOriginOffsetBytes = 4 * 4;

/// Values of the `uMode` root constant. Same numbers as `kSparseGlMode*`.
const int kD3d12SparseModeSolid = 0;
const int kD3d12SparseModeAlpha = 1;

/// Values of the `uPaintMode` root constant, independent from whether coverage
/// is solid or alpha8. Same numbers as `kSparseGlPaint*`.
const int kD3d12SparsePaintSolid = 0;
const int kD3d12SparsePaintGradient = 1;

/// `mode, material, atlasPage, firstInstance, instanceCount`.
const int kD3d12SparseCommandStride = 5;

/// Where each scalar lives inside the root-constant block, in 32-bit words.
///
/// These are offsets into the `cbuffer` below, which HLSL packs into `float4`
/// registers with the one rule that a vector may not *straddle* a 16-byte
/// boundary. Every entry here was placed so that it does not: the two `float2`s
/// sit in `.xy` and `.zw` of their register, and every `float4` starts one.
/// A scalar moved without moving its declaration writes into the wrong
/// register and the shader reads a colour where it expected a matrix row.
abstract final class D3d12SparseRootConstant {
  static const int viewport = 0; // float2
  static const int mode = 2; // uint
  static const int paintMode = 3; // uint
  static const int color = 4; // float4, premultiplied
  static const int gradientKind = 8; // uint
  static const int gradientSpread = 9; // uint
  static const int gradientLookup = 10; // float2: scale, bias
  static const int targetToLocal0 = 12; // float4
  static const int targetToLocal1 = 16; // float4
  static const int gradientGeometry0 = 20; // float4
  static const int gradientGeometry1 = 24; // float4
}

/// How many 32-bit values the sparse root constants occupy.
const int kD3d12SparseRootConstantCount = 28;

/// Root-signature parameter indices.
const int kD3d12SparseRootConstantsSlot = 0;
const int kD3d12SparseRootAlphaAtlasSlot = 1;
const int kD3d12SparseRootGradientLutSlot = 2;
const int kD3d12SparseRootParameterCount = 3;

/// One instanced vertex element, in input-layout order.
final class D3d12SparseInputElement {
  const D3d12SparseInputElement({
    required this.name,
    required this.semanticName,
    required this.semanticIndex,
    required this.components,
    required this.offsetBytes,
  });

  /// The HLSL field name, for the contract check below.
  final String name;

  /// The semantic Direct3D matches the element by. Both elements are
  /// `TEXCOORD` with different *indices*, which is how Direct3D spells what
  /// GLSL spells with two attribute names - and the index is part of the
  /// match, so an atlas origin bound to `TEXCOORD0` would silently become the
  /// quad rectangle and every strip would sample and cover the wrong pixels.
  final String semanticName;
  final int semanticIndex;
  final int components;
  final int offsetBytes;

  int get strideBytes => kD3d12SparseInstanceStrideBytes;

  /// Both elements advance once per quad, not once per corner vertex.
  int get instanceDataStepRate => 1;
}

const List<D3d12SparseInputElement> kD3d12SparseInputElements =
    <D3d12SparseInputElement>[
  D3d12SparseInputElement(
    name: 'quadRect',
    semanticName: 'TEXCOORD',
    semanticIndex: 0,
    components: 4,
    offsetBytes: kD3d12SparseQuadRectOffsetBytes,
  ),
  D3d12SparseInputElement(
    name: 'atlasOrigin',
    semanticName: 'TEXCOORD',
    semanticIndex: 1,
    components: 2,
    offsetBytes: kD3d12SparseAtlasOriginOffsetBytes,
  ),
];

/// The names declared in the root-constant block, in packing order.
const List<String> kD3d12SparseRootConstantNames = <String>[
  'uViewport',
  'uMode',
  'uPaintMode',
  'uColor',
  'uGradientKind',
  'uGradientSpread',
  'uGradientLookup',
  'uTargetToLocal0',
  'uTargetToLocal1',
  'uGradientGeometry0',
  'uGradientGeometry1',
];

/// The shared declarations, so the two stages cannot disagree about the
/// interpolants or about which dword of the root constants means what.
const String _shared = '''
cbuffer SparseConstants : register(b0) {
  float2 uViewport;
  uint uMode;
  uint uPaintMode;
  float4 uColor;
  uint uGradientKind;
  uint uGradientSpread;
  float2 uGradientLookup;
  float4 uTargetToLocal0;
  float4 uTargetToLocal1;
  float4 uGradientGeometry0;
  float4 uGradientGeometry1;
};

struct SparseVarying {
  float4 position       : SV_Position;
  float2 atlasTexel     : TEXCOORD0;
  float2 targetPosition : TEXCOORD1;
};
''';

/// The vertex stage, entry point `vsSparse`, target `vs_5_0`.
const String kD3d12SparseVertexShader = '''
$_shared

struct SparseInstance {
  float4 quadRect    : TEXCOORD0;
  float2 atlasOrigin : TEXCOORD1;
};

SparseVarying vsSparse(SparseInstance input, uint vertexId : SV_VertexID) {
  SparseVarying output;
  // Four vertices form a triangle strip: TL, TR, BL, BR. SV_VertexID makes
  // the immutable unit quad free: the only uploaded data is per-instance.
  float2 corner = float2(float(vertexId & 1), float((vertexId >> 1) & 1));
  float2 devicePosition = input.quadRect.xy + corner * input.quadRect.zw;
  output.atlasTexel = input.atlasOrigin + corner * input.quadRect.zw;
  output.targetPosition = devicePosition;
  // Device space is y-down from the top-left corner; normalised device
  // coordinates are y-up from the middle. Direct3D writes render-target row 0
  // at the top, so this single flip is the whole conversion and there is no
  // uYFlip - see the library comment.
  output.position = float4(
      devicePosition.x / uViewport.x * 2.0 - 1.0,
      1.0 - devicePosition.y / uViewport.y * 2.0,
      0.0,
      1.0);
  return output;
}
''';

/// The pixel stage, entry point `psSparse`, target `ps_5_0`.
///
/// The two branches are uniform across a whole draw: a command contains either
/// solid interiors or one alpha-atlas page, and one material.
const String kD3d12SparsePixelShader = '''
$_shared

Texture2D uAlphaAtlas : register(t0);
Texture2D uGradientLut : register(t1);
SamplerState uLinear : register(s0);

float gradientParameter(float2 targetPosition) {
  float2 local = float2(
      dot(uTargetToLocal0.xyz, float3(targetPosition, 1.0)),
      dot(uTargetToLocal1.xyz, float3(targetPosition, 1.0)));
  if (uGradientKind == 1) {
    float2 direction = uGradientGeometry0.zw - uGradientGeometry0.xy;
    float lengthSquared = dot(direction, direction);
    return lengthSquared == 0.0
        ? 0.0
        : dot(local - uGradientGeometry0.xy, direction) / lengthSquared;
  }

  float2 center = uGradientGeometry0.xy;
  float radius = uGradientGeometry0.z;
  float2 focus = float2(uGradientGeometry0.w, uGradientGeometry1.x);
  float2 ray = local - focus;
  if (all(ray == float2(0.0, 0.0))) return 0.0;
  if (all(focus == center)) return length(ray) / radius;
  float2 focusFromCenter = focus - center;
  float a = dot(ray, ray);
  float b = 2.0 * dot(focusFromCenter, ray);
  float c = dot(focusFromCenter, focusFromCenter) - radius * radius;
  float discriminant = b * b - 4.0 * a * c;
  if (a == 0.0 || discriminant < 0.0) return 0.0;
  float root = sqrt(discriminant);
  float first = (-b - root) / (2.0 * a);
  float second = (-b + root) / (2.0 * a);
  float scale = max(first > 0.0 ? first : 0.0,
                    second > 0.0 ? second : 0.0);
  return scale > 0.0 ? 1.0 / scale : 0.0;
}

float spreadGradient(float parameter) {
  if (uGradientSpread == 1) return frac(parameter);
  if (uGradientSpread == 2) {
    // GLSL's mod, not HLSL's fmod: fmod truncates towards zero and would
    // reflect a negative parameter through the wrong half of the ramp.
    float repeated = parameter - 2.0 * floor(parameter / 2.0);
    return repeated <= 1.0 ? repeated : 2.0 - repeated;
  }
  return clamp(parameter, 0.0, 1.0);
}

float4 psSparse(SparseVarying input) : SV_Target {
  float coverage = 1.0;
  if (uMode == 1) {
    // Device rectangles and atlas placements are integer-aligned. At pixel
    // centres the interpolated coordinate is texel + 0.5; floor therefore
    // names the exact alpha8 texel without normalised-UV rounding or
    // filtering, which is what texelFetch does in the GL shader.
    int2 texel = int2(floor(input.atlasTexel));
    coverage = uAlphaAtlas.Load(int3(texel, 0)).r;
  }
  if (uPaintMode == 1) {
    float parameter = spreadGradient(gradientParameter(input.targetPosition));
    float coordinate = parameter * uGradientLookup.x + uGradientLookup.y;
    // SampleLevel rather than Sample: the ramp has one mip level, so the
    // result is identical, and an explicit level keeps the fetch out from
    // under flow control where the compiler is entitled to warn about
    // derivatives.
    float4 straight =
        uGradientLut.SampleLevel(uLinear, float2(coordinate, 0.5), 0.0);
    straight.rgb *= straight.a;
    return straight * coverage;
  }
  return uColor * coverage;
}
''';

/// Entry point names, passed to `D3DCompile` as ASCII.
const String kD3d12SparseVertexEntryPoint = 'vsSparse';
const String kD3d12SparsePixelEntryPoint = 'psSparse';

/// Compilation targets. Shader Model 5.0 for the reason
/// `d3d12_shaders.dart` gives: every device that answers `D3D12CreateDevice`
/// supports it, and nothing here needs 5.1.
const String kD3d12SparseVertexTarget = 'vs_5_0';
const String kD3d12SparsePixelTarget = 'ps_5_0';

/// Checks the Dart-side element and root-constant contract against the HLSL.
///
/// A driver can run this before compiling; tests run it unconditionally, so a
/// renamed shader input cannot silently corrupt the instance buffer or leave a
/// root constant writing into a register nobody reads.
void validateD3d12SparseShaderContract() {
  for (final D3d12SparseInputElement element in kD3d12SparseInputElements) {
    final String declaration = '${element.components == 4 ? 'float4' : 'float2'}'
        ' ${element.name}';
    if (!kD3d12SparseVertexShader.contains(declaration)) {
      throw StateError('missing sparse HLSL input element: $declaration');
    }
    final String semantic =
        ': ${element.semanticName}${element.semanticIndex};';
    if (!kD3d12SparseVertexShader.contains(semantic)) {
      throw StateError('missing sparse HLSL semantic: $semantic');
    }
  }
  for (final String name in kD3d12SparseRootConstantNames) {
    if (!_shared.contains(' $name;')) {
      throw StateError('missing sparse HLSL root constant: $name');
    }
  }
  if (kD3d12SparseRootConstantCount !=
      D3d12SparseRootConstant.gradientGeometry1 + 4) {
    throw StateError(
      'kD3d12SparseRootConstantCount does not cover the declared block',
    );
  }
}

/// Reusable Direct3D-oriented instance and command arenas built from a
/// [SparseStripDrawPlan].
///
/// A near-duplicate of `SparseGlSubmission` on purpose. The two files are held
/// parallel so the parity test between them means something, and merging them
/// into `rendering/gpu/vector` is a change that has to move the GL side at the
/// same moment - see the library comment on why the D3D12 commands carry a
/// first *instance* where the GL ones carry a byte offset.
final class SparseD3d12Submission {
  SparseD3d12Submission({int initialInstances = 256, int initialCommands = 64})
      : _instances = Float32List(
          _positive(initialInstances, 'initialInstances') *
              kD3d12SparseInstanceFloatCount,
        ),
        _commands = Int32List(
          _positive(initialCommands, 'initialCommands') *
              kD3d12SparseCommandStride,
        );

  Float32List _instances;
  Int32List _commands;
  int _instanceCount = 0;
  int _commandCount = 0;
  int _growths = 0;

  int get instanceCount => _instanceCount;
  int get commandCount => _commandCount;
  int get arenaGrowths => _growths;

  Float32List get instanceStorage => _instances;
  Int32List get commandStorage => _commands;

  Float32List get instances => Float32List.sublistView(
        _instances,
        0,
        _instanceCount * kD3d12SparseInstanceFloatCount,
      );

  Int32List get commands => Int32List.sublistView(
        _commands,
        0,
        _commandCount * kD3d12SparseCommandStride,
      );

  int commandMode(int command) => _commandField(command, 0);
  int commandMaterial(int command) => _commandField(command, 1);
  int commandAtlasPage(int command) => _commandField(command, 2);

  /// The `StartInstanceLocation` of this command's `DrawInstanced`.
  int commandFirstInstance(int command) => _commandField(command, 3);
  int commandInstanceCount(int command) => _commandField(command, 4);

  double instanceX(int instance) => _instanceField(instance, 0);
  double instanceY(int instance) => _instanceField(instance, 1);
  double instanceWidth(int instance) => _instanceField(instance, 2);
  double instanceHeight(int instance) => _instanceField(instance, 3);
  double instanceAtlasX(int instance) => _instanceField(instance, 4);
  double instanceAtlasY(int instance) => _instanceField(instance, 5);

  /// Re-encodes [plan] while retaining the high-water typed-array arenas.
  void encode(SparseStripDrawPlan plan) {
    _instanceCount = 0;
    _commandCount = 0;
    for (var batch = 0; batch < plan.batchCount; batch++) {
      final int material = plan.batchMaterial(batch);
      final int solidCount = plan.batchSolidCount(batch);
      if (solidCount != 0) {
        final int first = _instanceCount;
        final int end = plan.batchSolidFirst(batch) + solidCount;
        for (var i = plan.batchSolidFirst(batch); i < end; i++) {
          _appendInstance(
            plan.solidX(i),
            plan.solidY(i),
            plan.solidWidth(i),
            plan.solidHeight(i),
            0,
            0,
          );
        }
        _appendCommand(kD3d12SparseModeSolid, material, -1, first, solidCount);
      }

      final int alphaEnd =
          plan.batchAlphaFirst(batch) + plan.batchAlphaCount(batch);
      var alpha = plan.batchAlphaFirst(batch);
      while (alpha < alphaEnd) {
        final int page = plan.alphaAtlasPage(alpha);
        final int first = _instanceCount;
        var count = 0;
        do {
          _appendInstance(
            plan.alphaX(alpha),
            plan.alphaY(alpha),
            plan.alphaWidth(alpha),
            plan.alphaHeight(alpha),
            plan.alphaAtlasX(alpha),
            plan.alphaAtlasY(alpha),
          );
          count++;
          alpha++;
        } while (alpha < alphaEnd && plan.alphaAtlasPage(alpha) == page);
        _appendCommand(kD3d12SparseModeAlpha, material, page, first, count);
      }
    }
  }

  void _appendInstance(
    int x,
    int y,
    int width,
    int height,
    int atlasX,
    int atlasY,
  ) {
    _ensureInstanceCapacity(_instanceCount + 1);
    final int base = _instanceCount * kD3d12SparseInstanceFloatCount;
    _instances[base] = x.toDouble();
    _instances[base + 1] = y.toDouble();
    _instances[base + 2] = width.toDouble();
    _instances[base + 3] = height.toDouble();
    _instances[base + 4] = atlasX.toDouble();
    _instances[base + 5] = atlasY.toDouble();
    _instanceCount++;
  }

  void _appendCommand(
    int mode,
    int material,
    int atlasPage,
    int first,
    int count,
  ) {
    _ensureCommandCapacity(_commandCount + 1);
    final int base = _commandCount * kD3d12SparseCommandStride;
    _commands[base] = mode;
    _commands[base + 1] = material;
    _commands[base + 2] = atlasPage;
    _commands[base + 3] = first;
    _commands[base + 4] = count;
    _commandCount++;
  }

  void _ensureInstanceCapacity(int count) {
    final int required = count * kD3d12SparseInstanceFloatCount;
    if (required <= _instances.length) return;
    var length = _instances.length * 2;
    while (length < required) {
      length *= 2;
    }
    _instances = Float32List(length)..setRange(0, _instances.length, _instances);
    _growths++;
  }

  void _ensureCommandCapacity(int count) {
    final int required = count * kD3d12SparseCommandStride;
    if (required <= _commands.length) return;
    var length = _commands.length * 2;
    while (length < required) {
      length *= 2;
    }
    _commands = Int32List(length)..setRange(0, _commands.length, _commands);
    _growths++;
  }

  double _instanceField(int instance, int field) {
    if (instance < 0 || instance >= _instanceCount) {
      throw RangeError.index(instance, _instances, 'instance');
    }
    return _instances[instance * kD3d12SparseInstanceFloatCount + field];
  }

  int _commandField(int command, int field) {
    if (command < 0 || command >= _commandCount) {
      throw RangeError.index(command, _commands, 'command');
    }
    return _commands[command * kD3d12SparseCommandStride + field];
  }
}

int _positive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'must be > 0');
  return value;
}
