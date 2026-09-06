/// A rectangle described by how far each of its edges is inset from the edges
/// of some container, rather than by absolute coordinates.
///
/// The distinction is the whole point, and it is easy to miss because both
/// shapes carry four doubles. A [Rect] names *where something is*; a
/// [RelativeRect] names *how it relates to whatever it sits in* - so the same
/// value describes a sensible position in a 300x200 window and in a 1920x1080
/// one, and neither has to be recomputed when the container resizes. That is
/// why `showMenu(position:)` takes one: a menu is asked for against the window
/// it will open into, and the caller frequently does not know that window's
/// size at the moment it asks.
///
/// The sign convention follows Flutter's exactly, because this type exists so
/// that Flutter code compiles here unchanged, and a flipped sign would be a
/// silent misplacement rather than a compile error: [left] and [top] grow
/// *rightwards and downwards* from the container's corresponding edges, while
/// [right] and [bottom] grow *leftwards and upwards* from theirs. All four
/// therefore read as "inset towards the middle", and all four may be negative,
/// which is how a rectangle that pokes out of its container is expressed.
///
/// ## Layering
///
/// This file may import geometry and nothing else - see
/// `test/architecture/layering_test.dart`, which asserts the rule over the
/// sources rather than trusting it as a convention. It is what keeps
/// `showMenu`'s argument type usable by code that has never heard of a widget.
library;

import 'dart:math' as math;

import 'offset.dart';
import 'rect.dart';
import 'size.dart';

final class RelativeRect {
  /// The four insets, in the order every other rectangle in this framework
  /// uses.
  const RelativeRect.fromLTRB(this.left, this.top, this.right, this.bottom);

  /// [rect] expressed against a container that starts at the origin.
  ///
  /// The common case: [rect] is already in the container's own coordinate
  /// space - which for a window is the space `RenderBox.localToGlobal`
  /// produces - and only the size of the container is needed to turn the far
  /// edges into insets.
  RelativeRect.fromSize(Rect rect, Size container)
      : left = rect.left,
        top = rect.top,
        right = container.width - rect.right,
        bottom = container.height - rect.bottom;

  /// [rect] expressed against [container], both in one shared outer space.
  ///
  /// Unlike [RelativeRect.fromSize] this subtracts the container's own origin,
  /// so a rect whose top-left is at 0,0 inside a container whose top-left is at
  /// 100,100 comes out at -100,-100. Passing a rect that is *already* in the
  /// container's space to this constructor is the classic double-subtraction
  /// bug; use [RelativeRect.fromSize] there.
  RelativeRect.fromRect(Rect rect, Rect container)
      : left = rect.left - container.left,
        top = rect.top - container.top,
        right = container.right - rect.right,
        bottom = container.bottom - rect.bottom;

  /// The whole container: every inset zero.
  static const RelativeRect fill = RelativeRect.fromLTRB(0, 0, 0, 0);

  /// How far the left edge sits to the right of the container's left edge.
  final double left;

  /// How far the top edge sits below the container's top edge.
  final double top;

  /// How far the right edge sits to the *left* of the container's right edge.
  final double right;

  /// How far the bottom edge sits *above* the container's bottom edge.
  final double bottom;

  /// Whether any edge is inset towards the middle at all.
  bool get hasInsets => left > 0 || top > 0 || right > 0 || bottom > 0;

  /// This rectangle moved by [offset].
  ///
  /// The far insets are *subtracted* rather than added, which is the sign
  /// convention doing its job: moving the rectangle right by 10 puts its right
  /// edge 10 closer to the container's right edge, so the inset shrinks. An
  /// implementation that added all four would inflate the rectangle instead of
  /// moving it, and the bug only shows up once the container is not square.
  RelativeRect shift(Offset offset) => RelativeRect.fromLTRB(
        left + offset.dx,
        top + offset.dy,
        right - offset.dx,
        bottom - offset.dy,
      );

  /// This rectangle with every edge pushed [delta] outwards.
  RelativeRect inflate(double delta) => RelativeRect.fromLTRB(
      left - delta, top - delta, right - delta, bottom - delta);

  /// This rectangle with every edge pulled [delta] inwards.
  RelativeRect deflate(double delta) => inflate(-delta);

  /// The overlap of the two, as the largest inset on each side.
  ///
  /// `max` on all four, not `min` on two of them: because every inset points
  /// inwards, the *tighter* rectangle is the one with the larger number on
  /// every side, so one rule covers all four edges. The result may be
  /// degenerate when the two do not overlap - the insets then sum past the
  /// container - and that is left to the caller rather than normalized here,
  /// so that a caller who wanted to detect it still can.
  RelativeRect intersect(RelativeRect other) => RelativeRect.fromLTRB(
        math.max(left, other.left),
        math.max(top, other.top),
        math.max(right, other.right),
        math.max(bottom, other.bottom),
      );

  /// This rectangle as absolute coordinates inside [container].
  ///
  /// Uses [container]'s width and height rather than its right and bottom
  /// edges, matching Flutter: the result is in the container's *own* space,
  /// where its top-left is the origin. Handing this a container that is not at
  /// the origin and expecting an outer-space rect back is the mirror of the
  /// [RelativeRect.fromRect] mistake.
  Rect toRect(Rect container) => Rect.fromLTRB(
        left,
        top,
        container.width - right,
        container.height - bottom,
      );

  /// Just the extent, for a container of the given size.
  Size toSize(Size container) =>
      Size(container.width - left - right, container.height - top - bottom);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelativeRect &&
          other.left == left &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'RelativeRect.fromLTRB(${left.toStringAsFixed(1)}, '
      '${top.toStringAsFixed(1)}, ${right.toStringAsFixed(1)}, '
      '${bottom.toStringAsFixed(1)})';
}
