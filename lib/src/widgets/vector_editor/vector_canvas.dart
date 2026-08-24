/// The interactive vector editor canvas.
///
/// The canvas is *controlled*: zoom, pan, the active tool and the selection all
/// live outside it, because every other part of an editor window - the rulers,
/// the property bar, the status bar - has to agree with them. A canvas that
/// owned its own zoom would leave the ruler showing a different one.
///
/// It also paints strictly inside its own box. See the header of
/// `vector_renderer.dart` for what happens when a canvas does not.
///
/// ## Why this reads raw pointer events instead of using [GestureDetector]
///
/// The canvas used to wrap itself in a `GestureDetector` and take `onTapDown`,
/// `onPanStart`, `onPanUpdate` and `onPanEnd`. Four separate things that a
/// vector editor needs are not expressible that way, and all four were broken:
///
///  * **the middle button.** Every drag recognizer in this framework declines a
///    press whose `button` is not the one it was built for, by design - so a
///    middle-button press produced no gesture at all and the universal
///    pan-with-the-middle-button did nothing. There is no middle-button drag
///    callback to ask for.
///  * **the wheel.** A `PointerScrollEvent` is not a gesture and never reaches
///    a recognizer; it has to be claimed from the [PointerSignalResolver]
///    during dispatch, which only a `PointerEventTarget` can do.
///  * **where the press was.** `DragStartDetails.globalPosition` is where the
///    *slop was crossed*, deliberately, which is right for dragging a list and
///    wrong for grabbing a 7-pixel handle: the resize anchor would be two or
///    three pixels away from the handle the user actually pressed.
///  * **click versus drag.** sK1 draws that line at five screen pixels of total
///    travel (`SelectController.do_action`), and Inkscape at a similar
///    threshold. The pan recognizer's slop is a different number chosen for a
///    different purpose, and the tap/pan arena hides the press from a tool that
///    needs to know about it before the arena resolves.
///
/// So the leaf render object is a [PointerEventTarget] and this state is the
/// small state machine over it. Nothing is arbitrated, because nothing else is
/// competing: the canvas is a leaf and the only thing under the pointer.
library;

import 'dart:math' as math;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../gestures/binding.dart';
import '../../gestures/tap.dart';
import '../../graphics/display_list.dart';
import '../../graphics/vector/doc_methods.dart';
import '../../graphics/vector/document.dart';
import '../../graphics/vector/primitives.dart';
import '../../graphics/vector/selectable_objects.dart';
import '../../graphics/vector/structural_objects.dart';
import '../../layout/render_box.dart';
import '../../platform/input_events.dart';
import '../element.dart';
import '../focus.dart';
import '../focus_scope.dart';
import '../keyboard_router.dart';
import '../pointer_router.dart';
import '../widget.dart';
import 'selection.dart';
import 'snap_manager.dart';
import 'text_edit_controller.dart';
import 'text_metrics.dart';
import 'tool_controller.dart';
import 'vector_renderer.dart';

/// How far, in device pixels, a press may travel and still be a click.
///
/// sK1's number, from `SelectController.do_action`: `change_x < 5 and
/// change_y < 5`, measured in window pixels. Below it a press-release is a
/// selection click; above it, it is a drag. Measuring in screen pixels rather
/// than document units is what keeps the threshold the same physical distance
/// at every zoom.
const double kCanvasDragSlopPixels = 5.0;

/// The zoom multiplier one notch of the wheel applies.
///
/// Applied as `base ^ -delta` rather than as a fixed step per event, which is
/// what makes a trackpad's fractional deltas add up correctly: ten reports of
/// 0.1 compose to exactly the same zoom as one report of 1.0, because
/// `b^0.1` ten times over is `b^1`. A fixed step per event would zoom ten
/// times as far on a trackpad as on a wheel.
const double kWheelZoomBase = 1.2;

/// Device pixels the view pans per line of horizontal wheel travel.
const double kWheelPanPixels = 48.0;

