/// The MDI area - sK1's `mdiarea.py`: rulers around a canvas, with a corner
/// button that cycles the document units.
///
/// The rulers are given the *same* zoom and pan the canvas is given, offset by
/// nothing else, which is what makes the tick under a shape's edge trustworthy.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'editor_scope.dart';
import 'metrics.dart';

/// Rulers, corner button and canvas.
class CanvasArea extends StatelessWidget {
  const CanvasArea({
    super.key,
    required this.model,
    required this.onViewportResized,
  });

  final EditorModel model;

  /// Reports the canvas box so zoom-to-fit knows what it is fitting into.
  final void Function(Size size) onViewportResized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!model.hasDocument) {
      return ColoredBox(
        color: theme.surface,
        child: const Center(child: Text('No document open')),
      );
    }
    final session = model.active;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: ChromeMetrics.of(Theme.of(context)).rulerThickness,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _UnitCorner(model: model),
              Expanded(
                child: ValueListenableBuilder<Offset?>(
                  valueListenable: model.pointer,
                  builder: (BuildContext context, Offset? cursor, _) =>
                      _GuideSource(
                    model: model,
                    horizontal: true,
                    child: RulerWidget(
                      zoom: session.zoom,
                      pan: session.pan.dx,
                      unit: model.units,
                      rulerThickness:
                          ChromeMetrics.of(Theme.of(context)).rulerThickness,
                      cursorPosition: cursor == null
                          ? null
                          : session.pan.dx + cursor.dx * session.zoom,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ValueListenableBuilder<Offset?>(
                valueListenable: model.pointer,
                builder: (BuildContext context, Offset? cursor, _) =>
                    _GuideSource(
                  model: model,
                  horizontal: false,
                  child: RulerWidget(
                    isVertical: true,
                    zoom: session.zoom,
                    pan: session.pan.dy,
                    unit: model.units,
                    rulerThickness:
                        ChromeMetrics.of(Theme.of(context)).rulerThickness,
                    cursorPosition: cursor == null
                        ? null
                        : session.pan.dy + cursor.dy * session.zoom,
                  ),
                ),
              ),
              Expanded(
                child: _MeasuredCanvas(
                  model: model,
                  onViewportResized: onViewportResized,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The square between the two rulers. Clicking it walks the unit list, which is
/// what sK1's `RulerSurface` corner does.
class _UnitCorner extends StatelessWidget {
  const _UnitCorner({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Document units: ${model.units.label} - click to change',
      child: GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: () {
          final next =
              (DocUnit.values.indexOf(model.units) + 1) % DocUnit.values.length;
          model.units = DocUnit.values[next];
          model.refresh('Units: ${model.units.label}');
        },
        child: SizedBox(
          width: ChromeMetrics.of(Theme.of(context)).rulerThickness,
          height: ChromeMetrics.of(Theme.of(context)).rulerThickness,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.surfaceAlternate,
              border: BoxBorder(color: theme.border, width: 1),
            ),
            child: Center(
              child: Text(
                model.units.label,
                // `labelSmall` - the caption/metadata role. It was 8 px, which
                // is below the size at which the hinting grid can keep a stem
                // straight, and five under the framework's base.
                style: theme.textTheme.labelSmall,
                color: theme.foregroundSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The canvas, plus the box measurement zoom-to-fit needs.
class _MeasuredCanvas extends StatelessWidget {
  const _MeasuredCanvas({
    required this.model,
    required this.onViewportResized,
  });

  final EditorModel model;
  final void Function(Size size) onViewportResized;

  @override
  Widget build(BuildContext context) {
    final session = model.active;
    final EditorScope? scope = EditorScope.maybeOf(context);
    return ContextMenuArea(
      enabled: scope != null,
      onOpen: _selectUnder,
      menuChildren: () => scope == null
          ? const <Widget>[]
          : scope.menus.widgets(scope.menus.canvas),
      child: _SizeReporter(
        onSize: onViewportResized,
        child: VectorCanvas(
          doc: session.document,
          page: session.page,
          zoom: session.zoom,
          pan: session.pan,
          tool: model.tool,
          selection: session.selection,
          snap: session.snap,
          showGrid: model.showGrid,
          showGuides: model.showGuides,
          polygonCorners: model.polygonCorners,
          freehandSmoothing: model.freehandSmoothing,
          activeLayer: session.layer,
          onZoomChanged: model.setZoom,
          onPanChanged: (pan) {
            session
              ..pan = pan
              ..viewTouched = true;
            model.refresh();
          },
          // Only what shows the pointer listens to it; see
          // EditorModel.pointer.
          onCursorMoved: (point) => model.cursor = point,
          onSelectionChanged: (_) => model.refresh(),
          onDocumentChanged: () => model.touch(),
          onObjectCreated: (Object object) {
            if (object is SelectableObject) model.objectCreated(object);
          },
          onTransformCommitted: model.commitTransform,
          onNodesEdited: model.nodesEdited,
          onTextCommitted: model.commitTextEdit,
          onHint: (String hint) => model.refresh(hint),
        ),
      ),
    );
  }

  /// What every editor does before a right-click menu: an object under the
  /// pointer that is not selected becomes the selection, so the menu is about
  /// what was clicked; empty page clears it, for the page's menu.
  void _selectUnder(Offset local) {
    final session = model.active;
    final zoom = session.zoom == 0 ? 1.0 : session.zoom;
    final point = (local - session.pan) / zoom;
    final hit =
        session.selection.hitTest(point, session.page, tolerance: 4 / zoom);
    if (hit == null) {
      if (model.hasSelection) model.deselect();
    } else if (!session.selection.contains(hit)) {
      model.pickObject(hit);
    }
  }
}

/// Reports its own size after layout, without rebuilding anything.
///
/// Needed because "fit the page into the window" is a question about pixels the
/// widget tree has, and the model does not. Reporting from layout rather than
/// from a rebuild keeps it out of the build phase.
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required super.child});

  final void Function(Size size) onSize;

  @override
  _RenderSizeReporter createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderSizeReporter renderObject) {
    renderObject.onSize = onSize;
  }
}

class _RenderSizeReporter extends RenderSingleChildBox {
  _RenderSizeReporter(this.onSize);

  void Function(Size size) onSize;
  Size _reported = Size.zero;

  /// The canvas box on screen, for a ruler drag that has to know where a
  /// point on the page is. One canvas is on screen at a time.
  static _RenderSizeReporter? current;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    current = this;
  }

  @override
  void detach() {
    if (identical(current, this)) current = null;
    super.detach();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
    } else {
      child.layout(constraints, parentUsesSize: true);
      size = child.size;
    }
    if (size != _reported) {
      _reported = size;
      onSize(size);
    }
  }
}

/// A ruler as a source of guides, as in CorelDRAW: drag out of the top ruler
/// for a horizontal guide and out of the left one for a vertical guide; let
/// go on the page to place it, back on the ruler to change your mind.
///
/// The guide follows the pointer while it is dragged - a real guide on the
/// page, added outside the history - and the drop is `guide.add`, one undo
/// step like any other command.
class _GuideSource extends StatefulWidget {
  const _GuideSource({
    required this.model,
    required this.horizontal,
    required this.child,
  });

  final EditorModel model;
  final bool horizontal;
  final Widget child;

  @override
  State<_GuideSource> createState() => _GuideSourceState();
}

class _GuideSourceState extends State<_GuideSource> {
  VectorGuide? _preview;

  EditorModel get model => widget.model;

  /// Where [global] is on the page, across the guide's orientation, and
  /// whether it is over the canvas at all.
  (double, bool)? _locate(Offset global) {
    final _RenderSizeReporter? canvas = _RenderSizeReporter.current;
    if (canvas == null || !model.hasDocument) return null;
    final Offset local = canvas.globalToLocal(global);
    final bool over = local.dx >= 0 &&
        local.dy >= 0 &&
        local.dx < canvas.size.width &&
        local.dy < canvas.size.height;
    final session = model.active;
    final double zoom = session.zoom == 0 ? 1.0 : session.zoom;
    final Offset point = (local - session.pan) / zoom;
    return (widget.horizontal ? point.dy : point.dx, over);
  }

  void _start(DragStartDetails details) {
    final (double, bool)? at = _locate(details.globalPosition);
    if (at == null) return;
    final GuideLayer layer = model.guideLayer;
    final VectorGuide guide = VectorGuide(
      parent: layer,
      position: at.$1,
      isHorizontal: widget.horizontal,
    );
    layer.children.add(guide);
    _preview = guide;
    model.refresh('Release on the page to place the guide');
  }

  void _update(DragUpdateDetails details) {
    final VectorGuide? guide = _preview;
    final (double, bool)? at = _locate(details.globalPosition);
    if (guide == null || at == null) return;
    guide.position = at.$1;
    model.refresh(at.$2
        ? 'Release on the page to place the guide'
        : 'Release on the ruler to cancel');
  }

  void _end(Offset global) {
    final VectorGuide? guide = _preview;
    _preview = null;
    if (guide == null) return;
    guide.parent?.children.remove(guide);
    final (double, bool)? at = _locate(global);
    final CommandRegistry? registry = EditorScope.maybeOf(context)?.registry;
    if (at == null || !at.$2 || registry == null) {
      model.refresh('Guide cancelled');
      return;
    }
    registry.execute('guide.add', <String, Object?>{
      'orientation': widget.horizontal ? 'horizontal' : 'vertical',
      'position': at.$1,
    });
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onPanStart: _start,
        onPanUpdate: _update,
        onPanEnd: (DragEndDetails details) => _end(details.globalPosition),
        child: widget.child,
      );
}
