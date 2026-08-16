/// What the widget layer is promised about getting a face - and a second face.
///
/// Two of these tests are about a machine this suite will never run on: one
/// with no font at all, and one whose first candidate is a file the parser
/// refuses. Both are the reason the registry exists rather than a call to
/// `Typeface.parse` at each call site, and both would otherwise only ever be
/// exercised by a user.
///
/// The fallback tests run against an **injected index built from
/// `test/fonts/`**, which is what makes a chain that is inherently about "what
/// is installed" deterministic. The three fixtures happen to disagree with each
/// other in exactly the ways that matter: Roboto has no Arabic, DejaVu has
/// Arabic and claims a Thai coverage bit it cannot honour, and Ahem claims
/// Greek and has none. Two machine-dependent tests are kept beside them,
/// guarded with a skip, because no fixture can prove that a CJK ideograph is
/// resolvable from a Latin interface font on a real desktop.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// The fixture every deterministic test in this repository draws with. A face
/// from `test/fonts/` and never one from the machine: a metric asserted against
/// whatever font happens to be installed is an assertion about the developer's
/// laptop.
const String _robotoPath = 'test/fonts/Roboto-Regular.ttf';
const String _dejaVuPath = 'test/fonts/DejaVuSans.ttf';
const String _ahemPath = 'test/fonts/ahem.ttf';

Typeface _roboto() => Typeface.parse(File(_robotoPath).readAsBytesSync());

Typeface _dejaVu() => Typeface.parse(File(_dejaVuPath).readAsBytesSync());

Typeface _ahem() => Typeface.parse(File(_ahemPath).readAsBytesSync());

/// An index over the three fixtures, as if they were the machine's fonts.
///
/// [onRead] counts file opens, which is how the caching claims below are
/// proved rather than asserted.
SystemFontIndex _fixtureIndex({void Function(SystemFontFile)? onRead}) =>
    SystemFontIndex.build(
      files: const <SystemFontFile>[
        SystemFontFile(path: _robotoPath, fileName: 'Roboto-Regular.ttf'),
        SystemFontFile(path: _dejaVuPath, fileName: 'DejaVuSans.ttf'),
        SystemFontFile(path: _ahemPath, fileName: 'ahem.ttf'),
      ],
      reader: (SystemFontFile file) {
        onRead?.call(file);
        return readSystemFontFaces(file);
      },
    );

