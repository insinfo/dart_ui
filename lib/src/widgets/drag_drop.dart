/// Drops, delivered to the widget under the pointer.
///
/// The platform reports a drag against a *window*: `IDropTarget` is registered
/// per `HWND`, `wl_data_device.enter` names a surface, `XdndEnter` names an X
/// window. Which control inside that window the user is aiming at is a question
/// only the widget tree can answer, and this file is the part that asks it.
///
/// ## The routing is a hit test, and deliberately the same one clicks use
///
/// [DragRouter] hit-tests `event.position` against the render tree and walks
/// the resulting [HitTestPath] deepest first, exactly as [PointerRouter] does
/// for a click. That is not merely convenient: a target that accepted drops in
/// a region its own hit test would not accept a click in is a target the user
/// cannot see the edges of. If a control is not clickable there, it is not
/// droppable there.
///
/// Two differences from the pointer path, both forced by the protocols:
///
///  * **There is no capture.** A pointer that goes down on a control belongs to
///    it until it comes up, wherever it travels; a drag belongs to whatever is
///    under it at every moment, because the *source* owns the gesture and the
///    destination is only being consulted. So every enter and over is a fresh
///    hit test, and moving from one drop zone into another is an ordinary
///    leave/enter pair rather than a capture that has to be broken.
///  * **A refusal falls through to the ancestor.** The deepest
///    [DragEventTarget] gets first refusal, and a target that returns
///    [DropResponse.reject] is skipped so its parent may take the drop instead.
///    A file list dropped on a label inside a drop zone should land in the drop
///    zone; with a click that question does not arise, because a widget that
///    does not handle a click simply does not implement the interface.
///
/// ## Enter and leave are derived here, not by the platform
///
/// The platform says "the pointer entered this *window*". Which widget it
/// entered, and which one it just left, is diffed by [DragRouter] between
/// consecutive events - the same shape as `PointerRouter._updateHoverPath`, and
/// the reason a `DropTarget` can rely on getting exactly one leave for every
/// enter even though no protocol sends one.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../gestures/constants.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/render_box.dart';
import '../platform/drag_drop.dart';
import '../platform/input_events.dart';
import '../platform/native_window.dart';
import 'element.dart';
import 'pointer_router.dart';
import 'semantics.dart';
import 'widget.dart';

export '../platform/drag_drop.dart';

/// A render object that can receive a drop.
///
/// Discovered off the hit-test path, exactly the way [PointerEventTarget] is,
/// so that nothing has to register and nothing can leak a stale registration
/// when a subtree is removed.
abstract interface class DragEventTarget {
  /// A drag arrived over this node. Answering [DropResponse.reject] passes the
  /// question to the ancestor above.
  DropResponse handleDragEnter(DragSessionEvent event);

  /// The drag moved and this node is still the one under it.
  DropResponse handleDragOver(DragSessionEvent event);

  /// The drag moved away, ended, or was cancelled. Exactly one per accepted
  /// [handleDragEnter].
  void handleDragLeave();

  /// The user dropped here. The returned action is what actually happened.
  Future<DragAction> handleDrop(DragSessionEvent event);
}

/// Finds the [DragEventTarget] under a drag and keeps enter/leave honest.
///
/// One per window, owned by the [BuildOwner], for [PointerRouter]'s reason:
/// hover-like state is per tree, and a global would make two windows in one
/// process share a drop target.
final class DragRouter {
  final HitTestPath _path = HitTestPath();

  DragEventTarget? _active;

  /// The node currently under the drag and willing to take it, or null.
  DragEventTarget? get activeTarget => _active;

