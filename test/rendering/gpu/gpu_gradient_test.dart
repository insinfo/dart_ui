import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

void main() {
  group('GpuGradientCache', () {
    test('uploads straight RGBA once and reuses value-equal gradients', () {
      final allocator = _Allocator();
      final cache = GpuGradientCache(allocator: allocator, lutSize: 3);
      final first = cache.resolve(_linear());
      final second = cache.resolve(_linear());

      expect(identical(first, second), isTrue);
      expect(cache.length, 1);
      expect(allocator.creates, 1);
      expect(allocator.uploads, 1);
      expect(first.texture.format, GpuTextureFormat.rgba8888Straight);
      expect(first.texture.filter, GpuTextureFilter.linear);
      expect(first.lookupBias, closeTo(1 / 6, 1e-12));
      expect(first.lookupScale, closeTo(2 / 3, 1e-12));
      expect(first.textureCoordinate(0), closeTo(1 / 6, 1e-12));
      expect(first.textureCoordinate(1), closeTo(5 / 6, 1e-12));
      expect(
        allocator.lastPixels,
        Uint8List.fromList(<int>[
          0x20,
          0x40,
          0x80,
          0x00,
          0x30,
          0x50,
          0x70,
          0x80,
          0x40,
          0x60,
          0x60,
          0xFF,
        ]),
      );
      expect(allocator.lastBytesPerRow, 12);
    });

    test('maps repeat and reflect into texel centres before sampling', () {
      final allocator = _Allocator();
      final repeat = GpuGradientCache(allocator: allocator, lutSize: 4)
          .resolve(_linear(spread: GradientSpread.repeat));
      final reflect = GpuGradientCache(allocator: allocator, lutSize: 4)
          .resolve(_linear(spread: GradientSpread.reflect));

      expect(repeat.textureCoordinate(1.25), closeTo(0.3125, 1e-12));
      expect(repeat.textureCoordinate(-0.25), closeTo(0.6875, 1e-12));
      expect(reflect.textureCoordinate(1.25), closeTo(0.6875, 1e-12));
      expect(reflect.textureCoordinate(-0.25), closeTo(0.3125, 1e-12));
    });

    test('recreates a binding after device loss and clear releases live data',
        () {
      final allocator = _Allocator();
      final cache = GpuGradientCache(allocator: allocator, lutSize: 2);
      final first = cache.resolve(_linear());
      (first.texture as _Texture).valid = false;

      final second = cache.resolve(_linear());
      expect(second.texture.id, isNot(first.texture.id));
      expect(allocator.creates, 2);
      expect(allocator.releases, 0, reason: 'a lost object is already dead');

      cache.clear();
      expect(cache.length, 0);
      expect(allocator.releases, 1);
      expect(second.texture.isValid, isFalse);
    });

    test('rejects allocator objects that violate the texture contract', () {
      final allocator = _Allocator(badFormat: true);
      final cache = GpuGradientCache(allocator: allocator, lutSize: 2);
      expect(() => cache.resolve(_linear()), throwsStateError);
      expect(allocator.uploads, 0);
      expect(allocator.releases, 1);
    });
  });

  group('GpuGradientShaderParameters', () {
    test('folds layer origin into exact local-target inverse matrices', () {
      final gradient = _linear();
      final parameters = GpuGradientShaderParameters.fromPaint(
        _paint(
          gradient,
          const Transform2D(2, 0, 0, 2, 10, 20),
        ),
        targetOriginInDevice: const Offset(4, 5),
      );

      final target =
          parameters.localToTarget.transformOffset(const Offset(3, 4));
      expect(target, const Offset(12, 23));
      expect(
          parameters.targetToLocal.transformOffset(target), const Offset(3, 4));
      expect(parameters.parameterAtTarget(target.dx, target.dy),
          closeTo(0.3, 1e-12));

      final scalars = parameters.scalars;
      expect(scalars.length, GpuGradientUniformOffset.scalarCount);
      expect(scalars[GpuGradientUniformOffset.kind], shaderKindLinear);
      expect(
          scalars[GpuGradientUniformOffset.spread], GradientSpread.pad.index);
      expect(
        scalars.sublist(GpuGradientUniformOffset.targetToLocal,
            GpuGradientUniformOffset.targetToLocal + 6),
        <double>[0.5, 0, 0, 0.5, -3, -7.5],
      );
      expect(
        scalars.sublist(GpuGradientUniformOffset.geometry,
            GpuGradientUniformOffset.geometry + 4),
        <double>[0, 0, 10, 0],
      );
    });

    test('evaluates focused radial geometry in local coordinates', () {
      final gradient = RadialGradient(
        centerX: 5,
        centerY: 5,
        radius: 5,
        focusX: 2,
        focusY: 5,
        stops: const <GradientStop>[
          GradientStop(0, 0xFF000000),
          GradientStop(1, 0xFFFFFFFF),
        ],
        spread: GradientSpread.reflect,
      );
      final parameters = GpuGradientShaderParameters.fromPaint(
        _paint(gradient, Transform2D.identity),
      );

      expect(parameters.parameterAtTarget(2, 5), 0);
      expect(parameters.parameterAtTarget(10, 5), closeTo(1, 1e-12));
      expect(
          parameters.scalars[GpuGradientUniformOffset.kind], shaderKindRadial);
      expect(parameters.scalars[GpuGradientUniformOffset.spread],
          GradientSpread.reflect.index);
      expect(
        parameters.scalars.sublist(GpuGradientUniformOffset.geometry,
            GpuGradientUniformOffset.geometry + 5),
        <double>[5, 5, 5, 2, 5],
      );
    });

    test('refuses solid paints, singular transforms, and non-finite origins',
        () {
      const solid = ReplayPaint(
        argbColor: 0xFFFFFFFF,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrcOver,
        antiAlias: true,
      );
      expect(() => GpuGradientShaderParameters.fromPaint(solid),
          throwsArgumentError);
      expect(
        () => GpuGradientShaderParameters.fromPaint(
          _paint(_linear(), const Transform2D.scaling(0, 1)),
        ),
        throwsStateError,
      );
      expect(
        () => GpuGradientShaderParameters.fromPaint(
          _paint(_linear(), Transform2D.identity),
          targetOriginInDevice: const Offset(double.infinity, 0),
        ),
        throwsArgumentError,
      );
    });

    test('published scalar storage is immutable', () {
      final parameters = GpuGradientShaderParameters.fromPaint(
        _paint(_linear(), Transform2D.identity),
      );
      expect(() => parameters.scalars[0] = 99, throwsUnsupportedError);
    });
  });
}

