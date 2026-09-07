/// Reading Autodesk FBX: the binary node tree, its geometry, its materials and
/// its skinned animation.
///
/// FBX has no specification. What follows was written against three.js's
/// `FBXLoader.js`, which is the accumulated record of every quirk that real
/// exporters produce, and against the files on the machine this was developed
/// on. Where this disagrees with that loader it is a bug here, not a
/// simplification, unless a comment says otherwise.
///
/// ## The three things that make FBX readers wrong rather than broken
///
/// **Vertices are `d`, not `f`.** FBX writes positions as *double* arrays. A
/// reader that assumes `Float32List` either throws on the cast or - if it
/// reinterprets the bytes - reads half of each double as a float and produces
/// a cloud of denormals that still has a plausible triangle count.
///
/// **`PolygonVertexIndex` masks the last index of every polygon** by bitwise
/// negation. `~i` is how the file says "this polygon ends here", so `-3` means
/// vertex 2. An index used before it is unmasked is a negative array subscript
/// or, worse, a wrong-but-positive one after a triangulation loop has already
/// mixed masked and unmasked values. Everything here unmasks at the point of
/// reading and never again.
///
/// **A node's rotation is not `Lcl Rotation`.** It is `PreRotation`, then
/// `Lcl Rotation` in the order named by `RotationOrder`, then the inverse of
/// `PostRotation`, all of it around `RotationPivot` and offset by
/// `RotationOffset`, with scaling having its own pivot and offset. Dropping
/// the pivots is what makes an arm rotate about the shoulder of the model
/// rather than its own, which looks like a skinning bug and is not one.
///
/// ## What is deliberately not here
///
/// ASCII FBX, NURBS geometry, blend shapes, cameras, lights and vertex colours
/// are refused by name into [Mesh3D.unsupported] rather than half-read. So are
/// layer-element mappings this does not implement: reading `ByPolygon` normals
/// as if they were `ByPolygonVertex` produces a model that renders, with its
/// shading silently taken from the wrong face.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../image/image_errors.dart';
import '../image/inflate.dart';
import 'mesh3d.dart';
import 'mesh_loaders.dart' show GltfBufferResolver, decodeMeshTexture;

/// The 23-byte binary preamble: `Kaydara FBX Binary  ` and three bytes that
/// every writer emits identically.
const String _binaryMagic = 'Kaydara FBX Binary';

/// One tick of FBX time. Times are stored as 64-bit integers in this unit so
/// that every frame rate anyone uses divides it exactly.
const double _fbxTicksPerSecond = 46186158000;

/// A ceiling on one decompressed property array, so that a corrupt length
/// field fails with a message rather than by exhausting memory.
const int _maxArrayBytes = 512 * 1024 * 1024;

/// Whether [bytes] begin with the binary FBX preamble.
bool looksLikeBinaryFbx(Uint8List bytes) {
  if (bytes.length < _binaryMagic.length) return false;
  for (var i = 0; i < _binaryMagic.length; i++) {
    if (bytes[i] != _binaryMagic.codeUnitAt(i)) return false;
  }
  return true;
}

/// Whether [text] is the ASCII flavour of FBX.
///
/// Worth detecting only so that it can be refused by name: without this the
/// sniffer in `loadMesh` falls through to the OBJ reader, which finds no `v`
/// lines and returns an empty model rather than an error.
bool looksLikeAsciiFbx(String text) {
  final String head = text.length > 2048 ? text.substring(0, 2048) : text;
  return head.contains('FBXHeaderExtension') ||
      (head.contains('FBXVersion') && head.contains('Objects'));
}

/// The raw node tree of a binary FBX.
///
/// Exposed because FBX is a format where "the model is wrong" and "the file
/// says something this reader did not expect" are the same symptom, and the
/// only way to tell them apart is to look at the records. A probe printing the
/// tree answers in seconds what stepping through the builder answers in an
/// afternoon.
List<FbxNode> parseFbxNodes(Uint8List bytes) => _FbxDocument.parse(bytes).roots;

/// Reads a binary FBX.
Mesh3D loadFbx(
  Uint8List bytes, {
  String name = 'model',
  GltfBufferResolver? resolveBuffer,
}) {
  if (!looksLikeBinaryFbx(bytes)) {
    throw const MeshParseException(
      'this is not a binary FBX',
      detail: 'the file does not begin with "Kaydara FBX Binary"; ASCII FBX '
          'is not read',
    );
  }
  final _FbxDocument document = _FbxDocument.parse(bytes);
  return _FbxBuilder(
    document,
    name: name,
    resolveBuffer: resolveBuffer,
  ).build();
}

// ---------------------------------------------------------------------------
// The node tree
// ---------------------------------------------------------------------------

/// One record of the FBX node tree: a name, a flat property list and children.
///
/// Kept as a tree rather than flattened into maps the way three.js does it.
/// The flattening there exists to make the ASCII and binary parsers produce the
/// same shape, and it loses ordering - which matters, because a geometry's
/// several `LayerElementUV` records are distinguished by nothing else.
final class FbxNode {
  FbxNode(this.name, this.properties, this.children);

  final String name;

  /// The record's own properties, in file order. The first three are by
  /// convention the object's id, its name and its subtype, for the records
  /// under `Objects`.
  final List<Object?> properties;

  final List<FbxNode> children;

  FbxNode? child(String name) {
    for (final FbxNode node in children) {
      if (node.name == name) return node;
    }
    return null;
  }

  Iterable<FbxNode> childrenNamed(String name) =>
      children.where((FbxNode node) => node.name == name);

  /// The object id, which is property zero of every record under `Objects`.
  int get id => properties.isNotEmpty && properties[0] is int
      ? properties[0]! as int
      : -1;

  /// The object's name, which FBX writes as `name\x00\x01Class`.
  String get attrName {
    if (properties.length < 2) return '';
    final Object? raw = properties[1];
    if (raw is! String) return '';
    final int end = raw.indexOf('\u0000');
    if (end >= 0) return raw.substring(0, end);
    // FBX 6 wrote `Model::Cube` where FBX 7 writes the name, a NUL and the
    // class. Both name the same object, and a viewer listing "Model::Cube"
    // is showing the format rather than the model.
    final int colons = raw.indexOf('::');
    return colons < 0 ? raw : raw.substring(colons + 2);
  }

  /// The object's subtype: `Mesh`, `LimbNode`, `Skin`, `Cluster`.
  String get attrType => properties.length > 2 && properties[2] is String
      ? properties[2]! as String
      : '';

  /// The single property of a value record, which is how FBX writes both
  /// `Vertices: *8000 { a: ... }` and `MappingInformationType: "Direct"`.
  Object? get value => properties.isEmpty ? null : properties[0];

  /// The `Properties70` block as a map from property name to its value list.
  ///
  /// A `P` record is `name, type, subtype, flags` followed by the value, and a
  /// vector property carries three values where a scalar carries one. Both are
  /// returned as a list so that the caller does not have to know which it is
  /// before it looks - `Lcl Scaling` and `Visibility` sit in the same block.
  Map<String, List<Object?>> get properties70 {
    final Map<String, List<Object?>> out = <String, List<Object?>>{};
    final FbxNode? block = child('Properties70') ?? child('Properties60');
    if (block == null) return out;
    for (final FbxNode entry in block.children) {
      if (entry.name != 'P' && entry.name != 'Property') continue;
      if (entry.properties.isEmpty) continue;
      final Object? key = entry.properties[0];
      if (key is! String) continue;
      out[key] = entry.properties.length > 4
          ? entry.properties.sublist(4)
          : const <Object?>[];
    }
    return out;
  }
}

/// The parsed file: the root records plus the indexes everything else needs.
final class _FbxDocument {
  _FbxDocument(this.version, this.roots);

  factory _FbxDocument.parse(Uint8List bytes) {
    final _FbxReader reader = _FbxReader(bytes);
    reader.skip(23);
    final int version = reader.uint32();
    if (version < 6400) {
      throw MeshParseException(
        'this FBX is too old to read',
        detail: 'version $version predates 6400, whose node layout is '
            'different again',
      );
    }
    final List<FbxNode> roots = <FbxNode>[];
    while (!_endOfContent(reader)) {
      final FbxNode? node = _parseNode(reader, version);
      if (node == null) break;
      roots.add(node);
    }
    return _FbxDocument(version, roots);
  }

  final int version;
  final List<FbxNode> roots;

  FbxNode? root(String name) {
    for (final FbxNode node in roots) {
      if (node.name == name) return node;
    }
    return null;
  }
}

/// Whether the reader has reached the 160-byte footer.
///
/// Ported from three.js, footnote and all: the footer is 16 bytes of magic,
/// padding to a 16-byte boundary, then 144 more, and exporters disagree about
/// the padding by a byte. Reading past it produces one garbage record with an
/// enormous end offset, which then swallows the rest of the file.
bool _endOfContent(_FbxReader reader) {
  if (reader.length % 16 == 0) {
    return ((reader.offset + 160 + 16) & ~0xF) >= reader.length;
  }
  return reader.offset + 160 + 16 >= reader.length;
}

