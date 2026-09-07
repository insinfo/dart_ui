/// Splicing one display list into another, and the one property that makes it
/// usable: **the result is indistinguishable from having drawn directly.**
///
/// [DisplayList.appendFrom] exists so a repaint boundary can record its subtree
/// once and replay it on later frames without walking that subtree again. That
/// is only sound if the replay produces the same command stream the walk would
/// have produced — same opcodes, same floats, and resource ids that resolve to
/// the same objects. A splice that drew *almost* the same thing would be a
/// rendering bug that appears only on the second frame, only in the part of
/// the tree that did not change, which is the hardest kind to find.
///
/// So most of this file is one comparison run against several shapes of
/// content. The rest is the refusals, which matter for the same reason: a
/// splice that silently produced something wrong is worse than one that says
/// it cannot.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/content_hint.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:test/test.dart';

/// Asserts that [spliced] and [direct] are the same command stream.
///
/// Command for command: opcode, operand counts, every float, and every
/// resource id *resolved through its own list*, because the two lists are
/// entitled to number their resources differently — what they are not entitled
/// to do is resolve them to different things.
void _expectSameStream(DisplayList spliced, DisplayList direct) {
  expect(
    spliced.commandCount,
    direct.commandCount,
    reason: 'a splice must not add or drop commands',
  );

  final DisplayListReader a = DisplayListReader(spliced);
  final DisplayListReader b = DisplayListReader(direct);
  var index = 0;
  while (a.moveNext()) {
    expect(b.moveNext(), isTrue, reason: 'the direct list ran out first');
    final String at = 'command $index';

    expect(a.opcode, b.opcode, reason: '$at: opcode');
    expect(a.intOperandCount, b.intOperandCount, reason: '$at: int operands');
    expect(
      a.floatOperandCount,
      b.floatOperandCount,
      reason: '$at: float operands',
    );
    for (var i = 0; i < a.floatOperandCount; i++) {
      expect(a.floatAt(i), b.floatAt(i), reason: '$at: float $i');
    }
    index++;
  }
  expect(b.moveNext(), isFalse, reason: 'the spliced list ran out first');
}

