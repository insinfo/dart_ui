/// Pure request planning for the X11 core `PutImage` fallback.
///
/// `xcb_put_image` does not split a large image for the caller. Its fixed
/// request is 24 bytes, its variable payload must fit the server's maximum
/// request length, and BIG-REQUESTS consumes another four bytes. This file
/// performs that arithmetic without touching XCB, native memory, or a display.
///
/// A tightly packed full-width BGRA image is divided into vertical bands. If
/// even one row does not fit, each row is divided into horizontal tiles. A
/// partial-width region or a padded source also uses one-row segments because
/// adjacent source rows are not contiguous in the byte range XCB must copy.
library;

const int _bytesPerBgraPixel = 4;
const int _corePutImageOverheadBytes = 24;
const int _bigRequestsExtraBytes = 4;
const int _maximumCoreRequestUnits = 0xffff;
const int _maximumUint16 = 0xffff;
const int _maximumInt16 = 0x7fff;
const int _maximumUint32 = 0xffffffff;

/// One contiguous `xcb_put_image` payload.
///
/// [sourceOffset] points into the framebuffer supplied to the presenter. The
/// destination rectangle uses device pixels relative to the X11 window.
final class X11PutImageSegment {
  const X11PutImageSegment({
    required this.sourceOffset,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.byteLength,
  });

  final int sourceOffset;
  final int x;
  final int y;
  final int width;
  final int height;
  final int byteLength;

  @override
  String toString() => 'X11PutImageSegment(sourceOffset: $sourceOffset, '
      'destination: $x,$y ${width}x$height, bytes: $byteLength)';
}

/// A validated sequence of core X11 PutImage requests.
final class X11PutImagePlan {
  X11PutImagePlan._({
    required this.requestOverheadBytes,
    required this.maximumPayloadBytes,
    required List<X11PutImageSegment> segments,
  }) : segments = List<X11PutImageSegment>.unmodifiable(segments);

  /// Plans presentation of a BGRA framebuffer region.
  ///
  /// [pixelWidth] and [pixelHeight] describe the complete framebuffer;
  /// [bytesPerRow] is its source stride. [left], [top], [width], and [height]
  /// select the device-pixel rectangle to upload, defaulting to the complete
  /// framebuffer.
  ///
  /// [maximumRequestUnits] is the value returned by
  /// `xcb_get_maximum_request_length`, whose unit is four bytes.
  factory X11PutImagePlan.create({
    required int pixelWidth,
    required int pixelHeight,
    required int bytesPerRow,
    required int maximumRequestUnits,
    int left = 0,
    int top = 0,
    int? width,
    int? height,
  }) {
    _validateFramebuffer(pixelWidth, pixelHeight, bytesPerRow);
    _validateMaximumRequestUnits(maximumRequestUnits);

    final regionWidth = width ?? pixelWidth - left;
    final regionHeight = height ?? pixelHeight - top;
    _validateRegion(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      left: left,
      top: top,
      width: regionWidth,
      height: regionHeight,
    );

    final usesBigRequests = maximumRequestUnits > _maximumCoreRequestUnits;
    final overhead = _corePutImageOverheadBytes +
        (usesBigRequests ? _bigRequestsExtraBytes : 0);
    final maximumRequestBytes = maximumRequestUnits * 4;
    if (maximumRequestBytes <= overhead) {
      throw ArgumentError.value(
        maximumRequestUnits,
        'maximumRequestUnits',
        'does not leave room for one BGRA pixel after the PutImage header',
      );
    }

    // The XCB data_len parameter is uint32. Four-byte alignment is already
    // natural for BGRA, but applying it here also makes the invariant explicit
    // if the request limit is ever supplied by a synthetic test server.
    final payloadLimit = (maximumRequestBytes - overhead) & ~3;
    final maximumPayload = payloadLimit > (_maximumUint32 & ~3)
        ? _maximumUint32 & ~3
        : payloadLimit;
    if (maximumPayload < _bytesPerBgraPixel) {
      throw ArgumentError.value(
        maximumRequestUnits,
        'maximumRequestUnits',
        'does not allow a four-byte BGRA payload',
      );
    }

    final segments = <X11PutImageSegment>[];
    final packedRegionRowBytes = regionWidth * _bytesPerBgraPixel;
    final sourceRowsAreContiguous = left == 0 &&
        regionWidth == pixelWidth &&
        bytesPerRow == packedRegionRowBytes;

    if (sourceRowsAreContiguous && packedRegionRowBytes <= maximumPayload) {
      final rowsPerBand = maximumPayload ~/ packedRegionRowBytes;
      var row = 0;
      while (row < regionHeight) {
        final bandHeight = _minimum(rowsPerBand, regionHeight - row);
        _addSegment(
          segments,
          sourceOffset: (top + row) * bytesPerRow,
          x: left,
          y: top + row,
          width: regionWidth,
          height: bandHeight,
          byteLength: bandHeight * packedRegionRowBytes,
        );
        row += bandHeight;
      }
    } else {
      // A one-row segment is contiguous even when the framebuffer has padding
      // or only a narrow rectangle is dirty. If the row itself is too wide,
      // the same loop naturally produces horizontal tiles.
      final pixelsPerTile = maximumPayload ~/ _bytesPerBgraPixel;
      for (var row = 0; row < regionHeight; row++) {
        var column = 0;
        while (column < regionWidth) {
          final tileWidth = _minimum(pixelsPerTile, regionWidth - column);
          _addSegment(
            segments,
            sourceOffset: (top + row) * bytesPerRow +
                (left + column) * _bytesPerBgraPixel,
            x: left + column,
            y: top + row,
            width: tileWidth,
            height: 1,
            byteLength: tileWidth * _bytesPerBgraPixel,
          );
          column += tileWidth;
        }
      }
    }

    return X11PutImagePlan._(
      requestOverheadBytes: overhead,
      maximumPayloadBytes: maximumPayload,
      segments: segments,
    );
  }

