/// Baseline queries and baseline alignment in a row.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  T laidOut<T extends RenderBox>(T node, BoxConstraints constraints) {
    final owner = PipelineOwner(rootConstraints: constraints)..root = node;
    owner.flushLayout();
    return node;
  }

  group('the query', () {
    test('a node with no text falls back to its bottom edge', () {
      final box = laidOut(
        MeasuredBox(const Size(20, 30)),
        BoxConstraints.tight(const Size(20, 30)),
      );

      expect(box.getDistanceToBaseline(TextBaseline.alphabetic), 30);
      expect(
        box.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true),
        isNull,
      );
    });

    test('a padded child\'s baseline is lower by the top inset', () {
      final padding = laidOut(
        RenderPadding(
          padding: const EdgeInsets(4, 7, 4, 2),
          child: BaselineBox(const Size(20, 30), 24),
        ),
        BoxConstraints.loose(const Size(200, 200)),
      );

      expect(
        padding.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true),
        31,
      );
    });

    test('a row reports the highest baseline among its children', () {
      final row = RenderFlex()
        ..add(BaselineBox(const Size(20, 40), 30))
        ..add(BaselineBox(const Size(20, 20), 16));
      laidOut(row, BoxConstraints.loose(const Size(200, 200)));

      // Both children sit at dy 0 under the default start alignment, so the
      // highest baseline in the row's own space is the smaller of the two.
      expect(
        row.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true),
        16,
      );
    });

    test('a column reports its first child\'s baseline', () {
      final column = RenderFlex(direction: Axis.vertical)
        ..add(BaselineBox(const Size(20, 40), 30))
        ..add(BaselineBox(const Size(20, 20), 16));
      laidOut(column, BoxConstraints.loose(const Size(200, 200)));

      expect(
        column.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true),
        30,
      );
    });

    test('asking before layout is an error, not a zero', () {
      expect(
        () => BaselineBox(const Size(20, 30), 24)
            .getDistanceToBaseline(TextBaseline.alphabetic),
        throwsStateError,
      );
    });
  });

  group('CrossAxisAlignment.baseline', () {
    test('puts two differently sized children on one line', () {
      // A 30-tall box whose baseline is 24 down, next to an 18-tall one whose
      // baseline is 14 down. The deeper baseline wins the line, so the shorter
      // child drops by the difference.
      final tall = BaselineBox(const Size(20, 30), 24);
      final short = BaselineBox(const Size(20, 18), 14);
      final row = RenderFlex(crossAxisAlignment: CrossAxisAlignment.baseline)
        ..add(tall)
        ..add(short);

      laidOut(row, BoxConstraints.loose(const Size(200, 200)));

      expect(tall.offsetFromParent.dy, 0);
      expect(short.offsetFromParent.dy, 10);
      // 24 above the line, and the deepest descent below it is the tall one's
      // 6, so the row needs 30.
      expect(row.size.height, 30);
      // The whole point, stated as one equation.
      expect(
        tall.offsetFromParent.dy + 24,
        short.offsetFromParent.dy + 14,
      );
    });

    test('grows past every child when ascender and descender are split', () {
      // Nobody is 34 tall, but the line needs 26 above and 8 below.
      final ascender = BaselineBox(const Size(20, 28), 26);
      final descender = BaselineBox(const Size(20, 20), 12);
      final row = RenderFlex(crossAxisAlignment: CrossAxisAlignment.baseline)
        ..add(ascender)
        ..add(descender);

      laidOut(row, BoxConstraints.loose(const Size(200, 200)));

      expect(ascender.offsetFromParent.dy, 0);
      expect(descender.offsetFromParent.dy, 14);
      expect(row.size.height, 34);
    });

    test('a child with no real baseline goes to the leading edge', () {
      final text = BaselineBox(const Size(20, 30), 24);
      final box = MeasuredBox(const Size(20, 40));
      final row = RenderFlex(crossAxisAlignment: CrossAxisAlignment.baseline)
        ..add(text)
        ..add(box);

      laidOut(row, BoxConstraints.loose(const Size(200, 200)));

      expect(text.offsetFromParent.dy, 0);
      expect(box.offsetFromParent.dy, 0);
      // The 40-tall box still decides the row's height; it just does not drag
      // the baseline down to 40.
      expect(row.size.height, 40);
    });

    test('is refused on a column', () {
      final column = RenderFlex(
        direction: Axis.vertical,
        crossAxisAlignment: CrossAxisAlignment.baseline,
      )..add(BaselineBox(const Size(20, 30), 24));

      expect(
        () => laidOut(column, BoxConstraints.loose(const Size(200, 200))),
        throwsStateError,
      );
    });

    test('switching the alignment re-lays the row out', () {
      final tall = BaselineBox(const Size(20, 30), 24);
      final short = BaselineBox(const Size(20, 18), 14);
      final row = RenderFlex()
        ..add(tall)
        ..add(short);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(200, 200)),
      )..root = row;
      owner.flushLayout();

      expect(short.offsetFromParent.dy, 0);

      row.crossAxisAlignment = CrossAxisAlignment.baseline;
      owner.flushLayout();

      expect(short.offsetFromParent.dy, 10);
    });
  });

  group('real text', () {
    test('two sizes of the same face share a line', () {
      final big = RenderText('Hg', fontSize: 24);
      final small = RenderText('Hg', fontSize: 12);
      final row = RenderFlex(crossAxisAlignment: CrossAxisAlignment.baseline)
        ..add(big)
        ..add(small);

      laidOut(row, BoxConstraints.loose(const Size(400, 200)));

      final double bigBaseline =
          big.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true)!;
      final double smallBaseline =
          small.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true)!;

      expect(bigBaseline, greaterThan(smallBaseline));
      expect(big.offsetFromParent.dy, 0);
      // The smaller line is pushed down by exactly the ascent difference.
      expect(small.offsetFromParent.dy, bigBaseline - smallBaseline);
      expect(
        big.offsetFromParent.dy + bigBaseline,
        small.offsetFromParent.dy + smallBaseline,
      );
    });

    test('the baseline a row aligns to is the one paint draws at', () {
      final text = laidOut(
        RenderText('Hg', fontSize: 20),
        BoxConstraints.loose(const Size(400, 200)),
      );
      final ScaledTypeface? face = text.font;
      if (face == null) return; // No system font: nothing to compare against.

      expect(
        text.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true),
        face.ascent,
      );
    });
  });
}
