/// SVG encoder and decoder for [VectorDocument].
///
/// ## What a saved file holds
///
/// Every object is written as the geometry any SVG reader draws - a `<path>`
/// in document coordinates, a `<text>` under its own `transform` - so the
/// file opens the same in a browser, Inkscape or Illustrator. Alongside, the
/// `dartui:` attributes carry what that geometry cannot: that a path *was* a
/// rectangle with rounded corners, an ellipse, a five-pointed star, and the
/// transform it had. Reading a file back, an element with those attributes
/// becomes the same editable object again; an element without them (any SVG
/// from elsewhere) becomes the closest thing the document model has.
///
/// ## What reading understands
///
/// `<svg>` width, height and viewBox with their units; `<g>` (Inkscape layers
/// become layers, other groups become groups); `rect` (with `rx`/`ry`),
/// `circle`, `ellipse`, `line`, `polyline`, `polygon`, `path` and `text`;
/// `transform` on any element; presentation attributes and the `style`
/// attribute; colours as hex, `rgb()`, `rgba()` and the basic names, with
/// `opacity`, `fill-opacity` and `stroke-opacity`; `fill-rule`; linear and
/// radial gradients by `url(#id)`, with `xlink:href` inheritance; stroke
/// width, caps, joins, miter limit and dashes; `display:none`.
library;

import 'dart:math' as math;

import '../../../geometry/offset.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../color.dart';
import '../../svg/svg_path.dart';
import '../../svg/svg_values.dart';
import '../../xml/xml.dart';
import '../bezier.dart';
import '../constants.dart';
import '../document.dart';
import '../document_object.dart';
import '../primitives.dart';
import '../selectable_objects.dart';
import '../structural_objects.dart';
import '../style.dart';

/// The namespace of the `dartui:` attributes.
const String kDartUiSvgNamespace = 'https://dart-ui.dev/ns/vector';

/// Bidirectional SVG codec for vector documents.
class VectorSvgCodec {
  /// Exports page [pageIndex] of [doc] as an SVG 1.1 document.
  static String exportToSvg(VectorDocument doc, {int pageIndex = 0}) =>
      _SvgWriter(doc).write(doc.getPage(pageIndex));

  /// Parses SVG source into a [VectorDocument].
  ///
  /// Throws [FormatException] for source that is not XML or has no `<svg>`
  /// root; anything inside that cannot be understood is skipped.
  static VectorDocument importFromSvg(String svgXml) =>
      _SvgReader().read(svgXml);
}

// ===========================================================================
// Writing
// ===========================================================================

final class _SvgWriter {
  _SvgWriter(this.doc);

  final VectorDocument doc;
  final StringBuffer _defs = StringBuffer();
  int _gradients = 0;

  String write(VectorPage page) {
    final double w = page.width;
    final double h = page.height;
    final StringBuffer body = StringBuffer();
    var layerIndex = 0;
    for (final VectorLayer layer in page.children
        .whereType<VectorLayer>()
        .where((l) => !l.isGuideLayer)) {
      layerIndex++;
      final List<String> attributes = <String>[
        'id="layer$layerIndex"',
        'inkscape:groupmode="layer"',
        'inkscape:label="${_escape(layer.name)}"',
        if (!layer.isVisible) 'style="display:none"',
        if (!layer.isEditable) 'sodipodi:insensitive="true"',
      ];
      body.writeln('  <g ${attributes.join(' ')}>');
      for (final DocumentObject child in layer.children) {
        _object(child, body, '    ');
      }
      body.writeln('  </g>');
    }

    final StringBuffer out = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8" standalone="no"?>')
      ..writeln('<svg xmlns="http://www.w3.org/2000/svg" '
          'xmlns:xlink="http://www.w3.org/1999/xlink" '
          'xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" '
          'xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" '
          'xmlns:dartui="$kDartUiSvgNamespace" '
          'width="${_n(w)}pt" height="${_n(h)}pt" viewBox="0 0 ${_n(w)} ${_n(h)}" '
          'version="1.1" dartui:page="${_escape(page.pageFormat.name)}" '
          'dartui:units="${doc.docUnits.name}">');
    if (doc.metaInfo.author.isNotEmpty || doc.metaInfo.notes.isNotEmpty) {
      out.writeln('  <metadata>');
      if (doc.metaInfo.author.isNotEmpty) {
        out.writeln('    <dartui:author>${_escape(doc.metaInfo.author)}'
            '</dartui:author>');
      }
      if (doc.metaInfo.notes.isNotEmpty) {
        out.writeln('    <dartui:notes>${_escape(doc.metaInfo.notes)}'
            '</dartui:notes>');
      }
      out.writeln('  </metadata>');
    }
    if (_defs.isNotEmpty) {
      out
        ..writeln('  <defs>')
        ..write(_defs)
        ..writeln('  </defs>');
    }
    out
      ..write(body)
      ..writeln('</svg>');
    return out.toString();
  }

