/// The hover label, and the one control where doing nothing is a correct
/// answer.
///
/// This file used to be three declarations at the bottom of `controls.dart`, of
/// which two had never run: [TooltipSurface] and [RenderTooltip] were written,
/// correct, and unreachable, because `Tooltip.build` returned its child. Six
/// call sites asked for a tooltip and none of them ever showed one. The
/// substrate that was missing arrived with `popup_host.dart`, so the trigger
/// half is now written here against it.
///
/// ## Why a tooltip is not a small menu
///
/// Every other popup in this framework takes the pointer, takes the keyboard,
/// or both. A tooltip must take neither, and the reason is circular in a way
/// that is worth stating: the tooltip exists *because* the pointer is resting
/// on the control underneath, so a tooltip that consumed the pointer would
/// remove the very condition that produced it and blink itself out of
/// existence in the frame it appeared. [PopupKind.tooltip] encodes that -
/// `takesPointer` is false, and `RenderPopupLayer.hitTestChildren` skips the
/// surface entirely - which is why nothing here adds a gesture layer over the
/// content. The trigger observes the pointer; it never claims it.
///
/// ## Why the wait is shared and not per widget
///
/// A tooltip appears after [Tooltip.waitDuration] of stillness, and the
/// obvious implementation - a timer owned by each [Tooltip] - gets the second
/// tooltip wrong. Sweeping along a toolbar the user pays the wait once, on the
/// first button; from then on the tooltips follow the pointer immediately,
/// because the user has already demonstrated they want labels. With a
/// per-widget timer each new button restarts the half second from scratch, so
/// the labels only ever appear when the pointer stops moving, and a user
/// scanning a row of icons sees nothing at all. The state that makes the
/// difference - *is a tooltip already up somewhere* - is owned by neither the
/// widget being left nor the widget being entered, so it lives in one
/// library-private variable that every [Tooltip] in the process consults. That
/// is also what guarantees only one tooltip is ever on screen.
///
/// ## Time
///
/// The waits are armed on a [UiDispatcher], never on `Timer`, and the seam is
/// the one `scrollbar.dart` uses for its fade: a [Tooltip.dispatcher] argument
/// falling back to the ambient [GestureScope]. Nothing in this framework may
/// read a wall clock to find out when something happens later, and a tooltip
/// that only worked against real time could only be tested by sleeping - which
/// means it would not be tested. With no dispatcher in scope the tooltip
/// appears immediately and stays until the pointer leaves: the same "fail
/// towards visible" direction the scrollbar takes, because a label that comes
/// too eagerly is a complaint and a label that never comes is a lost feature.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../gestures/constants.dart';
import '../graphics/display_list.dart';
import '../layout/render_box.dart';
import '../layout/render_proxy_box.dart';
import '../platform/input_events.dart';
import '../scheduler/timer_handle.dart';
import '../scheduler/ui_dispatcher.dart';
import '../semantics/semantics.dart';
import 'control.dart';
import 'element.dart';
import 'gesture_detector.dart' show GestureScope;
import 'pointer_router.dart';
import 'popup.dart';
import 'popup_host.dart';
import 'theme.dart';
import 'widget.dart';

/// What makes a tooltip appear from a *touch*, matching Flutter's enum name
/// and members so that code moved from there keeps compiling.
///
/// A mouse hover always triggers a tooltip regardless of this, which is
/// Flutter's behaviour too: the mode governs the touch gesture, not the
/// pointer. On a desktop backend hover is the trigger that matters, and the
/// default stays [TooltipTriggerMode.longPress] rather than being "corrected"
/// to something desktop-shaped, because a default that differs from Flutter's
/// is a behaviour change hiding inside a successful compile.
enum TooltipTriggerMode {
  /// Neither a tap nor a long press shows the tooltip. Hover still does.
  manual,

  /// A long press shows it.
  longPress,

  /// A single tap shows it.
  tap,
}

