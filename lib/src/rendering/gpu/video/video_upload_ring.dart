/// Which buffer the next frame may be written into, and which are still in
/// flight.
///
/// A tiny amount of bookkeeping guarding a bug that is very hard to see. The
/// GPU reads a texture at some point after the draw call that named it was
/// recorded, not during it. A producer that writes the next frame into the
/// same texture wins that race often enough to look correct in a still image
/// and loses it often enough to produce a frame whose top half is one moment
/// and whose bottom half is the next - a tear that only appears under load,
/// only on some drivers, and that no golden test will ever catch.
///
/// The Vulkan path in this repository hit exactly this class of bug from the
/// other direction: a staging cursor that rewound and overwrote bytes a draw
/// had already been recorded against (see
/// `rendering/gpu/vulkan/vulkan_sparse_executor.dart`). The lesson taken here
/// is the same one: the structure that hands out storage must know what is
/// still in flight, and it must **refuse** rather than wrap around silently.
/// [VideoUploadRing.acquire] throws [VideoUploadStalled]; it never returns a
/// buffer somebody may still be reading.
///
/// ## What "retired" means, and who says it
///
/// This class cannot know when the GPU finished - that answer lives in a fence,
/// a query, a swap chain's frame index or, in the simplest backends, a
/// `glFinish`. So it is *told*, through [VideoUploadRing.retire], and it only
/// ever accepts being told about newer frames: a retire that moves backwards
/// is the same rewinding cursor in another costume and is refused with an
/// error that names it.
///
/// The ring is deliberately backend-neutral and holds no device object, which
/// is what makes its whole state machine testable without a driver.
library;

/// Raised when every buffer of a ring is still in flight.
///
/// Carries the numbers a caller needs to fix it rather than only the fact:
/// which sequence was asked for, what the ring has retired through, and how
/// many buffers it has. The two fixes are "retire what the GPU finished" and
/// "allocate another buffer", and which one applies is visible from those.
final class VideoUploadStalled implements Exception {
  const VideoUploadStalled({
    required this.sequence,
    required this.bufferCount,
    required this.retiredThrough,
    required this.oldestInFlight,
  });

  final int sequence;
  final int bufferCount;
  final int retiredThrough;
  final int oldestInFlight;

  @override
  String toString() =>
      'VideoUploadStalled: frame #$sequence has nowhere to go. All '
      '$bufferCount buffers are still in flight; the oldest holds '
      '#$oldestInFlight and the ring has retired through #$retiredThrough. '
      'Either retire the frames the GPU has finished with, or create the '
      'streaming texture with a larger bufferCount.';
}

/// Rotates [bufferCount] buffers over a stream of frames.
final class VideoUploadRing {
  VideoUploadRing({required this.bufferCount}) {
    if (bufferCount < 1) {
      throw ArgumentError.value(
        bufferCount,
        'bufferCount',
        'a ring needs at least one buffer',
      );
    }
    _sequences = List<int>.filled(bufferCount, _free);
  }

  /// One buffer: correct, and synchronous. Every upload after the first
  /// stalls until the previous frame is retired, which is exactly what a
  /// caller that reads back immediately wants and exactly what a caller
  /// driving a display does not.
  static const int singleBuffered = 1;

  /// The working default. One buffer being written while one is being read.
  static const int doubleBuffered = 2;

  /// For a driver that keeps a frame in flight past the next present.
  static const int tripleBuffered = 3;

  final int bufferCount;

  static const int _free = -1;

  /// Sequence held by each buffer, or [_free].
  late final List<int> _sequences;

  int _front = -1;
  int _frontSequence = -1;
  int _retiredThrough = -1;
  int _nextCandidate = 0;
  int _acquiredBuffer = -1;

  /// The buffer a draw should sample, or -1 before the first [present].
  int get frontBuffer => _front;

  /// The sequence [frontBuffer] holds, or -1.
  int get frontSequence => _frontSequence;

  /// Everything at or below this has been declared finished by the caller.
  int get retiredThrough => _retiredThrough;

  /// Buffers holding a frame that has not been retired.
  int get inFlightCount {
    var count = 0;
    for (final int sequence in _sequences) {
      if (sequence != _free) count++;
    }
    return count;
  }

  /// Whether an [acquire] is currently open and awaiting [present].
  bool get hasOpenAcquire => _acquiredBuffer >= 0;

  /// The sequence held by buffer [buffer], or -1 when it is free.
  int sequenceOf(int buffer) => _sequences[buffer];