  void _object(DocumentObject obj, StringBuffer out, String indent) {
    if (obj is VectorGroup) {
      out.writeln('$indent<g dartui:type="group" '
          'dartui:trafo="${_list(obj.trafo)}">');
      for (final DocumentObject child in obj.children) {
        _object(child, out, '$indent  ');
      }
      out.writeln('$indent</g>');
      return;
    }
    if (obj is VectorText) {
      final TextStyleDescriptor text = obj.style.textStyle;
      final List<String> attributes = <String>[
        'transform="matrix(${_list(obj.trafo)})"',
        'x="0" y="0"',
        'font-size="${_n(text.fontSize)}"',
        'font-family="${_escape(text.fontFamily)}"',
        if (text.bold) 'font-weight="bold"',
        if (text.italic) 'font-style="italic"',
        ..._paint(obj, null),
        'dartui:type="text"',
      ];
      out.writeln('$indent<text ${attributes.join(' ')}>'
          '${_escape(obj.textContent)}</text>');
      return;
    }
    if (obj is! PrimitiveObject) return;
    final List<VectorPath> paths = obj.cachePaths ?? obj.getInitialPaths();
    if (paths.isEmpty) return;
    final String d = _pathData(paths, obj.trafo);
    final List<String> attributes = <String>[
      'd="$d"',
      ..._paint(obj, paths),
      ..._identity(obj),
    ];
    out.writeln('$indent<path ${attributes.join(' ')}/>');
  }

  /// The `dartui:` attributes that bring a primitive back as itself.
  List<String> _identity(PrimitiveObject obj) {
    final String trafo = 'dartui:trafo="${_list(obj.trafo)}"';
    return switch (obj) {
      VectorRectangle() => <String>[
          'dartui:type="rect"',
          trafo,
          'dartui:rect="${_list(obj.getRect())}"',
          'dartui:corners="${_list(obj.corners)}"',
        ],
      VectorCircle() => <String>[
          'dartui:type="ellipse"',
          trafo,
          'dartui:arc="${_n(obj.angle1)} ${_n(obj.angle2)} ${obj.arcType.name}"',
        ],
      VectorPolygon() => <String>[
          'dartui:type="polygon"',
          trafo,
          'dartui:polygon="${obj.cornersNum} ${_n(obj.angle1)} '
              '${_n(obj.angle2)} ${_n(obj.coef1)} ${_n(obj.coef2)}"',
        ],
      VectorCurve() => <String>['dartui:type="curve"', trafo],
      _ => const <String>[],
    };
  }

  /// Fill and stroke as presentation attributes.
  List<String> _paint(SelectableObject obj, List<VectorPath>? paths) {
    final FillDescriptor fill = obj.style.fill;
    final StrokeDescriptor stroke = obj.style.stroke;
    final List<String> out = <String>[];
    if (fill.isNone) {
      out.add('fill="none"');
    } else if (fill.isGradient &&
        fill.gradientStops.length >= 2 &&
        obj is PrimitiveObject &&
        paths != null) {
      out.add('fill="url(#${_gradient(obj, paths)})"');
      out.add('dartui:gradient="${fill.fillType.name} '
          '${_point(fill.gradientStart)} ${_point(fill.gradientEnd)} '
          '${_point(fill.gradientCenter)} ${_n(fill.gradientRadius)}"');
    } else {
      out.add('fill="${_hex(fill.color)}"');
      if (fill.color.alpha < 255) {
        out.add('fill-opacity="${_n(fill.color.alpha / 255)}"');
      }
    }
    if (fill.fillRule == FillRule.evenOdd) out.add('fill-rule="evenodd"');
    if (stroke.isNone || stroke.width <= 0) {
      out.add('stroke="none"');
    } else {
      out
        ..add('stroke="${_hex(stroke.color)}"')
        ..add('stroke-width="${_n(stroke.width)}"');
      if (stroke.color.alpha < 255) {
        out.add('stroke-opacity="${_n(stroke.color.alpha / 255)}"');
      }
      if (stroke.cap != LineCap.butt) {
        out.add(
            'stroke-linecap="${stroke.cap == LineCap.round ? 'round' : 'square'}"');
      }
      if (stroke.join != LineJoin.miter) {
        out.add(
            'stroke-linejoin="${stroke.join == LineJoin.round ? 'round' : 'bevel'}"');
      }
      if (stroke.miterLimit != 4) {
        out.add('stroke-miterlimit="${_n(stroke.miterLimit)}"');
      }
      if (stroke.dashPattern.isNotEmpty) {
        out.add('stroke-dasharray="${_list(stroke.dashPattern)}"');
        if (stroke.dashOffset != 0) {
          out.add('stroke-dashoffset="${_n(stroke.dashOffset)}"');
        }
      }
    }
    return out;
  }

  /// Writes the fill's gradient into `<defs>` in document space - the same
  /// mapping the canvas renders with - and returns its id.
  String _gradient(PrimitiveObject obj, List<VectorPath> paths) {
    final FillDescriptor fill = obj.style.fill;
    final String id = 'gradient${++_gradients}';
    final Rect box = _localBox(paths);
    Offset map(Offset relative) => applyTrafoToPoint(
        Offset(box.left + relative.dx * box.width,
            box.top + relative.dy * box.height),
        obj.trafo);
    final StringBuffer stops = StringBuffer();
    for (final GradientColorStop stop in fill.gradientStops) {
      stops.writeln('      <stop offset="${_n(stop.offset)}" '
          'stop-color="${_hex(stop.color)}"'
          '${stop.color.alpha < 255 ? ' stop-opacity="${_n(stop.color.alpha / 255)}"' : ''}/>');
    }
    if (fill.fillType == FillType.radialGradient) {
      final Offset centre = map(fill.gradientCenter);
      final Offset edge = map(Offset(
          fill.gradientCenter.dx + fill.gradientRadius,
          fill.gradientCenter.dy));
      _defs
        ..writeln('    <radialGradient id="$id" gradientUnits="userSpaceOnUse" '
            'cx="${_n(centre.dx)}" cy="${_n(centre.dy)}" '
            'r="${_n((edge - centre).distance)}">')
        ..write(stops)
        ..writeln('    </radialGradient>');
    } else {
      final Offset start = map(fill.gradientStart);
      final Offset end = map(fill.gradientEnd);
      _defs
        ..writeln('    <linearGradient id="$id" gradientUnits="userSpaceOnUse" '
            'x1="${_n(start.dx)}" y1="${_n(start.dy)}" '
            'x2="${_n(end.dx)}" y2="${_n(end.dy)}">')
        ..write(stops)
        ..writeln('    </linearGradient>');
    }
    return id;
  }

