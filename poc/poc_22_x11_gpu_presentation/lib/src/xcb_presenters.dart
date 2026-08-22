// ignore_for_file: implementation_imports
library;

import 'dart:ffi';
import 'dart:math' as math;

import 'package:dart_ui/src/backends/x11/x11_bindings.dart';
import 'package:dart_ui/src/backends/x11/x11_libc.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';

import 'presenter.dart';
import 'x11_context.dart';

const int _xcbImageFormatZPixmap = 2;
const int _protRead = 1;
const int _protWrite = 2;
const int _mapShared = 1;
const int _memfdCloexec = 1;

typedef _AttachFdNative = XcbCookie Function(
  Pointer<Void>,
  Uint32,
  Int32,
  Uint8,
);
typedef _AttachFdDart = XcbCookie Function(Pointer<Void>, int, int, int);
typedef _MemfdCreateNative = Int32 Function(Pointer<Uint8>, Uint32);
typedef _MemfdCreateDart = int Function(Pointer<Uint8>, int);
typedef _FtruncateNative = Int32 Function(Int32, Int64);
typedef _FtruncateDart = int Function(int, int);
typedef _MmapNative = Pointer<Uint8> Function(
  Pointer<Void>,
  IntPtr,
  Int32,
  Int32,
  Int32,
  Int64,
);
typedef _MmapDart = Pointer<Uint8> Function(
  Pointer<Void>,
  int,
  int,
  int,
  int,
  int,
);
typedef _MunmapNative = Int32 Function(Pointer<Uint8>, IntPtr);
typedef _MunmapDart = int Function(Pointer<Uint8>, int);

void _fillFrame(Pointer<Uint8> pixels, int bytes, int variant) {
  final b = variant == 0 ? 0x30 : 0xd0;
  final g = variant == 0 ? 0x90 : 0x40;
  final r = variant == 0 ? 0xe0 : 0x50;
  for (var offset = 0; offset < bytes; offset += 4) {
    pixels[offset] = b;
    pixels[offset + 1] = g;
    pixels[offset + 2] = r;
    pixels[offset + 3] = 0xff;
  }
}

final class PutImagePresenter implements FramePresenter {
  PutImagePresenter(this.width, this.height);

  final int width;
  final int height;
  late final X11BenchmarkContext _x11;
  Pointer<Uint8> _frames = nullptr;
  late final int _frameBytes;

  @override
  String get name => 'XCB core PutImage';
  @override
  String get device => 'CPU + libxcb';
  @override
  String get mode => 'native buffers, split core requests';

  @override
  void initialize() {
    _x11 = X11BenchmarkContext.create(
      width: width,
      height: height,
      title: 'POC-22 PutImage',
    );
    if (!_x11.connection.supportsBgraPutImage) {
      throw StateError('root visual does not support BGRA PutImage');
    }
    _frameBytes = width * height * 4;
    _frames = _x11.libc.allocate(_frameBytes * 2);
    if (_frames == nullptr) {
      throw StateError('native framebuffer allocation failed');
    }
    _fillFrame(_frames, _frameBytes, 0);
    _fillFrame(_frames + _frameBytes, _frameBytes, 1);
  }

  @override
  void present(int frameNumber) {
    final pixels = _frames + (frameNumber & 1) * _frameBytes;
    final rowBytes = width * 4;
    final payloadLimit = math.max(rowBytes, _x11.maximumRequestBytes - 24);
    final rowsPerRequest = math.max(1, payloadLimit ~/ rowBytes);
    for (var y = 0; y < height; y += rowsPerRequest) {
      final rows = math.min(rowsPerRequest, height - y);
      _x11.xcb.putImage(
        _x11.handle,
        _xcbImageFormatZPixmap,
        _x11.window,
        _x11.gc,
        width,
        rows,
        0,
        y,
        0,
        _x11.depth,
        rows * rowBytes,
        pixels + y * rowBytes,
      );
    }
    if (_x11.xcb.flush(_x11.handle) <= 0) {
      throw StateError('xcb_flush failed');
    }
  }

  @override
  void finish() => _x11.barrier();

  @override
  void dispose() {
    if (_frames != nullptr) {
      _x11.libc.free(_frames);
      _frames = nullptr;
    }
    _x11.dispose();
  }
}

final class MitShmPresenter implements FramePresenter {
  MitShmPresenter(this.width, this.height);

  final int width;
  final int height;
  late final X11BenchmarkContext _x11;
  late final XcbShmBindings _shm;
  Pointer<Uint8> _frames = nullptr;
  int _shmid = -1;
  int _segment = 0;
  int _completionEvent = -1;
  late final int _frameBytes;
  int _submitted = 0;
  int _completed = 0;
  bool _usesFileDescriptor = false;
  late final int _mappingBytes;
  late final _MunmapDart _munmap;

  @override
  String get name => 'XCB MIT-SHM';
  @override
  String get device => 'CPU + shared native memory';
  @override
  String get mode => _usesFileDescriptor
      ? 'memfd + mmap, 2 buffers, completion events'
      : 'System V SHM, 2 buffers, completion events';

