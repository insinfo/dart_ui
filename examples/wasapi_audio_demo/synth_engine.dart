import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';

const int synthNoteCount = 24;
const int _wetIndex = synthNoteCount;
const int _roomIndex = synthNoteCount + 1;
const int _dampingIndex = synthNoteCount + 2;
const int _masterIndex = synthNoteCount + 3;
const int _parameterCount = synthNoteCount + 4;

final class SynthEngine with DisposableMixin {
  SynthEngine()
      : parameters = WasapiSharedParameterBlock.allocate(_parameterCount) {
    parameters
      ..setValue(_wetIndex, 0.32)
      ..setValue(_roomIndex, 0.72)
      ..setValue(_dampingIndex, 0.28)
      ..setValue(_masterIndex, 0.24);
  }

  final WasapiSharedParameterBlock parameters;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _stopped = Completer<void>();
  ReceivePort? _messages;
  int _stopHandle = 0;

  int sampleRate = 0;
  int periodFrames = 0;
  Duration latency = Duration.zero;

  Future<void> start() async {
    throwIfDisposed();
    if (_messages != null) return _ready.future;
    final ReceivePort messages = ReceivePort();
    _messages = messages;
    messages.listen(_handleMessage);
    await Isolate.spawn(
      _audioIsolate,
      <Object>[messages.sendPort, parameters.address],
      debugName: 'dart_ui realtime audio',
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

  void noteOn(int note) {
    if (isDisposed || note < 0 || note >= synthNoteCount) return;
    parameters.setValue(note, 1);
  }

  void noteOff(int note) {
    if (isDisposed || note < 0 || note >= synthNoteCount) return;
    parameters.setValue(note, 0);
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
    for (int note = 0; note < synthNoteCount; note++) {
      parameters.setValue(note, 0);
    }
    WasapiRenderStream.signalStopHandle(_stopHandle);
    _stopHandle = 0;
    await _stopped.future;
  }

  @override
  void onDispose() {
    _messages?.close();
    parameters.dispose();
  }
}

void _audioIsolate(List<Object> setup) {
  final SendPort messages = setup[0] as SendPort;
  final int parameterAddress = setup[1] as int;
  WasapiRenderStream? stream;
  WasapiSharedParameterBlock? parameters;
  _KeyboardSynthProcessor? processor;
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
    parameters = WasapiSharedParameterBlock.attach(parameterAddress);
    processor = _KeyboardSynthProcessor(
      sampleRate: configuration.format.sampleRate,
      channels: configuration.format.channels,
      parameters: parameters,
    );
    messages.send(<Object?, Object?>{
      'type': 'ready',
      'stopHandle': stream.stopHandle,
      'sampleRate': configuration.format.sampleRate,
      'periodFrames': configuration.periodFrames,
      'latencyUs': configuration.streamLatency.inMicroseconds,
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
    stream?.dispose();
  }
}

final class _KeyboardSynthProcessor
    with DisposableMixin
    implements NativeFloat32AudioProcessor {
  _KeyboardSynthProcessor({
    required this.sampleRate,
    required this.channels,
    required this.parameters,
  })  : _snapshot = NativeAllocator.instance.allocate<Float>(
          _parameterCount * sizeOf<Float>(),
        ),
        _phases = NativeAllocator.instance.allocate<Double>(
          synthNoteCount * sizeOf<Double>(),
        ),
        _envelopes = NativeAllocator.instance.allocate<Float>(
          synthNoteCount * sizeOf<Float>(),
        ),
        _frequencies = NativeAllocator.instance.allocate<Double>(
          synthNoteCount * sizeOf<Double>(),
        ),
        _reverb = NativeSchroederReverb(
          sampleRate: sampleRate,
          channels: channels,
        ) {
    for (int note = 0; note < synthNoteCount; note++) {
      _snapshot[note] = 0;
      _phases[note] = 0;
      _envelopes[note] = 0;
      _frequencies[note] =
          130.81278265 * math.pow(2, note / 12).toDouble();
    }
    _snapshot[_wetIndex] = 0.32;
    _snapshot[_roomIndex] = 0.72;
    _snapshot[_dampingIndex] = 0.28;
    _snapshot[_masterIndex] = 0.24;
  }

  @override
  final int sampleRate;
  @override
  final int channels;
  final WasapiSharedParameterBlock parameters;
  final Pointer<Float> _snapshot;
  final Pointer<Double> _phases;
  final Pointer<Float> _envelopes;
  final Pointer<Double> _frequencies;
  final NativeSchroederReverb _reverb;

  @override
  void process(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    parameters.trySnapshot(_snapshot);
    _reverb
      ..wet = _snapshot[_wetIndex]
      ..roomSize = _snapshot[_roomIndex]
      ..damping = _snapshot[_dampingIndex];
    final double master = _snapshot[_masterIndex];
    final double attackStep = 1 / (sampleRate * 0.006);
    final double releaseStep = 1 / (sampleRate * 0.22);
    for (int frame = 0; frame < frames; frame++) {
      double left = 0;
      double right = 0;
      for (int note = 0; note < synthNoteCount; note++) {
        final bool gate = _snapshot[note] >= 0.5;
        double envelope = _envelopes[note];
        if (gate) {
          envelope += attackStep;
          if (envelope > 1) envelope = 1;
        } else if (envelope > 0) {
          envelope -= releaseStep;
          if (envelope < 0) envelope = 0;
        }
        _envelopes[note] = envelope;
        if (envelope == 0) continue;

        double phase = _phases[note];
        final double fundamental = math.sin(phase * math.pi * 2);
        final double harmonic = math.sin(phase * math.pi * 4) * 0.17;
        final double voice = (fundamental + harmonic) * envelope * master;
        final double pan = (note / (synthNoteCount - 1) - 0.5) * 0.34;
        left += voice * (1 - pan);
        right += voice * (1 + pan);
        phase += _frequencies[note] / sampleRate;
        if (phase >= 1) phase -= 1;
        _phases[note] = phase;
      }
      final int base = frame * channels;
      if (channels == 1) {
        interleavedSamples[base] = (left + right) * 0.35;
      } else {
        interleavedSamples[base] = left * 0.28;
        interleavedSamples[base + 1] = right * 0.28;
        for (int channel = 2; channel < channels; channel++) {
          interleavedSamples[base + channel] = (left + right) * 0.14;
        }
      }
    }
    _reverb.processInPlace(interleavedSamples, frames);
  }

  @override
  void onDispose() {
    _reverb.dispose();
    NativeAllocator.instance
      ..free(_frequencies)
      ..free(_envelopes)
      ..free(_phases)
      ..free(_snapshot);
  }
}
