// Adapted from Flutter, packages/flutter/lib/src/material/theme.dart.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The Material `Theme` widget.
library;

import '../platform/system_settings.dart' show Brightness;
import '../widgets/icon.dart' show IconTheme;
import '../widgets/theme.dart' as dui;
import '../widgets/widget.dart';
import 'theme_data.dart';

/// Which of an app's themes to use - Flutter's `ThemeMode`.
enum ThemeMode {
  /// Follow the platform's light or dark setting.
  system,
  light,
  dark,
}

/// Publishes a Material [ThemeData] to a subtree - Flutter's `Theme`.
///
/// Installs dart_ui's theme too, as [ThemeData.dartUiTheme], so dart_ui's
/// own controls under it take the Material colours; the styles, resources and
/// templates of the dart_ui theme above are kept. And it sets the ambient
/// [IconTheme] to [ThemeData.iconTheme], as Flutter's does.
class Theme extends StatelessWidget {
  const Theme({super.key, required this.data, required this.child});

  final ThemeData data;
  final Widget child;

  /// The nearest Material theme, or [ThemeData.fallback] (Material 3 light)
  /// when there is none.
  static ThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InheritedTheme>()?.data ??
      ThemeData.fallback();

  /// The nearest Material theme's brightness.
  static Brightness brightnessOf(BuildContext context) =>
      of(context).brightness;

  /// The nearest Material theme's brightness, or null with no theme above.
  static Brightness? maybeBrightnessOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_InheritedTheme>()
      ?.data
      .brightness;

  @override
  Widget build(BuildContext context) {
    final dui.Theme? outer = dui.Theme.maybeOf(context);
    return _InheritedTheme(
      data: data,
      child: dui.Theme(
        data: data.dartUiTheme,
        styles: outer?.styles,
        resources: outer?.resources,
        templates: outer?.templates,
        child: IconTheme(data: data.iconTheme, child: child),
      ),
    );
  }
}

final class _InheritedTheme extends InheritedWidget {
  const _InheritedTheme({required this.data, required super.child});

  final ThemeData data;

  @override
  bool updateShouldNotify(_InheritedTheme oldWidget) =>
      !identical(data, oldWidget.data) && data != oldWidget.data;
}

/// Flutter's `AnimatedTheme`. The theme changes at once: a theme here is
/// not interpolated, so [duration] and [curve] are accepted and ignored.
class AnimatedTheme extends StatelessWidget {
  const AnimatedTheme({
    super.key,
    required this.data,
    this.duration = const Duration(milliseconds: 200),
    this.curve,
    this.onEnd,
    required this.child,
  });

  final ThemeData data;
  final Duration duration;
  final Object? curve;
  final void Function()? onEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(data: data, child: child);
}
