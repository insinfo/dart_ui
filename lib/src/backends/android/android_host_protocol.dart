/// The binary protocol between the Android host activity and this process.
///
/// The host is a small Java `Activity` (`android/host/`) that owns the window
/// - a `SurfaceView` - and starts the Dart VM as a child process. The two talk
/// over one Unix-domain socket in the abstract namespace, whose name the host
/// passes in `DART_UI_ANDROID_SOCKET`. The shape follows ADR 0001's macOS host:
/// the platform's UI thread stays with the platform, Dart is on the far side
/// of a socket, and pixels travel through shared memory rather than the
/// socket.
///
/// Every message is a frame: a little-endian `u32` length counting the bytes
/// after it, a `u16` type, then the payload. Little-endian because both ends
/// are, and Java reads it with `ByteBuffer.order(LITTLE_ENDIAN)` without a
/// byte swap. A shared-memory buffer travels as an `SCM_RIGHTS` file
/// descriptor attached to its [AndroidHostMessage.surface] frame.
///
/// This file knows bytes and nothing else - no sockets, no windows - so the
/// whole protocol is testable on any machine.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Version of the protocol this side speaks. The host sends its own in
/// [AndroidHostMessage.hello]; a mismatch is refused with a diagnostic.
const int kAndroidHostProtocolVersion = 1;

/// Longest frame accepted, payload included. A frame larger than this is a
/// broken peer, not a message to buffer.
const int kAndroidHostMaxFrameBytes = 1 << 20;

/// Message types. Host to Dart below 100, Dart to host from 100.
abstract final class AndroidHostMessage {
  // Host -> Dart.

  /// `u16 version, i32 widthPx, i32 heightPx, i32 densityMilli`.
  static const int hello = 1;

  /// `i32 widthPx, i32 heightPx, i32 densityMilli` - the surface changed.
  static const int resized = 2;

  /// `u8 action, i32 pointerId, f32 x, f32 y, f32 pressure, u8 toolType,
  /// i64 eventTimeNanos, i32 buttonState`, positions in surface pixels.
  static const int pointer = 3;

  /// `u8 down, i32 keyCode, i32 scanCode, i32 metaState, i32 unicodeChar,
  /// i32 repeatCount`.
  static const int key = 4;

  /// UTF-8 text the input method committed.
  static const int text = 5;

  /// `u8 focused` - the activity window gained or lost input focus.
  static const int focus = 6;

  /// `u8 visible` - `onStart`/`onStop`.
  static const int visibility = 7;

  /// Back was pressed: the framework decides whether that closes.
  static const int back = 8;

  /// `i32 slot` - the host has copied that buffer and it may be reused.
  static const int presented = 9;

  /// `f32 x, f32 y, f32 dx, f32 dy` - a mouse wheel or trackpad scroll.
  static const int scroll = 10;

  /// The surface was destroyed and nothing presented now will show.
  static const int surfaceLost = 11;

  // Dart -> host.

  /// `i32 slot, i32 widthPx, i32 heightPx, i32 bytesPerRow, i64 byteSize`,
  /// plus the buffer's file descriptor as `SCM_RIGHTS`.
  static const int surface = 101;

  /// `i32 slot` - show that buffer.
  static const int present = 102;

  /// UTF-8 title, for the task switcher.
  static const int title = 103;

  /// `u8 show` - raise or hide the soft keyboard.
  static const int keyboard = 104;

  /// The application is done; the host finishes the activity.
  static const int quit = 105;
}

/// `MotionEvent` actions as the host reduces them.
enum AndroidPointerAction { down, move, up, cancel }

/// `MotionEvent.getToolType`, in the host's numbering.
enum AndroidToolType { unknown, finger, stylus, mouse, eraser }

/// A decoded host-to-Dart frame.
sealed class AndroidHostEvent {
  const AndroidHostEvent();
}

final class AndroidHelloEvent extends AndroidHostEvent {
  const AndroidHelloEvent({
    required this.version,
    required this.widthPx,
    required this.heightPx,
    required this.density,
  });

  final int version;
  final int widthPx;
  final int heightPx;

  /// Physical pixels per logical pixel - `DisplayMetrics.density`.
  final double density;
}

final class AndroidResizedEvent extends AndroidHostEvent {
  const AndroidResizedEvent({
    required this.widthPx,
    required this.heightPx,
    required this.density,
  });

  final int widthPx;
  final int heightPx;
  final double density;
}

