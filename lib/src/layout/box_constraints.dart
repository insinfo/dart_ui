/// The one thing a parent tells a child during layout.
///
/// The whole render tree runs on a single rule: constraints go down, sizes
/// come up, and the parent decides position. A child never asks its parent
/// anything, which is what makes layout a single top-down walk rather than a
/// fixpoint iteration.
///
/// Intrinsic sizing (`getMinIntrinsicWidth` and friends) is the one sanctioned
/// exception, and it is deliberately *not* expressed as a constraint. It is a
/// second, bottom-up query pass, it lives on `RenderBox` rather than here, and
/// it is fenced in by a cache, an invalidation rule and a hard ban on calling
/// `layout` from inside one - see the intrinsic section of `render_box.dart`.
/// A grid track sized to its widest cell is what forced it; nothing else in
/// this file changed because of it.
library;

import 'dart:math' as math;

import '../geometry/size.dart';
import 'edge_insets.dart';

/// An immutable range of permitted widths and heights.
///
/// ## Why the constructor throws
///
/// A constraint with `min > max` describes a box no size can satisfy. Every
/// toolkit has a choice here: normalise it silently, or refuse it. This one
/// refuses, because a denormalised constraint is never data - it is always
/// arithmetic that went wrong one or more layers up, and normalising produces
/// a plausible box that is the wrong size, several frames away from the code
/// that caused it. The message names the axis so the search starts in the
/// right place.
///
/// The operators below are held to the same standard in the other direction:
/// [deflate] and [enforce] clamp rather than throw, because their inputs *are*
/// data - padding larger than the space available is a normal consequence of a
/// window being resized, not a bug in the code that built it. The rule is
/// "loud when a programmer was wrong, clamped when the world was small".
final class BoxConstraints {
  BoxConstraints({
    this.minWidth = 0.0,
    this.maxWidth = double.infinity,
    this.minHeight = 0.0,
    this.maxHeight = double.infinity,
  }) {
    _validate('width', 'minWidth', minWidth, 'maxWidth', maxWidth);
    _validate('height', 'minHeight', minHeight, 'maxHeight', maxHeight);
  }

  /// The only size allowed.
  factory BoxConstraints.tight(Size size) => BoxConstraints(
        minWidth: size.width,
        maxWidth: size.width,
        minHeight: size.height,
        maxHeight: size.height,
      );

  /// Tight on the axes given, unbounded on the others.
  factory BoxConstraints.tightFor({double? width, double? height}) =>
      BoxConstraints(
        minWidth: width ?? 0.0,
        maxWidth: width ?? double.infinity,
        minHeight: height ?? 0.0,
        maxHeight: height ?? double.infinity,
      );

  /// At most [size], with no minimum: the child may be as small as it likes.
  factory BoxConstraints.loose(Size size) => BoxConstraints(
        maxWidth: size.width,
        maxHeight: size.height,
      );

  /// Tight at the given extents, or at infinity where one is omitted.
  ///
  /// Infinity here means "as large as your parent will let you", and it is
  /// only usable under a parent that itself has bounded constraints to
  /// [enforce] it against - a bare `expand()` handed to a leaf asks for an
  /// infinite box, which nothing can paint.
  factory BoxConstraints.expand({double? width, double? height}) =>
      BoxConstraints(
        minWidth: width ?? double.infinity,
        maxWidth: width ?? double.infinity,
        minHeight: height ?? double.infinity,
        maxHeight: height ?? double.infinity,
      );

  final double minWidth;
  final double maxWidth;
  final double minHeight;
  final double maxHeight;

  bool get hasBoundedWidth => maxWidth < double.infinity;

  bool get hasBoundedHeight => maxHeight < double.infinity;

  bool get hasTightWidth => minWidth >= maxWidth;

  bool get hasTightHeight => minHeight >= maxHeight;

  /// Whether exactly one size satisfies this. The relayout boundary rule in
  /// `render_box.dart` turns on this getter.
  bool get isTight => hasTightWidth && hasTightHeight;

  /// Whether the ranges are satisfiable and non-negative.
  ///
  /// Always true for anything the constructor returned - it is the predicate
  /// the constructor enforces. Exposed because callers doing their own
  /// interval arithmetic want to test a candidate before constructing it, and
  /// because a subclass or a future `copyWith` chain should have one
  /// definition of "normalised" to check against rather than reinventing it.
  bool get isNormalized =>
      minWidth >= 0.0 &&
      minWidth <= maxWidth &&
      minHeight >= 0.0 &&
      minHeight <= maxHeight;

  /// The smallest permitted size.
  Size get smallest => Size(minWidth, minHeight);

  /// The largest permitted size, which is infinite on an unbounded axis.
  Size get biggest => Size(maxWidth, maxHeight);

  /// The largest permitted size, falling back to the minimum on an unbounded
  /// axis.
  ///
  /// This is what "fill the space you are given" has to mean for a node with
  /// no content of its own: an infinite extent is not a size anything can
  /// paint, hit test or store in a float32 buffer, so an unbounded axis
  /// collapses to the smallest legal value instead of propagating infinity
  /// into the rest of the frame.
  Size get largestFinite => Size(
        hasBoundedWidth ? maxWidth : minWidth,
        hasBoundedHeight ? maxHeight : minHeight,
      );

