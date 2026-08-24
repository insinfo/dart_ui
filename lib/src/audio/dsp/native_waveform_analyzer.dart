/// Allocation-free rolling waveform telemetry over native float32 audio.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'native_audio_processor.dart';

/// Keeps a mono history window and exposes evenly spaced oscilloscope points.
///
/// The history, output points and cursor live in native-owned storage. Audio
/// samples are averaged across channels, but the caller's interleaved buffer
/// is never modified. [processInPlace] allocates nothing.
final class NativeWaveformAnalyzer
    with DisposableMixin
    implements NativeFloat32AudioEffect {
  NativeWaveformAnalyzer({
    required this.sampleRate,
    required this.channels,
    this.pointCount = 160,
    this.windowFrames = 2048,
  })  : _history = NativeAllocator.instance.allocate<Float>(
          windowFrames * sizeOf<Float>(),
        ),
        _points = NativeAllocator.instance.allocate<Float>(
          pointCount * sizeOf<Float>(),
        ) {
    if (sampleRate <= 0 || channels <= 0) {
      throw ArgumentError('sampleRate and channels must be positive');
    }
    if (pointCount < 2 || windowFrames < pointCount) {
      throw ArgumentError('windowFrames must be at least pointCount >= 2');
    }
    reset();
  }

  @override
  final int sampleRate;
  @override
  final int channels;
  final int pointCount;
  final int windowFrames;

  final Pointer<Float> _history;
  final Pointer<Float> _points;
  int _writeIndex = 0;
  int _availableFrames = 0;

  double sampleAt(int point) {
    throwIfDisposed();
    RangeError.checkValidIndex(point, this, 'point', pointCount);
    return _points[point];
  }

  @override
  void processInPlace(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    if (frames <= 0) return;
    for (int frame = 0; frame < frames; frame++) {
      final int offset = frame * channels;
      double mono = 0;
      for (int channel = 0; channel < channels; channel++) {
        mono += interleavedSamples[offset + channel];
      }
      _history[_writeIndex] = mono / channels;
      _writeIndex++;
      if (_writeIndex == windowFrames) _writeIndex = 0;
      if (_availableFrames < windowFrames) _availableFrames++;
    }

    final int visibleFrames = _availableFrames;
    if (visibleFrames == 0) return;
    final int oldest = (_writeIndex - visibleFrames) % windowFrames;
    for (int point = 0; point < pointCount; point++) {
      final int age = point * (visibleFrames - 1) ~/ (pointCount - 1);
      final int historyIndex = (oldest + age) % windowFrames;
      _points[point] = _history[historyIndex];
    }
  }

  @override
  void reset() {
    throwIfDisposed();
    _writeIndex = 0;
    _availableFrames = 0;
    for (int frame = 0; frame < windowFrames; frame++) {
      _history[frame] = 0;
    }
    for (int point = 0; point < pointCount; point++) {
      _points[point] = 0;
    }
  }

  @override
  void onDispose() {
    NativeAllocator.instance
      ..free(_points)
      ..free(_history);
  }
}
