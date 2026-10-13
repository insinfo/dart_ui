/// Builds an iOS app bundle for a dart_ui application (ADR 0010).
///
/// ```
/// dart run tool/ios/build_app.dart <entrypoint.dart> [options]
///   --out build/ios/App.app
///   --bundle-id dev.dartui.app
///   --name dart_ui
///   --simulator        build for the simulator (default: device)
///   --run              install on the booted simulator and launch it
///   --sign IDENTITY    codesign identity (default "-": ad-hoc, simulator only)
/// ```
///
/// The bundle is the Dart AOT runtime built for iOS with the patch in
/// `tool/mobile/dart_sdk_patches/` (the app's executable), and the program as
/// a Mach-O dylib snapshot in `Frameworks/App.framework/App`. Both the runtime
/// and the `gen_snapshot` that targets iOS come from
/// `tool/mobile/build_dart_runtime.dart`; `DART_UI_IOS_AOT_OUT` names its
/// output parent (`<checkout>/sdk/xcodebuild`). The kernel comes from the host
/// SDK of the same version, `DART_UI_IOS_DART`. `DEVELOPER_DIR` picks Xcode.
///
/// No Xcode project and no Flutter: `xcrun` for `vtool`, `codesign` and
/// `simctl`, and nothing else from Xcode.
library;

import 'dart:io';

const String runtimeVersion = '3.13.5';