/// Reads one record and everything nested inside it.
///
/// The header widened at version 7500: the three offsets are 32-bit below it
/// and 64-bit at or above it. Getting this wrong does not fail immediately -
/// it reads a plausible node name from the middle of an offset - which is why
/// the version is threaded down here rather than sniffed.
FbxNode? _parseNode(_FbxReader reader, int version) {
  final bool wide = version >= 7500;
  final int endOffset = wide ? reader.uint64() : reader.uint32();
  final int propertyCount = wide ? reader.uint64() : reader.uint32();
  wide ? reader.uint64() : reader.uint32(); // property list length, unused
  final int nameLength = reader.uint8();
  final String name = reader.string(nameLength);

  // The null record that terminates a nested list. Its whole content is the
  // zero end offset, and the bytes already consumed are exactly its length.
  if (endOffset == 0) return null;

  final List<Object?> properties = <Object?>[];
  for (var i = 0; i < propertyCount; i++) {
    properties.add(_parseProperty(reader));
  }

  final List<FbxNode> children = <FbxNode>[];
  while (reader.offset + 13 <= endOffset && reader.offset < reader.length) {
    final FbxNode? child = _parseNode(reader, version);
    if (child == null) break;
    children.add(child);
  }
  // Seek to the declared end rather than trusting the walk. Some writers leave
  // a byte of padding after the last child, and a reader that carries on from
  // where it happens to be starts the next sibling one byte late.
  if (endOffset > reader.offset && endOffset <= reader.length) {
    reader.offset = endOffset;
  }
  return FbxNode(name, properties, children);
}

/// Reads one property value.
///
/// The type letters are `YCIFDLSR` for scalars and `bcdfil` for arrays. An
/// array carries its own encoding flag, and encoding 1 means the payload is a
/// zlib stream - which is the normal case for anything large, so a reader that
/// only handles encoding 0 opens the tiny files and none of the real ones.
Object? _parseProperty(_FbxReader reader) {
  final int type = reader.uint8();
  switch (type) {
    case 0x59: // Y
      return reader.int16();
    case 0x43: // C
      return reader.uint8() & 1 == 1;
    case 0x49: // I
      return reader.int32();
    case 0x46: // F
      return reader.float32();
    case 0x44: // D
      return reader.float64();
    case 0x4C: // L
      return reader.int64();
    case 0x52: // R
      return reader.raw(reader.uint32());
    case 0x53: // S
      return reader.string(reader.uint32());
    case 0x62: // b
    case 0x63: // c
    case 0x64: // d
    case 0x66: // f
    case 0x69: // i
    case 0x6C: // l
      return _parseArray(reader, type);
    default:
      throw MeshParseException(
        'unknown FBX property type',
        detail: 'byte 0x${type.toRadixString(16)} at offset '
            '${reader.offset - 1}',
      );
  }
}

Object? _parseArray(_FbxReader reader, int type) {
  final int count = reader.uint32();
  final int encoding = reader.uint32();
  final int compressedLength = reader.uint32();
  final int stride = switch (type) {
    0x62 || 0x63 => 1,
    0x66 || 0x69 => 4,
    _ => 8,
  };
  if (count < 0 || count * stride > _maxArrayBytes) {
    throw MeshParseException(
      'an FBX array declares an impossible length',
      detail: '$count elements of $stride bytes',
    );
  }

  _FbxReader source;
  if (encoding == 0) {
    source = reader;
  } else if (encoding == 1) {
    final Uint8List compressed = reader.raw(compressedLength);
    final Uint8List inflated;
    try {
      // The exact decompressed size is known from the element count, so the
      // budget is the true size rather than a guess. `dart:io`'s zlib is not
      // an option: `graphics` may not import it, and the layering test says so.
      inflated = inflateZlib(
        compressed,
        maxOutputBytes: count * stride,
        budget: 'fbx array',
      );
    } on InflateException catch (error) {
      throw MeshParseException(
        'an FBX property array is not a valid zlib stream',
        detail: '$error',
      );
    } on ImageBudgetException catch (error) {
      throw MeshParseException(
        'an FBX property array decompresses to more than it declares',
        detail: '$error',
      );
    }
    source = _FbxReader(inflated);
  } else {
    throw MeshParseException(
      'an FBX array uses an encoding this reader does not know',
      detail: 'encoding $encoding; 0 is raw and 1 is zlib',
    );
  }

  switch (type) {
    case 0x62:
    case 0x63:
      final Uint8List out = Uint8List(count);
      for (var i = 0; i < count; i++) {
        out[i] = source.uint8() & 1;
      }
      return out;
    case 0x66:
      final Float32List out = Float32List(count);
      for (var i = 0; i < count; i++) {
        out[i] = source.float32();
      }
      return out;
    case 0x69:
      final Int32List out = Int32List(count);
      for (var i = 0; i < count; i++) {
        out[i] = source.int32();
      }
      return out;
    case 0x6C:
      final Int64List out = Int64List(count);
      for (var i = 0; i < count; i++) {
        out[i] = source.int64();
      }
      return out;
    default:
      final Float64List out = Float64List(count);
      for (var i = 0; i < count; i++) {
        out[i] = source.float64();
      }
      return out;
  }
}

/// A cursor over bytes.
///
/// Every read goes through [ByteData] rather than through a typed-data view.
/// A view would be faster, but FBX puts an array of doubles wherever it lands
/// and `Float64List.sublistView` throws on an offset that is not a multiple of
/// eight - which describes most of them.
final class _FbxReader {
  _FbxReader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  int offset = 0;

  int get length => bytes.length;

  void skip(int count) => offset += count;

  int uint8() => bytes[offset++];

  int int16() {
    final int value = data.getInt16(offset, Endian.little);
    offset += 2;
    return value;
  }

  int int32() {
    final int value = data.getInt32(offset, Endian.little);
    offset += 4;
    return value;
  }

  int uint32() {
    final int value = data.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  int int64() {
    final int value = data.getInt64(offset, Endian.little);
    offset += 8;
    return value;
  }

  /// A 64-bit length, read as a signed integer because Dart's int is 64-bit
  /// and a genuine unsigned value that large is a corrupt file either way.
  int uint64() => int64();

  double float32() {
    final double value = data.getFloat32(offset, Endian.little);
    offset += 4;
    return value;
  }

  double float64() {
    final double value = data.getFloat64(offset, Endian.little);
    offset += 8;
    return value;
  }

  Uint8List raw(int count) {
    final int end = offset + count;
    if (count < 0 || end > bytes.length) {
      throw MeshParseException(
        'an FBX record runs past the end of the file',
        detail: '$count bytes at offset $offset of ${bytes.length}',
      );
    }
    final Uint8List out = Uint8List.sublistView(bytes, offset, end);
    offset = end;
    return out;
  }

  /// A length-prefixed string.
  ///
  /// FBX writes an object's name as `name\x00\x01Class`, so the bytes after
  /// the first NUL are part of the record and are kept here; [FbxNode.attrName]
  /// is what trims them. Latin-1 rather than UTF-8 because the encoding is not
  /// declared and a malformed sequence must not lose the name.
  String string(int count) {
    final Uint8List slice = raw(count);
    return latin1.decode(slice, allowInvalid: true);
  }
}

// ---------------------------------------------------------------------------
// Small numeric helpers over property values
// ---------------------------------------------------------------------------

Float64List _asDoubles(Object? value) {
  if (value is Float64List) return value;
  if (value is Float32List) return Float64List.fromList(value);
  if (value is Int32List || value is Int64List) {
    final List<int> ints = value! as List<int>;
    final Float64List out = Float64List(ints.length);
    for (var i = 0; i < ints.length; i++) {
      out[i] = ints[i].toDouble();
    }
    return out;
  }
  return Float64List(0);
}

Int32List _asInts(Object? value) {
  if (value is Int32List) return value;
  if (value is Int64List) {
    final Int32List out = Int32List(value.length);
    for (var i = 0; i < value.length; i++) {
      out[i] = value[i];
    }
    return out;
  }
  if (value is Float64List || value is Float32List) {
    final List<double> doubles = value! as List<double>;
    final Int32List out = Int32List(doubles.length);
    for (var i = 0; i < doubles.length; i++) {
      out[i] = doubles[i].round();
    }
    return out;
  }
  return Int32List(0);
}

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return fallback;
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is double) return value.round();
  return fallback;
}

/// The first three numbers of a `Properties70` vector, or null when the
/// property is absent.
Vector3? _vector(Map<String, List<Object?>> properties, String key) {
  final List<Object?>? values = properties[key];
  if (values == null || values.length < 3) return null;
  return Vector3(
    _asDouble(values[0]),
    _asDouble(values[1]),
    _asDouble(values[2]),
  );
}

// ---------------------------------------------------------------------------
// Matrix and rotation helpers
// ---------------------------------------------------------------------------

const double _degrees = math.pi / 180;

/// FBX `RotationOrder` values as the axis sequence they name.
///
/// The file writes an enum and the enum is *extrinsic*: order 0 is "rotate
/// about X, then about the original Y, then about the original Z", which is
/// the same rotation as applying Z, then Y, then X intrinsically - hence the
/// reversal in this table. Reading the enum as intrinsic swaps the first and
/// last axis of every rotated node, which is invisible on a node rotated about
/// one axis and obvious on any other.
const List<String> _rotationOrders = <String>[
  'ZYX', // EulerXYZ
  'YZX', // EulerXZY
  'XZY', // EulerYZX
  'ZXY', // EulerYXZ
  'YXZ', // EulerZXY
  'XYZ', // EulerZYX
];

String _rotationOrder(int value) => value >= 0 && value < _rotationOrders.length
    ? _rotationOrders[value]
    : _rotationOrders[0];

