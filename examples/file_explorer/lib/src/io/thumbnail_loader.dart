/// Picture thumbnails from the disk, decoded away from the window's isolate.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:dart_ui/dart_ui.dart' show DecodedImage, decodeImageAsync;

/// Files larger than this are not decoded for a thumbnail.
const int kMaxThumbnailSource = 64 << 20;

/// [path]'s picture, scaled to fit [maxSide] pixels, or null when it is not
/// one this can read. Reading, decoding and scaling all run in another
/// isolate: a folder of photographs must not freeze the window.
Future<DecodedImage?> loadThumbnail(String path, {int maxSide = 256}) =>
    Isolate.run(() async {
      try {
        final File file = File(path);
        if (file.lengthSync() > kMaxThumbnailSource) return null;
        return await decodeImageAsync(file.readAsBytesSync(), maxSide: maxSide);
      } on Object {
        return null;
      }
    });
