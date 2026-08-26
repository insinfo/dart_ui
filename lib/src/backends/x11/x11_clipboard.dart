/// The X11 clipboard, which is not a clipboard.
///
/// X has **selections**: named pieces of state owned by a client, not by the
/// server. `CLIPBOARD` is one of them, and reading it is a conversation:
///
///   1. ask the server who owns `CLIPBOARD` - nobody is a real answer;
///   2. `ConvertSelection` on that owner, naming the type wanted and a
///      property on one of *our* windows to put it in;
///   3. wait for the owner to answer with a `SelectionNotify` through our own
///      event loop - an unknown number of milliseconds later, or never, if the
///      owner is busy or exits mid-transfer;
///   4. read the property back, deleting it as we read, because deleting is
///      how the owner learns the data was taken.
///
/// That is why [Clipboard] is asynchronous, and `platform/clipboard.dart` says
/// so at length. Everything in this file is one half of that conversation.
///
/// ## What is implemented, and what is not
///
///   * **Reading** asks for `UTF8_STRING` and falls back to `STRING`, which is
///     Latin-1 by definition and is what pre-UTF-8 applications still offer.
///     A large payload arrives as an `INCR` transfer - a property of type
///     `INCR` holding a size, then one chunk per `PropertyNotify` - and that
///     **is** implemented here, unlike the XDND destination in
///     `x11_drag_drop.dart`, because a paste of a whole file is ordinary where
///     a dropped payload that large is not.
///   * **Writing** takes ownership of `CLIPBOARD` and serves `TARGETS`,
///     `TIMESTAMP`, `UTF8_STRING`, `STRING` and `TEXT` from a
///     `SelectionRequest`. Serving as an **INCR owner is not implemented**: a
///     payload that would not fit in one `ChangeProperty` is refused out loud
///     rather than truncated, because a requestor that gets half a document
///     and no error pastes half a document.
///   * **`PRIMARY`** - the middle-click selection - is deliberately not here.
///     It is a different feature with different semantics (it follows the
///     caret, it is not a copy command) and modelling it as a second clipboard
///     is how toolkits end up overwriting the user's selection on every mouse
///     drag.
///
/// ## The ownership rule that makes this survive process exit
///
/// A selection dies with its owner. When this application exits, whatever it
/// copied stops being available to everyone else - which is X's behaviour, not
/// a bug here, and is why desktops run a clipboard manager. There is nothing a
/// client can do about it beyond handing the data to a manager on the way out,
/// which needs `CLIPBOARD_MANAGER` and `SAVE_TARGETS` and is not implemented.
///
/// ## Verification
///
/// Every rule below is exercised by `test/backends/x11/x11_clipboard_test.dart`
/// against a fake selection client that records the requests and feeds the
/// replies back. That proves the state machine - the request order, the INCR
/// assembly, the refusals - and it does **not** prove that a real X server or a
/// real GTK application behaves the way the fake does. That has not been run
/// against a live X session from this repository; see §68 of the roadmap.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../platform/clipboard.dart';
import 'x11_drag_drop.dart' show X11PropertyValue;
import 'x11_protocol.dart';

/// `PropertyNotify.state`.
const int x11PropertyNewValue = 0;
const int x11PropertyDeleted = 1;

/// The atoms the clipboard needs that nothing else in this backend interns.
///
/// `UTF8_STRING`, `TARGETS` and `INCR` are already in the connection's batch -
/// the first for `_NET_WM_NAME`, the other two for XDND - so they are not
/// repeated here. Interning the same name twice is harmless but it is also a
/// second place for the two lists to drift apart.
const List<String> x11ClipboardAtoms = <String>[
  'CLIPBOARD',
  'TEXT',
  'TIMESTAMP',
  'MULTIPLE',
  'text/plain;charset=utf-8',
  x11ClipboardProperty,
];

/// The property on **our** window that a clipboard transfer lands in.
///
/// Named after this framework rather than after the selection, for the same
/// reason `_DART_UI_XDND_DROP` is: the property is our own scratch space, and
/// two toolkits inside one process must not collide on it.
const String x11ClipboardProperty = '_DART_UI_CLIPBOARD';

/// The X requests the clipboard needs from a connection.
///
/// A subset interface, like `X11CpuClient` and `X11DragDropClient`, and for the
/// same reason: no pointer crosses it, so the state machine below is reachable
/// from a test on a machine with no X server. [X11Connection] satisfies it with
/// the methods it already has for XDND.
abstract interface class X11ClipboardClient {
  /// An atom from the connection's interned cache; zero when it is not there.
  int atom(String name);

