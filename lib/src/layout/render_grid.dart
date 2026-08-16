/// Two-dimensional layout: tracks, gaps and spans.
///
/// Section 25.4 asks for fixed, auto, fraction and minmax tracks, gaps, spans
/// and alignment. This file is all of it. Implicit *columns* and shared sizing
/// are the two the roadmap defers, and they stay deferred; implicit **rows**
/// are here, because auto-placement produces them the moment there is one child
/// more than the explicit grid has cells, and the alternative would have been to
/// throw at the most ordinary thing anyone does with a grid.
///
/// A grid is where intrinsic measurement stops being optional. An `auto` track
/// means "as wide as the widest thing in it", which is a bottom-up question
/// about content that no constraint can answer; see the intrinsic section of
/// `render_box.dart` for the protocol and its cost.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import 'alignment.dart';
import 'box_constraints.dart';
import 'render_box.dart';

/// How one row or column decides its extent.
///
/// Sealed: the sizing algorithm switches on these exhaustively, and a fifth
/// kind added elsewhere would silently fall into whatever branch happened to
/// be last.
sealed class GridTrack {
  const GridTrack();

  /// As wide as the widest thing in it, and no wider.
  ///
  /// "Widest" is the cells' **max-content** extent - the width at which nothing
  /// has to be compressed. An auto track never grows into leftover space; that
  /// is what [GridTrack.fraction] is for, and keeping the two jobs in separate
  /// track kinds is what makes a grid's column widths predictable from reading
  /// its declaration.
  static const GridTrack auto = AutoTrack();

  /// Exactly [extent] logical pixels, whatever is in it.
  static GridTrack fixed(double extent) => FixedTrack(extent);

  /// A share of what is left after every other track has been sized - CSS's
  /// `1fr`. See [RenderGrid] for where the division's remainder goes.
  static GridTrack fraction([double factor = 1.0]) => FractionTrack(factor);

  /// At least [min], at most [max].
  ///
  /// The common shape is `minmax(fixed(120), fraction(1))`: never narrower than
  /// 120, otherwise a share of the rest.
  static GridTrack minmax(GridTrack min, GridTrack max) =>
      MinMaxTrack(min: min, max: max);
}

/// A track of a fixed extent.
final class FixedTrack extends GridTrack {
  FixedTrack(this.extent) {
    if (extent.isNaN || extent.isInfinite || extent < 0.0) {
      throw ArgumentError.value(
        extent,
        'extent',
        'a fixed track must be a finite, non-negative number of pixels',
      );
    }
  }

  final double extent;

  @override
  bool operator ==(Object other) =>
      other is FixedTrack && other.extent == extent;

  @override
  int get hashCode => Object.hash(FixedTrack, extent);

  @override
  String toString() => 'GridTrack.fixed($extent)';
}

/// A track sized to its content.
final class AutoTrack extends GridTrack {
  const AutoTrack();

  @override
  bool operator ==(Object other) => other is AutoTrack;

  @override
  int get hashCode => 0x4175746F; // 'Auto'

  @override
  String toString() => 'GridTrack.auto';
}

/// A track taking a share of the leftover space.
final class FractionTrack extends GridTrack {
  FractionTrack(this.factor) {
    if (factor.isNaN || factor.isInfinite || factor <= 0.0) {
      throw ArgumentError.value(
        factor,
        'factor',
        'a fractional track must have a finite factor greater than zero; a '
            'zero-factor track would take no share of anything and is better '
            'written as GridTrack.fixed(0)',
      );
    }
  }

  final double factor;

  @override
  bool operator ==(Object other) =>
      other is FractionTrack && other.factor == factor;

  @override
  int get hashCode => Object.hash(FractionTrack, factor);

  @override
  String toString() => 'GridTrack.fraction($factor)';
}

