/// The WGSL the sparse-strip pipeline compiles, and its pure mappings.
///
/// This file is to `gl_sparse_strips.dart` what `wgsl_shaders.dart` is to
/// `gl_shaders.dart`: the same shader, in the language WebGPU speaks, plus the
/// layout constants both the pipeline descriptors and the VM tests derive from.
/// Nothing here imports `dart:js_interop`, so the whole contract - the module
/// source, the entry-point table, the uniform byte layout and the writer that
/// fills a slice - is checkable on a machine with no browser and no GPU.
///
/// ## The instance layout is *shared*, not translated
///
/// `SparseGlSubmission` in `gl_sparse_strips.dart` turns a
/// [SparseStripDrawPlan] into six floats per instance and a list of ordered
/// commands. That encoder contains no GL: it is typed arrays and ordering, and
/// the ordering *is* the correctness property - solid interiors before boundary
/// strips within a path, paths in submission order, alpha instances grouped by
/// atlas page. Re-implementing it here would create a second place for that
/// order to be right, which is one more than the number of places it can be
/// checked. So this backend consumes the same encoder and re-exports its
/// numbers under WebGPU names below; `wgsl_sparse_shaders_test.dart` pins the
/// two together so a change on either side is a failing test rather than a
/// silently different picture.
///
/// The same argument is why `webgl_sparse_driver.dart` runs the *GLSL* out of
/// `gl_sparse_strips.dart` unchanged: WebGL2 is GLES 3.0, and the ES dialect
/// that file already emits is literally the language a browser accepts.
///
/// ## Four fragment entry points, where GL had two uniform branches
///
/// The GL program selects coverage (solid interior or alpha8 strip) with
/// `uMode` and paint (colour or gradient) with `uPaintMode`. WebGPU bakes the
/// blend state into the pipeline, so a material change is a pipeline switch
/// whatever the shader looks like - and `wgsl_shaders.dart` already took the
/// consequence: once a switch is a given, folding the mode into the pipeline
/// deletes a uniform, a branch and a way for the two to disagree. Here that
/// gives four entry points, one per (coverage, paint) pair, and at most
/// 4 x 3 = 12 pipelines for the device's life.
///
/// ## One uniform slice per material, at a dynamic offset
///
/// Everything the fragment stage needs that is not per-vertex - the viewport,
/// the premultiplied colour, the gradient transform, geometry and lookup - is
/// one 112-byte struct. A submission writes one slice per material into a
/// single uniform buffer at [kWebGpuSparseUniformSliceStride] intervals and
/// each command binds group 0 at its material's offset, which is the same
/// dynamic-offset arrangement the dense path uses for its per-pass viewport
/// and for the same reason: `writeBuffer` is ordered against `submit`, so all
/// the slices are written before the command buffer that reads them.
///
/// ## There is no yFlip here either
///
/// For exactly the reason `wgsl_shaders.dart` states at length: WebGPU's
/// framebuffer origin is the top-left corner, so the single projection below is
/// right for a canvas and for a layer texture alike. The GL sparse shader
/// carries `uYFlip` because GL's origin is the bottom-left one; a WGSL port
/// that reintroduced it would draw every layer upside down.
library;

import 'dart:typed_data';

import '../gl/gl_sparse_strips.dart';
import '../gpu_gradient.dart';

/// The vertex entry point. One, shared by all four pipelines.
const String kWgslSparseVertexEntryPoint = 'vs_sparse';

/// The fragment entry point for a (coverage, paint) pair.
///
/// [coverageMode] is [kSparseGlModeSolid] or [kSparseGlModeAlpha];
/// [paintMode] is [kSparseGlPaintSolid] or [kSparseGlPaintGradient] - the same
/// constants the shared submission encoder writes into its commands, so a
/// command can be turned into a pipeline without a translation table in
/// between. Throws rather than defaulting: an unknown mode that quietly became
/// a solid fill would draw a shape in the wrong paint.
String wgslSparseFragmentEntryPoint({
  required int coverageMode,
  required int paintMode,
}) {
  final bool alpha = switch (coverageMode) {
    kSparseGlModeSolid => false,
    kSparseGlModeAlpha => true,
    _ => throw ArgumentError.value(
        coverageMode,
        'coverageMode',
        'must be kSparseGlModeSolid or kSparseGlModeAlpha',
      ),
  };
  return switch (paintMode) {
    kSparseGlPaintSolid =>
      alpha ? 'fs_sparse_solid_strip' : 'fs_sparse_solid_fill',
    kSparseGlPaintGradient =>
      alpha ? 'fs_sparse_gradient_strip' : 'fs_sparse_gradient_fill',
    _ => throw ArgumentError.value(
        paintMode,
        'paintMode',
        'must be kSparseGlPaintSolid or kSparseGlPaintGradient',
      ),
  };
}

