/// OpenGL submission contract for the backend-neutral sparse-strip plan.
///
/// This is deliberately a seam rather than a change to [GlRenderDevice]. The
/// current renderer remains the production path while this encoder makes the
/// next integration step mechanical and independently testable:
///
///  * upload [instanceStorage] to one dynamic instance VBO;
///  * before each command, rebase the two attributes to
///    [commandAttributeOffsetBytes] (core GL 3.3 has no base-instance draw);
///  * bind the material colour and the alpha page named by each command;
///  * issue `glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, count)`.
///
/// Commands retain path/material order. Solid interiors precede boundary
/// strips only within the same path, where the two regions never overlap.
library;

import 'dart:typed_data';

import '../vector/sparse_strip_draw_plan.dart';

/// Six floats per instance: device `x, y, width, height`, then alpha-atlas
/// `x, y`. Solid instances leave the atlas origin at zero.
const int kSparseGlInstanceFloatCount = 6;
const int kSparseGlInstanceStrideBytes = kSparseGlInstanceFloatCount * 4;
const int kSparseGlQuadRectOffsetBytes = 0;
const int kSparseGlAtlasOriginOffsetBytes = 4 * 4;

const int kSparseGlAttributeQuadRect = 0;
const int kSparseGlAttributeAtlasOrigin = 1;

const int kSparseGlModeSolid = 0;
const int kSparseGlModeAlpha = 1;

/// Material source, independent from whether coverage is solid or alpha8.
const int kSparseGlPaintSolid = 0;
const int kSparseGlPaintGradient = 1;

/// `mode, material, atlasPage, firstInstance, instanceCount`.
const int kSparseGlCommandStride = 5;

/// One instanced vertex attribute in the sparse-strip program.
final class SparseGlAttribute {
  const SparseGlAttribute({
    required this.name,
    required this.location,
    required this.components,
    required this.offsetBytes,
  });

  final String name;
  final int location;
  final int components;
  final int offsetBytes;

  int get strideBytes => kSparseGlInstanceStrideBytes;

  /// Both attributes advance once per quad, not once per corner vertex.
  int get divisor => 1;
}

const List<SparseGlAttribute> kSparseGlAttributes = <SparseGlAttribute>[
  SparseGlAttribute(
    name: 'aQuadRect',
    location: kSparseGlAttributeQuadRect,
    components: 4,
    offsetBytes: kSparseGlQuadRectOffsetBytes,
  ),
  SparseGlAttribute(
    name: 'aAtlasOrigin',
    location: kSparseGlAttributeAtlasOrigin,
    components: 2,
    offsetBytes: kSparseGlAtlasOriginOffsetBytes,
  ),
];

const List<String> kSparseGlUniformNames = <String>[
  'uViewport',
  'uYFlip',
  'uColor',
  'uMode',
  'uAlphaAtlas',
  'uPaintMode',
  'uGradientLut',
  'uGradientKind',
  'uGradientSpread',
  'uGradientLookup',
  'uTargetToLocal0',
  'uTargetToLocal1',
  'uGradientGeometry0',
  'uGradientGeometry1',
];

const String _sparseVertexBody = '''
uniform vec2 uViewport;
uniform int uYFlip;

void main() {
  // Four vertices form a triangle strip: TL, TR, BL, BR. gl_VertexID makes
  // the immutable unit quad free: the only uploaded data is per-instance.
  vec2 corner = vec2(float(gl_VertexID & 1),
                     float((gl_VertexID >> 1) & 1));
  vec2 devicePosition = aQuadRect.xy + corner * aQuadRect.zw;
  vAtlasTexel = aAtlasOrigin + corner * aQuadRect.zw;
  vTargetPosition = devicePosition;
  float ndcY = 1.0 - devicePosition.y / uViewport.y * 2.0;
  gl_Position = vec4(
      devicePosition.x / uViewport.x * 2.0 - 1.0,
      uYFlip == 0 ? ndcY : -ndcY,
      0.0,
      1.0);
}
''';