/// A track with a floor and a ceiling.
final class MinMaxTrack extends GridTrack {
  MinMaxTrack({required this.min, required this.max}) {
    if (min is FractionTrack) {
      throw ArgumentError.value(
        min,
        'min',
        'a fractional minimum is circular: the share a track takes of the '
            'leftover space is computed *from* the minima, so it cannot also '
            'be one. Use a fixed or auto minimum.',
      );
    }
    if (min is MinMaxTrack || max is MinMaxTrack) {
      throw ArgumentError(
        'minmax() does not nest: a range whose ends are themselves ranges has '
        'no single floor or ceiling to size a track from.',
      );
    }
  }

  /// [FixedTrack] or [AutoTrack].
  final GridTrack min;

  /// [FixedTrack], [AutoTrack] or [FractionTrack].
  final GridTrack max;

  @override
  bool operator ==(Object other) =>
      other is MinMaxTrack && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(MinMaxTrack, min, max);

  @override
  String toString() => 'GridTrack.minmax($min, $max)';
}

/// How a child is constrained inside the cell it was placed in.
enum GridFit {
  /// The cell's exact size, as a tight constraint. The default, because a grid
  /// exists to line things up and a cell whose content floated inside it would
  /// defeat that.
  stretch,

  /// At most the cell's size; the child picks its own and is then placed by
  /// [RenderGrid.alignment].
  loose,
}

/// Where a child sits in the grid.
final class GridParentData extends BoxParentData {
  /// Explicit column, or null to be placed automatically.
  int? column;

  /// Explicit row, or null to be placed automatically.
  int? row;

  int columnSpan = 1;
  int rowSpan = 1;

  /// Filled in by the grid during layout. Reading it after a layout is how a
  /// test or a debug overlay finds out where auto-placement put a child.
  int resolvedColumn = 0;
  int resolvedRow = 0;

  bool get isExplicit => column != null;

  @override
  String toString() => 'GridParentData(offset: $offset, '
      'cell: ($resolvedColumn, $resolvedRow), span: ($columnSpan, $rowSpan))';
}

/// Arranges children in rows and columns of independently sized tracks.
///
/// ## The sizing algorithm, in order
///
///   1. **Place.** Children with an explicit cell are placed first and mark
///      their cells taken; the rest are auto-placed row-major into the first
///      free run of cells wide enough for their span. Doing the explicit ones
///      first is what keeps auto-placement from depending on the order the
///      children happen to be in.
///   2. **Size the columns.** Each track starts at a base and a growth limit
///      derived from its kind. Children spanning exactly one column raise that
///      column's base to their max-content width. Children spanning several
///      raise it only if the columns they cross cannot already hold them, and
///      the shortfall is split equally among the *content-sized* columns they
///      cross - a span cannot inflate a fixed column, which is the whole point
///      of declaring one fixed.
///   3. **Distribute the leftover.** What remains after step 2 goes to the
///      fractional tracks and to nothing else. An `auto` column does not
///      stretch; if a grid has no fractional column it shrink-wraps its
///      content and leaves the rest of the space alone. This is a deliberate
///      departure from CSS, which stretches auto tracks by default: one rule
///      ("`auto` is content, `fr` is leftover") is worth more here than
///      compatibility with a behaviour most people are surprised by anyway.
///   4. **Size the rows**, by the same three steps - but a row's content height
///      is measured *at the width its columns just settled on*, which is why
///      the intrinsic queries take a cross extent and why rows cannot be sized
///      first.
///   5. **Lay the children out** in their cells and position them.
///
/// ## Where a fractional division's remainder goes
///
/// The last fractional track in declaration order absorbs it. Each track is
/// given `factor * (free / totalFactor)` except the last, which is given
/// whatever is left of the budget after the others took theirs. 100 pixels over
/// three `1fr` columns is therefore `33.333...`, `33.333...`, and a third value
/// a few ulps different that makes the three sum to exactly 100.
///
/// The alternative - giving every track the same rounded share - loses a
/// fraction of a pixel per track, and the loss shows up as a sliver of
/// background down the right edge of the grid that widens with the column
/// count. Picking one track to absorb the error confines it to one boundary,
/// where it is under a pixel and invisible. It is the same rule
/// `RenderFlex` uses for its last flexible child, deliberately: a row and a
/// one-row grid of the same declaration must not disagree by a pixel.
///
/// ## Overflow
///
/// Identical to `RenderFlex`, by design rather than by coincidence: this node
/// sizes itself to its constraints and never past them, positions the children
/// where the tracks put them even when that is outside its own box, does not
/// clip, does not throw, and records the excess in [overflow]. A second policy
/// here would mean a designer had to know which container a screen was built
/// from to predict what an oversized cell does.
final class RenderGrid extends RenderBoxContainer<GridParentData> {
  RenderGrid({
    required List<GridTrack> columns,
    List<GridTrack> rows = const <GridTrack>[],
    GridTrack implicitRow = GridTrack.auto,
    double columnGap = 0.0,
    double rowGap = 0.0,
    GridFit fit = GridFit.stretch,
    Alignment alignment = Alignment.center,
  })  : _columns = List<GridTrack>.unmodifiable(columns),
        _rows = List<GridTrack>.unmodifiable(rows),
        _implicitRow = implicitRow,
        _columnGap = columnGap,
        _rowGap = rowGap,
        _fit = fit,
        _alignment = alignment {
    _checkColumns(_columns);
    _checkGap('columnGap', columnGap);
    _checkGap('rowGap', rowGap);
  }