/// Every fragment entry point the module declares, in pipeline-key order.
const List<String> kWgslSparseFragmentEntryPoints = <String>[
  'fs_sparse_solid_fill',
  'fs_sparse_solid_strip',
  'fs_sparse_gradient_fill',
  'fs_sparse_gradient_strip',
];

/// Bytes between two instances in the vertex buffer.
///
/// Deliberately an alias of the GL constant rather than a fresh number: the
/// bytes come out of [SparseGlSubmission], and a WebGPU vertex layout that
/// disagreed with it would read a width where an atlas origin lives.
const int kWebGpuSparseInstanceStrideBytes = kSparseGlInstanceStrideBytes;

/// Byte offset of the `x, y, width, height` device rectangle in an instance.
const int kWebGpuSparseQuadRectOffsetBytes = kSparseGlQuadRectOffsetBytes;

/// Byte offset of the alpha-atlas origin in an instance.
const int kWebGpuSparseAtlasOriginOffsetBytes = kSparseGlAtlasOriginOffsetBytes;

/// Shader location of the device rectangle. Matches the GL attribute location.
const int kWebGpuSparseQuadRectLocation = kSparseGlAttributeQuadRect;

/// Shader location of the atlas origin. Matches the GL attribute location.
const int kWebGpuSparseAtlasOriginLocation = kSparseGlAttributeAtlasOrigin;

/// Vertices per instance. Four corners of a quad as a triangle strip, built
/// from `@builtin(vertex_index)` so the only uploaded data is per-instance.
const int kWebGpuSparseVertexCount = 4;

/// The texture format of one alpha-atlas page.
///
/// `r8unorm` is the WebGPU spelling of the `R8`/`GL_RED` page the plan packs
/// and the GL executor uploads. It is sampleable and copy-destination in the
/// core specification, with no optional feature involved, which is what keeps
/// the sparse path available wherever WebGPU itself is.
const String kWebGpuSparseAlphaFormat = 'r8unorm';

/// The texture format of the shared gradient LUT: RGBA8, straight alpha.
const String kWebGpuSparseGradientLutFormat = 'rgba8unorm';

/// Bytes of one material's uniform slice: the `SparseUniforms` struct.
///
/// 112 is what WGSL's own layout rules produce for the struct below - seven
/// 16-byte-aligned vectors ending at 96, two `i32` after them, rounded up to
/// the struct's 16-byte alignment. [writeWebGpuSparseUniformSlice] writes those
/// exact offsets, and a test checks each one, because a Dart writer that
/// drifted from the WGSL layout would put a gradient's focus where its radius
/// belongs and draw a plausible, wrong picture.
const int kWebGpuSparseUniformSliceSize = 112;

/// The stride between two materials' uniform slices, in bytes.
///
/// 256 is `minUniformBufferOffsetAlignment`'s specified default and every
/// dynamic offset must be a multiple of it, exactly as on the dense path.
const int kWebGpuSparseUniformSliceStride = 256;

/// Byte offsets inside one uniform slice.
///
/// Public because two independent things must agree on them: the writer below,
/// and any test that reads a slice back to check what a material became.
abstract final class WebGpuSparseUniformOffset {
  static const int viewport = 0;
  static const int gradientLookup = 8;
  static const int color = 16;
  static const int targetToLocal0 = 32;
  static const int targetToLocal1 = 48;
  static const int gradientGeometry0 = 64;
  static const int gradientGeometry1 = 80;
  static const int gradientKind = 96;
  static const int gradientSpread = 100;
}

/// Values of the `gradientKind` field, mirroring [Gradient.shaderKind].
const int kWebGpuSparseGradientKindLinear = 1;

