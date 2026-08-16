import 'dart:typed_data';

import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:test/test.dart';

/// A resource with value equality, to show that interning follows the
/// resource's own `==` rather than identity.
final class _ValuePath {
  const _ValuePath(this.id);

  final int id;

  @override
  bool operator ==(Object other) => other is _ValuePath && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

void main() {
  group('encoding', () {
    test('an empty list encodes nothing', () {
      final list = DisplayList();
      expect(list.opLength, 0);
      expect(list.floatLength, 0);
      expect(list.commandCount, 0);
      expect(DisplayListReader(list).moveNext(), isFalse);
    });

    test('save and restore round-trip', () {
      final list = DisplayList()
        ..save()
        ..restore();

      final reader = DisplayListReader(list);
      expect(reader.moveNext(), isTrue);
      expect(reader.opcode, opSave);
      expect(reader.intOperandCount, 0);
      expect(reader.floatOperandCount, 0);
      expect(reader.moveNext(), isTrue);
      expect(reader.opcode, opRestore);
      expect(reader.moveNext(), isFalse);
      expect(list.commandCount, 2);
    });

    test('saveLayer round-trips bounds and paint', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF102030);
      list.saveLayer(1.5, 2.5, 3.5, 4.5, paint);

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.opcode, opSaveLayer);
      expect(reader.paintId, paint);
      expect(reader.floatAt(0), 1.5);
      expect(reader.floatAt(1), 2.5);
      expect(reader.floatAt(2), 3.5);
      expect(reader.floatAt(3), 4.5);
    });