  static String _pathData(List<VectorPath> paths, List<double> trafo) {
    final StringBuffer d = StringBuffer();
    for (final VectorPath vp in paths) {
      final Offset start = applyTrafoToPoint(vp.start, trafo);
      d.write('M${_n(start.dx)} ${_n(start.dy)}');
      for (final Object pt in vp.points) {
        if (pt is CurvePoint) {
          final Offset c1 = applyTrafoToPoint(pt.control1, trafo);
          final Offset c2 = applyTrafoToPoint(pt.control2, trafo);
          final Offset end = applyTrafoToPoint(pt.endpoint, trafo);
          d.write('C${_n(c1.dx)} ${_n(c1.dy)} ${_n(c2.dx)} ${_n(c2.dy)} '
              '${_n(end.dx)} ${_n(end.dy)}');
        } else if (pt is Offset) {
          final Offset end = applyTrafoToPoint(pt, trafo);
          d.write('L${_n(end.dx)} ${_n(end.dy)}');
        }
      }
      if (vp.isClosed) d.write('Z');
    }
    return d.toString();
  }
}

// ===========================================================================
// Reading
// ===========================================================================

/// Presentation state inherited down the tree.
final class _Style {
  const _Style({
    this.fill = 0xFF000000,
    this.fillUrl,
    this.stroke,
    this.strokeWidth = 1,
    this.opacity = 1,
    this.fillOpacity = 1,
    this.strokeOpacity = 1,
    this.fillRule = FillRule.nonZero,
    this.cap = LineCap.butt,
    this.join = LineJoin.miter,
    this.miterLimit = 4,
    this.dashes = const <double>[],
    this.dashOffset = 0,
    this.fontSize = 16,
    this.fontFamily = 'Sans',
    this.bold = false,
    this.italic = false,
    this.visible = true,
    this.currentColor = 0xFF000000,
  });

  final int? fill;
  final String? fillUrl;
  final int? stroke;
  final double strokeWidth;
  final double opacity;
  final double fillOpacity;
  final double strokeOpacity;
  final FillRule fillRule;
  final LineCap cap;
  final LineJoin join;
  final double miterLimit;
  final List<double> dashes;
  final double dashOffset;
  final double fontSize;
  final String fontFamily;
  final bool bold;
  final bool italic;
  final bool visible;
  final int currentColor;
}

final class _Gradient {
  _Gradient({
    required this.radial,
    required this.stops,
    required this.userSpace,
    required this.geometry,
    required this.transform,
  });

  final bool radial;
  final List<GradientColorStop> stops;
  final bool userSpace;

  /// x1 y1 x2 y2, or cx cy r.
  final List<double> geometry;
  final Transform2D transform;
}

final class _SvgReader {
  final Map<String, XmlElement> _byId = <String, XmlElement>{};
  final Map<String, _Gradient?> _gradients = <String, _Gradient?>{};

  VectorDocument read(String source) {
    final XmlDocument xml;
    try {
      xml = XmlDocument.parse(source);
    } on Object catch (error) {
      throw FormatException('not an SVG document: $error');
    }
    final Iterable<XmlElement> roots = xml.findElements('svg');
    if (roots.isEmpty) {
      throw const FormatException('no <svg> root element');
    }
    final XmlElement root = roots.first;
    _index(root);

    // Page size in points; user units through the viewBox.
    final Rect? viewBox = _tryViewBox(root.getAttribute('viewBox'));
    double? widthPt = _lengthPt(root.getAttribute('width'));
    double? heightPt = _lengthPt(root.getAttribute('height'));
    widthPt ??= viewBox == null ? null : viewBox.width * 0.75;
    heightPt ??= viewBox == null ? null : viewBox.height * 0.75;
    widthPt ??= PageFormats.a4.width;
    heightPt ??= PageFormats.a4.height;
    // A file with a viewBox draws its user units into the page; one without
    // has CSS pixels as user units, and a pixel is three quarters of a point.
    final Transform2D rootTransform = viewBox == null
        ? const Transform2D.scaling(0.75, 0.75)
        : Transform2D.scaling(
                widthPt / viewBox.width, heightPt / viewBox.height)
            .multiply(Transform2D.translation(-viewBox.left, -viewBox.top));

    final String? units = root.getAttribute('dartui:units');
    final VectorDocument doc = VectorDocument(
      docUnits: DocUnit.values.firstWhere((u) => u.name == units,
          orElse: () => _unitsOf(root.getAttribute('width'))),
      docOrigin: DocOrigin.upperLeft,
    );
    final VectorPage page = doc.getPage(0);
    final PageSize? known = PageFormats.all
        .where((p) =>
            (p.width - widthPt!).abs() < 0.5 &&
                (p.height - heightPt!).abs() < 0.5 ||
            (p.width - heightPt!).abs() < 0.5 &&
                (p.height - widthPt).abs() < 0.5)
        .firstOrNull;
    page.pageFormat = known == null
        ? PageFormat(size: PageSize('Custom', widthPt, heightPt))
        : PageFormat(
            size: known,
            orientation: widthPt > heightPt
                ? PageOrientation.landscape
                : PageOrientation.portrait);

    final VectorLayer defaultLayer =
        page.children.whereType<VectorLayer>().first;
    var usedDefault = false;
    final _Style rootStyle = _style(const _Style(), root);
    for (final XmlElement child in root.childElements) {
      if (child.name.local == 'g' &&
          child.getAttribute('inkscape:groupmode') == 'layer') {
        final _Style style = _style(rootStyle, child, ignoreDisplay: true);
        final VectorLayer layer =
            usedDefault || defaultLayer.children.isNotEmpty
                ? doc.addLayer(page,
                    name: child.getAttribute('inkscape:label') ?? 'Layer')
                : (defaultLayer
                  ..name = child.getAttribute('inkscape:label') ?? 'Layer');
        usedDefault = true;
        layer.properties[0] = _displayed(child);
        if (child.getAttribute('sodipodi:insensitive') == 'true') {
          layer.properties[1] = false;
        }
        final Transform2D ctm =
            rootTransform.multiply(_transform(child.getAttribute('transform')));
        for (final XmlElement grandchild in child.childElements) {
          _element(grandchild, layer, ctm, style);
        }
      } else {
        _element(child, defaultLayer, rootTransform, rootStyle);
      }
    }
    doc.update();
    return doc;
  }

