import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test(
    'attachment observes repeated triggers and their latest velocities',
    () {
      final WasapiSharedTriggerBlock owner =
          WasapiSharedTriggerBlock.allocate(3);
      final WasapiSharedTriggerBlock audio =
          WasapiSharedTriggerBlock.attach(owner.address);
      final Pointer<Uint32> sequences =
          NativeAllocator.instance.allocate<Uint32>(3 * sizeOf<Uint32>());
      final Pointer<Float> velocities =
          NativeAllocator.instance.allocate<Float>(3 * sizeOf<Float>());
      addTearDown(() {
        NativeAllocator.instance
          ..free(velocities)
          ..free(sequences);
        audio.dispose();
        owner.dispose();
      });

      owner
        ..trigger(1, velocity: 0.35)
        ..trigger(1, velocity: 0.8)
        ..trigger(2, velocity: 2);
      expect(audio.trySnapshot(sequences, velocities), isTrue);
      expect(sequences.asTypedList(3), <int>[0, 2, 1]);
      expect(velocities[1], closeTo(0.8, 0.0001));
      expect(velocities[2], 1);
    },
    skip: !Platform.isWindows,
  );
}
