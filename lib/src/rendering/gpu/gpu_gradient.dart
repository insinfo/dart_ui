/// Backend-neutral gradient lookup textures and shader parameters.
///
/// This file deliberately stops before recording a draw. A backend opts into
/// gradient replay only after its pipeline consumes both [GpuGradientBinding]
/// and [GpuGradientShaderParameters]. Until then [GpuRasterSink] remains
/// outside `GradientRasterSink`, so a gradient is refused rather than drawn
/// with the paint's otherwise-unused solid colour.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/gradient.dart';
import '../../graphics/gradient_lut.dart';
import '../replay/display_list_player.dart';
import 'gpu_texture.dart';

/// A resident, immutable lookup ramp and the texture that owns its texels.
final class GpuGradientBinding {
  const GpuGradientBinding({
    required this.gradient,
    required this.texture,
    required this.lutSize,
  });

  /// Value whose stops were uploaded into [texture].
  final Gradient gradient;
  final GpuTextureHandle texture;
  final int lutSize;
  GradientSpread get spread => gradient.spread;

  /// Scale and bias from a spread-adjusted 0..1 parameter to texture space.
  ///
  /// A normalized coordinate addresses texel *edges*, while [GradientLut]
  /// defines its endpoints at texel centres. Sampling `t` directly would move
  /// every interval by half a texel. Shader adapters use `t * lookupScale +
  /// lookupBias`, which maps 0 and 1 to the first and last centres exactly.
  double get lookupScale => (lutSize - 1) / lutSize;
  double get lookupBias => 0.5 / lutSize;

  /// Reference coordinate calculation for shader parity tests.
  double textureCoordinate(double parameter) {
    final double t = switch (spread) {
      GradientSpread.pad => parameter == double.negativeInfinity
          ? 0
          : parameter == double.infinity
              ? 1
              : parameter.isNaN
                  ? 0
                  : parameter.clamp(0.0, 1.0),
      GradientSpread.repeat =>
        !parameter.isFinite ? 0 : parameter - parameter.floorToDouble(),
      GradientSpread.reflect => _reflect(parameter),
    };
    return t * lookupScale + lookupBias;
  }

  static double _reflect(double parameter) {
    if (!parameter.isFinite) return 0;
    var repeated = parameter % 2;
    if (repeated < 0) repeated += 2;
    return repeated <= 1 ? repeated : 2 - repeated;
  }
}

/// Uploads each value-equal gradient once and reuses it across frames.
///
/// The cache owns every returned texture until [clear]. Invalid handles are
/// replaced lazily, which is the device-loss seam used by the existing image
/// and atlas paths. Texels are RGBA, straight alpha, one row, and linearly
/// filtered; those choices are part of the contract rather than backend
/// policy because changing any of them changes the sampled colour.
final class GpuGradientCache {
  GpuGradientCache({
    required this.allocator,
    this.lutSize = kDefaultGradientLutSize,
  }) {
    if (lutSize < 2) {
      throw ArgumentError.value(lutSize, 'lutSize', 'must be at least 2');
    }
  }

  final GpuTextureAllocator allocator;
  final int lutSize;
  final Map<Gradient, GpuGradientBinding> _bindings =
      <Gradient, GpuGradientBinding>{};

  int get length => _bindings.length;

  GpuGradientBinding resolve(Gradient gradient) {
    final cached = _bindings[gradient];
    if (cached != null && cached.texture.isValid) return cached;

    final lut = GradientLut(gradient, size: lutSize);
    final texture = allocator.createTexture(
      width: lutSize,
      height: 1,
      format: GpuTextureFormat.rgba8888Straight,
      filter: GpuTextureFilter.linear,
    );
    if (texture.id == kNoTexture ||
        texture.width != lutSize ||
        texture.height != 1 ||
        texture.format != GpuTextureFormat.rgba8888Straight ||
        texture.filter != GpuTextureFilter.linear ||
        !texture.isValid) {
      if (texture.isValid) allocator.releaseTexture(texture);
      throw StateError(
        'GPU gradient allocator returned an incompatible texture: '
        'id=${texture.id}, ${texture.width}x${texture.height}, '
        '${texture.format.name}/${texture.filter.name}, '
        'valid=${texture.isValid}',
      );
    }

    final pixels = Uint8List(lutSize * 4);
    for (var i = 0; i < lutSize; i++) {
      final argb = lut.colorsArgb[i];
      final byte = i * 4;
      pixels[byte] = (argb >> 16) & 0xFF;
      pixels[byte + 1] = (argb >> 8) & 0xFF;
      pixels[byte + 2] = argb & 0xFF;
      pixels[byte + 3] = (argb >> 24) & 0xFF;
    }
    try {
      allocator.uploadRegion(
        texture,
        x: 0,
        y: 0,
        width: lutSize,
        height: 1,
        pixels: pixels,
        bytesPerRow: lutSize * 4,
      );
    } catch (_) {
      if (texture.isValid) allocator.releaseTexture(texture);
      rethrow;
    }

    final binding = GpuGradientBinding(
      gradient: gradient,
      texture: texture,
      lutSize: lutSize,
    );
    _bindings[gradient] = binding;
    return binding;
  }

  /// Releases every still-valid texture and forgets invalid device objects.
  void clear() {
    for (final binding in _bindings.values) {
      if (binding.texture.isValid) allocator.releaseTexture(binding.texture);
    }
    _bindings.clear();
  }
}

