import 'dart:ffi';
import 'dart:typed_data';

import 'package:poc_12_native_buffers/poc_12_native_buffers.dart';
import 'package:test/test.dart';

void main() {
  test('native allocation is aligned and aliases word and byte views', () {
    final buffer = NativePixelBuffer(4, 2);
    addTearDown(buffer.dispose);

    expect(buffer.length, 8);
    expect(buffer.byteLength, 32);
    expect(buffer.address % sizeOf<Uint32>(), 0);

    buffer.fillWithPointer(0xff332211);
    expect(buffer.words, everyElement(0xff332211));
    expect(buffer.bytes.take(4), orderedEquals([0x11, 0x22, 0x33, 0xff]));

    buffer.fillWithView(0xff665544);
    expect(buffer.pointer[3], 0xff665544);
  });

  test('copies Dart-managed packed pixels into native storage', () {
    final buffer = NativePixelBuffer(3, 2);
    addTearDown(buffer.dispose);
    final source = Uint32List.fromList([
      0xff000001,
      0xff000002,
      0xff000003,
      0xff000004,
      0xff000005,
      0xff000006,
    ]);

    buffer.copyFrom(source);

    expect(buffer.words, orderedEquals(source));
    expect(buffer.sampleChecksum(), source.first ^ source[3] ^ source.last);
    expect(
      () => buffer.copyFrom(Uint32List(1)),
      throwsArgumentError,
    );
  });

  test('manual lifecycle is idempotent and rejects use after free', () {
    final buffer = NativePixelBuffer(2, 2)..dispose();

    buffer.dispose();

    expect(buffer.isDisposed, isTrue);
    expect(() => buffer.address, throwsStateError);
    expect(() => buffer.fillWithPointer(0), throwsStateError);
    expect(() => buffer.fillWithView(0), throwsStateError);
  });

  test('benchmark strategies write equivalent final pixels', () {
    final results = const NativeBufferBenchmark(
      width: 32,
      height: 16,
      iterations: 3,
      warmupIterations: 1,
    ).run();

    expect(results, hasLength(6));
    expect(results.map((result) => result.strategy).toSet(), hasLength(6));
    expect(results.map((result) => result.checksum).toSet(), hasLength(1));
    expect(
      results,
      everyElement(
        isA<BufferBenchmarkResult>()
            .having(
              (result) => result.pixelWrites,
              'pixelWrites',
              greaterThan(0),
            )
            .having(
              (result) => result.nanosecondsPerPixel,
              'nanosecondsPerPixel',
              isNonNegative,
            ),
      ),
    );
  });
}