final class AndroidPointerEvent extends AndroidHostEvent {
  const AndroidPointerEvent({
    required this.action,
    required this.pointerId,
    required this.x,
    required this.y,
    required this.pressure,
    required this.toolType,
    required this.eventTimeNanos,
    required this.buttonState,
  });

  final AndroidPointerAction action;
  final int pointerId;

  /// Surface pixels, top-left origin.
  final double x;
  final double y;
  final double pressure;
  final AndroidToolType toolType;
  final int eventTimeNanos;

  /// `MotionEvent.getButtonState`, for a mouse.
  final int buttonState;
}

final class AndroidKeyEvent extends AndroidHostEvent {
  const AndroidKeyEvent({
    required this.down,
    required this.keyCode,
    required this.scanCode,
    required this.metaState,
    required this.unicodeChar,
    required this.repeatCount,
  });

  final bool down;

  /// `KeyEvent.getKeyCode` - an `AKEYCODE_*`.
  final int keyCode;
  final int scanCode;
  final int metaState;

  /// `KeyEvent.getUnicodeChar(metaState)`; 0 when the key types nothing.
  final int unicodeChar;
  final int repeatCount;
}

final class AndroidTextEvent extends AndroidHostEvent {
  const AndroidTextEvent(this.text);
  final String text;
}

final class AndroidFocusEvent extends AndroidHostEvent {
  const AndroidFocusEvent({required this.focused});
  final bool focused;
}

final class AndroidVisibilityEvent extends AndroidHostEvent {
  const AndroidVisibilityEvent({required this.visible});
  final bool visible;
}

final class AndroidBackEvent extends AndroidHostEvent {
  const AndroidBackEvent();
}

final class AndroidPresentedEvent extends AndroidHostEvent {
  const AndroidPresentedEvent(this.slot);
  final int slot;
}

final class AndroidScrollEvent extends AndroidHostEvent {
  const AndroidScrollEvent({
    required this.x,
    required this.y,
    required this.dx,
    required this.dy,
  });

  final double x;
  final double y;

  /// `AXIS_HSCROLL`/`AXIS_VSCROLL`, in Android's sign: positive `dy` scrolls
  /// up.
  final double dx;
  final double dy;
}

final class AndroidSurfaceLostEvent extends AndroidHostEvent {
  const AndroidSurfaceLostEvent();
}

/// A frame this side did not understand. Kept, not dropped, so the backend
/// can say what arrived.
final class AndroidUnknownEvent extends AndroidHostEvent {
  const AndroidUnknownEvent(this.type, this.length);
  final int type;
  final int length;
}

/// Splits a byte stream into frames and decodes them.
///
/// Bytes arrive in whatever pieces the socket hands over; [add] keeps the
/// tail of an incomplete frame and decodes every complete one.
final class AndroidHostDecoder {
  AndroidHostDecoder(this._emit);

  final void Function(AndroidHostEvent event) _emit;
  Uint8List _pending = Uint8List(0);

  /// Feeds [bytes]; throws [FormatException] for a frame no valid host
  /// sends, after which the stream is not trusted any further.
  void add(Uint8List bytes) {
    final Uint8List data;
    if (_pending.isEmpty) {
      data = bytes;
    } else {
      data = Uint8List(_pending.length + bytes.length)
        ..setRange(0, _pending.length, _pending)
        ..setRange(_pending.length, _pending.length + bytes.length, bytes);
    }
    final ByteData view = ByteData.sublistView(data);
    var offset = 0;
    while (data.length - offset >= 4) {
      final int length = view.getUint32(offset, Endian.little);
      if (length < 2 || length > kAndroidHostMaxFrameBytes) {
        throw FormatException('Android host frame of $length bytes');
      }
      if (data.length - offset - 4 < length) break;
      final int type = view.getUint16(offset + 4, Endian.little);
      _emit(_decode(
          type, ByteData.sublistView(data, offset + 6, offset + 4 + length)));
      offset += 4 + length;
    }
    _pending = offset == data.length
        ? Uint8List(0)
        : Uint8List.fromList(Uint8List.sublistView(data, offset));
  }

