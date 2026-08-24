/// The hint value, and the side table it rides in.
///
/// The load-bearing assertion in this file is the parity one: a display list
/// encoded with hints has to be word-for-word the list encoded without them.
/// Everything else here - packing, inheritance, coalescing - exists to make
/// that mechanism trustworthy, but the parity test is the contract.
library;

import 'package:dart_ui/src/graphics/content_hint.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:test/test.dart';

void main() {
  group('ContentHint', () {
    test('packs and unpacks every legal combination without allocating', () {
      for (final ContentMotionHint motion in ContentMotionHint.values) {
        for (final RenderQualityHint quality in RenderQualityHint.values) {
          final ContentHint hint =
              ContentHint(motion: motion, quality: quality);
          final ContentHint round = ContentHint.unpack(hint.packed);
          expect(round, hint);
          expect(
            identical(round, ContentHint.unpack(hint.packed)),
            isTrue,
            reason: 'unpack must answer from the constant table, so a frame '
                'that changes hint per command allocates nothing',
          );
        }
      }
    });

    test('rejects a packed value that is not a hint', () {
      expect(() => ContentHint.unpack(-1), throwsRangeError);
      expect(
        () => ContentHint.unpack(
          ContentMotionHint.values.length * RenderQualityHint.values.length,
        ),
        throwsRangeError,
      );
    });

    test('inheritance is per field, not per object', () {
      const ContentHint outer = ContentHint(
        motion: ContentMotionHint.transforming,
        quality: RenderQualityHint.preferQuality,
      );
      const ContentHint inner =
          ContentHint(quality: RenderQualityHint.preferSpeed);

      final ContentHint resolved = inner.inheritFrom(outer);
      expect(resolved.motion, ContentMotionHint.transforming,
          reason: 'the inner hint said nothing about motion');
      expect(resolved.quality, RenderQualityHint.preferSpeed,
          reason: 'the inner hint overrides where it does speak');
    });

    test('an inner hint overrides the field it declares', () {
      final ContentHint resolved =
          ContentHint.animating.inheritFrom(ContentHint.staticContent);
      expect(resolved.motion, ContentMotionHint.animating);
    });

    test('none is the identity of inheritance in both directions', () {
      expect(ContentHint.none.inheritFrom(ContentHint.staticContent),
          ContentHint.staticContent);
      expect(ContentHint.staticContent.inheritFrom(ContentHint.none),
          ContentHint.staticContent);
      expect(ContentHint.none.isEmpty, isTrue);
      expect(ContentHint.staticContent.isEmpty, isFalse);
    });
  });

  group('the hint side table', () {
    test('a hinted list encodes exactly the bytes an unhinted one does', () {
      final DisplayList hinted = DisplayList();
      hinted.pushContentHint(ContentHint.animating);
      _drawScene(hinted);
      hinted.popContentHint();

      final DisplayList plain = DisplayList();
      _drawScene(plain);

      expect(hinted.opLength, plain.opLength);
      expect(hinted.floatLength, plain.floatLength);
      expect(hinted.commandCount, plain.commandCount);
      expect(hinted.paintCount, plain.paintCount);
      for (var i = 0; i < plain.opLength; i++) {
        expect(hinted.opBuffer[i], plain.opBuffer[i], reason: 'op word $i');
      }
      for (var i = 0; i < plain.floatLength; i++) {
        expect(hinted.floatBuffer[i], plain.floatBuffer[i],
            reason: 'float slot $i');
      }

      expect(hinted.hasContentHints, isTrue);
      expect(plain.hasContentHints, isFalse,
          reason: 'a list nobody hinted must pay nothing at all');
    });

    test('a span covers the commands encoded inside it', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.drawRect(0, 0, 1, 1, paint); // outside
      list.pushContentHint(ContentHint.staticContent);
      final int inside = list.opLength;
      list.drawRect(1, 1, 2, 2, paint); // inside
      list.popContentHint();
      final int after = list.opLength;
      list.drawRect(2, 2, 3, 3, paint); // outside

      final ContentHintSpans spans = list.contentHints;
      expect(spans.spanCount, 2);
      expect(spans.spanStart(0), inside);
      expect(spans.spanHint(0), ContentHint.staticContent);
      expect(spans.spanStart(1), after);
      expect(spans.spanHint(1), ContentHint.none);
    });

    test('a pair that encloses no command leaves no trace', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.drawRect(0, 0, 1, 1, paint);
      list.pushContentHint(ContentHint.animating);
      list.popContentHint();
      list.drawRect(1, 1, 2, 2, paint);

      expect(list.hasContentHints, isFalse);
      expect(list.contentHints.spanCount, 0);
    });

    test('nested hints merge per field and restore the outer one', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.pushContentHint(ContentHint.transforming);
      list.drawRect(0, 0, 1, 1, paint);
      list.pushContentHint(
        const ContentHint(quality: RenderQualityHint.preferSpeed),
      );
      list.drawRect(1, 1, 2, 2, paint);
      list.popContentHint();
      list.drawRect(2, 2, 3, 3, paint);
      list.popContentHint();

      final ContentHintSpans spans = list.contentHints;
      expect(spans.spanCount, 4);
      expect(spans.spanHint(0), ContentHint.transforming);
      expect(
        spans.spanHint(1),
        const ContentHint(
          motion: ContentMotionHint.transforming,
          quality: RenderQualityHint.preferSpeed,
        ),
        reason: 'the inner hint inherits the motion it did not declare',
      );
      expect(spans.spanHint(2), ContentHint.transforming);
      expect(spans.spanHint(3), ContentHint.none);
    });

    test('reset clears the table and the open depth', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.pushContentHint(ContentHint.staticContent);
      list.drawRect(0, 0, 1, 1, paint);
      expect(list.contentHintDepth, 1);

      list.reset();

      expect(list.hasContentHints, isFalse);
      expect(list.contentHintDepth, 0);
      expect(list.contentHints.spanCount, 0);
    });

    test('an unbalanced pop fails loudly rather than advising the frame', () {
      final DisplayList list = DisplayList();
      expect(list.popContentHint, throwsStateError);
    });

    test('span indices out of range are refused', () {
      final DisplayList list = DisplayList();
      expect(() => list.contentHints.spanStart(0), throwsRangeError);
      expect(() => ContentHintSpans.empty.spanHint(0), throwsRangeError);
    });
  });
}

/// A few commands of every shape the encoder writes differently, so the parity
/// assertion is over a real stream and not over one rectangle.
void _drawScene(DisplayList list) {
  final int fill = list.addPaint(colorArgb: 0xFF102030);
  final int stroke = list.addPaint(colorArgb: 0xFF405060, strokeWidth: 2);
  list.save();
  list.transform(1, 0, 0, 1, 3, 4);
  list.clipRect(0, 0, 40, 40);
  list.drawRect(1, 2, 10, 12, fill);
  list.drawRRect(2, 3, 20, 22, 4, 4, 4, 4, 4, 4, 4, 4, stroke);
  list.restore();
}
