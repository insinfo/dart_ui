library;

import 'dart:convert';
import 'dart:typed_data';

import 'xauthority.dart';

const int x11NoOperationOpcode = 127;
const int x11GetInputFocusOpcode = 43;
const int x11PutImageOpcode = 72;

int _pad4(int value) => (value + 3) & ~3;

Uint8List buildConnectionRequest(X11Authorization authorization) {
  final name = ascii.encode(authorization.name);
  final data = authorization.data;
  final result = Uint8List(12 + _pad4(name.length) + _pad4(data.length));
  final view = ByteData.sublistView(result);
  result[0] = 0x6c; // LSB-first.
  view.setUint16(2, 11, Endian.little);
  view.setUint16(4, 0, Endian.little);
  view.setUint16(6, name.length, Endian.little);
  view.setUint16(8, data.length, Endian.little);
  result.setRange(12, 12 + name.length, name);
  final dataOffset = 12 + _pad4(name.length);
  result.setRange(dataOffset, dataOffset + data.length, data);
  return result;
}

final class X11Setup {
  const X11Setup({
    required this.resourceIdBase,
    required this.resourceIdMask,
    required this.maximumRequestUnits,
    required this.root,
    required this.rootVisual,
    required this.rootDepth,
    required this.blackPixel,
    required this.whitePixel,
  });

  factory X11Setup.parse(Uint8List reply, {required int screenNumber}) {
    if (reply.length < 40 || reply[0] != 1) {
      throw const FormatException('not an X11 setup-success packet');
    }
    final view = ByteData.sublistView(reply);
    final rootsLength = reply[28];
    if (screenNumber < 0 || screenNumber >= rootsLength) {
      throw RangeError.range(
        screenNumber,
        0,
        rootsLength - 1,
        'screenNumber',
      );
    }
    final vendorLength = view.getUint16(24, Endian.little);
    final formatsLength = reply[29];
    var screenOffset = 40 + _pad4(vendorLength) + formatsLength * 8;
    for (var screen = 0; screen < screenNumber; screen++) {
      screenOffset = _nextScreenOffset(reply, screenOffset);
    }
    if (screenOffset + 40 > reply.length) {
      throw const FormatException('truncated X11 screen setup');
    }
    return X11Setup(
      resourceIdBase: view.getUint32(12, Endian.little),
      resourceIdMask: view.getUint32(16, Endian.little),
      maximumRequestUnits: view.getUint16(26, Endian.little),
      root: view.getUint32(screenOffset, Endian.little),
      whitePixel: view.getUint32(screenOffset + 8, Endian.little),
      blackPixel: view.getUint32(screenOffset + 12, Endian.little),
      rootVisual: view.getUint32(screenOffset + 32, Endian.little),
      rootDepth: reply[screenOffset + 38],
    );
  }

  final int resourceIdBase;
  final int resourceIdMask;
  final int maximumRequestUnits;
  final int root;
  final int rootVisual;
  final int rootDepth;
  final int blackPixel;
  final int whitePixel;
}

int _nextScreenOffset(Uint8List reply, int offset) {
  if (offset + 40 > reply.length) {
    throw const FormatException('truncated X11 screen record');
  }
  final depths = reply[offset + 39];
  var cursor = offset + 40;
  final view = ByteData.sublistView(reply);
  for (var depth = 0; depth < depths; depth++) {
    if (cursor + 8 > reply.length) {
      throw const FormatException('truncated X11 depth record');
    }
    final visuals = view.getUint16(cursor + 2, Endian.little);
    cursor += 8 + visuals * 24;
    if (cursor > reply.length) {
      throw const FormatException('truncated X11 visual list');
    }
  }
  return cursor;
}

final class X11ResourceIdGenerator {
  X11ResourceIdGenerator(this.base, this.mask) : _increment = mask & -mask {
    if (mask == 0) throw ArgumentError.value(mask, 'mask', 'must not be zero');
  }