  /// `GetSelectionOwner`, or [xcbNone] when nobody owns it.
  int getSelectionOwner(int selection);

  /// `SetSelectionOwner`.
  void setSelectionOwner(int owner, int selection, int time);

  /// `ConvertSelection`. The answer arrives later as a `SelectionNotify`.
  void convertSelection({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  });

  /// `GetProperty`, optionally deleting the property as it is read.
  X11PropertyValue? readPropertyBytes(
    int window,
    int property, {
    required int type,
    bool delete = false,
  });

  /// `DeleteProperty`.
  void deleteWindowProperty(int window, int property);

  /// `ChangeProperty` with format 8.
  void setWindowPropertyBytes(
    int window,
    int property,
    int type,
    Uint8List bytes,
  );

  /// `ChangeProperty` with format 32.
  void setWindowProperty32(
    int window,
    int property,
    int type,
    List<int> values,
  );

  /// `SendEvent` of a `SelectionNotify`, which answers a `SelectionRequest`.
  ///
  /// [property] is [xcbNone] to refuse, and refusing out loud is required: the
  /// requestor is blocked on its own event queue waiting for this.
  void sendSelectionNotify({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  });

  /// Pushes queued requests to the server.
  int flush();

  /// Records a protocol failure on the connection's bounded error ring.
  void recordError(String message);
}

/// The window a transfer uses, and the newest server time seen.
///
/// Injected rather than reached for: a selection needs *a* window of ours to
/// put properties on and *a* recent timestamp to take ownership with, and the
/// object that knows both is the backend. Depending on it here would make this
/// file untestable, which is the whole reason for the seam above.
typedef X11ClipboardWindowLookup = int Function();
typedef X11ClipboardTimeLookup = int Function();

/// One pending read: the request in flight and the future waiting for it.
///
/// Holds the *remaining* targets rather than one, because a refusal is not a
/// failure - `UTF8_STRING` refused is the ordinary answer from a pre-UTF-8
/// application - and the fallback has to complete the same future the caller
/// is already awaiting. A second [Completer] here would mean the caller got
/// null while the real answer arrived somewhere it could not see.
final class _X11ClipboardRead {
  _X11ClipboardRead({
    required this.requestor,
    required this.property,
    required List<({int atom, String name})> targets,
  }) : _targets = targets;

  final int requestor;
  final int property;
  final List<({int atom, String name})> _targets;
  int _attempt = 0;

  final Completer<String?> completer = Completer<String?>();
  Timer? timer;

  /// The conversion currently in flight.
  int get target => _targets[_attempt].atom;
  String get targetName => _targets[_attempt].name;

  /// Whether another target is left to try after a refusal.
  bool get hasFallback => _attempt + 1 < _targets.length;

  void advance() => _attempt++;

  /// Set once the reply said `INCR`: chunks are accumulating and the transfer
  /// is not finished until a zero-length one arrives.
  BytesBuilder? incremental;

  bool get isIncremental => incremental != null;
}

/// `CLIPBOARD` as a state machine: one pending read, one owned payload.
///
/// One instance per connection, owned by the backend, which offers it the
/// selection events before routing anything by window - a `SelectionNotify` is
/// addressed to a window but is *about* a transfer, so the window index is the
/// wrong place to route it.
final class X11ClipboardManager {
  X11ClipboardManager(
    this._client, {
    required X11ClipboardWindowLookup windowOf,
    required X11ClipboardTimeLookup timeOf,
    Duration transferTimeout = const Duration(seconds: 5),
  })  : _windowOf = windowOf,
        _timeOf = timeOf,
        _transferTimeout = transferTimeout;

  final X11ClipboardClient _client;
  final X11ClipboardWindowLookup _windowOf;
  final X11ClipboardTimeLookup _timeOf;
  final Duration _transferTimeout;

  _X11ClipboardRead? _read;

  /// What this application last copied, while it still owns `CLIPBOARD`.
  ///
  /// Null means we do not own the selection - either nothing was copied, or a
  /// `SelectionClear` said another application took it. Keeping the text after
  /// losing ownership is how an application serves stale data to a requestor
  /// that reached it through a race.
  String? _ownedText;