/// Fills one material's uniform slice at [byteOffset] in [destination].
///
/// The gradient half is optional: a solid material passes null for both, and
/// the gradient fields stay zero, which the solid entry points never read.
/// A gradient material must pass both, and the two must describe the same
/// [Gradient] - the check is here rather than only in the executor because
/// this function is where the two objects are read together.
///
/// Everything is little-endian, which is the byte order WebGPU buffers are
/// defined in and the one every browser host runs.
void writeWebGpuSparseUniformSlice(
  ByteData destination,
  int byteOffset, {
  required int viewportWidth,
  required int viewportHeight,
  required double red,
  required double green,
  required double blue,
  required double alpha,
  GpuGradientBinding? gradientBinding,
  GpuGradientShaderParameters? gradientParameters,
}) {
  if (viewportWidth <= 0 || viewportHeight <= 0) {
    throw ArgumentError('viewport must be positive, got '
        '${viewportWidth}x$viewportHeight');
  }
  if (byteOffset < 0 ||
      byteOffset + kWebGpuSparseUniformSliceSize > destination.lengthInBytes) {
    throw RangeError.range(
      byteOffset,
      0,
      destination.lengthInBytes - kWebGpuSparseUniformSliceSize,
      'byteOffset',
    );
  }
  if ((gradientBinding == null) != (gradientParameters == null)) {
    throw ArgumentError(
      'a gradient material needs both a binding and shader parameters',
    );
  }

  void putFloat(int offset, double value) =>
      destination.setFloat32(byteOffset + offset, value, Endian.little);
  void putInt(int offset, int value) =>
      destination.setInt32(byteOffset + offset, value, Endian.little);

  const int viewport = WebGpuSparseUniformOffset.viewport;
  putFloat(viewport, viewportWidth.toDouble());
  putFloat(viewport + 4, viewportHeight.toDouble());

  const int color = WebGpuSparseUniformOffset.color;
  putFloat(color, red);
  putFloat(color + 4, green);
  putFloat(color + 8, blue);
  putFloat(color + 12, alpha);

  if (gradientBinding == null || gradientParameters == null) {
    // Zeroed rather than left as whatever the arena held: a slice is reused
    // across frames, and a stale focus point in a field the current material
    // does not read is a trap for the next one that does.
    for (var offset = WebGpuSparseUniformOffset.gradientLookup;
        offset < WebGpuSparseUniformOffset.gradientLookup + 8;
        offset += 4) {
      putFloat(offset, 0);
    }
    for (var offset = WebGpuSparseUniformOffset.targetToLocal0;
        offset < WebGpuSparseUniformOffset.gradientKind;
        offset += 4) {
      putFloat(offset, 0);
    }
    putInt(WebGpuSparseUniformOffset.gradientKind, 0);
    putInt(WebGpuSparseUniformOffset.gradientSpread, 0);
    return;
  }

  if (gradientBinding.gradient != gradientParameters.gradient) {
    throw ArgumentError(
      'gradient binding LUT does not match the shader parameters',
    );
  }

  const int lookup = WebGpuSparseUniformOffset.gradientLookup;
  putFloat(lookup, gradientBinding.lookupScale);
  putFloat(lookup + 4, gradientBinding.lookupBias);

  final Float32List scalars = gradientParameters.scalars;
  const int transform = GpuGradientUniformOffset.targetToLocal;
  // The GL adapter loads the same six scalars into two vec4 uniforms in this
  // order: row 0 is (a, c, tx) and row 1 is (b, d, ty), so a dot with
  // (x, y, 1) is the affine map. The fourth component is unused padding.
  const int row0 = WebGpuSparseUniformOffset.targetToLocal0;
  putFloat(row0, scalars[transform]);
  putFloat(row0 + 4, scalars[transform + 2]);
  putFloat(row0 + 8, scalars[transform + 4]);
  putFloat(row0 + 12, 0);
  const int row1 = WebGpuSparseUniformOffset.targetToLocal1;
  putFloat(row1, scalars[transform + 1]);
  putFloat(row1 + 4, scalars[transform + 3]);
  putFloat(row1 + 8, scalars[transform + 5]);
  putFloat(row1 + 12, 0);

  const int geometry = GpuGradientUniformOffset.geometry;
  const int geometry0 = WebGpuSparseUniformOffset.gradientGeometry0;
  const int geometry1 = WebGpuSparseUniformOffset.gradientGeometry1;
  for (var i = 0; i < 4; i++) {
    putFloat(geometry0 + i * 4, scalars[geometry + i]);
    putFloat(geometry1 + i * 4, scalars[geometry + 4 + i]);
  }

  putInt(
    WebGpuSparseUniformOffset.gradientKind,
    scalars[GpuGradientUniformOffset.kind].toInt(),
  );
  putInt(
    WebGpuSparseUniformOffset.gradientSpread,
    gradientBinding.spread.index,
  );
}

