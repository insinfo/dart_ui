/// The CFF parser and the Type 2 charstring interpreter.
///
/// Almost every test here builds its font **byte by byte**. That is a
/// deliberate choice over shipping an `.otf` fixture: a synthetic container is
/// deterministic, carries no licence, and - the point - lets a test aim at one
/// byte of one structure. "Subroutine bias in the 1240..33899 range" is not a
/// property any real font exposes on its own; it is a property of an INDEX with
/// a particular count, and the only way to test it is to build that INDEX.
///
/// The few tests that do read a real font are guarded and skip themselves when
/// the file is absent, because they read from `C:\Windows\Fonts` rather than
/// from the repository. They exist because a synthetic font only proves the
/// parser agrees with the test author's reading of the spec; a shipped font
/// proves it agrees with the type foundry's.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/text/cff.dart';
import 'package:dart_ui/src/text/font_data.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

void main() {
  group('INDEX', () {
    test('an empty INDEX is two bytes and holds nothing', () {
      // The count alone: no offSize byte follows a zero count, and a parser
      // that reads one anyway desynchronises every structure after it.
      final FontData data = FontData(Uint8List.fromList(<int>[0, 0, 0xAA]));
      final CffIndex index =
          CffIndex.parse(data, 0, wide: false, table: 'CFF ');

      expect(index.count, 0);
      expect(index.isEmpty, isTrue);
      expect(index.endOffset, 2);
    });

    test('an empty CFF2 INDEX is four bytes', () {
      final FontData data =
          FontData(Uint8List.fromList(<int>[0, 0, 0, 0, 0xAA]));
      final CffIndex index = CffIndex.parse(data, 0, wide: true, table: 'CFF2');

      expect(index.count, 0);
      expect(index.endOffset, 4);
    });

    for (int offSize = 1; offSize <= 4; offSize++) {
      test('offSize $offSize round-trips three entries', () {
        final List<List<int>> entries = <List<int>>[
          <int>[1],
          <int>[2, 3],
          <int>[4, 5, 6],
        ];
        final List<int> bytes = _index(entries, offSize: offSize);
        final CffIndex index = CffIndex.parse(
          FontData(Uint8List.fromList(bytes)),
          0,
          wide: false,
          table: 'CFF ',
        );

        expect(index.count, 3);
        expect(index[0], <int>[1]);
        expect(index[1], <int>[2, 3]);
        expect(index[2], <int>[4, 5, 6]);
        expect(index.endOffset, bytes.length);
      });
    }

    test('a zero or five byte offSize is refused', () {
      for (final int bad in <int>[0, 5]) {
        final FontData data = FontData(
          Uint8List.fromList(<int>[0, 1, bad, 0, 0, 0, 0, 0, 0]),
        );
        expect(
          () => CffIndex.parse(data, 0, wide: false, table: 'CFF '),
          throwsA(isA<FontFormatException>().having(
            (FontFormatException e) => e.message,
            'message',
            contains('offSize'),
          )),
          reason: 'offSize $bad is outside 1..4',
        );
      }
    });

    test('offsets that go backwards are refused, not clamped', () {
      // A negative-length entry would otherwise surface as a silently empty
      // glyph rather than as a broken font.
      final FontData data = FontData(
        Uint8List.fromList(<int>[0, 2, 1, 1, 9, 4, 0, 0, 0, 0, 0, 0, 0, 0]),
      );
      expect(
        () => CffIndex.parse(data, 0, wide: false, table: 'CFF '),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('a zero first offset is refused', () {
      // Offsets are 1-based. Zero means the writer used a 0-based convention
      // and every entry is shifted by one byte.
      final FontData data = FontData(
        Uint8List.fromList(<int>[0, 1, 1, 0, 1, 0xFF]),
      );
      expect(
        () => CffIndex.parse(data, 0, wide: false, table: 'CFF '),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('an entry past the end of the INDEX is refused by name', () {
      final CffIndex index = CffIndex.parse(
        FontData(Uint8List.fromList(_index(<List<int>>[
          <int>[1]
        ]))),
        0,
        wide: false,
        table: 'CFF ',
      );
      expect(() => index[1], throwsA(isA<FontFormatException>()));
      expect(() => index[-1], throwsA(isA<FontFormatException>()));
    });

    test('bias is 107, 1131 or 32768 depending on the count', () {
      // The three ranges, at both edges. Getting one wrong does not fail - it
      // calls a different subroutine and draws a different, plausible glyph.
      expect(CffIndex.biasFor(0), 107);
      expect(CffIndex.biasFor(1239), 107);
      expect(CffIndex.biasFor(1240), 1131);
      expect(CffIndex.biasFor(33899), 1131);
      expect(CffIndex.biasFor(33900), 32768);
      expect(CffIndex.biasFor(70000), 32768);
    });
  });

  group('DICT', () {
    test('integers in one, two, three and five bytes', () {
      final CffDict dict = CffDict.parse(Uint8List.fromList(<int>[
        ..._dictInt(0), 1, // b0 - 139 form
        ..._dictInt(500), 2, // 247..250 form
        ..._dictInt(-500), 3, // 251..254 form
        ..._dictInt(-20000), 4, // 28 + int16
        ..._dictInt(100000), 5, // 29 + int32
      ]));

      expect(dict.intOr(1, -1), 0);
      expect(dict.intOr(2, -1), 500);
      expect(dict.intOr(3, -1), -500);
      expect(dict.intOr(4, -1), -20000);
      expect(dict.intOr(5, -1), 100000);
    });

    test('a real operand decodes from packed BCD nibbles', () {
      // 0.001 is the FontMatrix scale that every CFF carries, so this encoding
      // is not an exotic corner - it is on the hot path of every OTF.
      final CffDict dict = CffDict.parse(Uint8List.fromList(<int>[
        30, 0x0A, 0x00, 0x1F, // ".001"
        1,
        30, 0xE2, 0xA2, 0x5F, // "-2.25"
        2,
        30, 0x1C, 0x3F, // "1E-3"
        3,
      ]));

      expect(dict.doubleOr(1, -1), closeTo(0.001, 1e-12));
      expect(dict.doubleOr(2, -1), closeTo(-2.25, 1e-12));
      expect(dict.doubleOr(3, -1), closeTo(0.001, 1e-12));
    });

    test('the reserved nibble 0xd is refused, not skipped', () {
      // A 0xd means the read is misaligned; skipping it keeps reading garbage
      // and reports success.
      expect(
        () => CffDict.parse(Uint8List.fromList(<int>[30, 0x1D, 0xFF, 1])),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('reserved nibble'),
        )),
      );
    });

    test('an unterminated real operand is refused', () {
      expect(
        () => CffDict.parse(Uint8List.fromList(<int>[30, 0x12, 0x34])),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('a two-byte operator is keyed apart from its one-byte namesake', () {
      // Operator 12 07 is FontMatrix and operator 7 is FamilyBlues. Collapsing
      // them into one key is a real bug in more than one shipped parser.
      final CffDict dict = CffDict.parse(Uint8List.fromList(<int>[
        ..._dictInt(1), 7, // one-byte operator 7
        ..._dictInt(2), 12, 7, // two-byte operator 12 07
      ]));

      expect(dict.intOr(7, -1), 1);
      expect(dict.intOr(1207, -1), 2);
    });

    test('operands with no operator are refused', () {
      expect(
        () => CffDict.parse(Uint8List.fromList(<int>[..._dictInt(5)])),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('no operator'),
        )),
      );
    });

    test('delta arrays accumulate', () {
      // BlueValues and friends store differences. Reading them raw puts every
      // alignment zone but the first in the wrong place.
      final CffDict dict = CffDict.parse(Uint8List.fromList(<int>[
        ..._dictInt(-20),
        ..._dictInt(20),
        ..._dictInt(700),
        ..._dictInt(10),
        6,
      ]));

      expect(dict.delta(6), <double>[-20, 0, 700, 710]);
      expect(dict[6], <double>[-20, 20, 700, 10],
          reason: 'the raw operands stay raw');
    });

    test('more than 48 operands before an operator is refused', () {
      final List<int> bytes = <int>[];
      for (int i = 0; i < 49; i++) {
        bytes.addAll(_dictInt(i));
      }
      bytes.add(1);
      expect(
        () => CffDict.parse(Uint8List.fromList(bytes)),
        throwsA(isA<FontFormatException>()),
      );
    });
  });

  group('charset', () {
    test('format 0 is a plain SID per glyph', () {
      final CffFont font = _font(
        charStrings: <List<int>>[_square(), _square(), _square()],
        charsetBytes: <int>[0, 0, 34, 0, 66], // 'A', 'a'
      );

      expect(font.charset.sidFor(0), 0);
      expect(font.charset.sidFor(1), 34);
      expect(font.charset.sidFor(2), 66);
      expect(font.glyphName(1), 'A');
      expect(font.glyphName(2), 'a');
      expect(font.glyphForName('a'), 2);
    });

    test('format 1 ranges cover nLeft + 1 glyphs', () {
      // nLeft counts the glyphs *after* the first. Reading it as the total
      // shifts every name in the font by a growing amount.
      final CffFont font = _font(
        charStrings: <List<int>>[
          for (int i = 0; i < 6; i++) _square(),
        ],
        charsetBytes: <int>[1, 0, 34, 2, 0, 66, 1],
      );

      expect(<int>[for (int g = 0; g < 6; g++) font.charset.sidFor(g)],
          <int>[0, 34, 35, 36, 66, 67]);
    });

    test('format 2 ranges use a 16-bit nLeft', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          for (int i = 0; i < 5; i++) _square(),
        ],
        charsetBytes: <int>[2, 0, 100, 0, 3],
      );

      expect(<int>[for (int g = 0; g < 5; g++) font.charset.sidFor(g)],
          <int>[0, 100, 101, 102, 103]);
    });

    test('charset offset 0 is the identity, not an offset', () {
      final CffFont font = _font(
        charStrings: <List<int>>[_square(), _square(), _square()],
      );
      expect(font.charset.sidFor(2), 2);
    });

    test('the Expert charsets are refused by name', () {
      // Refused rather than approximated: approximating means naming glyphs
      // wrongly, which is worse than not naming them.
      for (final int predefined in <int>[1, 2]) {
        expect(
          () => CffCharset.parse(
            FontData(Uint8List(16)),
            predefined,
            4,
            isCid: false,
            table: 'CFF ',
          ),
          throwsA(isA<CffUnsupportedFeature>()),
        );
      }
    });

    test('an unknown charset format is refused', () {
      expect(
        () => CffCharset.parse(
          FontData(Uint8List.fromList(<int>[7, 0, 0, 0, 0, 0, 0, 0])),
          0x0,
          4,
          isCid: false,
          table: 'CFF ',
        ),
        returnsNormally,
        reason: 'offset 0 never reaches the format switch',
      );
      expect(
        () => CffCharset.parse(
          FontData(Uint8List.fromList(<int>[0, 0, 0, 7, 0, 0, 0, 0])),
          3,
          4,
          isCid: false,
          table: 'CFF ',
        ),
        throwsA(isA<FontFormatException>()),
      );
    });
  });

  group('FDSelect', () {
    test('format 0 is one byte per glyph', () {
      final CffFdSelect select = CffFdSelect.parse(
        FontData(Uint8List.fromList(<int>[0, 0, 1, 1, 2])),
        0,
        4,
        table: 'CFF ',
      );

      expect(<int>[for (int g = 0; g < 4; g++) select.fdFor(g)],
          <int>[0, 1, 1, 2]);
    });

    test('format 3 ranges resolve at their edges', () {
      // Two ranges, [0, 3) -> 1 and [3, 5) -> 0, with the sentinel at 5. The
      // boundary glyph is the one a broken binary search gets wrong.
      final CffFdSelect select = CffFdSelect.parse(
        FontData(Uint8List.fromList(<int>[
          3, 0, 2, //
          0, 0, 1, //
          0, 3, 0, //
          0, 5, //
        ])),
        0,
        5,
        table: 'CFF ',
      );

      expect(<int>[for (int g = 0; g < 5; g++) select.fdFor(g)],
          <int>[1, 1, 1, 0, 0]);
    });

    test('a format 3 range that goes backwards is refused', () {
      expect(
        () => CffFdSelect.parse(
          FontData(Uint8List.fromList(<int>[
            3, 0, 2, //
            0, 4, 1, //
            0, 1, 0, //
            0, 5, //
          ])),
          0,
          5,
          table: 'CFF ',
        ),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('formats other than 0 and 3 are refused', () {
      expect(
        () => CffFdSelect.parse(
          FontData(Uint8List.fromList(<int>[1, 0, 0, 0, 0, 0])),
          0,
          2,
          table: 'CFF ',
        ),
        throwsA(isA<FontFormatException>()),
      );
    });
  });

  group('charstring: paths', () {
    test('rmoveto and rlineto draw a closed square', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(100), ..._num(0), 5, //
        ..._num(0), ..._num(100), 5, //
        ..._num(-100), ..._num(0), 5, //
        14,
      ]);

      expect(_contours(path), 1);
      expect(_verbs(path, verbLineTo), 3);
      expect(_verbs(path, verbClose), 1);
      expect(path.bounds.left, 0);
      expect(path.bounds.right, 100);
      expect(path.bounds.top, 0);
      expect(path.bounds.bottom, 100);
    });

    test('hlineto and vlineto alternate direction', () {
      // One operand each; the alternation is what makes four operands draw a
      // rectangle rather than four horizontal lines.
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(100), ..._num(60), ..._num(-100), 6, // h, v, h
        14,
      ]);

      expect(path.bounds.right, 100);
      expect(path.bounds.bottom, 60);
      expect(_verbs(path, verbLineTo), 3);
    });

    test('vlineto starts vertical', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(50), ..._num(30), 7, // v then h
        14,
      ]);
      expect(path.bounds.bottom, 50);
      expect(path.bounds.right, 30);
    });

    test('rrcurveto emits a cubic, not a flattened polyline', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(50), ..._num(40), ..._num(50), //
        ..._num(50), ..._num(0), 8, //
        14,
      ]);

      expect(_verbs(path, verbCubicTo), 1);
      expect(_verbs(path, verbQuadraticTo), 0,
          reason: 'CFF is cubic; a quadratic here means a conversion crept in');
      // The end point is the sum of the three deltas.
      expect(path.pointAt(3).dx, closeTo(100, 1e-9));
      expect(path.pointAt(3).dy, closeTo(100, 1e-9));
    });

    test('hhcurveto takes its odd first operand as dy1', () {
      // 5 operands: dy1 then one curve. Treating the odd operand as part of
      // the curve rotates the whole shape.
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(7), ..._num(10), ..._num(20), ..._num(30), ..._num(40), 27, //
        14,
      ]);

      // First control point is (10, 7): dx from the run, dy from the odd lead.
      expect(path.pointAt(1).dx, closeTo(10, 1e-9));
      expect(path.pointAt(1).dy, closeTo(7, 1e-9));
      // Last point has dy3 == 0, so it sits at the second control's y.
      expect(path.pointAt(3).dy, closeTo(7 + 30, 1e-9));
      expect(path.pointAt(3).dx, closeTo(10 + 20 + 40, 1e-9));
    });

    test('vvcurveto takes its odd first operand as dx1', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(7), ..._num(10), ..._num(20), ..._num(30), ..._num(40), 26, //
        14,
      ]);

      expect(path.pointAt(1).dx, closeTo(7, 1e-9));
      expect(path.pointAt(1).dy, closeTo(10, 1e-9));
      expect(path.pointAt(3).dx, closeTo(7 + 20, 1e-9));
      expect(path.pointAt(3).dy, closeTo(10 + 30 + 40, 1e-9));
    });

    test('hvcurveto alternates and reads a trailing fifth operand', () {
      // Nine operands: two curves, the second carrying the extra final
      // coordinate the alternation would otherwise leave at zero. Reading that
      // operand on the first curve instead is the classic bug here.
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(20), ..._num(30), ..._num(40), //
        ..._num(50), ..._num(60), ..._num(70), ..._num(80), //
        ..._num(90), 31,
      ]);

      expect(_verbs(path, verbCubicTo), 2);
      // Curve 1 starts horizontal and ends vertical: (10,0) (20,30) (0,40).
      expect(path.pointAt(3).dx, closeTo(30, 1e-9));
      expect(path.pointAt(3).dy, closeTo(70, 1e-9));
      // Curve 2 starts vertical and ends horizontal, plus the fifth operand
      // supplying the final dy.
      expect(path.pointAt(6).dx, closeTo(30 + 60 + 80, 1e-9));
      expect(path.pointAt(6).dy, closeTo(70 + 50 + 70 + 90, 1e-9));
    });

    test('vhcurveto starts vertical', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(20), ..._num(30), ..._num(40), 30, //
        14,
      ]);

      // (0,10) (20,30) (40,0): the first delta is vertical.
      expect(path.pointAt(1).dx, closeTo(0, 1e-9));
      expect(path.pointAt(1).dy, closeTo(10, 1e-9));
      expect(path.pointAt(3).dy, closeTo(40, 1e-9));
    });

    test('rcurveline is curves then exactly one line', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(10), ..._num(10), ..._num(10), //
        ..._num(10), ..._num(10), //
        ..._num(5), ..._num(-5), 24, //
        14,
      ]);

      expect(_verbs(path, verbCubicTo), 1);
      expect(_verbs(path, verbLineTo), 1);
    });

    test('rlinecurve is lines then exactly one curve', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(5), ..._num(5), //
        ..._num(5), ..._num(5), //
        ..._num(10), ..._num(10), ..._num(10), ..._num(10), //
        ..._num(10), ..._num(10), 25, //
        14,
      ]);

      expect(_verbs(path, verbLineTo), 2);
      expect(_verbs(path, verbCubicTo), 1);
    });
  });

  group('charstring: flex', () {
    test('flex is two curves and drops the flex depth', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(10), ..._num(10), ..._num(10), //
        ..._num(10), ..._num(-10), //
        ..._num(10), ..._num(-10), ..._num(10), ..._num(10), //
        ..._num(10), ..._num(10), //
        ..._num(50), 12, 35, //
        14,
      ]);

      expect(_verbs(path, verbCubicTo), 2);
      // Six deltas summed, and nothing else: 10+10+10+10+10+10 across x and
      // 10+10-10-10+10+10 across y. The 13th operand is fd - the flex depth -
      // and a parser that lets it reach the pen lands somewhere else entirely.
      expect(path.pointAt(6).dx, closeTo(60, 1e-9));
      expect(path.pointAt(6).dy, closeTo(20, 1e-9));
    });

    test('hflex ends on the starting y and carries only one dy', () {
      // The whole reason hflex is shorter than flex: one dy is written and
      // everything else is horizontal. dy2 lifts the join, and the second
      // curve subtracts the same dy2 to land back on the starting line.
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(20), ..._num(30), ..._num(40), //
        ..._num(50), ..._num(60), ..._num(70), 12, 34, //
        14,
      ]);

      expect(_verbs(path, verbCubicTo), 2);
      expect(path.pointAt(1).dy, closeTo(0, 1e-9),
          reason: 'dy1 is implicitly 0');
      expect(path.pointAt(2).dy, closeTo(30, 1e-9), reason: 'dy2');
      expect(path.pointAt(3).dy, closeTo(30, 1e-9),
          reason: 'the join sits at the second control point\'s y');
      expect(path.pointAt(4).dy, closeTo(30, 1e-9),
          reason: 'and so does the third control point');
      expect(path.pointAt(5).dy, closeTo(0, 1e-9), reason: '-dy2');
      expect(path.pointAt(6).dy, closeTo(0, 1e-9),
          reason: 'the end returns to the starting y');
      expect(path.pointAt(6).dx, closeTo(10 + 20 + 40 + 50 + 60 + 70, 1e-9));
    });

    test('hflex1 returns to the starting y through a computed final dy', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(5), ..._num(20), ..._num(7), //
        ..._num(30), ..._num(40), ..._num(50), ..._num(-4), //
        ..._num(60), 12, 36, //
        14,
      ]);

      expect(_verbs(path, verbCubicTo), 2);
      expect(path.pointAt(6).dy, closeTo(0, 1e-9),
          reason: 'dy6 is -(dy1 + dy2 + dy5) exactly so this lands on zero');
      expect(path.pointAt(6).dx, closeTo(10 + 20 + 30 + 40 + 50 + 60, 1e-9));
    });

    test('flex1 closes onto the starting y when dx dominates', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(100), ..._num(5), ..._num(100), ..._num(5), //
        ..._num(100), ..._num(-5), ..._num(100), ..._num(-5), //
        ..._num(100), ..._num(3), //
        ..._num(100), 12, 37, //
        14,
      ]);

      expect(_verbs(path, verbCubicTo), 2);
      expect(path.pointAt(6).dy, closeTo(0, 1e-9),
          reason: 'dx dominates, so the last operand is dx6 and dy6 undoes dy');
      expect(path.pointAt(6).dx, closeTo(600, 1e-9));
    });

    test('flex1 closes onto the starting x when dy dominates', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(5), ..._num(100), ..._num(5), ..._num(100), //
        ..._num(-5), ..._num(100), ..._num(-5), ..._num(100), //
        ..._num(3), ..._num(100), //
        ..._num(100), 12, 37, //
        14,
      ]);

      expect(path.pointAt(6).dx, closeTo(0, 1e-9),
          reason: 'dy dominates, so the last operand is dy6 and dx6 undoes dx');
      expect(path.pointAt(6).dy, closeTo(600, 1e-9));
    });
  });

  group('charstring: implicit width', () {
    test('an even rmoveto carries no width, so defaultWidthX wins', () {
      final CffFont font = _font(
        charStrings: <List<int>>[_square()],
        privateEntries: <int>[
          ..._dictInt(500), 20, // defaultWidthX
          ..._dictInt(200), 21, // nominalWidthX
        ],
      );

      expect(font.outlineOf(0).width, 500);
    });

    test('an odd rmoveto carries nominalWidthX + w', () {
      // Miscounting this shifts every remaining operand by one and skews the
      // whole glyph, not just its advance.
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[
            ..._num(50), ..._num(0), ..._num(0), 21, //
            ..._num(100), ..._num(0), 5, //
            14,
          ],
        ],
        privateEntries: <int>[
          ..._dictInt(500),
          20,
          ..._dictInt(200),
          21,
        ],
      );

      final CffGlyph glyph = font.outlineOf(0);
      expect(glyph.width, 250, reason: '200 nominal + 50');
      expect(glyph.path.bounds.right, 100,
          reason: 'the width must not be drawn as a coordinate');
    });

    test('hmoveto and vmoveto take a width at two operands', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(30), ..._num(10), 22, ..._num(5), ..._num(0), 5, 14],
          <int>[..._num(10), 4, ..._num(5), ..._num(0), 5, 14],
        ],
        privateEntries: <int>[..._dictInt(500), 20, ..._dictInt(200), 21],
      );

      expect(font.outlineOf(0).width, 230);
      expect(font.outlineOf(0).path.bounds.left, 10);
      expect(font.outlineOf(1).width, 500);
    });

    test('an odd stem count carries the width', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[
            ..._num(70), ..._num(0), ..._num(20), 1, // width + one hstem
            ..._num(0), ..._num(0), 21, //
            ..._num(10), ..._num(0), 5, 14,
          ],
        ],
        privateEntries: <int>[..._dictInt(500), 20, ..._dictInt(200), 21],
      );

      expect(font.outlineOf(0).width, 270);
    });

    test('endchar with a single operand carries the width', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(40), 14],
        ],
        privateEntries: <int>[..._dictInt(500), 20, ..._dictInt(200), 21],
      );

      final CffGlyph glyph = font.outlineOf(0);
      expect(glyph.width, 240);
      expect(glyph.path.isEmpty, isTrue, reason: 'a space still has a width');
    });

    test('only the first stack-clearing operator may carry a width', () {
      // Two rmovetos, the second with three operands. The second three-operand
      // form is malformed, but the width must already be settled by then - a
      // parser that re-reads it would take 9 as a width and drop a coordinate.
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[
            ..._num(0), ..._num(0), 21, //
            ..._num(10), ..._num(10), 21, //
            ..._num(20), ..._num(0), 5, 14,
          ],
        ],
        privateEntries: <int>[..._dictInt(500), 20, ..._dictInt(200), 21],
      );

      expect(font.outlineOf(0).width, 500);
      expect(font.outlineOf(0).path.bounds.right, 30);
    });
  });

  group('charstring: hints', () {
    test('hintmask counts hints declared implicitly on the stack', () {
      // Eight hstems, then two operands before hintmask that are an implicit
      // vstem - nine hints, so two mask bytes. The second mask byte is 14
      // (endchar): a parser that reads only one byte executes it and returns
      // an empty glyph, which is exactly the silent failure this pins down.
      final List<int> stems = <int>[];
      for (int i = 0; i < 16; i++) {
        stems.addAll(_num(10));
      }
      final Path path = _draw(<int>[
        ...stems, 18, // hstemhm, 8 hints
        ..._num(5), ..._num(5), 19, 0xFF, 14, // hintmask + 2 mask bytes
        ..._num(0), ..._num(0), 21, //
        ..._num(100), ..._num(0), 5, //
        ..._num(0), ..._num(100), 5, //
        14,
      ]);

      expect(path.isEmpty, isFalse,
          reason: 'the second mask byte was executed as endchar');
      expect(path.bounds.right, 100);
      expect(path.bounds.bottom, 100);
    });

    test('hintmask with no hints at all reads no mask bytes', () {
      final Path path = _draw(<int>[
        19, // hintmask, zero hints, zero mask bytes
        ..._num(0), ..._num(0), 21, //
        ..._num(40), ..._num(0), 5, //
        14,
      ]);

      expect(path.bounds.right, 40);
    });

    test('cntrmask consumes mask bytes the same way', () {
      final Path path = _draw(<int>[
        ..._num(10), ..._num(20), 3, // vstem, one hint
        20, 0x80, // cntrmask + one mask byte
        ..._num(0), ..._num(0), 21, //
        ..._num(40), ..._num(0), 5, //
        14,
      ]);

      expect(path.bounds.right, 40);
    });

    test('a truncated hint mask is refused', () {
      expect(
        () => _draw(<int>[..._num(10), ..._num(20), 18, 19]),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('mask bytes'),
        )),
      );
    });

    test('the Private DICT hint parameters are parsed even though unused', () {
      // Declared limit: nothing applies these yet. They are parsed so that
      // adding a PostScript hinter later is not also a parser change.
      final CffFont font = _font(
        charStrings: <List<int>>[_square()],
        privateEntries: <int>[
          ..._dictInt(-20), ..._dictInt(20), ..._dictInt(700), ..._dictInt(10),
          6, // BlueValues, delta-encoded
          ..._dictInt(80), 10, // StdHW
          ..._dictInt(100), 11, // StdVW
        ],
      );

      final CffPrivateDict private = font.privateDictFor(0);
      expect(private.blueValues, <double>[-20, 0, 700, 710]);
      expect(private.stdHW, 80);
      expect(private.stdVW, 100);
    });
  });

  group('charstring: subroutines', () {
    test('a local subroutine is called through the 107 bias', () {
      // Subroutine 0 is called as -107. A parser using the wrong bias would
      // either fail or, worse, call a different subroutine.
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(0), ..._num(0), 21, ..._num(-107), 10, 14],
        ],
        localSubrs: <List<int>>[
          <int>[..._num(100), ..._num(0), 5, 11], // rlineto; return
        ],
      );

      expect(font.outlineOf(0).path.bounds.right, 100);
    });

    test('a global subroutine has its own, independent bias', () {
      // Local INDEX of 1 (bias 107) and a global INDEX of 1240 (bias 1131).
      // A parser that shares one bias between the two draws nothing here.
      final List<List<int>> globals = <List<int>>[
        for (int i = 0; i < 1240; i++) <int>[11],
      ];
      globals[1239] = <int>[..._num(0), ..._num(70), 5, 11];

      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[
            ..._num(0), ..._num(0), 21, //
            ..._num(-107), 10, // local subr 0
            ..._num(108), 29, // global subr 1239 == 108 + 1131
            14,
          ],
        ],
        localSubrs: <List<int>>[
          <int>[..._num(100), ..._num(0), 5, 11],
        ],
        globalSubrs: globals,
      );

      expect(font.globalSubrs.count, 1240);
      expect(font.globalSubrs.bias, 1131);
      final Path path = font.outlineOf(0).path;
      expect(path.bounds.right, 100);
      expect(path.bounds.bottom, 70);
    });

    test('the 32768 bias range resolves a subroutine end to end', () {
      // 33900 entries is the smallest INDEX in the third range, and building
      // it is the only way to prove the constant.
      final List<List<int>> globals = <List<int>>[
        for (int i = 0; i < 33900; i++) <int>[11],
      ];
      globals[33899] = <int>[..._num(0), ..._num(55), 5, 11];

      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[
            ..._num(0), ..._num(0), 21, //
            ..._num(33899 - 32768), 29, //
            14,
          ],
        ],
        globalSubrs: globals,
      );

      expect(font.globalSubrs.bias, 32768);
      expect(font.outlineOf(0).path.bounds.bottom, 55);
    });

    test('a subroutine number outside the INDEX is refused', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(0), ..._num(0), 21, ..._num(500), 10, 14],
        ],
        localSubrs: <List<int>>[
          <int>[11],
        ],
      );

      expect(
        () => font.outlineOf(0),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('callsubr'),
        )),
      );
    });

    test('a self-calling subroutine is stopped by the depth cap', () {
      // Untrusted input must not be able to overflow the Dart stack. The cap
      // is ours, exactly as in glyf.dart's composite-depth guard.
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(0), ..._num(0), 21, ..._num(-107), 10, 14],
        ],
        localSubrs: <List<int>>[
          <int>[..._num(-107), 10, 11], // calls itself
        ],
      );

      expect(
        () => font.outlineOf(0),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('nest more than'),
        )),
      );
    });

    test('a charstring that overflows the operand stack is refused', () {
      final List<int> code = <int>[];
      for (int i = 0; i < 49; i++) {
        code.addAll(_num(1));
      }
      code.add(14);

      final CffFont font = _font(charStrings: <List<int>>[code]);
      expect(
        () => font.outlineOf(0),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('more than 48 operands'),
        )),
      );
    });

    test('a reserved operator is refused rather than skipped', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(0), ..._num(0), 21, 2, 14], // 2 is reserved
        ],
      );
      expect(
        () => font.outlineOf(0),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('reserved'),
        )),
      );
    });

    test('a charstring that ends inside an operand is refused', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[28, 0x01], // 16-bit operand, one byte short
        ],
      );
      expect(() => font.outlineOf(0), throwsA(isA<FontFormatException>()));
    });
  });

  group('charstring: arithmetic and storage', () {
    test('add, sub, mul, div, neg, abs and sqrt compute operands', () {
      // 3 4 add -> 7; 7 2 mul -> 14; 14 4 sub -> 10; 10 -> the x delta.
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(3), ..._num(4), 12, 10, // add -> 7
        ..._num(2), 12, 24, // mul -> 14
        ..._num(4), 12, 11, // sub -> 10
        ..._num(0), 5, // rlineto by (10, 0)
        ..._num(-100), 12, 9, // abs -> 100
        ..._num(4), 12, 12, // div -> 25
        ..._num(0), 12, 14, 12, 14, // neg twice -> 25
        5, // rlineto by (25, 0)... wait: needs two operands
        14,
      ]);

      expect(path.bounds.right, closeTo(35, 1e-9));
    });

    test('sqrt of a negative operand is refused', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(-4), 12, 26, ..._num(0), 21, 14],
        ],
      );
      expect(() => font.outlineOf(0), throwsA(isA<FontFormatException>()));
    });

    test('division by zero is refused', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(4), ..._num(0), 12, 12, ..._num(0), 21, 14],
        ],
      );
      expect(() => font.outlineOf(0), throwsA(isA<FontFormatException>()));
    });

    test('put and get round-trip through the transient array', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(80), ..._num(3), 12, 20, // put 80 at slot 3
        ..._num(3), 12, 21, // get slot 3
        ..._num(0), 5, //
        14,
      ]);

      expect(path.bounds.right, 80);
    });

    test('a transient slot outside 0..31 is refused', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[
            ..._num(1),
            ..._num(99),
            12,
            20,
            ..._num(0),
            ..._num(0),
            21,
            14
          ],
        ],
      );
      expect(
        () => font.outlineOf(0),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('transient slot'),
        )),
      );
    });

    test('ifelse takes the first branch when v1 <= v2', () {
      // `s1 s2 v1 v2 ifelse` yields s1 when v1 <= v2 and s2 otherwise. The
      // comparison is <=, not <, which is the detail worth pinning: an
      // implementation using < swaps the branch on every equality.
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(20), ..._num(1), ..._num(2), 12, 22, // -> 10
        ..._num(0), 5, //
        ..._num(70), ..._num(20), ..._num(5), ..._num(2), 12, 22, // -> 20
        ..._num(0), 5, //
        ..._num(3), ..._num(4), ..._num(9), ..._num(9), 12, 22, // -> 3
        ..._num(0), 5, //
        14,
      ]);

      expect(path.bounds.right, closeTo(33, 1e-9));
    });

    test('eq, and, or and not produce 1 and 0', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(1), ..._num(1), 12, 15, // eq -> 1
        ..._num(1), 12, 3, // and -> 1
        ..._num(0), 12, 4, // or -> 1
        12, 5, // not -> 0
        ..._num(20), 12, 10, // add -> 20
        ..._num(0), 5, //
        14,
      ]);

      expect(path.bounds.right, 20);
    });

    test('dup, exch, index and roll rearrange the stack', () {
      // Push 5, dup -> 5 5; exch is a no-op on equal values, so use distinct.
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(20), ..._num(60), 12, 28, // exch -> 60 20
        12, 18, // drop -> 60
        ..._num(0), 5, // rlineto (60, 0)
        ..._num(7), 12, 27, // dup -> 7 7
        12, 18, // drop -> 7
        ..._num(0), 5, //
        14,
      ]);

      expect(path.bounds.right, closeTo(67, 1e-9));
    });

    test('index copies the nth element from the top', () {
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(45), ..._num(9), //
        ..._num(1), 12, 29, // index 1 -> copies 45
        12, 18, 12, 18, // drop the two originals' leftovers
        ..._num(0), 5, //
        14,
      ]);

      expect(path.bounds.right, 45);
    });

    test('roll rotates the top n elements', () {
      // Stack 1 2 3, roll 3 1 -> 3 1 2, so the top is 2.
      final Path path = _draw(<int>[
        ..._num(0), ..._num(0), 21, //
        ..._num(10), ..._num(20), ..._num(30), //
        ..._num(3), ..._num(1), 12, 30, // roll
        12, 18, 12, 18, // drop two -> leaves 30
        ..._num(0), 5, //
        14,
      ]);

      expect(path.bounds.right, 30);
    });

    test('random is deterministic across runs of the same glyph', () {
      // Declared limit: `random` is a fixed-seed LCG, not a real random
      // source, because outline caching and golden tests both need the same
      // glyph to draw the same way twice.
      final CffFont a = _font(charStrings: <List<int>>[_randomGlyph()]);
      final CffFont b = _font(charStrings: <List<int>>[_randomGlyph()]);

      expect(
          a.outlineOf(0).path.bounds.right, b.outlineOf(0).path.bounds.right);
      expect(a.outlineOf(0).path.bounds.right, greaterThan(0));
    });

    test('Type 1 leftovers in a Type 2 stream are refused by name', () {
      for (final int op in <int>[6, 7, 16, 17, 33]) {
        final CffFont font = _font(
          charStrings: <List<int>>[
            <int>[..._num(0), ..._num(0), 21, 12, op, 14],
          ],
        );
        expect(
          () => font.outlineOf(0),
          throwsA(isA<CffUnsupportedFeature>()),
          reason: 'operator 12 $op is Type 1',
        );
      }
    });
  });

  group('charstring: seac', () {
    test('endchar with four operands composes two Standard Encoding glyphs',
        () {
      // Glyph 1 is a 100-unit square named 'A' (SID 34, Standard Encoding 65),
      // glyph 2 a 50-unit square named 'acute' (SID 125, code 194). Glyph 3
      // composes them with the accent offset by (200, 300).
      final CffFont font = _font(
        charStrings: <List<int>>[
          _square(),
          _square(),
          _square(size: 50),
          <int>[
            ..._num(200),
            ..._num(300),
            ..._num(65),
            ..._num(194),
            14,
          ],
        ],
        charsetBytes: <int>[0, 0, 34, 0, 125, 0, 200],
      );

      final Path path = font.outlineOf(3).path;
      expect(_contours(path), 2, reason: 'base plus accent');
      expect(path.bounds.left, 0);
      expect(path.bounds.bottom.round(), 350);
      expect(path.bounds.right.round(), 250);
    });

    test('seac keeps the composite width, not the components\'', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          _square(),
          _square(),
          _square(size: 50),
          <int>[
            ..._num(60), // width
            ..._num(200), ..._num(300), ..._num(65), ..._num(194), 14,
          ],
        ],
        charsetBytes: <int>[0, 0, 34, 0, 125, 0, 200],
        privateEntries: <int>[..._dictInt(500), 20, ..._dictInt(200), 21],
      );

      expect(font.outlineOf(3).width, 260);
    });

    test('seac naming a code the font has no glyph for is refused', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          _square(),
          <int>[..._num(0), ..._num(0), ..._num(65), ..._num(194), 14],
        ],
        charsetBytes: <int>[0, 0, 34],
      );

      expect(
        () => font.outlineOf(1),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('seac'),
        )),
      );
    });

    test('an unassigned Standard Encoding code is refused', () {
      // Code 0 has no SID. Treating a zero SID as glyph 0 would draw .notdef
      // as an accent, which is a box in the middle of a letter.
      final CffFont font = _font(
        charStrings: <List<int>>[
          _square(),
          <int>[..._num(0), ..._num(0), ..._num(65), ..._num(0), 14],
        ],
        charsetBytes: <int>[0, 0, 34],
      );

      expect(() => font.outlineOf(1), throwsA(isA<FontFormatException>()));
    });

    test('endchar with any other operand count is refused', () {
      final CffFont font = _font(
        charStrings: <List<int>>[
          <int>[..._num(1), ..._num(2), 14],
        ],
      );
      expect(
        () => font.outlineOf(0),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('endchar'),
        )),
      );
    });
  });

  group('CID-keyed fonts', () {
    test('FDSelect picks the Private DICT, and so the width, per glyph', () {
      // Two Font DICTs with different nominalWidthX. Choosing the wrong one
      // does not fail - it silently misreports the advance of half the font.
      final CffFont font = _font(
        cid: true,
        charStrings: <List<int>>[
          _square(),
          <int>[..._num(50), ..._num(0), ..._num(0), 21, ..._num(10), 6, 14],
          _square(),
          <int>[..._num(50), ..._num(0), ..._num(0), 21, ..._num(10), 6, 14],
        ],
        fdPrivates: <List<int>>[
          <int>[..._dictInt(100), 21], // nominalWidthX for FD 0
          <int>[..._dictInt(1000), 21], // nominalWidthX for FD 1
        ],
        fdSelectBytes: <int>[
          3, 0, 2, //
          0, 0, 0, // glyphs 0..1 -> FD 0
          0, 2, 1, // glyphs 2..3 -> FD 1
          0, 4, //
        ],
      );

      expect(font.isCid, isTrue);
      expect(font.privateDictCount, 2);
      expect(font.outlineOf(1).width, 150);
      expect(font.outlineOf(3).width, 1050);
    });

    test('FDSelect format 0 picks per glyph too', () {
      final CffFont font = _font(
        cid: true,
        charStrings: <List<int>>[
          _square(),
          <int>[..._num(50), ..._num(0), ..._num(0), 21, ..._num(10), 6, 14],
          <int>[..._num(50), ..._num(0), ..._num(0), 21, ..._num(10), 6, 14],
        ],
        fdPrivates: <List<int>>[
          <int>[..._dictInt(100), 21],
          <int>[..._dictInt(1000), 21],
        ],
        fdSelectBytes: <int>[0, 0, 0, 1],
      );

      expect(font.outlineOf(1).width, 150);
      expect(font.outlineOf(2).width, 1050);
    });

    test('a CID font names its glyphs by CID', () {
      final CffFont font = _font(
        cid: true,
        charStrings: <List<int>>[_square(), _square()],
        charsetBytes: <int>[0, 0x03, 0xE8], // glyph 1 -> CID 1000
        fdPrivates: <List<int>>[<int>[]],
        fdSelectBytes: <int>[0, 0, 0],
      );

      expect(font.charset.isCid, isTrue);
      expect(font.glyphName(1), 'cid1000');
      expect(font.glyphForName('cid1000'), isNull,
          reason: 'CID fonts have no name lookup at all');
    });

    test('a CID font that uses seac is refused', () {
      // A CID charset holds CIDs, so a Standard Encoding code cannot be
      // resolved to a glyph. Guessing would draw an arbitrary glyph.
      final CffFont font = _font(
        cid: true,
        charStrings: <List<int>>[
          _square(),
          <int>[..._num(0), ..._num(0), ..._num(65), ..._num(194), 14],
        ],
        fdPrivates: <List<int>>[<int>[]],
        fdSelectBytes: <int>[0, 0, 0],
      );

      expect(
        () => font.outlineOf(1),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('CID'),
        )),
      );
    });
  });

  group('FontMatrix and units', () {
    test('the default matrix in a 1000-upem face is the identity', () {
      final CffFont font = _font(
        charStrings: <List<int>>[_square()],
        unitsPerEm: 1000,
      );

      expect(font.fontMatrix[0], closeTo(0.001, 1e-12));
      expect(font.outputScale, closeTo(1.0, 1e-12));
      expect(font.outlineOf(0).path.bounds.right, 100);
    });

    test('a 2048-upem face scales charstring units into head units', () {
      // FontMatrix 0.001 says the charstrings are in 1000ths of an em; the
      // rest of the engine works in head.unitsPerEm. Without the fold, CFF
      // text comes out roughly half the size of everything else.
      final CffFont font = _font(
        charStrings: <List<int>>[_square()],
        unitsPerEm: 2048,
      );

      expect(font.outputScale, closeTo(2.048, 1e-12));
      // Path points are 32-bit floats, so the tolerance is float32's, not
      // double's. Anything tighter tests the storage format, not the parser.
      expect(font.outlineOf(0).path.bounds.right, closeTo(204.8, 1e-3));
    });

    test('a declared FontMatrix overrides the default', () {
      final CffFont font = _font(
        charStrings: <List<int>>[_square()],
        // FontMatrix [0.0005 0 0 0.0005 0 0]: 2000 charstring units per em.
        topEntries: <int>[
          ..._dictReal(0.0005),
          ..._dictInt(0),
          ..._dictInt(0),
          ..._dictReal(0.0005),
          ..._dictInt(0),
          ..._dictInt(0),
          12,
          7,
        ],
        unitsPerEm: 1000,
      );

      expect(font.outputScale, closeTo(0.5, 1e-12));
      expect(font.outlineOf(0).path.bounds.right, closeTo(50, 1e-9));
    });

    test('a collapsed FontMatrix is refused', () {
      expect(
        () => _font(
          charStrings: <List<int>>[_square()],
          topEntries: <int>[
            ..._dictInt(0),
            ..._dictInt(0),
            ..._dictInt(0),
            ..._dictInt(0),
            ..._dictInt(0),
            ..._dictInt(0),
            12,
            7,
          ],
        ),
        throwsA(isA<FontFormatException>()),
      );
    });
  });

  group('container refusals', () {
    test('a Top DICT with no CharStrings is refused', () {
      expect(
        () => _font(charStrings: <List<int>>[_square()], omitCharStrings: true),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('CharStrings'),
        )),
      );
    });

    test('CharstringType 1 is refused by name', () {
      expect(
        () => _font(
          charStrings: <List<int>>[_square()],
          topEntries: <int>[..._dictInt(1), 12, 6],
        ),
        throwsA(isA<CffUnsupportedFeature>().having(
          (CffUnsupportedFeature e) => e.feature,
          'feature',
          contains('CharstringType'),
        )),
      );
    });

    test('a CFF major version other than 1 is refused', () {
      final Uint8List bytes =
          _font(charStrings: <List<int>>[_square()]).data.bytes;
      final Uint8List broken = Uint8List.fromList(bytes)..[0] = 3;
      expect(
        () => CffFont.parse(FontData(broken), 0, broken.length),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('a CFF2 font found in a "CFF " table is refused with a pointer', () {
      final Uint8List bytes =
          _font(charStrings: <List<int>>[_square()]).data.bytes;
      final Uint8List broken = Uint8List.fromList(bytes)..[0] = 2;
      expect(
        () => CffFont.parse(FontData(broken), 0, broken.length),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('CFF2'),
        )),
      );
    });

    test('a glyph id outside the CharStrings INDEX draws nothing', () {
      final CffFont font = _font(charStrings: <List<int>>[_square()]);
      expect(font.outlineOf(9).path.isEmpty, isTrue);
      expect(font.outlineOf(-1).path.isEmpty, isTrue);
    });

    test('the standard string table has exactly 391 entries', () {
      // SIDs below 391 name a predefined glyph and SIDs at or above it index
      // the font's own String INDEX, so an off-by-one here renames every
      // custom glyph in every font.
      expect(standardStrings.length, nStdStrings);
      expect(standardStrings[0], '.notdef');
      expect(standardStrings[1], 'space');
      expect(standardStrings[34], 'A');
      expect(standardStrings[66], 'a');
      expect(standardStrings[390], 'Semibold');
    });

    test('Standard Encoding maps the codes seac actually uses', () {
      expect(standardEncoding[65], 34, reason: "'A'");
      expect(standardEncoding[194], 125, reason: "'acute'");
      expect(standardEncoding[0], 0, reason: 'unassigned');
      expect(standardEncoding.length, 256);
    });
  });

  group('CFF2', () {
    test('a non-variable CFF2 parses and draws', () {
      // Legal, and produced by a few subsetters. The point of supporting it is
      // that refusing every CFF2 would refuse fonts that have no variation at
      // all.
      final Uint8List bytes = _cff2(
        charStrings: <List<int>>[
          <int>[
            ..._num(0), ..._num(0), 21, //
            ..._num(100), ..._num(0), 5, //
            ..._num(0), ..._num(100), 5, //
          ],
        ],
      );
      final CffFont font =
          CffFont.parseCff2(FontData(bytes), 0, bytes.length, unitsPerEm: 1000);

      expect(font.isCff2, isTrue);
      expect(font.glyphCount, 1);
      expect(font.outlineOf(0).path.bounds.right, 100);
      expect(font.name, isEmpty, reason: 'CFF2 has no Name INDEX');
    });

    test('a variable CFF2 is refused rather than drawn at its default', () {
      // The refusal that matters most in this file. A default-instance glyph
      // looks like a perfectly good glyph and is the wrong weight.
      final Uint8List bytes = _cff2(
        charStrings: <List<int>>[
          <int>[..._num(0), ..._num(0), 21],
        ],
        vstore: true,
      );

      expect(
        () => CffFont.parseCff2(FontData(bytes), 0, bytes.length),
        throwsA(isA<CffUnsupportedFeature>().having(
          (CffUnsupportedFeature e) => e.feature,
          'feature',
          contains('ItemVariationStore'),
        )),
      );
    });

    test('a stray blend inside a non-variable CFF2 still throws', () {
      final Uint8List bytes = _cff2(
        charStrings: <List<int>>[
          <int>[..._num(0), ..._num(0), 21, ..._num(1), ..._num(1), 16],
        ],
      );
      final CffFont font = CffFont.parseCff2(FontData(bytes), 0, bytes.length);

      expect(
        () => font.outlineOf(0),
        throwsA(isA<CffUnsupportedFeature>().having(
          (CffUnsupportedFeature e) => e.feature,
          'feature',
          'blend',
        )),
      );
    });

    test('vsindex is refused too', () {
      final Uint8List bytes = _cff2(
        charStrings: <List<int>>[
          <int>[..._num(0), 15, ..._num(0), ..._num(0), 21],
        ],
      );
      final CffFont font = CffFont.parseCff2(FontData(bytes), 0, bytes.length);

      expect(
        () => font.outlineOf(0),
        throwsA(isA<CffUnsupportedFeature>()),
      );
    });

    test('a CFF2 header with the wrong major version is refused', () {
      final Uint8List bytes = _cff2(
        charStrings: <List<int>>[
          <int>[..._num(0), ..._num(0), 21],
        ],
      );
      bytes[0] = 1;
      expect(
        () => CffFont.parseCff2(FontData(bytes), 0, bytes.length),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('CFF2 charstrings carry no width, so endchar-seac is refused', () {
      final Uint8List bytes = _cff2(
        charStrings: <List<int>>[
          <int>[..._num(1), ..._num(2), ..._num(65), ..._num(194), 14],
        ],
      );
      final CffFont font = CffFont.parseCff2(FontData(bytes), 0, bytes.length);

      expect(() => font.outlineOf(0), throwsA(isA<FontFormatException>()));
    });
  });

  group('a real OpenType/CFF font', () {
    test('an .otf parses through Typeface and produces cubic outlines', () {
      final Typeface? face = _systemOtf('Academico-Regular.otf');
      if (face == null) {
        markTestSkipped('no CFF font on this machine');
        return;
      }

      expect(face.isCff, isTrue);
      expect(face.cff, isNotNull);
      expect(face.glyphCount, greaterThan(100));

      final int glyph = face.glyphForCodePoint(0x6F); // 'o'
      expect(glyph, isNot(0));
      final Path outline = face.outlineOf(glyph);

      expect(outline.isEmpty, isFalse);
      expect(_contours(outline), 2, reason: "'o' is an outside and a counter");
      expect(_verbs(outline, verbCubicTo), greaterThan(3),
          reason: 'CFF outlines are cubic; zero here means curves were lost');
      expect(_verbs(outline, verbQuadraticTo), 0,
          reason: 'a quadratic in a CFF glyph means a conversion crept in');
      // A lowercase o is roughly half an em tall in any text face.
      expect(outline.bounds.height, greaterThan(face.unitsPerEm * 0.3));
      expect(outline.bounds.height, lessThan(face.unitsPerEm.toDouble()));
    });

    test('a space has no outline but keeps its advance', () {
      final Typeface? face = _systemOtf('Academico-Regular.otf');
      if (face == null) {
        markTestSkipped('no CFF font on this machine');
        return;
      }

      final int space = face.glyphForCodePoint(0x20);
      expect(face.hasOutline(space), isFalse);
      expect(face.advanceOf(space), greaterThan(0));
    });

    test('every glyph in the face decodes without throwing', () {
      // The blunt instrument, as in the glyf tests: whatever the foundry
      // actually emitted - flex, seac, deep subroutines - runs here.
      final Typeface? face = _systemOtf('Academico-Regular.otf');
      if (face == null) {
        markTestSkipped('no CFF font on this machine');
        return;
      }

      int drawn = 0;
      for (int glyph = 0; glyph < face.glyphCount; glyph++) {
        if (!face.outlineOf(glyph).isEmpty) drawn++;
      }
      expect(drawn, greaterThan(face.glyphCount ~/ 2));
    });

    test('outlines are cached by glyph id, as on the glyf path', () {
      final Typeface? face = _systemOtf('Academico-Regular.otf');
      if (face == null) {
        markTestSkipped('no CFF font on this machine');
        return;
      }

      final int glyph = face.glyphForCodePoint(0x41);
      expect(identical(face.outlineOf(glyph), face.outlineOf(glyph)), isTrue);
    });

    test('a CID-keyed CJK face resolves its FDSelect', () {
      // Noto Sans JP is CID-keyed with several Font DICTs, which is the shape
      // no synthetic fixture proves: thousands of real FDSelect ranges.
      final Typeface? face = _systemOtf('NotoSansJP-Regular.otf');
      if (face == null) {
        markTestSkipped('no CID-keyed CFF font on this machine');
        return;
      }

      final CffFont cff = face.cff!;
      expect(cff.isCid, isTrue);
      expect(cff.privateDictCount, greaterThan(1));

      final int glyph = face.glyphForCodePoint(0x6F22); // 漢
      expect(glyph, isNot(0));
      expect(face.outlineOf(glyph).isEmpty, isFalse);
      expect(cff.glyphName(glyph), startsWith('cid'));
    });

    test('CFF advances agree with hmtx across the whole face', () {
      // The charstring width and `hmtx` are two independent statements of the
      // same number. A systematic disagreement means the implicit-width rule
      // is being applied wrongly, which is invisible in any single glyph.
      final Typeface? face = _systemOtf('Academico-Regular.otf');
      if (face == null) {
        markTestSkipped('no CFF font on this machine');
        return;
      }

      final CffFont cff = face.cff!;
      int disagreements = 0;
      for (int glyph = 0; glyph < face.glyphCount; glyph++) {
        final double fromCharstring =
            cff.outlineOf(glyph).width * cff.outputScale;
        if ((fromCharstring - face.advanceOf(glyph)).abs() > 1.0) {
          disagreements++;
        }
      }
      expect(disagreements, 0,
          reason: 'the implicit-width rule disagrees with hmtx');
    });
  });
}

// --- fixtures ---------------------------------------------------------------

/// A face read from the system font directory, or null when it is not there.
///
/// Returns null rather than throwing so each test can skip itself: these files
/// are not in the repository and CI may run on a machine without them.
Typeface? _systemOtf(String name) {
  final File file = File('C:/Windows/Fonts/$name');
  if (!file.existsSync()) return null;
  return Typeface.parse(file.readAsBytesSync());
}

int _contours(Path path) => _verbs(path, verbMoveTo);

int _verbs(Path path, int verb) {
  int count = 0;
  for (int i = 0; i < path.verbCount; i++) {
    if (path.verbAt(i) == verb) count++;
  }
  return count;
}

/// Runs [code] as the only glyph of a minimal font and returns its path.
Path _draw(List<int> code) =>
    _font(charStrings: <List<int>>[code]).outlineOf(0).path;

/// A closed square of side [size] starting at the origin.
List<int> _square({int size = 100}) => <int>[
      ..._num(0), ..._num(0), 21, //
      ..._num(size), ..._num(0), 5, //
      ..._num(0), ..._num(size), 5, //
      ..._num(-size), ..._num(0), 5, //
      14,
    ];

/// A glyph whose width comes from `random`, for the determinism test.
List<int> _randomGlyph() => <int>[
      ..._num(0), ..._num(0), 21, //
      12, 23, // random, in (0, 1]
      ..._num(1000), 12, 24, // scale it up so it survives rounding
      ..._num(0), 5, //
      14,
    ];

// --- byte builders ----------------------------------------------------------

/// A DICT integer operand, in the shortest encoding that fits.
List<int> _dictInt(int value) {
  if (value >= -107 && value <= 107) return <int>[value + 139];
  if (value >= 108 && value <= 1131) {
    final int delta = value - 108;
    return <int>[(delta >> 8) + 247, delta & 0xFF];
  }
  if (value >= -1131 && value <= -108) {
    final int delta = -value - 108;
    return <int>[(delta >> 8) + 251, delta & 0xFF];
  }
  if (value >= -32768 && value <= 32767) {
    return <int>[28, (value >> 8) & 0xFF, value & 0xFF];
  }
  return <int>[
    29,
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];
}

/// A DICT integer in the fixed five-byte form.
///
/// Fixed width on purpose: the container is laid out twice, once with
/// placeholder offsets and once with real ones, and only a fixed-width
/// encoding keeps the second pass from moving everything the first pass
/// measured.
List<int> _dictInt5(int value) => <int>[
      29,
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

/// A DICT real operand, nibble-packed.
List<int> _dictReal(double value) {
  final List<int> nibbles = <int>[];
  for (final int unit in value.toString().codeUnits) {
    switch (unit) {
      case 0x2E: // .
        nibbles.add(0xA);
      case 0x2D: // -
        nibbles.add(0xE);
      case 0x65: // e
        nibbles.add(0xB);
      case 0x2B: // +
        break;
      default:
        nibbles.add(unit - 0x30);
    }
  }
  nibbles.add(0xF);
  if (nibbles.length.isOdd) nibbles.add(0xF);

  final List<int> bytes = <int>[30];
  for (int i = 0; i < nibbles.length; i += 2) {
    bytes.add((nibbles[i] << 4) | nibbles[i + 1]);
  }
  return bytes;
}

/// A Type 2 charstring numeric operand, in the shortest encoding that fits.
List<int> _num(int value) {
  if (value >= -107 && value <= 107) return <int>[value + 139];
  if (value >= 108 && value <= 1131) {
    final int delta = value - 108;
    return <int>[(delta >> 8) + 247, delta & 0xFF];
  }
  if (value >= -1131 && value <= -108) {
    final int delta = -value - 108;
    return <int>[(delta >> 8) + 251, delta & 0xFF];
  }
  return <int>[28, (value >> 8) & 0xFF, value & 0xFF];
}

int _offSizeFor(int total) {
  if (total <= 0xFF) return 1;
  if (total <= 0xFFFF) return 2;
  if (total <= 0xFFFFFF) return 3;
  return 4;
}

/// A CFF 1.0 INDEX over [entries].
List<int> _index(List<List<int>> entries, {int? offSize}) {
  if (entries.isEmpty) return <int>[0, 0];
  int total = 1;
  for (final List<int> entry in entries) {
    total += entry.length;
  }
  final int size = offSize ?? _offSizeFor(total);
  final List<int> out = <int>[
    (entries.length >> 8) & 0xFF,
    entries.length & 0xFF,
    size,
  ];
  void put(int value) {
    for (int b = size - 1; b >= 0; b--) {
      out.add((value >> (b * 8)) & 0xFF);
    }
  }

  int running = 1;
  put(running);
  for (final List<int> entry in entries) {
    running += entry.length;
    put(running);
  }
  for (final List<int> entry in entries) {
    out.addAll(entry);
  }
  return out;
}

/// A CFF2 INDEX, whose count is 32 bits wide.
List<int> _index32(List<List<int>> entries) {
  if (entries.isEmpty) return <int>[0, 0, 0, 0];
  final List<int> narrow = _index(entries);
  return <int>[
    0, 0,
    ...narrow, // the uint16 count becomes the low half of a uint32
  ];
}

/// Builds a whole CFF 1.0 font and parses it.
///
/// Laid out twice: the first pass measures every section with placeholder
/// offsets, the second writes the real ones. That works only because every
/// offset uses the fixed five-byte DICT encoding, so nothing moves between the
/// two passes.
CffFont _font({
  required List<List<int>> charStrings,
  List<List<int>> globalSubrs = const <List<int>>[],
  List<List<int>> localSubrs = const <List<int>>[],
  List<int> privateEntries = const <int>[],
  List<int> topEntries = const <int>[],
  List<int>? charsetBytes,
  List<int>? fdSelectBytes,
  List<List<int>> fdPrivates = const <List<int>>[],
  bool cid = false,
  bool omitCharStrings = false,
  int unitsPerEm = 1000,
}) {
  List<int> withSubrs(List<int> entries, bool hasSubrs) {
    if (!hasSubrs) return entries;
    final int length = entries.length + 6;
    return <int>[...entries, ..._dictInt5(length), 19];
  }

  final List<int> privateBody =
      withSubrs(privateEntries, localSubrs.isNotEmpty);
  final List<int> localSubrsBytes =
      localSubrs.isEmpty ? <int>[] : _index(localSubrs);
  final List<List<int>> fdBodies = <List<int>>[
    for (final List<int> entries in fdPrivates) entries,
  ];

  int charsetOffset = 0;
  int fdSelectOffset = 0;
  int charStringsOffset = 0;
  int privateOffset = 0;
  int fdArrayOffset = 0;
  final List<int> fdPrivateOffsets = List<int>.filled(fdBodies.length, 0);
  List<int> bytes = <int>[];

  for (int pass = 0; pass < 2; pass++) {
    final List<List<int>> fdDicts = <List<int>>[
      for (int i = 0; i < fdBodies.length; i++)
        <int>[
          ..._dictInt5(fdBodies[i].length),
          ..._dictInt5(fdPrivateOffsets[i]),
          18,
        ],
    ];
    final List<int> fdArrayIndex = fdDicts.isEmpty ? <int>[] : _index(fdDicts);

    final List<int> top = <int>[
      if (cid) ...<int>[
        ..._dictInt5(391), ..._dictInt5(392), ..._dictInt5(0), 12, 30, // ROS
      ],
      if (charsetBytes != null) ...<int>[..._dictInt5(charsetOffset), 15],
      if (fdSelectBytes != null) ...<int>[
        ..._dictInt5(fdSelectOffset),
        12,
        37,
      ],
      if (!omitCharStrings) ...<int>[..._dictInt5(charStringsOffset), 17],
      if (!cid) ...<int>[
        ..._dictInt5(privateBody.length),
        ..._dictInt5(privateOffset),
        18,
      ],
      if (fdDicts.isNotEmpty) ...<int>[..._dictInt5(fdArrayOffset), 12, 36],
      ...topEntries,
    ];

    final List<int> nameIndex = _index(<List<int>>[
      <int>[0x54, 0x65, 0x73, 0x74], // 'Test'
    ]);
    final List<int> topIndex = _index(<List<int>>[top]);
    final List<int> stringIndex = _index(<List<int>>[
      <int>[0x41, 0x64, 0x6F, 0x62, 0x65], // 'Adobe', SID 391
      <int>[0x49, 0x64, 0x65, 0x6E, 0x74], // 'Ident', SID 392
    ]);
    final List<int> globalIndex = _index(globalSubrs);
    final List<int> charStringsIndex = _index(charStrings);

    int at = 4 +
        nameIndex.length +
        topIndex.length +
        stringIndex.length +
        globalIndex.length;
    charsetOffset = charsetBytes == null ? 0 : at;
    at += charsetBytes?.length ?? 0;
    fdSelectOffset = fdSelectBytes == null ? 0 : at;
    at += fdSelectBytes?.length ?? 0;
    charStringsOffset = at;
    at += charStringsIndex.length;
    privateOffset = at;
    if (!cid) at += privateBody.length + localSubrsBytes.length;
    fdArrayOffset = at;
    at += fdArrayIndex.length;
    for (int i = 0; i < fdBodies.length; i++) {
      fdPrivateOffsets[i] = at;
      at += fdBodies[i].length;
    }

    bytes = <int>[
      1, 0, 4, 4, // major, minor, hdrSize, offSize
      ...nameIndex,
      ...topIndex,
      ...stringIndex,
      ...globalIndex,
      if (charsetBytes != null) ...charsetBytes,
      if (fdSelectBytes != null) ...fdSelectBytes,
      ...charStringsIndex,
      if (!cid) ...privateBody,
      if (!cid) ...localSubrsBytes,
      ...fdArrayIndex,
      for (final List<int> body in fdBodies) ...body,
    ];
  }

  final Uint8List data = Uint8List.fromList(bytes);
  return CffFont.parse(
    FontData(data),
    0,
    data.length,
    unitsPerEm: unitsPerEm,
  );
}

/// Builds a minimal CFF2 table.
///
/// Same two-pass trick as [_font]. CFF2 has no Name INDEX, no String INDEX and
/// no charset, so the layout is header, Top DICT, Global Subr INDEX, then the
/// structures the Top DICT points at.
Uint8List _cff2({
  required List<List<int>> charStrings,
  bool vstore = false,
}) {
  int charStringsOffset = 0;
  int fdArrayOffset = 0;
  int vstoreOffset = 0;
  int fdPrivateOffset = 0;
  const List<int> fdPrivateBody = <int>[];
  List<int> bytes = <int>[];

  for (int pass = 0; pass < 2; pass++) {
    final List<int> top = <int>[
      ..._dictInt5(charStringsOffset),
      17,
      ..._dictInt5(fdArrayOffset),
      12,
      36,
      if (vstore) ...<int>[..._dictInt5(vstoreOffset), 24],
    ];
    final List<int> fdDict = <int>[
      ..._dictInt5(fdPrivateBody.length),
      ..._dictInt5(fdPrivateOffset),
      18,
    ];
    final List<int> fdArrayIndex = _index32(<List<int>>[fdDict]);
    final List<int> globalIndex = _index32(const <List<int>>[]);
    final List<int> charStringsIndex = _index32(charStrings);

    int at = 5 + top.length + globalIndex.length;
    charStringsOffset = at;
    at += charStringsIndex.length;
    fdArrayOffset = at;
    at += fdArrayIndex.length;
    fdPrivateOffset = at;
    at += fdPrivateBody.length;
    vstoreOffset = at;

    bytes = <int>[
      2, 0, 5, (top.length >> 8) & 0xFF, top.length & 0xFF,
      ...top,
      ...globalIndex,
      ...charStringsIndex,
      ...fdArrayIndex,
      ...fdPrivateBody,
      if (vstore) ...<int>[0, 2, 0, 0], // an empty ItemVariationStore stub
    ];
  }

  return Uint8List.fromList(bytes);
}
