/// Flutter-compatible linear and circular progress indicators.
library;

import 'dart:math' as math;

import '../animation/animation.dart';
import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_opcodes.dart' show paintStyleStroke;
import '../layout/render_box.dart';
import '../semantics/semantics.dart';
import 'animation_scope.dart';
import 'element.dart';
import 'theme.dart';
import 'widget.dart';

final class LinearProgressIndicator extends StatelessWidget {
  const LinearProgressIndicator({
    super.key,
    this.value,
    this.backgroundColor,
    this.color,
    this.minHeight = 4,
    this.semanticsLabel,
    this.semanticsValue,
  }) : assert(value == null || (value >= 0 && value <= 1));

  final double? value;
  final Color? backgroundColor;
  final Color? color;
  final double minHeight;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return _ProgressRenderWidget(
      value: value,
      circular: false,
      extent: minHeight,
      strokeWidth: minHeight,
      color: color ??
          theme.progressIndicatorTheme.color ??
          theme.colorScheme.primary,
      trackColor: backgroundColor ??
          theme.progressIndicatorTheme.linearTrackColor ??
          theme.disabledSurface,
      semanticsLabel: semanticsLabel,
      semanticsValue: semanticsValue,
    );
  }
}

final class CircularProgressIndicator extends StatefulWidget {
  const CircularProgressIndicator({
    super.key,
    this.value,
    this.backgroundColor,
    this.color,
    this.strokeWidth = 4,
    this.size = 36,
    this.semanticsLabel,
    this.semanticsValue,
  })  : assert(value == null || (value >= 0 && value <= 1)),
        assert(strokeWidth > 0),
        assert(size > 0);

  final double? value;
  final Color? backgroundColor;
  final Color? color;
  final double strokeWidth;
  final double size;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  State<CircularProgressIndicator> createState() =>
      _CircularProgressIndicatorState();
}

final class _CircularProgressIndicatorState
    extends State<CircularProgressIndicator> {
  AnimationController? _animation;

  @override
  void didUpdateWidget(CircularProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != null && oldWidget.value == null) {
      _animation?.dispose();
      _animation = null;
    }
  }

  void _ensureAnimation(BuildContext context) {
    if (widget.value != null || _animation != null) return;
    final clock = AnimationScope.maybeOf(context);
    if (clock == null) return;
    _animation = AnimationController(
      clock: clock,
      duration: const Duration(milliseconds: 1100),
    )
      ..addListener(_tick)
      ..repeat();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _animation?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ensureAnimation(context);
    final ThemeData theme = Theme.of(context);
    return _ProgressRenderWidget(
      value: widget.value,
      animationValue: _animation?.value ?? 0,
      circular: true,
      extent: widget.size,
      strokeWidth: widget.strokeWidth,
      color: widget.color ??
          theme.progressIndicatorTheme.color ??
          theme.colorScheme.primary,
      trackColor: widget.backgroundColor ??
          theme.progressIndicatorTheme.circularTrackColor ??
          theme.disabledSurface,
      semanticsLabel: widget.semanticsLabel,
      semanticsValue: widget.semanticsValue,
    );
  }
}

/// Compact convenience spelling for an indeterminate circular indicator.
final class LoadingSpinner extends CircularProgressIndicator {
  const LoadingSpinner({
    super.key,
    super.color,
    super.backgroundColor,
    super.strokeWidth,
    super.size,
    super.semanticsLabel,
  });
}

final class _ProgressRenderWidget extends RenderObjectWidget {
  const _ProgressRenderWidget({
    required this.value,
    this.animationValue = 0,
    required this.circular,
    required this.extent,
    required this.strokeWidth,
    required this.color,
    required this.trackColor,
    required this.semanticsLabel,
    required this.semanticsValue,
  });

  final double? value;
  final double animationValue;
  final bool circular;
  final double extent;
  final double strokeWidth;
  final Color color;
  final Color trackColor;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderProgressIndicator createRenderObject(BuildContext context) =>
      RenderProgressIndicator()
        ..value = value
        ..animationValue = animationValue
        ..circular = circular
        ..extent = extent
        ..strokeWidth = strokeWidth
        ..color = color
        ..trackColor = trackColor
        ..semanticsLabel = semanticsLabel
        ..semanticsValue = semanticsValue;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProgressIndicator object,
  ) {
    object
      ..value = value
      ..animationValue = animationValue
      ..circular = circular
      ..extent = extent
      ..strokeWidth = strokeWidth
      ..color = color
      ..trackColor = trackColor
      ..semanticsLabel = semanticsLabel
      ..semanticsValue = semanticsValue;
  }
}

final class RenderProgressIndicator extends RenderBox
    implements SemanticsProvider {
  double? value;
  double animationValue = 0;
  bool circular = false;
  double extent = 4;
  double strokeWidth = 4;
  Color color = const Color(0xFF2563EB);
  Color trackColor = const Color(0xFFE2E8F0);
  String? semanticsLabel;
  String? semanticsValue;

  @override
  void performLayout() {
    size = constraints.constrain(
      circular ? Size(extent, extent) : Size(140, extent),
    );
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    if (!circular) {
      _paintLinear(list, offset);
      return;
    }
    final double radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    if (radius <= 0) return;
    final Offset center = Offset(
      offset.dx + size.width / 2,
      offset.dy + size.height / 2,
    );
    _drawArc(list, center, radius, -math.pi / 2, math.pi * 2, trackColor);
    final double start = value == null
        ? -math.pi / 2 + animationValue * math.pi * 2
        : -math.pi / 2;
    final double sweep = value == null ? math.pi * 1.45 : math.pi * 2 * value!;
    if (sweep > 0) _drawArc(list, center, radius, start, sweep, color);
  }

  void _paintLinear(DisplayList list, Offset offset) {
    final Rect track =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final double radius = size.height / 2;
    list.drawRRectUniform(
      track.left,
      track.top,
      track.right,
      track.bottom,
      radius,
      radius,
      list.addPaint(colorArgb: trackColor.value, antiAlias: true),
    );
    final double fraction = value ?? animationValue;
    final double width = size.width * fraction.clamp(0.0, 1.0);
    if (width <= 0) return;
    final Rect fill = Rect.fromLTWH(track.left, track.top, width, track.height);
    final double fillRadius = math.min(radius, width / 2);
    list.drawRRectUniform(
      fill.left,
      fill.top,
      fill.right,
      fill.bottom,
      fillRadius,
      fillRadius,
      list.addPaint(colorArgb: color.value, antiAlias: true),
    );
  }

  void _drawArc(
    DisplayList list,
    Offset center,
    double radius,
    double start,
    double sweep,
    Color arcColor,
  ) {
    final int segments = math.max(8, (48 * sweep.abs() / (math.pi * 2)).ceil());
    final PathBuilder builder = PathBuilder();
    for (var index = 0; index <= segments; index++) {
      final double angle = start + sweep * index / segments;
      final double x = center.dx + math.cos(angle) * radius;
      final double y = center.dy + math.sin(angle) * radius;
      if (index == 0) {
        builder.moveTo(x, y);
      } else {
        builder.lineTo(x, y);
      }
    }
    final int paint = list.addPaint(
      colorArgb: arcColor.value,
      style: paintStyleStroke,
      strokeWidth: strokeWidth,
      antiAlias: true,
    );
    list.drawPath(list.addPath(builder.build()), paint);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.progressBar,
        label: semanticsLabel,
        value: semanticsValue ??
            (value == null ? null : '${(value! * 100).round()}%'),
      );
}
