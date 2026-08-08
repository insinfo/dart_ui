/// The line protocol spoken by the native AppKit host, and a parser for it.
///
/// ADR 0001 put Dart on the far side of a pipe from the window, so *every*
/// platform event this backend will ever report arrives as a line of the
/// host's stdout. That makes this file the single place where a malformed byte
/// can turn into a wrong event, and the only part of the backend that can be
/// exercised on a machine with no AppKit. It therefore takes bytes and pushes
/// to a sink, and knows nothing about processes, windows or streams.
///
/// Why bytes and not `utf8.decode` + `LineSplitter`: the requirement is no
/// allocation per event. A decoded line allocates a String, a split allocates
/// a List, and `int.parse` on a substring allocates again - three objects for
/// a pointer move, on a path whose end-to-end budget was measured at 824 us
/// (`doc/logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md`). The protocol is
/// ASCII by construction, so numbers are read straight out of the byte buffer.
/// Only genuinely rare lines - `ERROR=`, unrecognised text - build a String,
/// because a diagnostic that cannot be printed is worth less than the garbage
/// it saved.
library;

import 'dart:typed_data';

/// Protocol version this backend was written against.
///
/// Version 3 is the one measured in the POC (`SURFACES`, `PRESENT_SLOT`,
/// `SURFACE_PORT`). Version 4 adds the `WINDOW=` event lines that
/// `NativeWindow` needs and slot-aware surface handoff; a version 3 host still
/// works, it just never reports a resize.
const int kMacosHostProtocolVersion = 4;

/// Oldest host this client will talk to. Below this the handshake is refused
/// with a named diagnostic rather than a stream of unrecognised lines.
const int kMacosHostMinimumProtocolVersion = 3;

/// Longest line accepted. A host that emits more than this is malfunctioning,
/// and growing the buffer to follow it would turn that into an OOM instead of
/// a diagnostic.
const int kMacosHostMaxLineBytes = 8192;

/// The scalar fields of the handshake banner.
enum HostHandshakeField {
  /// `MAIN_THREAD=1`. Zero means the host is not on thread 0, which is the
  /// entire reason this backend exists - it must be treated as fatal.
  mainThread,

  /// `WINDOW_ID=<n>` - the `CGSWindowID`. Kept for `screencapture -l` and for
  /// logs; it is deliberately NOT the [NativeWindowId] the framework sees.
  windowNumber,

  /// `PROTOCOL=<n>`.
  protocolVersion,

  /// `HOST_PID=<n>`. Needed to derive the rendezvous bootstrap name, which
  /// must be unique per host instance or a restarted host collides with the
  /// name its dead predecessor published.
  hostPid,

  /// `WINDOW_SCALE=<thousandths>` - the backing scale factor of the screen the
  /// window opened on, times 1000.
  ///
  /// An integer because every other handshake field is one, and because the
  /// number decides how many pixels the surface pool allocates: getting it in
  /// the banner means a Retina window allocates once instead of allocating at
  /// 1x and immediately reallocating. Absent on a protocol 3 host, which then
  /// falls back to the caller's assumption plus the first resize.
  renderScaleMilli,
}

/// A window-level notification from the host.
///
/// These map one-to-one onto `PlatformWindowEvent`; the mapping lives in
/// `macos_window.dart` so that this file stays free of framework types and can
/// be tested with nothing but bytes.
enum HostWindowEventKind {
  /// `WINDOW=RESIZED:<w>:<h>:<renderScale>` - logical size plus the backing
  /// scale factor of the screen the window is currently on.
  resized,

  /// `WINDOW=MOVED:<x>:<y>` in top-left-origin screen points. The flip out of
  /// AppKit's bottom-left origin happens in the host, on purpose: it needs the
  /// screen frame to do it, and shipping that number to Dart just to flip it
  /// here would put a second copy of the convention in a second language.
  moved,

  /// `WINDOW=SCALE:<renderScale>:<desktopScale>`.
  scaleChanged,

