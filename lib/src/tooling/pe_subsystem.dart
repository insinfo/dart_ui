/// Inspection and editing of the Windows PE subsystem field.
library;

import 'dart:io';
import 'dart:typed_data';

const int _mzSignature = 0x5A4D;
const int _peSignature = 0x00004550;
const int _pe32Magic = 0x010B;
const int _pe32PlusMagic = 0x020B;
const int _subsystemOffsetInOptionalHeader = 68;
const int _checksumOffsetInOptionalHeader = 64;
const int _certificateDirectoryIndex = 4;

/// Subsystems relevant to ordinary desktop executables.
enum PeSubsystem {
  native(1, 'Native'),
  windowsGui(2, 'Windows GUI'),
  windowsConsole(3, 'Windows Console'),
  posixConsole(7, 'POSIX Console'),
  windowsCeGui(9, 'Windows CE GUI'),
  efiApplication(10, 'EFI Application');

  const PeSubsystem(this.value, this.description);

  final int value;
  final String description;

  static PeSubsystem? fromValue(int value) {
    for (final PeSubsystem subsystem in values) {
      if (subsystem.value == value) return subsystem;
    }
    return null;
  }
}

/// Parsed facts needed to inspect or safely update a PE image.
final class PeImageInfo {
  const PeImageInfo({
    required this.path,
    required this.is64Bit,
    required this.subsystemValue,
    required this.subsystemOffset,
    required this.checksum,
    required this.checksumOffset,
    required this.hasAuthenticodeCertificate,
  });

  final String path;
  final bool is64Bit;
  final int subsystemValue;
  final int subsystemOffset;
  final int checksum;
  final int checksumOffset;

  /// Whether the PE certificate table is non-empty.
  ///
  /// Changing any covered byte invalidates Authenticode. The editor therefore
  /// refuses these images unless the caller explicitly opts in and intends to
  /// sign the result again.
  final bool hasAuthenticodeCertificate;

  PeSubsystem? get subsystem => PeSubsystem.fromValue(subsystemValue);

  String get format => is64Bit ? 'PE32+ (64-bit)' : 'PE32 (32-bit)';

  String get subsystemDescription =>
      subsystem?.description ?? 'Unknown ($subsystemValue)';
}

/// A malformed or unsafe-to-edit Portable Executable image.
final class PeFormatException implements Exception {
  const PeFormatException(this.message);

  final String message;

  @override
  String toString() => 'PeFormatException: $message';
}

/// Reads and updates the PE Optional Header without external build tools.
final class PeSubsystemEditor {
  const PeSubsystemEditor._();

  static PeImageInfo inspect(String path) {
    final File file = File(path);
    if (!file.existsSync()) {
      throw PeFormatException('file does not exist: $path');
    }
    return _parse(path, file.readAsBytesSync());
  }

  /// Sets [target], preserving a zero checksum or recomputing a non-zero one.
  ///
  /// This operation must happen before Authenticode signing. Set
  /// [allowSigned] only when the existing signature is intentionally being
  /// discarded and the executable will be signed again afterwards.
  static PeImageInfo setSubsystem(
    String path,
    PeSubsystem target, {
    bool allowSigned = false,
  }) {
    final File file = File(path);
    if (!file.existsSync()) {
      throw PeFormatException('file does not exist: $path');
    }
    final Uint8List bytes = file.readAsBytesSync();
    final PeImageInfo before = _parse(path, bytes);
    if (before.subsystemValue == target.value) return before;
    if (before.hasAuthenticodeCertificate && !allowSigned) {
      throw const PeFormatException(
        'the executable has an Authenticode certificate; patch it before '
        'signing, or pass allowSigned only if it will be signed again',
      );
    }
    final ByteData data = ByteData.sublistView(bytes);
    data.setUint16(before.subsystemOffset, target.value, Endian.little);
    if (before.checksum != 0) {
      data.setUint32(before.checksumOffset, 0, Endian.little);
      data.setUint32(
        before.checksumOffset,
        _peChecksum(bytes, before.checksumOffset),
        Endian.little,
      );
    }
    file.writeAsBytesSync(bytes, flush: true);
    return _parse(path, bytes);
  }

  static PeImageInfo _parse(String path, Uint8List bytes) {
    if (bytes.length < 0x40) {
      throw const PeFormatException('file is too small for a DOS header');
    }
    final ByteData data = ByteData.sublistView(bytes);
    if (data.getUint16(0, Endian.little) != _mzSignature) {
      throw const PeFormatException('missing MZ signature');
    }

    final int peOffset = data.getUint32(0x3C, Endian.little);
    if (peOffset > bytes.length - 24) {
      throw const PeFormatException('PE header offset is outside the file');
    }
    if (data.getUint32(peOffset, Endian.little) != _peSignature) {
      throw const PeFormatException('missing PE\\0\\0 signature');
    }

    final int optionalHeaderSize = data.getUint16(peOffset + 20, Endian.little);
    final int optionalHeaderOffset = peOffset + 24;
    if (optionalHeaderSize < _subsystemOffsetInOptionalHeader + 2 ||
        optionalHeaderOffset + optionalHeaderSize > bytes.length) {
      throw const PeFormatException('truncated PE optional header');
    }

    final int magic = data.getUint16(optionalHeaderOffset, Endian.little);
    final bool is64Bit = switch (magic) {
      _pe32PlusMagic => true,
      _pe32Magic => false,
      _ => throw PeFormatException(
          'unsupported optional-header magic 0x${magic.toRadixString(16)}',
        ),
    };
    final int subsystemOffset =
        optionalHeaderOffset + _subsystemOffsetInOptionalHeader;
    final int checksumOffset =
        optionalHeaderOffset + _checksumOffsetInOptionalHeader;

    final int dataDirectoriesOffset =
        optionalHeaderOffset + (is64Bit ? 112 : 96);
    final int certificateEntryOffset =
        dataDirectoriesOffset + _certificateDirectoryIndex * 8;
    var hasCertificate = false;
    if (certificateEntryOffset + 8 <=
        optionalHeaderOffset + optionalHeaderSize) {
      final int certificateAddress =
          data.getUint32(certificateEntryOffset, Endian.little);
      final int certificateSize =
          data.getUint32(certificateEntryOffset + 4, Endian.little);
      hasCertificate = certificateAddress != 0 && certificateSize != 0;
    }

    return PeImageInfo(
      path: path,
      is64Bit: is64Bit,
      subsystemValue: data.getUint16(subsystemOffset, Endian.little),
      subsystemOffset: subsystemOffset,
      checksum: data.getUint32(checksumOffset, Endian.little),
      checksumOffset: checksumOffset,
      hasAuthenticodeCertificate: hasCertificate,
    );
  }
}

int _peChecksum(Uint8List bytes, int checksumOffset) {
  var sum = 0;
  for (var offset = 0; offset < bytes.length; offset += 2) {
    if (offset == checksumOffset || offset == checksumOffset + 2) continue;
    final int low = bytes[offset];
    final int high = offset + 1 < bytes.length ? bytes[offset + 1] : 0;
    sum += low | (high << 8);
    sum = (sum & 0xFFFF) + (sum >> 16);
  }
  sum = (sum & 0xFFFF) + (sum >> 16);
  sum += bytes.length;
  return sum & 0xFFFFFFFF;
}