Matrix4 _rotationAbout(String axis, double radians) {
  final double c = math.cos(radians);
  final double s = math.sin(radians);
  switch (axis) {
    case 'X':
      return Matrix4(Float64List.fromList(<double>[
        1, 0, 0, 0, //
        0, c, s, 0, //
        0, -s, c, 0, //
        0, 0, 0, 1, //
      ]));
    case 'Y':
      return Matrix4(Float64List.fromList(<double>[
        c, 0, -s, 0, //
        0, 1, 0, 0, //
        s, 0, c, 0, //
        0, 0, 0, 1, //
      ]));
    default:
      return Matrix4(Float64List.fromList(<double>[
        c, s, 0, 0, //
        -s, c, 0, 0, //
        0, 0, 1, 0, //
        0, 0, 0, 1, //
      ]));
  }
}

/// The rotation named by [degrees] applied in [order].
///
/// Composed axis by axis rather than written out as one closed form per order.
/// The closed forms are six blocks of nine trigonometric products each and a
/// transposed sign in any of them is a model that is subtly reflected; this is
/// slower and can be checked by reading it.
Matrix4 _eulerMatrix(Vector3 degrees, String order) {
  final Map<String, double> radians = <String, double>{
    'X': degrees.x * _degrees,
    'Y': degrees.y * _degrees,
    'Z': degrees.z * _degrees,
  };
  var out = Matrix4.identity();
  for (var i = 0; i < order.length; i++) {
    final String axis = order[i];
    out = out.multiply(_rotationAbout(axis, radians[axis]!));
  }
  return out;
}

/// The unit quaternion `(x, y, z, w)` of a rotation matrix.
///
/// Shepperd's method: the branch picks whichever of the four components is
/// largest, because the direct formula divides by one of them and a rotation
/// of exactly 180 degrees makes `w` zero.
Float32List _quaternionFromMatrix(Matrix4 matrix) {
  final Float64List m = matrix.storage;
  // Column-major: m[0], m[4], m[8] is the first row.
  final double m00 = m[0], m01 = m[4], m02 = m[8];
  final double m10 = m[1], m11 = m[5], m12 = m[9];
  final double m20 = m[2], m21 = m[6], m22 = m[10];
  final double trace = m00 + m11 + m22;
  double x, y, z, w;
  if (trace > 0) {
    final double s = 0.5 / math.sqrt(trace + 1);
    w = 0.25 / s;
    x = (m21 - m12) * s;
    y = (m02 - m20) * s;
    z = (m10 - m01) * s;
  } else if (m00 > m11 && m00 > m22) {
    final double s = 2 * math.sqrt(1 + m00 - m11 - m22);
    w = (m21 - m12) / s;
    x = 0.25 * s;
    y = (m01 + m10) / s;
    z = (m02 + m20) / s;
  } else if (m11 > m22) {
    final double s = 2 * math.sqrt(1 + m11 - m00 - m22);
    w = (m02 - m20) / s;
    x = (m01 + m10) / s;
    y = 0.25 * s;
    z = (m12 + m21) / s;
  } else {
    final double s = 2 * math.sqrt(1 + m22 - m00 - m11);
    w = (m10 - m01) / s;
    x = (m02 + m20) / s;
    y = (m12 + m21) / s;
    z = 0.25 * s;
  }
  final double length = math.sqrt(x * x + y * y + z * z + w * w);
  if (length == 0) return Float32List.fromList(<double>[0, 0, 0, 1]);
  return Float32List.fromList(
    <double>[x / length, y / length, z / length, w / length],
  );
}

/// The lengths of the three basis columns, which is the scale a transform
/// applies along each of its own axes.
Vector3 _scaleOf(Matrix4 matrix) {
  final Float64List m = matrix.storage;
  return Vector3(
    math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]),
    math.sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]),
    math.sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]),
  );
}

/// The rotation part alone: the basis columns divided by their lengths.
Matrix4 _rotationOf(Matrix4 matrix) {
  final Float64List m = matrix.storage;
  final Vector3 scale = _scaleOf(matrix);
  final double sx = scale.x == 0 ? 0 : 1 / scale.x;
  final double sy = scale.y == 0 ? 0 : 1 / scale.y;
  final double sz = scale.z == 0 ? 0 : 1 / scale.z;
  return Matrix4(Float64List.fromList(<double>[
    m[0] * sx, m[1] * sx, m[2] * sx, 0, //
    m[4] * sy, m[5] * sy, m[6] * sy, 0, //
    m[8] * sz, m[9] * sz, m[10] * sz, 0, //
    0, 0, 0, 1, //
  ]));
}

/// The translation alone, as a matrix.
Matrix4 _translationOf(Matrix4 matrix) {
  final Float64List m = matrix.storage;
  return Matrix4.translation(Vector3(m[12], m[13], m[14]));
}

Vector3 _positionOf(Matrix4 matrix) =>
    Vector3(matrix.storage[12], matrix.storage[13], matrix.storage[14]);

/// The inverse transpose of the upper 3x3, which is what a normal must be
/// carried through.
///
/// A normal pushed through the vertex matrix is wrong the moment the scale is
/// not uniform: squash a sphere along Y and its normals must stretch along Y,
/// not squash. Every model exported in centimetres and scaled to metres by one
/// axis at a time hits this.
Matrix4 _normalMatrix(Matrix4 matrix) {
  final Float64List m = matrix.inverted.storage;
  return Matrix4(Float64List.fromList(<double>[
    m[0], m[4], m[8], 0, //
    m[1], m[5], m[9], 0, //
    m[2], m[6], m[10], 0, //
    0, 0, 0, 1, //
  ]));
}

/// Everything a node's transform is built from.
final class _TransformData {
  Vector3? translation;
  Vector3? rotation;
  Vector3? scale;
  Vector3? preRotation;
  Vector3? postRotation;
  Vector3? rotationOffset;
  Vector3? rotationPivot;
  Vector3? scalingOffset;
  Vector3? scalingPivot;
  String eulerOrder = _rotationOrders[0];
  int inheritType = 0;
  Matrix4? parentLocal;
  Matrix4? parentWorld;
}

