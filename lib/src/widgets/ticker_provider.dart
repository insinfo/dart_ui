// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/widgets/ticker_provider.dart):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// `TickerMode`, `SingleTickerProviderStateMixin` and
/// `TickerProviderStateMixin`: what makes `AnimationController(vsync: this)`
/// work in a `State`, as in Flutter.
///
/// The tickers these mixins create are driven by the clock of the nearest
/// `AnimationScope` - the one `DartUiApp` installs in every window - read
/// when the ticker is created. With no scope above, the ticker has no clock;
/// see `animation/ticker.dart` for what a controller does then.
///
/// `State` here has no `didChangeDependencies` or `activate`, so a change of
/// [TickerMode] reaches the tickers through the mode's notifier, which is
/// what Flutter does too; a change of clock (a window re-bound to another
/// scheduler) is not followed - the controller keeps the clock it was
/// created with.
library;

import '../animation/clock.dart';
import '../animation/ticker.dart';
import '../foundation/value_notifier.dart';
import 'animation_scope.dart';
import 'widget.dart';

/// Enables or disables the tickers in a subtree - Flutter's `TickerMode`.
///
/// A disabled subtree's tickers are muted: their animations hold still and
/// ask for no frames until the subtree is enabled again. An enabled
/// `TickerMode` inside a disabled one is still disabled.
class TickerMode extends StatefulWidget {
  const TickerMode({super.key, required this.enabled, required this.child});

  /// Whether tickers in [child] may tick, unless an ancestor disables them.
  final bool enabled;

  final Widget child;

  /// Whether tickers at [context] are enabled; true with no [TickerMode]
  /// above. Rebuilds [context] when it changes.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_EffectiveTickerMode>()
          ?.enabled ??
      true;

  /// Whether tickers at [context] are enabled, as something to listen to -
  /// what a ticker provider uses to mute its tickers without a rebuild.
  static ValueListenable<bool> getNotifier(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_EffectiveTickerMode>()?.notifier ??
      _alwaysEnabled;

  static final ValueNotifier<bool> _alwaysEnabled = ValueNotifier<bool>(true);

  @override
  State<TickerMode> createState() => _TickerModeState();
}

class _TickerModeState extends State<TickerMode> {
  final ValueNotifier<bool> _effective = ValueNotifier<bool>(true);
  ValueListenable<bool>? _ancestor;

  void _update() {
    _effective.value = widget.enabled && (_ancestor?.value ?? true);
  }

  @override
  void dispose() {
    _ancestor?.removeListener(_update);
    _effective.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-read on every build: the ancestor mode is an inherited value, and
    // this State has no didChangeDependencies to learn about a new one.
    final ValueListenable<bool> ancestor = TickerMode.getNotifier(context);
    if (!identical(ancestor, _ancestor)) {
      _ancestor?.removeListener(_update);
      _ancestor = ancestor..addListener(_update);
    }
    _update();
    return _EffectiveTickerMode(
      enabled: _effective.value,
      notifier: _effective,
      child: widget.child,
    );
  }
}

class _EffectiveTickerMode extends InheritedWidget {
  const _EffectiveTickerMode({
    required this.enabled,
    required this.notifier,
    required super.child,
  });

  final bool enabled;
  final ValueNotifier<bool> notifier;