Future<void> main(List<String> arguments) async {
  String? entrypoint;
  var out = 'build/ios/App.app';
  var bundleId = 'dev.dartui.app';
  var name = 'dart_ui';
  var simulator = false;
  var run = false;
  var identity = '-';
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--out':
        out = arguments[++i];
      case '--bundle-id':
        bundleId = arguments[++i];
      case '--name':
        name = arguments[++i];
      case '--simulator':
        simulator = true;
      case '--run':
        run = true;
        simulator = true;
      case '--sign':
        identity = arguments[++i];
      default:
        if (arguments[i].startsWith('-') || entrypoint != null) {
          _fail('unexpected argument ${arguments[i]}');
        }
        entrypoint = arguments[i];
    }
  }
  if (entrypoint == null) {
    _fail('usage: build_app.dart <entrypoint.dart> [--simulator] [--run] '
        '[--out App.app] [--bundle-id id] [--name name] [--sign identity]');
  }
  final Map<String, String> env = Platform.environment;
  final String dart = env['DART_UI_IOS_DART'] ?? 'dart';
  final String? aotOut = env['DART_UI_IOS_AOT_OUT'];
  if (aotOut == null) _fail('DART_UI_IOS_AOT_OUT is not set');
  final String build =
      '$aotOut/${simulator ? 'ProductIosSimARM64' : 'ProductIosARM64'}';
  final File runtime = File('$build/exe.stripped/dartaotruntime');
  final File genSnapshot = File('$build/clang_arm64/gen_snapshot');
  if (!runtime.existsSync() || !genSnapshot.existsSync()) {
    _fail('no runtime or gen_snapshot in $build; run '
        'tool/mobile/build_dart_runtime.dart --target '
        '${simulator ? 'ios-simulator-arm64' : 'ios-arm64'}');
  }

  final String sdk = File(dart).absolute.parent.parent.path;
  final ProcessResult version = await Process.run(dart, <String>['--version']);
  if (!'${version.stdout}${version.stderr}'
      .contains('Dart SDK version: $runtimeVersion ')) {
    _fail('the kernel must come from Dart $runtimeVersion; '
        'set DART_UI_IOS_DART');
  }

  final Directory work = Directory('$out.work');
  if (work.existsSync()) work.deleteSync(recursive: true);
  work.createSync(recursive: true);
  final String kernel = '${work.path}/app.dill';
  await _exec('$sdk/bin/dartaotruntime', <String>[
    '$sdk/bin/snapshots/gen_kernel_aot.dart.snapshot',
    '--platform',
    '$sdk/lib/_internal/vm_platform_product.dill',
    '--aot',
    '--tfa',
    '--target-os',
    'ios',
    '-Ddart.vm.product=true',
    '--packages',
    '.dart_tool/package_config.json',
    '-o',
    kernel,
    entrypoint,
  ]);
  final String snapshot = '${work.path}/App';
  await _exec(genSnapshot.path, <String>[
    '--snapshot_kind=app-aot-macho-dylib',
    '--macho=$snapshot',
    '--strip',
    kernel,
  ]);

  final Directory app = Directory(out);
  if (app.existsSync()) app.deleteSync(recursive: true);
  final Directory framework = Directory('${app.path}/Frameworks/App.framework')
    ..createSync(recursive: true);
  // gen_snapshot marks the dylib as iOS; the simulator loads only dylibs
  // marked for it.
  if (simulator) {
    await _exec('xcrun', <String>[
      'vtool',
      '-set-build-version',
      'iossim',
      '17.0',
      '27.0',
      '-replace',
      '-output',
      '${framework.path}/App',
      snapshot,
    ]);
  } else {
    File(snapshot).copySync('${framework.path}/App');
  }
  File('${framework.path}/Info.plist')
      .writeAsStringSync(_plist(<String, Object>{
    'CFBundleExecutable': 'App',
    'CFBundleIdentifier': '$bundleId.app',
    'CFBundlePackageType': 'FMWK',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '1',
    'MinimumOSVersion': '17.0',
    'CFBundleSupportedPlatforms': <String>[
      simulator ? 'iPhoneSimulator' : 'iPhoneOS'
    ],
  }));
  final String executable = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  runtime.copySync('${app.path}/$executable');
  await Process.run('chmod', <String>['755', '${app.path}/$executable']);
  File('${app.path}/Info.plist').writeAsStringSync(_plist(<String, Object>{
    'CFBundleExecutable': executable,
    'CFBundleIdentifier': bundleId,
    'CFBundleName': name,
    'CFBundleDisplayName': name,
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '1',
    'MinimumOSVersion': '17.0',
    'CFBundleSupportedPlatforms': <String>[
      simulator ? 'iPhoneSimulator' : 'iPhoneOS'
    ],
    'LSRequiresIPhoneOS': true,
    'UIDeviceFamily': <int>[1, 2],
    'UILaunchScreen': <String, Object>{},
    'UIApplicationSceneManifest': <String, Object>{
      'UIApplicationSupportsMultipleScenes': false,
      'UISceneConfigurations': <String, Object>{
        'UIWindowSceneSessionRoleApplication': <Object>[
          <String, Object>{
            'UISceneConfigurationName': 'Default',
            'UISceneDelegateClassName': 'DartUiSceneDelegate',
          },
        ],
      },
    },
  }));
  await _exec(
      'codesign', <String>['--force', '--sign', identity, framework.path]);
  await _exec('codesign', <String>['--force', '--sign', identity, app.path]);
  stdout.writeln('app: ${app.path}');

  if (run) {
    await _exec('xcrun', <String>['simctl', 'install', 'booted', app.path]);
    final Process launched = await Process.start('xcrun',
        <String>['simctl', 'launch', '--console-pty', 'booted', bundleId],
        mode: ProcessStartMode.inheritStdio);
    exitCode = await launched.exitCode;
  }
}

String _plist(Map<String, Object> values) {
  final StringBuffer out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
    ..writeln('<plist version="1.0">');
  _value(out, values, '');
  out.writeln('</plist>');
  return out.toString();
}

void _value(StringBuffer out, Object value, String indent) {
  switch (value) {
    case final Map<String, Object> map:
      out.writeln('$indent<dict>');
      for (final MapEntry<String, Object> entry in map.entries) {
        out.writeln('$indent  <key>${entry.key}</key>');
        _value(out, entry.value, '$indent  ');
      }
      out.writeln('$indent</dict>');
    case final List<Object> list:
      out.writeln('$indent<array>');
      for (final Object item in list) {
        _value(out, item, '$indent  ');
      }
      out.writeln('$indent</array>');
    case final bool flag:
      out.writeln('$indent<${flag ? 'true' : 'false'}/>');
    case final int number:
      out.writeln('$indent<integer>$number</integer>');
    default:
      out.writeln('$indent<string>$value</string>');
  }
}

Future<void> _exec(String executable, List<String> arguments) async {
  final ProcessResult result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    _fail('$executable ${arguments.take(3).join(' ')}... exited '
        '${result.exitCode}\n${result.stdout}${result.stderr}');
  }
}

Never _fail(String message) {
  stderr.writeln('build_app: $message');
  exit(1);
}