  /// `WINDOW=EXPOSED:<x>:<y>:<w>:<h>`, in logical units relative to the client
  /// area. An all-zero rect means "the host could not tell us", which the
  /// window turns into a null dirty rect.
  exposed,

  activated,
  deactivated,

  /// `WINDOW=STATE:<n>`, where n indexes `WindowState`. There is no
  /// state-changed event in `window_events.dart` - deliberately, since every
  /// state change that matters also produces a resize - so this only updates
  /// the window's `state` getter.
  stateChanged,

  /// `WINDOW=CLOSE_REQUESTED` - the user hit the close button. The host
  /// answers `NO` to AppKit and waits: whether a window closes is the
  /// framework's decision, per `window_events.dart`.
  closeRequested,

  /// `WINDOW=CLOSED` - the window really is gone.
  closed,
}

/// Input as the host's local `NSEvent` monitor saw it.
enum HostInputKind {
  keyDown,
  keyUp,
  pointerDown,
  pointerUp,
  pointerMove,
  scroll,

  /// An event the host matched but this client does not model. Reported rather
  /// than dropped so a log can show that input *is* flowing.
  other,
}

/// Acknowledgements that carry at most one number.
enum HostAckKind {
  /// `PONG`.
  pong,

  /// `TITLE_OK`.
  title,

  /// `FRAME_OK <n>` - the copying transport. Present only for comparison; this
  /// backend does not use it.
  frame,

  /// `SHM_OK <bytes>`. Unused here for the reason in ADR 0001: shared memory
  /// is 1.2-1.4x faster than a pipe at every frame size, which proves the cost
  /// is the per-pixel CGImage rebuild that shm does not remove.
  sharedMemory,

  /// `SURFACES_OK <n>` - a pool attached through the deprecated global lookup.
  surfacePoolLookup,

  /// `SURFACE_POOL_OK <n>` - an empty pool allocated, ready for per-slot
  /// mach-port handoff.
  surfacePoolAllocated,

  /// `PORT_SERVER_OK <name>` - the host checked a receive right in with
  /// launchd. The value reported is the length of the name, which is enough to
  /// assert the line was well formed without allocating the name itself; the
  /// name is already known, because Dart chose it.
  portServer,

  /// `CLOSE_OK` - the host accepted `CLOSE` and is terminating.
  closeAccepted,

  /// `TEARDOWN=PASS` - every native handle released, in reverse order.
  teardown,

  /// `MAIN_THREAD=0`, i.e. the one handshake answer that is fatal on its own.
  notMainThread,
}

/// Which mechanism actually delivered a surface to the host.
///
/// Measured in `doc/logs/MACH_PORT_HANDOFF_2026-08-08.md`: `registered` fails
/// because libxpc overwrites the registered-port array during `fork()`,
/// `bootstrap` works but has been deprecated since 10.5, and `rendezvous`
/// works with no deprecated call and no ordering constraint. This backend asks
/// for rendezvous and records what it got.
enum HostSurfaceMechanism { registered, bootstrap, rendezvous }

/// What the host said it presented from.
///
/// Two distinct tags rather than one tag plus a detail field, so a client that
/// pins `surface` cannot silently measure the deprecated fallback and report
/// it as the supported path.
enum HostPresentTransport {
  /// `IOSurfaceLookup`, the deprecated global-surface path.
  surfaceLookup,

  /// `IOSurfaceLookupFromMachPort`, the supported path.
  surfacePort,

  /// A slot of the double-buffered pool.
  surfaceSlot,

  /// A `CGImage` over a shared mapping.
  sharedMemory,
}

/// Where parsed lines go.
///
/// A sink of callbacks rather than a stream of message objects because a
/// message object is an allocation per event, and pointer moves arrive at
/// input rates. Every payload is passed as a primitive.
abstract interface class HostMessageSink {
  void onHandshake(HostHandshakeField field, int value);

  /// `PROTOCOL_FEATURES=<csv>`. Once per host, so a String is affordable and
  /// the alternative - a feature enum this client would have to keep in sync
  /// with a host it cannot rebuild - is worse.
  void onProtocolFeatures(String features);

