/// Integer device-space clipping for the CPU rasteriser.
///
/// RECT-ONLY, DELIBERATELY. The current clip is always one axis-aligned
/// rectangle in whole device pixels. There is no path clipping, no rounded
/// rectangle clipping and no antialiased clip edge. This is stated here rather
/// than left to be discovered because "the clip is a rectangle" is an
/// assumption the rasteriser's inner loops are built on: they compute a row
/// span once and then write it without consulting the clip again.
///
/// What would change for path clipping: the current clip stops being four
/// numbers and becomes a per-scanline coverage mask - for each row, a list of
/// spans, or a byte of coverage per pixel when the edge is antialiased.
/// [ClipStack.intersect] would rasterise the incoming path into that mask and
/// combine it with the mask below by multiplying coverage. The rasteriser's
/// span loop would then read a coverage byte per pixel and fold it into the
/// source alpha before blending; `blendPixelOver` already takes an alpha, so
/// that is a multiply at the top of the loop body and not a redesign. The
/// rectangle case would survive as the fast path it deserves to be, since it
/// needs no mask memory at all.
///
/// Rounding: a clip is converted to whole pixels by rounding each edge to the
/// nearest pixel centre, the same rule the rasteriser's fills use. Matching
/// the two matters more than which rule is picked - it is what makes
/// "clip to R, then fill R" produce exactly R rather than a rectangle short of
/// an edge. Rounding outward would keep partially covered pixels and rounding
/// inward would drop them; both are defensible, and both are wrong the moment
/// they disagree with the fill.
library;

import '../../geometry/rect.dart';

/// A save/restore stack of integer device-space clip rectangles.
///
/// The current clip is exposed as four ints ([left], [top], [right],
/// [bottom]) as well as a [current] [Rect]. The ints are what the rasteriser
/// reads; [current] allocates a `Rect` and exists for callers and tests that
/// want a value rather than a hot loop.
final class ClipStack {
  /// Starts with the whole device surface visible.
  ///
  /// The root entry being the device bounds is why the rasteriser only ever
  /// tests against the clip: intersection can only shrink, so a clip that
  /// starts at the surface can never grow past it and no separate bounds check
  /// is needed in the inner loop.
  ClipStack.forDevice(int width, int height)
      : _left = 0,
        _top = 0,
        _right = width,
        _bottom = height;

  int _left;
  int _top;
  int _right;
  int _bottom;

  /// Saved entries, four ints per depth level, most recent last.
  ///
  /// This list only ever grows. [restore] drops [_depth] by one and leaves the
  /// numbers in place to be overwritten by the next [save], so a UI that saves
  /// and restores a few levels deep every frame - which is every UI - stops
  /// allocating after the first frame reaches its deepest nesting. A
  /// `List<Rect>` of immutable rectangles would allocate an object per save
  /// forever, which is exactly what section 6.5 rules out.
  final List<int> _saved = <int>[];

  /// Number of saved levels, which is `_saved.length ~/ 4` minus whatever has
  /// been restored and not yet overwritten.
  int _depth = 0;

  int get left => _left;

  int get top => _top;

  int get right => _right;

  int get bottom => _bottom;

  /// Nesting depth, zero at the root. Restoring at zero is a caller bug.
  int get depth => _depth;

  /// True when the clip admits no pixels, so callers can bail before doing any
  /// per-primitive work.
  bool get isEmpty => _right <= _left || _bottom <= _top;

  /// The current clip as a rectangle, or [Rect.zero] when empty.
  ///
  /// Allocates. Not for use inside a rasterisation loop; read the four int
  /// getters there instead.
  Rect get current => isEmpty
      ? Rect.zero
      : Rect.fromLTRB(
          _left.toDouble(),
          _top.toDouble(),
          _right.toDouble(),
          _bottom.toDouble(),
        );

  /// Pushes the current clip so a later [restore] brings it back exactly.
  void save() {
    final base = _depth * 4;
    if (base == _saved.length) {
      _saved
        ..add(_left)
        ..add(_top)
        ..add(_right)
        ..add(_bottom);
    } else {
      // Reusing slots left behind by a previous restore: the steady state.
      _saved[base] = _left;
      _saved[base + 1] = _top;
      _saved[base + 2] = _right;
      _saved[base + 3] = _bottom;
    }
    _depth++;
  }

  /// Pops the clip pushed by the matching [save].
  ///
  /// Throws when the stack is empty. An unbalanced restore means the caller
  /// lost track of its own nesting, and silently clamping at the root would
  /// leave the following draw calls clipped to something nobody asked for -
  /// visible as a rendering glitch far from the code that caused it.
  void restore() {
    if (_depth == 0) {
      throw StateError('ClipStack.restore() without a matching save()');
    }
    _depth--;
    final base = _depth * 4;
    _left = _saved[base];
    _top = _saved[base + 1];
    _right = _saved[base + 2];
    _bottom = _saved[base + 3];
  }

  /// Narrows the clip to the part it shares with [rect].
  ///
  /// [rect] is in device space and may have fractional edges; see the library
  /// comment for the rounding rule. The result is never wider than before -
  /// this cannot be used to reopen a region an enclosing clip closed.
  void intersect(Rect rect) {
    if (isEmpty) return;
    intersectDevice(
      pixelEdge(rect.left),
      pixelEdge(rect.top),
      pixelEdge(rect.right),
      pixelEdge(rect.bottom),
    );
  }

  /// [intersect] for callers that already hold integer edges, so a clip that
  /// came from integer geometry does not round-trip through doubles.
  void intersectDevice(int left, int top, int right, int bottom) {
    if (left > _left) _left = left;
    if (top > _top) _top = top;
    if (right < _right) _right = right;
    if (bottom < _bottom) _bottom = bottom;
    if (_right <= _left || _bottom <= _top) {
      // Collapse every empty clip to the same rectangle. Otherwise an empty
      // clip keeps coordinates that a later intersect would compare against,
      // and two empty clips would not be equal to each other.
      _left = 0;
      _top = 0;
      _right = 0;
      _bottom = 0;
    }
  }
}

/// Rounds a device-space edge to the nearest whole pixel.
///
/// `(value + 0.5).floor()` rather than `value.round()`: Dart rounds halves away
/// from zero, so -0.5 would go to -1 while 0.5 goes to 1, and a rectangle
/// dragged across the origin would change width by a pixel as it crossed.
/// Flooring the shifted value rounds every half in the same direction
/// regardless of sign, which is what keeps a shape's pixel size stable as it
/// moves.
int pixelEdge(double value) => (value + 0.5).floor();
