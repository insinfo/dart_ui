// ignore_for_file: implementation_imports
library;

import 'dart:ffi';

import 'package:dart_ui/src/backends/x11/x11_bindings.dart';
import 'package:dart_ui/src/backends/x11/x11_connection.dart';
import 'package:dart_ui/src/backends/x11/x11_libc.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';

const int _xcbGcForeground = 1 << 2;

final class X11BenchmarkContext {
  X11BenchmarkContext._({
    required this.xcb,
    required this.libc,
    required this.connection,
    required this.window,
    required this.gc,
    required this.width,
    required this.height,
  });

  final XcbBindings xcb;
  final X11Libc libc;
  final X11Connection connection;
  final int window;
  final int gc;
  final int width;
  final int height;

  Pointer<Void> get handle => connection.handle;
  int get depth => connection.rootDepth;
  int get visual => connection.rootVisual;
  int get maximumRequestBytes => connection.maximumRequestBytes;

  static X11BenchmarkContext create({
    required int width,
    required int height,
    required String title,
    bool createGraphicsContext = true,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    final xcb = XcbBindings.load(diagnostics);
    final libc = X11Libc.open(diagnostics);
    if (xcb == null || libc == null) {
      throw StateError(diagnostics.join('; '));
    }
    final attempt = X11Connection.open(
      xcb: xcb,
      libc: libc,
      display: null,
    );
    if (attempt.connection is! X11Connection) {
      throw StateError(attempt.diagnostics.join('; '));
    }
    final connection = attempt.connection! as X11Connection;
    final window = connection.createTopLevelWindow(X11TopLevelWindowRequest(
      width: width,
      height: height,
      title: title,
      resizable: false,
      decorated: true,
      visible: true,
    ));
    var gc = 0;
    if (createGraphicsContext) {
      gc = xcb.generateId(connection.handle);
      connection.valueScratch[0] = connection.whitePixel;
      final cookie = xcb.createGcChecked(
        connection.handle,
        gc,
        window,
        _xcbGcForeground,
        connection.valueScratch,
      );
      final error = connection.checkRequest(cookie, 'CreateGC');
      if (error != null) {
        connection.destroyTopLevelWindow(window);
        connection.dispose();
        throw StateError(error);
      }
    }
    connection.flush();
    return X11BenchmarkContext._(
      xcb: xcb,
      libc: libc,
      connection: connection,
      window: window,
      gc: gc,
      width: width,
      height: height,
    );
  }

  void barrier() {
    final cookie = xcb.getGeometry(handle, window);
    final reply = xcb.getGeometryReply(handle, cookie, connection.errorScratch);
    if (reply == nullptr) {
      throw StateError('xcb_get_geometry_reply failed during barrier');
    }
    libc.free(reply);
  }

  Pointer<Uint8> waitForEventType(int responseType) {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final event = xcb.pollForEvent(handle);
      if (event != nullptr) {
        final type = event[0] & 0x7f;
        if (type == responseType) return event;
        if (type == 0) {
          final errorCode = event[1];
          final minorOpcode = readU16(event, 8);
          final majorOpcode = event[10];
          libc.free(event);
          throw StateError(
            'X11 error $errorCode from opcode $majorOpcode:$minorOpcode '
            'while waiting for event $responseType',
          );
        }
        libc.free(event);
        continue;
      }
      connection.waitForActivity(1000);
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('timed out waiting for X11 event $responseType');
      }
    }
  }

  void dispose() {
    if (gc != 0) xcb.freeGc(handle, gc);
    connection.destroyTopLevelWindow(window);
    connection.dispose();
  }
}
