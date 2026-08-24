/// Pure Dart renderer for vector document objects.
///
/// One rule governs everything here: the renderer paints **inside the viewport
/// it is handed** and nowhere else. An earlier version filled a
/// `Rect.fromLTWH(-10000, -10000, 20000, 20000)` desktop rectangle in global
/// coordinates with no clip, which silently repainted the whole window - the
/// menu bar, the property bar and the tool box were all laid out correctly and
/// then buried under the canvas' own background, because a display list is
/// painted in order and the canvas comes after them. Anything that wants to
/// cover "everything" must be told how big everything is.
library;

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/color.dart';
import '../../graphics/display_list.dart';
import '../../graphics/display_list_geometry.dart';
import '../../graphics/display_list_opcodes.dart';
import '../../graphics/vector/document.dart';
import '../../graphics/vector/document_object.dart';
import '../../graphics/vector/primitives.dart';
import '../../graphics/vector/selectable_objects.dart';
import '../../graphics/vector/structural_objects.dart';
import '../../rendering/text/font_registry.dart';
import '../../rendering/text/text_painter.dart';
import 'selection.dart';

/// Colours the canvas paints with, named so the editor can match them.
abstract final class VectorCanvasPalette {
  /// The desk the page sits on.
  static const Color desktop = Color(0xFF8C8C8C);

  /// The paper itself.
  static const Color sheet = Color(0xFFFFFFFF);

  /// The hairline around the paper.
  static const Color sheetBorder = Color(0xFF5A5A5A);

  static const Color sheetShadow = Color(0x40000000);
  static const Color grid = Color(0x1A000000);
  static const Color guide = Color(0xFF00A0C0);
  static const Color selection = Color(0xFF1E88E5);
  static const Color handleFill = Color(0xFFFFFFFF);
  static const Color rubberBand = Color(0xFF1E88E5);

  /// The in-canvas text caret. Solid black rather than the selection blue:
  /// a caret is a text affordance and reads as one only at full contrast.
  static const Color caret = Color(0xFF000000);

  /// The wash behind selected characters while a text is being edited.
  static const Color textSelection = Color(0x553F8FE0);
}

/// Renders a [VectorDocument] page to a [DisplayList].
class VectorRenderer {
  /// Compiles the active [page] of [doc] into [list].
  ///
  /// [viewport] is the box, in the display list's current coordinate space,
  /// that this canvas owns. It bounds the desktop fill and the clip, and it is
  /// the reason a canvas can be one cell of a larger window without erasing
  /// its neighbours.
  static void renderPage(
    DisplayList list,
    VectorDocument doc,
    VectorPage page, {
    required Rect viewport,
    double zoom = 1.0,
    Offset pan = Offset.zero,
    bool showGrid = true,
    bool showGuides = true,
    SelectionManager? selection,
    ToolMode? currentTool,
    Rect? rubberBand,
    TextEditCaret? caret,
  }) {
    list.save();
    list.clipRectangle(viewport);

    // 1. Desktop background - the viewport, never more.
    final bgPaint =
        list.addPaint(colorArgb: VectorCanvasPalette.desktop.value);
    list.drawRectangle(viewport, bgPaint);

    // Apply pan and zoom.
    list.save();
    list.transform2D(Transform2D.compose(
      translation: pan,
      scaleX: zoom,
      scaleY: zoom,
    ));

    // 2. Page shadow and white sheet.
    final pageRect = page.rect;
    final shadowPaint =
        list.addPaint(colorArgb: VectorCanvasPalette.sheetShadow.value);
    list.drawRectangle(
      Rect.fromLTWH(
          pageRect.left + 4, pageRect.top + 4, pageRect.width, pageRect.height),
      shadowPaint,
    );

    final sheetPaint = list.addPaint(colorArgb: VectorCanvasPalette.sheet.value);
    list.drawRectangle(pageRect, sheetPaint);

    // A *stroked* border. Filling it painted the sheet grey, which is what made
    // the sample document look like it had no paper under it.
    final borderPaint = list.addPaint(
      colorArgb: VectorCanvasPalette.sheetBorder.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / (zoom == 0 ? 1 : zoom),
    );
    list.drawRectangle(pageRect, borderPaint);

    // 3. Grid, under the artwork rather than over it.
    if (showGrid) {
      _renderGrid(pageRect, list, zoom);
    }

    // 4. Document objects (bottom-to-top across visible layers).
    //
    // Text is collected rather than drawn here: a glyph run carries a face at
    // a fixed pixel size, so drawing one under the zoom transform would move
    // it correctly and scale it not at all. The texts are shaped at
    // `fontSize * zoom` and emitted in device space below.
    final texts = <_PendingText>[];
    for (final layer in doc.getVisibleLayers(page)) {
      _renderLayer(layer, list, texts);
    }

    // 5. Guidelines.
    if (showGuides) {
      _renderGuides(page, list, zoom);
    }

    // 6. Selection highlights & transform handles.
    if (selection != null && selection.hasSelection) {
      _renderSelection(selection, list, zoom);
    }

    // 7. The rubber band, and the text caret. Both are interaction feedback
    // and both are hairlines in *screen* pixels, so their widths are divided
    // by the zoom the same way the selection frame's is.
    if (rubberBand != null) {
      final bandPaint = list.addPaint(
        colorArgb: VectorCanvasPalette.rubberBand.value,
        style: paintStyleStroke,
        strokeWidth: 1.0 / (zoom == 0 ? 1 : zoom),
      );
      list.drawRectangle(rubberBand, bandPaint);
    }

    if (caret != null) _renderCaret(list, caret, zoom);

    list.restore();

    // Text, in device space, still inside the viewport clip.
    for (final text in texts) {
      _renderText(list, text, zoom: zoom, pan: pan);
    }

    list.restore();
  }

