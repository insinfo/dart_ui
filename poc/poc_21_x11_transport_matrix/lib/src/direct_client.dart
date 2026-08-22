library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'display.dart';
import 'libc_transport.dart';
import 'x11_wire.dart';
import 'xauthority.dart';

enum DirectTransportKind { dartIo, libcFfi }

abstract interface class X11BenchmarkClient {
  String get name;
  Future<void> connect();
  Future<void> noOperations(int count);
  Future<void> roundTrips(int count);
  Future<void> putImages(int count);
  Future<void> close();
}

abstract interface class X11ByteTransport {
  Future<void> connect(String path);
  Future<void> write(Uint8List bytes);
  Future<void> flush();
  Future<Uint8List> readExactly(int count);
  Future<void> close();
}

final class DirectX11Client implements X11BenchmarkClient {
  DirectX11Client({
    required this.kind,
    required this.display,
    required this.imageWidth,
    required this.imageHeight,
    this.authorization,
  });

  final DirectTransportKind kind;
  final X11DisplayTarget display;
  final X11Authorization? authorization;
  final int imageWidth;
  final int imageHeight;

  X11ByteTransport? _transport;
  int _window = 0;
  int _gc = 0;
  Uint8List? _putImage;

  @override
  String get name => switch (kind) {
        DirectTransportKind.dartIo => 'dart:io Socket + protocolo Dart',
        DirectTransportKind.libcFfi => 'libc socket FFI + protocolo Dart',
      };

