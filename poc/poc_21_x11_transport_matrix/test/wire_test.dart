import 'dart:convert';
import 'dart:typed_data';

import 'package:poc_21_x11_transport_matrix/poc_21_x11_transport_matrix.dart';
import 'package:test/test.dart';

void main() {
  group('DISPLAY', () {
    test('parses local display and screen', () {
      final target = X11DisplayTarget.parse(':12.3');
      expect(target.displayNumber, 12);
      expect(target.screenNumber, 3);
      expect(target.unixSocketPath, '/tmp/.X11-unix/X12');
    });

    test('rejects TCP because the benchmark compares Unix sockets', () {
      expect(
        () => X11DisplayTarget.parse('remote.example:0'),
        throwsUnsupportedError,
      );
    });
  });

  test('connection request carries padded MIT cookie fields', () {
    const authorization = X11Authorization(
      name: 'MIT-MAGIC-COOKIE-1',
      data: <int>[1, 2, 3, 4, 5],
    );
    final request = buildConnectionRequest(authorization);
    final view = ByteData.sublistView(request);
    expect(request[0], 0x6c);
    expect(view.getUint16(2, Endian.little), 11);
    expect(view.getUint16(6, Endian.little), 18);
    expect(view.getUint16(8, Endian.little), 5);
    expect(request.length % 4, 0);
  });

  test('NoOperation builder emits independent four-byte requests', () {
    final requests = buildNoOperations(3);
    expect(requests.length, 12);
    for (var offset = 0; offset < requests.length; offset += 4) {
      expect(requests[offset], x11NoOperationOpcode);
      expect(
        ByteData.sublistView(requests).getUint16(offset + 2, Endian.little),
        1,
      );
    }
  });

  test('resource ids honor a mask whose low bits are reserved', () {
    final ids = X11ResourceIdGenerator(0x200000, 0x00fffff0);
    expect(ids.next(), 0x200010);
    expect(ids.next(), 0x200020);
  });

  test('PutImage builder validates and encodes its payload', () {
    final pixels = Uint8List(4 * 3 * 2);
    final request = buildPutImage(
      drawable: 0x101,
      gc: 0x102,
      width: 3,
      height: 2,
      depth: 24,
      pixels: pixels,
    );
    final view = ByteData.sublistView(request);
    expect(request[0], x11PutImageOpcode);
    expect(request[1], 2);
    expect(view.getUint16(2, Endian.little) * 4, request.length);
    expect(view.getUint32(4, Endian.little), 0x101);
    expect(view.getUint16(12, Endian.little), 3);
    expect(request[21], 24);
  });

  test('setup parser walks variable-size screens', () {
    final reply = Uint8List(40 + 40 + 8 + 24 + 40);
    final view = ByteData.sublistView(reply);
    reply[0] = 1;
    reply[28] = 2;
    view.setUint16(26, 65535, Endian.little);
    // Screen 0: one depth containing one visual, so screen 1 begins at 112.
    reply[40 + 39] = 1;
    view.setUint16(40 + 40 + 2, 1, Endian.little);
    const second = 40 + 40 + 8 + 24;
    view
      ..setUint32(12, 0x200000, Endian.little)
      ..setUint32(16, 0x1fffff, Endian.little)
      ..setUint32(second, 0x99, Endian.little)
      ..setUint32(second + 8, 0xffffff, Endian.little)
      ..setUint32(second + 12, 0, Endian.little)
      ..setUint32(second + 32, 0x42, Endian.little);
    reply[second + 38] = 24;
    final setup = X11Setup.parse(reply, screenNumber: 1);
    expect(setup.root, 0x99);
    expect(setup.rootVisual, 0x42);
    expect(setup.rootDepth, 24);
  });

  test('Xauthority parser reads big-endian length-prefixed records', () {
    final builder = BytesBuilder();
    void u16(int value) => builder.add(<int>[value >> 8, value & 0xff]);
    void field(List<int> value) {
      u16(value.length);
      builder.add(value);
    }

    u16(256);
    field(ascii.encode('host'));
    field(ascii.encode('0'));
    field(ascii.encode('MIT-MAGIC-COOKIE-1'));
    field(<int>[0xaa, 0xbb]);
    final records = X11Authorization.parse(builder.takeBytes());
    expect(records, hasLength(1));
    expect(records.single.family, 256);
    expect(records.single.number, '0');
    expect(records.single.data, <int>[0xaa, 0xbb]);
  });
}
