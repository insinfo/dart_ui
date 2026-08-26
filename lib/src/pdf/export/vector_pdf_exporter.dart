/// Exporter that renders a [VectorDocument] to standard PDF bytes (ISO 32000).
library;

import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../graphics/vector/document.dart';
import '../../graphics/vector/document_object.dart';
import '../../graphics/vector/primitives.dart';
import '../../graphics/vector/selectable_objects.dart';
import '../../graphics/vector/structural_objects.dart';
import 'pdf_canvas_recorder.dart';
import 'pdf_document_builder.dart';

/// Exports [VectorDocument]s into high-fidelity PDF documents.
class VectorPdfExporter {
  /// Compiles [doc] into a standard PDF byte stream.
  static Uint8List exportToPdf(VectorDocument doc) {
    final builder = PdfDocumentBuilder(
      title: doc.metaInfo.notes.isNotEmpty
          ? doc.metaInfo.notes
          : 'dart_ui Vector Document',
      author: doc.metaInfo.author.isNotEmpty
          ? doc.metaInfo.author
          : 'dart_ui Vector Engine',
    );

    for (final page in doc.pageList) {
      final w = page.width;
      final h = page.height;
      final recorder = builder.addPage(width: w, height: h);

      // Render visible layers bottom-to-top
      for (final layer in doc.getVisibleLayers(page)) {
        _renderLayer(layer, recorder, h);
      }
    }

    return builder.build();
  }

  static void _renderLayer(
      VectorLayer layer, PdfCanvasRecorder recorder, double pageHeight) {
    for (final child in layer.children) {
      _renderObject(child, recorder, pageHeight);
    }
  }

  static void _renderObject(
      DocumentObject obj, PdfCanvasRecorder recorder, double pageHeight) {
    if (obj is VectorGroup) {
      for (final child in obj.children) {
        _renderObject(child, recorder, pageHeight);
      }
      return;
    }

    if (obj is PrimitiveObject) {
      final paths = obj.cachePaths ?? obj.getInitialPaths();
      if (paths.isEmpty && obj is! VectorText) return;

      final fill = obj.style.fill;
      final stroke = obj.style.stroke;

      // Handle VectorText
      if (obj is VectorText) {
        final pos = applyTrafoToPoint(Offset.zero, obj.trafo);
        recorder.drawText(
          obj.textContent,
          pos,
          fontSize: obj.style.textStyle.fontSize,
          color: fill.isSolid ? fill.color.value : 0xFF000000,
        );
        return;
      }

      // Handle Path Primitives
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
      recorder.drawPath(
        path,
        fillColor: !fill.isNone ? fill.color.value : null,
        strokeColor: !stroke.isNone ? stroke.color.value : null,
        strokeWidth: stroke.width,
      );
    }
  }
}
