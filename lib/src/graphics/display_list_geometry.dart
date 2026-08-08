/// The geometry-typed layer over the raw encoder.
///
/// [DisplayList] takes bare doubles on purpose: it is the hot path, and a
/// command that costs an `Offset` allocation per call would contradict section
/// 6.5. Callers above the renderer think in [Rect] and [Transform2D] though,
/// and translating by hand at every call site is how component orders get
/// swapped.
///
/// These are extension methods rather than instance methods, so the encoder
/// keeps no dependency on the geometry layer - `graphics` may depend on
/// `geometry`, but keeping the core free of it means the encoder stays usable
/// from an isolate that never loads geometry at all. They compile to the same
/// call: no wrapper object survives.
library;

import 'dart:typed_data';

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/transform2d.dart';
import 'display_list.dart';
import 'display_list_opcodes.dart';

extension DisplayListGeometry on DisplayList {
  /// Concatenates [value].
  ///
  /// The component order here is the whole reason this file has a test: the
  /// encoder stores six floats positionally, and [Transform2D] is the only
  /// definition of what those positions mean.
  void transform2D(Transform2D value) =>
      transform(value.a, value.b, value.c, value.d, value.tx, value.ty);

  void clipRectangle(Rect rect, {int op = clipOpIntersect}) =>
      clipRect(rect.left, rect.top, rect.right, rect.bottom, op: op);

  void drawRectangle(Rect rect, int paintId) =>
      drawRect(rect.left, rect.top, rect.right, rect.bottom, paintId);

  /// Blits [source] of an image into [destination].
  void drawImageRects(
    int imageId,
    Rect source,
    Rect destination,
    int paintId,
  ) =>
      drawImage(
        imageId,
        source.left,
        source.top,
        source.right,
        source.bottom,
        destination.left,
        destination.top,
        destination.right,
        destination.bottom,
        paintId,
      );

  /// Positions a shaped run at [origin]. The glyph buffers are borrowed by the
  /// encoder, not retained, so the shaper keeps reusing one scratch pair.
  void drawGlyphRunAt(
    int fontId,
    int paintId,
    Offset origin,
    Int32List glyphIds,
    Float32List glyphOffsets,
    int glyphCount,
  ) =>
      drawGlyphRun(
        fontId,
        paintId,
        origin.dx,
        origin.dy,
        glyphIds,
        glyphOffsets,
        glyphCount,
      );
}
