/// Window metrics and platform preferences published to a widget subtree.
///
/// A render tree already receives the window size as its root constraint, but
/// constraints only flow through render objects. Widgets that choose a layout,
/// avoid a system inset or select a resolution need the same information while
/// they build. [MediaQuery] is that widget-layer view of one window.
///
/// The shape follows Flutter's per-view `MediaQueryData`, with one important
/// boundary: this framework exposes only values its platform contract can
/// currently report. Size and device-pixel ratio are live, and so are the
/// desktop-wide preferences - [MediaQueryData.platformBrightness],
/// [MediaQueryData.highContrast], [MediaQueryData.disableAnimations] and
/// [MediaQueryData.textScaleFactor] - which the application copies from its
/// `SystemSettings` into every window and refreshes when the platform reports
/// a change. Safe padding and keyboard insets may be overridden by a nested
/// query until the native backends grow corresponding events.
library;

import 'dart:math' as math;

import '../geometry/size.dart';
import '../layout/edge_insets.dart';
import '../platform/system_settings.dart';
import 'widget.dart';

/// Whether the current window is wider than it is tall.
enum Orientation { portrait, landscape }

/// Immutable media information for one window.
final class MediaQueryData {
  const MediaQueryData({
    this.size = Size.zero,
    this.devicePixelRatio = 1.0,
    this.textScaleFactor = 1.0,
    this.padding = EdgeInsets.zero,
    this.viewPadding = EdgeInsets.zero,
    this.viewInsets = EdgeInsets.zero,
    this.accessibleNavigation = false,
    this.highContrast = false,
    this.disableAnimations = false,
    this.boldText = false,
    this.platformBrightness = Brightness.light,
  })  : assert(devicePixelRatio > 0),
        assert(textScaleFactor > 0);

  /// The client area in logical pixels.
  final Size size;

  /// Physical pixels per logical pixel for this window's render surface.
  final double devicePixelRatio;

  /// The user's preferred multiplier for text.
  final double textScaleFactor;

  /// Safe space not obscured by either system UI or [viewInsets].
  final EdgeInsets padding;

  /// Safe space independent of temporary obstructions such as a keyboard.
  final EdgeInsets viewPadding;

  /// Fully obscured space, most commonly an on-screen keyboard.
  final EdgeInsets viewInsets;

  final bool accessibleNavigation;
  final bool highContrast;
  final bool disableAnimations;
  final bool boldText;

  /// Whether the desktop is in light or dark mode.
  ///
  /// The *platform's* preference, which is not necessarily the brightness of
  /// the theme in force: an application may pin a dark theme on a light
  /// desktop. A widget that wants to follow the system reads this and picks
  /// its theme from it; because the application rebuilds every window's query
  /// when the setting changes, that widget follows it live. Light when the
  /// platform did not say, which is also what every test sees.
  final Brightness platformBrightness;

  Orientation get orientation =>
      size.width > size.height ? Orientation.landscape : Orientation.portrait;

  MediaQueryData copyWith({
    Size? size,
    double? devicePixelRatio,
    double? textScaleFactor,
    EdgeInsets? padding,
    EdgeInsets? viewPadding,
    EdgeInsets? viewInsets,
    bool? accessibleNavigation,
    bool? highContrast,
    bool? disableAnimations,
    bool? boldText,
    Brightness? platformBrightness,
  }) =>
      MediaQueryData(
        size: size ?? this.size,
        devicePixelRatio: devicePixelRatio ?? this.devicePixelRatio,
        textScaleFactor: textScaleFactor ?? this.textScaleFactor,
        padding: padding ?? this.padding,
        viewPadding: viewPadding ?? this.viewPadding,
        viewInsets: viewInsets ?? this.viewInsets,
        accessibleNavigation: accessibleNavigation ?? this.accessibleNavigation,
        highContrast: highContrast ?? this.highContrast,
        disableAnimations: disableAnimations ?? this.disableAnimations,
        boldText: boldText ?? this.boldText,
        platformBrightness: platformBrightness ?? this.platformBrightness,
      );

