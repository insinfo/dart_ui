import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';

import 'drum_kit.dart';

const int _wetIndex = 0;
const int _roomIndex = 1;
const int _dampingIndex = 2;
const int _masterIndex = 3;
const int _parameterCount = 4;

final class DrumEngine with DisposableMixin {
  DrumEngine({required this.sampleDirectory})
      : triggers = WasapiSharedTriggerBlock.allocate(drumKit.length),
        parameters = WasapiSharedParameterBlock.allocate(_parameterCount) {
    parameters
      ..setValue(_wetIndex, 0.12)
      ..setValue(_roomIndex, 0.48)
      ..setValue(_dampingIndex, 0.38)
      ..setValue(_masterIndex, 0.72);
  }

  final String sampleDirectory;
  final WasapiSharedTriggerBlock triggers;
  final WasapiSharedParameterBlock parameters;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _stopped = Completer<void>();
  ReceivePort? _messages;
  int _stopHandle = 0;

  int sampleRate = 0;
  int periodFrames = 0;
  Duration latency = Duration.zero;
  int loadedSamples = 0;

  Future<void> start() async {
    throwIfDisposed();
    if (_messages != null) return _ready.future;
    final ReceivePort messages = ReceivePort();
    _messages = messages;
    messages.listen(_handleMessage);
    await Isolate.spawn(
      _audioIsolate,
      <Object>[
        messages.sendPort,
        triggers.address,
        parameters.address,
        sampleDirectory,
      ],
      debugName: 'dart_ui realtime drum sampler',
    );
    return _ready.future;
  }

  void _handleMessage(Object? message) {
    if (message is! Map<Object?, Object?>) return;
    switch (message['type']) {
      case 'ready':
        _stopHandle = message['stopHandle']! as int;
        sampleRate = message['sampleRate']! as int;
        periodFrames = message['periodFrames']! as int;
        loadedSamples = message['loadedSamples']! as int;
        latency = Duration(microseconds: message['latencyUs']! as int);
        if (!_ready.isCompleted) _ready.complete();
      case 'stopped':
        if (!_stopped.isCompleted) _stopped.complete();
      case 'error':
        final StateError error = StateError('${message['error']}');
        if (!_ready.isCompleted) _ready.completeError(error);
        if (!_stopped.isCompleted) _stopped.completeError(error);
    }
  }

  void trigger(int pad, {double velocity = 1}) {
    if (isDisposed || pad < 0 || pad >= drumKit.length) return;
    triggers.trigger(pad, velocity: velocity);
  }

  double get wet => parameters.valueAt(_wetIndex);
  set wet(double value) => parameters.setValue(_wetIndex, value);
  double get roomSize => parameters.valueAt(_roomIndex);
  set roomSize(double value) => parameters.setValue(_roomIndex, value);
  double get damping => parameters.valueAt(_dampingIndex);
  set damping(double value) => parameters.setValue(_dampingIndex, value);
  double get master => parameters.valueAt(_masterIndex);
  set master(double value) => parameters.setValue(_masterIndex, value);

  Future<void> stop() async {
    if (_stopHandle == 0) return;
    WasapiRenderStream.signalStopHandle(_stopHandle);
    _stopHandle = 0;
    await _stopped.future;
  }

  @override
  void onDispose() {
    _messages?.close();
    parameters.dispose();
    triggers.dispose();
  }
}

void _audioIsolate(List<Object> setup) {
  final SendPort messages = setup[0] as SendPort;
  final int triggerAddress = setup[1] as int;
  final int parameterAddress = setup[2] as int;
  final String sampleDirectory = setup[3] as String;
  WasapiRenderStream? stream;
  WasapiSharedTriggerBlock? triggers;
  WasapiSharedParameterBlock? parameters;
  _DrumProcessor? processor;
  try {
    stream = WasapiAudioBackend().openStream(
      const AudioStreamRequest(
        preferredFormat: AudioFormat(
          sampleRate: 48000,
          channels: 2,
          sampleFormat: AudioSampleFormat.float32,
        ),
        preferredPeriodFrames: 128,
      ),
    );
    final AudioStreamConfiguration configuration = stream.configuration;
    if (configuration.format.sampleFormat != AudioSampleFormat.float32) {
      throw StateError('O endpoint não aceitou PCM float32: '
          '${configuration.format}');
    }
    final List<NativePcmAudioBuffer> clips = _loadSamples(
      sampleDirectory,
      configuration.format.sampleRate,
      configuration.format.channels,
    );
    triggers = WasapiSharedTriggerBlock.attach(triggerAddress);
    parameters = WasapiSharedParameterBlock.attach(parameterAddress);
    processor = _DrumProcessor(
      sampleRate: configuration.format.sampleRate,
      channels: configuration.format.channels,
      clips: clips,
      triggers: triggers,
      parameters: parameters,
    );
    messages.send(<Object?, Object?>{
      'type': 'ready',
      'stopHandle': stream.stopHandle,
      'sampleRate': configuration.format.sampleRate,
      'periodFrames': configuration.periodFrames,
      'latencyUs': configuration.streamLatency.inMicroseconds,
      'loadedSamples': clips.length,
    });
    stream.runWithProcessor(processor);
    messages.send(<Object?, Object?>{'type': 'stopped'});
  } on Object catch (error, stack) {
    messages.send(<Object?, Object?>{
      'type': 'error',
      'error': '$error\n$stack',
    });
  } finally {
    processor?.dispose();
    parameters?.dispose();
    triggers?.dispose();
    stream?.dispose();
  }
}

