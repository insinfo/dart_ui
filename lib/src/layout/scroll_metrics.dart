// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/painting/basic_types.dart,
// packages/flutter/lib/src/rendering/viewport_offset.dart and
// packages/flutter/lib/src/widgets/scroll_metrics.dart):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// What a scroll looks like from outside: Flutter's `ScrollMetrics`, and the
/// two enums it is written in.
///
/// A scroll notification carries a *snapshot* of these numbers, not the live
/// position, so a listener that keeps one sees the scroll as it was when the
/// notification was sent. `ScrollPosition` mixes [ScrollMetrics] in, which is
/// how the live object and the snapshot answer the same questions with the
/// same arithmetic.
library;

import 'dart:math' as math;

import '../text/shaper.dart' show TextDirection;
import 'render_flex.dart' show Axis;

/// A direction along either the horizontal or vertical [Axis] in which the
/// origin, or zero position, is determined.
///
/// [down] is the ordinary vertical scroll view: offset zero at the top, the
/// content growing downwards. A reversed vertical view is [up].
enum AxisDirection {
  /// Zero at the bottom, positive values going up.
  up,

  /// Zero on the left, positive values going right.
  right,

  /// Zero at the top, positive values going down.
  down,

  /// Zero on the right, positive values going left.
  left,
}

/// The [Axis] of [axisDirection].
Axis axisDirectionToAxis(AxisDirection axisDirection) =>
    switch (axisDirection) {
      AxisDirection.up || AxisDirection.down => Axis.vertical,
      AxisDirection.left || AxisDirection.right => Axis.horizontal,
    };

/// The [AxisDirection] in which reading proceeds in [textDirection].
AxisDirection textDirectionToAxisDirection(TextDirection textDirection) =>
    switch (textDirection) {
      TextDirection.rightToLeft => AxisDirection.left,
      TextDirection.leftToRight => AxisDirection.right,
    };

/// The opposite of [axisDirection].
AxisDirection flipAxisDirection(AxisDirection axisDirection) =>
    switch (axisDirection) {
      AxisDirection.up => AxisDirection.down,
      AxisDirection.right => AxisDirection.left,
      AxisDirection.down => AxisDirection.up,
      AxisDirection.left => AxisDirection.right,
    };

/// Whether [axisDirection] runs against the reading direction of its axis:
/// [AxisDirection.up] or [AxisDirection.left].
bool axisDirectionIsReversed(AxisDirection axisDirection) =>
    switch (axisDirection) {
      AxisDirection.up || AxisDirection.left => true,
      AxisDirection.down || AxisDirection.right => false,
    };

/// The direction in which the user is trying to change the scroll offset.
///
/// [forward] is towards offset zero - a finger dragged down a vertical list,
/// a wheel turned away from the user - and [reverse] towards the end, which
/// is Flutter's meaning of both words.
enum ScrollDirection {
  /// Not scrolling, or scrolling not driven by the user.
  idle,

  /// Towards offset zero.
  forward,

  /// Away from offset zero.
  reverse,
}

/// The opposite of [direction]; [ScrollDirection.idle] stays idle.
ScrollDirection flipScrollDirection(ScrollDirection direction) =>
    switch (direction) {
      ScrollDirection.idle => ScrollDirection.idle,
      ScrollDirection.forward => ScrollDirection.reverse,
      ScrollDirection.reverse => ScrollDirection.forward,
    };

