import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';

const int _playingIndex = 0;
const int _volumeIndex = 1;
const int _seekIndex = 2;
const int _equalizerStartIndex = 3;
const List<double> musicEqualizerFrequencies = <double>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];
const int _parameterCount = 13;
const int _seekTrigger = 0;
const int _positionTelemetry = 0;
const int _endedTelemetry = 1;
const int _peakTelemetry = 2;
const int _spectrumTelemetryStart = 3;
const int musicSpectrumBandCount = 40;
const int _waveformTelemetryStart =
    _spectrumTelemetryStart + musicSpectrumBandCount;
const int musicWaveformPointCount = 160;
const int _telemetryCount = _waveformTelemetryStart + musicWaveformPointCount;

final class MusicPlayerEngine with DisposableMixin {
  MusicPlayerEngine()
      : parameters = WasapiSharedParameterBlock.allocate(_parameterCount),
        commands = WasapiSharedTriggerBlock.allocate(1),
        telemetry = WasapiSharedTelemetryBlock.allocate(_telemetryCount) {
    parameters
      ..setValue(_playingIndex, 0)
      ..setValue(_volumeIndex, 0.72)
      ..setValue(_seekIndex, 0);
    for (int band = 0; band < musicEqualizerFrequencies.length; band++) {
      parameters.setValue(_equalizerStartIndex + band, 0);
    }
  }

  final WasapiSharedParameterBlock parameters;
  final WasapiSharedTriggerBlock commands;
  final WasapiSharedTelemetryBlock telemetry;
  ReceivePort? _messages;
  Completer<void>? _ready;
  Completer<void>? _stopped;
  int _stopHandle = 0;

  String? path;
  int sampleRate = 0;
  int channels = 0;
  int periodFrames = 0;
  int frameCount = 0;
  Duration duration = Duration.zero;
  String decoder = '';

  bool get isLoaded => _stopHandle != 0;
  bool get isPlaying => parameters.valueAt(_playingIndex) >= 0.5;
  double get volume => parameters.valueAt(_volumeIndex);
  double get positionFraction => telemetry.valueAt(_positionTelemetry);
  double get peak => telemetry.valueAt(_peakTelemetry);
  bool get hasEnded => telemetry.valueAt(_endedTelemetry) >= 0.5;

  double spectrumLevelAt(int band) {
    RangeError.checkValidIndex(band, this, 'band', musicSpectrumBandCount);
    return telemetry.valueAt(_spectrumTelemetryStart + band);
  }

  double waveformSampleAt(int point) {
    RangeError.checkValidIndex(point, this, 'point', musicWaveformPointCount);
    return telemetry.valueAt(_waveformTelemetryStart + point);
  }

  double equalizerGainDbAt(int band) {
    RangeError.checkValidIndex(
      band,
      musicEqualizerFrequencies,
      'band',
    );
    return parameters.valueAt(_equalizerStartIndex + band);
  }

  void setEqualizerGainDb(int band, double value) {
    RangeError.checkValidIndex(
      band,
      musicEqualizerFrequencies,
      'band',
    );
    parameters.setValue(_equalizerStartIndex + band, value.clamp(-12, 12));
  }

  void resetEqualizer() {
    for (int band = 0; band < musicEqualizerFrequencies.length; band++) {
      parameters.setValue(_equalizerStartIndex + band, 0);
    }
  }

  Future<void> load(String path) async {
    throwIfDisposed();
    await stop();
    this.path = path;
    telemetry
      ..publish(_positionTelemetry, 0)
      ..publish(_endedTelemetry, 0)
      ..publish(_peakTelemetry, 0);
    for (int band = 0; band < musicSpectrumBandCount; band++) {
      telemetry.publish(_spectrumTelemetryStart + band, 0);
    }
    for (int point = 0; point < musicWaveformPointCount; point++) {
      telemetry.publish(_waveformTelemetryStart + point, 0);
    }
    parameters
      ..setValue(_playingIndex, 1)
      ..setValue(_seekIndex, 0);
    final Completer<void> ready = Completer<void>();
    final Completer<void> stopped = Completer<void>();
    _ready = ready;
    _stopped = stopped;
    final ReceivePort messages = ReceivePort();
    _messages = messages;
    messages.listen(_handleMessage);
    await Isolate.spawn(
      _playerIsolate,
      <Object>[
        messages.sendPort,
        path,
        parameters.address,
        commands.address,
        telemetry.address,
      ],
      debugName: 'dart_ui music decoder and player',
    );
    await ready.future;
  }

