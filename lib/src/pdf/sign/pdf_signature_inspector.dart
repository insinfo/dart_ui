import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/asn1/der.dart';
import 'pdf_byte_range_signer.dart';

/// One detached CMS signature embedded in a PDF `/Sig` dictionary.
final class PdfEmbeddedSignature {
  PdfEmbeddedSignature({
    required this.byteRange,
    required Uint8List cms,
    required Uint8List documentDigest,
    required this.contentsStart,
    required this.contentsEnd,
    required this.coversWholeDocument,
  })  : cms = Uint8List.fromList(cms),
        documentDigest = Uint8List.fromList(documentDigest);

  final List<int> byteRange;
  final Uint8List cms;
  final Uint8List documentDigest;

  /// Offset of the `<` that starts the hexadecimal `/Contents` string.
  final int contentsStart;

  /// Offset immediately after the `>` that closes `/Contents`.
  final int contentsEnd;

  /// True when the two ranges cover every byte outside `/Contents`.
  ///
  /// An older signature in an incrementally co-signed PDF is normally false:
  /// it covers the revision that existed when it was created, not later
  /// appended revisions.
  final bool coversWholeDocument;
}

/// Reads the structural envelope of PAdES/CMS signatures from PDF bytes.
///
/// This validates offsets, hexadecimal encoding and the outer DER value. It
/// deliberately does not claim trust, revocation or cryptographic validity;
/// those require certificate-chain policy and a verifier.
final class PdfSignatureInspector {
  const PdfSignatureInspector();

  static final RegExp _byteRangePattern = RegExp(
    r'/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]',
  );

  List<PdfEmbeddedSignature> inspect(Uint8List bytes) {
    final source = latin1.decode(bytes, allowInvalid: true);
    final signatures = <PdfEmbeddedSignature>[];
    for (final match in _byteRangePattern.allMatches(source)) {
      final range = <int>[
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
      ];
      _validateRange(bytes, range);
      final contentsStart = range[1];
      final contentsEnd = range[2];
      if (bytes[contentsStart] != 0x3c || bytes[contentsEnd - 1] != 0x3e) {
        throw const FormatException(
          'PDF signature /ByteRange does not exclude one <...> string',
        );
      }
      final paddedCms = _decodeHex(
        Uint8List.sublistView(bytes, contentsStart + 1, contentsEnd - 1),
      );
      final der = DerReader(paddedCms).read();
      if (der.tag != 0x30) {
        throw const FormatException('PDF signature /Contents is not CMS DER');
      }
      final cms = der.encoded;
      if (!_isSignedData(cms)) {
        throw const FormatException(
          'PDF signature /Contents is not CMS SignedData',
        );
      }
      signatures.add(PdfEmbeddedSignature(
        byteRange: List<int>.unmodifiable(range),
        cms: cms,
        documentDigest: const PdfByteRangeSigner().hashByteRange(bytes, range),
        contentsStart: contentsStart,
        contentsEnd: contentsEnd,
        coversWholeDocument: range[2] + range[3] == bytes.length,
      ));
    }
    return List<PdfEmbeddedSignature>.unmodifiable(signatures);
  }

  static void _validateRange(Uint8List bytes, List<int> range) {
    if (range[0] != 0 ||
        range[1] < 0 ||
        range[2] <= range[1] ||
        range[3] < 0 ||
        range[2] + range[3] > bytes.length) {
      throw FormatException('invalid PDF signature /ByteRange: $range');
    }
  }

  static Uint8List _decodeHex(Uint8List source) {
    final digits = <int>[];
    for (final byte in source) {
      if (_isWhitespace(byte)) continue;
      final nibble = _nibble(byte);
      if (nibble < 0) {
        throw const FormatException(
          'PDF signature /Contents contains a non-hexadecimal character',
        );
      }
      digits.add(nibble);
    }
    if (digits.length.isOdd) digits.add(0);
    return Uint8List.fromList(<int>[
      for (var index = 0; index < digits.length; index += 2)
        (digits[index] << 4) | digits[index + 1],
    ]);
  }

  static bool _isWhitespace(int byte) =>
      byte == 0 ||
      byte == 9 ||
      byte == 10 ||
      byte == 12 ||
      byte == 13 ||
      byte == 32;

  static int _nibble(int byte) {
    if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
    if (byte >= 0x41 && byte <= 0x46) return byte - 0x41 + 10;
    if (byte >= 0x61 && byte <= 0x66) return byte - 0x61 + 10;
    return -1;
  }

  static bool _isSignedData(Uint8List cms) {
    final outer = DerReader(cms).read();
    final sequence = DerReader(outer.value);
    final contentType = sequence.read();
    return contentType.tag == 0x06 &&
        contentType.value.length == 9 &&
        _same(
          contentType.value,
          const <int>[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02],
        );
  }

  static bool _same(Uint8List left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