  /// The server time ownership was taken at, which `TIMESTAMP` must answer
  /// with. ICCCM: answering `CurrentTime` there breaks a requestor that is
  /// trying to detect a selection that changed under it.
  int _ownedSince = xcbCurrentTime;

  bool _disposed = false;

  /// Whether this application currently believes it owns `CLIPBOARD`.
  bool get ownsSelection => _ownedText != null;

  /// The largest payload one `ChangeProperty` can carry, in bytes.
  ///
  /// Deliberately well under the protocol's own limit rather than computed
  /// from `maximum-request-length`: the point is to refuse *early and by a
  /// clear rule* instead of discovering the ceiling as a truncated paste in
  /// another application. Serving more than this needs an INCR owner, which is
  /// stated as missing in the library comment rather than implied by silence.
  static const int maximumServedBytes = 200 * 1024;

  // -------------------------------------------------------------------------
  // Reading
  // -------------------------------------------------------------------------

  /// The text on `CLIPBOARD`, null when it holds none.
  ///
  /// Asks for `UTF8_STRING` first and falls back to `STRING` when the owner
  /// refuses that conversion - `STRING` is Latin-1 by definition and is what a
  /// pre-UTF-8 application still offers.
  Future<String?> readText() {
    if (_disposed) {
      return Future<String?>.error(const ClipboardException(
        operation: 'readText',
        reason: 'the X11 connection is gone',
        backend: 'x11',
      ));
    }
    final int selection = _client.atom('CLIPBOARD');
    if (selection == 0) {
      return Future<String?>.error(const ClipboardException(
        operation: 'readText',
        reason: 'the CLIPBOARD atom was not interned on this connection',
        backend: 'x11',
      ));
    }
    // Our own copy, without a round trip through ourselves. Asking the server
    // to ask us is not merely wasteful: the reply arrives through the same
    // event loop this future is waiting on, so an application that pasted
    // during a synchronous stretch would deadlock against itself.
    final int owner = _client.getSelectionOwner(selection);
    final int window = _windowOf();
    if (owner == window && _ownedText != null) {
      return Future<String?>.value(_ownedText);
    }
    // Nobody owns it. Not a failure - a clipboard with nothing on it - and
    // answering now saves the caller a timeout.
    if (owner == xcbNone) return Future<String?>.value();
    if (window == xcbNone) {
      return Future<String?>.error(const ClipboardException(
        operation: 'readText',
        reason: 'a selection transfer needs one of this application\'s '
            'windows to receive the property, and there is none open',
        backend: 'x11',
      ));
    }
    final _X11ClipboardRead? active = _read;
    if (active != null) {
      // One property, one transfer at a time: a second ConvertSelection into
      // the same property would race the first one's reply and both would read
      // the wrong bytes.
      return active.completer.future.then<String?>((String? _) => readText());
    }
    final int property = _client.atom(x11ClipboardProperty);
    if (property == 0) {
      return Future<String?>.error(const ClipboardException(
        operation: 'readText',
        reason: 'the $x11ClipboardProperty atom was not interned',
        backend: 'x11',
      ));
    }
    // In preference order, skipping anything the server would not intern.
    // `STRING` is last and is always there - it is a predefined atom - so the
    // list is never empty.
    final int utf8Atom = _client.atom('UTF8_STRING');
    final int mimeAtom = _client.atom('text/plain;charset=utf-8');
    final read = _X11ClipboardRead(
      requestor: window,
      property: property,
      targets: <({int atom, String name})>[
        if (utf8Atom != 0) (atom: utf8Atom, name: 'UTF8_STRING'),
        if (mimeAtom != 0) (atom: mimeAtom, name: 'text/plain;charset=utf-8'),
        (atom: xcbAtomString, name: 'STRING'),
      ],
    );
    _read = read;
    _sendConversion(read, selection);
    return read.completer.future;
  }

  /// Issues the conversion for the target [read] is currently on.
  void _sendConversion(_X11ClipboardRead read, int selection) {
    // A value left over from a transfer that timed out would otherwise be read
    // back as this one's answer.
    _client.deleteWindowProperty(read.requestor, read.property);
    _client.convertSelection(
      requestor: read.requestor,
      selection: selection,
      target: read.target,
      property: read.property,
      time: _timeOf(),
    );
    _client.flush();
    read.timer?.cancel();
    final String name = read.targetName;
    read.timer = Timer(_transferTimeout, () {
      _failRead(
        read,
        'the clipboard owner never answered the $name conversion within '
        '${_transferTimeout.inMilliseconds}ms',
      );
    });
  }