/// Where the canvas is on screen, refreshed every paint.
///
/// A gesture arrives in root coordinates and the tools work in document
/// coordinates, so something has to know where the canvas box starts. The
/// render object is the only thing that does, and it learns it during paint;
/// this is the handoff, kept out of the widget so no rebuild is involved.
final class CanvasViewport {
  Offset origin = Offset.zero;
  Size size = Size.zero;

  Rect get rect => Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
}

/// The interactive vector editor canvas.
class VectorCanvas extends StatefulWidget {
  const VectorCanvas({
    super.key,
    required this.doc,
    required this.page,
    required this.zoom,
    required this.pan,
    required this.tool,
    required this.selection,
    this.snap,
    this.showGrid = true,
    this.showGuides = true,
    this.polygonCorners = 5,
    this.onZoomChanged,
    this.onPanChanged,
    this.onCursorMoved,
    this.onSelectionChanged,
    this.onDocumentChanged,
    this.onObjectCreated,
    this.onTransformCommitted,
    this.onTextCommitted,
    this.onHint,
  });

  final VectorDocument doc;
  final VectorPage page;

  /// Device pixels per document point.
  final double zoom;

  /// Where document (0,0) lands inside the canvas box, in device pixels.
  final Offset pan;

  final ToolMode tool;
  final SelectionManager selection;
  final SnapManager? snap;
  final bool showGrid;
  final bool showGuides;

  /// Corner count for newly created polygons; the sK1 polygon config plugin.
  final int polygonCorners;

  final void Function(double zoom, Offset pan)? onZoomChanged;
  final void Function(Offset pan)? onPanChanged;

  /// The cursor, in document coordinates, or null when it left the canvas.
  final void Function(Offset? documentPoint)? onCursorMoved;

  final void Function(SelectionManager selection)? onSelectionChanged;

  /// The document was mutated and everything showing it must be rebuilt.
  final void Function()? onDocumentChanged;

  /// A tool finished creating an object, so it can be pushed onto undo.
  final void Function(Object object)? onObjectCreated;

  /// A move or resize finished. Carries both ends of the gesture, so the
  /// editor records one undo entry for the whole drag instead of one per
  /// pointer move - or, as before, none at all.
  final void Function(SelectionEdit edit)? onTransformCommitted;

  /// An in-canvas text edit was committed, with the string it replaced.
  final void Function(VectorText object, String before, String after)?
      onTextCommitted;

  /// A one-line description of what the pointer would do here.
  ///
  /// CorelDRAW's status bar does this - "click to select; second click to
  /// rotate; Shift+click for multiple selection" - and it is the cheapest
  /// quality signal an editor has.
  final void Function(String hint)? onHint;

  @override
  State<VectorCanvas> createState() => VectorCanvasState();
}

