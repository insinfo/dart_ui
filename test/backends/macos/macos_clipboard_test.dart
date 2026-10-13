import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  group('HTML and images', () {
    final Uint8List png = Uint8List.fromList(
        <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 1, 2, 3]);

    test('an image comes back as the PNG bytes the host sent', () async {
      final channel =
          _Channel(typedReads: <String, (HostClipboardResult, String)>{
        'png': (HostClipboardResult.data, base64.encode(png)),
      });
      expect(await MacosClipboard(() => channel).readImage(), png);
      expect(channel.typedReadTypes, <String>['png']);
    });

    test('no image is null, not an error', () async {
      expect(await MacosClipboard(() => _Channel()).readImage(), isNull);
    });

    test('bytes that are not a PNG are refused by name', () async {
      final clipboard = MacosClipboard(
          () => _Channel(typedReads: <String, (HostClipboardResult, String)>{
                'png': (HostClipboardResult.data, base64.encode(<int>[1, 2])),
              }));
      await expectLater(
        clipboard.readImage(),
        throwsA(isA<ClipboardException>()
            .having((e) => e.operation, 'operation', 'readImage')
            .having((e) => e.reason, 'reason', contains('not a PNG'))),
      );
    });

    test('an image the host could not convert is a failure, not null',
        () async {
      final clipboard = MacosClipboard(
          () => _Channel(typedReads: <String, (HostClipboardResult, String)>{
                'png': (HostClipboardResult.failed, ''),
              }));
      await expectLater(
        clipboard.readImage(),
        throwsA(isA<ClipboardException>()
            .having((e) => e.operation, 'operation', 'readImage')),
      );
    });

    test('writing an image sends base64 of the PNG as type png', () async {
      final channel = _Channel(write: HostClipboardResult.written);
      await MacosClipboard(() => channel).writeImage(png);
      expect(channel.typedWrites.single.$1, 'png');
      expect(base64.decode(channel.typedWrites.single.$2), png);
    });

    test('writing something that is not a PNG is the caller\'s error',
        () async {
      final channel = _Channel(write: HostClipboardResult.written);
      await expectLater(
        MacosClipboard(() => channel).writeImage(Uint8List(4)),
        throwsArgumentError,
      );
      expect(channel.typedWrites, isEmpty);
    });

    test('HTML is read as UTF-8', () async {
      final channel =
          _Channel(typedReads: <String, (HostClipboardResult, String)>{
        'html': (HostClipboardResult.data, _encode('<b>olá</b>')),
      });
      expect(await MacosClipboard(() => channel).readHtml(), '<b>olá</b>');
    });

    test('HTML is written with its plain-text alternative', () async {
      final channel = _Channel(write: HostClipboardResult.written);
      await MacosClipboard(() => channel)
          .writeHtml('<p>olá <b>mundo</b></p>', plainText: 'olá mundo!');
      final (String type, String payload) = channel.typedWrites.single;
      expect(type, 'html');
      final List<String> halves = payload.split('.');
      expect(halves, hasLength(2));
      expect(utf8.decode(base64.decode(halves[0])), '<p>olá <b>mundo</b></p>');
      expect(utf8.decode(base64.decode(halves[1])), 'olá mundo!');
    });

    test('without a plain-text alternative one is derived from the HTML',
        () async {
      final channel = _Channel(write: HostClipboardResult.written);
      await MacosClipboard(() => channel)
          .writeHtml('<p>um</p><p>dois &amp; três</p>');
      final String payload = channel.typedWrites.single.$2;
      expect(utf8.decode(base64.decode(payload.split('.')[1])),
          'um\n\ndois & três');
    });

    test('formats are parsed from the host\'s list', () async {
      final channel =
          _Channel(typedReads: <String, (HostClipboardResult, String)>{
        'formats': (HostClipboardResult.data, 'text,image'),
      });
      expect(await MacosClipboard(() => channel).availableFormats(),
          <ClipboardFormat>{ClipboardFormat.text, ClipboardFormat.image});
    });

    test('an empty pasteboard has no formats', () async {
      final channel =
          _Channel(typedReads: <String, (HostClipboardResult, String)>{
        'formats': (HostClipboardResult.data, ''),
      });
      expect(await MacosClipboard(() => channel).availableFormats(), isEmpty);
    });

    test('a host without clipboard-rich is refused before anything is sent',
        () async {
      final channel = _Channel(rich: false, write: HostClipboardResult.written);
      final clipboard = MacosClipboard(() => channel);
      for (final Future<Object?> Function() operation
          in <Future<Object?> Function()>[
        clipboard.readImage,
        clipboard.readHtml,
        clipboard.availableFormats,
        () => clipboard.writeImage(png),
        () => clipboard.writeHtml('<i>x</i>'),
      ]) {
        await expectLater(
          operation(),
          throwsA(isA<ClipboardException>()
              .having((e) => e.reason, 'reason', contains('clipboard-rich'))),
        );
      }
      expect(channel.typedReadTypes, isEmpty);
      expect(channel.typedWrites, isEmpty);
      // Text still works on that host.
      await clipboard.writeText('ok');
      expect(channel.written, hasLength(1));
    });

    test('a refused image write is a named failure', () async {
      final clipboard =
          MacosClipboard(() => _Channel(write: HostClipboardResult.failed));
      await expectLater(
        clipboard.writeImage(png),
        throwsA(isA<ClipboardException>()
            .having((e) => e.operation, 'operation', 'writeImage')),
      );
    });

    test('a typed answer to a text read is refused, not decoded', () async {
      final clipboard =
          MacosClipboard(() => _Channel(read: (HostClipboardResult.data, '')));
      await expectLater(
        clipboard.readText(),
        throwsA(isA<ClipboardException>()),
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
  _Channel({
    this.read,
    this.write,
    this.error,
    this.rich = true,
    this.typedReads = const <String, (HostClipboardResult, String)>{},
  });

  final (HostClipboardResult, String)? read;
  final HostClipboardResult? write;
  final Object? error;
  final bool rich;
  final Map<String, (HostClipboardResult, String)> typedReads;
  final List<String> written = <String>[];

  /// Every typed write, as (type, payload).
  final List<(String, String)> typedWrites = <(String, String)>[];

  /// Every typed read's type, in order.
  final List<String> typedReadTypes = <String>[];

  @override
  bool get supportsClipboard => true;

  @override
  bool get supportsRichClipboard => rich;

  @override
  Future<(HostClipboardResult, String)> requestClipboardReadType(
    String type,
    Duration timeout,
  ) async {
    if (error != null) throw error!;
    typedReadTypes.add(type);
    return typedReads[type] ?? (HostClipboardResult.none, '');
  }

  @override
  Future<HostClipboardResult> requestClipboardWriteType(
    String type,
    String payload,
    Duration timeout,
  ) async {
    if (error != null) throw error!;
    typedWrites.add((type, payload));
    return write!;
  }

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
