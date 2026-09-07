/// Finding the files a 3D model refers to but does not contain.
///
/// A `.gltf` names its `.bin`, an `.obj` names its `.mtl`, a `.mtl` names its
/// textures and an FBX may name a texture it did not embed. All of them do it
/// with a **relative URI written by whatever tool exported the model**, on
/// whatever filesystem that tool was running on, and the file has usually been
/// moved, zipped and unzipped at least once since.
///
/// So a resolver that only opens the URI as written finds almost nothing. The
/// mesh loaders deliberately do not touch the filesystem at all — a decoder
/// that opens files cannot run in a browser, in a test, or over bytes that
/// arrived from a network — and this is the piece that belongs to whoever knows
/// where the document came from.
///
/// ## What actually goes wrong, in the order it goes wrong
///
/// Every rule below is here because a real model in `D:\3d` needed it:
///
///   1. **A texture in a `textures/` subdirectory.** `Wolf.fbx` names
///      `Wolf_Body.jpg`; the file is in `textures/Wolf_Body.jpg` beside it.
///      This is the single most common layout of a downloaded model and the
///      one an as-written resolver misses completely.
///   2. **An absolute path from the exporting machine.**
///      `C:\Users\someone\Desktop\wood.png` is what FBX routinely stores. Only
///      the last segment is usable.
///   3. **Windows separators in a URI**, and percent-encoding: an exporter
///      writes `my%20model.bin` for a file whose name has a space.
///   4. **A case that does not match.** The exporting filesystem was
///      case-insensitive and the archive preserved `Wolf_Body.JPG` against a
///      reference to `.jpg`. Matching case-insensitively costs one directory
///      listing and is the difference between a textured model and a grey one.
///
/// Each candidate is tried in that order and the first hit wins, so an exact
/// match beside the document always beats a fuzzy one in a subdirectory.
library;

import 'dart:io';
import 'dart:typed_data';

/// Reads files a model refers to, relative to where the model itself was found.
///
/// One instance per opened document: it caches both the hits and the misses,
/// because a `.mtl` with forty materials naming one atlas asks for that atlas
/// forty times, and a missing texture is asked for just as often.
final class ModelAssetResolver {
  ModelAssetResolver(this.document, {List<String>? searchDirectories})
      : searchDirectories = searchDirectories ?? defaultSearchDirectories;

  /// Subdirectories tried beside the document, in order.
  ///
  /// `''` is the document's own directory. The rest are the conventions
  /// exporters and asset sites use; they cost a `File.existsSync` each, which
  /// is nothing next to decoding an image.
  static const List<String> defaultSearchDirectories = <String>[
    '',
    'textures',
    'Textures',
    'texture',
    'maps',
    'Maps',
    'tex',
    'images',
    'source',
    '../textures',
    '../Textures',
    '../source',
  ];

  /// The model file every relative reference is resolved against.
  final File document;

  final List<String> searchDirectories;

  final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  /// Paths that were asked for and not found, in the order they were asked.
  ///
  /// Kept so a viewer can say *which* file is missing rather than that
  /// something was. "the texture Wolf_Body.jpg was not found" tells a person
  /// where to look; "textures unsupported" does not.
  final List<String> missing = <String>[];

  /// How many distinct references were resolved from disk.
  int get resolvedCount =>
      _cache.values.where((Uint8List? bytes) => bytes != null).length;

  /// The bytes for [uri], or null.
  Uint8List? call(String uri) {
    final Uint8List? cached = _cache[uri];
    if (cached != null || _cache.containsKey(uri)) return cached;
    final Uint8List? bytes = _find(uri);
    _cache[uri] = bytes;
    if (bytes == null) missing.add(uri);
    return bytes;
  }

  Uint8List? _find(String uri) {
    if (uri.isEmpty) return null;
    // A network reference is somebody else's job: this class reads a disk and
    // an application that wants to fetch should pass its own resolver.
    if (uri.startsWith('http:') || uri.startsWith('https:')) return null;

    final String decoded = _decode(uri);
    final String normalised = decoded.replaceAll('\\', '/');
    final String base = normalised.split('/').last;
    final String directory = document.parent.path;

    for (final String relative in searchDirectories) {
      // The reference as written, which is the only candidate that can carry
      // its own subdirectory - `textures/wood.png` written by an exporter that
      // got it right.
      if (relative.isEmpty) {
        final Uint8List? exact = _read('$directory/$normalised');
        if (exact != null) return exact;
      }
      final String folder =
          relative.isEmpty ? directory : '$directory/$relative';
      final Uint8List? hit = _read('$folder/$base');
      if (hit != null) return hit;
      final Uint8List? insensitive = _readInsensitive(folder, base);
      if (insensitive != null) return insensitive;
    }
    return null;
  }

  /// Percent-decodes [uri], leaving it alone if that fails.
  ///
  /// `Uri.decodeComponent` throws on a stray `%` that is not an escape, which
  /// a Windows path written straight into a URI field can easily contain. A
  /// path that cannot be decoded is still worth trying as it stands.
  static String _decode(String uri) {
    if (!uri.contains('%')) return uri;
    try {
      return Uri.decodeComponent(uri);
    } on ArgumentError {
      return uri;
    } on FormatException {
      return uri;
    }
  }

  Uint8List? _read(String path) {
    try {
      final File file = File(path);
      if (!file.existsSync()) return null;
      return Uint8List.fromList(file.readAsBytesSync());
    } on FileSystemException {
      // A path that exists and cannot be read - a permission, a lock, a
      // dangling link. Treated as absent, because the caller's only useful
      // response is the same either way.
      return null;
    }
  }

  /// [name] in [folder], ignoring case.
  ///
  /// Listing a directory is much more expensive than a `stat`, so it runs only
  /// after the exact name has already failed there.
  Uint8List? _readInsensitive(String folder, String name) {
    final Directory directory = Directory(folder);
    if (!directory.existsSync()) return null;
    final String wanted = name.toLowerCase();
    try {
      for (final FileSystemEntity entry in directory.listSync()) {
        if (entry is! File) continue;
        final String candidate =
            entry.path.replaceAll('\\', '/').split('/').last;
        if (candidate.toLowerCase() == wanted) {
          return Uint8List.fromList(entry.readAsBytesSync());
        }
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }
}
