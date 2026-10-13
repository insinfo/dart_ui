/// The few AudioToolbox Audio Queue functions dart_ui calls, bound once.
///
/// Shared by the [PcmAudioPlayer] over a decoded clip and the processor
/// stream that pulls samples from a DSP graph: both open a float32
/// interleaved output queue and keep a few buffers in it.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';

/// `AudioQueueOutputCallback`: user data, the queue, the buffer handed back.
typedef AudioQueueOutputCallbackNative = Void Function(
    Pointer<Void> userData, Pointer<Void> queue, Pointer<Void> buffer);

const int _kAudioFormatLinearPCM = 0x6C70636D; // 'lpcm'
const int _kAudioFormatFlagIsFloat = 1;
const int _kAudioFormatFlagIsPacked = 8;

/// `kAudioQueueParam_Volume`.
const int kAudioQueueParamVolume = 1;

final class AudioToolboxApi {
  AudioToolboxApi._(DynamicLibrary lib)
      : newOutput = lib.lookupFunction<
            Int32 Function(
                Pointer<Void>,
                Pointer<NativeFunction<AudioQueueOutputCallbackNative>>,
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Void>,
                Uint32,
                Pointer<Pointer<Void>>),
            int Function(
                Pointer<Void>,
                Pointer<NativeFunction<AudioQueueOutputCallbackNative>>,
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Void>,
                int,
                Pointer<Pointer<Void>>)>('AudioQueueNewOutput'),
        allocateBuffer = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
            int Function(Pointer<Void>, int,
                Pointer<Pointer<Void>>)>('AudioQueueAllocateBuffer'),
        enqueue = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Pointer<Void>),
            int Function(Pointer<Void>, Pointer<Void>, int,
                Pointer<Void>)>('AudioQueueEnqueueBuffer'),
        start = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>),
            int Function(Pointer<Void>, Pointer<Void>)>('AudioQueueStart'),
        pause = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('AudioQueuePause'),
        stop = lib.lookupFunction<Int32 Function(Pointer<Void>, Uint8),
            int Function(Pointer<Void>, int)>('AudioQueueStop'),
        dispose = lib.lookupFunction<Int32 Function(Pointer<Void>, Uint8),
            int Function(Pointer<Void>, int)>('AudioQueueDispose'),
        setParameter = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Float),
            int Function(Pointer<Void>, int, double)>('AudioQueueSetParameter'),
        currentTime = lib.lookupFunction<
            Int32 Function(
                Pointer<Void>, Pointer<Void>, Pointer<Double>, Pointer<Void>),
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Double>,
                Pointer<Void>)>('AudioQueueGetCurrentTime');

  static AudioToolboxApi? _instance;
  static bool _tried = false;

  /// The bound functions, or null where AudioToolbox does not load.
  static AudioToolboxApi? get instance {
    if (_tried) return _instance;
    _tried = true;
    try {
      _instance = AudioToolboxApi._(DynamicLibrary.open(
          '/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox'));
    } on Object {
      _instance = null;
    }
    return _instance;
  }

  final int Function(
      Pointer<Void>,
      Pointer<NativeFunction<AudioQueueOutputCallbackNative>>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Pointer<Void>>) newOutput;
  final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>) allocateBuffer;
  final int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Void>) enqueue;
  final int Function(Pointer<Void>, Pointer<Void>) start;
  final int Function(Pointer<Void>) pause;
  final int Function(Pointer<Void>, int) stop;
  final int Function(Pointer<Void>, int) dispose;
  final int Function(Pointer<Void>, int, double) setParameter;

  /// `AudioQueueGetCurrentTime`; the out parameter is an `AudioTimeStamp`
  /// whose first field, `mSampleTime`, is all dart_ui reads.
  final int Function(
      Pointer<Void>, Pointer<Void>, Pointer<Double>, Pointer<Void>) currentTime;

  /// A new output queue for interleaved float32 at [sampleRate] and
  /// [channels], or null. With no run loop, [callback] is called on the
  /// queue's own thread - which a `NativeCallable.listener` turns into a
  /// message for the isolate that made it. [userData] comes back with it.
  Pointer<Void>? newFloat32Output({
    required int sampleRate,
    required int channels,
    required NativeCallable<AudioQueueOutputCallbackNative> callback,
    required int userData,
  }) {
    final Pointer<Uint8> format = NativeAllocator.instance.allocate<Uint8>(40);
    final Pointer<Pointer<Void>> slot =
        NativeAllocator.instance.allocate<Pointer<Void>>(8);
    try {
      final int bytesPerFrame = 4 * channels;
      format.cast<Double>().value = sampleRate.toDouble();
      final Pointer<Uint32> fields = (format + 8).cast<Uint32>();
      fields[0] = _kAudioFormatLinearPCM;
      fields[1] = _kAudioFormatFlagIsFloat | _kAudioFormatFlagIsPacked;
      fields[2] = bytesPerFrame; // mBytesPerPacket
      fields[3] = 1; // mFramesPerPacket
      fields[4] = bytesPerFrame; // mBytesPerFrame
      fields[5] = channels; // mChannelsPerFrame
      fields[6] = 32; // mBitsPerChannel
      fields[7] = 0; // mReserved
      final int status = newOutput(format.cast(), callback.nativeFunction,
          Pointer<Void>.fromAddress(userData), nullptr, nullptr, 0, slot);
      if (status != 0 || slot.value == nullptr) return null;
      return slot.value;
    } finally {
      NativeAllocator.instance
        ..free(format)
        ..free(slot);
    }
  }

  /// A buffer of [bytes] in [queue], or null.
  Pointer<Void>? newBuffer(Pointer<Void> queue, int bytes) {
    final Pointer<Pointer<Void>> slot =
        NativeAllocator.instance.allocate<Pointer<Void>>(8);
    try {
      if (allocateBuffer(queue, bytes, slot) != 0) return null;
      return slot.value;
    } finally {
      NativeAllocator.instance.free(slot);
    }
  }

  /// The sample the queue is playing now, counted from its start, or null.
  double? sampleTime(Pointer<Void> queue) {
    final Pointer<Double> stamp = NativeAllocator.instance.allocate<Double>(64);
    try {
      if (currentTime(queue, nullptr, stamp, nullptr) != 0) return null;
      return stamp.value;
    } finally {
      NativeAllocator.instance.free(stamp);
    }
  }
}

/// The audio bytes of an `AudioQueueBuffer`: u32 capacity, then the data
/// pointer at 8 and the byte size at 16.
Pointer<Float> audioQueueBufferData(Pointer<Void> buffer) =>
    Pointer<Pointer<Float>>.fromAddress(buffer.address + 8).value;

void setAudioQueueBufferBytes(Pointer<Void> buffer, int bytes) =>
    Pointer<Uint32>.fromAddress(buffer.address + 16).value = bytes;
