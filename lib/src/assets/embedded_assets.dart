/// Resources compiled into the program itself - fonts, images, data - so an
/// application ships as one executable with nothing beside it.
///
/// `dart_ui build` writes a generated library that registers every embedded
/// file here before the application's `main` runs; the framework's own
/// fonts are found here before the disk is searched, and an application
/// reads its own resources with [EmbeddedAssets.bytes] - falling back to
/// the file it was embedded from when that answers null, which is a
/// `dart run` during development.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The registry of embedded resources, by key.
///
/// Keys are paths with `/` separators relative to the project that embedded
/// them - `assets/logo.png` - and `dart_ui/fonts/<file>` for the
/// framework's own fonts.
abstract final class EmbeddedAssets {
  static final Map<String, String> _encoded = <String, String>{};
  static final Map<String, Uint8List> _decoded = <String, Uint8List>{};

  /// Registers resources held as base64 text - what generated code passes,
  /// since a string constant is the compact way to put bytes in a program.
  /// Each one is decoded the first time it is asked for.
  static void registerBase64(Map<String, String> resources) {
    for (final MapEntry<String, String> entry in resources.entries) {
      _encoded[entry.key] = entry.value;
      _decoded.remove(entry.key);
    }
  }

  /// Registers [bytes] under [key].
  static void register(String key, Uint8List bytes) {
    _decoded[key] = bytes;
    _encoded.remove(key);
  }

  static bool contains(String key) =>
      _decoded.containsKey(key) || _encoded.containsKey(key);

  /// Every embedded key.
  static Iterable<String> get keys =>
      <String>{..._decoded.keys, ..._encoded.keys};

  /// The bytes under [key], or null when nothing is embedded there.
  static Uint8List? bytes(String key) {
    final Uint8List? ready = _decoded[key];
    if (ready != null) return ready;
    final String? text = _encoded.remove(key);
    if (text == null) return null;
    return _decoded[key] = base64Decode(text);
  }

  /// Forgets everything - for tests.
  static void clear() {
    _encoded.clear();
    _decoded.clear();
  }
}
