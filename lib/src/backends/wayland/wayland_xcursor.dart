/// Reading XCursor theme files in pure Dart.
///
/// Wayland has no system cursors. `wl_pointer.set_cursor` takes a
/// `wl_surface` the client has drawn the cursor into itself, so a client that
/// wants the user's actual pointer theme has to find the theme on disk, parse
/// its binary format and upload the pixels. `libwayland-cursor` does this in
/// C; this file does it in Dart, because a shim library is exactly what this
/// framework does not allow.
///
/// ## The file format, which is small and undocumented outside the source
///
/// An XCursor file is a table of contents followed by chunks:
///
/// ```text
/// header:  magic "Xcur" (0x72756358 LE) | header size | version | ntoc
/// toc[n]:  type | subtype | position
/// image:   header size | type(0xfffd0002) | subtype(= nominal size) |
///          version | width | height | xhot | yhot | delay | ARGB pixels
/// ```
///
/// Everything is little-endian 32-bit. Image pixels are **non-premultiplied
/// ARGB in a little-endian word**, which lands in memory as B,G,R,A - the same
/// byte order as the framework's own framebuffers, so no channel shuffling is
/// needed, only the premultiply that `wl_shm` requires.
///
/// Animated cursors are several images sharing one nominal size, each with a
/// `delay`. Only the first frame is used today; the rest are parsed and kept
/// so that an animation timer can be added without touching the parser.
library;

import 'dart:typed_data';

/// `"Xcur"` as a little-endian 32-bit word.
const int xcursorMagic = 0x72756358;

/// Chunk type for an image.
const int xcursorImageType = 0xfffd0002;

/// Chunk type for a comment, skipped.
const int xcursorCommentType = 0xfffe0001;

/// One cursor image at one nominal size.
final class XcursorImage {
  const XcursorImage({
    required this.nominalSize,
    required this.width,
    required this.height,
    required this.hotspotX,
    required this.hotspotY,
    required this.delayMilliseconds,
    required this.pixels,
  });

  /// The size the theme calls this image, which is *not* always its pixel
  /// width: a 24-pixel nominal cursor may be stored at 32 pixels. Selection
  /// goes by this number, because that is what `XCURSOR_SIZE` names.
  final int nominalSize;

  final int width;
  final int height;
  final int hotspotX;
  final int hotspotY;

  /// Frame duration for an animated cursor; 0 for a static one.
  final int delayMilliseconds;

  /// BGRA bytes, **premultiplied** - converted at parse time, because that is
  /// what `wl_shm` ARGB8888 means and what the framework's [Framebuffer]
  /// contract promises everywhere else.
  final Uint8List pixels;

  int get bytesPerRow => width * 4;

  @override
  String toString() => 'XcursorImage(nominal $nominalSize, '
      '${width}x$height, hotspot $hotspotX,$hotspotY)';
}

/// Every image in one cursor file.
final class XcursorFile {
  const XcursorFile(this.images);

  final List<XcursorImage> images;

  /// The available nominal sizes, ascending.
  List<int> get nominalSizes {
    final sizes = images.map((XcursorImage i) => i.nominalSize).toSet().toList()
      ..sort();
    return sizes;
  }

  /// The first frame of the size closest to [preferredSize].
  ///
  /// "Closest" rather than "smallest that fits": a 24-pixel theme asked for 32
  /// should give its 24, not nothing, and a theme with 24 and 48 asked for 32
  /// should give 24 rather than a cursor twice the requested size. Ties go to
  /// the larger image, which scales down more cleanly than up.
  XcursorImage? bestForSize(int preferredSize) {
    if (images.isEmpty) return null;
    XcursorImage? best;
    var bestDistance = -1;
    for (final image in images) {
      final distance = (image.nominalSize - preferredSize).abs();
      if (best == null ||
          distance < bestDistance ||
          (distance == bestDistance && image.nominalSize > best.nominalSize)) {
        best = image;
        bestDistance = distance;
      }
    }
    // Return the *first frame* of that size: a later frame of an animation
    // would show the cursor mid-blink.
    for (final image in images) {
      if (image.nominalSize == best!.nominalSize) return image;
    }
    return best;
  }

