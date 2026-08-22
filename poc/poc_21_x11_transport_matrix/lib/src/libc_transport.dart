library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'direct_client.dart';

const int _afUnix = 1;
const int _sockStream = 1;

typedef _SocketN = Int32 Function(Int32, Int32, Int32);
typedef _SocketD = int Function(int, int, int);
typedef _ConnectN = Int32 Function(Int32, Pointer<Uint8>, Uint32);
typedef _ConnectD = int Function(int, Pointer<Uint8>, int);
typedef _ReadN = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _ReadD = int Function(int, Pointer<Uint8>, int);
typedef _WriteN = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _WriteD = int Function(int, Pointer<Uint8>, int);
typedef _CloseN = Int32 Function(Int32);
typedef _CloseD = int Function(int);

final class LibcUnixTransport implements X11ByteTransport {
  LibcUnixTransport() {
    if (!Platform.isLinux) {
      throw UnsupportedError('libc Unix transport requires Linux');
    }
  }

  late final DynamicLibrary _libc = _openLibc();
  late final _SocketD _socket =
      _libc.lookupFunction<_SocketN, _SocketD>('socket');
  late final _ConnectD _connect =
      _libc.lookupFunction<_ConnectN, _ConnectD>('connect');
  late final _ReadD _read = _libc.lookupFunction<_ReadN, _ReadD>('read');
  late final _WriteD _write = _libc.lookupFunction<_WriteN, _WriteD>('write');
  late final _CloseD _close = _libc.lookupFunction<_CloseN, _CloseD>('close');

  int _fd = -1;
  Pointer<Uint8> _writeScratch = nullptr;
  int _writeCapacity = 0;
  Pointer<Uint8> _readScratch = nullptr;
  int _readCapacity = 0;

  @override
  Future<void> connect(String path) async {
    if (_fd >= 0) throw StateError('libc transport already open');
    final encoded = utf8.encode(path);
    if (encoded.length >= 108) {
      throw RangeError('sockaddr_un path exceeds 107 bytes: $path');
    }
    final fd = _socket(_afUnix, _sockStream, 0);
    if (fd < 0) throw StateError('socket(AF_UNIX, SOCK_STREAM) failed');
    final address = calloc<Uint8>(110);
    try {
      final view = address.asTypedList(110);
      ByteData.sublistView(view).setUint16(0, _afUnix, Endian.host);
      view.setRange(2, 2 + encoded.length, encoded);
      view[2 + encoded.length] = 0;
      if (_connect(fd, address, 2 + encoded.length + 1) != 0) {
        _close(fd);
        throw StateError('connect(AF_UNIX, $path) failed');
      }
      _fd = fd;
    } finally {
      calloc.free(address);
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final fd = _requireFd();
    if (bytes.isEmpty) return;
    final native = _ensureWriteCapacity(bytes.length);
    native.asTypedList(bytes.length).setAll(0, bytes);
    var offset = 0;
    while (offset < bytes.length) {
      final written = _write(fd, native + offset, bytes.length - offset);
      if (written <= 0) {
        throw StateError('write($fd) failed after $offset bytes');
      }
      offset += written;
    }
  }

  @override
  Future<void> flush() async {
    // write(2) is synchronous. The protocol-level barrier in the benchmark is
    // what proves that the X server consumed every preceding request.
  }

  @override
  Future<Uint8List> readExactly(int count) async {
    final fd = _requireFd();
    final native = _ensureReadCapacity(count == 0 ? 1 : count);
    var offset = 0;
    while (offset < count) {
      final received = _read(fd, native + offset, count - offset);
      if (received == 0) {
        throw StateError('X11 socket closed after $offset of $count bytes');
      }
      if (received < 0) {
        throw StateError('read($fd) failed after $offset bytes');
      }
      offset += received;
    }
    return Uint8List.fromList(native.asTypedList(count));
  }

  Pointer<Uint8> _ensureWriteCapacity(int count) {
    if (_writeCapacity >= count) return _writeScratch;
    if (_writeScratch != nullptr) malloc.free(_writeScratch);
    _writeScratch = malloc<Uint8>(count);
    _writeCapacity = count;
    return _writeScratch;
  }

  Pointer<Uint8> _ensureReadCapacity(int count) {
    if (_readCapacity >= count) return _readScratch;
    if (_readScratch != nullptr) malloc.free(_readScratch);
    _readScratch = malloc<Uint8>(count);
    _readCapacity = count;
    return _readScratch;
  }

  int _requireFd() {
    if (_fd < 0) throw StateError('libc transport is not open');
    return _fd;
  }

  @override
  Future<void> close() async {
    final fd = _fd;
    _fd = -1;
    if (fd >= 0) _close(fd);
    if (_writeScratch != nullptr) malloc.free(_writeScratch);
    if (_readScratch != nullptr) malloc.free(_readScratch);
    _writeScratch = nullptr;
    _readScratch = nullptr;
    _writeCapacity = 0;
    _readCapacity = 0;
  }
}

DynamicLibrary _openLibc() {
  final process = DynamicLibrary.process();
  if (process.providesSymbol('socket')) return process;
  for (final name in const <String>['libc.so.6', 'libc.so']) {
    try {
      final library = DynamicLibrary.open(name);
      if (library.providesSymbol('socket')) return library;
    } on Object {
      // Try the next ordinary Linux soname.
    }
  }
  throw StateError('could not load libc socket symbols');
}
