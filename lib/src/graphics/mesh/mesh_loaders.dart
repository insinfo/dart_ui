/// Reading OBJ, STL, glTF 2.0, GLB and FBX into [Mesh3D].
///
/// Five formats, chosen because between them they cover what a person actually
/// has on disk: OBJ from anything old, STL from anything printed, glTF/GLB
/// from anything current, and FBX from every animation pipeline there is.
/// FBX's node tree, property system and skinning live in `fbx_loader.dart`
/// because they are a reader in their own right; what remains here is the
/// sniff that routes to it.
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
import '../image/decoded_image.dart';
import '../image/image_errors.dart';
import '../image/raster_formats.dart';
import 'fbx_loader.dart' show loadFbx, looksLikeAsciiFbx, looksLikeBinaryFbx;
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
  if (looksLikeBinaryFbx(bytes)) {
    return loadFbx(bytes, name: name, resolveBuffer: resolveBuffer);
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
  // ASCII FBX is refused by name rather than left to the OBJ reader, which
  // finds no `v` lines in it and returns an empty model instead of an error.
  if (looksLikeAsciiFbx(text)) {
    throw const MeshParseException(
      'this is an ASCII FBX, and only binary FBX is read',
      detail: 'the two formats share a name and nothing else: the text one is '
          'a different grammar with the same node names. Re-export it as '
          'binary FBX, or as glTF.',
    );
  }
  return loadObj(text, name: name, resolveBuffer: resolveBuffer);
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

/// Turns encoded image bytes into the word layout a rasteriser samples.
///
/// Returns null rather than throwing on anything it cannot read: a model whose
/// normal map is a format this repository has no codec for should still show
/// its base colour, and the caller records `textures` as unread. Throwing would
/// turn one unreadable image into an unopenable model.
MeshTexture? decodeMeshTexture(Uint8List bytes, {String name = ''}) {
  if (bytes.isEmpty) return null;
  final DecodedImage decoded;
  try {
    decoded = decodeImage(bytes);
  } on UnsupportedImageFormatException {
    return null;
  } on Object {
    // Any decoder failure at all. The alternative is a viewer that refuses a
    // model because one of its forty textures is truncated.
    return null;
  }

  final int width = decoded.width;
  final int height = decoded.height;
  final Uint32List pixels = Uint32List(width * height);
  final Uint8List source = decoded.pixels;
  final int red = decoded.order.redIndex;
  final int blue = decoded.order.blueIndex;
  for (var i = 0; i < pixels.length; i++) {
    final int at = i * 4;
    // Opaque by construction: the shading path has no blending, so an alpha
    // that survived here would be read as a colour channel by nothing and
    // would only make the word look transparent to a future reader.
    pixels[i] = 0xFF000000 |
        (source[at + red] << 16) |
        (source[at + 1] << 8) |
        source[at + blue];
  }
  return MeshTexture(
    width: width,
    height: height,
    pixels: pixels,
    name: name,
  );
}

// ---------------------------------------------------------------------------
// OBJ
// ---------------------------------------------------------------------------

/// Runs of whitespace, compiled once.
///
/// Writing `line.split(RegExp(r'\s+'))` at the call site compiles a fresh
/// pattern on **every call**, which for a 1.2 MB OBJ is one compilation per
/// line. Measured in AOT: `robotnik.obj` went from **3105 ms to 70 ms**, which
/// is 44 times, for moving one expression out of a loop. Nothing about the
/// code reads differently either way, and that is why it survives review - the
/// allocation is invisible at the call site.
final RegExp _whitespace = RegExp(r'\s+');

/// Reads Wavefront OBJ, and the `.mtl` beside it when [resolveBuffer] can
/// find one.
///
/// Faces are grouped by `usemtl`, so a model with a body material and an eye
/// material becomes two primitives with two textures rather than one primitive
/// wearing whichever it met last.
///
/// **`v` is flipped.** OBJ puts the texture origin at the bottom left and glTF
/// at the top left; everything downstream of these loaders uses glTF's, so the
/// flip happens here. Doing it in the sampler instead would mean the rasteriser
/// having to know where each mesh came from.
Mesh3D loadObj(
  String source, {
  String name = 'model',
  GltfBufferResolver? resolveBuffer,
}) {
  final List<double> positions = <double>[];
  final List<double> normals = <double>[];
  final List<double> texCoords = <double>[];
  final Set<String> unsupported = <String>{};
  final Map<String, MeshMaterial> materials = <String, MeshMaterial>{};

  // Faces reference vertices by index, and the same position can appear with
  // different normals or texture coordinates in different faces. A key of
  // "position/uv/normal" keeps those distinct without exploding every vertex,
  // which is what emitting three fresh vertices per triangle would do.
  final Map<String, int> vertexIds = <String, int>{};
  final List<double> outPositions = <double>[];
  final List<double> outNormals = <double>[];
  final List<double> outUvs = <double>[];
  var sawNormals = false;
  var sawUvs = false;

  // One index list per material, in first-seen order so the model draws in the
  // order the file wrote it.
  final Map<String, List<int>> byMaterial = <String, List<int>>{};
  var currentMaterial = '';
  List<int> indicesFor(String material) =>
      byMaterial.putIfAbsent(material, () => <int>[]);

  int vertexFor(String token) {
    final int? existing = vertexIds[token];
    if (existing != null) return existing;
    final List<String> parts = token.split('/');
    final int positionIndex = _objIndex(parts[0], positions.length ~/ 3);
    final int uvIndex = parts.length > 1 && parts[1].isNotEmpty
        ? _objIndex(parts[1], texCoords.length ~/ 2)
        : -1;
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

    if (uvIndex >= 0 && uvIndex * 2 + 1 < texCoords.length) {
      sawUvs = true;
      outUvs
        ..add(texCoords[uvIndex * 2])
        // The flip. See the note on this function.
        ..add(1 - texCoords[uvIndex * 2 + 1]);
    } else {
      outUvs.addAll(<double>[0, 0]);
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
        positions.addAll(_numbers(rest, 3));
      case 'vn':
        normals.addAll(_numbers(rest, 3));
      case 'vt':
        texCoords.addAll(_numbers(rest, 2));
      case 'f':
        final List<String> tokens =
            rest.split(_whitespace).where((String t) => t.isNotEmpty).toList();
        if (tokens.length < 3) continue;
        final List<int> indices = indicesFor(currentMaterial);
        final int first = vertexFor(tokens[0]);
        // Fan triangulation. Correct for the convex faces an exporter emits
        // and wrong for a concave one, which OBJ permits and no common tool
        // writes; ear clipping would be right in general and is not worth the
        // code until a model needs it.
        for (var i = 1; i + 1 < tokens.length; i++) {
          indices
            ..add(first)
            ..add(vertexFor(tokens[i]))
            ..add(vertexFor(tokens[i + 1]));
        }
      case 'mtllib':
        final Uint8List? mtl = resolveBuffer?.call(rest);
        if (mtl == null) {
          // Named precisely rather than as "materials from .mtl", because the
          // two cases need different answers: a viewer that cannot resolve
          // paths, and a `.mtl` that is simply not next to the model. The
          // second is common in models downloaded loose and there is nothing
          // to fix in the loader.
          unsupported.add('the .mtl file "$rest" was not found');
        } else {
          materials.addAll(
            parseMtl(
              utf8.decode(mtl, allowMalformed: true),
              resolveBuffer: resolveBuffer,
              unsupported: unsupported,
            ),
          );
        }
      case 'usemtl':
        currentMaterial = rest;
      case 's':
      case 'g':
      case 'o':
        break;
      default:
        break;
    }
  }

  final int totalIndices =
      byMaterial.values.fold(0, (int sum, List<int> list) => sum + list.length);
  if (totalIndices == 0) {
    throw const MeshParseException(
      'the OBJ has no faces',
      detail: 'positions may have loaded, but nothing references them',
    );
  }

  final Float32List sharedPositions = Float32List.fromList(outPositions);
  final Float32List? sharedNormals =
      sawNormals ? Float32List.fromList(outNormals) : null;
  final Float32List? sharedUvs = sawUvs ? Float32List.fromList(outUvs) : null;

  final List<MeshPrimitive> primitives = <MeshPrimitive>[];
  for (final MapEntry<String, List<int>> entry in byMaterial.entries) {
    if (entry.value.isEmpty) continue;
    // The vertex arrays are shared across primitives rather than sliced per
    // material. Slicing would mean renumbering every index and duplicating
    // every vertex on a material boundary; sharing costs a primitive that
    // indexes a superset, which nothing here minds.
    primitives.add(
      MeshPrimitive(
        positions: sharedPositions,
        indices: Uint32List.fromList(entry.value),
        normals: sharedNormals,
        uvs: sharedUvs,
        material: materials[entry.key] ?? const MeshMaterial(),
      ),
    );
  }

  if (materials.isEmpty && byMaterial.keys.any((String k) => k.isNotEmpty)) {
    unsupported.add('materials from .mtl');
  }

  return Mesh3D(
    name: name,
    format: 'obj',
    primitives: primitives,
    unsupported: unsupported,
  );
}

/// Reads a `.mtl`, keeping the base colour and the diffuse map.
///
/// The rest of the format - specular exponent, ambient colour, illumination
/// model, bump and displacement maps - describes shading this rasteriser does
/// not do, so it is skipped rather than stored where nothing reads it.
Map<String, MeshMaterial> parseMtl(
  String source, {
  GltfBufferResolver? resolveBuffer,
  Set<String>? unsupported,
}) {
  final Map<String, MeshMaterial> materials = <String, MeshMaterial>{};
  // Decoded once per file even when several materials name the same image,
  // which an exported atlas routinely does.
  final Map<String, MeshTexture?> textures = <String, MeshTexture?>{};

  String current = '';
  var colorArgb = 0xFFB4BCC8;
  MeshTexture? map;

  void flush() {
    if (current.isEmpty) return;
    materials[current] = MeshMaterial(
      name: current,
      colorArgb: colorArgb,
      baseColorTexture: map,
    );
  }

  for (final String rawLine in const LineSplitter().convert(source)) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final int space = line.indexOf(' ');
    if (space < 0) continue;
    final String keyword = line.substring(0, space);
    final String rest = line.substring(space + 1).trim();

    switch (keyword) {
      case 'newmtl':
        flush();
        current = rest;
        colorArgb = 0xFFB4BCC8;
        map = null;
      case 'Kd':
        final List<double> rgb = _numbers(rest, 3);
        int channel(double value) => (value.clamp(0.0, 1.0) * 255).round();
        colorArgb = 0xFF000000 |
            (channel(rgb[0]) << 16) |
            (channel(rgb[1]) << 8) |
            channel(rgb[2]);
      case 'map_Kd':
        // Options come before the filename: `map_Kd -s 1 1 1 wood.png`. Taking
        // the last token rather than the whole rest is what survives them, and
        // a filename with spaces is rare enough to lose to that trade.
        final List<String> parts =
            rest.split(_whitespace).where((String t) => t.isNotEmpty).toList();
        if (parts.isEmpty) break;
        final String file = parts.last;
        map = textures.putIfAbsent(file, () {
          final Uint8List? bytes = resolveBuffer?.call(file);
          if (bytes == null) {
            unsupported?.add('the texture "$file" was not found');
            return null;
          }
          final MeshTexture? decoded = decodeMeshTexture(bytes, name: file);
          if (decoded == null) unsupported?.add('textures');
          return decoded;
        });
      case 'map_Bump':
      case 'bump':
        unsupported?.add('normal maps');
      case 'map_Ks':
        unsupported?.add('specular maps');
      default:
        break;
    }
  }
  flush();
  return materials;
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
      text.split(_whitespace).where((String t) => t.isNotEmpty).toList();
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

/// Supplies the bytes of a file that sits beside the model rather than inside
/// it: a glTF's `.bin`, a texture image, an OBJ's `.mtl`.
///
/// Reading those means touching the filesystem, which this library does not do
/// and deliberately: a decoder that opens files is a decoder that cannot run in
/// a browser, in a test, or over bytes that arrived from a network. So the path
/// stays with the caller and this is the seam. Returning null for a URI the
/// caller will not or cannot resolve is normal, and the loader records what it
/// therefore could not read.
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
  if (_list(gltf['cameras']).isNotEmpty) unsupported.add('cameras');

  // Decoded once per image and shared by every material that names it. A
  // model with forty primitives over one atlas decodes the atlas once; doing
  // it per material would decode a 4096x4096 PNG forty times.
  final Map<int, MeshTexture?> textureCache = <int, MeshTexture?>{};
  MeshTexture? textureAt(int index) => textureCache.putIfAbsent(index, () {
        final List<Object?> textures = _list(gltf['textures']);
        if (index < 0 || index >= textures.length) return null;
        final Object? texture = textures[index];
        if (texture is! Map<String, Object?>) return null;
        final Object? sourceIndex = texture['source'];
        if (sourceIndex is! num) {
          // A texture with no source is an extension's - `EXT_texture_webp`
          // and friends put theirs under `extensions`. Named rather than
          // guessed at.
          unsupported.add('texture extensions');
          return null;
        }
        final List<Object?> images = _list(gltf['images']);
        final int at = sourceIndex.toInt();
        if (at < 0 || at >= images.length) return null;
        final Object? image = images[at];
        if (image is! Map<String, Object?>) return null;

        final Uint8List? bytes = _gltfImageBytes(
          image,
          bufferViews: bufferViews,
          buffers: buffers,
          resolveBuffer: resolveBuffer,
          unsupported: unsupported,
        );
        if (bytes == null) return null;
        final MeshTexture? decoded =
            decodeMeshTexture(bytes, name: image['name'] as String? ?? '');
        if (decoded == null) unsupported.add('textures');
        return decoded;
      });

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
            textureAt: textureAt,
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
  required MeshTexture? Function(int index) textureAt,
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

  // `TEXCOORD_0` only. A mesh with a second UV set uses it for a lightmap or
  // an occlusion map, neither of which is shaded here, so reading it would
  // cost memory for something nothing samples.
  Float32List? uvs;
  final Object? uvIndex = attributes['TEXCOORD_0'];
  if (uvIndex is num) {
    uvs = _gltfAccessorFloats(
      uvIndex.toInt(),
      accessors: accessors,
      bufferViews: bufferViews,
      buffers: buffers,
      components: 2,
    );
  }
  if (attributes.containsKey('TEXCOORD_1')) {
    unsupported.add('a second UV set');
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
    uvs: uvs,
    material: _gltfMaterial(
      primitive['material'],
      materials,
      unsupported,
      textureAt,
    ),
  );
}