  @override
  bool updateShouldNotify(_EffectiveTickerMode oldWidget) =>
      enabled != oldWidget.enabled;
}

AnimationClock? _clockOf(BuildContext context) =>
    context.getInheritedWidgetOfExactType<AnimationScope>()?.clock;

/// A `State` that is the `vsync` of one `AnimationController` - Flutter's
/// `SingleTickerProviderStateMixin`.
///
/// Creating a second ticker throws; use [TickerProviderStateMixin] for more.
/// Disposing the state while its ticker is still active throws too, as in
/// Flutter: dispose the controller before calling `super.dispose()`.
mixin SingleTickerProviderStateMixin<T extends StatefulWidget> on State<T>
    implements TickerProvider {
  Ticker? _ticker;
  ValueListenable<bool>? _tickerModeNotifier;

  @override
  Ticker createTicker(TickerCallback onTick) {
    if (_ticker != null) {
      throw StateError(
        '$runtimeType is a SingleTickerProviderStateMixin but multiple '
        'tickers were created. A SingleTickerProviderStateMixin can only be '
        'used as a TickerProvider once; use TickerProviderStateMixin for a '
        'State that drives more than one AnimationController.',
      );
    }
    final Ticker ticker = _ticker = Ticker(
      onTick,
      debugLabel: 'created by $runtimeType',
      clock: _clockOf(context),
    );
    _updateTickerModeNotifier();
    _updateTicker();
    return ticker;
  }

  void _updateTicker() {
    final Ticker? ticker = _ticker;
    if (ticker == null) return;
    ticker.muted = !(_tickerModeNotifier?.value ?? true);
  }

  void _updateTickerModeNotifier() {
    final ValueListenable<bool> notifier = TickerMode.getNotifier(context);
    if (identical(notifier, _tickerModeNotifier)) return;
    _tickerModeNotifier?.removeListener(_updateTicker);
    _tickerModeNotifier = notifier..addListener(_updateTicker);
  }

  @override
  void dispose() {
    final Ticker? ticker = _ticker;
    _tickerModeNotifier?.removeListener(_updateTicker);
    _tickerModeNotifier = null;
    if (ticker != null && ticker.isActive) {
      ticker.dispose();
      throw StateError(
        '$this was disposed with an active Ticker. $runtimeType created a '
        'Ticker via its SingleTickerProviderStateMixin, but at the time '
        'dispose() was called on the mixin, that Ticker was still active. '
        'Dispose the AnimationController before calling super.dispose().',
      );
    }
    super.dispose();
  }
}

/// A `State` that is the `vsync` of any number of `AnimationController`s -
/// Flutter's `TickerProviderStateMixin`.
mixin TickerProviderStateMixin<T extends StatefulWidget> on State<T>
    implements TickerProvider {
  Set<Ticker>? _tickers;
  ValueListenable<bool>? _tickerModeNotifier;

  @override
  Ticker createTicker(TickerCallback onTick) {
    if (_tickerModeNotifier == null) _updateTickerModeNotifier();
    final Set<Ticker> tickers = _tickers ??= <Ticker>{};
    final _WidgetTicker ticker = _WidgetTicker(
      onTick,
      this,
      debugLabel: 'created by $runtimeType',
      clock: _clockOf(context),
    )..muted = !(_tickerModeNotifier?.value ?? true);
    tickers.add(ticker);
    return ticker;
  }

  void _removeTicker(_WidgetTicker ticker) => _tickers?.remove(ticker);

  void _updateTickers() {
    final Set<Ticker>? tickers = _tickers;
    if (tickers == null) return;
    final bool muted = !(_tickerModeNotifier?.value ?? true);
    for (final Ticker ticker in tickers) {
      ticker.muted = muted;
    }
  }

  void _updateTickerModeNotifier() {
    final ValueListenable<bool> notifier = TickerMode.getNotifier(context);
    if (identical(notifier, _tickerModeNotifier)) return;
    _tickerModeNotifier?.removeListener(_updateTickers);
    _tickerModeNotifier = notifier..addListener(_updateTickers);
  }

  @override
  void dispose() {
    _tickerModeNotifier?.removeListener(_updateTickers);
    _tickerModeNotifier = null;
    final List<Ticker> active = <Ticker>[
      for (final Ticker ticker in _tickers ?? const <Ticker>{})
        if (ticker.isActive) ticker,
    ];
    if (active.isNotEmpty) {
      for (final Ticker ticker in active) {
        ticker.dispose();
      }
      throw StateError(
        '$this was disposed with an active Ticker. $runtimeType created a '
        'Ticker via its TickerProviderStateMixin, but at the time dispose() '
        'was called on the mixin, that Ticker was still active. All Tickers '
        'must be disposed before calling super.dispose(): dispose every '
        'AnimationController first.',
      );
    }
    super.dispose();
  }
}

/// A ticker that leaves its provider's set when it is disposed.
class _WidgetTicker extends Ticker {
  _WidgetTicker(super.onTick, this._creator, {super.debugLabel, super.clock});

  final TickerProviderStateMixin<StatefulWidget> _creator;

  @override
  void dispose() {
    _creator._removeTicker(this);
    super.dispose();
  }
}
