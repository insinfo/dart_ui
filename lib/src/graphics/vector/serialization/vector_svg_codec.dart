/// SVG encoder and decoder for [VectorDocument].
library;

import 'package:xml/xml.dart';

import '../../../geometry/offset.dart';
import '../../color.dart';
import '../../svg/svg_path.dart';
import '../bezier.dart';
import '../constants.dart';
import '../document.dart';
import '../document_object.dart';
import '../primitives.dart';
import '../selectable_objects.dart';
import '../structural_objects.dart';
import '../style.dart';

/// Bidirectional SVG codec for vector documents.
class VectorSvgCodec {
  /// Exports [doc] to standard SVG 1.1 XML string.
  static String exportToSvg(VectorDocument doc, {int pageIndex = 0}) {
    final page = doc.getPage(pageIndex);
    final w = page.width;
    final h = page.height;

    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8" standalone="no"?>');
    buffer.writeln(
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        'width="${w}pt" height="${h}pt" viewBox="0 0 $w $h" version="1.1">');

    // Metadata
    if (doc.metaInfo.author.isNotEmpty || doc.metaInfo.notes.isNotEmpty) {
      buffer.writeln('  <metadata>');
      if (doc.metaInfo.author.isNotEmpty) {
        buffer.writeln('    <author>${doc.metaInfo.author}</author>');
      }
      if (doc.metaInfo.notes.isNotEmpty) {
        buffer.writeln('    <description>${doc.metaInfo.notes}</description>');
      }
      buffer.writeln('  </metadata>');
    }

    for (final layer in doc.getVisibleLayers(page)) {
      buffer.writeln('  <g id="${layer.name}" stroke-linecap="round">');
      for (final child in layer.children) {
        _exportObject(child, buffer, '    ');
      }
      buffer.writeln('  </g>');
    }

    buffer.writeln('</svg>');
    return buffer.toString();
  }

  static void _exportObject(
      DocumentObject obj, StringBuffer buffer, String indent) {
    if (obj is VectorGroup) {
      buffer.writeln('$indent<g>');
      for (final child in obj.children) {
        _exportObject(child, buffer, '$indent  ');
      }
      buffer.writeln('$indent</g>');
      return;
    }

    if (obj is VectorText) {
      final pos = applyTrafoToPoint(Offset.zero, obj.trafo);
      final fillHex = _colorToHex(obj.style.fill.color);
      buffer.writeln(
          '$indent<text x="${pos.dx}" y="${pos.dy}" font-size="${obj.style.textStyle.fontSize}" '
          'font-family="${obj.style.textStyle.fontFamily}" fill="$fillHex">${obj.textContent}</text>');
      return;
    }

    if (obj is PrimitiveObject) {
      final paths = obj.cachePaths ?? obj.getInitialPaths();
      if (paths.isEmpty) return;

      final dBuffer = StringBuffer();
      for (final vp in paths) {
        final start = applyTrafoToPoint(vp.start, obj.trafo);
        dBuffer.write('M ${start.dx} ${start.dy} ');

        for (final pt in vp.points) {
          if (pt is CurvePoint) {
            final cp1 = applyTrafoToPoint(pt.control1, obj.trafo);
            final cp2 = applyTrafoToPoint(pt.control2, obj.trafo);
            final end = applyTrafoToPoint(pt.endpoint, obj.trafo);
            dBuffer.write(
                'C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${end.dx} ${end.dy} ');
          } else if (pt is Offset) {
            final end = applyTrafoToPoint(pt, obj.trafo);
            dBuffer.write('L ${end.dx} ${end.dy} ');
          }
        }

        if (vp.isClosed) {
          dBuffer.write('Z ');
        }
      }

      final fillStr = obj.style.fill.isNone
          ? 'none'
          : _colorToHex(obj.style.fill.color);
      final strokeStr = obj.style.stroke.isNone
          ? 'none'
          : _colorToHex(obj.style.stroke.color);
      final strokeWidth = obj.style.stroke.width;

      buffer.writeln(
          '$indent<path d="${dBuffer.toString().trim()}" fill="$fillStr" stroke="$strokeStr" stroke-width="$strokeWidth"/>');
    }
  }

  /// Parses an SVG XML string into a [VectorDocument].
  static VectorDocument importFromSvg(String svgXml) {
    final doc = VectorDocument(
      docUnits: DocUnit.pt,
      docOrigin: DocOrigin.upperLeft,
    );

    final page = doc.getPage(0);
    final layer = page.children.whereType<VectorLayer>().first;

    final document = XmlDocument.parse(svgXml);
    final svgElem = document.findElements('svg').firstOrNull;

    if (svgElem != null) {
      final widthAttr = svgElem.getAttribute('width');
      final heightAttr = svgElem.getAttribute('height');
      if (widthAttr != null && heightAttr != null) {
        final w = double.tryParse(widthAttr.replaceAll(RegExp(r'[^\d.]'), ''));
        final h = double.tryParse(heightAttr.replaceAll(RegExp(r'[^\d.]'), ''));
        if (w != null && h != null && w > 0 && h > 0) {
          page.pageFormat = PageFormat(size: PageSize('SVG', w, h));
        }
      }

      _importXmlChildren(svgElem, layer, doc);
    }

    doc.update();
    return doc;
  }