class VectorCanvasState extends State<VectorCanvas>
    implements KeyboardEventTarget, TextInputTarget {
  final CanvasViewport _viewport = CanvasViewport();
  late DocumentMethods _methods;
  late SnapManager _snap;
  ToolController? _controller;
  ToolMode? _controllerTool;

  late final FocusNode _focusNode =
      FocusNode(debugLabel: 'VectorCanvas', target: this);

  /// Counts the clicks of a run, preferring the platform's own count.
  ///
  /// The same [MultiTapCounter] the tap recognizer uses, for the same reason
  /// its documentation gives: the double-click interval and rectangle are
  /// accessibility settings the user chose, and re-deriving them from a
  /// constant overrides that choice silently.
  final MultiTapCounter _clicks = MultiTapCounter();

  // --- gesture state ------------------------------------------------------

  int? _activePointer;
  PointerButton _activeButton = PointerButton.primary;
  Offset _pressGlobal = Offset.zero;
  int _pressClickCount = 1;
  bool _isDragging = false;

  /// Viewport pan in progress: the middle button, the hand tool, or Space.
  Offset? _panStart;

  bool _spaceHeld = false;

  CanvasTextEditor? _textEditor;

  /// Whether a text object is open for editing in the canvas.
  bool get isEditingText => _textEditor != null;

  /// The text being edited, or null.
  CanvasTextEditor? get textEditor => _textEditor;

  /// The rubber band currently being dragged, in document units, or null.
  Rect? get marqueeRect {
    final ToolController? controller = _controller;
    return controller is SelectToolController ? controller.marquee : null;
  }

  @override
  void initState() {
    super.initState();
    // Text has no geometry paths, so without a measurer every text object has
    // a zero bounding box and is invisible to the pointer. Installing it here
    // means any document a canvas shows has clickable text.
    VectorTextMetrics.install();
    _methods = DocumentMethods(widget.doc);
    _snap = widget.snap ?? SnapManager();
    widget.doc.update();
  }

  @override
  void didUpdateWidget(VectorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.doc, widget.doc)) {
      _cancelTextEdit();
      _methods = DocumentMethods(widget.doc);
      _controller = null;
      _controllerTool = null;
      widget.doc.update();
    }
    if (oldWidget.tool != widget.tool) _commitTextEdit();
    if (widget.snap != null && !identical(oldWidget.snap, widget.snap)) {
      _snap = widget.snap!;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// The modifiers the window last saw a key transition for.
  ///
  /// Read from the owner rather than tracked here, because a modifier pressed
  /// before the canvas ever had focus still has to count: Shift+clicking a
  /// freshly opened window is the first thing anybody tries.
  Set<KeyModifier> get _modifiers {
    final BuildContext ctx = context;
    if (ctx is Element) return ctx.owner?.heldModifiers ?? const <KeyModifier>{};
    return const <KeyModifier>{};
  }

  /// The tool controller for the active tool, built on demand.
  ///
  /// Null for tools the canvas drives itself - zoom and pan are viewport
  /// operations, not document ones, and giving them a `ToolController` would
  /// mean handing the document to something that never touches it.
  ToolController? get _tool {
    if (_controllerTool != widget.tool) {
      _controllerTool = widget.tool;
      _controller = switch (widget.tool) {
        ToolMode.select || ToolMode.shaper => SelectToolController(
            doc: widget.doc,
            methods: _methods,
            selection: widget.selection,
            snap: _snap,
          ),
        ToolMode.rectangle => RectangleToolController(
            doc: widget.doc,
            methods: _methods,
            selection: widget.selection,
            snap: _snap,
          ),
        ToolMode.circle => CircleToolController(
            doc: widget.doc,
            methods: _methods,
            selection: widget.selection,
            snap: _snap,
          ),
        ToolMode.polygon => PolygonToolController(
            doc: widget.doc,
            methods: _methods,
            selection: widget.selection,
            snap: _snap,
            corners: widget.polygonCorners,
          ),
        ToolMode.curve => CurveToolController(
            doc: widget.doc,
            methods: _methods,
            selection: widget.selection,
            snap: _snap,
          ),
        ToolMode.text => TextToolController(
            doc: widget.doc,
            methods: _methods,
            selection: widget.selection,
            snap: _snap,
          ),
        ToolMode.zoom || ToolMode.fleur => null,
      };
    }
    final ToolController? controller = _controller;
    if (controller != null) {
      controller
        ..modifiers = _modifiers
        ..zoom = widget.zoom;
    }
    return controller;
  }

  /// Converts a root-space pointer position into document coordinates.
  Offset toDocument(Offset global) {
    final local = global - _viewport.origin;
    final zoom = widget.zoom == 0 ? 1.0 : widget.zoom;
    return (local - widget.pan) / zoom;
  }

  /// Converts a document point into root-space device pixels.
  Offset toGlobal(Offset document) =>
      _viewport.origin + widget.pan + document * widget.zoom;

  /// The canvas box in root coordinates, for rulers and hit tests.
  Rect get viewportRect => _viewport.rect;

  void _zoomAround(Offset globalFocus, double factor) {
    final before = toDocument(globalFocus);
    final zoom = (widget.zoom * factor).clamp(0.02, 64.0);
    // Keep the focus point pinned: the pan that satisfies
    // local = pan + doc * zoom for the same doc point.
    final local = globalFocus - _viewport.origin;
    final pan = local - before * zoom;
    widget.onZoomChanged?.call(zoom, pan);
  }

  // -------------------------------------------------------------------------
  // Pointer
  // -------------------------------------------------------------------------

  void _handlePointerEvent(PointerEvent event) {
    switch (event) {
      case PointerScrollEvent():
        // Claimed through the resolver so a wheel notch over the canvas is not
        // also applied by a scrollable that happens to contain it.
        final GestureBinding? binding = GestureBinding.current;
        if (binding == null) {
          _applyWheel(event);
        } else {
          binding.signalResolver.register(event, _applyWheel);
        }
      case PointerDownEvent():
        _handleDown(event);
      case PointerMoveEvent():
        _handleMove(event);
      case PointerUpEvent():
        _handleUp(event);
      case PointerCancelEvent():
        _handleCancel();
    }
  }

  void _handleDown(PointerDownEvent event) {
    _focusNode.requestFocus(FocusChangeReason.pointer);
    _activePointer = event.pointerId;
    _activeButton = event.button;
    _pressGlobal = event.logicalPosition;
    _isDragging = false;
    // Only the primary button advances the run: a middle-click to pan between
    // two left clicks must not make the second of them a double click.
    if (event.button == PointerButton.primary) {
      _pressClickCount = _clicks.countTap(event);
    }

    // The middle button pans, in every tool. So does Space, and so does the
    // hand tool. This is the one gesture no editor makes you change tool for.
    if (event.button == PointerButton.middle ||
        _spaceHeld ||
        widget.tool == ToolMode.fleur) {
      _panStart = widget.pan;
      return;
    }
    if (event.button != PointerButton.primary) return;

    // Everything else waits: a press is not yet a drag, and the tools that
    // create geometry must not put a one-by-one rectangle in the document for
    // a click that was only ever a click.
  }

  void _handleMove(PointerMoveEvent event) {
    widget.onCursorMoved?.call(toDocument(event.logicalPosition));

    final Offset? panStart = _panStart;
    if (panStart != null) {
      widget.onPanChanged
          ?.call(panStart + (event.logicalPosition - _pressGlobal));
      return;
    }
    if (event.pointerId != _activePointer) return;
    if (_activeButton != PointerButton.primary) return;

    if (!_isDragging) {
      final Offset travel = event.logicalPosition - _pressGlobal;
      if (travel.dx.abs() < kCanvasDragSlopPixels &&
          travel.dy.abs() < kCanvasDragSlopPixels) {
        return;
      }
      _isDragging = true;
      _beginDrag();
    }
    _continueDrag(event.logicalPosition);
  }

  void _handleUp(PointerUpEvent event) {
    if (_panStart != null) {
      _panStart = null;
      _activePointer = null;
      return;
    }
    if (event.pointerId != _activePointer) return;
    _activePointer = null;
    if (_activeButton != PointerButton.primary) return;

    if (_isDragging) {
      _endDrag(event.logicalPosition);
    } else {
      _handleClick(event.logicalPosition);
    }
    _isDragging = false;
  }

  void _handleCancel() {
    _panStart = null;
    _activePointer = null;
    if (_isDragging) {
      _tool?.onCancel();
      _isDragging = false;
      _report(documentChanged: true);
    }
  }

  // --- drags --------------------------------------------------------------

  void _beginDrag() {
    if (widget.tool == ToolMode.zoom) return;
    _commitTextEdit();
    _tool?.onPointerDown(toDocument(_pressGlobal), widget.page);
    _report();
  }

  void _continueDrag(Offset global) {
    if (widget.tool == ToolMode.zoom) {
      setState(() {});
      return;
    }
    _tool?.onPointerMove(toDocument(global), widget.page);
    _report();
  }

  void _endDrag(Offset global) {
    if (widget.tool == ToolMode.zoom) {
      // Dragging with the zoom tool frames a rectangle, which is sK1's
      // `zoom_to_rectangle`.
      final Rect band =
          Rect.fromPoints(toDocument(_pressGlobal), toDocument(global));
      if (band.width > 1 && band.height > 1) _zoomToRect(band);
      return;
    }
    final ToolController? controller = _tool;
    if (controller == null) return;
    controller.onPointerUp(toDocument(global), widget.page);

    final Object? created = controller.takeCreatedObject();
    if (created != null) widget.onObjectCreated?.call(created);
    if (controller is SelectToolController) {
      final SelectionEdit? edit = controller.takeEdit();
      if (edit != null) widget.onTransformCommitted?.call(edit);
    }
    _report(documentChanged: created != null);
  }

  void _zoomToRect(Rect band) {
    final Size box = _viewport.size;
    if (box.width <= 0 || box.height <= 0) return;
    final double scale = (box.width / band.width) < (box.height / band.height)
        ? box.width / band.width
        : box.height / band.height;
    final double zoom = scale.clamp(0.02, 64.0);
    widget.onZoomChanged?.call(
      zoom,
      Offset(
        (box.width - band.width * zoom) / 2 - band.left * zoom,
        (box.height - band.height * zoom) / 2 - band.top * zoom,
      ),
    );
  }

  // --- clicks -------------------------------------------------------------

  void _handleClick(Offset global) {
    final Offset point = toDocument(global);

    if (widget.tool == ToolMode.zoom) {
      _zoomAround(global, _modifiers.contains(KeyModifier.shift) ? 1 / 1.4 : 1.4);
      return;
    }
    if (widget.tool == ToolMode.fleur) return;

    // A click inside an open text edit moves the caret rather than reselecting.
    final CanvasTextEditor? editor = _textEditor;
    if (editor != null) {
      if (editor.object.cacheBbox
          .inflate(SelectionManager.objectGrabPixels / _safeZoom)
          .contains(point)) {
        final Offset local = _toTextLocal(editor.object, point);
        if (_pressClickCount >= 2) {
          editor.selectWordAtX(local.dx);
        } else {
          editor.placeCaretAtX(local.dx);
        }
        _report();
        return;
      }
      _commitTextEdit();
    }

    final ToolController? controller = _tool;
    if (controller is SelectToolController) {
      if (_pressClickCount >= 2) {
        final SelectableObject? hit = controller.objectAt(point, widget.page);
        if (hit is VectorText) {
          _beginTextEdit(hit, point);
          return;
        }
      }
      controller.click(point, widget.page);
      _report();
      _reportSelectHint();
      return;
    }
    if (controller == null) return;

    // The creators need a drag to describe a size; a bare click on one would
    // leave a one-by-one shape behind. The click-driven tools are the two that
    // place rather than stretch.
    if (widget.tool == ToolMode.text || widget.tool == ToolMode.curve) {
      controller
        ..onPointerDown(point, widget.page)
        ..onPointerUp(point, widget.page);
      final Object? created = controller.takeCreatedObject();
      if (created != null) widget.onObjectCreated?.call(created);
      if (created is VectorText) _beginTextEdit(created, point);
      _report(documentChanged: true);
    }
  }

  /// The CorelDRAW status-bar line: what the next click would do, here, now.
  void _reportSelectHint() {
    final void Function(String)? onHint = widget.onHint;
    if (onHint == null) return;
    onHint(
      widget.selection.hasSelection
          ? '${widget.selection.count} selected - drag to move, drag a handle '
              'to resize (Shift keeps the ratio), Shift+click adds or removes'
          : 'Click to select, drag to band-select, Shift+click adds to the '
              'selection',
    );
  }

  double get _safeZoom => widget.zoom == 0 ? 1.0 : widget.zoom;

  /// A document point expressed in a text object's own coordinates.
  ///
  /// The full inverse of the affine, not just a subtraction of the
  /// translation: a text that has been scaled or rotated still has to put its
  /// caret where the user clicked.
  Offset _toTextLocal(VectorText object, Offset point) {
    final List<double> t = object.trafo;
    final double det = t[0] * t[3] - t[1] * t[2];
    if (det == 0) return point - Offset(t[4], t[5]);
    final double dx = point.dx - t[4];
    final double dy = point.dy - t[5];
    return Offset(
      (t[3] * dx - t[2] * dy) / det,
      (-t[1] * dx + t[0] * dy) / det,
    );
  }

  // -------------------------------------------------------------------------
  // Text editing
  // -------------------------------------------------------------------------

  void _beginTextEdit(VectorText object, Offset at) {
    widget.selection.select(object);
    final Offset local = _toTextLocal(object, at);
    _textEditor = CanvasTextEditor(
      object,
      caretOffset: VectorTextMetrics.offsetAtX(object, local.dx),
    );
    _focusNode.requestFocus(FocusChangeReason.pointer);
    widget.onHint?.call(
      'Editing text - Escape abandons the change, Enter or a click outside '
      'keeps it',
    );
    _report();
  }

  /// Keeps the edit and reports it for undo.
  void _commitTextEdit() {
    final CanvasTextEditor? editor = _textEditor;
    if (editor == null) return;
    _textEditor = null;
    if (editor.isDirty) {
      widget.onTextCommitted
          ?.call(editor.object, editor.originalText, editor.object.textContent);
    }
    _report(documentChanged: editor.isDirty);
  }

  /// Throws the edit away, restoring the original string.
  void _cancelTextEdit() {
    final CanvasTextEditor? editor = _textEditor;
    if (editor == null) return;
    _textEditor = null;
    editor.cancel();
    _report(documentChanged: true);
  }

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  @override
  bool handleKeyEvent(KeyEvent event) {
    // Space is a held modifier here, not a character: it turns the primary
    // drag into a pan, which is the other half of the middle-button gesture.
    // Not while typing, where a space is a space.
    if (event.logicalKey == logicalKeySpace && _textEditor == null) {
      _spaceHeld = event is KeyDownEvent;
      return true;
    }

    final CanvasTextEditor? editor = _textEditor;
    if (editor != null) {
      if (event is KeyDownEvent && event.logicalKey == logicalKeyEscape) {
        _cancelTextEdit();
        return true;
      }
      if (event is KeyDownEvent && event.logicalKey == logicalKeyEnter) {
        _commitTextEdit();
        return true;
      }
      if (editor.handleKey(event)) {
        _report();
        return true;
      }
      return false;
    }

    if (event is KeyDownEvent && event.logicalKey == logicalKeyEscape) {
      if (!widget.selection.hasSelection) return false;
      widget.selection.deselectAll();
      _report();
      return true;
    }
    return false;
  }

  @override
  bool handleTextInput(TextInputEvent event) {
    final CanvasTextEditor? editor = _textEditor;
    if (editor == null) return false;
    if (!editor.insert(event.text)) return false;
    _report();
    return true;
  }

  // -------------------------------------------------------------------------
  // Wheel
  // -------------------------------------------------------------------------

  /// One wheel or trackpad report.
  ///
  /// **The mapping, and why it is not sK1's.** sK1 scrolls on a plain wheel,
  /// scrolls horizontally on Ctrl+wheel and zooms on Shift+wheel
  /// (`AbstractController.wheel`). Shift+wheel cannot be honoured here: the
  /// Win32 backend converts Shift+vertical-wheel into a *horizontal* scroll
  /// before any widget sees it - the conventional stand-in for a mouse with no
  /// tilt wheel - and `PointerScrollEvent` carries no modifier set to recover
  /// it from. That is a framework limitation, recorded rather than worked
  /// around.
  ///
  /// So the canvas takes CorelDRAW's default instead, which is also what the
  /// user asked for: **a vertical wheel zooms about the cursor**, and a
  /// horizontal delta - a tilt wheel, a trackpad swipe, or Shift+wheel on
  /// Windows - pans sideways. Zooming about the cursor rather than the centre
  /// of the view is the part that matters: a zoom that walks away from what
  /// you are looking at is the classic complaint.
  void _applyWheel(PointerScrollEvent event) {
    // A "line" is one detent. Pixel-unit devices report far larger numbers, so
    // they are divided down to detents before anything else happens.
    final double unit =
        event.scrollDeltaUnit == ScrollDeltaUnit.lines ? 1.0 : 1 / 40.0;
    final double dx = event.scrollDelta.dx * unit;
    final double dy = event.scrollDelta.dy * unit;

    if (dx != 0) {
      widget.onPanChanged?.call(widget.pan - Offset(dx * kWheelPanPixels, 0));
    }
    if (dy != 0) {
      _zoomAround(event.logicalPosition, math.pow(kWheelZoomBase, -dy).toDouble());
    }
  }

  // -------------------------------------------------------------------------

  void _report({bool documentChanged = false}) {
    if (mounted) setState(() {});
    widget.onSelectionChanged?.call(widget.selection);
    if (documentChanged) widget.onDocumentChanged?.call();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        autofocus: true,
        child: _CanvasLeaf(
          doc: widget.doc,
          page: widget.page,
          zoom: widget.zoom,
          pan: widget.pan,
          selection: widget.selection,
          tool: widget.tool,
          showGrid: widget.showGrid,
          showGuides: widget.showGuides,
          viewport: _viewport,
          marquee: marqueeRect,
          textEditor: _textEditor,
          onPointer: _handlePointerEvent,
        ),
      );
}

