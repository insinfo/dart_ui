library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'direct_client.dart';
import 'display.dart';

final class _XcbScreen extends Struct {
  @Uint32()
  external int root;
  @Uint32()
  external int defaultColormap;
  @Uint32()
  external int whitePixel;
  @Uint32()
  external int blackPixel;
  @Uint32()
  external int currentInputMasks;
  @Uint16()
  external int widthInPixels;
  @Uint16()
  external int heightInPixels;
  @Uint16()
  external int widthInMillimeters;
  @Uint16()
  external int heightInMillimeters;
  @Uint16()
  external int minInstalledMaps;
  @Uint16()
  external int maxInstalledMaps;
  @Uint32()
  external int rootVisual;
  @Uint8()
  external int backingStores;
  @Uint8()
  external int saveUnders;
  @Uint8()
  external int rootDepth;
  @Uint8()
  external int allowedDepthsLen;
}

final class _XcbScreenIterator extends Struct {
  external Pointer<_XcbScreen> data;
  @Int32()
  external int rem;
  @Int32()
  external int index;
}

final class _XcbCookie extends Struct {
  @Uint32()
  external int sequence;
}

typedef _ConnectN = Pointer<Void> Function(Pointer<Char>, Pointer<Int32>);
typedef _ConnectD = Pointer<Void> Function(Pointer<Char>, Pointer<Int32>);
typedef _DisconnectN = Void Function(Pointer<Void>);
typedef _DisconnectD = void Function(Pointer<Void>);
typedef _IntConnectionN = Int32 Function(Pointer<Void>);
typedef _IntConnectionD = int Function(Pointer<Void>);
typedef _PointerConnectionN = Pointer<Void> Function(Pointer<Void>);
typedef _PointerConnectionD = Pointer<Void> Function(Pointer<Void>);
typedef _RootsN = _XcbScreenIterator Function(Pointer<Void>);
typedef _RootsD = _XcbScreenIterator Function(Pointer<Void>);
typedef _ScreenNextN = Void Function(Pointer<_XcbScreenIterator>);
typedef _ScreenNextD = void Function(Pointer<_XcbScreenIterator>);
typedef _GenerateIdN = Uint32 Function(Pointer<Void>);
typedef _GenerateIdD = int Function(Pointer<Void>);
typedef _NoOpN = _XcbCookie Function(Pointer<Void>);
typedef _NoOpD = _XcbCookie Function(Pointer<Void>);
typedef _FocusN = _XcbCookie Function(Pointer<Void>);
typedef _FocusD = _XcbCookie Function(Pointer<Void>);
typedef _ReplyN = Pointer<Uint8> Function(
  Pointer<Void>,
  _XcbCookie,
  Pointer<Pointer<Uint8>>,
);
typedef _ReplyD = Pointer<Uint8> Function(
  Pointer<Void>,
  _XcbCookie,
  Pointer<Pointer<Uint8>>,
);
typedef _CreateWindowN = _XcbCookie Function(
  Pointer<Void>,
  Uint8,
  Uint32,
  Uint32,
  Int16,
  Int16,
  Uint16,
  Uint16,
  Uint16,
  Uint16,
  Uint32,
  Uint32,
  Pointer<Uint32>,
);
typedef _CreateWindowD = _XcbCookie Function(
  Pointer<Void>,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  Pointer<Uint32>,
);
typedef _CreateGcN = _XcbCookie Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Uint32>,
);
typedef _CreateGcD = _XcbCookie Function(
  Pointer<Void>,
  int,
  int,
  int,
  Pointer<Uint32>,
);
typedef _PutImageN = _XcbCookie Function(
  Pointer<Void>,
  Uint8,
  Uint32,
  Uint32,
  Uint16,
  Uint16,
  Int16,
  Int16,
  Uint8,
  Uint8,
  Uint32,
  Pointer<Uint8>,
);
typedef _PutImageD = _XcbCookie Function(
  Pointer<Void>,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  Pointer<Uint8>,
);
typedef _ResourceN = _XcbCookie Function(Pointer<Void>, Uint32);
typedef _ResourceD = _XcbCookie Function(Pointer<Void>, int);