  void _handleMessage(Object? message) {
    if (message is! Map<Object?, Object?>) return;
    switch (message['type']) {
      case 'ready':
        _stopHandle = message['stopHandle']! as int;
        sampleRate = message['sampleRate']! as int;
        channels = message['channels']! as int;
        periodFrames = message['periodFrames']! as int;
        frameCount = message['frameCount']! as int;
        duration = Duration(microseconds: message['durationUs']! as int);
        decoder = message['decoder']! as String;
        if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      case 'stopped':
        if (!(_stopped?.isCompleted ?? true)) _stopped!.complete();
      case 'error':
        final StateError error = StateError('${message['error']}');
        if (!(_ready?.isCompleted ?? true)) _ready!.completeError(error);
        if (!(_stopped?.isCompleted ?? true)) _stopped!.completeError(error);
    }
  }

  void play() {
    if (!isLoaded) return;
    if (hasEnded) seek(0);
    parameters.setValue(_playingIndex, 1);
  }

  void pause() {
    if (!isLoaded) return;
    parameters.setValue(_playingIndex, 0);
  }

  void seek(double fraction) {
    if (!isLoaded) return;
    parameters.setValue(_seekIndex, fraction.clamp(0.0, 1.0));
    commands.trigger(_seekTrigger);
  }

  set volume(double value) =>
      parameters.setValue(_volumeIndex, value.clamp(0.0, 1.0));

  Future<void> stop() async {
    if (_stopHandle != 0) {
      WasapiRenderStream.signalStopHandle(_stopHandle);
      _stopHandle = 0;
      await _stopped?.future;
    }
    _messages?.close();
    _messages = null;
    _ready = null;
    _stopped = null;
  }

  @override
  void onDispose() {
    _messages?.close();
    telemetry.dispose();
    commands.dispose();
    parameters.dispose();
  }
}

void _playerIsolate(List<Object> setup) {
  final SendPort messages = setup[0] as SendPort;
  final String path = setup[1] as String;
  final int parameterAddress = setup[2] as int;
  final int commandAddress = setup[3] as int;
  final int telemetryAddress = setup[4] as int;
  WasapiRenderStream? stream;
  WasapiSharedParameterBlock? parameters;
  WasapiSharedTriggerBlock? commands;
  WasapiSharedTelemetryBlock? telemetry;
  _MusicProcessor? processor;
  NativePcmAudioBuffer? decoded;
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
    final bool isWave = path.toLowerCase().endsWith('.wav');
    final NativePcmAudioBuffer source = isWave
        ? WaveDecoder.decode(File(path).readAsBytesSync())
        : MediaFoundationAudioDecoder.decodeFile(path);
    try {
      decoded = source.converted(
        sampleRate: configuration.format.sampleRate,
        channels: configuration.format.channels,
      );
    } finally {
      source.dispose();
    }
    parameters = WasapiSharedParameterBlock.attach(parameterAddress);
    commands = WasapiSharedTriggerBlock.attach(commandAddress);
    telemetry = WasapiSharedTelemetryBlock.attach(telemetryAddress);
    processor = _MusicProcessor(
      clip: decoded,
      parameters: parameters,
      commands: commands,
      telemetry: telemetry,
    );
    decoded = null; // processor owns it from here.
    messages.send(<Object?, Object?>{
      'type': 'ready',
      'stopHandle': stream.stopHandle,
      'sampleRate': configuration.format.sampleRate,
      'channels': configuration.format.channels,
      'periodFrames': configuration.periodFrames,
      'frameCount': processor.clip.frameCount,
      'durationUs': processor.clip.duration.inMicroseconds,
      'decoder': isWave ? 'RIFF/WAVE · Dart' : 'MP3 · Media Foundation FFI',
    });
    stream.runWithProcessor(processor);
    messages.send(<Object?, Object?>{'type': 'stopped'});
  } on Object catch (error, stack) {
    messages.send(<Object?, Object?>{
      'type': 'error',
      'error': '$error\n$stack',
    });
  } finally {
    decoded?.dispose();
    processor?.dispose();
    telemetry?.dispose();
    commands?.dispose();
    parameters?.dispose();
    stream?.dispose();
  }
}

