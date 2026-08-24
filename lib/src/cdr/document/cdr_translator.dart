/// Translator between CorelDRAW binary structures and the high-level [VectorDocument] model.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../graphics/color.dart';
import '../../graphics/vector/constants.dart';
import '../../graphics/vector/document.dart';
import '../../graphics/vector/primitives.dart';
import '../../graphics/vector/selectable_objects.dart';
import '../../graphics/vector/structural_objects.dart';
import '../../graphics/vector/style.dart';
import '../container/riff_writer.dart';
import '../geometry/cdr_path.dart';
import '../styles/cdr_color_parser.dart';
import 'cdr_document.dart';

/// Translates between CorelDRAW documents and [VectorDocument]s.
class CdrTranslator {
  /// Converts a [CdrDocument] into a [VectorDocument].
  static VectorDocument toVectorDocument(CdrDocument cdrDoc) {
    final doc = VectorDocument(
      docUnits: DocUnit.pt,
      docOrigin: DocOrigin.lowerLeft,
      metaInfo: DocumentMetaInfo(
        notes: 'Imported from ${cdrDoc.versionName}',
      ),
    );

    final page = doc.getPage(0);
    page.name = 'CorelDRAW Page';
    if (cdrDoc.bounds.width > 0 && cdrDoc.bounds.height > 0) {
      page.pageFormat = PageFormat(
        size: PageSize('Custom', cdrDoc.bounds.width, cdrDoc.bounds.height),
      );
    }

    final layer = page.children.whereType<VectorLayer>().first;

    // Convert each parsed CDR path into a VectorCurve
    for (final cdrPath in cdrDoc.paths) {
      final vPaths = <VectorPath>[];
      VectorPath? currentPath;

      for (final node in cdrPath.nodes) {
        final pt = Offset(node.x, node.y);

        switch (node.type) {
          case CdrNodeType.moveTo:
            if (currentPath != null) vPaths.add(currentPath);
            currentPath = VectorPath(
              start: pt,
              points: [],
              closure: node.isClosed ? PathClosure.closed : PathClosure.opened,
            );
          case CdrNodeType.lineTo:
            currentPath?.points.add(pt);
            if (node.isClosed) currentPath?.closure = PathClosure.closed;
          case CdrNodeType.cubicTo:
            final cp1 = Offset(node.cx1 ?? node.x, node.cy1 ?? node.y);
            final cp2 = Offset(node.cx2 ?? node.x, node.cy2 ?? node.y);
            currentPath?.points.add(CurvePoint(cp1, cp2, pt, NodeType.smooth));
            if (node.isClosed) currentPath?.closure = PathClosure.closed;
        }
      }

      if (currentPath != null) {
        vPaths.add(currentPath);
      }

      if (vPaths.isNotEmpty) {
        final curve = VectorCurve(
          paths: vPaths,
          style: const VectorStyle(
            fill: FillDescriptor.solid(Color(0xFF2196F3)),
            stroke: StrokeDescriptor(
              color: Color(0xFF000000),
              width: 1.0,
            ),
          ),
        );
        curve.parent = layer;
        layer.children.add(curve);
        curve.update();
      }
    }

    doc.update();
    return doc;
  }