final class XcbBenchmarkClient implements X11BenchmarkClient {
  XcbBenchmarkClient({
    required this.display,
    required this.imageWidth,
    required this.imageHeight,
  }) {
    if (!Platform.isLinux) {
      throw UnsupportedError('libxcb benchmark requires Linux');
    }
  }

  final X11DisplayTarget display;
  final int imageWidth;
  final int imageHeight;

  Pointer<Void> _connection = nullptr;
  Pointer<Uint8> _pixels = nullptr;
  Pointer<Pointer<Uint8>> _errorScratch = nullptr;
  int _window = 0;
  int _gc = 0;
  int _rootDepth = 0;

  late _DisconnectD _disconnect;
  late _IntConnectionD _flush;
  late _NoOpD _noOperation;
  late _FocusD _getInputFocus;
  late _ReplyD _getInputFocusReply;
  late _CreateWindowD _createWindow;
  late _CreateGcD _createGc;
  late _PutImageD _putImage;
  late _ResourceD _destroyWindow;
  late _ResourceD _freeGc;

  @override
  String get name => 'libxcb via Dart FFI';

  @override
  Future<void> connect() async {
    if (_connection != nullptr) throw StateError('$name already connected');
    final library = _openXcb();
    final connect = library.lookupFunction<_ConnectN, _ConnectD>('xcb_connect');
    _disconnect =
        library.lookupFunction<_DisconnectN, _DisconnectD>('xcb_disconnect');
    final hasError = library.lookupFunction<_IntConnectionN, _IntConnectionD>(
      'xcb_connection_has_error',
    );
    final getSetup =
        library.lookupFunction<_PointerConnectionN, _PointerConnectionD>(
            'xcb_get_setup');
    final roots = library.lookupFunction<_RootsN, _RootsD>(
      'xcb_setup_roots_iterator',
    );
    final screenNext = library.lookupFunction<_ScreenNextN, _ScreenNextD>(
      'xcb_screen_next',
    );
    final generateId = library.lookupFunction<_GenerateIdN, _GenerateIdD>(
      'xcb_generate_id',
    );
    _flush = library.lookupFunction<_IntConnectionN, _IntConnectionD>(
      'xcb_flush',
    );
    _noOperation = library.lookupFunction<_NoOpN, _NoOpD>('xcb_no_operation');
    _getInputFocus =
        library.lookupFunction<_FocusN, _FocusD>('xcb_get_input_focus');
    _getInputFocusReply = library.lookupFunction<_ReplyN, _ReplyD>(
      'xcb_get_input_focus_reply',
    );
    _createWindow = library.lookupFunction<_CreateWindowN, _CreateWindowD>(
      'xcb_create_window',
    );
    _createGc = library.lookupFunction<_CreateGcN, _CreateGcD>('xcb_create_gc');
    _putImage = library.lookupFunction<_PutImageN, _PutImageD>('xcb_put_image');
    _destroyWindow =
        library.lookupFunction<_ResourceN, _ResourceD>('xcb_destroy_window');
    _freeGc = library.lookupFunction<_ResourceN, _ResourceD>('xcb_free_gc');

    final displayName = display.original.toNativeUtf8().cast<Char>();
    final screenNumber = calloc<Int32>();
    try {
      _connection = connect(displayName, screenNumber);
      if (_connection == nullptr || hasError(_connection) != 0) {
        throw StateError('xcb_connect failed for ${display.original}');
      }
      _errorScratch = calloc<Pointer<Uint8>>();
      final setup = getSetup(_connection);
      if (setup == nullptr) throw StateError('xcb_get_setup returned null');
      final iteratorStorage = calloc<_XcbScreenIterator>();
      try {
        final first = roots(setup);
        iteratorStorage.ref
          ..data = first.data
          ..rem = first.rem
          ..index = first.index;
        for (var i = 0; i < display.screenNumber; i++) {
          if (iteratorStorage.ref.rem <= 1) {
            throw RangeError('DISPLAY requested absent screen $i');
          }
          screenNext(iteratorStorage);
        }
        if (iteratorStorage.ref.data == nullptr) {
          throw StateError('X11 setup contains no selected screen');
        }
        final screen = iteratorStorage.ref.data.ref;
        _rootDepth = screen.rootDepth;
        _window = generateId(_connection);
        _gc = generateId(_connection);
        _createWindow(
          _connection,
          screen.rootDepth,
          _window,
          screen.root,
          0,
          0,
          imageWidth,
          imageHeight,
          0,
          1,
          screen.rootVisual,
          0,
          nullptr,
        );
        _createGc(_connection, _gc, _window, 0, nullptr);
      } finally {
        calloc.free(iteratorStorage);
      }
      _barrier();
      _pixels = malloc<Uint8>(imageWidth * imageHeight * 4);
      final pixels = _pixels.asTypedList(imageWidth * imageHeight * 4);
      for (var i = 0; i < pixels.length; i += 4) {
        final pixel = i ~/ 4;
        pixels[i] = pixel & 0xff;
        pixels[i + 1] = (pixel >> 3) & 0xff;
        pixels[i + 2] = (pixel >> 7) & 0xff;
        pixels[i + 3] = 0xff;
      }
    } catch (_) {
      await close();
      rethrow;
    } finally {
      calloc.free(screenNumber);
      malloc.free(displayName);
    }
  }

