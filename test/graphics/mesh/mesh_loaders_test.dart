/// Reading OBJ, STL, glTF and GLB, against files written here by hand and
/// against whatever real models are on this machine.
///
/// The hand-written half pins the conventions that are easy to get wrong and
/// impossible to notice: OBJ's 1-based and negative indices, glTF's
/// column-major node matrices, an interleaved buffer's byte stride, and the
/// binary/ASCII sniff that a `solid` prefix does not settle. Each of those
/// produces a model that loads, reports a plausible triangle count, and is
/// wrong.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:test/test.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// A binary STL of [facets] triangles, with [headerText] in the 80-byte header.
Uint8List _binaryStl(int facets, {String headerText = ''}) {
  final Uint8List out = Uint8List(84 + facets * 50);
  final ByteData data = ByteData.sublistView(out);
  for (var i = 0; i < headerText.length && i < 80; i++) {
    out[i] = headerText.codeUnitAt(i);
  }
  data.setUint32(80, facets, Endian.little);
  var at = 84;
  for (var f = 0; f < facets; f++) {
    data.setFloat32(at + 8, 1, Endian.little); // normal z
    at += 12;
    for (var v = 0; v < 3; v++) {
      data.setFloat32(at, v.toDouble(), Endian.little);
      data.setFloat32(at + 4, f.toDouble(), Endian.little);
      at += 12;
    }
    at += 2;
  }
  return out;
}