  void _index(XmlElement element) {
    final String? id = element.getAttribute('id');
    if (id != null) _byId[id] = element;
    for (final XmlElement child in element.childElements) {
      _index(child);
    }
  }

  /// Converts one element (and its subtree) and adds it to [parent].
  void _element(XmlElement element, DocumentObject parent, Transform2D ctm,
      _Style inherited) {
    final String name = element.name.local;
    if (const <String>{
      'defs',
      'metadata',
      'title',
      'desc',
      'style',
      'linearGradient',
      'radialGradient',
      'clipPath',
      'mask',
      'pattern',
      'symbol',
      'marker',
      'namedview',
    }.contains(name)) {
      return;
    }
    final _Style style = _style(inherited, element);
    if (!style.visible && name != 'g') return;
    final Transform2D local =
        ctm.multiply(_transform(element.getAttribute('transform')));

    if (name == 'g' || name == 'a') {
      final VectorGroup group = VectorGroup();
      for (final XmlElement child in element.childElements) {
        _element(child, group, local, style);
      }
      if (!style.visible || group.children.isEmpty) return;
      if (group.children.length == 1 &&
          element.getAttribute('dartui:type') != 'group') {
        // A wrapper group carries only its transform, which the child
        // already has: keep the child, not a group of one.
        _add(parent, group.children.single);
        return;
      }
      for (final DocumentObject child in group.children) {
        child.parent = group;
      }
      _add(parent, group..update());
      return;
    }

    if (name == 'use') {
      final String? href =
          element.getAttribute('xlink:href') ?? element.getAttribute('href');
      final XmlElement? target = href != null && href.startsWith('#')
          ? _byId[href.substring(1)]
          : null;
      if (target == null) return;
      final double x = _number(element, 'x');
      final double y = _number(element, 'y');
      _element(
          target, parent, local.multiply(Transform2D.translation(x, y)), style);
      return;
    }

    final SelectableObject? object = _shape(element, name, local, style);
    if (object == null) return;
    _add(parent, object);
  }

