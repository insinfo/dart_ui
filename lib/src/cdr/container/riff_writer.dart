/// Serializer for binary RIFF containers (CorelDRAW CDR format).

import 'dart:typed_data';

/// Builder for creating binary RIFF / CorelDRAW files.
class RiffWriter {
  /// Writes a complete RIFF container containing [subchunks].
  static Uint8List writeRiff(String formType, List<Uint8List> subchunks) {
    var totalSubSize = 4; // for formType (4 bytes)
    for (final chunk in subchunks) {
      totalSubSize += chunk.length;
      if (chunk.length % 2 != 0) {
        totalSubSize += 1; // 2-byte word padding
      }
    }

    final bb = BytesBuilder();
    // 'RIFF' header
    bb.add(Uint8List.fromList([0x52, 0x49, 0x46, 0x46]));
    // Total size (file size - 8)
    final sizeData = ByteData(4)..setUint32(0, totalSubSize, Endian.little);
    bb.add(sizeData.buffer.asUint8List());
    // Form type (e.g. 'CDR6', 'CDRA', 'CDR ')
    final formBytes = formType.padRight(4).substring(0, 4).codeUnits;
    bb.add(Uint8List.fromList(formBytes));

    // Append subchunks
    for (final chunk in subchunks) {
      bb.add(chunk);
      if (chunk.length % 2 != 0) {
        bb.addByte(0); // padding byte
      }
    }

    return bb.toBytes();
  }

  /// Writes an individual chunk: `FourCC (4 bytes) + Length (4 bytes) + Data`.
  static Uint8List writeChunk(String fourCC, Uint8List data) {
    final bb = BytesBuilder();
    final fourCCBytes = fourCC.padRight(4).substring(0, 4).codeUnits;
    bb.add(Uint8List.fromList(fourCCBytes));

    final sizeData = ByteData(4)..setUint32(0, data.length, Endian.little);
    bb.add(sizeData.buffer.asUint8List());
    bb.add(data);

    return bb.toBytes();
  }

  /// Writes a `LIST` container chunk: `'LIST' + Length + ListType (4 bytes) + Subchunks`.
  static Uint8List writeList(String listType, List<Uint8List> subchunks) {
    var totalSubSize = 4; // listType
    for (final chunk in subchunks) {
      totalSubSize += chunk.length;
      if (chunk.length % 2 != 0) {
        totalSubSize += 1;
      }
    }

    final bb = BytesBuilder();
    bb.add(Uint8List.fromList([0x4C, 0x49, 0x53, 0x54])); // 'LIST'

    final sizeData = ByteData(4)..setUint32(0, totalSubSize, Endian.little);
    bb.add(sizeData.buffer.asUint8List());

    final listTypeBytes = listType.padRight(4).substring(0, 4).codeUnits;
    bb.add(Uint8List.fromList(listTypeBytes));

    for (final chunk in subchunks) {
      bb.add(chunk);
      if (chunk.length % 2 != 0) {
        bb.addByte(0);
      }
    }

    return bb.toBytes();
  }
}