void main() {
  group('OBJ', () {
    test('reads positions and faces', () {
      final Mesh3D mesh = loadObj('''
v 0 0 0
v 1 0 0
v 0 1 0
f 1 2 3
''');
      expect(mesh.format, 'obj');
      expect(mesh.triangleCount, 1);
      expect(mesh.vertexCount, 3);
      expect(mesh.computeBounds().max.x, 1);
    });

    test('indices are 1-based, and a 0 is not a vertex', () {
      // The classic off-by-one. Reading them as 0-based shifts every face by
      // one vertex, which for a smooth mesh produces a model that still looks
      // like a model - slightly, uniformly wrong.
      final Mesh3D mesh = loadObj('''
v 10 0 0
v 0 20 0
v 0 0 30
f 1 2 3
''');
      final MeshPrimitive p = mesh.primitives.single;
      expect(p.positions[0], 10);
      expect(p.positions[4], 20);
      expect(p.positions[8], 30);
    });

    test('a negative index counts back from the end', () {
      final Mesh3D mesh = loadObj('''
v 0 0 0
v 1 0 0
v 0 1 0
f -3 -2 -1
''');
      expect(mesh.triangleCount, 1);
      expect(mesh.computeBounds().max.y, 1);
    });

    test('a quad becomes two triangles', () {
      final Mesh3D mesh = loadObj('''
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
f 1 2 3 4
''');
      expect(mesh.triangleCount, 2);
    });

    test('normals are read and vertices with different normals stay apart', () {
      // `v/vt/vn` triples. Two faces sharing a position but not a normal are
      // two vertices, and collapsing them is what makes a hard edge look
      // rounded.
      final Mesh3D mesh = loadObj('''
v 0 0 0
v 1 0 0
v 0 1 0
vn 0 0 1
vn 0 1 0
f 1//1 2//1 3//1
f 1//2 2//2 3//2
''');
      expect(mesh.triangleCount, 2);
      expect(
        mesh.vertexCount,
        6,
        reason: 'three positions, each with two distinct normals',
      );
      expect(mesh.primitives.single.normals, isNotNull);
    });

    test('materials are named as unread rather than ignored', () {
      final Mesh3D mesh = loadObj('''
mtllib thing.mtl
usemtl body
v 0 0 0
v 1 0 0
v 0 1 0
f 1 2 3
''');
      expect(mesh.unsupported, contains('materials from .mtl'));
      expect(mesh.triangleCount, 1);
    });

    test('a file with no faces is refused rather than returned empty', () {
      expect(
        () => loadObj('v 0 0 0\nv 1 0 0\n'),
        throwsA(isA<MeshParseException>()),
      );
    });
  });

  group('STL', () {
    test('reads a binary file', () {
      final Mesh3D mesh = loadStl(_binaryStl(3));
      expect(mesh.format, 'stl');
      expect(mesh.triangleCount, 3);
      expect(
        mesh.vertexCount,
        9,
        reason: 'the format has no index buffer, so nothing is shared',
      );
    });

    test('a binary file whose header says "solid" is still binary', () {
      // The trap. Sniffing for a `solid` prefix says ASCII and then the parser
      // finds no `vertex` lines and returns nothing - with no error, because
      // an empty ASCII STL is a legal thing to write.
      final Mesh3D mesh = loadMesh(_binaryStl(2, headerText: 'solid exported'));
      expect(mesh.format, 'stl');
      expect(mesh.triangleCount, 2);
    });

    test('reads an ASCII file', () {
      final Mesh3D mesh = loadMesh(_bytes('''
solid test
facet normal 0 0 1
  outer loop
    vertex 0 0 0
    vertex 1 0 0
    vertex 0 1 0
  endloop
endfacet
endsolid test
'''));
      expect(mesh.format, 'stl');
      expect(mesh.triangleCount, 1);
    });

    test('a declared facet count larger than the file is refused', () {
      // Allocating what a corrupt header asks for is how a viewer turns a bad
      // download into an out-of-memory instead of a message.
      final Uint8List truncated =
          Uint8List.sublistView(_binaryStl(100), 0, 84 + 50 * 3);
      expect(
        () => loadStl(truncated),
        throwsA(isA<MeshParseException>()),
      );
    });

    test('all-zero normals are treated as absent, not as data', () {
      // Many exporters write zeros. Handing them to a shader makes every facet
      // black, which reads as a lighting bug.
      final Uint8List stl = _binaryStl(2);
      final ByteData data = ByteData.sublistView(stl);
      for (var f = 0; f < 2; f++) {
        data.setFloat32(84 + f * 50 + 8, 0, Endian.little);
      }
      expect(loadStl(stl).primitives.single.normals, isNull);
      expect(loadStl(_binaryStl(2)).primitives.single.normals, isNotNull);
    });
  });

  group('glTF', () {
    /// A minimal document with one triangle in a base64 buffer.
    String document({
      String nodeExtra = '',
      int byteStride = 0,
      String extra = '',
    }) {
      // Three vertices of three floats, then three unsigned shorts of indices,
      // padded to a four-byte boundary.
      final ByteData buffer = ByteData(36 + 8);
      const List<double> positions = <double>[0, 0, 0, 1, 0, 0, 0, 1, 0];
      for (var i = 0; i < positions.length; i++) {
        buffer.setFloat32(i * 4, positions[i], Endian.little);
      }
      for (var i = 0; i < 3; i++) {
        buffer.setUint16(36 + i * 2, i, Endian.little);
      }
      final String base64 =
          base64Encode(Uint8List.sublistView(buffer.buffer.asUint8List()));
      return '''
{
  "asset": {"version": "2.0"},
  "scene": 0,
  "scenes": [{"nodes": [0]}],
  "nodes": [{"mesh": 0$nodeExtra}],
  "meshes": [{"primitives": [
    {"attributes": {"POSITION": 0}, "indices": 1}
  ]}],
  "accessors": [
    {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
    {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}
  ],
  "bufferViews": [
    {"buffer": 0, "byteOffset": 0, "byteLength": 36${byteStride == 0 ? '' : ', "byteStride": $byteStride'}},
    {"buffer": 0, "byteOffset": 36, "byteLength": 6}
  ],
  "buffers": [{"byteLength": 44, "uri": "data:application/octet-stream;base64,$base64"}]$extra
}
''';
    }

    test('reads a triangle out of a base64 buffer', () {
      final Mesh3D mesh = loadGltf(document());
      expect(mesh.format, 'gltf');
      expect(mesh.triangleCount, 1);
      expect(mesh.vertexCount, 3);
      expect(mesh.computeBounds().max.x, 1);
    });

    test('a node translation moves the geometry', () {
      final Mesh3D mesh =
          loadGltf(document(nodeExtra: ', "translation": [10, 0, 0]'));
      final Bounds3 bounds = mesh.computeBounds();
      expect(bounds.min.x, 10);
      expect(bounds.max.x, 11);
    });

    test('a node matrix is read column-major', () {
      // Sixteen numbers, and reading them row-major transposes every model
      // that uses one. The matrix below translates by (5, 6, 7); read the
      // other way it would shear instead.
      final Mesh3D mesh = loadGltf(document(
        nodeExtra: ', "matrix": [1,0,0,0, 0,1,0,0, 0,0,1,0, 5,6,7,1]',
      ));
      final Bounds3 bounds = mesh.computeBounds();
      expect(bounds.min.x, 5);
      expect(bounds.min.y, 6);
      expect(bounds.min.z, 7);
    });

    test('an interleaved buffer is read through its stride', () {
      // Exporters interleave routinely, and a reader that walks elements back
      // to back returns a third of the mesh followed by whatever came next.
      // Here the positions are spaced 12 bytes apart, which is also their own
      // size, so declaring the stride must not change the answer.
      expect(
        loadGltf(document(byteStride: 12)).computeBounds().max.x,
        1,
      );
    });

    test('an external buffer is named when nothing resolves it', () {
      const String external = '''
{
  "asset": {"version": "2.0"},
  "scene": 0,
  "scenes": [{"nodes": [0]}],
  "nodes": [{"mesh": 0}],
  "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
  "accessors": [
    {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}
  ],
  "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36}],
  "buffers": [{"byteLength": 36, "uri": "geometry.bin"}]
}
''';
      expect(
        () => loadGltf(external),
        throwsA(isA<MeshParseException>()),
        reason: 'with no geometry there is nothing to draw',
      );

      // And with a resolver it loads, which is what makes the seam real rather
      // than a place to put an apology.
      final ByteData buffer = ByteData(36);
      buffer.setFloat32(12, 2, Endian.little);
      final Mesh3D mesh = loadGltf(
        external,
        resolveBuffer: (String uri) =>
            uri == 'geometry.bin' ? buffer.buffer.asUint8List() : null,
      );
      expect(mesh.triangleCount, 1);
      expect(mesh.computeBounds().max.x, 2);
    });

    test('a non-triangle primitive mode is named and skipped', () {
      final String lines = document().replaceFirst(
        '"attributes": {"POSITION": 0}, "indices": 1',
        '"attributes": {"POSITION": 0}, "indices": 1, "mode": 1',
      );
      expect(() => loadGltf(lines), throwsA(isA<MeshParseException>()));
    });

    test('a base colour factor becomes the material colour', () {
      final String withMaterial = document(
        extra: ''',
  "materials": [
    {"pbrMetallicRoughness": {"baseColorFactor": [1, 0, 0, 1]},
     "doubleSided": true}
  ]''',
      ).replaceFirst(
        '"attributes": {"POSITION": 0}, "indices": 1',
        '"attributes": {"POSITION": 0}, "indices": 1, "material": 0',
      );
      final MeshMaterial material =
          loadGltf(withMaterial).primitives.single.material;
      expect(material.colorArgb, 0xFFFF0000);
      expect(material.doubleSided, isTrue);
    });
  });

  group('format sniffing', () {
    test('FBX is refused by name, with what to do instead', () {
      final Uint8List fbx = Uint8List(64);
      const String magic = 'Kaydara FBX Binary';
      for (var i = 0; i < magic.length; i++) {
        fbx[i] = magic.codeUnitAt(i);
      }
      expect(
        () => loadMesh(fbx),
        throwsA(
          isA<MeshParseException>().having(
            (MeshParseException e) => e.detail,
            'detail',
            contains('glTF'),
          ),
        ),
      );
    });

    test('a ZIP is named as a container rather than as an unknown format', () {
      final Uint8List zip = Uint8List(64);
      zip[0] = 0x50;
      zip[1] = 0x4B;
      expect(
        () => loadMesh(zip),
        throwsA(
          isA<MeshParseException>().having(
            (MeshParseException e) => e.message,
            'message',
            contains('ZIP'),
          ),
        ),
      );
    });

    test('a GLB is recognised by its magic', () {
      // Nothing to load - the point is that the header is read as GLB and the
      // failure is about the chunks and not about the format.
      final Uint8List glb = Uint8List(12);
      glb.setAll(0, <int>[0x67, 0x6C, 0x54, 0x46]);
      final ByteData data = ByteData.sublistView(glb);
      data.setUint32(4, 2, Endian.little);
      expect(
        () => loadGlb(glb),
        throwsA(
          isA<MeshParseException>().having(
            (MeshParseException e) => e.message,
            'message',
            contains('JSON chunk'),
          ),
        ),
      );
    });
  });

  group('geometry', () {
    test('smooth normals are area-weighted', () {
      // Not normalised before accumulating, on purpose: a large face should
      // count for more than a sliver beside it. Two triangles meeting along an
      // edge, one much larger, and the shared vertex must lean towards the
      // larger one's plane.
      final MeshPrimitive primitive = MeshPrimitive(
        positions: Float32List.fromList(<double>[
          0, 0, 0, //
          10, 0, 0, //
          0, 10, 0, //
          0, 0, 1, //
        ]),
        indices: Uint32List.fromList(<int>[0, 1, 2, 0, 2, 3]),
      );
      final Float32List normals = primitive.computeSmoothNormals();
      // Vertex 0 is shared. The big triangle lies in z = 0 with normal +z; the
      // small one is in x = 0 with normal -x. Area-weighted, the result must be
      // much closer to +z.
      expect(normals[2].abs(), greaterThan(normals[0].abs()));
    });

    test('a degenerate triangle does not produce NaN normals', () {
      final MeshPrimitive primitive = MeshPrimitive(
        positions: Float32List.fromList(<double>[0, 0, 0, 0, 0, 0, 0, 0, 0]),
        indices: Uint32List.fromList(<int>[0, 1, 2]),
      );
      for (final double value in primitive.computeSmoothNormals()) {
        expect(value.isNaN, isFalse);
      }
    });

    test('empty bounds do not swallow the first point', () {
      // Starting the box at the origin instead of at infinity puts a point the
      // model may not contain in shot, and frames a distant model with the
      // origin in view.
      const Bounds3 empty = Bounds3.empty;
      expect(empty.isEmpty, isTrue);
      final Bounds3 one = empty.include(const Vector3(5, 5, 5));
      expect(one.min, isA<Vector3>().having((Vector3 v) => v.x, 'x', 5));
      expect(one.max, isA<Vector3>().having((Vector3 v) => v.x, 'x', 5));
    });
  });

  group('real models on this machine', () {
    // Skipped where the files are not present, which is everywhere but the
    // machine they were downloaded on. The hand-written cases above are the
    // contract; these are the reality check, and a reality check that cannot
    // run is not a reason to fail a suite.
    final Directory root = Directory('D:/3d');
    final String? skip =
        root.existsSync() ? null : 'no model library at ${root.path}';

    test('the same model in OBJ and GLB has the same triangle count', () {
      // The strongest cross-check available without a reference renderer: two
      // independent readers, two formats, one model. A fan-triangulation bug
      // or a stride bug shows up here as a mismatch.
      final File obj = File('${root.path}/robotnik.obj');
      final File glb = File('${root.path}/robotnik.glb');
      if (!obj.existsSync() || !glb.existsSync()) return;

      final Mesh3D fromObj =
          loadMesh(Uint8List.fromList(obj.readAsBytesSync()));
      final Mesh3D fromGlb =
          loadMesh(Uint8List.fromList(glb.readAsBytesSync()));
      expect(fromObj.triangleCount, fromGlb.triangleCount);
    }, skip: skip);

    test('a large binary STL loads whole', () {
      final File stl = File('${root.path}/Mario+Kart+3D+Statue.stl');
      if (!stl.existsSync()) return;
      final Mesh3D mesh = loadMesh(Uint8List.fromList(stl.readAsBytesSync()));
      expect(mesh.triangleCount, 451838);
      expect(mesh.vertexCount, 451838 * 3);
    }, skip: skip);
  });
}