  /// Routes an enter or an over - they are the same operation once the
  /// previous target is known, which is why the platform's distinction between
  /// them does not survive into the tree.
  ///
  /// Returns what the window should tell the source.
  DropResponse update(DragSessionEvent event, {required RenderBox root}) {
    _path.reset();
    root.hitTest(event.position, path: _path);

    // A target that is no longer under the pointer at all has lost the drag
    // whatever the new candidates answer, so it is told before they are asked.
    // That is what makes moving between two zones the natural leave-then-enter
    // pair a highlight wants, rather than the reverse - and it is *only* safe
    // for a target that has left the path: one that is still on it may be the
    // ancestor that takes the drop when the deeper candidate refuses, and
    // leaving it early would be a leave with no enter to match.
    final DragEventTarget? active = _active;
    if (active != null && !_pathContains(active)) _leaveActive();

    for (int i = 0; i < _path.length; i++) {
      final RenderBox node = _path[i];
      if (node is! DragEventTarget) continue;
      final DragEventTarget target = node as DragEventTarget;
      final bool wasActive = identical(target, _active);
      final DropResponse response = wasActive
          ? target.handleDragOver(event)
          : target.handleDragEnter(event);
      if (!response.isAccepted) {
        // A target that refuses is not the target: if it was the active one it
        // has just stopped being, and either way the ancestor gets a turn.
        if (wasActive) {
          target.handleDragLeave();
          _active = null;
        }
        continue;
      }
      if (!wasActive) {
        _leaveActive();
        _active = target;
      }
      return response;
    }
    _leaveActive();
    return const DropResponse.reject();
  }

  /// The drag left the window, or ended without a drop.
  void leave() => _leaveActive();

  /// The user dropped. The active target performs it; nobody else is asked,
  /// because the source has already been told which action this window agreed
  /// to and asking a different widget now could perform a different one.
  Future<DragAction> drop(DragSessionEvent event) async {
    final DragEventTarget? target = _active;
    _active = null;
    if (target == null) return DragAction.none;
    try {
      return await target.handleDrop(event);
    } finally {
      target.handleDragLeave();
    }
  }

  bool _pathContains(DragEventTarget target) {
    for (int i = 0; i < _path.length; i++) {
      if (identical(_path[i], target)) return true;
    }
    return false;
  }

  void _leaveActive() {
    final DragEventTarget? target = _active;
    _active = null;
    target?.handleDragLeave();
  }
}

/// Hands a window's drags to its widget tree.
///
/// This is the object a backend's `registerDropTarget` is given: it turns the
/// window-level [DropTargetHandler] the platform needs into the per-widget
/// routing above.
final class WidgetTreeDropTarget implements DropTargetHandler {
  WidgetTreeDropTarget(this.owner);

  final BuildOwner owner;

  @override
  DropResponse onDragEnter(DragSessionEvent event) =>
      owner.dispatchDragUpdate(event);

  @override
  DropResponse onDragOver(DragSessionEvent event) =>
      owner.dispatchDragUpdate(event);

  @override
  void onDragLeave() => owner.dispatchDragLeave();

  @override
  Future<DragAction> onDrop(DragSessionEvent event) =>
      owner.dispatchDrop(event);
}

/// Publishes the platform's drag and drop to a subtree.
///
/// The same shape as `ClipboardScope`, installed at the same place and for the
/// same reason: a control that wants to start a drag should not have to be
/// handed a backend by its parent, and a subtree with no scope above it gets an
/// [UnavailableDragDrop] whose message says so rather than a null.
final class DragDropScope extends InheritedWidget {
  const DragDropScope({
    super.key,
    required this.dragAndDrop,
    this.window,
    required super.child,
  });

  final DragDropBackend dragAndDrop;

  /// The window this subtree is mounted in, which starting a drag needs.
  ///
  /// Every protocol wants it and wants it for a different reason: Wayland
  /// needs the origin `wl_surface` and the input serial that came with it,
  /// XDND needs a window to own `XdndSelection` with, Win32 needs nothing but
  /// records it. So [DragRequest] takes one, and a [DragSource] has no other
  /// way to find it - the widget tree deliberately does not know what a window
  /// is anywhere else.
  ///
  /// Null in a widget test that mounted a tree without an application, which
  /// is why [DragSource] reports that case as a named failure rather than
  /// dereferencing it.
  final NativeWindow? window;

  /// The nearest backend, or one that fails by name when there is none.
  static DragDropBackend of(BuildContext context) =>
      maybeOf(context) ??
      const UnavailableDragDrop(
        name: 'none',
        reason: 'no DragDropScope is installed above this control; an '
            'application installs one from Application.dragAndDrop',
      );

