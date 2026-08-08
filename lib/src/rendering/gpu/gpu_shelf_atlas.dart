/// Rectangle packing for the GPU mask atlas.
///
/// A *shelf* packer is the simplest allocator that works for the atlas's
/// access pattern: shapes arrive in arbitrary order, every allocation is
/// axis-aligned, and the whole atlas resets every frame.  No
/// defragmentation, no merging, no free list - the cost that buys is one
/// integer comparison per shelf and one new shelf when nothing fits.
///
/// The name comes from the image: imagine stacking boxes on shelves in a
/// bookcase.  Each shelf is a horizontal strip of the atlas whose height
/// equals the tallest item placed on it.  A new item goes on the first
/// shelf it fits width-wise; if none has room, a new shelf is opened below
/// the last one.
///
/// ## Why not something better?
///
/// Maxrects, Guillotine and Skyline all pack tighter, and the literature
/// is clear on that.  The difference matters when the atlas is persistent
/// across frames and waste accumulates; here the atlas resets every frame,
/// so the only waste is the unused height *within* a shelf, and a shelf
/// opened for a 30-pixel glyph that later receives a 12-pixel rect wastes
/// 18 rows of texels for the width of that rect - which, at 1 byte per
/// texel and a 1024-wide atlas, is 18 KB.  Measured against the 1 MB atlas
/// and the fact that a frame with hundreds of masked shapes is already
/// heavy, the saving is not worth the code.
///
/// Revisit when the atlas is cached across frames (the mask atlas library
/// comment names that as the obvious next step and says why it is absent).
library;

/// One rectangle's position in the atlas.
final class AtlasSlot {
  const AtlasSlot(this.x, this.y);
  final int x;
  final int y;

  @override
  String toString() => 'AtlasSlot($x, $y)';
}

/// A shelf-based rectangle packer.
///
/// Immutable configuration (width, height), mutable packing state.  Call
/// [reset] between frames to reclaim every allocation without reallocating
/// the object itself.
final class ShelfAtlas {
  ShelfAtlas({required this.width, required this.height})
      : assert(width > 0 && height > 0);

  final int width;
  final int height;

  // A shelf is (y, shelfHeight, xCursor).  Three parallel lists rather than
  // a list of objects: the allocator runs per shape per frame and should not
  // create garbage for the GC to trace.
  final List<int> _shelfY = <int>[];
  final List<int> _shelfHeight = <int>[];
  final List<int> _shelfX = <int>[];

  /// The y coordinate just below the last shelf - where the next new shelf
  /// would start.  Equal to [height] when the atlas is full vertically.
  int _nextShelfY = 0;

  /// How many shelves are currently in use.
  int get shelfCount => _shelfY.length;

  /// Tries to place a rectangle of [w]×[h] texels.
  ///
  /// Returns the top-left corner of the placed rectangle, or null when the
  /// atlas has no room.  The caller must clear the returned region before
  /// writing into it - the packer does not zero memory.
  AtlasSlot? allocate(int w, int h) {
    if (w <= 0 || h <= 0 || w > width || h > height) return null;

    // Try existing shelves.  A shelf is usable when the item fits both
    // horizontally (remaining width) and vertically (shelf height).  The
    // vertical check uses >=, not ==: a 12px item on a 30px shelf is fine,
    // the wasted rows are the trade documented above.
    for (var i = 0; i < _shelfY.length; i++) {
      if (_shelfX[i] + w <= width && _shelfHeight[i] >= h) {
        final slot = AtlasSlot(_shelfX[i], _shelfY[i]);
        _shelfX[i] += w;
        return slot;
      }
    }

    // No shelf has room.  Open a new one if the atlas has vertical space.
    if (_nextShelfY + h > height) return null;

    final slot = AtlasSlot(0, _nextShelfY);
    _shelfY.add(_nextShelfY);
    _shelfHeight.add(h);
    _shelfX.add(w);
    _nextShelfY += h;
    return slot;
  }

  /// Drops every allocation.  O(1) in practice: clears three small lists and
  /// resets one integer.
  void reset() {
    _shelfY.clear();
    _shelfHeight.clear();
    _shelfX.clear();
    _nextShelfY = 0;
  }

  @override
  String toString() =>
      'ShelfAtlas(${width}x$height, shelves: ${_shelfY.length}, '
      'nextY: $_nextShelfY)';
}