  static AndroidHostEvent _decode(int type, ByteData p) {
    try {
      switch (type) {
        case AndroidHostMessage.hello:
          return AndroidHelloEvent(
            version: p.getUint16(0, Endian.little),
            widthPx: p.getInt32(2, Endian.little),
            heightPx: p.getInt32(6, Endian.little),
            density: p.getInt32(10, Endian.little) / 1000,
          );
        case AndroidHostMessage.resized:
          return AndroidResizedEvent(
            widthPx: p.getInt32(0, Endian.little),
            heightPx: p.getInt32(4, Endian.little),
            density: p.getInt32(8, Endian.little) / 1000,
          );
        case AndroidHostMessage.pointer:
          final int action = p.getUint8(0);
          final int tool = p.getUint8(17);
          return AndroidPointerEvent(
            action: action < AndroidPointerAction.values.length
                ? AndroidPointerAction.values[action]
                : AndroidPointerAction.cancel,
            pointerId: p.getInt32(1, Endian.little),
            x: p.getFloat32(5, Endian.little),
            y: p.getFloat32(9, Endian.little),
            pressure: p.getFloat32(13, Endian.little),
            toolType: tool < AndroidToolType.values.length
                ? AndroidToolType.values[tool]
                : AndroidToolType.unknown,
            eventTimeNanos: p.getInt64(18, Endian.little),
            buttonState: p.getInt32(26, Endian.little),
          );
        case AndroidHostMessage.key:
          return AndroidKeyEvent(
            down: p.getUint8(0) != 0,
            keyCode: p.getInt32(1, Endian.little),
            scanCode: p.getInt32(5, Endian.little),
            metaState: p.getInt32(9, Endian.little),
            unicodeChar: p.getInt32(13, Endian.little),
            repeatCount: p.getInt32(17, Endian.little),
          );
        case AndroidHostMessage.text:
          return AndroidTextEvent(
              utf8.decode(Uint8List.sublistView(p), allowMalformed: true));
        case AndroidHostMessage.focus:
          return AndroidFocusEvent(focused: p.getUint8(0) != 0);
        case AndroidHostMessage.visibility:
          return AndroidVisibilityEvent(visible: p.getUint8(0) != 0);
        case AndroidHostMessage.back:
          return const AndroidBackEvent();
        case AndroidHostMessage.presented:
          return AndroidPresentedEvent(p.getInt32(0, Endian.little));
        case AndroidHostMessage.scroll:
          return AndroidScrollEvent(
            x: p.getFloat32(0, Endian.little),
            y: p.getFloat32(4, Endian.little),
            dx: p.getFloat32(8, Endian.little),
            dy: p.getFloat32(12, Endian.little),
          );
        case AndroidHostMessage.surfaceLost:
          return const AndroidSurfaceLostEvent();
      }
    } on RangeError {
      throw FormatException('Android host message $type with a short payload '
          '(${p.lengthInBytes} bytes)');
    }
    return AndroidUnknownEvent(type, p.lengthInBytes);
  }
}

/// Builds Dart-to-host frames.
abstract final class AndroidHostEncoder {
  static Uint8List surface({
    required int slot,
    required int widthPx,
    required int heightPx,
    required int bytesPerRow,
    required int byteSize,
  }) =>
      _frame(AndroidHostMessage.surface, 24, (ByteData p) {
        p
          ..setInt32(0, slot, Endian.little)
          ..setInt32(4, widthPx, Endian.little)
          ..setInt32(8, heightPx, Endian.little)
          ..setInt32(12, bytesPerRow, Endian.little)
          ..setInt64(16, byteSize, Endian.little);
      });

  static Uint8List present(int slot) =>
      _frame(AndroidHostMessage.present, 4, (ByteData p) {
        p.setInt32(0, slot, Endian.little);
      });

  static Uint8List title(String title) =>
      _bytes(AndroidHostMessage.title, utf8.encode(title));

  static Uint8List keyboard({required bool show}) =>
      _frame(AndroidHostMessage.keyboard, 1, (ByteData p) {
        p.setUint8(0, show ? 1 : 0);
      });

  static Uint8List quit() => _frame(AndroidHostMessage.quit, 0, (_) {});

  static Uint8List _bytes(int type, List<int> payload) =>
      _frame(type, payload.length, (ByteData p) {
        Uint8List.sublistView(p).setAll(0, payload);
      });

  static Uint8List _frame(
      int type, int payloadLength, void Function(ByteData payload) write) {
    final Uint8List frame = Uint8List(6 + payloadLength);
    final ByteData view = ByteData.sublistView(frame)
      ..setUint32(0, 2 + payloadLength, Endian.little)
      ..setUint16(4, type, Endian.little);
    write(ByteData.sublistView(frame, 6));
    assert(view.lengthInBytes == frame.length);
    return frame;
  }
}