  /// [a]..[d] carry the fields of [kind]; see [HostWindowEventKind]. Unused
  /// slots are zero.
  void onWindowEvent(
    HostWindowEventKind kind,
    double a,
    double b,
    double c,
    double d,
  );

  /// The gate: every `NSEvent` the application dequeued. [machTime] is
  /// `mach_absolute_time` in the host, on the same system-wide clock a Dart
  /// process reads, which is what makes the boundary cost separable from the
  /// WindowServer delivery cost.
  void onInput(
    HostInputKind kind,
    double x,
    double y,
    int keyCode,
    int machTime,
  );

  /// The same event as seen by the responder chain. Proof of routing, not a
  /// second event: consumers must not deliver both.
  void onViewInput(HostInputKind kind, double x, double y);

  void onAck(HostAckKind kind, int value);

  /// `SURFACE_OK <id> <w>x<h>`, the deprecated lookup path. [slot] is -1 when
  /// the host attached it as the single surface rather than into a pool.
  void onSurfaceAttached(int surfaceId, int slot);

  /// `SURFACE_PORT_OK <mechanism> <w>x<h> [slot<n>]`.
  void onSurfacePortAttached(HostSurfaceMechanism mechanism, int slot);

  /// `PRESENT_OK <sequence> <tag>`. [slot] is -1 for the single-surface forms.
  void onPresented(int sequence, int slot, HostPresentTransport transport);

  /// `ERROR=<code>`. Rare, and useless without the text, so this one string is
  /// deliberate.
  void onError(String code);

  /// Anything else. Not silently dropped: a host that starts printing
  /// something new should show up in a log, not vanish.
  void onUnrecognised(String line);
}

/// No-op implementations of every callback, so a consumer overrides only what
/// it consumes and adding a message to the protocol does not break it.
mixin HostMessageSinkAdapter implements HostMessageSink {
  @override
  void onHandshake(HostHandshakeField field, int value) {}

  @override
  void onProtocolFeatures(String features) {}

  @override
  void onWindowEvent(
    HostWindowEventKind kind,
    double a,
    double b,
    double c,
    double d,
  ) {}

  @override
  void onInput(
    HostInputKind kind,
    double x,
    double y,
    int keyCode,
    int machTime,
  ) {}

  @override
  void onViewInput(HostInputKind kind, double x, double y) {}

  @override
  void onAck(HostAckKind kind, int value) {}

  @override
  void onSurfaceAttached(int surfaceId, int slot) {}

  @override
  void onSurfacePortAttached(HostSurfaceMechanism mechanism, int slot) {}

  @override
  void onPresented(int sequence, int slot, HostPresentTransport transport) {}

  @override
  void onError(String code) {}

  @override
  void onUnrecognised(String line) {}
}

const int _kNewline = 0x0A;
const int _kReturn = 0x0D;
const int _kColon = 0x3A;
const int _kSpace = 0x20;
const int _kMinus = 0x2D;
const int _kPlus = 0x2B;
const int _kDot = 0x2E;
const int _kZero = 0x30;
const int _kNine = 0x39;

/// Returned by the number readers when there was no number to read. Chosen
/// over an exception because a malformed line must produce a diagnostic and
/// let the next line through, not unwind a stdout listener.
const int kHostFieldMissing = -0x8000000000000;

/// Splits the host's stdout into lines and turns each into a sink callback.
///
/// Not a `StreamTransformer`: this is fed raw chunks by whatever owns the
/// process, and in a test it is fed a `Uint8List` of recorded output. The
/// buffer is reused across lines, so a session parses without allocating
/// anything except the event payloads the framework contract forces.
final class HostProtocolParser {
  HostProtocolParser(this._sink, {int initialCapacity = 256})
      : _line = Uint8List(initialCapacity);

  final HostMessageSink _sink;

  Uint8List _line;
  int _length = 0;
  int _cursor = 0;

  /// Set when a line exceeded [kMacosHostMaxLineBytes]. The rest of that line
  /// is discarded rather than parsed from the middle, which would invent a
  /// message that was never sent.
  bool _overflowed = false;