  final int base;
  final int mask;
  final int _increment;
  int _variable = 0;

  int next() {
    _variable = (_variable + _increment) & mask;
    if (_variable == 0) {
      throw StateError('X11 resource-id range exhausted');
    }
    return base | _variable;
  }
}

Uint8List buildNoOperations(int count) {
  if (count < 0) throw RangeError.value(count, 'count');
  final result = Uint8List(count * 4);
  final view = ByteData.sublistView(result);
  for (var i = 0; i < count; i++) {
    final offset = i * 4;
    result[offset] = x11NoOperationOpcode;
    view.setUint16(offset + 2, 1, Endian.little);
  }
  return result;
}

Uint8List buildGetInputFocus() {
  final result = Uint8List(4)..[0] = x11GetInputFocusOpcode;
  ByteData.sublistView(result).setUint16(2, 1, Endian.little);
  return result;
}

Uint8List buildCreateWindow({
  required X11Setup setup,
  required int window,
  required int width,
  required int height,
}) {
  final result = Uint8List(32);
  final view = ByteData.sublistView(result);
  result[0] = 1;
  result[1] = setup.rootDepth;
  view
    ..setUint16(2, 8, Endian.little)
    ..setUint32(4, window, Endian.little)
    ..setUint32(8, setup.root, Endian.little)
    ..setInt16(12, 0, Endian.little)
    ..setInt16(14, 0, Endian.little)
    ..setUint16(16, width, Endian.little)
    ..setUint16(18, height, Endian.little)
    ..setUint16(20, 0, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, setup.rootVisual, Endian.little)
    ..setUint32(28, 0, Endian.little);
  return result;
}

Uint8List buildCreateGc({required int gc, required int drawable}) {
  final result = Uint8List(16)..[0] = 55;
  final view = ByteData.sublistView(result);
  view
    ..setUint16(2, 4, Endian.little)
    ..setUint32(4, gc, Endian.little)
    ..setUint32(8, drawable, Endian.little)
    ..setUint32(12, 0, Endian.little);
  return result;
}

Uint8List buildPutImage({
  required int drawable,
  required int gc,
  required int width,
  required int height,
  required int depth,
  required Uint8List pixels,
}) {
  final expected = width * height * 4;
  if (pixels.length != expected) {
    throw ArgumentError.value(
      pixels.length,
      'pixels',
      'expected $expected BGRA bytes',
    );
  }
  final bytes = 24 + pixels.length;
  if (bytes ~/ 4 > 0xffff) {
    throw RangeError('PutImage exceeds the core X11 request limit');
  }
  final result = Uint8List(bytes);
  final view = ByteData.sublistView(result);
  result[0] = x11PutImageOpcode;
  result[1] = 2; // ZPixmap.
  view
    ..setUint16(2, bytes ~/ 4, Endian.little)
    ..setUint32(4, drawable, Endian.little)
    ..setUint32(8, gc, Endian.little)
    ..setUint16(12, width, Endian.little)
    ..setUint16(14, height, Endian.little)
    ..setInt16(16, 0, Endian.little)
    ..setInt16(18, 0, Endian.little);
  result[20] = 0;
  result[21] = depth;
  result.setRange(24, bytes, pixels);
  return result;
}

Uint8List repeatPacket(Uint8List packet, int count) {
  if (count < 0) throw RangeError.value(count, 'count');
  final result = Uint8List(packet.length * count);
  for (var i = 0; i < count; i++) {
    result.setRange(i * packet.length, (i + 1) * packet.length, packet);
  }
  return result;
}

String decodeSetupFailure(Uint8List reply) {
  if (reply.length < 8) return 'truncated X11 setup failure';
  final reasonLength = reply[1];
  if (8 + reasonLength > reply.length) return 'truncated X11 failure reason';
  return latin1.decode(reply.sublist(8, 8 + reasonLength));
}
