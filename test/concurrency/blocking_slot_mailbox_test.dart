/// The frame handoff, end to end, across two real isolates.
///
/// Every test here can hang rather than fail if the code under test is wrong -
/// that is the nature of a blocking primitive - so every one of them carries a
/// [Timeout]. A broken build must report a failure, not stop CI.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_ui/src/concurrency/blocking_slot_mailbox.dart';
import 'package:dart_ui/src/concurrency/blocking_wait.dart';
import 'package:dart_ui/src/graphics/video/video_frame_ring_buffer.dart';
import 'package:test/test.dart';

/// The geometry both isolates need to find a slot, and nothing else.
///
/// Note what is *not* here: no pixels, and no per-frame address. Each isolate
/// is told where the ring starts and how big a slot is, and works out the rest
/// from the slot index that came through the mailbox. That is what makes the
/// address assertion below mean something - the consumer's address is derived
/// from the eight bytes the mailbox carried, not handed to it by the test.
final class _RingGeometry {
  const _RingGeometry(this.baseAddress, this.bytesPerSlot, this.slotCount);

  final int baseAddress;
  final int bytesPerSlot;
  final int slotCount;

  int addressOf(int slot) => baseAddress + slot * bytesPerSlot;
}

final class _ProduceRequest {
  const _ProduceRequest({
    required this.reply,
    required this.mailboxAddress,
    required this.geometry,
    required this.generation,
    required this.startDelayMilliseconds,
  });

  final SendPort reply;
  final int mailboxAddress;
  final _RingGeometry geometry;
  final int generation;

  /// Long enough that the consumer is provably parked before anything is
  /// published. Without it the consumer might find a frame already waiting and
  /// never block at all, which would make the whole test vacuous.
  final int startDelayMilliseconds;
}

final class _ConsumeRequest {
  const _ConsumeRequest({
    required this.reply,
    required this.mailboxAddress,
    required this.geometry,
    required this.stamp,
    required this.timeoutMilliseconds,
  });

  final SendPort reply;
  final int mailboxAddress;
  final _RingGeometry geometry;

  /// Written back into the ring by the consumer, so the test can prove the two
  /// isolates are looking at one buffer and not at two equal ones.
  final int stamp;

  final int timeoutMilliseconds;
}

final class _FrameReport {
  const _FrameReport({
    required this.slot,
    required this.generation,
    required this.address,
    required this.checksum,
    required this.elapsedMilliseconds,
  });

  final int slot;
  final int generation;
  final int address;
  final int checksum;
  final int elapsedMilliseconds;
}

final class _ConsumerResult {
  const _ConsumerResult({
    required this.frames,
    required this.nativeWaitCount,
    required this.elapsedMilliseconds,
    required this.endedWith,
  });

  final List<_FrameReport> frames;

  /// How many times the consumer entered the platform's wait function.
  ///
  /// The number that separates blocking from spinning. Both deliver the same
  /// bytes at the same moment; only this tells them apart.
  final int nativeWaitCount;

  final int elapsedMilliseconds;

  /// The runtime type of whatever ended the loop, by name.
  final String endedWith;
}

/// The byte a frame carries at [index]; deterministic, so the test can compute
/// the expected checksum without reading the ring.
int _patternByte(int frame, int index) => (frame * 7 + index) & 0xFF;

int _checksum(Uint8List bytes, int stride) {
  var sum = 0;
  for (var at = 0; at < bytes.length; at += stride) {
    sum = (sum + bytes[at]) & 0xFFFFFF;
  }
  return sum;
}

const int _checksumStride = 97;

void _produceFrames(_ProduceRequest request) {
  final BlockingSlotMailbox mailbox =
      BlockingSlotMailbox.attach(request.mailboxAddress);
  try {
    sleep(Duration(milliseconds: request.startDelayMilliseconds));
    for (var frame = 0; frame < request.geometry.slotCount; frame++) {
      final Uint8List bytes =
          Pointer<Uint8>.fromAddress(request.geometry.addressOf(frame))
              .asTypedList(request.geometry.bytesPerSlot);
      for (var at = 0; at < bytes.length; at++) {
        bytes[at] = _patternByte(frame, at);
      }
      mailbox.put(frame, request.generation,
          timeout: const Duration(seconds: 10));
    }
    request.reply.send('produced');
  } on Object catch (error) {
    request.reply.send('producer failed: $error');
  } finally {
    mailbox.detach();
  }
}