final class _MusicProcessor
    with DisposableMixin
    implements NativeFloat32AudioProcessor {
  _MusicProcessor({
    required this.clip,
    required this.parameters,
    required this.commands,
    required this.telemetry,
  })  : _snapshot = NativeAllocator.instance.allocate<Float>(
          _parameterCount * sizeOf<Float>(),
        ),
        _commandSequences = NativeAllocator.instance.allocate<Uint32>(
          sizeOf<Uint32>(),
        ),
        _commandVelocities = NativeAllocator.instance.allocate<Float>(
          sizeOf<Float>(),
        ),
        _player = NativePcmClipPlayer(clip),
        _equalizer = NativeGraphicEqualizer(
          sampleRate: clip.sampleRate,
          channels: clip.channels,
          frequencies: musicEqualizerFrequencies,
        ),
        _spectrum = NativeSpectrumAnalyzer(
          sampleRate: clip.sampleRate,
          channels: clip.channels,
          bandCount: musicSpectrumBandCount,
        ),
        _waveform = NativeWaveformAnalyzer(
          sampleRate: clip.sampleRate,
          channels: clip.channels,
          pointCount: musicWaveformPointCount,
          windowFrames: 2048,
        ) {
    _snapshot[_playingIndex] = 1;
    _snapshot[_volumeIndex] = 0.72;
    _snapshot[_seekIndex] = 0;
    for (int band = 0; band < musicEqualizerFrequencies.length; band++) {
      _snapshot[_equalizerStartIndex + band] = 0;
    }
  }

  final NativePcmAudioBuffer clip;
  final WasapiSharedParameterBlock parameters;
  final WasapiSharedTriggerBlock commands;
  final WasapiSharedTelemetryBlock telemetry;
  final Pointer<Float> _snapshot;
  final Pointer<Uint32> _commandSequences;
  final Pointer<Float> _commandVelocities;
  final NativePcmClipPlayer _player;
  final NativeGraphicEqualizer _equalizer;
  final NativeSpectrumAnalyzer _spectrum;
  final NativeWaveformAnalyzer _waveform;
  int _previousSeekSequence = 0;

  @override
  int get sampleRate => clip.sampleRate;
  @override
  int get channels => clip.channels;

  @override
  void process(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    parameters.trySnapshot(_snapshot);
    if (commands.trySnapshot(_commandSequences, _commandVelocities)) {
      final int sequence = _commandSequences[_seekTrigger];
      if (sequence != _previousSeekSequence) {
        _player.seekToFraction(_snapshot[_seekIndex]);
        _equalizer.reset();
        _spectrum.reset();
        _waveform.reset();
        telemetry.publish(_endedTelemetry, 0);
        _previousSeekSequence = sequence;
      }
    }
    _player
      ..volume = _snapshot[_volumeIndex]
      ..playing = _snapshot[_playingIndex] >= 0.5
      ..process(interleavedSamples, frames);
    for (int band = 0; band < musicEqualizerFrequencies.length; band++) {
      _equalizer.setGainDb(
        band,
        _snapshot[_equalizerStartIndex + band],
      );
    }
    _equalizer.processInPlace(interleavedSamples, frames);
    _spectrum.processInPlace(interleavedSamples, frames);
    _waveform.processInPlace(interleavedSamples, frames);

    double peak = 0;
    for (int index = 0; index < frames * channels; index++) {
      final double level = interleavedSamples[index].abs();
      if (level > peak) peak = level;
    }
    telemetry
      ..publish(_positionTelemetry, _player.positionFraction)
      ..publish(_endedTelemetry, _player.isAtEnd ? 1 : 0)
      ..publish(_peakTelemetry, peak.clamp(0.0, 1.0));
    for (int band = 0; band < musicSpectrumBandCount; band++) {
      telemetry.publish(
        _spectrumTelemetryStart + band,
        _spectrum.levelAt(band),
      );
    }
    for (int point = 0; point < musicWaveformPointCount; point++) {
      telemetry.publish(
        _waveformTelemetryStart + point,
        _waveform.sampleAt(point),
      );
    }
  }

  @override
  void onDispose() {
    _waveform.dispose();
    _spectrum.dispose();
    _equalizer.dispose();
    _player.dispose();
    clip.dispose();
    NativeAllocator.instance
      ..free(_commandVelocities)
      ..free(_commandSequences)
      ..free(_snapshot);
  }
}
