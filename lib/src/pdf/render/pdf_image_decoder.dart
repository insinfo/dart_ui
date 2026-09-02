library;

import 'dart:typed_data';

import '../../graphics/image/decoded_image.dart';
import '../../graphics/image/raster_formats.dart';
import '../format/pdf_object.dart';

/// Decodes the samples of a PDF image XObject into premultiplied BGRA pixels.
///
/// PDF image streams are not necessarily ordinary PNG/JPEG files. Most are
/// packed sample planes whose meaning comes from `/BitsPerComponent`,
/// `/ColorSpace` and `/Decode`. In particular, indexed images contain palette
/// indices rather than gray values; treating an index as a gray component is
/// what turns a palette's white background into an almost-black square.
DecodedImage? decodePdfImage({
  required Uint8List bytes,
  required int width,
  required int height,
  PdfDict? dictionary,
  PdfResolver? resolver,
}) {
  if (width <= 0 || height <= 0 || bytes.isEmpty) return null;

  // DCTDecode, JPXDecode and similar pass-through filters leave a complete
  // encoded image here. Keep that path ahead of raw PDF sample decoding.
  final RasterImageFormat? encoded = sniffImageFormat(bytes);
  if (encoded == RasterImageFormat.jpeg2000) {
    // ISO 32000-1 section 7.4.9: the JPX colour space is used as-is unless
    // the dictionary overrides it, `/Decode` is ignored, and any opacity
    // channel in the file counts only when `/SMaskInData` is 1 or 2. The
    // codec reports whether that channel is premultiplied (2) or not (1).
    final int smaskInData =
        dictionary?.getNumber('SMaskInData', resolver)?.toInt() ?? 0;
    try {
      return decodeJp2(bytes, keepAlpha: smaskInData != 0);
    } on Object {
      return null;
    }
  }
  if (encoded != null) {
    try {
      return decodeImage(bytes, preferNative: false);
    } on Object {
      return null;
    }
  }

  final int bits =
      dictionary?.getNumber('BitsPerComponent', resolver)?.toInt() ?? 8;
  if (bits != 1 && bits != 2 && bits != 4 && bits != 8) return null;

  final _PdfSampleColorSpace? colorSpace =
      _PdfSampleColorSpace.parse(dictionary, resolver);
  if (colorSpace == null) return null;

  final int components = colorSpace.components;
  final int rowBits = width * components * bits;
  final int rowBytes = (rowBits + 7) >> 3;
  if (bytes.length < rowBytes * height) return null;

  final int maxSample = (1 << bits) - 1;
  final List<double>? decode = _decodeArray(
    dictionary?.getArray('Decode', resolver),
    components,
    colorSpace,
    resolver,
  );
  final Uint8List pixels = Uint8List(width * height * 4);
  final List<int> samples = List<int>.filled(components, 0);

  for (var y = 0; y < height; y++) {
    final int rowStart = y * rowBytes;
    for (var x = 0; x < width; x++) {
      final int firstBit = x * components * bits;
      for (var component = 0; component < components; component++) {
        final int bit = firstBit + component * bits;
        final int shift = 8 - bits - (bit & 7);
        samples[component] =
            (bytes[rowStart + (bit >> 3)] >> shift) & maxSample;
      }
      final (int red, int green, int blue) = colorSpace.toRgb(
        samples,
        maxSample,
        decode,
      );
      final int target = (y * width + x) * 4;
      pixels[target] = blue;
      pixels[target + 1] = green;
      pixels[target + 2] = red;
      pixels[target + 3] = 255;
    }
  }

  return DecodedImage(
    width: width,
    height: height,
    order: ImageChannelOrder.bgra,
    pixels: pixels,
    hasAlpha: false,
  );
}

List<double>? _decodeArray(
  PdfArray? value,
  int components,
  _PdfSampleColorSpace colorSpace,
  PdfResolver? resolver,
) {
  if (value == null) return null;
  if (value.length < components * 2) return null;
  final result = <double>[];
  for (var index = 0; index < components * 2; index++) {
    final num? number = value.getNumber(index, resolver);
    if (number == null) return null;
    result.add(number.toDouble());
  }
  return result;
}

sealed class _PdfSampleColorSpace {
  const _PdfSampleColorSpace(this.components);

  final int components;

  (int, int, int) toRgb(
    List<int> samples,
    int maxSample,
    List<double>? decode,
  );

  static _PdfSampleColorSpace? parse(
    PdfDict? dictionary,
    PdfResolver? resolver,
  ) {
    final PdfObject? object = dictionary?.getResolved('ColorSpace', resolver);
    if (object == null) return const _ComponentColorSpace.gray();
    return _parseObject(object, resolver);
  }

