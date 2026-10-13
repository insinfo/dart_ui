/// The callback signatures every Flutter package spells the same way.
///
/// Flutter declares these in `foundation/basic_types.dart` (and
/// `VoidCallback` in `dart:ui`); a migrated widget's constructor names them
/// in its parameters, so they have to exist under exactly these names for
/// the code to compile unchanged. They are plain function types: a
/// `void Function()` is a [VoidCallback] and vice versa, so dart_ui code
/// written with the long spelling interoperates with code written with
/// these.
library;

import 'dart:async';

/// A callback with no arguments and no result: `onPressed`, `onTap`.
typedef VoidCallback = void Function();

/// Reports that a value changed to [value]: `onChanged`.
typedef ValueChanged<T> = void Function(T value);

/// Stores [value]; unlike [ValueChanged], the value need not have changed.
typedef ValueSetter<T> = void Function(T value);

/// Produces a value on demand.
typedef ValueGetter<T> = T Function();

/// A [VoidCallback] that finishes later.
typedef AsyncCallback = Future<void> Function();

/// A [ValueSetter] that finishes later.
typedef AsyncValueSetter<T> = Future<void> Function(T value);

/// A [ValueGetter] whose value arrives later.
typedef AsyncValueGetter<T> = Future<T> Function();
