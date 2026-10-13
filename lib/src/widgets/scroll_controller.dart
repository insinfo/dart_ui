// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/widgets/scroll_controller.dart):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Flutter's `ScrollController`, over this framework's [ScrollPosition].
///
/// ## Two things a `controller:` takes
///
/// Scroll views here have always been driven by a [ScrollPosition] passed as
/// `controller:`, and Flutter code passes a [ScrollController]. Both work,
/// because the parameter's type is [ScrollPositionSource], which both
/// implement:
///
///  * a [ScrollController] creates one [ScrollPosition] for every scroll view
///    it is given to, follows them in [positions], and forwards their changes
///    to its own listeners - Flutter's model, unchanged;
///  * a [ScrollPosition] drives the one view it is given to directly, and its
///    own axis wins over the view's.
///
/// A position cannot itself *be* a [ScrollController]: it lives in the layout
/// layer, below the clock that `animateTo` needs, and that layering is the
/// one rule here that is not negotiable. A shared interface is what is left,
/// and the cost is that the field's static type is not `ScrollController?`:
/// code that *reads* `listView.controller` gets a [ScrollPositionSource].
library;

import '../animation/curves.dart';
import '../foundation/change_notifier.dart';
import '../layout/render_viewport.dart';
import 'scroll_view.dart' show ScrollPositionAnimation;

/// Signature of [ScrollController.onAttach] and [ScrollController.onDetach].
typedef ScrollControllerCallback = void Function(ScrollPosition position);

/// Controls one or more scroll views: reads and sets their offset, animates
/// it, and notifies its listeners whenever any of them moves.
///
/// ```dart
/// final ScrollController controller = ScrollController();
/// controller.addListener(() {
///   if (controller.position.extentAfter < 500) loadMore();
/// });
/// ListView.builder(controller: controller, itemCount: n, itemBuilder: ...);
/// // later
/// controller.animateTo(0, duration: Duration(milliseconds: 300),
///     curve: Curves.easeOut);
/// ```
///
/// Differences from Flutter: [createScrollPosition] takes the axis and the
/// previous position (there is no `ScrollContext`, and physics belong to the
/// scroll view); `keepScrollOffset` is accepted and has no effect, since there
/// is no `PageStorage` to keep an offset across a view rebuilt from scratch.
class ScrollController extends ChangeNotifier implements ScrollPositionSource {
  ScrollController({
    double initialScrollOffset = 0.0,
    this.keepScrollOffset = true,
    this.debugLabel,
    this.onAttach,
    this.onDetach,
  }) : _initialScrollOffset = initialScrollOffset;

  /// The offset a scroll view starts at the first time it is attached.
  double get initialScrollOffset => _initialScrollOffset;
  final double _initialScrollOffset;

  /// Whether the offset is saved to `PageStorage` and restored from it. There
  /// is no `PageStorage` here, so this has no effect; a view that replaces
  /// its position (a new controller, a new axis) keeps its offset either way,
  /// as in Flutter.
  final bool keepScrollOffset;

  /// A name for this controller in [toString].
  final String? debugLabel;

  /// Called after a position is attached.
  final ScrollControllerCallback? onAttach;

  /// Called after a position is detached.
  final ScrollControllerCallback? onDetach;

  final List<ScrollPosition> _positions = <ScrollPosition>[];

  /// The positions of the scroll views this controller is attached to.
  Iterable<ScrollPosition> get positions => _positions;

  /// Whether any scroll view is attached. Read [position] and [offset] only
  /// when this is true.
  bool get hasClients => _positions.isNotEmpty;

  /// The position of the one attached scroll view.
  ///
  /// Throws a [StateError] when none or more than one is attached - use
  /// [positions] for a controller shared by several.
  ScrollPosition get position {
    if (_positions.isEmpty) {
      throw StateError(
        'ScrollController${_label()} is not attached to any scroll views; '
        'check hasClients first.',
      );
    }
    if (_positions.length > 1) {
      throw StateError(
        'ScrollController${_label()} is attached to ${_positions.length} '
        'scroll views; use positions.',
      );
    }
    return _positions.single;
  }

  /// The offset of the one attached scroll view.
  double get offset => position.pixels;