final class _CanvasLeaf extends RenderObjectWidget {
  const _CanvasLeaf({
    required this.doc,
    required this.page,
    required this.zoom,
    required this.pan,
    required this.selection,
    required this.tool,
    required this.showGrid,
    required this.showGuides,
    required this.viewport,
    required this.marquee,
    required this.textEditor,
    required this.onPointer,
  });

  final VectorDocument doc;
  final VectorPage page;
  final double zoom;
  final Offset pan;
  final SelectionManager selection;
  final ToolMode tool;
  final bool showGrid;
  final bool showGuides;
  final CanvasViewport viewport;
  final Rect? marquee;
  final CanvasTextEditor? textEditor;
  final void Function(PointerEvent event) onPointer;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderVectorCanvas createRenderObject(BuildContext context) =>
      RenderVectorCanvas(
        doc: doc,
        page: page,
        zoom: zoom,
        pan: pan,
        selection: selection,
        tool: tool,
        showGrid: showGrid,
        showGuides: showGuides,
        viewport: viewport,
        marquee: marquee,
        textEditor: textEditor,
        onPointer: onPointer,
      );

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderVectorCanvas renderObject) {
    renderObject
      ..doc = doc
      ..page = page
      ..zoom = zoom
      ..pan = pan
      ..selection = selection
      ..tool = tool
      ..showGrid = showGrid
      ..showGuides = showGuides
      ..viewport = viewport
      ..marquee = marquee
      ..textEditor = textEditor
      ..onPointer = onPointer;
  }
}

