import 'dart:convert';

import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/macos_text_input.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/platform/text_input.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

void main() {
  late _Window window;
  late _Client client;
  late MacosTextInputConnection connection;

  setUp(() {
    window = _Window();
    client = _Client();
  });

  group('a connection', () {
    setUp(() {
      connection = MacosTextInputConnection(window, client);
      window.imeHandler = connection;
    });

    test('enable sends the caret, once until it moves', () {
      client.caret = const Rect.fromLTWH(12, 30, 0, 18);
      connection.enable();
      connection.updateEditingState();
      expect(window.carets, <String>[HostCommands.imeCaret(12, 30, 1, 18)],
          reason: 'a zero-width caret is sent one point wide, and an '
              'unchanged one is not sent again');

      client.caret = const Rect.fromLTWH(20, 30, 1, 18);
      connection.updateEditingState();
      expect(window.carets.last, HostCommands.imeCaret(20, 30, 1, 18));
    });

    test('the text around the caret is pushed, once until it changes', () {
      // What the host answers selectedRange and
      // attributedSubstringForProposedRange: with - the press-and-hold accent
      // menu reads it to know which letter it replaces.
      client.surrounding = ImeSurroundingText(text: 'café', cursor: 3);
      connection.enable();
      connection.updateEditingState();
      expect(window.surroundings,
          <String>[HostCommands.imeSurrounding('café', 3, 3)]);

      client.surrounding =
          ImeSurroundingText(text: 'café au', cursor: 7, anchor: 5);
      connection.updateEditingState();
      expect(window.surroundings.last,
          HostCommands.imeSurrounding('café au', 5, 7));
      expect(const MacosTextInputBackend().usesSurroundingText, isTrue);
    });

    test('a long document is sent as a window around the caret', () {
      // The host reads lines of at most 8192 bytes; a whole document would
      // not fit, and an input method reads a few characters of context.
      final String text = 'a' * 5000;
      client.surrounding = ImeSurroundingText(text: text, cursor: 2500);
      connection.enable();
      expect(
          window.surroundings.single,
          HostCommands.imeSurrounding('a' * (2 * kMacosImeSurroundingWindow),
              kMacosImeSurroundingWindow, kMacosImeSurroundingWindow));
    });

    test('a sensitive field shares nothing', () {
      client
        ..configuration = TextInputConfiguration.password
        ..surrounding = ImeSurroundingText(text: 'hunter2', cursor: 7);
      connection.enable();
      expect(window.surroundings, isEmpty);
    });

    test('a deletion around the caret reaches the client', () {
      // An insertText:replacementRange: that reaches past the selection -
      // 'é' replacing the 'e' the accent menu was opened on.
      connection
        ..enable()
        ..onDeleteSurrounding(1, 0);
      expect(client.deletions, <(int, int)>[(1, 0)]);
    });

    test('a preedit reaches the client with its selection', () {
      connection
        ..enable()
        ..onComposition('にほ', 1, 1);
      expect(client.compositions.single, ('にほ', 1, 2));
      expect(connection.isComposing, isTrue);
    });

    test('an empty preedit ends the composition, once', () {
      connection
        ..enable()
        ..onComposition('x', 1, 0)
        ..onComposition('', 0, 0)
        ..onComposition('', 0, 0);
      expect(
          client.compositions, <(String, int, int)>[('x', 1, 1), ('', 0, 0)]);
      expect(connection.isComposing, isFalse);
    });

    test('a commit reaches the client and ends the composition', () {
      connection
        ..enable()
        ..onComposition('にほん', 3, 0)
        ..onCommit('日本');
      expect(client.commits, <String>['日本']);
      expect(connection.isComposing, isFalse);
    });

    test('a selection past the end is clamped, not thrown', () {
      connection
        ..enable()
        ..onComposition('ab', 5, 9);
      expect(client.compositions.single, ('ab', 2, 2));
    });

    test('disable cancels on the host and ends the preedit in the field', () {
      connection
        ..enable()
        ..onComposition('x', 1, 0);
      window.commands.clear();
      connection.disable();
      expect(window.commands, <String>[HostCommands.imeCancel()]);
      expect(client.compositions.last, ('', 0, 0));
      expect(connection.isEnabled, isFalse);
    });

    test('a password field takes no preedit', () {
      client.configuration = TextInputConfiguration.password;
      connection
        ..enable()
        ..onComposition('x', 1, 0)
        ..onCommit('y');
      expect(connection.isEnabled, isFalse);
      expect(client.compositions, isEmpty);
      expect(client.commits, isEmpty);
    });

    test('nothing reaches a client before enable or after detach', () {
      connection.onComposition('x', 1, 0);
      expect(client.compositions, isEmpty);

      connection
        ..enable()
        ..detach()
        ..onCommit('y');
      expect(client.commits, isEmpty);
      expect(window.imeHandler, isNull);
    });

    test('detach leaves a newer connection in place', () {
      final MacosTextInputConnection newer =
          MacosTextInputConnection(window, _Client());
      window.imeHandler = newer;
      connection.detach();
      expect(window.imeHandler, same(newer));
    });
  });

  test('IME text is base64 of UTF-8, and anything else is refused', () {
    expect(decodeImeText(base64.encode(utf8.encode('日本'))), '日本');
    expect(decodeImeText(''), '');
    expect(decodeImeText('%%%'), isNull);
  });

  test('the two composition lines parse', () {
    final List<String> seen = <String>[];
    HostProtocolParser(_Sink(seen)).addBytes(utf8.encode(
      'COMPOSE=44Gr44G7:2:0\nCOMPOSE=-:0:0\nCOMMIT=5pel5pys\n'
      'COMPOSE=abc\n',
    ));
    expect(seen, <String>[
      'compose 44Gr44G7 2 0',
      'compose  0 0',
      'commit 5pel5pys',
      'error BAD_COMPOSE',
    ]);
  });

  test('a deletion around the selection parses, and a broken one is refused',
      () {
    final List<String> seen = <String>[];
    HostProtocolParser(_Sink(seen)).addBytes(
        utf8.encode('IME_DELETE=1:0\nIME_DELETE=2:3\nIME_DELETE=4\n'));
    expect(seen, <String>['delete 1 0', 'delete 2 3', 'error BAD_IME_DELETE']);
  });

  test('the surrounding text command is base64, or - when empty', () {
    expect(HostCommands.imeSurrounding('', 0, 0), 'IME_SURROUNDING - 0 0\n');
    expect(HostCommands.imeSurrounding('é', 0, 1),
        'IME_SURROUNDING ${base64.encode(utf8.encode('é'))} 0 1\n');
  });
}

