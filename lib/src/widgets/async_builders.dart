/// Building from a [Future] or a [Stream]: Flutter's `FutureBuilder`,
/// `StreamBuilder` and `AsyncSnapshot`, with their names and semantics, so
/// a screen that loads something shows "loading", then the data or the
/// error, without a hand-written state machine.
library;

import 'dart:async';

import 'widget.dart';

/// Where an asynchronous computation is.
enum ConnectionState {
  /// No future or stream to watch.
  none,

  /// Watching, nothing arrived yet.
  waiting,

  /// A stream that has delivered and may deliver more.
  active,

  /// The future completed, or the stream closed.
  done,
}

/// What an asynchronous computation has produced so far.
final class AsyncSnapshot<T> {
  const AsyncSnapshot._(
      this.connectionState, this.data, this.error, this.stackTrace);

  /// Nothing to watch.
  const AsyncSnapshot.nothing()
      : this._(ConnectionState.none, null, null, null);

  /// Waiting, with no data yet.
  const AsyncSnapshot.waiting()
      : this._(ConnectionState.waiting, null, null, null);

  /// [data] in [state].
  const AsyncSnapshot.withData(ConnectionState state, T data)
      : this._(state, data, null, null);

  /// [error] in [state].
  const AsyncSnapshot.withError(
    ConnectionState state,
    Object error, [
    StackTrace stackTrace = StackTrace.empty,
  ]) : this._(state, null, error, stackTrace);

  final ConnectionState connectionState;

  /// The latest value, or null when there is none - or when the latest
  /// thing was an error.
  final T? data;

  final Object? error;
  final StackTrace? stackTrace;

  bool get hasData => data != null;
  bool get hasError => error != null;

  /// [data], or throws the [error] - for a builder that has already
  /// handled waiting.
  T get requireData {
    if (hasData) return data as T;
    if (hasError) Error.throwWithStackTrace(error!, stackTrace!);
    throw StateError('AsyncSnapshot has neither data nor error');
  }

  /// This snapshot in [state], keeping its data or error.
  AsyncSnapshot<T> inState(ConnectionState state) =>
      AsyncSnapshot<T>._(state, data, error, stackTrace);

  @override
  bool operator ==(Object other) =>
      other is AsyncSnapshot<T> &&
      other.connectionState == connectionState &&
      other.data == data &&
      other.error == error &&
      other.stackTrace == stackTrace;

  @override
  int get hashCode => Object.hash(connectionState, data, error, stackTrace);

  @override
  String toString() =>
      'AsyncSnapshot($connectionState, $data, $error, $stackTrace)';
}

/// Builds with the latest [AsyncSnapshot] of [future]: waiting, then the
/// value or the error. [initialData] is shown while waiting.
///
/// A different future starts over; the old one's result, should it arrive
/// late, is ignored - a search box replaced by a newer query must not show
/// the older answer.
final class FutureBuilder<T> extends StatefulWidget {
  const FutureBuilder({
    super.key,
    required this.future,
    required this.builder,
    this.initialData,
  });

  final Future<T>? future;
  final Widget Function(BuildContext context, AsyncSnapshot<T> snapshot)
      builder;
  final T? initialData;

  @override
  State<FutureBuilder<T>> createState() => _FutureBuilderState<T>();
}

final class _FutureBuilderState<T> extends State<FutureBuilder<T>> {
  Object? _activeCallbackIdentity;
  late AsyncSnapshot<T> _snapshot;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initialData == null
        ? AsyncSnapshot<T>._(ConnectionState.none, null, null, null)
        : AsyncSnapshot<T>.withData(
            ConnectionState.none, widget.initialData as T);
    _subscribe();
  }

  @override
  void didUpdateWidget(FutureBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.future == widget.future) return;
    if (_activeCallbackIdentity != null) {
      _activeCallbackIdentity = null;
      _snapshot = _snapshot.inState(ConnectionState.none);
    }
    _subscribe();
  }

  @override
  void dispose() {
    _activeCallbackIdentity = null;
    super.dispose();
  }

  void _subscribe() {
    final Future<T>? future = widget.future;
    if (future == null) return;
    final Object callbackIdentity = Object();
    _activeCallbackIdentity = callbackIdentity;
    future.then<void>((T data) {
      if (_activeCallbackIdentity != callbackIdentity || !mounted) return;
      setState(() =>
          _snapshot = AsyncSnapshot<T>.withData(ConnectionState.done, data));
    }, onError: (Object error, StackTrace stackTrace) {
      if (_activeCallbackIdentity != callbackIdentity || !mounted) return;
      setState(() => _snapshot =
          AsyncSnapshot<T>.withError(ConnectionState.done, error, stackTrace));
    });
    _snapshot = _snapshot.inState(ConnectionState.waiting);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _snapshot);
}

/// Builds with the latest [AsyncSnapshot] of [stream]: waiting, then each
/// value or error as it arrives (active), then done when it closes.
final class StreamBuilder<T> extends StatefulWidget {
  const StreamBuilder({
    super.key,
    required this.stream,
    required this.builder,
    this.initialData,
  });

  final Stream<T>? stream;
  final Widget Function(BuildContext context, AsyncSnapshot<T> snapshot)
      builder;
  final T? initialData;

  @override
  State<StreamBuilder<T>> createState() => _StreamBuilderState<T>();
}

final class _StreamBuilderState<T> extends State<StreamBuilder<T>> {
  StreamSubscription<T>? _subscription;
  late AsyncSnapshot<T> _snapshot;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initialData == null
        ? AsyncSnapshot<T>._(ConnectionState.none, null, null, null)
        : AsyncSnapshot<T>.withData(
            ConnectionState.none, widget.initialData as T);
    _subscribe();
  }

  @override
  void didUpdateWidget(StreamBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream == widget.stream) return;
    if (_subscription != null) {
      _unsubscribe();
      _snapshot = _snapshot.inState(ConnectionState.none);
    }
    _subscribe();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _subscribe() {
    final Stream<T>? stream = widget.stream;
    if (stream == null) return;
    _subscription = stream.listen(
      (T data) {
        if (!mounted) return;
        setState(() => _snapshot =
            AsyncSnapshot<T>.withData(ConnectionState.active, data));
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted) return;
        setState(() => _snapshot = AsyncSnapshot<T>.withError(
            ConnectionState.active, error, stackTrace));
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _snapshot = _snapshot.inState(ConnectionState.done));
      },
    );
    _snapshot = _snapshot.inState(ConnectionState.waiting);
  }

  void _unsubscribe() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _snapshot);
}
