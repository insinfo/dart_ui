/// The zlib a target without `dart:io` has, which is none.
///
/// dart2js and dart2wasm have no `ZLibCodec` and the browser's own
/// `CompressionStream` is asynchronous, so it cannot answer a synchronous
/// `deflateZlib`. Null here means "there is no faster encoder to hand", and
/// [deflateZlib] then runs the encoder in `deflate.dart` - which is the whole
/// reason that encoder exists.
library;

import 'dart:typed_data';

Uint8List? nativeDeflate(Uint8List data, {required bool raw}) => null;