  /// The nearest backend, or null - for a caller that would rather hide a
  /// "drag me" affordance than offer one that will fail.
  static DragDropBackend? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DragDropScope>()
      ?.dragAndDrop;

  /// The window this subtree is mounted in, or null outside an application.
  static NativeWindow? windowOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DragDropScope>()?.window;

  @override
  bool updateShouldNotify(DragDropScope oldWidget) =>
      !identical(dragAndDrop, oldWidget.dragAndDrop) ||
      !identical(window, oldWidget.window);
}

/// What a [DropTarget] is told when the drag arrives, in widget terms.
///
/// A thin reading of [DragSessionEvent] rather than a pass-through, because the
/// two questions a drop handler actually asks - "where, in my own coordinates?"
/// and "what is in it?" - are both wrong on the raw event: its position is in
/// the window's client space, not the target's.
final class DropDetails {
  const DropDetails({
    required this.data,
    required this.localPosition,
    required this.action,
    required this.session,
  });

  /// What is being dragged.
  final DragData data;

  /// Where the pointer is, relative to this target's top-left corner.
  final Offset localPosition;

  /// The action this target agreed to.
  final DragAction action;

  /// The whole platform event, for a handler that needs the modifiers or the
  /// screen position.
  final DragSessionEvent session;
}

/// Decides whether a drop is welcome, and as what.
typedef DropAcceptance = DropResponse Function(DropDetails details);

/// Performs a drop, answering with what was really done.
typedef DropPerform = Future<DragAction> Function(DropDetails details);

/// A region of the tree that accepts drops.
///
/// The plainest use names the formats it takes and what to do with them:
///
/// ```dart
/// DropTarget(
///   formats: const <String>[DragFormats.uriList],
///   onDrop: (DropDetails details) async {
///     open(await details.data.readFilePaths());
///     return DragAction.copy;
///   },
///   child: const Text('drop files here'),
/// )
/// ```
///
/// [onDrop] is required and returns the action performed, because the honest
/// answer matters: returning [DragAction.move] is what lets the source delete
/// its original, and returning [DragAction.none] after a failed read tells it
/// not to.
///
/// **On a backend with no drag and drop** - headless, and the web backend for
/// now - the window is never registered and this widget simply never fires.
/// That is a property of the platform rather than of the widget, and it is
/// discoverable rather than silent: `DragDropScope.of(context)` answers with an
/// [UnavailableDragDrop] whose message names the backend and the reason, which
/// is what a caller should check before offering a "drop files here"
/// affordance at all.
final class DropTarget extends SingleChildRenderObjectWidget {
  const DropTarget({
    super.key,
    required this.onDrop,
    this.formats = const <String>[DragFormats.uriList, DragFormats.text],
    this.action = DragAction.copy,
    this.accepts,
    this.onDragEnter,
    this.onDragOver,
    this.onDragLeave,
    this.highlightColor,
    this.opaque = true,
    this.semanticLabel,
    super.child,
  });

  /// The formats this target takes, **in its own order of preference**.
  ///
  /// The order is the target's, not the source's: a file manager wants
  /// [DragFormats.uriList] before [DragFormats.text] when a drag offers both,
  /// and a note editor wants the opposite. See [DragDataReading.preferredFormat].
  final List<String> formats;

  /// What this target does with what it takes. Refused when the source does not
  /// allow it - a move onto a target whose source only offers copy is a
  /// refusal, never a silent copy.
  final DragAction action;

  /// Overrides the default accept rule, which is "one of [formats] is on offer
  /// and the source allows [action]".
  ///
  /// Called on every move, so it must be cheap and must not await: see
  /// [DropTargetHandler].
  final DropAcceptance? accepts;

  final void Function(DropDetails details)? onDragEnter;
  final void Function(DropDetails details)? onDragOver;
  final void Function()? onDragLeave;

  final DropPerform onDrop;

