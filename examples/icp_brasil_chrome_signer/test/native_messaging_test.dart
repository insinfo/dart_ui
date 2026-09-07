import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../native_host/lib/native_messaging.dart';

void main() {
  test('native messaging uses a little-endian length and round trips JSON', () {
    const codec = NativeMessageCodec();
    final encoded = codec.encode(<String, Object?>{'ação': 'assinar', 'id': 7});
    expect(ByteData.sublistView(encoded).getUint32(0, Endian.little),
        encoded.length - 4);
    expect(codec.decode(Uint8List.sublistView(encoded, 4)),
        <String, Object?>{'ação': 'assinar', 'id': 7});
  });

  test('reader accepts split frames', () async {
    const codec = NativeMessageCodec();
    final frame = codec.encode(<String, Object?>{'id': 'abc'});
    final messages =
        await NativeMessageReader(Stream<List<int>>.fromIterable(<List<int>>[
      frame.sublist(0, 2),
      frame.sublist(2, 7),
      frame.sublist(7),
    ])).messages().toList();
    expect(messages.single['id'], 'abc');
  });

  test('codec rejects non-object JSON', () {
    expect(
        () => const NativeMessageCodec()
            .decode(Uint8List.fromList(utf8.encode('[]'))),
        throwsFormatException);
  });
}
// ignore_for_file: avoid_relative_lib_imports
