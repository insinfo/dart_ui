import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _xcbCwBackPixel = 1 << 1;
const _xcbCwEventMask = 1 << 11;
const _xcbEventMaskExposure = 1 << 15;
const _xcbEventMaskStructureNotify = 1 << 17;
const _xcbWindowClassInputOutput = 1;
const _xcbZPixmap = 2;
const _xcbExpose = 12;

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

/// A minimal XCB window that is suitable for Xvfb smoke testing.
final class XcbWindow {
  XcbWindow() {
    if (!Platform.isLinux) {
      throw UnsupportedError('POC-02 can run only on Linux/X11.');
    }
  }

  late final DynamicLibrary _xcb = DynamicLibrary.open('libxcb.so.1');
  Pointer<Void> _connection = nullptr;
  int _window = 0;
  int _graphicsContext = 0;
  late final int _rootDepth;

  bool get isConnected => _connection != nullptr;
  int get windowId => _window;

  late final Pointer<Void> Function(Pointer<Int8>, Pointer<Int32>) _connect =
      _xcb.lookupFunction<Pointer<Void> Function(Pointer<Int8>, Pointer<Int32>),
          Pointer<Void> Function(Pointer<Int8>, Pointer<Int32>)>('xcb_connect');
  late final int Function(Pointer<Void>) _connectionHasError =
      _xcb.lookupFunction<Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>(
    'xcb_connection_has_error',
  );
  late final Pointer<Void> Function(Pointer<Void>) _getSetup =
      _xcb.lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>(
    'xcb_get_setup',
  );
  late final _XcbScreenIterator Function(Pointer<Void>) _rootsIterator =
      _xcb.lookupFunction<
          _XcbScreenIterator Function(Pointer<Void>),
          _XcbScreenIterator Function(
              Pointer<Void>)>('xcb_setup_roots_iterator');
  late final int Function(Pointer<Void>) _generateId = _xcb.lookupFunction<
      Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('xcb_generate_id');
  late final void Function(Pointer<Void>, int, int, int, int, int, int, int,
          int, int, int, int, Pointer<Uint32>) _createWindow =
      _xcb.lookupFunction<
          Void Function(Pointer<Void>, Uint8, Uint32, Uint32, Int16, Int16,
              Uint16, Uint16, Uint16, Uint16, Uint32, Uint32, Pointer<Uint32>),
          void Function(Pointer<Void>, int, int, int, int, int, int, int, int,
              int, int, int, Pointer<Uint32>)>('xcb_create_window');
  late final void Function(Pointer<Void>, int) _mapWindow = _xcb.lookupFunction<
      Void Function(Pointer<Void>, Uint32), void Function(Pointer<Void>, int)>(
    'xcb_map_window',
  );
  late final void Function(Pointer<Void>, int, int, int, Pointer<Uint32>)
      _createGc = _xcb.lookupFunction<
          Void Function(Pointer<Void>, Uint32, Uint32, Uint32, Pointer<Uint32>),
          void Function(
              Pointer<Void>, int, int, int, Pointer<Uint32>)>('xcb_create_gc');
  late final void Function(Pointer<Void>, int, int, int, int, int, int, int,
          int, int, int, Pointer<Uint8>) _putImage =
      _xcb.lookupFunction<
          Void Function(Pointer<Void>, Uint8, Uint32, Uint32, Uint16, Uint16,
              Int16, Int16, Uint8, Uint8, Uint32, Pointer<Uint8>),
          void Function(Pointer<Void>, int, int, int, int, int, int, int, int,
              int, int, Pointer<Uint8>)>('xcb_put_image');
  late final Pointer<Uint8> Function(Pointer<Void>) _pollForEvent =
      _xcb.lookupFunction<Pointer<Uint8> Function(Pointer<Void>),
          Pointer<Uint8> Function(Pointer<Void>)>('xcb_poll_for_event');
  late final int Function(Pointer<Void>) _flush = _xcb.lookupFunction<
      Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('xcb_flush');
  late final void Function(Pointer<Void>, int) _destroyWindow =
      _xcb.lookupFunction<Void Function(Pointer<Void>, Uint32),
          void Function(Pointer<Void>, int)>(
    'xcb_destroy_window',
  );
  late final void Function(Pointer<Void>) _disconnect = _xcb.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('xcb_disconnect');

  void create({int width = 160, int height = 120}) {
    final screenNumber = calloc<Int32>();
    try {
      _connection = _connect(nullptr, screenNumber);
    } finally {
      calloc.free(screenNumber);
    }
    if (_connection == nullptr || _connectionHasError(_connection) != 0) {
      dispose();
      throw StateError('xcb_connect failed; verify DISPLAY and X server.');
    }

    final screen = _rootsIterator(_getSetup(_connection)).data.ref;
    _rootDepth = screen.rootDepth;
    _window = _generateId(_connection);
    _graphicsContext = _generateId(_connection);
    final values = calloc<Uint32>(2);
    try {
      values[0] = screen.blackPixel;
      values[1] = _xcbEventMaskExposure | _xcbEventMaskStructureNotify;
      _createWindow(
        _connection,
        _rootDepth,
        _window,
        screen.root,
        0,
        0,
        width,
        height,
        0,
        _xcbWindowClassInputOutput,
        screen.rootVisual,
        _xcbCwBackPixel | _xcbCwEventMask,
        values,
      );
      _createGc(_connection, _graphicsContext, _window, 0, nullptr);
      _mapWindow(_connection, _window);
      _flush(_connection);
    } finally {
      calloc.free(values);
    }
  }

  /// Uploads an opaque BGRA image using XCB's bootstrap `PutImage` path.
  void putBgra(Uint8List pixels, int width, int height) {
    if (_window == 0) throw StateError('Window has not been created.');
    if (pixels.length != width * height * 4) {
      throw ArgumentError.value(
          pixels.length, 'pixels', 'Expected BGRA8888 data.');
    }
    final nativePixels = calloc<Uint8>(pixels.length);
    try {
      nativePixels.asTypedList(pixels.length).setAll(0, pixels);
      _putImage(_connection, _xcbZPixmap, _window, _graphicsContext, width,
          height, 0, 0, 0, _rootDepth, pixels.length, nativePixels);
      _flush(_connection);
    } finally {
      calloc.free(nativePixels);
    }
  }

  /// Polls events until [timeout], returning true once an Expose is observed.
  bool waitForExpose(Duration timeout) {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final event = _pollForEvent(_connection);
      if (event != nullptr) {
        try {
          if ((event.value & 0x7f) == _xcbExpose) return true;
        } finally {
          calloc.free(event);
        }
      }
      sleep(const Duration(milliseconds: 5));
    }
    return false;
  }

  void dispose() {
    if (_connection == nullptr) return;
    if (_window != 0) {
      _destroyWindow(_connection, _window);
      _flush(_connection);
      _window = 0;
    }
    _disconnect(_connection);
    _connection = nullptr;
  }
}