  static void _renderLayer(
    VectorLayer layer,
    DisplayList list,
    List<_PendingText> texts,
  ) {
    for (final child in layer.children) {
      _renderObject(child, list, texts);
    }
  }

  /// Shapes and draws one text object at its device position.
  static void _renderText(
    DisplayList list,
    _PendingText pending, {
    required double zoom,
    required Offset pan,
  }) {
    final content = pending.object.textContent;
    if (content.isEmpty) return;
    final descriptor = pending.object.style.textStyle;
    final pixelSize = descriptor.fontSize * zoom;
    if (pixelSize < 3 || pixelSize > 400) return;
    final face = FontRegistry.instance
        .uiFont(pixelSize, weight: descriptor.bold ? 700 : 400);
    if (face == null) return;

    final trafo = pending.object.trafo;
    final origin = Offset(trafo[4], trafo[5]);
    final device = Offset(pan.dx + origin.dx * zoom, pan.dy + origin.dy * zoom);
    final fill = pending.object.style.fill;
    final color = fill.isNone ? const Color(0xFF000000) : fill.color;
    _textPainter.paint(
      list,
      content,
      face,
      device,
      list.addPaint(colorArgb: color.value, antiAlias: true),
    );
  }

  static final TextPainter _textPainter = TextPainter();

