/// What it costs to move a decoded video frame from one isolate to another.
///
/// The question this answers: a video decoder cannot run on the main isolate
/// without freezing during a window drag, because Windows runs a nested modal
/// message loop there and the Dart event loop is parked inside it. Moving the
/// decode to an isolate of its own fixes that — **if handing the frames back
/// does not cost more than it saves.** A 1080p BGRA frame is 8.29 MB, and at
/// 25 fps that is 207 MB a second crossing the boundary.
///
/// Four ways of crossing it are measured against each other:
///
///   1. **Same isolate** — the baseline, and what runs today. No boundary.
///   2. **A shared native ring, addressed by integer.** The frame stays where
///      the decoder wrote it, in memory `NativeVideoFrameRing` already
///      allocates with `dart:ffi`, and only the slot index crosses the port.
///      Isolates share one address space, so the consumer rebuilds the view
///      with `Pointer.fromAddress(...).asTypedList(...)`.
///   3. **A copy through the port** — a plain `Uint8List` on a `SendPort`,
///      which the VM serialises by copying.
///   4. **`TransferableTypedData`** — a move rather than a copy: the sender
///      loses the buffer and the receiver gains it, with no memcpy. The catch
///      is that the sender loses it, so a ring cannot be reused and every
///      frame needs a fresh allocation.
///
/// Each is timed for latency (send to receive, per frame) and for the
/// throughput a decoder would actually need to sustain.
///
/// ```
/// dart compile exe -o build/handoff.exe tool/isolate_frame_handoff_probe.dart
/// build/handoff.exe
/// ```
///
/// Run it compiled. `dart run` measures the front end more than it measures
/// this; see `tool/startup_cost.dart`.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_ui/src/ffi/native_memory.dart';

/// 1920x1080 BGRA, the frame the video player actually decodes.
const int _width = 1920;
const int _height = 1080;
const int _frameBytes = _width * _height * 4;
const int _slots = 4;
const int _frames = 120;

/// A checksum the consumer computes so the compiler cannot delete the read.
///
/// Sampled rather than summed over all 8.29 MB: reading every byte would make
/// this measure the consumer's arithmetic instead of the handoff. One byte a
/// row is enough to prove the data arrived and is the right data.
int _checksum(Uint8List bytes) {
  var sum = 0;
  for (var y = 0; y < _height; y++) {
    sum = (sum + bytes[y * _width * 4 + (y % _width) * 4]) & 0xFFFFFF;
  }
  return sum;
}

/// Fills [bytes] the way a decoder would: a whole frame of pixels.
void _produce(Uint8List bytes, int sequence) {
  // A real memcpy-sized write, because that is what a decoder does and it is
  // half of what makes the shared-memory case interesting: the producer pays
  // this cost in every one of the four arrangements.
  final Uint32List words = Uint32List.sublistView(bytes);
  final int colour = 0xFF000000 | (sequence * 7919) & 0xFFFFFF;
  for (var i = 0; i < words.length; i++) {
    words[i] = colour;
  }
}

/// Microsecond timings, summarised the way a frame budget is read.
final class _Timings {
  _Timings(this.label);

  final String label;
  final List<int> samples = <int>[];

  void add(int microseconds) => samples.add(microseconds);

  double get median {
    final List<int> sorted = List<int>.of(samples)..sort();
    return sorted.isEmpty ? 0 : sorted[sorted.length ~/ 2].toDouble();
  }

  double get p95 {
    final List<int> sorted = List<int>.of(samples)..sort();
    return sorted.isEmpty ? 0 : sorted[(sorted.length * 95) ~/ 100].toDouble();
  }

  double get mean => samples.isEmpty
      ? 0
      : samples.reduce((int a, int b) => a + b) / samples.length;

  @override
  String toString() => '| $label | ${(median / 1000).toStringAsFixed(3)} | '
      '${(mean / 1000).toStringAsFixed(3)} | '
      '${(p95 / 1000).toStringAsFixed(3)} |';
}

// ---------------------------------------------------------------------------
// 1. Same isolate
// ---------------------------------------------------------------------------

Future<_Timings> _sameIsolate() async {
  final _Timings timings = _Timings('mesma isolate (hoje)');
  final Pointer<Uint8> memory =
      NativeAllocator.instance.allocate<Uint8>(_frameBytes * _slots);
  try {
    final List<Uint8List> views = List<Uint8List>.generate(
      _slots,
      (int i) => Pointer<Uint8>.fromAddress(memory.address + i * _frameBytes)
          .asTypedList(_frameBytes),
      growable: false,
    );
    final Stopwatch watch = Stopwatch();
    var sink = 0;
    for (var frame = 0; frame < _frames; frame++) {
      watch
        ..reset()
        ..start();
      final Uint8List slot = views[frame % _slots];
      _produce(slot, frame);
      sink ^= _checksum(slot);
      watch.stop();
      timings.add(watch.elapsedMicroseconds);
    }
    if (sink == 0x7FFFFFFF) print('unreachable $sink');
  } finally {
    NativeAllocator.instance.free(memory);
  }
  return timings;
}

