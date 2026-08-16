/// Command-line interface for building native dart_ui applications.
library;

import 'dart:io';

import 'application_builder.dart';
import 'pe_subsystem.dart';

final class DartUiCli {
  DartUiCli({StringSink? output, StringSink? errors})
      : _output = output ?? stdout,
        _errors = errors ?? stderr;

  final StringSink _output;
  final StringSink _errors;

  Future<int> run(List<String> arguments) async {
    if (arguments.isEmpty ||
        arguments.first == 'help' ||
        arguments.first == '--help' ||
        arguments.first == '-h') {
      _writeHelp();
      return 0;
    }
    try {
      return switch (arguments.first) {
        'build' => await _build(arguments.sublist(1)),
        'pe' => _pe(arguments.sublist(1)),
        _ => throw _UsageException(
            'unknown command "${arguments.first}"',
          ),
      };
    } on _UsageException catch (error) {
      _errors.writeln('error: ${error.message}');
      _errors.writeln('Run "dart_ui --help" for usage.');
      return 64;
    } on ApplicationBuildException catch (error) {
      _errors.writeln('build failed: ${error.message}');
      return 1;
    } on PeFormatException catch (error) {
      _errors.writeln('PE error: ${error.message}');
      return 1;
    } on FileSystemException catch (error) {
      _errors.writeln('filesystem error: ${error.message}');
      return 1;
    } on ProcessException catch (error) {
      _errors.writeln('process error: ${error.message}');
      return 1;
    }
  }

  Future<int> _build(List<String> arguments) async {
    if (arguments.contains('--help') || arguments.contains('-h')) {
      _writeBuildHelp();
      return 0;
    }
    String? entrypoint;
    String? outputPath;
    String? appName;
    String? identifier;
    var version = '1.0.0';
    var console = false;

    for (var index = 0; index < arguments.length; index++) {
      final String argument = arguments[index];
      switch (argument) {
        case '-o' || '--output':
          outputPath = _valueAfter(arguments, index, argument);
          index++;
        case '--name':
          appName = _valueAfter(arguments, index, argument);
          index++;
        case '--identifier':
          identifier = _valueAfter(arguments, index, argument);
          index++;
        case '--version':
          version = _valueAfter(arguments, index, argument);
          index++;
        case '--console':
          console = true;
        default:
          if (argument.startsWith('-')) {
            throw _UsageException('unknown build option "$argument"');
          }
          if (entrypoint != null) {
            throw _UsageException(
              'build accepts one entrypoint; got "$entrypoint" and '
              '"$argument"',
            );
          }
          entrypoint = argument;
      }
    }
    if (entrypoint == null) {
      throw const _UsageException('build requires an entrypoint.dart');
    }

    final ApplicationBuildResult result = await DesktopApplicationBuilder(
      output: _output,
    ).build(ApplicationBuildRequest(
      entrypoint: entrypoint,
      outputPath: outputPath,
      appName: appName,
      bundleIdentifier: identifier,
      version: version,
      windowsConsole: console,
    ));
    _output.writeln('Built: ${result.primaryArtifact}');
    if (result.launcherArtifact case final String launcher) {
      _output.writeln('Launcher: $launcher');
    }
    return 0;
  }

  int _pe(List<String> arguments) {
    if (arguments.contains('--help') || arguments.contains('-h')) {
      _writePeHelp();
      return 0;
    }
    String? path;
    PeSubsystem? target;
    var allowSigned = false;
    for (final String argument in arguments) {
      switch (argument) {
        case '--info':
          target = null;
        case '--gui':
          target = PeSubsystem.windowsGui;
        case '--console':
          target = PeSubsystem.windowsConsole;
        case '--allow-signed':
          allowSigned = true;
        default:
          if (argument.startsWith('-')) {
            throw _UsageException('unknown pe option "$argument"');
          }
          if (path != null) {
            throw const _UsageException('pe accepts exactly one executable');
          }
          path = argument;
      }
    }
    if (path == null) {
      throw const _UsageException('pe requires a path to an executable');
    }
    final PeImageInfo info = target == null
        ? PeSubsystemEditor.inspect(path)
        : PeSubsystemEditor.setSubsystem(
            path,
            target,
            allowSigned: allowSigned,
          );
    _output.writeln('File: ${info.path}');
    _output.writeln('Format: ${info.format}');
    _output.writeln(
      'Subsystem: ${info.subsystemDescription} '
      '(0x${info.subsystemValue.toRadixString(16)})',
    );
    _output.writeln(
      'Authenticode certificate: '
      '${info.hasAuthenticodeCertificate ? 'present' : 'none'}',
    );
    return 0;
  }

  String _valueAfter(List<String> arguments, int index, String option) {
    if (index + 1 >= arguments.length || arguments[index + 1].startsWith('-')) {
      throw _UsageException('$option requires a value');
    }
    return arguments[index + 1];
  }

  void _writeHelp() {
    _output.writeln('dart_ui desktop application tools');
    _output.writeln();
    _output.writeln('Commands:');
    _output.writeln('  dart_ui build <entrypoint.dart> [options]');
    _output.writeln('  dart_ui pe <executable.exe> [--info|--gui|--console]');
    _output.writeln();
    _output.writeln('Builds are native to the current host; there is no AOT '
        'cross-compilation between Windows, Linux and macOS.');
  }

  void _writeBuildHelp() {
    _output.writeln('Usage: dart_ui build <entrypoint.dart> [options]');
    _output.writeln('  -o, --output <path>       Output executable or .app');
    _output.writeln('      --name <display name> Application display name');
    _output.writeln('      --identifier <id>     macOS reverse-DNS bundle id');
    _output.writeln('      --version <x.y.z>     macOS bundle version');
    _output.writeln('      --console             Keep Windows console');
  }

  void _writePeHelp() {
    _output.writeln('Usage: dart_ui pe <executable.exe> [action]');
    _output.writeln('      --info          Inspect only (default)');
    _output.writeln('      --gui           Set Windows GUI subsystem');
    _output.writeln('      --console       Set Windows console subsystem');
    _output.writeln('      --allow-signed  Permit invalidating Authenticode');
  }
}

final class _UsageException implements Exception {
  const _UsageException(this.message);

  final String message;
}
