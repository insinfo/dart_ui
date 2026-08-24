import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test(
    'native ring wraps and an attachment sees the same cursors',
    () {
      final WasapiSharedRingBuffer ring = WasapiSharedRingBuffer.allocate(
        capacityFrames: 4,
        bytesPerFrame: 2,
      );
      final WasapiSharedRingBuffer attached =
          WasapiSharedRingBuffer.attach(ring.address);
      final Pointer<Uint8> source = NativeAllocator.instance.allocate(8);
      final Pointer<Uint8> output = NativeAllocator.instance.allocate(8);
      addTearDown(() {
        attached.dispose();
        ring.dispose();
        NativeAllocator.instance.free(source);
        NativeAllocator.instance.free(output);
      });

      source.asTypedList(8).setAll(0, <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      expect(ring.writeFrames(source, 3), 3);
      expect(attached.tryReadFrames(output, 2), 2);
      expect(output.asTypedList(4), <int>[1, 2, 3, 4]);

      expect(
          attached.writeFrames(
              Pointer<Uint8>.fromAddress(source.address + 2), 3),
          3);
      expect(ring.tryReadFrames(output, 4), 4);
      expect(output.asTypedList(8), <int>[5, 6, 3, 4, 5, 6, 7, 8]);
      expect(ring.availableReadFrames, 0);
    },
    skip: !Platform.isWindows,
  );
}