/// Checks the Dart-side contract against the generated module.
///
/// The sibling of `validateSparseGlShaderContract`, and it earns its place for
/// the same reason: a renamed shader input is a WebGPU validation error that
/// arrives on the `uncapturederror` channel a microtask after the call that
/// caused it, long after the stack that could explain it is gone. Failing here
/// names the missing declaration instead.
void validateWgslSparseShaderContract() {
  const String source = kWgslSparseShaderModuleSource;
  if (!source.contains('fn $kWgslSparseVertexEntryPoint(')) {
    throw StateError(
      'missing sparse WGSL vertex entry point: $kWgslSparseVertexEntryPoint',
    );
  }
  for (final String entryPoint in kWgslSparseFragmentEntryPoints) {
    if (!source.contains('fn $entryPoint(')) {
      throw StateError('missing sparse WGSL fragment entry point: $entryPoint');
    }
  }
  const List<String> declarations = <String>[
    '@location($kWebGpuSparseQuadRectLocation) quadRect: vec4f,',
    '@location($kWebGpuSparseAtlasOriginLocation) atlasOrigin: vec2f,',
    '@group(0) @binding(0) var<uniform> uSparse: SparseUniforms;',
    '@group(1) @binding(0) var uAlphaAtlas: texture_2d<f32>;',
    '@group(1) @binding(1) var uGradientLut: texture_2d<f32>;',
    '@group(1) @binding(2) var uGradientSampler: sampler;',
  ];
  for (final String declaration in declarations) {
    if (!source.contains(declaration)) {
      throw StateError('missing sparse WGSL declaration: $declaration');
    }
  }
  const List<String> fields = <String>[
    'viewport: vec2f,',
    'gradientLookup: vec2f,',
    'color: vec4f,',
    'targetToLocal0: vec4f,',
    'targetToLocal1: vec4f,',
    'gradientGeometry0: vec4f,',
    'gradientGeometry1: vec4f,',
    'gradientKind: i32,',
    'gradientSpread: i32,',
  ];
  for (final String field in fields) {
    if (!source.contains(field)) {
      throw StateError('missing sparse WGSL uniform field: $field');
    }
  }
}

