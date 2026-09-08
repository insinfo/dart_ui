/// The application's own slider in the operating system's volume mixer.
///
/// ## Why this is a capability and not a method on [AudioStream]
///
/// Session volume is not portable, and the honest shape for something that is
/// not portable is a capability a backend either offers or does not - the
/// `is SomeInterface` test this repository already uses for optional
/// presenter behaviour in `lib/src/app/window_host.dart`.
///
///   * **Windows / WASAPI** has it: `ISimpleAudioVolume` on the audio session,
///     which is the row the user sees under this application's name in the
///     volume mixer. Implemented, in `windows/wasapi_session_volume.dart`.
///   * **PulseAudio and PipeWire** have per-stream volume and could implement
///     this, and there is no backend for either here yet.
///   * **ALSA** has no session concept at all. There is no per-application
///     volume to expose; a mixer element belongs to the *card*, and moving it
///     would turn every other application down too.
///   * **CoreAudio** has no real per-application volume on macOS. The
///     per-application sliders users remember are third-party software that
///     inserts a driver.
///
/// A method on [AudioStream] would have to answer somehow on all four, and
/// the two available answers are both worse than not having the method: a
/// silent no-op, which makes a control that appears to work and does nothing,
/// or a fallback to stream gain, which is a different thing wearing the same
/// name - one is inside our process and invisible to the user, the other is
/// the operating system's and visible to everyone.
///
/// So a caller discovers it, and a caller that demands it gets a refusal that
/// names the backend and the reason. See [AudioSessionVolumes.require].
library;

import 'audio_device.dart';

/// Read and write this application's volume in the operating system's mixer.
///
/// Implemented by a backend's stream type when the platform has a
/// per-application volume concept. Obtain it with [AudioSessionVolumes.of] or
/// [AudioSessionVolumes.require] rather than by naming a backend class.
///
/// ## This is not stream gain, and the differences are observable
///
///   * The user can change it, from the operating system's own user interface,
///     at any time - so a read can return something this application never
///     wrote.
///   * It persists across runs. The operating system remembers where the
///     slider was left for this application.
///   * It applies to the whole audio session, which is every stream this
///     process opened, not to one stream.
///   * It is not exact. Windows applies its own curve between the number here
///     and the pixels of the slider, and the audio engine's own resampling and
///     mixing sit between this and the endpoint. Nothing here can promise
///     bit-identical passthrough at 1.0 the way `AudioGain` can, because the
///     samples pass through code this framework does not own.
///
/// Use `AudioStream.gain` when the application wants a level of its own that
/// nothing else can move. Use this when the user should be able to find this
/// application in the mixer and turn it down.
abstract interface class AudioSessionVolume {
  /// The session's level, a linear amplitude in 0..1.
  ///
  /// Linear amplitude because that is what the platform stores -
  /// `ISimpleAudioVolume` documents its level as a value in that range and
  /// scales samples by it. `AudioGain.decibels(x).factor` converts, for a
  /// caller that thinks in decibels.
  double get sessionVolume;

  /// Sets the session's level. Values outside 0..1 are clamped, because the
  /// platform rejects them and a rejected write would leave the level at
  /// whatever it happened to be.
  set sessionVolume(double value);

  /// Whether the session is muted in the operating system's mixer.
  ///
  /// Separate from a level of zero, and the platform keeps them separate:
  /// unmuting restores the level that was set, so a caller that muted by
  /// writing zero has destroyed the value the user chose.
  bool get sessionMuted;

  set sessionMuted(bool value);
}

/// Raised when a caller demands a capability the audio backend does not have.
///
/// An [Error] rather than an exception, and the same shape as
/// `UnsupportedCapabilityError` in `lib/src/foundation/diagnostics.dart`:
/// reaching it means the caller asked for something it had not established was
/// possible, which is a bug in the caller rather than a missing library on the
/// machine.
///
/// It is not in that class because [Capability] there is a *window backend*
/// vocabulary - windows, presentation, input, clipboard - and its own
/// documentation records what happened the last time a subsystem borrowed the
/// nearest value from it: the renderer refused a glyph atlas and printed
/// "vulkan does not support gpuPresentation", sending readers to debug a
/// swapchain that was working. Audio is a third axis and gets its own
/// sentence.
final class AudioCapabilityError extends Error {
  AudioCapabilityError({
    required this.backendName,
    required this.capability,
    this.detail,
  });

