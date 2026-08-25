/// The scrollbar: the one part of scrolling the user can see and grab.
///
/// `ScrollPosition.thumb` has described a thumb - a start and an extent, both
/// as fractions of the track - since scrolling was written, and until now
/// nothing drew it. A long form scrolled with no indication of how long it was
/// or where in it the user had got to.
///
/// Two decisions are worth stating, because both are places a scrollbar is
/// usually wrong:
///
///  * **the thumb is a view of the model, not a second model.** Every number
///    painted here comes out of [ScrollPosition.thumb]; this widget adds only
///    a minimum size, because a thumb of half a pixel in a very long document
///    is invisible and therefore ungrabbable. A scrollbar that computed its
///    own fractions would drift from the content it describes the moment the
///    content resized;
///  * **dragging the thumb is not dragging the content.** The thumb travels
///    `track - thumbExtent` pixels while the content travels
///    [ScrollPosition.maxScrollExtent], so a drag is scaled by the ratio
///    between them. Moving the content by the pointer's own delta - the
///    obvious implementation - makes the thumb run away from the pointer in
///    any list longer than its viewport, which is every list that has a
///    scrollbar at all. [RenderScrollbar.dragScale] is that ratio, and it is
///    public so the arithmetic can be asserted rather than eyeballed.
///
/// ## When it is on screen
///
/// [ScrollbarVisibility] is a declared policy rather than a heuristic:
///
///  * [ScrollbarVisibility.always] - visible whenever the content can scroll.
///    The desktop default, and what a form with a mouse wants;
///  * [ScrollbarVisibility.whenScrolling] - invisible until the position
///    moves, then visible for [Scrollbar.fadeDelay] after the last movement,
///    then faded out over [Scrollbar.fadeDuration]. This needs a
///    [UiDispatcher]: fading is a thing that happens *later*, and nothing in
///    this framework may read a clock to find out when. With no dispatcher in
///    scope the policy degrades to [ScrollbarVisibility.always], which is the
///    safe direction to fail - a scrollbar that stayed up is a cosmetic
///    complaint, one that never appeared is a lost feature;
///  * [ScrollbarVisibility.never] - no scrollbar and no hit target, for a
///    surface that scrolls by gesture only.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_opcodes.dart' show paintStyleStroke;
import '../layout/render_box.dart';
import '../layout/render_viewport.dart';
import '../platform/input_events.dart';
import '../scheduler/timer_handle.dart';
import '../scheduler/ui_dispatcher.dart';
import 'basic.dart';
import 'control.dart';
import 'element.dart';
import 'gesture_detector.dart';
import 'pointer_router.dart';
import 'proxy.dart';
import 'semantics.dart';
import 'theme.dart';
import 'widget.dart';

/// When a [Scrollbar] is on screen.
enum ScrollbarVisibility {
  /// Whenever the content is longer than the viewport.
  always,

  /// While the position is moving, and for a moment afterwards.
  whenScrolling,

  /// Never. The scrollbar is not built, so it is not a hit target either.
  never,
}

/// Keeps horizontal and vertical scrollbars anchored to one visible stage.
///
/// The child owns the two scrollable viewports and drives [horizontalPosition]
/// and [verticalPosition]. The tracks are intentionally composed *outside*
/// that child: putting the vertical track inside horizontally scrolling
/// content makes it travel with the canvas and disappear beyond the right
/// edge, while putting the horizontal track inside vertically scrolling
/// content has the symmetric bug.
final class TwoDimensionalScrollbar extends StatelessWidget {
  const TwoDimensionalScrollbar({
    super.key,
    required this.horizontalPosition,
    required this.verticalPosition,
    required this.child,
    this.horizontalVisibility = ScrollbarVisibility.always,
    this.verticalVisibility = ScrollbarVisibility.always,
    this.horizontalThickness,
    this.verticalThickness,
    this.interactive = true,
    this.dispatcher,
  });

  final ScrollPosition horizontalPosition;
  final ScrollPosition verticalPosition;
  final Widget child;
  final ScrollbarVisibility horizontalVisibility;
  final ScrollbarVisibility verticalVisibility;
  final double? horizontalThickness;
  final double? verticalThickness;
  final bool interactive;
  final UiDispatcher? dispatcher;