  @override
  Future<void> noOperations(int count) async {
    _requireConnection();
    for (var i = 0; i < count; i++) {
      _noOperation(_connection);
    }
    _barrier();
  }

  @override
  Future<void> roundTrips(int count) async {
    _requireConnection();
    for (var i = 0; i < count; i++) {
      _barrier();
    }
  }

  @override
  Future<void> putImages(int count) async {
    _requireConnection();
    if (_pixels == nullptr) throw StateError('$name has no pixel buffer');
    final byteLength = imageWidth * imageHeight * 4;
    for (var i = 0; i < count; i++) {
      _putImage(
        _connection,
        2,
        _window,
        _gc,
        imageWidth,
        imageHeight,
        0,
        0,
        0,
        _rootDepth,
        byteLength,
        _pixels,
      );
    }
    _barrier();
  }

  void _barrier() {
    final cookie = _getInputFocus(_connection);
    if (_flush(_connection) <= 0) throw StateError('xcb_flush failed');
    if (_errorScratch == nullptr) {
      throw StateError('$name has no reply-error scratch');
    }
    _errorScratch.value = nullptr;
    final reply = _getInputFocusReply(_connection, cookie, _errorScratch);
    if (reply == nullptr) {
      final errorPointer = _errorScratch.value;
      final code = errorPointer == nullptr ? -1 : errorPointer[1];
      if (errorPointer != nullptr) malloc.free(errorPointer);
      _errorScratch.value = nullptr;
      throw StateError('xcb_get_input_focus_reply failed: X error $code');
    }
    malloc.free(reply);
  }

  void _requireConnection() {
    if (_connection == nullptr) throw StateError('$name is not connected');
  }

  @override
  Future<void> close() async {
    final connection = _connection;
    _connection = nullptr;
    if (connection != nullptr) {
      if (_gc != 0) _freeGc(connection, _gc);
      if (_window != 0) _destroyWindow(connection, _window);
      _flush(connection);
      _disconnect(connection);
    }
    if (_pixels != nullptr) malloc.free(_pixels);
    if (_errorScratch != nullptr) calloc.free(_errorScratch);
    _pixels = nullptr;
    _errorScratch = nullptr;
    _window = 0;
    _gc = 0;
    _rootDepth = 0;
  }
}

DynamicLibrary _openXcb() {
  for (final name in const <String>['libxcb.so.1', 'libxcb.so']) {
    try {
      return DynamicLibrary.open(name);
    } on Object {
      // Try the development soname after the runtime soname.
    }
  }
  throw StateError('could not load libxcb.so.1 or libxcb.so');
}
