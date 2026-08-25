import 'dart:typed_data';

import '../../inflate.dart';

enum IccProfileCompression { none, deflate }

/// ICC Profile data stored with an image.
class IccProfile {
  String name = '';
  IccProfileCompression compression;
  Uint8List data;

  IccProfile(this.name, this.compression, this.data);

  IccProfile.from(IccProfile other)
      : name = other.name,
        compression = other.compression,
        data = other.data.sublist(0);

  IccProfile clone() => IccProfile.from(this);

  /// Returns the uncompressed data of the ICC Profile, decompressing the stored
  /// data as necessary.
  ///
  /// Inflates through this package's own `inflate.dart` rather than a zlib from
  /// `dart:io` or a package: the codecs are reachable from the web backend, and
  /// that inflater is the one that compiles under dart2js and dart2wasm.
  Uint8List decompressed() {
    if (compression == IccProfileCompression.none) {
      return data;
    }
    data = inflateZlib(
      data,
      // An ICC profile is a colour table, not an image; anything past a few MiB
      // is a malformed or hostile stream rather than a profile.
      maxOutputBytes: 16 * 1024 * 1024,
      budget: 'icc_profile',
    );
    compression = IccProfileCompression.none;
    return data;
  }
}
