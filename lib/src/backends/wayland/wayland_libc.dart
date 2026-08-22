/// The libc entry points the Wayland backend needs, and nothing more.
///
/// Same policy as `x11_libc.dart`: `package:ffi` is not a dependency, libc is
/// already mapped into every process this backend can run in, and everything
/// here is Linux-shaped. Two further constraints are specific to Wayland:
///
///   * **The socket itself is opened through libc**, not `dart:io`. Wayland
///     passes file descriptors (`SCM_RIGHTS`) attached to ordinary protocol
///     bytes - the keyboard keymap arrives that way, the shm pool fd leaves
///     that way - and `dart:io` sockets cannot see or send ancillary data. One
///     transport must own the descriptor, so all of it is `sendmsg`/`recvmsg`.
///   * **Struct layouts are the LP64 ones** (x86_64/aarch64): `msghdr` is 56
///     bytes, `cmsghdr` headers are 16, `sockaddr_un` is 2 + 108. 32-bit and
///     exotic ABIs differ and are not supported; that is a stated limitation,
///     not an oversight.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';

// ---------------------------------------------------------------------------
// Constants (Linux, x86_64/aarch64 values).
// ---------------------------------------------------------------------------

const int afUnix = 1;
const int sockStream = 1;
const int sockCloexec = 0x80000;
const int sockNonblock = 0x800;

/// `sockaddr_un`: `sa_family_t` (2 bytes) + `sun_path[108]`.
const int sockaddrUnSize = 110;
const int sockaddrUnPathCapacity = 108;

const int solSocket = 1;
const int scmRights = 1;

const int msgDontwait = 0x40;
const int msgNosignal = 0x4000;
const int msgCmsgCloexec = 0x40000000;

/// LP64 `struct msghdr` layout.
const int msghdrSize = 56;
const int msghdrNameOffset = 0;
const int msghdrNamelenOffset = 8;
const int msghdrIovOffset = 16;
const int msghdrIovlenOffset = 24;
const int msghdrControlOffset = 32;
const int msghdrControllenOffset = 40;
const int msghdrFlagsOffset = 48;

/// LP64 `struct iovec`: pointer + size.
const int iovecSize = 16;

/// LP64 `struct cmsghdr` header: `size_t cmsg_len; int cmsg_level; int
/// cmsg_type;` then data, all word-aligned.
const int cmsgHeaderSize = 16;

/// Enough control space for the bursts Wayland actually produces. libwayland
/// uses 28 fds; rounding to 32 costs nothing.
const int maxAncillaryFds = 32;
const int controlBufferSize = cmsgHeaderSize + maxAncillaryFds * 4;

const int oCloexec = 0x80000;
const int oNonblock = 0x800;

const int pollIn = 0x0001;
const int pollErr = 0x0008;
const int pollHup = 0x0010;

/// Size of one `struct pollfd` (int fd, short events, short revents).
const int pollFdSize = 8;

const int eagain = 11;
const int eintr = 4;
const int epipe = 32;
const int econnreset = 104;

const int mfdCloexec = 0x0001;
const int mfdAllowSealing = 0x0002;

const int protRead = 0x1;
const int protWrite = 0x2;
const int mapShared = 0x01;
const int mapPrivate = 0x02;