  /// Encodes a [VectorDocument] into a native binary CorelDRAW (.cdr) file.
  static Uint8List toCdrBytes(VectorDocument doc,
      {CdrVersion version = CdrVersion.v6}) {
    final subchunks = <Uint8List>[];

    // 1. 'vrsn' chunk (Version number: 600 for CDR6)
    final vrsnData = ByteData(2)..setUint16(0, 600, Endian.little);
    subchunks.add(RiffWriter.writeChunk('vrsn', vrsnData.buffer.asUint8List()));

    // 2. 'DISP' chunk (Thumbnail preview header)
    final dispData = ByteData(16)
      ..setUint32(0, 0, Endian.little)
      ..setUint32(4, 128, Endian.little) // Width
      ..setUint32(8, 128, Endian.little) // Height
      ..setUint32(12, 24, Endian.little); // BPP
    subchunks.add(RiffWriter.writeChunk('DISP', dispData.buffer.asUint8List()));

    // 3. 'LIST INFO' chunk
    final infoSubchunks = <Uint8List>[];
    if (doc.metaInfo.author.isNotEmpty) {
      infoSubchunks.add(RiffWriter.writeChunk(
          'INAM', Uint8List.fromList(utf8.encode(doc.metaInfo.author))));
    }
    if (doc.metaInfo.notes.isNotEmpty) {
      infoSubchunks.add(RiffWriter.writeChunk(
          'ICMT', Uint8List.fromList(utf8.encode(doc.metaInfo.notes))));
    }
    if (infoSubchunks.isNotEmpty) {
      subchunks.add(RiffWriter.writeList('INFO', infoSubchunks));
    }

    // 4. Object chunks for each page and layer
    for (final page in doc.pageList) {
      final pageSubchunks = <Uint8List>[];

      for (final layer in doc.getPageLayers(page)) {
        for (final obj in layer.children) {
          if (obj is PrimitiveObject) {
            final paths = obj.cachePaths ?? obj.getInitialPaths();
            if (paths.isNotEmpty) {
              // Encode 'crve' chunk
              final crveBytes = _encodeCrveChunk(paths, obj.trafo);
              pageSubchunks.add(RiffWriter.writeChunk('crve', crveBytes));

              // Encode 'fild' chunk
              if (!obj.style.fill.isNone) {
                final fildBytes = _encodeFildChunk(obj.style.fill);
                pageSubchunks.add(RiffWriter.writeChunk('fild', fildBytes));
              }

              // Encode 'outl' chunk
              if (!obj.style.stroke.isNone) {
                final outlBytes = _encodeOutlChunk(obj.style.stroke);
                pageSubchunks.add(RiffWriter.writeChunk('outl', outlBytes));
              }
            }
          }
        }
      }

      if (pageSubchunks.isNotEmpty) {
        subchunks.add(RiffWriter.writeList('page', pageSubchunks));
      }
    }

    return RiffWriter.writeRiff('CDR6', subchunks);
  }

  static Uint8List _encodeCrveChunk(
      List<VectorPath> paths, List<double> trafo) {
    final bb = BytesBuilder();

    // Total knot count
    var knotCount = 0;
    for (final p in paths) {
      knotCount += 1 + p.points.length;
    }

    final header = ByteData(4)..setUint16(0, knotCount, Endian.little);
    bb.add(header.buffer.asUint8List());

    for (final p in paths) {
      // Start node (moveTo)
      final startPt = applyTrafoToPoint(p.start, trafo);
      bb.add(_encodeNode(0, startPt.dx, startPt.dy, 0, 0, 0, 0));

      var prevPt = startPt;
      for (final pt in p.points) {
        if (pt is CurvePoint) {
          final cp1 = applyTrafoToPoint(pt.control1, trafo);
          final cp2 = applyTrafoToPoint(pt.control2, trafo);
          final end = applyTrafoToPoint(pt.endpoint, trafo);
          bb.add(
              _encodeNode(2, end.dx, end.dy, cp1.dx, cp1.dy, cp2.dx, cp2.dy));
          prevPt = end;
        } else if (pt is Offset) {
          final end = applyTrafoToPoint(pt, trafo);
          bb.add(_encodeNode(
              1, end.dx, end.dy, prevPt.dx, prevPt.dy, end.dx, end.dy));
          prevPt = end;
        }
      }
    }

    return bb.toBytes();
  }

  static Uint8List _encodeNode(int type, double x, double y, double cx1,
      double cy1, double cx2, double cy2) {
    final data = ByteData(28);
    data.setUint8(0, type); // 0=move, 1=line, 2=curve
    data.setUint8(1, 0); // flags
    data.setUint16(2, 0, Endian.little); // pad
    data.setFloat32(4, x, Endian.little);
    data.setFloat32(8, y, Endian.little);
    data.setFloat32(12, cx1, Endian.little);
    data.setFloat32(16, cy1, Endian.little);
    data.setFloat32(20, cx2, Endian.little);
    data.setFloat32(24, cy2, Endian.little);
    return data.buffer.asUint8List();
  }

  static Uint8List _encodeFildChunk(FillDescriptor fill) {
    final bb = BytesBuilder();
    bb.addByte(fill.isSolid ? 1 : (fill.isGradient ? 2 : 0)); // fill type
    final colorBytes = CdrColorParser.encodeRgb(fill.color);
    bb.add(colorBytes);
    return bb.toBytes();
  }

  static Uint8List _encodeOutlChunk(StrokeDescriptor stroke) {
    final bb = BytesBuilder();
    final widthData = ByteData(4)..setFloat32(0, stroke.width, Endian.little);
    bb.add(widthData.buffer.asUint8List());
    final colorBytes = CdrColorParser.encodeRgb(stroke.color);
    bb.add(colorBytes);
    return bb.toBytes();
  }
}