/// A description of a scrollable's contents, useful for modeling the state
/// of its viewport.
///
/// The three extents are what a "load more" listener reads:
/// [extentBefore] is how much content is scrolled off the leading edge,
/// [extentInside] how much is visible, [extentAfter] how much is left.
mixin ScrollMetrics {
  /// A copy of these metrics with the given fields replaced: a snapshot that
  /// no longer follows the scroll.
  ScrollMetrics copyWith({
    double? minScrollExtent,
    double? maxScrollExtent,
    double? pixels,
    double? viewportDimension,
    AxisDirection? axisDirection,
    double? devicePixelRatio,
  }) =>
      FixedScrollMetrics(
        minScrollExtent: minScrollExtent ??
            (hasContentDimensions ? this.minScrollExtent : null),
        maxScrollExtent: maxScrollExtent ??
            (hasContentDimensions ? this.maxScrollExtent : null),
        pixels: pixels ?? (hasPixels ? this.pixels : null),
        viewportDimension: viewportDimension ??
            (hasViewportDimension ? this.viewportDimension : null),
        axisDirection: axisDirection ?? this.axisDirection,
        devicePixelRatio: devicePixelRatio ?? this.devicePixelRatio,
      );

  /// The minimum in-range value for [pixels].
  double get minScrollExtent;

  /// The maximum in-range value for [pixels].
  double get maxScrollExtent;

  /// Whether [minScrollExtent] and [maxScrollExtent] are known.
  bool get hasContentDimensions;

  /// The current scroll offset.
  double get pixels;

  /// Whether [pixels] is known.
  bool get hasPixels;

  /// The extent of the viewport along the [axis].
  double get viewportDimension;

  /// Whether [viewportDimension] is known.
  bool get hasViewportDimension;

  /// The direction in which the scroll offset increases.
  AxisDirection get axisDirection;

  /// The axis in which the scroll view scrolls.
  Axis get axis => axisDirectionToAxis(axisDirection);

  /// Whether [pixels] is outside `[minScrollExtent, maxScrollExtent]`.
  bool get outOfRange => pixels < minScrollExtent || pixels > maxScrollExtent;

  /// Whether [pixels] is exactly at [minScrollExtent] or [maxScrollExtent].
  bool get atEdge => pixels == minScrollExtent || pixels == maxScrollExtent;

  /// How much content is scrolled off the leading edge.
  double get extentBefore => math.max(pixels - minScrollExtent, 0.0);

  /// How much of the viewport shows content: the whole viewport, less any
  /// overscroll at either end.
  double get extentInside {
    return viewportDimension -
        (minScrollExtent - pixels).clamp(0.0, viewportDimension) -
        (pixels - maxScrollExtent).clamp(0.0, viewportDimension);
  }

  /// How much content is left past the trailing edge.
  double get extentAfter => math.max(maxScrollExtent - pixels, 0.0);

  /// The total extent of the content, viewport included.
  double get extentTotal =>
      maxScrollExtent - minScrollExtent + viewportDimension;

  /// The ratio of physical to logical pixels the content is drawn at.
  double get devicePixelRatio;
}

/// An immutable snapshot of [ScrollMetrics].
class FixedScrollMetrics with ScrollMetrics {
  FixedScrollMetrics({
    required double? minScrollExtent,
    required double? maxScrollExtent,
    required double? pixels,
    required double? viewportDimension,
    required this.axisDirection,
    required this.devicePixelRatio,
  })  : _minScrollExtent = minScrollExtent,
        _maxScrollExtent = maxScrollExtent,
        _pixels = pixels,
        _viewportDimension = viewportDimension;

  final double? _minScrollExtent;
  final double? _maxScrollExtent;
  final double? _pixels;
  final double? _viewportDimension;

  @override
  double get minScrollExtent => _known(_minScrollExtent, 'minScrollExtent');

  @override
  double get maxScrollExtent => _known(_maxScrollExtent, 'maxScrollExtent');

  @override
  bool get hasContentDimensions =>
      _minScrollExtent != null && _maxScrollExtent != null;

  @override
  double get pixels => _known(_pixels, 'pixels');

  @override
  bool get hasPixels => _pixels != null;

  @override
  double get viewportDimension =>
      _known(_viewportDimension, 'viewportDimension');

  @override
  bool get hasViewportDimension => _viewportDimension != null;

  @override
  final AxisDirection axisDirection;

  @override
  final double devicePixelRatio;

  static double _known(double? value, String name) {
    if (value == null) {
      throw StateError(
        '$name is not known yet: the scroll view has not been laid out. '
        'Check has$name-style getters (hasPixels, hasContentDimensions, '
        'hasViewportDimension) before reading it.',
      );
    }
    return value;
  }

  @override
  String toString() =>
      !hasPixels || !hasContentDimensions || !hasViewportDimension
          ? 'FixedScrollMetrics(not laid out)'
          : 'FixedScrollMetrics('
              '${extentBefore.toStringAsFixed(1)}..['
              '${extentInside.toStringAsFixed(1)}]..'
              '${extentAfter.toStringAsFixed(1)})';
}
