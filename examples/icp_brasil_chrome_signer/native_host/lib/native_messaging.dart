import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int maxNativeMessageBytes = 32 * 1024 * 1024;

final class NativeMessageCodec {
  const NativeMessageCodec();

  Uint8List encode(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    if (body.length > maxNativeMessageBytes) {
      throw const FormatException('native message exceeds 32 MiB');
    }
    final result = Uint8List(4 + body.length);
    ByteData.sublistView(result).setUint32(0, body.length, Endian.little);
    result.setRange(4, result.length, body);
    return result;
  }

  Map<String, Object?> decode(Uint8List body) {
    if (body.length > maxNativeMessageBytes) {
      throw const FormatException('native message exceeds 32 MiB');
    }
    final value = jsonDecode(utf8.decode(body));
    if (value is! Map) {
      throw const FormatException('message must be an object');
    }
    return value.cast<String, Object?>();
  }
}

final class NativeMessageReader {
  NativeMessageReader(Stream<List<int>> input) : _input = input;
  final Stream<List<int>> _input;

  Stream<Map<String, Object?>> messages() async* {
    final bytes = <int>[];
    await for (final chunk in _input) {
      bytes.addAll(chunk);
      while (bytes.length >= 4) {
        final length = ByteData.sublistView(Uint8List.fromList(bytes), 0, 4)
            .getUint32(0, Endian.little);
        if (length > maxNativeMessageBytes) {
          throw const FormatException('native message exceeds 32 MiB');
        }
        if (bytes.length < length + 4) {
          break;
        }
        final body = Uint8List.fromList(bytes.sublist(4, 4 + length));
        bytes.removeRange(0, 4 + length);
        yield const NativeMessageCodec().decode(body);
      }
    }
    if (bytes.isNotEmpty) {
      throw const FormatException('truncated native message');
    }
  }
}

Future<void> writeNativeMessage(
  IOSink output,
  Map<String, Object?> message,
) async {
  output.add(const NativeMessageCodec().encode(message));
  await output.flush();
}