  /// Feeds raw stdout bytes. Chunk boundaries fall anywhere, including inside
  /// a line and between the `\r` and the `\n`, which is why the split is a
  /// state machine and not a `split`.
  void addBytes(List<int> bytes) {
    for (var index = 0; index < bytes.length; index++) {
      final byte = bytes[index];
      if (byte == _kNewline) {
        if (_overflowed) {
          _overflowed = false;
          _length = 0;
          _sink.onError('LINE_OVERFLOW');
          continue;
        }
        // A `\r\n` host would otherwise leave the carriage return inside the
        // last field of every line.
        if (_length > 0 && _line[_length - 1] == _kReturn) _length--;
        if (_length > 0) _dispatch();
        _length = 0;
        continue;
      }
      if (_overflowed) continue;
      if (_length == _line.length) {
        if (_line.length >= kMacosHostMaxLineBytes) {
          _overflowed = true;
          _length = 0;
          continue;
        }
        _grow();
      }
      _line[_length++] = byte;
    }
  }

  /// Reports a trailing line that arrived without its newline, which is what a
  /// host killed mid-write leaves behind. Called when the stdout stream ends,
  /// so the last thing a dying host managed to say is not thrown away.
  void flush() {
    if (_overflowed) {
      _overflowed = false;
      _length = 0;
      _sink.onError('LINE_OVERFLOW');
      return;
    }
    if (_length > 0 && _line[_length - 1] == _kReturn) _length--;
    if (_length > 0) _dispatch();
    _length = 0;
  }

  void _grow() {
    final capacity = _line.length * 2 > kMacosHostMaxLineBytes
        ? kMacosHostMaxLineBytes
        : _line.length * 2;
    final grown = Uint8List(capacity)..setRange(0, _length, _line);
    _line = grown;
  }

  // --- dispatch --------------------------------------------------------------
  //
  // Switching on the first byte before comparing prefixes keeps the hot lines
  // (INPUT=, WINDOW=, PRESENT_OK) at one or two comparisons. `_startsWith`
  // reads a const String's code units, which allocates nothing.

  void _dispatch() {
    switch (_line[0]) {
      case 0x49: // 'I'
        if (_startsWith('INPUT=')) return _parseInput(6);
      case 0x56: // 'V'
        if (_startsWith('VIEW_INPUT=')) return _parseViewInput(11);
      case 0x57: // 'W'
        if (_startsWith('WINDOW=')) return _parseWindowEvent(7);
        if (_startsWith('WINDOW_ID=')) {
          return _handshakeAt(HostHandshakeField.windowNumber, 10);
        }
        if (_startsWith('WINDOW_SCALE=')) {
          return _handshakeAt(HostHandshakeField.renderScaleMilli, 13);
        }
      case 0x50: // 'P'
        if (_startsWith('PRESENT_OK ')) return _parsePresented(11);
        if (_startsWith('PONG')) return _sink.onAck(HostAckKind.pong, 0);
        if (_startsWith('PROTOCOL_FEATURES=')) {
          return _sink.onProtocolFeatures(_stringFrom(18));
        }
        if (_startsWith('PROTOCOL=')) {
          return _handshakeAt(HostHandshakeField.protocolVersion, 9);
        }
        if (_startsWith('PORT_SERVER_OK ')) {
          return _sink.onAck(HostAckKind.portServer, _length - 15);
        }
      case 0x53: // 'S'
        if (_startsWith('SURFACE_PORT_OK ')) return _parseSurfacePort(16);
        if (_startsWith('SURFACE_POOL_OK ')) {
          return _ackAt(HostAckKind.surfacePoolAllocated, 16);
        }
        if (_startsWith('SURFACES_OK ')) {
          return _ackAt(HostAckKind.surfacePoolLookup, 12);
        }
        if (_startsWith('SURFACE_OK ')) return _parseSurfaceAttached(11);
        if (_startsWith('SHM_OK ')) return _ackAt(HostAckKind.sharedMemory, 7);
      case 0x54: // 'T'
        if (_startsWith('TITLE_OK')) return _sink.onAck(HostAckKind.title, 0);
        if (_startsWith('TEARDOWN=PASS')) {
          return _sink.onAck(HostAckKind.teardown, 0);
        }
      case 0x43: // 'C'
        if (_startsWith('CLOSE_OK')) {
          return _sink.onAck(HostAckKind.closeAccepted, 0);
        }
      case 0x45: // 'E'
        if (_startsWith('ERROR=')) return _sink.onError(_stringFrom(6));
      case 0x4D: // 'M'
        if (_startsWith('MAIN_THREAD=')) {
          _cursor = 12;
          final value = _readInt();
          if (value == 0) {
            // Fatal on its own: a host that is not on thread 0 has thrown away
            // the only guarantee this backend was chosen for.
            return _sink.onAck(HostAckKind.notMainThread, 0);
          }
          return _sink.onHandshake(HostHandshakeField.mainThread, value);
        }
      case 0x48: // 'H'
        if (_startsWith('HOST_PID=')) {
          return _handshakeAt(HostHandshakeField.hostPid, 9);
        }
      case 0x46: // 'F'
        if (_startsWith('FRAME_OK ')) return _ackAt(HostAckKind.frame, 9);
    }
    _sink.onUnrecognised(_stringFrom(0));
  }