  /// Painted over the child while an accepted drag is over this target.
  ///
  /// The minimum honest feedback: the user has to be able to see *which*
  /// region will take the drop, and a target that only changes the cursor
  /// leaves them guessing between two adjacent zones. Null paints nothing, for
  /// a caller drawing its own highlight from [onDragEnter].
  final Color? highlightColor;

  /// Whether this target is hittable across its whole area or only where its
  /// child is.
  ///
  /// True by default, unlike [GestureDetector]: a drop zone is normally an
  /// *area*, often a mostly empty one, and defaulting to the child would make
  /// the empty part of a "drop files here" panel refuse drops.
  final bool opaque;

  /// What assistive technology calls this region.
  final String? semanticLabel;

  @override
  RenderDropTarget createRenderObject(BuildContext context) =>
      RenderDropTarget(opaque: opaque)..configure(this);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDropTarget renderObject,
  ) {
    renderObject
      ..opaque = opaque
      ..configure(this);
  }
}

/// The render object behind [DropTarget].
final class RenderDropTarget extends RenderSingleChildBox
    implements DragEventTarget, SemanticsProvider {
  RenderDropTarget({this.opaque = true});

  /// Whether this target is hittable across its whole area.
  ///
  /// A plain field: it changes neither geometry nor pixels, only what the
  /// *next* hit test finds, and the next hit test reads it.
  bool opaque;

  List<String> _formats = const <String>[];
  DragAction _action = DragAction.copy;
  DropAcceptance? _accepts;
  void Function(DropDetails details)? _onDragEnter;
  void Function(DropDetails details)? _onDragOver;
  void Function()? _onDragLeave;
  DropPerform? _onDrop;
  Color? _highlightColor;
  String? _semanticLabel;

  /// Whether an accepted drag is over this target right now.
  ///
  /// Public because it is the state a caller wants to reflect in its own
  /// painting, and because the test asserts on it.
  bool get isDragOver => _isDragOver;
  bool _isDragOver = false;

  /// Pushes a widget's configuration onto this render object.
  ///
  /// One method rather than a setter per callback, for [RenderGestureDetector]'s
  /// reason: the set changes together on every rebuild and comparing them one
  /// at a time would mark the object dirty for a closure identity that changes
  /// on every build anyway.
  void configure(DropTarget widget) {
    _formats = widget.formats;
    _action = widget.action;
    _accepts = widget.accepts;
    _onDragEnter = widget.onDragEnter;
    _onDragOver = widget.onDragOver;
    _onDragLeave = widget.onDragLeave;
    _onDrop = widget.onDrop;
    _semanticLabel = widget.semanticLabel;
    if (_highlightColor != widget.highlightColor) {
      _highlightColor = widget.highlightColor;
      if (_isDragOver) markNeedsPaint();
    }
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.largestFinite;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  bool hitTestSelf(Offset position) => opaque;

  @override
  void paint(DisplayList list, Offset offset) {
    super.paint(list, offset);
    final Color? highlight = _highlightColor;
    if (!_isDragOver || highlight == null) return;
    // Over the child, not behind it: the point of the highlight is to say
    // "here", and a wash behind opaque content is invisible.
    final int paintId = list.addPaint(colorArgb: highlight.value);
    list.drawRectangle(
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      paintId,
    );
  }

  // -------------------------------------------------------------------------
  // DragEventTarget
  // -------------------------------------------------------------------------

  @override
  DropResponse handleDragEnter(DragSessionEvent event) {
    final DropResponse response = _evaluate(event);
    _setDragOver(response.isAccepted);
    if (response.isAccepted) {
      _onDragEnter?.call(_details(event, response.action));
    }
    return response;
  }

  @override
  DropResponse handleDragOver(DragSessionEvent event) {
    final DropResponse response = _evaluate(event);
    _setDragOver(response.isAccepted);
    if (response.isAccepted) {
      _onDragOver?.call(_details(event, response.action));
    }
    return response;
  }

  @override
  void handleDragLeave() {
    if (!_isDragOver) return;
    _setDragOver(false);
    _onDragLeave?.call();
  }

  @override
  Future<DragAction> handleDrop(DragSessionEvent event) async {
    final DropPerform? perform = _onDrop;
    final DropResponse response = _evaluate(event);
    if (perform == null || !response.isAccepted) return DragAction.none;
    return perform(_details(event, response.action));
  }

  /// The default accept rule, or the caller's.
  DropResponse _evaluate(DragSessionEvent event) {
    final DropAcceptance? accepts = _accepts;
    if (accepts != null) return accepts(_details(event, _action));
    final String? format = event.data.preferredFormat(_formats);
    if (format == null) return const DropResponse.reject();
    // Asking for an action the source cannot perform is a refusal on every
    // protocol, so it is one here rather than a quiet downgrade to copy.
    if (!event.allowedActions.contains(_action)) {
      return const DropResponse.reject();
    }
    return DropResponse(acceptedFormat: format, action: _action);
  }

  DropDetails _details(DragSessionEvent event, DragAction action) =>
      DropDetails(
        data: event.data,
        localPosition: globalToLocal(event.position),
        action: action,
        session: event,
      );

  void _setDragOver(bool value) {
    if (value == _isDragOver) return;
    _isDragOver = value;
    if (_highlightColor != null) markNeedsPaint();
  }

  /// Leaving the tree ends any drag over this node.
  ///
  /// The router is not told: a detached node is no longer on any hit-test
  /// path, so the next move drops it as the active target through the ordinary
  /// leave path. What must not survive is the flag, which would otherwise
  /// paint a highlight the first frame the node is remounted.
  @override
  void detach() {
    _isDragOver = false;
    super.detach();
  }

  // -------------------------------------------------------------------------
  // Semantics
  // -------------------------------------------------------------------------

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.generic,
        label: _semanticLabel,
        // `selected` rather than a state of its own: the semantic vocabulary
        // has no "drop target under a drag", and inventing one would mean
        // every bridge in the repository learning a state no platform API can
        // express. Selected is what a screen reader already announces for
        // "this is the one that will act".
        states: <SemanticsState>{
          if (_isDragOver) SemanticsState.selected,
        },
      );
}