  /// Returns data in which selected safe-padding edges have been consumed.
  ///
  /// [viewPadding] is reduced by the amount consumed rather than blindly set
  /// to zero. That is what keeps nested safe areas from applying the same inset
  /// twice while preserving any larger, unconsumed view padding.
  MediaQueryData removePadding({
    bool removeLeft = false,
    bool removeTop = false,
    bool removeRight = false,
    bool removeBottom = false,
  }) {
    if (!(removeLeft || removeTop || removeRight || removeBottom)) return this;
    return copyWith(
      padding: _copyEdges(
        padding,
        left: removeLeft ? 0 : null,
        top: removeTop ? 0 : null,
        right: removeRight ? 0 : null,
        bottom: removeBottom ? 0 : null,
      ),
      viewPadding: _copyEdges(
        viewPadding,
        left: removeLeft
            ? math.max(0, viewPadding.left - padding.left).toDouble()
            : null,
        top: removeTop
            ? math.max(0, viewPadding.top - padding.top).toDouble()
            : null,
        right: removeRight
            ? math.max(0, viewPadding.right - padding.right).toDouble()
            : null,
        bottom: removeBottom
            ? math.max(0, viewPadding.bottom - padding.bottom).toDouble()
            : null,
      ),
    );
  }

  /// Returns data in which selected fully-obscured edges have been consumed.
  MediaQueryData removeViewInsets({
    bool removeLeft = false,
    bool removeTop = false,
    bool removeRight = false,
    bool removeBottom = false,
  }) {
    if (!(removeLeft || removeTop || removeRight || removeBottom)) return this;
    return copyWith(
      viewPadding: _copyEdges(
        viewPadding,
        left: removeLeft
            ? math.max(0, viewPadding.left - viewInsets.left).toDouble()
            : null,
        top: removeTop
            ? math.max(0, viewPadding.top - viewInsets.top).toDouble()
            : null,
        right: removeRight
            ? math.max(0, viewPadding.right - viewInsets.right).toDouble()
            : null,
        bottom: removeBottom
            ? math.max(0, viewPadding.bottom - viewInsets.bottom).toDouble()
            : null,
      ),
      viewInsets: _copyEdges(
        viewInsets,
        left: removeLeft ? 0 : null,
        top: removeTop ? 0 : null,
        right: removeRight ? 0 : null,
        bottom: removeBottom ? 0 : null,
      ),
    );
  }

