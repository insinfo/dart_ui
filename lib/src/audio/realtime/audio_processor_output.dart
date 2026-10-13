/// Plays a DSP graph on the default output device, on any platform.
library;

import 'dart:async';

import '../audio_format.dart';
import '../dsp/native_audio_processor.dart';
import 'audio_control_block.dart';
import 'audio_processor_output_stub.dart'
    if (dart.library.io) 'audio_processor_output_io.dart' as platform;

/// Builds the processor on the audio isolate, once the device format is
/// known. It must return a processor at [AudioOutputContext.sampleRate] and
/// [AudioOutputContext.channels].
///
/// It runs on another isolate, so it must be a function that can be sent
/// there: a top-level or static function, or a closure that captures only
/// sendable values - a path, a few numbers - and not a widget or a `this`.
typedef AudioProcessorBuilder = NativeFloat32AudioProcessor Function(
    AudioOutputContext context);

/// What a [AudioProcessorBuilder] knows about the stream it fills.
final class AudioOutputContext {
  AudioOutputContext({
    required this.sampleRate,
    required this.channels,
    required this.periodFrames,
    this.controls,
  });

  final int sampleRate;
  final int channels;

  /// Frames the processor is usually asked for at a time.
  final int periodFrames;

  /// The block passed to [AudioProcessorOutput.open], attached on this
  /// isolate, or null when none was passed.
  final AudioControlBlock? controls;

  /// Facts the builder wants the opener to have - a clip's length, the codec
  /// that decoded it. Values must be sendable between isolates; they arrive
  /// as [AudioProcessorOutput.details].
  final Map<String, Object?> details = <String, Object?>{};
}

/// A processor rendering to the default output device.
///
/// The one call an application makes for realtime audio, whatever the
/// platform: WASAPI on Windows, an Audio Queue on macOS and iOS. Either way
/// the processor lives on a dedicated isolate, so a slow frame of the
/// interface never reaches the speaker, and talks to the application through
/// an [AudioControlBlock].
///
/// ```dart
/// final controls = AudioControlBlock.allocate(parameters: 1, telemetry: 1);
/// final output = await AudioProcessorOutput.open(
///   (context) => MySynth(context.sampleRate, context.channels, context.controls!),
///   controls: controls,
/// );
/// controls.setParameter(0, 0.5);       // the synth reads it next block
/// print(controls.telemetry(0));        // and publishes back
/// await output?.close();
/// ```
final class AudioProcessorOutput {
  /// Made by the platform implementation; applications call [open].
  AudioProcessorOutput.internal({
    required this.backend,
    required this.sampleRate,
    required this.channels,
    required this.periodFrames,
    required this.latency,
    required this.details,
    required Future<Object?> finished,
    required void Function() stop,
  }) : _stop = stop {
    _done = finished.then((Object? error) => _error = error);
  }

  /// Starts [build]'s processor on the default output, or returns null when
  /// this platform or machine has no output to give it.
  ///
  /// A throw from [build] comes back as a throw from here. [controls], when
  /// given, must stay alive until [close] completes. [preferredFormat] is a
  /// wish: the device may pick another rate, which the builder then sees in
  /// its context.
  static Future<AudioProcessorOutput?> open(
    AudioProcessorBuilder build, {
    AudioControlBlock? controls,
    int preferredSampleRate = 48000,
    int preferredChannels = 2,
    int? preferredPeriodFrames,
    String debugName = 'dart_ui audio output',
  }) =>
      platform.openAudioProcessorOutput(
        build,
        controls: controls,
        preferredFormat: AudioFormat(
          sampleRate: preferredSampleRate,
          channels: preferredChannels,
          sampleFormat: AudioSampleFormat.float32,
        ),
        preferredPeriodFrames: preferredPeriodFrames,
        debugName: debugName,
      );

  /// Which system service renders it, for display: `WASAPI`, `Audio Queue`.
  final String backend;
  final int sampleRate;
  final int channels;
  final int periodFrames;

  /// About how long a change the processor makes takes to be heard.
  final Duration latency;

  /// What the builder put in [AudioOutputContext.details].
  final Map<String, Object?> details;

  late final Future<void> _done;
  Object? _error;
  final void Function() _stop;
  bool _closing = false;

  /// Completes when the output stops, by [close] or because the processor
  /// failed - [error] tells which.
  Future<void> get done => _done;

  /// Why the output stopped on its own, or null.
  Object? get error => _error;

  /// Stops the device and disposes the processor on its isolate.
  Future<void> close() {
    if (!_closing) {
      _closing = true;
      _stop();
    }
    return _done;
  }
}