  void _handshakeAt(HostHandshakeField field, int offset) {
    _cursor = offset;
    final value = _readInt();
    if (value == kHostFieldMissing) return _sink.onError('BAD_HANDSHAKE');
    _sink.onHandshake(field, value);
  }

  void _ackAt(HostAckKind kind, int offset) {
    _cursor = offset;
    final value = _readInt();
    _sink.onAck(kind, value == kHostFieldMissing ? 0 : value);
  }

  // INPUT=<kind>:<x>:<y>:<keyCode>:<machTime>
  void _parseInput(int offset) {
    _cursor = offset;
    final kind = _readInputKind();
    if (kind == null) return _sink.onError('BAD_INPUT_KIND');
    final x = _readDoubleField();
    final y = _readDoubleField();
    final keyCode = _readIntField();
    // machTime is absent on a protocol 2 host. Zero is a legal reading of a
    // clock nobody stamped, and refusing the whole event over a missing
    // timestamp would drop input to save a measurement.
    final machTime = _readIntField();
    if (x.isNaN || y.isNaN) return _sink.onError('BAD_INPUT_POSITION');
    _sink.onInput(
      kind,
      x,
      y,
      keyCode == kHostFieldMissing ? 0 : keyCode,
      machTime == kHostFieldMissing ? 0 : machTime,
    );
  }

  // VIEW_INPUT=<kind>:<x>:<y>
  void _parseViewInput(int offset) {
    _cursor = offset;
    final kind = _readInputKind();
    if (kind == null) return _sink.onError('BAD_INPUT_KIND');
    final x = _readDoubleField();
    final y = _readDoubleField();
    if (x.isNaN || y.isNaN) return _sink.onError('BAD_INPUT_POSITION');
    _sink.onViewInput(kind, x, y);
  }