  List<GridTrack> _columns;
  List<GridTrack> _rows;
  GridTrack _implicitRow;
  double _columnGap;
  double _rowGap;
  GridFit _fit;
  Alignment _alignment;
  Size _overflow = Size.zero;

  // Scratch, reused every frame. Layout runs on every frame that touches this
  // subtree, and section 6.5 puts it on the list of routes that must not
  // allocate per frame.
  final List<double> _columnSizes = <double>[];
  final List<double> _rowSizes = <double>[];
  // A second pair, so an intrinsic query does not overwrite what the last
  // layout settled on: an ancestor measuring this grid must not change what
  // [columnSizes] reports about the frame on screen.
  final List<double> _measuredColumns = <double>[];
  final List<double> _measuredRows = <double>[];
  final List<double> _bases = <double>[];
  final List<double> _limits = <double>[];
  final List<bool> _frozen = <bool>[];
  final List<bool> _occupied = <bool>[];
  int _rowCount = 0;

  /// The column tracks, as declared.
  List<GridTrack> get columns => _columns;

  set columns(List<GridTrack> value) {
    if (_sameTracks(_columns, value)) return;
    _checkColumns(value);
    _columns = List<GridTrack>.unmodifiable(value);
    markNeedsLayout();
  }

  /// The explicit row tracks. May be empty, in which case every row is
  /// implicit and sized by [implicitRow].
  List<GridTrack> get rows => _rows;

  set rows(List<GridTrack> value) {
    if (_sameTracks(_rows, value)) return;
    _rows = List<GridTrack>.unmodifiable(value);
    markNeedsLayout();
  }

  /// How a row past the end of [rows] is sized.
  GridTrack get implicitRow => _implicitRow;

  set implicitRow(GridTrack value) {
    if (value == _implicitRow) return;
    _implicitRow = value;
    markNeedsLayout();
  }

  double get columnGap => _columnGap;

  set columnGap(double value) {
    if (value == _columnGap) return;
    _checkGap('columnGap', value);
    _columnGap = value;
    markNeedsLayout();
  }

  double get rowGap => _rowGap;

  set rowGap(double value) {
    if (value == _rowGap) return;
    _checkGap('rowGap', value);
    _rowGap = value;
    markNeedsLayout();
  }

  GridFit get fit => _fit;

  set fit(GridFit value) {
    if (value == _fit) return;
    _fit = value;
    markNeedsLayout();
  }

