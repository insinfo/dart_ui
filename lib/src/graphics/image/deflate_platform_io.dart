/// The zlib the Dart VM already links, reached through `dart:io`.
///
/// This is C zlib, not Dart: `ZLibCodec` binds the same library `deflate(1)`
/// and every PDF tool in existence use. It is here for one reason - it is
/// about 2.5x faster than the encoder in `deflate.dart` on the same bytes -
/// and it is not the default, because it is also about 1.2% *larger* on the
/// PDF corpus and its output is not the output the web produces. See the
/// "Which encoder" section of `deflate.dart` for the measurement and the
/// argument.
library;

import 'dart:io';
import 'dart:typed_data';

/// Level 6, which is `ZLibOption.defaultLevel` and what every other zlib
/// caller means by "default compression"; the header this writes is then the
/// same `78 9C` the Dart encoder writes, so a reader cannot tell the two
/// apart by their first two bytes.
final ZLibCodec _zlib = ZLibCodec(level: 6);
final ZLibCodec _rawZlib = ZLibCodec(level: 6, raw: true);

Uint8List? nativeDeflate(Uint8List data, {required bool raw}) {
  final List<int> encoded = (raw ? _rawZlib : _zlib).encode(data);
  // `encode` is typed `List<int>`; it hands back a `Uint8List` today and
  // copying a growable list here would be a silent per-stream allocation if
  // that ever changed.
  return encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
}