const String _sparseFragmentBody = '''
uniform vec4 uColor;
uniform int uMode;
uniform sampler2D uAlphaAtlas;
uniform int uPaintMode;
uniform sampler2D uGradientLut;
uniform int uGradientKind;
uniform int uGradientSpread;
uniform vec2 uGradientLookup;
uniform vec4 uTargetToLocal0;
uniform vec4 uTargetToLocal1;
uniform vec4 uGradientGeometry0;
uniform vec4 uGradientGeometry1;

float gradientParameter(vec2 targetPosition) {
  vec2 local = vec2(
      dot(uTargetToLocal0.xyz, vec3(targetPosition, 1.0)),
      dot(uTargetToLocal1.xyz, vec3(targetPosition, 1.0)));
  if (uGradientKind == 1) {
    vec2 direction = uGradientGeometry0.zw - uGradientGeometry0.xy;
    float lengthSquared = dot(direction, direction);
    return lengthSquared == 0.0
        ? 0.0
        : dot(local - uGradientGeometry0.xy, direction) / lengthSquared;
  }

  vec2 center = uGradientGeometry0.xy;
  float radius = uGradientGeometry0.z;
  vec2 focus = vec2(uGradientGeometry0.w, uGradientGeometry1.x);
  vec2 ray = local - focus;
  if (all(equal(ray, vec2(0.0)))) return 0.0;
  if (all(equal(focus, center))) return length(ray) / radius;
  vec2 focusFromCenter = focus - center;
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
  if (uGradientSpread == 1) return fract(parameter);
  if (uGradientSpread == 2) {
    float repeated = mod(parameter, 2.0);
    return repeated <= 1.0 ? repeated : 2.0 - repeated;
  }
  return clamp(parameter, 0.0, 1.0);
}

void main() {
  float coverage = 1.0;
  if (uMode == 1) {
    // Device rectangles and atlas placements are integer-aligned. At pixel
    // centres the interpolated coordinate is texel + 0.5; floor therefore
    // names the exact alpha8 texel without normalised-UV rounding or filtering.
    coverage = texelFetch(uAlphaAtlas, ivec2(floor(vAtlasTexel)), 0).r;
  }
  if (uPaintMode == 1) {
    float parameter = spreadGradient(gradientParameter(vTargetPosition));
    float coordinate = parameter * uGradientLookup.x + uGradientLookup.y;
    vec4 straight = texture(uGradientLut, vec2(coordinate, 0.5));
    straight.rgb *= straight.a;
    fragColor = straight * coverage;
  } else {
    fragColor = uColor * coverage;
  }
}
''';

/// Sparse-strip instancing vertex shader for desktop GL 3.3 or GLES 3.0.
String sparseGlVertexShaderSource({required bool desktop}) => desktop
    ? '#version 330 core\n'
        'layout(location = 0) in vec4 aQuadRect;\n'
        'layout(location = 1) in vec2 aAtlasOrigin;\n'
        'out vec2 vAtlasTexel;\n'
        'out vec2 vTargetPosition;\n'
        '$_sparseVertexBody'
    : '#version 300 es\n'
        'precision highp float;\n'
        'layout(location = 0) in vec4 aQuadRect;\n'
        'layout(location = 1) in vec2 aAtlasOrigin;\n'
        'out vec2 vAtlasTexel;\n'
        'out vec2 vTargetPosition;\n'
        '$_sparseVertexBody';

/// Sparse-strip fragment shader. The uniform branch is coherent for a whole
/// draw: a command contains either solid interiors or one alpha-atlas page.
String sparseGlFragmentShaderSource({required bool desktop}) => desktop
    ? '#version 330 core\n'
        'in vec2 vAtlasTexel;\n'
        'in vec2 vTargetPosition;\n'
        'out vec4 fragColor;\n'
        '$_sparseFragmentBody'
    : '#version 300 es\n'
        'precision highp float;\n'
        'in vec2 vAtlasTexel;\n'
        'in vec2 vTargetPosition;\n'
        'out vec4 fragColor;\n'
        '$_sparseFragmentBody';

