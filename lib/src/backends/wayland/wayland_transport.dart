/// Byte-and-descriptor transport between the client and the compositor.
///
/// The seam exists for the same reason `X11WindowClient` does: everything
/// above it - connection, windows, the whole protocol state machine - is pure
/// Dart over byte arrays, testable on a machine with no Wayland session. Only
/// [WaylandSocketTransport] touches FFI, and it is deliberately dumb: it moves
/// bytes and file descriptors, and knows nothing about messages.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import 'wayland_libc.dart';
import 'wayland_wire.dart';

/// Moving bytes and descriptors, with a doorbell.
///
/// Sending is buffered: [queueMessage] accumulates, [flush] writes. That is
/// not an optimisation detail but the protocol's own advice - Wayland clients
/// batch requests and flush once per pump, and a transport that wrote every
/// message eagerly would syscall per request.
abstract interface class WaylandTransport implements Disposable {
  bool get isOpen;

  /// Queues [bytes] for sending, with [fds] attached to their first byte.
  void queueMessage(Uint8List bytes, List<int> fds);

  /// Writes everything queued. Returns false when the connection failed.
  bool flush();

  /// Drains whatever the compositor already sent, without blocking. Bytes go
  /// into [decoder]; ancillary descriptors are appended to [receivedFds] in
  /// arrival order. Returns the byte count, 0 for nothing, -1 for a dead
  /// connection.
  int receive(WaylandWireDecoder decoder, List<int> receivedFds);

  /// Blocks until the socket or the wake pipe has something, or [timeout]
  /// milliseconds pass (negative blocks indefinitely). Returns true when the
  /// wake pipe fired.
  bool waitForActivity(int timeoutMilliseconds);

  /// Rings the doorbell from any thread or isolate.
  bool signalWake();

  /// Closes a descriptor the compositor handed over (a keymap fd, once read).
  void closeFd(int fd);

  /// A fresh pipe for a clipboard transfer, or null when the host cannot make
  /// one. The read end is handed to `wl_data_offer.receive`-style reads; the
  /// write end serves `wl_data_source.send`. Both ends are close-on-exec.
  ({int readFd, int writeFd})? createPipe();

  /// Writes all of [bytes] to [fd]. Returns false on any failure - the peer
  /// closing its end mid-paste is normal, not exceptional, and the caller
  /// only needs to know the transfer did not complete.
  bool writeAllToFd(int fd, Uint8List bytes);

  /// Reads [fd] to end-of-file, waiting at most [timeoutMilliseconds] for
  /// each chunk, and returns the bytes. Null when the transfer failed or the
  /// writer went silent past the timeout - a hung clipboard owner must cost a
  /// bounded wait, never a frozen isolate.
  Uint8List? readAllFromFd(int fd, {int timeoutMilliseconds = 2000});
}

/// The outcome of trying to open the compositor socket.
final class WaylandTransportAttempt {
  const WaylandTransportAttempt({
    required this.transport,
    required this.diagnostics,
  });

  final WaylandTransport? transport;
  final List<BackendDiagnostic> diagnostics;

  bool get succeeded => transport != null;
}