// ---------------------------------------------------------------------------
// The source side
// ---------------------------------------------------------------------------

/// Builds the payload a drag will carry, at the moment the drag begins.
///
/// A builder rather than a value because the payload is a function of *when*:
/// a list that drags its selection has to serialise the selection the user had
/// when they started pulling, not the one it had when the widget was built.
typedef DragPayloadBuilder = DragData Function();

/// Builds the picture that follows the cursor, when the platform can show one.
typedef DragFeedbackBuilder = DragFeedbackImage? Function();

/// A region of the tree the user can drag *out of*.
///
/// ## The drag starts on movement, never on the press
///
/// A press is not a drag, and treating it as one is the bug that makes a list
/// impossible to click: every attempt to select an item would begin an
/// operating-system drag instead. So this widget waits for the pointer to
/// travel [slop] logical pixels from where it went down, which is the same
/// hysteresis boundary `gestures/constants.dart` already defines for every
/// other drag in this repository - 4 pixels for a mouse, which is Win32's own
/// `SM_CXDRAG`, and 18 for a finger, which is a fingertip's contact patch.
///
/// Passing [slop] explicitly is for the rare control that needs a different
/// number; the default asks [touchSlopForKind], so a mouse and a finger get
/// the answer each deserves without the caller branching.
///
/// ## What happens after that is the platform's, and it differs
///
/// [DragDropBackend.startDrag] is a future on every backend, and on exactly one
/// of them it is a lie about concurrency: **Win32's `DoDragDrop` runs its own
/// modal loop and does not return until the user lets go**, so the whole Dart
/// isolate is parked inside it - no frame is painted and no timer fires in the
/// meantime. That is the platform's design rather than this widget's, and the
/// consequence a caller must plan for is that [onDragEnd] can arrive a long
/// time after [onDragStarted] with nothing in between.
///
/// ```dart
/// DragSource(
///   data: () => MemoryDragData.filePaths(selectedPaths),
///   allowedActions: const <DragAction>{DragAction.copy, DragAction.move},
///   child: const Text('drag me'),
/// )
/// ```
final class DragSource extends StatefulWidget {
  const DragSource({
    super.key,
    required this.data,
    this.allowedActions = const <DragAction>{DragAction.copy},
    this.preferredAction = DragAction.copy,
    this.feedback,
    this.slop,
    this.enabled = true,
    this.opaque = false,
    this.onDragStarted,
    this.onDragEnd,
    this.onDragFailed,
    this.child,
  });

