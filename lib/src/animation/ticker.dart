// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/scheduler/ticker.dart):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Flutter's `Ticker`, `TickerProvider`, `TickerFuture` and `TickerCanceled`,
/// on this framework's [AnimationClock].
///
/// ## Where the time comes from
///
/// Flutter's ticker asks the process-wide `SchedulerBinding` for frames. This
/// framework has no ambient clock - `clock.dart` says why - so a [Ticker] is
/// registered with an [AnimationClock] and is called back from
/// [AnimationClock.tick], once per frame, with the time elapsed since it was
/// started. The first callback after [Ticker.start] reports [Duration.zero],
/// exactly as Flutter's does: a ticker started between two frames is not
/// charged for the part of the frame it was not alive for.
///
/// Inside a widget tree the clock comes from the nearest `AnimationScope`
/// through `TickerProviderStateMixin`, so `AnimationController(vsync: this)`
/// is written the Flutter way. A ticker with **no clock** - created with no
/// `AnimationScope` above it - never ticks; [Ticker.canTick] says so, and an
/// `AnimationController` driven by one jumps straight to where it was going,
/// which is the framework's rule for animations with no clock (see
/// `widgets/implicit_animation.dart`).
library;

import 'dart:async';

import 'clock.dart';

/// Called once per frame with the time since the ticker was started.
typedef TickerCallback = void Function(Duration elapsed);

/// Something that hands out [Ticker]s - the `vsync` of an
/// `AnimationController`.
abstract class TickerProvider {
  const TickerProvider();

  /// A ticker that calls [onTick] once per frame while it is active.
  Ticker createTicker(TickerCallback onTick);
}

/// Calls its callback once per frame while it is active.
///
/// [start] activates it and returns a [TickerFuture] that completes when
/// [stop] is called; [stop] with `canceled: true` (or [dispose]) cancels it
/// instead, which leaves the future pending and fails its
/// [TickerFuture.orCancel].
///
/// The ticker is registered with its [clock] from construction to [dispose]
/// and asks for frames only while [isTicking].
class Ticker implements AnimationTicker {
  /// [clock] is this framework's addition: the [AnimationClock] whose frames
  /// drive the ticker. Without one the ticker never ticks; see the library
  /// documentation.
  Ticker(this._onTick, {this.debugLabel, AnimationClock? clock})
      : _clock = clock {
    clock?.addTicker(this);
  }

  final TickerCallback _onTick;

  /// A name for diagnostics.
  final String? debugLabel;

  final AnimationClock? _clock;

  /// The clock this ticker is registered with, or null when it has none and
  /// therefore never ticks.
  AnimationClock? get clock => _clock;

  /// Whether this ticker has a clock to be driven by.
  bool get canTick => _clock != null;

  TickerFuture? _future;
  Duration? _startTime;
  bool _muted = false;
  bool _disposed = false;

  /// Accepted for Flutter compatibility. Frames are requested from the clock
  /// the same way either way.
  bool forceFrames = false;

  /// A muted ticker keeps its place in time but does not call back - what a
  /// subtree under `TickerMode(enabled: false)` gets.
  bool get muted => _muted;

  set muted(bool value) {
    if (value == _muted) return;
    _muted = value;
    if (!value && isActive) _clock?.requestFrame();
  }

  /// Whether [start] was called and [stop] has not been since.
  bool get isActive => _future != null;

  /// Whether this ticker will be called back on the next frame: active, not
  /// muted, and with a clock.
  @override
  bool get isTicking => _future != null && !_muted && _clock != null;

  /// Whether a frame callback is pending. With an [AnimationClock] it is
  /// whenever [isTicking].
  bool get scheduled => isTicking;

  /// Whether [scheduleTick] would do anything.
  bool get shouldScheduleTick => !muted && isActive && !scheduled;

  /// Activates the ticker. Starting one that is already active throws, as in
  /// Flutter: stop it first.
  TickerFuture start() {
    if (_disposed) {
      throw StateError('Ticker.start() called after dispose().');
    }
    if (isActive) {
      throw StateError(
        'A ticker was started twice. A ticker that is already active cannot '
        'be started again without first stopping it. ($this)',
      );
    }
    final TickerFuture future = _future = TickerFuture._();
    // Started from inside a frame: this frame is the start, as in Flutter,
    // so a status listener that turns an animation round loses no frame.
    final AnimationClock? clock = _clock;
    _startTime = clock != null && clock.inTick ? clock.timestamp : null;
    scheduleTick();
    return future;
  }

