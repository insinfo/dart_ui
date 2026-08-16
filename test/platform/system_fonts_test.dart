/// Finding a font by the name it calls itself, and picking the right face.
///
/// Two halves, and they are tested very differently on purpose:
///
///   * the **matching rule** is arithmetic over plain values, so it is tested
///     against hand-built faces. Every regime of the CSS weight search has a
///     case here, including the counter-intuitive 400-to-500 one, because the
///     rule is easy to implement plausibly and wrongly and nothing about a real
///     font would reveal the difference;
///   * the **index** is tested against the machine's own fonts, guarded with a
///     skip. There is no way to prove "Segoe UI is found by its family name and
///     not by its file name" without a family whose files are named nothing
///     like it - and `seguisb.ttf` is exactly that.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A face with only the axes the matcher looks at filled in.
SystemFontFace _face({
  String family = 'Test',
  int weight = 400,
  int width = 5,
  bool italic = false,
  bool oblique = false,
  bool declaresStyle = true,
  String? subfamily,
  String? legacyFamily,
  UnicodeCoverage coverage = UnicodeCoverage.none,
  String? path,
}) =>
    SystemFontFace(
      path: path ?? '$family-$weight-$width-$italic-$oblique.ttf',
      faceIndex: 0,
      family: family,
      legacyFamily: legacyFamily,
      subfamily: subfamily,
      weight: weight,
      width: width,
      italic: italic,
      oblique: oblique,
      declaresStyle: declaresStyle,
      coverage: coverage,
    );

/// The machine's index, built once for this file. Null when the machine has no
/// readable font, which is what a CI container looks like.
SystemFontIndex? _machineIndex;
bool _machineIndexBuilt = false;

SystemFontIndex? machineIndex() {
  if (_machineIndexBuilt) return _machineIndex;
  _machineIndexBuilt = true;
  final SystemFontIndex index = SystemFonts.cachedIndex(
    reader: readSystemFontFaces,
  );
  _machineIndex = index.isEmpty ? null : index;
  return _machineIndex;
}