// ---------------------------------------------------------------------------
// 2. A shared native ring, addressed by integer
// ---------------------------------------------------------------------------

/// What the producer isolate needs to find the ring.
final class _RingRequest {
  const _RingRequest(this.reply, this.address, this.slots);

  final SendPort reply;
  final int address;

  /// How many slots the allocation actually holds.
  ///
  /// Carried rather than assumed, and the reason is the first thing this probe
  /// taught: an earlier version passed a one-slot buffer and let the producer
  /// build four views over it. `asTypedList` does not check the length against
  /// the allocation - it cannot, the allocation is not something it knows - so
  /// the writes went past the end and the **process died with an access
  /// violation and no Dart exception**. That is the price of sharing raw
  /// memory across isolates, and it belongs in the report rather than in a
  /// silently corrected mistake.
  final int slots;
}

Future<void> _sharedRingProducer(_RingRequest request) async {
  final ReceivePort inbox = ReceivePort();
  request.reply.send(inbox.sendPort);
  final List<Uint8List> views = List<Uint8List>.generate(
    request.slots,
    (int i) => Pointer<Uint8>.fromAddress(request.address + i * _frameBytes)
        .asTypedList(_frameBytes),
    growable: false,
  );

  // One frame per request, so the timing below measures a round trip and not
  // a queue draining. A real decoder would run ahead by a slot or two, which
  // is strictly cheaper than this.
  await for (final Object? message in inbox) {
    if (message is! int) break;
    final int slot = message % request.slots;
    _produce(views[slot], message);
    // Only the slot index crosses. The 8.29 MB stays where it was written.
    request.reply.send(slot);
  }
  inbox.close();
}

Future<_Timings> _sharedRing() async {
  final _Timings timings = _Timings('anel nativo compartilhado');
  final Pointer<Uint8> memory =
      NativeAllocator.instance.allocate<Uint8>(_frameBytes * _slots);
  final ReceivePort inbox = ReceivePort();
  final StreamIterator<Object?> replies =
      StreamIterator<Object?>(inbox.cast<Object?>());
  try {
    final List<Uint8List> views = List<Uint8List>.generate(
      _slots,
      (int i) => Pointer<Uint8>.fromAddress(memory.address + i * _frameBytes)
          .asTypedList(_frameBytes),
      growable: false,
    );
    await Isolate.spawn(
      _sharedRingProducer,
      _RingRequest(inbox.sendPort, memory.address, _slots),
    );
    await replies.moveNext();
    final SendPort requests = replies.current! as SendPort;

    final Stopwatch watch = Stopwatch();
    var sink = 0;
    for (var frame = 0; frame < _frames; frame++) {
      watch
        ..reset()
        ..start();
      requests.send(frame);
      await replies.moveNext();
      final int slot = replies.current! as int;
      sink ^= _checksum(views[slot]);
      watch.stop();
      timings.add(watch.elapsedMicroseconds);
    }
    requests.send('stop');
    if (sink == 0x7FFFFFFF) print('unreachable $sink');
  } finally {
    await replies.cancel();
    inbox.close();
    NativeAllocator.instance.free(memory);
  }
  return timings;
}

// ---------------------------------------------------------------------------
// 3. A copy through the port
// ---------------------------------------------------------------------------

Future<void> _copyProducer(SendPort reply) async {
  final ReceivePort inbox = ReceivePort();
  reply.send(inbox.sendPort);
  final Uint8List scratch = Uint8List(_frameBytes);
  await for (final Object? message in inbox) {
    if (message is! int) break;
    _produce(scratch, message);
    // The VM serialises this by copying every byte.
    reply.send(scratch);
  }
  inbox.close();
}

Future<_Timings> _portCopy() async {
  final _Timings timings = _Timings('cópia pela porta');
  final ReceivePort inbox = ReceivePort();
  final StreamIterator<Object?> replies =
      StreamIterator<Object?>(inbox.cast<Object?>());
  try {
    await Isolate.spawn(_copyProducer, inbox.sendPort);
    await replies.moveNext();
    final SendPort requests = replies.current! as SendPort;

    final Stopwatch watch = Stopwatch();
    var sink = 0;
    for (var frame = 0; frame < _frames; frame++) {
      watch
        ..reset()
        ..start();
      requests.send(frame);
      await replies.moveNext();
      sink ^= _checksum(replies.current! as Uint8List);
      watch.stop();
      timings.add(watch.elapsedMicroseconds);
    }
    requests.send('stop');
    if (sink == 0x7FFFFFFF) print('unreachable $sink');
  } finally {
    await replies.cancel();
    inbox.close();
  }
  return timings;
}