void _consumeFrames(_ConsumeRequest request) {
  final BlockingSlotMailbox mailbox =
      BlockingSlotMailbox.attach(request.mailboxAddress);
  final Stopwatch elapsed = Stopwatch()..start();
  final List<_FrameReport> frames = <_FrameReport>[];
  String endedWith = 'never ended';
  try {
    while (true) {
      final MailboxSlot taken = mailbox.takeBlocking(
          timeout: Duration(milliseconds: request.timeoutMilliseconds));
      final Uint8List bytes =
          Pointer<Uint8>.fromAddress(request.geometry.addressOf(taken.slot))
              .asTypedList(request.geometry.bytesPerSlot);
      frames.add(_FrameReport(
        slot: taken.slot,
        generation: taken.generation,
        address: request.geometry.addressOf(taken.slot),
        checksum: _checksum(bytes, _checksumStride),
        elapsedMilliseconds: elapsed.elapsedMilliseconds,
      ));
      // Written *through* the shared ring. If anything on this path had
      // copied, the owner would read its own untouched bytes back.
      bytes[bytes.length - 1] = request.stamp;
    }
  } on Object catch (error) {
    endedWith = error.runtimeType.toString();
  }
  request.reply.send(_ConsumerResult(
    frames: frames,
    nativeWaitCount: mailbox.nativeWaitCount,
    elapsedMilliseconds: elapsed.elapsedMilliseconds,
    endedWith: endedWith,
  ));
  mailbox.detach();
}

/// Blocks on an empty mailbox until the timeout expires, then reports it.
void _waitForNothing(List<Object> request) {
  final SendPort reply = request[0] as SendPort;
  final int address = request[1] as int;
  final int timeoutMilliseconds = request[2] as int;
  final BlockingSlotMailbox mailbox = BlockingSlotMailbox.attach(address);
  final Stopwatch elapsed = Stopwatch()..start();
  String outcome = 'returned a frame, which is wrong';
  try {
    mailbox.takeBlocking(timeout: Duration(milliseconds: timeoutMilliseconds));
  } on Object catch (error) {
    outcome = error.runtimeType.toString();
  }
  reply.send(<Object>[
    outcome,
    elapsed.elapsedMilliseconds,
    mailbox.nativeWaitCount,
  ]);
  mailbox.detach();
}

/// Calls the blocking take on an isolate pretending to be the root one.
void _takeOnFakeRoot(List<Object> request) {
  final SendPort reply = request[0] as SendPort;
  final int address = request[1] as int;
  final bool optIn = request[2] as bool;
  final BlockingSlotMailbox mailbox = BlockingSlotMailbox.attach(address);
  if (optIn) BlockingWaitPolicy.allowOnThisIsolate();
  String outcome = 'returned normally';
  try {
    mailbox.takeBlocking(timeout: const Duration(milliseconds: 120));
  } on Object catch (error) {
    outcome = error.runtimeType.toString();
  }
  reply.send(outcome);
  mailbox.detach();
}