  /// Animates every attached position to [offset], clamped to its range.
  ///
  /// The future completes when all of them have stopped: at the target, or
  /// where a drag or another animation interrupted them. A view with no
  /// dispatcher (no clock) jumps instead.
  Future<void> animateTo(
    double offset, {
    required Duration duration,
    required Curve curve,
  }) async {
    await Future.wait<void>(<Future<void>>[
      for (final ScrollPosition position in List<ScrollPosition>.of(_positions))
        position.animateTo(offset, duration: duration, curve: curve),
    ]);
  }

  /// Jumps every attached position to [value], clamped to its range, and
  /// stops any fling or animation running on it.
  void jumpTo(double value) {
    for (final ScrollPosition position in List<ScrollPosition>.of(_positions)) {
      position.jumpTo(value);
    }
  }

  /// Starts following [position]: its changes are this controller's.
  void attach(ScrollPosition position) {
    if (_positions.contains(position)) return;
    _positions.add(position);
    position.addListener(notifyListeners);
    onAttach?.call(position);
  }

  /// Stops following [position].
  void detach(ScrollPosition position) {
    if (!_positions.remove(position)) return;
    position.removeListener(notifyListeners);
    onDetach?.call(position);
  }

  /// Creates the position for a scroll view along [axis]. [oldPosition] is
  /// the one the same view drove before - under this controller or another -
  /// and its offset is carried over, as Flutter's position absorbs the one it
  /// replaces; otherwise the view starts at [initialScrollOffset]. Override
  /// to return a configured position.
  ScrollPosition createScrollPosition(
    ScrollAxis axis,
    ScrollPosition? oldPosition,
  ) =>
      ScrollPosition(
        axis: axis,
        pixels: oldPosition?.pixels ?? initialScrollOffset,
        debugLabel: debugLabel,
      );

  @override
  ScrollPosition attachScrollable(
    ScrollAxis axis, {
    ScrollPosition? oldPosition,
  }) {
    final ScrollPosition position = createScrollPosition(axis, oldPosition);
    attach(position);
    return position;
  }

  @override
  void detachScrollable(ScrollPosition position) => detach(position);

  @override
  void dispose() {
    for (final ScrollPosition position in _positions) {
      position.removeListener(notifyListeners);
    }
    super.dispose();
  }

  String _label() => debugLabel == null ? '' : ' ($debugLabel)';

  @override
  String toString() {
    final String clients = _positions.isEmpty
        ? 'no clients'
        : _positions.length == 1
            ? 'one client, offset ${offset.toStringAsFixed(1)}'
            : '${_positions.length} clients';
    return '$runtimeType#${identityHashCode(this).toRadixString(16)}'
        '${_label()}($clients)';
  }
}

/// Keeps the [ScrollPosition] a scroll view drives in step with the view's
/// `controller:` and axis.
///
/// What every scroll view here does with its controller, written once: with
/// no controller it makes its own [ScrollController], as Flutter's
/// `Scrollable` does; a new controller or a new axis detaches the old
/// position and attaches a new one, keeping the offset; disposal detaches.
/// Public for scroll views written outside the framework.
final class ScrollPositionAttachment {
  ScrollPositionAttachment();

  ScrollController? _fallback;
  ScrollPositionSource? _source;
  ScrollAxis? _axis;
  ScrollPosition? _position;

  /// The position attached by the last [update].
  ScrollPosition get position {
    final ScrollPosition? position = _position;
    if (position == null) {
      throw StateError('ScrollPositionAttachment.update was never called');
    }
    return position;
  }

  /// The position for [controller] along [axis], attaching a new one if
  /// either changed since the last call.
  ScrollPosition update(ScrollPositionSource? controller, ScrollAxis axis) {
    final ScrollPositionSource source =
        controller ?? (_fallback ??= ScrollController());
    final ScrollPosition? old = _position;
    if (old != null &&
        identical(source, _source) &&
        (axis == _axis || source is ScrollPosition)) {
      return old;
    }
    if (old != null) _source!.detachScrollable(old);
    final ScrollPosition position =
        source.attachScrollable(axis, oldPosition: old);
    _source = source;
    _axis = axis;
    _position = position;
    final ScrollController? fallback = _fallback;
    if (fallback != null && !identical(fallback, source)) {
      fallback.dispose();
      _fallback = null;
    }
    return position;
  }

  /// Detaches the position and disposes the controller made for it.
  void dispose() {
    final ScrollPosition? position = _position;
    if (position != null) _source?.detachScrollable(position);
    _position = null;
    _source = null;
    _fallback?.dispose();
    _fallback = null;
  }
}
