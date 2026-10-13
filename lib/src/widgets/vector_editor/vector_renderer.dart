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

import 'dart:math' as math;
import 'dart:typed_data';

import '../../animation/animation.dart' show ColorTween;
import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/stroke.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/color.dart';
import '../../graphics/display_list.dart';
import '../../graphics/display_list_geometry.dart';
import '../../graphics/display_list_opcodes.dart';
import '../../graphics/gradient.dart';
import '../../graphics/image/decoded_image.dart';
import '../../graphics/vector/arrowheads.dart';
import '../../graphics/vector/calligraphy.dart';
import '../../graphics/vector/constants.dart';
import '../../graphics/vector/document.dart';
import '../../graphics/vector/document_object.dart';
import '../../graphics/vector/pixmap.dart';
import '../../graphics/vector/primitives.dart';
import '../../graphics/vector/selectable_objects.dart';
import '../../graphics/vector/structural_objects.dart';
import '../../graphics/vector/style.dart';
import '../../rendering/cpu_renderer.dart' show rasterizeDisplayList;
import '../../rendering/framebuffer.dart';
import '../../rendering/text/text_painter.dart';
import '../../text/paragraph.dart' show Paragraph;
import '../../vector_editing/node_editing.dart';
import '../../vector_editing/parametric_handles.dart';
import '../../vector_editing/patterns.dart';
import '../../vector_editing/selection.dart';
import '../../vector_editing/text_metrics.dart';
import '../../vector_editing/tool_mode.dart';
import '../image.dart' show framebufferFromImage;
import '../theme.dart';

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
        // The paper is the document's, not the interface's: it is white in
        // a dark theme too, or black artwork would vanish into it.
        sheet: VectorCanvasPalette.sheet,
        sheetBorder: theme.border,
        sheetShadow: VectorCanvasPalette.sheetShadow,
        grid: VectorCanvasPalette.grid,
        guide: VectorCanvasPalette.guide,
        selection: theme.accent,
        handleFill: VectorCanvasPalette.handleFill,
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

  /// Drawn over the paper, so a tint of black rather than a theme grey.
  static const Color grid = Color(0x14000000);

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
    _zoom = zoom;

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

    // 6. Selection highlights & transform handles - or, with the Shape
    // tool on a curve, its nodes and their handles instead.
    final VectorCurve? edited =
        currentTool == ToolMode.shaper ? selection?.nodes.curve : null;
    final List<SelectableObject> picked =
        selection?.selectedObjects ?? const <SelectableObject>[];
    final SelectableObject? shaped =
        currentTool == ToolMode.shaper && picked.length == 1
            ? picked.single
            : null;
    if (edited != null && selection!.selectedObjects.contains(edited)) {
      _renderNodes(edited, selection.nodes, list, zoom, colors);
    } else if (shaped is PrimitiveObject &&
        ParametricHandles.supports(shaped)) {
      _renderParametric(shaped, list, zoom, colors);
    } else if (selection != null && selection.hasSelection) {
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
    // Tiny text has no useful device coverage. Large text, however, must not
    // be omitted: the GPU sink routes glyphs that outgrow its persistent
    // atlas through scalable outlines and tiles the resulting mask. The old
    // 400 px ceiling made text disappear at roughly 2200% zoom.
    if (!pixelSize.isFinite || pixelSize < 3) return;
    final trafo = pending.object.trafo;
    // Device matrix: the view (zoom, pan) after the object's own transform.
    final a = zoom * trafo[0];
    final b = zoom * trafo[1];
    final c = zoom * trafo[2];
    final d = zoom * trafo[3];
    final tx = pan.dx + zoom * trafo[4];
    final ty = pan.dy + zoom * trafo[5];
    // Shape at the size the glyphs will actually cover, and let the matrix
    // carry only rotation, skew and mirroring - so a plain text stays crisp
    // and a rotated one turns with its frame instead of staying upright.
    final scale = math.sqrt((a * d - b * c).abs());
    final fill = pending.object.style.fill;
    final color = fill.isNone ? const Color(0xFF000000) : fill.color;
    final shapedSize = descriptor.fontSize * scale;
    if (!shapedSize.isFinite || shapedSize < 3) return;
    // The face the metrics measure with - family, bold, italic - so the box
    // the pointer hits is the ink on screen.
    final shapedFace = VectorTextMetrics.faceAt(descriptor, shapedSize);
    if (shapedFace == null) return;
    // Centred and right-aligned text grows from its anchor: the start, in
    // the text's own units, is measured once at document scale.
    final double shift = VectorTextMetrics.measure(pending.object).left;
    final paint = list.addPaint(colorArgb: color.value, antiAlias: true);
    final plain = b == 0 && c == 0 && a > 0 && d > 0 && (a - d).abs() < 1e-9;
    if (VectorTextMetrics.isMultiline(pending.object)) {
      // Lines: laid out at the device size with the frame scaled to match,
      // so they break where the document-scale measure says they do, and
      // hung from the first baseline like a single line is.
      final Paragraph laid =
          VectorTextMetrics.paragraphAt(pending.object, shapedFace, scale);
      final Offset topLeft = Offset(shift * scale, -laid.lines.first.baseline);
      if (plain) {
        _textPainter.paintParagraph(
            list, laid, Offset(tx, ty) + topLeft, paint);
        return;
      }
      list
        ..save()
        ..transform(a / scale, b / scale, c / scale, d / scale, tx, ty);
      _textPainter.paintParagraph(list, laid, topLeft, paint);
      list.restore();
      return;
    }
    if (plain) {
      _textPainter.paint(
          list, content, shapedFace, Offset(tx + a * shift, ty), paint);
      return;
    }
    list
      ..save()
      ..transform(a / scale, b / scale, c / scale, d / scale, tx, ty);
    _textPainter.paint(
        list, content, shapedFace, Offset(shift * scale, 0), paint);
    list.restore();
  }

  static final TextPainter _textPainter = TextPainter();

  /// [objects] drawn into an image the size of their union's box times
  /// [scale] - no page, grid or selection, transparent where nothing is -
  /// or null when they cover nothing. What "copy as a picture" and a PNG
  /// export need. The sides are capped at [maxSide] pixels.
  static DecodedImage? rasterizeObjects(
    List<SelectableObject> objects, {
    double scale = 1,
    int maxSide = 8192,
  }) {
    Rect? box;
    for (final SelectableObject object in objects) {
      final Rect bounds = object.cacheBbox;
      if (bounds.isEmpty) continue;
      box = box == null ? bounds : box.union(bounds);
    }
    if (box == null || scale <= 0) return null;
    final double fit =
        math.min(1, maxSide / math.max(box.width * scale, box.height * scale));
    final double zoom = scale * fit;
    final int width = math.max(1, (box.width * zoom).ceil());
    final int height = math.max(1, (box.height * zoom).ceil());
    final Offset pan = Offset(-box.left * zoom, -box.top * zoom);
    final DisplayList list = DisplayList();
    _zoom = zoom;
    final texts = <_PendingText>[];
    list
      ..save()
      ..transform2D(
          Transform2D.compose(translation: pan, scaleX: zoom, scaleY: zoom));
    for (final SelectableObject object in objects) {
      _renderObject(object, list, texts);
    }
    list.restore();
    for (final _PendingText text in texts) {
      _renderText(list, text, zoom: zoom, pan: pan);
    }
    final Framebuffer framebuffer = Framebuffer(
      width: width,
      height: height,
      bytesPerRow: width * 4,
      format: PixelFormat.rgba8888Premultiplied,
      pixels: Uint8List(width * height * 4),
    );
    rasterizeDisplayList(list, framebuffer, clearColor: 0x00000000);
    return DecodedImage(
      width: width,
      height: height,
      order: ImageChannelOrder.rgba,
      pixels: framebuffer.pixels,
      hasAlpha: true,
    );
  }

  /// The zoom of the page being rendered, for the images, which are
  /// resampled to the pixels they cover.
  static double _zoom = 1;

  /// Each image's pixels at the size they were last drawn, so a frame at
  /// the same zoom resamples nothing.
  static final Expando<_PixmapRaster> _rasters = Expando<_PixmapRaster>();

  /// An embedded image, in the document pass so it stays in z-order.
  ///
  /// Resampled to the device pixels its rectangle covers and drawn with the
  /// destination in document units under the zoom: the CPU raster copies
  /// one source pixel per destination pixel, so the image has to arrive at
  /// its device size, and a GPU samples the same buffer. That holds for a
  /// scale and a translation; an image turned or skewed by its transform is
  /// drawn as its outline with a cross until transformed image drawing
  /// exists, rather than unrotated in the wrong place.
  static void _renderPixmap(VectorPixmap pixmap, DisplayList list) {
    final Uint8List? data = pixmap.pixelData;
    if (data == null ||
        pixmap.pixelWidth <= 0 ||
        pixmap.pixelHeight <= 0 ||
        pixmap.imageFormat != PixmapFormat.rgba ||
        data.length != pixmap.pixelWidth * pixmap.pixelHeight * 4) {
      return;
    }
    final List<double> t = pixmap.trafo;
    final double width = pixmap.pixelWidth * 72.0 / pixmap.dpi;
    final double height = pixmap.pixelHeight * 72.0 / pixmap.dpi;
    if (t[1].abs() > 1e-9 || t[2].abs() > 1e-9) {
      final paint = list.addPaint(
        colorArgb: 0xFF808080,
        style: paintStyleStroke,
        strokeWidth: 1 / (_zoom == 0 ? 1 : _zoom),
      );
      final corners = applyTrafoToPoints(<Offset>[
        Offset.zero,
        Offset(width, 0),
        Offset(width, height),
        Offset(0, height),
      ], t);
      final builder = PathBuilder()..moveTo(corners[0].dx, corners[0].dy);
      for (final Offset c in <Offset>[corners[1], corners[2], corners[3]]) {
        builder.lineTo(c.dx, c.dy);
      }
      builder
        ..close()
        ..moveTo(corners[0].dx, corners[0].dy)
        ..lineTo(corners[2].dx, corners[2].dy)
        ..moveTo(corners[1].dx, corners[1].dy)
        ..lineTo(corners[3].dx, corners[3].dy);
      list.drawPath(list.addPath(builder.build()), paint);
      return;
    }
    final Rect box = pixmap.cacheBbox;
    final int deviceWidth = (box.width * _zoom).round().clamp(1, 8192);
    final int deviceHeight = (box.height * _zoom).round().clamp(1, 8192);
    _PixmapRaster? raster = _rasters[pixmap];
    if (raster == null ||
        !identical(raster.data, data) ||
        raster.image.width != deviceWidth ||
        raster.image.height != deviceHeight) {
      final DecodedImage source = DecodedImage(
        width: pixmap.pixelWidth,
        height: pixmap.pixelHeight,
        order: ImageChannelOrder.rgba,
        pixels: data,
        hasAlpha: true,
      );
      final bool mirroredX = t[0] < 0;
      final bool mirroredY = t[3] < 0;
      DecodedImage scaled = source.resample(
        width: deviceWidth,
        height: deviceHeight,
        filter: deviceWidth < pixmap.pixelWidth
            ? ResampleFilter.box
            : ResampleFilter.nearest,
      );
      if (mirroredX || mirroredY) {
        scaled = _mirror(scaled, mirroredX, mirroredY);
      }
      raster = _rasters[pixmap] = _PixmapRaster(data, scaled);
    }
    list.drawImage(
      list.addImage(framebufferFromImage(raster.image)),
      0,
      0,
      deviceWidth.toDouble(),
      deviceHeight.toDouble(),
      box.left,
      box.top,
      box.right,
      box.bottom,
      list.addPaint(colorArgb: 0xFFFFFFFF),
    );
  }

  /// [image] flipped on the axes a negative scale turns over.
  static DecodedImage _mirror(DecodedImage image, bool x, bool y) {
    final Uint8List from = image.pixels;
    final Uint8List to = Uint8List(from.length);
    final int w = image.width;
    final int h = image.height;
    for (int row = 0; row < h; row++) {
      final int sourceRow = y ? h - 1 - row : row;
      for (int col = 0; col < w; col++) {
        final int sourceCol = x ? w - 1 - col : col;
        final int s = (sourceRow * w + sourceCol) * 4;
        final int d = (row * w + col) * 4;
        to[d] = from[s];
        to[d + 1] = from[s + 1];
        to[d + 2] = from[s + 2];
        to[d + 3] = from[s + 3];
      }
    }
    return DecodedImage(
      width: w,
      height: h,
      order: image.order,
      pixels: to,
      hasAlpha: image.hasAlpha,
    );
  }

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

    if (obj is VectorPixmap) {
      _renderPixmap(obj, list);
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
            pathBuilder.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, end.dx, end.dy);
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
      if (fill.isPattern && VectorPatterns.isTexture(fill.patternId)) {
        _renderTexture(obj, pathId, list);
      } else if (fill.isPattern) {
        // A two-colour pattern: the background in the shape, then the
        // marks, already cut to it.
        final Color? background = fill.patternBackground;
        if (background != null) {
          list.drawPath(
              pathId,
              list.addPaint(
                colorArgb: background.value,
                antiAlias: true,
                fillRule: fill.fillRule == FillRule.evenOdd
                    ? pathFillRuleEvenOdd
                    : pathFillRuleNonZero,
              ));
        }
        final List<VectorPath> marks = VectorPatterns.marksOf(obj);
        if (marks.isNotEmpty) {
          list.drawPath(
            list.addPath(_pathOf(marks, kNormalTrafo)),
            list.addPaint(colorArgb: fill.color.value, antiAlias: true),
          );
        }
      } else if (!fill.isNone) {
        final fillPaint = list.addPaint(
          colorArgb: fill.color.value,
          antiAlias: true,
          fillRule: fill.fillRule == FillRule.evenOdd
              ? pathFillRuleEvenOdd
              : pathFillRuleNonZero,
          gradient: fill.isGradient ? _gradientFor(obj, paths) : null,
        );
        list.drawPath(pathId, fillPaint);
      }

      // Stroke - a stroke paint, not a fill paint. Drawing an outline with a
      // fill paint reproduces the fill twice and loses the outline entirely.
      if (stroke.isCalligraphic) {
        // A flat nib: the stroke is a shape of its own, filled.
        list.drawPath(
          list.addPath(calligraphicOutline(paths, obj.trafo, stroke)),
          list.addPaint(colorArgb: stroke.color.value, antiAlias: true),
        );
        _renderArrowheads(obj, paths, list);
      } else if (!stroke.isNone && stroke.width > 0) {
        final strokePaint = list.addPaint(
          colorArgb: stroke.color.value,
          style: paintStyleStroke,
          strokeWidth: stroke.width,
          antiAlias: true,
          // The model's enums are in the renderer's order.
          strokeCap: StrokeCap.values[stroke.cap.index],
          strokeJoin: StrokeJoin.values[stroke.join.index],
          miterLimit: stroke.miterLimit,
          dashArray: stroke.dashPattern.isEmpty ? null : stroke.dashPattern,
          dashOffset: stroke.dashOffset,
        );
        list.drawPath(pathId, strokePaint);
        _renderArrowheads(obj, paths, list);
      }
    }
  }

  /// Each textured object's image at the size it was last drawn.
  static final Expando<_TextureRaster> _textures = Expando<_TextureRaster>();

  /// A texture fill: the shape rasterized at the device pixels it covers
  /// for a mask, the texture computed in the object's units under it, and
  /// the result drawn as an image in z-order - the one fill that is pixels,
  /// not geometry, so it is made where the pixels are.
  static void _renderTexture(
      PrimitiveObject obj, int pathId, DisplayList list) {
    final FillDescriptor fill = obj.style.fill;
    final Rect box = obj.cacheBbox;
    if (box.isEmpty) return;
    final int width = (box.width * _zoom).ceil().clamp(1, 4096);
    final int height = (box.height * _zoom).ceil().clamp(1, 4096);
    final List<VectorPath>? paths = obj.cachePaths;
    if (paths == null) return;
    _TextureRaster? raster = _textures[obj];
    if (raster == null ||
        !identical(raster.paths, paths) ||
        !identical(raster.trafo, obj.trafo) ||
        raster.fill != fill ||
        raster.image.width != width ||
        raster.image.height != height) {
      // The mask: the shape, opaque, at this size.
      final double sx = width / box.width;
      final double sy = height / box.height;
      final DisplayList mask = DisplayList();
      mask
        ..transform(sx, 0, 0, sy, -box.left * sx, -box.top * sy)
        ..drawPath(
          mask.addPath(_pathOf(paths, obj.trafo)),
          mask.addPaint(
            colorArgb: 0xFFFFFFFF,
            antiAlias: true,
            fillRule: fill.fillRule == FillRule.evenOdd
                ? pathFillRuleEvenOdd
                : pathFillRuleNonZero,
          ),
        );
      final Framebuffer framebuffer = Framebuffer(
        width: width,
        height: height,
        bytesPerRow: width * 4,
        format: PixelFormat.rgba8888Premultiplied,
        pixels: Uint8List(width * height * 4),
      );
      rasterizeDisplayList(mask, framebuffer, clearColor: 0x00000000);
      final Uint8List pixels = framebuffer.pixels;
      final Color front = fill.color;
      // Over nothing, the texture fades from see-through to its colour.
      final Color back =
          fill.patternBackground ?? Color(fill.color.value & 0x00FFFFFF);
      final double size = fill.patternSize <= 0 ? 8 : fill.patternSize;
      final String kind = fill.patternId!;
      for (int y = 0; y < height; y++) {
        final double docY = box.top + (y + 0.5) / sy;
        for (int x = 0; x < width; x++) {
          final int i = (y * width + x) * 4;
          final int coverage = pixels[i + 3];
          if (coverage == 0) continue;
          final double docX = box.left + (x + 0.5) / sx;
          final double t =
              VectorPatterns.textureAt(kind, docX / size, docY / size)
                  .clamp(0.0, 1.0);
          final int argb = ColorTween.interpolate(back.value, front.value, t);
          final int a = ((argb >>> 24) * coverage + 127) ~/ 255;
          pixels[i] = ((argb >> 16 & 0xFF) * a + 127) ~/ 255;
          pixels[i + 1] = ((argb >> 8 & 0xFF) * a + 127) ~/ 255;
          pixels[i + 2] = ((argb & 0xFF) * a + 127) ~/ 255;
          pixels[i + 3] = a;
        }
      }
      raster = _textures[obj] = _TextureRaster(
        paths,
        obj.trafo,
        fill,
        DecodedImage(
          width: width,
          height: height,
          order: ImageChannelOrder.rgba,
          pixels: pixels,
          hasAlpha: true,
        ),
      );
    }
    list.drawImage(
      list.addImage(framebufferFromImage(raster.image)),
      0,
      0,
      width.toDouble(),
      height.toDouble(),
      box.left,
      box.top,
      box.left + width / _zoom,
      box.top + height / _zoom,
      list.addPaint(colorArgb: 0xFFFFFFFF),
    );
  }

  /// [paths] placed by [trafo], as a display-list path.
  static Path _pathOf(List<VectorPath> paths, List<double> trafo) {
    final PathBuilder builder = PathBuilder();
    for (final VectorPath vp in paths) {
      final Offset start = applyTrafoToPoint(vp.start, trafo);
      builder.moveTo(start.dx, start.dy);
      for (final Object pt in vp.points) {
        if (pt is CurvePoint) {
          final Offset c1 = applyTrafoToPoint(pt.control1, trafo);
          final Offset c2 = applyTrafoToPoint(pt.control2, trafo);
          final Offset end = applyTrafoToPoint(pt.endpoint, trafo);
          builder.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
        } else if (pt is Offset) {
          final Offset end = applyTrafoToPoint(pt, trafo);
          builder.lineTo(end.dx, end.dy);
        }
      }
      if (vp.isClosed) builder.close();
    }
    return builder.build();
  }

  /// The outline's arrowheads, on the open ends of [paths], in the outline's
  /// colour and sized by its width.
  static void _renderArrowheads(
    PrimitiveObject obj,
    List<VectorPath> paths,
    DisplayList list,
  ) {
    final stroke = obj.style.stroke;
    final ArrowHead start = ArrowHead.of(stroke.startArrow);
    final ArrowHead end = ArrowHead.of(stroke.endArrow);
    if (start == ArrowHead.none && end == ArrowHead.none) return;
    final int paint = list.addPaint(colorArgb: stroke.color.value);
    Offset doc(Offset p) => applyTrafoToPoint(p, obj.trafo);
    for (final vp in paths) {
      if (vp.isClosed || vp.points.isEmpty) continue;
      // The first and last segments, as the points that give their
      // direction: the nearest control point that is not the node itself.
      final Offset first = doc(vp.start);
      final Offset? afterFirst = _awayFrom(first, <Offset>[
        if (vp.points.first case final CurvePoint c) ...<Offset>[
          doc(c.control1),
          doc(c.control2),
          doc(c.endpoint),
        ] else
          doc(vp.points.first as Offset),
      ]);
      final Object lastPoint = vp.points.last;
      final Offset last = doc(
          lastPoint is CurvePoint ? lastPoint.endpoint : lastPoint as Offset);
      final Offset previous = vp.points.length > 1
          ? doc(switch (vp.points[vp.points.length - 2]) {
              final CurvePoint c => c.endpoint,
              final Object o => o as Offset,
            })
          : first;
      final Offset? beforeLast = _awayFrom(last, <Offset>[
        if (lastPoint case final CurvePoint c) ...<Offset>[
          doc(c.control2),
          doc(c.control1),
        ],
        previous,
      ]);
      if (afterFirst != null) {
        final Path? head = start.at(first, first - afterFirst, stroke.width);
        if (head != null) list.drawPath(list.addPath(head), paint);
      }
      if (beforeLast != null) {
        final Path? head = end.at(last, last - beforeLast, stroke.width);
        if (head != null) list.drawPath(list.addPath(head), paint);
      }
    }
  }

  /// The first of [candidates] that is not [node] itself.
  static Offset? _awayFrom(Offset node, List<Offset> candidates) {
    for (final Offset c in candidates) {
      if ((c - node).distance > 1e-9) return c;
    }
    return null;
  }

  /// The fill's gradient in document space.
  ///
  /// Its geometry is relative to the shape's own box before the transform -
  /// SVG's `objectBoundingBox` - so it stretches, turns and moves with the
  /// object.
  static Gradient? _gradientFor(PrimitiveObject obj, List<VectorPath> paths) {
    final fill = obj.style.fill;
    final stops = <GradientStop>[
      for (final stop in fill.gradientStops)
        GradientStop(stop.offset.clamp(0.0, 1.0), stop.color.value),
    ];
    if (stops.length < 2) return null;
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    void take(Offset p) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }

    for (final vp in paths) {
      take(vp.start);
      for (final pt in vp.points) {
        if (pt is CurvePoint) {
          take(pt.endpoint);
        } else if (pt is Offset) {
          take(pt);
        }
      }
    }
    if (!minX.isFinite) return null;
    final w = maxX - minX;
    final h = maxY - minY;
    Offset map(Offset relative) => applyTrafoToPoint(
        Offset(minX + relative.dx * w, minY + relative.dy * h), obj.trafo);
    if (fill.fillType == FillType.radialGradient) {
      final centre = map(fill.gradientCenter);
      final edge = map(Offset(fill.gradientCenter.dx + fill.gradientRadius,
          fill.gradientCenter.dy));
      return RadialGradient(
        centerX: centre.dx,
        centerY: centre.dy,
        radius: (edge - centre).distance,
        stops: stops,
      );
    }
    final start = map(fill.gradientStart);
    final end = map(fill.gradientEnd);
    return LinearGradient(
      startX: start.dx,
      startY: start.dy,
      endX: end.dx,
      endY: end.dy,
      stops: stops,
    );
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

  /// The Shape tool's view of [curve]: its outline as a hairline, every
  /// node as a small square - filled when picked - and the Bézier handles of
  /// the picked nodes as levers ending in a dot. All in screen pixels.
  static void _renderNodes(
    VectorCurve curve,
    NodeSelection picked,
    DisplayList list,
    double zoom,
    VectorCanvasColors colors,
  ) {
    final double scale = zoom == 0 ? 1.0 : zoom;
    final int line = list.addPaint(
      colorArgb: colors.selection.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / scale,
    );
    final int fill = list.addPaint(colorArgb: colors.handleFill.value);
    final int accent = list.addPaint(colorArgb: colors.selection.value);

    Offset doc(Offset local) => NodeEditing.toDocument(curve, local);

    // The outline, so a curve with no fill is still visible being edited.
    final PathBuilder outline = PathBuilder();
    for (final VectorPath path in curve.paths) {
      final Offset start = doc(path.start);
      outline.moveTo(start.dx, start.dy);
      for (final Object point in path.points) {
        if (point is CurvePoint) {
          final Offset c1 = doc(point.control1);
          final Offset c2 = doc(point.control2);
          final Offset end = doc(point.endpoint);
          outline.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
        } else {
          final Offset end = doc(point as Offset);
          outline.lineTo(end.dx, end.dy);
        }
      }
      if (path.isClosed) outline.close();
    }
    list.drawPath(list.addPath(outline.build()), line);

    final double size = 6.0 / scale;
    for (final PathNode node in picked.nodes) {
      final Offset at =
          doc(NodeEditing.nodePoint(curve.paths[node.path], node.index));
      for (final NodeHandleSide side in NodeHandleSide.values) {
        final Offset? handle =
            NodeEditing.handle(curve, NodeHandleRef(node, side));
        if (handle == null) continue;
        final Offset end = doc(handle);
        final PathBuilder lever = PathBuilder()
          ..moveTo(at.dx, at.dy)
          ..lineTo(end.dx, end.dy);
        list.drawPath(list.addPath(lever.build()), line);
        final int tip = list.addPath(_diamondPath(end, size * 0.9));
        list
          ..drawPath(tip, accent)
          ..drawPath(tip, line);
      }
    }
    for (final PathNode node in NodeEditing.nodesOf(curve)) {
      final Offset at =
          doc(NodeEditing.nodePoint(curve.paths[node.path], node.index));
      final Rect box = Rect.fromCenter(center: at, width: size, height: size);
      list.drawRectangle(box, picked.nodes.contains(node) ? accent : fill);
      list.drawRectangle(box, line);
    }
  }

  /// A rectangle's or an ellipse's own handles under the Shape tool: its
  /// outline, and a node where each corner rounds or each end of the arc is.
  static void _renderParametric(
    PrimitiveObject shape,
    DisplayList list,
    double zoom,
    VectorCanvasColors colors,
  ) {
    final double scale = zoom == 0 ? 1.0 : zoom;
    final int line = list.addPaint(
      colorArgb: colors.selection.value,
      style: paintStyleStroke,
      strokeWidth: 1.0 / scale,
    );
    final int fill = list.addPaint(colorArgb: colors.handleFill.value);
    final PathBuilder outline = PathBuilder();
    for (final VectorPath path in shape.cachePaths ?? shape.getInitialPaths()) {
      final Offset start = applyTrafoToPoint(path.start, shape.trafo);
      outline.moveTo(start.dx, start.dy);
      for (final Object point in path.points) {
        if (point is CurvePoint) {
          final Offset c1 = applyTrafoToPoint(point.control1, shape.trafo);
          final Offset c2 = applyTrafoToPoint(point.control2, shape.trafo);
          final Offset end = applyTrafoToPoint(point.endpoint, shape.trafo);
          outline.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
        } else {
          final Offset end = applyTrafoToPoint(point as Offset, shape.trafo);
          outline.lineTo(end.dx, end.dy);
        }
      }
      if (path.isClosed) outline.close();
    }
    list.drawPath(list.addPath(outline.build()), line);
    final double size = 6.0 / scale;
    for (final Offset at in ParametricHandles.of(shape)) {
      final Rect box = Rect.fromCenter(center: at, width: size, height: size);
      list
        ..drawRectangle(box, fill)
        ..drawRectangle(box, line);
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

    final bool rotating = selection.handleMode == SelectionHandleMode.rotate;
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

    if (caret.selection.isNotEmpty) {
      final washPaint = list.addPaint(colorArgb: colors.textSelection.value);
      final builder = PathBuilder();
      // One rectangle per line the selection crosses, each mapped through
      // the text's transform so a rotated text gets a rotated wash.
      for (final Rect box in caret.selection) {
        final corners = <Offset>[
          Offset(box.left, box.top),
          Offset(box.right, box.top),
          Offset(box.right, box.bottom),
          Offset(box.left, box.bottom),
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
      }
      list.drawPath(list.addPath(builder.build()), washPaint);
    }

    final top = applyTrafoToPoint(
        Offset(caret.caret.left, caret.caret.top), caret.trafo);
    final bottom = applyTrafoToPoint(
        Offset(caret.caret.left, caret.caret.bottom), caret.trafo);
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

/// A texture fill's pixels at one size, and what they were made from.
final class _TextureRaster {
  const _TextureRaster(this.paths, this.trafo, this.fill, this.image);

  final List<VectorPath> paths;
  final List<double> trafo;
  final FillDescriptor fill;
  final DecodedImage image;
}

/// An image's pixels at one device size, and the data they came from.
final class _PixmapRaster {
  const _PixmapRaster(this.data, this.image);

  final Uint8List data;
  final DecodedImage image;
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
    required this.caret,
    this.selection = const <Rect>[],
  });

  /// The text object's transform, which maps the values below into the page.
  final List<double> trafo;

  /// The caret: a zero-width rectangle from the top to the bottom of its
  /// line, in text units - the first baseline's start is the origin.
  final Rect caret;

  /// The selected run, one rectangle per line it crosses; empty for a plain
  /// caret.
  final List<Rect> selection;
}
