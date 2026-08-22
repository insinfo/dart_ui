import 'dart:typed_data';

import 'package:dart_ui/src/backends/wayland/wayland_protocol.dart';
import 'package:dart_ui/src/backends/wayland/wayland_wire.dart';
import 'package:test/test.dart';

void main() {
  group('WaylandMessageWriter', () {
    test('wl_display.get_registry matches the golden wire bytes', () {
      final writer = WaylandMessageWriter();
      writer.begin(wlDisplayObjectId, wlDisplayRequestGetRegistry);
      writer.putNewId(2);

      // Header word 0: object id 1. Word 1: size 12 << 16 | opcode 1.
      // Little-endian, which is the only host order this backend supports.
      expect(writer.take(), <int>[
        0x01, 0x00, 0x00, 0x00, //
        0x01, 0x00, 0x0c, 0x00, //
        0x02, 0x00, 0x00, 0x00, //
      ]);
    });

    test('wl_display.sync matches the golden wire bytes', () {
      final writer = WaylandMessageWriter();
      writer.begin(wlDisplayObjectId, wlDisplayRequestSync);
      writer.putNewId(3);

      expect(writer.take(), <int>[
        0x01, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x0c, 0x00, //
        0x03, 0x00, 0x00, 0x00, //
      ]);
    });

    test('strings carry their NUL and pad to a 32-bit boundary', () {
      final writer = WaylandMessageWriter();
      writer.begin(7, xdgToplevelRequestSetTitle);
      writer.putString('abc');

      // length word 4 (3 chars + NUL), then "abc\0" - already aligned.
      expect(writer.take(), <int>[
        0x07, 0x00, 0x00, 0x00, //
        0x02, 0x00, 0x10, 0x00, //
        0x04, 0x00, 0x00, 0x00, //
        0x61, 0x62, 0x63, 0x00, //
      ]);
    });

    test('non-aligned strings gain zero padding', () {
      final writer = WaylandMessageWriter();
      writer.begin(7, xdgToplevelRequestSetTitle);
      writer.putString('wayland');

      // 7 chars + NUL = 8: aligned. Use 5 chars to force padding.
      final bytes = writer.take();
      expect(bytes.length, 8 + 4 + 8);

      writer.begin(7, xdgToplevelRequestSetTitle);
      writer.putString('olá'); // 4 UTF-8 bytes + NUL = 5, pads to 8.
      final padded = writer.take();
      expect(padded.length, 8 + 4 + 8);
      expect(padded.sublist(12), <int>[
        0x6f, 0x6c, 0xc3, 0xa1, //
        0x00, 0x00, 0x00, 0x00, //
      ]);
    });

    test('arrays pad to a 32-bit boundary without counting the padding', () {
      final writer = WaylandMessageWriter();
      writer.begin(9, 0);
      writer.putArray(Uint8List.fromList(<int>[1, 2, 3, 4, 5]));

      final bytes = writer.take();
      expect(bytes.length, 8 + 4 + 8);
      final data = ByteData.sublistView(bytes);
      expect(data.getUint32(8, Endian.little), 5);
      expect(bytes.sublist(12), <int>[1, 2, 3, 4, 5, 0, 0, 0]);
    });

    test('fds ride out of band and occupy no wire bytes', () {
      final writer = WaylandMessageWriter();
      writer.begin(4, wlShmRequestCreatePool);
      writer.putNewId(5);
      writer.putFd(42);
      writer.putInt(4096);

      expect(writer.fds, <int>[42]);
      final bytes = writer.take();
      expect(bytes.length, 8 + 4 + 4);
    });

    test('rejects opcodes and object ids outside the header fields', () {
      final writer = WaylandMessageWriter();
      expect(() => writer.begin(0, 0), throwsArgumentError);
      expect(() => writer.begin(1, 0x10000), throwsArgumentError);
      expect(() => writer.putUint(-1), throwsArgumentError);
    });

    test('grows past its initial capacity without corrupting bytes', () {
      final writer = WaylandMessageWriter(64);
      writer.begin(1, 0);
      final long = 'x' * 500;
      writer.putString(long);
      final bytes = writer.take();
      expect(bytes.length, 8 + 4 + waylandWordAlign(501));
      expect(bytes[12], 0x78);
      expect(bytes[12 + 499], 0x78);
      expect(bytes[12 + 500], 0);
    });
  });

  group('fixed-point conversion', () {
    test('round-trips representative values', () {
      for (final value in <double>[0, 1, -1, 24.5, -3.25, 1000.125]) {
        expect(
          waylandFixedToDouble(waylandDoubleToFixed(value)),
          value,
          reason: 'value $value',
        );
      }
    });

    test('negative values use two\'s complement on the wire', () {
      expect(waylandDoubleToFixed(-1), 0xffffff00);
      expect(waylandFixedToDouble(0xffffff00), -1.0);
    });
  });

  group('WaylandMessageReader', () {
    test('round-trips every argument kind', () {
      final writer = WaylandMessageWriter();
      writer.begin(3, 1);
      writer.putInt(-7);
      writer.putUint(0xfeedbeef);
      writer.putFixed(12.5);
      writer.putString('painéis');
      writer.putArray(Uint8List.fromList(<int>[9, 8, 7]));
      writer.putObject(11);
      final bytes = writer.take();

      final decoder = WaylandWireDecoder();
      decoder.addBytes(bytes);
      final message = WaylandWireMessage();
      expect(decoder.nextMessage(message), isTrue);
      expect(message.objectId, 3);
      expect(message.opcode, 1);

      final reader = WaylandMessageReader(message.payload);
      expect(reader.readInt(), -7);
      expect(reader.readUint(), 0xfeedbeef);
      expect(reader.readFixed(), 12.5);
      expect(reader.readString(), 'painéis');
      expect(reader.readArray(), <int>[9, 8, 7]);
      expect(reader.readObject(), 11);
      expect(reader.isAtEnd, isTrue);
    });

    test('consumes ancillary fds in argument order', () {
      final fds = <int>[10, 11];
      final writer = WaylandMessageWriter();
      writer.begin(2, 0);
      writer.putUint(1);
      final reader = WaylandMessageReader(
        Uint8List.sublistView(writer.take(), waylandHeaderBytes),
        fds,
      );
      expect(reader.readUint(), 1);
      expect(reader.readFd(), 10);
      expect(reader.readFd(), 11);
      expect(reader.readFd(), -1, reason: 'an absent fd is -1, not a throw');
    });

    test('a truncated payload throws instead of reading garbage', () {
      final reader = WaylandMessageReader(Uint8List(2));
      expect(reader.readUint, throwsStateError);
    });
  });

  group('WaylandWireDecoder', () {
    test('reassembles messages split at arbitrary byte boundaries', () {
      final writer = WaylandMessageWriter();
      writer.begin(5, 2);
      writer.putUint(77);
      final first = writer.take();
      writer.begin(6, 3);
      writer.putString('two');
      final second = writer.take();
      final stream = Uint8List.fromList(<int>[...first, ...second]);

      // Feed one byte at a time: the ugliest chunking a socket can produce.
      final decoder = WaylandWireDecoder();
      final message = WaylandWireMessage();
      final seen = <(int, int)>[];
      for (var i = 0; i < stream.length; i++) {
        decoder.addBytes(Uint8List.fromList(<int>[stream[i]]));
        while (decoder.nextMessage(message)) {
          seen.add((message.objectId, message.opcode));
          if (message.objectId == 5) {
            expect(WaylandMessageReader(message.payload).readUint(), 77);
          } else {
            expect(WaylandMessageReader(message.payload).readString(), 'two');
          }
        }
      }
      expect(seen, <(int, int)>[(5, 2), (6, 3)]);
      expect(decoder.bufferedBytes, 0);
    });

    test('addBytes honours an explicit length prefix', () {
      final writer = WaylandMessageWriter();
      writer.begin(8, 1);
      final bytes = writer.take();
      final oversized = Uint8List(bytes.length + 16);
      oversized.setAll(0, bytes);

      final decoder = WaylandWireDecoder();
      decoder.addBytes(oversized, bytes.length);
      final message = WaylandWireMessage();
      expect(decoder.nextMessage(message), isTrue);
      expect(message.objectId, 8);
      expect(decoder.nextMessage(message), isFalse);
    });

    test('a header that declares less than 8 bytes is a hard error', () {
      final decoder = WaylandWireDecoder();
      final bogus = Uint8List(8);
      ByteData.sublistView(bogus).setUint32(4, 4 << 16, Endian.little);
      decoder.addBytes(bogus);
      expect(() => decoder.nextMessage(WaylandWireMessage()), throwsStateError);
    });
  });
}
