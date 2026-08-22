/// Key auto-repeat for Wayland, where the client does the repeating.
///
/// X11 servers and Win32 repeat keys for you; a Wayland compositor does not.
/// It tells the client the user's setting once - `wl_keyboard.repeat_info`
/// with a rate in characters per second and an initial delay in milliseconds -
/// and every client synthesises its own repeats. This class is that machine,
/// kept pure: time is an argument, never a clock, so a test can play a whole
/// repeat run in microseconds and assert the exact cadence.
///
/// One key repeats at a time, which is exactly xkb's model: pressing a second
/// repeating key replaces the first (type `aaaa`, press `s` while holding `a`,
/// and it is `s` that repeats). Releasing a key that is not the repeating one
/// changes nothing.
library;

/// The repeating state machine. The owner feeds it presses, releases, focus
/// changes and the current time; it answers with how many repeats are due.
final class WaylandKeyRepeat {
  /// Repeats per second, from `repeat_info`. Zero disables repeat, which is
  /// what the protocol means by a zero rate.
  int _rateHz = 25;

  /// Milliseconds a key must stay down before the first repeat.
  int _delayMilliseconds = 400;

  int get rateHz => _rateHz;
  int get delayMilliseconds => _delayMilliseconds;

  /// The evdev keycode currently armed, or -1.
  int _armedKey = -1;

  /// The wl_surface the armed press was delivered to; repeats carry it so a
  /// focus change between press and repeat cannot leak keys elsewhere.
  int _armedSurfaceId = 0;

  /// When the *next* repeat is due, in the caller's clock.
  int _nextDueMilliseconds = 0;

  bool get isArmed => _armedKey >= 0;
  int get armedKey => _armedKey;
  int get armedSurfaceId => _armedSurfaceId;

  /// Applies `wl_keyboard.repeat_info`. A change takes effect from the next
  /// press; re-arming mid-hold for a settings change is not worth the state.
  void configure({required int rateHz, required int delayMilliseconds}) {
    _rateHz = rateHz < 0 ? 0 : rateHz;
    _delayMilliseconds = delayMilliseconds < 0 ? 0 : delayMilliseconds;
    if (_rateHz == 0) cancel();
  }

  /// Arms [key] pressed at [nowMilliseconds] on [surfaceId], replacing any
  /// previously armed key. A disabled rate arms nothing.
  void onKeyDown(int key, int surfaceId, int nowMilliseconds) {
    if (_rateHz <= 0) {
      cancel();
      return;
    }
    _armedKey = key;
    _armedSurfaceId = surfaceId;
    _nextDueMilliseconds = nowMilliseconds + _delayMilliseconds;
  }

  /// Disarms when [key] is the repeating key. Any other release is one of the
  /// keys the user is *also* holding, and must not stop the repeat.
  void onKeyUp(int key) {
    if (_armedKey == key) cancel();
  }

  /// Disarms unconditionally - keyboard focus left, the window died, the
  /// connection dropped. A repeat delivered after any of those would be the
  /// classic stuck-key bug.
  void cancel() {
    _armedKey = -1;
    _armedSurfaceId = 0;
    _nextDueMilliseconds = 0;
  }

  /// Milliseconds until the next repeat is due, or null when disarmed. Zero
  /// when overdue. This is what the event pump clamps its poll timeout to.
  int? millisecondsUntilDue(int nowMilliseconds) {
    if (!isArmed) return null;
    final remaining = _nextDueMilliseconds - nowMilliseconds;
    return remaining < 0 ? 0 : remaining;
  }

  /// How many repeats have become due by [nowMilliseconds], advancing the
  /// schedule past them. At most [maximumBurst], so a laptop waking from
  /// sleep types a bounded burst instead of a screenful.
  int takeDueRepeats(int nowMilliseconds, {int maximumBurst = 8}) {
    if (!isArmed || _rateHz <= 0) return 0;
    if (nowMilliseconds < _nextDueMilliseconds) return 0;
    final intervalMilliseconds = 1000 ~/ _rateHz == 0 ? 1 : 1000 ~/ _rateHz;
    var due =
        1 + (nowMilliseconds - _nextDueMilliseconds) ~/ intervalMilliseconds;
    if (due > maximumBurst) {
      due = maximumBurst;
      // Skip the backlog entirely: repeats older than the burst window are
      // lost time, not owed keystrokes.
      _nextDueMilliseconds = nowMilliseconds + intervalMilliseconds;
    } else {
      _nextDueMilliseconds += due * intervalMilliseconds;
    }
    return due;
  }

  @override
  String toString() => 'WaylandKeyRepeat(rate: ${_rateHz}Hz, '
      'delay: ${_delayMilliseconds}ms, '
      'armed: ${isArmed ? 'key $_armedKey' : 'no'})';
}