/// The leaf that rasterizes one page of a [VectorDocument].
final class RenderVectorCanvas extends RenderBox implements PointerEventTarget {
  RenderVectorCanvas({
    required VectorDocument doc,
    required VectorPage page,
    required double zoom,
    required Offset pan,
    required SelectionManager selection,
    required ToolMode tool,
    required bool showGrid,
    required bool showGuides,
    required CanvasViewport viewport,
    Rect? marquee,
    CanvasTextEditor? textEditor,
    this.onPointer,
  })  : _doc = doc,
        _page = page,
        _zoom = zoom,
        _pan = pan,
        _selection = selection,
        _tool = tool,
        _showGrid = showGrid,
        _showGuides = showGuides,
        _viewport = viewport,
        _marquee = marquee,
        _textEditor = textEditor;

  /// Where every pointer event on this canvas goes.
  ///
  /// The state machine lives in the widget's `State`, which knows the tool, the
  /// zoom and the callbacks; this render object's only job is to be the node
  /// the router can find and capture.
  void Function(PointerEvent event)? onPointer;

  VectorDocument _doc;
  set doc(VectorDocument value) {
    _doc = value;
    markNeedsPaint();
  }

  VectorPage _page;
  set page(VectorPage value) {
    _page = value;
    markNeedsPaint();
  }

