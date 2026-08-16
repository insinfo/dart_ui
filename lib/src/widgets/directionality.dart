/// The reading direction, published to a subtree.
///
/// The text engine has had a complete UAX#9 implementation for a while - see
/// `src/text/bidi.dart` and its conformance run against the UCD - so a
/// paragraph of Arabic has always come out in the right visual order. The
/// *layout* around it did not: a row put its first child on the left in every
/// locale, padding had a `left` and no `start`, and nothing mirrored. The
/// framework spoke Arabic and drew a left-to-right user interface around it.
///
/// This file is the value that closes that gap. It carries no policy of its
/// own beyond publication and scoping; what `start` means is decided by
/// `EdgeInsetsDirectional`, `AlignmentDirectional` and `RenderFlex`, each of
/// which takes a [TextDirection] and resolves it into physical coordinates.
///
/// The enum itself is `TextDirection` from `src/text/shaper.dart`, reused
/// rather than redeclared. A widget-layer copy would have to be converted at
/// every boundary where layout meets text, and a conversion function between
/// two identical two-valued enums is a bug generator with no upside.
library;

import '../geometry/transform2d.dart';
import '../text/shaper.dart' show TextDirection;
import 'widget.dart';

/// Thrown by [Directionality.of] when no [Directionality] is in scope.
///
/// See the note on [Directionality.of] for why this is an error rather than a
/// silent left-to-right default.
final class MissingDirectionalityError extends Error {
  MissingDirectionalityError(this.requestedBy);

  /// The widget type that asked, so the message names something the reader can
  /// find in their own code rather than only the framework's.
  final String requestedBy;

  @override
  String toString() => 'No Directionality ancestor found for $requestedBy.\n'
      'Something in this subtree resolves a logical start/end edge, and there '
      'is no reading direction in scope to resolve it against.\n'
      'Wrap the subtree - usually the whole application - in a Directionality:\n'
      '\n'
      '  Directionality(\n'
      '    textDirection: TextDirection.leftToRight,\n'
      '    child: ...,\n'
      '  )\n'
      '\n'
      'If this location genuinely has no locale, call Directionality.maybeOf '
      'and pick a fallback explicitly.';
}

/// Publishes a [TextDirection] to everything below it.
///
/// Scoping is per node, not global. A [Directionality] nested inside another
/// shadows it for its own subtree and only for its own subtree, which is what
/// makes a left-to-right code block inside a right-to-left document - or a
/// right-to-left name inside a left-to-right form - expressible at all.
final class Directionality extends InheritedWidget {
  const Directionality({
    super.key,
    required this.textDirection,
    required super.child,
  });

  final TextDirection textDirection;

  /// The reading direction in scope at [context], or a thrown
  /// [MissingDirectionalityError].
  ///
  /// ## Why this throws instead of defaulting to left-to-right
  ///
  /// A silent default is invisible in exactly the case that produces it. The
  /// author who forgets to install a [Directionality] is, essentially always,
  /// working in a left-to-right locale - so a left-to-right fallback looks
  /// perfect on their machine, in their screenshots and in their tests. The
  /// bug ships, and it surfaces as a mirrored-wrong interface for the users
  /// least able to file a report the author can read. The cost is paid by
  /// somebody who is not in the room.
  ///
  /// Throwing moves that cost to the first frame the author renders. It is
  /// loud, it happens once, and the fix is one widget at the root. The failure
  /// also names the asking widget: "no Directionality" with no location is the
  /// kind of message that gets worked around by adding a default somewhere.
  ///
  /// The escape hatch is [maybeOf], and the difference between the two is the
  /// whole point: `Directionality.maybeOf(context) ?? TextDirection.leftToRight`
  /// is exactly as lenient as a silent default, but it is *written down* in
  /// the file that chose it, where a reviewer can see it and a right-to-left
  /// user's bug report can be traced to it.
  ///
  /// Note that the render tree deliberately does **not** follow this rule:
  /// `RenderFlex.textDirection` is nullable and null lays out left-to-right.
  /// A render object is assembled by tests and tools that have no locale and
  /// no widget path to name; the decision belongs where the decision is made,
  /// which is here.
  static TextDirection of(BuildContext context) {
    final Directionality? scope =
        context.dependOnInheritedWidgetOfExactType<Directionality>();
    if (scope == null) {
      throw MissingDirectionalityError('${context.widget.runtimeType}');
    }
    return scope.textDirection;
  }

  /// The reading direction in scope at [context], or null.
  ///
  /// For callers that have a defensible fallback and want to state it. Creates
  /// the same dependency [of] does, so a later direction change still rebuilds
  /// the caller.
  static TextDirection? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<Directionality>()
      ?.textDirection;

  /// Whether a drawable that opted into [matchTextDirection] must be painted
  /// mirrored at [context].
  ///
  /// The hook a directional icon uses. See [mirrorsInDirection] for the pure
  /// form and for what "directional" means here.
  ///
  /// Reads the direction through [of], so a widget that asked to follow the
  /// reading direction and was given no reading direction fails rather than
  /// quietly not mirroring. When [matchTextDirection] is false nothing is read
  /// at all and no dependency is created: an icon that is not directional does
  /// not need a locale and must not be forced to have one.
  static bool mirrors(
    BuildContext context, {
    required bool matchTextDirection,
  }) =>
      matchTextDirection && of(context).isRightToLeft;

  @override
  bool updateShouldNotify(Directionality oldWidget) =>
      textDirection != oldWidget.textDirection;
}

/// Whether a drawable marked `matchTextDirection` is mirrored under
/// [direction].
///
/// This is the whole mechanism, and it is a boolean on purpose: mirroring is
/// opt-in per drawable, because most glyphs must **not** flip. An arrow, a
/// "send", an undo curl, a media next-track and a directional chevron all mean
/// the opposite thing when reflected, and those are the ones that want it. A
/// magnifier, a camera, a checkmark, a logo, a clock and anything containing
/// text or a digit look wrong or nonsensical mirrored, and those keep their
/// shape in every locale. There is no way to tell the two apart from the
/// artwork, so the flag is data the icon carries, not something inferred.
///
/// Kept as a free function so a render object - which has no [BuildContext] -
/// can resolve the same rule from the [TextDirection] it was handed.
bool mirrorsInDirection(
  TextDirection direction, {
  required bool matchTextDirection,
}) =>
    matchTextDirection && direction.isRightToLeft;

/// The transform that reflects a [width]-wide box about its own vertical
/// centre, leaving it in the same place.
///
/// Push this, paint the drawable at its normal offsets, pop. The reflection is
/// about the box rather than about the origin precisely so the caller does not
/// have to compensate with a translation it can get wrong by a pixel: a box at
/// x in `0..width` maps back onto `0..width`.
///
/// Provided because the alternative - every directional drawable writing
/// `Transform2D(-1, 0, 0, 1, width, 0)` inline - is four opportunities to get
/// a sign wrong, repeated once per icon.
Transform2D horizontalMirror(double width) =>
    Transform2D(-1, 0, 0, 1, width, 0);