  double constrainWidth([double width = double.infinity]) =>
      _clamp(width, minWidth, maxWidth);

  double constrainHeight([double height = double.infinity]) =>
      _clamp(height, minHeight, maxHeight);

  /// The closest size to [size] that this permits.
  Size constrain(Size size) => Size(
        constrainWidth(size.width),
        constrainHeight(size.height),
      );

  /// Whether [size] is inside the range. Used by the layout driver to catch a
  /// `performLayout` that ignored what it was told.
  bool isSatisfiedBy(Size size) =>
      size.width >= minWidth &&
      size.width <= maxWidth &&
      size.height >= minHeight &&
      size.height <= maxHeight;

  /// This constraint, clipped into [outer].
  ///
  /// Clamped, not rejected: a node asking for a 400px minimum inside a 200px
  /// parent is describing an intent, and the parent's limit wins. Both ends
  /// are clamped into the outer range, so the result is always normalised even
  /// when the two ranges do not overlap at all - in which case the result is
  /// tight at the nearest edge of [outer], the closest thing to the request
  /// that the parent actually permits.
  BoxConstraints enforce(BoxConstraints outer) => BoxConstraints(
        minWidth: _clamp(minWidth, outer.minWidth, outer.maxWidth),
        maxWidth: _clamp(maxWidth, outer.minWidth, outer.maxWidth),
        minHeight: _clamp(minHeight, outer.minHeight, outer.maxHeight),
        maxHeight: _clamp(maxHeight, outer.minHeight, outer.maxHeight),
      );

  /// The same maxima with the minima dropped to zero - "you may be smaller".
  BoxConstraints loosen() => BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );

  /// Raises the minima (and lowers the maxima) toward the given extents,
  /// staying inside the current range.
  BoxConstraints tighten({double? width, double? height}) {
    final double w =
        width == null ? minWidth : _clamp(width, minWidth, maxWidth);
    final double h =
        height == null ? minHeight : _clamp(height, minHeight, maxHeight);
    return BoxConstraints(
      minWidth: w,
      maxWidth: width == null ? maxWidth : w,
      minHeight: h,
      maxHeight: height == null ? maxHeight : h,
    );
  }

  /// The space left for a child after [insets] are removed.
  ///
  /// Clamped at zero, and the maxima are never allowed below the deflated
  /// minima, so padding wider than the box yields a satisfiable
  /// zero-or-smallest constraint rather than an unsatisfiable one. An
  /// unbounded axis stays unbounded: `infinity - 8` is still infinity.
  BoxConstraints deflate(EdgeInsets insets) {
    final double horizontal = insets.horizontal;
    final double vertical = insets.vertical;
    final double deflatedMinWidth = math.max(0.0, minWidth - horizontal);
    final double deflatedMinHeight = math.max(0.0, minHeight - vertical);
    return BoxConstraints(
      minWidth: deflatedMinWidth,
      maxWidth: math.max(deflatedMinWidth, maxWidth - horizontal),
      minHeight: deflatedMinHeight,
      maxHeight: math.max(deflatedMinHeight, maxHeight - vertical),
    );
  }

  BoxConstraints copyWith({
    double? minWidth,
    double? maxWidth,
    double? minHeight,
    double? maxHeight,
  }) =>
      BoxConstraints(
        minWidth: minWidth ?? this.minWidth,
        maxWidth: maxWidth ?? this.maxWidth,
        minHeight: minHeight ?? this.minHeight,
        maxHeight: maxHeight ?? this.maxHeight,
      );

  static double _clamp(double value, double low, double high) =>
      value < low ? low : (value > high ? high : value);

  static void _validate(
    String axis,
    String minName,
    double min,
    String maxName,
    double max,
  ) {
    if (min.isNaN || max.isNaN) {
      throw ArgumentError(
        'BoxConstraints has a NaN $axis axis: $minName is $min and $maxName '
        'is $max. NaN propagates through every size derived from it, so the '
        'box that finally looks wrong will be nowhere near the division that '
        'produced this.',
      );
    }
    if (min < 0.0) {
      throw ArgumentError(
        'BoxConstraints has a negative $axis axis: $minName is $min. A '
        'negative minimum cannot be satisfied by any size.',
      );
    }
    if (min > max) {
      throw ArgumentError(
        'BoxConstraints has an unsatisfiable $axis axis: $minName ($min) is '
        'greater than $maxName ($max). No size satisfies this, so it was '
        'built by arithmetic that went wrong rather than by a layout that '
        'meant it.',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BoxConstraints &&
      other.minWidth == minWidth &&
      other.maxWidth == maxWidth &&
      other.minHeight == minHeight &&
      other.maxHeight == maxHeight;

  @override
  int get hashCode => Object.hash(minWidth, maxWidth, minHeight, maxHeight);

  @override
  String toString() => 'BoxConstraints(w: $minWidth..$maxWidth, '
      'h: $minHeight..$maxHeight)';
}
