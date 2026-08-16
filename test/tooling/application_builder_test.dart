import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/tooling/application_builder.dart';
import 'package:dart_ui/src/tooling/pe_subsystem.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File entrypoint;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('dart_ui_builder_test_');
    entrypoint = File('${temporary.path}/hello_world.dart')
      ..writeAsStringSync('void main() {}');
  });

  tearDown(() {
    temporary.deleteSync(recursive: true);
  });

  test('Windows output is an exe with the GUI subsystem', () async {
    final DesktopApplicationBuilder builder = DesktopApplicationBuilder(
      platform: DesktopHostPlatform.windows,
      compiler: _fakeCompiler(writePe: true),
      output: StringBuffer(),
    );

    final ApplicationBuildResult result = await builder.build(
      ApplicationBuildRequest(
        entrypoint: entrypoint.path,
        outputPath: '${temporary.path}/hello',
      ),
    );

    expect(result.primaryArtifact, endsWith('hello.exe'));
    expect(
      PeSubsystemEditor.inspect(result.primaryArtifact).subsystem,
      PeSubsystem.windowsGui,
    );
  });

  test('Linux output includes a terminal-free desktop launcher', () async {
    final DesktopApplicationBuilder builder = DesktopApplicationBuilder(
      platform: DesktopHostPlatform.linux,
      compiler: _fakeCompiler(),
      output: StringBuffer(),
    );

    final ApplicationBuildResult result = await builder.build(
      ApplicationBuildRequest(
        entrypoint: entrypoint.path,
        outputPath: '${temporary.path}/with space/hello',
        appName: 'Hello World',
      ),
    );
    final String desktop = File(result.launcherArtifact!).readAsStringSync();

    expect(File(result.primaryArtifact).existsSync(), isTrue);
    expect(desktop, contains('Type=Application'));
    expect(desktop, contains('Name=Hello World'));
    expect(desktop, contains('Terminal=false'));
    expect(desktop, contains('Exec="'));
  });

  test('macOS output has the standard app bundle structure', () async {
    final DesktopApplicationBuilder builder = DesktopApplicationBuilder(
      platform: DesktopHostPlatform.macos,
      compiler: _fakeCompiler(),
      output: StringBuffer(),
    );

    final ApplicationBuildResult result = await builder.build(
      ApplicationBuildRequest(
        entrypoint: entrypoint.path,
        outputPath: '${temporary.path}/Hello World',
        appName: 'Hello & World',
        bundleIdentifier: 'com.example.hello-world',
        version: '2.1.0',
      ),
    );
    final Directory bundle = Directory(result.primaryArtifact);
    final String plist =
        File('${bundle.path}/Contents/Info.plist').readAsStringSync();

    expect(bundle.path, endsWith('.app'));
    expect(
      File('${bundle.path}/Contents/MacOS/hello_world').existsSync(),
      isTrue,
    );
    expect(Directory('${bundle.path}/Contents/Resources').existsSync(), isTrue);
    expect(plist, contains('<string>Hello &amp; World</string>'));
    expect(plist, contains('<string>com.example.hello-world</string>'));
    expect(plist, contains('<string>2.1.0</string>'));
  });

  test('rejects invalid metadata before invoking the compiler', () async {
    var compiled = false;
    final DesktopApplicationBuilder builder = DesktopApplicationBuilder(
      platform: DesktopHostPlatform.macos,
      compiler: (String _, String __) async => compiled = true,
      output: StringBuffer(),
    );

    await expectLater(
      builder.build(ApplicationBuildRequest(
        entrypoint: entrypoint.path,
        bundleIdentifier: 'not a bundle identifier',
      )),
      throwsA(isA<ApplicationBuildException>()),
    );
    expect(compiled, isFalse);
  });
}

DartExeCompiler _fakeCompiler({bool writePe = false}) =>
    (String _, String outputPath) async {
      final File output = File(outputPath);
      output.parent.createSync(recursive: true);
      output.writeAsBytesSync(writePe ? _minimalPe() : <int>[1, 2, 3]);
    };

Uint8List _minimalPe() {
  final Uint8List bytes = Uint8List(512);
  final ByteData data = ByteData.sublistView(bytes);
  const int peOffset = 0x80;
  const int optionalHeaderOffset = peOffset + 24;
  data.setUint16(0, 0x5A4D, Endian.little);
  data.setUint32(0x3C, peOffset, Endian.little);
  data.setUint32(peOffset, 0x00004550, Endian.little);
  data.setUint16(peOffset + 20, 240, Endian.little);
  data.setUint16(optionalHeaderOffset, 0x020B, Endian.little);
  data.setUint16(optionalHeaderOffset + 68, 3, Endian.little);
  return bytes;
}
