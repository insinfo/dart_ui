/// The gate that keeps `dart:ffi` out of the portable path.
///
/// ## Why a compilation test is the most valuable test in this directory
///
/// Everything else about the web backend can be checked by reading, by
/// `dart analyze`, or by a browser test. None of those catches the failure this
/// file exists for.
///
/// That failure is: somebody adds an import to a file under
/// `lib/src/rendering/gpu/webgl` or `lib/src/backends/web` - or, far more
/// likely, adds one to a *shared* library those files already import, such as
/// `lib/src/rendering/gpu/gpu_raster_sink.dart` - and the new import reaches
/// `dart:ffi`, or `dart:io`, or anything else the web does not have. The
/// analyzer is perfectly happy: those libraries exist on the VM, which is the
/// platform the analyzer resolves against by default. Every VM test goes on
/// passing. The break is invisible until somebody tries to build for the web,
/// which by then is a different change, a different person and a different
/// week.
///
/// So this runs the two web compilers over an entrypoint that imports the whole
/// backend, and fails if either one refuses. It is slow by the standards of the
/// tests around it - a few seconds each - and it is worth every one of them,
/// because it is the only thing standing between this package and a web build
/// that silently stops existing.
///
/// **Both compilers, not one.** `dart2js` and `dart2wasm` do not accept the
/// same programs. `dart:html` compiles under the first and does not exist under
/// the second, which is precisely the divergence `pubspec.yaml` cites for
/// choosing `package:web`. A gate that ran only `dart compile js` would have let
/// that one through.
///
/// ## Why it also compiles a desktop example
///
/// The rule is not "the package targets the web". It is "the package targets
/// the web **and** the VM", and a change that satisfied only the first would be
/// just as broken - moving a shared library onto `package:web` would break
/// `dart compile exe` while leaving both web compilers happy. So the third case
/// builds `example/gallery_headless.dart`, which is the portable desktop
/// example and the one that runs on every CI platform.
///
/// ## Why this is not `@TestOn('browser')`
///
/// Nothing here runs a browser. It runs a *compiler*, which is a subprocess, so
/// the test itself is a plain VM test - and it must be, because `dart:io` is
/// how a subprocess is started and a browser test has no `dart:io`. That is
/// also why it is not in the Chrome suite: this must run on the Linux and macOS
/// CI machines, which have neither Chrome nor a GPU, and it does.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The entrypoint that pulls in every web library. See its own header.
const String _webFixture = 'test/backends/web/web_compilation_fixture.dart';

/// The portable desktop example, which must go on building for the VM.
const String _desktopExample = 'example/gallery_headless.dart';

/// Generous, and deliberately so.
///
/// A cold `dart compile wasm` on a loaded CI machine is much slower than the
/// two seconds it takes locally, and a compilation gate that flakes on a
/// timeout teaches people to rerun it rather than to read it - which is worse
/// than not having it. The number is a backstop against a hung compiler, not a
/// performance assertion.
const Timeout _compilerTimeout = Timeout(Duration(minutes: 5));

void main() {
  // One temporary directory for every output, removed at the end. The outputs
  // are never inspected: what is being asserted is that the compiler *accepted*
  // the program, and the artefact is a by-product. `dart compile js` insists on
  // an output path, so it gets one.
  late Directory output;

  setUpAll(() {
    output = Directory.systemTemp.createTempSync('dart_ui_web_compile');
  });

  tearDownAll(() {
    if (output.existsSync()) output.deleteSync(recursive: true);
  });

  group('the web backend compiles', () {
    test('with dart2js', () {
      final _CompileResult result = _compile(
        <String>['compile', 'js', '-o', '${output.path}/web.js', _webFixture],
      );
      expect(
        result.exitCode,
        0,
        reason: 'dart compile js refused the web backend. This almost always '
            'means a library reachable from $_webFixture imports something '
            'the web does not have - dart:ffi and dart:io are the two that '
            'happen. The compiler names the import below.\n\n${result.output}',
      );
    }, timeout: _compilerTimeout);

    test('with dart2wasm', () {
      final _CompileResult result = _compile(
        <String>[
          'compile',
          'wasm',
          '-o',
          '${output.path}/web.wasm',
          _webFixture,
        ],
      );
      expect(
        result.exitCode,
        0,
        reason: 'dart compile wasm refused the web backend. Note that this can '
            'fail while dart compile js succeeds: dart:html exists under '
            'dart2js and not under dart2wasm, which is exactly why this '
            'package depends on package:web instead. The compiler names the '
            'problem below.\n\n${result.output}',
      );
    }, timeout: _compilerTimeout);
  });

  test('the desktop example still compiles for the VM', () {
    // The other half of the gate. A change that moved a shared library onto
    // package:web would satisfy both tests above and break this one.
    final _CompileResult result = _compile(
      <String>[
        'compile',
        'exe',
        '-o',
        '${output.path}/gallery${Platform.isWindows ? '.exe' : ''}',
        _desktopExample,
      ],
    );
    expect(
      result.exitCode,
      0,
      reason: 'dart compile exe refused the portable desktop example. The web '
          'backend must not have made the VM path unbuildable - the package '
          'targets both.\n\n${result.output}',
    );
  }, timeout: _compilerTimeout);
}

final class _CompileResult {
  const _CompileResult(this.exitCode, this.output);

  final int exitCode;

  /// stdout and stderr together.
  ///
  /// Together because a compiler splits its message across the two in a way
  /// that is not worth predicting: `dart compile js` writes its summary to
  /// stdout and its errors to stderr, and a failure report that showed only one
  /// of them would routinely be the empty one.
  final String output;
}

/// Runs `dart` with [arguments] from the repository root.
///
/// Synchronous on purpose. These are the only tests in the file, they are
/// inherently serial - three compilers competing for the same machine is slower
/// than three in a row - and `runSync` keeps the failure output attached to the
/// test that produced it.
///
/// The working directory is left as inherited rather than set explicitly,
/// because `dart test` already runs from the package root and the paths above
/// are relative to it, exactly as `test/differential/cpu_gpu_parity_test.dart`
/// reads `test/fonts/ahem.ttf`.
_CompileResult _compile(List<String> arguments) {
  final ProcessResult result = Process.runSync(
    // The executable that is running this test, not whatever `dart` is on the
    // PATH. On a machine with two SDKs installed those are different compilers,
    // and a gate that tested the wrong one would be worse than no gate.
    Platform.resolvedExecutable,
    arguments,
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  return _CompileResult(
    result.exitCode,
    '${result.stdout}\n${result.stderr}'.trim(),
  );
}
