/// Portable contracts for native audio devices and streams.
library;

import '../foundation/lifecycle.dart';
import 'audio_format.dart';

enum AudioDeviceDirection { output, input }

enum AudioDeviceRole { console, multimedia, communications }

enum AudioShareMode { shared, exclusive }

enum AudioStreamState { stopped, running, disposed }

/// A device exposed by a platform audio service.
final class AudioDeviceInfo {
  const AudioDeviceInfo({
    required this.id,
    required this.name,
    required this.direction,
    this.isDefault = false,
    this.isActive = true,
  });

  final String id;
  final String name;
  final AudioDeviceDirection direction;
  final bool isDefault;
  final bool isActive;
}

/// Desired stream properties. The backend reports the actual result in
/// [AudioStreamConfiguration].
final class AudioStreamRequest {
  const AudioStreamRequest({
    this.deviceId,
    this.direction = AudioDeviceDirection.output,
    this.role = AudioDeviceRole.multimedia,
    this.shareMode = AudioShareMode.shared,
    this.preferredFormat,
    this.preferredPeriodFrames,
  });

  final String? deviceId;
  final AudioDeviceDirection direction;
  final AudioDeviceRole role;
  final AudioShareMode shareMode;
  final AudioFormat? preferredFormat;
  final int? preferredPeriodFrames;
}

/// The format and buffering negotiated with the operating system.
final class AudioStreamConfiguration {
  const AudioStreamConfiguration({
    required this.format,
    required this.periodFrames,
    required this.bufferFrames,
    required this.streamLatency,
  });

  final AudioFormat format;
  final int periodFrames;
  final int bufferFrames;
  final Duration streamLatency;
}

/// An error returned by a platform audio service.
final class AudioBackendException implements Exception {
  const AudioBackendException(this.operation, this.message, {this.code});

  final String operation;
  final String message;
  final int? code;

  @override
  String toString() {
    final String suffix = code == null
        ? ''
        : ' (0x${code!.toUnsigned(32).toRadixString(16).padLeft(8, '0')})';
    return 'AudioBackendException: $operation: $message$suffix';
  }
}

/// Lifecycle common to native input and output streams.
///
/// Sample transfer is intentionally not part of this portable interface: a
/// realtime implementation uses native pointers, which are unavailable on the
/// web. Native applications import `package:dart_ui/audio.dart` for that API.
abstract interface class AudioStream implements Disposable {
  AudioStreamConfiguration get configuration;
  AudioStreamState get state;
  void start();
  void stop();
}

/// A platform audio service. Calls are synchronous so callers can create and
/// drive a native stream wholly inside one dedicated isolate.
abstract interface class AudioBackend {
  String get id;
  String get name;
  bool get isAvailable;

  List<AudioDeviceInfo> enumerateDevices({
    AudioDeviceDirection direction = AudioDeviceDirection.output,
    AudioDeviceRole role = AudioDeviceRole.multimedia,
  });

  AudioStream openStream(AudioStreamRequest request);
}