  /// Where a child sits in its cell when [fit] is [GridFit.loose].
  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsLayout();
  }

  /// Pixels the tracks needed beyond what this node was allowed, per axis.
  Size get overflow => _overflow;

  bool get hasOverflow => _overflow.width > 0 || _overflow.height > 0;

  /// How many rows the last layout used, explicit and implicit together.
  int get rowCount => _rowCount;

  /// The column extents the last layout settled on. A view of the live buffer,
  /// so copy it if you mean to keep it.
  List<double> get columnSizes => _columnSizes;

  List<double> get rowSizes => _rowSizes;

  static bool _sameTracks(List<GridTrack> a, List<GridTrack> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static void _checkColumns(List<GridTrack> columns) {
    if (columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'a grid needs at least one column; with none there is no cell to place '
            'anything in and no axis to auto-place along',
      );
    }
  }

  static void _checkGap(String name, double value) {
    if (value.isNaN || value.isInfinite || value < 0.0) {
      throw ArgumentError.value(
        value,
        name,
        'must be a finite, non-negative number of pixels',
      );
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! GridParentData) {
      child.parentData = GridParentData();
    }
  }

  /// Pins [child] to a cell, and/or gives it a span.
  ///
  /// Passing neither [column] nor [row] leaves the child to auto-placement
  /// while still applying the spans. Passing one without the other is rejected:
  /// half a coordinate is not a placement, and guessing the other half is how a
  /// grid ends up with two children in the same cell for reasons nobody can
  /// reconstruct.
  void place(
    RenderBox child, {
    int? column,
    int? row,
    int columnSpan = 1,
    int rowSpan = 1,
  }) {
    if ((column == null) != (row == null)) {
      throw ArgumentError(
        'place() needs both a column and a row, or neither. Got '
        'column: $column, row: $row.',
      );
    }
    if (column != null && (column < 0 || row! < 0)) {
      throw ArgumentError('a cell coordinate cannot be negative');
    }
    if (column != null && column >= _columns.length) {
      throw ArgumentError.value(
        column,
        'column',
        'is past the last of this grid\'s ${_columns.length} columns',
      );
    }
    if (columnSpan < 1 || rowSpan < 1) {
      throw ArgumentError('a span covers at least one cell');
    }
    final GridParentData data = childParentData(child);
    data
      ..column = column
      ..row = row
      ..columnSpan = math.min(columnSpan, _columns.length)
      ..rowSpan = rowSpan;
    markNeedsLayout();
  }

  // -----------------------------------------------------------------------
  // Placement
  // -----------------------------------------------------------------------

  GridTrack _rowTrack(int index) =>
      index < _rows.length ? _rows[index] : _implicitRow;

  void _ensureRowCapacity(int rows) {
    final int needed = rows * _columns.length;
    while (_occupied.length < needed) {
      _occupied.add(false);
    }
  }

  bool _isFree(int row, int column, int rowSpan, int columnSpan) {
    for (int r = row; r < row + rowSpan; r++) {
      for (int c = column; c < column + columnSpan; c++) {
        if (_occupied[r * _columns.length + c]) return false;
      }
    }
    return true;
  }

  void _occupy(int row, int column, int rowSpan, int columnSpan) {
    for (int r = row; r < row + rowSpan; r++) {
      for (int c = column; c < column + columnSpan; c++) {
        _occupied[r * _columns.length + c] = true;
      }
    }
  }

  /// Resolves every child's cell and returns the number of rows used.
  int _placeChildren() {
    final int columnCount = _columns.length;
    final int count = childCount;
    for (int i = 0; i < _occupied.length; i++) {
      _occupied[i] = false;
    }
    _ensureRowCapacity(_rows.length);
    int rowsUsed = _rows.length;

    // Phase one: the explicitly placed children claim their cells, so that
    // auto-placement below can see them no matter what order they arrived in.
    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final GridParentData data = childParentData(child);
      if (!data.isExplicit) continue;
      final int column = math.min(data.column!, columnCount - 1);
      final int row = data.row!;
      final int columnSpan = math.min(data.columnSpan, columnCount - column);
      _ensureRowCapacity(row + data.rowSpan);
      _occupy(row, column, data.rowSpan, columnSpan);
      data
        ..resolvedColumn = column
        ..resolvedRow = row;
      rowsUsed = math.max(rowsUsed, row + data.rowSpan);
    }

    // Phase two: everyone else, row-major, never moving the cursor backwards.
    // The cursor is what makes this linear rather than a re-scan per child.
    int cursor = 0;
    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final GridParentData data = childParentData(child);
      if (data.isExplicit) continue;
      final int columnSpan = math.min(data.columnSpan, columnCount);
      while (true) {
        final int column = cursor % columnCount;
        final int row = cursor ~/ columnCount;
        if (column + columnSpan > columnCount) {
          // Would straddle the right edge: skip to the start of the next row
          // rather than wrapping a span around, which would not be one cell.
          cursor = (row + 1) * columnCount;
          continue;
        }
        _ensureRowCapacity(row + data.rowSpan);
        if (_isFree(row, column, data.rowSpan, columnSpan)) {
          _occupy(row, column, data.rowSpan, columnSpan);
          data
            ..resolvedColumn = column
            ..resolvedRow = row;
          rowsUsed = math.max(rowsUsed, row + data.rowSpan);
          break;
        }
        cursor++;
      }
    }
    return rowsUsed;
  }

  // -----------------------------------------------------------------------
  // Track sizing
  // -----------------------------------------------------------------------

  /// Whether a track's extent is decided by what is in it, and can therefore
  /// absorb the shortfall of a child that spans it.
  static bool _isContentSized(GridTrack track) => switch (track) {
        AutoTrack() => true,
        FixedTrack() => false,
        FractionTrack() => false,
        MinMaxTrack(:final GridTrack min, :final GridTrack max) =>
          min is AutoTrack || max is AutoTrack,
      };

  static double _floorOf(GridTrack track) => switch (track) {
        FixedTrack(:final double extent) => extent,
        AutoTrack() => 0.0,
        FractionTrack() => 0.0,
        MinMaxTrack(:final GridTrack min) => _floorOf(min),
      };

  static double _ceilingOf(GridTrack track) => switch (track) {
        FixedTrack(:final double extent) => extent,
        AutoTrack() => double.infinity,
        FractionTrack() => double.infinity,
        MinMaxTrack(:final GridTrack max) => _ceilingOf(max),
      };

  static bool _isFractional(GridTrack track) => switch (track) {
        FractionTrack() => true,
        MinMaxTrack(:final GridTrack max) => max is FractionTrack,
        AutoTrack() => false,
        FixedTrack() => false,
      };

  static double _factorOf(GridTrack track) => switch (track) {
        FractionTrack(:final double factor) => factor,
        MinMaxTrack(:final GridTrack max) => _factorOf(max),
        AutoTrack() => 0.0,
        FixedTrack() => 0.0,
      };

  /// Sizes one axis' tracks into [into].
  ///
  /// [columnsAxis] picks which axis, and with it what a child's content demand
  /// means: a max-content width for the column pass, and a height measured *at
  /// the width its columns already settled on* for the row pass. That is the
  /// only difference between the two, which is why they are one method.
  ///
  /// An axis flag rather than a pair of callbacks: this runs every frame, and
  /// an instance-method tear-off allocates.
  void _sizeTracks({
    required bool columnsAxis,
    required bool minContent,
    required int trackCount,
    required double gap,
    required double available,
    required List<double> into,
  }) {
    _resize(_bases, trackCount);
    _resize(_limits, trackCount);
    for (int i = 0; i < trackCount; i++) {
      final GridTrack track = _trackAt(columnsAxis, i);
      _bases[i] = _floorOf(track);
      _limits[i] = _ceilingOf(track);
    }

    // Step 2a: single-track children raise their track's base directly.
    final int count = childCount;
    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final GridParentData data = childParentData(child);
      final int span = columnsAxis ? data.columnSpan : data.rowSpan;
      if (span != 1) continue;
      final int index = columnsAxis ? data.resolvedColumn : data.resolvedRow;
      if (index >= trackCount) continue;
      if (!_isContentSized(_trackAt(columnsAxis, index))) continue;
      _bases[index] = math.max(
        _bases[index],
        _contributionOf(child, data, columnsAxis, minContent),
      );
    }

    // Step 2b: spanning children raise only what they have to, and only in
    // tracks that are content-sized. A child crossing a fixed and an auto
    // column pushes the auto one; a child crossing two fixed ones overflows,
    // which is the honest outcome of declaring both fixed.
    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final GridParentData data = childParentData(child);
      final int span = columnsAxis ? data.columnSpan : data.rowSpan;
      if (span <= 1) continue;
      final int start = columnsAxis ? data.resolvedColumn : data.resolvedRow;
      final int end = math.min(start + span, trackCount);
      if (end <= start) continue;
      double covered = gap * (end - start - 1);
      int absorbers = 0;
      for (int t = start; t < end; t++) {
        covered += _bases[t];
        if (_isContentSized(_trackAt(columnsAxis, t))) absorbers++;
      }
      final double shortfall =
          _contributionOf(child, data, columnsAxis, minContent) - covered;
      if (shortfall <= 0 || absorbers == 0) continue;
      final double share = shortfall / absorbers;
      for (int t = start; t < end; t++) {
        if (_isContentSized(_trackAt(columnsAxis, t))) _bases[t] += share;
      }
    }

    // The ceiling caps what *content* could add, and never the floor: a floor
    // above the ceiling is the declaration's own doing - minmax(fixed(200),
    // fixed(100)) - and the floor wins there, because a minimum is a promise
    // about what fits and a maximum is only a preference about what looks
    // right. So the effective ceiling is `max(floor, ceiling)`, and the base
    // is clamped to it.
    for (int i = 0; i < trackCount; i++) {
      final GridTrack track = _trackAt(columnsAxis, i);
      final double ceiling = math.max(_floorOf(track), _ceilingOf(track));
      _limits[i] = ceiling;
      if (ceiling.isFinite) _bases[i] = math.min(_bases[i], ceiling);
    }

    _resize(into, trackCount);
    for (int i = 0; i < trackCount; i++) {
      into[i] = _bases[i];
    }
    if (trackCount == 0) return;

    _distributeFractions(
      columnsAxis: columnsAxis,
      trackCount: trackCount,
      gap: gap,
      available: available,
      into: into,
    );
  }

  /// Step 3: hand the leftover to the fractional tracks.
  ///
  /// Follows CSS's "find the size of an fr" rather than simply adding a share
  /// on top of each base, because a `minmax(fixed(70), fraction(1))` track next
  /// to a plain `fraction(1)` must end up at 70 and 30 out of 100 - not at 70
  /// plus half of what is left. A track whose floor already exceeds its share
  /// is frozen at that floor and taken out of the pool, and the pool is
  /// recomputed; that terminates because each round freezes at least one track.
  void _distributeFractions({
    required bool columnsAxis,
    required int trackCount,
    required double gap,
    required double available,
    required List<double> into,
  }) {
    if (!available.isFinite) return;

    _resizeFlags(_frozen, trackCount);
    double fixedExtent = gap * (trackCount - 1);
    double totalFactor = 0.0;
    int fractionCount = 0;
    for (int i = 0; i < trackCount; i++) {
      final GridTrack track = _trackAt(columnsAxis, i);
      final bool fractional = _isFractional(track);
      _frozen[i] = !fractional;
      if (fractional) {
        totalFactor += _factorOf(track);
        fractionCount++;
      } else {
        fixedExtent += into[i];
      }
    }
    if (fractionCount == 0 || totalFactor <= 0.0) return;

    double pool = math.max(0.0, available - fixedExtent);
    double remainingFactor = totalFactor;
    bool changed = true;
    while (changed) {
      changed = false;
      final double rate = pool / remainingFactor;
      for (int i = 0; i < trackCount; i++) {
        if (_frozen[i]) continue;
        final double factor = _factorOf(_trackAt(columnsAxis, i));
        if (into[i] > rate * factor) {
          // Its floor is bigger than its share: it takes the floor and stops
          // competing, and everybody else divides what is left.
          _frozen[i] = true;
          pool = math.max(0.0, pool - into[i]);
          remainingFactor -= factor;
          changed = true;
        }
      }
      if (remainingFactor <= 0.0) return;
    }

    // The remainder policy: every unfrozen track but the last takes its exact
    // share, and the last takes what is left of the budget. See the class
    // comment for why the error is concentrated in one boundary.
    int last = -1;
    for (int i = 0; i < trackCount; i++) {
      if (!_frozen[i]) last = i;
    }
    final double rate = pool / remainingFactor;
    double assigned = 0.0;
    for (int i = 0; i < trackCount; i++) {
      if (_frozen[i]) continue;
      if (i == last) {
        into[i] = math.max(0.0, pool - assigned);
      } else {
        final double share = rate * _factorOf(_trackAt(columnsAxis, i));
        into[i] = share;
        assigned += share;
      }
    }
  }

  /// Grows or truncates [list] to [length], filling with zero.
  ///
  /// `list.length = n` cannot grow a list of a non-nullable element type, and
  /// rebuilding the list would allocate on every frame.
  static void _resize(List<double> list, int length) {
    while (list.length < length) {
      list.add(0.0);
    }
    if (list.length > length) list.removeRange(length, list.length);
  }

  static void _resizeFlags(List<bool> list, int length) {
    while (list.length < length) {
      list.add(false);
    }
    if (list.length > length) list.removeRange(length, list.length);
  }

  static double _totalOf(List<double> sizes, double gap) {
    if (sizes.isEmpty) return 0.0;
    double total = gap * (sizes.length - 1);
    for (int i = 0; i < sizes.length; i++) {
      total += sizes[i];
    }
    return total;
  }

  /// The offset of track [index], given the sizes before it.
  static double _originOf(List<double> sizes, double gap, int index) {
    double origin = gap * index;
    for (int i = 0; i < index; i++) {
      origin += sizes[i];
    }
    return origin;
  }

  static double _extentOf(
    List<double> sizes,
    double gap,
    int start,
    int span,
  ) {
    final int end = math.min(start + span, sizes.length);
    double extent = gap * (end - start - 1);
    for (int i = start; i < end; i++) {
      extent += sizes[i];
    }
    return math.max(0.0, extent);
  }

  // -----------------------------------------------------------------------
  // Layout
  // -----------------------------------------------------------------------

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    _rowCount = _placeChildren();
    final int columnCount = _columns.length;

    _sizeTracks(
      columnsAxis: true,
      minContent: false,
      trackCount: columnCount,
      gap: _columnGap,
      available: constraints.maxWidth,
      into: _columnSizes,
    );

    // Rows are measured at the widths the columns just settled on. That
    // ordering is the reason the intrinsic protocol takes a cross extent at
    // all: "how tall is this paragraph" has no answer until its width is known.
    _widthsForRows = _columnSizes;
    _sizeTracks(
      columnsAxis: false,
      minContent: false,
      trackCount: _rowCount,
      gap: _rowGap,
      available: constraints.maxHeight,
      into: _rowSizes,
    );

    final double desiredWidth = _totalOf(_columnSizes, _columnGap);
    final double desiredHeight = _totalOf(_rowSizes, _rowGap);
    size = constraints.constrain(Size(desiredWidth, desiredHeight));
    _overflow = Size(
      math.max(0.0, desiredWidth - size.width),
      math.max(0.0, desiredHeight - size.height),
    );

    final int count = childCount;
    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final GridParentData data = childParentData(child);
      final double cellWidth = _extentOf(
        _columnSizes,
        _columnGap,
        data.resolvedColumn,
        data.columnSpan,
      );
      final double cellHeight = _extentOf(
        _rowSizes,
        _rowGap,
        data.resolvedRow,
        data.rowSpan,
      );
      final Size cell = Size(cellWidth, cellHeight);
      child.layout(
        _fit == GridFit.stretch
            ? BoxConstraints.tight(cell)
            : BoxConstraints.loose(cell),
        parentUsesSize: _fit == GridFit.loose,
      );
      final Offset origin = Offset(
        _originOf(_columnSizes, _columnGap, data.resolvedColumn),
        _originOf(_rowSizes, _rowGap, data.resolvedRow),
      );
      final Offset inCell = _fit == GridFit.stretch
          ? Offset.zero
          : _alignment.offsetFor(child.size, cell);
      data.offset = Offset(origin.dx + inCell.dx, origin.dy + inCell.dy);
    }
  }

  /// The column extents the row pass measures heights against. Points at
  /// whichever buffer the current pass filled - the layout one or the
  /// intrinsic one.
  List<double> _widthsForRows = const <double>[];

  GridTrack _trackAt(bool columnsAxis, int index) =>
      columnsAxis ? _columns[index] : _rowTrack(index);

  /// How much extent [child] asks for along this axis.
  ///
  /// The row case takes the cell's already-decided width, which is what makes
  /// "a row is as tall as its tallest cell's text needs at that column width"
  /// expressible at all.
  double _contributionOf(
    RenderBox child,
    GridParentData data,
    bool columnsAxis,
    bool minContent,
  ) {
    if (columnsAxis) {
      return minContent
          ? child.getMinIntrinsicWidth(double.infinity)
          : child.getMaxIntrinsicWidth(double.infinity);
    }
    final double width = _extentOf(
      _widthsForRows,
      _columnGap,
      data.resolvedColumn,
      data.columnSpan,
    );
    return minContent
        ? child.getMinIntrinsicHeight(width)
        : child.getMaxIntrinsicHeight(width);
  }

  // -----------------------------------------------------------------------
  // Intrinsics
  // -----------------------------------------------------------------------
  //
  // A grid's own content demand is the sum of its columns' demands plus the
  // gaps, with a fractional track counted at its content size - a `1fr` column
  // asks for no particular width, but the grid still has to be wide enough for
  // what is in it.
  //
  // The height queries size the columns for the width they are given and then
  // sum the rows, which is the same two-step layout performs. That makes them
  // the expensive pair; they are cached like every other intrinsic, and the
  // scratch buffers they write are the same ones layout uses, which is safe
  // only because an intrinsic can never run while a layout of this same node is
  // in progress - see the ban on calling `layout` from an intrinsic.

  double _intrinsicWidth({required bool max}) {
    _placeChildren();
    _sizeTracks(
      columnsAxis: true,
      minContent: !max,
      trackCount: _columns.length,
      gap: _columnGap,
      available: double.infinity,
      into: _measuredColumns,
    );
    return _totalOf(_measuredColumns, _columnGap);
  }

  double _intrinsicHeight(double width, {required bool max}) {
    final int rows = _placeChildren();
    _sizeTracks(
      columnsAxis: true,
      minContent: false,
      trackCount: _columns.length,
      gap: _columnGap,
      available: width,
      into: _measuredColumns,
    );
    _widthsForRows = _measuredColumns;
    _sizeTracks(
      columnsAxis: false,
      minContent: !max,
      trackCount: rows,
      gap: _rowGap,
      available: double.infinity,
      into: _measuredRows,
    );
    return _totalOf(_measuredRows, _rowGap);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _intrinsicWidth(max: false);

  @override
  double computeMaxIntrinsicWidth(double height) => _intrinsicWidth(max: true);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, max: false);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, max: true);

  /// The first row's baseline: a grid reads like a table, and a table's rows
  /// line up with whatever is beside them by their first line of text.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);
}
