/// The X11 clipboard state machine, against a fake selection client.
///
/// The fake records every request and lets a test feed the replies back in the
/// order a real owner would send them. That proves the *conversation* - the
/// order of requests, the fallback after a refusal, the INCR assembly, the
/// refusals that must never be silent - and it proves nothing about libxcb or
/// about how a real GTK or Qt application answers. Neither can run on a machine
/// with no X server; see §68 of the roadmap.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/x11/x11_clipboard.dart';
import 'package:dart_ui/src/backends/x11/x11_drag_drop.dart'
    show X11PropertyValue;
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/platform/clipboard.dart';
import 'package:test/test.dart';

const int _ourWindow = 0x400;
const int _theirWindow = 0x800;

const Map<String, int> _atoms = <String, int>{
  'CLIPBOARD': 200,
  'UTF8_STRING': 201,
  'TARGETS': 202,
  'TIMESTAMP': 203,
  'INCR': 204,
  'TEXT': 205,
  'MULTIPLE': 206,
  'text/plain;charset=utf-8': 207,
  x11ClipboardProperty: 208,
};

typedef _Conversion = ({
  int requestor,
  int selection,
  int target,
  int property,
  int time,
});

typedef _Notify = ({
  int requestor,
  int selection,
  int target,
  int property,
  int time,
});

typedef _PropertyWrite = ({
  int window,
  int property,
  int type,
  Object value,
});

final class _FakeSelectionClient implements X11ClipboardClient {
  _FakeSelectionClient({Map<String, int>? atoms}) : _names = atoms ?? _atoms;

  final Map<String, int> _names;

  final List<_Conversion> conversions = <_Conversion>[];
  final List<_Notify> notifies = <_Notify>[];
  final List<_PropertyWrite> writes = <_PropertyWrite>[];
  final List<(int, int)> deletes = <(int, int)>[];
  final List<(int owner, int selection, int time)> ownerships =
      <(int, int, int)>[];
  final List<String> errors = <String>[];
  int flushes = 0;

  /// What `GetSelectionOwner` answers. A test sets it to [_ourWindow] to make
  /// the manager think it took ownership.
  int owner = _theirWindow;

  /// Queued `GetProperty` answers, consumed in order.
  final List<X11PropertyValue?> propertyReplies = <X11PropertyValue?>[];

  @override
  int atom(String name) => _names[name] ?? 0;

  @override
  int getSelectionOwner(int selection) => owner;

  @override
  void setSelectionOwner(int owner, int selection, int time) =>
      ownerships.add((owner, selection, time));

