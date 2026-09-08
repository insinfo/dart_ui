/// The general-purpose byte handoff, and the refusal that keeps frames out.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_ui/src/concurrency/blocking_byte_mailbox.dart';
import 'package:dart_ui/src/concurrency/blocking_slot_mailbox.dart';
import 'package:dart_ui/src/concurrency/blocking_wait.dart';
import 'package:test/test.dart';

/// Sends one message after a delay, so the consumer has to park for it.
void _sendAfterDelay(List<Object> request) {
  final SendPort reply = request[0] as SendPort;
  final int address = request[1] as int;
  final int delayMilliseconds = request[2] as int;
  final int length = request[3] as int;
  final BlockingByteMailbox mailbox = BlockingByteMailbox.attach(address);
  try {
    sleep(Duration(milliseconds: delayMilliseconds));
    final Uint8List payload = Uint8List(length);
    for (var at = 0; at < length; at++) {
      payload[at] = (at * 31 + 7) & 0xFF;
    }
    mailbox.put(payload, timeout: const Duration(seconds: 10));
    reply.send('sent');
  } on Object catch (error) {
    reply.send('failed: $error');
  } finally {
    mailbox.detach();
  }
}

void main() {
  test('a consumer parks for a message and gets the bytes', () async {
    const int length = 4096;
    final BlockingByteMailbox mailbox = BlockingByteMailbox.allocate();
    final ReceivePort replies = ReceivePort();
    final ReceivePort exited = ReceivePort();
    await Isolate.spawn(
      _sendAfterDelay,
      <Object>[replies.sendPort, mailbox.address, 300, length],
      onExit: exited.sendPort,
      debugName: 'byte-producer',
    );

    final Stopwatch elapsed = Stopwatch()..start();
    final Uint8List received =
        mailbox.takeBlocking(timeout: const Duration(seconds: 10));
    elapsed.stop();

    expect(received, hasLength(length));
    for (var at = 0; at < length; at++) {
      if (received[at] != (at * 31 + 7) & 0xFF) {
        fail('byte $at differs: ${received[at]}');
      }
    }
    expect(elapsed.elapsedMilliseconds, greaterThanOrEqualTo(250),
        reason: 'the take really waited for the producer');
    expect(mailbox.nativeWaitCount, inInclusiveRange(1, 10),
        reason: 'blocked, rather than polled');

    expect(await replies.first, 'sent');
    await exited.first;
    replies.close();
    exited.close();
    mailbox.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a payload big enough to be a frame is refused', () {
    // The whole reason this class documents itself as the wrong tool for
    // pixels: two copies of 7.91 MiB, twenty-five times a second, is the
    // measured 3.47x regression `NativeVideoFrameRing` exists to avoid. The
    // limit is enforced rather than left to the comment.
    final BlockingByteMailbox mailbox = BlockingByteMailbox.allocate();
    addTearDown(mailbox.dispose);
    expect(
      () => mailbox.put(Uint8List(BlockingByteMailbox.maximumPayloadBytes + 1)),
      throwsA(isA<ArgumentError>().having(
        (ArgumentError error) => '${error.message}',
        'message',
        contains('shared ring'),
      )),
    );
  });

  test('a timed-out put does not leak the payload it allocated', () {
    // The box is full and stays full, so the copy `put` made never reaches
    // anybody who could free it. One leak per timed-out message adds up on a
    // path whose entire purpose is a stuck producer.
    final BlockingByteMailbox mailbox = BlockingByteMailbox.allocate();
    addTearDown(mailbox.dispose);
    mailbox.put(Uint8List.fromList(<int>[1, 2, 3]));
    expect(mailbox.hasValue, isTrue);
    expect(
      () => mailbox.put(Uint8List.fromList(<int>[4]),
          timeout: const Duration(milliseconds: 60)),
      throwsA(isA<BlockingWaitTimeout>()),
    );
    expect(mailbox.tryTake(), <int>[1, 2, 3],
        reason: 'the failed put must not have displaced the message');
  });

  test('an undelivered message is freed with the mailbox', () {
    final BlockingByteMailbox mailbox = BlockingByteMailbox.allocate();
    mailbox.put(Uint8List.fromList(<int>[9, 9, 9]));
    expect(mailbox.hasValue, isTrue);
    // Nobody will ever take it, so dispose owns it now. Without this the
    // buffer outlives every reference to it.
    mailbox.dispose();
  });

  test('closing wakes a taker that would otherwise wait forever', () {
    final BlockingByteMailbox mailbox = BlockingByteMailbox.allocate();
    addTearDown(mailbox.dispose);
    mailbox.close();
    expect(
      () => mailbox.takeBlocking(timeout: const Duration(seconds: 5)),
      throwsA(isA<MailboxClosedException>()),
    );
  });
}
