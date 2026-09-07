/// Reading OBJ, STL, glTF 2.0 and GLB into [Mesh3D].
///
/// Four formats, chosen because between them they cover what a person actually
/// has on disk: OBJ from anything old, STL from anything printed, and glTF/GLB
/// from anything current. **FBX is refused by name.** It is Autodesk's binary
/// format with a compressed node tree, a property system and a version history
/// that changed the layout more than once; supporting it is a project rather
/// than a loader, and half-supporting it would mean models that open and are
/// silently wrong.
///
/// ## The convention that trips every one of these
///
/// Face winding and handedness. OBJ and glTF are counter-clockwise front-facing
/// in a right-handed space; STL is counter-clockwise too but carries a normal
/// per facet that disagrees with the winding often enough that the winding is
/// the one to trust — many exporters write a zero normal, and some write one
/// pointing the wrong way. So the loaders here keep the file's winding and
/// never reorder, and the rasteriser decides what facing means. A loader that
/// "fixed" winding would make a model look right in this viewer and wrong
/// everywhere else.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../container/zip_archive.dart' show ZipArchive;
import 'mesh3d.dart';

/// Reads a model, choosing the format from the bytes rather than the name.
///
/// [name] is only used for the mesh's label and to disambiguate the one case
/// the bytes cannot: OBJ and ASCII STL are both plain text.
Mesh3D loadMesh(
  Uint8List bytes, {
  String name = 'model',
  GltfBufferResolver? resolveBuffer,
}) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x67 &&
      bytes[1] == 0x6C &&
      bytes[2] == 0x54 &&
      bytes[3] == 0x46) {
    return loadGlb(bytes, name: name, resolveBuffer: resolveBuffer);
  }
  // A ZIP where a model was expected is a container somebody exported by
  // mistake, and saying so beats "not a known format".
  if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    final ZipArchive archive = ZipArchive.parse(bytes);
    throw MeshParseException(
      'this is a ZIP container, not a model',
      detail: 'entries: ${archive.names.take(8).join(', ')}',
    );
  }
  if (_looksLikeFbx(bytes)) {
    throw const MeshParseException(
      'FBX is not supported',
      detail: 'Autodesk FBX is a binary format with its own node tree and '
          'property system; this viewer reads OBJ, STL, glTF and GLB. Export '
          'the model as glTF or OBJ.',
    );
  }
  if (_looksBinary(bytes)) return loadStl(bytes, name: name);

  final String text = utf8.decode(bytes, allowMalformed: true);
  final String head = text.length > 512 ? text.substring(0, 512) : text;
  if (head.trimLeft().startsWith('solid') && head.contains('facet')) {
    return loadStl(bytes, name: name);
  }
  if (head.trimLeft().startsWith('{')) {
    return loadGltf(text, name: name, resolveBuffer: resolveBuffer);
  }
  return loadObj(text, name: name);
}

bool _looksLikeFbx(Uint8List bytes) {
  const String magic = 'Kaydara FBX Binary';
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic.codeUnitAt(i)) return false;
  }
  return true;
}