final class _Sink with HostMessageSinkAdapter {
  _Sink(this.seen);
  final List<String> seen;

  @override
  void onImeDelete(int before, int after) => seen.add('delete $before $after');

  @override
  void onComposition(String base64, int selectedLocation, int selectedLength) =>
      seen.add('compose $base64 $selectedLocation $selectedLength');

  @override
  void onCommit(String base64) => seen.add('commit $base64');

  @override
  void onError(String code) => seen.add('error $code');
}

final class _Window implements MacosImeWindow {
  final List<String> commands = <String>[];

  List<String> get carets =>
      commands.where((String c) => c.startsWith('IME_CARET')).toList();

  List<String> get surroundings =>
      commands.where((String c) => c.startsWith('IME_SURROUNDING')).toList();

  @override
  NativeWindowId get id => const NativeWindowId(4);

  @override
  MacosImeHandler? imeHandler;

  @override
  bool sendImeCommand(String command) {
    commands.add(command);
    return true;
  }
}

final class _Client implements TextInputClient {
  TextInputConfiguration configuration = const TextInputConfiguration();
  Rect caret = const Rect.fromLTWH(0, 0, 1, 16);
  final List<(String, int, int)> compositions = <(String, int, int)>[];
  final List<String> commits = <String>[];
  final List<(int, int)> deletions = <(int, int)>[];
  ImeSurroundingText surrounding = ImeSurroundingText.empty;

  @override
  TextInputConfiguration get textInputConfiguration => configuration;

  @override
  ImeSurroundingText get surroundingText => surrounding;

  @override
  Rect get caretRect => caret;

  @override
  void updateComposition(ImeComposition composition) => compositions
      .add((composition.text, composition.cursorStart, composition.cursorEnd));

  @override
  void commitText(String text) => commits.add(text);

  @override
  void deleteSurroundingText({
    required int beforeLength,
    required int afterLength,
  }) =>
      deletions.add((beforeLength, afterLength));
}
