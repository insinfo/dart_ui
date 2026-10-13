// Adapted from Flutter, packages/flutter/lib/src/widgets/widget_state.dart.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Interactive states and the values that depend on them - Flutter's
/// `WidgetState` and `WidgetStateProperty`, with the `MaterialState` aliases.
///
/// In Flutter these live in the widgets library. They are here, with the
/// Material layer, because Material is what reads them; a widget of the
/// framework that needs them can move this file down unchanged.
library;

import '../foundation/value_notifier.dart';
import '../graphics/color.dart' hide Colors;

/// What a user is doing to an interactive widget.
enum WidgetState {
  hovered,
  focused,
  pressed,
  dragged,
  selected,
  scrolledUnder,
  disabled,
  error,
}

/// Material's former name for [WidgetState].
typedef MaterialState = WidgetState;

/// A value that depends on a widget's [WidgetState]s.
abstract class WidgetStateProperty<T> {
  const WidgetStateProperty();

  /// The value for [states].
  T resolve(Set<WidgetState> states);

  /// [value] resolved for [states] when it is a property, or itself.
  static T resolveAs<T>(T value, Set<WidgetState> states) {
    if (value is WidgetStateProperty<T>) return value.resolve(states);
    return value;
  }

  /// A property computed by [callback].
  static WidgetStateProperty<T> resolveWith<T>(
          T Function(Set<WidgetState> states) callback) =>
      _WidgetStatePropertyWith<T>(callback);

  /// The same [value] in every state.
  static WidgetStateProperty<T> all<T>(T value) =>
      WidgetStatePropertyAll<T>(value);
}

/// Material's former name for [WidgetStateProperty].
typedef MaterialStateProperty<T> = WidgetStateProperty<T>;

final class _WidgetStatePropertyWith<T> extends WidgetStateProperty<T> {
  const _WidgetStatePropertyWith(this._resolve);

  final T Function(Set<WidgetState> states) _resolve;

  @override
  T resolve(Set<WidgetState> states) => _resolve(states);
}

/// A [WidgetStateProperty] with one value for every state.
class WidgetStatePropertyAll<T> extends WidgetStateProperty<T> {
  const WidgetStatePropertyAll(this.value);

  final T value;

  @override
  T resolve(Set<WidgetState> states) => value;

  @override
  bool operator ==(Object other) =>
      other is WidgetStatePropertyAll<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'WidgetStatePropertyAll($value)';
}

/// Material's former name for [WidgetStatePropertyAll].
typedef MaterialStatePropertyAll<T> = WidgetStatePropertyAll<T>;

/// A [Color] that is also a [WidgetStateProperty]: it paints as its value in
/// no state, and resolves per state where a property is read.
abstract class WidgetStateColor extends Color
    implements WidgetStateProperty<Color> {
  const WidgetStateColor(super.defaultValue);

  /// A colour computed by [callback]; it paints as the colour for no state.
  factory WidgetStateColor.resolveWith(
          Color Function(Set<WidgetState> states) callback) =>
      _WidgetStateColorWith(callback);

  /// Transparent in every state.
  static const WidgetStateColor transparent = _WidgetStateColorTransparent();

  @override
  Color resolve(Set<WidgetState> states);
}

/// Material's former name for [WidgetStateColor].
typedef MaterialStateColor = WidgetStateColor;

final class _WidgetStateColorWith extends WidgetStateColor {
  _WidgetStateColorWith(this._resolve) : super(_resolve(<WidgetState>{}).value);

  final Color Function(Set<WidgetState> states) _resolve;

  @override
  Color resolve(Set<WidgetState> states) => _resolve(states);
}

final class _WidgetStateColorTransparent extends WidgetStateColor {
  const _WidgetStateColorTransparent() : super(0x00000000);

  @override
  Color resolve(Set<WidgetState> states) => const Color(0x00000000);
}

/// The states of one interactive widget, shared with whoever wants to read
/// or drive them - Flutter's `WidgetStatesController`.
class WidgetStatesController extends ValueNotifier<Set<WidgetState>> {
  WidgetStatesController([Set<WidgetState>? value])
      : super(<WidgetState>{...?value});

  /// Adds [state] when [add] is true, removes it otherwise; notifies when
  /// that changed anything.
  void update(WidgetState state, bool add) {
    final bool changed = add ? value.add(state) : value.remove(state);
    if (changed) notifyListeners();
  }
}

/// Material's former name for [WidgetStatesController].
typedef MaterialStatesController = WidgetStatesController;
