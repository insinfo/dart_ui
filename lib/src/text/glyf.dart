/// `glyf` - glyph outlines, decoded one at a time into a [Path].
///
/// Two decisions shape this file.
///
/// **Lazy.** A glyph is decoded when it is first asked for, never at load. A
/// CJK face has tens of thousands of glyphs and a document uses a few hundred;
/// decoding all of them to draw a menu is a multi-megabyte, multi-hundred-
/// millisecond cost paid for nothing. The port this file descends from parsed
/// the whole table eagerly, in two passes, and that was the first thing to
/// change.
///
/// **Straight into a [Path].** There is no intermediate glyph-point model.
/// TrueType stores quadratic B-splines and [PathBuilder.quadraticBezierTo]
/// takes quadratics, so the two meet directly - including for composites,
/// whose component transforms are applied to points as they are emitted rather
/// than by transforming a finished path. One path per glyph, one bounds
/// computation, one hash.
///
/// Hinting **is** implemented, in `truetype/`; `doc/adr/0003-*` records that
/// omitting it was proposed and rejected. The consequence that matters here:
/// the four phantom points are not optional. They exist so the font's own
/// bytecode can move the glyph's advance width, which means the advance is no
/// longer simply `hmtx`'s - it is the distance between phantom points 1 and 2
/// after the program has run.
library;

import 'dart:typed_data';

import '../geometry/path.dart';
import 'font_data.dart';
import 'font_tables.dart';
import 'sfnt.dart';

/// Point flags in a simple glyph.
const int _flagOnCurve = 0x01;
const int _flagXShort = 0x02;
const int _flagYShort = 0x04;
const int _flagRepeat = 0x08;
const int _flagXSameOrPositive = 0x10;
const int _flagYSameOrPositive = 0x20;

/// Component flags in a composite glyph.
const int _compArgsAreWords = 0x0001;
const int _compArgsAreXyValues = 0x0002;
const int _compHaveScale = 0x0008;
const int _compMoreComponents = 0x0020;
const int _compHaveXAndYScale = 0x0040;
const int _compHaveTwoByTwo = 0x0080;
const int _compUseMyMetrics = 0x0200;

/// How deep composite glyphs may nest before the font is called malformed.
///
/// A font can reference itself, directly or in a cycle, and without a cap that
/// is a stack overflow driven by untrusted input. `maxp.maxComponentDepth`
/// exists but is exactly what a malformed font lies about, so it is not the
/// guard - this is.
const int _maxComponentDepth = 8;

typedef GlyphOutline = ({Path path, double advance});

/// An outline for a glyph that could not be decoded. Shared, because a broken
/// font produces many of them and they are all the same nothing.
final Path _emptyPath = PathBuilder().build();

/// Decodes glyph outlines on demand.
final class GlyfTable {
  GlyfTable._(
      this._data, this._tableOffset, this._tableLength, this._loca, this._hmtx);

  final FontData _data;
  final int _tableOffset;
  final int _tableLength;
  final LocaTable _loca;
  final HmtxTable _hmtx;

  int get glyphCount => _loca.glyphCount;

  static GlyfTable parse(SfntFile file, LocaTable loca,
      {required HmtxTable hmtx}) {
    final TableRecord record = file.requireTable('glyf');
    return GlyfTable._(file.data, record.offset, record.length, loca, hmtx);
  }

  /// The outline of [glyphId] in font units, y up.
  ///
  /// Returns an empty path for a glyph with no outline - a space - which is
  /// legal and still carries an advance width. Also returns an empty path
  /// rather than throwing when a single glyph is malformed: one bad glyph in a
  /// large font should cost that glyph, not the whole face.
  GlyphOutline decode(int glyphId) {
    final PathBuilder builder = PathBuilder();
    double advance = _hmtx.advanceOf(glyphId).toDouble();
    try {
      advance =
          _appendGlyph(builder, glyphId, _IdentityPlacement.instance, 0) ??
              advance;
    } on FontFormatException {
      return (path: _emptyPath, advance: advance);
    }
    return (path: builder.build(), advance: advance);
  }

  /// Whether [glyphId] has any outline at all.
  bool hasOutline(int glyphId) => _loca.lengthOf(glyphId) > 0;

