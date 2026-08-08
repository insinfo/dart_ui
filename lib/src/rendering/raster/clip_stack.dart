/// Device-space clipping for the CPU rasteriser.
///
/// RECT-ONLY, DELIBERATELY. The current clip is always one axis-aligned
/// rectangle. There is no path clipping and no rounded rectangle clipping.
/// This is stated here rather than left to be discovered because "the clip is
/// a rectangle" is an assumption the rasteriser's inner loops are built on:
/// they compute a row span once and then write it without consulting the clip
/// again.
///
/// TWO RECTANGLES, ONE CLIP. Every level carries the clip twice: as whole
/// pixels ([left] and friends) and as the exact device-space edges it was
/// asked for ([exactLeft] and friends). They are the same region at two
/// resolutions, and which one a draw call reads depends on whether that call
/// can express a fraction of a pixel:
///
/// * Hard-edged draws - `fillRect`, `drawFramebuffer` - read the integer
///   rectangle. A pixel is in or out, so a fractional clip edge has to be
///   rounded to one or the other eventually, and rounding it once here is
///   cheaper than rounding it per pixel.
/// * Antialiased draws read the exact rectangle, so a clip edge at x = 10.5
///   leaves column 10 half covered instead of chopping it.
///
/// Carrying both is the answer to a problem the antialiased fill was deferred
/// over: with an integer-only clip, a shape whose edge coincides with its clip
/// - a card drawn exactly to the bounds it is clipped to, which is the common
/// case, not a corner case - would come out soft on the edges the clip did not
/// touch and hard on the ones it did. Same shape, two different edge
/// treatments, and which edge got which depended on where the layout landed.
/// The alternative was to leave the clip hard and document the asymmetry, but
/// an artifact that appears and disappears with sub-pixel layout changes is
/// the kind that gets reported as "sometimes the card looks wrong" and never
/// reproduced. Four doubles per clip level is a cheap price to not have that
/// conversation.
///
/// The cost is a second notion of empty, and it is worth reading twice: a clip
/// narrower than one pixel admits no whole pixels but still admits coverage.
/// [isEmpty] answers for the integer rectangle and [isEmptyExact] for the
/// exact one, and `isEmpty` being true does NOT mean nothing can be drawn -
/// only that no hard-edged draw can. `isEmptyExact` implies `isEmpty`, never
/// the reverse.
///
/// What would change for path clipping: the clip stops being a rectangle and
/// becomes a per-scanline coverage mask - for each row, a list of spans, or a
/// byte of coverage per pixel. [intersect] would rasterise the incoming path
/// into that mask and combine it with the mask below by multiplying coverage,
/// and the rasteriser's span loop would read a coverage byte per pixel and
/// fold it into the source alpha exactly as it already folds the rectangle
/// coverage from `spanCoverage`. So the seam is the same one antialiasing
/// already uses, and the rectangle case survives as the fast path it deserves
/// to be, since it needs no mask memory at all.
///
/// Rounding: the integer clip rounds each edge to the nearest pixel centre,
/// the same rule the hard-edged fills use. Matching the two matters more than
/// which rule is picked - it is what makes "clip to R, then fill R" produce
/// exactly R rather than a rectangle short of an edge. Rounding outward would
/// keep partially covered pixels and rounding inward would drop them; both are
/// defensible, and both are wrong the moment they disagree with the fill.
library;

import '../../geometry/rect.dart';

/// A save/restore stack of device-space clip rectangles.
///
/// The current clip is exposed as four ints ([left], [top], [right],
/// [bottom]), four doubles ([exactLeft] and friends) and as [current] and
/// [currentExact] [Rect]s. The scalars are what the rasteriser reads; the
/// `Rect` getters allocate and exist for callers and tests that want a value
/// rather than a hot loop.
final class ClipStack {
  /// Starts with the whole device surface visible.
  ///
  /// The root entry being the device bounds is why the rasteriser only ever
  /// tests against the clip: intersection can only shrink, so a clip that
  /// starts at the surface can never grow past it and no separate bounds check
  /// is needed in the inner loop. That holds for the exact rectangle too,
  /// which is what lets the antialiased fill derive its pixel iteration bounds
  /// from the clip alone and still stay inside the buffer.
  ClipStack.forDevice(int width, int height)
      : _left = 0,
        _top = 0,
        _right = width,
        _bottom = height,
        _exactLeft = 0,
        _exactTop = 0,
        _exactRight = width.toDouble(),
        _exactBottom = height.toDouble();

  int _left;
  int _top;
  int _right;
  int _bottom;

  double _exactLeft;
  double _exactTop;
  double _exactRight;
  double _exactBottom;

  /// Saved entries, four ints per depth level, most recent last.
  ///
  /// This list only ever grows. [restore] drops [_depth] by one and leaves the
  /// numbers in place to be overwritten by the next [save], so a UI that saves
  /// and restores a few levels deep every frame - which is every UI - stops
  /// allocating after the first frame reaches its deepest nesting. A
  /// `List<Rect>` of immutable rectangles would allocate an object per save
  /// forever, which is exactly what section 6.5 rules out.
  final List<int> _saved = <int>[];