  // WINDOW=<KIND>[:<fields>]
  void _parseWindowEvent(int offset) {
    _cursor = offset;
    final start = _cursor;
    while (_cursor < _length && _line[_cursor] != _kColon) {
      _cursor++;
    }
    final end = _cursor;
    if (_regionEquals(start, end, 'RESIZED')) {
      final w = _readDoubleField();
      final h = _readDoubleField();
      final scale = _readDoubleField();
      if (w.isNaN || h.isNaN) return _sink.onError('BAD_WINDOW_RESIZED');
      // A scale of zero would silently allocate a zero-pixel surface later.
      return _sink.onWindowEvent(
        HostWindowEventKind.resized,
        w,
        h,
        scale.isNaN || scale <= 0 ? 1.0 : scale,
        0,
      );
    }
    if (_regionEquals(start, end, 'MOVED')) {
      final x = _readDoubleField();
      final y = _readDoubleField();
      if (x.isNaN || y.isNaN) return _sink.onError('BAD_WINDOW_MOVED');
      return _sink.onWindowEvent(HostWindowEventKind.moved, x, y, 0, 0);
    }
    if (_regionEquals(start, end, 'SCALE')) {
      final render = _readDoubleField();
      final desktop = _readDoubleField();
      if (render.isNaN || render <= 0) return _sink.onError('BAD_WINDOW_SCALE');
      return _sink.onWindowEvent(
        HostWindowEventKind.scaleChanged,
        render,
        desktop.isNaN || desktop <= 0 ? render : desktop,
        0,
        0,
      );
    }
    if (_regionEquals(start, end, 'EXPOSED')) {
      final x = _readDoubleField();
      final y = _readDoubleField();
      final w = _readDoubleField();
      final h = _readDoubleField();
      return _sink.onWindowEvent(
        HostWindowEventKind.exposed,
        x.isNaN ? 0 : x,
        y.isNaN ? 0 : y,
        w.isNaN ? 0 : w,
        h.isNaN ? 0 : h,
      );
    }
    if (_regionEquals(start, end, 'STATE')) {
      final value = _readIntField();
      if (value == kHostFieldMissing || value < 0) {
        return _sink.onError('BAD_WINDOW_STATE');
      }
      return _sink.onWindowEvent(
        HostWindowEventKind.stateChanged,
        value.toDouble(),
        0,
        0,
        0,
      );
    }
    if (_regionEquals(start, end, 'ACTIVATED')) {
      return _sink.onWindowEvent(HostWindowEventKind.activated, 0, 0, 0, 0);
    }
    if (_regionEquals(start, end, 'DEACTIVATED')) {
      return _sink.onWindowEvent(HostWindowEventKind.deactivated, 0, 0, 0, 0);
    }
    if (_regionEquals(start, end, 'CLOSE_REQUESTED')) {
      return _sink.onWindowEvent(
        HostWindowEventKind.closeRequested,
        0,
        0,
        0,
        0,
      );
    }
    if (_regionEquals(start, end, 'CLOSED')) {
      return _sink.onWindowEvent(HostWindowEventKind.closed, 0, 0, 0, 0);
    }
    _sink.onUnrecognised(_stringFrom(0));
  }

  // SURFACE_OK <id> <w>x<h> [slot<n>]
  void _parseSurfaceAttached(int offset) {
    _cursor = offset;
    final id = _readInt();
    if (id == kHostFieldMissing) return _sink.onError('BAD_SURFACE_OK');
    _sink.onSurfaceAttached(id, _findSlotSuffix());
  }

  // SURFACE_PORT_OK <mechanism> <w>x<h> [slot<n>]
  void _parseSurfacePort(int offset) {
    _cursor = offset;
    final start = _cursor;
    while (_cursor < _length && _line[_cursor] != _kSpace) {
      _cursor++;
    }
    final end = _cursor;
    HostSurfaceMechanism mechanism;
    if (_regionEquals(start, end, 'rendezvous')) {
      mechanism = HostSurfaceMechanism.rendezvous;
    } else if (_regionEquals(start, end, 'bootstrap')) {
      mechanism = HostSurfaceMechanism.bootstrap;
    } else if (_regionEquals(start, end, 'registered')) {
      mechanism = HostSurfaceMechanism.registered;
    } else {
      return _sink.onError('BAD_SURFACE_MECHANISM');
    }
    _sink.onSurfacePortAttached(mechanism, _findSlotSuffix());
  }