  @override
  Future<void> connect() async {
    if (_transport != null) throw StateError('$name already connected');
    final transport = switch (kind) {
      DirectTransportKind.dartIo => DartIoUnixTransport(),
      DirectTransportKind.libcFfi => LibcUnixTransport(),
    };
    _transport = transport;
    try {
      await transport.connect(display.unixSocketPath);
      final resolvedAuthorization =
          authorization ?? await X11Authorization.discover(display);
      await transport.write(buildConnectionRequest(resolvedAuthorization));
      await transport.flush();
      final prefix = await transport.readExactly(8);
      final extraUnits =
          ByteData.sublistView(prefix).getUint16(6, Endian.little);
      final extra = await transport.readExactly(extraUnits * 4);
      final complete = Uint8List(8 + extra.length)
        ..setRange(0, 8, prefix)
        ..setRange(8, 8 + extra.length, extra);
      if (complete[0] != 1) {
        throw StateError('X11 setup rejected: ${decodeSetupFailure(complete)}');
      }
      final setup = X11Setup.parse(
        complete,
        screenNumber: display.screenNumber,
      );
      final ids = X11ResourceIdGenerator(
        setup.resourceIdBase,
        setup.resourceIdMask,
      );
      _window = ids.next();
      _gc = ids.next();
      final creation = BytesBuilder(copy: false)
        ..add(buildCreateWindow(
          setup: setup,
          window: _window,
          width: imageWidth,
          height: imageHeight,
        ))
        ..add(buildCreateGc(gc: _gc, drawable: _window))
        ..add(buildGetInputFocus());
      await transport.write(creation.takeBytes());
      await transport.flush();
      await _readReply();
      final pixels = Uint8List(imageWidth * imageHeight * 4);
      for (var i = 0; i < pixels.length; i += 4) {
        final pixel = i ~/ 4;
        pixels[i] = pixel & 0xff;
        pixels[i + 1] = (pixel >> 3) & 0xff;
        pixels[i + 2] = (pixel >> 7) & 0xff;
        pixels[i + 3] = 0xff;
      }
      _putImage = buildPutImage(
        drawable: _window,
        gc: _gc,
        width: imageWidth,
        height: imageHeight,
        depth: setup.rootDepth,
        pixels: pixels,
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> noOperations(int count) async {
    final transport = _requireTransport();
    final batch = BytesBuilder(copy: false)
      ..add(buildNoOperations(count))
      ..add(buildGetInputFocus());
    await transport.write(batch.takeBytes());
    await transport.flush();
    await _readReply();
  }

  @override
  Future<void> roundTrips(int count) async {
    final transport = _requireTransport();
    final request = buildGetInputFocus();
    for (var i = 0; i < count; i++) {
      await transport.write(request);
      await transport.flush();
      await _readReply();
    }
  }

  @override
  Future<void> putImages(int count) async {
    final transport = _requireTransport();
    final packet = _putImage;
    if (packet == null) throw StateError('$name has no PutImage request');
    final batch = BytesBuilder(copy: false)
      ..add(repeatPacket(packet, count))
      ..add(buildGetInputFocus());
    await transport.write(batch.takeBytes());
    await transport.flush();
    await _readReply();
  }

  Future<Uint8List> _readReply() async {
    final transport = _requireTransport();
    while (true) {
      final header = await transport.readExactly(32);
      final responseType = header[0] & 0x7f;
      final extraUnits =
          ByteData.sublistView(header).getUint32(4, Endian.little);
      if (responseType == 0) {
        throw StateError(
          'X11 error ${header[1]} from opcode ${header[10]}, '
          'sequence ${ByteData.sublistView(header).getUint16(2, Endian.little)}',
        );
      }
      if (responseType == 1) {
        if (extraUnits > 0) await transport.readExactly(extraUnits * 4);
        return header;
      }
      // GenericEvents may carry data after their fixed 32-byte header.
      if (responseType == 35 && extraUnits > 0) {
        await transport.readExactly(extraUnits * 4);
      }
    }
  }

  X11ByteTransport _requireTransport() {
    final transport = _transport;
    if (transport == null) throw StateError('$name is not connected');
    return transport;
  }

  @override
  Future<void> close() async {
    final transport = _transport;
    _transport = null;
    _putImage = null;
    _window = 0;
    _gc = 0;
    await transport?.close();
  }
}

final class DartIoUnixTransport implements X11ByteTransport {
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final _ByteInbox _inbox = _ByteInbox();

  @override
  Future<void> connect(String path) async {
    if (_socket != null) throw StateError('dart:io transport already open');
    final address = InternetAddress(path, type: InternetAddressType.unix);
    final socket = await Socket.connect(address, 0);
    _socket = socket;
    _subscription = socket.listen(
      _inbox.add,
      onError: _inbox.fail,
      onDone: _inbox.close,
      cancelOnError: true,
    );
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final socket = _socket;
    if (socket == null) throw StateError('dart:io transport is not open');
    socket.add(bytes);
  }

  @override
  Future<void> flush() async {
    final socket = _socket;
    if (socket == null) throw StateError('dart:io transport is not open');
    await socket.flush();
  }

  @override
  Future<Uint8List> readExactly(int count) => _inbox.readExactly(count);

  @override
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.flush();
        await socket.close();
      } finally {
        await _subscription?.cancel();
      }
    }
    _subscription = null;
  }
}

final class _ByteInbox {
  Uint8List _bytes = Uint8List(0);
  int _offset = 0;
  Completer<void>? _signal;
  Object? _error;
  StackTrace? _stackTrace;
  bool _closed = false;

  int get _available => _bytes.length - _offset;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    final combined = Uint8List(_available + chunk.length)
      ..setRange(0, _available, _bytes, _offset)
      ..setRange(_available, _available + chunk.length, chunk);
    _bytes = combined;
    _offset = 0;
    _notify();
  }

  void fail(Object error, StackTrace stackTrace) {
    _error = error;
    _stackTrace = stackTrace;
    _notify();
  }

  void close() {
    _closed = true;
    _notify();
  }

  Future<Uint8List> readExactly(int count) async {
    if (count < 0) throw RangeError.value(count, 'count');
    while (_available < count) {
      final error = _error;
      if (error != null) {
        Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
      }
      if (_closed) {
        throw StateError(
          'X11 socket closed with $_available of $count requested bytes',
        );
      }
      _signal ??= Completer<void>();
      await _signal!.future;
    }
    final result = Uint8List.sublistView(_bytes, _offset, _offset + count);
    _offset += count;
    if (_offset == _bytes.length) {
      _bytes = Uint8List(0);
      _offset = 0;
    }
    return Uint8List.fromList(result);
  }

  void _notify() {
    final signal = _signal;
    _signal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }
}