/// Checks the Dart-side attribute/uniform contract against both generated
/// shader dialects. A GL program owner can run this before compiling; tests
/// run it unconditionally so a renamed shader input cannot silently corrupt
/// the instance VBO.
void validateSparseGlShaderContract() {
  for (final bool desktop in <bool>[true, false]) {
    final String vertex = sparseGlVertexShaderSource(desktop: desktop);
    final String fragment = sparseGlFragmentShaderSource(desktop: desktop);
    for (final SparseGlAttribute attribute in kSparseGlAttributes) {
      final String declaration = 'layout(location = ${attribute.location}) in '
          '${attribute.components == 4 ? 'vec4' : 'vec2'} ${attribute.name};';
      if (!vertex.contains(declaration)) {
        throw StateError('missing sparse GL attribute: $declaration');
      }
    }
    for (final String uniform in kSparseGlUniformNames) {
      if (!vertex.contains(' $uniform;') && !fragment.contains(' $uniform;')) {
        throw StateError('missing sparse GL uniform: $uniform');
      }
    }
  }
}

/// Reusable GL-oriented instance and command arenas built from a
/// [SparseStripDrawPlan].
final class SparseGlSubmission {
  SparseGlSubmission({int initialInstances = 256, int initialCommands = 64})
      : _instances = Float32List(
          _positive(initialInstances, 'initialInstances') *
              kSparseGlInstanceFloatCount,
        ),
        _commands = Int32List(
          _positive(initialCommands, 'initialCommands') *
              kSparseGlCommandStride,
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
        _instanceCount * kSparseGlInstanceFloatCount,
      );

  Int32List get commands => Int32List.sublistView(
        _commands,
        0,
        _commandCount * kSparseGlCommandStride,
      );

  int commandMode(int command) => _commandField(command, 0);
  int commandMaterial(int command) => _commandField(command, 1);
  int commandAtlasPage(int command) => _commandField(command, 2);
  int commandFirstInstance(int command) => _commandField(command, 3);
  int commandInstanceCount(int command) => _commandField(command, 4);

  /// VBO byte offset for [attribute] when issuing [command].
  ///
  /// The eventual driver call is `glVertexAttribPointer` with this offset,
  /// [SparseGlAttribute.strideBytes], and a divisor of one, followed by an
  /// instanced draw whose instance count is [commandInstanceCount]. Rebinding
  /// the pointer is the GL 3.3/ES 3.0 substitute for a base-instance draw.
  int commandAttributeOffsetBytes(
    int command,
    SparseGlAttribute attribute,
  ) =>
      commandFirstInstance(command) * kSparseGlInstanceStrideBytes +
      attribute.offsetBytes;

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
        _appendCommand(kSparseGlModeSolid, material, -1, first, solidCount);
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
        _appendCommand(kSparseGlModeAlpha, material, page, first, count);
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
    final int base = _instanceCount * kSparseGlInstanceFloatCount;
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
    final int base = _commandCount * kSparseGlCommandStride;
    _commands[base] = mode;
    _commands[base + 1] = material;
    _commands[base + 2] = atlasPage;
    _commands[base + 3] = first;
    _commands[base + 4] = count;
    _commandCount++;
  }

  void _ensureInstanceCapacity(int count) {
    final int required = count * kSparseGlInstanceFloatCount;
    if (required <= _instances.length) return;
    var length = _instances.length * 2;
    while (length < required) {
      length *= 2;
    }
    final Float32List grown = Float32List(length)
      ..setRange(0, _instances.length, _instances);
    _instances = grown;
    _growths++;
  }

  void _ensureCommandCapacity(int count) {
    final int required = count * kSparseGlCommandStride;
    if (required <= _commands.length) return;
    var length = _commands.length * 2;
    while (length < required) {
      length *= 2;
    }
    final Int32List grown = Int32List(length)
      ..setRange(0, _commands.length, _commands);
    _commands = grown;
    _growths++;
  }

  double _instanceField(int instance, int field) {
    if (instance < 0 || instance >= _instanceCount) {
      throw RangeError.index(instance, _instances, 'instance');
    }
    return _instances[instance * kSparseGlInstanceFloatCount + field];
  }

  int _commandField(int command, int field) {
    if (command < 0 || command >= _commandCount) {
      throw RangeError.index(command, _commands, 'command');
    }
    return _commands[command * kSparseGlCommandStride + field];
  }
}

int _positive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'must be > 0');
  return value;
}