// ---------------------------------------------------------------------------
// 4. TransferableTypedData
// ---------------------------------------------------------------------------

Future<void> _transferProducer(SendPort reply) async {
  final ReceivePort inbox = ReceivePort();
  reply.send(inbox.sendPort);
  await for (final Object? message in inbox) {
    if (message is! int) break;
    // A fresh buffer every frame, because the transfer takes it away: there is
    // no ring to reuse, and that allocation is part of what this costs.
    final Uint8List bytes = Uint8List(_frameBytes);
    _produce(bytes, message);
    reply.send(TransferableTypedData.fromList(<Uint8List>[bytes]));
  }
  inbox.close();
}

Future<_Timings> _transfer() async {
  final _Timings timings = _Timings('TransferableTypedData');
  final ReceivePort inbox = ReceivePort();
  final StreamIterator<Object?> replies =
      StreamIterator<Object?>(inbox.cast<Object?>());
  try {
    await Isolate.spawn(_transferProducer, inbox.sendPort);
    await replies.moveNext();
    final SendPort requests = replies.current! as SendPort;

    final Stopwatch watch = Stopwatch();
    var sink = 0;
    for (var frame = 0; frame < _frames; frame++) {
      watch
        ..reset()
        ..start();
      requests.send(frame);
      await replies.moveNext();
      final TransferableTypedData moved =
          replies.current! as TransferableTypedData;
      sink ^= _checksum(moved.materialize().asUint8List());
      watch.stop();
      timings.add(watch.elapsedMicroseconds);
    }
    requests.send('stop');
    if (sink == 0x7FFFFFFF) print('unreachable $sink');
  } finally {
    await replies.cancel();
    inbox.close();
  }
  return timings;
}

// ---------------------------------------------------------------------------
// The one correctness question the timings cannot answer
// ---------------------------------------------------------------------------

/// Whether a write in one isolate is actually visible in another.
///
/// Dart has no published memory model for `dart:ffi` memory shared between
/// isolates, and isolates run on different operating-system threads. What makes
/// this safe in practice is that the port send and the matching receive are a
/// synchronisation point inside the VM — the producer's writes happen before
/// the send, and the consumer's reads after the receive. This checks that the
/// ordering holds for a whole frame rather than assuming it, over enough
/// rounds that a torn read would show up.
Future<bool> _visibilityHolds() async {
  final Pointer<Uint8> memory =
      NativeAllocator.instance.allocate<Uint8>(_frameBytes);
  final ReceivePort inbox = ReceivePort();
  final StreamIterator<Object?> replies =
      StreamIterator<Object?>(inbox.cast<Object?>());
  try {
    final Uint8List view = memory.asTypedList(_frameBytes);
    await Isolate.spawn(
      _sharedRingProducer,
      _RingRequest(inbox.sendPort, memory.address, 1),
    );
    await replies.moveNext();
    final SendPort requests = replies.current! as SendPort;

    for (var round = 0; round < 200; round++) {
      requests.send(round);
      await replies.moveNext();
      final int expected = 0xFF000000 | (round * 7919) & 0xFFFFFF;
      final Uint32List words = Uint32List.sublistView(view);
      // The first word, the last, and one in the middle: a partially visible
      // write would show at an edge.
      if (words[0] != expected ||
          words[words.length ~/ 2] != expected ||
          words[words.length - 1] != expected) {
        requests.send('stop');
        return false;
      }
    }
    requests.send('stop');
    return true;
  } finally {
    await replies.cancel();
    inbox.close();
    NativeAllocator.instance.free(memory);
  }
}

Future<void> main() async {
  print('quadro 1920x1080 BGRA = '
      '${(_frameBytes / 1024 / 1024).toStringAsFixed(2)} MiB · '
      '$_frames quadros por caminho · '
      '${(_frameBytes * 25 / 1024 / 1024).toStringAsFixed(0)} MiB/s a 25 fps');

  final bool visible = await _visibilityHolds();
  print('escrita de uma isolate visível na outra, 200 rodadas: '
      '${visible ? 'sim' : 'NÃO'}');

  final List<_Timings> results = <_Timings>[
    await _sameIsolate(),
    await _sharedRing(),
    await _portCopy(),
    await _transfer(),
  ];

  print('\n| caminho | mediana (ms) | média (ms) | p95 (ms) |');
  print('|---|---|---|---|');
  for (final _Timings timings in results) {
    print(timings);
  }

  final double baseline = results.first.median;
  print('\nsobre a mesma isolate:');
  for (final _Timings timings in results.skip(1)) {
    final double delta = timings.median - baseline;
    print('  ${timings.label}: '
        '${delta >= 0 ? '+' : ''}${(delta / 1000).toStringAsFixed(3)} ms '
        'por quadro (${(timings.median / baseline).toStringAsFixed(2)}x)');
  }
}
