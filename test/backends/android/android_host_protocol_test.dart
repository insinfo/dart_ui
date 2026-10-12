import 'dart:typed_data';

import 'package:dart_ui/src/backends/android/android_host_protocol.dart';
import 'package:dart_ui/src/backends/android/android_input.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:test/test.dart';

/// A host-to-Dart frame, built the way the Java host builds it.
Uint8List frame(int type, void Function(ByteData payload) write, int length) {
  final Uint8List bytes = Uint8List(6 + length);
  ByteData.sublistView(bytes)
    ..setUint32(0, 2 + length, Endian.little)
    ..setUint16(4, type, Endian.little);
  write(ByteData.sublistView(bytes, 6));
  return bytes;
}

Uint8List hello() => frame(AndroidHostMessage.hello, (ByteData p) {
      p
        ..setUint16(0, kAndroidHostProtocolVersion, Endian.little)
        ..setInt32(2, 1080, Endian.little)
        ..setInt32(6, 2340, Endian.little)
        ..setInt32(10, 2750, Endian.little);
    }, 14);

Uint8List touch(int action, double x, double y) =>
    frame(AndroidHostMessage.pointer, (ByteData p) {
      p
        ..setUint8(0, action)
        ..setInt32(1, 7, Endian.little)
        ..setFloat32(5, x, Endian.little)
        ..setFloat32(9, y, Endian.little)
        ..setFloat32(13, 1, Endian.little)
        ..setUint8(17, AndroidToolType.finger.index)
        ..setInt64(18, 123456789, Endian.little)
        ..setInt32(26, 0, Endian.little);
    }, 30);