/// A registry that can only see the fixtures, with Roboto as its interface
/// face.
FontRegistry _fixtureRegistry() {
  final FontRegistry registry = FontRegistry(
    search: () => null,
    index: _fixtureIndex(),
  );
  registry.useTypeface(_roboto(), source: _robotoPath);
  return registry;
}

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

  group('choosing a face by family', () {
    test('a family is resolved by name, and a missing one is null', () {
      final FontRegistry registry = _fixtureRegistry();

      expect(registry.faceFor('DejaVu Sans')!.familyName, 'DejaVu Sans');
      expect(registry.faceFor('dejavu sans')!.familyName, 'DejaVu Sans');
      // Not "here is Roboto instead": a silent substitution is exactly what
      // section 6.6 forbids, and the caller is the one that knows whether a
      // different family is acceptable.
      expect(registry.faceFor('Helvetica Neue'), isNull);
    });

    test('a registered face is preferred over the machine index', () {
      final FontRegistry registry = FontRegistry(
        search: () => null,
        index: _fixtureIndex(),
      );
      final Typeface shipped = _dejaVu();
      registry.registerTypeface(shipped, family: 'Application Sans');

      expect(registry.faceFor('Application Sans'), same(shipped));
      expect(registry.registeredFaces.single.family, 'Application Sans');
      // Registering the same face twice does not duplicate it.
      registry.registerTypeface(shipped, family: 'Application Sans');
      expect(registry.registeredFaces, hasLength(1));
    });
  });

  group('the fallback chain', () {
    test('a face that already has the character is the answer, for free', () {
      final FontRegistry registry = _fixtureRegistry();

      final FallbackResolution latin = registry.resolveCodePoint(0x41);
      expect(latin.face!.familyName, 'Roboto');
      expect(latin.step, FontFallbackStep.requested);
      expect(latin.facesExamined, 0);
      expect(latin.glyph, isNot(0));
      // The common case must not open a single file.
      expect(registry.facesOpened, 0);
    });

    test('Arabic falls out of a Latin face and into one that has it', () {
      final FontRegistry registry = _fixtureRegistry();

      // U+0645 ARABIC LETTER MEEM. Roboto has no Arabic at all; DejaVu does,
      // and declares the Arabic bit, so the coverage filter reaches it first.
      final FallbackResolution arabic =
          registry.resolveCodePoint(0x0645, script: Script.arab);

      expect(arabic.found, isTrue);
      expect(arabic.face!.familyName, 'DejaVu Sans');
      expect(arabic.face!.glyphForCodePoint(0x0645), arabic.glyph);
      expect(arabic.step, FontFallbackStep.coverageScan);
    });

    test('the coverage bit orders the search and the cmap decides it', () {
      // Ahem claims the Greek bit (7) and has no Greek glyph; DejaVu also
      // claims it and does. Starting from Ahem, the chain must not stop at the
      // face whose OS/2 said yes - the cmap is what answers.
      final FontRegistry registry = FontRegistry(
        search: () => null,
        index: _fixtureIndex(),
      );
      final Typeface ahem = _ahem();
      expect(ahem.declaresCodePoint(0x03B1), isTrue);
      expect(ahem.coversCodePoint(0x03B1), isFalse);

      final FallbackResolution greek =
          registry.resolveCodePoint(0x03B1, from: ahem);

      expect(greek.found, isTrue);
      expect(greek.face!.coversCodePoint(0x03B1), isTrue);
      expect(greek.face!.familyName, isNot('Ahem'));
    });

    test('a character no installed face has resolves to nothing, and says so',
        () {
      final FontRegistry registry = _fixtureRegistry();

      // U+0E01 THAI CHARACTER KO KHAI. DejaVu *claims* the Thai bit, so it is
      // opened and rejected; nothing else in the index has Thai either.
      final FallbackResolution thai = registry.resolveCodePoint(0x0E01);

      expect(thai.found, isFalse);
      expect(thai.glyph, 0);
      expect(thai.step, FontFallbackStep.none);
      expect(thai.facesExamined, greaterThan(0),
          reason: 'the claiming face was tried before being disbelieved');
    });

    test('the decision is cached per script and code point', () {
      final FontRegistry registry = _fixtureRegistry();

      final FallbackResolution first =
          registry.resolveCodePoint(0x0645, script: Script.arab);
      final int opensAfterFirst = registry.facesOpened;
      expect(opensAfterFirst, greaterThan(0), reason: 'the search read a file');

      for (int i = 0; i < 200; i++) {
        final FallbackResolution again =
            registry.resolveCodePoint(0x0645, script: Script.arab);
        expect(identical(again.face, first.face), isTrue);
      }

      // A paragraph of Arabic asks per character. Without the cache each of
      // those characters would re-scan the index and re-open the files.
      expect(registry.facesOpened, opensAfterFirst);
      expect(registry.fallbackCacheStats.queries, 201);
      expect(registry.fallbackCacheStats.searches, 1);
    });

    test('an opened face is parsed once, however often it is asked for', () {
      final FontRegistry registry = _fixtureRegistry();

      // Two different Arabic letters, two different scripts, one file.
      registry.resolveCodePoint(0x0645, script: Script.arab);
      registry.resolveCodePoint(0x0627, script: Script.arab);
      registry.resolveCodePoint(0x05D0, script: Script.hebr);

      expect(registry.facesOpened, 1);
    });

    test('the index itself is read once per file, counted', () {
      final List<String> reads = <String>[];
      final SystemFontIndex index = _fixtureIndex(
        onRead: (SystemFontFile file) => reads.add(file.fileName),
      );

      expect(reads, hasLength(3));
      expect(index.faceCount, 3);
      expect(index.filesRefused, 0);
      // Building the index reads name/OS/2 and nothing else; the outlines -
      // which are all of the file size - are read only for a chosen face.
      expect(index.facesFor('DejaVu Sans'), hasLength(1));
    });

    test('registering a face invalidates the decisions taken without it', () {
      final FontRegistry registry = FontRegistry(
        search: () => null,
        index: SystemFontIndex.empty,
      );
      registry.useTypeface(_roboto(), source: _robotoPath);

      expect(registry.resolveCodePoint(0x0645).found, isFalse);
      registry.registerTypeface(_dejaVu());
      // The answer changed because the world did; a cache that outlived the
      // change would keep reporting "no Arabic on this machine".
      final FallbackResolution after = registry.resolveCodePoint(0x0645);
      expect(after.found, isTrue);
      expect(after.face!.familyName, 'DejaVu Sans');
    });

    test('a CJK ideograph resolves from a Latin face on a real desktop', () {
      final FontRegistry registry = FontRegistry(search: () => null)
        ..useTypeface(_roboto(), source: _robotoPath);
      if (registry.systemFonts.isEmpty) {
        markTestSkipped('no readable font on this machine');
        return;
      }

      // U+6F22, the "kan" of kanji. Roboto has no Han whatsoever, so this can
      // only be answered by the machine - which is the point: the chain is what
      // makes a Japanese label render in a Latin interface.
      final FallbackResolution han =
          registry.resolveCodePoint(0x6F22, script: Script.hani);
      if (!han.found) {
        markTestSkipped('this machine has no font with Han ideographs');
        return;
      }

      expect(han.face!.coversCodePoint(0x6F22), isTrue);
      expect(han.face!.familyName, isNotNull);
      expect(
        han.step,
        anyOf(
          FontFallbackStep.scriptPreference,
          FontFallbackStep.coverageScan,
        ),
      );
      // Whatever it found, it is not the face we started with.
      expect(han.face!.familyName, isNot('Roboto'));
    });

    test('a machine with no fonts at all answers nothing rather than throwing',
        () {
      final FontRegistry registry = FontRegistry(
        search: () => null,
        index: SystemFontIndex.empty,
      );

      final FallbackResolution nothing = registry.resolveCodePoint(0x0645);
      expect(nothing.found, isFalse);
      expect(nothing.step, FontFallbackStep.none);
      expect(nothing.facesExamined, 0);
    });
  });

  group('emoji', () {
    test('a face that covers the character is found, and its limits reported',
        () {
      final FontRegistry registry = _fixtureRegistry();

      // U+1F600 has no OS/2 coverage bit at all - the bit table stopped
      // tracking Unicode in 2008 - and DejaVu draws it anyway. A chain that
      // used the bit to *exclude* faces would report no emoji font here.
      final EmojiResolution grin = registry.resolveEmoji('\u{1F600}');

      expect(grin.found, isTrue);
      expect(grin.face!.familyName, 'DejaVu Sans');
      expect(grin.presentation, EmojiPresentation.unspecified);
      expect(grin.isZwjSequence, isFalse);
      expect(grin.drawable, isTrue);
      expect(grin.colourTable, isNull);
      expect(grin.limitation, isNull);
    });

    test('a presentation nobody declares is reported, not silently dropped',
        () {
      final FontRegistry registry = _fixtureRegistry();

      // U+263A U+FE0F asks for the colour presentation. None of the fixtures
      // carries cmap format 14, so the base glyph is used - and the caller is
      // told that the selector could not be honoured rather than being left to
      // wonder why the smiley is monochrome.
      final EmojiResolution emoji = registry.resolveEmoji('☺️');

      expect(emoji.found, isTrue);
      expect(emoji.presentation, EmojiPresentation.emoji);
      expect(emoji.limitation, contains('cmap format 14'));

      final EmojiResolution text = registry.resolveEmoji('☺︎');
      expect(text.presentation, EmojiPresentation.text);
      expect(text.limitation, contains('text'));
    });

    test('a ZWJ sequence is reported whole, or its split is named', () {
      final FontRegistry registry = _fixtureRegistry();

      // Both halves in one face: the sequence can at least be handed to a
      // shaper as one run.
      final EmojiResolution joined = registry.resolveEmoji('☺‍❤');
      expect(joined.isZwjSequence, isTrue);
      expect(joined.face!.familyName, 'DejaVu Sans');
      expect(joined.limitation, isNull);

      // U+1F44D is in no fixture, so the sequence cannot be drawn by one face
      // and the answer says which character caused it.
      final EmojiResolution split = registry.resolveEmoji('☺‍\u{1F44D}');
      expect(split.isZwjSequence, isTrue);
      expect(split.limitation, contains('1F44D'));
      expect(split.limitation, contains('separate parts'));
    });

    test('a cluster of only joiners has nothing to draw and says so', () {
      final FontRegistry registry = _fixtureRegistry();

      final EmojiResolution empty = registry.resolveEmoji('‍️');
      expect(empty.found, isFalse);
      expect(empty.limitation, contains('no character to draw'));
    });

    test('a colour emoji font is used for its outlines, and the gap declared',
        () {
      final FontRegistry registry = FontRegistry(search: () => null)
        ..useTypeface(_roboto(), source: _robotoPath);
      if (registry.systemFonts.isEmpty) {
        markTestSkipped('no readable font on this machine');
        return;
      }

      final EmojiResolution grin = registry.resolveEmoji('\u{1F600}');
      if (!grin.found || grin.colourTable == null) {
        markTestSkipped('no colour emoji font on this machine');
        return;
      }

      // COLR, CBDT and sbix are all unimplemented. The engine draws the base
      // outlines and *says* that is what it is doing: a user who reports "my
      // emoji are grey" must be able to find the sentence that predicted it.
      expect(
        grin.colourTable,
        anyOf(<String>['COLR', 'CBDT', 'sbix', 'SVG ']),
      );
      expect(grin.limitation, contains('does not implement'));
      expect(grin.limitation, contains(grin.colourTable!));
    });

    test('a variation selector a real font declares is honoured', () {
      final FontRegistry registry = FontRegistry(search: () => null)
        ..useTypeface(_roboto(), source: _robotoPath);
      if (registry.systemFonts.isEmpty) {
        markTestSkipped('no readable font on this machine');
        return;
      }

      // U+263A U+FE0F. A colour emoji face declares this pair in cmap format
      // 14, which is how the emoji presentation is selected at all.
      final EmojiResolution emoji = registry.resolveEmoji('☺️');
      if (!emoji.found ||
          emoji.face!.glyphForVariation(0x263A, 0xFE0F) == null) {
        markTestSkipped('no face declaring an emoji presentation for U+263A');
        return;
      }

      expect(emoji.presentation, EmojiPresentation.emoji);
      expect(emoji.glyph, emoji.face!.glyphForVariation(0x263A, 0xFE0F));
      expect(emoji.limitation ?? '', isNot(contains('cmap format 14')));
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
