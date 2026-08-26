import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/platform/shell_platform_io.dart' as shell_io;
import 'package:test/test.dart';

void main() {
  group('url validation', () {
    test('absolute URLs of any scheme pass', () {
      expect(parseLaunchableUrl('https://dart.dev').scheme, 'https');
      expect(parseLaunchableUrl('mailto:someone@example.com').scheme, 'mailto');
      expect(parseLaunchableUrl('vscode://file/x').scheme, 'vscode');
    });

    test('a bare program name or relative path is refused', () {
      expect(
          () => parseLaunchableUrl('cmd.exe'), throwsA(isA<ShellException>()));
      expect(() => parseLaunchableUrl('../secrets.txt'),
          throwsA(isA<ShellException>()));
      expect(() => parseLaunchableUrl(''), throwsA(isA<ShellException>()));
    });
  });

  group('command planning (pure)', () {
    test('linux open prefers xdg-open and passes the target verbatim', () {
      final List<ShellCommand> commands = linuxOpenCommands('https://dart.dev');
      expect(commands.first.executable, 'xdg-open');
      expect(commands.first.arguments, <String>['https://dart.dev']);
      expect(commands.map((ShellCommand c) => c.executable),
          containsAll(<String>['gio', 'kde-open5']));
    });

    test('linux reveal asks FileManager1 first and degrades to the parent', () {
      final List<ShellCommand> commands =
          linuxRevealCommands('/home/isaque/docs/relatório.pdf');
      expect(commands.first.executable, 'dbus-send');
      expect(
        commands.first.arguments,
        contains('array:string:file:///home/isaque/docs/relat%C3%B3rio.pdf'),
      );
      expect(commands[1].executable, 'xdg-open');
      expect(commands[1].arguments, <String>['/home/isaque/docs']);
    });

    test('macOS uses open, and open -R for reveal', () {
      expect(macOpenCommand('/tmp/a.txt').executable, '/usr/bin/open');
      final ShellCommand reveal = macRevealCommand('/tmp/a.txt');
      expect(reveal.arguments, <String>['-R', '/tmp/a.txt']);
    });

    test('windows reveal quotes the path after /select,', () {
      expect(
        windowsRevealParameters(r'C:\Users\isaque\My Files\a.txt'),
        r'/select,"C:\Users\isaque\My Files\a.txt"',
      );
    });
  });

  group('fallback execution (injected runner)', () {
    ProcessResult result(int exitCode) => ProcessResult(1, exitCode, '', '');

    test('stops at the first launcher that exits 0', () async {
      final List<String> ran = <String>[];
      await shell_io.runFirstAvailable(
        'openUrl',
        linuxOpenCommands('https://dart.dev'),
        run: (String executable, List<String> arguments) async {
          ran.add(executable);
          return result(0);
        },
      );
      expect(ran, <String>['xdg-open']);
    });

    test('a missing launcher moves on to the next one', () async {
      final List<String> ran = <String>[];
      await shell_io.runFirstAvailable(
        'openUrl',
        linuxOpenCommands('https://dart.dev'),
        run: (String executable, List<String> arguments) async {
          ran.add(executable);
          if (executable == 'xdg-open') {
            throw ProcessException(executable, arguments);
          }
          return result(0);
        },
      );
      expect(ran, <String>['xdg-open', 'gio']);
    });

    test('when every launcher fails the exception names them all', () async {
      expect(
        () => shell_io.runFirstAvailable(
          'openUrl',
          linuxOpenCommands('https://dart.dev'),
          run: (String executable, List<String> arguments) async {
            throw ProcessException(executable, arguments);
          },
        ),
        throwsA(
          isA<ShellException>().having(
            (ShellException e) => e.reason,
            'reason',
            allOf(contains('xdg-open'), contains('gio'), contains('kde-open5')),
          ),
        ),
      );
    });

    test('a nonzero exit is recorded and the next launcher is tried', () async {
      final List<String> ran = <String>[];
      await shell_io.runFirstAvailable(
        'openUrl',
        linuxOpenCommands('https://dart.dev'),
        run: (String executable, List<String> arguments) async {
          ran.add(executable);
          return result(executable == 'gio' ? 0 : 4);
        },
      );
      expect(ran, <String>['xdg-open', 'gio']);
    });
  });

  group('io guards', () {
    test('openPath refuses a path that does not exist', () {
      expect(
        () => Shell.openPath(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'definitely-not-here-${DateTime.now().microsecondsSinceEpoch}',
        ),
        throwsA(isA<ShellException>()),
      );
    });

    test('openUrl refuses a non-URL before touching the platform', () {
      expect(
          () => Shell.openUrl('notepad.exe'), throwsA(isA<ShellException>()));
    });
  });
}