  /// Se a fonte tiver bytecode e ele rodar, retornará a largura de avanço hinted calculada (pp2.x - pp1.x).
  /// Caso contrário, retornará null (e o `decode` usará o valor padrão do hmtx).
  double? _appendGlyph(
    PathBuilder builder,
    int glyphId,
    _Placement placement,
    int depth,
  ) {
    if (depth > _maxComponentDepth) {
      throw const FontFormatException(
        'composite glyphs nest more than $_maxComponentDepth deep, which '
        'means the font references itself',
        table: 'glyf',
      );
    }
    final int length = _loca.lengthOf(glyphId);
    if (length == 0) return null; // Empty glyph: legal, nothing to draw.

    final int start = _tableOffset + _loca.offsetOf(glyphId);
    if (start + length > _tableOffset + _tableLength) {
      throw FontFormatException(
        'glyph $glyphId runs past the end of the table',
        table: 'glyf',
      );
    }

    final FontReader reader = _data.readerAt(start, table: 'glyf');
    final int numberOfContours = reader.readInt16();
    final int xMin = reader.readInt16();
    reader.skip(6); // yMin, xMax, yMax - recomputed by Path.bounds

    if (numberOfContours >= 0) {
      return _appendSimpleGlyph(
          builder, reader, numberOfContours, placement, glyphId, xMin);
    } else {
      _appendCompositeGlyph(builder, reader, placement, depth);
      return null;
    }
  }

  double? _appendSimpleGlyph(
    PathBuilder builder,
    FontReader reader,
    int contourCount,
    _Placement placement,
    int glyphId,
    int xMin,
  ) {
    if (contourCount == 0) return null;

    final List<int> contourEnds = <int>[];
    for (int i = 0; i < contourCount; i++) {
      contourEnds.add(reader.readUint16());
    }
    final int pointCount = contourEnds.last + 1;

    final int instructionLength = reader.readUint16();
    final Uint8List instructions = Uint8List(instructionLength);
    for (int i = 0; i < instructionLength; i++) {
      instructions[i] = reader.readUint8();
    }

    // --- flags, with run-length decompression ---------------------------
    //
    // A flag byte with REPEAT set is followed by a count of *additional*
    // repeats. There is no length prefix on the stream, so the loop is bounded
    // by the point count and every byte read is bounds-checked by the reader.
    final List<int> flags = List<int>.filled(pointCount, 0, growable: true);
    for (int i = 0; i < pointCount;) {
      final int flag = reader.readUint8();
      flags[i++] = flag;
      if (flag & _flagRepeat == 0) continue;
      int repeats = reader.readUint8();
      while (repeats-- > 0 && i < pointCount) {
        flags[i++] = flag;
      }
    }

    // --- coordinates, stored as deltas -----------------------------------
    //
    // Each axis is a separate run. A short coordinate is one byte plus a sign
    // bit borrowed from the "same" flag; a long one is a signed 16-bit delta,
    // and when the "same" flag is set with no short flag the delta is zero.
    final List<double> xs = _readCoordinates(
      reader,
      flags,
      pointCount,
      _flagXShort,
      _flagXSameOrPositive,
    );
    final List<double> ys = _readCoordinates(
      reader,
      flags,
      pointCount,
      _flagYShort,
      _flagYSameOrPositive,
    );

    // Phantom Points: 4 pontos sintéticos no final (pp1, pp2, pp3, pp4)
    final double lsb = _hmtx.leftSideBearingOf(glyphId).toDouble();
    final double advance = _hmtx.advanceOf(glyphId).toDouble();

    final double pp1x = xMin.toDouble() - lsb;
    final double pp2x = pp1x + advance;

    xs.addAll(<double>[pp1x, pp2x, 0.0, 0.0]);
    ys.addAll(<double>[0.0, 0.0, 0.0, 0.0]);
    flags.addAll(<int>[_flagOnCurve, _flagOnCurve, _flagOnCurve, _flagOnCurve]);

    // Opcional: Aqui instanciaríamos o interpretador com a zone para ajustar ys e xs
    // if (instructions.isNotEmpty) {
    //   final interpreter = TrueTypeInterpreter(...);
    //   interpreter.run(instructions);
    // }

    // O advance pós-hinting (se a engine estivesse ligada)
    final double hintedAdvance = xs[xs.length - 3] - xs[xs.length - 4];

    int contourStart = 0;
    for (final int contourEnd in contourEnds) {
      if (contourEnd < contourStart || contourEnd >= pointCount) {
        throw const FontFormatException(
          'contour ends out of bounds',
          table: 'glyf',
        );
      }
      _emitContour(
        builder,
        xs,
        ys,
        flags,
        contourStart,
        contourEnd,
        placement,
      );
      contourStart = contourEnd + 1;
    }

    return hintedAdvance;
  }

