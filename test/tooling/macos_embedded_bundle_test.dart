/// The `.app` of the embedded macOS backend: its layout, its plists, the
/// toolchain it is compiled with, the build steps in order, and the runtime
/// patch it depends on. Tools are faked: nothing here needs the Dart SDK
/// checkout, Xcode or a Mac.
library;

import 'dart:io';

import 'package:dart_ui/src/tooling/application_builder.dart';
import 'package:dart_ui/src/tooling/dart_ui_cli.dart';
import 'package:dart_ui/src/tooling/macos_embedded_bundle.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('embedded_bundle'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('--macos-backend values', () {
    expect(MacosAppBackend.parse('embedded'), MacosAppBackend.embedded);
    expect(MacosAppBackend.parse('appkitEmbedded'), MacosAppBackend.embedded);
    expect(MacosAppBackend.parse('host'), MacosAppBackend.nativeHost);
    expect(MacosAppBackend.parse('native-host'), MacosAppBackend.nativeHost);
    expect(() => MacosAppBackend.parse('skylight'), throwsFormatException);
  });

  group('toolchain', () {
    test('comes from a checkout or a build directory, with the host dart', () {
      expect(MacosEmbeddedToolchain.resolve(const <String, String>{}), isNull);
      final MacosEmbeddedToolchain fromCheckout =
          MacosEmbeddedToolchain.resolve(const <String, String>{
        'DART_UI_DART_SDK_SRC': '/src',
        'DART_UI_IOS_DART': '/sdk/bin/dart',
      })!;
      expect(fromCheckout.runtime,
          '/src/sdk/xcodebuild/ProductARM64/exe.stripped/dartaotruntime');
      expect(fromCheckout.genSnapshot,
          '/src/sdk/xcodebuild/ProductARM64/exe.stripped/gen_snapshot');
      expect(fromCheckout.hostDart, '/sdk/bin/dart');
      final MacosEmbeddedToolchain explicit = MacosEmbeddedToolchain.resolve(
        const <String, String>{
          'DART_UI_DART_SDK_SRC': '/src',
          'DART_UI_MACOS_DART': '/a/bin/dart',
        },
        buildDirectory: '/out',
        dart: '/b/bin/dart',
      )!;
      expect(explicit.runtime, '/out/exe.stripped/dartaotruntime');
      expect(explicit.hostDart, '/b/bin/dart');
      expect(explicit.missing(), hasLength(4));
    });

    test('compiles a product AOT kernel for macOS and a Mach-O dylib', () {
      const MacosEmbeddedToolchain toolchain = MacosEmbeddedToolchain(
        runtime: '/out/dartaotruntime',
        genSnapshot: '/out/gen_snapshot',
        hostDart: '/sdk/bin/dart',
      );
      final List<String> kernel = toolchain.kernelArguments(
          entrypoint: 'main.dart', packages: 'pc.json', output: 'app.dill');
      expect(kernel.first, '/sdk/bin/snapshots/gen_kernel_aot.dart.snapshot');
      expect(kernel, containsAllInOrder(<String>['--target-os', 'macos']));
      expect(kernel, contains('-Ddart.vm.product=true'));
      expect(kernel, containsAllInOrder(<String>['--packages', 'pc.json']));
      expect(kernel.last, 'main.dart');
      expect(
          toolchain.snapshotArguments(kernel: 'app.dill', output: 'App'),
          <String>[
            '--snapshot_kind=app-aot-macho-dylib',
            '--macho=App',
            '--strip',
            'app.dill',
          ]);
    });
  });

  group('bundle', () {
    test('the framework is versioned and found where the runtime looks', () {
      final MacosEmbeddedBundleLayout layout =
          MacosEmbeddedBundleLayout('${temp.path}/X.app', 'x')..create();
      expect(Directory(layout.macos).existsSync(), isTrue);
      expect(Link('${layout.framework}/Versions/Current').targetSync(), 'A');
      expect(
          Link('${layout.framework}/App').targetSync(), 'Versions/Current/App');
      // The patch's MacRunBundle: <exe dir>/../Frameworks/App.framework/App.
      expect(
        File('${layout.macos}/${MacosEmbeddedBundleLayout.snapshotFromExecutable}')
            .absolute
            .path
            .replaceAll('/Contents/MacOS/../', '/Contents/'),
        '${layout.framework}/App',
      );
    });

    test('Info.plist: the runtime is the app, no LSUIElement', () {
      final String plist = macosEmbeddedInfoPlist(
        appName: 'A & B',
        executableName: 'ab',
        identifier: 'dev.dartui.ab',
        version: '1.2.3',
        minimumSystemVersion: '11.0',
        iconFile: 'AppIcon',
        extra: const <String, String>{'NSCameraUsageDescription': 'x'},
      );
      expect(plist, contains('<key>CFBundleExecutable</key>\n  <string>ab'));
      expect(plist, contains('A &amp; B'));
      expect(plist, contains('<key>NSPrincipalClass</key>'));
      expect(plist, contains('<key>NSHighResolutionCapable</key>\n  <true/>'));
      expect(plist, contains('NSCameraUsageDescription'));
      expect(plist, isNot(contains('LSUIElement')),
          reason: 'one process, and it is the application in the Dock');
      final String framework = macosEmbeddedFrameworkInfoPlist(
          identifier: 'dev.dartui.ab',
          version: '1.0',
          minimumSystemVersion: '11.0');
      expect(framework, contains('<string>FMWK</string>'));
      expect(framework, contains('<string>dev.dartui.ab.app</string>'));
    });

    test('the package config is the nearest one above the entrypoint', () {
      final File config =
          File('${temp.path}/pkg/.dart_tool/package_config.json')
            ..createSync(recursive: true);
      final File entry = File('${temp.path}/pkg/bin/deep/main.dart')
        ..createSync(recursive: true);
      expect(findPackageConfig(entry.path), config.absolute.path);
    });

    test('the builder compiles, lays out and signs inside out', () async {
      final Directory out = Directory('${temp.path}/out')..createSync();
      File('${out.path}/dartaotruntime').writeAsStringSync('runtime');
      File('${out.path}/gen_snapshot').writeAsStringSync('');
      final Directory sdk = Directory('${temp.path}/sdk');
      File('${sdk.path}/bin/snapshots/gen_kernel_aot.dart.snapshot')
          .createSync(recursive: true);
      File('${sdk.path}/lib/_internal/vm_platform_product.dill')
          .createSync(recursive: true);
      File('${sdk.path}/bin/dart').createSync(recursive: true);
      File('${temp.path}/app/.dart_tool/package_config.json')
          .createSync(recursive: true);
      final File entry = File('${temp.path}/app/bin/demo.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}');

      final List<String> ran = <String>[];
      Future<ProcessResult> tools(String executable, List<String> args) async {
        ran.add('${executable.split('/').last} ${args.join(' ')}');
        for (final String arg in args) {
          // gen_snapshot writes the dylib the bundle carries.
          if (arg.startsWith('--macho=')) {
            File(arg.substring(8)).writeAsStringSync('snapshot');
          }
        }
        return ProcessResult(0, 0, '', '');
      }

      final StringBuffer log = StringBuffer();
      final ApplicationBuildResult result = await DesktopApplicationBuilder(
        platform: DesktopHostPlatform.macos,
        output: log,
        tools: tools,
      ).build(ApplicationBuildRequest(
        entrypoint: entry.path,
        outputPath: '${temp.path}/Demo.app',
        embedFrameworkFonts: false,
        macosBackend: MacosAppBackend.embedded,
        macosEmbeddedToolchain: MacosEmbeddedToolchain(
          runtime: '${out.path}/dartaotruntime',
          genSnapshot: '${out.path}/gen_snapshot',
          hostDart: '${sdk.path}/bin/dart',
        ),
      ));

      final MacosEmbeddedBundleLayout layout =
          MacosEmbeddedBundleLayout(result.primaryArtifact, 'demo');
      expect(File(layout.executable).readAsStringSync(), 'runtime');
      expect(File('${layout.framework}/App').readAsStringSync(), 'snapshot');
      expect(File(layout.infoPlist).readAsStringSync(),
          contains('<string>dev.dartui.demo</string>'));
      expect(File(layout.frameworkInfoPlist).existsSync(), isTrue);
      expect(Directory('${temp.path}/Demo.app.work').existsSync(), isFalse);
      // Kernel, snapshot, then the framework signed before the bundle.
      expect(ran.first, startsWith('dartaotruntime '));
      expect(ran[1], startsWith('gen_snapshot --snapshot_kind'));
      final int framework = ran.indexWhere((String c) =>
          c.startsWith('codesign') && c.endsWith('App.framework'));
      final int bundle = ran.indexWhere(
          (String c) => c.startsWith('codesign') && c.endsWith('Demo.app'));
      expect(framework, greaterThan(1));
      expect(bundle, greaterThan(framework));
    });

    test('without a toolchain the build says how to get one', () async {
      final File entry = File('${temp.path}/demo.dart')
        ..writeAsStringSync('void main() {}');
      await expectLater(
        DesktopApplicationBuilder(
          platform: DesktopHostPlatform.macos,
          output: StringBuffer(),
        ).build(ApplicationBuildRequest(
          entrypoint: entry.path,
          outputPath: '${temp.path}/Demo.app',
          embedFrameworkFonts: false,
          macosBackend: MacosAppBackend.embedded,
          macosEmbeddedToolchain: const MacosEmbeddedToolchain(
            runtime: '/nowhere/dartaotruntime',
            genSnapshot: '/nowhere/gen_snapshot',
            hostDart: '/nowhere/bin/dart',
          ),
        )),
        throwsA(isA<ApplicationBuildException>().having(
            (ApplicationBuildException e) => e.message,
            'message',
            contains('patched runtime'))),
      );
    });

    test('the CLI takes --macos-backend', () async {
      final StringBuffer errors = StringBuffer();
      final int code = await DartUiCli(output: StringBuffer(), errors: errors)
          .run(<String>['build', 'x.dart', '--macos-backend=bogus']);
      expect(code, isNot(0));
      expect(errors.toString(), contains('native-host or embedded'));
    });
  });

  group('runtime patch', () {
    final File patch = File('tool/mobile/dart_sdk_patches/3.13.5-macos.patch');

    test('touches only the standalone runtime, only on macOS', () {
      final String text = patch.readAsStringSync();
      final List<String> files = <String>[
        for (final Match m
            in RegExp(r'^diff --git a/(\S+)', multiLine: true).allMatches(text))
          m.group(1)!,
      ];
      expect(
          files, <String>['runtime/bin/main.cc', 'runtime/bin/main_impl.cc']);
      // Every block it adds is behind the macOS-not-iOS guard, so the iOS and
      // Android builds of the same checkout are untouched.
      final int guards = RegExp(
              r'^\+#if defined\(DART_HOST_OS_MACOS\) && !defined\(DART_HOST_OS_IOS\)',
              multiLine: true)
          .allMatches(text)
          .length;
      expect(guards, greaterThanOrEqualTo(4));
      for (final String piece in <String>[
        'Dart_SetMessageNotifyCallback(MacNotifyMessage)',
        'kCFRunLoopCommonModes',
        'Dart_HandleMessage()',
        'Dart_HasLivePorts()',
        'Dart_DartUiMainThreadLoop',
        'Dart_DartUiRunApplication',
        'Frameworks/App.framework/App',
        'DART_UI_MAIN_THREAD_LOOP',
      ]) {
        expect(text, contains(piece));
      }
    });

    test('is applied on top of the iOS patch in the checkout, when present',
        () async {
      final String? checkout = Platform.environment['DART_UI_DART_SDK_SRC'];
      if (checkout == null ||
          !File('$checkout/sdk/tools/build.py').existsSync()) {
        markTestSkipped('no DART_UI_DART_SDK_SRC checkout on this machine');
        return;
      }
      // The layered rule build_dart_runtime.dart applies: the last patch
      // that reverses cleanly, and every one before it, is in the tree.
      final ProcessResult reverses = await Process.run(
          'git', <String>['apply', '--reverse', '--check', patch.absolute.path],
          workingDirectory: '$checkout/sdk');
      expect(reverses.exitCode, 0, reason: '${reverses.stderr}');
    });
  });
}
