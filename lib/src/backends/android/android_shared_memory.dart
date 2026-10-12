/// Shared memory the Android host can map: a `memfd`, sized and mapped here.
///
/// The host receives [AndroidSharedBuffer.fd] over the socket (`SCM_RIGHTS`,
/// sent by the transport) and maps it read-only, so a frame crosses the process boundary without being copied
/// through the socket. `memfd_create` is in bionic from API 30; before that the
/// system call is made directly - the kernel has had it since 3.17, and every
/// device that runs API 26 has a newer kernel.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/native_memory.dart';

typedef _MemfdNative = Int32 Function(Pointer<Uint8>, Uint32);
typedef _SyscallNative = Int64 Function(Int64, Pointer<Uint8>, Uint32);
typedef _FtruncateNative = Int32 Function(Int32, Int64);
typedef _MmapNative = Pointer<Uint8> Function(
    Pointer<Void>, IntPtr, Int32, Int32, Int32, Int64);
typedef _MunmapNative = Int32 Function(Pointer<Uint8>, IntPtr);
typedef _CloseNative = Int32 Function(Int32);

const int _protReadWrite = 0x1 | 0x2;
const int _mapShared = 0x1;
const int _mfdCloexec = 0x1;

/// One shared, mapped buffer.
final class AndroidSharedBuffer {
  AndroidSharedBuffer._(this.fd, this.byteSize, this._address);

  /// Creates and maps [byteSize] bytes, zeroed.
  factory AndroidSharedBuffer.create(int byteSize, {String name = 'dart_ui'}) {
    final _Libc libc = _Libc.instance;
    final Pointer<Uint8> label = _cString(name);
    final int fd;
    try {
      fd = libc.memfd(label);
    } finally {
      NativeAllocator.instance.free(label);
    }
    if (fd < 0) throw StateError('memfd_create failed ($fd)');
    if (libc.ftruncate(fd, byteSize) != 0) {
      libc.close(fd);
      throw StateError('ftruncate($byteSize) on the memfd failed');
    }
    final Pointer<Uint8> address =
        libc.mmap(nullptr, byteSize, _protReadWrite, _mapShared, fd, 0);
    if (address.address == -1 || address == nullptr) {
      libc.close(fd);
      throw StateError('mmap of $byteSize bytes failed');
    }
    return AndroidSharedBuffer._(fd, byteSize, address);
  }

  final int fd;
  final int byteSize;
  final Pointer<Uint8> _address;
  bool _released = false;

  /// The mapping, as bytes. Invalid after [release].
  late final Uint8List bytes = _address.asTypedList(byteSize);

  void release() {
    if (_released) return;
    _released = true;
    final _Libc libc = _Libc.instance;
    libc.munmap(_address, byteSize);
    libc.close(fd);
  }
}

Pointer<Uint8> _cString(String value) {
  final List<int> units = value.codeUnits;
  final Pointer<Uint8> text =
      NativeAllocator.instance.allocate<Uint8>(units.length + 1);
  final Uint8List view = text.asTypedList(units.length + 1);
  view.setAll(0, units);
  view[units.length] = 0;
  return text;
}

final class _Libc {
  _Libc._(DynamicLibrary libc)
      : _memfd = _lookupMemfd(libc),
        _syscall = libc.lookupFunction<_SyscallNative,
            int Function(int, Pointer<Uint8>, int)>('syscall'),
        ftruncate =
            libc.lookupFunction<_FtruncateNative, int Function(int, int)>(
                'ftruncate64'),
        mmap = libc.lookupFunction<
            _MmapNative,
            Pointer<Uint8> Function(
                Pointer<Void>, int, int, int, int, int)>('mmap64'),
        munmap = libc.lookupFunction<_MunmapNative,
            int Function(Pointer<Uint8>, int)>('munmap'),
        close = libc.lookupFunction<_CloseNative, int Function(int)>('close');

  static final _Libc instance = _Libc._(DynamicLibrary.process());

  final int Function(Pointer<Uint8>, int)? _memfd;
  final int Function(int, Pointer<Uint8>, int) _syscall;
  final int Function(int, int) ftruncate;
  final Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int) mmap;
  final int Function(Pointer<Uint8>, int) munmap;
  final int Function(int) close;

  static int Function(Pointer<Uint8>, int)? _lookupMemfd(DynamicLibrary libc) {
    try {
      return libc.lookupFunction<_MemfdNative,
          int Function(Pointer<Uint8>, int)>('memfd_create');
    } on ArgumentError {
      return null;
    }
  }

  int memfd(Pointer<Uint8> name) {
    final int Function(Pointer<Uint8>, int)? direct = _memfd;
    if (direct != null) return direct(name, _mfdCloexec);
    // __NR_memfd_create: 279 on arm64, 319 on x86_64.
    final int number = Abi.current() == Abi.androidX64 ? 319 : 279;
    return _syscall(number, name, _mfdCloexec);
  }
}