// ---------------------------------------------------------------------------
// Typedefs.
// ---------------------------------------------------------------------------

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);
typedef _SocketNative = Int32 Function(Int32, Int32, Int32);
typedef _SocketDart = int Function(int, int, int);
typedef _ConnectNative = Int32 Function(Int32, Pointer<Uint8>, Uint32);
typedef _ConnectDart = int Function(int, Pointer<Uint8>, int);
typedef _SendmsgNative = IntPtr Function(Int32, Pointer<Uint8>, Int32);
typedef _SendmsgDart = int Function(int, Pointer<Uint8>, int);
typedef _RecvmsgNative = IntPtr Function(Int32, Pointer<Uint8>, Int32);
typedef _RecvmsgDart = int Function(int, Pointer<Uint8>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _PollNative = Int32 Function(Pointer<Uint8>, UintPtr, Int32);
typedef _PollDart = int Function(Pointer<Uint8>, int, int);
typedef _Pipe2Native = Int32 Function(Pointer<Int32>, Int32);
typedef _Pipe2Dart = int Function(Pointer<Int32>, int);
typedef _ReadNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _ReadDart = int Function(int, Pointer<Uint8>, int);
typedef _WriteNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _WriteDart = int Function(int, Pointer<Uint8>, int);
typedef _MemfdCreateNative = Int32 Function(Pointer<Uint8>, Uint32);
typedef _MemfdCreateDart = int Function(Pointer<Uint8>, int);
typedef _FtruncateNative = Int32 Function(Int32, Int64);
typedef _FtruncateDart = int Function(int, int);
typedef _MmapNative = Pointer<Uint8> Function(
    Pointer<Uint8>, IntPtr, Int32, Int32, Int32, Int64);
typedef _MmapDart = Pointer<Uint8> Function(
    Pointer<Uint8>, int, int, int, int, int);
typedef _MunmapNative = Int32 Function(Pointer<Uint8>, IntPtr);
typedef _MunmapDart = int Function(Pointer<Uint8>, int);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

/// The libc symbols this backend calls, resolved once.
///
/// [open] never throws: a machine missing one of these cannot run the backend,
/// and the probe report needs the missing symbol's name rather than a stack
/// trace from three layers down.
final class WaylandLibc {
  WaylandLibc._(this._library);

  /// Returns null and fills [diagnostics] when libc could not be resolved.
  static WaylandLibc? open(List<BackendDiagnostic> diagnostics) {
    DynamicLibrary? library;
    try {
      library = DynamicLibrary.process();
    } on Object catch (error) {
      diagnostics.add(
        BackendDiagnostic.missingLibrary('process image', detail: '$error'),
      );
    }
    if (library == null || !library.providesSymbol('malloc')) {
      for (final candidate in const <String>['libc.so.6', 'libc.so']) {
        try {
          library = DynamicLibrary.open(candidate);
          break;
        } on Object catch (error) {
          diagnostics.add(
            BackendDiagnostic.missingLibrary(candidate, detail: '$error'),
          );
        }
      }
    }
    if (library == null) return null;

    final missing = <String>[];
    for (final symbol in _requiredSymbols) {
      if (!library.providesSymbol(symbol)) missing.add(symbol);
    }
    if (missing.isNotEmpty) {
      for (final symbol in missing) {
        diagnostics.add(
          BackendDiagnostic.missingSymbol(symbol, detail: 'libc'),
        );
      }
      return null;
    }
    return WaylandLibc._(library);
  }

  /// `memfd_create` is checked separately: it appeared in glibc 2.27 and its
  /// absence only disables shm presentation, not the whole backend.
  static const List<String> _requiredSymbols = <String>[
    'malloc',
    'free',
    'socket',
    'connect',
    'sendmsg',
    'recvmsg',
    'close',
    'poll',
    'pipe2',
    'read',
    'write',
    'ftruncate',
    'mmap',
    'munmap',
  ];

  final DynamicLibrary _library;

  late final _MallocDart _malloc =
      _library.lookupFunction<_MallocNative, _MallocDart>('malloc');
  late final _FreeDart _free =
      _library.lookupFunction<_FreeNative, _FreeDart>('free');
  late final _SocketDart _socket =
      _library.lookupFunction<_SocketNative, _SocketDart>('socket');
  late final _ConnectDart _connect =
      _library.lookupFunction<_ConnectNative, _ConnectDart>('connect');
  late final _SendmsgDart _sendmsg =
      _library.lookupFunction<_SendmsgNative, _SendmsgDart>('sendmsg');
  late final _RecvmsgDart _recvmsg =
      _library.lookupFunction<_RecvmsgNative, _RecvmsgDart>('recvmsg');
  late final _CloseDart _close =
      _library.lookupFunction<_CloseNative, _CloseDart>('close');
  late final _PollDart _poll =
      _library.lookupFunction<_PollNative, _PollDart>('poll');
  late final _Pipe2Dart _pipe2 =
      _library.lookupFunction<_Pipe2Native, _Pipe2Dart>('pipe2');
  late final _ReadDart _read =
      _library.lookupFunction<_ReadNative, _ReadDart>('read');
  late final _WriteDart _write =
      _library.lookupFunction<_WriteNative, _WriteDart>('write');
  late final _FtruncateDart _ftruncate =
      _library.lookupFunction<_FtruncateNative, _FtruncateDart>('ftruncate');
  late final _MmapDart _mmap =
      _library.lookupFunction<_MmapNative, _MmapDart>('mmap');
  late final _MunmapDart _munmap =
      _library.lookupFunction<_MunmapNative, _MunmapDart>('munmap');

  late final bool hasMemfdCreate = _library.providesSymbol('memfd_create');

  late final _MemfdCreateDart _memfdCreate = _library
      .lookupFunction<_MemfdCreateNative, _MemfdCreateDart>('memfd_create');

  late final _ErrnoLocationDart? _errnoLocation =
      _library.providesSymbol('__errno_location')
          ? _library.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
              '__errno_location')
          : null;

  /// The current `errno`, or -1 when the host hides `__errno_location`.
  /// Read immediately after the failing call; any libc call may overwrite it.
  int get errno {
    final location = _errnoLocation;
    if (location == null) return -1;
    return location().value;
  }

  Pointer<Uint8> allocateZeroed(int bytes) {
    final pointer = _malloc(bytes);
    if (pointer == nullptr) return pointer;
    for (var i = 0; i < bytes; i++) {
      pointer[i] = 0;
    }
    return pointer;
  }

  void free(Pointer<Uint8> pointer) {
    if (pointer == nullptr) return;
    _free(pointer);
  }

  /// A NUL-terminated UTF-8 copy of [value]. The caller owns it.
  Pointer<Uint8> allocateUtf8(String value) {
    final bytes = utf8.encode(value);
    final pointer = _malloc(bytes.length + 1);
    if (pointer == nullptr) return pointer;
    for (var i = 0; i < bytes.length; i++) {
      pointer[i] = bytes[i];
    }
    pointer[bytes.length] = 0;
    return pointer;
  }

  int socket(int domain, int type, int protocol) =>
      _socket(domain, type, protocol);

  int connect(int fd, Pointer<Uint8> address, int addressLength) =>
      _connect(fd, address, addressLength);

  int sendmsg(int fd, Pointer<Uint8> msghdr, int flags) =>
      _sendmsg(fd, msghdr, flags);

  int recvmsg(int fd, Pointer<Uint8> msghdr, int flags) =>
      _recvmsg(fd, msghdr, flags);

  int closeFd(int fd) => _close(fd);

  int poll(Pointer<Uint8> fds, int count, int timeoutMillis) =>
      _poll(fds, count, timeoutMillis);

  int pipe2(Pointer<Int32> fds, int flags) => _pipe2(fds, flags);

  int read(int fd, Pointer<Uint8> buffer, int count) =>
      _read(fd, buffer, count);

  int write(int fd, Pointer<Uint8> buffer, int count) =>
      _write(fd, buffer, count);

  int memfdCreate(Pointer<Uint8> name, int flags) => _memfdCreate(name, flags);

  int ftruncate(int fd, int length) => _ftruncate(fd, length);

  Pointer<Uint8> mmap(int length, int prot, int flags, int fd, int offset) =>
      _mmap(nullptr, length, prot, flags, fd, offset);

  int munmap(Pointer<Uint8> address, int length) => _munmap(address, length);
}

