/// The handful of libc entry points this backend needs.
///
/// `package:ffi` is deliberately not a dependency of `dart_ui`. Pulling one in
/// to get `calloc` would put a third-party package in the dependency graph of
/// a framework whose whole claim is that it is pure Dart, in exchange for
/// eight bytes of glue. libc is already mapped into every process this backend
/// can run in, so the allocator, the self-pipe used by [X11Libc.write] and the
/// System V shared memory calls all come from there.
///
/// Everything here is Linux-shaped. The constants below (`O_CLOEXEC`,
/// `IPC_CREAT`) are the x86/x86_64/arm/aarch64 values, which is every machine
/// an X server realistically runs on today; mips and alpha differ and are not
/// supported. That is a stated limitation, not an oversight.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';

/// `O_CLOEXEC`. A wake pipe that survives an `exec` is a descriptor leak into
/// every child process the application ever spawns.
const int oCloexec = 0x80000;

/// `O_NONBLOCK`. [X11Libc.write] on the wake pipe must never block: a full
/// pipe already means a wake is pending, so dropping the byte is correct.
const int oNonblock = 0x800;

const int pollIn = 0x0001;
const int pollErr = 0x0008;
const int pollHup = 0x0010;
const int pollNval = 0x0020;

/// Size of one `struct pollfd` (int fd, short events, short revents).
const int pollFdSize = 8;

const int ipcPrivate = 0;
const int ipcCreat = 0x200;
const int ipcRmid = 0;

