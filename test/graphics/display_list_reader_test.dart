import 'dart:typed_data';

import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:test/test.dart';

/// A list holding one `drawRect`: two words, four floats. Small enough that
/// every corruption below can be described exactly.
DisplayList _oneRect() {
  final list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF808080);
  return list..drawRect(1.0, 2.0, 3.0, 4.0, paint);
}

void main() {
  group('cursor', () {
    test('commandIndex counts from zero and opcode is invalid at the ends', () {
      final list = DisplayList()
        ..save()
        ..restore();
      final reader = DisplayListReader(list);
      expect(reader.commandIndex, -1);
      expect(reader.opcode, opInvalid);

      reader.moveNext();
      expect(reader.commandIndex, 0);
      reader.moveNext();
      expect(reader.commandIndex, 1);

      expect(reader.moveNext(), isFalse);
      expect(reader.opcode, opInvalid);
      expect(reader.intOperandCount, 0);
      expect(reader.floatOperandCount, 0);
    });

    test('rewind replays the same stream from the same reader', () {
      final list = _oneRect();
      final reader = DisplayListReader(list);
      expect(reader.moveNext(), isTrue);
      expect(reader.floatAt(0), 1.0);
      expect(reader.moveNext(), isFalse);

      reader.rewind();

      expect(reader.commandIndex, -1);
      expect(reader.moveNext(), isTrue);
      expect(reader.floatAt(0), 1.0);
    });

    test('the float cursor advances only by the slots each command claims', () {
      final list = DisplayList()
        ..save()
        ..clipRect(1.0, 2.0, 3.0, 4.0)
        ..save()
        ..drawRect(5.0, 6.0, 7.0, 8.0, 0);

      final reader = DisplayListReader(list);
      reader.moveNext();
      expect(reader.floatOperandCount, 0);
      reader.moveNext();
      expect(reader.floatAt(0), 1.0);
      reader.moveNext();
      expect(reader.floatOperandCount, 0);
      reader.moveNext();
      expect(reader.floatAt(0), 5.0);
      expect(reader.validate(), 4);
    });

    test('operand access is bounds-checked', () {
      final reader = DisplayListReader(_oneRect())..moveNext();
      expect(() => reader.intAt(1), throwsA(isA<RangeError>()));
      expect(() => reader.intAt(-1), throwsA(isA<RangeError>()));
      expect(() => reader.floatAt(4), throwsA(isA<RangeError>()));
      expect(() => reader.floatAt(-1), throwsA(isA<RangeError>()));
    });

    test('a named accessor refuses an opcode that has no such operand', () {
      final reader = DisplayListReader(_oneRect())..moveNext();
      expect(() => reader.pathId, throwsA(isA<StateError>()));
      expect(() => reader.imageId, throwsA(isA<StateError>()));
      expect(() => reader.clipOp, throwsA(isA<StateError>()));
      expect(() => reader.fontId, throwsA(isA<StateError>()));
      expect(() => reader.glyphCount, throwsA(isA<StateError>()));

      final saveReader = DisplayListReader(DisplayList()..save())..moveNext();
      expect(() => saveReader.paintId, throwsA(isA<StateError>()));
    });
  });

  group('corrupt buffers are rejected, not read past', () {
    test('a word stream cut mid-command is detected', () {
      final list = _oneRect();
      final reader = DisplayListReader.overBuffers(
        list.opBuffer,
        list.opLength - 1,
        list.floatBuffer,
        list.floatLength,
      );
      expect(
        reader.moveNext,
        throwsA(
          isA<DisplayListFormatException>().having(
            (e) => e.message,
            'message',
            contains('truncated'),
          ),
        ),
      );
    });

    test('a float stream cut short is detected', () {
      final list = _oneRect();
      final reader = DisplayListReader.overBuffers(
        list.opBuffer,
        list.opLength,
        list.floatBuffer,
        list.floatLength - 1,
      );
      expect(reader.moveNext, throwsA(isA<DisplayListFormatException>()));
    });

    test('a length outside its buffer is refused at construction', () {
      final ops = Uint32List(4);
      final floats = Float32List(4);
      expect(
        () => DisplayListReader.overBuffers(ops, 5, floats, 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => DisplayListReader.overBuffers(ops, 0, floats, -1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a word without the header marker is detected', () {
      final ops = Uint32List(2);
      // Plausible-looking operand data: a small opcode, correct slot counts,
      // but no marker. Without the marker this would decode as a save.
      ops[0] = opSave;
      final reader = DisplayListReader.overBuffers(ops, 1, Float32List(0), 0);
      expect(
        reader.moveNext,
        throwsA(
          isA<DisplayListFormatException>()
              .having((e) => e.wordOffset, 'wordOffset', 0)
              .having((e) => e.message, 'message', contains('header')),
        ),
      );
    });

    test('an unknown opcode is detected', () {
      final ops = Uint32List(1)..[0] = encodeHeader(kOpcodeCount + 3, 0, 0);
      final reader = DisplayListReader.overBuffers(ops, 1, Float32List(0), 0);
      expect(
        reader.moveNext,
        throwsA(
          isA<DisplayListFormatException>().having(
            (e) => e.message,
            'message',
            contains('unknown opcode'),
          ),
        ),
      );
    });

    test('a header whose slot counts disagree with the table is detected', () {
      final ops = Uint32List(4)..[0] = encodeHeader(opDrawRect, 2, 4);
      final reader = DisplayListReader.overBuffers(
        ops,
        3,
        Float32List(4),
        4,
      );
      expect(
        reader.moveNext,
        throwsA(
          isA<DisplayListFormatException>().having(
            (e) => e.message,
            'message',
            contains('int operands'),
          ),
        ),
      );

      final wrongFloats = Uint32List(2)..[0] = encodeHeader(opDrawRect, 1, 6);
      expect(
        DisplayListReader.overBuffers(
          wrongFloats,
          2,
          Float32List(6),
          6,
        ).moveNext,
        throwsA(
          isA<DisplayListFormatException>().having(
            (e) => e.message,
            'message',
            contains('float operands'),
          ),
        ),
      );
    });

    test('a glyph run whose embedded count was corrupted is detected', () {
      final list = DisplayList()
        ..drawGlyphRun(
          1,
          0,
          0.0,
          0.0,
          Int32List.fromList(<int>[4, 5]),
          Float32List.fromList(<double>[0, 0, 1, 1]),
          2,
        );
      // Word 3 is the glyph count; the declared slot counts still say two
      // glyphs, so the disagreement has to be caught.
      list.opBuffer[3] = 3;
      expect(
        DisplayListReader(list).moveNext,
        throwsA(
          isA<DisplayListFormatException>().having(
            (e) => e.message,
            'message',
            contains('glyph count'),
          ),
        ),
      );
    });

    test('a glyph run header too small to hold its own count is detected', () {
      final ops = Uint32List(3)
        ..[0] = encodeHeader(opDrawGlyphRun, 2, 2)
        ..[1] = 0
        ..[2] = 0;
      final reader = DisplayListReader.overBuffers(ops, 3, Float32List(2), 2);
      expect(
        reader.moveNext,
        throwsA(
          isA<DisplayListFormatException>().having(
            (e) => e.message,
            'message',
            contains('at least 3'),
          ),
        ),
      );
    });

    test(
        'desynchronisation cannot go unnoticed: dropping one operand word '
        'derails into a detected failure', () {
      final list = DisplayList()
        ..drawRect(1.0, 2.0, 3.0, 4.0, 0)
        ..drawRect(5.0, 6.0, 7.0, 8.0, 0)
        ..save();

      // Splice out the first command's paint operand, the way a buggy writer
      // or a bad memcpy would. Every following word is now misaligned.
      final ops = Uint32List(list.opLength - 1);
      ops[0] = list.opBuffer[0];
      for (var i = 1; i < ops.length; i++) {
        ops[i] = list.opBuffer[i + 1];
      }
      final reader = DisplayListReader.overBuffers(
        ops,
        ops.length,
        list.floatBuffer,
        list.floatLength,
      );
      expect(reader.validate, throwsA(isA<DisplayListFormatException>()));
    });

    test('trailing float data is reported by validate', () {
      final list = DisplayList()..save();
      final floats = Float32List(4);
      final reader = DisplayListReader.overBuffers(
        list.opBuffer,
        list.opLength,
        floats,
        4,
      );
      expect(
        reader.validate,
        throwsA(
          isA<DisplayListFormatException>().having(
            (e) => e.message,
            'message',
            contains('trailing float data'),
          ),
        ),
      );
    });

    test('the exception names the word where framing was lost', () {
      final list = DisplayList()
        ..save()
        ..save();
      list.opBuffer[1] = 0;
      try {
        DisplayListReader(list).validate();
        fail('expected a DisplayListFormatException');
      } on DisplayListFormatException catch (error) {
        expect(error.wordOffset, 1);
        expect(error.toString(), contains('word 1'));
      }
    });
  });
}