Future<void> _untilQuiet(bool Function() condition, Duration limit) async {
  final Stopwatch elapsed = Stopwatch()..start();
  while (!condition() && elapsed.elapsed < limit) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  group('two isolates over one ring', () {
    test('the consumer blocks, wakes with the frame, and nothing is copied',
        () async {
      const int slotCount = 3;
      const int bytesPerSlot = 64 * 1024;
      const int stamp = 0xC3;
      final NativeVideoFrameRing ring = NativeVideoFrameRing(
        slotCount: slotCount,
        bytesPerSlot: bytesPerSlot,
      );
      // Leases taken up front so the test holds the ring's own view of every
      // slot, which is what the consumer's reported addresses are checked
      // against.
      final List<NativeVideoFrameLease> leases = <NativeVideoFrameLease>[
        for (var i = 0; i < slotCount; i++) ring.acquire(),
      ];
      final _RingGeometry geometry = _RingGeometry(
        leases.first.pointer.address,
        bytesPerSlot,
        slotCount,
      );
      final BlockingSlotMailbox mailbox =
          BlockingSlotMailbox.allocate(capacity: slotCount);

      final ReceivePort consumerReplies = ReceivePort();
      final ReceivePort producerReplies = ReceivePort();
      final ReceivePort consumerExited = ReceivePort();
      final ReceivePort producerExited = ReceivePort();
      final StreamIterator<Object?> consumerEvents =
          StreamIterator<Object?>(consumerReplies);
      final StreamIterator<Object?> producerEvents =
          StreamIterator<Object?>(producerReplies);

      await Isolate.spawn(
        _consumeFrames,
        _ConsumeRequest(
          reply: consumerReplies.sendPort,
          mailboxAddress: mailbox.address,
          geometry: geometry,
          stamp: stamp,
          timeoutMilliseconds: 15000,
        ),
        onExit: consumerExited.sendPort,
        debugName: 'frame-consumer',
      );

      // The consumer must be parked before anything is published, or the test
      // would pass just as well against a mailbox that never blocks.
      await _untilQuiet(
          () => mailbox.parkedWaiters == 1, const Duration(seconds: 10));
      expect(mailbox.parkedWaiters, 1,
          reason: 'the consumer should be parked in the native wait by now');

      await Isolate.spawn(
        _produceFrames,
        _ProduceRequest(
          reply: producerReplies.sendPort,
          mailboxAddress: mailbox.address,
          geometry: geometry,
          generation: leases.first.generation,
          startDelayMilliseconds: 350,
        ),
        onExit: producerExited.sendPort,
        debugName: 'frame-producer',
      );

      expect(await producerEvents.moveNext(), isTrue);
      expect(producerEvents.current, 'produced');

      // The consumer is now parked again on an empty mailbox. Closing here is
      // the shutdown-with-a-waiter case: the waiter must be woken and must
      // leave by name, not sit there.
      await _untilQuiet(
          () => mailbox.parkedWaiters == 1, const Duration(seconds: 10));
      expect(
        mailbox.dispose,
        throwsA(isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('parked'),
        )),
        reason: 'freeing the block under a sleeping thread is the corruption '
            'this whole layer is written to avoid',
      );

      expect(await consumerEvents.moveNext(), isTrue);
      final _ConsumerResult result = consumerEvents.current as _ConsumerResult;
      await consumerEvents.cancel();
      await producerEvents.cancel();
      await consumerExited.first;
      await producerExited.first;
      consumerExited.close();
      producerExited.close();

      expect(result.endedWith, 'MailboxClosedException',
          reason: 'a consumer loop ends because the producer shut down');
      expect(result.frames, hasLength(slotCount));

      for (var frame = 0; frame < slotCount; frame++) {
        final _FrameReport report = result.frames[frame];
        expect(report.slot, frame, reason: 'the queue is FIFO');
        expect(report.generation, leases[frame].generation,
            reason: 'the generation is what lets the consumer notice the ring '
                'wrapped while the message was in flight');

        // **No copy, checked by address.** The consumer derived this from the
        // slot index the mailbox carried; the ring derived its own from the
        // allocation. They are the same bytes.
        expect(
          report.address,
          leases[frame].pointer.address,
          reason: 'the consumer must read the producer\'s memory, not a copy '
              'of it',
        );

        var expected = 0;
        for (var at = 0; at < bytesPerSlot; at += _checksumStride) {
          expected = (expected + _patternByte(frame, at)) & 0xFFFFFF;
        }
        expect(report.checksum, expected,
            reason: 'and the bytes at that address are the ones written');

        // Aliasing, from the other direction: the consumer's write is visible
        // to the owner through the ring's own view.
        expect(leases[frame].bytes[bytesPerSlot - 1], stamp);
        expect(leases[frame].isValid, isTrue);
      }

      // Blocked, not spun. A 350 ms wait costs two native waits at a 250 ms
      // slice; the three frames that follow cost a few more. A spin loop over
      // `tryTake` would have run this into six figures.
      expect(result.frames.first.elapsedMilliseconds, greaterThanOrEqualTo(300),
          reason: 'the consumer really waited for the producer');
      expect(
        result.nativeWaitCount,
        inInclusiveRange(1, 20),
        reason: 'blocking, not polling: got ${result.nativeWaitCount} native '
            'waits over ${result.elapsedMilliseconds} ms',
      );

      // Teardown, in the order the class documents: closed, waiters gone,
      // then and only then freed.
      expect(mailbox.parkedWaiters, 0);
      expect(mailbox.isClosed, isTrue);
      expect(mailbox.putTotal, slotCount);
      expect(mailbox.takeTotal, slotCount);
      mailbox.dispose();
      ring.dispose();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a wait for something that never comes fails by name, in time',
        () async {
      final BlockingSlotMailbox mailbox =
          BlockingSlotMailbox.allocate(capacity: 2);
      final ReceivePort replies = ReceivePort();
      final ReceivePort exited = ReceivePort();
      await Isolate.spawn(
        _waitForNothing,
        <Object>[replies.sendPort, mailbox.address, 400],
        onExit: exited.sendPort,
        debugName: 'lonely-consumer',
      );
      final List<Object?> report = (await replies.first) as List<Object?>;
      await exited.first;
      replies.close();
      exited.close();

      expect(report[0], 'BlockingWaitTimeout',
          reason: 'a frozen application with no message is the worst outcome '
              'this framework can produce; the timeout must be named');
      expect(report[1]! as int, greaterThanOrEqualTo(380),
          reason: 'it must actually have waited');
      expect(report[1]! as int, lessThan(5000),
          reason: 'and it must have stopped waiting');
      expect(report[2]! as int, inInclusiveRange(1, 10),
          reason: 'a 400 ms wait is two slices, not a poll loop');

      expect(mailbox.parkedWaiters, 0);
      mailbox.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('the blocking take refuses on an isolate that looks like the root',
        () async {
      final BlockingSlotMailbox mailbox =
          BlockingSlotMailbox.allocate(capacity: 1);

      Future<String> outcomeWith({required bool optIn}) async {
        final ReceivePort replies = ReceivePort();
        final ReceivePort exited = ReceivePort();
        await Isolate.spawn(
          _takeOnFakeRoot,
          <Object>[replies.sendPort, mailbox.address, optIn],
          onExit: exited.sendPort,
          // The whole point: `Isolate.current.debugName` is `main` on the root
          // isolate of a VM, in JIT and in AOT alike, and this is the only way
          // to reproduce that from a test - the test runner's own isolate is
          // called `test_suite:<uri>`.
          debugName: 'main',
        );
        final String outcome = (await replies.first) as String;
        await exited.first;
        replies.close();
        exited.close();
        return outcome;
      }

      expect(
        await outcomeWith(optIn: false),
        'BlockingWaitOnRootIsolateError',
        reason: 'parking the isolate that services the UI is a frozen window, '
            'not a slow frame',
      );
      expect(
        await outcomeWith(optIn: true),
        'BlockingWaitTimeout',
        reason: 'an isolate that has declared it drives no window gets the '
            'ordinary bounded wait',
      );

      mailbox.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('single isolate behaviour', () {
    test('the non-blocking forms never park, so they are legal anywhere', () {
      final BlockingSlotMailbox mailbox =
          BlockingSlotMailbox.allocate(capacity: 2);
      addTearDown(mailbox.dispose);
      expect(mailbox.tryTake(), isNull);
      expect(mailbox.tryPut(1, 5), isTrue);
      expect(mailbox.tryPut(0, 6), isTrue);
      expect(mailbox.tryPut(2, 7), isFalse, reason: 'capacity is two');
      final MailboxSlot? first = mailbox.tryTake();
      expect(first?.slot, 1);
      expect(first?.generation, 5);
      expect(mailbox.tryTake()?.slot, 0);
      expect(mailbox.tryTake(), isNull);
    });

    test('a queue drains before it reports being closed', () {
      // Otherwise a shutdown drops whatever the producer had already
      // published, which for a decoder is the last frames of the file.
      final BlockingSlotMailbox mailbox =
          BlockingSlotMailbox.allocate(capacity: 2);
      addTearDown(mailbox.dispose);
      expect(mailbox.tryPut(1, 1), isTrue);
      mailbox.close();
      expect(mailbox.takeBlocking().slot, 1);
      expect(mailbox.takeBlocking, throwsA(isA<MailboxClosedException>()));
    });

    test('attaching to something that is not a mailbox is refused', () {
      // The alternative is calling a lock primitive on whatever happens to be
      // at that address, and that does not fail, it corrupts.
      final BlockingSlotMailbox mailbox =
          BlockingSlotMailbox.allocate(capacity: 1);
      addTearDown(mailbox.dispose);
      expect(() => BlockingSlotMailbox.attach(0), throwsArgumentError);
      expect(
        () => BlockingSlotMailbox.attach(mailbox.address + 8),
        throwsA(isA<StateError>()),
      );
    });

    test('teardown is asymmetric, and each half refuses the other', () {
      // The two halves are not interchangeable and both mistakes are silent:
      // an attached handle freeing the block pulls it out from under the
      // owner, and an owner detaching leaks the block, the mutex and both
      // condition variables while looking like a clean shutdown.
      final BlockingSlotMailbox owner =
          BlockingSlotMailbox.allocate(capacity: 1);
      final BlockingSlotMailbox attached =
          BlockingSlotMailbox.attach(owner.address);
      expect(attached.dispose, throwsA(isA<StateError>()));
      expect(owner.detach, throwsA(isA<StateError>()));
      attached.detach();
      owner.dispose();
    });
  });
}
