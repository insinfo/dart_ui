import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('construction', () {
    test('tight admits exactly one size', () {
      final c = BoxConstraints.tight(const Size(120, 40));

      expect(c.isTight, isTrue);
      expect(c.constrain(const Size(999, 1)), const Size(120, 40));
      expect(c.smallest, const Size(120, 40));
      expect(c.biggest, const Size(120, 40));
    });

    test('loose keeps the maximum and drops the minimum', () {
      final c = BoxConstraints.loose(const Size(120, 40));

      expect(c.isTight, isFalse);
      expect(c.smallest, Size.zero);
      expect(c.constrain(const Size(500, 10)), const Size(120, 10));
    });

    test('expand is tight at infinity on an omitted axis', () {
      final c = BoxConstraints.expand(width: 30);

      expect(c.hasTightWidth, isTrue);
      expect(c.maxWidth, 30);
      expect(c.hasBoundedHeight, isFalse);
      expect(c.minHeight, double.infinity);
    });

    test('largestFinite falls back to the minimum on an unbounded axis', () {
      final c = BoxConstraints(minWidth: 5, maxHeight: 40);

      expect(c.hasBoundedWidth, isFalse);
      // Infinity is not a size anything can paint, so the unbounded axis
      // collapses to its minimum instead of propagating.
      expect(c.largestFinite, const Size(5, 40));
    });
  });

  group('a denormalised constraint is refused, by axis', () {
    test('names the width axis when minWidth exceeds maxWidth', () {
      expect(
        () => BoxConstraints(minWidth: 300, maxWidth: 200),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            allOf(
              contains('width'),
              contains('minWidth'),
              contains('maxWidth'),
              isNot(contains('height')),
            ),
          ),
        ),
      );
    });

    test('names the height axis when minHeight exceeds maxHeight', () {
      expect(
        () => BoxConstraints(minHeight: 10, maxHeight: 9),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            allOf(contains('height'), isNot(contains('width'))),
          ),
        ),
      );
    });

    test('refuses a negative minimum', () {
      expect(
        () => BoxConstraints(minWidth: -1),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            contains('negative width'),
          ),
        ),
      );
    });

    test('refuses NaN rather than letting it spread', () {
      expect(
        () => BoxConstraints(maxHeight: double.nan),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            allOf(contains('NaN'), contains('height')),
          ),
        ),
      );
    });

    test('a negative size cannot smuggle one in through tight', () {
      expect(
        () => BoxConstraints.tight(const Size(-4, 10)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('every constructed instance is normalised', () {
      expect(BoxConstraints.tight(const Size(3, 4)).isNormalized, isTrue);
      expect(BoxConstraints.loose(const Size(3, 4)).isNormalized, isTrue);
      expect(BoxConstraints.expand().isNormalized, isTrue);
    });
  });

  group('enforce', () {
    test('the outer range wins on both ends', () {
      final inner = BoxConstraints(minWidth: 400, maxWidth: 800);
      final outer = BoxConstraints(minWidth: 0, maxWidth: 200);

      final result = inner.enforce(outer);

      // A node asking for 400 inside a 200 parent gets 200, not an overflow
      // and not an exception.
      expect(result.minWidth, 200);
      expect(result.maxWidth, 200);
      expect(result.isNormalized, isTrue);
    });

    test('leaves a request that already fits alone', () {
      final inner = BoxConstraints(minWidth: 50, maxWidth: 100);
      final outer = BoxConstraints(maxWidth: 300);

      expect(inner.enforce(outer), inner);
    });

    test('never produces a denormalised result from disjoint ranges', () {
      final inner = BoxConstraints(minHeight: 500, maxHeight: 600);
      final outer = BoxConstraints(minHeight: 10, maxHeight: 20);

      final result = inner.enforce(outer);

      expect(result.minHeight, 20);
      expect(result.maxHeight, 20);
      expect(result.isNormalized, isTrue);
    });
  });

  group('deflate', () {
    test('removes the insets from both ends of both axes', () {
      final c = BoxConstraints(
        minWidth: 100,
        maxWidth: 200,
        minHeight: 50,
        maxHeight: 60,
      );

      final result = c.deflate(const EdgeInsets(4, 2, 6, 8));

      expect(result.minWidth, 90);
      expect(result.maxWidth, 190);
      expect(result.minHeight, 40);
      expect(result.maxHeight, 50);
    });

    test('clamps at zero instead of throwing when padding exceeds the box', () {
      final c = BoxConstraints.tight(const Size(10, 10));

      // Not a programming error: a window that shrank is exactly this. The
      // child gets nothing, and the result is still satisfiable.
      final result = c.deflate(const EdgeInsets.all(30));

      expect(result.minWidth, 0);
      expect(result.maxWidth, 0);
      expect(result.isNormalized, isTrue);
    });

    test('an unbounded axis stays unbounded', () {
      final result =
          BoxConstraints().deflate(const EdgeInsets.symmetric(horizontal: 8));

      expect(result.hasBoundedWidth, isFalse);
    });
  });

  group('miscellaneous arithmetic', () {
    test('loosen keeps the maxima and drops the minima', () {
      final result = BoxConstraints.tight(const Size(30, 40)).loosen();

      expect(result.minWidth, 0);
      expect(result.maxWidth, 30);
      expect(result.minHeight, 0);
      expect(result.maxHeight, 40);
    });

    test('tighten stays inside the existing range', () {
      final c = BoxConstraints(maxWidth: 100);

      expect(c.tighten(width: 400).maxWidth, 100);
      expect(c.tighten(width: 40).isTight, isFalse);
      expect(c.tighten(width: 40).hasTightWidth, isTrue);
    });

    test('isSatisfiedBy is what catches a node ignoring its constraints', () {
      final c = BoxConstraints.tight(const Size(10, 10));

      expect(c.isSatisfiedBy(const Size(10, 10)), isTrue);
      expect(c.isSatisfiedBy(const Size(10, 11)), isFalse);
    });

    test('equality is by value, since layout caches on it', () {
      expect(
        BoxConstraints.tight(const Size(10, 20)),
        BoxConstraints(
          minWidth: 10,
          maxWidth: 10,
          minHeight: 20,
          maxHeight: 20,
        ),
      );
      expect(
        BoxConstraints.tight(const Size(10, 20)).hashCode,
        BoxConstraints.tight(const Size(10, 20)).hashCode,
      );
      expect(
        BoxConstraints.tight(const Size(10, 20)) ==
            BoxConstraints.tight(const Size(10, 21)),
        isFalse,
      );
    });
  });
}
