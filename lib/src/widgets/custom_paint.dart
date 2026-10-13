/// Drawing of your own: Flutter's `CustomPaint` with a [CustomPainter], and
/// the framework's original form, a [BoxPainter] closure over the display
/// list.
library;

import '../foundation/change_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/canvas.dart';
import '../layout/custom_painter.dart';
import '../layout/pipeline.dart';
import '../layout/render_box.dart';
import '../layout/render_proxy_box.dart' show RenderProxyBox;
import 'element.dart';
import 'widget.dart';

/// Draws into a [DisplayList] in the box's own coordinates - the framework's
/// original painter, still accepted by [CustomPaint.painter].
typedef BoxPainter = void Function(DisplayList list, Size size);

/// A widget that paints with [painter] behind its child and
/// [foregroundPainter] in front of it - Flutter's `CustomPaint`.
///
/// [painter] and [foregroundPainter] are each a [CustomPainter] (Flutter's
/// contract: `paint(Canvas, Size)`, `shouldRepaint`, a `repaint` listenable,
/// `hitTest`) or a [BoxPainter] closure. The parameter is typed `Object?` so
/// both compile; anything else is an [ArgumentError] when the widget is
/// built.
///
/// Sizing is Flutter's: with a [child] the box is the child's size; without
/// one it is [size] constrained by the parent.
///
/// A [CustomPainter] repaints when the new widget's painter answers
/// [CustomPainter.shouldRepaint] true (or is of another type), and on every
/// notification of its `repaint` listenable. A [BoxPainter] closure repaints
/// on every rebuild, because two closures cannot be compared.
///
/// `isComplex` and `willChange` are accepted and ignored: there is no raster
/// cache to advise. Semantics from a painter are not supported.
final class CustomPaint extends SingleChildRenderObjectWidget {
  const CustomPaint({
    super.key,
    this.painter,
    this.foregroundPainter,
    this.size = Size.zero,
    this.isComplex = false,
    this.willChange = false,
    super.child,
  });

  /// Painted before the child: a [CustomPainter] or a [BoxPainter].
  final Object? painter;

  /// Painted after the child: a [CustomPainter] or a [BoxPainter].
  final Object? foregroundPainter;

  /// The size to ask for when there is no child.
  final Size size;

  final bool isComplex;

  final bool willChange;

  @override
  RenderCustomPaint createRenderObject(BuildContext context) =>
      RenderCustomPaint(
        painter: painter,
        foregroundPainter: foregroundPainter,
        preferredSize: size,
        isComplex: isComplex,
        willChange: willChange,
      );

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderCustomPaint renderObject) {
    renderObject
      ..painter = painter
      ..foregroundPainter = foregroundPainter
      ..preferredSize = size
      ..isComplex = isComplex
      ..willChange = willChange;
  }
}

/// The render node behind [CustomPaint] - Flutter's `RenderCustomPaint`.
final class RenderCustomPaint extends RenderProxyBox {
  RenderCustomPaint({
    Object? painter,
    Object? foregroundPainter,
    Size preferredSize = Size.zero,
    this.isComplex = false,
    this.willChange = false,
    super.child,
  })  : _painter = _checked(painter, 'painter'),
        _foregroundPainter = _checked(foregroundPainter, 'foregroundPainter'),
        _preferredSize = preferredSize;

  Object? _painter;
  Object? _foregroundPainter;
  Size _preferredSize;

  bool isComplex;

  bool willChange;

  static Object? _checked(Object? value, String name) {
    if (value == null || value is CustomPainter || value is BoxPainter) {
      return value;
    }
    throw ArgumentError.value(value, name,
        'must be a CustomPainter or a BoxPainter (DisplayList, Size) closure');
  }

  /// The background painter: a [CustomPainter], a [BoxPainter] or null.
  Object? get painter => _painter;

  set painter(Object? value) {
    final Object? old = _painter;
    if (identical(old, value)) return;
    _painter = _checked(value, 'painter');
    _didUpdate(old, value);
  }

  /// The foreground painter: a [CustomPainter], a [BoxPainter] or null.
  Object? get foregroundPainter => _foregroundPainter;

  set foregroundPainter(Object? value) {
    final Object? old = _foregroundPainter;
    if (identical(old, value)) return;
    _foregroundPainter = _checked(value, 'foregroundPainter');
    _didUpdate(old, value);
  }

  void _didUpdate(Object? old, Object? value) {
    if (value is CustomPainter &&
        old is CustomPainter &&
        value.runtimeType == old.runtimeType &&
        !value.shouldRepaint(old)) {
      // Same picture; only the repaint subscription may have changed.
    } else {
      markNeedsPaint();
    }
    if (owner != null) {
      if (old is Listenable) old.removeListener(markNeedsPaint);
      if (value is Listenable) value.addListener(markNeedsPaint);
    }
  }

  /// The size asked for when there is no child.
  Size get preferredSize => _preferredSize;

  set preferredSize(Size value) {
    if (value == _preferredSize) return;
    _preferredSize = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    final Object? p = _painter;
    final Object? f = _foregroundPainter;
    if (p is Listenable) p.addListener(markNeedsPaint);
    if (f is Listenable) f.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    final Object? p = _painter;
    final Object? f = _foregroundPainter;
    if (p is Listenable) p.removeListener(markNeedsPaint);
    if (f is Listenable) f.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child != null) {
      super.performLayout();
      return;
    }
    size = constraints.constrain(_preferredSize);
  }

  @override
  double computeMinIntrinsicWidth(double height) => child == null
      ? _preferredSize.width
      : super.computeMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) => child == null
      ? _preferredSize.width
      : super.computeMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => child == null
      ? _preferredSize.height
      : super.computeMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => child == null
      ? _preferredSize.height
      : super.computeMaxIntrinsicHeight(width);

  /// Flutter's rule: a foreground painter that claims the point takes it,
  /// then the child, then a background [CustomPainter] (which claims the
  /// whole box unless its [CustomPainter.hitTest] says otherwise). A
  /// [BoxPainter] closure claims nothing, as the original node did.
  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    final Object? f = _foregroundPainter;
    if (f is CustomPainter && (f.hitTest(position) ?? false)) return this;
    return super.hitTestChildren(position, path: path);
  }

  @override
  bool hitTestSelf(Offset position) {
    final Object? p = _painter;
    return p is CustomPainter && (p.hitTest(position) ?? true);
  }

  void _paintWith(Object? painter, DisplayList list, Offset offset) {
    if (painter == null) return;
    if (painter is CustomPainter) {
      final Canvas canvas = Canvas.forDisplayList(list);
      if (offset != Offset.zero) canvas.translate(offset.dx, offset.dy);
      painter.paint(canvas, size);
      canvas.close();
      return;
    }
    final BoxPainter boxPainter = painter as BoxPainter;
    list
      ..save()
      ..transform(1, 0, 0, 1, offset.dx, offset.dy);
    boxPainter(list, size);
    list.restore();
  }

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty && child == null) return;
    _paintWith(_painter, list, offset);
    super.paint(list, offset);
    _paintWith(_foregroundPainter, list, offset);
  }
}
