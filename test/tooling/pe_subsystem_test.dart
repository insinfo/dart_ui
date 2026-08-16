import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/tooling/pe_subsystem.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('dart_ui_pe_test_');
  });

  tearDown(() {
    temporary.deleteSync(recursive: true);
  });

  test('inspects and patches PE32+ produced as a console application', () {
    final File executable = File('${temporary.path}/app.exe')
      ..writeAsBytesSync(_peImage(is64Bit: true));

    final PeImageInfo before = PeSubsystemEditor.inspect(executable.path);
    expect(before.format, 'PE32+ (64-bit)');
    expect(before.subsystem, PeSubsystem.windowsConsole);

    final PeImageInfo after = PeSubsystemEditor.setSubsystem(
      executable.path,
      PeSubsystem.windowsGui,
    );
    expect(after.subsystem, PeSubsystem.windowsGui);
    expect(executable.lengthSync(), 512);
  });

  test('supports PE32 and recomputes an existing checksum', () {
    final File executable = File('${temporary.path}/app32.exe')
      ..writeAsBytesSync(_peImage(is64Bit: false, checksum: 0x12345678));
    final int oldChecksum = PeSubsystemEditor.inspect(executable.path).checksum;

    final PeImageInfo after = PeSubsystemEditor.setSubsystem(
      executable.path,
      PeSubsystem.windowsGui,
    );

    expect(after.is64Bit, isFalse);
    expect(after.checksum, isNot(0));
    expect(after.checksum, isNot(oldChecksum));
  });

  test('refuses to invalidate an Authenticode certificate silently', () {
    final File executable = File('${temporary.path}/signed.exe')
      ..writeAsBytesSync(_peImage(is64Bit: true, signed: true));

    expect(
      () => PeSubsystemEditor.setSubsystem(
        executable.path,
        PeSubsystem.windowsGui,
      ),
      throwsA(
        isA<PeFormatException>().having(
          (PeFormatException error) => error.message,
          'message',
          contains('Authenticode'),
        ),
      ),
    );
    expect(
      PeSubsystemEditor.inspect(executable.path).subsystem,
      PeSubsystem.windowsConsole,
    );
  });

  test('rejects a malformed image without modifying it', () {
    final File executable = File('${temporary.path}/broken.exe')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);

    expect(
      () => PeSubsystemEditor.inspect(executable.path),
      throwsA(isA<PeFormatException>()),
    );
    expect(executable.readAsBytesSync(), <int>[1, 2, 3, 4]);
  });
}

Uint8List _peImage({
  required bool is64Bit,
  int subsystem = 3,
  int checksum = 0,
  bool signed = false,
}) {
  final Uint8List bytes = Uint8List(512);
  final ByteData data = ByteData.sublistView(bytes);
  const int peOffset = 0x80;
  final int optionalHeaderSize = is64Bit ? 240 : 224;
  const int optionalHeaderOffset = peOffset + 24;
  data.setUint16(0, 0x5A4D, Endian.little);
  data.setUint32(0x3C, peOffset, Endian.little);
  data.setUint32(peOffset, 0x00004550, Endian.little);
  data.setUint16(peOffset + 20, optionalHeaderSize, Endian.little);
  data.setUint16(
    optionalHeaderOffset,
    is64Bit ? 0x020B : 0x010B,
    Endian.little,
  );
  data.setUint32(optionalHeaderOffset + 64, checksum, Endian.little);
  data.setUint16(optionalHeaderOffset + 68, subsystem, Endian.little);
  if (signed) {
    final int directories = optionalHeaderOffset + (is64Bit ? 112 : 96);
    data.setUint32(directories + 4 * 8, 0x1E0, Endian.little);
    data.setUint32(directories + 4 * 8 + 4, 16, Endian.little);
  }
  return bytes;
}
