import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/audio.dart';
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

/// Plays one file through the equalizer and analyzers below.
///
/// Nothing here knows which operating system it runs on:
/// [AudioProcessorOutput] puts the processor on the platform's output device
/// (WASAPI, an Audio Queue) on its own isolate, and the controls and readings
/// travel through an [AudioControlBlock].
final class MusicPlayerEngine with DisposableMixin {
  MusicPlayerEngine()
      : controls = AudioControlBlock.allocate(
          parameters: _parameterCount,
          triggers: 1,
          telemetry: _telemetryCount,
        ) {
    controls
      ..setParameter(_playingIndex, 0)
      ..setParameter(_volumeIndex, 0.72)
      ..setParameter(_seekIndex, 0);
  }

  final AudioControlBlock controls;
  AudioProcessorOutput? _output;

  String? path;
  int sampleRate = 0;
  int channels = 0;
  int periodFrames = 0;
  int frameCount = 0;
  Duration duration = Duration.zero;
  String decoder = '';

  bool get isLoaded => _output != null;
  bool get isPlaying => controls.parameter(_playingIndex) >= 0.5;
  double get volume => controls.parameter(_volumeIndex);
  double get positionFraction => controls.telemetry(_positionTelemetry);
  double get peak => controls.telemetry(_peakTelemetry);
  bool get hasEnded => controls.telemetry(_endedTelemetry) >= 0.5;

  double spectrumLevelAt(int band) {
    RangeError.checkValidIndex(band, this, 'band', musicSpectrumBandCount);
    return controls.telemetry(_spectrumTelemetryStart + band);
  }

  double waveformSampleAt(int point) {
    RangeError.checkValidIndex(point, this, 'point', musicWaveformPointCount);
    return controls.telemetry(_waveformTelemetryStart + point);
  }

  double equalizerGainDbAt(int band) {
    RangeError.checkValidIndex(
      band,
      musicEqualizerFrequencies,
      'band',
    );
    return controls.parameter(_equalizerStartIndex + band);
  }

  void setEqualizerGainDb(int band, double value) {
    RangeError.checkValidIndex(
      band,
      musicEqualizerFrequencies,
      'band',
    );
    controls.setParameter(
        _equalizerStartIndex + band, value.clamp(-12, 12).toDouble());
  }

  void resetEqualizer() {
    for (int band = 0; band < musicEqualizerFrequencies.length; band++) {
      controls.setParameter(_equalizerStartIndex + band, 0);
    }
  }

  Future<void> load(String path) async {
    throwIfDisposed();
    await stop();
    this.path = path;
    for (int index = 0; index < _telemetryCount; index++) {
      controls.publish(index, 0);
    }
    controls
      ..setParameter(_playingIndex, 1)
      ..setParameter(_seekIndex, 0);
    final AudioProcessorOutput? output = await AudioProcessorOutput.open(
      _musicProcessorFor(path),
      controls: controls,
      preferredPeriodFrames: 128,
      debugName: 'dart_ui music decoder and player',
    );
    if (output == null) {
      throw StateError('Nenhuma saída de áudio disponível nesta máquina.');
    }
    _output = output;
    sampleRate = output.sampleRate;
    channels = output.channels;
    periodFrames = output.periodFrames;
    frameCount = output.details['frameCount']! as int;
    duration = Duration(microseconds: output.details['durationUs']! as int);
    decoder = '${output.details['decoder']} · ${output.backend}';
  }

  void play() {
    if (!isLoaded) return;
    if (hasEnded) seek(0);
    controls.setParameter(_playingIndex, 1);
  }

  void pause() {
    if (!isLoaded) return;
    controls.setParameter(_playingIndex, 0);
  }

  void seek(double fraction) {
    if (!isLoaded) return;
    controls
      ..setParameter(_seekIndex, fraction.clamp(0.0, 1.0))
      ..trigger(_seekTrigger);
  }

  set volume(double value) =>
      controls.setParameter(_volumeIndex, value.clamp(0.0, 1.0));

  Future<void> stop() async {
    final AudioProcessorOutput? output = _output;
    _output = null;
    await output?.close();
  }

  @override
  void onDispose() {
    // The audio isolate reads the block until it stops; an engine disposed
    // while playing leaks it rather than pulling memory from under it.
    if (_output == null) controls.dispose();
  }
}

/// Decodes [path] on the audio isolate, converted to the device's format.
AudioProcessorBuilder _musicProcessorFor(String path) =>
    (AudioOutputContext context) {
      final bool isWave = path.toLowerCase().endsWith('.wav');
      final NativePcmAudioBuffer? source = isWave
          ? WaveDecoder.decode(File(path).readAsBytesSync())
          : MediaAudioTracks.decodeFile(path);
      if (source == null) {
        throw StateError('O sistema não decodificou este arquivo.');
      }
      final NativePcmAudioBuffer clip;
      try {
        clip = source.converted(
          sampleRate: context.sampleRate,
          channels: context.channels,
        );
      } finally {
        source.dispose();
      }
      context.details
        ..['frameCount'] = clip.frameCount
        ..['durationUs'] = clip.duration.inMicroseconds
        ..['decoder'] = isWave
            ? 'RIFF/WAVE · Dart'
            : Platform.isWindows
                ? 'Media Foundation FFI'
                : 'ExtAudioFile FFI';
      return _MusicProcessor(clip: clip, controls: context.controls!);
    };

final class _MusicProcessor
    with DisposableMixin
    implements NativeFloat32AudioProcessor {
  _MusicProcessor({
    required this.clip,
    required this.controls,
  })  : _player = NativePcmClipPlayer(clip),
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
        ),
        _seekSequence = controls.triggerSequence(_seekTrigger);

  final NativePcmAudioBuffer clip;
  final AudioControlBlock controls;
  final NativePcmClipPlayer _player;
  final NativeGraphicEqualizer _equalizer;
  final NativeSpectrumAnalyzer _spectrum;
  final NativeWaveformAnalyzer _waveform;
  int _seekSequence;

  @override
  int get sampleRate => clip.sampleRate;
  @override
  int get channels => clip.channels;

  @override
  void process(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    final int sequence = controls.triggerSequence(_seekTrigger);
    if (sequence != _seekSequence) {
      _player.seekToFraction(controls.parameter(_seekIndex));
      _equalizer.reset();
      _spectrum.reset();
      _waveform.reset();
      controls.publish(_endedTelemetry, 0);
      _seekSequence = sequence;
    }
    _player
      ..volume = controls.parameter(_volumeIndex)
      ..playing = controls.parameter(_playingIndex) >= 0.5
      ..process(interleavedSamples, frames);
    for (int band = 0; band < musicEqualizerFrequencies.length; band++) {
      _equalizer.setGainDb(
        band,
        controls.parameter(_equalizerStartIndex + band),
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
    controls
      ..publish(_positionTelemetry, _player.positionFraction)
      ..publish(_endedTelemetry, _player.isAtEnd ? 1 : 0)
      ..publish(_peakTelemetry, peak.clamp(0.0, 1.0));
    for (int band = 0; band < musicSpectrumBandCount; band++) {
      controls.publish(
        _spectrumTelemetryStart + band,
        _spectrum.levelAt(band),
      );
    }
    for (int point = 0; point < musicWaveformPointCount; point++) {
      controls.publish(
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
  }
}