  /// The exact edges, kept in a parallel list under the same discipline and
  /// indexed by the same [_depth]. Separate lists rather than one list of
  /// doubles holding both, because the integer edges are read in inner loops
  /// and should stay ints rather than being converted back on every access.
  final List<double> _savedExact = <double>[];

  /// Number of saved levels, which is `_saved.length ~/ 4` minus whatever has
  /// been restored and not yet overwritten.
  int _depth = 0;

  int get left => _left;

  int get top => _top;

  int get right => _right;

  int get bottom => _bottom;

  double get exactLeft => _exactLeft;

  double get exactTop => _exactTop;

  double get exactRight => _exactRight;

  double get exactBottom => _exactBottom;

  /// Nesting depth, zero at the root. Restoring at zero is a caller bug.
  int get depth => _depth;

  /// True when the clip admits no whole pixels, so hard-edged draws can bail
  /// before doing any per-primitive work.
  ///
  /// Not the same question as [isEmptyExact]; see the library comment. A clip
  /// this reports as empty can still admit an antialiased draw.
  bool get isEmpty => _right <= _left || _bottom <= _top;

  /// True when the clip admits no area at all, so nothing can be drawn through
  /// it by any means.
  bool get isEmptyExact =>
      _exactRight <= _exactLeft || _exactBottom <= _exactTop;

  /// The current integer clip as a rectangle, or [Rect.zero] when empty.
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

  /// The current exact clip as a rectangle, or [Rect.zero] when empty.
  ///
  /// Allocates, for the same reasons and with the same warning as [current].
  Rect get currentExact => isEmptyExact
      ? Rect.zero
      : Rect.fromLTRB(_exactLeft, _exactTop, _exactRight, _exactBottom);

  /// Pushes the current clip so a later [restore] brings it back exactly.
  void save() {
    final base = _depth * 4;
    if (base == _saved.length) {
      _saved
        ..add(_left)
        ..add(_top)
        ..add(_right)
        ..add(_bottom);
      _savedExact
        ..add(_exactLeft)
        ..add(_exactTop)
        ..add(_exactRight)
        ..add(_exactBottom);
    } else {
      // Reusing slots left behind by a previous restore: the steady state.
      _saved[base] = _left;
      _saved[base + 1] = _top;
      _saved[base + 2] = _right;
      _saved[base + 3] = _bottom;
      _savedExact[base] = _exactLeft;
      _savedExact[base + 1] = _exactTop;
      _savedExact[base + 2] = _exactRight;
      _savedExact[base + 3] = _exactBottom;
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
    _exactLeft = _savedExact[base];
    _exactTop = _savedExact[base + 1];
    _exactRight = _savedExact[base + 2];
    _exactBottom = _savedExact[base + 3];
  }

  /// Narrows the clip to the part it shares with [rect].
  ///
  /// [rect] is in device space and may have fractional edges: those are kept
  /// as given in the exact rectangle and rounded by [pixelEdge] in the integer
  /// one. The result is never wider than before - this cannot be used to
  /// reopen a region an enclosing clip closed.
  void intersect(Rect rect) {
    // Bailing on the exact emptiness rather than the integer one. A clip that
    // has no whole pixels left may still have area, and skipping the narrowing
    // here would leave that area wider than the caller asked for - which an
    // antialiased draw would then paint into.
    if (isEmptyExact) return;
    if (rect.left > _exactLeft) _exactLeft = rect.left;
    if (rect.top > _exactTop) _exactTop = rect.top;
    if (rect.right < _exactRight) _exactRight = rect.right;
    if (rect.bottom < _exactBottom) _exactBottom = rect.bottom;
    if (isEmptyExact) {
      _exactLeft = 0;
      _exactTop = 0;
      _exactRight = 0;
      _exactBottom = 0;
    }
    _intersectPixels(
      pixelEdge(rect.left),
      pixelEdge(rect.top),
      pixelEdge(rect.right),
      pixelEdge(rect.bottom),
    );
  }

  /// [intersect] for callers that already hold integer edges, so a clip that
  /// came from integer geometry does not round-trip through doubles.
  void intersectDevice(int left, int top, int right, int bottom) {
    if (isEmptyExact) return;
    if (left > _exactLeft) _exactLeft = left.toDouble();
    if (top > _exactTop) _exactTop = top.toDouble();
    if (right < _exactRight) _exactRight = right.toDouble();
    if (bottom < _exactBottom) _exactBottom = bottom.toDouble();
    if (isEmptyExact) {
      _exactLeft = 0;
      _exactTop = 0;
      _exactRight = 0;
      _exactBottom = 0;
    }
    _intersectPixels(left, top, right, bottom);
  }

  void _intersectPixels(int left, int top, int right, int bottom) {
    if (left > _left) _left = left;
    if (top > _top) _top = top;
    if (right < _right) _right = right;
    if (bottom < _bottom) _bottom = bottom;
    if (isEmpty) {
      // Collapse every empty clip to the same rectangle. Otherwise an empty
      // clip keeps coordinates that a later intersect would compare against,
      // and two empty clips would not be equal to each other. Zero is also
      // absorbing under further intersection - `min(x, 0) <= 0 <= max(y, 0)` -
      // so a clip that has lost its pixels cannot regain them.
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
