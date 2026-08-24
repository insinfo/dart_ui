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
import '../theme.dart';
import 'selection.dart';

/// Every colour the canvas paints with, resolved from the theme.
///
/// The canvas used to hold nine literals, and the loudest of them was a flat
/// `#8C8C8C` desk: a mid grey that belonged to no palette, agreed with nothing
/// in the window around it, and turned a themed application into a themed
/// application with a grey hole in the middle. The desk is not a colour of its
/// own - it is `surfaceSunken`, the one step of the surface ladder that goes
/// *down*, and the page is content resting on it. Saying that in tokens is
/// what makes the canvas follow a theme switch instead of ignoring it.
///
/// The mapping, and why each one:
///
/// | canvas part | token | because |
/// |---|---|---|
/// | desk | `surfaceSunken` | the well a document is set into |
/// | page | `surfaceAlternate` | content resting on that ground |
/// | page edge | `border` | the edge where two surfaces meet |
/// | grid | `borderSubtle` | a divider *inside* one surface |
/// | selection frame, band, handle edge | `accent` | live interaction feedback |
/// | handle body | `surfaceAlternate` | a handle is a small control |
/// | caret | `foreground` | a caret is text, at full contrast |
/// | text run wash | `selection` | selected text, the token's own job |
///
/// The page edge is `border` and **not** `borderStrong`, which is where this
/// started: `borderStrong` is the 3:1 class, and 3:1 against a desk light
/// enough to be a surface is arithmetically out of reach - the contrast test
/// says so, and it says so for every light theme. That is the token telling
/// the truth rather than the token being wrong: a page is not a control
/// outline, it is a surface resting on another surface, and what separates
/// them is the step between the two plus the shadow the upper one casts.
///
/// Two colours are deliberately *not* tokens. A [guide] is a document
/// annotation the user places, like the artwork's own colours, and sK1's cyan
/// is what a user of that program looks for. A [sheetShadow] is an opacity
/// over whatever lies under it rather than a hue, and the palette has no token
/// for one; if a shadow token is ever added to `ThemeData` this is its first
/// caller.
final class VectorCanvasColors {
  const VectorCanvasColors({
    required this.desktop,
    required this.sheet,
    required this.sheetBorder,
    required this.sheetShadow,
    required this.grid,
    required this.guide,
    required this.selection,
    required this.handleFill,
    required this.rubberBand,
    required this.caret,
    required this.textSelection,
  });

  /// The canvas colours a [ThemeData] asks for.
  factory VectorCanvasColors.fromTheme(ThemeData theme) => VectorCanvasColors(
        desktop: theme.surfaceSunken,
        sheet: theme.surfaceAlternate,
        sheetBorder: theme.border,
        sheetShadow: VectorCanvasPalette.sheetShadow,
        grid: theme.borderSubtle,
        guide: VectorCanvasPalette.guide,
        selection: theme.accent,
        handleFill: theme.surfaceAlternate,
        rubberBand: theme.accent,
        caret: theme.foreground,
        textSelection: theme.selection,
      );

  /// The desk the page sits on.
  final Color desktop;

  /// The paper itself.
  final Color sheet;

  /// The hairline around the paper.
  final Color sheetBorder;

  final Color sheetShadow;
  final Color grid;
  final Color guide;
  final Color selection;
  final Color handleFill;
  final Color rubberBand;

  /// The in-canvas text caret.
  final Color caret;

  /// The wash behind selected characters while a text is being edited.
  final Color textSelection;
}

/// The canvas colours of the framework's default light theme.
///
/// Kept as the fallback a renderer uses when it is handed no colours at all -
/// a display-list test that renders a page with no widget tree around it - and
/// as the home of the two values [VectorCanvasColors] does not take from a
/// token.
abstract final class VectorCanvasPalette {
  /// The desk the page sits on.
  static const Color desktop = Color(0xFFEEF0F4);

  /// The paper itself.
  static const Color sheet = Color(0xFFFFFFFF);

  /// The hairline around the paper.
  static const Color sheetBorder = Color(0xFFD5D9E0);

  /// Not a token: a cast shadow is an opacity over whatever is under it, not a
  /// hue in the palette.
  static const Color sheetShadow = Color(0x33000000);
  static const Color grid = Color(0xFFE7E9ED);