/// `EAGAIN`/`EWOULDBLOCK` on Linux. The one errno a wake write may return
/// without anything being wrong.
const int eagain = 11;

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);
typedef _Pipe2Native = Int32 Function(Pointer<Int32>, Int32);
typedef _Pipe2Dart = int Function(Pointer<Int32>, int);
typedef _ReadNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _ReadDart = int Function(int, Pointer<Uint8>, int);
typedef _WriteNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _WriteDart = int Function(int, Pointer<Uint8>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _PollNative = Int32 Function(Pointer<Uint8>, UintPtr, Int32);
typedef _PollDart = int Function(Pointer<Uint8>, int, int);
typedef _ShmgetNative = Int32 Function(Int32, IntPtr, Int32);
typedef _ShmgetDart = int Function(int, int, int);
typedef _ShmatNative = Pointer<Uint8> Function(Int32, Pointer<Uint8>, Int32);
typedef _ShmatDart = Pointer<Uint8> Function(int, Pointer<Uint8>, int);
typedef _ShmdtNative = Int32 Function(Pointer<Uint8>);
typedef _ShmdtDart = int Function(Pointer<Uint8>);
typedef _ShmctlNative = Int32 Function(Int32, Int32, Pointer<Uint8>);
typedef _ShmctlDart = int Function(int, int, Pointer<Uint8>);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

/// The libc symbols this backend calls, resolved once.
///
/// [open] never throws. A machine without one of these is not a machine this
/// backend can run on, and the caller needs the name of the missing symbol in
/// its probe report rather than a stack trace from three layers down.
final class X11Libc {
  X11Libc._(this._library);

  /// Returns null and fills [diagnostics] when libc could not be resolved.
  static X11Libc? open(List<BackendDiagnostic> diagnostics) {
    DynamicLibrary? library;
    // The process image already exports libc on Linux. Opening `libc.so.6`
    // explicitly is the fallback for a statically odd host; on musl the
    // soname differs, which is why the process lookup is tried first.
    try {
      library = DynamicLibrary.process();
    } on Object catch (error) {
      diagnostics.add(
        BackendDiagnostic.missingLibrary(
          'process image',
          detail: '$error',
        ),
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
    return X11Libc._(library);
  }

  static const List<String> _requiredSymbols = <String>[
    'malloc',
    'free',
    'pipe2',
    'read',
    'write',
    'close',
    'poll',
  ];

  final DynamicLibrary _library;

  late final _MallocDart _malloc =
      _library.lookupFunction<_MallocNative, _MallocDart>('malloc');
  late final _FreeDart _free =
      _library.lookupFunction<_FreeNative, _FreeDart>('free');
  late final _Pipe2Dart _pipe2 =
      _library.lookupFunction<_Pipe2Native, _Pipe2Dart>('pipe2');
  late final _ReadDart _read =
      _library.lookupFunction<_ReadNative, _ReadDart>('read');
  late final _WriteDart _write =
      _library.lookupFunction<_WriteNative, _WriteDart>('write');
  late final _CloseDart _close =
      _library.lookupFunction<_CloseNative, _CloseDart>('close');
  late final _PollDart _poll =
      _library.lookupFunction<_PollNative, _PollDart>('poll');

  late final bool _hasShm = _library.providesSymbol('shmget') &&
      _library.providesSymbol('shmat') &&
      _library.providesSymbol('shmdt') &&
      _library.providesSymbol('shmctl');

  late final _ShmgetDart _shmget =
      _library.lookupFunction<_ShmgetNative, _ShmgetDart>('shmget');
  late final _ShmatDart _shmat =
      _library.lookupFunction<_ShmatNative, _ShmatDart>('shmat');
  late final _ShmdtDart _shmdt =
      _library.lookupFunction<_ShmdtNative, _ShmdtDart>('shmdt');
  late final _ShmctlDart _shmctl =
      _library.lookupFunction<_ShmctlNative, _ShmctlDart>('shmctl');

  late final _ErrnoLocationDart? _errnoLocation =
      _library.providesSymbol('__errno_location')
          ? _library.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
              '__errno_location')
          : null;

  /// Whether System V shared memory is callable at all. False rules out the
  /// MIT-SHM present path before a single X request is sent.
  bool get supportsSharedMemory => _hasShm;

  /// The current `errno`, or -1 when the host does not expose
  /// `__errno_location` (some hardened libcs do not).
  ///
  /// Read it immediately after the failing call: any intervening libc call may
  /// overwrite it, which is exactly the trap that makes "operation failed"
  /// error messages useless.
  int get errno {
    final location = _errnoLocation;
    if (location == null) return -1;
    return location().value;
  }

  /// Zeroed native memory, or `nullptr` when the allocation failed.
  ///
  /// Zeroing here rather than calling `calloc` keeps the required symbol list
  /// short and makes the cost visible: every buffer this backend allocates is
  /// small and allocated once, never per frame and never per event.
  Pointer<Uint8> allocateZeroed(int bytes) {
    final pointer = _malloc(bytes);
    if (pointer == nullptr) return pointer;
    for (var i = 0; i < bytes; i++) {
      pointer[i] = 0;
    }
    return pointer;
  }

  Pointer<Uint8> allocate(int bytes) => _malloc(bytes);

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

  /// `pipe2(fds, O_CLOEXEC | O_NONBLOCK)`. Returns 0 on success.
  int pipe2(Pointer<Int32> fds, int flags) => _pipe2(fds, flags);

  int read(int fd, Pointer<Uint8> buffer, int count) =>
      _read(fd, buffer, count);

  int write(int fd, Pointer<Uint8> buffer, int count) =>
      _write(fd, buffer, count);

  int closeFd(int fd) => _close(fd);

  int poll(Pointer<Uint8> fds, int count, int timeoutMillis) =>
      _poll(fds, count, timeoutMillis);

  int shmget(int key, int size, int flags) => _shmget(key, size, flags);

  Pointer<Uint8> shmat(int id, int flags) => _shmat(id, nullptr, flags);

  int shmdt(Pointer<Uint8> address) => _shmdt(address);

  int shmctl(int id, int command) => _shmctl(id, command, nullptr);
}

/// True when multi-byte protocol fields are laid out low byte first.
///
/// libxcb hands events to the client in *host* byte order, so this is the only
/// thing the readers below need to know. Every X server this backend will meet
/// is little-endian, but assuming it is how a port to a big-endian host turns
/// into a week of debugging garbled window sizes.
final bool x11HostIsLittleEndian = Endian.host == Endian.little;

/// Reads a 16-bit field at [offset].
///
/// Byte-indexing a `Pointer<Uint8>` compiles to a raw load and allocates
/// nothing - no intermediate `Pointer`, no typed-data view, no box. That is
/// the whole reason these exist instead of `raw.cast<Uint16>()`: section 6.5
/// forbids an allocation per event, and MotionNotify arrives once per pointer
/// sample during a drag.
int readU16(Pointer<Uint8> p, int offset) {
  if (x11HostIsLittleEndian) {
    return p[offset] | (p[offset + 1] << 8);
  }
  return (p[offset] << 8) | p[offset + 1];
}

/// Reads a 16-bit field at [offset] as signed. X window coordinates are
/// `int16` and go negative the moment a window is dragged off the left edge.
int readI16(Pointer<Uint8> p, int offset) {
  final value = readU16(p, offset);
  return value >= 0x8000 ? value - 0x10000 : value;
}

int readU32(Pointer<Uint8> p, int offset) {
  if (x11HostIsLittleEndian) {
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

int readI32(Pointer<Uint8> p, int offset) {
  final value = readU32(p, offset);
  return value >= 0x80000000 ? value - 0x100000000 : value;
}

void writeU32(Pointer<Uint8> p, int offset, int value) {
  if (x11HostIsLittleEndian) {
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

void writeU16(Pointer<Uint8> p, int offset, int value) {
  if (x11HostIsLittleEndian) {
    p[offset] = value & 0xff;
    p[offset + 1] = (value >> 8) & 0xff;
    return;
  }
  p[offset] = (value >> 8) & 0xff;
  p[offset + 1] = value & 0xff;
}