  // PRESENT_OK <sequence> <transport>, where transport is one of
  // `surface`, `surface-port`, `shm`, `slot<n>`.
  void _parsePresented(int offset) {
    _cursor = offset;
    final sequence = _readInt();
    if (sequence == kHostFieldMissing) return _sink.onError('BAD_PRESENT_OK');
    if (_cursor < _length && _line[_cursor] == _kSpace) _cursor++;
    final start = _cursor;
    final end = _length;
    if (_regionEquals(start, end, 'surface-port')) {
      return _sink.onPresented(
        sequence,
        -1,
        HostPresentTransport.surfacePort,
      );
    }
    if (_regionEquals(start, end, 'surface')) {
      return _sink.onPresented(
        sequence,
        -1,
        HostPresentTransport.surfaceLookup,
      );
    }
    if (_regionEquals(start, end, 'shm')) {
      return _sink.onPresented(
        sequence,
        -1,
        HostPresentTransport.sharedMemory,
      );
    }
    if (end - start > 4 && _regionEquals(start, start + 4, 'slot')) {
      _cursor = start + 4;
      final slot = _readInt();
      if (slot == kHostFieldMissing) return _sink.onError('BAD_PRESENT_SLOT');
      return _sink.onPresented(
        sequence,
        slot,
        HostPresentTransport.surfaceSlot,
      );
    }
    _sink.onError('BAD_PRESENT_TRANSPORT');
  }

  /// Finds a trailing `slot<n>` token, returning -1 when there is none. Lets a
  /// protocol 3 host - which has no per-slot handoff - be understood by the
  /// same code path as a protocol 4 one.
  int _findSlotSuffix() {
    for (var index = 0; index + 5 <= _length; index++) {
      if (_line[index] == _kSpace &&
          _regionEquals(index + 1, index + 5, 'slot')) {
        _cursor = index + 5;
        final slot = _readInt();
        return slot == kHostFieldMissing ? -1 : slot;
      }
    }
    return -1;
  }

  // --- field readers ---------------------------------------------------------

  HostInputKind? _readInputKind() {
    final start = _cursor;
    while (_cursor < _length && _line[_cursor] != _kColon) {
      _cursor++;
    }
    final end = _cursor;
    if (_regionEquals(start, end, 'pointerMove')) {
      return HostInputKind.pointerMove;
    }
    if (_regionEquals(start, end, 'keyDown')) return HostInputKind.keyDown;
    if (_regionEquals(start, end, 'keyUp')) return HostInputKind.keyUp;
    if (_regionEquals(start, end, 'pointerDown')) {
      return HostInputKind.pointerDown;
    }
    if (_regionEquals(start, end, 'pointerUp')) return HostInputKind.pointerUp;
    if (_regionEquals(start, end, 'scroll')) return HostInputKind.scroll;
    if (_regionEquals(start, end, 'other')) return HostInputKind.other;
    return null;
  }

  /// Skips one separator, then reads an integer. Returns [kHostFieldMissing]
  /// when the field is absent, which is how an older host's shorter line is
  /// tolerated instead of rejected.
  int _readIntField() {
    if (_cursor < _length &&
        (_line[_cursor] == _kColon || _line[_cursor] == _kSpace)) {
      _cursor++;
    }
    return _readInt();
  }

  double _readDoubleField() {
    if (_cursor < _length &&
        (_line[_cursor] == _kColon || _line[_cursor] == _kSpace)) {
      _cursor++;
    }
    return _readDouble();
  }

  int _readInt() {
    var negative = false;
    if (_cursor < _length &&
        (_line[_cursor] == _kMinus || _line[_cursor] == _kPlus)) {
      negative = _line[_cursor] == _kMinus;
      _cursor++;
    }
    var digits = 0;
    var value = 0;
    while (_cursor < _length) {
      final byte = _line[_cursor];
      if (byte < _kZero || byte > _kNine) break;
      value = value * 10 + (byte - _kZero);
      digits++;
      _cursor++;
    }
    if (digits == 0) return kHostFieldMissing;
    return negative ? -value : value;
  }

