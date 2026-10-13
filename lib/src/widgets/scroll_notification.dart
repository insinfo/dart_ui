// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/widgets/scroll_notification.dart and
// scroll_metrics.dart's notification):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Scroll notifications, as Flutter sends them.
///
/// Every scroll view here sends, from its own context:
///
///  * [ScrollStartNotification] when a scroll begins - a drag, a fling, an
///    `animateTo`, or a one-off movement such as a wheel notch, a key or a
///    `jumpTo`, each of which is a scroll of its own;
///  * [ScrollUpdateNotification] for every movement, with the drag's details
///    when a finger or the mouse caused it;
///  * [OverscrollNotification] when a movement hit an edge during a scroll;
///  * [ScrollEndNotification] when the scroll is over;
///  * [UserScrollNotification] when the direction the user scrolls in
///    changes, and back to idle at the end;
///  * [ScrollMetricsNotification] after layout changed the viewport or the
///    content extent, posted to the scroll view's dispatcher (none is sent
///    when the view has no dispatcher).
///
/// [ScrollNotification.depth] counts the scroll views between the one that
/// sent it and the listener: zero is "my own child", which is what
/// [defaultScrollNotificationPredicate] accepts.
library;

import '../gestures/drag.dart';
import '../layout/scroll_metrics.dart';
import 'element.dart';
import 'notification_listener.dart';
import 'scroll_view.dart' show Scrollable;
import 'widget.dart';

/// A [Notification] that a layout changed: a scroll moved, a size changed.
abstract class LayoutChangedNotification extends Notification {
  const LayoutChangedNotification();
}

/// Counts the scroll views a notification passes on its way up.
mixin ViewportNotificationMixin on Notification {
  /// How many scroll views lie between the one that sent this notification
  /// and the listener that sees it. Zero for the listener directly around
  /// the scroll view.
  int get depth => _depth;
  int _depth = 0;

  @override
  bool visitAncestor(Element element) {
    if (element.widget is Scrollable) _depth += 1;
    return super.visitAncestor(element);
  }
}

/// A [Notification] about a scroll view's scrolling.
abstract class ScrollNotification extends LayoutChangedNotification
    with ViewportNotificationMixin {
  ScrollNotification({required this.metrics, required this.context});

  /// A snapshot of the scroll as it was when this was sent.
  final ScrollMetrics metrics;

  /// The scroll view's build context: where the notification came from.
  final BuildContext? context;

  @override
  String toString() =>
      '$runtimeType(depth: $depth${depth == 0 ? ' (local)' : ''}, $metrics)';
}

/// A scroll began.
class ScrollStartNotification extends ScrollNotification {
  ScrollStartNotification({
    required super.metrics,
    required super.context,
    this.dragDetails,
  });

  /// The drag that started it; null when it was not a drag.
  final DragStartDetails? dragDetails;
}

/// The scroll offset changed.
class ScrollUpdateNotification extends ScrollNotification {
  ScrollUpdateNotification({
    required super.metrics,
    required super.context,
    this.dragDetails,
    this.scrollDelta,
    int? depth,
  }) {
    if (depth != null) _depth = depth;
  }

  /// The drag movement that caused this update; null for a fling, an
  /// animation, the wheel or the keyboard.
  final DragUpdateDetails? dragDetails;

  /// How far the offset moved, in logical pixels.
  final double? scrollDelta;
}

/// A movement during a scroll was not applied because the content was at an
/// edge.
class OverscrollNotification extends ScrollNotification {
  OverscrollNotification({
    required super.metrics,
    required super.context,
    this.dragDetails,
    required this.overscroll,
    this.velocity = 0.0,
  }) {
    if (overscroll.isNaN || overscroll == 0) {
      throw ArgumentError.value(
        overscroll,
        'overscroll',
        'must be a non-zero number',
      );
    }
  }

  /// The drag that pushed against the edge, if one did.
  final DragUpdateDetails? dragDetails;

  /// How far past the edge the movement wanted to go: negative at the start,
  /// positive at the end.
  final double overscroll;

  /// The velocity of a fling that hit the edge, in pixels per second; zero
  /// for a drag.
  final double velocity;
}

/// A scroll ended.
class ScrollEndNotification extends ScrollNotification {
  ScrollEndNotification({
    required super.metrics,
    required super.context,
    this.dragDetails,
  });

  /// The drag whose release ended it; null when the scroll ended otherwise
  /// (a fling coming to rest, an animation finishing).
  final DragEndDetails? dragDetails;
}

/// The direction the user scrolls in changed.
class UserScrollNotification extends ScrollNotification {
  UserScrollNotification({
    required super.metrics,
    required super.context,
    required this.direction,
  });

  /// [ScrollDirection.forward] towards offset zero,
  /// [ScrollDirection.reverse] away from it, [ScrollDirection.idle] when the
  /// scroll is over.
  final ScrollDirection direction;
}

/// A predicate on [ScrollNotification]s, for a widget that should react only
/// to some scroll views below it.
typedef ScrollNotificationPredicate = bool Function(
  ScrollNotification notification,
);

/// Accepts only notifications from the nearest scroll view below
/// ([ScrollNotification.depth] zero).
bool defaultScrollNotificationPredicate(ScrollNotification notification) =>
    notification.depth == 0;

/// The viewport or the content of a scroll view changed size, without the
/// offset moving.
class ScrollMetricsNotification extends Notification
    with ViewportNotificationMixin {
  ScrollMetricsNotification({required this.metrics, required this.context});

  final ScrollMetrics metrics;

  final BuildContext context;

  /// This notification as a [ScrollUpdateNotification] with no movement,
  /// for code that reacts to both the same way.
  ScrollUpdateNotification asScrollUpdate() => ScrollUpdateNotification(
        metrics: metrics,
        context: context,
        depth: depth,
      );

  @override
  String toString() => 'ScrollMetricsNotification(depth: $depth, $metrics)';
}