List<NativePcmAudioBuffer> _loadSamples(
  String directory,
  int sampleRate,
  int channels,
) {
  final List<NativePcmAudioBuffer> clips = <NativePcmAudioBuffer>[];
  try {
    for (final DrumPadSpec pad in drumKit) {
      final File file =
          File('$directory${Platform.pathSeparator}${pad.fileName}');
      if (!file.existsSync()) {
        throw StateError('Sample não encontrado: ${file.path}');
      }
      final NativePcmAudioBuffer decoded =
          WaveDecoder.decode(file.readAsBytesSync());
      try {
        clips
            .add(decoded.converted(sampleRate: sampleRate, channels: channels));
      } finally {
        decoded.dispose();
      }
    }
    return clips;
  } on Object {
    for (final NativePcmAudioBuffer clip in clips) {
      clip.dispose();
    }
    rethrow;
  }
}

final class _DrumProcessor
    with DisposableMixin
    implements NativeFloat32AudioProcessor {
  _DrumProcessor({
    required this.sampleRate,
    required this.channels,
    required this.clips,
    required this.triggers,
    required this.parameters,
  })  : _sequences = NativeAllocator.instance.allocate<Uint32>(
          drumKit.length * sizeOf<Uint32>(),
        ),
        _previousSequences = NativeAllocator.instance.allocate<Uint32>(
          drumKit.length * sizeOf<Uint32>(),
        ),
        _velocities = NativeAllocator.instance.allocate<Float>(
          drumKit.length * sizeOf<Float>(),
        ),
        _parameterSnapshot = NativeAllocator.instance.allocate<Float>(
          _parameterCount * sizeOf<Float>(),
        ),
        _mixer = NativeSampleMixer(
          sampleRate: sampleRate,
          channels: channels,
          samples: clips,
          maxVoices: 40,
        ),
        _reverb = NativeSchroederReverb(
          sampleRate: sampleRate,
          channels: channels,
        ) {
    _parameterSnapshot[_wetIndex] = 0.12;
    _parameterSnapshot[_roomIndex] = 0.48;
    _parameterSnapshot[_dampingIndex] = 0.38;
    _parameterSnapshot[_masterIndex] = 0.72;
  }

  @override
  final int sampleRate;
  @override
  final int channels;
  final List<NativePcmAudioBuffer> clips;
  final WasapiSharedTriggerBlock triggers;
  final WasapiSharedParameterBlock parameters;
  final Pointer<Uint32> _sequences;
  final Pointer<Uint32> _previousSequences;
  final Pointer<Float> _velocities;
  final Pointer<Float> _parameterSnapshot;
  final NativeSampleMixer _mixer;
  final NativeSchroederReverb _reverb;

  @override
  void process(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    if (triggers.trySnapshot(_sequences, _velocities)) {
      for (int pad = 0; pad < drumKit.length; pad++) {
        final int current = _sequences[pad];
        final int previous = _previousSequences[pad];
        int pending = (current - previous) & 0xffffffff;
        if (pending > 4) pending = 4;
        while (pending-- > 0) {
          final DrumPadSpec spec = drumKit[pad];
          _mixer.trigger(
            pad,
            gain: _velocities[pad] * spec.gain,
            chokeGroup: spec.chokeGroup,
          );
        }
        _previousSequences[pad] = current;
      }
    }
    parameters.trySnapshot(_parameterSnapshot);
    _mixer.outputGain = _parameterSnapshot[_masterIndex];
    _mixer.process(interleavedSamples, frames);
    _reverb
      ..wet = _parameterSnapshot[_wetIndex]
      ..roomSize = _parameterSnapshot[_roomIndex]
      ..damping = _parameterSnapshot[_dampingIndex]
      ..processInPlace(interleavedSamples, frames);
  }

  @override
  void onDispose() {
    _reverb.dispose();
    _mixer.dispose();
    for (final NativePcmAudioBuffer clip in clips) {
      clip.dispose();
    }
    NativeAllocator.instance
      ..free(_parameterSnapshot)
      ..free(_velocities)
      ..free(_previousSequences)
      ..free(_sequences);
  }
}