  /// What to drag, built when the gesture commits.
  final DragPayloadBuilder data;

  /// What this source is willing to let a destination do. A destination that
  /// asks for anything outside this set is refused by the backend.
  final Set<DragAction> allowedActions;

  /// What should happen when nobody expresses a preference.
  final DragAction preferredAction;

  /// The picture to drag under the cursor, where the platform can show one.
  ///
  /// Honoured by backends that have somewhere to put it and ignored - never
  /// emulated - by the rest; see [DragRequest.feedback] for why drawing our
  /// own would be worse than none.
  final DragFeedbackBuilder? feedback;

  /// How far the pointer must travel before this becomes a drag, or null for
  /// [touchSlopForKind] - which is what almost every caller wants.
  final double? slop;

  /// Whether this source will start a drag at all. A disabled source still
  /// lays out and paints its child; it simply never commits.
  final bool enabled;

  /// Whether the source is hittable across its whole area or only where its
  /// child is.
  ///
  /// False by default, the opposite of [DropTarget]: a drag source is normally
  /// *a thing you grab* - a row, a chip, a file tile - and an opaque one would
  /// claim the empty space around it as draggable too.
  final bool opaque;

  /// The drag has begun and the platform has been asked to run it.
  final void Function()? onDragStarted;

  /// The drag ended, carrying the action the destination performed.
  ///
  /// [DragAction.none] means the user dropped on nothing or cancelled, which is
  /// the ordinary outcome and not a failure. [DragAction.move] is the one that
  /// obliges this source to delete its original - and it should do so *here*,
  /// after the destination confirmed the transfer, never optimistically when
  /// the drag started.
  final void Function(DragAction action)? onDragEnd;

  /// The platform refused to start the drag, with the reason.
  ///
  /// Separate from an [onDragEnd] of [DragAction.none] on purpose: "the user
  /// changed their mind" and "this backend has no drag and drop" are different
  /// facts, and a control that shows a message for the second must not show it
  /// for the first.
  final void Function(DragDropException error)? onDragFailed;

  final Widget? child;

  @override
  State<DragSource> createState() => DragSourceState();
}

/// The state of a [DragSource]. Public only so a test can read [isDragging].
final class DragSourceState extends State<DragSource> {
  /// Whether a drag this widget started is still running.
  ///
  /// Guards against a second `startDrag` from the same gesture, which on Win32
  /// would be a second modal loop nested inside the first.
  bool get isDragging => _dragging;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) => _DragSourceDetector(
        opaque: widget.opaque,
        slop: widget.slop,
        enabled: widget.enabled && !_dragging,
        onDragCommitted: startDrag,
        child: widget.child,
      );

  /// Starts the drag now, without waiting for a gesture.
  ///
  /// Public because a control may have its own reason to begin one - a
  /// "drag out" menu item, a keyboard accessible alternative - and because it
  /// is what the widget test drives instead of synthesising pointer travel.
  Future<void> startDrag() async {
    if (_dragging) return;
    final DragDropBackend backend = DragDropScope.of(context);
    final NativeWindow? window = DragDropScope.windowOf(context);
    if (window == null) {
      widget.onDragFailed?.call(
        const DragDropException(
          operation: 'startDrag',
          reason: 'this subtree is not mounted in an application window, so '
              'there is no window for the platform to drag out of; an '
              'application installs one through DragDropScope.window',
        ),
      );
      return;
    }
    _dragging = true;
    widget.onDragStarted?.call();
    try {
      final DragAction performed = await backend.startDrag(
        DragRequest(
          window: window,
          data: widget.data(),
          allowedActions: widget.allowedActions,
          preferredAction: widget.preferredAction,
          feedback: widget.feedback?.call(),
        ),
      );
      if (mounted) widget.onDragEnd?.call(performed);
    } on DragDropException catch (error) {
      if (mounted) widget.onDragFailed?.call(error);
    } finally {
      // Cleared even when the widget is gone, because the guard is about this
      // State and the State may still be alive in an inactive element waiting
      // to be reclaimed by a global key.
      _dragging = false;
      // The detector's `enabled` is derived from this flag, so the tree has to
      // be rebuilt for it to start listening again.
      if (mounted) setState(() {});
    }
  }
}

