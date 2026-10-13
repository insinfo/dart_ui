// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/foundation/synchronous_future.dart):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Flutter's `SynchronousFuture`: a future whose value is already known, so
/// `then` runs its callback at once instead of in a later microtask.
///
/// It exists for one kind of caller - an API that is asynchronous in general
/// but often has its answer already, such as an image provider whose key or
/// pixels are in memory. Answering with a `SynchronousFuture` lets the
/// consumer finish in the same frame, with no blank frame in between.
///
/// As in Flutter it is a sharp tool: code that `await`s it still yields, and
/// `catchError` never calls back, because there is never an error.
library;

import 'dart:async';

/// A [Future] that runs its `then` callbacks synchronously.
class SynchronousFuture<T> implements Future<T> {
  SynchronousFuture(this._value);

  final T _value;

  @override
  Stream<T> asStream() {
    final StreamController<T> controller = StreamController<T>();
    controller.add(_value);
    controller.close();
    return controller.stream;
  }

  @override
  Future<T> catchError(Function onError, {bool Function(Object error)? test}) =>
      Completer<T>().future;

  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue,
      {Function? onError}) {
    final FutureOr<R> result = onValue(_value);
    if (result is Future<R>) return result;
    return SynchronousFuture<R>(result);
  }

  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      Future<T>.value(_value).timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<T> whenComplete(FutureOr<dynamic> Function() action) {
    try {
      final FutureOr<dynamic> result = action();
      if (result is Future) {
        return result.then<T>((dynamic value) => _value);
      }
      return this;
    } catch (error, stack) {
      return Future<T>.error(error, stack);
    }
  }
}
