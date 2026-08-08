import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Frame transport 2 of 3: POSIX shared memory.
//
// The pipe transport copies the whole framebuffer twice per frame - once into
// the pipe, once out of it - and serialises it through a 64 KB kernel buffer.
// A shared mapping copies zero times: Dart writes pixels straight into the
// mapping and the host reads them from the same physical pages. Only a short
// control line still travels through the pipe.
//
// macOS caps shared-memory names at 31 characters and requires a leading
// slash, so the name is kept deliberately short.
// ---------------------------------------------------------------------------

const int _oRdonly = 0x0000;
const int _oRdwr = 0x0002;
const int _oCreat = 0x0200;
const int _oExcl = 0x0800;

const int _protRead = 0x01;
const int _protWrite = 0x02;
const int _mapShared = 0x0001;

final DynamicLibrary _libc = DynamicLibrary.process();

// shm_open is variadic: `int shm_open(const char *, int, ...)`. On arm64 the
// variadic argument goes on the stack, so declaring a plain three-argument
// function would pass the mode in x2 and the kernel would see garbage.
final _shmOpen = _libc.lookupFunction<
    Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
    int Function(Pointer<Utf8>, int, int)>('shm_open');
final _shmUnlink = _libc.lookupFunction<Int32 Function(Pointer<Utf8>),
    int Function(Pointer<Utf8>)>('shm_unlink');
final _ftruncate =
    _libc.lookupFunction<Int32 Function(Int32, Int64), int Function(int, int)>(
        'ftruncate');
final _mmap = _libc.lookupFunction<
    Pointer<Void> Function(Pointer<Void>, IntPtr, Int32, Int32, Int32, Int64),
    Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)>('mmap');
final _munmap = _libc.lookupFunction<Int32 Function(Pointer<Void>, IntPtr),
    int Function(Pointer<Void>, int)>('munmap');
final _close =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _errnoLocation =
    _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error');

int get _errno => _errnoLocation().value;

class SharedFrameBuffer {
  SharedFrameBuffer._(this.name, this._fd, this._mapping, this.byteLength);

  final String name;
  final int _fd;
  final Pointer<Void> _mapping;
  final int byteLength;

  bool _closed = false;

  /// The mapping as a writable view. Writing here IS the frame upload: there is
  /// no later copy step.
  Uint8List get pixels => _mapping.cast<Uint8>().asTypedList(byteLength);

  static SharedFrameBuffer create(String name, int byteLength) {
    final nameUtf8 = name.toNativeUtf8();
    try {
      // A stale segment from a crashed run would otherwise be reused at the
      // wrong size, so always start from a fresh one.
      _shmUnlink(nameUtf8);
      final fd =
          _shmOpen(nameUtf8, _oRdwr | _oCreat | _oExcl, 0x180 /* 0600 */);
      if (fd < 0) {
        throw StateError('shm_open($name) failed, errno=$_errno');
      }
      if (_ftruncate(fd, byteLength) != 0) {
        _close(fd);
        _shmUnlink(nameUtf8);
        throw StateError('ftruncate($byteLength) failed, errno=$_errno');
      }
      final mapping =
          _mmap(nullptr, byteLength, _protRead | _protWrite, _mapShared, fd, 0);
      // mmap reports failure as MAP_FAILED, which is (void *)-1, not null.
      if (mapping.address == 0 || mapping.address == 0xFFFFFFFFFFFFFFFF) {
        _close(fd);
        _shmUnlink(nameUtf8);
        throw StateError('mmap failed, errno=$_errno');
      }
      return SharedFrameBuffer._(name, fd, mapping, byteLength);
    } finally {
      calloc.free(nameUtf8);
    }
  }

  /// Fills the mapping with one solid BGRA colour, in place.
  void fillBgra(int blue, int green, int red, {int alpha = 255}) {
    final bytes = pixels;
    for (var i = 0; i < bytes.length; i += 4) {
      bytes[i] = blue;
      bytes[i + 1] = green;
      bytes[i + 2] = red;
      bytes[i + 3] = alpha;
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _munmap(_mapping, byteLength);
    _close(_fd);
    final nameUtf8 = name.toNativeUtf8();
    _shmUnlink(nameUtf8);
    calloc.free(nameUtf8);
  }
}

/// Read-only attachment, for symmetry with what the host does. Used by tests
/// that verify the host really saw the bytes Dart wrote.
Uint8List? peekSharedFrame(String name, int byteLength) {
  final nameUtf8 = name.toNativeUtf8();
  try {
    final fd = _shmOpen(nameUtf8, _oRdonly, 0);
    if (fd < 0) return null;
    final mapping = _mmap(nullptr, byteLength, _protRead, _mapShared, fd, 0);
    _close(fd);
    if (mapping.address == 0 || mapping.address == 0xFFFFFFFFFFFFFFFF) {
      return null;
    }
    return mapping.cast<Uint8>().asTypedList(byteLength);
  } finally {
    calloc.free(nameUtf8);
  }
}