/// The half of [DragSource] that watches pointers.
final class _DragSourceDetector extends SingleChildRenderObjectWidget {
  const _DragSourceDetector({
    required this.onDragCommitted,
    required this.opaque,
    required this.enabled,
    required this.slop,
    super.child,
  });

  final void Function() onDragCommitted;
  final bool opaque;
  final bool enabled;
  final double? slop;

  @override
  RenderDragSource createRenderObject(BuildContext context) =>
      RenderDragSource(opaque: opaque)
        ..onDragCommitted = onDragCommitted
        ..enabled = enabled
        ..slop = slop;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDragSource renderObject,
  ) {
    renderObject
      ..opaque = opaque
      ..onDragCommitted = onDragCommitted
      ..enabled = enabled
      ..slop = slop;
  }
}

/// Turns a press followed by movement into one call.
///
/// Deliberately not a `GestureRecognizer` in an arena. A drag out of the
/// application is not competing with the taps and pans inside it for the same
/// pointer: once `DoDragDrop` or `start_drag` has the gesture, the platform
/// owns it and no Dart recognizer will see another event for that pointer at
/// all. Entering an arena would therefore promise an arbitration this widget
/// cannot honour - and losing one would leave the platform mid-drag with
/// nobody driving it.
final class RenderDragSource extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderDragSource({this.opaque = false});

  /// Whether this source is hittable across its whole area. A plain field for
  /// [RenderDropTarget.opaque]'s reason.
  bool opaque;

  /// Called once, when the pointer has travelled far enough.
  void Function()? onDragCommitted;

  /// Whether a gesture may commit at all.
  bool enabled = true;

  /// The travel that commits, or null for [touchSlopForKind].
  double? slop;

  int? _pointerId;
  Offset _origin = Offset.zero;
  double _threshold = kPrecisePointerSlop;

  /// Whether a press is being watched but has not committed yet. For the test
  /// that has to prove a press alone starts nothing.
  bool get isTracking => _pointerId != null;

  /// The travel the current press would have to make to commit.
  double get threshold => _threshold;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  bool hitTestSelf(Offset position) => opaque;

  @override
  void handlePointerEvent(PointerEvent event) {
    switch (event) {
      case PointerDownEvent():
        // Only the primary button drags. A right-press opens a context menu on
        // every desktop, and starting an OS drag from one would make that menu
        // unreachable.
        if (!enabled || event.button != PointerButton.primary) return;
        _pointerId = event.pointerId;
        _origin = event.logicalPosition;
        _threshold = slop ?? touchSlopForKind(event.kind);
      case PointerMoveEvent():
        if (_pointerId != event.pointerId) return;
        if ((event.logicalPosition - _origin).distance < _threshold) return;
        // Cleared *before* the callback: `startDrag` can park the isolate
        // inside a modal loop on Win32, and a second move arriving after it
        // returns must not commit again.
        _pointerId = null;
        if (enabled) onDragCommitted?.call();
      case PointerUpEvent():
      case PointerCancelEvent():
        if (_pointerId == event.pointerId) _pointerId = null;
      case PointerScrollEvent():
        break;
    }
  }

  /// A press that never released is not a press any more once this node leaves
  /// the tree; forgetting it here is what stops a remounted node from
  /// committing on the first move of an unrelated gesture.
  @override
  void detach() {
    _pointerId = null;
    super.detach();
  }
}
