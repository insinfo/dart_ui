import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_geometry.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:dart_ui/src/rendering/replay/recording_sink.dart';
import 'package:dart_ui/src/rendering/replay/replay_state.dart';
import 'package:test/test.dart';

const Rect _surface = Rect.fromLTRB(0, 0, 100, 100);

RecordingSink _play(
  DisplayList list, {
  Rect deviceBounds = _surface,
  Transform2D deviceTransform = Transform2D.identity,
}) {
  final sink = RecordingSink();
  DisplayListPlayer(sink).play(
    DisplayListReader(list),
    DisplayListResources(list),
    deviceBounds: deviceBounds,
    deviceTransform: deviceTransform,
  );
  return sink;
}

void main() {
  group('transform', () {
    test('nested scopes compose, and restore drops the inner one', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF00FF00);
      list
        ..save()
        ..transform2D(const Transform2D.scaling(2, 2))
        ..save()
        ..transform2D(const Transform2D.translation(10, 5))
        // Under scale(2) * translate(10, 5) the unit square lands at
        // (20, 10)..(28, 18): the translation is scaled too, because it was
        // concatenated inside the scaled scope.
        ..drawRect(0, 0, 4, 4, paint)
        ..restore()
        // Back to scale(2) alone.
        ..drawRect(0, 0, 4, 4, paint)
        ..restore();

      final List<FillRectCall> fills = _play(list).allOf<FillRectCall>();
      expect(fills, hasLength(2));
      expect(fills[0].deviceRect, const Rect.fromLTRB(20, 10, 28, 18));
      expect(fills[1].deviceRect, const Rect.fromLTRB(0, 0, 8, 8));
    });

    test('the device transform is the root of the composition', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..transform2D(const Transform2D.translation(1, 2))
        ..drawRect(0, 0, 10, 10, paint);

      // A device pixel ratio of 2 enters here and multiplies everything below
      // it, translation included.
      final sink = _play(
        list,
        deviceTransform: const Transform2D.scaling(2, 2),
      );
      expect(
        sink.single<FillRectCall>().deviceRect,
        const Rect.fromLTRB(2, 4, 22, 24),
      );
    });

    test('a rotation reaches the sink as its conservative bounding box', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF123456);
      const double angle = math.pi / 4;
      list
        ..transform2D(Transform2D.rotation(angle))
        ..drawRect(0, 0, 10, 10, paint);

      final Rect device = _play(list).single<FillRectCall>().deviceRect;

      // Corners of the rotated square, in the order the transform maps them:
      // (0,0), (10c, 10s), (10c-10s, 10c+10s), (-10s, 10c). The tolerance is
      // for the float32 the encoder stores the matrix in, not for the maths.
      final double c = math.cos(angle);
      final double s = math.sin(angle);
      expect(device.left, closeTo(-10 * s, 1e-5));
      expect(device.top, closeTo(0, 1e-5));
      expect(device.right, closeTo(10 * c, 1e-5));
      expect(device.bottom, closeTo(10 * (c + s), 1e-5));

      // Stated as an approximation rather than left to be discovered: the box
      // is twice the area of the square it stands for, and every pixel of that
      // excess would be painted. A rotated fill needs a quad primitive, not a
      // tighter box.
      expect(device.width * device.height, closeTo(200, 1e-3));
      expect(device.width * device.height, greaterThan(100));
    });
  });

  group('clip', () {
    test('nested clips intersect and restore reopens the outer one', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list
        ..clipRect(10, 10, 50, 50)
        ..save()
        ..clipRect(30, 0, 80, 80)
        ..drawRect(0, 0, 100, 100, paint)
        ..restore()
        ..drawRect(0, 0, 100, 100, paint);

      final List<FillRectCall> fills = _play(list).allOf<FillRectCall>();
      expect(fills, hasLength(2));
      expect(fills[0].clip, const Rect.fromLTRB(30, 10, 50, 50));
      expect(fills[1].clip, const Rect.fromLTRB(10, 10, 50, 50));
    });

    test('the surface bounds are already a clip before any clipRect', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRect(0, 0, 10, 10, paint);
      expect(
        _play(list, deviceBounds: const Rect.fromLTRB(0, 0, 20, 20))
            .single<FillRectCall>()
            .clip,
        const Rect.fromLTRB(0, 0, 20, 20),
      );
    });

    test('a primitive outside the clip never reaches the sink', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFF0000);
      list
        ..clipRect(0, 0, 10, 10)
        ..drawRect(50, 50, 60, 60, paint)
        ..drawRRectUniform(50, 50, 60, 60, 2, 2, paint)
        ..drawImage(list.addImage(Object()), 0, 0, 4, 4, 50, 50, 60, 60, paint);

      expect(_play(list).callCount, 0);
    });

    test('a rect merely touching the clip edge is culled', () {
      // Rect.intersects is strict, and a shared edge encloses no pixel; a
      // primitive that only touches would otherwise reach the rasteriser as an
      // empty span.
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFF0000);
      list
        ..clipRect(0, 0, 10, 10)
        ..drawRect(10, 0, 20, 10, paint);
      expect(_play(list).callCount, 0);
    });

    test('an empty clip suppresses even the primitives with no bounds', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFF0000);
      final int path = list.addPath(Object());
      list
        ..clipRect(0, 0, 10, 10)
        ..clipRect(60, 60, 70, 70)
        ..drawPath(path, paint);
      expect(_play(list).callCount, 0);
    });

    test('clips are transformed by the transform in force at the time', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list
        ..transform2D(const Transform2D.translation(5, 5))
        ..clipRect(0, 0, 10, 10)
        ..drawRect(0, 0, 100, 100, paint);
      expect(
        _play(list).single<FillRectCall>().clip,
        const Rect.fromLTRB(5, 5, 15, 15),
      );
    });
  });

  group('opcodes', () {
    test('every supported command round-trips through the player', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF102030);
      final int layerPaint = list.addPaint(
        colorArgb: 0x80FFFFFF,
        blendMode: blendModePlus,
      );
      final path = Object();
      final image = Object();
      final int pathId = list.addPath(path);
      final int imageId = list.addImage(image);
      final glyphIds = Int32List.fromList(<int>[11, 22]);
      final glyphOffsets = Float32List.fromList(<double>[0, 0, 3, 4]);

      list
        ..save()
        ..transform2D(const Transform2D.translation(5, 5))
        ..clipRect(0, 0, 50, 50)
        ..drawRect(0, 0, 10, 10, paint)
        ..drawRRectUniform(0, 0, 10, 10, 2, 3, paint)
        ..drawPath(pathId, paint)
        ..drawImage(imageId, 0, 0, 4, 4, 0, 0, 20, 20, paint)
        ..drawGlyphRun(7, paint, 1, 2, glyphIds, glyphOffsets, 2)
        ..saveLayer(0, 0, 30, 30, layerPaint)
        ..drawRect(0, 0, 5, 5, paint)
        ..restore()
        ..restore();

      final List<RasterCall> calls = _play(list).calls;
      expect(
        calls.map((c) => c.runtimeType).toList(),
        <Type>[
          FillRectCall,
          FillRRectCall,
          DrawPathCall,
          DrawImageCall,
          DrawGlyphRunCall,
          BeginLayerCall,
          FillRectCall,
          EndLayerCall,
        ],
      );

      const Rect clip = Rect.fromLTRB(5, 5, 55, 55);
      const ReplayPaint expectedPaint = ReplayPaint(
        argbColor: 0xFF102030,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrcOver,
        antiAlias: true,
      );

      final fill = calls[0] as FillRectCall;
      expect(fill.deviceRect, const Rect.fromLTRB(5, 5, 15, 15));
      expect(fill.clip, clip);
      expect(fill.paint, expectedPaint);

      final rrect = calls[1] as FillRRectCall;
      expect(rrect.deviceRect, const Rect.fromLTRB(5, 5, 15, 15));
      expect(rrect.deviceRadii, <double>[2, 3, 2, 3, 2, 3, 2, 3]);

      final drawPath = calls[2] as DrawPathCall;
      expect(drawPath.path, same(path));
      expect(drawPath.transform, const Transform2D.translation(5, 5));
      expect(drawPath.clip, clip);

      final drawImage = calls[3] as DrawImageCall;
      expect(drawImage.image, same(image));
      expect(drawImage.sourceRect, const Rect.fromLTRB(0, 0, 4, 4));
      expect(drawImage.deviceRect, const Rect.fromLTRB(5, 5, 25, 25));

      final glyphs = calls[4] as DrawGlyphRunCall;
      expect(glyphs.fontId, 7);
      expect(glyphs.deviceOrigin, const Offset(6, 7));
      expect(glyphs.glyphIds, <int>[11, 22]);
      expect(glyphs.deviceOffsets, <double>[0, 0, 3, 4]);

      final layer = calls[5] as BeginLayerCall;
      expect(layer.deviceBounds, const Rect.fromLTRB(5, 5, 35, 35));
      expect(layer.clip, clip);
      expect(layer.paint.argbColor, 0x80FFFFFF);
      expect(layer.paint.blendMode, blendModePlus);

      // The layer's declared bounds clip its contents, not only its composite.
      expect(
          (calls[6] as FillRectCall).clip, const Rect.fromLTRB(5, 5, 35, 35));
    });

    test('glyph offsets arrive in device space, positioned by the origin', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..transform2D(const Transform2D.scaling(2, 2))
        ..drawGlyphRun(
          3,
          paint,
          10,
          20,
          Int32List.fromList(<int>[1, 2]),
          Float32List.fromList(<double>[0, 0, 5, 1]),
          2,
        );

      final glyphs = _play(list).single<DrawGlyphRunCall>();
      expect(glyphs.deviceOrigin, const Offset(20, 40));
      expect(glyphs.deviceOffsets, <double>[0, 0, 10, 2]);
      // The matrix travels with the run so outlines can be scaled; it must not
      // be applied to the offsets a second time.
      expect(glyphs.transform, const Transform2D.scaling(2, 2));
    });

    test('rounded-rectangle radii scale with the axes they belong to', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..transform2D(const Transform2D.scaling(2, 4))
        ..drawRRect(0, 0, 10, 10, 1, 2, 3, 4, 5, 6, 7, 8, paint);

      expect(
        _play(list).single<FillRRectCall>().deviceRadii,
        <double>[2, 8, 6, 16, 10, 24, 14, 32],
      );
    });

    test('layers nest, and each restore closes only its own', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..saveLayer(0, 0, 50, 50, paint)
        ..save()
        ..saveLayer(0, 0, 20, 20, paint)
        ..restore()
        ..restore()
        ..restore();

      expect(
        _play(list).calls.map((c) => c.runtimeType).toList(),
        <Type>[
          BeginLayerCall,
          BeginLayerCall,
          EndLayerCall,
          EndLayerCall,
        ],
      );
    });

    test('a layer clipped away still gets a balanced begin/end pair', () {
      // The sink keeps a stack; a missing end would misattribute every
      // primitive after it.
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..clipRect(0, 0, 10, 10)
        ..saveLayer(80, 80, 90, 90, paint)
        ..drawRect(80, 80, 90, 90, paint)
        ..restore();

      final List<RasterCall> calls = _play(list).calls;
      expect(
        calls.map((c) => c.runtimeType).toList(),
        <Type>[BeginLayerCall, EndLayerCall],
      );
      expect((calls[0] as BeginLayerCall).deviceBounds.isEmpty, isTrue);
    });
  });

  group('failures', () {
    test('an unbalanced restore names itself and points at the command', () {
      final list = DisplayList()
        ..save()
        ..restore()
        ..restore();

      expect(
        () => _play(list),
        throwsA(
          isA<UnbalancedRestoreException>()
              .having((e) => e.commandIndex, 'commandIndex', 2)
              .having((e) => e.wordOffset, 'wordOffset', 2),
        ),
      );
    });

    test('a stream that ends with a save open is refused', () {
      final list = DisplayList()
        ..save()
        ..save()
        ..restore();

      expect(
        () => _play(list),
        throwsA(
          isA<UnbalancedSaveException>()
              .having((e) => e.outstandingSaves, 'outstandingSaves', 1),
        ),
      );
    });

    test('clipPath fails loudly with its name and word offset', () {
      final list = DisplayList();
      final int path = list.addPath(Object());
      list
        ..save()
        ..clipPath(path);

      expect(
        () => _play(list),
        throwsA(
          isA<UnsupportedCommandException>()
              .having((e) => e.opcode, 'opcode', opClipPath)
              .having((e) => e.wordOffset, 'wordOffset', 1)
              .having((e) => e.toString(), 'toString', contains('clipPath')),
        ),
      );
    });

    test('a difference clip is refused rather than approximated', () {
      final list = DisplayList()..clipRect(0, 0, 10, 10, op: clipOpDifference);
      expect(
        () => _play(list),
        throwsA(isA<UnsupportedCommandException>()),
      );
    });

    test('a paint style no encoder could write is refused, not guessed', () {
      // Style 3 fits the two-bit field but names nothing; addPaint rejects it,
      // so this can only arrive from a corrupt or hand-written buffer. Reading
      // it as a fill would put a solid block on screen and blame the shape.
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.drawRect(0, 0, 10, 10, paint);

      expect(
        () => DisplayListPlayer(RecordingSink()).play(
          DisplayListReader(list),
          _PaintStyleOverride(DisplayListResources(list), 3),
          deviceBounds: _surface,
        ),
        throwsA(
          isA<UnsupportedCommandException>().having(
            (e) => e.toString(),
            'toString',
            contains('paint style 3'),
          ),
        ),
      );
    });
  });

  group('stroked shapes become centrelines', () {
    // The rectangle primitives take device geometry and no matrix, so they
    // cannot express a stroke whose width is in local units. The player
    // rebuilds those shapes as paths instead of widening every sink.

    test('a stroked rect leaves as a path, in LOCAL space, with the matrix',
        () {
      final list = DisplayList();
      final int paint = list.addPaint(
        colorArgb: 0xFF000000,
        style: paintStyleStroke,
        strokeWidth: 2,
      );
      list
        ..save()
        ..transform2D(const Transform2D.scaling(2, 2))
        ..drawRect(1, 1, 5, 5, paint)
        ..restore();

      final sink = _play(list);
      expect(sink.allOf<FillRectCall>(), isEmpty);
      final DrawPathCall call = sink.single<DrawPathCall>();
      // Local, not device: the sink strokes before transforming, so a
      // pre-scaled centreline would double the width a second time.
      expect((call.path as Path).bounds, const Rect.fromLTRB(1, 1, 5, 5));
      expect(call.transform, const Transform2D.scaling(2, 2));
      expect(call.paint.strokeWidth, 2);
      expect(call.paint.style, paintStyleStroke);
    });

    test('a stroked rounded rect keeps its radii unscaled', () {
      final list = DisplayList();
      final int paint = list.addPaint(
        colorArgb: 0xFF000000,
        style: paintStyleStroke,
        strokeWidth: 1,
      );
      list
        ..save()
        ..transform2D(const Transform2D.scaling(3, 3))
        ..drawRRect(0, 0, 10, 10, 4, 4, 4, 4, 4, 4, 4, 4, paint)
        ..restore();

      final sink = _play(list);
      expect(sink.allOf<FillRRectCall>(), isEmpty);
      final DrawPathCall call = sink.single<DrawPathCall>();
      final Path path = call.path as Path;
      expect(path.bounds, const Rect.fromLTRB(0, 0, 10, 10));
      // A 4-unit corner: the leftmost point of the top edge sits 4 in from the
      // corner. Scaled radii would have put it at 12 and bulged the shape.
      expect(path.pointX(0), closeTo(4, 1e-6));
      expect(call.transform, const Transform2D.scaling(3, 3));
    });

    test('fillAndStroke travels as one path so the sink can order the halves',
        () {
      final list = DisplayList();
      final int paint = list.addPaint(
        colorArgb: 0xFF000000,
        style: paintStyleFillAndStroke,
        strokeWidth: 2,
      );
      list.drawRect(0, 0, 10, 10, paint);

      final sink = _play(list);
      // Not a fast rect fill plus a path stroke: that would need a second
      // ReplayPaint, and the id-keyed cache has one per paint id.
      expect(sink.allOf<FillRectCall>(), isEmpty);
      expect(sink.single<DrawPathCall>().paint.style, paintStyleFillAndStroke);
    });

    test('a stroke reaching into the clip is not culled away', () {
      // The rect is entirely outside the clip; only the outer half of its
      // stroke crosses into it. Culling on the un-inflated bounds - which is
      // what the fill route does - would drop it.
      final list = DisplayList();
      final int paint = list.addPaint(
        colorArgb: 0xFF000000,
        style: paintStyleStroke,
        strokeWidth: 4,
      );
      list
        ..save()
        ..clipRect(0, 0, 10, 10)
        ..drawRect(11, 0, 20, 10, paint)
        ..restore();

      expect(_play(list).allOf<DrawPathCall>(), hasLength(1));
    });
  });

  group('reuse', () {
    test('one player replays two lists without leaking paint ids', () {
      // Ids are frame-local: paint 0 means something different in the second
      // list, and a cache that survived would answer with the first colour.
      final sink = RecordingSink();
      final player = DisplayListPlayer(sink);

      final first = DisplayList();
      first.drawRect(0, 0, 1, 1, first.addPaint(colorArgb: 0xFFAA0000));
      player.play(
        DisplayListReader(first),
        DisplayListResources(first),
        deviceBounds: _surface,
      );

      final second = DisplayList();
      second.drawRect(0, 0, 1, 1, second.addPaint(colorArgb: 0xFF00BB00));
      player.play(
        DisplayListReader(second),
        DisplayListResources(second),
        deviceBounds: _surface,
      );

      final List<FillRectCall> fills = sink.allOf<FillRectCall>();
      expect(fills, hasLength(2));
      expect(fills[0].paint.argbColor, 0xFFAA0000);
      expect(fills[1].paint.argbColor, 0xFF00BB00);
    });

    test('a paint used twice is resolved once', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF010203);
      list
        ..drawRect(0, 0, 1, 1, paint)
        ..drawRect(2, 2, 3, 3, paint);

      final List<FillRectCall> fills = _play(list).allOf<FillRectCall>();
      expect(identical(fills[0].paint, fills[1].paint), isTrue);
    });

    test('replaying leaves the state balanced for the next frame', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list
        ..save()
        ..transform2D(const Transform2D.scaling(3, 3))
        ..drawRect(0, 0, 1, 1, paint)
        ..restore();

      final sink = RecordingSink();
      final player = DisplayListPlayer(sink);
      for (var i = 0; i < 3; i++) {
        player.play(
          DisplayListReader(list),
          DisplayListResources(list),
          deviceBounds: _surface,
        );
      }
      expect(player.state.saveDepth, 0);
      expect(player.state.stackGrowths, 0);
      expect(
        sink.allOf<FillRectCall>().map((c) => c.deviceRect).toSet(),
        <Rect>{const Rect.fromLTRB(0, 0, 3, 3)},
      );
    });
  });
}

/// Answers with a style the encoder cannot write, which is the only way to
/// reach the player's "unknown paint style" branch without a corrupt buffer.
final class _PaintStyleOverride implements ReplayResources {
  _PaintStyleOverride(this._inner, this._style);

  final ReplayResources _inner;
  final int _style;

  @override
  int paintStyle(int id) => _style;

  @override
  int paintColor(int id) => _inner.paintColor(id);

  @override
  double paintStrokeWidth(int id) => _inner.paintStrokeWidth(id);

  @override
  int paintBlendMode(int id) => _inner.paintBlendMode(id);

  @override
  bool paintAntiAlias(int id) => _inner.paintAntiAlias(id);

  @override
  Object pathAt(int id) => _inner.pathAt(id);

  @override
  Object imageAt(int id) => _inner.imageAt(id);

  @override
  Object fontAt(int id) => _inner.fontAt(id);
}
