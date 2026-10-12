import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/macos_drag_drop.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/platform/drag_drop.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

const int _copy = 1;
const int _link = 2;
const int _move = 16;
const int _option = 1 << 19;
const int _command = 1 << 20;

String _b64(String text) => base64.encode(utf8.encode(text));

void main() {
  late _Window window;
  late _Handler handler;
  late MacosDropTarget target;

  setUp(() {
    window = _Window();
    handler = _Handler();
    target = MacosDropTarget(window, handler);
    window.dropTarget = target;
  });

  test('files arrive as the uri-list every backend builds', () async {
    target
      ..onItem('file', _b64('/tmp/a b.pdf'))
      ..onItem('file', _b64('/tmp/c.svg'))
      ..onDrag(HostDragPhase.enter, 10, 20, _copy | _move, 0);

    final DragSessionEvent enter = handler.enters.single;
    expect(enter.position, const Offset(10, 20));
    expect(enter.data.formats, <String>[DragFormats.uriList]);
    expect(await enter.data.readFilePaths(),
        <String>['/tmp/a b.pdf', '/tmp/c.svg']);
    expect(
      await enter.data.readBytes(DragFormats.uriList),
      MemoryDragData.filePaths(<String>['/tmp/a b.pdf', '/tmp/c.svg'])
          .bytesOf(DragFormats.uriList),
    );
  });

  test('text arrives as UTF-8 text', () async {
    target
      ..onItem('text', _b64('olá'))
      ..onDrag(HostDragPhase.enter, 0, 0, _copy, 0);
    expect(
        utf8.decode(
            (await handler.enters.single.data.readBytes(DragFormats.text))!),
        'olá');
  });

  test('every answer goes back to the host as an NSDragOperation', () {
    handler.response = const DropResponse(
        acceptedFormat: DragFormats.uriList, action: DragAction.move);
    target
      ..onItem('file', _b64('/x'))
      ..onDrag(HostDragPhase.enter, 0, 0, _copy | _move, 0);
    handler.response = const DropResponse.reject();
    target.onDrag(HostDragPhase.over, 1, 1, _copy | _move, 0);

    expect(
        window.commands,
        <String>[
          HostCommands.dropResponse(_move),
          HostCommands.dropResponse(0),
        ],
        reason: 'a refusal is 0, which makes the host decline the drop');
  });

  test('a drop reaches the handler once, with the last position', () async {
    target
      ..onItem('file', _b64('/x'))
      ..onDrag(HostDragPhase.enter, 0, 0, _copy, 0)
      ..onDrag(HostDragPhase.drop, 5, 6, _copy, 0)
      ..onDrag(HostDragPhase.drop, 5, 6, _copy, 0);
    expect(handler.drops.single.position, const Offset(5, 6));
    expect(await handler.drops.single.data.readFilePaths(), <String>['/x']);
  });

  test('a leave arrives once per enter, and a drag starts clean', () async {
    target
      ..onItem('file', _b64('/old'))
      ..onDrag(HostDragPhase.enter, 0, 0, _copy, 0)
      ..onDrag(HostDragPhase.leave, 0, 0, 0, 0)
      ..onDrag(HostDragPhase.leave, 0, 0, 0, 0);
    expect(handler.leaves, 1);

    target
      ..onItem('text', _b64('new'))
      ..onDrag(HostDragPhase.enter, 0, 0, _copy, 0);
    expect(handler.enters.last.data.formats, contains(DragFormats.text));
    expect(
        handler.enters.last.data.formats, isNot(contains(DragFormats.uriList)),
        reason: 'the files of the last drag must not leak into this one');
  });

  test('revoke unregisters on the host and ends a drag in progress', () async {
    target
      ..onItem('file', _b64('/x'))
      ..onDrag(HostDragPhase.enter, 0, 0, _copy, 0);
    await target.revoke();
    await target.revoke();
    expect(handler.leaves, 1);
    expect(window.dropTarget, isNull);
    expect(window.commands.last, HostCommands.dropUnregister());
    expect(target.isActive, isFalse);

    target.onDrag(HostDragPhase.drop, 0, 0, _copy, 0);
    expect(handler.drops, isEmpty);
  });

  group('actions', () {
    test('the mask says what the source allows', () {
      expect(macosAllowedActions(_copy | _link),
          <DragAction>{DragAction.copy, DragAction.link});
      expect(macosAllowedActions(4), <DragAction>{DragAction.move},
          reason: 'generic is the destination choosing, which is a move');
    });

    test('the modifiers say what the user asked for, as in Finder', () {
      final all = <DragAction>{
        DragAction.copy,
        DragAction.move,
        DragAction.link
      };
      expect(macosSuggestedAction(all, 0), DragAction.copy);
      expect(macosSuggestedAction(all, _option), DragAction.copy);
      expect(macosSuggestedAction(all, _command), DragAction.move);
      expect(macosSuggestedAction(all, _option | _command), DragAction.link);
      expect(macosSuggestedAction(<DragAction>{DragAction.move}, 0),
          DragAction.move,
          reason: 'what is allowed wins over the default');
      expect(macosSuggestedAction(<DragAction>{}, 0), DragAction.none);
    });

    test('the modifiers reach the handler', () {
      target
        ..onItem('file', _b64('/x'))
        ..onDrag(HostDragPhase.enter, 0, 0, _copy, _option);
      expect(handler.enters.single.modifiers, <KeyModifier>{KeyModifier.alt});
    });

    test('operations map both ways', () {
      expect(macosDragOperation(DragAction.copy), _copy);
      expect(macosDragOperation(DragAction.move), _move);
      expect(macosDragOperation(DragAction.link), _link);
      expect(macosDragOperation(DragAction.none), 0);
    });
  });

  group('dragging out', () {
    test('sends DRAG_START and answers with what the destination did',
        () async {
      // Files as file URLs and text as a string, allowing copy and move;
      // the host's NSDraggingSource ends with the NSDragOperation performed.
      expect(const MacosDragDropBackend().canStartDrag, isTrue);
      final _DragWindow window = _DragWindow();
      final Future<DragAction> drag = const MacosDragDropBackend().startDrag(
        DragRequest(
          window: window,
          data: MemoryDragData(<String, Uint8List>{
            DragFormats.uriList:
                utf8.encode('file:///tmp/a.pdf\r\nfile:///tmp/b.svg\r\n'),
            DragFormats.text: utf8.encode('olá'),
          }),
          allowedActions: const <DragAction>{DragAction.copy, DragAction.move},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final String command = window.commands.single;
      final List<String> parts = command.trim().split(' ');
      expect(parts[0], 'DRAG_START');
      expect(parts[2], '17', reason: 'copy (1) | move (16)');
      expect(utf8.decode(base64.decode(parts[3])), '/tmp/a.pdf\n/tmp/b.svg');
      expect(utf8.decode(base64.decode(parts[4])), 'olá');

      macosDragSourceEnded(int.parse(parts[1]), 16);
      expect(await drag, DragAction.move);
    });

    test('a drag nothing was dropped on ends with none', () async {
      final _DragWindow window = _DragWindow();
      final Future<DragAction> drag = const MacosDragDropBackend().startDrag(
        DragRequest(window: window, data: MemoryDragData.text('x')),
      );
      await Future<void>.delayed(Duration.zero);
      macosDragSourceEnded(
          int.parse(window.commands.single.trim().split(' ')[1]), 0);
      expect(await drag, DragAction.none);
    });

    test('no mouse press to start from is a refusal by name', () async {
      // AppKit begins a session only from a mouse event in the view.
      final _DragWindow window = _DragWindow();
      final Future<DragAction> drag = const MacosDragDropBackend().startDrag(
        DragRequest(window: window, data: MemoryDragData.text('x')),
      );
      await Future<void>.delayed(Duration.zero);
      macosDragSourceEnded(
          int.parse(window.commands.single.trim().split(' ')[1]), -1);
      await expectLater(drag, throwsA(isA<DragDropException>()));
    });

    test('the end line parses, and a broken one is refused', () {
      final List<String> seen = <String>[];
      HostProtocolParser(_Sink(seen)).addBytes(utf8.encode(
          'DRAG_SOURCE_END=4:16\nDRAG_SOURCE_END=5:-1\nDRAG_SOURCE_END=6\n'));
      expect(seen, <String>[
        'source end 4 16',
        'source end 5 -1',
        'error BAD_DRAG_SOURCE_END'
      ]);
    });
  });

  test('the two drag lines parse', () {
    final List<String> seen = <String>[];
    HostProtocolParser(_Sink(seen)).addBytes(utf8.encode(
      'DRAG_ITEM=file:L3g=\nDRAG=ENTER:1.5000:2.0000:17:524288\n'
      'DRAG=LEAVE\nDRAG=NOPE\n',
    ));
    expect(seen, <String>[
      'item file L3g=',
      'drag enter 1.5 2.0 17 524288',
      'drag leave 0.0 0.0 0 0',
      'error BAD_DRAG',
    ]);
  });
}

final class _Sink with HostMessageSinkAdapter {
  _Sink(this.seen);
  final List<String> seen;

  @override
  void onDragItem(String kind, String base64) => seen.add('item $kind $base64');

  @override
  void onDrag(HostDragPhase phase, double x, double y, int mask, int flags) =>
      seen.add('drag ${phase.name} $x $y $mask $flags');

  @override
  void onDragSourceEnd(int request, int operation) =>
      seen.add('source end $request $operation');

  @override
  void onError(String code) => seen.add('error $code');
}

/// A macOS window as far as a drag source needs one: an id and a host to
/// send to. The rest of [NativeWindow] is never called here.
final class _DragWindow implements NativeWindow, MacosDropWindow {
  final List<String> commands = <String>[];

  @override
  NativeWindowId get id => const NativeWindowId(5);

  @override
  MacosDropTarget? dropTarget;

  @override
  bool sendDropCommand(String command) {
    commands.add(command);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Window implements MacosDropWindow {
  final List<String> commands = <String>[];

  @override
  NativeWindowId get id => const NativeWindowId(3);

  @override
  MacosDropTarget? dropTarget;

  @override
  bool sendDropCommand(String command) {
    commands.add(command);
    return true;
  }
}

final class _Handler implements DropTargetHandler {
  final List<DragSessionEvent> enters = <DragSessionEvent>[];
  final List<DragSessionEvent> drops = <DragSessionEvent>[];
  int leaves = 0;
  DropResponse response =
      const DropResponse(acceptedFormat: DragFormats.uriList);

  @override
  DropResponse onDragEnter(DragSessionEvent event) {
    enters.add(event);
    return response;
  }

  @override
  DropResponse onDragOver(DragSessionEvent event) => response;

  @override
  void onDragLeave() => leaves++;

  @override
  Future<DragAction> onDrop(DragSessionEvent event) async {
    drops.add(event);
    return DragAction.copy;
  }
}
