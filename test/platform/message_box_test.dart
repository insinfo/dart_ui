import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/platform/message_box_platform_io.dart'
    as message_box_io;
import 'package:test/test.dart';

void main() {
  group('windows style mapping (pure)', () {
    test('each kind carries its icon, confirm carries the second button', () {
      // MB_OK | MB_ICONINFORMATION
      expect(windowsMessageBoxStyle(MessageBoxKind.info), 0x40);
      // MB_OK | MB_ICONWARNING
      expect(windowsMessageBoxStyle(MessageBoxKind.warning), 0x30);
      // MB_OK | MB_ICONERROR
      expect(windowsMessageBoxStyle(MessageBoxKind.error), 0x10);
      // MB_OKCANCEL | MB_ICONQUESTION
      expect(windowsMessageBoxStyle(MessageBoxKind.confirm), 0x21);
      expect(windowsMessageBoxOk, 1);
    });
  });

  group('linux command planning (pure)', () {
    test('zenity is first, kdialog second, with per-tool argument grammar',
        () {
      final List<ShellCommand> commands = linuxMessageBoxCommands(
        MessageBoxKind.confirm,
        title: 'Sair',
        message: 'Descartar alterações?',
      );
      expect(commands, hasLength(2));
      expect(commands[0].executable, 'zenity');
      expect(
        commands[0].arguments,
        <String>[
          '--question',
          '--title=Sair',
          '--text=Descartar alterações?',
        ],
      );
      expect(commands[1].executable, 'kdialog');
      expect(
        commands[1].arguments,
        <String>['--title', 'Sair', '--yesno', 'Descartar alterações?'],
      );
    });

    test('the non-question kinds map to the tools own dialog names', () {
      expect(
        linuxMessageBoxCommands(MessageBoxKind.error, title: 't', message: 'm')
            .first
            .arguments
            .first,
        '--error',
      );
      expect(
        linuxMessageBoxCommands(MessageBoxKind.warning,
                title: 't', message: 'm')[1]
            .arguments,
        contains('--sorry'),
      );
    });
  });

  group('macOS script planning (pure)', () {
    test('strings are escaped before interpolation', () {
      expect(escapeAppleScriptString(r'a "quoted" \path'),
          r'a \"quoted\" \\path');
    });

    test('confirm gets Cancel/OK, error gets the stop icon', () {
      final String confirm = macMessageBoxScript(
        MessageBoxKind.confirm,
        title: 'Sair',
        message: 'Tem certeza?',
      );
      expect(confirm, contains('buttons {"Cancel", "OK"}'));
      expect(confirm, contains('default button "OK"'));

      final String error = macMessageBoxScript(
        MessageBoxKind.error,
        title: 'Erro',
        message: 'Falhou',
      );
      expect(error, contains('with icon stop'));
      expect(error, contains('buttons {"OK"}'));
    });
  });

  group('linux fallback execution (injected runner)', () {
    ProcessResult result(int exitCode) => ProcessResult(1, exitCode, '', '');

    test('zenity exit 0 is the affirmative answer', () async {
      final bool answer = await message_box_io.linuxShow(
        title: 't',
        message: 'm',
        kind: MessageBoxKind.confirm,
        run: (String executable, List<String> arguments) async => result(0),
      );
      expect(answer, isTrue);
    });

    test('exit 1 is Cancel, not a failure', () async {
      final bool answer = await message_box_io.linuxShow(
        title: 't',
        message: 'm',
        kind: MessageBoxKind.confirm,
        run: (String executable, List<String> arguments) async => result(1),
      );
      expect(answer, isFalse);
    });

    test('a missing zenity falls back to kdialog', () async {
      final List<String> ran = <String>[];
      final bool answer = await message_box_io.linuxShow(
        title: 't',
        message: 'm',
        kind: MessageBoxKind.info,
        run: (String executable, List<String> arguments) async {
          ran.add(executable);
          if (executable == 'zenity') {
            throw ProcessException(executable, arguments);
          }
          return result(0);
        },
      );
      expect(answer, isTrue);
      expect(ran, <String>['zenity', 'kdialog']);
    });

    test('no helper at all is a MessageBoxException naming both', () {
      expect(
        () => message_box_io.linuxShow(
          title: 't',
          message: 'm',
          kind: MessageBoxKind.info,
          run: (String executable, List<String> arguments) async {
            throw ProcessException(executable, arguments);
          },
        ),
        throwsA(
          isA<MessageBoxException>().having(
            (MessageBoxException e) => e.reason,
            'reason',
            allOf(contains('zenity'), contains('kdialog')),
          ),
        ),
      );
    });
  });
}
