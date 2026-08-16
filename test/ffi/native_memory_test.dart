/// The native allocator and the arena, including the conversions Win32 needs.
///
/// Almost everything here runs on every platform, because almost everything
/// here *is* portable: an arena's ordering, a UTF-16 encoding and a NUL scan
/// have no operating system in them. The two Windows-only assertions are marked
/// and say why.
///
/// ## Why the string conversions get this much attention
///
/// Every `W` entry point on Windows takes a `LPCWSTR`, and a wrong conversion
/// there is the class of bug that works perfectly on the machine it was written
/// on and fails the first time a path has an accent in it or a window title has
/// an emoji. The three ways to get it wrong are all tested below: terminating
/// with one zero byte instead of two, sizing a buffer from `String.length` when
/// the encoding is UTF-8, and re-encoding runes by hand instead of copying the
/// code units a Dart string already holds.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  final String? skipReason = NativeAllocator.isAvailable
      ? null
      : 'no native allocator on ${Platform.operatingSystem}';

  group('the allocator', () {
    test('binds something and says which', () {
      final NativeAllocator allocator = NativeAllocator.instance;
      expect(allocator.provenance, isNotEmpty);
      printOnFailure('bound $allocator');
      // The pair matters more than the name: a block allocated by one heap and
      // freed by another is corruption that surfaces somewhere else entirely,
      // which is why provenance names both halves together.
      expect(allocator.provenance, contains('/'));
    }, skip: skipReason);

    test('uses the COM task allocator on Windows', () {
      // Adopted from package:ffi, and the reason is specific to this process:
      // a Dart program on Windows can have msvcrt.dll and ucrtbase.dll both
      // loaded, each exporting malloc against its own heap. ole32.dll is
      // loaded once, and its allocator is the one COM itself allocates from.
      expect(NativeAllocator.instance.provenance, contains('ole32.dll'));
    }, skip: Platform.isWindows ? skipReason : 'Windows only');

    test('hands back zeroed memory', () {
      // Not tidiness: every Windows descriptor in this repository is filled
      // field by field, and DXGI_SWAP_CHAIN_DESC1.Stereo left as garbage is a
      // swap chain that fails to create with an HRESULT naming nothing.
      final NativeAllocator allocator = NativeAllocator.instance;
      final Pointer<Uint8> block = allocator.allocate<Uint8>(256);
      expect(block.asTypedList(256).every((int b) => b == 0), isTrue);
      allocator.free(block);
    }, skip: skipReason);

    test('refuses an alignment it cannot promise, rather than lying', () {
      final NativeAllocator allocator = NativeAllocator.instance;
      // 16 is what both malloc and CoTaskMemAlloc guarantee.
      final Pointer<Uint8> fine = allocator.allocate<Uint8>(32, alignment: 16);
      expect(fine, isNot(nullptr));
      allocator.free(fine);
      // Anything stricter would be a silently misaligned SIMD load a long way
      // from here.
      expect(() => allocator.allocate<Uint8>(32, alignment: 64),
          throwsArgumentError);
      expect(() => allocator.allocate<Uint8>(-1), throwsArgumentError);
    }, skip: skipReason);

    test('freeing nullptr is a no-op', () {
      NativeAllocator.instance.free(nullptr);
    }, skip: skipReason);
  });

  group('the arena', () {
    test('releases everything in one call and stays usable', () {
      // The half of package:ffi's Arena.releaseAll that takes `reuse: true`. A
      // retry loop can empty one arena per iteration instead of building a new
      // one, and whoever is holding the arena does not have to be told its
      // reference went stale.
      final arena = NativeArena();
      addTearDown(arena.dispose);

      arena
        ..allocate<Uint8>(16)
        ..allocate<Uint8>(16)
        ..allocateOutPointer();
      expect(arena.length, 3);

      arena.releaseAll();
      expect(arena.length, 0);

      final Pointer<Uint8> after = arena.allocate<Uint8>(8);
      expect(after, isNot(nullptr));
      expect(arena.length, 1);
    }, skip: skipReason);

    test('dispose is idempotent and refuses further allocation', () {
      final arena = NativeArena()..allocate<Uint8>(8);
      arena
        ..dispose()
        ..dispose();
      expect(() => arena.allocate<Uint8>(8), throwsStateError);
      expect(arena.releaseAll, throwsStateError);
    }, skip: skipReason);

    test('free() on an arena does nothing, on purpose', () {
      // An arena's memory dies once, in a block. Releasing one pointer early
      // would leave the bag holding a release for memory that is already gone,
      // which is a double free at teardown - the exact failure the arena
      // exists to remove. package:ffi's Arena.free is a no-op for the same
      // reason.
      final arena = NativeArena();
      addTearDown(arena.dispose);
      final Pointer<Uint8> block = arena.allocate<Uint8>(8);
      arena.free(block);
      expect(arena.length, 1);
      // Still writable, which is the observable half of "nothing happened".
      block.asTypedList(8)[7] = 0xAB;
      expect(block.asTypedList(8)[7], 0xAB);
    }, skip: skipReason);

    test('the Allocator extension counts elements where allocate counts bytes',
        () {
      // Both spellings are used in this repository and the difference is
      // dart:ffi's, not this class's. Getting them confused sizes a descriptor
      // by a factor of four.
      final arena = NativeArena();
      addTearDown(arena.dispose);

      final Pointer<Uint32> byBytes = arena.allocate<Uint32>(16);
      final Pointer<Uint32> byElements = arena<Uint32>(4);
      // Sixteen bytes either way, reached from opposite directions.
      byBytes.asTypedList(4)[3] = 0xFFFFFFFF;
      byElements.asTypedList(4)[3] = 0xFFFFFFFF;
      expect(byBytes.asTypedList(4)[3], 0xFFFFFFFF);
      expect(byElements.asTypedList(4)[3], 0xFFFFFFFF);
    }, skip: skipReason);

    test('an out-pointer slot is pointer-wide and starts null', () {
      final arena = NativeArena();
      addTearDown(arena.dispose);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      // Zeroed matters here more than anywhere: every failure path in this
      // repository checks `out.value == nullptr` after a COM call that may not
      // have written it.
      expect(out.value, nullptr);
    }, skip: skipReason);
  });

  group('using()', () {
    test('releases the arena when the body returns', () {
      late final NativeArena captured;
      final int answer = using((NativeArena arena) {
        captured = arena;
        arena.allocate<Uint8>(32);
        return 42;
      });
      expect(answer, 42);
      expect(captured.isDisposed, isTrue);
    }, skip: skipReason);

    test('releases the arena when the body throws', () {
      // The whole reason this exists rather than a try/finally at each call
      // site: the `finally` is the line that gets dropped when the body grows
      // an early return.
      late final NativeArena captured;
      expect(
        () => using((NativeArena arena) {
          captured = arena;
          arena.allocate<Uint8>(32);
          throw StateError('the driver said no');
        }),
        throwsStateError,
      );
      expect(captured.isDisposed, isTrue);
    }, skip: skipReason);
  });

  group('string conversions', () {
    test('UTF-16 is a copy of the code units a Dart string already holds', () {
      final arena = NativeArena();
      addTearDown(arena.dispose);
      const String value = 'Ação';
      final Pointer<Uint16> native = arena.allocateUtf16(value);

      expect(native.asTypedList(5), <int>[
        0x0041, // A
        0x00E7, // ç
        0x00E3, // ã
        0x006F, // o
        0x0000, // the terminator, and it is sixteen bits wide
      ]);
      expect(readNativeUtf16(native, limit: 64), value);
    }, skip: skipReason);

    test('a surrogate pair survives untouched', () {
      // U+1F600, which is two UTF-16 code units. Anything that walked runes
      // and re-encoded them by hand is where an astral character gets lost;
      // copying codeUnits cannot.
      final arena = NativeArena();
      addTearDown(arena.dispose);
      const String value = 'a\u{1F600}b';
      final Pointer<Uint16> native = arena.allocateUtf16(value);

      expect(native.asTypedList(5), <int>[0x61, 0xD83D, 0xDE00, 0x62, 0]);
      expect(readNativeUtf16(native, limit: 64), value);
      expect(readNativeUtf16(native, limit: 64).runes.length, 3);
    }, skip: skipReason);

    test('an empty string is one NUL and nothing else', () {
      final arena = NativeArena();
      addTearDown(arena.dispose);
      expect(arena.allocateUtf16('').asTypedList(1), <int>[0]);
      expect(readNativeUtf16(arena.allocateUtf16(''), limit: 8), '');
      expect(readNativeUtf16(nullptr, limit: 8), '');
      expect(readNativeUtf16(arena.allocateUtf16('x'), limit: 0), '');
    }, skip: skipReason);

    test('reading stops at the limit when nothing terminated the buffer', () {
      // DXGI_ADAPTER_DESC.Description is a fixed 128-code-unit array that is
      // only NUL padded when the name is shorter. A reader with no bound walks
      // off the end of the structure.
      final arena = NativeArena();
      addTearDown(arena.dispose);
      final Pointer<Uint16> units = arena.allocate<Uint16>(8);
      units.asTypedList(4).setAll(0, <int>[0x48, 0x49, 0x4A, 0x4B]);
      expect(readNativeUtf16(units, limit: 4), 'HIJK');
      expect(readNativeUtf16(units, limit: 2), 'HI');
    }, skip: skipReason);

    test('UTF-8 is measured in bytes, not in code units', () {
      // The mistake this refuses: sizing the buffer from `value.length`. 'Ação'
      // is four code units and six UTF-8 bytes.
      final arena = NativeArena();
      addTearDown(arena.dispose);
      const String value = 'Ação';
      final Pointer<Uint8> native = arena.allocateUtf8(value);

      expect(value.length, 4);
      expect(native.asTypedList(7),
          <int>[0x41, 0xC3, 0xA7, 0xC3, 0xA3, 0x6F, 0x00]);
      expect(readNativeUtf8(native, limit: 64), value);
    }, skip: skipReason);

    test('a malformed UTF-8 buffer is replaced, not thrown on', () {
      // This decodes whatever a native library handed back, and a diagnostic
      // that throws while being formatted loses the failure it described.
      final arena = NativeArena();
      addTearDown(arena.dispose);
      final Pointer<Uint8> bytes = arena.allocate<Uint8>(4);
      bytes.asTypedList(4).setAll(0, <int>[0x41, 0xFF, 0x42, 0x00]);
      expect(readNativeUtf8(bytes, limit: 4), contains('A'));
      expect(readNativeUtf8(bytes, limit: 4), contains('B'));
    }, skip: skipReason);

    test('ASCII refuses anything that is not ASCII', () {
      // Every string that crosses allocateAscii is a shader entry point, a
      // target profile or an input-layout semantic name, all spelled in the
      // ASCII subset by the APIs that read them. A non-ASCII unit is a caller
      // bug and must not be silently truncated to one byte.
      final arena = NativeArena();
      addTearDown(arena.dispose);

      expect(arena.allocateAscii('ps_4_0').asTypedList(7),
          <int>[0x70, 0x73, 0x5F, 0x34, 0x5F, 0x30, 0x00]);
      expect(() => arena.allocateAscii('vertexMainç'), throwsArgumentError);
      expect(readNativeAscii(arena.allocateAscii('POSITION'), limit: 32),
          'POSITION');
      expect(readNativeAscii(nullptr, limit: 8), '');
    }, skip: skipReason);
  });
}