  double _zoom;
  set zoom(double value) {
    if (_zoom == value) return;
    _zoom = value;
    markNeedsPaint();
  }

  Offset _pan;
  set pan(Offset value) {
    if (_pan == value) return;
    _pan = value;
    markNeedsPaint();
  }

  SelectionManager _selection;
  set selection(SelectionManager value) {
    _selection = value;
    markNeedsPaint();
  }

  ToolMode _tool;
  set tool(ToolMode value) {
    if (_tool == value) return;
    _tool = value;
    markNeedsPaint();
  }

  bool _showGrid;
  set showGrid(bool value) {
    if (_showGrid == value) return;
    _showGrid = value;
    markNeedsPaint();
  }

  bool _showGuides;
  set showGuides(bool value) {
    if (_showGuides == value) return;
    _showGuides = value;
    markNeedsPaint();
  }

  CanvasViewport _viewport;
  set viewport(CanvasViewport value) {
    _viewport = value;
    markNeedsPaint();
  }

  Rect? _marquee;
  set marquee(Rect? value) {
    if (_marquee == value) return;
    _marquee = value;
    markNeedsPaint();
  }

  CanvasTextEditor? _textEditor;
  set textEditor(CanvasTextEditor? value) {
    _textEditor = value;
    markNeedsPaint();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) => onPointer?.call(event);

