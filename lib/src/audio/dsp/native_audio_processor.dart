/// Realtime DSP contracts over caller-owned native sample buffers.
library;

import 'dart:ffi';

import '../../foundation/lifecycle.dart';

/// Fills or transforms interleaved float32 samples in native memory.
///
/// Implementations must prepare all storage before [process] and must not use
/// asynchronous work in that method. The buffer contains `frames * channels`
/// samples and remains owned by the native audio backend.
abstract interface class NativeFloat32AudioProcessor implements Disposable {
  int get sampleRate;
  int get channels;

  void process(Pointer<Float> interleavedSamples, int frames);
}

/// An in-place effect that consumes and replaces an interleaved float32 block.
abstract interface class NativeFloat32AudioEffect implements Disposable {
  int get sampleRate;
  int get channels;

  void processInPlace(Pointer<Float> interleavedSamples, int frames);
  void reset();
}
