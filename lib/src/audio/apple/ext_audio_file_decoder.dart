/// Decodes an audio file to float32 PCM with AudioToolbox's `ExtAudioFile`.
///
/// The Apple counterpart of the Media Foundation decoder: the system's own
/// codecs - MP3, AAC and ALAC in M4A/MP4, WAV, AIFF, CAF, FLAC - asked for
/// interleaved float32 at the file's rate and channel count, which is what a
/// [NativePcmAudioBuffer] holds and an output queue plays.
library;

import 'dart:convert';
import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../native/native_pcm_audio_buffer.dart';

typedef _Ptr = Pointer<Void>;

const int _kFileDataFormat = 0x66666d74; // 'ffmt'
const int _kClientDataFormat = 0x63666d74; // 'cfmt'
const int _kFileLengthFrames = 0x2366726d; // '#frm'
const int _kAudioFormatLinearPCM = 0x6C70636D; // 'lpcm'

abstract final class ExtAudioFileDecoder {
  /// The whole of [path] as float32 PCM, or null when the system cannot
  /// open or decode it - which a player treats as "no sound", never as an
  /// error to crash on.
  static NativePcmAudioBuffer? decodeFile(String path) {
    final DynamicLibrary toolbox;
    final DynamicLibrary coreFoundation;
    try {
      toolbox = DynamicLibrary.open(
          '/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox');
      coreFoundation = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
    } on Object {
      return null;
    }
    final urlCreate = coreFoundation.lookupFunction<
        _Ptr Function(_Ptr, Pointer<Uint8>, IntPtr, Bool),
        _Ptr Function(_Ptr, Pointer<Uint8>, int,
            bool)>('CFURLCreateFromFileSystemRepresentation');
    final cfRelease = coreFoundation
        .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('CFRelease');
    final openUrl = toolbox.lookupFunction<Int32 Function(_Ptr, Pointer<_Ptr>),
        int Function(_Ptr, Pointer<_Ptr>)>('ExtAudioFileOpenURL');
    final getProperty = toolbox.lookupFunction<
        Int32 Function(_Ptr, Uint32, Pointer<Uint32>, _Ptr),
        int Function(
            _Ptr, int, Pointer<Uint32>, _Ptr)>('ExtAudioFileGetProperty');
    final setProperty = toolbox.lookupFunction<
        Int32 Function(_Ptr, Uint32, Uint32, _Ptr),
        int Function(_Ptr, int, int, _Ptr)>('ExtAudioFileSetProperty');
    final read = toolbox.lookupFunction<
        Int32 Function(_Ptr, Pointer<Uint32>, _Ptr),
        int Function(_Ptr, Pointer<Uint32>, _Ptr)>('ExtAudioFileRead');
    final disposeFile =
        toolbox.lookupFunction<Int32 Function(_Ptr), int Function(_Ptr)>(
            'ExtAudioFileDispose');

    final NativeAllocator memory = NativeAllocator.instance;
    final List<int> bytes = utf8.encode(path);
    final Pointer<Uint8> pathBytes = memory.allocate<Uint8>(bytes.length + 1);
    pathBytes.asTypedList(bytes.length).setAll(0, bytes);
    final _Ptr url = urlCreate(nullptr, pathBytes, bytes.length, false);
    memory.free(pathBytes);
    if (url == nullptr) return null;

    final Pointer<_Ptr> fileSlot = memory.allocate<_Ptr>(8);
    final Pointer<Uint8> format = memory.allocate<Uint8>(40);
    final Pointer<Uint32> size = memory.allocate<Uint32>(4);
    final Pointer<Int64> length = memory.allocate<Int64>(8);
    _Ptr file = nullptr;
    NativePcmAudioBuffer? result;
    try {
      if (openUrl(url, fileSlot) != 0 || fileSlot.value == nullptr) return null;
      file = fileSlot.value;
      size.value = 40;
      if (getProperty(file, _kFileDataFormat, size, format.cast()) != 0) {
        return null;
      }
      final double sampleRate = format.cast<Double>().value;
      final int channels = (format + 8).cast<Uint32>()[5];
      if (sampleRate <= 0 || channels <= 0) return null;
      // Ask for interleaved float32 at the file's own rate and channels.
      final Pointer<Uint32> fields = (format + 8).cast<Uint32>();
      fields[0] = _kAudioFormatLinearPCM;
      fields[1] = 1 | 8; // float, packed
      fields[2] = 4 * channels;
      fields[3] = 1;
      fields[4] = 4 * channels;
      fields[5] = channels;
      fields[6] = 32;
      fields[7] = 0;
      if (setProperty(file, _kClientDataFormat, 40, format.cast()) != 0) {
        return null;
      }
      size.value = 8;
      if (getProperty(file, _kFileLengthFrames, size, length.cast()) != 0) {
        return null;
      }
      final int frames = length.value;
      if (frames <= 0) return null;
      final NativePcmAudioBuffer pcm = NativePcmAudioBuffer.allocate(
        sampleRate: sampleRate.round(),
        channels: channels,
        frameCount: frames,
      );
      // AudioBufferList with one buffer: u32 count, then the AudioBuffer at
      // 8 - u32 channels, u32 byte size, data pointer at 16.
      final Pointer<Uint8> list = memory.allocate<Uint8>(24);
      final Pointer<Uint32> count = memory.allocate<Uint32>(4);
      var done = 0;
      try {
        while (done < frames) {
          final int want = frames - done < 32768 ? frames - done : 32768;
          list.cast<Uint32>()[0] = 1;
          (list + 8).cast<Uint32>()[0] = channels;
          (list + 12).cast<Uint32>()[0] = want * channels * 4;
          (list + 16).cast<Pointer<Float>>().value =
              pcm.samples + done * channels;
          count.value = want;
          if (read(file, count, list.cast()) != 0) break;
          if (count.value == 0) break;
          done += count.value;
        }
      } finally {
        memory.free(list);
        memory.free(count);
      }
      if (done == 0) {
        pcm.dispose();
        return null;
      }
      // A file may decode to fewer frames than its header promised; the
      // rest of the buffer is already silence.
      result = pcm;
      return result;
    } finally {
      if (file != nullptr) disposeFile(file);
      cfRelease(url);
      memory
        ..free(fileSlot)
        ..free(format)
        ..free(size)
        ..free(length);
    }
  }
}
