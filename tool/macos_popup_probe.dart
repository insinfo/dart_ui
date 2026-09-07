import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class _Inspection {
  const _Inspection({
    required this.kind,
    required this.windowClass,
    required this.styleMask,
    required this.level,
    required this.isKey,
    required this.ignoresMouse,
  });

  final String kind;
  final String windowClass;
  final int styleMask;
  final int level;
  final bool isKey;
  final bool ignoresMouse;
}

Future<_Inspection> _inspect(String host, String kind) async {
  final Process process = await Process.start(host, <String>[
    '--command-stdin',
    '--width',
    '180',
    '--height',
    '100',
    '--title',
    'dart_ui $kind probe',
    '--window-kind',
    kind,
  ]);
  final Completer<_Inspection> inspected = Completer<_Inspection>();
  final List<String> errors = <String>[];
  late final StreamSubscription<String> output;
  output = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) {
    stdout.writeln('$kind: $line');
    if (line.startsWith('HOST_PID=')) {
      process.stdin.writeln('INSPECT_WINDOW');
    } else if (line.startsWith('WINDOW_INSPECT=')) {
      final List<String> fields = line.substring(15).split(':');
      if (fields.length != 6) {
        inspected.completeError(StateError('malformed inspection: $line'));
        return;
      }
      inspected.complete(_Inspection(
        kind: fields[0],
        windowClass: fields[1],
        styleMask: int.parse(fields[2]),
        level: int.parse(fields[3]),
        isKey: fields[4] == '1',
        ignoresMouse: fields[5] == '1',
      ));
      process.stdin.writeln('CLOSE');
    }
  });
  final StreamSubscription<String> errorOutput = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(errors.add);
  try {
    final _Inspection result =
        await inspected.future.timeout(const Duration(seconds: 15));
    final int status =
        await process.exitCode.timeout(const Duration(seconds: 10));
    if (status != 0) {
      throw StateError('host exited $status: ${errors.join('\n')}');
    }
    return result;
  } finally {
    if (!inspected.isCompleted) process.kill();
    await output.cancel();
    await errorOutput.cancel();
  }
}

Future<void> main() async {
  if (!Platform.isMacOS) {
    stdout.writeln('MACOS_POPUP=SKIP platform=${Platform.operatingSystem}');
    return;
  }
  final String? host = Platform.environment['DART_UI_MACOS_HOST'];
  if (host == null || host.isEmpty) {
    throw StateError('DART_UI_MACOS_HOST must name the compiled host');
  }

  const int nonactivatingPanel = 1 << 7;
  final _Inspection popup = await _inspect(host, 'popup');
  final _Inspection tooltip = await _inspect(host, 'tooltip');
  final bool passed = popup.kind == 'popup' &&
      tooltip.kind == 'tooltip' &&
      popup.windowClass == 'NSPanel' &&
      tooltip.windowClass == 'NSPanel' &&
      popup.styleMask & nonactivatingPanel != 0 &&
      tooltip.styleMask & nonactivatingPanel != 0 &&
      popup.level > 0 &&
      tooltip.level == popup.level &&
      !popup.isKey &&
      !tooltip.isKey &&
      !popup.ignoresMouse &&
      tooltip.ignoresMouse;
  stdout.writeln(
    'MACOS_POPUP=${passed ? 'PASS' : 'FAIL'} '
    'popup=${popup.windowClass}/${popup.styleMask}/${popup.level}/key=${popup.isKey} '
    'tooltip=${tooltip.windowClass}/${tooltip.styleMask}/${tooltip.level}/key=${tooltip.isKey}/ignoresMouse=${tooltip.ignoresMouse}',
  );
  if (!passed) exitCode = 1;
}