  SelectableObject? _shape(
      XmlElement element, String name, Transform2D ctm, _Style style) {
    final String? type = element.getAttribute('dartui:type');
    final List<double>? savedTrafo =
        _numbersOrNull(element.getAttribute('dartui:trafo'));
    // The rest of this file's own primitives, rebuilt as themselves. The
    // saved transform is in document space already, so the file's own
    // viewBox scaling (identity for a file this codec wrote) is applied on
    // top rather than the element's.
    if (type != null && savedTrafo != null && savedTrafo.length == 6) {
      final Transform2D page = _pageOf(element, ctm);
      final List<double> trafo = _compose(page, savedTrafo);
      final PrimitiveObject? rebuilt = switch (type) {
        'rect' => _savedRect(element, trafo),
        'ellipse' => _savedEllipse(element, trafo),
        'polygon' => _savedPolygon(element, trafo),
        'curve' => null, // the path data is the curve
        _ => null,
      };
      if (rebuilt != null) {
        rebuilt.style = _vectorStyle(element, style, page);
        rebuilt.update();
        _applyGradient(rebuilt, element, style, ctm);
        return rebuilt;
      }
    }

    switch (name) {
      case 'rect':
        final double w = _number(element, 'width');
        final double h = _number(element, 'height');
        if (w <= 0 || h <= 0) return null;
        double? rx = _numberOrNull(element, 'rx');
        double? ry = _numberOrNull(element, 'ry');
        rx ??= ry;
        ry ??= rx;
        final double round = rx == null
            ? 0
            : (math.min(rx, ry!) / (math.min(w, h) / 2)).clamp(0.0, 1.0);
        final VectorRectangle rect = VectorRectangle(
          startX: _number(element, 'x'),
          startY: _number(element, 'y'),
          rectWidth: w,
          rectHeight: h,
          corners: <double>[round, round, round, round],
          trafo: _trafo(ctm),
          style: _vectorStyle(element, style, ctm),
        )..update();
        _applyGradient(rect, element, style, ctm);
        return rect;
      case 'circle':
      case 'ellipse':
        final double r = _number(element, 'r');
        final double rx = name == 'circle' ? r : _number(element, 'rx');
        final double ry = name == 'circle' ? r : _number(element, 'ry');
        if (rx <= 0 || ry <= 0) return null;
        final double cx = _number(element, 'cx');
        final double cy = _number(element, 'cy');
        final List<double> trafo =
            _compose(ctm, <double>[rx * 2, 0, 0, ry * 2, cx - rx, cy - ry]);
        final VectorCircle circle = VectorCircle(
          trafo: trafo,
          initialTrafo: List<double>.of(trafo),
          style: _vectorStyle(element, style, ctm),
        )..update();
        _applyGradient(circle, element, style, ctm);
        return circle;
      case 'line':
      case 'polyline':
      case 'polygon':
      case 'path':
        final List<VectorPath> paths = _paths(element, name);
        if (paths.isEmpty) return null;
        final VectorCurve curve = VectorCurve(
          paths: paths,
          trafo: _trafo(ctm),
          style: _vectorStyle(element, style, ctm),
        )..update();
        _applyGradient(curve, element, style, ctm);
        return curve;
      case 'text':
        final String content = element.innerText.trim();
        if (content.isEmpty) return null;
        final List<double> x =
            _numbersOrNull(element.getAttribute('x')) ?? const <double>[0];
        final List<double> y =
            _numbersOrNull(element.getAttribute('y')) ?? const <double>[0];
        final VectorStyle base = _vectorStyle(element, style, ctm);
        return VectorText(
          textContent: content,
          trafo: _compose(ctm, <double>[
            1,
            0,
            0,
            1,
            x.isEmpty ? 0 : x.first,
            y.isEmpty ? 0 : y.first,
          ]),
          style: base.copyWith(
            stroke: StrokeDescriptor.none,
            textStyle: base.textStyle.copyWith(
              fontSize: style.fontSize,
              fontFamily: style.fontFamily,
              bold: style.bold,
              italic: style.italic,
            ),
          ),
        )..update();
    }
    return null;
  }

  /// The transform from page space for an element this codec wrote: the
  /// chain above it without the element's own `transform` attribute, which
  /// (for text) restates the saved trafo.
  Transform2D _pageOf(XmlElement element, Transform2D ctm) {
    final String? own = element.getAttribute('transform');
    if (own == null) return ctm;
    final Transform2D t = _transform(own);
    final double det = t.a * t.d - t.b * t.c;
    if (det == 0) return ctm;
    final Transform2D inverse = Transform2D(
      t.d / det,
      -t.b / det,
      -t.c / det,
      t.a / det,
      (t.c * t.ty - t.d * t.tx) / det,
      (t.b * t.tx - t.a * t.ty) / det,
    );
    return ctm.multiply(inverse);
  }

  PrimitiveObject? _savedRect(XmlElement element, List<double> trafo) {
    final List<double>? rect =
        _numbersOrNull(element.getAttribute('dartui:rect'));
    if (rect == null || rect.length != 4) return null;
    final List<double>? corners =
        _numbersOrNull(element.getAttribute('dartui:corners'));
    return VectorRectangle(
      startX: rect[0],
      startY: rect[1],
      rectWidth: rect[2],
      rectHeight: rect[3],
      corners: corners != null && corners.length == 4 ? corners : null,
      trafo: trafo,
    );
  }

  PrimitiveObject _savedEllipse(XmlElement element, List<double> trafo) {
    final List<String> arc =
        (element.getAttribute('dartui:arc') ?? '').split(RegExp(r'\s+'));
    return VectorCircle(
      trafo: trafo,
      initialTrafo: List<double>.of(trafo),
      angle1: arc.isNotEmpty ? double.tryParse(arc[0]) ?? 0 : 0,
      angle2: arc.length > 1 ? double.tryParse(arc[1]) ?? 0 : 0,
      arcType: arc.length > 2
          ? ArcType.values
              .firstWhere((t) => t.name == arc[2], orElse: () => ArcType.chord)
          : ArcType.chord,
    );
  }

  PrimitiveObject? _savedPolygon(XmlElement element, List<double> trafo) {
    final List<double>? p =
        _numbersOrNull(element.getAttribute('dartui:polygon'));
    if (p == null || p.length != 5) return null;
    return VectorPolygon(
      cornersNum: p[0].round().clamp(3, 1000),
      angle1: p[1],
      angle2: p[2],
      coef1: p[3],
      coef2: p[4],
      trafo: trafo,
      initialTrafo: List<double>.of(trafo),
    );
  }

  List<VectorPath> _paths(XmlElement element, String name) {
    try {
      final String d = switch (name) {
        'line' => 'M${_number(element, 'x1')} ${_number(element, 'y1')} '
            'L${_number(element, 'x2')} ${_number(element, 'y2')}',
        'polyline' || 'polygon' => () {
            final List<double> n =
                parseSvgNumbers(element.getAttribute('points') ?? '');
            if (n.length < 4) return '';
            final StringBuffer b = StringBuffer('M${n[0]} ${n[1]}');
            for (var i = 2; i + 1 < n.length; i += 2) {
              b.write(' L${n[i]} ${n[i + 1]}');
            }
            if (name == 'polygon') b.write(' Z');
            return b.toString();
          }(),
        _ => element.getAttribute('d') ?? '',
      };
      if (d.trim().isEmpty) return const <VectorPath>[];
      return vectorPathsFromPath(parseSvgPathData(d));
    } on Object {
      return const <VectorPath>[];
    }
  }