  @override
  Widget build(BuildContext context) => Scrollbar(
        position: verticalPosition,
        visibility: verticalVisibility,
        thickness: verticalThickness,
        interactive: interactive,
        dispatcher: dispatcher,
        child: Scrollbar(
          position: horizontalPosition,
          visibility: horizontalVisibility,
          thickness: horizontalThickness,
          interactive: interactive,
          dispatcher: dispatcher,
          child: child,
        ),
      );
}

/// Overlays a scrollbar on [child], driven by [position].
///
/// The child is laid out at full size and the bar is painted over it rather
/// than beside it. That is deliberate: insetting the content by the bar's
/// thickness makes the content reflow the instant a list becomes scrollable,
/// which is how a list one item too long ends up flickering between two widths.
final class Scrollbar extends StatefulWidget {
  const Scrollbar({
    super.key,
    required this.position,
    required this.child,
    this.visibility = ScrollbarVisibility.always,
    this.thickness,
    this.minThumbExtent,
    this.interactive = true,
    this.fadeDelay = const Duration(milliseconds: 600),
    this.fadeDuration = const Duration(milliseconds: 200),
    this.dispatcher,
  });

  final ScrollPosition position;
  final Widget child;
  final ScrollbarVisibility visibility;

  /// How wide (or, for a horizontal bar, how tall) the track is.
  final double? thickness;

  /// The smallest thumb that is still worth grabbing.
  final double? minThumbExtent;

  /// Whether the thumb answers the pointer. False makes it an indicator.
  final bool interactive;

  /// How long after the last movement the fade begins.
  final Duration fadeDelay;

  /// How long the fade itself takes.
  final Duration fadeDuration;

  /// Where the fade's timers are armed. Falls back to [GestureScope].
  final UiDispatcher? dispatcher;

  @override
  State<Scrollbar> createState() => _ScrollbarState();
}

final class _ScrollbarState extends State<Scrollbar> {
  /// One step of the fade. Small enough to look continuous, large enough that
  /// a 200 ms fade is a dozen timers rather than a hundred.
  static const Duration _fadeStep = Duration(milliseconds: 16);

  UiDispatcher? _dispatcher;
  TimerHandle? _timer;
  double _opacity = 1.0;
  bool _fading = false;

  @override
  void initState() {
    super.initState();
    // Hidden until something moves, but only under a policy that can ever show
    // it again. The dispatcher is not known until the first build, so the
    // decision is re-taken there.
    _opacity = widget.visibility == ScrollbarVisibility.whenScrolling ? 0 : 1;
    widget.position.addListener(_onScrolled);
  }

  @override
  void didUpdateWidget(Scrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      oldWidget.position.removeListener(_onScrolled);
      widget.position.addListener(_onScrolled);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    widget.position.removeListener(_onScrolled);
    super.dispose();
  }

  /// Whether this scrollbar can fade, which needs both a policy and a clock.
  bool get _canFade =>
      widget.visibility == ScrollbarVisibility.whenScrolling &&
      _dispatcher != null;

  void _onScrolled(ScrollPosition position) {
    if (widget.visibility != ScrollbarVisibility.whenScrolling) return;
    if (!mounted) return;
    _timer?.cancel();
    _timer = null;
    _fading = false;
    final UiDispatcher? dispatcher = _dispatcher;
    if (dispatcher != null) {
      _timer = dispatcher.schedule(widget.fadeDelay, _beginFade);
    }
    if (_opacity == 1.0) return;
    setState(() => _opacity = 1.0);
  }

  void _beginFade() {
    _timer = null;
    if (!mounted) return;
    _fading = true;
    _stepFade();
  }

  void _stepFade() {
    _timer = null;
    if (!mounted || !_fading) return;
    final int total = widget.fadeDuration.inMicroseconds;
    final double delta =
        total <= 0 ? 1.0 : _fadeStep.inMicroseconds / total.toDouble();
    final double next = (_opacity - delta).clamp(0.0, 1.0);
    setState(() => _opacity = next);
    if (next <= 0) {
      _fading = false;
      return;
    }
    _timer = _dispatcher?.schedule(_fadeStep, _stepFade);
  }

