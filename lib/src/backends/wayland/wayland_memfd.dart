/// The production [WaylandShmAllocator]: `memfd_create` + `ftruncate` +
/// `mmap`.
///
/// memfd is the right primitive for `wl_shm` on every kernel this backend can
/// meet (Linux >= 3.17, glibc >= 2.27): the fd is anonymous, sealable and
/// needs no name in `/dev/shm` that could collide or leak. Hosts whose libc
/// lacks the wrapper simply lose CPU presentation - the probe says so instead
/// of the first frame failing.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/lifecycle.dart';
import 'wayland_libc.dart';
import 'wayland_shm.dart';

final class WaylandMemfdAllocator implements WaylandShmAllocator {
  WaylandMemfdAllocator(this._libc);

  final WaylandLibc _libc;

  @override
  bool get isAvailable => _libc.hasMemfdCreate;

  @override
  WaylandShmMemory allocate(int byteLength) {
    if (byteLength <= 0) {
      throw ArgumentError.value(byteLength, 'byteLength', 'must be positive');
    }
    if (!isAvailable) {
      throw StateError('memfd_create is not exported by this libc');
    }
    final name = _libc.allocateUtf8('dart_ui-shm');
    if (name == nullptr) {
      throw StateError('malloc failed while naming a Wayland shm pool');
    }
    final fd = _libc.memfdCreate(name, mfdCloexec | mfdAllowSealing);
    final createErrno = _libc.errno;
    _libc.free(name);
    if (fd < 0) {
      throw StateError('memfd_create failed (errno=$createErrno)');
    }
    if (_libc.ftruncate(fd, byteLength) != 0) {
      final error = _libc.errno;
      _libc.closeFd(fd);
      throw StateError(
          'ftruncate($byteLength) failed for a Wayland shm pool '
          '(errno=$error)');
    }
    final mapping = _libc.mmap(
      byteLength,
      protRead | protWrite,
      mapShared,
      fd,
      0,
    );
    // MAP_FAILED is (void*)-1; dart:ffi surfaces it as that address.
    if (mapping == nullptr || mapping.address == -1) {
      final error = _libc.errno;
      _libc.closeFd(fd);
      throw StateError('mmap($byteLength) failed for a Wayland shm pool '
          '(errno=$error)');
    }
    return _MemfdMemory(
      libc: _libc,
      fd: fd,
      mapping: mapping,
      byteLength: byteLength,
    );
  }

  @override
  Uint8List? readSharedMemory(int fd, int byteLength) {
    if (fd < 0 || byteLength <= 0) return null;
    // Keymaps are mapped privately: the compositor may hand the same fd to
    // every client, and MAP_PRIVATE guarantees nobody's write can corrupt it.
    final mapping = _libc.mmap(byteLength, protRead, mapPrivate, fd, 0);
    if (mapping == nullptr || mapping.address == -1) return null;
    try {
      return Uint8List.fromList(mapping.asTypedList(byteLength));
    } finally {
      _libc.munmap(mapping, byteLength);
    }
  }
}

final class _MemfdMemory with DisposableMixin implements WaylandShmMemory {
  _MemfdMemory({
    required WaylandLibc libc,
    required this.fd,
    required Pointer<Uint8> mapping,
    required int byteLength,
  })  : _libc = libc,
        _mapping = mapping,
        _byteLength = byteLength,
        bytes = mapping.asTypedList(byteLength);

  final WaylandLibc _libc;
  final Pointer<Uint8> _mapping;
  final int _byteLength;

  @override
  final int fd;

  @override
  final Uint8List bytes;

  @override
  void onDispose() {
    _libc.munmap(_mapping, _byteLength);
    _libc.closeFd(fd);
  }
}