// ---------------------------------------------------------------------------
// Struct writers. Byte-indexing a Pointer<Uint8> compiles to a raw store and
// allocates nothing, the same trick x11_libc.dart uses for event decoding.
// ---------------------------------------------------------------------------

final bool waylandHostIsLittleEndian = Endian.host == Endian.little;

int readU16(Pointer<Uint8> p, int offset) {
  if (waylandHostIsLittleEndian) {
    return p[offset] | (p[offset + 1] << 8);
  }
  return (p[offset] << 8) | p[offset + 1];
}

int readU32(Pointer<Uint8> p, int offset) {
  if (waylandHostIsLittleEndian) {
    return p[offset] |
        (p[offset + 1] << 8) |
        (p[offset + 2] << 16) |
        (p[offset + 3] << 24);
  }
  return (p[offset] << 24) |
      (p[offset + 1] << 16) |
      (p[offset + 2] << 8) |
      p[offset + 3];
}

int readU64(Pointer<Uint8> p, int offset) =>
    readU32(p, offset) | (readU32(p, offset + 4) << 32);

void writeU16(Pointer<Uint8> p, int offset, int value) {
  if (waylandHostIsLittleEndian) {
    p[offset] = value & 0xff;
    p[offset + 1] = (value >> 8) & 0xff;
    return;
  }
  p[offset] = (value >> 8) & 0xff;
  p[offset + 1] = value & 0xff;
}

void writeU32(Pointer<Uint8> p, int offset, int value) {
  if (waylandHostIsLittleEndian) {
    p[offset] = value & 0xff;
    p[offset + 1] = (value >> 8) & 0xff;
    p[offset + 2] = (value >> 16) & 0xff;
    p[offset + 3] = (value >> 24) & 0xff;
    return;
  }
  p[offset] = (value >> 24) & 0xff;
  p[offset + 1] = (value >> 16) & 0xff;
  p[offset + 2] = (value >> 8) & 0xff;
  p[offset + 3] = value & 0xff;
}

void writeU64(Pointer<Uint8> p, int offset, int value) {
  writeU32(p, offset, value & 0xffffffff);
  writeU32(p, offset + 4, (value >> 32) & 0xffffffff);
}

void writePointer(Pointer<Uint8> p, int offset, Pointer<Uint8> value) {
  writeU64(p, offset, value.address);
}