/// The whole sparse shader module.
///
/// The fragment bodies are translations of `_sparseFragmentBody` in
/// `gl_sparse_strips.dart`, token for token where the languages agree and with
/// a comment where they do not. There are exactly two places they do not, and
/// both would produce a plausible, wrong picture rather than an error:
///
///   * `mod(x, 2.0)` in GLSL is `x - 2 * floor(x / 2)` and follows the sign of
///     the divisor; WGSL's `%` truncates toward zero and answers a negative
///     value for a negative parameter. `reflect` needs the GLSL one, which is
///     also what `GpuGradientBinding.textureCoordinate` computes in Dart, so
///     the expression is written out.
///   * GLSL's `all(equal(a, b))` is `all(a == b)` here.
const String kWgslSparseShaderModuleSource = '''
// Per-material data, bound at a dynamic offset. The byte layout is pinned by
// WebGpuSparseUniformOffset in wgsl_sparse_shaders.dart; adding a field here
// without adding it there writes a gradient's geometry into its transform.
struct SparseUniforms {
  viewport: vec2f,
  gradientLookup: vec2f,
  color: vec4f,
  targetToLocal0: vec4f,
  targetToLocal1: vec4f,
  gradientGeometry0: vec4f,
  gradientGeometry1: vec4f,
  gradientKind: i32,
  gradientSpread: i32,
}

@group(0) @binding(0) var<uniform> uSparse: SparseUniforms;
@group(1) @binding(0) var uAlphaAtlas: texture_2d<f32>;
@group(1) @binding(1) var uGradientLut: texture_2d<f32>;
@group(1) @binding(2) var uGradientSampler: sampler;

// One quad per instance: the device rectangle, and where its coverage lives in
// the alpha atlas. A solid interior leaves the origin at zero and never reads
// the atlas.
struct SparseInstance {
  @location(0) quadRect: vec4f,
  @location(1) atlasOrigin: vec2f,
}

struct SparseVertexOutput {
  @builtin(position) position: vec4f,
  @location(0) atlasTexel: vec2f,
  @location(1) targetPosition: vec2f,
}

@vertex
fn vs_sparse(
  instance: SparseInstance,
  @builtin(vertex_index) vertexIndex: u32,
) -> SparseVertexOutput {
  var out: SparseVertexOutput;
  // Four vertices form a triangle strip: TL, TR, BL, BR. The immutable unit
  // quad is free this way, exactly as gl_VertexID makes it free on GL.
  let corner = vec2f(
    f32(vertexIndex & 1u),
    f32((vertexIndex >> 1u) & 1u));
  let devicePosition = instance.quadRect.xy + corner * instance.quadRect.zw;
  out.atlasTexel = instance.atlasOrigin + corner * instance.quadRect.zw;
  out.targetPosition = devicePosition;
  // Device space is y-down from the top-left corner; NDC is y-up from the
  // middle. WebGPU's framebuffer origin is the top-left one, so this single
  // flip is right for a canvas and for a layer texture alike - see the library
  // comment on why there is no yFlip uniform.
  out.position = vec4f(
    devicePosition.x / uSparse.viewport.x * 2.0 - 1.0,
    1.0 - devicePosition.y / uSparse.viewport.y * 2.0,
    0.0,
    1.0);
  return out;
}

// Device rectangles and atlas placements are integer-aligned. At pixel centres
// the interpolated coordinate is texel + 0.5, so floor names the exact alpha8
// texel without normalised-UV rounding or filtering.
fn sparseCoverage(atlasTexel: vec2f) -> f32 {
  return textureLoad(uAlphaAtlas, vec2i(floor(atlasTexel)), 0).r;
}

fn sparseGradientParameter(targetPosition: vec2f) -> f32 {
  let local = vec2f(
    dot(uSparse.targetToLocal0.xyz, vec3f(targetPosition, 1.0)),
    dot(uSparse.targetToLocal1.xyz, vec3f(targetPosition, 1.0)));
  if (uSparse.gradientKind == 1) {
    let direction = uSparse.gradientGeometry0.zw - uSparse.gradientGeometry0.xy;
    let lengthSquared = dot(direction, direction);
    if (lengthSquared == 0.0) {
      return 0.0;
    }
    return dot(local - uSparse.gradientGeometry0.xy, direction) / lengthSquared;
  }

  let center = uSparse.gradientGeometry0.xy;
  let radius = uSparse.gradientGeometry0.z;
  let focus = vec2f(uSparse.gradientGeometry0.w, uSparse.gradientGeometry1.x);
  let ray = local - focus;
  if (all(ray == vec2f(0.0))) {
    return 0.0;
  }
  if (all(focus == center)) {
    return length(ray) / radius;
  }
  let focusFromCenter = focus - center;
  let a = dot(ray, ray);
  let b = 2.0 * dot(focusFromCenter, ray);
  let c = dot(focusFromCenter, focusFromCenter) - radius * radius;
  let discriminant = b * b - 4.0 * a * c;
  if (a == 0.0 || discriminant < 0.0) {
    return 0.0;
  }
  let root = sqrt(discriminant);
  let first = (-b - root) / (2.0 * a);
  let second = (-b + root) / (2.0 * a);
  let scale = max(
    select(0.0, first, first > 0.0),
    select(0.0, second, second > 0.0));
  if (scale > 0.0) {
    return 1.0 / scale;
  }
  return 0.0;
}

fn sparseSpreadGradient(parameter: f32) -> f32 {
  if (uSparse.gradientSpread == 1) {
    return fract(parameter);
  }
  if (uSparse.gradientSpread == 2) {
    // GLSL's mod and Dart's %, which WGSL's % is not: % truncates toward zero
    // and would answer a negative value for a negative parameter, mirroring
    // the ramp about the wrong end.
    let repeated = parameter - 2.0 * floor(parameter * 0.5);
    return select(2.0 - repeated, repeated, repeated <= 1.0);
  }
  return clamp(parameter, 0.0, 1.0);
}

// The LUT is straight alpha, one row, linearly filtered. Premultiplying here
// and applying coverage afterwards is the same order gl_sparse_strips.dart
// uses and the order the CPU compositor expects.
fn sparseGradientColor(targetPosition: vec2f) -> vec4f {
  let parameter = sparseSpreadGradient(
    sparseGradientParameter(targetPosition));
  let coordinate =
    parameter * uSparse.gradientLookup.x + uSparse.gradientLookup.y;
  let straight = textureSample(
    uGradientLut, uGradientSampler, vec2f(coordinate, 0.5));
  return vec4f(straight.rgb * straight.a, straight.a);
}

@fragment
fn fs_sparse_solid_fill(in: SparseVertexOutput) -> @location(0) vec4f {
  return uSparse.color;
}

@fragment
fn fs_sparse_solid_strip(in: SparseVertexOutput) -> @location(0) vec4f {
  return uSparse.color * sparseCoverage(in.atlasTexel);
}

@fragment
fn fs_sparse_gradient_fill(in: SparseVertexOutput) -> @location(0) vec4f {
  return sparseGradientColor(in.targetPosition);
}

@fragment
fn fs_sparse_gradient_strip(in: SparseVertexOutput) -> @location(0) vec4f {
  return sparseGradientColor(in.targetPosition)
      * sparseCoverage(in.atlasTexel);
}
''';