void main() {
  group('AndroidHostDecoder', () {
    test('decodes the hello banner', () {
      final List<AndroidHostEvent> events = <AndroidHostEvent>[];
      AndroidHostDecoder(events.add).add(hello());
      final AndroidHelloEvent event = events.single as AndroidHelloEvent;
      expect(event.version, kAndroidHostProtocolVersion);
      expect(event.widthPx, 1080);
      expect(event.heightPx, 2340);
      expect(event.density, 2.75);
    });

    test('reassembles frames split at any byte', () {
      final Uint8List stream = Uint8List.fromList(
          <int>[...hello(), ...touch(0, 10.5, 20), ...touch(2, 11, 21)]);
      for (var cut = 1; cut < stream.length; cut++) {
        final List<AndroidHostEvent> events = <AndroidHostEvent>[];
        AndroidHostDecoder(events.add)
          ..add(Uint8List.sublistView(stream, 0, cut))
          ..add(Uint8List.sublistView(stream, cut));
        expect(events, hasLength(3), reason: 'cut at $cut');
        final AndroidPointerEvent down = events[1] as AndroidPointerEvent;
        expect(down.action, AndroidPointerAction.down);
        expect(down.pointerId, 7);
        expect(down.x, 10.5);
        expect(down.eventTimeNanos, 123456789);
        expect(
            (events[2] as AndroidPointerEvent).action, AndroidPointerAction.up);
      }
    });

    test('decodes key, text, focus and back', () {
      final List<AndroidHostEvent> events = <AndroidHostEvent>[];
      AndroidHostDecoder(events.add)
        ..add(frame(AndroidHostMessage.key, (ByteData p) {
          p
            ..setUint8(0, 1)
            ..setInt32(1, 29, Endian.little)
            ..setInt32(5, 30, Endian.little)
            ..setInt32(9, 0x1, Endian.little)
            ..setInt32(13, 0x41, Endian.little)
            ..setInt32(17, 0, Endian.little);
        }, 21))
        ..add(frame(AndroidHostMessage.text, (ByteData p) {
          Uint8List.sublistView(p).setAll(0, <int>[0x6F, 0x6C, 0xC3, 0xA1]);
        }, 4))
        ..add(frame(
            AndroidHostMessage.focus, (ByteData p) => p.setUint8(0, 1), 1))
        ..add(frame(AndroidHostMessage.back, (_) {}, 0));
      final AndroidKeyEvent key = events[0] as AndroidKeyEvent;
      expect(key.down, isTrue);
      expect(key.keyCode, 29);
      expect(key.unicodeChar, 0x41);
      expect((events[1] as AndroidTextEvent).text, 'olá');
      expect((events[2] as AndroidFocusEvent).focused, isTrue);
      expect(events[3], isA<AndroidBackEvent>());
    });

    test('rejects a frame no host sends', () {
      final Uint8List bad = Uint8List(6);
      ByteData.sublistView(bad).setUint32(0, 1, Endian.little);
      expect(() => AndroidHostDecoder((_) {}).add(bad),
          throwsA(isA<FormatException>()));
    });

    test('rejects a short payload instead of reading past it', () {
      expect(
        () => AndroidHostDecoder((_) {})
            .add(frame(AndroidHostMessage.pointer, (_) {}, 4)),
        throwsA(isA<FormatException>()),
      );
    });

    test('keeps an unknown type as such', () {
      final List<AndroidHostEvent> events = <AndroidHostEvent>[];
      AndroidHostDecoder(events.add).add(frame(77, (_) {}, 3));
      final AndroidUnknownEvent unknown = events.single as AndroidUnknownEvent;
      expect(unknown.type, 77);
      expect(unknown.length, 3);
    });
  });

  group('AndroidHostEncoder', () {
    test('frames a surface message with its geometry', () {
      final ByteData view = ByteData.sublistView(AndroidHostEncoder.surface(
          slot: 1,
          widthPx: 1080,
          heightPx: 2340,
          bytesPerRow: 4320,
          byteSize: 4320 * 2340));
      expect(view.lengthInBytes, 6 + 24);
      expect(view.getUint32(0, Endian.little), 2 + 24);
      expect(view.getUint16(4, Endian.little), AndroidHostMessage.surface);
      expect(view.getInt32(6, Endian.little), 1);
      expect(view.getInt32(18, Endian.little), 4320);
      expect(view.getInt64(22, Endian.little), 4320 * 2340);
    });

    test('frames present, keyboard and quit', () {
      expect(AndroidHostEncoder.present(1),
          <int>[6, 0, 0, 0, AndroidHostMessage.present, 0, 1, 0, 0, 0]);
      expect(AndroidHostEncoder.keyboard(show: true),
          <int>[3, 0, 0, 0, AndroidHostMessage.keyboard, 0, 1]);
      expect(AndroidHostEncoder.quit(),
          <int>[2, 0, 0, 0, AndroidHostMessage.quit, 0]);
    });
  });

  group('android input', () {
    test('letters, digits, function keys and the keypad', () {
      expect(androidLogicalKey(29), 0x41); // A
      expect(androidLogicalKey(54), 0x5A); // Z
      expect(androidLogicalKey(7), 0x30); // 0
      expect(androidLogicalKey(131), 0x70); // F1
      expect(androidLogicalKey(153), 0x69); // NUMPAD_9
      expect(androidLogicalKey(66), 0x0D); // ENTER
      expect(androidLogicalKey(67), 0x08); // DEL is backspace
      expect(androidLogicalKey(112), 0x2E); // FORWARD_DEL
      expect(androidLogicalKey(21), 0x25); // DPAD_LEFT
      expect(androidLogicalKey(999), 0);
    });

    test('modifiers and locations', () {
      expect(androidKeyModifiers(0x1 | 0x1000),
          <KeyModifier>{KeyModifier.shift, KeyModifier.control});
      expect(androidKeyLocation(60), KeyLocation.right);
      expect(androidKeyLocation(156), KeyLocation.numpad);
    });

    test('text only for what a key types', () {
      expect(androidKeyText(0x61, 0), 'a');
      expect(androidKeyText(0xE1, 0), 'á');
      expect(androidKeyText(0x0A, 0), isNull); // Enter
      expect(androidKeyText(0x61, 0x1000), isNull); // Ctrl+A is a shortcut
      expect(androidKeyText(0, 0), isNull);
    });

    test('tools and buttons', () {
      expect(androidPointerKind(AndroidToolType.finger), PointerKind.touch);
      expect(androidPointerKind(AndroidToolType.stylus), PointerKind.stylus);
      expect(androidPointerKind(AndroidToolType.mouse), PointerKind.mouse);
      expect(androidPointerButton(AndroidToolType.mouse, 0x2),
          PointerButton.secondary);
      expect(androidPointerButton(AndroidToolType.finger, 0x2),
          PointerButton.primary);
    });
  });
}