/// Logical scalar layout shared by GLSL/HLSL/MSL/SPIR-V/WGSL adapters.
///
/// This is not a byte-for-byte uniform block: APIs impose different alignment
/// rules. Adapters copy the named ranges into their native block. Keeping the
/// scalar order here still makes shader generation and parity tests share one
/// source of truth.
abstract final class GpuGradientUniformOffset {
  static const int kind = 0;
  static const int spread = 1;
  static const int targetToLocal = 4;
  static const int localToTarget = 10;
  static const int geometry = 16;
  static const int scalarCount = 24;
}

/// Per-draw transforms and geometry consumed by a gradient shader.
///
/// `target` means the current render target: device space on the root surface
/// and layer-local space in an offscreen pass. [targetOriginInDevice] folds
/// that distinction into both matrices, so shaders never need a layer special
/// case. The fragment stage maps its target coordinate through
/// [targetToLocal], then evaluates [gradient]'s local geometry.
final class GpuGradientShaderParameters {
  GpuGradientShaderParameters._({
    required this.gradient,
    required this.localToTarget,
    required this.targetToLocal,
  }) : _scalars = Float32List(GpuGradientUniformOffset.scalarCount) {
    _scalars[GpuGradientUniformOffset.kind] = gradient.shaderKind.toDouble();
    _scalars[GpuGradientUniformOffset.spread] =
        gradient.spread.index.toDouble();
    _writeTransform(GpuGradientUniformOffset.targetToLocal, targetToLocal);
    _writeTransform(GpuGradientUniformOffset.localToTarget, localToTarget);
    final geometry = gradient.geometry;
    for (var i = 0; i < geometry.length; i++) {
      _scalars[GpuGradientUniformOffset.geometry + i] = geometry[i];
    }
    for (var i = 0; i < _scalars.length; i++) {
      if (!_scalars[i].isFinite) {
        throw ArgumentError.value(
          _scalars[i],
          'gradient scalar $i',
          'must remain finite after conversion to float32',
        );
      }
    }
  }

  factory GpuGradientShaderParameters.fromPaint(
    ReplayPaint paint, {
    Offset targetOriginInDevice = Offset.zero,
  }) {
    final gradient = paint.gradient;
    if (gradient == null) {
      throw ArgumentError.value(paint, 'paint', 'does not carry a gradient');
    }
    if (!targetOriginInDevice.dx.isFinite ||
        !targetOriginInDevice.dy.isFinite) {
      throw ArgumentError.value(
        targetOriginInDevice,
        'targetOriginInDevice',
        'must be finite',
      );
    }
    final localToTarget = Transform2D.translation(
      -targetOriginInDevice.dx,
      -targetOriginInDevice.dy,
    ).multiply(paint.shaderTransform);
    final targetToLocal = localToTarget.invert();
    if (targetToLocal == null) {
      throw StateError(
        'gradient shader transform is singular and cannot map target pixels '
        'back to gradient-local coordinates: ${paint.shaderTransform}',
      );
    }
    return GpuGradientShaderParameters._(
      gradient: gradient,
      localToTarget: localToTarget,
      targetToLocal: targetToLocal,
    );
  }

  final Gradient gradient;
  final Transform2D localToTarget;
  final Transform2D targetToLocal;
  final Float32List _scalars;

  late final Float32List scalars = _scalars.asUnmodifiableView();

  /// Reference parameter evaluation used by backend parity tests.
  double parameterAtTarget(double targetX, double targetY) {
    final x = targetToLocal.a * targetX +
        targetToLocal.c * targetY +
        targetToLocal.tx;
    final y = targetToLocal.b * targetX +
        targetToLocal.d * targetY +
        targetToLocal.ty;
    return switch (gradient) {
      final LinearGradient linear => _linearParameter(linear, x, y),
      final RadialGradient radial => _radialParameter(radial, x, y),
    };
  }

  void _writeTransform(int offset, Transform2D transform) {
    _scalars[offset] = transform.a;
    _scalars[offset + 1] = transform.b;
    _scalars[offset + 2] = transform.c;
    _scalars[offset + 3] = transform.d;
    _scalars[offset + 4] = transform.tx;
    _scalars[offset + 5] = transform.ty;
  }

  static double _linearParameter(LinearGradient gradient, double x, double y) {
    final dx = gradient.endX - gradient.startX;
    final dy = gradient.endY - gradient.startY;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0 || !lengthSquared.isFinite) return 0;
    return ((x - gradient.startX) * dx + (y - gradient.startY) * dy) /
        lengthSquared;
  }

  static double _radialParameter(RadialGradient gradient, double x, double y) {
    final dx = x - gradient.focusX;
    final dy = y - gradient.focusY;
    if (dx == 0 && dy == 0) return 0;
    if (!gradient.hasFocus) {
      return math.sqrt(dx * dx + dy * dy) / gradient.radius;
    }
    final vx = gradient.focusX - gradient.centerX;
    final vy = gradient.focusY - gradient.centerY;
    final a = dx * dx + dy * dy;
    final b = 2 * (vx * dx + vy * dy);
    final c = vx * vx + vy * vy - gradient.radius * gradient.radius;
    final discriminant = b * b - 4 * a * c;
    if (a == 0 || discriminant < 0 || !discriminant.isFinite) return 0;
    final root = math.sqrt(discriminant);
    final first = (-b - root) / (2 * a);
    final second = (-b + root) / (2 * a);
    final s = math.max(first > 0 ? first : 0, second > 0 ? second : 0);
    return s > 0 && s.isFinite ? 1 / s : 0;
  }
}