  @override
  void convertSelection({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) =>
      conversions.add((
        requestor: requestor,
        selection: selection,
        target: target,
        property: property,
        time: time,
      ));

  @override
  X11PropertyValue? readPropertyBytes(
    int window,
    int property, {
    required int type,
    bool delete = false,
  }) {
    if (propertyReplies.isEmpty) return null;
    return propertyReplies.removeAt(0);
  }

  @override
  void deleteWindowProperty(int window, int property) =>
      deletes.add((window, property));

  @override
  void setWindowPropertyBytes(
    int window,
    int property,
    int type,
    Uint8List bytes,
  ) =>
      writes.add((
        window: window,
        property: property,
        type: type,
        value: bytes,
      ));

  @override
  void setWindowProperty32(
    int window,
    int property,
    int type,
    List<int> values,
  ) =>
      writes.add((
        window: window,
        property: property,
        type: type,
        value: List<int>.of(values),
      ));

  @override
  void sendSelectionNotify({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) =>
      notifies.add((
        requestor: requestor,
        selection: selection,
        target: target,
        property: property,
        time: time,
      ));

  @override
  int flush() => ++flushes;

  @override
  void recordError(String message) => errors.add(message);
}

X11PropertyValue _value(int type, List<int> bytes) => X11PropertyValue(
      type: type,
      format: 8,
      bytes: Uint8List.fromList(bytes),
    );

void main() {
  late _FakeSelectionClient client;
  late X11ClipboardManager manager;

  X11ClipboardManager build({int window = _ourWindow, int time = 9000}) {
    return X11ClipboardManager(
      client,
      windowOf: () => window,
      timeOf: () => time,
      transferTimeout: const Duration(milliseconds: 50),
    );
  }

  setUp(() {
    client = _FakeSelectionClient();
    manager = build();
  });

  group('reading', () {
    test('an unowned CLIPBOARD is null without a round trip', () {
      // Not a failure - a clipboard with nothing on it - and answering now is
      // what saves the caller the transfer timeout.
      client.owner = xcbNone;

      expect(manager.readText(), completion(isNull));
      expect(client.conversions, isEmpty);
    });

    test('asks for UTF8_STRING into our own property, with a real time', () {
      unawaited_(manager.readText());

      final _Conversion request = client.conversions.single;
      expect(request.requestor, _ourWindow);
      expect(request.selection, _atoms['CLIPBOARD']);
      expect(request.target, _atoms['UTF8_STRING']);
      expect(request.property, _atoms[x11ClipboardProperty]);
      expect(request.time, 9000);
      // The property is cleared first: a value left from a transfer that timed
      // out would otherwise be read back as this one's answer.
      expect(client.deletes.single, (_ourWindow, _atoms[x11ClipboardProperty]));
    });

    test('decodes a UTF8_STRING reply', () async {
      final Future<String?> pending = manager.readText();
      client.propertyReplies
          .add(_value(_atoms['UTF8_STRING']!, utf8.encode('olá mundo')));

      expect(
        manager.handleSelectionNotify(
          requestor: _ourWindow,
          selection: _atoms['CLIPBOARD']!,
          target: _atoms['UTF8_STRING']!,
          property: _atoms[x11ClipboardProperty]!,
        ),
        isTrue,
      );

      expect(await pending, 'olá mundo');
    });

    test('decodes STRING as Latin-1, not as UTF-8', () async {
      // STRING is Latin-1 by definition. Decoding it as UTF-8 turns every
      // accented character an old application copied into a replacement one.
      final Future<String?> pending = manager.readText();
      // The owner refuses UTF8_STRING, then the MIME name, then answers STRING.
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: xcbNone,
      );
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['text/plain;charset=utf-8']!,
        property: xcbNone,
      );
      client.propertyReplies.add(_value(xcbAtomString, <int>[0x61, 0xe7]));
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: xcbAtomString,
        property: _atoms[x11ClipboardProperty]!,
      );

      expect(await pending, 'aç');
      expect(
        client.conversions.map((c) => c.target),
        <int>[
          _atoms['UTF8_STRING']!,
          _atoms['text/plain;charset=utf-8']!,
          xcbAtomString,
        ],
      );
    });

    test('a refusal of the last target is null, not an error', () async {
      final Future<String?> pending = manager.readText();
      for (final int target in <int>[
        _atoms['UTF8_STRING']!,
        _atoms['text/plain;charset=utf-8']!,
        xcbAtomString,
      ]) {
        manager.handleSelectionNotify(
          requestor: _ourWindow,
          selection: _atoms['CLIPBOARD']!,
          target: target,
          property: xcbNone,
        );
      }

      expect(await pending, isNull);
    });

    test('the fallback completes the future the caller is already awaiting',
        () async {
      // A second Completer here would have handed the caller null while the
      // real answer arrived somewhere it could not see.
      final Future<String?> pending = manager.readText();
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: xcbNone,
      );
      client.propertyReplies
          .add(_value(_atoms['text/plain;charset=utf-8']!, utf8.encode('x')));
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['text/plain;charset=utf-8']!,
        property: xcbNone,
      );
      client.propertyReplies.clear();
      client.propertyReplies.add(_value(xcbAtomString, <int>[0x78]));
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: xcbAtomString,
        property: _atoms[x11ClipboardProperty]!,
      );