  @override
  Widget build(BuildContext context) {
    _dispatcher = widget.dispatcher ?? GestureScope.of(context);
    // A policy that cannot fade shows the bar instead of hiding it forever.
    if (!_canFade && _opacity < 1 && !_fading) _opacity = 1;
    if (widget.visibility == ScrollbarVisibility.never || _opacity <= 0) {
      return widget.child;
    }
    final bool vertical = widget.position.axis == ScrollAxis.vertical;
    final ThemeData theme = Theme.of(context);
    final ScrollbarThemeData scrollbarTheme = theme.scrollbarTheme;
    final double thickness = widget.thickness ?? scrollbarTheme.thickness;
    final double hoveredThickness = math.max(
      thickness,
      scrollbarTheme.hoveredThickness,
    );
    final double hitExtent =
        hoveredThickness + scrollbarTheme.crossAxisMargin * 2;
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned(
          left: vertical ? null : 0,
          right: 0,
          top: vertical ? 0 : null,
          bottom: 0,
          width: vertical ? hitExtent : null,
          height: vertical ? null : hitExtent,
          child: Opacity(
            opacity: _opacity,
            child: _ScrollbarTrack(
              position: widget.position,
              theme: theme,
              thickness: thickness,
              minThumbExtent:
                  widget.minThumbExtent ?? scrollbarTheme.minThumbLength,
              interactive: widget.interactive,
            ),
          ),
        ),
      ],
    );
  }
}

/// The track and thumb alone, with no child: [SingleChildRenderObjectWidget]
/// with the child left null is this framework's leaf render widget.
final class _ScrollbarTrack extends SingleChildRenderObjectWidget {
  const _ScrollbarTrack({
    required this.position,
    required this.theme,
    required this.thickness,
    required this.minThumbExtent,
    required this.interactive,
  });

  final ScrollPosition position;
  final ThemeData theme;
  final double thickness;
  final double minThumbExtent;
  final bool interactive;

  @override
  RenderScrollbar createRenderObject(BuildContext context) => RenderScrollbar(
        position: position,
        thickness: thickness,
        minThumbExtent: minThumbExtent,
        interactive: interactive,
      )..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderScrollbar object,
  ) {
    object
      ..position = position
      ..thickness = thickness
      ..minThumbExtent = minThumbExtent
      ..interactive = interactive
      ..theme = theme;
  }
}