/// The tooltip currently on screen, anywhere in this isolate.
///
/// One at a time: a second label appearing while the first is still up is
/// never what the user asked for, so opening one closes the other.
_TooltipState? _visibleTooltip;

/// The tooltip that most recently established that the user is reading
/// tooltips, or null once that has expired.
///
/// See the library comment for why this is not per widget. It is a *separate*
/// variable from [_visibleTooltip], and the separation is the whole mechanism:
/// the router reports the pointer leaving one control before it reports it
/// entering the next, so a warmth flag cleared by the hide would already be
/// gone by the time the neighbour asked - and every tooltip after the first
/// would pay the full wait again, which is exactly the behaviour the shared
/// state exists to avoid.
_TooltipState? _warmTooltip;

/// The timer that ends the warmth, or null when nothing is pending.
TimerHandle? _warmthTimer;

/// How long "the user is reading tooltips" outlives the tooltip that
/// established it.
///
/// Long enough to cross the gap between two controls in a toolbar, short
/// enough that coming back to the same toolbar a moment later pays the wait
/// again - which it should, because by then the user is doing something else.
const Duration _kTooltipWarmthGrace = Duration(milliseconds: 100);

/// A hover label attached to a child.
///
/// Flutter's signature, so that `Tooltip(message: ..., child: ...)` moves
/// across unchanged - and so do the six call sites in this repository that
/// were already written against it while it did nothing.
final class Tooltip extends StatefulWidget {
  const Tooltip({
    super.key,
    required this.message,
    this.waitDuration = const Duration(milliseconds: 500),
    this.showDuration = const Duration(milliseconds: 1500),
    this.preferBelow = true,
    this.verticalOffset = 24.0,
    this.triggerMode = TooltipTriggerMode.longPress,
    this.dispatcher,
    required this.child,
  });

  /// The text the tooltip shows.
  final String message;

  /// How long the pointer must rest on [child] before the tooltip appears -
  /// unless another tooltip is already up, in which case it appears at once.
  final Duration waitDuration;

  /// How long the tooltip stays up once shown, if the pointer never leaves.
  final Duration showDuration;

  /// Whether the tooltip prefers to sit below [child].
  ///
  /// A preference and not an instruction: [PopupAdjustment.flipY] moves it to
  /// the other side when the preferred one would put it outside the work area,
  /// which is what makes a tooltip on the bottom row of a window readable.
  final bool preferBelow;

  /// The gap between the *centre* of [child] and the near edge of the tooltip.
  ///
  /// Measured from the centre rather than from the edge because that is what
  /// Flutter measures from, and a tooltip sitting a control's half-height
  /// further out than the one in the application being ported is exactly the
  /// kind of difference nobody files a bug about and everybody notices.
  final double verticalOffset;

  /// What touch gesture shows the tooltip. Hover is unconditional.
  final TooltipTriggerMode triggerMode;

  /// Where the waits are armed. Falls back to the ambient [GestureScope].
  ///
  /// Not part of Flutter's signature; it is this framework's answer to the
  /// same problem `Scrollbar.dispatcher` solves, and it is optional, so a
  /// Flutter call site never mentions it.
  final UiDispatcher? dispatcher;

  final Widget child;

  @override
  State<Tooltip> createState() => _TooltipState();
}

final class _TooltipState extends State<Tooltip> {
  UiDispatcher? _dispatcher;
  PopupHost? _host;
  _RenderTooltipTrigger? _trigger;

  PopupHandle? _handle;
  TimerHandle? _waitTimer;
  TimerHandle? _showTimer;
  TimerHandle? _pressTimer;

  /// Whether this tooltip's surface is currently open.
  bool get isShowing => _handle != null;

  @override
  void didUpdateWidget(Tooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The surface is built by a closure the host owns, so a changed message
    // reaches it only if the popup is told to rebuild. Without this a tooltip
    // that is up while its control's meaning changes keeps showing the old
    // text until the pointer leaves and comes back.
    if (oldWidget.message != widget.message) _handle?.markNeedsBuild();
  }

