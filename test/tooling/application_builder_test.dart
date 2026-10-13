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
      macosHost: () => (File('${temporary.path}/dart_ui_macos_host')
            ..writeAsStringSync('h'))
          .path,
      tools: _FakeTools().run,
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
    expect(
      File('${bundle.path}/Contents/MacOS/dart_ui_macos_host').existsSync(),
      isTrue,
      reason: 'the AppKit host travels inside the bundle',
    );
    expect(plist, contains('<string>Hello &amp; World</string>'));
    expect(plist, contains('<string>com.example.hello-world</string>'));
    expect(plist, contains('<string>2.1.0</string>'));
    expect(plist, contains('<key>LSMinimumSystemVersion</key>'));
    expect(plist, contains('<key>LSUIElement</key>'),
        reason: 'the Dart program stays out of the Dock; the host shows');
  });

  group('macOS bundle tools', () {
    late _FakeTools tools;
    late String host;

    DesktopApplicationBuilder builder() => DesktopApplicationBuilder(
          platform: DesktopHostPlatform.macos,
          compiler: _fakeCompiler(),
          output: StringBuffer(),
          macosHost: () => host,
          tools: tools.run,
        );

    setUp(() {
      tools = _FakeTools();
      host = (File('${temporary.path}/dart_ui_macos_host')
            ..writeAsStringSync('h'))
          .path;
    });

    test('an icon becomes every iconset size and an icns the plist names',
        () async {
      final File icon = File('${temporary.path}/icon.png')
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
      final ApplicationBuildResult result = await builder().build(
        ApplicationBuildRequest(
          entrypoint: entrypoint.path,
          outputPath: '${temporary.path}/App',
          iconPath: icon.path,
          codesignIdentity: null,
        ),
      );
      final List<List<String>> sips = tools.calls
          .where((List<String> call) => call.first == 'sips')
          .toList();
      expect(sips, hasLength(macosIconsetSizes.length));
      expect(sips.map((List<String> call) => call[2]),
          containsAll(<String>['16', '32', '64', '128', '256', '512', '1024']));
      final List<String> iconutil = tools.calls
          .singleWhere((List<String> call) => call.first == 'iconutil');
      expect(iconutil.last,
          '${result.primaryArtifact}/Contents/Resources/AppIcon.icns');
      final String plist = File('${result.primaryArtifact}/Contents/Info.plist')
          .readAsStringSync();
      expect(plist, contains('<key>CFBundleIconFile</key>'));
      expect(plist, contains('<string>AppIcon</string>'));
      expect(tools.calls.where((List<String> call) => call.first == 'codesign'),
          isEmpty,
          reason: 'unsigned on request');
    });

    test('signs the host, then the bundle, then verifies; ad hoc by default',
        () async {
      final ApplicationBuildResult result = await builder().build(
        ApplicationBuildRequest(
          entrypoint: entrypoint.path,
          outputPath: '${temporary.path}/App',
        ),
      );
      final List<List<String>> codesign = tools.calls
          .where((List<String> call) => call.first == 'codesign')
          .toList();
      expect(codesign, hasLength(3));
      expect(codesign[0], containsAllInOrder(<String>['--sign', '-']));
      expect(codesign[0].last, endsWith('Contents/MacOS/dart_ui_macos_host'));
      expect(codesign[0], isNot(contains('--timestamp')),
          reason: 'an ad-hoc signature takes no timestamp');
      expect(codesign[1].last, result.primaryArtifact);
      expect(codesign[2], containsAll(<String>['--verify', '--strict']));
    });

    test('a Developer ID signs hardened with entitlements and notarizes',
        () async {
      final File entitlements = File('${temporary.path}/app.entitlements')
        ..writeAsStringSync('<plist/>');
      final ApplicationBuildResult result = await builder().build(
        ApplicationBuildRequest(
          entrypoint: entrypoint.path,
          outputPath: '${temporary.path}/App',
          codesignIdentity: 'Developer ID Application: Example (ABCDE12345)',
          hardenedRuntime: true,
          entitlementsPath: entitlements.path,
          infoPlist: const <String, String>{
            'NSMicrophoneUsageDescription': 'Records <voice> notes',
          },
          notaryProfile: 'notary',
        ),
      );
      final List<String> sign = tools.calls
          .firstWhere((List<String> call) => call.first == 'codesign');
      expect(
          sign,
          containsAll(<String>[
            '--timestamp',
            '--options',
            'runtime',
            '--entitlements',
            entitlements.path,
          ]));
      final List<String> names = <String>[
        for (final List<String> call in tools.calls) call.first,
      ];
      expect(names, containsAllInOrder(<String>['codesign', 'ditto', 'xcrun']));
      final List<String> staple = tools.calls.last;
      expect(staple,
          <String>['xcrun', 'stapler', 'staple', result.primaryArtifact]);
      final String plist = File('${result.primaryArtifact}/Contents/Info.plist')
          .readAsStringSync();
      expect(plist, contains('<key>NSMicrophoneUsageDescription</key>'));
      expect(plist, contains('Records &lt;voice&gt; notes'));
    });

    test('a failing tool fails the build with what it said', () async {
      tools.failing = 'codesign';
      await expectLater(
        builder().build(ApplicationBuildRequest(
          entrypoint: entrypoint.path,
          outputPath: '${temporary.path}/App',
        )),
        throwsA(isA<ApplicationBuildException>().having(
            (ApplicationBuildException e) => e.message,
            'message',
            contains('no identity found'))),
      );
    });

    test('notarizing an unsigned bundle is refused', () async {
      await expectLater(
        builder().build(ApplicationBuildRequest(
          entrypoint: entrypoint.path,
          outputPath: '${temporary.path}/App',
          codesignIdentity: null,
          notaryProfile: 'notary',
        )),
        throwsA(isA<ApplicationBuildException>()),
      );
    });
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

  test('embedding: the program registers the resources, then runs main',
      () async {
    final File asset = File('${temporary.path}/logo.txt')
      ..writeAsStringSync('hello');
    String? compiled;
    final DesktopApplicationBuilder builder = DesktopApplicationBuilder(
      platform: DesktopHostPlatform.linux,
      compiler: (String entry, String out) async {
        compiled = entry;
        File(out).writeAsStringSync('');
      },
      output: StringBuffer(),
    );
    await builder.build(ApplicationBuildRequest(
      entrypoint: entrypoint.path,
      outputPath: '${temporary.path}/hello',
      embed: <String>[asset.path],
    ));
    expect(compiled, endsWith('dart_ui_build/hello_world/main.dart'));
    final Directory work = File(compiled!).parent;
    addTearDown(() => work.deleteSync(recursive: true));
    final String main = File(compiled!).readAsStringSync();
    expect(main, contains('registerEmbeddedAssets();'));
    expect(main, contains('app.main()'),
        reason: "the entrypoint's main takes no arguments");
    final String assets = File('${work.path}/assets.g.dart').readAsStringSync();
    expect(assets, contains("r'aGVsbG8='"), reason: 'hello in base64');
    expect(assets, contains("'dart_ui/fonts/Inter-Regular.ttf'"));
    expect(assets, isNot(contains('Roboto')));
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

/// Records each tool call and succeeds, except for [failing].
final class _FakeTools {
  final List<List<String>> calls = <List<String>>[];
  String? failing;

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add(<String>[executable, ...arguments]);
    if (executable == failing) {
      return ProcessResult(0, 1, '', 'error: no identity found');
    }
    return ProcessResult(0, 0, '', '');
  }
}