  /// Answers a `SelectionNotify`. Returns whether it belonged to this manager.
  ///
  /// Matched on (requestor, target) rather than by window, because a selection
  /// reply is about a transfer and several may be addressed to the same window.
  bool handleSelectionNotify({
    required int requestor,
    required int selection,
    required int target,
    required int property,
  }) {
    final _X11ClipboardRead? read = _read;
    if (read == null) return false;
    if (read.requestor != requestor || read.target != target) return false;
    final int expected = _client.atom('CLIPBOARD');
    if (expected != 0 && selection != expected) return false;

    if (property == xcbNone) {
      // The owner refused this conversion, which is routine rather than
      // exceptional: an application from before UTF-8 offers `STRING` and
      // nothing else. Try the next target on the same future; running out of
      // targets is what "no text on the clipboard" means.
      if (read.hasFallback) {
        read.advance();
        _sendConversion(read, selection);
        return true;
      }
      _finishRead(read, null);
      return true;
    }
    if (property != read.property) return false;
    _readProperty(read);
    return true;
  }

  void _readProperty(_X11ClipboardRead read) {
    final X11PropertyValue? value = _client.readPropertyBytes(
      read.requestor,
      read.property,
      // Any type, not the target atom: naming a type the owner did not use
      // succeeds with an *empty* value, so an INCR transfer would look exactly
      // like an owner that sent nothing.
      type: xcbGetPropertyTypeAny,
      delete: true,
    );
    if (value == null) {
      _failRead(read, 'the clipboard property could not be read back');
      return;
    }
    final int incr = _client.atom('INCR');
    if (incr != 0 && value.type == incr) {
      // The value is a lower bound on the size, not the data. Deleting the
      // property - which `readPropertyBytes` just did - is the signal that
      // starts the owner sending chunks.
      read.incremental = BytesBuilder(copy: false);
      read.timer?.cancel();
      read.timer = Timer(
        _transferTimeout,
        () => _failRead(read, 'an INCR clipboard transfer stalled'),
      );
      _client.flush();
      return;
    }
    _finishRead(read, _decode(value));
  }

  /// Advances an `INCR` transfer. Returns whether the event belonged to it.
  ///
  /// One `PropertyNotify` with state `NewValue` per chunk on the property the
  /// transfer named; a zero-length chunk ends it. Deleting each chunk as it is
  /// read is what asks the owner for the next one.
  bool handlePropertyNotify({
    required int window,
    required int atom,
    required int state,
  }) {
    final _X11ClipboardRead? read = _read;
    if (read == null || !read.isIncremental) return false;
    if (read.requestor != window || read.property != atom) return false;
    if (state != x11PropertyNewValue) return false;

    final X11PropertyValue? value = _client.readPropertyBytes(
      window,
      atom,
      type: xcbGetPropertyTypeAny,
      delete: true,
    );
    _client.flush();
    if (value == null) {
      _failRead(read, 'an INCR clipboard chunk could not be read back');
      return true;
    }
    if (value.bytes.isEmpty) {
      final BytesBuilder builder = read.incremental!;
      _finishRead(
        read,
        _decode(X11PropertyValue(
          type: read.target,
          format: 8,
          bytes: builder.takeBytes(),
        )),
      );
      return true;
    }
    read.incremental!.add(value.bytes);
    read.timer?.cancel();
    read.timer = Timer(
      _transferTimeout,
      () => _failRead(read, 'an INCR clipboard transfer stalled'),
    );
    return true;
  }

  /// Decodes a payload according to the type the owner actually used.
  ///
  /// `STRING` is Latin-1 **by definition** in the protocol, not "UTF-8 that
  /// happens to be ASCII": decoding it as UTF-8 turns every accented character
  /// an old application copied into a replacement character.
  String? _decode(X11PropertyValue value) {
    if (value.bytes.isEmpty) return '';
    final int utf8Atom = _client.atom('UTF8_STRING');
    if (utf8Atom != 0 && value.type == utf8Atom) {
      return utf8.decode(value.bytes, allowMalformed: true);
    }
    if (value.type == xcbAtomString) {
      return latin1.decode(value.bytes, allowInvalid: true);
    }
    // An owner that answered with some other type answered the wrong question.
    // Guessing is how a paste inserts a PNG header into a document.
    return null;
  }