  /// Returns data in which selected persistent view-padding edges are gone.
  MediaQueryData removeViewPadding({
    bool removeLeft = false,
    bool removeTop = false,
    bool removeRight = false,
    bool removeBottom = false,
  }) {
    if (!(removeLeft || removeTop || removeRight || removeBottom)) return this;
    return copyWith(
      padding: _copyEdges(
        padding,
        left: removeLeft ? 0 : null,
        top: removeTop ? 0 : null,
        right: removeRight ? 0 : null,
        bottom: removeBottom ? 0 : null,
      ),
      viewPadding: _copyEdges(
        viewPadding,
        left: removeLeft ? 0 : null,
        top: removeTop ? 0 : null,
        right: removeRight ? 0 : null,
        bottom: removeBottom ? 0 : null,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaQueryData &&
      other.size == size &&
      other.devicePixelRatio == devicePixelRatio &&
      other.textScaleFactor == textScaleFactor &&
      other.padding == padding &&
      other.viewPadding == viewPadding &&
      other.viewInsets == viewInsets &&
      other.accessibleNavigation == accessibleNavigation &&
      other.highContrast == highContrast &&
      other.disableAnimations == disableAnimations &&
      other.boldText == boldText &&
      other.platformBrightness == platformBrightness;

  @override
  int get hashCode => Object.hash(
        size,
        devicePixelRatio,
        textScaleFactor,
        padding,
        viewPadding,
        viewInsets,
        accessibleNavigation,
        highContrast,
        disableAnimations,
        boldText,
        platformBrightness,
      );

  @override
  String toString() => 'MediaQueryData($size @ $devicePixelRatio, '
      'padding: $padding, viewInsets: $viewInsets, '
      '${platformBrightness.name})';
}

EdgeInsets _copyEdges(
  EdgeInsets value, {
  double? left,
  double? top,
  double? right,
  double? bottom,
}) =>
    EdgeInsets(
      left ?? value.left,
      top ?? value.top,
      right ?? value.right,
      bottom ?? value.bottom,
    );

/// Thrown when a widget asks for window media outside a [MediaQuery].
final class MissingMediaQueryError extends Error {
  MissingMediaQueryError(this.requestedBy);

  final String requestedBy;

  @override
  String toString() => 'No MediaQuery ancestor found for $requestedBy.\n'
      'Window size, scale and safe insets are scoped per window. Applications '
      'started with runApp install this scope automatically; isolated widget '
      'trees should wrap their root in MediaQuery(data: ..., child: ...).\n'
      'Use MediaQuery.maybeOf only when the absence is intentional.';
}

/// Publishes [data] to descendants.
final class MediaQuery extends InheritedWidget {
  const MediaQuery({
    super.key,
    required this.data,
    required super.child,
  });

  factory MediaQuery.removePadding({
    Key? key,
    required BuildContext context,
    bool removeLeft = false,
    bool removeTop = false,
    bool removeRight = false,
    bool removeBottom = false,
    required Widget child,
  }) =>
      MediaQuery(
        key: key,
        data: of(context).removePadding(
          removeLeft: removeLeft,
          removeTop: removeTop,
          removeRight: removeRight,
          removeBottom: removeBottom,
        ),
        child: child,
      );

  factory MediaQuery.removeViewInsets({
    Key? key,
    required BuildContext context,
    bool removeLeft = false,
    bool removeTop = false,
    bool removeRight = false,
    bool removeBottom = false,
    required Widget child,
  }) =>
      MediaQuery(
        key: key,
        data: of(context).removeViewInsets(
          removeLeft: removeLeft,
          removeTop: removeTop,
          removeRight: removeRight,
          removeBottom: removeBottom,
        ),
        child: child,
      );

  factory MediaQuery.removeViewPadding({
    Key? key,
    required BuildContext context,
    bool removeLeft = false,
    bool removeTop = false,
    bool removeRight = false,
    bool removeBottom = false,
    required Widget child,
  }) =>
      MediaQuery(
        key: key,
        data: of(context).removeViewPadding(
          removeLeft: removeLeft,
          removeTop: removeTop,
          removeRight: removeRight,
          removeBottom: removeBottom,
        ),
        child: child,
      );

  final MediaQueryData data;

  static MediaQueryData of(BuildContext context) {
    final MediaQueryData? data = maybeOf(context);
    if (data == null) {
      throw MissingMediaQueryError('${context.widget.runtimeType}');
    }
    return data;
  }

  static MediaQueryData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaQuery>()?.data;

  static Size sizeOf(BuildContext context) => of(context).size;
  static Size? maybeSizeOf(BuildContext context) => maybeOf(context)?.size;
  static double widthOf(BuildContext context) => sizeOf(context).width;
  static double heightOf(BuildContext context) => sizeOf(context).height;
  static double devicePixelRatioOf(BuildContext context) =>
      of(context).devicePixelRatio;
  static EdgeInsets paddingOf(BuildContext context) => of(context).padding;
  static EdgeInsets viewPaddingOf(BuildContext context) =>
      of(context).viewPadding;
  static EdgeInsets viewInsetsOf(BuildContext context) =>
      of(context).viewInsets;
  static Orientation orientationOf(BuildContext context) =>
      of(context).orientation;

  /// The desktop's light or dark preference; see
  /// [MediaQueryData.platformBrightness].
  ///
  /// Depends on the whole query, as every accessor here does: this framework's
  /// [MediaQuery] is a plain inherited widget, not Flutter's aspect-keyed
  /// `InheritedModel`, so a widget that reads only the brightness still
  /// rebuilds when the window is resized. Read it low in the tree, or below a
  /// widget that caches its subtree, where that matters.
  static Brightness platformBrightnessOf(BuildContext context) =>
      of(context).platformBrightness;

  /// [platformBrightnessOf], or null outside any [MediaQuery] - a widget test
  /// that mounted a tree without one.
  static Brightness? maybePlatformBrightnessOf(BuildContext context) =>
      maybeOf(context)?.platformBrightness;

  static bool highContrastOf(BuildContext context) => of(context).highContrast;
  static bool disableAnimationsOf(BuildContext context) =>
      of(context).disableAnimations;

  @override
  bool updateShouldNotify(MediaQuery oldWidget) => data != oldWidget.data;
}