  /// 24 for a core request, 28 when BIG-REQUESTS extended framing is needed.
  final int requestOverheadBytes;

  /// Maximum bytes usable by the data pointer of one segment.
  final int maximumPayloadBytes;

  final List<X11PutImageSegment> segments;

  int get totalPayloadBytes =>
      segments.fold(0, (total, segment) => total + segment.byteLength);
}

void _validateFramebuffer(int width, int height, int bytesPerRow) {
  if (width <= 0 || width > _maximumUint16) {
    throw RangeError.range(width, 1, _maximumUint16, 'pixelWidth');
  }
  if (height <= 0 || height > _maximumUint16) {
    throw RangeError.range(height, 1, _maximumUint16, 'pixelHeight');
  }
  final minimumStride = width * _bytesPerBgraPixel;
  if (bytesPerRow < minimumStride || bytesPerRow % _bytesPerBgraPixel != 0) {
    throw ArgumentError.value(
      bytesPerRow,
      'bytesPerRow',
      'must be a four-byte-aligned BGRA stride of at least $minimumStride',
    );
  }
}

void _validateMaximumRequestUnits(int value) {
  if (value <= 0 || value > _maximumUint32) {
    throw RangeError.range(value, 1, _maximumUint32, 'maximumRequestUnits');
  }
}

void _validateRegion({
  required int pixelWidth,
  required int pixelHeight,
  required int left,
  required int top,
  required int width,
  required int height,
}) {
  if (left < 0 || left > _maximumInt16) {
    throw RangeError.range(left, 0, _maximumInt16, 'left');
  }
  if (top < 0 || top > _maximumInt16) {
    throw RangeError.range(top, 0, _maximumInt16, 'top');
  }
  if (width <= 0 || left + width > pixelWidth) {
    throw RangeError(
      'width must select a non-empty region within the framebuffer',
    );
  }
  if (height <= 0 || top + height > pixelHeight) {
    throw RangeError(
      'height must select a non-empty region within the framebuffer',
    );
  }
}

void _addSegment(
  List<X11PutImageSegment> target, {
  required int sourceOffset,
  required int x,
  required int y,
  required int width,
  required int height,
  required int byteLength,
}) {
  // PutImage destination coordinates are signed 16-bit. Width and height may
  // extend past 32767, but the origin of every independently split request may
  // not. Catching this in the pure plan prevents silent FFI truncation.
  if (x > _maximumInt16 || y > _maximumInt16) {
    throw RangeError(
      'a split PutImage segment starts outside the signed 16-bit coordinate '
      'range at ($x, $y)',
    );
  }
  if (width <= 0 || width > _maximumUint16) {
    throw RangeError.range(width, 1, _maximumUint16, 'segment width');
  }
  if (height <= 0 || height > _maximumUint16) {
    throw RangeError.range(height, 1, _maximumUint16, 'segment height');
  }
  if (byteLength <= 0 || byteLength > _maximumUint32) {
    throw RangeError.range(
      byteLength,
      1,
      _maximumUint32,
      'segment byteLength',
    );
  }
  target.add(
    X11PutImageSegment(
      sourceOffset: sourceOffset,
      x: x,
      y: y,
      width: width,
      height: height,
      byteLength: byteLength,
    ),
  );
}

int _minimum(int a, int b) => a < b ? a : b;