  @override
  void dispose() {
    _hide();
    // Warmth outlives the hide by design, and a warmth pointing at a state
    // that is gone would keep every later tooltip skipping its wait for the
    // life of the isolate - and would leak one test's state into the next.
    if (identical(_warmTooltip, this)) _endWarmth();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _dispatcher = widget.dispatcher ?? GestureScope.of(context);
    final PopupHost? host = PopupHost.maybeOf(context);
    _host = host;
    // `maybeOf`, and the child alone when there is none. A tooltip is the one
    // control for which silence is right: a backend with no popups still has
    // to render the button, and a thrown "no PopupHostScope" would turn a
    // decoration into a crash. Menus use `PopupHost.of` for the opposite
    // reason - a menu that opens nothing reads as broken.
    if (host == null) return widget.child;
    return _TooltipTrigger(
      onAttached: (_RenderTooltipTrigger box) => _trigger = box,
      onHoverChanged: _handleHoverChanged,
      onPointerAction: _handlePointerAction,
      child: widget.child,
    );
  }

  // -------------------------------------------------------------------------
  // Triggers
  // -------------------------------------------------------------------------

  void _handleHoverChanged(bool hovered) {
    if (hovered) {
      _scheduleShow();
      return;
    }
    _hide();
  }

  void _handlePointerAction(_TooltipPointerAction action) {
    switch (action) {
      case _TooltipPointerAction.press:
        if (widget.triggerMode != TooltipTriggerMode.longPress) return;
        _pressTimer?.cancel();
        // The long press uses the gesture layer's own timeout rather than
        // [Tooltip.waitDuration]: the two answer different questions, and a
        // press that showed a tooltip after a different delay than every other
        // long press in the application is a gesture that feels broken.
        _pressTimer = _dispatcher?.schedule(kLongPressTimeout, _show);
      case _TooltipPointerAction.tap:
        _pressTimer?.cancel();
        _pressTimer = null;
        if (widget.triggerMode == TooltipTriggerMode.tap) _show();
      case _TooltipPointerAction.cancel:
        _pressTimer?.cancel();
        _pressTimer = null;
    }
  }

  void _scheduleShow() {
    if (_handle != null) return;
    _waitTimer?.cancel();
    _waitTimer = null;
    final UiDispatcher? dispatcher = _dispatcher;
    // Warm, or unable to wait at all. Both go straight to the surface; see the
    // library comment for why "some other tooltip is up" is the condition that
    // skips the wait, and why it cannot be answered from this widget's state.
    if (dispatcher == null ||
        _warmTooltip != null ||
        widget.waitDuration <= Duration.zero) {
      _show();
      return;
    }
    _waitTimer = dispatcher.schedule(widget.waitDuration, _show);
  }

  // -------------------------------------------------------------------------
  // The surface
  // -------------------------------------------------------------------------

