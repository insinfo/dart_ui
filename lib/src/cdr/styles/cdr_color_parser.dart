
import 'dart:typed_data';

import '../../graphics/color.dart';
import 'cdr_styles.dart';

/// Parses CDR color structures from raw chunk bytes.
class CdrColorParser {
  /// Parses a color descriptor from [data] at [offset].
  ///
  /// CDR v3-v5 color format (4-6 bytes):
  /// - Model (1-2 bytes): 1=CMYK, 2=RGB, 3=HLS, 4=Gray, 5=Pantone
  /// - Components: 4 bytes (CMYK) or 3 bytes (RGB)
  ///
  /// CDR v6+ color format:
  /// - Model (2 bytes uint16 LE)
  /// - Component 1..4 (uint16 or uint8 depending on version)
  static CdrColor parse(ByteData data, int offset, {int version = 6}) {
    if (offset + 4 > data.lengthInBytes) {
      return CdrColor.black;
    }

    final modelId = data.getUint8(offset);

    switch (modelId) {
      case 1: // CMYK
        if (offset + 5 <= data.lengthInBytes) {
          final c = data.getUint8(offset + 1) / 255.0;
          final m = data.getUint8(offset + 2) / 255.0;
          final y = data.getUint8(offset + 3) / 255.0;
          final k = data.getUint8(offset + 4) / 255.0;
          return CdrColor.cmyk(c, m, y, k);
        }
      case 2: // RGB
        if (offset + 4 <= data.lengthInBytes) {
          final r = data.getUint8(offset + 1);
          final g = data.getUint8(offset + 2);
          final b = data.getUint8(offset + 3);
          return CdrColor.rgb(r, g, b);
        }
      case 4: // Grayscale
        if (offset + 2 <= data.lengthInBytes) {
          final g = data.getUint8(offset + 1);
          return CdrColor.rgb(g, g, g);
        }
      case 5: // Pantone / Spot
        if (offset + 4 <= data.lengthInBytes) {
          final spotId = data.getUint16(offset + 1, Endian.little);
          final tint = data.getUint8(offset + 3) / 255.0;
          // Approximate spot color by tint
          final grayVal = (255 * (1.0 - tint)).round().clamp(0, 255);
          return CdrColor(
            model: CdrColorModel.pantone,
            colorArgb: (0xFF << 24) | (grayVal << 16) | (grayVal << 8) | grayVal,
            pantoneName: 'Pantone $spotId',
          );
        }
      default:
        // Default RGB if within bounds
        if (offset + 3 <= data.lengthInBytes) {
          final r = data.getUint8(offset);
          final g = data.getUint8(offset + 1);
          final b = data.getUint8(offset + 2);
          return CdrColor.rgb(r, g, b);
        }
    }

    return CdrColor.black;
  }

  /// Converts a [Color] into a 4-byte CDR RGB byte sequence.
  static Uint8List encodeRgb(Color color) {
    return Uint8List.fromList([
      2, // Model: RGB
      color.red,
      color.green,
      color.blue,
    ]);
  }
}
