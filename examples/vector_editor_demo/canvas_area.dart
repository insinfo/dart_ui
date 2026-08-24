/// The MDI area - sK1's `mdiarea.py`: rulers around a canvas, with a corner
/// button that cycles the document units.
///
/// The rulers are given the *same* zoom and pan the canvas is given, offset by
/// nothing else, which is what makes the tick under a shape's edge trustworthy.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';
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
    final cursor = model.cursor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: ChromeMetrics.rulerThickness,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _UnitCorner(model: model),
              Expanded(
                child: RulerWidget(
                  zoom: session.zoom,
                  pan: session.pan.dx,
                  unit: model.units,
                  rulerThickness: ChromeMetrics.rulerThickness,
                  cursorPosition: cursor == null
                      ? null
                      : session.pan.dx + cursor.dx * session.zoom,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              RulerWidget(
                isVertical: true,
                zoom: session.zoom,
                pan: session.pan.dy,
                unit: model.units,
                rulerThickness: ChromeMetrics.rulerThickness,
                cursorPosition: cursor == null
                    ? null
                    : session.pan.dy + cursor.dy * session.zoom,
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
          final next = (DocUnit.values.indexOf(model.units) + 1) %
              DocUnit.values.length;
          model.units = DocUnit.values[next];
          model.refresh('Units: ${model.units.label}');
        },
        child: SizedBox(
          width: ChromeMetrics.rulerThickness,
          height: ChromeMetrics.rulerThickness,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.surfaceAlternate,
              border: BoxBorder(color: theme.border, width: 1),
            ),
            child: Center(
              child: Text(
                model.units.label,
                color: theme.foregroundSecondary,
                fontSize: 8,
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
    return _SizeReporter(
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
        onZoomChanged: model.setZoom,
        onPanChanged: (pan) {
          session.pan = pan;
          model.refresh();
        },
        onCursorMoved: (point) {
          model.cursor = point;
          model.refresh();
        },
        onSelectionChanged: (_) => model.refresh(),
        onDocumentChanged: () => model.touch(),
        onObjectCreated: (_) => model.touch('Object created'),
        onTransformCommitted: model.commitTransform,
        onTextCommitted: model.commitTextEdit,
        onHint: (String hint) => model.refresh(hint),
      ),
    );
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
