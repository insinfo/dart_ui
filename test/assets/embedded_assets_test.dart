import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  tearDown(EmbeddedAssets.clear);

  test('base64 is decoded once, on first use', () {
    EmbeddedAssets.registerBase64(<String, String>{
      'assets/hello.txt': base64Encode(utf8.encode('hello')),
    });
    expect(EmbeddedAssets.contains('assets/hello.txt'), isTrue);
    final Uint8List first = EmbeddedAssets.bytes('assets/hello.txt')!;
    expect(utf8.decode(first), 'hello');
    expect(identical(EmbeddedAssets.bytes('assets/hello.txt'), first), isTrue);
    expect(EmbeddedAssets.bytes('assets/missing'), isNull);
  });

  test('embedded framework fonts are installed before the disk is searched',
      () {
    addTearDown(FontRegistry.instance.reset);
    for (final String name in <String>[
      FrameworkFonts.uiFileName,
      FrameworkFonts.iconFileName,
      FrameworkFonts.fluentIconFileName,
    ]) {
      EmbeddedAssets.register(FrameworkFonts.embeddedKey(name),
          File('assets/fonts/$name').readAsBytesSync());
    }
    final FrameworkFontLoadResult result = FrameworkFonts.install();
    expect(result.directory, 'embedded');
    expect(result.uiFontLoaded, isTrue);
    expect(result.fluentIconFontLoaded, isTrue);
  });
}