  static void _importXmlChildren(
      XmlElement parentElem, VectorLayer layer, VectorDocument doc) {
    for (final child in parentElem.children.whereType<XmlElement>()) {
      switch (child.name.local) {
        case 'g':
          _importXmlChildren(child, layer, doc);
        case 'rect':
          final x = double.tryParse(child.getAttribute('x') ?? '0') ?? 0;
          final y = double.tryParse(child.getAttribute('y') ?? '0') ?? 0;
          final w = double.tryParse(child.getAttribute('width') ?? '0') ?? 0;
          final h = double.tryParse(child.getAttribute('height') ?? '0') ?? 0;
          if (w > 0 && h > 0) {
            final rect = VectorRectangle(
              startX: x,
              startY: y,
              rectWidth: w,
              rectHeight: h,
              style: _parseStyle(child),
            );
            rect.parent = layer;
            layer.children.add(rect);
          }
        case 'circle':
          final cx = double.tryParse(child.getAttribute('cx') ?? '0') ?? 0;
          final cy = double.tryParse(child.getAttribute('cy') ?? '0') ?? 0;
          final r = double.tryParse(child.getAttribute('r') ?? '0') ?? 0;
          if (r > 0) {
            final circle = VectorCircle.fromRect(
              [cx, cy, r * 2, r * 2],
              style: _parseStyle(child),
            );
            circle.parent = layer;
            layer.children.add(circle);
          }
        case 'path':
          final d = child.getAttribute('d');
          if (d != null && d.isNotEmpty) {
            try {
              final path = parseSvgPathData(d);
              final vPaths = vectorPathsFromPath(path);
              if (vPaths.isNotEmpty) {
                final curve = VectorCurve(
                  paths: vPaths,
                  style: _parseStyle(child),
                );
                curve.parent = layer;
                layer.children.add(curve);
              }
            } catch (_) {
              // Ignore malformed SVG path
            }
          }
        case 'text':
          final x = double.tryParse(child.getAttribute('x') ?? '0') ?? 0;
          final y = double.tryParse(child.getAttribute('y') ?? '0') ?? 0;
          final text = child.innerText.trim();
          if (text.isNotEmpty) {
            final textObj = VectorText(
              textContent: text,
              trafo: [1.0, 0.0, 0.0, 1.0, x, y],
              style: _parseStyle(child),
            );
            textObj.parent = layer;
            layer.children.add(textObj);
          }
      }
    }
  }

  static VectorStyle _parseStyle(XmlElement elem) {
    var fill = const FillDescriptor.solid(Color(0xFF000000));
    var stroke = StrokeDescriptor.none;

    final fillAttr = elem.getAttribute('fill');
    if (fillAttr != null) {
      if (fillAttr == 'none') {
        fill = FillDescriptor.none;
      } else {
        final c = _parseColor(fillAttr);
        if (c != null) fill = FillDescriptor.solid(c);
      }
    }

    final strokeAttr = elem.getAttribute('stroke');
    if (strokeAttr != null && strokeAttr != 'none') {
      final c = _parseColor(strokeAttr);
      final sw =
          double.tryParse(elem.getAttribute('stroke-width') ?? '1') ?? 1.0;
      if (c != null) {
        stroke = StrokeDescriptor(color: c, width: sw);
      }
    }

    return VectorStyle(fill: fill, stroke: stroke);
  }

  static Color? _parseColor(String str) {
    final s = str.trim();
    if (s.startsWith('#')) {
      final hex = s.substring(1);
      if (hex.length == 6) {
        final val = int.tryParse(hex, radix: 16);
        if (val != null) return Color(0xFF000000 | val);
      } else if (hex.length == 3) {
        final r = int.parse(hex[0] + hex[0], radix: 16);
        final g = int.parse(hex[1] + hex[1], radix: 16);
        final b = int.parse(hex[2] + hex[2], radix: 16);
        return Color.fromARGB(255, r, g, b);
      }
    }
    return null;
  }

  static String _colorToHex(Color color) {
    final r = color.red.toRadixString(16).padLeft(2, '0');
    final g = color.green.toRadixString(16).padLeft(2, '0');
    final b = color.blue.toRadixString(16).padLeft(2, '0');
    return '#$r$g$b';
  }
}
