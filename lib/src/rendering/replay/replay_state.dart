/// The save/restore machine a display list walk carries.
///
/// A display list is a flat command stream, but the picture it describes is a
/// tree: `save` opens a scope, `restore` closes it, and every command in
/// between sees the transform and clip that scope established. This file is
/// that scope stack and nothing else - it knows about geometry, not about
/// opcodes - so the player above it stays a switch over commands and the
/// stack discipline can be tested on its own.
///
/// ## Why the stack is preallocated
///
/// Section 6.5 forbids allocation on the per-frame path, and `save`/`restore`
/// is the most frequent pair in a real frame: one per node with a transform, a
/// clip, or an opacity, so hundreds to thousands per frame. The stack is
/// therefore two fixed-length lists that are written by index and only ever
/// reallocated when a frame nests deeper than any frame before it. Steady
/// state is a store, an increment, and no garbage - see [stackGrowths], which
/// is the observable proof and stops increasing after the first few frames.
///
/// The saved values are immutable [Transform2D] and [Rect] objects rather than
/// unpacked doubles. Storing a reference costs no allocation, and it keeps all
/// the matrix arithmetic in the one place that is already tested for it;
/// unpacking six doubles per level would mean reimplementing `multiply` here
/// against the same component order, which is exactly the bug that is
/// expensive to find.
///
/// ## Policy on an unbalanced stream
///
/// Both directions of imbalance are errors, and neither is repaired:
///
///   * a `restore` with no matching `save` throws
///     [UnbalancedRestoreException] instead of underflowing the stack. There
///     is no sane recovery - the commands after it would run under a transform
///     that belongs to whoever called the player;
///   * a stream that ends with saves still open throws
///     [UnbalancedSaveException]. Silently unwinding at the end is the
///     tempting alternative and it is worse: the imbalance is always a bug in
///     the producer, it is invisible for as long as the list is played alone,
///     and it corrupts the picture the moment two lists are concatenated. With
///     `saveLayer` it would also mean a layer that is composited by nobody.
///
/// The player is what detects the second case, because only it knows the
/// stream has ended; [saveDepth] is what it checks.
library;

import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';

/// A violation of the save/restore discipline.
///
/// Separate from `DisplayListFormatException`, which means the bytes are not a
/// display list at all. These say the bytes decode fine and describe an
/// impossible picture - a distinction worth keeping, because the first points
/// at the transport and the second at the producer.
sealed class ReplayStateException implements Exception {
  const ReplayStateException();

  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when `restore` is executed with no `save` outstanding.
final class UnbalancedRestoreException extends ReplayStateException {
  const UnbalancedRestoreException({this.commandIndex, this.wordOffset});

  /// Position of the offending command, when the thrower knew it. [ReplayState]
  /// on its own does not; the player fills both in.
  final int? commandIndex;
  final int? wordOffset;

  @override
  String get message {
    final where = commandIndex == null
        ? ''
        : ' (command $commandIndex at word $wordOffset)';
    return 'restore with no matching save$where';
  }
}

/// Thrown when a stream ends with scopes still open.
final class UnbalancedSaveException extends ReplayStateException {
  const UnbalancedSaveException(this.outstandingSaves);

  final int outstandingSaves;

  @override
  String get message =>
      'display list ended with $outstandingSaves save(s) still open';
}

/// Current transform and clip, plus the stack that `save` and `restore` move.
///
/// One instance is meant to outlive many walks: [reset] rewinds it without
/// giving up the stack storage, the same arena trick the display list encoder
/// uses on its buffers.
final class ReplayState {
  ReplayState({int initialDepth = 16})
      : assert(initialDepth > 0),
        _transforms = List<Transform2D>.filled(
          initialDepth,
          Transform2D.identity,
        ),
        _clips = List<Rect>.filled(initialDepth, Rect.zero);

  List<Transform2D> _transforms;
  List<Rect> _clips;
  int _depth = 0;
  int _stackGrowths = 0;

  Transform2D _transform = Transform2D.identity;
  Rect _clip = Rect.zero;

  /// Maps the coordinates the commands are written in onto device pixels.
  Transform2D get transform => _transform;

  /// Device-space clip. Empty means nothing under this scope is visible; it
  /// can never become non-empty again, since clipping only ever intersects.
  Rect get clip => _clip;

  /// Scopes currently open. Zero at the start and, in a well-formed stream, at
  /// the end.
  int get saveDepth => _depth;

  /// Levels the stack can hold before it has to grow.
  int get stackCapacity => _transforms.length;

  /// How many times the stack has been reallocated since construction.
  ///
  /// Exposed for the same reason `DisplayList.bufferGrowths` is: it is the
  /// only way a test can assert that a frame which saves and restores
  /// hundreds of times allocates nothing while doing it.
  int get stackGrowths => _stackGrowths;

  /// Rewinds to a fresh walk over [deviceBounds] with [deviceTransform] as the
  /// root transform, keeping the stack storage.
  ///
  /// The root clip is the surface, not an infinite plane: everything outside
  /// it is unpaintable, so starting there lets the very first cull do its job
  /// instead of waiting for the first `clipRect`.
  void reset({
    required Rect deviceBounds,
    Transform2D deviceTransform = Transform2D.identity,
  }) {
    _transform = deviceTransform;
    _clip = deviceBounds;
    _depth = 0;
  }

  /// Opens a scope.
  void save() {
    if (_depth == _transforms.length) _grow();
    _transforms[_depth] = _transform;
    _clips[_depth] = _clip;
    _depth++;
  }

  /// Closes the innermost scope.
  ///
  /// Throws [UnbalancedRestoreException] rather than underflowing. The player
  /// checks [saveDepth] first so it can attach the command position; this
  /// guard is what protects every other caller.
  void restore() {
    if (_depth == 0) throw const UnbalancedRestoreException();
    _depth--;
    _transform = _transforms[_depth];
    _clip = _clips[_depth];
  }

  /// Concatenates [local] under the current transform.
  ///
  /// `this AFTER local`: the new matrix maps a point by applying [local]
  /// first, so coordinates written after this command are read in the frame
  /// the command just established. That is the canvas convention, and the
  /// reason it is spelled out is that the opposite order also compiles and
  /// only diverges once rotation meets translation.
  void concat(Transform2D local) => _transform = _transform.multiply(local);

  /// Intersects the clip with a rectangle that is already in device space.
  void clipDeviceRect(Rect deviceRect) => _clip = _clip.intersect(deviceRect);

  /// Device-space bounding box of a rectangle written in local coordinates.
  Rect deviceBoundsOf(Rect local) => _transform.transformRect(local);

  void _grow() {
    final int capacity = _transforms.length * 2;
    final List<Transform2D> transforms = List<Transform2D>.filled(
      capacity,
      Transform2D.identity,
    );
    transforms.setRange(0, _depth, _transforms);
    _transforms = transforms;
    final List<Rect> clips = List<Rect>.filled(capacity, Rect.zero);
    clips.setRange(0, _depth, _clips);
    _clips = clips;
    _stackGrowths++;
  }
}