      expect(await pending, 'x');
    });

    test('a reply for another transfer is not consumed', () {
      unawaited_(manager.readText());

      expect(
        manager.handleSelectionNotify(
          requestor: _theirWindow,
          selection: _atoms['CLIPBOARD']!,
          target: _atoms['UTF8_STRING']!,
          property: _atoms[x11ClipboardProperty]!,
        ),
        isFalse,
      );
      expect(
        manager.handleSelectionNotify(
          requestor: _ourWindow,
          selection: 999,
          target: _atoms['UTF8_STRING']!,
          property: _atoms[x11ClipboardProperty]!,
        ),
        isFalse,
      );
    });

    test('a SelectionNotify with no transfer in flight is not ours', () {
      expect(
        manager.handleSelectionNotify(
          requestor: _ourWindow,
          selection: _atoms['CLIPBOARD']!,
          target: _atoms['UTF8_STRING']!,
          property: _atoms[x11ClipboardProperty]!,
        ),
        isFalse,
      );
    });

    test('a property that cannot be read back is a named failure', () async {
      final Future<String?> pending = manager.readText();
      client.propertyReplies.add(null);
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: _atoms[x11ClipboardProperty]!,
      );

      await expectLater(
        pending,
        throwsA(isA<ClipboardException>().having(
          (e) => e.reason,
          'reason',
          contains('could not be read back'),
        )),
      );
    });

    test('an owner that answers the wrong type produces null, never a guess',
        () async {
      // Guessing is how a paste inserts a PNG header into a document.
      final Future<String?> pending = manager.readText();
      client.propertyReplies.add(_value(4242, <int>[0x89, 0x50, 0x4e, 0x47]));
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: _atoms[x11ClipboardProperty]!,
      );

      expect(await pending, isNull);
    });

    test('an owner that never answers fails rather than hanging', () async {
      final Future<String?> pending = manager.readText();

      await expectLater(
        pending,
        throwsA(isA<ClipboardException>().having(
          (e) => e.reason,
          'reason',
          contains('never answered'),
        )),
      );
    });

    test('our own copy is answered without asking the server', () async {
      client.owner = _ourWindow;
      await manager.writeText('mine');

      expect(await manager.readText(), 'mine');
      // Asking the server to ask us would deliver the reply through the same
      // event loop this future waits on - a deadlock against ourselves.
      expect(client.conversions, isEmpty);
    });

    test('no window means a named failure, not a silent null', () async {
      final X11ClipboardManager windowless = build(window: xcbNone);

      await expectLater(
        windowless.readText(),
        throwsA(isA<ClipboardException>().having(
          (e) => e.operation,
          'operation',
          'readText',
        )),
      );
    });

    test('a second read waits for the first rather than racing its property',
        () async {
      final Future<String?> first = manager.readText();
      final Future<String?> second = manager.readText();

      expect(client.conversions, hasLength(1));

      client.propertyReplies
          .add(_value(_atoms['UTF8_STRING']!, utf8.encode('one')));
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: _atoms[x11ClipboardProperty]!,
      );
      expect(await first, 'one');

      client.propertyReplies
          .add(_value(_atoms['UTF8_STRING']!, utf8.encode('two')));
      await Future<void>.delayed(Duration.zero);
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: _atoms[x11ClipboardProperty]!,
      );
      expect(await second, 'two');
      expect(client.conversions, hasLength(2));
    });
  });

  group('reading an INCR transfer', () {
    Future<String?> startIncr() {
      final Future<String?> pending = manager.readText();
      // The property arrives typed INCR and holding a size, not the payload.
      client.propertyReplies
          .add(_value(_atoms['INCR']!, <int>[0x00, 0x10, 0x00, 0x00]));
      manager.handleSelectionNotify(
        requestor: _ourWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: _atoms[x11ClipboardProperty]!,
      );
      return pending;
    }

    test('assembles the chunks and stops at the empty one', () async {
      final Future<String?> pending = startIncr();

      client.propertyReplies
          .add(_value(_atoms['UTF8_STRING']!, utf8.encode('hello ')));
      expect(
        manager.handlePropertyNotify(
          window: _ourWindow,
          atom: _atoms[x11ClipboardProperty]!,
          state: x11PropertyNewValue,
        ),
        isTrue,
      );
      client.propertyReplies
          .add(_value(_atoms['UTF8_STRING']!, utf8.encode('world')));
      manager.handlePropertyNotify(
        window: _ourWindow,
        atom: _atoms[x11ClipboardProperty]!,
        state: x11PropertyNewValue,
      );
      client.propertyReplies.add(_value(_atoms['UTF8_STRING']!, const <int>[]));
      manager.handlePropertyNotify(
        window: _ourWindow,
        atom: _atoms[x11ClipboardProperty]!,
        state: x11PropertyNewValue,
      );

      expect(await pending, 'hello world');
    });

    test('the size header is never mistaken for the payload', () async {
      // Handing back the four bytes of the header would paste mojibake.
      final Future<String?> pending = startIncr();
      client.propertyReplies.add(_value(_atoms['UTF8_STRING']!, const <int>[]));
      manager.handlePropertyNotify(
        window: _ourWindow,
        atom: _atoms[x11ClipboardProperty]!,
        state: x11PropertyNewValue,
      );

      expect(await pending, '');
    });

    test('a Deleted PropertyNotify is not a chunk', () async {
      final Future<String?> pending = startIncr();

      expect(
        manager.handlePropertyNotify(
          window: _ourWindow,
          atom: _atoms[x11ClipboardProperty]!,
          state: x11PropertyDeleted,
        ),
        isFalse,
      );

      client.propertyReplies.add(_value(_atoms['UTF8_STRING']!, const <int>[]));
      manager.handlePropertyNotify(
        window: _ourWindow,
        atom: _atoms[x11ClipboardProperty]!,
        state: x11PropertyNewValue,
      );
      expect(await pending, '');
    });

    test('a PropertyNotify on another property is left for the window', () {
      unawaited_(startIncr().catchError((Object _) => null));

      expect(
        manager.handlePropertyNotify(
          window: _ourWindow,
          atom: 4242,
          state: x11PropertyNewValue,
        ),
        isFalse,
      );
    });

    test('a PropertyNotify with no INCR in flight is never consumed', () {
      unawaited_(manager.readText());

      expect(
        manager.handlePropertyNotify(
          window: _ourWindow,
          atom: _atoms[x11ClipboardProperty]!,
          state: x11PropertyNewValue,
        ),
        isFalse,
      );
    });

    test('a stalled transfer fails rather than waiting forever', () async {
      final Future<String?> pending = startIncr();

      await expectLater(
        pending,
        throwsA(isA<ClipboardException>().having(
          (e) => e.reason,
          'reason',
          contains('stalled'),
        )),
      );
    });
  });

  group('writing', () {
    test('takes ownership and verifies it with a round trip', () async {
      client.owner = _ourWindow;

      await manager.writeText('copied');

      expect(client.ownerships.single, (_ourWindow, _atoms['CLIPBOARD'], 9000));
      expect(manager.ownsSelection, isTrue);
    });

    test('a refused SetSelectionOwner is a named failure, not a silent one',
        () async {
      // SetSelectionOwner is not an error when the server ignores it; an
      // application that believes it owns the clipboard when it does not is
      // one whose copy simply never happened.
      client.owner = _theirWindow;

      await expectLater(
        manager.writeText('copied'),
        throwsA(isA<ClipboardException>().having(
          (e) => e.operation,
          'operation',
          'writeText',
        )),
      );
      expect(manager.ownsSelection, isFalse);
    });

    test('no window means a named failure', () async {
      final X11ClipboardManager windowless = build(window: xcbNone);

      await expectLater(
        windowless.writeText('x'),
        throwsA(isA<ClipboardException>()),
      );
    });

    test('a payload too large to serve is refused, never truncated', () async {
      client.owner = _ourWindow;
      final String huge = 'a' * (X11ClipboardManager.maximumServedBytes + 1);

      await expectLater(
        manager.writeText(huge),
        throwsA(isA<ClipboardException>().having(
          (e) => e.reason,
          'reason',
          contains('INCR selection owner is not implemented'),
        )),
      );
      expect(manager.ownsSelection, isFalse);
      expect(client.ownerships, isEmpty);
    });
  });

  group('serving a SelectionRequest', () {
    setUp(() async {
      client.owner = _ourWindow;
      await manager.writeText('olá');
      client.writes.clear();
      client.notifies.clear();
    });

    test('answers TARGETS with the types it can actually produce', () {
      expect(
        manager.handleSelectionRequest(
          requestor: _theirWindow,
          selection: _atoms['CLIPBOARD']!,
          target: _atoms['TARGETS']!,
          property: 300,
          time: 9100,
        ),
        isTrue,
      );

      final _PropertyWrite write = client.writes.single;
      expect(write.window, _theirWindow);
      expect(write.property, 300);
      expect(write.type, xcbAtomAtom);
      expect(
        write.value,
        containsAll(<int>[
          _atoms['TARGETS']!,
          _atoms['TIMESTAMP']!,
          _atoms['UTF8_STRING']!,
          xcbAtomString,
        ]),
      );
      expect(client.notifies.single.property, 300);
    });

    test('answers TIMESTAMP with when ownership was taken', () {
      // Not the current time: a requestor uses this to notice that the
      // selection changed under it.
      manager.handleSelectionRequest(
        requestor: _theirWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['TIMESTAMP']!,
        property: 300,
        time: 9100,
      );

      final _PropertyWrite write = client.writes.single;
      expect(write.type, xcbAtomInteger);
      expect(write.value, <int>[9000]);
    });

    test('answers UTF8_STRING with the encoded text', () {
      manager.handleSelectionRequest(
        requestor: _theirWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: 300,
        time: 9100,
      );

      final _PropertyWrite write = client.writes.single;
      expect(write.type, _atoms['UTF8_STRING']);
      expect(write.value, utf8.encode('olá'));
      expect(client.notifies.single.property, 300);
    });

    test('answers STRING as Latin-1 and types the property STRING', () {
      manager.handleSelectionRequest(
        requestor: _theirWindow,
        selection: _atoms['CLIPBOARD']!,
        target: xcbAtomString,
        property: 300,
        time: 9100,
      );

      final _PropertyWrite write = client.writes.single;
      expect(write.type, xcbAtomString);
      expect(write.value, <int>[0x6f, 0x6c, 0xe1]);
    });

    test('a TEXT conversion is typed STRING, not TEXT', () async {
      // A requestor that asked for TEXT and got a property typed TEXT learns
      // nothing about the encoding it has to decode with.
      manager.handleSelectionRequest(
        requestor: _theirWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['TEXT']!,
        property: 300,
        time: 9100,
      );

      expect(client.writes.single.type, xcbAtomString);
    });

    test('refuses STRING for text Latin-1 cannot represent', () async {
      // Substituting `?` would silently corrupt the paste; the requestor falls
      // back to UTF8_STRING, which TARGETS told it to prefer anyway.
      client.owner = _ourWindow;
      await manager.writeText('日本語');
      client.writes.clear();
      client.notifies.clear();

      manager.handleSelectionRequest(
        requestor: _theirWindow,
        selection: _atoms['CLIPBOARD']!,
        target: xcbAtomString,
        property: 300,
        time: 9100,
      );

      expect(client.writes, isEmpty);
      expect(client.notifies.single.property, xcbNone);
    });

    test('refuses a type it cannot produce, out loud', () {
      // The requestor is blocked on its own event queue waiting for a
      // SelectionNotify; staying silent hangs it.
      manager.handleSelectionRequest(
        requestor: _theirWindow,
        selection: _atoms['CLIPBOARD']!,
        target: 4242,
        property: 300,
        time: 9100,
      );

      expect(client.writes, isEmpty);
      expect(client.notifies.single.property, xcbNone);
      expect(client.notifies.single.target, 4242);
    });

    test('an obsolete requestor with no property gets the target as one', () {
      manager.handleSelectionRequest(
        requestor: _theirWindow,
        selection: _atoms['CLIPBOARD']!,
        target: _atoms['UTF8_STRING']!,
        property: xcbNone,
        time: 9100,
      );

      expect(client.writes.single.property, _atoms['UTF8_STRING']);
      expect(client.notifies.single.property, _atoms['UTF8_STRING']);
    });

    test('a request for another selection is not ours to answer', () {
      expect(
        manager.handleSelectionRequest(
          requestor: _theirWindow,
          selection: 999,
          target: _atoms['UTF8_STRING']!,
          property: 300,
          time: 9100,
        ),
        isFalse,
      );
      expect(client.notifies, isEmpty);
    });

    test('a request arriving when we own nothing is not ours', () {
      final X11ClipboardManager fresh = build();

      expect(
        fresh.handleSelectionRequest(
          requestor: _theirWindow,
          selection: _atoms['CLIPBOARD']!,
          target: _atoms['UTF8_STRING']!,
          property: 300,
          time: 9100,
        ),
        isFalse,
      );
    });
  });

  group('losing the selection', () {
    test('SelectionClear drops the payload rather than serving it stale',
        () async {
      client.owner = _ourWindow;
      await manager.writeText('mine');

      expect(manager.handleSelectionClear(_atoms['CLIPBOARD']!), isTrue);
      expect(manager.ownsSelection, isFalse);
      expect(
        manager.handleSelectionRequest(
          requestor: _theirWindow,
          selection: _atoms['CLIPBOARD']!,
          target: _atoms['UTF8_STRING']!,
          property: 300,
          time: 9100,
        ),
        isFalse,
      );
    });

    test('a clear for another selection is not ours', () async {
      client.owner = _ourWindow;
      await manager.writeText('mine');

      expect(manager.handleSelectionClear(999), isFalse);
      expect(manager.ownsSelection, isTrue);
    });
  });

  group('dispose', () {
    test('fails a pending read instead of leaving it dangling', () async {
      final Future<String?> pending = manager.readText();

      manager.dispose();

      await expectLater(pending, throwsA(isA<ClipboardException>()));
    });

    test('every later operation is a named failure', () async {
      manager.dispose();

      await expectLater(manager.readText(), throwsA(isA<ClipboardException>()));
      await expectLater(
        manager.writeText('x'),
        throwsA(isA<ClipboardException>()),
      );
    });
  });

  group('X11Clipboard', () {
    test('is the Clipboard contract over the manager', () async {
      client.owner = _ourWindow;
      final Clipboard clipboard = X11Clipboard(manager);

      await clipboard.writeText('through the facade');

      expect(await clipboard.readText(), 'through the facade');
    });
  });

  group('an atom the server would not intern', () {
    test('reading without CLIPBOARD is a named failure', () async {
      client = _FakeSelectionClient(atoms: const <String, int>{});
      manager = build();

      await expectLater(
        manager.readText(),
        throwsA(isA<ClipboardException>().having(
          (e) => e.reason,
          'reason',
          contains('CLIPBOARD atom'),
        )),
      );
    });

    test('writing without CLIPBOARD is a named failure', () async {
      client = _FakeSelectionClient(atoms: const <String, int>{});
      manager = build();

      await expectLater(
        manager.writeText('x'),
        throwsA(isA<ClipboardException>()),
      );
    });
  });
}

/// Starts a future whose result this test does not need.
///
/// Spelled out rather than `unawaited` from `dart:async` so that the intent -
/// "the request is what is being asserted, not the answer" - is visible at the
/// call site.
void unawaited_(Future<Object?> future) {
  future.then<void>((Object? _) {}, onError: (Object _) {});
}