LinearGradient _linear({GradientSpread spread = GradientSpread.pad}) =>
    LinearGradient(
      startX: 0,
      startY: 0,
      endX: 10,
      endY: 0,
      stops: const <GradientStop>[
        GradientStop(0, 0x00204080),
        GradientStop(1, 0xFF406060),
      ],
      spread: spread,
    );

ReplayPaint _paint(Gradient gradient, Transform2D transform) => ReplayPaint(
      argbColor: 0,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendModeSrcOver,
      antiAlias: true,
      gradient: gradient,
      shaderTransform: transform,
    );

final class _Texture implements GpuTextureHandle {
  _Texture({
    required this.id,
    required this.width,
    required this.height,
    required this.format,
    required this.filter,
  });

  @override
  final int id;
  @override
  final int width;
  @override
  final int height;
  @override
  final GpuTextureFormat format;
  @override
  final GpuTextureFilter filter;
  bool valid = true;
  @override
  bool get isValid => valid;
}

final class _Allocator implements GpuTextureAllocator {
  _Allocator({this.badFormat = false});

  final bool badFormat;
  int creates = 0;
  int uploads = 0;
  int releases = 0;
  Uint8List? lastPixels;
  int? lastBytesPerRow;

  @override
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.nearest,
  }) {
    creates++;
    return _Texture(
      id: creates,
      width: width,
      height: height,
      format: badFormat ? GpuTextureFormat.rgba8888Premultiplied : format,
      filter: filter,
    );
  }

  @override
  void uploadRegion(
    GpuTextureHandle texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    uploads++;
    lastPixels = Uint8List.fromList(pixels);
    lastBytesPerRow = bytesPerRow;
  }

  @override
  void releaseTexture(GpuTextureHandle texture) {
    releases++;
    (texture as _Texture).valid = false;
  }
}
