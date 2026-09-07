/// Reading FBX, against files written here byte by byte and against the real
/// models on this machine.
///
/// The hand-written half exists because every FBX bug worth catching produces
/// a model that loads: a `Vertices` array read as float instead of double, a
/// polygon index used before its end-of-face mask is cleared, a rotation
/// composed without its pivot. None of those throws and none of them changes
/// the triangle count, so a test that only counts triangles passes on all of
/// them. Each case below pins one value that is different when the rule is
/// broken.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/fbx_loader.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A minimal FBX writer, so that the cases below are bytes and not fixtures
// ---------------------------------------------------------------------------

/// One record being assembled.
final class _Node {
  _Node(this.name, [List<Object?>? properties])
      : properties = properties ?? <Object?>[];

  final String name;
  final List<Object?> properties;
  final List<_Node> children = <_Node>[];

  _Node add(_Node child) {
    children.add(child);
    return child;
  }
}

/// A property that must be written as a typed array rather than as a scalar.
final class _Array {
  const _Array(this.type, this.values, {this.deflate = false});

  /// One of `d`, `f`, `i`, `l`.
  final String type;
  final List<num> values;

  /// Whether to write it as encoding 1, a zlib stream.
  final bool deflate;
}

/// Adler-32, which zlib puts at the end of every stream and this reader checks.
int _adler32(Uint8List bytes) {
  var a = 1;
  var b = 0;
  for (final int byte in bytes) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

/// A zlib stream whose DEFLATE blocks are all *stored*.
///
/// Uncompressed on purpose: this repository has an inflater and no deflater, so
/// the alternative would be a compressed blob checked in as a magic constant.
/// A stored block still exercises everything the loader has to get right - the
/// two-byte header, the block framing, the Adler trailer - and it can be read
/// by anyone maintaining this test.
Uint8List _zlibStored(Uint8List raw) {
  final BytesBuilder out = BytesBuilder()..add(<int>[0x78, 0x01]);
  var at = 0;
  do {
    final int length = (raw.length - at) > 65535 ? 65535 : raw.length - at;
    final bool last = at + length >= raw.length;
    out.add(<int>[
      last ? 1 : 0,
      length & 0xFF,
      (length >> 8) & 0xFF,
      ~length & 0xFF,
      (~length >> 8) & 0xFF,
    ]);
    out.add(Uint8List.sublistView(raw, at, at + length));
    at += length;
  } while (at < raw.length);
  final int adler = _adler32(raw);
  out.add(<int>[
    (adler >> 24) & 0xFF,
    (adler >> 16) & 0xFF,
    (adler >> 8) & 0xFF,
    adler & 0xFF,
  ]);
  return out.toBytes();
}

/// Serialises [roots] as a binary FBX of the given [version].
Uint8List _fbx(List<_Node> roots, {int version = 7400}) {
  final BytesBuilder out = BytesBuilder();
  out.add(latin1.encode('Kaydara FBX Binary  '));
  out.add(<int>[0x00, 0x1A, 0x00]);
  out.add(_u32(version));

  // Offsets are absolute from the start of the file, so a node cannot be
  // written until its own length is known. Serialising bottom-up and then
  // fixing the offsets afterwards is the usual answer; writing each subtree to
  // its own buffer and measuring it is the simpler one and this is a test.
  for (final _Node node in roots) {
    out.add(_node(node, out.length, version));
  }
  // The 160-byte footer, which the reader uses to know it has finished.
  out.add(Uint8List(176));
  return out.toBytes();
}

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

Uint8List _u64(int value) =>
    Uint8List(8)..buffer.asByteData().setInt64(0, value, Endian.little);

Uint8List _size(int value, int version) =>
    version >= 7500 ? _u64(value) : _u32(value);

Uint8List _node(_Node node, int start, int version) {
  final BytesBuilder properties = BytesBuilder();
  for (final Object? property in node.properties) {
    properties.add(_property(property));
  }
  final Uint8List propertyBytes = properties.toBytes();

  final int headerLength = (version >= 7500 ? 24 : 12) + 1 + node.name.length;
  var at = start + headerLength + propertyBytes.length;

  final BytesBuilder childBytes = BytesBuilder();
  for (final _Node child in node.children) {
    final Uint8List encoded = _node(child, at, version);
    childBytes.add(encoded);
    at += encoded.length;
  }
  if (node.children.isNotEmpty) {
    // The null record that closes a nested list. Without it the reader has no
    // way to know a child list ended before the parent's end offset.
    final int nullLength = version >= 7500 ? 25 : 13;
    childBytes.add(Uint8List(nullLength));
    at += nullLength;
  }

  final BytesBuilder out = BytesBuilder()
    ..add(_size(at, version))
    ..add(_size(node.properties.length, version))
    ..add(_size(propertyBytes.length, version))
    ..add(<int>[node.name.length])
    ..add(latin1.encode(node.name))
    ..add(propertyBytes)
    ..add(childBytes.toBytes());
  return out.toBytes();
}

Uint8List _property(Object? value) {
  final BytesBuilder out = BytesBuilder();
  if (value is _Array) {
    out.add(latin1.encode(value.type));
    final int stride = value.type == 'd' || value.type == 'l' ? 8 : 4;
    final Uint8List raw = Uint8List(value.values.length * stride);
    final ByteData data = ByteData.sublistView(raw);
    for (var i = 0; i < value.values.length; i++) {
      switch (value.type) {
        case 'd':
          data.setFloat64(i * 8, value.values[i].toDouble(), Endian.little);
        case 'f':
          data.setFloat32(i * 4, value.values[i].toDouble(), Endian.little);
        case 'l':
          data.setInt64(i * 8, value.values[i].toInt(), Endian.little);
        default:
          data.setInt32(i * 4, value.values[i].toInt(), Endian.little);
      }
    }
    final Uint8List payload = value.deflate ? _zlibStored(raw) : raw;
    out
      ..add(_u32(value.values.length))
      ..add(_u32(value.deflate ? 1 : 0))
      ..add(_u32(value.deflate ? payload.length : 0))
      ..add(payload);
    return out.toBytes();
  }
  if (value is String) {
    out
      ..add(latin1.encode('S'))
      ..add(_u32(value.length))
      ..add(latin1.encode(value));
    return out.toBytes();
  }
  if (value is int) {
    out
      ..add(latin1.encode('L'))
      ..add(_u64(value));
    return out.toBytes();
  }
  if (value is double) {
    final Uint8List bytes = Uint8List(8)
      ..buffer.asByteData().setFloat64(0, value, Endian.little);
    out
      ..add(latin1.encode('D'))
      ..add(bytes);
    return out.toBytes();
  }
  if (value is Uint8List) {
    out
      ..add(latin1.encode('R'))
      ..add(_u32(value.length))
      ..add(value);
    return out.toBytes();
  }
  throw ArgumentError('no FBX property type for $value');
}

/// A `Properties70` `P` record.
_Node _p(String name, String type, List<Object?> values) =>
    _Node('P', <Object?>[name, type, '', '', ...values]);

// ---------------------------------------------------------------------------
// Model fragments the cases share
// ---------------------------------------------------------------------------

/// A unit quad on the XY plane as one four-sided polygon.
///
/// Written as a quad rather than as two triangles because the quad is what
/// exercises the end-of-face mask: the fourth index is `~3`.
_Node _quadGeometry(int id, {bool deflate = false}) {
  final _Node geometry = _Node('Geometry', <Object?>[id, 'quad', 'Mesh'])
    ..add(_Node('Vertices', <Object?>[
      _Array('d', <double>[0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
          deflate: deflate),
    ]))
    ..add(_Node('PolygonVertexIndex', <Object?>[
      _Array('i', <int>[0, 1, 2, ~3], deflate: deflate),
    ]));
  return geometry;
}

_Node _model(int id, String name, List<_Node> properties) {
  final _Node model = _Node('Model', <Object?>[id, name, 'Mesh']);
  final _Node block = _Node('Properties70');
  for (final _Node property in properties) {
    block.add(property);
  }
  model.add(block);
  return model;
}

_Node _connect(List<List<Object?>> links) {
  final _Node connections = _Node('Connections');
  for (final List<Object?> link in links) {
    connections.add(_Node('C', link));
  }
  return connections;
}

Mesh3D _load(List<_Node> roots, {int version = 7400}) =>
    loadFbx(_fbx(roots, version: version), name: 'test');

void main() {
  group('the binary node tree', () {
    test('reads a quad through the 32-bit layout', () {
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'quad', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      expect(mesh.format, 'fbx');
      expect(mesh.triangleCount, 2);
      expect(mesh.vertexCount, 6);
    });

    test('reads the same file through the 64-bit layout of 7500', () {
      // The three sizes in a record header widened at version 7500. Reading a
      // 7500 file with the narrow header lands in the middle of an offset and
      // produces a node whose name is four bytes of a number - which does not
      // throw, it just finds nothing.
      final Mesh3D mesh = _load(
        <_Node>[
          _Node('Objects')
            ..add(_quadGeometry(100))
            ..add(_model(200, 'quad', <_Node>[])),
          _connect(<List<Object?>>[
            <Object?>['OO', 100, 200],
          ]),
        ],
        version: 7700,
      );
      expect(mesh.triangleCount, 2);
    });

    test('inflates a zlib-encoded property array', () {
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100, deflate: true))
          ..add(_model(200, 'quad', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      expect(mesh.triangleCount, 2);
      expect(mesh.computeBounds().max.x, 1);
    });

    test('positions are read as doubles, not floats', () {
      // The value below is exactly representable in a double and not in a
      // float. A loader that reads `Vertices` as `Float32List` - which is the
      // bug this exists to catch - either throws on the cast or reads eight
      // bytes as two floats and produces a number nothing like this one.
      const double x = 1.0000000000000002;
      final _Node geometry = _Node('Geometry', <Object?>[100, 'tri', 'Mesh'])
        ..add(_Node('Vertices', <Object?>[
          const _Array('d', <double>[0, 0, 0, x, 0, 0, 0, 1, 0]),
        ]))
        ..add(_Node('PolygonVertexIndex', <Object?>[
          const _Array('i', <int>[0, 1, ~2]),
        ]));
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(geometry)
          ..add(_model(200, 'tri', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      // Float32 rounds the extra bit away; the point is that the *double* was
      // read, so the largest x is 1 and not 0 or a denormal.
      expect(mesh.computeBounds().max.x, closeTo(1, 1e-6));
      expect(mesh.triangleCount, 1);
    });
  });

  group('polygons', () {
    test('the end-of-face mask picks the right vertex', () {
      // `~3` is -4, and the polygon's last corner is vertex 3. A reader that
      // uses the raw value indexes backwards; one that negates it lands on
      // vertex 4, which does not exist. Both produce a mesh - this pins which
      // vertex the last corner actually is.
      final _Node geometry = _Node('Geometry', <Object?>[100, 'quad', 'Mesh'])
        ..add(_Node('Vertices', <Object?>[
          const _Array('d', <double>[
            0, 0, 0, //
            1, 0, 0, //
            1, 1, 0, //
            0, 7, 0, // the fourth vertex, and the only one with y == 7
          ]),
        ]))
        ..add(_Node('PolygonVertexIndex', <Object?>[
          const _Array('i', <int>[0, 1, 2, ~3]),
        ]));
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(geometry)
          ..add(_model(200, 'quad', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      expect(mesh.triangleCount, 2);
      expect(mesh.computeBounds().max.y, 7);
    });

    test('a five-sided polygon is fanned and said to be', () {
      final _Node geometry = _Node('Geometry', <Object?>[100, 'ngon', 'Mesh'])
        ..add(_Node('Vertices', <Object?>[
          const _Array('d', <double>[
            0, 0, 0, 2, 0, 0, 3, 1, 0, 1, 2, 0, -1, 1, 0, //
          ]),
        ]))
        ..add(_Node('PolygonVertexIndex', <Object?>[
          const _Array('i', <int>[0, 1, 2, 3, ~4]),
        ]));
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(geometry)
          ..add(_model(200, 'ngon', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      expect(mesh.triangleCount, 3);
      expect(
        mesh.unsupported.any((String s) => s.contains('more than four sides')),
        isTrue,
      );
    });
  });

  group('layer elements', () {
    test('ByPolygonVertex/Direct normals land on the right corner', () {
      final _Node geometry = _quadGeometry(100)
        ..add(_Node('LayerElementNormal')
          ..add(_Node('MappingInformationType', <Object?>['ByPolygonVertex']))
          ..add(_Node('ReferenceInformationType', <Object?>['Direct']))
          ..add(_Node('Normals', <Object?>[
            const _Array('d', <double>[
              0, 0, 1, //
              0, 0, 1, //
              0, 0, 1, //
              0, 1, 0, // the fourth corner alone points along +Y
            ]),
          ])));
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(geometry)
          ..add(_model(200, 'quad', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      final Float32List normals = mesh.primitives.single.normals!;
      // Six corners after the fan: 0,1,2 then 0,2,3. Only the last one is the
      // fourth corner, so only the last normal is +Y.
      expect(normals.length, 18);
      expect(normals[17], closeTo(0, 1e-6));
      expect(normals[16], closeTo(1, 1e-6));
      expect(normals[2], closeTo(1, 1e-6));
    });

    test('ByVertice/IndexToDirect UVs are indexed twice', () {
      // The combination that reads as a plausible number under every wrong
      // rule: the mapping picks the vertex, and the reference then puts that
      // through a second table before it reaches the data.
      final _Node geometry = _quadGeometry(100)
        ..add(_Node('LayerElementUV')
          ..add(_Node('MappingInformationType', <Object?>['ByVertice']))
          ..add(_Node('ReferenceInformationType', <Object?>['IndexToDirect']))
          ..add(_Node('UV', <Object?>[
            const _Array('d', <double>[0, 0, 0.25, 0, 0.5, 0, 0.75, 0]),
          ]))
          ..add(_Node('UVIndex', <Object?>[
            // Vertex 0 uses UV 3, vertex 1 uses UV 2, and so on: reversed, so
            // that skipping the second lookup gives a different answer.
            const _Array('i', <int>[3, 2, 1, 0]),
          ])));
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(geometry)
          ..add(_model(200, 'quad', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      final Float32List uvs = mesh.primitives.single.uvs!;
      expect(uvs[0], closeTo(0.75, 1e-6));
      expect(uvs[2], closeTo(0.5, 1e-6));
      // v is flipped into glTF's top-left origin, so a file v of 0 is 1 here.
      expect(uvs[1], closeTo(1, 1e-6));
    });

    test('a mapping this loader does not implement is named, not guessed', () {
      final _Node geometry = _quadGeometry(100)
        ..add(_Node('LayerElementNormal')
          ..add(_Node('MappingInformationType', <Object?>['ByEdge']))
          ..add(_Node('ReferenceInformationType', <Object?>['Direct']))
          ..add(_Node('Normals', <Object?>[
            const _Array('d', <double>[0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]),
          ])));
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(geometry)
          ..add(_model(200, 'quad', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      expect(mesh.primitives.single.normals, isNull);
      expect(
        mesh.unsupported.any((String s) => s.contains('ByEdge')),
        isTrue,
        reason: 'the mapping must be refused by name rather than read with the '
            'nearest rule that fits',
      );
    });

    test('two materials split the mesh into two primitives', () {
      final _Node geometry = _Node('Geometry', <Object?>[100, 'pair', 'Mesh'])
        ..add(_Node('Vertices', <Object?>[
          const _Array('d', <double>[
            0, 0, 0, 1, 0, 0, 0, 1, 0, //
            0, 0, 5, 1, 0, 5, 0, 1, 5, //
          ]),
        ]))
        ..add(_Node('PolygonVertexIndex', <Object?>[
          const _Array('i', <int>[0, 1, ~2, 3, 4, ~5]),
        ]))
        ..add(_Node('LayerElementMaterial')
          ..add(_Node('MappingInformationType', <Object?>['ByPolygon']))
          ..add(_Node('ReferenceInformationType', <Object?>['IndexToDirect']))
          ..add(_Node('Materials', <Object?>[
            const _Array('i', <int>[1, 0]),
          ])));

      final _Node red = _Node('Material', <Object?>[300, 'red', ''])
        ..add(_Node('Properties70')
          ..add(_p('DiffuseColor', 'Color', <Object?>[1.0, 0.0, 0.0])));
      final _Node blue = _Node('Material', <Object?>[301, 'blue', ''])
        ..add(_Node('Properties70')
          ..add(_p('DiffuseColor', 'Color', <Object?>[0.0, 0.0, 1.0])));

      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(geometry)
          ..add(_model(200, 'pair', <_Node>[]))
          ..add(red)
          ..add(blue),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
          <Object?>['OO', 300, 200],
          <Object?>['OO', 301, 200],
        ]),
      ]);
      expect(mesh.primitives.length, 2);
      expect(mesh.triangleCount, 2);
      final Set<int> colours = <int>{
        for (final MeshPrimitive p in mesh.primitives) p.material.colorArgb,
      };
      expect(colours, <int>{0xFFFF0000, 0xFF0000FF});
    });
  });

  group('node transforms', () {
    test('Lcl Translation moves the mesh', () {
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'quad', <_Node>[
            _p('Lcl Translation', 'Lcl Translation',
                <Object?>[10.0, 20.0, 30.0]),
          ])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      final Bounds3 bounds = mesh.computeBounds();
      expect(bounds.min.x, closeTo(10, 1e-6));
      expect(bounds.min.y, closeTo(20, 1e-6));
      expect(bounds.min.z, closeTo(30, 1e-6));
    });

    test('Lcl Rotation is applied, and about the axis the order names', () {
      // Ninety degrees about Z takes the corner at (1, 0, 0) to (0, 1, 0). A
      // loader that skips `Lcl Rotation` - which the first draft of this one
      // did - leaves the quad on the X axis and every other test still passes.
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'quad', <_Node>[
            _p('Lcl Rotation', 'Lcl Rotation', <Object?>[0.0, 0.0, 90.0]),
          ])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      final Bounds3 bounds = mesh.computeBounds();
      expect(bounds.min.x, closeTo(-1, 1e-6));
      expect(bounds.max.x, closeTo(0, 1e-6));
      expect(bounds.max.y, closeTo(1, 1e-6));
    });

    test('a rotation turns about RotationPivot, not about the origin', () {
      // The pivot is the corner at (1, 1, 0), so rotating 180 degrees about Z
      // about it maps the quad onto [1, 2] x [1, 2]. Ignoring the pivot maps it
      // onto [-1, 0] x [-1, 0] instead: same shape, same triangle count, wrong
      // place, and on a skeleton it is a limb bending about the wrong joint.
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'quad', <_Node>[
            _p('RotationPivot', 'Vector3D', <Object?>[1.0, 1.0, 0.0]),
            _p('Lcl Rotation', 'Lcl Rotation', <Object?>[0.0, 0.0, 180.0]),
          ])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      final Bounds3 bounds = mesh.computeBounds();
      expect(bounds.min.x, closeTo(1, 1e-6));
      expect(bounds.min.y, closeTo(1, 1e-6));
      expect(bounds.max.x, closeTo(2, 1e-6));
      expect(bounds.max.y, closeTo(2, 1e-6));
    });

    test('PreRotation composes before Lcl Rotation', () {
      // Pre-rotating 90 degrees about X and then rotating 90 about Z is not
      // the same as either alone, and the order matters: `Lcl Rotation` is
      // applied first and the pre-rotation after it, so the quad's +Y edge
      // lands on +Z. Composing them the other way round puts it on -X, and
      // the bounding box says which happened.
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'quad', <_Node>[
            _p('PreRotation', 'Vector3D', <Object?>[90.0, 0.0, 0.0]),
            _p('Lcl Rotation', 'Lcl Rotation', <Object?>[0.0, 0.0, 90.0]),
          ])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      final Bounds3 bounds = mesh.computeBounds();
      expect(bounds.max.z, closeTo(1, 1e-6));
      expect(bounds.min.z, closeTo(0, 1e-6));
      expect(bounds.min.x, closeTo(-1, 1e-6));
      expect(bounds.max.x, closeTo(0, 1e-6));
      expect(bounds.size.y, closeTo(0, 1e-6));
    });

    test('a parent model carries its child', () {
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'child', <_Node>[
            _p('Lcl Translation', 'Lcl Translation', <Object?>[1.0, 0.0, 0.0]),
          ]))
          ..add(_model(201, 'parent', <_Node>[
            _p('Lcl Translation', 'Lcl Translation', <Object?>[0.0, 5.0, 0.0]),
          ])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
          <Object?>['OO', 200, 201],
        ]),
      ]);
      final Bounds3 bounds = mesh.computeBounds();
      expect(bounds.min.x, closeTo(1, 1e-6));
      expect(bounds.min.y, closeTo(5, 1e-6));
      expect(
        mesh.nodes.map((MeshNode n) => n.name),
        contains('parent'),
      );
    });

    test('a Z-up file is rotated into Y-up and says so', () {
      // No file in the library this was developed against declares `UpAxis: 2`,
      // so this case is the only cover the rotation has. A Z-up model read
      // without it lies on its face, and the bounding box a viewer frames the
      // camera from has the model's height in its depth axis.
      final Mesh3D mesh = _load(<_Node>[
        _Node('GlobalSettings')
          ..add(_Node('Properties70')..add(_p('UpAxis', 'int', <Object?>[2]))),
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'quad', <_Node>[])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      // The quad lies on XY before the rotation, so afterwards it lies on XZ.
      final Bounds3 bounds = mesh.computeBounds();
      expect(bounds.size.y, closeTo(0, 1e-6));
      expect(bounds.size.z, closeTo(1, 1e-6));
      expect(
        mesh.unsupported.any((String s) => s.contains('Z-up')),
        isTrue,
      );
    });

    test('GeometricTranslation moves the mesh and not the node', () {
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'quad', <_Node>[
            _p('GeometricTranslation', 'Vector3D', <Object?>[0.0, 0.0, 9.0]),
          ])),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
        ]),
      ]);
      expect(mesh.computeBounds().min.z, closeTo(9, 1e-6));
      // The node itself stays at the origin: only its geometry moved.
      final MeshNode node =
          mesh.nodes.firstWhere((MeshNode n) => n.name == 'quad');
      expect(node.restTranslation.z, closeTo(0, 1e-6));
    });
  });

  group('textures', () {
    test('an embedded Content is decoded', () {
      // A 1x1 PNG, written here rather than checked in: an embedded texture is
      // the common case for a self-contained FBX and this is the whole path,
      // from an `R` property through the image codec to a sampled texel.
      final Uint8List bmp = _onePixelPng(0x20, 0x40, 0x60);
      final Mesh3D mesh = _load(<_Node>[
        _Node('Objects')
          ..add(_quadGeometry(100))
          ..add(_model(200, 'quad', <_Node>[]))
          ..add(_Node('Material', <Object?>[300, 'skin', ''])
            ..add(_Node('Properties70')))
          ..add(_Node('Texture', <Object?>[400, 'diffuse', ''])
            ..add(_Node('RelativeFilename', <Object?>['skin.png'])))
          ..add(_Node('Video', <Object?>[500, 'skin', 'Clip'])
            ..add(_Node('RelativeFilename', <Object?>['skin.png']))
            ..add(_Node('Content', <Object?>[bmp]))),
        _connect(<List<Object?>>[
          <Object?>['OO', 100, 200],
          <Object?>['OO', 300, 200],
          <Object?>['OP', 400, 300, 'DiffuseColor'],
          <Object?>['OO', 500, 400],
        ]),
      ]);
      final MeshTexture? texture =
          mesh.primitives.single.material.baseColorTexture;
      expect(texture, isNotNull);
      expect(texture!.width, 1);
      expect(texture.sample(0, 0) & 0xFFFFFF, 0x204060);
    });

    test('an external filename that cannot be resolved is named', () {
      final Mesh3D mesh = loadFbx(
        _fbx(<_Node>[
          _Node('Objects')
            ..add(_quadGeometry(100))
            ..add(_model(200, 'quad', <_Node>[]))
            ..add(_Node('Material', <Object?>[300, 'skin', ''])
              ..add(_Node('Properties70')))
            ..add(_Node('Texture', <Object?>[400, 'diffuse', ''])
              ..add(_Node('RelativeFilename', <Object?>[r'..\tex\skin.png'])))
            ..add(_Node('Video', <Object?>[500, 'skin', 'Clip'])
              ..add(_Node('RelativeFilename', <Object?>[r'..\tex\skin.png']))),
          _connect(<List<Object?>>[
            <Object?>['OO', 100, 200],
            <Object?>['OO', 300, 200],
            <Object?>['OP', 400, 300, 'DiffuseColor'],
            <Object?>['OO', 500, 400],
          ]),
        ]),
        name: 'test',
      );
      expect(
        mesh.unsupported,
        contains('the texture "skin.png" was not found'),
        reason: 'the exporter\'s path is stripped to the bare name, because '
            'the directory it names is on a machine that is not this one',
      );
    });
  });

  group('the sniffer', () {
    test('loadMesh routes binary FBX here', () {
      final Mesh3D mesh = loadMesh(
        _fbx(<_Node>[
          _Node('Objects')
            ..add(_quadGeometry(100))
            ..add(_model(200, 'quad', <_Node>[])),
          _connect(<List<Object?>>[
            <Object?>['OO', 100, 200],
          ]),
        ]),
      );
      expect(mesh.format, 'fbx');
    });

    test('ASCII FBX is refused by name rather than read as OBJ', () {
      final Uint8List ascii = Uint8List.fromList(utf8.encode('''
; FBX 7.4.0 project file
FBXHeaderExtension:  {
  FBXHeaderVersion: 1003
  FBXVersion: 7400
}
Objects:  {
}
'''));
      expect(
        () => loadMesh(ascii),
        throwsA(isA<MeshParseException>().having(
          (MeshParseException e) => e.message,
          'message',
          contains('ASCII FBX'),
        )),
      );
    });

    test('bytes that are not FBX at all are refused', () {
      expect(
        () => loadFbx(Uint8List.fromList(<int>[1, 2, 3, 4])),
        throwsA(isA<MeshParseException>()),
      );
    });
  });

  group('posing', () {
    test('a skin with no animation poses to its rest positions', () {
      // The property that makes every other skinning result meaningful: with
      // the identity pose, `jointWorld * inverseBind` is the identity and the
      // vertices must come back exactly where they were. A bind matrix taken
      // from the wrong space fails here before anything moves.
      final MeshNode root = MeshNode(
        name: 'root',
        parent: -1,
        restLocal: Matrix4.translation(const Vector3(3, 0, 0)),
        restTranslation: const Vector3(3, 0, 0),
        restRotation: Float32List.fromList(<double>[0, 0, 0, 1]),
        restScale: const Vector3(1, 1, 1),
      );
      final MeshSkin skin = MeshSkin(
        name: 'one',
        jointNodes: Int32List.fromList(<int>[0]),
        inverseBind: <Matrix4>[
          Matrix4.translation(const Vector3(-3, 0, 0)),
        ],
      );
      final MeshPrimitive primitive = MeshPrimitive(
        positions: Float32List.fromList(<double>[5, 1, 0]),
        indices: Uint32List.fromList(<int>[0]),
        jointIndices: Uint16List.fromList(<int>[0, 0, 0, 0]),
        jointWeights: Float32List.fromList(<double>[1, 0, 0, 0]),
        skin: 0,
      );
      final MeshPose pose = MeshPose(<MeshNode>[root])..evaluate(null, 0);
      final Float32List posed =
          skinPositions(primitive, pose.skinningMatrices(skin));
      expect(posed[0], closeTo(5, 1e-5));
      expect(posed[1], closeTo(1, 1e-5));
    });

    test('a rotation channel turns the joint it names', () {
      final MeshNode root = MeshNode(
        name: 'root',
        parent: -1,
        restLocal: Matrix4.identity(),
        restTranslation: Vector3.zero,
        restRotation: Float32List.fromList(<double>[0, 0, 0, 1]),
        restScale: const Vector3(1, 1, 1),
      );
      // A quarter turn about Z, as a quaternion: sin(45 degrees) in z and w.
      const double h = 0.7071067811865476;
      final MeshAnimation animation = MeshAnimation(
        name: 'turn',
        duration: 1,
        channels: <MeshAnimationChannel>[
          MeshAnimationChannel(
            node: 0,
            path: MeshChannelPath.rotation,
            times: Float32List.fromList(<double>[0, 1]),
            values: Float32List.fromList(<double>[0, 0, 0, 1, 0, 0, h, h]),
          ),
        ],
      );
      final MeshSkin skin = MeshSkin(
        name: 'one',
        jointNodes: Int32List.fromList(<int>[0]),
        inverseBind: <Matrix4>[Matrix4.identity()],
      );
      final MeshPrimitive primitive = MeshPrimitive(
        positions: Float32List.fromList(<double>[1, 0, 0]),
        indices: Uint32List.fromList(<int>[0]),
        jointIndices: Uint16List.fromList(<int>[0, 0, 0, 0]),
        jointWeights: Float32List.fromList(<double>[1, 0, 0, 0]),
        skin: 0,
      );

      final MeshPose pose = MeshPose(<MeshNode>[root])..evaluate(animation, 1);
      final Float32List end =
          skinPositions(primitive, pose.skinningMatrices(skin));
      expect(end[0], closeTo(0, 1e-5));
      expect(end[1], closeTo(1, 1e-5));

      // Half way, the interpolation is a slerp and not a component-wise blend:
      // 45 degrees, so both components are the same.
      pose.evaluate(animation, 0.5);
      final Float32List middle =
          skinPositions(primitive, pose.skinningMatrices(skin));
      expect(middle[0], closeTo(h, 1e-5));
      expect(middle[1], closeTo(h, 1e-5));
    });

    test('weights are renormalised so a vertex is not shrunk', () {
      // Two joints claiming 0.25 each and nothing else. Without the
      // renormalisation the vertex would land half way to the origin.
      final MeshNode root = MeshNode(
        name: 'root',
        parent: -1,
        restLocal: Matrix4.identity(),
        restTranslation: Vector3.zero,
        restRotation: Float32List.fromList(<double>[0, 0, 0, 1]),
        restScale: const Vector3(1, 1, 1),
      );
      final MeshPrimitive primitive = MeshPrimitive(
        positions: Float32List.fromList(<double>[4, 0, 0]),
        indices: Uint32List.fromList(<int>[0]),
        jointIndices: Uint16List.fromList(<int>[0, 0, 0, 0]),
        jointWeights: Float32List.fromList(<double>[0.5, 0.5, 0, 0]),
        skin: 0,
      );
      final MeshPose pose = MeshPose(<MeshNode>[root])..evaluate(null, 0);
      final Float32List posed = skinPositions(
        primitive,
        pose.skinningMatrices(MeshSkin(
          name: 'one',
          jointNodes: Int32List.fromList(<int>[0]),
          inverseBind: <Matrix4>[Matrix4.identity()],
        )),
      );
      expect(posed[0], closeTo(4, 1e-5));
    });
  });

  group('real models on this machine', () {
    // Skipped where the files are not present, which is everywhere but the
    // machine they were downloaded on. The cases above are the contract; these
    // are the reality check, and a reality check that cannot run is not a
    // reason to fail a suite.
    final Directory root = Directory('D:/3d');
    final String? skip =
        root.existsSync() ? null : 'no model library at ${root.path}';

    Mesh3D read(String path) {
      final File file = File(path);
      return loadMesh(
        Uint8List.fromList(file.readAsBytesSync()),
        name: file.uri.pathSegments.last,
        resolveBuffer: (String uri) {
          final File sibling = File('${file.parent.path}/$uri');
          return sibling.existsSync()
              ? Uint8List.fromList(sibling.readAsBytesSync())
              : null;
        },
      );
    }

    test('the same model in FBX, OBJ and GLB has the same triangle count', () {
      // The strongest cross-check available without a reference renderer:
      // three independent readers, three formats, one model. A fan bug, a
      // mask bug or a stride bug shows up here as a mismatch.
      final File fbx = File('${root.path}/sonic.fbx');
      final File obj = File('${root.path}/sonic.obj');
      final File glb = File('${root.path}/sonic.glb');
      if (!fbx.existsSync() || !obj.existsSync() || !glb.existsSync()) return;
      final Mesh3D fromFbx = read(fbx.path);
      expect(fromFbx.triangleCount, read(obj.path).triangleCount);
      expect(fromFbx.triangleCount, read(glb.path).triangleCount);
    }, skip: skip);

    test('the FBX and the GLB of the same scene agree on size and shape', () {
      final File fbx = File('${root.path}/FBX/FBX/SciFi_Island.fbx');
      final File glb = File('${root.path}/GLB/GLB/SciFi_Island.glb');
      if (!fbx.existsSync() || !glb.existsSync()) return;
      final Mesh3D fromFbx = read(fbx.path);
      final Mesh3D fromGlb = read(glb.path);
      expect(fromFbx.triangleCount, fromGlb.triangleCount);
      expect(fromFbx.primitives.length, fromGlb.primitives.length);
      // The FBX is in centimetres and the glTF export is in metres, so the
      // sizes are compared as a ratio. Anything but a hundred here means the
      // transform hierarchy was composed differently by the two readers.
      final Vector3 a = fromFbx.computeBounds().size;
      final Vector3 b = fromGlb.computeBounds().size;
      expect(a.x / b.x, closeTo(100, 0.1));
      expect(a.y / b.y, closeTo(100, 0.1));
      expect(a.z / b.z, closeTo(100, 0.1));
    }, skip: skip);

    test('a Mixamo take reads its skin and its curves', () {
      final File file = File('${root.path}/animated/Dying.fbx');
      if (!file.existsSync()) return;
      final Mesh3D mesh = read(file.path);
      expect(mesh.skins, isNotEmpty);
      expect(mesh.animations, hasLength(1));
      final MeshAnimation animation = mesh.animations.single;
      expect(animation.duration, closeTo(4.4, 0.1));
      expect(animation.channels.length, greaterThan(40));
      expect(
        mesh.primitives.every((MeshPrimitive p) => p.isSkinned),
        isTrue,
      );
    }, skip: skip);

    test('posing a Mixamo take at rest returns the stored vertices', () {
      final File file = File('${root.path}/animated/Dying.fbx');
      if (!file.existsSync()) return;
      final Mesh3D mesh = read(file.path);
      final MeshPose pose = MeshPose(mesh.nodes)..evaluate(null, 0);
      for (final MeshPrimitive primitive in mesh.primitives) {
        final Float32List posed = skinPositions(
          primitive,
          pose.skinningMatrices(mesh.skins[primitive.skin]),
        );
        var worst = 0.0;
        for (var i = 0; i < posed.length; i++) {
          final double delta = (posed[i] - primitive.positions[i]).abs();
          if (delta > worst) worst = delta;
        }
        // Centimetres, on a model 180 of them tall. Anything larger means the
        // inverse bind matrices are not the inverses of the rest pose, and the
        // model would be torn apart before the animation even starts.
        expect(worst, lessThan(0.05));
      }
    }, skip: skip);

    test('the dying animation puts the character on the floor', () {
      // The end-to-end check that no unit test can stand in for: at the start
      // of the take the figure is 1.7 m tall, and at the end it is lying down.
      // A skinning bug that poses limbs wrongly still changes these numbers,
      // but a transform that is not applied at all leaves them identical.
      final File file = File('${root.path}/animated/Dying.fbx');
      if (!file.existsSync()) return;
      final Mesh3D mesh = read(file.path);
      final MeshAnimation animation = mesh.animations.single;

      Bounds3 boundsAt(double time) {
        final MeshPose pose = MeshPose(mesh.nodes)..evaluate(animation, time);
        var bounds = Bounds3.empty;
        for (final MeshPrimitive primitive in mesh.primitives) {
          final Float32List posed = skinPositions(
            primitive,
            pose.skinningMatrices(mesh.skins[primitive.skin]),
          );
          for (var i = 0; i + 2 < posed.length; i += 3) {
            bounds = bounds.include(
              Vector3(posed[i], posed[i + 1], posed[i + 2]),
            );
          }
        }
        return bounds;
      }

      final Bounds3 start = boundsAt(0);
      final Bounds3 end = boundsAt(animation.duration);
      expect(start.max.y, greaterThan(150));
      expect(end.max.y, lessThan(60));
      // Standing, the arms are at the sides; on the floor the body is spread
      // along the ground, so the horizontal extent grows as the height falls.
      expect(end.size.z, greaterThan(start.size.z));
    }, skip: skip);
  });
}

