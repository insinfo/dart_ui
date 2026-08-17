import 'dart:typed_data';

/// Parser inicial para arquivos Corel Presentation Exchange (.cmx).
class CmxParser {
  final ByteData data;

  CmxParser(this.data);

  bool isCmxFormat() {
    if (data.lengthInBytes < 4) return false;

    // RIFF check
    final r = data.getUint8(0);
    final i = data.getUint8(1);
    final f1 = data.getUint8(2);
    final f2 = data.getUint8(3);

    if (r != 82 || i != 73 || f1 != 70 || f2 != 70) return false; // "RIFF"

    if (data.lengthInBytes < 12) return false;
    // CMX1 check
    final c = data.getUint8(8);
    final m = data.getUint8(9);
    final x = data.getUint8(10);
    final one = data.getUint8(11);

    if (c == 67 && m == 77 && x == 88 && one == 49) return true; // "CMX1"

    return false;
  }
}
