import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test(
    'attachment snapshots UI parameters from shared native memory',
    () {
      final WasapiSharedParameterBlock owner =
          WasapiSharedParameterBlock.allocate(4);
      final WasapiSharedParameterBlock audio =
          WasapiSharedParameterBlock.attach(owner.address);
      final Pointer<Float> snapshot =
          NativeAllocator.instance.allocate<Float>(4 * sizeOf<Float>());
      addTearDown(() {
        audio.dispose();
        owner.dispose();
        NativeAllocator.instance.free(snapshot);
      });

      owner
        ..setValue(0, 1)
        ..setValue(1, 0.25)
        ..setValue(2, -0.5)
        ..setValue(3, 0.75);
      expect(audio.trySnapshot(snapshot), isTrue);
      expect(snapshot.asTypedList(4), <double>[1, 0.25, -0.5, 0.75]);
    },
    skip: !Platform.isWindows,
  );
}