  void _show() {
    _waitTimer = null;
    _pressTimer = null;
    if (!mounted || _handle != null) return;
    final PopupHost? host = _host;
    final _RenderTooltipTrigger? box = _trigger;
    // A timer that outlives its own render object is not a caller error: a
    // control can be scrolled out of the tree while the wait runs, and asking
    // an unlaid-out box where it is on screen would throw.
    if (host == null || box == null || !box.hasSize) return;

    // One tooltip at a time. The previous one goes away *before* this one is
    // opened, so the shared variable never names a closed popup.
    final _TooltipState? previous = _visibleTooltip;
    if (previous != null && !identical(previous, this)) previous._hide();

    final Offset topLeft = box.localToGlobal(Offset.zero);
    final Rect anchor = Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      box.size.width,
      box.size.height,
    );
    final double offset =
        widget.preferBelow ? widget.verticalOffset : -widget.verticalOffset;
    _handle = host.open(PopupSpec(
      anchorRect: anchor,
      kind: PopupKind.tooltip,
      // The anchor point is the child's *centre*, which is why
      // [PopupAnchorPoint.center] appears here rather than an edge: it is the
      // point Flutter's tooltip delegate measures [Tooltip.verticalOffset]
      // from, and it is also the one point that survives a flip unchanged, so
      // flipping costs exactly the sign of the offset and nothing else.
      anchorPoint: PopupAnchorPoint.center,
      popupPoint: widget.preferBelow
          ? PopupAnchorPoint.topCenter
          : PopupAnchorPoint.bottomCenter,
      offset: Offset(0, offset),
      // Flip vertically, slide horizontally. Never flip horizontally: a
      // tooltip that jumped to the other side of its control would no longer
      // read as belonging to it, while sliding keeps it under the same button.
      adjustments: const <PopupAdjustment>{
        PopupAdjustment.flipY,
        PopupAdjustment.slideX,
      },
      builder: (BuildContext context) =>
          TooltipSurface(message: widget.message),
      onDismiss: _handleDismissed,
    ));
    _visibleTooltip = this;
    _warmTooltip = this;
    _warmthTimer?.cancel();
    _warmthTimer = null;

    final UiDispatcher? dispatcher = _dispatcher;
    if (dispatcher != null && widget.showDuration > Duration.zero) {
      _showTimer = dispatcher.schedule(widget.showDuration, _hide);
    }
  }

  void _hide() {
    _cancelTimers();
    final PopupHandle? handle = _handle;
    // Cleared before the close, so that [_handleDismissed] - which the close
    // calls back into - finds nothing left to do rather than re-entering.
    _handle = null;
    if (identical(_visibleTooltip, this)) _visibleTooltip = null;
    if (identical(_warmTooltip, this)) _armWarmthExpiry();
    handle?.close();
  }

  /// Starts the grace period after which the next tooltip pays the full wait
  /// again. With no clock there is nothing to time it with, so warmth ends at
  /// once - which is the honest answer rather than a warmth that never ends.
  void _armWarmthExpiry() {
    _warmthTimer?.cancel();
    _warmthTimer = null;
    final UiDispatcher? dispatcher = _dispatcher;
    if (dispatcher == null) {
      _warmTooltip = null;
      return;
    }
    _warmthTimer = dispatcher.schedule(_kTooltipWarmthGrace, _endWarmth);
  }

  void _endWarmth() {
    _warmthTimer?.cancel();
    _warmthTimer = null;
    _warmTooltip = null;
  }

  /// The host closed this popup by a route that did not start here: a
  /// `closeAll` on window deactivation, or the layer being torn down. The
  /// bookkeeping has to happen anyway, or the shared variable would keep
  /// naming a tooltip that is no longer on screen and every later tooltip
  /// would skip its wait forever.
  void _handleDismissed() {
    _handle = null;
    if (identical(_visibleTooltip, this)) _visibleTooltip = null;
    if (identical(_warmTooltip, this)) _armWarmthExpiry();
    _cancelTimers();
  }

  void _cancelTimers() {
    _waitTimer?.cancel();
    _waitTimer = null;
    _showTimer?.cancel();
    _showTimer = null;
    _pressTimer?.cancel();
    _pressTimer = null;
  }
}

// ---------------------------------------------------------------------------
// The trigger
// ---------------------------------------------------------------------------

/// What the trigger saw the pointer do, reduced to the three things a tooltip
/// cares about.
enum _TooltipPointerAction { press, tap, cancel }

final class _TooltipTrigger extends SingleChildRenderObjectWidget {
  const _TooltipTrigger({
    required this.onAttached,
    required this.onHoverChanged,
    required this.onPointerAction,
    required super.child,
  });

  final void Function(_RenderTooltipTrigger box) onAttached;
  final void Function(bool hovered) onHoverChanged;
  final void Function(_TooltipPointerAction action) onPointerAction;