  /// Deactivates the ticker. With [canceled] false the [TickerFuture] from
  /// [start] completes; with true it is canceled.
  void stop({bool canceled = false}) {
    final TickerFuture? future = _future;
    if (future == null) return;
    _future = null;
    _startTime = null;
    if (canceled) {
      future._cancel(this);
    } else {
      future._complete();
    }
  }

  /// Asks the clock for a frame.
  void scheduleTick({bool rescheduling = false}) {
    if (isTicking) _clock?.requestFrame();
  }

  /// Nothing to undo: the clock stops asking for frames by itself once no
  /// ticker [isTicking].
  void unscheduleTick() {}

  @override
  void tick(Duration timestamp) {
    if (_future == null || _muted) return;
    final Duration start = _startTime ??= timestamp;
    _onTick(timestamp - start);
  }

  /// Takes over [originalTicker]'s run - its future and its start time - and
  /// disposes it. What `AnimationController.resync` uses when a widget moves
  /// to a different provider.
  void absorbTicker(Ticker originalTicker) {
    final TickerFuture? future = originalTicker._future;
    if (future != null && _future == null) {
      _future = future;
      _startTime = originalTicker._startTime;
      originalTicker._future = null;
      scheduleTick();
    }
    originalTicker.dispose();
  }

  /// Cancels any run and unregisters from the clock. Using the ticker
  /// afterwards throws.
  void dispose() {
    if (_disposed) return;
    final TickerFuture? future = _future;
    if (future != null) {
      _future = null;
      future._cancel(this);
    }
    _disposed = true;
    _clock?.removeTicker(this);
  }

  @override
  String toString() => 'Ticker(${debugLabel ?? ''})';
}

/// What [Ticker.start] returns: completes when the ticker is stopped, and
/// never when it is canceled - [orCancel] is the future that fails then.
class TickerFuture implements Future<void> {
  TickerFuture._();

  /// An already completed future, for an animation with nothing to do.
  TickerFuture.complete() {
    _complete();
  }

  final Completer<void> _primaryCompleter = Completer<void>();
  Completer<void>? _secondaryCompleter;

  /// Null while running, true once complete, false once canceled.
  bool? _completed;

  void _complete() {
    _completed = true;
    _primaryCompleter.complete();
    _secondaryCompleter?.complete();
  }

  void _cancel(Ticker ticker) {
    _completed = false;
    _secondaryCompleter?.completeError(TickerCanceled(ticker));
  }

  /// Calls [callback] when the ticker completes or is canceled.
  void whenCompleteOrCancel(void Function() callback) {
    void thunk(Object? value) => callback();
    orCancel.then<void>(thunk, onError: thunk);
  }

  /// A future that completes with this one, or fails with [TickerCanceled]
  /// when the ticker is canceled.
  Future<void> get orCancel {
    Completer<void>? secondary = _secondaryCompleter;
    if (secondary == null) {
      secondary = _secondaryCompleter = Completer<void>();
      final bool? completed = _completed;
      if (completed == true) {
        secondary.complete();
      } else if (completed == false) {
        secondary.completeError(const TickerCanceled());
      }
    }
    return secondary.future;
  }

  @override
  Stream<void> asStream() => _primaryCompleter.future.asStream();

  @override
  Future<void> catchError(Function onError,
          {bool Function(Object error)? test}) =>
      _primaryCompleter.future.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(void value) onValue,
          {Function? onError}) =>
      _primaryCompleter.future.then<R>(onValue, onError: onError);

  @override
  Future<void> timeout(Duration timeLimit,
          {FutureOr<void> Function()? onTimeout}) =>
      _primaryCompleter.future.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<void> whenComplete(FutureOr<void> Function() action) =>
      _primaryCompleter.future.whenComplete(action);

  @override
  String toString() => 'TickerFuture(${switch (_completed) {
        null => 'active',
        true => 'complete',
        false => 'canceled',
      }})';
}

/// The error [TickerFuture.orCancel] fails with when its ticker is canceled.
class TickerCanceled implements Exception {
  const TickerCanceled([this.ticker]);

  /// The ticker that was canceled, when known.
  final Ticker? ticker;

  @override
  String toString() => ticker != null
      ? 'This ticker was canceled: $ticker'
      : 'The ticker was canceled before the "orCancel" property was first '
          'used.';
}
