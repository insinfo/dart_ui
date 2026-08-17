import 'dart:typed_data';
import 'pdf_filter.dart';

/// Decodificador `/LZWDecode` com suporte a tamanho de código variável (9 a 12 bits) e `EarlyChange`.
class LzwFilter implements PdfFilter {
  const LzwFilter();

  static const int clearTableCode = 256;
  static const int endOfDataCode = 257;

  @override
  Uint8List decode(Uint8List data, [DecodeParms parms = const DecodeParms()]) {
    if (data.isEmpty) return Uint8List(0);

    final earlyChange = parms.earlyChange;
    final out = <int>[];

    final table = <List<int>>[];
    void resetTable() {
      table.clear();
      for (var i = 0; i < 256; i++) {
        table.add([i]);
      }
      table.add(const []); // 256: ClearTable
      table.add(const []); // 257: EndOfData
    }

    resetTable();

    var codeLength = 9;
    var bitPos = 0;
    final totalBits = data.length * 8;

    int readCode() {
      if (bitPos + codeLength > totalBits) return endOfDataCode;
      final byteIndex = bitPos >> 3;
      final bitOffset = bitPos & 7;

      var val = 0;
      var bitsNeeded = codeLength;
      var currentByte = byteIndex;

      while (bitsNeeded > 0) {
        final bitsAvailableInByte =
            8 - (currentByte == byteIndex ? bitOffset : 0);
        final bitsToTake =
            bitsNeeded < bitsAvailableInByte ? bitsNeeded : bitsAvailableInByte;
        final shift = bitsAvailableInByte - bitsToTake;
        final mask = ((1 << bitsToTake) - 1) << shift;
        final chunk = (data[currentByte] & mask) >> shift;

        val = (val << bitsToTake) | chunk;
        bitsNeeded -= bitsToTake;
        currentByte++;
      }

      bitPos += codeLength;
      return val;
    }

    var oldCode = -1;

    while (bitPos < totalBits) {
      final code = readCode();
      if (code == endOfDataCode) break;
      if (code == clearTableCode) {
        resetTable();
        codeLength = 9;
        oldCode = -1;
        continue;
      }

      List<int> sequence;
      if (code < table.length) {
        sequence = table[code];
        if (oldCode != -1) {
          final newEntry = List<int>.from(table[oldCode])..add(sequence[0]);
          table.add(newEntry);
        }
      } else if (code == table.length && oldCode != -1) {
        final newEntry = List<int>.from(table[oldCode])..add(table[oldCode][0]);
        table.add(newEntry);
        sequence = newEntry;
      } else {
        break; // Fluxo corrompido
      }

      out.addAll(sequence);
      oldCode = code;

      var tableLimit = (1 << codeLength);
      if (earlyChange == 1) {
        tableLimit -= 1;
      }
      if (table.length >= tableLimit && codeLength < 12) {
        codeLength++;
      }
    }

    final decompressed = Uint8List.fromList(out);
    return DecodeParms.applyPredictor(decompressed, parms);
  }
}
