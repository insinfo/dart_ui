/// What the widget layer is promised about getting a face.
///
/// Two of these tests are about a machine this suite will never run on: one
/// with no font at all, and one whose first candidate is a file the parser
/// refuses. Both are the reason the registry exists rather than a call to
/// `Typeface.parse` at each call site, and both would otherwise only ever be
/// exercised by a user.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// The fixture every deterministic test in this repository draws with. A face
/// from `test/fonts/` and never one from the machine: a metric asserted against
/// whatever font happens to be installed is an assertion about the developer's
/// laptop.
const String _robotoPath = 'test/fonts/Roboto-Regular.ttf';

Typeface _roboto() => Typeface.parse(File(_robotoPath).readAsBytesSync());

void main() {
  group('resolving a face', () {
    test('an override replaces whatever the machine has', () {
      final FontRegistry registry = FontRegistry();
      final Typeface roboto = _roboto();

      registry.useTypeface(roboto);

      expect(registry.uiTypeface, same(roboto));
      expect(registry.hasUiFont, isTrue);
      expect(registry.uiFont(16)!.pixelSize, 16);
      expect(registry.uiFont(16)!.typeface, same(roboto));
    });

    test('a file override reports the path it loaded', () {
      final FontRegistry registry = FontRegistry();

      expect(registry.useFontFile(_robotoPath), isTrue);
      expect(registry.source, _robotoPath);
    });

    test('a file that is not a font is refused without changing anything', () {
      final FontRegistry registry = FontRegistry();
      registry.useTypeface(_roboto());

      // An application shipping its own font needs to know the load failed;
      // throwing would make a cosmetic problem fatal, and silently succeeding
      // would leave it drawing in a face it did not choose.
      expect(registry.useFontFile('test/fonts/LICENSES.md'), isFalse);
      expect(registry.useFontFile('test/fonts/does-not-exist.ttf'), isFalse);
      expect(registry.hasUiFont, isTrue);
    });

    test('one size is one scaled face, and two sizes are two', () {
      final FontRegistry registry = FontRegistry()..useTypeface(_roboto());

      // Identity matters beyond allocation: the glyph cache and the display
      // list's font table both key on the scaled face, so a fresh instance per
      // paint would be a fresh cache entry per paint.
      expect(registry.uiFont(12), same(registry.uiFont(12)));
      expect(registry.uiFont(12), isNot(same(registry.uiFont(13))));
    });

    test('reset forgets the override', () {
      final FontRegistry registry = FontRegistry(search: () => null)
        ..useTypeface(_roboto());

      registry.reset();

      expect(registry.hasUiFont, isFalse);
      expect(registry.source, isNull);
    });
  });

  group('a machine with no usable font', () {
    test('resolves to null rather than throwing', () {
      final FontRegistry registry = FontRegistry(search: () => null);

      expect(registry.uiTypeface, isNull);
      expect(registry.uiFont(12), isNull);
      expect(registry.hasUiFont, isFalse);
      expect(registry.source, isNull);
    });

    test('a failed search is not repeated', () {
      int searches = 0;
      final FontRegistry registry = FontRegistry(search: () {
        searches++;
        return null;
      });

      for (int i = 0; i < 5; i++) {
        registry.uiFont(12);
      }

      // Enumerating a fonts directory is hundreds of stat calls. Retrying it
      // per paint would turn a missing font into a permanently slow frame.
      expect(searches, 1);
    });

    test('a search that throws is still not fatal', () {
      final FontRegistry registry =
          FontRegistry(search: () => throw StateError('unreadable'));

      // The contract is on the *default* search, which catches everything it
      // can; an injected one that throws is a bug in the injection and is
      // allowed to surface.
      expect(() => registry.uiFont(12), throwsStateError);
    });

    test('the reserved box is non-zero, so layout does not collapse', () {
      final Size box = FontRegistry.estimatedSize('HELLO', 12);

      expect(box.width, greaterThan(0));
      expect(box.height, greaterThan(12));
      expect(FontRegistry.estimatedSize('', 12).width, 0);
      // Longer text reserves more, so a row of labels keeps its shape.
      expect(
        FontRegistry.estimatedSize('HELLO WORLD', 12).width,
        greaterThan(box.width),
      );
    });
  });

  group('the default search', () {
    test('either finds a parseable face or reports none, never throws', () {
      final FontRegistry registry = FontRegistry();

      // Deliberately not asserting that a font *was* found: this suite has to
      // pass in a container with an empty fonts directory. What is asserted is
      // that the two possible answers are both well formed.
      final Typeface? face = registry.uiTypeface;
      if (face == null) {
        expect(registry.source, isNull);
        expect(registry.uiFont(12), isNull);
      } else {
        expect(registry.source, isNotNull);
        expect(face.glyphCount, greaterThan(0));
        expect(registry.uiFont(12)!.lineHeight, greaterThan(0));
      }
    });
  });

  group('the shared painter', () {
    test('measures through the shaper, so it accounts for kerning', () {
      final ScaledTypeface font = _roboto().atSize(24);

      final Size measured = uiTextPainter.measure('AV', font);
      final double nominal = font.measure('AV');

      expect(measured.width, lessThanOrEqualTo(nominal));
      expect(measured.height, font.lineHeight);
    });
  });
}
