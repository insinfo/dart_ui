/// [CustomPainter] and [CustomClipper]: the delegates a Flutter app hands to
/// `CustomPaint` and to the clip widgets.
///
/// Both are Flutter's contracts unchanged - `paint(Canvas, Size)`,
/// `shouldRepaint`, a `repaint`/`reclip` [Listenable], `hitTest`,
/// `getClip(Size)`, `shouldReclip` - so a painter or clipper written for
/// Flutter compiles and behaves the same. The only spelling difference is
/// that they `implement` [Listenable] rather than extend it, because this
/// framework's [Listenable] is an interface; a subclass written as
/// `extends CustomPainter` with `super(repaint: ...)` is unaffected.
library;

import '../foundation/change_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import 'canvas.dart';

/// The interface `CustomPaint` uses to paint - Flutter's `CustomPainter`.
///
/// [paint] receives a [Canvas] whose origin is the box's top-left corner and
/// the box's [Size]. The canvas is a facade over the display list; see
/// `canvas.dart` for what it can and cannot draw.
///
/// The painter is asked to repaint when the widget is rebuilt with a painter
/// for which [shouldRepaint] answers true, and whenever [repaint] notifies -
/// an animation passed as `repaint` repaints every tick without a rebuild.
///
/// Semantics (`semanticsBuilder`) are not supported: the framework's
/// semantic tree describes render objects, not painted shapes.
abstract class CustomPainter implements Listenable {
  /// [repaint], when given, triggers a repaint every time it notifies.
  const CustomPainter({Listenable? repaint}) : _repaint = repaint;

  final Listenable? _repaint;

  @override
  void addListener(void Function() listener) => _repaint?.addListener(listener);

  @override
  void removeListener(void Function() listener) =>
      _repaint?.removeListener(listener);

  /// Paints into [canvas], within `Offset.zero` to [size].
  ///
  /// Drawing outside that area is not clipped (as in Flutter); wrap the
  /// painter in a `ClipRect` for that.
  void paint(Canvas canvas, Size size);

  /// Whether a new instance of the painter draws differently from
  /// [oldDelegate]. Called only when the painter instance changed and the two
  /// have the same runtime type.
  bool shouldRepaint(covariant CustomPainter oldDelegate);

  /// Whether [position] (local coordinates) hits what this painter drew.
  ///
  /// Null, the default, means "the whole box" for a background painter and
  /// "nothing" for a foreground painter - Flutter's rule.
  bool? hitTest(Offset position) => null;

  @override
  String toString() => '$runtimeType';
}

/// An interface for computing a clip - Flutter's `CustomClipper`.
///
/// [T] is [Rect] for `ClipRect` and `ClipOval`, `RRect` for `ClipRRect` and
/// `Path` for `ClipPath`.
abstract class CustomClipper<T> implements Listenable {
  /// [reclip], when given, recomputes the clip every time it notifies.
  const CustomClipper({Listenable? reclip}) : _reclip = reclip;

  final Listenable? _reclip;

  @override
  void addListener(void Function() listener) => _reclip?.addListener(listener);

  @override
  void removeListener(void Function() listener) =>
      _reclip?.removeListener(listener);

  /// The clip, for a box of [size].
  T getClip(Size size);

  /// A rectangle that contains the clip; used for culling. The whole box by
  /// default.
  Rect getApproximateClipRect(Size size) =>
      Rect.fromLTWH(0, 0, size.width, size.height);

  /// Whether a new instance of the clipper clips differently from
  /// [oldClipper].
  bool shouldReclip(covariant CustomClipper<T> oldClipper);

  @override
  String toString() => '$runtimeType';
}