/// The local matrix of a node, composed the way the FBX SDK composes it.
///
/// A direct port of three.js's `generateTransform`, which is itself a port of
/// Autodesk's `transformations` sample. The order is not negotiable and it is
/// not the obvious one: the rotation happens about `RotationPivot` after
/// `RotationOffset` has moved it, the scaling has its own pivot and offset, and
/// the whole thing is then re-expressed relative to the parent because
/// `InheritType` decides whether the parent's scale reaches the child's
/// rotation. A composition that merely multiplies T, R and S is right for every
/// model whose author never touched a pivot and wrong for every one who did.
Matrix4 _generateTransform(_TransformData data) {
  final Matrix4 translationM = data.translation == null
      ? Matrix4.identity()
      : Matrix4.translation(data.translation!);
  // Pre- and post-rotation always use order 0, even when the node names
  // another: Maya writes its "Joint Orient" into PreRotation and the euler
  // order applies to Lcl Rotation alone.
  final Matrix4 preRotationM = data.preRotation == null
      ? Matrix4.identity()
      : _eulerMatrix(data.preRotation!, _rotationOrders[0]);
  final Matrix4 rotationM = data.rotation == null
      ? Matrix4.identity()
      : _eulerMatrix(data.rotation!, data.eulerOrder);
  final Matrix4 postRotationM = data.postRotation == null
      ? Matrix4.identity()
      : _eulerMatrix(data.postRotation!, _rotationOrders[0]).inverted;
  final Matrix4 scalingM =
      data.scale == null ? Matrix4.identity() : Matrix4.scale(data.scale!);
  final Matrix4 scalingOffsetM = data.scalingOffset == null
      ? Matrix4.identity()
      : Matrix4.translation(data.scalingOffset!);
  final Matrix4 scalingPivotM = data.scalingPivot == null
      ? Matrix4.identity()
      : Matrix4.translation(data.scalingPivot!);
  final Matrix4 rotationOffsetM = data.rotationOffset == null
      ? Matrix4.identity()
      : Matrix4.translation(data.rotationOffset!);
  final Matrix4 rotationPivotM = data.rotationPivot == null
      ? Matrix4.identity()
      : Matrix4.translation(data.rotationPivot!);

  final Matrix4 parentWorld = data.parentWorld ?? Matrix4.identity();
  final Matrix4 parentLocal = data.parentLocal ?? Matrix4.identity();

  final Matrix4 localRotation =
      preRotationM.multiply(rotationM).multiply(postRotationM);
  final Matrix4 parentGlobalRotation = _rotationOf(parentWorld);
  final Matrix4 parentTranslation = _translationOf(parentWorld);
  final Matrix4 parentGlobalRotationScale =
      parentTranslation.inverted.multiply(parentWorld);
  final Matrix4 parentGlobalScale =
      parentGlobalRotation.inverted.multiply(parentGlobalRotationScale);

  final Matrix4 globalRotationScale;
  switch (data.inheritType) {
    case 1:
      globalRotationScale = parentGlobalRotation
          .multiply(parentGlobalScale)
          .multiply(localRotation)
          .multiply(scalingM);
    case 2:
      final Matrix4 parentLocalScale = Matrix4.scale(_scaleOf(parentLocal));
      globalRotationScale = parentGlobalRotation
          .multiply(localRotation)
          .multiply(parentGlobalScale.multiply(parentLocalScale.inverted))
          .multiply(scalingM);
    default:
      globalRotationScale = parentGlobalRotation
          .multiply(localRotation)
          .multiply(parentGlobalScale)
          .multiply(scalingM);
  }

  final Matrix4 local = translationM
      .multiply(rotationOffsetM)
      .multiply(rotationPivotM)
      .multiply(preRotationM)
      .multiply(rotationM)
      .multiply(postRotationM)
      .multiply(rotationPivotM.inverted)
      .multiply(scalingOffsetM)
      .multiply(scalingPivotM)
      .multiply(scalingM)
      .multiply(scalingPivotM.inverted);

  final Matrix4 globalTranslation =
      _translationOf(parentWorld.multiply(_translationOf(local)));
  return parentWorld.inverted
      .multiply(globalTranslation.multiply(globalRotationScale));
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

/// One end of a connection: the object at the other end, and the property it
/// was connected to for an `OP` link.
final class _Link {
  const _Link(this.id, this.property);

  final int id;

  /// The property name of an object-property connection - `DiffuseColor`,
  /// `Lcl Translation`, `d|X` - or null for a plain object-object one.
  final String? property;
}

/// The connection graph, in both directions.
///
/// Both directions because FBX uses the same table to say "this texture is the
/// diffuse map of that material" and "that material belongs to this model",
/// and the two are read from opposite ends.
final class _Connections {
  final Map<int, List<_Link>> childrenOf = <int, List<_Link>>{};
  final Map<int, List<_Link>> parentsOf = <int, List<_Link>>{};

  void add(int from, int to, String? property) {
    (childrenOf[to] ??= <_Link>[]).add(_Link(from, property));
    (parentsOf[from] ??= <_Link>[]).add(_Link(to, property));
  }

  List<_Link> children(int id) => childrenOf[id] ?? const <_Link>[];
  List<_Link> parents(int id) => parentsOf[id] ?? const <_Link>[];
}

// ---------------------------------------------------------------------------
// Layer elements
// ---------------------------------------------------------------------------

/// A per-vertex, per-corner, per-polygon or per-mesh attribute, plus the two
/// enums that say how to index it.
final class _LayerElement {
  const _LayerElement({
    required this.componentCount,
    required this.buffer,
    required this.indices,
    required this.mapping,
    required this.reference,
  });

  final int componentCount;
  final Float64List buffer;
  final Int32List indices;
  final String mapping;
  final String reference;

  /// Whether the two enums together are a combination this reads correctly.
  bool get isSupported =>
      const <String>{
        'ByPolygonVertex',
        'ByPolygon',
        'ByVertice',
        'ByVertex',
        'AllSame',
        'AllByPolygon',
      }.contains(mapping) &&
      const <String>{'Direct', 'IndexToDirect', 'Index'}.contains(reference);

  /// The offset into [buffer] of the value for one polygon corner, or -1 when
  /// the indexing runs off the end.
  ///
  /// The crossing of the two enums is where most FBX readers go wrong, because
  /// every combination produces a plausible number. `ByVertice` indexed with a
  /// corner number reads a real normal belonging to a different vertex, and
  /// the model is shaded smoothly and incorrectly.
  int offsetFor(int polygonVertexIndex, int polygonIndex, int vertexIndex) {
    int index;
    switch (mapping) {
      case 'ByPolygonVertex':
        index = polygonVertexIndex;
      case 'ByPolygon':
      case 'AllByPolygon':
        index = polygonIndex;
      case 'ByVertice':
      case 'ByVertex':
        index = vertexIndex;
      case 'AllSame':
        index = indices.isEmpty ? 0 : indices[0];
      default:
        return -1;
    }
    if (reference == 'IndexToDirect' || reference == 'Index') {
      if (index < 0 || index >= indices.length) return -1;
      index = indices[index];
    }
    if (index < 0) return -1;
    final int from = index * componentCount;
    if (from + componentCount > buffer.length) return -1;
    return from;
  }
}

/// The per-polygon material index layer.
///
/// Read separately from every other layer element because its
/// `ReferenceInformationType` lies: files say `IndexToDirect` and then write no
/// index array at all, because `Materials` already holds one material number
/// per polygon. Honouring the declared reference type means a second lookup
/// through a table that is not there, and every polygon falls back to material
/// zero - a multi-material model arrives as one primitive wearing whichever
/// material came first.
_LayerElement? _readMaterialElement(FbxNode? layer) {
  if (layer == null) return null;
  final String mapping =
      layer.child('MappingInformationType')?.value as String? ?? '';
  // `NoMappingInformation` means the file declined to say, which is the same
  // as one material for the whole mesh.
  if (mapping == 'NoMappingInformation') return null;
  final FbxNode? data = layer.child('Materials');
  if (data == null) return null;
  return _LayerElement(
    componentCount: 1,
    buffer: _asDoubles(data.value),
    indices: Int32List(0),
    mapping: mapping,
    reference: 'Direct',
  );
}

_LayerElement? _readLayerElement(
  FbxNode? layer, {
  required String dataName,
  required String indexName,
  required int componentCount,
}) {
  if (layer == null) return null;
  final FbxNode? data = layer.child(dataName);
  if (data == null) return null;
  return _LayerElement(
    componentCount: componentCount,
    buffer: _asDoubles(data.value),
    indices: _asInts(layer.child(indexName)?.value),
    mapping: layer.child('MappingInformationType')?.value as String? ?? '',
    reference: layer.child('ReferenceInformationType')?.value as String? ?? '',
  );
}

// ---------------------------------------------------------------------------
// The build
// ---------------------------------------------------------------------------

/// One vertex-per-corner accumulator for a single material.
final class _PrimitiveBuilder {
  _PrimitiveBuilder(this.material);

  final MeshMaterial material;
  final List<double> positions = <double>[];
  final List<double> normals = <double>[];
  final List<double> uvs = <double>[];
  final List<int> jointIndices = <int>[];
  final List<double> jointWeights = <double>[];
  bool hasNormals = true;
  bool hasUvs = true;
}

/// A joint's weights while they are being gathered, before the four largest
/// are chosen.
final class _VertexWeights {
  final List<int> joints = <int>[];
  final List<double> weights = <double>[];
}

final class _FbxBuilder {
  _FbxBuilder(this.document, {required this.name, this.resolveBuffer});

  final _FbxDocument document;
  final String name;
  final GltfBufferResolver? resolveBuffer;

  final Set<String> unsupported = <String>{};
  final _Connections connections = _Connections();

  /// Every record under `Objects`, by id.
  final Map<int, FbxNode> objects = <int, FbxNode>{};

  /// The same records grouped by their record name: `Model`, `Geometry`.
  final Map<String, List<FbxNode>> objectsByClass = <String, List<FbxNode>>{};

  /// Model id to index in [nodes], filled by [_buildNodes].
  final Map<int, int> nodeIndexOf = <int, int>{};
  final List<MeshNode> nodes = <MeshNode>[];
  final List<Matrix4> nodeWorld = <Matrix4>[];
  final List<Matrix4> nodeLocal = <Matrix4>[];

  /// Node index to the `_TransformData` it was built from, which the
  /// animation pass needs for the euler order and the pre/post rotations.
  final Map<int, _TransformData> transformDataOf = <int, _TransformData>{};

  final List<MeshSkin> skins = <MeshSkin>[];

  /// Geometry id to the index in [skins] of the skin that deforms it.
  final Map<int, int> skinOfGeometry = <int, int>{};

  final Map<int, MeshTexture?> textureCache = <int, MeshTexture?>{};

  Mesh3D build() {
    _index();
    _readConnections();
    _buildNodes();
    _buildSkins();

    final List<MeshPrimitive> primitives = <MeshPrimitive>[];
    for (final FbxNode model in objectsByClass['Model'] ?? const <FbxNode>[]) {
      if (model.attrType != 'Mesh') continue;
      final int? index = nodeIndexOf[model.id];
      if (index == null) continue;
      for (final _Link link in connections.children(model.id)) {
        final FbxNode? geometry = objects[link.id];
        if (geometry == null || geometry.name != 'Geometry') continue;
        if (geometry.attrType == 'NurbsCurve' ||
            geometry.attrType == 'NurbsSurface') {
          unsupported.add('NURBS geometry');
          continue;
        }
        if (geometry.attrType != 'Mesh') continue;
        primitives.addAll(
          _buildGeometry(geometry, model, nodeWorld[index]),
        );
      }
    }

    _noteUnsupportedObjects();

    if (primitives.isEmpty) {
      throw const MeshParseException(
        'the FBX holds no drawable mesh',
        detail: 'it may contain only cameras, lights or NURBS curves, or its '
            'geometry may not be connected to any model',
      );
    }

    final List<MeshAnimation> animations = _buildAnimations();

    return Mesh3D(
      name: name,
      format: 'fbx',
      primitives: primitives,
      unsupported: unsupported,
      nodes: nodes,
      skins: skins,
      animations: animations,
    );
  }

  void _index() {
    final FbxNode? root = document.root('Objects');
    if (root == null) {
      throw const MeshParseException(
        'the FBX has no Objects section',
        detail: 'the node tree parsed but holds nothing to draw',
      );
    }
    for (final FbxNode node in root.children) {
      final int id = node.id;
      if (id >= 0) objects[id] = node;
      (objectsByClass[node.name] ??= <FbxNode>[]).add(node);
    }
  }

  void _readConnections() {
    final FbxNode? root = document.root('Connections');
    if (root == null) return;
    for (final FbxNode entry in root.childrenNamed('C')) {
      if (entry.properties.length < 3) continue;
      final Object? kind = entry.properties[0];
      final int from = _asInt(entry.properties[1], -1);
      final int to = _asInt(entry.properties[2], -1);
      if (from < 0 && to < 0) continue;
      final String? property = kind == 'OP' && entry.properties.length > 3
          ? entry.properties[3] as String?
          : null;
      connections.add(from, to, property);
    }
  }

  // -------------------------------------------------------------------------
  // Nodes
  // -------------------------------------------------------------------------

  /// Builds the transform hierarchy, parents before children.
  ///
  /// A single synthetic root is always prepended. It carries the up-axis
  /// correction when the file is Z-up, and having it unconditionally means the
  /// skin's bind matrices are composed the same way whether or not the
  /// correction is the identity - a conditional root is exactly the sort of
  /// thing that works on the files it was written against.
  void _buildNodes() {
    final List<FbxNode> models = objectsByClass['Model'] ?? const <FbxNode>[];

    final Map<int, List<int>> childrenOfModel = <int, List<int>>{};
    final Set<int> modelIds = <int>{for (final FbxNode m in models) m.id};
    final Set<int> hasParent = <int>{};
    for (final FbxNode model in models) {
      for (final _Link link in connections.parents(model.id)) {
        if (link.property != null) continue;
        if (!modelIds.contains(link.id)) continue;
        (childrenOfModel[link.id] ??= <int>[]).add(model.id);
        hasParent.add(model.id);
        break;
      }
    }

    final Matrix4 rootMatrix = _upAxisCorrection();
    nodes.add(MeshNode(
      name: '(scene)',
      parent: -1,
      restLocal: rootMatrix,
      restTranslation: _positionOf(rootMatrix),
      restRotation: _quaternionFromMatrix(_rotationOf(rootMatrix)),
      restScale: _scaleOf(rootMatrix),
    ));
    nodeLocal.add(rootMatrix);
    nodeWorld.add(rootMatrix);

    final Set<int> visited = <int>{};
    void visit(int id, int parentIndex) {
      if (!visited.add(id)) return;
      final FbxNode? model = objects[id];
      if (model == null) return;
      final _TransformData data = _transformDataFor(model);
      data.parentLocal = nodeLocal[parentIndex];
      data.parentWorld = nodeWorld[parentIndex];
      final Matrix4 local = _generateTransform(data);
      final Matrix4 world = nodeWorld[parentIndex].multiply(local);
      final int index = nodes.length;
      nodeIndexOf[id] = index;
      transformDataOf[index] = data;
      nodes.add(MeshNode(
        name: model.attrName,
        parent: parentIndex,
        restLocal: local,
        restTranslation: _positionOf(local),
        restRotation: _quaternionFromMatrix(_rotationOf(local)),
        restScale: _scaleOf(local),
      ));
      nodeLocal.add(local);
      nodeWorld.add(world);
      for (final int child in childrenOfModel[id] ?? const <int>[]) {
        visit(child, index);
      }
    }

    for (final FbxNode model in models) {
      if (hasParent.contains(model.id)) continue;
      visit(model.id, 0);
    }
    // A model whose parent chain forms a cycle is never reached above. FBX
    // does not forbid one and at least one exporter writes them; attaching the
    // remainder to the root keeps its geometry rather than dropping it.
    for (final FbxNode model in models) {
      if (visited.contains(model.id)) continue;
      unsupported.add('a cycle in the model hierarchy');
      visit(model.id, 0);
    }
  }

  _TransformData _transformDataFor(FbxNode model) {
    final Map<String, List<Object?>> properties = model.properties70;
    final _TransformData data = _TransformData();
    final List<Object?>? order = properties['RotationOrder'];
    data.eulerOrder = _rotationOrder(
      order == null || order.isEmpty ? 0 : _asInt(order[0]),
    );
    final List<Object?>? inherit = properties['InheritType'];
    if (inherit != null && inherit.isNotEmpty) {
      data.inheritType = _asInt(inherit[0]);
    }
    data.translation = _vector(properties, 'Lcl Translation');
    data.rotation = _vector(properties, 'Lcl Rotation');
    data.scale = _vector(properties, 'Lcl Scaling');
    data.preRotation = _vector(properties, 'PreRotation');
    data.postRotation = _vector(properties, 'PostRotation');
    data.rotationOffset = _vector(properties, 'RotationOffset');
    data.rotationPivot = _vector(properties, 'RotationPivot');
    data.scalingOffset = _vector(properties, 'ScalingOffset');
    data.scalingPivot = _vector(properties, 'ScalingPivot');
    return data;
  }

  /// The rotation that brings a Z-up file into the Y-up space everything
  /// downstream assumes.
  ///
  /// Without it a model authored in a Z-up tool lies on its face, and the
  /// bounding box that a viewer frames the camera from has its height in the
  /// depth axis. `UnitScaleFactor` is deliberately *not* applied: it would
  /// make an FBX in centimetres and the same model in glTF disagree by a
  /// hundred, and every other loader here keeps the file's units.
  Matrix4 _upAxisCorrection() {
    final FbxNode? settings = document.root('GlobalSettings');
    if (settings == null) return Matrix4.identity();
    final List<Object?>? upAxis = settings.properties70['UpAxis'];
    if (upAxis == null || upAxis.isEmpty) return Matrix4.identity();
    if (_asInt(upAxis[0]) != 2) return Matrix4.identity();
    unsupported.add('a Z-up file, rotated into Y-up rather than converted');
    return _rotationAbout('X', -math.pi / 2);
  }

  // -------------------------------------------------------------------------
  // Skins
  // -------------------------------------------------------------------------

  /// Reads every `Skin` deformer into a [MeshSkin].
  ///
  /// The inverse bind matrix comes from the **node hierarchy's rest pose**, not
  /// from the cluster's `TransformLink`. The two are meant to be the same, and
  /// when they are it makes no difference; when they are not, taking the
  /// hierarchy guarantees that posing at the rest pose is exactly the identity,
  /// so a model with an inconsistent bind pose renders correctly until it is
  /// animated instead of being visibly torn apart before it moves. The
  /// disagreement is measured below and named, because it is the thing to
  /// suspect first if a posed model looks wrong.
  void _buildSkins() {
    for (final FbxNode deformer
        in objectsByClass['Deformer'] ?? const <FbxNode>[]) {
      if (deformer.attrType == 'BlendShape') {
        unsupported.add('blend shapes');
        continue;
      }
      if (deformer.attrType != 'Skin') continue;

      final List<int> jointNodes = <int>[];
      final List<Matrix4> inverseBind = <Matrix4>[];
      final List<FbxNode> clusters = <FbxNode>[];
      var worstMismatch = 0.0;

      for (final _Link link in connections.children(deformer.id)) {
        final FbxNode? cluster = objects[link.id];
        if (cluster == null || cluster.attrType != 'Cluster') continue;
        int? boneNode;
        for (final _Link boneLink in connections.children(cluster.id)) {
          final int? index = nodeIndexOf[boneLink.id];
          if (index != null) {
            boneNode = index;
            break;
          }
        }
        if (boneNode == null) continue;
        clusters.add(cluster);
        jointNodes.add(boneNode);
        inverseBind.add(nodeWorld[boneNode].inverted);

        final Float64List link0 =
            _asDoubles(cluster.child('TransformLink')?.value);
        if (link0.length == 16) {
          worstMismatch = math.max(
            worstMismatch,
            _relativeDifference(nodeWorld[boneNode], Matrix4(link0)),
          );
        }
      }
      if (jointNodes.isEmpty) continue;

      if (worstMismatch > 1e-3) {
        unsupported.add(
          'a bind pose whose TransformLink disagrees with the node hierarchy '
          '(by ${worstMismatch.toStringAsFixed(3)}); the hierarchy was used',
        );
      }

      final int skinIndex = skins.length;
      skins.add(MeshSkin(
        name: deformer.attrName,
        jointNodes: Int32List.fromList(jointNodes),
        inverseBind: inverseBind,
      ));
      _clustersOfSkin[skinIndex] = clusters;
      for (final _Link parent in connections.parents(deformer.id)) {
        final FbxNode? geometry = objects[parent.id];
        if (geometry != null && geometry.name == 'Geometry') {
          skinOfGeometry[parent.id] = skinIndex;
        }
      }
    }
  }

  final Map<int, List<FbxNode>> _clustersOfSkin = <int, List<FbxNode>>{};

  /// How far two transforms are apart, relative to the size of the larger.
  double _relativeDifference(Matrix4 a, Matrix4 b) {
    var difference = 0.0;
    var magnitude = 0.0;
    for (var i = 0; i < 16; i++) {
      difference = math.max(difference, (a.storage[i] - b.storage[i]).abs());
      magnitude = math.max(magnitude, a.storage[i].abs());
    }
    return magnitude == 0 ? difference : difference / magnitude;
  }

  // -------------------------------------------------------------------------
  // Geometry
  // -------------------------------------------------------------------------

  List<MeshPrimitive> _buildGeometry(
    FbxNode geometry,
    FbxNode model,
    Matrix4 world,
  ) {
    final Float64List vertices = _asDoubles(geometry.child('Vertices')?.value);
    final Int32List polygonIndices =
        _asInts(geometry.child('PolygonVertexIndex')?.value);
    if (vertices.isEmpty || polygonIndices.isEmpty) {
      return const <MeshPrimitive>[];
    }

    if (geometry.childrenNamed('LayerElementColor').isNotEmpty) {
      unsupported.add('vertex colours');
    }
    if (geometry.childrenNamed('LayerElementUV').length > 1) {
      unsupported.add('a second UV set');
    }

    _LayerElement? normals = _readLayerElement(
      geometry.childrenNamed('LayerElementNormal').firstOrNull,
      dataName: 'Normals',
      indexName: 'NormalsIndex',
      componentCount: 3,
    );
    _LayerElement? uvs = _readLayerElement(
      geometry.childrenNamed('LayerElementUV').firstOrNull,
      dataName: 'UV',
      indexName: 'UVIndex',
      componentCount: 2,
    );
    _LayerElement? materialIndices = _readMaterialElement(
      geometry.childrenNamed('LayerElementMaterial').firstOrNull,
    );
    // A layer whose mapping this reader does not implement is dropped whole
    // rather than read with the nearest rule that fits. The model then has no
    // normals, which a viewer can see and say so about; read wrongly it has
    // normals that are subtly from the wrong face and nothing says anything.
    if (normals != null && !normals.isSupported) {
      unsupported.add(
        'normals mapped ${normals.mapping}/${normals.reference}',
      );
      normals = null;
    }
    if (uvs != null && !uvs.isSupported) {
      unsupported.add('UVs mapped ${uvs.mapping}/${uvs.reference}');
      uvs = null;
    }
    if (materialIndices != null && !materialIndices.isSupported) {
      unsupported.add(
        'material indices mapped '
        '${materialIndices.mapping}/${materialIndices.reference}',
      );
      materialIndices = null;
    }

    final List<MeshMaterial> materials = _materialsOf(model);
    final Matrix4 preTransform = _geometricTransform(model);
    final Matrix4 vertexMatrix = world.multiply(preTransform);
    final Matrix4 normalMatrix = _normalMatrix(vertexMatrix);

    final int? skinIndex = skinOfGeometry[geometry.id];
    final Map<int, _VertexWeights> weightTable = skinIndex == null
        ? const <int, _VertexWeights>{}
        : _weightTable(skinIndex);

    final Map<int, _PrimitiveBuilder> builders = <int, _PrimitiveBuilder>{};
    _PrimitiveBuilder builderFor(int material) => builders.putIfAbsent(
          material,
          () => _PrimitiveBuilder(
            material >= 0 && material < materials.length
                ? materials[material]
                : (materials.isNotEmpty
                    ? materials.first
                    : const MeshMaterial()),
          ),
        );

    // One polygon at a time. The corner indices are collected until the file
    // marks the last one, then the polygon is fanned into triangles.
    final List<int> faceVertex = <int>[];
    final List<int> faceCorner = <int>[];
    var polygonIndex = 0;
    var sawLargeNgon = false;
    var negativeMaterial = false;

    for (var corner = 0; corner < polygonIndices.length; corner++) {
      final int raw = polygonIndices[corner];
      final bool endOfFace = raw < 0;
      // The unmasking, and the only place it happens. `~raw` and `raw ^ -1`
      // are the same operation; the file marks the polygon's last corner by
      // negating it, so an index used before this line is off by one and
      // negative.
      final int vertexIndex = endOfFace ? ~raw : raw;
      faceVertex.add(vertexIndex);
      faceCorner.add(corner);
      if (!endOfFace) continue;

      final int faceLength = faceVertex.length;
      if (faceLength > 4) sawLargeNgon = true;
      if (faceLength >= 3) {
        var material = 0;
        if (materialIndices != null && materialIndices.mapping != 'AllSame') {
          final int at = materialIndices.offsetFor(
            faceCorner[0],
            polygonIndex,
            faceVertex[0],
          );
          if (at >= 0) material = materialIndices.buffer[at].round();
          if (material < 0) {
            negativeMaterial = true;
            material = 0;
          }
        }
        final _PrimitiveBuilder builder = builderFor(material);

        // A fan from the first corner. Correct for a triangle and for any
        // convex polygon, which is what exporters write; a concave n-gon
        // triangulated this way grows a sliver outside its own outline, and
        // that is named below rather than left to be discovered.
        for (var k = 1; k + 1 < faceLength; k++) {
          for (final int local in <int>[0, k, k + 1]) {
            _emitCorner(
              builder,
              vertices: vertices,
              vertexIndex: faceVertex[local],
              corner: faceCorner[local],
              polygonIndex: polygonIndex,
              normals: normals,
              uvs: uvs,
              vertexMatrix: vertexMatrix,
              normalMatrix: normalMatrix,
              weightTable: weightTable,
            );
          }
        }
      }
      polygonIndex++;
      faceVertex.clear();
      faceCorner.clear();
    }

    if (sawLargeNgon) {
      unsupported.add(
        'polygons with more than four sides, fan-triangulated rather than '
        'earclipped',
      );
    }
    if (negativeMaterial) {
      unsupported.add('negative material indices, replaced with the first');
    }

    final List<MeshPrimitive> out = <MeshPrimitive>[];
    for (final _PrimitiveBuilder builder in builders.values) {
      if (builder.positions.isEmpty) continue;
      final int count = builder.positions.length ~/ 3;
      final Uint32List indices = Uint32List(count);
      for (var i = 0; i < count; i++) {
        indices[i] = i;
      }
      out.add(MeshPrimitive(
        positions: Float32List.fromList(builder.positions),
        indices: indices,
        normals: builder.hasNormals && builder.normals.length == count * 3
            ? Float32List.fromList(builder.normals)
            : null,
        uvs: builder.hasUvs && builder.uvs.length == count * 2
            ? Float32List.fromList(builder.uvs)
            : null,
        material: builder.material,
        jointIndices: skinIndex == null
            ? null
            : Uint16List.fromList(builder.jointIndices),
        jointWeights: skinIndex == null
            ? null
            : Float32List.fromList(builder.jointWeights),
        skin: skinIndex ?? -1,
      ));
    }
    return out;
  }

  void _emitCorner(
    _PrimitiveBuilder builder, {
    required Float64List vertices,
    required int vertexIndex,
    required int corner,
    required int polygonIndex,
    required _LayerElement? normals,
    required _LayerElement? uvs,
    required Matrix4 vertexMatrix,
    required Matrix4 normalMatrix,
    required Map<int, _VertexWeights> weightTable,
  }) {
    final int p = vertexIndex * 3;
    if (p + 2 >= vertices.length) {
      // A corner pointing past the end of the position array. One malformed
      // polygon must not cost the whole model, so it becomes a degenerate
      // triangle at the origin rather than an exception.
      builder.positions.addAll(<double>[0, 0, 0]);
    } else {
      final Vector3 position = vertexMatrix.transformPoint(
        Vector3(vertices[p], vertices[p + 1], vertices[p + 2]),
      );
      builder.positions.addAll(<double>[position.x, position.y, position.z]);
    }

    if (normals == null) {
      builder.hasNormals = false;
    } else {
      final int at = normals.offsetFor(corner, polygonIndex, vertexIndex);
      if (at < 0) {
        builder.hasNormals = false;
      } else {
        final Vector3 normal = normalMatrix
            .transformDirection(Vector3(
              normals.buffer[at],
              normals.buffer[at + 1],
              normals.buffer[at + 2],
            ))
            .normalized;
        builder.normals.addAll(<double>[normal.x, normal.y, normal.z]);
      }
    }

    if (uvs == null) {
      builder.hasUvs = false;
    } else {
      final int at = uvs.offsetFor(corner, polygonIndex, vertexIndex);
      if (at < 0) {
        builder.hasUvs = false;
      } else {
        // FBX puts the texture origin at the bottom left and everything
        // downstream of these loaders uses glTF's top left, so v is flipped
        // here for the same reason the OBJ reader flips it.
        builder.uvs.addAll(<double>[uvs.buffer[at], 1 - uvs.buffer[at + 1]]);
      }
    }

    if (weightTable.isNotEmpty || builder.jointWeights.isNotEmpty) {
      _emitWeights(builder, weightTable[vertexIndex]);
    }
  }

  /// Writes the four largest weights of one vertex.
  ///
  /// The four *largest*, not the first four the file lists. A Mixamo character
  /// has vertices touched by six or seven clusters and the file does not sort
  /// them; keeping the first four leaves a shoulder weighted to the spine and
  /// the fingers, and the arm shears when the spine turns.
  void _emitWeights(_PrimitiveBuilder builder, _VertexWeights? weights) {
    final List<int> joints = <int>[0, 0, 0, 0];
    final List<double> values = <double>[0, 0, 0, 0];
    if (weights != null) {
      for (var i = 0; i < weights.joints.length; i++) {
        final double weight = weights.weights[i];
        var carriedJoint = weights.joints[i];
        var carriedWeight = weight;
        for (var slot = 0; slot < 4; slot++) {
          if (carriedWeight > values[slot]) {
            final double heldWeight = values[slot];
            final int heldJoint = joints[slot];
            values[slot] = carriedWeight;
            joints[slot] = carriedJoint;
            carriedWeight = heldWeight;
            carriedJoint = heldJoint;
          }
        }
      }
    }
    var total = 0.0;
    for (final double value in values) {
      total += value;
    }
    // Renormalised so the four sum to one. Dropping the fifth weight without
    // this shrinks the vertex towards the origin by whatever fraction was
    // thrown away, which on a hand reads as the fingers melting.
    if (total > 0) {
      for (var i = 0; i < 4; i++) {
        values[i] /= total;
      }
    }
    builder.jointIndices.addAll(joints);
    builder.jointWeights.addAll(values);
  }

  /// Vertex index to the clusters that claim it, for one skin.
  Map<int, _VertexWeights> _weightTable(int skinIndex) {
    final Map<int, _VertexWeights> table = <int, _VertexWeights>{};
    final List<FbxNode> clusters =
        _clustersOfSkin[skinIndex] ?? const <FbxNode>[];
    for (var slot = 0; slot < clusters.length; slot++) {
      final FbxNode cluster = clusters[slot];
      final Int32List indices = _asInts(cluster.child('Indexes')?.value);
      final Float64List weights = _asDoubles(cluster.child('Weights')?.value);
      final int count = math.min(indices.length, weights.length);
      for (var i = 0; i < count; i++) {
        if (weights[i] == 0) continue;
        (table[indices[i]] ??= _VertexWeights())
          ..joints.add(slot)
          ..weights.add(weights[i]);
      }
    }
    return table;
  }

  /// The `Geometric*` transform, which offsets a mesh from its own node.
  ///
  /// Separate from the node's transform and not inherited by children: it is
  /// how a 3ds Max exporter records that the mesh was moved without moving its
  /// pivot. Applying it to the node instead moves the node's children too.
  Matrix4 _geometricTransform(FbxNode model) {
    final Map<String, List<Object?>> properties = model.properties70;
    final Vector3? translation = _vector(properties, 'GeometricTranslation');
    final Vector3? rotation = _vector(properties, 'GeometricRotation');
    final Vector3? scale = _vector(properties, 'GeometricScaling');
    if (translation == null && rotation == null && scale == null) {
      return Matrix4.identity();
    }
    final _TransformData data = _TransformData()
      ..translation = translation
      ..rotation = rotation
      ..scale = scale;
    final List<Object?>? order = properties['RotationOrder'];
    data.eulerOrder = _rotationOrder(
      order == null || order.isEmpty ? 0 : _asInt(order[0]),
    );
    return _generateTransform(data);
  }

  // -------------------------------------------------------------------------
  // Materials and textures
  // -------------------------------------------------------------------------

  /// The materials of one model, in the order `LayerElementMaterial` indexes
  /// them.
  List<MeshMaterial> _materialsOf(FbxNode model) {
    final List<MeshMaterial> out = <MeshMaterial>[];
    for (final _Link link in connections.children(model.id)) {
      final FbxNode? node = objects[link.id];
      if (node == null || node.name != 'Material') continue;
      out.add(_material(node));
    }
    return out;
  }

  MeshMaterial _material(FbxNode node) {
    final Map<String, List<Object?>> properties = node.properties70;
    // `Diffuse` is what the FBX SDK writes and `DiffuseColor` is what the
    // Blender exporter writes; a reader that knows only one of them gives half
    // the models in the world a default grey.
    final Vector3 colour = _vector(properties, 'Diffuse') ??
        _vector(properties, 'DiffuseColor') ??
        const Vector3(0.8, 0.8, 0.8);
    final double shininess =
        _asDouble(properties['Shininess']?.firstOrNull, 20);

    MeshTexture? baseColor;
    for (final _Link link in connections.children(node.id)) {
      final FbxNode? child = objects[link.id];
      if (child == null || child.name != 'Texture') continue;
      switch (link.property) {
        case 'DiffuseColor':
        case 'Maya|TEX_color_map':
        case 'Maya|baseColor':
          baseColor ??= _texture(child);
        case 'NormalMap':
        case 'Bump':
          unsupported.add('normal maps');
        case 'EmissiveColor':
          unsupported.add('emissive maps');
        case 'SpecularColor':
          unsupported.add('specular maps');
        case null:
          // An unlabelled texture connection, which older exporters write for
          // the diffuse map. Taken as the base colour only when nothing
          // labelled has claimed the slot.
          baseColor ??= _texture(child);
      }
    }

    return MeshMaterial(
      name: node.attrName,
      colorArgb: 0xFF000000 |
          ((colour.x.clamp(0.0, 1.0) * 255).round() << 16) |
          ((colour.y.clamp(0.0, 1.0) * 255).round() << 8) |
          (colour.z.clamp(0.0, 1.0) * 255).round(),
      // FBX writes Phong shininess, which is not roughness. The conversion is
      // the usual approximation and is here so that a Phong material does not
      // arrive with this repository's default roughness regardless of what the
      // file said.
      roughness:
          shininess <= 0 ? 1 : math.sqrt(2 / (shininess + 2)).clamp(0.0, 1.0),
      baseColorTexture: baseColor,
    );
  }

  /// The image behind a `Texture` node: its `Video`, whose `Content` is the
  /// file's own bytes when the FBX is self-contained.
  MeshTexture? _texture(FbxNode texture) {
    final MeshTexture? cached = textureCache[texture.id];
    if (cached != null) return cached;
    if (textureCache.containsKey(texture.id)) return null;
    textureCache[texture.id] = null;

    for (final _Link link in connections.children(texture.id)) {
      final FbxNode? video = objects[link.id];
      if (video == null || video.name != 'Video') continue;
      final String file = _fileNameOf(video).isNotEmpty
          ? _fileNameOf(video)
          : _fileNameOf(texture);

      final Object? content = video.child('Content')?.value;
      if (content is Uint8List && content.isNotEmpty) {
        final MeshTexture? decoded = decodeMeshTexture(content, name: file);
        if (decoded == null) {
          unsupported.add('an embedded texture in a format with no codec here');
        }
        textureCache[texture.id] = decoded;
        return decoded;
      }

      if (file.isEmpty) continue;
      final Uint8List? bytes = resolveBuffer?.call(file);
      if (bytes == null) {
        unsupported.add('the texture "$file" was not found');
        continue;
      }
      final MeshTexture? decoded = decodeMeshTexture(bytes, name: file);
      if (decoded == null) unsupported.add('textures');
      textureCache[texture.id] = decoded;
      return decoded;
    }
    return null;
  }

  /// The bare file name of a `Video` or `Texture` node.
  ///
  /// `RelativeFilename` first because `FileName` is the absolute path on the
  /// machine that exported the model, and it names a drive that does not exist
  /// here. Both are split on backslash *and* forward slash: the separator in
  /// the file is whichever the exporting tool used, and this reader must not
  /// care which machine that was.
  String _fileNameOf(FbxNode node) {
    for (final String key in const <String>[
      'RelativeFilename',
      'FileName',
      'Filename',
      'Path',
    ]) {
      final Object? value = node.child(key)?.value;
      if (value is! String || value.isEmpty) continue;
      var text = value;
      final int slash = math.max(text.lastIndexOf('/'), text.lastIndexOf(r'\'));
      if (slash >= 0) text = text.substring(slash + 1);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  void _noteUnsupportedObjects() {
    for (final FbxNode node in objectsByClass['Model'] ?? const <FbxNode>[]) {
      switch (node.attrType) {
        case 'Camera':
          unsupported.add('cameras');
        case 'Light':
          unsupported.add('lights');
      }
    }
    if ((objectsByClass['Constraint'] ?? const <FbxNode>[]).isNotEmpty) {
      unsupported.add('constraints');
    }
  }

  // -------------------------------------------------------------------------
  // Animation
  // -------------------------------------------------------------------------

  List<MeshAnimation> _buildAnimations() {
    final List<FbxNode> stacks =
        objectsByClass['AnimationStack'] ?? const <FbxNode>[];
    if (stacks.isEmpty) return const <MeshAnimation>[];

    final Map<int, _CurveNode> curveNodes = _readCurveNodes();
    if (curveNodes.isEmpty) return const <MeshAnimation>[];

    final List<MeshAnimation> out = <MeshAnimation>[];
    for (final FbxNode stack in stacks) {
      final List<MeshAnimationChannel> channels = <MeshAnimationChannel>[];
      var layerCount = 0;
      for (final _Link layerLink in connections.children(stack.id)) {
        final FbxNode? layer = objects[layerLink.id];
        if (layer == null || layer.name != 'AnimationLayer') continue;
        layerCount++;
        // One layer per stack in every file anyone writes. A second layer is
        // an additive blend with its own weight curve, and reading it as if it
        // replaced the first would produce a pose belonging to neither.
        if (layerCount > 1) {
          unsupported.add('additive animation layers beyond the first');
          continue;
        }
        channels.addAll(_channelsOfLayer(layer, curveNodes));
      }
      if (channels.isEmpty) continue;
      var duration = 0.0;
      for (final MeshAnimationChannel channel in channels) {
        if (channel.times.isNotEmpty) {
          duration = math.max(duration, channel.times.last);
        }
      }
      out.add(MeshAnimation(
        name: stack.attrName,
        channels: channels,
        duration: duration,
      ));
    }
    return out;
  }

  /// Every `AnimationCurveNode` with its per-axis curves attached.
  Map<int, _CurveNode> _readCurveNodes() {
    final Map<int, _CurveNode> out = <int, _CurveNode>{};
    for (final FbxNode node
        in objectsByClass['AnimationCurveNode'] ?? const <FbxNode>[]) {
      out[node.id] = _CurveNode(node.attrName);
    }
    for (final FbxNode curve
        in objectsByClass['AnimationCurve'] ?? const <FbxNode>[]) {
      final Object? keyTime = curve.child('KeyTime')?.value;
      final Float64List values =
          _asDoubles(curve.child('KeyValueFloat')?.value);
      if (keyTime is! Int64List || values.isEmpty) {
        // The times are int64 ticks. A file that wrote them as anything else
        // is one this reader has never seen, and guessing the unit would put
        // the whole take on the wrong clock.
        if (keyTime != null) {
          unsupported.add('animation curve times that are not int64 ticks');
        }
        continue;
      }
      final Float32List times = Float32List(keyTime.length);
      for (var i = 0; i < keyTime.length; i++) {
        times[i] = keyTime[i] / _fbxTicksPerSecond;
      }
      for (final _Link parent in connections.parents(curve.id)) {
        final _CurveNode? owner = out[parent.id];
        if (owner == null) continue;
        final String property = parent.property ?? '';
        if (property.endsWith('X')) {
          owner.x = _Curve(times, values);
        } else if (property.endsWith('Y')) {
          owner.y = _Curve(times, values);
        } else if (property.endsWith('Z')) {
          owner.z = _Curve(times, values);
        } else if (property.contains('DeformPercent')) {
          unsupported.add('blend shape animation');
        }
        break;
      }
    }
    return out;
  }

  List<MeshAnimationChannel> _channelsOfLayer(
    FbxNode layer,
    Map<int, _CurveNode> curveNodes,
  ) {
    final List<MeshAnimationChannel> out = <MeshAnimationChannel>[];
    for (final _Link link in connections.children(layer.id)) {
      final _CurveNode? curveNode = curveNodes[link.id];
      if (curveNode == null || !curveNode.hasCurves) continue;

      int? node;
      String? property;
      for (final _Link parent in connections.parents(link.id)) {
        if (parent.property == null) continue;
        final int? index = nodeIndexOf[parent.id];
        if (index == null) continue;
        node = index;
        property = parent.property;
        break;
      }
      if (node == null) continue;

      final _TransformData? data = transformDataOf[node];
      final MeshChannelPath? path = switch (property) {
        'Lcl Translation' => MeshChannelPath.translation,
        'Lcl Rotation' => MeshChannelPath.rotation,
        'Lcl Scaling' => MeshChannelPath.scale,
        _ => null,
      };
      if (path == null) {
        // A curve driving something other than the three transform channels -
        // a material colour, a camera's field of view, a visibility flag.
        unsupported.add('animated "${property ?? curveNode.attr}"');
        continue;
      }

      final MeshNode meshNode = nodes[node];
      final Float32List times = curveNode.mergedTimes();
      if (times.isEmpty) continue;

      if (path == MeshChannelPath.rotation) {
        out.add(_rotationChannel(node, curveNode, times, data));
      } else {
        final Vector3 rest = path == MeshChannelPath.translation
            ? meshNode.restTranslation
            : meshNode.restScale;
        final Float32List values = Float32List(times.length * 3);
        for (var i = 0; i < times.length; i++) {
          values[i * 3] = curveNode.x?.sample(times[i]) ?? rest.x;
          values[i * 3 + 1] = curveNode.y?.sample(times[i]) ?? rest.y;
          values[i * 3 + 2] = curveNode.z?.sample(times[i]) ?? rest.z;
        }
        out.add(MeshAnimationChannel(
          node: node,
          path: path,
          times: times,
          values: values,
        ));
      }
    }
    return out;
  }

  /// A rotation channel, as quaternions.
  ///
  /// The euler angles in the file are only the middle of the node's rotation:
  /// `PreRotation` comes before them and the inverse of `PostRotation` after,
  /// exactly as in the rest pose. A channel that ignores them animates a joint
  /// about the wrong axes, which on a Mixamo skeleton is every joint, because
  /// the whole bind orientation lives in `PreRotation`.
  MeshAnimationChannel _rotationChannel(
    int node,
    _CurveNode curves,
    Float32List times,
    _TransformData? data,
  ) {
    final String order = data?.eulerOrder ?? _rotationOrders[0];
    final Matrix4 pre = data?.preRotation == null
        ? Matrix4.identity()
        : _eulerMatrix(data!.preRotation!, _rotationOrders[0]);
    final Matrix4 post = data?.postRotation == null
        ? Matrix4.identity()
        : _eulerMatrix(data!.postRotation!, _rotationOrders[0]).inverted;
    final Vector3 restDegrees = data?.rotation ?? Vector3.zero;

    // Sample the three axes onto one time line first, because a step of more
    // than half a turn between two keys has to be subdivided in *euler* space:
    // interpolating the quaternions instead takes the short way round, which
    // is the opposite of what a 270-degree key pair means.
    final List<double> keyTimes = <double>[];
    final List<double> keyAngles = <double>[];
    for (var i = 0; i < times.length; i++) {
      final double x = curves.x?.sample(times[i]) ?? restDegrees.x;
      final double y = curves.y?.sample(times[i]) ?? restDegrees.y;
      final double z = curves.z?.sample(times[i]) ?? restDegrees.z;
      if (i > 0) {
        final double dx = (x - keyAngles[keyAngles.length - 3]).abs();
        final double dy = (y - keyAngles[keyAngles.length - 2]).abs();
        final double dz = (z - keyAngles[keyAngles.length - 1]).abs();
        final double largest = math.max(dx, math.max(dy, dz));
        if (largest >= 180) {
          final int steps = (largest / 180).ceil();
          final double t0 = keyTimes.last;
          final double x0 = keyAngles[keyAngles.length - 3];
          final double y0 = keyAngles[keyAngles.length - 2];
          final double z0 = keyAngles[keyAngles.length - 1];
          for (var s = 1; s < steps; s++) {
            final double f = s / steps;
            keyTimes.add(t0 + (times[i] - t0) * f);
            keyAngles.addAll(<double>[
              x0 + (x - x0) * f,
              y0 + (y - y0) * f,
              z0 + (z - z0) * f,
            ]);
          }
        }
      }
      keyTimes.add(times[i]);
      keyAngles.addAll(<double>[x, y, z]);
    }

    final Float32List values = Float32List(keyTimes.length * 4);
    for (var i = 0; i < keyTimes.length; i++) {
      final Matrix4 rotation = pre
          .multiply(_eulerMatrix(
            Vector3(
                keyAngles[i * 3], keyAngles[i * 3 + 1], keyAngles[i * 3 + 2]),
            order,
          ))
          .multiply(post);
      var q = _quaternionFromMatrix(rotation);
      if (i > 0) {
        final int previous = (i - 1) * 4;
        final double dot = values[previous] * q[0] +
            values[previous + 1] * q[1] +
            values[previous + 2] * q[2] +
            values[previous + 3] * q[3];
        // A quaternion and its negation name the same orientation, and the
        // sign flips freely as the angles cross a boundary. Left alone, the
        // interpolator between two keys of opposite sign spins the joint all
        // the way round between two frames.
        if (dot < 0) {
          q = Float32List.fromList(<double>[-q[0], -q[1], -q[2], -q[3]]);
        }
      }
      values[i * 4] = q[0];
      values[i * 4 + 1] = q[1];
      values[i * 4 + 2] = q[2];
      values[i * 4 + 3] = q[3];
    }

    return MeshAnimationChannel(
      node: node,
      path: MeshChannelPath.rotation,
      times: Float32List.fromList(keyTimes),
      values: values,
    );
  }
}

/// One axis of one animated property.
final class _Curve {
  const _Curve(this.times, this.values);

  final Float32List times;
  final Float64List values;

  /// The value at [time], linearly interpolated.
  ///
  /// FBX curves carry tangents and an interpolation mode per key - cubic,
  /// constant, TCB. Everything here is read as linear, which is exact for the
  /// per-frame keys a motion-capture take is baked to and an approximation for
  /// a hand-animated curve.
  double sample(double time) {
    if (times.isEmpty || values.isEmpty) return 0;
    if (time <= times[0]) return values[0];
    final int last = times.length - 1;
    if (time >= times[last]) return values[math.min(last, values.length - 1)];
    var low = 0;
    var high = last;
    while (low + 1 < high) {
      final int mid = (low + high) >> 1;
      if (times[mid] <= time) {
        low = mid;
      } else {
        high = mid;
      }
    }
    if (low + 1 >= values.length) return values[values.length - 1];
    final double span = times[low + 1] - times[low];
    if (span <= 0) return values[low];
    final double t = (time - times[low]) / span;
    return values[low] + (values[low + 1] - values[low]) * t;
  }
}

/// An `AnimationCurveNode`: up to three curves, one per axis.
final class _CurveNode {
  _CurveNode(this.attr);

  final String attr;
  _Curve? x;
  _Curve? y;
  _Curve? z;

  bool get hasCurves => x != null || y != null || z != null;

  /// The union of the three axes' key times, sorted and deduplicated.
  ///
  /// FBX gives every axis its own key list, and a joint whose X is keyed at
  /// frames 0 and 30 while its Y is keyed at 15 must be evaluated at all three.
  Float32List mergedTimes() {
    final Set<double> all = <double>{};
    for (final _Curve? curve in <_Curve?>[x, y, z]) {
      if (curve == null) continue;
      for (final double time in curve.times) {
        all.add(time);
      }
    }
    final List<double> sorted = all.toList()..sort();
    return Float32List.fromList(sorted);
  }
}