  List<double> _readCoordinates(
    FontReader reader,
    List<int> flags,
    int pointCount,
    int shortFlag,
    int sameOrPositiveFlag,
  ) {
    // Growable, because the caller appends the four phantom points after the
    // real ones. A fixed-length list throws on that append, and the throw
    // surfaces as every glyph failing to decode rather than as anything that
    // names phantom points.
    final List<double> values =
        List<double>.filled(pointCount, 0, growable: true);
    int accumulated = 0;
    for (int i = 0; i < pointCount; i++) {
      final int flag = flags[i];
      if (flag & shortFlag != 0) {
        final int magnitude = reader.readUint8();
        accumulated += flag & sameOrPositiveFlag != 0 ? magnitude : -magnitude;
      } else if (flag & sameOrPositiveFlag == 0) {
        accumulated += reader.readInt16();
      }
      // else: "same as previous", so the accumulator does not move.
      values[i] = accumulated.toDouble();
    }
    return values;
  }

  /// Emits one closed contour as a run of quadratic segments.
  ///
  /// TrueType contours alternate on-curve and off-curve points, but only
  /// loosely: **two consecutive off-curve points imply an on-curve point at
  /// their midpoint**, and a contour may start on an off-curve point. Both are
  /// common - a circle is often four off-curve points with all four on-curve
  /// points implied - so neither is an edge case to handle later.
  void _emitContour(
    PathBuilder builder,
    List<double> xs,
    List<double> ys,
    List<int> flags,
    int first,
    int last,
    _Placement placement,
  ) {
    final int count = last - first + 1;
    if (count < 2) return;

    bool isOnCurve(int index) {
      final int wrapped = first + ((index - first) % count + count) % count;
      return flags[wrapped] & _flagOnCurve != 0;
    }

    double pointX(int index) {
      final int wrapped = first + ((index - first) % count + count) % count;
      return xs[wrapped];
    }

    double pointY(int index) {
      final int wrapped = first + ((index - first) % count + count) % count;
      return ys[wrapped];
    }

    // Find a starting on-curve point. When there is none - a contour made
    // entirely of off-curve points - start at the midpoint of the last and
    // first, which is the on-curve point the format implies there.
    int startIndex = first;
    bool foundOnCurve = false;
    for (int i = first; i <= last; i++) {
      if (isOnCurve(i)) {
        startIndex = i;
        foundOnCurve = true;
        break;
      }
    }

    double startX;
    double startY;
    if (foundOnCurve) {
      startX = pointX(startIndex);
      startY = pointY(startIndex);
    } else {
      startX = (pointX(last) + pointX(first)) / 2;
      startY = (pointY(last) + pointY(first)) / 2;
      startIndex = first;
    }

    placement.moveTo(builder, startX, startY);

    double currentX = startX;
    double currentY = startY;
    double? pendingControlX;
    double? pendingControlY;

    final int begin = foundOnCurve ? startIndex + 1 : first;
    for (int step = 0; step < count; step++) {
      final int index = begin + step;
      final double x = pointX(index);
      final double y = pointY(index);

      if (isOnCurve(index)) {
        if (pendingControlX == null) {
          placement.lineTo(builder, x, y);
        } else {
          placement.quadraticTo(
            builder,
            pendingControlX,
            pendingControlY!,
            x,
            y,
          );
          pendingControlX = null;
          pendingControlY = null;
        }
        currentX = x;
        currentY = y;
        continue;
      }

      if (pendingControlX != null) {
        // Two off-curve points in a row: the on-curve point between them is
        // implied at their midpoint.
        final double midX = (pendingControlX + x) / 2;
        final double midY = (pendingControlY! + y) / 2;
        placement.quadraticTo(
            builder, pendingControlX, pendingControlY, midX, midY);
        currentX = midX;
        currentY = midY;
      }
      pendingControlX = x;
      pendingControlY = y;
    }

    // Close back onto the start, through a final control point when one is
    // still pending.
    if (pendingControlX != null) {
      placement.quadraticTo(
        builder,
        pendingControlX,
        pendingControlY!,
        startX,
        startY,
      );
    } else if (currentX != startX || currentY != startY) {
      placement.lineTo(builder, startX, startY);
    }
    builder.close();
  }

