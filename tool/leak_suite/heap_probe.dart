/// Dart-heap readings, taken by the process from its own VM Service.
///
/// Class A of the three kinds of leak: an object still reachable after
/// `dispose()`. `lifecycle.dart` makes disposal idempotent and ordered but
/// cannot make it *complete* - a listener left on a stream, a closure captured
/// by a static, a window kept in a backend's list after it closed are all
/// perfectly disposed and perfectly retained - and only the heap can say so.
///
/// ## Why it connects to itself
///
/// The obvious shape is to spawn the program as a child under
/// `--enable-vm-service` and attach, which is what `tool/frame_timeline_trace
/// .dart` does. It costs about six seconds of front-end compilation per run
/// (`tool/startup_cost.dart`) and, worse, it puts the workload in a different
/// process from the [ProcessResourceProbe] counters, so the GDI and handle
/// numbers would describe a process the heap numbers do not.
///
/// `dart:developer`'s [Service.controlWebServer] turns the service on in the
/// running isolate and hands back its URI, so one process can hold all three
/// classes of measurement over the same cycles. The service is bound to
/// localhost and torn down at the end of the run.
///
/// ## JIT only, and it says which
///
/// There is no VM Service in an AOT executable. [HeapProbe.tryStart] returns
/// null there instead of throwing, and the suite reports class A as *not
/// measured in this run* rather than as clean - a leak detector that silently
/// reports nothing is worse than one that reports nothing loudly. The native
/// and operating-system counters keep working in AOT, which is the reason to
/// have them.
library;

import 'dart:developer' as developer;

import '../vm_service_client.dart';

/// One reading of the Dart heap.
final class HeapSample {
  const HeapSample({
    required this.heapUsageBytes,
    required this.externalUsageBytes,
    required this.instanceCounts,
    required this.instanceBytes,
  });

  /// Bytes live in the new and old generations after a full GC.
  final int heapUsageBytes;

  /// Bytes of native memory the VM knows is owned by Dart objects - typed data
  /// backing stores among them. Not the same as [NativeAllocator]'s blocks,
  /// which the VM never hears about.
  final int externalUsageBytes;

  /// Live instance count per watched class name.
  final Map<String, int> instanceCounts;

  /// Live bytes per watched class name.
  final Map<String, int> instanceBytes;
}

/// A connection from this process to its own VM Service.
final class HeapProbe {
  HeapProbe._(this._client, this._isolateId, this.serviceUri);

  final VmServiceClient _client;
  final String _isolateId;
  final Uri serviceUri;

  /// Starts the service if it is not already on and connects to it.
  ///
  /// Null when there is no VM Service to start - an AOT build, or a VM that
  /// refused. [onUnavailable] is given the reason so the report can say which.
  static Future<HeapProbe?> tryStart({
    void Function(String reason)? onUnavailable,
  }) async {
    Uri? uri;
    try {
      // `silenceOutput` because the service otherwise prints its URI to stdout
      // in the middle of the suite's own table.
      final developer.ServiceProtocolInfo info =
          await developer.Service.controlWebServer(
        enable: true,
        silenceOutput: true,
      );
      uri = info.serverUri;
    } on Object catch (error) {
      onUnavailable?.call('Service.controlWebServer threw: $error');
      return null;
    }
    if (uri == null) {
      onUnavailable?.call(
        'no VM Service in this process - an AOT build has none, so the Dart '
        'heap cannot be measured here',
      );
      return null;
    }
    try {
      final VmServiceClient client = await VmServiceClient.connect(uri);
      return HeapProbe._(client, await client.mainIsolateId(), uri);
    } on Object catch (error) {
      onUnavailable?.call('could not connect to $uri: $error');
      return null;
    }
  }

  /// Forces a full GC and reads the profile.
  ///
  /// The GC is not optional and is the whole reason this is one call rather
  /// than a getter: without it every reading includes whatever the collector
  /// has not got round to yet, and that garbage grows and shrinks with no
  /// relation to what leaked. `gc: true` makes each sample a statement about
  /// *reachable* objects, which is the only thing "leak" can mean on a managed
  /// heap.
  Future<HeapSample> sample(Set<String> watchedClasses) async {
    final Map<String, Object?> profile = await _client.call(
          'getAllocationProfile',
          <String, Object?>{'isolateId': _isolateId, 'gc': true},
        ) ??
        const <String, Object?>{};
    final Map<String, Object?> usage =
        (profile['memoryUsage'] as Map<String, Object?>?) ??
            const <String, Object?>{};
    final Map<String, int> counts = <String, int>{};
    final Map<String, int> bytes = <String, int>{};
    for (final String name in watchedClasses) {
      counts[name] = 0;
      bytes[name] = 0;
    }
    for (final Object? raw
        in (profile['members'] as List<Object?>?) ?? const <Object?>[]) {
      if (raw is! Map<String, Object?>) continue;
      final Object? owner = raw['class'];
      if (owner is! Map<String, Object?>) continue;
      final Object? name = owner['name'];
      if (name is! String || !watchedClasses.contains(name)) continue;
      // Summed rather than assigned: two libraries may declare classes of the
      // same name, and a watch list keyed by bare name would otherwise report
      // whichever came last in the profile.
      counts[name] = counts[name]! + ((raw['instancesCurrent'] as int?) ?? 0);
      bytes[name] = bytes[name]! + ((raw['bytesCurrent'] as int?) ?? 0);
    }
    return HeapSample(
      heapUsageBytes: (usage['heapUsage'] as int?) ?? 0,
      externalUsageBytes: (usage['externalUsage'] as int?) ?? 0,
      instanceCounts: counts,
      instanceBytes: bytes,
    );
  }

  Future<void> close() async {
    await _client.close();
    try {
      await developer.Service.controlWebServer(enable: false);
    } on Object {
      // Shutting the service down is tidiness, not correctness; a VM that
      // refuses must not fail a run whose measurements are already taken.
    }
  }
}