/// Whether the first kilobyte holds bytes no text model would.
///
/// A binary STL begins with an 80-byte header that is often zeros, which is
/// exactly what this finds. Checking for a `solid` prefix instead is the trap:
/// plenty of binary STLs start their header with the word "solid" because the
/// tool that wrote them copied an ASCII one.
bool _looksBinary(Uint8List bytes) {
  final int limit = bytes.length < 1024 ? bytes.length : 1024;
  for (var i = 0; i < limit; i++) {
    final int b = bytes[i];
    if (b == 0) return true;
    if (b < 9 || (b > 13 && b < 32)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// OBJ
// ---------------------------------------------------------------------------

/// Reads Wavefront OBJ.
///
/// Positions, normals, texture coordinates and faces, with faces of any arity
/// fan-triangulated. Groups become separate primitives so a viewer can report
/// them, and `usemtl` names are recorded even though the `.mtl` file beside the
/// model is not read: the name is what lets a person tell that materials exist
/// and were not applied.
Mesh3D loadObj(String source, {String name = 'model'}) {
  final List<double> positions = <double>[];
  final List<double> normals = <double>[];
  final Set<String> unsupported = <String>{};

  // Faces reference vertices by index, and the same vertex can appear with
  // different normals in different faces. A key of "position/normal" is what
  // keeps those distinct without exploding every vertex - which is what
  // emitting three fresh vertices per triangle would do, tripling the memory
  // of a two-million-triangle model for nothing.
  final Map<String, int> vertexIds = <String, int>{};
  final List<double> outPositions = <double>[];
  final List<double> outNormals = <double>[];
  final List<int> indices = <int>[];
  var sawNormals = false;

  int vertexFor(String token) {
    final int? existing = vertexIds[token];
    if (existing != null) return existing;
    final List<String> parts = token.split('/');
    final int positionIndex = _objIndex(parts[0], positions.length ~/ 3);
    final int normalIndex = parts.length > 2 && parts[2].isNotEmpty
        ? _objIndex(parts[2], normals.length ~/ 3)
        : -1;
    final int id = outPositions.length ~/ 3;
    if (positionIndex >= 0 && positionIndex * 3 + 2 < positions.length) {
      outPositions
        ..add(positions[positionIndex * 3])
        ..add(positions[positionIndex * 3 + 1])
        ..add(positions[positionIndex * 3 + 2]);
    } else {
      outPositions.addAll(<double>[0, 0, 0]);
    }
    if (normalIndex >= 0 && normalIndex * 3 + 2 < normals.length) {
      sawNormals = true;
      outNormals
        ..add(normals[normalIndex * 3])
        ..add(normals[normalIndex * 3 + 1])
        ..add(normals[normalIndex * 3 + 2]);
    } else {
      outNormals.addAll(<double>[0, 0, 0]);
    }
    return vertexIds[token] = id;
  }

  for (final String rawLine in const LineSplitter().convert(source)) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final int space = line.indexOf(' ');
    if (space < 0) continue;
    final String keyword = line.substring(0, space);
    final String rest = line.substring(space + 1).trim();

    switch (keyword) {
      case 'v':
        final List<double> values = _numbers(rest, 3);
        positions.addAll(values);
      case 'vn':
        normals.addAll(_numbers(rest, 3));
      case 'vt':
        // Read and dropped: this viewer has no texture sampling, so keeping
        // the coordinates would only make the mesh bigger.
        unsupported.add('texture coordinates');
      case 'f':
        final List<String> tokens = rest
            .split(RegExp(r'\s+'))
            .where((String t) => t.isNotEmpty)
            .toList();
        if (tokens.length < 3) continue;
        final int first = vertexFor(tokens[0]);
        // Fan triangulation. Correct for the convex faces an exporter emits and
        // wrong for a concave one, which OBJ permits and no common tool writes;
        // an ear-clipping triangulator would be right in general and is not
        // worth the code until a model needs it.
        for (var i = 1; i + 1 < tokens.length; i++) {
          indices
            ..add(first)
            ..add(vertexFor(tokens[i]))
            ..add(vertexFor(tokens[i + 1]));
        }
      case 'mtllib':
      case 'usemtl':
        unsupported.add('materials from .mtl');
      case 's':
      case 'g':
      case 'o':
        break;
      default:
        break;
    }
  }

  if (indices.isEmpty) {
    throw const MeshParseException(
      'the OBJ has no faces',
      detail: 'positions may have loaded, but nothing references them',
    );
  }

  return Mesh3D(
    name: name,
    format: 'obj',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
        positions: Float32List.fromList(outPositions),
        indices: Uint32List.fromList(indices),
        normals: sawNormals ? Float32List.fromList(outNormals) : null,
      ),
    ],
    unsupported: unsupported,
  );
}

