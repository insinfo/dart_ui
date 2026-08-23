import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/platform/drag_drop.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

void main() {
  group('DragAction', () {
    test('only a move destroys the source', () {
      expect(DragAction.move.destroysSource, isTrue);
      for (final DragAction action in <DragAction>[
        DragAction.none,
        DragAction.copy,
        DragAction.link,
        DragAction.ask,
      ]) {
        expect(action.destroysSource, isFalse, reason: action.name);
      }
    });
  });

  group('resolveDragAction', () {
    test('takes the preferred action when it is allowed', () {
      expect(
        resolveDragAction(
          <DragAction>{DragAction.copy, DragAction.move},
          preferred: DragAction.move,
        ),
        DragAction.move,
      );
    });

    test('falls back to copy, which cannot lose data', () {
      expect(
        resolveDragAction(
          <DragAction>{DragAction.copy, DragAction.move},
          preferred: DragAction.link,
        ),
        DragAction.copy,
      );
    });

    test('walks the fallback order when copy is not on offer', () {
      expect(
        resolveDragAction(<DragAction>{DragAction.link, DragAction.move}),
        DragAction.move,
      );
      expect(
        resolveDragAction(<DragAction>{DragAction.link}),
        DragAction.link,
      );
      expect(resolveDragAction(<DragAction>{}), DragAction.none);
    });

    test('never resolves to none just because none was preferred', () {
      expect(
        resolveDragAction(
          <DragAction>{DragAction.none, DragAction.copy},
          preferred: DragAction.none,
        ),
        DragAction.copy,
      );
    });
  });

  group('dragActionForModifiers', () {
    test('the convention every desktop agrees on', () {
      expect(
        dragActionForModifiers(<KeyModifier>{KeyModifier.control}),
        DragAction.copy,
      );
      expect(
        dragActionForModifiers(<KeyModifier>{KeyModifier.shift}),
        DragAction.move,
      );
      expect(
        dragActionForModifiers(
          <KeyModifier>{KeyModifier.control, KeyModifier.shift},
        ),
        DragAction.link,
      );
    });

    test('no modifier is not a preference', () {
      expect(dragActionForModifiers(const <KeyModifier>{}), isNull);
      expect(
        dragActionForModifiers(<KeyModifier>{KeyModifier.alt}),
        isNull,
      );
    });
  });

  group('parseUriList', () {
    test('reads CRLF, the spelling RFC 2483 mandates', () {
      expect(
        parseUriList('file:///a\r\nfile:///b\r\n').map((Uri u) => u.path),
        <String>['/a', '/b'],
      );
    });

    test('tolerates the LF-only files half the world sends', () {
      expect(parseUriList('file:///a\nfile:///b'), hasLength(2));
    });

    test('skips comments and blank lines', () {
      expect(
        parseUriList('# a comment\n\nfile:///a\n'),
        <Uri>[Uri.parse('file:///a')],
      );
    });

    test("skips GNOME's leading action word", () {
      expect(
        parseUriList('copy\nfile:///a\n'),
        <Uri>[Uri.parse('file:///a')],
      );
    });

    test('one unparseable line does not lose the others', () {
      expect(
        parseUriList('not a uri\nfile:///a\n').map((Uri u) => u.path),
        <String>['/a'],
        reason: 'a multi-file drop must not be lost to one bad line',
      );
    });
  });

  group('MemoryDragData', () {
    test('text is offered under every spelling of text', () async {
      final MemoryDragData data = MemoryDragData.text('hello');
      expect(
        data.formats,
        containsAll(<String>[
          DragFormats.text,
          DragFormats.plainText,
          DragFormats.utf8String,
        ]),
      );
      expect(await data.readText(), 'hello');
    });

    test('non-ASCII text survives the round trip', () async {
      final MemoryDragData data = MemoryDragData.text('caf\u00e9 \u4e2d');
      expect(await data.readText(), 'caf\u00e9 \u4e2d');
    });

    test('an unknown format is null, not an error', () async {
      final MemoryDragData data = MemoryDragData.text('x');
      expect(await data.readBytes('image/png'), isNull);
    });

    test('uris are encoded CRLF-terminated', () async {
      final MemoryDragData data =
          MemoryDragData.uris(<Uri>[Uri.parse('file:///a')]);
      expect(
        utf8.decode(data.bytesOf(DragFormats.uriList)!),
        'file:///a\r\n',
      );
      expect(await data.readUris(), <Uri>[Uri.parse('file:///a')]);
    });

    test('windows file paths round-trip through readFilePaths', () async {
      final MemoryDragData data =
          MemoryDragData.filePaths(<String>[r'C:\tmp\a.txt']);
      expect(await data.readFilePaths(), <String>[r'C:\tmp\a.txt']);
    });

    test('posix file paths round-trip through readFilePaths', () async {
      final MemoryDragData data =
          MemoryDragData.filePaths(<String>['/home/a.txt']);
      expect(await data.readFilePaths(), <String>['/home/a.txt']);
    });

    test('a non-file URI is skipped rather than turned into a path', () async {
      final MemoryDragData data =
          MemoryDragData.uris(<Uri>[Uri.parse('https://example.com/a')]);
      expect(await data.readUris(), hasLength(1));
      expect(await data.readFilePaths(), isEmpty);
    });

    test('malformed UTF-8 is replaced, not thrown on', () async {
      final MemoryDragData data = MemoryDragData(<String, Uint8List>{
        DragFormats.text: Uint8List.fromList(<int>[0x41, 0xFF, 0x42]),
      });
      final String? text = await data.readText();
      expect(text, isNotNull);
      expect(text!.startsWith('A'), isTrue);
      expect(text.endsWith('B'), isTrue);
    });
  });

  group('DragDataReading', () {
    test('preferredFormat follows the caller order, not the source order', () {
      final MemoryDragData data = MemoryDragData(<String, Uint8List>{
        DragFormats.text: Uint8List(0),
        DragFormats.uriList: Uint8List(0),
      });
      expect(
        data.preferredFormat(
          <String>[DragFormats.uriList, DragFormats.text],
        ),
        DragFormats.uriList,
      );
      expect(
        data.preferredFormat(
          <String>[DragFormats.text, DragFormats.uriList],
        ),
        DragFormats.text,
      );
      expect(data.preferredFormat(<String>['image/png']), isNull);
    });

    test('hasFiles and hasText recognise every spelling', () {
      expect(MemoryDragData.filePaths(<String>['/a']).hasFiles, isTrue);
      expect(MemoryDragData.filePaths(<String>['/a']).hasText, isFalse);
      expect(MemoryDragData.text('x').hasText, isTrue);
      expect(
        MemoryDragData(<String, Uint8List>{
          DragFormats.gnomeCopiedFiles: Uint8List(0),
        }).hasFiles,
        isTrue,
      );
    });
  });

  group('LazyDragData', () {
    test('produces on demand and only once', () async {
      int calls = 0;
      final LazyDragData data = LazyDragData(
        <String>[DragFormats.text],
        (String format) async {
          calls++;
          return Uint8List.fromList(utf8.encode('hi'));
        },
      );

      expect(await data.readText(), 'hi');
      expect(await data.readText(), 'hi');
      expect(calls, 1, reason: 'the transfer consumed the offer');
    });

    test('a null answer is cached too, because the offer is gone', () async {
      int calls = 0;
      final LazyDragData data = LazyDragData(
        <String>[DragFormats.text],
        (String format) async {
          calls++;
          return null;
        },
      );

      expect(await data.readBytes(DragFormats.text), isNull);
      expect(await data.readBytes(DragFormats.text), isNull);
      expect(calls, 1, reason: 'asking again would hang, not fail again');
    });

    test('a format that was never offered is not produced', () async {
      final LazyDragData data = LazyDragData(
        <String>[DragFormats.text],
        (String format) async => Uint8List(1),
      );
      expect(await data.readBytes(DragFormats.uriList), isNull);
    });
  });

  group('DropResponse', () {
    test('a rejection is not accepted, however it is spelled', () {
      expect(const DropResponse.reject().isAccepted, isFalse);
      expect(
        const DropResponse(acceptedFormat: null).isAccepted,
        isFalse,
      );
      expect(
        const DropResponse(
          acceptedFormat: DragFormats.text,
          action: DragAction.none,
        ).isAccepted,
        isFalse,
        reason: 'accepting a format but promising nothing leaves the source '
            'waiting for a drop that will never be performed',
      );
    });

    test('an accepted response names both halves', () {
      const DropResponse response = DropResponse(
        acceptedFormat: DragFormats.uriList,
        action: DragAction.move,
      );
      expect(response.isAccepted, isTrue);
      expect(response.acceptedFormat, DragFormats.uriList);
      expect(response.action, DragAction.move);
    });
  });

  group('UnavailableDragDrop', () {
    test('registration fails by name rather than silently', () async {
      const UnavailableDragDrop backend = UnavailableDragDrop(
        name: 'headless',
        reason: 'no other application to drag from',
      );
      expect(backend.canStartDrag, isFalse);
      await expectLater(
        backend.registerDropTarget(
          window: _FakeWindow(),
          handler: _RecordingHandler(),
        ),
        throwsA(
          isA<DragDropException>()
              .having((DragDropException e) => e.backend, 'backend', 'headless')
              .having((DragDropException e) => e.operation, 'operation',
                  'registerDropTarget'),
        ),
      );
    });

    test('the failure arrives as a rejected future, not at the call site', () {
      const UnavailableDragDrop backend =
          UnavailableDragDrop(name: 'web', reason: 'not implemented yet');
      // No await, no throw: the future is created without raising, which is
      // what lets a caller store it and await it later.
      final Future<DragAction> pending =
          backend.startDrag(DragRequest(
        window: _FakeWindow(),
        data: MemoryDragData.text('x'),
      ));
      expect(pending, throwsA(isA<DragDropException>()));
    });
  });

  group('DragDropException', () {
    test('names the operation, the backend and the platform code', () {
      const DragDropException error = DragDropException(
        operation: 'RegisterDragDrop',
        reason: 'already registered',
        backend: 'win32',
        errorCode: 0x80040101,
      );
      final String text = error.toString();
      expect(text, contains('RegisterDragDrop'));
      expect(text, contains('win32'));
      expect(text, contains('80040101'));
      expect(text, contains('already registered'));
    });
  });

  group('FakeDragDrop', () {
    test('hands back the newest live handler', () async {
      final FakeDragDrop backend = FakeDragDrop();
      final _RecordingHandler first = _RecordingHandler();
      final _RecordingHandler second = _RecordingHandler();

      await backend.registerDropTarget(
          window: _FakeWindow(), handler: first);
      final DropTargetRegistration registration = await backend
          .registerDropTarget(window: _FakeWindow(), handler: second);

      expect(backend.handler, same(second));
      await registration.revoke();
      expect(registration.isActive, isFalse);
      expect(backend.handler, same(first));
    });

    test('records drag requests and plays back a result', () async {
      final FakeDragDrop backend = FakeDragDrop()
        ..dragResult = DragAction.move;
      final DragRequest request = DragRequest(
        window: _FakeWindow(),
        data: MemoryDragData.text('x'),
        allowedActions: const <DragAction>{DragAction.move},
      );

      expect(await backend.startDrag(request), DragAction.move);
      expect(backend.requests.single, same(request));
    });
  });

  group('DragSessionEvent', () {
    test('carries the client position and the modifiers verbatim', () {
      final DragSessionEvent event = DragSessionEvent(
        windowId: const NativeWindowId(7),
        position: const Offset(12, 34),
        data: MemoryDragData.text('x'),
        allowedActions: const <DragAction>{DragAction.copy},
        modifiers: const <KeyModifier>{KeyModifier.shift},
      );
      expect(event.windowId.value, 7);
      expect(event.position, const Offset(12, 34));
      expect(event.screenPosition, isNull);
      expect(event.modifiers, contains(KeyModifier.shift));
      expect(event.suggestedAction, DragAction.copy);
    });
  });
}

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

final class _RecordingHandler implements DropTargetHandler {
  @override
  DropResponse onDragEnter(DragSessionEvent event) =>
      const DropResponse.reject();

  @override
  DropResponse onDragOver(DragSessionEvent event) =>
      const DropResponse.reject();

  @override
  void onDragLeave() {}

  @override
  Future<DragAction> onDrop(DragSessionEvent event) async => DragAction.none;
}

/// The narrowest possible [NativeWindow]: the port only ever reads its id.
final class _FakeWindow implements NativeWindow {
  @override
  NativeWindowId get id => const NativeWindowId(1);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