  @override
  _RenderTooltipTrigger createRenderObject(BuildContext context) {
    final _RenderTooltipTrigger box = _RenderTooltipTrigger(
      onHoverChanged: onHoverChanged,
      onPointerAction: onPointerAction,
    );
    // The State needs the render object to answer "where is my child on
    // screen", and a BuildContext here offers no `findRenderObject`. The
    // handshake goes this way round rather than through a GlobalKey, because a
    // key would make every tooltip an entry in a global registry for the life
    // of the window.
    onAttached(box);
    return box;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTooltipTrigger renderObject,
  ) {
    renderObject
      ..onHoverChanged = onHoverChanged
      ..onPointerAction = onPointerAction;
    onAttached(renderObject);
  }
}

/// Watches the pointer over the tooltip's child without ever claiming it.
///
/// It learns about hover because it is in the hit path - the router diffs that
/// path on every move and calls [handleHoverChanged] on what entered and left -
/// and it learns about presses because being a [PointerEventTarget] in the same
/// path means events are offered to it on the way past. It is not a
/// [PointerEventBarrier] and it never reports anything as handled, so the
/// control underneath receives exactly what it would have received with no
/// tooltip wrapped around it.
final class _RenderTooltipTrigger extends RenderProxyBox
    implements HoverEventTarget, PointerEventTarget {
  _RenderTooltipTrigger({
    required this.onHoverChanged,
    required this.onPointerAction,
  });

  void Function(bool hovered) onHoverChanged;
  void Function(_TooltipPointerAction action) onPointerAction;

  bool _pressed = false;

  /// True, so that a tooltip works over a child that is not itself
  /// hit-testable - an icon, a text label - which is most of the six call
  /// sites this widget already had. It costs the child nothing: children are
  /// tested first and win whenever they answer.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleHoverChanged(bool hovered) => onHoverChanged(hovered);

  @override
  void handlePointerEvent(PointerEvent event) {
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        _pressed = true;
        onPointerAction(_TooltipPointerAction.press);
      case PointerUpEvent(button: PointerButton.primary):
        if (!_pressed) return;
        _pressed = false;
        // A release that wandered off the child is a cancelled gesture and not
        // a tap - the rule every control here applies - and it is checked
        // against this box rather than against the hit path because the press
        // captured the pointer, so the path is no longer consulted.
        onPointerAction(
          hasSize && size.contains(globalToLocal(event.logicalPosition))
              ? _TooltipPointerAction.tap
              : _TooltipPointerAction.cancel,
        );
      case PointerCancelEvent():
        if (!_pressed) return;
        _pressed = false;
        onPointerAction(_TooltipPointerAction.cancel);
      default:
        return;
    }
  }
}

// ---------------------------------------------------------------------------
// The surface
// ---------------------------------------------------------------------------

/// The surface a tooltip paints when shown.
final class TooltipSurface extends StatelessWidget {
  const TooltipSurface({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) =>
      _TooltipRenderWidget(message: message, theme: Theme.of(context));
}

final class _TooltipRenderWidget extends RenderObjectWidget {
  const _TooltipRenderWidget({required this.message, required this.theme});

  final String message;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderTooltip createRenderObject(BuildContext context) =>
      RenderTooltip(message: message)..theme = theme;

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderTooltip object) {
    object
      ..message = message
      ..theme = theme;
  }
}

final class RenderTooltip extends RenderBox with ControlBehavior {
  RenderTooltip({required String message}) : _message = message;

  String _message;

  String get message => _message;

  set message(String value) {
    if (value == _message) return;
    _message = value;
    markNeedsLayout();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final Size text = measureLabel(_message);
    size = constraints.constrain(
      Size(text.width + theme.effectiveControlPadding * 2, text.height + 8),
    );
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintRoundedFill(list, rect, theme.surfaceRaised, theme.cornerRadiusSmall);
    paintRoundedBorder(list, rect, theme.border, theme.cornerRadiusSmall);
    paintCenteredLabel(list, _message, rect, theme.foreground);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.tooltip,
        label: _message,
      );
}