  // --- style ---------------------------------------------------------------

  _Style _style(_Style parent, XmlElement element,
      {bool ignoreDisplay = false}) {
    final Map<String, String> v = <String, String>{};
    const List<String> names = <String>[
      'fill',
      'stroke',
      'stroke-width',
      'opacity',
      'fill-opacity',
      'stroke-opacity',
      'fill-rule',
      'stroke-linecap',
      'stroke-linejoin',
      'stroke-miterlimit',
      'stroke-dasharray',
      'stroke-dashoffset',
      'font-size',
      'font-family',
      'font-weight',
      'font-style',
      'display',
      'visibility',
      'color',
    ];
    for (final String name in names) {
      final String? value = element.getAttribute(name);
      if (value != null) v[name] = value.trim();
    }
    final String? inline = element.getAttribute('style');
    if (inline != null) {
      for (final String declaration in inline.split(';')) {
        final int colon = declaration.indexOf(':');
        if (colon <= 0) continue;
        v[declaration.substring(0, colon).trim().toLowerCase()] =
            declaration.substring(colon + 1).trim();
      }
    }
    int? color(String raw, int? fallback, int current) {
      try {
        return parseSvgColor(raw, current);
      } on Object {
        return fallback;
      }
    }

    final int currentColor = v.containsKey('color')
        ? color(v['color']!, parent.currentColor, parent.currentColor) ??
            parent.currentColor
        : parent.currentColor;
    final String? fillRaw = v['fill'];
    final bool fillIsUrl = fillRaw != null && fillRaw.startsWith('url(');
    final String? fontWeight = v['font-weight'];
    return _Style(
      fill: fillRaw == null
          ? parent.fill
          : fillIsUrl
              ? parent.fill
              : color(fillRaw, parent.fill, currentColor),
      fillUrl: fillRaw == null ? parent.fillUrl : (fillIsUrl ? fillRaw : null),
      stroke: v.containsKey('stroke')
          ? (v['stroke']!.startsWith('url(')
              ? parent.stroke ?? 0xFF000000
              : color(v['stroke']!, parent.stroke, currentColor))
          : parent.stroke,
      strokeWidth: _lengthUser(v['stroke-width']) ?? parent.strokeWidth,
      opacity: parent.opacity * parseSvgUnit(v['opacity'], 1),
      fillOpacity: v.containsKey('fill-opacity')
          ? parseSvgUnit(v['fill-opacity'], 1)
          : parent.fillOpacity,
      strokeOpacity: v.containsKey('stroke-opacity')
          ? parseSvgUnit(v['stroke-opacity'], 1)
          : parent.strokeOpacity,
      fillRule: switch (v['fill-rule']?.toLowerCase()) {
        'evenodd' => FillRule.evenOdd,
        'nonzero' => FillRule.nonZero,
        _ => parent.fillRule,
      },
      cap: switch (v['stroke-linecap']?.toLowerCase()) {
        'round' => LineCap.round,
        'square' => LineCap.square,
        'butt' => LineCap.butt,
        _ => parent.cap,
      },
      join: switch (v['stroke-linejoin']?.toLowerCase()) {
        'round' => LineJoin.round,
        'bevel' => LineJoin.bevel,
        'miter' => LineJoin.miter,
        _ => parent.join,
      },
      miterLimit:
          double.tryParse(v['stroke-miterlimit'] ?? '') ?? parent.miterLimit,
      dashes: v.containsKey('stroke-dasharray')
          ? (v['stroke-dasharray'] == 'none'
              ? const <double>[]
              : parseSvgNumbers(v['stroke-dasharray']!))
          : parent.dashes,
      dashOffset:
          double.tryParse(v['stroke-dashoffset'] ?? '') ?? parent.dashOffset,
      fontSize: _lengthUser(v['font-size']) ?? parent.fontSize,
      fontFamily: v['font-family']
              ?.split(',')
              .first
              .trim()
              .replaceAll(RegExp(r'''['"]'''), '') ??
          parent.fontFamily,
      bold: fontWeight == null
          ? parent.bold
          : fontWeight == 'bold' ||
              fontWeight == 'bolder' ||
              (int.tryParse(fontWeight) ?? 400) >= 600,
      italic: v.containsKey('font-style')
          ? v['font-style'] == 'italic' || v['font-style'] == 'oblique'
          : parent.italic,
      visible: parent.visible &&
          (ignoreDisplay || v['display']?.toLowerCase() != 'none') &&
          v['visibility']?.toLowerCase() != 'hidden',
      currentColor: currentColor,
    );
  }

  bool _displayed(XmlElement element) {
    final String? display = element.getAttribute('display');
    final String inline = element.getAttribute('style') ?? '';
    return display?.trim() != 'none' &&
        !RegExp(r'display\s*:\s*none').hasMatch(inline);
  }

