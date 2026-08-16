/// The layout failures that get a name instead of a hang.
///
/// Section 25.7 asks layout to *detect* four things - a circular parent/child
/// dependency, an invalid infinite measure, a property changed during arrange,
/// and an excessive number of passes - and to "emitir árvore reduzida de
/// diagnóstico". This file is the vocabulary for that.
///
/// Why named types rather than `StateError` with a good message: these are the
/// failures a test wants to assert on precisely, by type rather than by
/// matching words in a message, and the ones a development overlay wants to
/// render specially. A message is for a human reading a log; a type is for the
/// code that has to
/// tell this failure from the twenty other `StateError`s the render tree
/// throws. They extend [Error] rather than [Exception] because none of them is
/// recoverable - every one is a bug in a `performLayout`, not a condition the
/// application can handle and continue from.
library;

import '../geometry/size.dart';
import 'render_box.dart';

/// Base class for the layout protocol violations section 25.7 names.
sealed class LayoutError extends Error {
  LayoutError(this.message);

  /// What went wrong, in prose, already naming the node.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Layout was asked to run again and again without converging.
///
/// Raised by the pipeline once the dirty list has refilled more times than any
/// legitimate cascade needs. The usual cause is one `performLayout` dirtying a
/// node that dirties it back.
final class LayoutCycleError extends LayoutError {
  LayoutCycleError({
    required this.passes,
    required this.suspects,
    required String diagnosticTree,
  })  : _diagnosticTree = diagnosticTree,
        super(
          'layout did not settle after $passes passes. A node is marking '
          'another node dirty from inside performLayout, and the two are '
          'dirtying each other; layout cannot converge.\n$diagnosticTree',
        );

  /// How many times the dirty list refilled before this was raised.
  final int passes;

  /// The nodes that were re-laid-out the most, worst first.
  ///
  /// Not "the cycle" - proving which edge closes it would need the dependency
  /// graph, which nothing records. These are the nodes that kept coming back,
  /// which in practice is the same set.
  final List<RenderBox> suspects;

  final String _diagnosticTree;

  /// The reduced tree: the ancestor chain of each suspect, and nothing else.
  ///
  /// Reduced on purpose. A render tree that fails this check is usually a whole
  /// application, and dumping it buries the two nodes that matter under a
  /// thousand that do not.
  String get diagnosticTree => _diagnosticTree;
}

/// A node reported a size with an infinite extent.
///
/// Legal against an unbounded constraint and wrong every time: infinity is not
/// a size anything can paint, hit test or store, and it poisons every
/// arithmetic it reaches. The fix is at the node, which must decide what "as
/// large as possible" means when there is no largest - usually
/// `BoxConstraints.largestFinite`.
final class InfiniteMeasureError extends LayoutError {
  InfiniteMeasureError(this.node, this.reported)
      : super(
          '${node.runtimeType} sized itself $reported. An infinite extent '
          'satisfies an unbounded constraint but is not a size: nothing can '
          'paint it, hit test it or store it, and every ancestor that adds to '
          'it becomes infinite too. Decide what "as large as possible" means '
          'here - BoxConstraints.largestFinite is usually it.',
        );

  final RenderBox node;
  final Size reported;
}

/// A [RenderBox.layout] call was made from inside an intrinsic query.
///
/// An intrinsic is a measurement. Laying a child out during one would leave it
/// holding geometry computed from a constraint no parent ever chose, and that
/// geometry would then be painted.
final class LayoutDuringIntrinsicError extends LayoutError {
  LayoutDuringIntrinsicError(this.node)
      : super(
          'layout() was called on a ${node.runtimeType} from inside an '
          'intrinsic measurement. An intrinsic query answers "how big does '
          'your content want to be"; it must not size or position anything, '
          'because the constraint it would have to invent is not one any '
          'parent chose. A node that cannot answer without laying out should '
          'return a documented approximation and say so in its doc comment.',
        );

  final RenderBox node;
}

/// An intrinsic query returned something that is not an extent.
final class InvalidIntrinsicError extends LayoutError {
  InvalidIntrinsicError(
    this.node,
    this.dimension,
    this.argument,
    this.returned,
  ) : super(
          '${node.runtimeType}.compute${_capitalize(dimension)}($argument) '
          'returned $returned. An intrinsic must be a finite, non-negative '
          'extent: it is summed, compared and divided by every layout above '
          'it, and infinity or a negative there is indistinguishable from a '
          'legitimate answer until a box disappears several frames later.',
        );

  final RenderBox node;

  /// Which of the four questions was asked, as `minWidth`, `maxHeight`, ...
  final String dimension;

  /// The cross extent the caller passed in.
  final double argument;

  final double returned;

  static String _capitalize(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
}