/// Draws the track and the thumb, and lets the pointer move the thumb.
final class RenderScrollbar extends RenderBox
    with ControlBehavior
    implements PointerEventBarrier {
  RenderScrollbar({
    required ScrollPosition position,
    double thickness = 6,
    double minThumbExtent = 16.0,
    bool interactive = true,
  })  : _position = position,
        _thickness = thickness,
        _minThumbExtent = minThumbExtent,
        _interactive = interactive {
    _position.addListener(_onScrolled);
  }

  ScrollPosition _position;
  double _thickness;
  double _minThumbExtent;
  bool _interactive;

  int? _dragPointer;
  double _dragOrigin = 0;
  double _dragStartPixels = 0;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    _position.removeListener(_onScrolled);
    _position = value..addListener(_onScrolled);
    markNeedsPaint();
  }

  double get minThumbExtent => _minThumbExtent;

  double get thickness => _thickness;

  set thickness(double value) {
    if (value == _thickness) return;
    _thickness = value;
    markNeedsPaint();
  }

  set minThumbExtent(double value) {
    if (value == _minThumbExtent) return;
    _minThumbExtent = value;
    markNeedsPaint();
  }

  bool get interactive => _interactive;

  set interactive(bool value) {
    if (value == _interactive) return;
    _interactive = value;
    if (!value) _dragPointer = null;
    markNeedsPaint();
  }

  bool get _vertical => _position.axis == ScrollAxis.vertical;

  /// The length of the track along the scroll axis.
  double get trackExtent =>
      hasSize ? (_vertical ? size.height : size.width) : 0;

  double get buttonExtent {
    final ScrollbarThemeData config = theme.scrollbarTheme;
    if (!config.showButtons) return 0;
    final double available =
        math.max(0, trackExtent - config.mainAxisMargin * 2);
    return math.min(config.buttonExtent, available / 2);
  }

  double get trackMainStart =>
      theme.scrollbarTheme.mainAxisMargin + buttonExtent;

  double get usableTrackExtent => math.max(
        0,
        trackExtent -
            theme.scrollbarTheme.mainAxisMargin * 2 -
            buttonExtent * 2,
      );

  /// Where the thumb sits along the track, in pixels, or null when the content
  /// fits and there is nothing to draw.
  ///
  /// Derived entirely from [ScrollPosition.thumb]; the only thing added is
  /// [minThumbExtent], and the start is re-expressed in terms of the free
  /// space that is left once the minimum has been applied - so a thumb that
  /// was widened to stay grabbable still reaches the end of its track exactly
  /// when the content does.
  ({double start, double extent})? get thumbMetrics {
    final ({double start, double extent})? thumb = _position.thumb;
    final double track = usableTrackExtent;
    if (thumb == null || track <= 0) return null;
    // A compact control can legitimately leave less track than the themed
    // minimum thumb length. Keep the clamp bounds ordered in that case; the
    // whole available track is still a valid, reachable thumb.
    final double minimumExtent = math.min(_minThumbExtent, track);
    final double extent = (thumb.extent * track).clamp(minimumExtent, track);
    final double free = track - extent;
    final double fraction = thumb.extent >= 1
        ? 0.0
        : (thumb.start / (1 - thumb.extent)).clamp(0.0, 1.0);
    return (start: free * fraction, extent: extent);
  }

  /// Content pixels per pixel of thumb travel.
  ///
  /// Zero when the thumb cannot move, which is what stops a division by zero
  /// from turning a click on a full-length thumb into a jump to infinity.
  double get dragScale {
    final ({double start, double extent})? metrics = thumbMetrics;
    if (metrics == null) return 0;
    final double free = usableTrackExtent - metrics.extent;
    if (free <= 0) return 0;
    return _position.maxScrollExtent / free;
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    size = constraints.constrain(
      Size(
        constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.minWidth,
        constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.minHeight,
      ),
    );
  }

  /// Only where there is a thumb. A scrollbar over content that fits draws
  /// nothing, and an invisible eight-pixel strip that swallowed presses along
  /// the right edge of every short list would be worse than no scrollbar.
  @override
  bool hitTestSelf(Offset position) => _interactive && thumbMetrics != null;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!_interactive || !hasSize) return;
    final Offset local = globalToLocal(event.logicalPosition);
    final double rawMain = _vertical ? local.dy : local.dx;
    final double main = rawMain - trackMainStart;
    if (event is PointerDownEvent && event.button == PointerButton.primary) {
      final ({double start, double extent})? metrics = thumbMetrics;
      if (metrics == null) return;
      final double buttons = buttonExtent;
      if (buttons > 0) {
        if (rawMain < trackMainStart) {
          _position.applyDelta(-defaultLineExtent);
          return;
        }
        if (rawMain >= trackExtent - trackMainStart) {
          _position.applyDelta(defaultLineExtent);
          return;
        }
      }
      if (main >= metrics.start && main <= metrics.start + metrics.extent) {
        _dragPointer = event.pointerId;
        _dragOrigin = main;
        _dragStartPixels = _position.pixels;
        return;
      }
      // A press on the track either side of the thumb pages towards it, which
      // is what every platform's scrollbar does and what makes the track more
      // than decoration.
      _position.pageBy(main < metrics.start ? -1 : 1);
      return;
    }
    if (event is PointerMoveEvent) {
      if (_dragPointer != event.pointerId) return;
      final double scale = dragScale;
      if (scale == 0) return;
      _position.jumpTo(_dragStartPixels + (main - _dragOrigin) * scale);
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_dragPointer == event.pointerId) _dragPointer = null;
    }
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final ({double start, double extent})? metrics = thumbMetrics;
    if (metrics == null) return;
    final ScrollbarThemeData config = theme.scrollbarTheme;
    final bool active = isHovered || _dragPointer != null;
    final double visualThickness =
        active ? math.max(_thickness, config.hoveredThickness) : _thickness;
    final double mainStart = trackMainStart;
    final Rect track = _vertical
        ? Rect.fromLTWH(
            offset.dx + size.width - config.crossAxisMargin - visualThickness,
            offset.dy + mainStart,
            visualThickness,
            usableTrackExtent,
          )
        : Rect.fromLTWH(
            offset.dx + mainStart,
            offset.dy + size.height - config.crossAxisMargin - visualThickness,
            usableTrackExtent,
            visualThickness,
          );
    if (config.trackVisibility || active) {
      _paintRounded(
        list,
        track,
        config.trackColor ?? theme.disabledSurface.withAlpha(0x38),
        config.radius,
      );
    }
    if (buttonExtent > 0) {
      _paintButtons(list, offset, visualThickness, config);
    }
    final Rect thumb = _vertical
        ? Rect.fromLTWH(
            track.left,
            track.top + metrics.start,
            visualThickness,
            metrics.extent,
          )
        : Rect.fromLTWH(
            track.left + metrics.start,
            track.top,
            metrics.extent,
            visualThickness,
          );
    _paintRounded(
      list,
      thumb,
      active
          ? config.hoveredThumbColor ?? theme.foreground.withAlpha(0xB8)
          : config.thumbColor ?? theme.foregroundSecondary.withAlpha(0x78),
      config.radius,
    );
  }

  void _paintButtons(
    DisplayList list,
    Offset offset,
    double visualThickness,
    ScrollbarThemeData config,
  ) {
    final double crossStart = _vertical
        ? offset.dx + size.width - config.crossAxisMargin - visualThickness
        : offset.dy + size.height - config.crossAxisMargin - visualThickness;
    final Rect startButton = _vertical
        ? Rect.fromLTWH(
            crossStart,
            offset.dy + config.mainAxisMargin,
            visualThickness,
            buttonExtent,
          )
        : Rect.fromLTWH(
            offset.dx + config.mainAxisMargin,
            crossStart,
            buttonExtent,
            visualThickness,
          );
    final Rect endButton = _vertical
        ? Rect.fromLTWH(
            crossStart,
            offset.dy + trackExtent - config.mainAxisMargin - buttonExtent,
            visualThickness,
            buttonExtent,
          )
        : Rect.fromLTWH(
            offset.dx + trackExtent - config.mainAxisMargin - buttonExtent,
            crossStart,
            buttonExtent,
            visualThickness,
          );
    final Color fill = config.buttonColor ??
        config.trackColor ??
        theme.disabledSurface.withAlpha(0x88);
    _paintRounded(list, startButton, fill, config.radius);
    _paintRounded(list, endButton, fill, config.radius);
    final Color icon = config.buttonIconColor ?? theme.foregroundSecondary;
    _paintArrow(list, startButton, icon, towardsEnd: false);
    _paintArrow(list, endButton, icon, towardsEnd: true);
  }

  void _paintArrow(
    DisplayList list,
    Rect rect,
    Color color, {
    required bool towardsEnd,
  }) {
    final double sign = towardsEnd ? 1 : -1;
    final PathBuilder builder = PathBuilder();
    if (_vertical) {
      builder
        ..moveTo(rect.center.dx - 2.5, rect.center.dy - sign * 1.5)
        ..lineTo(rect.center.dx, rect.center.dy + sign * 1.5)
        ..lineTo(rect.center.dx + 2.5, rect.center.dy - sign * 1.5);
    } else {
      builder
        ..moveTo(rect.center.dx - sign * 1.5, rect.center.dy - 2.5)
        ..lineTo(rect.center.dx + sign * 1.5, rect.center.dy)
        ..lineTo(rect.center.dx - sign * 1.5, rect.center.dy + 2.5);
    }
    list.drawPath(
      list.addPath(builder.build()),
      list.addPaint(
        colorArgb: color.value,
        style: paintStyleStroke,
        strokeWidth: 1.5,
        antiAlias: true,
      ),
    );
  }

  static void _paintRounded(
    DisplayList list,
    Rect rect,
    Color color,
    double configuredRadius,
  ) {
    final double radius = math.min(
      configuredRadius,
      math.min(rect.width, rect.height) / 2,
    );
    list.drawRRectUniform(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      radius,
      radius,
      list.addPaint(colorArgb: color.value, antiAlias: true),
    );
  }

  void _onScrolled(ScrollPosition position) => markNeedsPaint();

  @override
  void detach() {
    _position.removeListener(_onScrolled);
    super.detach();
  }

  /// A scrollbar is a range widget: a value inside a minimum and a maximum,
  /// changed by dragging. There is no dedicated role in [SemanticsRole] and
  /// [SemanticsRole.slider] is the mapping ARIA itself uses for `scrollbar`, so
  /// it is reported as one rather than as an unlabelled generic box.
  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.slider,
        value: _position.pixels.toStringAsFixed(0),
        hint: 'of ${_position.maxScrollExtent.toStringAsFixed(0)}',
        actions: const <SemanticsAction>{
          SemanticsAction.scrollUp,
          SemanticsAction.scrollDown,
        },
      );
}