/// The encoded bytes of one glTF image, from wherever it lives.
///
/// Three places, and a GLB uses the first: a `bufferView` into the binary
/// chunk, a base64 `data:` URI, or a file beside the document.
Uint8List? _gltfImageBytes(
  Map<String, Object?> image, {
  required List<Object?> bufferViews,
  required List<Uint8List> buffers,
  required GltfBufferResolver? resolveBuffer,
  required Set<String> unsupported,
}) {
  final Object? viewIndex = image['bufferView'];
  if (viewIndex is num) {
    final int at = viewIndex.toInt();
    if (at < 0 || at >= bufferViews.length) return null;
    final Object? view = bufferViews[at];
    if (view is! Map<String, Object?>) return null;
    final int bufferIndex = (view['buffer'] as num?)?.toInt() ?? -1;
    if (bufferIndex < 0 || bufferIndex >= buffers.length) return null;
    final Uint8List buffer = buffers[bufferIndex];
    final int offset = (view['byteOffset'] as num?)?.toInt() ?? 0;
    final int length = (view['byteLength'] as num?)?.toInt() ?? 0;
    if (offset + length > buffer.length) return null;
    return Uint8List.sublistView(buffer, offset, offset + length);
  }

  final Object? uri = image['uri'];
  if (uri is! String) return null;
  if (uri.startsWith('data:')) {
    final int comma = uri.indexOf(',');
    if (comma < 0 || !uri.substring(0, comma).contains(';base64')) return null;
    return base64Decode(uri.substring(comma + 1));
  }
  final Uint8List? resolved = resolveBuffer?.call(uri);
  if (resolved == null || resolved.isEmpty) {
    unsupported.add('external textures');
    return null;
  }
  return resolved;
}

MeshMaterial _gltfMaterial(
  Object? index,
  List<Object?> materials,
  Set<String> unsupported,
  MeshTexture? Function(int index) textureAt,
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
  MeshTexture? texture;
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
    final Object? map = pbr['baseColorTexture'];
    if (map is Map<String, Object?>) {
      final Object? textureIndex = map['index'];
      if (textureIndex is num) texture = textureAt(textureIndex.toInt());
      final Object? uvSet = map['texCoord'];
      if (uvSet is num && uvSet.toInt() != 0) {
        unsupported.add('a second UV set');
      }
    }
  }
  if (raw.containsKey('normalTexture')) unsupported.add('normal maps');
  if (raw.containsKey('emissiveTexture')) unsupported.add('emissive maps');
  return MeshMaterial(
    name: raw['name'] as String? ?? '',
    colorArgb: colorArgb,
    metallic: metallic,
    roughness: roughness,
    doubleSided: raw['doubleSided'] == true,
    baseColorTexture: texture,
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