  static void _renderObject(
    DocumentObject obj,
    DisplayList list,
    List<_PendingText> texts,
  ) {
    if (obj is VectorGroup) {
      for (final child in obj.children) {
        _renderObject(child, list, texts);
      }
      return;
    }

    if (obj is VectorText) {
      texts.add(_PendingText(obj));
      return;
    }

    if (obj is PrimitiveObject) {
      final paths = obj.cachePaths ?? obj.getInitialPaths();
      if (paths.isEmpty) return;

      final fill = obj.style.fill;
      final stroke = obj.style.stroke;

      // Build combined path
      final pathBuilder = PathBuilder();
      for (final vp in paths) {
        final start = applyTrafoToPoint(vp.start, obj.trafo);
        pathBuilder.moveTo(start.dx, start.dy);

        for (final pt in vp.points) {
          if (pt is CurvePoint) {
            final cp1 = applyTrafoToPoint(pt.control1, obj.trafo);
            final cp2 = applyTrafoToPoint(pt.control2, obj.trafo);
            final end = applyTrafoToPoint(pt.endpoint, obj.trafo);
            pathBuilder.cubicTo(
                cp1.dx, cp1.dy, cp2.dx, cp2.dy, end.dx, end.dy);
          } else if (pt is Offset) {
            final end = applyTrafoToPoint(pt, obj.trafo);
            pathBuilder.lineTo(end.dx, end.dy);
          }
        }

        if (vp.isClosed) {
          pathBuilder.close();
        }
      }

      final path = pathBuilder.build();
      final pathId = list.addPath(path);

      // Fill
      if (!fill.isNone) {
        final fillPaint =
            list.addPaint(colorArgb: fill.color.value, antiAlias: true);
        list.drawPath(pathId, fillPaint);
      }

      // Stroke - a stroke paint, not a fill paint. Drawing an outline with a
      // fill paint reproduces the fill twice and loses the outline entirely.
      if (!stroke.isNone && stroke.width > 0) {
        final strokePaint = list.addPaint(
          colorArgb: stroke.color.value,
          style: paintStyleStroke,
          strokeWidth: stroke.width,
          antiAlias: true,
        );
        list.drawPath(pathId, strokePaint);
      }
    }
  }

  static void _renderGrid(Rect pageRect, DisplayList list, double zoom) {
    const spacing = 28.346; // ~10 mm in points
    // Below a certain scale the grid is solid noise; drop it rather than draw
    // a grey page.
    if (spacing * zoom < 4.0) return;
    final gridPaint = list.addPaint(colorArgb: VectorCanvasPalette.grid.value);
    final hairline = 1.0 / (zoom == 0 ? 1 : zoom);

    for (var x = pageRect.left; x <= pageRect.right; x += spacing) {
      list.drawRect(x, pageRect.top, x + hairline, pageRect.bottom, gridPaint);
    }
    for (var y = pageRect.top; y <= pageRect.bottom; y += spacing) {
      list.drawRect(pageRect.left, y, pageRect.right, y + hairline, gridPaint);
    }
  }

  static void _renderGuides(VectorPage page, DisplayList list, double zoom) {
    final guidePaint = list.addPaint(colorArgb: VectorCanvasPalette.guide.value);
    final hairline = 1.0 / (zoom == 0 ? 1 : zoom);
    final rect = page.rect;
    // Guides run the width of the page, not the width of the universe: the
    // clip would hide the overshoot anyway and a 20000pt rectangle at high
    // zoom is a rasterizer stress test for nothing.
    final overshoot = rect.width + rect.height;

    for (final child in page.children) {
      if (child is GuideLayer && child.isVisible) {
        for (final g in child.children) {
          if (g is VectorGuide) {
            if (g.isHorizontal) {
              list.drawRect(rect.left - overshoot, g.position,
                  rect.right + overshoot, g.position + hairline, guidePaint);
            } else {
              list.drawRect(g.position, rect.top - overshoot,
                  g.position + hairline, rect.bottom + overshoot, guidePaint);
            }
          }
        }
      }
    }
  }

  static void _renderSelection(
    SelectionManager selection,
    DisplayList list,
    double zoom,
  ) {
    final bounds = selection.selectionBounds;
    if (bounds == Rect.zero) return;
    final scale = zoom == 0 ? 1.0 : zoom;

    // Selection bounding box outline - stroked, so the selected art stays
    // visible through it.
    final selPaint = list.addPaint(
      colorArgb: VectorCanvasPalette.selection.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / scale,
    );
    list.drawRectangle(bounds, selPaint);

    // 8 transform handles, sized in screen pixels so they stay grabbable at
    // any zoom.
    final handleSize = 7.0 / scale;
    final handlePaint =
        list.addPaint(colorArgb: VectorCanvasPalette.handleFill.value);
    final handleBorderPaint = list.addPaint(
      colorArgb: VectorCanvasPalette.selection.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / scale,
    );

    for (final pos in handlePositions(bounds)) {
      final handleRect = Rect.fromCenter(
        center: pos,
        width: handleSize,
        height: handleSize,
      );
      list.drawRectangle(handleRect, handlePaint);
      list.drawRectangle(handleRect, handleBorderPaint);
    }
  }