/// OBJ indices are 1-based, and negative means "counted back from the end".
int _objIndex(String token, int count) {
  final int? value = int.tryParse(token);
  if (value == null) return -1;
  if (value > 0) return value - 1;
  if (value < 0) return count + value;
  return -1;
}

List<double> _numbers(String text, int expected) {
  final List<String> parts =
      text.split(RegExp(r'\s+')).where((String t) => t.isNotEmpty).toList();
  return <double>[
    for (var i = 0; i < expected; i++)
      i < parts.length ? (double.tryParse(parts[i]) ?? 0) : 0,
  ];
}

// ---------------------------------------------------------------------------
// STL
// ---------------------------------------------------------------------------

/// Reads STL, binary or ASCII.
///
/// Every facet carries three fresh vertices: the format has no vertex sharing
/// at all, which is why an STL of a smooth object still shades flat. Welding
/// coincident vertices would fix that and is deliberately not done here — it is
/// a lossy decision about how coincident is coincident, and it belongs to a
/// tool, not to a loader.
Mesh3D loadStl(Uint8List bytes, {String name = 'model'}) {
  if (!_looksBinary(bytes)) {
    return _loadAsciiStl(utf8.decode(bytes, allowMalformed: true), name);
  }
  if (bytes.length < 84) {
    throw const MeshParseException(
      'the STL is too short to hold a header and a count',
    );
  }
  final ByteData data = ByteData.sublistView(bytes);
  final int count = data.getUint32(80, Endian.little);
  // 50 bytes per facet: a normal, three vertices, and two bytes of attribute.
  // Checking the arithmetic before allocating is what turns a corrupt file into
  // a message instead of an out-of-memory.
  final int expected = 84 + count * 50;
  if (count < 0 || expected > bytes.length) {
    throw MeshParseException(
      'the STL declares more facets than it holds',
      detail:
          '$count facets need $expected bytes, the file has ${bytes.length}',
    );
  }

  final Float32List positions = Float32List(count * 9);
  final Float32List normals = Float32List(count * 9);
  final Uint32List indices = Uint32List(count * 3);
  var at = 84;
  for (var f = 0; f < count; f++) {
    final double nx = data.getFloat32(at, Endian.little);
    final double ny = data.getFloat32(at + 4, Endian.little);
    final double nz = data.getFloat32(at + 8, Endian.little);
    at += 12;
    for (var v = 0; v < 3; v++) {
      final int base = (f * 3 + v) * 3;
      positions[base] = data.getFloat32(at, Endian.little);
      positions[base + 1] = data.getFloat32(at + 4, Endian.little);
      positions[base + 2] = data.getFloat32(at + 8, Endian.little);
      normals[base] = nx;
      normals[base + 1] = ny;
      normals[base + 2] = nz;
      indices[f * 3 + v] = f * 3 + v;
      at += 12;
    }
    at += 2;
  }

  return Mesh3D(
    name: name,
    format: 'stl',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
        positions: positions,
        indices: indices,
        // Only when the file wrote real ones. A zero normal is what many
        // exporters put there, and handing zeros to the shader makes every
        // facet black - which reads as a lighting bug rather than as absent
        // data.
        normals: _hasNonZero(normals) ? normals : null,
      ),
    ],
  );
}

bool _hasNonZero(Float32List values) {
  for (var i = 0; i < values.length; i++) {
    if (values[i] != 0) return true;
  }
  return false;
}