  /// The backend or stream that was asked, named as the caller would
  /// recognise it.
  final String backendName;

  /// What was asked for - `session volume`, not an enum value that had to be
  /// stretched to fit.
  final String capability;

  /// Why it is not there: the platform's own limitation, or the fact that no
  /// backend has been written for it here yet.
  final String? detail;

  @override
  String toString() => 'AudioCapabilityError: $backendName does not provide '
      '$capability${detail == null ? '' : ' ($detail)'}';
}

/// Discovering, or demanding, session volume on a stream.
abstract final class AudioSessionVolumes {
  /// The session-volume control of [stream], or null when its backend has
  /// none.
  ///
  /// Null is the discovery answer and it is a normal one: a caller with a
  /// volume slider in its own user interface hides it, or falls back to
  /// `AudioStream.gain` *knowingly* and tells the user which one it is showing.
  static AudioSessionVolume? of(AudioStream stream) {
    // The cast is not redundant: Dart 3.6 does not promote a variable across
    // two unrelated interface types, so `stream` stays an [AudioStream] here
    // even inside the `is`.
    if (stream is AudioSessionVolume) return stream as AudioSessionVolume;
    return null;
  }

  /// The session-volume control of [stream], or a named refusal.
  ///
  /// For a caller that has already decided it needs the operating system's own
  /// slider and for which stream gain is not a substitute - a media
  /// application's mixer entry, say. The refusal names the stream and the
  /// reason, so the failure reads as "this platform has no per-application
  /// volume" rather than as a null dereference three frames later.
  static AudioSessionVolume require(AudioStream stream) {
    final AudioSessionVolume? volume = of(stream);
    if (volume != null) return volume;
    throw AudioCapabilityError(
      backendName: stream.runtimeType.toString(),
      capability: 'session volume',
      detail: 'this backend does not implement AudioSessionVolume; see '
          'kAudioSessionVolumeUnimplemented for why, per platform',
    );
  }
}

/// Platforms whose session volume this framework does not implement, and why.
///
/// The point is that a reader can tell "not needed" from "not noticed": every
/// line here is a decision, in the shape `kMetalDeliberatelyUnbound` uses in
/// `lib/src/rendering/gpu/metal/metal_bindings.dart` for the Metal surface
/// this renderer deliberately does not bind.
///
/// Two of these lines say "the platform has no such concept" and two say "no
/// backend exists here yet". They are different states and a future
/// implementer needs to be able to tell them apart before spending an
/// afternoon looking for an API that does not exist.
const Map<String, String> kAudioSessionVolumeUnimplemented = <String, String>{
  'ALSA': 'the platform has no session concept at all: a mixer element belongs '
      'to the card, so writing one would turn every other application down '
      'too. There is nothing to implement, only something not to fake',
  'CoreAudio (macOS)':
      'there is no real per-application volume; kAudioHardwareServiceDevice'
          'Property_VirtualMasterVolume is the *device* volume, and the '
          'per-application sliders users remember come from third-party '
          'software that installs a driver',
  'PulseAudio': 'has per-stream volume through pa_context_set_sink_input_'
      'volume and could implement this. Not done because there is no '
      'PulseAudio AudioBackend in this repository yet',
  'PipeWire':
      'has per-node volume and could implement this. Not done because there '
          'is no PipeWire AudioBackend in this repository yet',
  'Web Audio':
      'a GainNode is stream gain by another name, inside the page, and there '
          'is no browser API for this tab\'s row in the host operating '
          'system\'s mixer. AudioGain already covers what is achievable',
};
