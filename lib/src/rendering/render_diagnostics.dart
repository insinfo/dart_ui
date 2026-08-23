/// "What happened in this frame?", asked cheaply enough to leave in.
///
/// The per-draw selector already produces a named reason for every decision -
/// `GpuPathStrategyDecision.reason` is a sentence, not a code - and until this
/// file existed there was nowhere for it to go. It was formatted into a
/// `toString` that nothing called, so the one piece of evidence that explains
/// a slow frame was produced and dropped on every draw.
///
/// ## The rule that shaped the API
///
/// Recording must cost nothing when it is off, and the enforceable form of
/// "nothing" is *no allocation*: not a counter object, not a snapshot, not a
/// formatted string. So:
///
///   * the disabled recorder is a `const` singleton whose methods have empty
///     bodies and which holds no state at all. Turning diagnostics off does
///     not mean skipping a `if (enabled)` at each call site - it means the
///     call is a no-op that the compiler can see through;
///   * every recording method takes primitives and enums the caller already
///     has. `recordDecision` takes the decision's own `reason` string, which
///     the selector built anyway; nothing is interpolated at a call site;
///   * the counting recorder keeps fixed-length arrays indexed by strategy, so
///     a frame with ten thousand draws allocates nothing either. Only
///     [RenderDiagnosticsRecorder.snapshot] allocates, and only when the
///     application asks.
///
/// `test/rendering/render_diagnostics_test.dart` holds all three to that: it
/// drives ten thousand records through the disabled recorder and asserts the
/// snapshot is still the same `const` object it started as.
library;

import 'gpu/gpu_path_strategy.dart';

/// How much the renderer records about its own decisions.
enum RenderDiagnosticsMode {
  /// Nothing. The default, and it costs nothing - see the library comment.
  off,

  /// Per-strategy draw counts, mask-cache hits and misses, and the last named
  /// reason for each strategy accepted or refused.
  ///
  /// Fixed cost per frame regardless of draw count: the counters are arrays
  /// indexed by strategy and the reasons are the selector's own strings.
  counters,
}

/// One frame's decisions, as an immutable value.
///
/// Allocated only by [RenderDiagnosticsRecorder.snapshot], which the
/// application calls when it wants to look. A frame that is never asked about
/// creates none of these.
final class FrameRenderDiagnostics {
  const FrameRenderDiagnostics({
    required this.drawsByStrategy,
    required this.reasonsByStrategy,
    required this.refusalsByStrategy,
    this.maskCacheHits = 0,
    this.maskCacheMisses = 0,
  });

  /// A frame in which nothing was recorded.
  ///
  /// `const`, and the value the disabled recorder returns every time, so a
  /// caller that snapshots unconditionally still allocates nothing.
  static const FrameRenderDiagnostics empty = FrameRenderDiagnostics(
    drawsByStrategy: <int>[0, 0, 0, 0, 0, 0],
    reasonsByStrategy: <String?>[null, null, null, null, null, null],
    refusalsByStrategy: <String?>[null, null, null, null, null, null],
  );

  /// Draw count per [GpuPathStrategy], indexed by `strategy.index`.
  final List<int> drawsByStrategy;

  /// The last reason each strategy was *selected*, indexed the same way.
  final List<String?> reasonsByStrategy;

  /// The last reason each strategy was *refused*, indexed the same way.
  ///
  /// A kill switch shows up here: `RenderPolicy.restrict` records
  /// `'disabled by RenderPolicy kill switch'` against every strategy it turns
  /// off, which is what makes bisecting a rendering bug in production an
  /// observation rather than a guess.
  final List<String?> refusalsByStrategy;

  final int maskCacheHits;
  final int maskCacheMisses;

  int drawsOf(GpuPathStrategy strategy) => drawsByStrategy[strategy.index];

  String? reasonFor(GpuPathStrategy strategy) =>
      reasonsByStrategy[strategy.index];

  String? refusalFor(GpuPathStrategy strategy) =>
      refusalsByStrategy[strategy.index];

  int get totalDraws {
    var total = 0;
    for (final int count in drawsByStrategy) {
      total += count;
    }
    return total;
  }

  /// True when nothing at all was recorded, which is what a frame that ran
  /// with [RenderDiagnosticsMode.off] always reports.
  bool get isEmpty =>
      totalDraws == 0 &&
      maskCacheHits == 0 &&
      maskCacheMisses == 0 &&
      refusalsByStrategy.every((String? reason) => reason == null);