  /// Reserves a buffer for frame [sequence].
  ///
  /// The reservation stays open until [present] or [abandon]: a partially
  /// written buffer is not a buffer anything may sample, and leaving the ring
  /// to work that out from a later call is how a half-uploaded frame reaches
  /// the screen once in a thousand runs.
  ///
  /// Throws [VideoUploadStalled] when nothing is free, [StateError] when an
  /// acquire is already open, and [ArgumentError] when [sequence] does not
  /// move forward - a stream whose sequence repeats or goes backwards cannot
  /// be reasoned about by anything downstream, including [retire].
  int acquire(int sequence) {
    if (_acquiredBuffer >= 0) {
      throw StateError(
        'buffer $_acquiredBuffer is already acquired for frame '
        '#${_sequences[_acquiredBuffer]}; present or abandon it before '
        'acquiring another',
      );
    }
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence', 'must not be negative');
    }
    if (sequence <= _frontSequence) {
      throw ArgumentError.value(
        sequence,
        'sequence',
        'must be newer than the front frame #$_frontSequence; a sequence '
            'that repeats or moves backwards makes "still in flight" '
            'unanswerable',
      );
    }

    // Round-robin from where the last acquire left off rather than "first
    // free". Round-robin keeps a buffer unused for as long as possible after
    // it retires, which is the margin that absorbs a driver retiring a frame
    // slightly later than the caller thinks it did.
    for (var step = 0; step < bufferCount; step++) {
      final int candidate = (_nextCandidate + step) % bufferCount;
      if (_sequences[candidate] != _free) continue;
      _sequences[candidate] = sequence;
      _acquiredBuffer = candidate;
      _nextCandidate = (candidate + 1) % bufferCount;
      return candidate;
    }

    var oldest = _sequences[0];
    for (final int held in _sequences) {
      if (held < oldest) oldest = held;
    }
    throw VideoUploadStalled(
      sequence: sequence,
      bufferCount: bufferCount,
      retiredThrough: _retiredThrough,
      oldestInFlight: oldest,
    );
  }

  /// Declares the open acquire finished and makes it the front buffer.
  void present(int buffer) {
    if (_acquiredBuffer != buffer) {
      throw StateError(
        'buffer $buffer is not the acquired one ($_acquiredBuffer)',
      );
    }
    _front = buffer;
    _frontSequence = _sequences[buffer];
    _acquiredBuffer = -1;
  }

  /// Gives an acquired buffer back without presenting it.
  ///
  /// For the upload that threw halfway: the buffer holds nothing anybody
  /// should sample, and leaving it marked in flight would leak a slot per
  /// failure until the ring stalls permanently.
  void abandon(int buffer) {
    if (_acquiredBuffer != buffer) {
      throw StateError(
        'buffer $buffer is not the acquired one ($_acquiredBuffer)',
      );
    }
    _sequences[buffer] = _free;
    _acquiredBuffer = -1;
    _nextCandidate = buffer;
  }

  /// Declares every frame at or below [sequence] finished by the GPU.
  ///
  /// The front buffer is freed by this like any other, which is correct: the
  /// caller is saying the GPU is done reading it. It stays *the front buffer*
  /// - [frontBuffer] keeps naming it, so a draw issued before the next upload
  /// still samples the right pixels - it simply becomes eligible for reuse.
  ///
  /// Moving backwards is refused. A caller whose fence bookkeeping wrapped or
  /// reset must say so with [reset] rather than by retiring an older number,
  /// because "retire through an older frame" is indistinguishable from
  /// "un-retire", and the reading that lets a buffer be reused early is the
  /// one that corrupts a frame.
  void retire(int sequence) {
    if (sequence < _retiredThrough) {
      throw ArgumentError.value(
        sequence,
        'sequence',
        'the ring has already retired through #$_retiredThrough; retiring '
            'backwards would hand out a buffer that is still being read. Use '
            'reset() if the stream restarted',
      );
    }
    _retiredThrough = sequence;
    for (var i = 0; i < bufferCount; i++) {
      if (i == _acquiredBuffer) continue;
      final int held = _sequences[i];
      if (held != _free && held <= sequence) _sequences[i] = _free;
    }
  }

  /// Retires everything, including the front frame.
  ///
  /// What a caller that just blocked on the device - a `glFinish`, a fence
  /// wait on the last submission - is entitled to say.
  void retireAll() {
    if (_frontSequence >= 0) retire(_frontSequence);
  }

  /// Forgets every frame. For a stream that restarted, and for device loss,
  /// where nothing in flight is in flight any more because the queue is gone.
  void reset() {
    for (var i = 0; i < bufferCount; i++) {
      _sequences[i] = _free;
    }
    _front = -1;
    _frontSequence = -1;
    _retiredThrough = -1;
    _nextCandidate = 0;
    _acquiredBuffer = -1;
  }

  @override
  String toString() => 'VideoUploadRing($bufferCount buffers, front $_front '
      '(#$_frontSequence), retired through #$_retiredThrough, '
      '$inFlightCount in flight)';
}
