// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/widgets/notification_listener.dart):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Notifications that bubble up the widget tree: Flutter's `Notification` and
/// `NotificationListener`.
///
/// The opposite direction to an inherited widget. An inherited widget hands a
/// value *down* to whoever asks; a notification is sent *up* from a location
/// and every [NotificationListener] above it, nearest first, may look at it
/// and stop it. Scroll views send `ScrollNotification`s this way, which is
/// how a widget learns that the list below it scrolled without holding the
/// list's controller.
library;

import 'package:meta/meta.dart';

import 'element.dart';
import 'widget.dart';

/// Signature of [NotificationListener.onNotification]: return true to stop
/// the notification, false to let it continue to the listeners above.
typedef NotificationListenerCallback<T extends Notification> = bool Function(
  T notification,
);

/// A notification that can bubble up the widget tree.
///
/// Subclass it, and [dispatch] an instance from a [BuildContext]; every
/// [NotificationListener] of a matching type above that context sees it,
/// nearest first, until one returns true.
abstract class Notification {
  const Notification();

  /// Offers this notification to [element], an ancestor of where it was
  /// dispatched. Returns false to stop the walk.
  ///
  /// Subclasses override it to learn about the path - scroll notifications
  /// count the scroll views they pass to compute their depth - and must call
  /// the inherited method.
  @protected
  @mustCallSuper
  bool visitAncestor(Element element) {
    final Widget widget = element.widget;
    if (widget is NotificationListener<Notification>) {
      if (widget._dispatch(this, element)) return false;
    }
    return true;
  }

  /// Starts bubbling this notification at [target], which is usually the
  /// `context` of the widget sending it. A null target does nothing.
  ///
  /// The walk starts at [target]'s parent, and at [target] itself only when
  /// it is a [NotificationListener]: a listener hears what is dispatched
  /// from its own context.
  void dispatch(BuildContext? target) {
    if (target == null || !target.mounted) return;
    if (target is Element &&
        target.widget is NotificationListener<Notification> &&
        !visitAncestor(target)) {
      return;
    }
    target.visitAncestorElements(visitAncestor);
  }

  @override
  String toString() => '$runtimeType';
}

/// Listens for [Notification]s of type [T] bubbling up from its subtree.
///
/// ```dart
/// NotificationListener<ScrollEndNotification>(
///   onNotification: (ScrollEndNotification notification) {
///     save(notification.metrics.pixels);
///     return false; // let the listeners above hear it too
///   },
///   child: ListView.builder(...),
/// )
/// ```
class NotificationListener<T extends Notification> extends StatelessWidget {
  const NotificationListener({
    super.key,
    required this.child,
    this.onNotification,
  });

  /// The subtree whose notifications are heard.
  final Widget child;

  /// Called for every notification of type [T] from [child]'s subtree.
  /// Returning true stops it; false lets it reach the listeners above.
  final NotificationListenerCallback<T>? onNotification;

  bool _dispatch(Notification notification, Element element) {
    final NotificationListenerCallback<T>? onNotification = this.onNotification;
    if (onNotification != null && notification is T) {
      return onNotification(notification);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => child;
}