  /// Not a token either: a guide is a document annotation the user places, and
  /// sK1's cyan is the colour a user of that program looks for.
  static const Color guide = Color(0xFF00A0C0);
  static const Color selection = Color(0xFF2563EB);
  static const Color handleFill = Color(0xFFFFFFFF);
  static const Color rubberBand = Color(0xFF2563EB);
  static const Color caret = Color(0xFF14181F);
  static const Color textSelection = Color(0xFFD8E5FE);

  /// The whole set, as the default light theme resolves it.
  static const VectorCanvasColors defaults = VectorCanvasColors(
    desktop: desktop,
    sheet: sheet,
    sheetBorder: sheetBorder,
    sheetShadow: sheetShadow,
    grid: grid,
    guide: guide,
    selection: selection,
    handleFill: handleFill,
    rubberBand: rubberBand,
    caret: caret,
    textSelection: textSelection,
  );
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
    VectorCanvasColors colors = VectorCanvasPalette.defaults,
  }) {
    list.save();
    list.clipRectangle(viewport);

    // 1. Desktop background - the viewport, never more.
    final bgPaint = list.addPaint(colorArgb: colors.desktop.value);
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
    final shadowPaint = list.addPaint(colorArgb: colors.sheetShadow.value);
    list.drawRectangle(
      Rect.fromLTWH(
          pageRect.left + 4, pageRect.top + 4, pageRect.width, pageRect.height),
      shadowPaint,
    );

    final sheetPaint = list.addPaint(colorArgb: colors.sheet.value);
    list.drawRectangle(pageRect, sheetPaint);

    // A *stroked* border. Filling it painted the sheet grey, which is what made
    // the sample document look like it had no paper under it.
    final borderPaint = list.addPaint(
      colorArgb: colors.sheetBorder.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / (zoom == 0 ? 1 : zoom),
    );
    list.drawRectangle(pageRect, borderPaint);

    // 3. Grid, under the artwork rather than over it.
    if (showGrid) {
      _renderGrid(pageRect, list, zoom, colors);
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
      _renderGuides(page, list, zoom, colors);
    }

    // 6. Selection highlights & transform handles.
    if (selection != null && selection.hasSelection) {
      _renderSelection(selection, list, zoom, colors);
    }

    // 7. The rubber band, and the text caret. Both are interaction feedback
    // and both are hairlines in *screen* pixels, so their widths are divided
    // by the zoom the same way the selection frame's is.
    if (rubberBand != null) {
      final bandPaint = list.addPaint(
        colorArgb: colors.rubberBand.value,
        style: paintStyleStroke,
        strokeWidth: 1.0 / (zoom == 0 ? 1 : zoom),
      );
      list.drawRectangle(rubberBand, bandPaint);
    }

    if (caret != null) _renderCaret(list, caret, zoom, colors);

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

  static void _renderGrid(
    Rect pageRect,
    DisplayList list,
    double zoom,
    VectorCanvasColors colors,
  ) {
    const spacing = 28.346; // ~10 mm in points
    // Below a certain scale the grid is solid noise; drop it rather than draw
    // a grey page.
    if (spacing * zoom < 4.0) return;
    final gridPaint = list.addPaint(colorArgb: colors.grid.value);
    final hairline = 1.0 / (zoom == 0 ? 1 : zoom);

    for (var x = pageRect.left; x <= pageRect.right; x += spacing) {
      list.drawRect(x, pageRect.top, x + hairline, pageRect.bottom, gridPaint);
    }
    for (var y = pageRect.top; y <= pageRect.bottom; y += spacing) {
      list.drawRect(pageRect.left, y, pageRect.right, y + hairline, gridPaint);
    }
  }

  static void _renderGuides(
    VectorPage page,
    DisplayList list,
    double zoom,
    VectorCanvasColors colors,
  ) {
    final guidePaint = list.addPaint(colorArgb: colors.guide.value);
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
    VectorCanvasColors colors,
  ) {
    final bounds = selection.selectionBounds;
    if (bounds == Rect.zero) return;
    final scale = zoom == 0 ? 1.0 : zoom;

    // Selection bounding box outline - stroked, so the selected art stays
    // visible through it.
    final selPaint = list.addPaint(
      colorArgb: colors.selection.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / scale,
    );
    list.drawRectangle(bounds, selPaint);

    // 8 transform handles, sized in screen pixels so they stay grabbable at
    // any zoom.
    final handleSize = 7.0 / scale;
    final handlePaint = list.addPaint(colorArgb: colors.handleFill.value);
    final handleBorderPaint = list.addPaint(
      colorArgb: colors.selection.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / scale,
    );

    final bool rotating =
        selection.handleMode == SelectionHandleMode.rotate;
    final List<Offset> centres = handlePositions(bounds);

    for (var i = 0; i < centres.length; i++) {
      final Offset pos = centres[i];
      if (!rotating) {
        final handleRect = Rect.fromCenter(
          center: pos,
          width: handleSize,
          height: handleSize,
        );
        list.drawRectangle(handleRect, handlePaint);
        list.drawRectangle(handleRect, handleBorderPaint);
        continue;
      }

      // The rotate frame has to *look* different or the mode is invisible, and
      // an invisible mode is a bug report. Corners become diamonds - a square
      // turned, which is what a corner now does - and the edges become bars
      // lying along the edge they skew, which is the direction they slide in.
      final TransformHandle handle = TransformHandle.values[i];
      if (SelectionManager.isCorner(handle)) {
        final int diamond = list.addPath(_diamondPath(pos, handleSize));
        list.drawPath(diamond, handlePaint);
        list.drawPath(diamond, handleBorderPaint);
        continue;
      }
      final bool horizontal = handle == TransformHandle.topCenter ||
          handle == TransformHandle.bottomCenter;
      final Rect bar = Rect.fromCenter(
        center: pos,
        width: horizontal ? handleSize * 2.2 : handleSize * 0.8,
        height: horizontal ? handleSize * 0.8 : handleSize * 2.2,
      );
      list.drawRectangle(bar, handlePaint);
      list.drawRectangle(bar, handleBorderPaint);
    }

    if (rotating) _renderPivot(selection.pivot, list, scale, colors);
  }

  /// The rotation pivot: a ring with a dot in it, and a cross through it.
  ///
  /// Drawn as a ring rather than as a ninth square because it is not a corner
  /// of anything - it is a *point*, it can be dragged off the box entirely,
  /// and a square there would read as one more thing to pull the box by. The
  /// cross is what makes it findable once it has been dragged over artwork.
  static void _renderPivot(
    Offset pivot,
    DisplayList list,
    double scale,
    VectorCanvasColors colors,
  ) {
    final double radius = 5.0 / scale;
    final Rect box = Rect.fromCenter(
      center: pivot,
      width: radius * 2,
      height: radius * 2,
    );
    final fill = list.addPaint(colorArgb: colors.handleFill.value);
    final edge = list.addPaint(
      colorArgb: colors.selection.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / scale,
    );
    // A uniform round rect whose radius is half its side is a circle, which
    // saves building a four-cubic path for a five-pixel mark.
    list.drawRRectUniform(
        box.left, box.top, box.right, box.bottom, radius, radius, fill);
    list.drawRRectUniform(
        box.left, box.top, box.right, box.bottom, radius, radius, edge);

    final double arm = radius * 1.6;
    final cross = PathBuilder()
      ..moveTo(pivot.dx - arm, pivot.dy)
      ..lineTo(pivot.dx + arm, pivot.dy)
      ..moveTo(pivot.dx, pivot.dy - arm)
      ..lineTo(pivot.dx, pivot.dy + arm);
    list.drawPath(list.addPath(cross.build()), edge);
  }

  /// A square turned forty-five degrees, centred on [centre].
  static Path _diamondPath(Offset centre, double size) {
    final double half = size * 0.75;
    return (PathBuilder()
          ..moveTo(centre.dx, centre.dy - half)
          ..lineTo(centre.dx + half, centre.dy)
          ..lineTo(centre.dx, centre.dy + half)
          ..lineTo(centre.dx - half, centre.dy)
          ..close())
        .build();
  }

  /// The caret, and the wash behind a selected run, for an open text edit.
  ///
  /// Drawn in document space and through the object's own transform, so a text
  /// that has been scaled or rotated gets a caret that is scaled and rotated
  /// with it rather than an upright bar in the wrong place.
  static void _renderCaret(
    DisplayList list,
    TextEditCaret caret,
    double zoom,
    VectorCanvasColors colors,
  ) {
    final scale = zoom == 0 ? 1.0 : zoom;

    final TextSelectionRange? range = caret.selection;
    if (range != null && range.end > range.start) {
      final washPaint = list.addPaint(colorArgb: colors.textSelection.value);
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
      colorArgb: colors.caret.value,
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
