import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_explorer/src/io/zip_operations.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('explorer-zip-test-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test(
      'ZIP round trip retains nested files, Unicode names and empty directories',
      () async {
    final source = Directory('${dir.path}/source')..createSync();
    Directory('${source.path}/empty').createSync();
    File('${source.path}/ação.txt').writeAsStringSync('hello ' * 1000);
    Directory('${source.path}/nested').createSync();
    File('${source.path}/nested/data.bin').writeAsBytesSync([0, 1, 2, 3, 255]);
    final zip = '${dir.path}/test.zip';
    await createZip([source.path], zip);
    expect(File(zip).lengthSync(), lessThan(6000));
    final out = '${dir.path}/out';
    await extractZip(zip, out);
    expect(File('$out/source/ação.txt').readAsStringSync(), 'hello ' * 1000);
    expect(File('$out/source/nested/data.bin').readAsBytesSync(),
        [0, 1, 2, 3, 255]);
    expect(Directory('$out/source/empty').existsSync(), isTrue);
    await expectLater(
        extractZip(zip, out), throwsA(isA<FileSystemException>()));
  });

  test('extraction rejects traversal before writing outside the destination',
      () async {
    final zip = File('${dir.path}/bad.zip');
    zip.writeAsBytesSync(_stored('../escape.txt', utf8.encode('bad')));
    final out = '${dir.path}/out';
    await expectLater(extractZip(zip.path, out), throwsFormatException);
    expect(File('${dir.path}/escape.txt').existsSync(), isFalse);
    expect(Directory(out).existsSync(), isFalse);
  });

  test('CRC corruption rolls back the entire extraction', () async {
    final file = File('${dir.path}/a.txt')..writeAsStringSync('hello');
    final zip = '${dir.path}/test.zip';
    await createZip([file.path], zip);
    final bytes = File(zip).readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length - 4; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        data.setUint32(i + 16, 123, Endian.little);
        break;
      }
    }
    File(zip).writeAsBytesSync(bytes);
    await expectLater(
        extractZip(zip, '${dir.path}/out'), throwsFormatException);
    expect(Directory('${dir.path}/out').existsSync(), isFalse);
  });

  test('creation refuses links and existing destinations', () async {
    final file = File('${dir.path}/a.txt')..writeAsStringSync('a');
    await expectLater(
        createZip([file.path], file.path), throwsA(isA<FileSystemException>()));
    expect(file.readAsStringSync(), 'a');
    if (!Platform.isWindows) {
      final link = Link('${dir.path}/link')..createSync(file.path);
      await expectLater(createZip([link.path], '${dir.path}/link.zip'),
          throwsA(isA<FileSystemException>()));
      expect(File('${dir.path}/link.zip').existsSync(), isFalse);
    }
  });
}

Uint8List _stored(String name, List<int> contents) {
  final file = utf8.encode(name);
  final result =
      Uint8List(30 + file.length + contents.length + 46 + file.length + 22);
  final b = ByteData.sublistView(result);
  void w(int at, int v) => b.setUint32(at, v, Endian.little);
  void h(int at, int v) => b.setUint16(at, v, Endian.little);
  w(0, 0x04034b50);
  h(4, 20);
  w(18, contents.length);
  w(22, contents.length);
  h(26, file.length);
  result.setRange(30, 30 + file.length, file);
  result.setRange(
      30 + file.length, 30 + file.length + contents.length, contents);
  final c = 30 + file.length + contents.length;
  w(c, 0x02014b50);
  h(c + 4, 20);
  h(c + 6, 20);
  w(c + 20, contents.length);
  w(c + 24, contents.length);
  h(c + 28, file.length);
  result.setRange(c + 46, c + 46 + file.length, file);
  final e = c + 46 + file.length;
  w(e, 0x06054b50);
  h(e + 8, 1);
  h(e + 10, 1);
  w(e + 12, 46 + file.length);
  w(e + 16, c);
  return result;
}