  void _finishRead(_X11ClipboardRead read, String? text) {
    if (!identical(_read, read)) return;
    _read = null;
    read.timer?.cancel();
    if (!read.completer.isCompleted) read.completer.complete(text);
  }

  void _failRead(_X11ClipboardRead read, String reason) {
    if (!identical(_read, read)) return;
    _read = null;
    read.timer?.cancel();
    if (read.completer.isCompleted) return;
    read.completer.completeError(ClipboardException(
      operation: 'readText',
      reason: reason,
      backend: 'x11',
    ));
  }

  // -------------------------------------------------------------------------
  // Writing
  // -------------------------------------------------------------------------

  /// Takes ownership of `CLIPBOARD` and holds [text] until somebody asks.
  ///
  /// Ownership is verified with a `GetSelectionOwner` round trip rather than
  /// assumed: `SetSelectionOwner` is not an error when it is refused - a stale
  /// timestamp makes the server ignore it silently - and an application that
  /// believes it owns the clipboard when it does not is one whose copy simply
  /// never happened.
  Future<void> writeText(String text) async {
    if (_disposed) {
      throw const ClipboardException(
        operation: 'writeText',
        reason: 'the X11 connection is gone',
        backend: 'x11',
      );
    }
    final int selection = _client.atom('CLIPBOARD');
    if (selection == 0) {
      throw const ClipboardException(
        operation: 'writeText',
        reason: 'the CLIPBOARD atom was not interned on this connection',
        backend: 'x11',
      );
    }
    final int window = _windowOf();
    if (window == xcbNone) {
      throw const ClipboardException(
        operation: 'writeText',
        reason: 'owning a selection needs one of this application\'s windows '
            'to own it, and there is none open',
        backend: 'x11',
      );
    }
    final int bytes = utf8.encode(text).length;
    if (bytes > maximumServedBytes) {
      throw ClipboardException(
        operation: 'writeText',
        reason: '$bytes bytes exceeds the $maximumServedBytes this backend can '
            'serve from a single ChangeProperty; an INCR selection owner is '
            'not implemented, and truncating the payload would be worse than '
            'refusing it',
        backend: 'x11',
      );
    }
    final int time = _timeOf();
    _client.setSelectionOwner(window, selection, time);
    _client.flush();
    if (_client.getSelectionOwner(selection) != window) {
      throw const ClipboardException(
        operation: 'writeText',
        reason: 'the server did not accept this application as the CLIPBOARD '
            'owner; the timestamp used was probably older than the current '
            'owner\'s',
        backend: 'x11',
      );
    }
    _ownedText = text;
    _ownedSince = time;
  }

