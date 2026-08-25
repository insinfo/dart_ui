/// Turns "frames handed to the endpoint" into "frames the device has played".
library;

/// The frame accounting behind [MediaClock.position] for a WASAPI render pass.
///
/// ## Why a cursor over the clip is not the answer by itself
///
/// The obvious clock is the read cursor of the thing filling the buffer -
/// `NativePcmClipPlayer.positionFrames`. It is pull-driven, so it does only
/// advance when the device asks for more, and that is most of what is wanted.
/// What it is not is *where the needle is*: everything the pump has written is
/// still sitting in the endpoint buffer waiting to be played, so the cursor
/// runs ahead of the sound by up to one full buffer - 10 to 30 ms on a typical
/// shared-mode engine. Lip sync at that offset is visible, and worse, it is a
/// constant offset that looks like a bug in the video path.
///
/// ## What is actually known at a wakeup
///
/// [WasapiRenderStream.renderAvailableWith] asks the client for
/// `GetCurrentPadding`, hands the processor every writable frame, and releases
/// all of them - so on return the endpoint is full again and the frames it was
/// given are exactly `bufferFrames - padding`. That inverts: the padding at the
/// moment of the wakeup is `bufferFrames - rendered`, and the total the device
/// has consumed is everything released so far minus that padding. No extra COM
/// call and no second clock are involved.
///
/// ## The origin, and why silence is counted
///
/// `WasapiRenderStream.start` primes the endpoint with `bufferFrames` of
/// silence before starting the engine, so the first frames the device consumes
/// are not media. Rather than special-case that, the priming is counted as
/// released like anything else and an *origin* records the released count at
/// which the current media segment began. Position is then
/// `originFrame + (consumed - originReleased)`, floored at `originFrame`: while
/// the priming silence drains the difference is negative and the clock sits
/// still at the origin, which is the truthful answer - the media has not
/// started. The same mechanism covers a restart after a pause or a seek, where
/// the endpoint is primed again and the origin moves to the new media frame.
final class EndpointRenderClock {
  EndpointRenderClock({required this.bufferFrames}) {
    if (bufferFrames <= 0) {
      throw RangeError.value(bufferFrames, 'bufferFrames', 'must be positive');
    }
  }

  /// The endpoint buffer size reported by `IAudioClient::GetBufferSize`.
  final int bufferFrames;

  int _released = 0;
  int _originReleased = 0;
  int _originFrame = 0;
  int _positionFrames = 0;

  /// The media frame the device is playing, as of the last [onRendered].
  int get positionFrames => _positionFrames;

  /// Total frames released to the endpoint since the last [restart].
  int get releasedFrames => _released;

  /// Frames written but not yet played, as of the last [onRendered].
  ///
  /// This is what a pause has to give back: it is still queued in the endpoint
  /// and `IAudioClient::Reset` is about to throw it away.
  int get inFlightFrames {
    final int flight =
        _released - _originReleased - (_positionFrames - _originFrame);
    return flight < 0 ? 0 : flight;
  }

  /// Rebases the clock on a stream that has just been started and primed with
  /// [bufferFrames] of silence, with [originFrame] as the media frame the next
  /// render will begin at.
  void restart(int originFrame) {
    _released = bufferFrames;
    _originReleased = _released;
    _originFrame = originFrame;
    _positionFrames = originFrame;
  }

  /// Records one engine wakeup that handed [renderedFrames] to the processor,
  /// and returns the media frame the device is playing right now.
  int onRendered(int renderedFrames) {
    if (renderedFrames <= 0) return _positionFrames;
    final int padding = bufferFrames - renderedFrames;
    final int consumed = _released - padding;
    _released += renderedFrames;
    final int advance = consumed - _originReleased;
    _positionFrames = advance <= 0 ? _originFrame : _originFrame + advance;
    return _positionFrames;
  }
}

/// Converts a frame count in [sampleRate] to a wall duration.
///
/// Integer arithmetic on microseconds, deliberately: a double seconds value
/// loses a microsecond of resolution somewhere past an hour of playback, and
/// this number is the one a video player compares frame timestamps against.
Duration framesToDuration(int frames, int sampleRate) {
  if (sampleRate <= 0) {
    throw RangeError.value(sampleRate, 'sampleRate', 'must be positive');
  }
  if (frames <= 0) return Duration.zero;
  return Duration(
    microseconds: frames * Duration.microsecondsPerSecond ~/ sampleRate,
  );
}

/// Converts a wall duration to a frame count in [sampleRate], rounded down.
int durationToFrames(Duration time, int sampleRate) {
  if (sampleRate <= 0) {
    throw RangeError.value(sampleRate, 'sampleRate', 'must be positive');
  }
  if (time <= Duration.zero) return 0;
  return time.inMicroseconds * sampleRate ~/ Duration.microsecondsPerSecond;
}