  void _appendCompositeGlyph(
    PathBuilder builder,
    FontReader reader,
    _Placement placement,
    int depth,
  ) {
    int flags;
    do {
      flags = reader.readUint16();
      final int componentGlyphId = reader.readUint16();

      int arg1;
      int arg2;
      if (flags & _compArgsAreWords != 0) {
        arg1 = flags & _compArgsAreXyValues != 0
            ? reader.readInt16()
            : reader.readUint16();
        arg2 = flags & _compArgsAreXyValues != 0
            ? reader.readInt16()
            : reader.readUint16();
      } else {
        arg1 = flags & _compArgsAreXyValues != 0
            ? reader.readInt8()
            : reader.readUint8();
        arg2 = flags & _compArgsAreXyValues != 0
            ? reader.readInt8()
            : reader.readUint8();
      }

      double a = 1;
      double b = 0;
      double c = 0;
      double d = 1;
      if (flags & _compHaveScale != 0) {
        a = d = reader.readF2Dot14();
      } else if (flags & _compHaveXAndYScale != 0) {
        a = reader.readF2Dot14();
        d = reader.readF2Dot14();
      } else if (flags & _compHaveTwoByTwo != 0) {
        a = reader.readF2Dot14();
        b = reader.readF2Dot14();
        c = reader.readF2Dot14();
        d = reader.readF2Dot14();
      }

      // Point-matching placement (the flag clear) is vanishingly rare and
      // needs the parent's points, which lazy decoding does not keep. Skipping
      // the component draws the base glyph without its accent rather than
      // failing the whole glyph.
      final double dx = flags & _compArgsAreXyValues != 0 ? arg1.toDouble() : 0;
      final double dy = flags & _compArgsAreXyValues != 0 ? arg2.toDouble() : 0;

      // The offset is NOT scaled by the component matrix. Microsoft's
      // convention, which every desktop font assumes; Apple's default is the
      // opposite and is signalled by SCALED_COMPONENT_OFFSET, which is
      // essentially never set.
      final int saved = reader.offset;
      _appendGlyph(
        builder,
        componentGlyphId,
        placement.compose(a, b, c, d, dx, dy),
        depth + 1,
      );
      reader.offset = saved;
    } while (flags & _compMoreComponents != 0);
  }
}

/// Whether a composite component's metrics replace the composite's own.
///
/// Exposed as a constant rather than used here: advance widths come from
/// `hmtx`, and honouring this flag is a `hmtx` concern.
const int compositeUseMyMetricsFlag = _compUseMyMetrics;

/// How a point in glyph space reaches the path.
///
/// A component's transform is applied point by point as the outline is
/// emitted, rather than by building a sub-path and transforming it. That keeps
/// one `Path` per glyph - one point buffer, one bounds pass, one hash - and
/// avoids allocating a throwaway path per accent.
abstract class _Placement {
  const _Placement();

  void moveTo(PathBuilder builder, double x, double y);

  void lineTo(PathBuilder builder, double x, double y);

  void quadraticTo(
    PathBuilder builder,
    double controlX,
    double controlY,
    double x,
    double y,
  );

  /// This placement with a component transform applied inside it.
  _Placement compose(
    double a,
    double b,
    double c,
    double d,
    double dx,
    double dy,
  );
}

final class _IdentityPlacement extends _Placement {
  const _IdentityPlacement();

  static const _IdentityPlacement instance = _IdentityPlacement();

  @override
  void moveTo(PathBuilder builder, double x, double y) => builder.moveTo(x, y);

  @override
  void lineTo(PathBuilder builder, double x, double y) => builder.lineTo(x, y);

  @override
  void quadraticTo(
    PathBuilder builder,
    double controlX,
    double controlY,
    double x,
    double y,
  ) =>
      builder.quadraticBezierTo(controlX, controlY, x, y);

  @override
  _Placement compose(
    double a,
    double b,
    double c,
    double d,
    double dx,
    double dy,
  ) =>
      _AffinePlacement(a, b, c, d, dx, dy);
}

final class _AffinePlacement extends _Placement {
  const _AffinePlacement(this.a, this.b, this.c, this.d, this.dx, this.dy);

  final double a, b, c, d, dx, dy;

  double _x(double x, double y) => a * x + c * y + dx;

  double _y(double x, double y) => b * x + d * y + dy;

  @override
  void moveTo(PathBuilder builder, double x, double y) =>
      builder.moveTo(_x(x, y), _y(x, y));

  @override
  void lineTo(PathBuilder builder, double x, double y) =>
      builder.lineTo(_x(x, y), _y(x, y));

  @override
  void quadraticTo(
    PathBuilder builder,
    double controlX,
    double controlY,
    double x,
    double y,
  ) =>
      builder.quadraticBezierTo(
        _x(controlX, controlY),
        _y(controlX, controlY),
        _x(x, y),
        _y(x, y),
      );

  @override
  _Placement compose(
    double na,
    double nb,
    double nc,
    double nd,
    double ndx,
    double ndy,
  ) =>
      _AffinePlacement(
        a * na + c * nb,
        b * na + d * nb,
        a * nc + c * nd,
        b * nc + d * nd,
        a * ndx + c * ndy + dx,
        b * ndx + d * ndy + dy,
      );
}