  /// Every frame of one nominal size, in file order - an animation.
  List<XcursorImage> framesForSize(int nominalSize) => images
      .where((XcursorImage image) => image.nominalSize == nominalSize)
      .toList();
}

/// Parses an XCursor file, or returns null when [bytes] is not one.
///
/// Never throws on malformed input: a broken or truncated cursor in a theme
/// directory must degrade to "no cursor from this file", not take the
/// application down at the moment the pointer moves. Every rejection is a
/// null, and the caller falls back to the next theme in the inherit chain.
XcursorFile? parseXcursorFile(Uint8List bytes) {
  if (bytes.length < 16) return null;
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.little) != xcursorMagic) return null;
  final headerSize = data.getUint32(4, Endian.little);
  final tocCount = data.getUint32(12, Endian.little);
  if (headerSize < 16 || tocCount == 0) return null;
  // Each toc entry is three words; a count that cannot fit is a corrupt file.
  if (headerSize + tocCount * 12 > bytes.length) return null;

  final images = <XcursorImage>[];
  for (var i = 0; i < tocCount; i++) {
    final entry = headerSize + i * 12;
    final type = data.getUint32(entry, Endian.little);
    final position = data.getUint32(entry + 8, Endian.little);
    if (type == xcursorCommentType) continue;
    if (type != xcursorImageType) continue;
    final image = _parseImageChunk(bytes, data, position);
    if (image != null) images.add(image);
  }
  if (images.isEmpty) return null;
  return XcursorFile(images);
}

XcursorImage? _parseImageChunk(Uint8List bytes, ByteData data, int position) {
  // chunk: header, type, subtype, version, width, height, xhot, yhot, delay.
  const chunkHeaderWords = 9;
  if (position + chunkHeaderWords * 4 > bytes.length) return null;
  final chunkHeaderSize = data.getUint32(position, Endian.little);
  final type = data.getUint32(position + 4, Endian.little);
  if (type != xcursorImageType) return null;
  final nominalSize = data.getUint32(position + 8, Endian.little);
  final width = data.getUint32(position + 16, Endian.little);
  final height = data.getUint32(position + 20, Endian.little);
  final hotspotX = data.getUint32(position + 24, Endian.little);
  final hotspotY = data.getUint32(position + 28, Endian.little);
  final delay = data.getUint32(position + 32, Endian.little);

  // The spec caps dimensions at 0x7fff; a larger value is a corrupt header,
  // and multiplying it out would try to allocate gigabytes.
  if (width == 0 || height == 0 || width > 0x7fff || height > 0x7fff) {
    return null;
  }
  if (hotspotX > width || hotspotY > height) return null;

  final pixelStart = position + (chunkHeaderSize < chunkHeaderWords * 4
      ? chunkHeaderWords * 4
      : chunkHeaderSize);
  final pixelBytes = width * height * 4;
  if (pixelStart + pixelBytes > bytes.length) return null;

  // ARGB little-endian words are B,G,R,A in memory: the framework's own byte
  // order. Only the premultiply is left, which wl_shm requires and XCursor
  // files do not store.
  final pixels = Uint8List(pixelBytes);
  for (var offset = 0; offset < pixelBytes; offset += 4) {
    final source = pixelStart + offset;
    final alpha = bytes[source + 3];
    if (alpha == 255) {
      pixels[offset] = bytes[source];
      pixels[offset + 1] = bytes[source + 1];
      pixels[offset + 2] = bytes[source + 2];
      pixels[offset + 3] = 255;
      continue;
    }
    if (alpha == 0) continue; // already zeroed
    pixels[offset] = (bytes[source] * alpha + 127) ~/ 255;
    pixels[offset + 1] = (bytes[source + 1] * alpha + 127) ~/ 255;
    pixels[offset + 2] = (bytes[source + 2] * alpha + 127) ~/ 255;
    pixels[offset + 3] = alpha;
  }

  return XcursorImage(
    nominalSize: nominalSize,
    width: width,
    height: height,
    hotspotX: hotspotX,
    hotspotY: hotspotY,
    delayMilliseconds: delay,
    pixels: pixels,
  );
}