  static _PdfSampleColorSpace? _parseObject(
    PdfObject object,
    PdfResolver? resolver,
  ) {
    if (object is PdfName) {
      return switch (object.name) {
        'DeviceGray' || 'G' || 'CalGray' => const _ComponentColorSpace.gray(),
        'DeviceRGB' || 'RGB' || 'CalRGB' => const _ComponentColorSpace.rgb(),
        'DeviceCMYK' || 'CMYK' => const _ComponentColorSpace.cmyk(),
        _ => null,
      };
    }
    if (object is! PdfArray || object.length == 0) return null;
    final PdfObject? family = object.getResolved(0, resolver);
    if (family is! PdfName) return null;
    if (family.name == 'Indexed' || family.name == 'I') {
      if (object.length < 4) return null;
      final PdfObject? baseObject = object.getResolved(1, resolver);
      final int? highValue = object.getNumber(2, resolver)?.toInt();
      final PdfObject? lookupObject = object.getResolved(3, resolver);
      if (baseObject == null || highValue == null || highValue < 0) return null;
      final _PdfSampleColorSpace? base = _parseObject(baseObject, resolver);
      final Uint8List? lookup = switch (lookupObject) {
        final PdfString value => value.bytes,
        final PdfStream value => value.getDecodedBytes(resolver),
        _ => null,
      };
      if (base == null || lookup == null) return null;
      return _IndexedColorSpace(base, highValue, lookup);
    }
    if (family.name == 'ICCBased' && object.length >= 2) {
      final PdfObject? profile = object.getResolved(1, resolver);
      if (profile is! PdfStream) return null;
      return switch (profile.dict.getNumber('N', resolver)?.toInt()) {
        1 => const _ComponentColorSpace.gray(),
        3 => const _ComponentColorSpace.rgb(),
        4 => const _ComponentColorSpace.cmyk(),
        _ => null,
      };
    }
    return switch (family.name) {
      'CalGray' => const _ComponentColorSpace.gray(),
      'CalRGB' => const _ComponentColorSpace.rgb(),
      _ => null,
    };
  }
}

enum _ComponentModel { gray, rgb, cmyk }

final class _ComponentColorSpace extends _PdfSampleColorSpace {
  const _ComponentColorSpace.gray()
      : model = _ComponentModel.gray,
        super(1);
  const _ComponentColorSpace.rgb()
      : model = _ComponentModel.rgb,
        super(3);
  const _ComponentColorSpace.cmyk()
      : model = _ComponentModel.cmyk,
        super(4);

  final _ComponentModel model;

  @override
  (int, int, int) toRgb(
    List<int> samples,
    int maxSample,
    List<double>? decode,
  ) {
    double component(int index) {
      final double normalized = samples[index] / maxSample;
      if (decode == null) return normalized;
      final double low = decode[index * 2];
      final double high = decode[index * 2 + 1];
      return (low + normalized * (high - low)).clamp(0.0, 1.0);
    }

    return switch (model) {
      _ComponentModel.gray => _rgb(component(0), component(0), component(0)),
      _ComponentModel.rgb => _rgb(component(0), component(1), component(2)),
      _ComponentModel.cmyk => () {
          final double c = component(0);
          final double m = component(1);
          final double y = component(2);
          final double k = component(3);
          return _rgb(
            (1 - c) * (1 - k),
            (1 - m) * (1 - k),
            (1 - y) * (1 - k),
          );
        }(),
    };
  }
}

final class _IndexedColorSpace extends _PdfSampleColorSpace {
  const _IndexedColorSpace(this.base, this.highValue, this.lookup) : super(1);

  final _PdfSampleColorSpace base;
  final int highValue;
  final Uint8List lookup;

  @override
  (int, int, int) toRgb(
    List<int> samples,
    int maxSample,
    List<double>? decode,
  ) {
    final double normalized = samples[0] / maxSample;
    final double mapped = decode == null
        ? normalized * highValue
        : decode[0] + normalized * (decode[1] - decode[0]);
    final int index = mapped.round().clamp(0, highValue);
    final int offset = index * base.components;
    if (offset + base.components > lookup.length) return (0, 0, 0);
    final List<int> baseSamples = List<int>.generate(
      base.components,
      (int component) => lookup[offset + component],
      growable: false,
    );
    return base.toRgb(baseSamples, 255, null);
  }
}

(int, int, int) _rgb(double red, double green, double blue) => (
      (red.clamp(0.0, 1.0) * 255).round(),
      (green.clamp(0.0, 1.0) * 255).round(),
      (blue.clamp(0.0, 1.0) * 255).round(),
    );