  /// Answers a `SelectionRequest`. Returns whether it was ours to answer.
  ///
  /// Every path ends in a `SelectionNotify`, including every refusal: the
  /// requestor is blocked on its own event queue waiting for one, and a client
  /// that stays silent hangs the application that tried to paste from it.
  bool handleSelectionRequest({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) {
    final int clipboard = _client.atom('CLIPBOARD');
    if (clipboard == 0 || selection != clipboard) return false;
    final String? text = _ownedText;
    if (text == null) return false;

    // ICCCM 2.2: a requestor from before the property field existed sets it to
    // None and means "put it in a property named after the target".
    final int destination = property == xcbNone ? target : property;
    if (destination == xcbNone) {
      _refuse(requestor, selection, target, time);
      return true;
    }

    final int targets = _client.atom('TARGETS');
    final int timestamp = _client.atom('TIMESTAMP');
    final int utf8Atom = _client.atom('UTF8_STRING');
    final int textAtom = _client.atom('TEXT');
    final int mimeAtom = _client.atom('text/plain;charset=utf-8');

    if (targets != 0 && target == targets) {
      _client.setWindowProperty32(
        requestor,
        destination,
        xcbAtomAtom,
        <int>[
          if (targets != 0) targets,
          if (timestamp != 0) timestamp,
          if (utf8Atom != 0) utf8Atom,
          if (mimeAtom != 0) mimeAtom,
          xcbAtomString,
          if (textAtom != 0) textAtom,
        ],
      );
      _accept(requestor, selection, target, destination, time);
      return true;
    }

    if (timestamp != 0 && target == timestamp) {
      // The time ownership was taken, not the current time: a requestor uses
      // this to notice that the selection changed under it.
      _client.setWindowProperty32(
        requestor,
        destination,
        xcbAtomInteger,
        <int>[_ownedSince],
      );
      _accept(requestor, selection, target, destination, time);
      return true;
    }

    final Uint8List? payload = _encodeFor(target, text);
    if (payload == null) {
      _refuse(requestor, selection, target, time);
      return true;
    }
    if (payload.length > maximumServedBytes) {
      _client.recordError(
        'refused a ${payload.length}-byte CLIPBOARD conversion: this backend '
        'does not implement an INCR selection owner',
      );
      _refuse(requestor, selection, target, time);
      return true;
    }
    // The type is the *target* for UTF8_STRING and the MIME name, and STRING
    // for TEXT: a requestor that asked for TEXT and got a property typed TEXT
    // learns nothing about the encoding it must decode with.
    _client.setWindowPropertyBytes(
      requestor,
      destination,
      target == textAtom ? xcbAtomString : target,
      payload,
    );
    _accept(requestor, selection, target, destination, time);
    return true;
  }

  /// The bytes for one target, or null when this owner cannot produce it.
  Uint8List? _encodeFor(int target, String text) {
    final int utf8Atom = _client.atom('UTF8_STRING');
    final int mimeAtom = _client.atom('text/plain;charset=utf-8');
    if ((utf8Atom != 0 && target == utf8Atom) ||
        (mimeAtom != 0 && target == mimeAtom)) {
      return Uint8List.fromList(utf8.encode(text));
    }
    final int textAtom = _client.atom('TEXT');
    if (target == xcbAtomString || (textAtom != 0 && target == textAtom)) {
      // STRING is Latin-1. A character outside it cannot be represented, and
      // substituting `?` silently corrupts the paste - so the whole conversion
      // is refused and the requestor falls back to UTF8_STRING, which is what
      // the TARGETS list told it to prefer anyway.
      final bytes = Uint8List(text.length);
      for (var i = 0; i < text.length; i++) {
        final int unit = text.codeUnitAt(i);
        if (unit > 0xff) return null;
        bytes[i] = unit;
      }
      return bytes;
    }
    return null;
  }

  void _accept(
    int requestor,
    int selection,
    int target,
    int property,
    int time,
  ) {
    _client.sendSelectionNotify(
      requestor: requestor,
      selection: selection,
      target: target,
      property: property,
      time: time,
    );
    _client.flush();
  }

  void _refuse(int requestor, int selection, int target, int time) {
    _client.sendSelectionNotify(
      requestor: requestor,
      selection: selection,
      target: target,
      property: xcbNone,
      time: time,
    );
    _client.flush();
  }

  /// Another application took `CLIPBOARD`. Returns whether it was ours to lose.
  bool handleSelectionClear(int selection) {
    final int clipboard = _client.atom('CLIPBOARD');
    if (clipboard == 0 || selection != clipboard) return false;
    if (_ownedText == null) return false;
    // Dropped, not kept: serving text after losing ownership is how a
    // requestor that reached us through a race gets stale data.
    _ownedText = null;
    _ownedSince = xcbCurrentTime;
    return true;
  }

  /// Fails a pending read and forgets any owned payload.
  ///
  /// Called when the connection goes away. A future that nothing will ever
  /// answer is the hang this whole file is shaped to avoid, so it is completed
  /// with an error rather than left dangling.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final _X11ClipboardRead? read = _read;
    if (read != null) {
      _read = null;
      read.timer?.cancel();
      if (!read.completer.isCompleted) {
        read.completer.completeError(const ClipboardException(
          operation: 'readText',
          reason: 'the X11 connection was closed while the clipboard owner '
              'was still answering',
          backend: 'x11',
        ));
      }
    }
    _ownedText = null;
  }

  @override
  String toString() => 'X11ClipboardManager(owns: $ownsSelection, '
      'reading: ${_read != null})';
}

/// The portable clipboard facade over [X11ClipboardManager].
///
/// Thin on purpose: the state machine belongs to the manager, which the
/// backend also feeds events to, and this is only the shape the application
/// layer names.
final class X11Clipboard implements Clipboard {
  const X11Clipboard(this.manager);

  final X11ClipboardManager manager;

  @override
  Future<String?> readText() => manager.readText();

  @override
  Future<void> writeText(String text) => manager.writeText(text);
}