  /// The document style of an element whose user space maps to the page
  /// through [ctm]. Stroke widths are scaled by it: an SVG stroke is in the
  /// element's units, a document stroke is in points.
  VectorStyle _vectorStyle(XmlElement element, _Style style, Transform2D ctm) {
    final int? fillArgb = style.fill;
    final FillDescriptor fill = fillArgb == null && style.fillUrl == null
        ? FillDescriptor.none
        : FillDescriptor(
            fillType: FillType.solid,
            fillRule: style.fillRule,
            color: Color(_withAlpha(
                fillArgb ?? 0xFF000000, style.opacity * style.fillOpacity)),
          );
    final int? strokeArgb = style.stroke;
    final StrokeDescriptor stroke = strokeArgb == null
        ? StrokeDescriptor.none
        : StrokeDescriptor(
            color: Color(
                _withAlpha(strokeArgb, style.opacity * style.strokeOpacity)),
            width: style.strokeWidth * _scaleOf(ctm),
            cap: style.cap,
            join: style.join,
            miterLimit: style.miterLimit,
            dashPattern: <double>[
              for (final double d in style.dashes) d * _scaleOf(ctm),
            ],
            dashOffset: style.dashOffset * _scaleOf(ctm),
          );
    return VectorStyle(
      fill: fill,
      stroke: stroke,
      textStyle: TextStyleDescriptor(
        fontSize: style.fontSize,
        fontFamily: style.fontFamily,
        bold: style.bold,
        italic: style.italic,
      ),
    );
  }

  /// Replaces a solid fill with the gradient `fill="url(#id)"` names, in the
  /// object's own relative coordinates.
  void _applyGradient(
      PrimitiveObject obj, XmlElement element, _Style style, Transform2D ctm) {
    final String? url = style.fillUrl;
    if (url == null) return;
    final RegExpMatch? match =
        RegExp(r'url\(\s*#([^)\s]+)\s*\)').firstMatch(url);
    if (match == null) return;
    final _Gradient? gradient = _gradient(match.group(1)!);
    if (gradient == null) {
      return;
    }
    final List<VectorPath> paths = obj.cachePaths ?? obj.getInitialPaths();
    final Rect box = _localBox(paths);
    if (box.width <= 0 || box.height <= 0) return;
    final double alpha = style.opacity * style.fillOpacity;
    final List<GradientColorStop> stops = <GradientColorStop>[
      for (final GradientColorStop stop in gradient.stops)
        GradientColorStop(
            stop.offset, Color(_withAlpha(stop.color.value, alpha))),
    ];

    // A point of the gradient, as a fraction of the object's local box.
    Offset relative(double x, double y) {
      final Offset g = gradient.transform.transformOffset(Offset(x, y));
      if (!gradient.userSpace) return g;
      // User space of the element - where the object's local geometry
      // lives too, unless the rebuilt primitive carries a different trafo.
      final Offset local = _inverseMap(obj.trafo, ctm.transformOffset(g));
      return Offset(
          (local.dx - box.left) / box.width, (local.dy - box.top) / box.height);
    }

    final List<double> g = gradient.geometry;
    final FillRule rule = obj.style.fill.fillRule;
    if (gradient.radial) {
      final Offset centre = relative(g[0], g[1]);
      final Offset edge = relative(g[0] + g[2], g[1]);
      obj.style = obj.style.copyWith(
        fill: FillDescriptor(
          fillType: FillType.radialGradient,
          fillRule: rule,
          color: stops.first.color,
          gradientStops: stops,
          gradientCenter: centre,
          gradientRadius: (edge - centre).dx.abs(),
        ),
      );
    } else {
      obj.style = obj.style.copyWith(
        fill: FillDescriptor(
          fillType: FillType.linearGradient,
          fillRule: rule,
          color: stops.first.color,
          gradientStops: stops,
          gradientStart: relative(g[0], g[1]),
          gradientEnd: relative(g[2], g[3]),
        ),
      );
    }
  }

  _Gradient? _gradient(String id, [int depth = 0]) {
    if (_gradients.containsKey(id)) return _gradients[id];
    final XmlElement? element = _byId[id];
    if (element == null || depth > 8) return null;
    final String name = element.name.local;
    if (name != 'linearGradient' && name != 'radialGradient') return null;
    final String? href =
        element.getAttribute('xlink:href') ?? element.getAttribute('href');
    final _Gradient? base = href != null && href.startsWith('#')
        ? _gradient(href.substring(1), depth + 1)
        : null;
    final List<GradientColorStop> stops = <GradientColorStop>[];
    for (final XmlElement stop
        in element.childElements.where((e) => e.name.local == 'stop')) {
      final Map<String, String> v = <String, String>{
        if (stop.getAttribute('stop-color') != null)
          'stop-color': stop.getAttribute('stop-color')!,
        if (stop.getAttribute('stop-opacity') != null)
          'stop-opacity': stop.getAttribute('stop-opacity')!,
      };
      for (final String declaration
          in (stop.getAttribute('style') ?? '').split(';')) {
        final int colon = declaration.indexOf(':');
        if (colon > 0) {
          v[declaration.substring(0, colon).trim()] =
              declaration.substring(colon + 1).trim();
        }
      }
      int argb;
      try {
        argb =
            parseSvgColor(v['stop-color'] ?? 'black', 0xFF000000) ?? 0x00000000;
      } on Object {
        argb = 0xFF000000;
      }
      final String rawOffset = stop.getAttribute('offset') ?? '0';
      final double offset = rawOffset.trim().endsWith('%')
          ? (double.tryParse(rawOffset.trim().replaceAll('%', '')) ?? 0) / 100
          : double.tryParse(rawOffset) ?? 0;
      stops.add(GradientColorStop(offset.clamp(0.0, 1.0),
          Color(_withAlpha(argb, parseSvgUnit(v['stop-opacity'], 1)))));
    }
    final bool userSpace = (element.getAttribute('gradientUnits') ??
            (base?.userSpace == true
                ? 'userSpaceOnUse'
                : 'objectBoundingBox')) ==
        'userSpaceOnUse';
    double attr(String name, double fallback) {
      final String? raw = element.getAttribute(name);
      if (raw == null) return fallback;
      final String t = raw.trim();
      if (t.endsWith('%')) {
        return (double.tryParse(t.substring(0, t.length - 1)) ?? 0) / 100;
      }
      return _lengthUser(t) ?? fallback;
    }

    final bool radial = name == 'radialGradient';
    final List<double>? inherited =
        base != null && base.radial == radial ? base.geometry : null;
    final _Gradient result = _Gradient(
      radial: radial,
      stops: stops.isNotEmpty
          ? stops
          : (base?.stops ?? const <GradientColorStop>[]),
      userSpace: userSpace,
      geometry: radial
          ? <double>[
              attr('cx', inherited?[0] ?? 0.5),
              attr('cy', inherited?[1] ?? 0.5),
              attr('r', inherited?[2] ?? 0.5),
            ]
          : <double>[
              attr('x1', inherited?[0] ?? 0),
              attr('y1', inherited?[1] ?? 0),
              attr('x2', inherited?[2] ?? 1),
              attr('y2', inherited?[3] ?? 0),
            ],
      transform: element.getAttribute('gradientTransform') != null
          ? _transform(element.getAttribute('gradientTransform'))
          : (base?.transform ?? Transform2D.identity),
    );
    _gradients[id] = result.stops.length >= 2 ? result : null;
    return _gradients[id];
  }