  /// Reads a fixed-point decimal. NaN means "no number here".
  ///
  /// No exponent form: the host prints coordinates with `%.0f` and scales with
  /// `%.4f`, so an `e` in this position means the protocol changed under us and
  /// should be reported, not silently reinterpreted.
  double _readDouble() {
    var negative = false;
    if (_cursor < _length &&
        (_line[_cursor] == _kMinus || _line[_cursor] == _kPlus)) {
      negative = _line[_cursor] == _kMinus;
      _cursor++;
    }
    var digits = 0;
    var value = 0.0;
    while (_cursor < _length) {
      final byte = _line[_cursor];
      if (byte < _kZero || byte > _kNine) break;
      value = value * 10.0 + (byte - _kZero);
      digits++;
      _cursor++;
    }
    if (_cursor < _length && _line[_cursor] == _kDot) {
      _cursor++;
      var scale = 0.1;
      while (_cursor < _length) {
        final byte = _line[_cursor];
        if (byte < _kZero || byte > _kNine) break;
        value += (byte - _kZero) * scale;
        scale *= 0.1;
        digits++;
        _cursor++;
      }
    }
    if (digits == 0) return double.nan;
    return negative ? -value : value;
  }

  /// Compares the buffer against a compile-time constant without allocating.
  bool _startsWith(String prefix) {
    if (_length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (_line[index] != prefix.codeUnitAt(index)) return false;
    }
    return true;
  }

  bool _regionEquals(int start, int end, String text) {
    if (end - start != text.length) return false;
    if (end > _length) return false;
    for (var index = 0; index < text.length; index++) {
      if (_line[start + index] != text.codeUnitAt(index)) return false;
    }
    return true;
  }

  /// The only allocating path, reserved for lines that are rare by design.
  String _stringFrom(int offset) =>
      String.fromCharCodes(_line, offset, _length);
}

/// Builds the commands the host accepts.
///
/// Kept next to the parser so both halves of the protocol change together. The
/// hot one - present - has a byte encoder rather than a String builder,
/// because it runs once per frame and `'PRESENT_SLOT $seq $slot\n'` allocates
/// three objects to say twenty bytes.
final class HostCommands {
  const HostCommands._();

  static String ping() => 'PING\n';

  static String setTitle(String title) => 'SET_TITLE $title\n';

  /// Bounds in top-left-origin screen points, matching
  /// [HostWindowEventKind.moved].
  static String setBounds(double x, double y, double width, double height) =>
      'SET_BOUNDS ${_fixed(x)} ${_fixed(y)} '
      '${_fixed(width)} ${_fixed(height)}\n';

  static String show() => 'SHOW\n';

  static String hide() => 'HIDE\n';

  static String setCursor(String name) => 'CURSOR $name\n';

  /// Null rect means the whole window.
  static String redraw(double x, double y, double width, double height) =>
      'REDRAW ${_fixed(x)} ${_fixed(y)} ${_fixed(width)} ${_fixed(height)}\n';

  static String redrawAll() => 'REDRAW\n';

  /// Allocates an empty pool of [count] slots for per-slot mach-port handoff.
  static String surfacePool(int count) => 'SURFACE_POOL $count\n';

  /// The deprecated fallback: attach a whole pool by global surface id.
  static String surfacesByLookup(List<int> surfaceIds) =>
      'SURFACES ${surfaceIds.join(' ')}\n';

  /// Publishes a launchd receive right the parent can look up and send to.
  static String portServer(String name) => 'PORT_SERVER $name\n';

  /// Receives one surface port into [slot]; -1 for the single-surface form.
  static String surfacePortRendezvous(int slot) => slot < 0
      ? 'SURFACE_PORT RENDEZVOUS\n'
      : 'SURFACE_PORT RENDEZVOUS $slot\n';

  static String presentSlot(int sequence, int slot) =>
      'PRESENT_SLOT $sequence $slot\n';

  static String close() => 'CLOSE\n';

  /// The bootstrap name for a rendezvous with a given host.
  ///
  /// Derived from the host's pid because a name is a launchd-global identifier
  /// and a restarted host must not collide with the one its killed predecessor
  /// published. [attempt] separates two hosts that were handed the same
  /// recycled pid, which is rare but free to rule out.
  static String rendezvousName(int hostPid, int attempt) =>
      'dart-ui.macos.r.$hostPid.$attempt';

  static String _fixed(double value) => value.toStringAsFixed(4);
}