  @override
  void initialize() {
    _x11 = X11BenchmarkContext.create(
      width: width,
      height: height,
      title: 'POC-22 MIT-SHM',
    );
    if (!_x11.connection.extensions.contains('MIT-SHM')) {
      throw StateError('X server does not advertise MIT-SHM');
    }
    final diagnostics = <BackendDiagnostic>[];
    final loaded = XcbShmBindings.load(diagnostics);
    if (loaded == null) throw StateError(diagnostics.join('; '));
    _shm = loaded;
    _frameBytes = width * height * 4;
    _mappingBytes = _frameBytes * 2;
    _segment = _x11.xcb.generateId(_x11.handle);
    if (!_tryAttachFileDescriptor()) {
      _attachSystemV();
    }
    _fillFrame(_frames, _frameBytes, 0);
    _fillFrame(_frames + _frameBytes, _frameBytes, 1);
    _completionEvent = _queryCompletionEvent();
  }

  bool _tryAttachFileDescriptor() {
    if (!_shm.library.providesSymbol('xcb_shm_attach_fd_checked')) {
      return false;
    }
    final libc = DynamicLibrary.process();
    if (!libc.providesSymbol('memfd_create') ||
        !libc.providesSymbol('ftruncate') ||
        !libc.providesSymbol('mmap') ||
        !libc.providesSymbol('munmap')) {
      return false;
    }
    final memfdCreate = libc
        .lookupFunction<_MemfdCreateNative, _MemfdCreateDart>('memfd_create');
    final ftruncate =
        libc.lookupFunction<_FtruncateNative, _FtruncateDart>('ftruncate');
    final mmap = libc.lookupFunction<_MmapNative, _MmapDart>('mmap');
    _munmap = libc.lookupFunction<_MunmapNative, _MunmapDart>('munmap');
    final attachFd = _shm.library
        .lookupFunction<_AttachFdNative, _AttachFdDart>(
            'xcb_shm_attach_fd_checked');
    final name = _x11.libc.allocateUtf8('dart-ui-poc22');
    final fd = memfdCreate(name, _memfdCloexec);
    _x11.libc.free(name);
    if (fd < 0) return false;
    try {
      if (ftruncate(fd, _mappingBytes) != 0) return false;
      final mapping = mmap(
        nullptr,
        _mappingBytes,
        _protRead | _protWrite,
        _mapShared,
        fd,
        0,
      );
      if (mapping == nullptr || mapping.address == -1) return false;
      final cookie = attachFd(_x11.handle, _segment, fd, 0);
      final error = _x11.connection.checkRequest(cookie, 'ShmAttachFd');
      if (error != null) {
        _munmap(mapping, _mappingBytes);
        return false;
      }
      _frames = mapping;
      _usesFileDescriptor = true;
      return true;
    } finally {
      _x11.libc.closeFd(fd);
    }
  }

  void _attachSystemV() {
    if (!_x11.libc.supportsSharedMemory) {
      throw StateError('System V shared memory is unavailable');
    }
    _shmid = _x11.libc.shmget(ipcPrivate, _mappingBytes, ipcCreat | 0x180);
    if (_shmid < 0) {
      throw StateError('shmget failed, errno=${_x11.libc.errno}');
    }
    _frames = _x11.libc.shmat(_shmid, 0);
    if (_frames.address == -1 || _frames == nullptr) {
      throw StateError('shmat failed, errno=${_x11.libc.errno}');
    }
    final attach = _shm.attachChecked(_x11.handle, _segment, _shmid, 0);
    final error = _x11.connection.checkRequest(attach, 'ShmAttach');
    if (error != null) throw StateError(error);
    _x11.libc.shmctl(_shmid, ipcRmid);
  }

  int _queryCompletionEvent() {
    final name = _x11.libc.allocateUtf8('MIT-SHM');
    try {
      final cookie = _x11.xcb.queryExtension(_x11.handle, 7, name);
      final reply = _x11.xcb.queryExtensionReply(
        _x11.handle,
        cookie,
        _x11.connection.errorScratch,
      );
      if (reply == nullptr || reply[8] == 0) {
        throw StateError('QueryExtension(MIT-SHM) failed');
      }
      try {
        return reply[10];
      } finally {
        _x11.libc.free(reply);
      }
    } finally {
      _x11.libc.free(name);
    }
  }

  void _waitOne() {
    final event = _x11.waitForEventType(_completionEvent);
    _x11.libc.free(event);
    _completed++;
  }

  @override
  void present(int frameNumber) {
    if (_submitted - _completed >= 2) _waitOne();
    final offset = (frameNumber & 1) * _frameBytes;
    _shm.putImage(
      _x11.handle,
      _x11.window,
      _x11.gc,
      width,
      height,
      0,
      0,
      width,
      height,
      0,
      0,
      _x11.depth,
      _xcbImageFormatZPixmap,
      1,
      _segment,
      offset,
    );
    _submitted++;
    if (_x11.xcb.flush(_x11.handle) <= 0) {
      throw StateError('xcb_flush failed');
    }
  }

  @override
  void finish() {
    while (_completed < _submitted) {
      _waitOne();
    }
    _x11.barrier();
  }

  @override
  void dispose() {
    if (_segment != 0) {
      _shm.detach(_x11.handle, _segment);
      _x11.xcb.flush(_x11.handle);
      _segment = 0;
    }
    if (_frames != nullptr && _frames.address != -1) {
      if (_usesFileDescriptor) {
        _munmap(_frames, _mappingBytes);
      } else {
        _x11.libc.shmdt(_frames);
      }
      _frames = nullptr;
    }
    if (_shmid >= 0) {
      _x11.libc.shmctl(_shmid, ipcRmid);
      _shmid = -1;
    }
    _x11.dispose();
  }
}