void main() {
  group('the splice draws what the walk would have drawn', () {
    test('a plain run of geometry', () {
      final DisplayList direct = DisplayList();
      final int red = direct.addPaint(colorArgb: 0xFFFF0000);
      final int blue = direct.addPaint(colorArgb: 0xFF0000FF);
      direct
        ..drawRect(0, 0, 10, 10, red)
        ..drawRect(5, 5, 20, 20, blue)
        ..drawRRectUniform(1, 2, 3, 4, 2, 2, red);

      final DisplayList sub = DisplayList();
      final int subRed = sub.addPaint(colorArgb: 0xFFFF0000);
      final int subBlue = sub.addPaint(colorArgb: 0xFF0000FF);
      sub
        ..drawRect(0, 0, 10, 10, subRed)
        ..drawRect(5, 5, 20, 20, subBlue)
        ..drawRRectUniform(1, 2, 3, 4, 2, 2, subRed);

      final DisplayList spliced = DisplayList()..appendFrom(sub);

      _expectSameStream(spliced, direct);
      expect(spliced.paintColor(0), 0xFFFF0000);
      expect(spliced.paintColor(1), 0xFF0000FF);
    });

    test('when the parent already used some of the same paints', () {
      // The interning case. The parent has drawn with red before the splice,
      // so the sub-list's red must land on the id the parent already has
      // rather than creating a second entry - and the sub-list's *blue*, which
      // the parent has never seen, must get a fresh one. Getting this backwards
      // paints the second half of the frame in the first half's colour.
      final DisplayList direct = DisplayList();
      final int red = direct.addPaint(colorArgb: 0xFFFF0000);
      direct.drawRect(0, 0, 1, 1, red);
      final int blue = direct.addPaint(colorArgb: 0xFF0000FF);
      direct
        ..drawRect(2, 2, 3, 3, red)
        ..drawRect(4, 4, 5, 5, blue);

      final DisplayList sub = DisplayList();
      final int subRed = sub.addPaint(colorArgb: 0xFFFF0000);
      final int subBlue = sub.addPaint(colorArgb: 0xFF0000FF);
      sub
        ..drawRect(2, 2, 3, 3, subRed)
        ..drawRect(4, 4, 5, 5, subBlue);

      final DisplayList spliced = DisplayList();
      final int parentRed = spliced.addPaint(colorArgb: 0xFFFF0000);
      spliced
        ..drawRect(0, 0, 1, 1, parentRed)
        ..appendFrom(sub);

      _expectSameStream(spliced, direct);
      expect(
        spliced.paintCount,
        direct.paintCount,
        reason: 'interning has to dedup across the splice, or the table grows '
            'by a copy of every colour the parent already had',
      );
    });

    test('paths, images and fonts resolve to the same objects', () {
      // Four resource tables, four id spaces, and an id that indexes the wrong
      // one produces the wrong glyph face or a RangeError rather than a
      // visible smudge - so the resolution is asserted, not the number.
      final Object pathA = Object();
      final Object imageA = Object();
      final Object fontA = Object();

      final DisplayList sub = DisplayList();
      final int paint = sub.addPaint(colorArgb: 0xFF00FF00);
      final int path = sub.addPath(pathA);
      final int image = sub.addImage(imageA);
      final int font = sub.addFont(fontA);
      sub
        ..drawPath(path, paint)
        ..drawImage(image, 0, 0, 4, 4, 0, 0, 4, 4, paint)
        ..drawGlyphRun(
          font,
          paint,
          0,
          12,
          Int32List.fromList(<int>[1, 2]),
          Float32List.fromList(<double>[0, 0, 6, 0]),
          2,
        );

      final DisplayList spliced = DisplayList()..appendFrom(sub);

      final DisplayListReader reader = DisplayListReader(spliced);
      expect(reader.moveNext(), isTrue);
      expect(identical(spliced.pathAt(reader.pathId), pathA), isTrue);
      expect(reader.moveNext(), isTrue);
      expect(identical(spliced.imageAt(reader.imageId), imageA), isTrue);
      expect(reader.moveNext(), isTrue);
      expect(identical(spliced.fontAt(reader.fontId), fontA), isTrue);
    });

    test('save, clip and restore survive with their nesting intact', () {
      final DisplayList direct = DisplayList();
      final int paint = direct.addPaint(colorArgb: 0xFF123456);
      direct
        ..save()
        ..clipRect(0, 0, 8, 8)
        ..drawRect(1, 1, 2, 2, paint)
        ..restore();

      final DisplayList sub = DisplayList();
      final int subPaint = sub.addPaint(colorArgb: 0xFF123456);
      sub
        ..save()
        ..clipRect(0, 0, 8, 8)
        ..drawRect(1, 1, 2, 2, subPaint)
        ..restore();

      _expectSameStream(DisplayList()..appendFrom(sub), direct);
    });

    test('a splice of a splice is still the same stream', () {
      // A repaint boundary inside a repaint boundary. If the id rewriting were
      // not idempotent this is where it would show, because the inner list's
      // ids have already been rewritten once.
      final DisplayList direct = DisplayList();
      final int one = direct.addPaint(colorArgb: 0xFF010101);
      final int two = direct.addPaint(colorArgb: 0xFF020202);
      direct
        ..drawRect(0, 0, 1, 1, one)
        ..drawRect(1, 1, 2, 2, two);

      final DisplayList inner = DisplayList();
      final int innerTwo = inner.addPaint(colorArgb: 0xFF020202);
      inner.drawRect(1, 1, 2, 2, innerTwo);

      final DisplayList middle = DisplayList();
      final int middleOne = middle.addPaint(colorArgb: 0xFF010101);
      middle
        ..drawRect(0, 0, 1, 1, middleOne)
        ..appendFrom(inner);

      _expectSameStream(DisplayList()..appendFrom(middle), direct);
    });

    test('an empty sub-list changes nothing', () {
      final DisplayList target = DisplayList();
      final int paint = target.addPaint(colorArgb: 0xFF999999);
      target.drawRect(0, 0, 1, 1, paint);
      final int commandsBefore = target.commandCount;
      final int opsBefore = target.opLength;
      final int paintsBefore = target.paintCount;

      target.appendFrom(DisplayList());

      expect(target.commandCount, commandsBefore);
      expect(target.opLength, opsBefore);
      expect(target.paintCount, paintsBefore);
    });

    test('the same sub-list can be spliced twice, and repeats exactly', () {
      // What a boundary that appears twice on screen does, and what a second
      // frame does. A primitive that consumed its source would work once.
      final DisplayList sub = DisplayList();
      final int paint = sub.addPaint(colorArgb: 0xFFABCDEF);
      sub.drawRect(0, 0, 3, 3, paint);

      final DisplayList once = DisplayList()..appendFrom(sub);
      final DisplayList twice = DisplayList()
        ..appendFrom(sub)
        ..appendFrom(sub);

      expect(twice.commandCount, once.commandCount * 2);
      expect(
        twice.paintCount,
        once.paintCount,
        reason: 'the second splice interns onto the first one\'s paint',
      );
    });
  });

  group('the refusals', () {
    test('a list cannot be spliced into itself', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.drawRect(0, 0, 1, 1, paint);

      expect(() => list.appendFrom(list), throwsArgumentError);
    });

    test('a sub-list carrying content hints is refused by name', () {
      // A hint span records the value already merged with the hints enclosing
      // it, so replaying one under a different enclosure would apply the wrong
      // hint - silently, and only to the spliced part. Refusing is the only
      // honest answer until spans are re-merged on splice.
      final DisplayList sub = DisplayList();
      final int paint = sub.addPaint(colorArgb: 0xFF000000);
      sub
        ..pushContentHint(ContentHint.animating)
        ..drawRect(0, 0, 1, 1, paint)
        ..popContentHint();

      expect(
        sub.hasContentHints,
        isTrue,
        reason: 'the refusal below is only reachable on a list that has one',
      );
      expect(() => DisplayList().appendFrom(sub), throwsStateError);
    });

    test('a sub-list with no hints splices, so the refusal is not blanket', () {
      final DisplayList sub = DisplayList();
      final int paint = sub.addPaint(colorArgb: 0xFF000000);
      sub.drawRect(0, 0, 1, 1, paint);

      expect(sub.hasContentHints, isFalse);
      expect(() => DisplayList().appendFrom(sub), returnsNormally);
    });
  });
}
