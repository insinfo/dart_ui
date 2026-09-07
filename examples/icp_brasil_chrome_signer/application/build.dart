import 'dart:io';

Future<void> main() async {
  final applicationDirectory = File.fromUri(Platform.script).parent;
  final projectDirectory = applicationDirectory.parent;
  final repositoryRoot = projectDirectory.parent.parent;
  final source = File(
    '${repositoryRoot.path}${Platform.pathSeparator}examples'
    '${Platform.pathSeparator}pdf_signer_demo'
    '${Platform.pathSeparator}main.dart',
  );
  final outputDirectory = Directory(
    '${applicationDirectory.path}${Platform.pathSeparator}dist',
  )..createSync(recursive: true);
  final executableName =
      Platform.isWindows ? 'dart_ui_pdf_signer.exe' : 'dart_ui_pdf_signer';
  final output = File(
    '${outputDirectory.path}${Platform.pathSeparator}$executableName',
  );

  final process = await Process.start(
    Platform.resolvedExecutable,
    <String>['compile', 'exe', source.path, '-o', output.path],
    workingDirectory: repositoryRoot.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final result = await process.exitCode;
  if (result != 0) {
    exitCode = result;
    return;
  }
  stdout.writeln(
    'Aplicativo gerado para ${Platform.operatingSystem}: ${output.path}',
  );
}