    test('transform round-trips six components in order', () {
      final list = DisplayList()..transform(1.0, 0.5, -0.5, 2.0, 8.0, -16.0);

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.opcode, opTransform);
      expect(reader.floatOperandCount, 6);
      expect(
        <double>[for (var i = 0; i < 6; i++) reader.floatAt(i)],
        <double>[1.0, 0.5, -0.5, 2.0, 8.0, -16.0],
      );
    });

    test('clipRect round-trips the clip operation', () {
      final list = DisplayList()
        ..clipRect(0.0, 0.0, 10.0, 20.0)
        ..clipRect(1.0, 2.0, 3.0, 4.0, op: clipOpDifference);

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.clipOp, clipOpIntersect);
      expect(reader.floatAt(3), 20.0);
      reader.moveNext();
      expect(reader.clipOp, clipOpDifference);
      expect(reader.floatAt(0), 1.0);
    });

    test('clipPath round-trips path and operation', () {
      final list = DisplayList();
      final int path = list.addPath(Object());
      list.clipPath(path, op: clipOpDifference);

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.opcode, opClipPath);
      expect(reader.pathId, path);
      expect(reader.clipOp, clipOpDifference);
      expect(reader.floatOperandCount, 0);
    });

    test('drawRect round-trips bounds and paint', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF00FF00);
      list.drawRect(-4.0, -8.0, 12.0, 24.0, paint);

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.opcode, opDrawRect);
      expect(reader.paintId, paint);
      expect(reader.floatAt(0), -4.0);
      expect(reader.floatAt(1), -8.0);
      expect(reader.floatAt(2), 12.0);
      expect(reader.floatAt(3), 24.0);
    });

    test('drawRRect round-trips eight radii after the bounds', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.drawRRect(
        0.0,
        0.0,
        100.0,
        50.0,
        1.0,
        2.0,
        3.0,
        4.0,
        5.0,
        6.0,
        7.0,
        8.0,
        paint,
      );

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.opcode, opDrawRRect);
      expect(reader.floatOperandCount, 12);
      expect(
        <double>[for (var i = 4; i < 12; i++) reader.floatAt(i)],
        <double>[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0],
      );
    });

    test('drawRRectUniform repeats one radius on every corner', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.drawRRectUniform(0.0, 0.0, 10.0, 10.0, 3.0, 4.0, paint);

      final reader = DisplayListReader(list)..moveNext();
      expect(
        <double>[for (var i = 4; i < 12; i++) reader.floatAt(i)],
        <double>[3.0, 4.0, 3.0, 4.0, 3.0, 4.0, 3.0, 4.0],
      );
    });

    test('drawPath round-trips both ids', () {
      final list = DisplayList();
      final int path = list.addPath(Object());
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawPath(path, paint);

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.opcode, opDrawPath);
      expect(reader.pathId, path);
      expect(reader.paintId, paint);
    });

    test('drawImage round-trips source and destination rects', () {
      final list = DisplayList();
      final int image = list.addImage(Object());
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawImage(
        image,
        0.0,
        0.0,
        64.0,
        32.0,
        10.0,
        20.0,
        74.0,
        52.0,
        paint,
      );

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.opcode, opDrawImage);
      expect(reader.imageId, image);
      expect(reader.paintId, paint);
      expect(
        <double>[for (var i = 0; i < 8; i++) reader.floatAt(i)],
        <double>[0.0, 0.0, 64.0, 32.0, 10.0, 20.0, 74.0, 52.0],
      );
    });

    test('drawGlyphRun round-trips ids and per-glyph offsets', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF202020);
      final glyphIds = Int32List.fromList(<int>[7, 8, 9]);
      final offsets = Float32List.fromList(
        <double>[0.0, 0.0, 6.0, 0.5, 12.0, 1.0],
      );
      list.drawGlyphRun(3, paint, 20.0, 40.0, glyphIds, offsets, 3);

      final reader = DisplayListReader(list)..moveNext();
      expect(reader.opcode, opDrawGlyphRun);
      expect(reader.fontId, 3);
      expect(reader.paintId, paint);
      expect(reader.glyphCount, 3);
      expect(reader.floatAt(0), 20.0);
      expect(reader.floatAt(1), 40.0);
      expect(
        <int>[for (var i = 0; i < 3; i++) reader.glyphIdAt(i)],
        <int>[7, 8, 9],
      );
      expect(reader.glyphOffsetXAt(2), 12.0);
      expect(reader.glyphOffsetYAt(2), 1.0);
    });

    test('a run longer than the header can describe is refused', () {
      final list = DisplayList();
      expect(
        () => list.drawGlyphRun(
          0,
          0,
          0.0,
          0.0,
          Int32List(kMaxGlyphsPerRun + 1),
          Float32List((kMaxGlyphsPerRun + 1) * 2),
          kMaxGlyphsPerRun + 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(list.commandCount, 0);
    });

    test('a run whose operand arrays are too short is refused', () {
      final list = DisplayList();
      expect(
        () => list.drawGlyphRun(
          0,
          0,
          0.0,
          0.0,
          Int32List(2),
          Float32List(4),
          3,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => list.drawGlyphRun(
          0,
          0,
          0.0,
          0.0,
          Int32List(4),
          Float32List(2),
          2,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an unknown clip operation is refused', () {
      final list = DisplayList();
      expect(
        () => list.clipRect(0.0, 0.0, 1.0, 1.0, op: 99),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => list.clipPath(0, op: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(list.commandCount, 0);
    });

    test('every header declares the slot counts the table demands', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF123456);
      final int path = list.addPath(Object());
      final int image = list.addImage(Object());
      list
        ..save()
        ..saveLayer(0.0, 0.0, 1.0, 1.0, paint)
        ..transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
        ..clipRect(0.0, 0.0, 1.0, 1.0)
        ..clipPath(path)
        ..drawRect(0.0, 0.0, 1.0, 1.0, paint)
        ..drawRRectUniform(0.0, 0.0, 1.0, 1.0, 1.0, 1.0, paint)
        ..drawPath(path, paint)
        ..drawImage(image, 0, 0, 1, 1, 0, 0, 1, 1, paint)
        ..drawGlyphRun(
          0,
          paint,
          0.0,
          0.0,
          Int32List.fromList(<int>[1]),
          Float32List.fromList(<double>[0.0, 0.0]),
          1,
        )
        ..restore();

      final reader = DisplayListReader(list);
      final seen = <int>{};
      while (reader.moveNext()) {
        seen.add(reader.opcode);
        final int header = list.opBuffer[reader.headerOffset];
        expect(headerMarker(header), kHeaderMarker);
        expect(headerOpcode(header), reader.opcode);
        expect(headerIntSlots(header), reader.intOperandCount);
        expect(headerFloatSlots(header), reader.floatOperandCount);
        final int expectedInts = intSlotsFor(reader.opcode);
        if (expectedInts != kVariableSlots) {
          expect(reader.intOperandCount, expectedInts);
        }
        final int expectedFloats = floatSlotsFor(reader.opcode);
        if (expectedFloats != kVariableSlots) {
          expect(reader.floatOperandCount, expectedFloats);
        }
      }
      expect(seen.length, kOpcodeCount - 1);
      expect(reader.validate(), list.commandCount);
    });
  });

  group('resource interning', () {
    test('identical paints collapse to one id', () {
      final list = DisplayList();
      final int a = list.addPaint(
        colorArgb: 0xFF336699,
        style: paintStyleStroke,
        strokeWidth: 2.5,
        blendMode: blendModePlus,
        antiAlias: false,
      );
      final int b = list.addPaint(
        colorArgb: 0xFF336699,
        style: paintStyleStroke,
        strokeWidth: 2.5,
        blendMode: blendModePlus,
        antiAlias: false,
      );
      expect(b, a);
      expect(list.paintCount, 1);
    });

    test('each differing paint field yields a new id', () {
      final list = DisplayList();
      final int base = list.addPaint(colorArgb: 0xFF000000);
      expect(list.addPaint(colorArgb: 0xFF000001), isNot(base));
      expect(
        list.addPaint(colorArgb: 0xFF000000, style: paintStyleStroke),
        isNot(base),
      );
      expect(
        list.addPaint(colorArgb: 0xFF000000, strokeWidth: 1.0),
        isNot(base),
      );
      expect(
        list.addPaint(colorArgb: 0xFF000000, blendMode: blendModeSrc),
        isNot(base),
      );
      expect(
        list.addPaint(colorArgb: 0xFF000000, antiAlias: false),
        isNot(base),
      );
      expect(
        list.addPaint(
          colorArgb: 0xFF000000,
          fillRule: pathFillRuleEvenOdd,
        ),
        isNot(base),
      );
      expect(list.paintCount, 7);
    });

    test('paints differing below float32 precision are one paint', () {
      final list = DisplayList();
      final int a = list.addPaint(colorArgb: 0xFF000000, strokeWidth: 1.0);
      final int b = list.addPaint(
        colorArgb: 0xFF000000,
        strokeWidth: 1.0 + 1e-9,
      );
      expect(b, a);
      expect(list.paintCount, 1);
    });

    test('paint fields survive interning', () {
      final list = DisplayList();
      final int id = list.addPaint(
        colorArgb: 0xDEADBEEF,
        style: paintStyleFillAndStroke,
        strokeWidth: 3.25,
        blendMode: blendModeSrc,
        antiAlias: false,
        fillRule: pathFillRuleEvenOdd,
      );
      expect(list.paintColor(id), 0xDEADBEEF);
      expect(list.paintStyle(id), paintStyleFillAndStroke);
      expect(list.paintStrokeWidth(id), 3.25);
      expect(list.paintBlendMode(id), blendModeSrc);
      expect(list.paintAntiAlias(id), isFalse);
      expect(list.paintFillRule(id), pathFillRuleEvenOdd);
    });

    test('a paint id outside the table is refused', () {
      final list = DisplayList()..addPaint(colorArgb: 0);
      expect(() => list.paintColor(1), throwsA(isA<RangeError>()));
      expect(() => list.paintColor(-1), throwsA(isA<RangeError>()));
    });

    test('unknown paint style or blend mode is refused', () {
      final list = DisplayList();
      expect(
        () => list.addPaint(colorArgb: 0, style: 7),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => list.addPaint(colorArgb: 0, blendMode: 7),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('many distinct paints all get distinct ids', () {
      final list = DisplayList(initialPaintCapacity: 2);
      final ids = <int>{};
      for (var i = 0; i < 500; i++) {
        ids.add(list.addPaint(colorArgb: 0xFF000000 + i, strokeWidth: i / 4));
      }
      expect(ids.length, 500);
      expect(list.paintCount, 500);
      expect(list.paintColor(499), 0xFF0001F3);
    });

    test('paths intern by their own equality', () {
      final list = DisplayList();
      final identityA = Object();
      final identityB = Object();
      expect(list.addPath(identityA), 0);
      expect(list.addPath(identityA), 0);
      expect(list.addPath(identityB), 1);
      expect(list.addPath(const _ValuePath(9)), 2);
      expect(list.addPath(const _ValuePath(9)), 2);
      expect(list.addPath(const _ValuePath(10)), 3);
      expect(list.pathCount, 4);
      expect(list.pathAt(1), same(identityB));
    });

    test('images intern independently of paths', () {
      final list = DisplayList();
      final shared = Object();
      expect(list.addPath(shared), 0);
      expect(list.addImage(shared), 0);
      expect(list.addImage(Object()), 1);
      expect(list.pathCount, 1);
      expect(list.imageCount, 2);
      expect(list.imageAt(0), same(shared));
    });
  });

  group('arena reuse', () {
    test('reset rewinds the cursors and drops the resource tables', () {
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF00FF00);
      list
        ..addPath(Object())
        ..addImage(Object())
        ..drawRect(0.0, 0.0, 1.0, 1.0, paint);
      expect(list.commandCount, 1);

      list.reset();

      expect(list.opLength, 0);
      expect(list.floatLength, 0);
      expect(list.commandCount, 0);
      expect(list.paintCount, 0);
      expect(list.pathCount, 0);
      expect(list.imageCount, 0);
      expect(DisplayListReader(list).moveNext(), isFalse);
    });

    test('reset keeps the buffers themselves, not just their size', () {
      final list = DisplayList(initialOpCapacity: 16, initialFloatCapacity: 16);
      for (var i = 0; i < 500; i++) {
        list.drawRect(0.0, 0.0, 1.0, 1.0, 0);
      }
      final Uint32List ops = list.opBuffer;
      final Float32List floats = list.floatBuffer;
      final int opCapacity = list.opCapacity;
      final int floatCapacity = list.floatCapacity;

      list.reset();

      expect(list.opBuffer, same(ops));
      expect(list.floatBuffer, same(floats));
      expect(list.opCapacity, opCapacity);
      expect(list.floatCapacity, floatCapacity);
    });

    test('a repeated frame reallocates nothing', () {
      final list = DisplayList(initialOpCapacity: 16, initialFloatCapacity: 16);

      void encodeFrame() {
        final int paint = list.addPaint(colorArgb: 0xFF112233);
        for (var i = 0; i < 5000; i++) {
          list.drawRect(i.toDouble(), 0.0, i + 1.0, 8.0, paint);
        }
      }

      encodeFrame();
      final int firstFrameGrowths = list.bufferGrowths;
      final Uint32List ops = list.opBuffer;
      final Float32List floats = list.floatBuffer;
      final int commands = list.commandCount;

      for (var frame = 0; frame < 10; frame++) {
        list.reset();
        encodeFrame();
      }

      expect(list.bufferGrowths, firstFrameGrowths);
      expect(list.opBuffer, same(ops));
      expect(list.floatBuffer, same(floats));
      expect(list.commandCount, commands);
    });

    test('growth stays logarithmic in the number of commands', () {
      final list = DisplayList(initialOpCapacity: 16, initialFloatCapacity: 16);
      const int commands = 50000;
      for (var i = 0; i < commands; i++) {
        list.drawRect(0.0, 0.0, 1.0, 1.0, 0);
      }
      expect(list.commandCount, commands);
      expect(list.opLength, commands * 2);
      expect(list.floatLength, commands * 4);

      // Doubling from 16 slots: at most log2(cap/16)+1 reallocations per
      // buffer. Anything per-command would be four orders of magnitude more.
      expect(list.bufferGrowths, lessThan(40));
      expect(list.opCapacity, greaterThanOrEqualTo(list.opLength));
      expect(list.floatCapacity, greaterThanOrEqualTo(list.floatLength));
    });
  });
}