  /// The caret, and the wash behind a selected run, for an open text edit.
  ///
  /// Drawn in document space and through the object's own transform, so a text
  /// that has been scaled or rotated gets a caret that is scaled and rotated
  /// with it rather than an upright bar in the wrong place.
  static void _renderCaret(DisplayList list, TextEditCaret caret, double zoom) {
    final scale = zoom == 0 ? 1.0 : zoom;

    final TextSelectionRange? range = caret.selection;
    if (range != null && range.end > range.start) {
      final washPaint =
          list.addPaint(colorArgb: VectorCanvasPalette.textSelection.value);
      final builder = PathBuilder();
      final corners = <Offset>[
        Offset(range.start, -caret.ascent),
        Offset(range.end, -caret.ascent),
        Offset(range.end, caret.descent),
        Offset(range.start, caret.descent),
      ];
      for (var i = 0; i < corners.length; i++) {
        final point = applyTrafoToPoint(corners[i], caret.trafo);
        if (i == 0) {
          builder.moveTo(point.dx, point.dy);
        } else {
          builder.lineTo(point.dx, point.dy);
        }
      }
      builder.close();
      list.drawPath(list.addPath(builder.build()), washPaint);
    }

    final top = applyTrafoToPoint(Offset(caret.caretX, -caret.ascent), caret.trafo);
    final bottom =
        applyTrafoToPoint(Offset(caret.caretX, caret.descent), caret.trafo);
    final caretPaint = list.addPaint(
      colorArgb: VectorCanvasPalette.caret.value,
      style: paintStyleStroke,
      strokeWidth: 1.4 / scale,
    );
    final stem = PathBuilder()
      ..moveTo(top.dx, top.dy)
      ..lineTo(bottom.dx, bottom.dy);
    list.drawPath(list.addPath(stem.build()), caretPaint);
  }

  /// The eight transform handle centres of [bounds], in document units.
  ///
  /// Shared with [SelectionManager.hitTestHandle] so what is drawn and what is
  /// grabbable can never drift apart.
  static List<Offset> handlePositions(Rect bounds) => <Offset>[
        Offset(bounds.left, bounds.top),
        Offset(bounds.center.dx, bounds.top),
        Offset(bounds.right, bounds.top),
        Offset(bounds.right, bounds.center.dy),
        Offset(bounds.right, bounds.bottom),
        Offset(bounds.center.dx, bounds.bottom),
        Offset(bounds.left, bounds.bottom),
        Offset(bounds.left, bounds.center.dy),
      ];
}

/// The interaction modes a canvas tool can be in.
enum ToolMode {
  select,
  shaper,
  zoom,
  fleur,
  rectangle,
  circle,
  polygon,
  curve,
  text,
}

/// A text object held back until the device-space pass.
final class _PendingText {
  const _PendingText(this.object);

  final VectorText object;
}

/// Where a text caret is, in the edited object's own coordinates.
///
/// Passed to the renderer rather than reached for, because the renderer must
/// stay a function of the document plus the interaction state it is handed -
/// a painter that queried a controller would paint a different frame depending
/// on when it ran.
final class TextEditCaret {
  const TextEditCaret({
    required this.trafo,
    required this.caretX,
    required this.ascent,
    required this.descent,
    this.selection,
  });

  /// The text object's transform, which maps the values below into the page.
  final List<double> trafo;

  /// The caret's distance along the baseline from the text origin.
  final double caretX;

  /// The line box, measured from the baseline.
  final double ascent;
  final double descent;

  /// The selected run, or null for a plain caret.
  final TextSelectionRange? selection;
}

/// The two baseline distances a selected run spans.
final class TextSelectionRange {
  const TextSelectionRange(this.start, this.end);

  final double start;
  final double end;
}