  /// A multi-line report, one strategy per line, refusals included.
  ///
  /// Built on demand and never as part of recording: the reason strings are
  /// already in the arrays, so this is the only place they are joined.
  String describe() {
    final StringBuffer out = StringBuffer()
      ..writeln('frame: $totalDraws draws, mask cache $maskCacheHits hit / '
          '$maskCacheMisses miss');
    for (final GpuPathStrategy strategy in GpuPathStrategy.values) {
      final int count = drawsByStrategy[strategy.index];
      final String? reason = reasonsByStrategy[strategy.index];
      final String? refusal = refusalsByStrategy[strategy.index];
      if (count == 0 && refusal == null) continue;
      out.write('  ${strategy.name}: $count');
      if (reason != null) out.write(' - $reason');
      if (refusal != null) out.write(' [refused: $refusal]');
      out.writeln();
    }
    return out.toString();
  }

  @override
  String toString() => 'FrameRenderDiagnostics($totalDraws draws)';
}

/// Where a renderer sends what it decided.
///
/// Handed to the selector seam rather than reached through a global, so a test
/// can hold its own recorder and a backend cannot accidentally record into
/// somebody else's frame. [RenderPolicyScope] holds the application-wide one.
abstract interface class RenderDiagnosticsRecorder {
  /// A recorder that keeps nothing and allocates nothing. See the library
  /// comment for why this, and not a null check at each call site.
  static const RenderDiagnosticsRecorder disabled = _DisabledRecorder();

  /// A recorder that counts. One object, fixed-size arrays, no per-draw
  /// allocation.
  factory RenderDiagnosticsRecorder.counting() = _CountingRecorder;

  /// Builds the recorder [mode] asks for.
  factory RenderDiagnosticsRecorder.forMode(RenderDiagnosticsMode mode) =>
      switch (mode) {
        RenderDiagnosticsMode.off => disabled,
        RenderDiagnosticsMode.counters => _CountingRecorder(),
      };

  /// False for [disabled]. A caller with something expensive to compute *only*
  /// for diagnostics guards it with this; a caller that already holds the
  /// values does not need to.
  bool get isRecording;

  /// Clears the live counters. Called once per frame by whoever owns the
  /// frame; not calling it accumulates across frames, which is occasionally
  /// what a benchmark wants.
  void beginFrame();

  /// One draw went to [strategy], for [reason] - the selector's own sentence.
  void recordDecision(GpuPathStrategy strategy, String reason);

  /// [strategy] was available but not taken, or was taken away, for [reason].
  void recordRefusal(GpuPathStrategy strategy, String reason);

  /// The dense mask for a draw was already resident.
  void recordMaskCacheHit();

  /// The dense mask for a draw had to be rasterised and uploaded.
  void recordMaskCacheMiss();

  /// What has been recorded since the last [beginFrame].
  ///
  /// Allocates for a counting recorder; returns [FrameRenderDiagnostics.empty]
  /// for [disabled], the same instance every time.
  FrameRenderDiagnostics snapshot();
}

final class _DisabledRecorder implements RenderDiagnosticsRecorder {
  const _DisabledRecorder();

  @override
  bool get isRecording => false;

  @override
  void beginFrame() {}

  @override
  void recordDecision(GpuPathStrategy strategy, String reason) {}

  @override
  void recordRefusal(GpuPathStrategy strategy, String reason) {}

  @override
  void recordMaskCacheHit() {}

  @override
  void recordMaskCacheMiss() {}

  @override
  FrameRenderDiagnostics snapshot() => FrameRenderDiagnostics.empty;
}

final class _CountingRecorder implements RenderDiagnosticsRecorder {
  _CountingRecorder()
      : _draws = List<int>.filled(GpuPathStrategy.values.length, 0),
        _reasons = List<String?>.filled(GpuPathStrategy.values.length, null),
        _refusals = List<String?>.filled(GpuPathStrategy.values.length, null);

  final List<int> _draws;
  final List<String?> _reasons;
  final List<String?> _refusals;
  int _hits = 0;
  int _misses = 0;

  @override
  bool get isRecording => true;

  @override
  void beginFrame() {
    for (var i = 0; i < _draws.length; i++) {
      _draws[i] = 0;
      _reasons[i] = null;
      _refusals[i] = null;
    }
    _hits = 0;
    _misses = 0;
  }

  @override
  void recordDecision(GpuPathStrategy strategy, String reason) {
    _draws[strategy.index]++;
    // Last writer wins rather than a list: a frame draws thousands of paths
    // and a growing list of near-identical sentences is a leak with a report
    // attached. The distribution is in the counts; the sentence is an example.
    _reasons[strategy.index] = reason;
  }

  @override
  void recordRefusal(GpuPathStrategy strategy, String reason) =>
      _refusals[strategy.index] = reason;

  @override
  void recordMaskCacheHit() => _hits++;

  @override
  void recordMaskCacheMiss() => _misses++;

  @override
  FrameRenderDiagnostics snapshot() => FrameRenderDiagnostics(
        drawsByStrategy: List<int>.unmodifiable(_draws),
        reasonsByStrategy: List<String?>.unmodifiable(_reasons),
        refusalsByStrategy: List<String?>.unmodifiable(_refusals),
        maskCacheHits: _hits,
        maskCacheMisses: _misses,
      );
}