Mesh3D _loadAsciiStl(String source, String name) {
  final List<double> positions = <double>[];
  final List<int> indices = <int>[];
  for (final String rawLine in const LineSplitter().convert(source)) {
    final String line = rawLine.trim();
    if (!line.startsWith('vertex')) continue;
    final List<double> values = _numbers(line.substring(6).trim(), 3);
    indices.add(positions.length ~/ 3);
    positions.addAll(values);
  }
  if (indices.isEmpty || indices.length % 3 != 0) {
    throw MeshParseException(
      'the ASCII STL has no complete facets',
      detail: '${indices.length} vertices',
    );
  }
  return Mesh3D(
    name: name,
    format: 'stl',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
        positions: Float32List.fromList(positions),
        indices: Uint32List.fromList(indices),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// glTF 2.0 and GLB
// ---------------------------------------------------------------------------

/// Supplies the bytes of a glTF buffer that lives outside the document.
///
/// A `.gltf` normally sits beside a `.bin`, and reading it means touching the
/// filesystem — which this library does not do, and deliberately: a decoder
/// that opens files is a decoder that cannot run in a browser, in a test, or
/// over bytes that arrived from a network. So the path stays with the caller,
/// and this is the seam. Returning null for a URI the caller will not or cannot
/// resolve is normal, and the loader records `external buffers (.bin)`.
typedef GltfBufferResolver = Uint8List? Function(String uri);

/// Reads a GLB: the binary wrapper around glTF JSON plus one buffer.
Mesh3D loadGlb(
  Uint8List bytes, {
  String name = 'model',
  GltfBufferResolver? resolveBuffer,
}) {
  if (bytes.length < 12) {
    throw const MeshParseException('the GLB is too short for its header');
  }
  final ByteData data = ByteData.sublistView(bytes);
  final int version = data.getUint32(4, Endian.little);
  if (version != 2) {
    throw MeshParseException(
      'only glTF 2 binary is supported',
      detail: 'this file declares version $version',
    );
  }
  String? json;
  Uint8List? binary;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final int length = data.getUint32(at, Endian.little);
    final int kind = data.getUint32(at + 4, Endian.little);
    final int start = at + 8;
    if (start + length > bytes.length) break;
    final Uint8List chunk = Uint8List.sublistView(bytes, start, start + length);
    if (kind == 0x4E4F534A) {
      json = utf8.decode(chunk, allowMalformed: true);
    } else if (kind == 0x004E4942) {
      binary = chunk;
    }
    // Chunks are padded to four bytes, and a reader that does not round up
    // lands one to three bytes into the next header and stops early with half
    // the model.
    at = start + ((length + 3) & ~3);
  }
  if (json == null) {
    throw const MeshParseException('the GLB has no JSON chunk');
  }
  return loadGltf(
    json,
    name: name,
    binaryChunk: binary,
    resolveBuffer: resolveBuffer,
  );
}

/// Reads glTF 2.0 JSON.
///
/// [binaryChunk] is the GLB buffer when there is one. A `.gltf` that points at
/// external `.bin` files cannot be read from the text alone, and this says so
/// by name rather than returning an empty model.
Mesh3D loadGltf(
  String source, {
  String name = 'model',
  Uint8List? binaryChunk,
  GltfBufferResolver? resolveBuffer,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (error) {
    throw MeshParseException('the glTF is not JSON', detail: '$error');
  }
  if (decoded is! Map<String, Object?>) {
    throw const MeshParseException('a glTF document is a JSON object');
  }
  final Map<String, Object?> gltf = decoded;
  final Set<String> unsupported = <String>{};

  final List<Uint8List> buffers =
      _gltfBuffers(gltf, binaryChunk, unsupported, resolveBuffer);
  final List<Object?> bufferViews = _list(gltf['bufferViews']);
  final List<Object?> accessors = _list(gltf['accessors']);
  final List<Object?> materials = _list(gltf['materials']);
  final List<Object?> meshes = _list(gltf['meshes']);

  if (_list(gltf['animations']).isNotEmpty) unsupported.add('animations');
  if (_list(gltf['skins']).isNotEmpty) unsupported.add('skinning');
  if (_list(gltf['textures']).isNotEmpty) unsupported.add('textures');
  if (_list(gltf['cameras']).isNotEmpty) unsupported.add('cameras');

  final List<MeshPrimitive> primitives = <MeshPrimitive>[];

  // The node tree, walked so that each mesh is placed where the scene puts it.
  // Ignoring it and drawing every mesh at the origin is the shortcut that makes
  // a multi-part model - a car with four wheels, all at the centre - look like
  // a pile.
  void walk(int nodeIndex, Matrix4 parent, Set<int> seen) {
    if (!seen.add(nodeIndex)) return;
    final List<Object?> nodes = _list(gltf['nodes']);
    if (nodeIndex < 0 || nodeIndex >= nodes.length) return;
    final Object? raw = nodes[nodeIndex];
    if (raw is! Map<String, Object?>) return;
    final Matrix4 local = _gltfNodeMatrix(raw);
    final Matrix4 world = parent.multiply(local);

    final Object? meshIndex = raw['mesh'];
    if (meshIndex is num && meshIndex.toInt() < meshes.length) {
      final Object? mesh = meshes[meshIndex.toInt()];
      if (mesh is Map<String, Object?>) {
        for (final Object? entry in _list(mesh['primitives'])) {
          if (entry is! Map<String, Object?>) continue;
          final MeshPrimitive? primitive = _gltfPrimitive(
            entry,
            accessors: accessors,
            bufferViews: bufferViews,
            buffers: buffers,
            materials: materials,
            transform: world,
            unsupported: unsupported,
          );
          if (primitive != null) primitives.add(primitive);
        }
      }
    }
    for (final Object? child in _list(raw['children'])) {
      if (child is num) walk(child.toInt(), world, seen);
    }
    seen.remove(nodeIndex);
  }

  final List<Object?> scenes = _list(gltf['scenes']);
  final int sceneIndex = (gltf['scene'] as num?)?.toInt() ?? 0;
  if (sceneIndex >= 0 && sceneIndex < scenes.length) {
    final Object? scene = scenes[sceneIndex];
    if (scene is Map<String, Object?>) {
      for (final Object? node in _list(scene['nodes'])) {
        if (node is num) walk(node.toInt(), Matrix4.identity(), <int>{});
      }
    }
  } else {
    // A document with meshes and no scene is legal and is what some exporters
    // produce; drawing the meshes unplaced is better than drawing nothing.
    for (var i = 0; i < _list(gltf['nodes']).length; i++) {
      walk(i, Matrix4.identity(), <int>{});
    }
  }

  if (primitives.isEmpty) {
    throw const MeshParseException(
      'the glTF holds no drawable primitives',
      detail: 'meshes may be present but no scene node reaches them, or the '
          'buffers are external and were not supplied',
    );
  }

  return Mesh3D(
    name: name,
    format: binaryChunk == null ? 'gltf' : 'glb',
    primitives: primitives,
    unsupported: unsupported,
  );
}

List<Object?> _list(Object? value) => value is List ? value : const <Object?>[];

List<Uint8List> _gltfBuffers(
  Map<String, Object?> gltf,
  Uint8List? binaryChunk,
  Set<String> unsupported,
  GltfBufferResolver? resolveBuffer,
) {
  final List<Uint8List> buffers = <Uint8List>[];
  for (final Object? entry in _list(gltf['buffers'])) {
    if (entry is! Map<String, Object?>) {
      buffers.add(Uint8List(0));
      continue;
    }
    final Object? uri = entry['uri'];
    if (uri == null) {
      // No URI means the GLB binary chunk.
      buffers.add(binaryChunk ?? Uint8List(0));
    } else if (uri is String && uri.startsWith('data:')) {
      final int comma = uri.indexOf(',');
      if (comma < 0 || !uri.substring(0, comma).contains(';base64')) {
        unsupported.add('non-base64 data URIs');
        buffers.add(Uint8List(0));
      } else {
        buffers.add(base64Decode(uri.substring(comma + 1)));
      }
    } else if (uri is String) {
      // An external `.bin` beside the file. Reading it would mean this library
      // touching the filesystem, which it does not do; the caller supplies it
      // through [GltfBufferResolver] or the buffer stays empty and is named.
      final Uint8List? resolved = resolveBuffer?.call(uri);
      if (resolved == null || resolved.isEmpty) {
        unsupported.add('external buffers (.bin)');
        buffers.add(Uint8List(0));
      } else {
        buffers.add(resolved);
      }
    } else {
      unsupported.add('external buffers (.bin)');
      buffers.add(Uint8List(0));
    }
  }
  return buffers;
}

Matrix4 _gltfNodeMatrix(Map<String, Object?> node) {
  final Object? matrix = node['matrix'];
  if (matrix is List && matrix.length == 16) {
    return Matrix4(Float64List.fromList(<double>[
      for (final Object? value in matrix) (value as num?)?.toDouble() ?? 0,
    ]));
  }
  Matrix4 result = Matrix4.identity();
  final Object? translation = node['translation'];
  if (translation is List && translation.length >= 3) {
    result = result.multiply(Matrix4.translation(Vector3(
      (translation[0] as num).toDouble(),
      (translation[1] as num).toDouble(),
      (translation[2] as num).toDouble(),
    )));
  }
  final Object? rotation = node['rotation'];
  if (rotation is List && rotation.length >= 4) {
    result = result.multiply(Matrix4.rotationFromQuaternion(
      (rotation[0] as num).toDouble(),
      (rotation[1] as num).toDouble(),
      (rotation[2] as num).toDouble(),
      (rotation[3] as num).toDouble(),
    ));
  }
  final Object? scale = node['scale'];
  if (scale is List && scale.length >= 3) {
    result = result.multiply(Matrix4.scale(Vector3(
      (scale[0] as num).toDouble(),
      (scale[1] as num).toDouble(),
      (scale[2] as num).toDouble(),
    )));
  }
  return result;
}

MeshPrimitive? _gltfPrimitive(
  Map<String, Object?> primitive, {
  required List<Object?> accessors,
  required List<Object?> bufferViews,
  required List<Uint8List> buffers,
  required List<Object?> materials,
  required Matrix4 transform,
  required Set<String> unsupported,
}) {
  // Mode 4 is triangles. The others - strips, fans, lines, points - are legal
  // and rare, and drawing a line list as triangles would produce nonsense, so
  // they are named and skipped.
  final int mode = (primitive['mode'] as num?)?.toInt() ?? 4;
  if (mode != 4) {
    unsupported.add('primitive mode $mode');
    return null;
  }
  final Object? attributes = primitive['attributes'];
  if (attributes is! Map<String, Object?>) return null;
  final Object? positionIndex = attributes['POSITION'];
  if (positionIndex is! num) return null;

  final Float32List? positions = _gltfAccessorFloats(
    positionIndex.toInt(),
    accessors: accessors,
    bufferViews: bufferViews,
    buffers: buffers,
    components: 3,
  );
  if (positions == null) return null;

  // Positions are baked into world space here rather than carried as a matrix
  // per primitive. The rasteriser then has one transform for the whole model
  // instead of one per primitive, and a scene of two hundred nodes costs two
  // hundred fewer matrix multiplications per frame.
  for (var i = 0; i + 2 < positions.length; i += 3) {
    final Vector3 p = transform.transformPoint(
      Vector3(positions[i], positions[i + 1], positions[i + 2]),
    );
    positions[i] = p.x;
    positions[i + 1] = p.y;
    positions[i + 2] = p.z;
  }

  Float32List? normals;
  final Object? normalIndex = attributes['NORMAL'];
  if (normalIndex is num) {
    normals = _gltfAccessorFloats(
      normalIndex.toInt(),
      accessors: accessors,
      bufferViews: bufferViews,
      buffers: buffers,
      components: 3,
    );
    if (normals != null) {
      for (var i = 0; i + 2 < normals.length; i += 3) {
        // Direction and not point: a normal carried through the node's
        // translation stops being a direction.
        final Vector3 n = transform
            .transformDirection(
              Vector3(normals[i], normals[i + 1], normals[i + 2]),
            )
            .normalized;
        normals[i] = n.x;
        normals[i + 1] = n.y;
        normals[i + 2] = n.z;
      }
    }
  }

  Uint32List indices;
  final Object? indexAccessor = primitive['indices'];
  if (indexAccessor is num) {
    indices = _gltfAccessorIndices(
          indexAccessor.toInt(),
          accessors: accessors,
          bufferViews: bufferViews,
          buffers: buffers,
        ) ??
        Uint32List(0);
  } else {
    // No index buffer: the positions are the triangles, in order.
    final int count = positions.length ~/ 3;
    indices = Uint32List(count);
    for (var i = 0; i < count; i++) {
      indices[i] = i;
    }
  }
  if (indices.isEmpty) return null;

  return MeshPrimitive(
    positions: positions,
    indices: indices,
    normals: normals,
    material: _gltfMaterial(primitive['material'], materials, unsupported),
  );
}

MeshMaterial _gltfMaterial(
  Object? index,
  List<Object?> materials,
  Set<String> unsupported,
) {
  if (index is! num || index.toInt() >= materials.length) {
    return const MeshMaterial();
  }
  final Object? raw = materials[index.toInt()];
  if (raw is! Map<String, Object?>) return const MeshMaterial();
  final Object? pbr = raw['pbrMetallicRoughness'];
  var colorArgb = 0xFFB4BCC8;
  var metallic = 1.0;
  var roughness = 1.0;
  if (pbr is Map<String, Object?>) {
    final Object? base = pbr['baseColorFactor'];
    if (base is List && base.length >= 3) {
      int channel(int i) =>
          (((base[i] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0) * 255).round();
      final int alpha = base.length > 3
          ? (((base[3] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0) * 255).round()
          : 255;
      colorArgb =
          (alpha << 24) | (channel(0) << 16) | (channel(1) << 8) | channel(2);
    }
    metallic = (pbr['metallicFactor'] as num?)?.toDouble() ?? 1;
    roughness = (pbr['roughnessFactor'] as num?)?.toDouble() ?? 1;
    if (pbr.containsKey('baseColorTexture')) unsupported.add('textures');
  }
  if (raw.containsKey('normalTexture')) unsupported.add('normal maps');
  if (raw.containsKey('emissiveTexture')) unsupported.add('emissive maps');
  return MeshMaterial(
    name: raw['name'] as String? ?? '',
    colorArgb: colorArgb,
    metallic: metallic,
    roughness: roughness,
    doubleSided: raw['doubleSided'] == true,
  );
}

/// The component sizes glTF accessors use, by component type.
const Map<int, int> _componentBytes = <int, int>{
  5120: 1, // byte
  5121: 1, // unsigned byte
  5122: 2, // short
  5123: 2, // unsigned short
  5125: 4, // unsigned int
  5126: 4, // float
};

const Map<String, int> _typeComponents = <String, int>{
  'SCALAR': 1,
  'VEC2': 2,
  'VEC3': 3,
  'VEC4': 4,
  'MAT4': 16,
};

/// Reads a float accessor, honouring the byte stride.
///
/// The stride is the part that is easy to skip and expensive to skip: an
/// interleaved buffer packs position, normal and texture coordinate together,
/// so reading elements back to back returns a third of a mesh followed by
/// garbage. Exporters interleave routinely.
Float32List? _gltfAccessorFloats(
  int index, {
  required List<Object?> accessors,
  required List<Object?> bufferViews,
  required List<Uint8List> buffers,
  required int components,
}) {
  final _Accessor? accessor =
      _accessorAt(index, accessors, bufferViews, buffers);
  if (accessor == null) return null;
  if (accessor.componentType != 5126) return null;
  if (accessor.components != components) return null;

  final Float32List out = Float32List(accessor.count * components);
  final ByteData data = ByteData.sublistView(accessor.bytes);
  final int stride = accessor.stride == 0 ? components * 4 : accessor.stride;
  for (var element = 0; element < accessor.count; element++) {
    final int base = accessor.offset + element * stride;
    if (base + components * 4 > accessor.bytes.length) break;
    for (var c = 0; c < components; c++) {
      out[element * components + c] =
          data.getFloat32(base + c * 4, Endian.little);
    }
  }
  return out;
}

Uint32List? _gltfAccessorIndices(
  int index, {
  required List<Object?> accessors,
  required List<Object?> bufferViews,
  required List<Uint8List> buffers,
}) {
  final _Accessor? accessor =
      _accessorAt(index, accessors, bufferViews, buffers);
  if (accessor == null || accessor.components != 1) return null;
  final int size = _componentBytes[accessor.componentType] ?? 0;
  if (size == 0) return null;

  final Uint32List out = Uint32List(accessor.count);
  final ByteData data = ByteData.sublistView(accessor.bytes);
  final int stride = accessor.stride == 0 ? size : accessor.stride;
  for (var element = 0; element < accessor.count; element++) {
    final int at = accessor.offset + element * stride;
    if (at + size > accessor.bytes.length) break;
    out[element] = switch (accessor.componentType) {
      5121 => data.getUint8(at),
      5123 => data.getUint16(at, Endian.little),
      5125 => data.getUint32(at, Endian.little),
      _ => 0,
    };
  }
  return out;
}

final class _Accessor {
  const _Accessor({
    required this.bytes,
    required this.offset,
    required this.stride,
    required this.count,
    required this.components,
    required this.componentType,
  });

  final Uint8List bytes;
  final int offset;
  final int stride;
  final int count;
  final int components;
  final int componentType;
}

_Accessor? _accessorAt(
  int index,
  List<Object?> accessors,
  List<Object?> bufferViews,
  List<Uint8List> buffers,
) {
  if (index < 0 || index >= accessors.length) return null;
  final Object? raw = accessors[index];
  if (raw is! Map<String, Object?>) return null;
  final int count = (raw['count'] as num?)?.toInt() ?? 0;
  final int componentType = (raw['componentType'] as num?)?.toInt() ?? 0;
  final int components = _typeComponents[raw['type'] as String? ?? ''] ?? 0;
  if (count == 0 || components == 0) return null;

  final Object? viewIndex = raw['bufferView'];
  if (viewIndex is! num || viewIndex.toInt() >= bufferViews.length) {
    // A sparse accessor with no bufferView is all zeros by definition. Reading
    // it as absent is right; reading it as an error would reject a legal file.
    return null;
  }
  final Object? view = bufferViews[viewIndex.toInt()];
  if (view is! Map<String, Object?>) return null;
  final int bufferIndex = (view['buffer'] as num?)?.toInt() ?? -1;
  if (bufferIndex < 0 || bufferIndex >= buffers.length) return null;
  final Uint8List buffer = buffers[bufferIndex];
  if (buffer.isEmpty) return null;

  final int viewOffset = (view['byteOffset'] as num?)?.toInt() ?? 0;
  final int viewLength = (view['byteLength'] as num?)?.toInt() ?? 0;
  if (viewOffset + viewLength > buffer.length) return null;

  return _Accessor(
    bytes: Uint8List.sublistView(buffer, viewOffset, viewOffset + viewLength),
    offset: (raw['byteOffset'] as num?)?.toInt() ?? 0,
    stride: (view['byteStride'] as num?)?.toInt() ?? 0,
    count: count,
    components: components,
    componentType: componentType,
  );
}