/// The production transport: one `AF_UNIX` stream socket to
/// `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, spoken through `sendmsg`/`recvmsg` so
/// `SCM_RIGHTS` descriptors ride along with the protocol bytes.
final class WaylandSocketTransport
    with DisposableMixin
    implements WaylandTransport {
  WaylandSocketTransport._(this._libc, this._fd);

  /// Opens [socketPath], or reports exactly what stopped it. Never throws:
  /// a probe walking several backends needs a report from each.
  static WaylandTransportAttempt open({
    required WaylandLibc libc,
    required String socketPath,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    final encodedPath = socketPath.codeUnits;
    if (encodedPath.length > sockaddrUnPathCapacity - 1) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'Wayland socket path exceeds sockaddr_un capacity',
        detail: socketPath,
      ));
      return WaylandTransportAttempt(transport: null, diagnostics: diagnostics);
    }

    final fd = libc.socket(afUnix, sockStream | sockCloexec, 0);
    if (fd < 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'socket(AF_UNIX) failed',
        detail: 'errno=${libc.errno}',
      ));
      return WaylandTransportAttempt(transport: null, diagnostics: diagnostics);
    }

    final address = libc.allocateZeroed(sockaddrUnSize);
    if (address == nullptr) {
      libc.closeFd(fd);
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while preparing sockaddr_un',
      ));
      return WaylandTransportAttempt(transport: null, diagnostics: diagnostics);
    }
    writeU16(address, 0, afUnix);
    for (var i = 0; i < encodedPath.length; i++) {
      address[2 + i] = encodedPath[i] & 0xff;
    }
    final connected = libc.connect(fd, address, sockaddrUnSize);
    final connectErrno = libc.errno;
    libc.free(address);
    if (connected != 0) {
      libc.closeFd(fd);
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'connect to Wayland socket failed',
        detail: '$socketPath (errno=$connectErrno)',
      ));
      return WaylandTransportAttempt(transport: null, diagnostics: diagnostics);
    }

    final transport = WaylandSocketTransport._(libc, fd);
    if (!transport._allocateScratch(diagnostics) ||
        !transport._openWakePipe(diagnostics)) {
      transport.dispose();
      return WaylandTransportAttempt(transport: null, diagnostics: diagnostics);
    }
    diagnostics.add(BackendDiagnostic.note('connected to $socketPath'));
    return WaylandTransportAttempt(
      transport: transport,
      diagnostics: diagnostics,
    );
  }

  final WaylandLibc _libc;
  final int _fd;
  final DisposableBag _bag = DisposableBag();

  bool _broken = false;
  int _wakeReadFd = -1;
  int _wakeWriteFd = -1;

  // Outgoing queue: plain Dart bytes plus the fds attached to the first
  // unsent byte. Copied into native scratch only inside flush().
  final BytesBuilder _outgoing = BytesBuilder(copy: true);
  final List<int> _outgoingFds = <int>[];

  /// Native scratch, allocated once. `_ioBuffer` carries payload both ways;
  /// 64 KiB matches libwayland's own connection buffer.
  static const int _ioBufferSize = 65536;
  late final Pointer<Uint8> _msghdr;
  late final Pointer<Uint8> _iovec;
  late final Pointer<Uint8> _control;
  late final Pointer<Uint8> _ioBuffer;
  late final Pointer<Uint8> _pollScratch;
  late final Pointer<Uint8> _wakeScratch;

  /// Reused per receive: the Dart-side view the decoder copies from.
  final Uint8List _receiveCopy = Uint8List(_ioBufferSize);

  @override
  bool get isOpen => !isDisposed && !_broken;

  bool _allocateScratch(List<BackendDiagnostic> diagnostics) {
    final msghdr = _libc.allocateZeroed(msghdrSize);
    final iovec = _libc.allocateZeroed(iovecSize);
    final control = _libc.allocateZeroed(controlBufferSize);
    final io = _libc.allocateZeroed(_ioBufferSize);
    final poll = _libc.allocateZeroed(2 * pollFdSize);
    final wake = _libc.allocateZeroed(64);
    if (msghdr == nullptr ||
        iovec == nullptr ||
        control == nullptr ||
        io == nullptr ||
        poll == nullptr ||
        wake == nullptr) {
      _libc.free(msghdr);
      _libc.free(iovec);
      _libc.free(control);
      _libc.free(io);
      _libc.free(poll);
      _libc.free(wake);
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while allocating Wayland transport scratch',
      ));
      return false;
    }
    _msghdr = msghdr;
    _iovec = iovec;
    _control = control;
    _ioBuffer = io;
    _pollScratch = poll;
    _wakeScratch = wake;
    _bag.add(msghdr, () {
      _libc.free(msghdr);
      _libc.free(iovec);
      _libc.free(control);
      _libc.free(io);
      _libc.free(poll);
      _libc.free(wake);
    });
    return true;
  }

  bool _openWakePipe(List<BackendDiagnostic> diagnostics) {
    final fds = _libc.allocateZeroed(8).cast<Int32>();
    if (fds == nullptr) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while preparing Wayland wake pipe',
      ));
      return false;
    }
    final result = _libc.pipe2(fds, oCloexec | oNonblock);
    if (result != 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'pipe2 failed; wake() will not interrupt a blocked pump',
        detail: 'errno=${_libc.errno}',
      ));
      _libc.free(fds.cast<Uint8>());
      return false;
    }
    _wakeReadFd = fds[0];
    _wakeWriteFd = fds[1];
    _libc.free(fds.cast<Uint8>());
    _bag.add(_wakeReadFd, () {
      if (_wakeWriteFd >= 0) _libc.closeFd(_wakeWriteFd);
      if (_wakeReadFd >= 0) _libc.closeFd(_wakeReadFd);
      _wakeWriteFd = -1;
      _wakeReadFd = -1;
    });
    return true;
  }

  @override
  void queueMessage(Uint8List bytes, List<int> fds) {
    throwIfDisposed();
    _outgoing.add(bytes);
    _outgoingFds.addAll(fds);
  }

  @override
  bool flush() {
    throwIfDisposed();
    if (_broken) return false;
    if (_outgoing.isEmpty && _outgoingFds.isEmpty) return true;
    final bytes = _outgoing.takeBytes();
    var offset = 0;
    var fdsPending = _outgoingFds.isNotEmpty;
    while (offset < bytes.length) {
      final chunk = bytes.length - offset > _ioBufferSize
          ? _ioBufferSize
          : bytes.length - offset;
      _ioBuffer.asTypedList(_ioBufferSize).setRange(0, chunk, bytes, offset);
      final sent = _sendChunk(chunk, fdsPending ? _outgoingFds : null);
      if (sent < 0) {
        _broken = true;
        _outgoingFds.clear();
        return false;
      }
      if (fdsPending) {
        // Delivered with the first successful sendmsg; never resent.
        _outgoingFds.clear();
        fdsPending = false;
      }
      offset += sent;
      if (sent < chunk) {
        // Socket buffer full: requeue the tail and let the next pump retry.
        _outgoing.add(Uint8List.sublistView(bytes, offset));
        return true;
      }
    }
    return true;
  }

  int _sendChunk(int length, List<int>? fds) {
    // msghdr: no name, one iovec over _ioBuffer, optional SCM_RIGHTS control.
    writePointer(_msghdr, msghdrNameOffset, nullptr);
    writeU32(_msghdr, msghdrNamelenOffset, 0);
    writePointer(_msghdr, msghdrIovOffset, _iovec);
    writeU64(_msghdr, msghdrIovlenOffset, 1);
    writePointer(_iovec, 0, _ioBuffer);
    writeU64(_iovec, 8, length);
    if (fds == null || fds.isEmpty) {
      writePointer(_msghdr, msghdrControlOffset, nullptr);
      writeU64(_msghdr, msghdrControllenOffset, 0);
    } else {
      if (fds.length > maxAncillaryFds) {
        // More descriptors than one control block carries would need message
        // splitting; nothing in this backend sends more than one per flush.
        throw StateError('cannot send ${fds.length} fds in one message');
      }
      final cmsgLen = cmsgHeaderSize + fds.length * 4;
      writeU64(_control, 0, cmsgLen);
      writeU32(_control, 8, solSocket);
      writeU32(_control, 12, scmRights);
      for (var i = 0; i < fds.length; i++) {
        writeU32(_control, cmsgHeaderSize + i * 4, fds[i]);
      }
      writePointer(_msghdr, msghdrControlOffset, _control);
      writeU64(_msghdr, msghdrControllenOffset, (cmsgLen + 7) & ~7);
    }
    writeU32(_msghdr, msghdrFlagsOffset, 0);

    while (true) {
      final sent = _libc.sendmsg(_fd, _msghdr, msgNosignal);
      if (sent >= 0) return sent;
      final error = _libc.errno;
      if (error == eintr) continue;
      if (error == eagain) return 0;
      return -1;
    }
  }

  @override
  int receive(WaylandWireDecoder decoder, List<int> receivedFds) {
    throwIfDisposed();
    if (_broken) return -1;
    var total = 0;
    while (true) {
      writePointer(_msghdr, msghdrNameOffset, nullptr);
      writeU32(_msghdr, msghdrNamelenOffset, 0);
      writePointer(_msghdr, msghdrIovOffset, _iovec);
      writeU64(_msghdr, msghdrIovlenOffset, 1);
      writePointer(_iovec, 0, _ioBuffer);
      writeU64(_iovec, 8, _ioBufferSize);
      writePointer(_msghdr, msghdrControlOffset, _control);
      writeU64(_msghdr, msghdrControllenOffset, controlBufferSize);
      writeU32(_msghdr, msghdrFlagsOffset, 0);

      final received =
          _libc.recvmsg(_fd, _msghdr, msgDontwait | msgCmsgCloexec);
      if (received < 0) {
        final error = _libc.errno;
        if (error == eintr) continue;
        if (error == eagain) return total;
        _broken = true;
        return total > 0 ? total : -1;
      }
      if (received == 0) {
        // Orderly shutdown by the compositor.
        _broken = true;
        return total > 0 ? total : -1;
      }
      _collectAncillaryFds(receivedFds);
      final native = _ioBuffer.asTypedList(received);
      _receiveCopy.setRange(0, received, native);
      decoder.addBytes(_receiveCopy, received);
      total += received;
      if (received < _ioBufferSize) return total;
    }
  }

  void _collectAncillaryFds(List<int> receivedFds) {
    final controlLength = readU64(_msghdr, msghdrControllenOffset);
    var offset = 0;
    while (offset + cmsgHeaderSize <= controlLength) {
      final cmsgLen = readU64(_control, offset);
      if (cmsgLen < cmsgHeaderSize) break;
      final level = readU32(_control, offset + 8);
      final type = readU32(_control, offset + 12);
      final dataBytes = cmsgLen - cmsgHeaderSize;
      if (level == solSocket && type == scmRights) {
        for (var i = 0; i + 4 <= dataBytes; i += 4) {
          receivedFds.add(readU32(_control, offset + cmsgHeaderSize + i));
        }
      }
      offset += (cmsgLen + 7) & ~7;
    }
  }

  @override
  bool waitForActivity(int timeoutMilliseconds) {
    if (isDisposed || _broken) return false;
    writeU32(_pollScratch, 0, _fd);
    writeU16(_pollScratch, 4, pollIn);
    writeU16(_pollScratch, 6, 0);
    var count = 1;
    if (_wakeReadFd >= 0) {
      writeU32(_pollScratch, pollFdSize, _wakeReadFd);
      writeU16(_pollScratch, pollFdSize + 4, pollIn);
      writeU16(_pollScratch, pollFdSize + 6, 0);
      count = 2;
    }
    final ready = _libc.poll(_pollScratch, count, timeoutMilliseconds);
    if (ready <= 0) return false;
    if (count < 2) return false;
    final wakeRevents = readU16(_pollScratch, pollFdSize + 6);
    if ((wakeRevents & pollIn) == 0) return false;
    _drainWakePipe();
    return true;
  }

  void _drainWakePipe() {
    if (_wakeReadFd < 0) return;
    while (true) {
      final read = _libc.read(_wakeReadFd, _wakeScratch, 64);
      if (read < 64) return;
    }
  }

  @override
  bool signalWake() {
    if (_wakeWriteFd < 0) return false;
    _wakeScratch[0] = 1;
    final written = _libc.write(_wakeWriteFd, _wakeScratch, 1);
    if (written == 1) return true;
    return _libc.errno == eagain;
  }

  @override
  void closeFd(int fd) {
    if (fd >= 0) _libc.closeFd(fd);
  }

  @override
  ({int readFd, int writeFd})? createPipe() {
    if (isDisposed) return null;
    final fds = _libc.allocateZeroed(8).cast<Int32>();
    if (fds == nullptr) return null;
    // O_CLOEXEC only: the read side is polled before every read, so blocking
    // descriptors are fine and keep the write side simple for the peer.
    final result = _libc.pipe2(fds, oCloexec);
    if (result != 0) {
      _libc.free(fds.cast<Uint8>());
      return null;
    }
    final pipe = (readFd: fds[0], writeFd: fds[1]);
    _libc.free(fds.cast<Uint8>());
    return pipe;
  }

  @override
  bool writeAllToFd(int fd, Uint8List bytes) {
    if (isDisposed || fd < 0) return false;
    var offset = 0;
    while (offset < bytes.length) {
      final chunk = bytes.length - offset > _ioBufferSize
          ? _ioBufferSize
          : bytes.length - offset;
      _ioBuffer.asTypedList(_ioBufferSize).setRange(0, chunk, bytes, offset);
      final written = _libc.write(fd, _ioBuffer, chunk);
      if (written < 0) {
        if (_libc.errno == eintr) continue;
        // EPIPE when the reader gave up mid-paste: a failed transfer, not a
        // crash. SIGPIPE cannot fire here - the Dart VM ignores it.
        return false;
      }
      if (written == 0) return false;
      offset += written;
    }
    return true;
  }

  @override
  Uint8List? readAllFromFd(int fd, {int timeoutMilliseconds = 2000}) {
    if (isDisposed || fd < 0) return null;
    final builder = BytesBuilder(copy: true);
    while (true) {
      // Poll before each read so a writer that stalls forever costs one
      // timeout, never a blocked isolate.
      writeU32(_pollScratch, 0, fd);
      writeU16(_pollScratch, 4, pollIn);
      writeU16(_pollScratch, 6, 0);
      final ready = _libc.poll(_pollScratch, 1, timeoutMilliseconds);
      if (ready < 0) {
        if (_libc.errno == eintr) continue;
        return null;
      }
      if (ready == 0) return null; // timeout: the owner went silent.
      // POLLHUP still delivers the buffered tail through read(2); the
      // zero-byte read after it is the EOF that finishes the transfer, so
      // revents needs no inspection here.
      final received = _libc.read(fd, _ioBuffer, _ioBufferSize);
      if (received < 0) {
        if (_libc.errno == eintr) continue;
        return null;
      }
      if (received == 0) return builder.takeBytes(); // EOF: transfer complete.
      builder.add(Uint8List.fromList(_ioBuffer.asTypedList(received)));
    }
  }

  @override
  void onDispose() {
    _bag.dispose();
    _libc.closeFd(_fd);
  }
}