  @override
  void performLayout() {
    // A canvas takes whatever it is given, but "whatever it is given" has to be
    // finite: an unbounded constraint here means the caller forgot an Expanded,
    // and a canvas that silently sized itself to a default would hide that.
    size = Size(
      constraints.hasBoundedWidth ? constraints.maxWidth : constraints.minWidth,
      constraints.hasBoundedHeight
          ? constraints.maxHeight
          : constraints.minHeight,
    );
  }

  @override
  void paint(DisplayList list, Offset offset) {
    _viewport
      ..origin = offset
      ..size = size;
    VectorRenderer.renderPage(
      list,
      _doc,
      _page,
      viewport: Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      zoom: _zoom,
      pan: _pan + offset,
      showGrid: _showGrid,
      showGuides: _showGuides,
      selection: _selection,
      currentTool: _tool,
      rubberBand: _marquee,
      caret: _caret(),
    );
  }

  /// The caret and selection of an open text edit, in document units.
  TextEditCaret? _caret() {
    final CanvasTextEditor? editor = _textEditor;
    if (editor == null) return null;
    final VectorText object = editor.object;
    final VectorTextInk ink = object.ink;
    final TextSelectionRange selection = TextSelectionRange(
      editor.selectionX(editor.value.selection.start),
      editor.selectionX(editor.value.selection.end),
    );
    return TextEditCaret(
      trafo: object.trafo,
      caretX: editor.caretX,
      ascent: ink.ascent,
      descent: ink.descent,
      selection: editor.value.selection.isCollapsed ? null : selection,
    );
  }
}