  // --- small helpers ---------------------------------------------------------

  static void _add(DocumentObject parent, DocumentObject child) {
    child.parent = parent;
    parent.children.add(child);
  }

  static Transform2D _transform(String? raw) {
    try {
      return parseSvgTransform(raw);
    } on Object {
      return Transform2D.identity;
    }
  }

  static Rect? _tryViewBox(String? raw) {
    try {
      final Rect? box = parseSvgViewBox(raw);
      return box == null || box.width <= 0 || box.height <= 0 ? null : box;
    } on Object {
      return null;
    }
  }

  static double _number(XmlElement element, String name) =>
      _numberOrNull(element, name) ?? 0;

  static double? _numberOrNull(XmlElement element, String name) =>
      _lengthUser(element.getAttribute(name));

  /// A length in user units: plain numbers as they are, absolute units
  /// converted through CSS's 96 px to the inch.
  static double? _lengthUser(String? raw) {
    if (raw == null) return null;
    return parseSvgLength(raw) ??
        double.tryParse(raw.replaceAll(RegExp(r'[a-z%]+$'), ''));
  }

  /// A root width or height in points.
  static double? _lengthPt(String? raw) {
    if (raw == null || raw.trim().endsWith('%')) return null;
    final double? px = parseSvgLength(raw);
    return px == null || px <= 0 ? null : px * 0.75;
  }

  static DocUnit _unitsOf(String? width) {
    final String unit = (width ?? '').replaceAll(RegExp(r'[0-9.\s+-]'), '');
    return switch (unit) {
      'mm' => DocUnit.mm,
      'cm' => DocUnit.cm,
      'in' => DocUnit.inch,
      'pt' => DocUnit.pt,
      _ => DocUnit.px,
    };
  }

  static List<double>? _numbersOrNull(String? raw) =>
      raw == null ? null : parseSvgNumbers(raw);

  static List<double> _trafo(Transform2D t) =>
      <double>[t.a, t.b, t.c, t.d, t.tx, t.ty];

  /// [outer] after [inner] (both `[a, b, c, d, tx, ty]`).
  static List<double> _compose(Transform2D outer, List<double> inner) =>
      _trafo(outer.multiply(Transform2D(
          inner[0], inner[1], inner[2], inner[3], inner[4], inner[5])));

  static double _scaleOf(Transform2D t) =>
      math.sqrt((t.a * t.d - t.b * t.c).abs());

  /// [point] in page space, brought back through [trafo] to local space.
  static Offset _inverseMap(List<double> trafo, Offset point) {
    final double det = trafo[0] * trafo[3] - trafo[1] * trafo[2];
    if (det == 0) return point;
    final double dx = point.dx - trafo[4];
    final double dy = point.dy - trafo[5];
    return Offset((trafo[3] * dx - trafo[2] * dy) / det,
        (-trafo[1] * dx + trafo[0] * dy) / det);
  }

  static int _withAlpha(int argb, double opacity) {
    final int alpha = (((argb >> 24) & 0xFF) * opacity.clamp(0.0, 1.0)).round();
    return (argb & 0x00FFFFFF) | alpha << 24;
  }
}

// ===========================================================================
// Shared
// ===========================================================================

/// The box of [paths]' end points, in their own (pre-transform) space - the
/// box a gradient's relative coordinates refer to.
Rect _localBox(List<VectorPath> paths) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  void take(Offset p) {
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }

  for (final VectorPath vp in paths) {
    take(vp.start);
    for (final Object pt in vp.points) {
      if (pt is CurvePoint) {
        take(pt.endpoint);
      } else if (pt is Offset) {
        take(pt);
      }
    }
  }
  if (!minX.isFinite) return Rect.zero;
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

String _n(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  final String s = value.toStringAsFixed(4);
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

String _list(List<double> values) => values.map(_n).join(' ');

String _point(Offset p) => '${_n(p.dx)},${_n(p.dy)}';

String _hex(Color color) =>
    '#${(color.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// Escapes text and attribute values. A text object with `&` or `<` in it
/// otherwise produced a file no XML parser would read back.
String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