void main() {
  group('the CSS weight search', () {
    test('an exact weight always wins, in every regime', () {
      for (final int wanted in <int>[100, 300, 400, 500, 700, 900]) {
        final List<SystemFontFace> family = <SystemFontFace>[
          _face(weight: 100),
          _face(weight: 300),
          _face(weight: 400),
          _face(weight: 500),
          _face(weight: 700),
          _face(weight: 900),
        ];
        final FaceMatch match =
            SystemFontIndex.matchAmong(family, weight: wanted)!;
        expect(match.face.weight, wanted);
        expect(match.exact, isTrue);
      }
    });

    test('below 400, lighter is searched before heavier', () {
      // 300 asked for, 200 and 500 available. 200 is further away in absolute
      // terms and is still the answer: too light reads as the same typeface,
      // too heavy reads as bold.
      final FaceMatch match = SystemFontIndex.matchAmong(
        <SystemFontFace>[_face(weight: 200), _face(weight: 500)],
        weight: 300,
      )!;
      expect(match.face.weight, 200);
      expect(match.exact, isFalse);

      // With nothing lighter, the search turns round and takes the lightest of
      // what is heavier.
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(weight: 500), _face(weight: 900)],
          weight: 300,
        )!
            .face
            .weight,
        500,
      );
    });

    test('above 500, heavier is searched before lighter', () {
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(weight: 300), _face(weight: 800)],
          weight: 700,
        )!
            .face
            .weight,
        800,
      );
      // Nothing heavier: take the heaviest of what is lighter.
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(weight: 300), _face(weight: 600)],
          weight: 700,
        )!
            .face
            .weight,
        600,
      );
    });

    test('400 and 500 have their own rule, and it looks wrong', () {
      // The case the whole test exists for. 400 requested, {100, 600, 900}
      // available: the CSS rule tries 400..500 first (nothing), then everything
      // *below* the request descending - so 100 wins over 600, even though 600
      // is nearer on the number line. A framework that "simplified" this to
      // nearest-neighbour would render body text in Semibold.
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[
            _face(weight: 100),
            _face(weight: 600),
            _face(weight: 900),
          ],
          weight: 400,
        )!
            .face
            .weight,
        100,
      );
      // 500 behaves the same way.
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(weight: 100), _face(weight: 600)],
          weight: 500,
        )!
            .face
            .weight,
        100,
      );
      // But a weight in (request, 500] is preferred over anything below, which
      // is the half of the rule that is not a special case.
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(weight: 450), _face(weight: 100)],
          weight: 400,
        )!
            .face
            .weight,
        450,
      );
    });

    test('a face that states its weight beats one that had it inferred', () {
      final FaceMatch match = SystemFontIndex.matchAmong(
        <SystemFontFace>[
          _face(weight: 400, declaresStyle: false, path: 'inferred.ttf'),
          _face(weight: 400, path: 'declared.ttf'),
        ],
        weight: 400,
      )!;
      expect(match.face.path, 'declared.ttf');
    });
  });

  group('the CSS width search', () {
    test('at or below Normal, narrower is searched before wider', () {
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(width: 2), _face(width: 7)],
          width: 3,
        )!
            .face
            .width,
        2,
      );
      // Nothing narrower: the nearest wider one.
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(width: 5), _face(width: 7)],
          width: 3,
        )!
            .face
            .width,
        5,
      );
    });

    test('above Normal, wider is searched before narrower', () {
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(width: 3), _face(width: 9)],
          width: 7,
        )!
            .face
            .width,
        9,
      );
      expect(
        SystemFontIndex.matchAmong(
          <SystemFontFace>[_face(width: 3), _face(width: 5)],
          width: 7,
        )!
            .face
            .width,
        5,
      );
    });

    test('width is decided before weight, not alongside it', () {
      // The axis order is part of the rule. Asking for Condensed Bold in a
      // family that has Condensed Regular and Normal Bold must give the
      // Condensed one: stretch is settled first and weight chooses within it.
      final FaceMatch match = SystemFontIndex.matchAmong(
        <SystemFontFace>[
          _face(width: 3, weight: 400, path: 'condensed-regular.ttf'),
          _face(width: 5, weight: 700, path: 'normal-bold.ttf'),
        ],
        width: 3,
        weight: 700,
      )!;
      expect(match.face.path, 'condensed-regular.ttf');
      expect(match.exact, isFalse);
    });
  });

  group('italic, oblique and upright', () {
    test('a true italic is preferred over an oblique, and reported as exact',
        () {
      final FaceMatch match = SystemFontIndex.matchAmong(
        <SystemFontFace>[
          _face(oblique: true, italic: true, path: 'oblique.ttf'),
          _face(italic: true, path: 'italic.ttf'),
        ],
        italic: true,
      )!;
      expect(match.face.path, 'italic.ttf');
      expect(match.substitutedSlant, isFalse);
      expect(match.exact, isTrue);
    });

    test('an oblique substituted for an italic is flagged, not hidden', () {
      // The two are not interchangeable: an italic is a different design and an
      // oblique is the upright sheared. A caller that must not substitute has
      // to be able to find out that one happened.
      final FaceMatch match = SystemFontIndex.matchAmong(
        <SystemFontFace>[_face(), _face(oblique: true, path: 'oblique.ttf')],
        italic: true,
      )!;
      expect(match.face.path, 'oblique.ttf');
      expect(match.substitutedSlant, isTrue);
      expect(match.exact, isFalse);
    });

    test('upright falls to an oblique before a true italic', () {
      final FaceMatch match = SystemFontIndex.matchAmong(
        <SystemFontFace>[
          _face(italic: true, path: 'italic.ttf'),
          _face(oblique: true, path: 'oblique.ttf'),
        ],
      )!;
      expect(match.face.path, 'oblique.ttf');
      expect(match.substitutedSlant, isTrue);
    });

    test('upright is exact when an upright exists', () {
      final FaceMatch match = SystemFontIndex.matchAmong(
        <SystemFontFace>[_face(italic: true), _face(path: 'upright.ttf')],
      )!;
      expect(match.face.path, 'upright.ttf');
      expect(match.substitutedSlant, isFalse);
      expect(match.exact, isTrue);
    });

    test('an empty candidate set is null, never a guess', () {
      expect(SystemFontIndex.matchAmong(<SystemFontFace>[]), isNull);
    });
  });

  group('the index', () {
    test('groups by family name and normalises the key', () {
      final SystemFontIndex index = SystemFontIndex.build(
        files: <SystemFontFile>[
          const SystemFontFile(path: 'a.ttf', fileName: 'a.ttf'),
        ],
        reader: (SystemFontFile file) => <SystemFontFace>[
          _face(family: 'Segoe  UI', weight: 400, path: 'a.ttf'),
        ],
      );

      // Case and internal whitespace do not distinguish a family; punctuation
      // does, because "Noto Sans" and "Noto-Sans" are genuinely different
      // names.
      expect(index.facesFor('segoe ui'), hasLength(1));
      expect(index.facesFor('SEGOE UI'), hasLength(1));
      expect(index.hasFamily('Segoe-UI'), isFalse);
      expect(index.familyNames, contains('Segoe  UI'));
    });

    test('a face is reachable by its legacy family name too', () {
      final SystemFontIndex index = SystemFontIndex.build(
        files: <SystemFontFile>[
          const SystemFontFile(path: 'l.ttf', fileName: 'l.ttf'),
        ],
        reader: (SystemFontFile file) => <SystemFontFace>[
          _face(
            family: 'Roboto',
            legacyFamily: 'Roboto Light',
            weight: 300,
            path: 'l.ttf',
          ),
        ],
      );

      // The four-style model split this family in two; a user may type either
      // name and both are the font's own.
      expect(index.facesFor('Roboto'), hasLength(1));
      expect(index.facesFor('Roboto Light'), hasLength(1));
      expect(index.faceCount, 1, reason: 'one face, two names');
    });

    test('the same face found twice is indexed once', () {
      const SystemFontFile file =
          SystemFontFile(path: 'dup.ttf', fileName: 'dup.ttf');
      final SystemFontIndex index = SystemFontIndex.build(
        files: <SystemFontFile>[file, file],
        reader: (SystemFontFile f) =>
            <SystemFontFace>[_face(family: 'Dup', path: 'dup.ttf')],
      );

      expect(index.faceCount, 1);
      expect(index.filesScanned, 2);
    });

    test('a file that yields no face is counted as refused, not as absent', () {
      final SystemFontIndex index = SystemFontIndex.build(
        files: <SystemFontFile>[
          const SystemFontFile(path: 'bad.ttf', fileName: 'bad.ttf'),
        ],
        reader: (SystemFontFile file) => const <SystemFontFace>[],
      );

      expect(index.isEmpty, isTrue);
      expect(index.filesScanned, 1);
      // The difference between "no fonts here" and "none of them parsed" is
      // the difference between two very different bug reports.
      expect(index.filesRefused, 1);
    });

    test('coverage bits order candidates and never exclude them', () {
      final SystemFontFace claiming = _face(
        family: 'Claims Arabic',
        // Bit 13 is Arabic; bit 13 lives in the first word.
        coverage: const UnicodeCoverage(1 << 13, 0, 0, 0),
      );
      final SystemFontFace silent = _face(family: 'No OS/2');
      final SystemFontFace other = _face(
        family: 'Claims Latin',
        coverage: const UnicodeCoverage(1, 0, 0, 0),
      );
      final SystemFontIndex index = SystemFontIndex.build(
        files: <SystemFontFile>[
          const SystemFontFile(path: 'x.ttf', fileName: 'x.ttf'),
        ],
        reader: (SystemFontFile file) =>
            <SystemFontFace>[other, silent, claiming],
      );

      final List<SystemFontFace> candidates =
          index.facesDeclaringBit(13).toList();
      // The claiming face and the one that claims nothing are both offered;
      // the face that claims a different block is not, at this level - the
      // registry's chain is what tries it last of all.
      expect(candidates, contains(claiming));
      expect(candidates, contains(silent));
      expect(candidates, isNot(contains(other)));
      expect(const UnicodeCoverage(1 << 13, 0, 0, 0).hasBit(13), isTrue);
      expect(const UnicodeCoverage(0, 1, 0, 0).hasBit(32), isTrue);
      expect(const UnicodeCoverage(0, 0, 0, 1 << 31).hasBit(127), isTrue);
      expect(UnicodeCoverage.none.isEmpty, isTrue);
      expect(UnicodeCoverage.none.hasBit(200), isFalse);
    });

    test('matching never leaves the family it was asked for', () {
      final SystemFontIndex index = SystemFontIndex.build(
        files: <SystemFontFile>[
          const SystemFontFile(path: 'x.ttf', fileName: 'x.ttf'),
        ],
        reader: (SystemFontFile file) => <SystemFontFace>[
          _face(family: 'Present'),
        ],
      );

      // Silently answering with a different family is the failure section 6.6
      // forbids; null is the honest answer.
      expect(index.match('Absent'), isNull);
      expect(index.match('Present'), isNotNull);
    });

    test('the index is built once and reused', () {
      SystemFonts.invalidateIndex();
      // This test leaves a stub index in the process-wide cache, and the tests
      // below ask that cache about the real machine. Dropping it here is what
      // keeps the two independent.
      addTearDown(SystemFonts.invalidateIndex);
      int reads = 0;
      SystemFontIndex build() => SystemFonts.cachedIndex(
            reader: (SystemFontFile file) {
              reads++;
              return const <SystemFontFace>[];
            },
          );

      final SystemFontIndex first = build();
      final int afterFirst = reads;
      final SystemFontIndex second = build();

      expect(identical(first, second), isTrue);
      expect(reads, afterFirst, reason: 'a cached index reads no files');
      expect(SystemFonts.hasCachedIndex, isTrue);

      SystemFonts.invalidateIndex();
      expect(SystemFonts.hasCachedIndex, isFalse);
      build();
      if (afterFirst > 0) {
        expect(reads, greaterThan(afterFirst),
            reason:
                'invalidation is what makes a newly installed font visible');
      }
    });
  });

  group('this machine', () {
    test('a family is found by the name in its name table, not by file name',
        () {
      final SystemFontIndex? index = machineIndex();
      if (index == null) {
        markTestSkipped('no readable font on this machine');
        return;
      }

      // Whatever this machine has, every face filed under a family must agree
      // that it *is* that family - which is the property a file-name match
      // cannot give.
      for (final String family in index.familyNames.take(50)) {
        for (final SystemFontFace face in index.facesFor(family)) {
          expect(
            SystemFontIndex.normalizeFamily(face.family) ==
                    SystemFontIndex.normalizeFamily(family) ||
                SystemFontIndex.normalizeFamily(face.legacyFamily ?? '') ==
                    SystemFontIndex.normalizeFamily(family),
            isTrue,
            reason: '${face.path} is filed under "$family"',
          );
        }
      }
      expect(index.faceCount, greaterThan(0));
    });

    test('Segoe UI is found by family, including files named nothing like it',
        () {
      final SystemFontIndex? index = machineIndex();
      if (index == null || !index.hasFamily('Segoe UI')) {
        markTestSkipped('needs Windows with Segoe UI installed');
        return;
      }

      final List<SystemFontFace> faces = index.facesFor('Segoe UI');
      expect(faces.length, greaterThan(1));

      // `seguisb.ttf` is Segoe UI Semibold. No file-name heuristic finds that,
      // and this is the whole reason the index reads `name` tables.
      final Iterable<String> files = faces.map(
        (SystemFontFace face) => face.path.split(r'\').last.toLowerCase(),
      );
      expect(files, contains('segoeui.ttf'));
      expect(
        files.any((String name) => !name.startsWith('segoeui')),
        isTrue,
        reason: 'the family reaches beyond the files named after it',
      );

      // And the three weight regimes, against a real family that ships
      // 300/350/400/600/700/900.
      expect(index.match('Segoe UI', weight: 300)!.face.weight, 300);
      expect(index.match('Segoe UI', weight: 400)!.face.weight, 400);
      expect(index.match('Segoe UI', weight: 700)!.face.weight, 700);
      // 500 asked for, none available: below-the-request wins over 600.
      expect(index.match('Segoe UI', weight: 500)!.face.weight, 400);
      // 800 asked for: the search goes up first.
      expect(index.match('Segoe UI', weight: 800)!.face.weight, 900);

      final FaceMatch italic = index.match('Segoe UI', italic: true)!;
      expect(italic.face.italic, isTrue);
      expect(italic.face.weight, 400);
      expect(italic.substitutedSlant, isFalse);
    });

    test('Arial Narrow is the Arial family at width 3, not a family of its own',
        () {
      final SystemFontIndex? index = machineIndex();
      if (index == null || !index.hasFamily('Arial')) {
        markTestSkipped('needs Windows with Arial installed');
        return;
      }
      final List<SystemFontFace> narrow = index
          .facesFor('Arial')
          .where((SystemFontFace face) => face.width < 5)
          .toList();
      if (narrow.isEmpty) {
        markTestSkipped('this machine has Arial without Arial Narrow');
        return;
      }

      // The file is ARIALN.TTF and the family in its name table is "Arial"
      // with subfamily "Narrow": matching by file name would make it its own
      // family and leave `font-stretch: condensed` unsatisfiable.
      final FaceMatch match = index.match('Arial', width: 3)!;
      expect(match.face.width, 3);
      expect(match.face.family, 'Arial');
      expect(index.match('Arial', width: 5)!.face.width, 5);
    });

    test('the preferred interface family resolves to an upright regular face',
        () {
      final SystemFontIndex? index = machineIndex();
      if (index == null) {
        markTestSkipped('no readable font on this machine');
        return;
      }
      final FaceMatch? match = SystemFonts.findPreferredFamily(
        reader: readSystemFontFaces,
      );
      if (match == null) {
        markTestSkipped('none of this platform\'s usual UI families installed');
        return;
      }

      expect(match.face.italic, isFalse);
      expect(SystemFonts.defaultUiFamilies(),
          contains(anyOf(match.face.family, match.face.legacyFamily)));
      expect(match.face.weight, 400);
    });

    test(
        'the file-name heuristic and the family index agree, or the index is '
        'right', () {
      final SystemFontIndex? index = machineIndex();
      final SystemFontFile? byName = const SystemFonts().findPreferred();
      if (index == null || byName == null) {
        markTestSkipped('no readable font on this machine');
        return;
      }

      // Not asserting that they pick the same file - they need not, and when
      // they differ the index is the one that read the font. What is asserted
      // is that the heuristic's answer is a real font file that the index also
      // knows about, so the two are talking about the same machine.
      expect(
        index.faces.any((SystemFontFace face) => face.path == byName.path),
        isTrue,
        reason: '${byName.path} was found by name but is not in the index',
      );
    });
  });
}
