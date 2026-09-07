import 'dart:typed_data';

import 'package:dart_ui/src/pdf/io/byte_reader.dart';
import 'package:test/test.dart';

void main() {
  test('readBytes returns the requested zero-copy view', () {
    final source = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final reader = ByteReader(source)..skip(1);

    final view = reader.readBytes(2);
    source[2] = 9;

    expect(view, <int>[2, 9]);
    expect(reader.offset, 3);
  });

  test('readUntilKeyword ignores marker bytes inside binary data', () {
    final source = Uint8List.fromList(<int>[
      1,
      ...'endstreamX'.codeUnits,
      2,
      0x0a,
      ...'endstream'.codeUnits,
      0x0a,
      3,
    ]);
    final reader = ByteReader(source);

    final bytes = reader.readUntilKeyword('endstream'.codeUnits);

    expect(bytes, <int>[1, ...'endstreamX'.codeUnits, 2, 0x0a]);
    expect(reader.peekUint8(), 0x0a);
  });
}