/// A one-pixel 8-bit RGB PNG of the given colour.
Uint8List _onePixelPng(int r, int g, int b) {
  final BytesBuilder out = BytesBuilder()
    ..add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final Uint8List header = Uint8List(13);
  final ByteData headerData = ByteData.sublistView(header);
  headerData.setUint32(0, 1, Endian.big); // width
  headerData.setUint32(4, 1, Endian.big); // height
  header[8] = 8; // bit depth
  header[9] = 2; // colour type: truecolour
  out.add(_pngChunk('IHDR', header));

  // One scanline: the filter byte, then the pixel. Filter 0 is "none", which
  // is what a one-pixel image has no reason to improve on.
  out.add(_pngChunk(
    'IDAT',
    _zlibStored(Uint8List.fromList(<int>[0, r, g, b])),
  ));
  out.add(_pngChunk('IEND', Uint8List(0)));
  return out.toBytes();
}

Uint8List _pngChunk(String type, Uint8List data) {
  final Uint8List typeBytes = latin1.encode(type);
  final Uint8List body = Uint8List(typeBytes.length + data.length)
    ..setRange(0, typeBytes.length, typeBytes)
    ..setRange(typeBytes.length, typeBytes.length + data.length, data);
  final Uint8List length = Uint8List(4)
    ..buffer.asByteData().setUint32(0, data.length, Endian.big);
  final Uint8List crc = Uint8List(4)
    ..buffer.asByteData().setUint32(0, _crc32(body), Endian.big);
  return (BytesBuilder()
        ..add(length)
        ..add(body)
        ..add(crc))
      .toBytes();
}

int _crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final int byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
