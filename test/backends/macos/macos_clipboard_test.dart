import 'dart:async';
import 'dart:convert';

import 'package:dart_ui/src/backends/macos/host_process.dart';
import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/macos_clipboard.dart';
import 'package:dart_ui/src/platform/clipboard.dart';
import 'package:test/test.dart';

void main() {
  group('reading', () {
    test('no text on the pasteboard is null, not an error', () async {
      final clipboard =
          MacosClipboard(() => _Channel(read: (HostClipboardResult.none, '')));
      expect(await clipboard.readText(), isNull);
    });

    test('text comes back decoded, newlines and all', () async {
      final clipboard = MacosClipboard(() =>
          _Channel(read: (HostClipboardResult.text, _encode('olá\nmundo 🌍'))));
      expect(await clipboard.readText(), 'olá\nmundo 🌍');
    });

    test('the empty string is text, distinct from null', () async {
      final clipboard =
          MacosClipboard(() => _Channel(read: (HostClipboardResult.text, '')));
      expect(await clipboard.readText(), '');
    });

    test('a pasteboard the host could not read is a named failure', () async {
      final clipboard = MacosClipboard(
          () => _Channel(read: (HostClipboardResult.failed, '')));
      await expectLater(
        clipboard.readText(),
        throwsA(isA<ClipboardException>()
            .having((e) => e.operation, 'operation', 'readText')
            .having((e) => e.backend, 'backend', 'macos')),
      );
    });

    test('bytes that are not base64 of UTF-8 are refused, not guessed at',
        () async {
      final clipboard = MacosClipboard(
          () => _Channel(read: (HostClipboardResult.text, '%%%')));
      await expectLater(
        clipboard.readText(),
        throwsA(isA<ClipboardException>()
            .having((e) => e.reason, 'reason', contains('base64'))),
      );
    });
  });

  group('writing', () {
    test('the host receives base64 of UTF-8', () async {
      final channel = _Channel(write: HostClipboardResult.written);
      await MacosClipboard(() => channel).writeText('olá\nmundo');
      expect(utf8.decode(base64.decode(channel.written.single)), 'olá\nmundo');
    });

    test('a refused write is a named failure', () async {
      final clipboard =
          MacosClipboard(() => _Channel(write: HostClipboardResult.failed));
      await expectLater(
        clipboard.writeText('x'),
        throwsA(isA<ClipboardException>()
            .having((e) => e.operation, 'operation', 'writeText')
            .having((e) => e.reason, 'reason', contains('refused'))),
      );
    });
  });

  group('when no host can answer', () {
    test('no window means no host, and the failure says so', () async {
      final clipboard = MacosClipboard(() => null);
      await expectLater(
        clipboard.readText(),
        throwsA(isA<ClipboardException>()
            .having((e) => e.reason, 'reason', contains('no open window'))),
      );
      await expectLater(
        clipboard.writeText('x'),
        throwsA(isA<ClipboardException>()),
      );
    });

    test('a host that does not answer in time is a failure, not a hang',
        () async {
      final clipboard = MacosClipboard(
        () => _Channel(error: TimeoutException('late')),
        timeout: const Duration(milliseconds: 250),
      );
      await expectLater(
        clipboard.readText(),
        throwsA(isA<ClipboardException>()
            .having((e) => e.reason, 'reason', contains('250 ms'))),
      );
    });

    test('a host that exits mid-request names the exit', () async {
      final clipboard = MacosClipboard(() =>
          _Channel(error: StateError('the macOS host exited with status -9')));
      await expectLater(
        clipboard.writeText('x'),
        throwsA(isA<ClipboardException>()
            .having((e) => e.reason, 'reason', contains('exited'))),
      );
    });
  });

  test('the host is looked up per call, so a recovered window is used',
      () async {
    _Channel? current;
    final clipboard = MacosClipboard(() => current);
    await expectLater(clipboard.readText(), throwsA(isA<ClipboardException>()));
    current = _Channel(read: (HostClipboardResult.text, _encode('back')));
    expect(await clipboard.readText(), 'back');
  });
}

String _encode(String text) => base64.encode(utf8.encode(text));

final class _Channel implements MacosClipboardChannel {
  _Channel({this.read, this.write, this.error});

  final (HostClipboardResult, String)? read;
  final HostClipboardResult? write;
  final Object? error;
  final List<String> written = <String>[];

  @override
  bool get supportsClipboard => true;

  @override
  Future<(HostClipboardResult, String)> requestClipboardRead(
    Duration timeout,
  ) async {
    if (error != null) throw error!;
    return read!;
  }

  @override
  Future<HostClipboardResult> requestClipboardWrite(
    String base64,
    Duration timeout,
  ) async {
    if (error != null) throw error!;
    written.add(base64);
    return write!;
  }
}
