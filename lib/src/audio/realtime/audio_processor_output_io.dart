/// The native side of [AudioProcessorOutput]: one isolate per output.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../apple/audio_queue_processor_stream.dart';
import '../audio_device.dart';
import '../audio_format.dart';
import '../dsp/native_audio_processor.dart';
import '../windows/wasapi_backend.dart';
import '../windows/wasapi_render_stream.dart';
import 'audio_control_block.dart';
import 'audio_processor_output.dart';

/// An Audio Queue is fed from an isolate's event loop rather than a device
/// thread, so it gets at least this many frames per buffer, three buffers
/// deep: about 32 ms at 48 kHz.
const int _minimumQueuePeriod = 512;
const int _queueBufferCount = 3;

Future<AudioProcessorOutput?> openAudioProcessorOutput(
  AudioProcessorBuilder build, {
  required AudioControlBlock? controls,
  required AudioFormat preferredFormat,
  required int? preferredPeriodFrames,
  required String debugName,
}) async {
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isIOS) {
    return null;
  }
  final ReceivePort events = ReceivePort();
  final Completer<AudioProcessorOutput?> opened =
      Completer<AudioProcessorOutput?>();
  final Completer<Object?> finished = Completer<Object?>();
  void finish(Object? error) {
    events.close();
    if (!opened.isCompleted) {
      if (error == null) {
        opened.complete(null);
      } else {
        opened.completeError(error);
      }
    }
    if (!finished.isCompleted) finished.complete(error);
  }

  events.listen((Object? message) {
    if (message is! Map<Object?, Object?>) {
      // The isolate exited without saying why: it was killed or crashed.
      finish(opened.isCompleted ? null : StateError('audio isolate exited'));
      return;
    }
    switch (message['type']) {
      case 'unavailable':
        finish(null);
      case 'ready':
        final Object? stopHandle = message['stopHandle'];
        final Object? control = message['control'];
        opened.complete(AudioProcessorOutput.internal(
          backend: message['backend']! as String,
          sampleRate: message['sampleRate']! as int,
          channels: message['channels']! as int,
          periodFrames: message['periodFrames']! as int,
          latency: Duration(microseconds: message['latencyUs']! as int),
          details: Map<String, Object?>.unmodifiable(
              message['details']! as Map<String, Object?>),
          finished: finished.future,
          stop: () {
            if (stopHandle is int) {
              WasapiRenderStream.signalStopHandle(stopHandle);
            } else if (control is SendPort) {
              control.send('stop');
            }
          },
        ));
      case 'stopped':
        finish(null);
      case 'error':
        finish(StateError('${message['error']}'));
    }
  });
  try {
    await Isolate.spawn(
      _audioIsolate,
      <Object?>[
        events.sendPort,
        build,
        controls?.address ?? 0,
        preferredFormat.sampleRate,
        preferredFormat.channels,
        preferredPeriodFrames,
      ],
      onExit: events.sendPort,
      debugName: debugName,
    );
  } on Object {
    events.close();
    rethrow;
  }
  return opened.future;
}

void _audioIsolate(List<Object?> setup) {
  final SendPort events = setup[0]! as SendPort;
  final AudioProcessorBuilder build = setup[1]! as AudioProcessorBuilder;
  final int controlsAddress = setup[2]! as int;
  final int sampleRate = setup[3]! as int;
  final int channels = setup[4]! as int;
  final int? periodFrames = setup[5] as int?;
  if (Platform.isWindows) {
    _runWasapi(
        events, build, controlsAddress, sampleRate, channels, periodFrames);
  } else {
    _runAudioQueue(
        events, build, controlsAddress, sampleRate, channels, periodFrames);
  }
}

/// WASAPI waits on the device period, so this blocks the isolate until the
/// stop handle is signalled.
void _runWasapi(SendPort events, AudioProcessorBuilder build,
    int controlsAddress, int sampleRate, int channels, int? periodFrames) {
  WasapiRenderStream? stream;
  AudioControlBlock? controls;
  NativeFloat32AudioProcessor? processor;
  try {
    try {
      stream = WasapiAudioBackend().openStream(AudioStreamRequest(
        preferredFormat: AudioFormat(
          sampleRate: sampleRate,
          channels: channels,
          sampleFormat: AudioSampleFormat.float32,
        ),
        preferredPeriodFrames: periodFrames,
      ));
    } on Object {
      events.send(<String, Object?>{'type': 'unavailable'});
      return;
    }
    final AudioStreamConfiguration configuration = stream.configuration;
    controls =
        controlsAddress == 0 ? null : AudioControlBlock.attach(controlsAddress);
    final AudioOutputContext context = AudioOutputContext(
      sampleRate: configuration.format.sampleRate,
      channels: configuration.format.channels,
      periodFrames: configuration.periodFrames,
      controls: controls,
    );
    processor = build(context);
    events.send(<String, Object?>{
      'type': 'ready',
      'backend': 'WASAPI',
      'sampleRate': context.sampleRate,
      'channels': context.channels,
      'periodFrames': context.periodFrames,
      'latencyUs': configuration.streamLatency.inMicroseconds,
      'details': context.details,
      'stopHandle': stream.stopHandle,
    });
    stream.runWithProcessor(processor);
    events.send(<String, Object?>{'type': 'stopped'});
  } on Object catch (error, stack) {
    events.send(<String, Object?>{'type': 'error', 'error': '$error\n$stack'});
  } finally {
    processor?.dispose();
    controls?.dispose();
    stream?.dispose();
  }
}

/// The queue calls back through a listener, which keeps this isolate alive
/// until a stop message disposes it.
void _runAudioQueue(SendPort events, AudioProcessorBuilder build,
    int controlsAddress, int sampleRate, int channels, int? periodFrames) {
  AudioControlBlock? controls;
  NativeFloat32AudioProcessor? processor;
  try {
    controls =
        controlsAddress == 0 ? null : AudioControlBlock.attach(controlsAddress);
    final int period = (periodFrames ?? 0) < _minimumQueuePeriod
        ? _minimumQueuePeriod
        : periodFrames!;
    final AudioOutputContext context = AudioOutputContext(
      sampleRate: sampleRate,
      channels: channels,
      periodFrames: period,
      controls: controls,
    );
    processor = build(context);
    final AudioQueueProcessorStream? stream = AudioQueueProcessorStream.open(
      processor,
      periodFrames: period,
      bufferCount: _queueBufferCount,
    );
    if (stream == null) {
      processor.dispose();
      controls?.dispose();
      events.send(<String, Object?>{'type': 'unavailable'});
      return;
    }
    stream.start();
    if (!stream.isRunning) {
      // Created but not started: a Mac with no output device.
      stream.dispose();
      processor.dispose();
      controls?.dispose();
      events.send(<String, Object?>{'type': 'unavailable'});
      return;
    }
    final NativeFloat32AudioProcessor running = processor;
    final AudioControlBlock? attached = controls;
    final ReceivePort control = ReceivePort();
    control.listen((Object? _) {
      control.close();
      stream.dispose();
      running.dispose();
      attached?.dispose();
      events.send(<String, Object?>{'type': 'stopped'});
    });
    events.send(<String, Object?>{
      'type': 'ready',
      'backend': 'Audio Queue',
      'sampleRate': processor.sampleRate,
      'channels': processor.channels,
      'periodFrames': period,
      'latencyUs': stream.latency.inMicroseconds,
      'details': context.details,
      'control': control.sendPort,
    });
  } on Object catch (error, stack) {
    processor?.dispose();
    controls?.dispose();
    events.send(<String, Object?>{'type': 'error', 'error': '$error\n$stack'});
  }
}
