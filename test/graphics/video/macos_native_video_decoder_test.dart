import 'dart:io';

import 'package:dart_ui/src/graphics/video/macos_native_video_decoder.dart';
import 'package:dart_ui/src/graphics/video/video_decoder.dart';
import 'package:test/test.dart';

void main() {
  test('the hot path writes native slots without a managed frame allocation',
      () {
    final String source = File(
      'lib/src/graphics/video/macos_native_video_decoder.dart',
    ).readAsStringSync();

    expect(source, contains('storage.acquire()'));
    expect(source, contains('_memcpy('));
    expect(source, contains('lifetime: decoded.lease'));
    expect(source, isNot(contains('Uint8List(')));
    expect(source, isNot(contains('.asTypedList(')));
  });

  test('the direct backend refuses non-macOS without loading frameworks', () {
    if (Platform.isMacOS) return;
    expect(
      openMacosNativeVideoDecoder('unused.mov', const VideoDecoderOptions()),
      throwsA(
        isA<VideoDecoderException>()
            .having((e) => e.operation, 'operation', 'native-open')
            .having((e) => e.message, 'message', contains('only on macOS')),
      ),
    );
  });
}
