/// The platform primitives, checked rather than assumed.
///
/// Two things in this layer are claims about an ABI this repository cannot
/// see: how big the platform's mutex and condition variable are, and which
/// library exports them. Both are the kind of mistake that does not fail - a
/// mutex that is bigger than its reservation quietly writes over the field
/// next to it, and a symbol resolved out of the wrong library works until it
/// does not. So both are asserted here, on every platform CI runs.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_ui/src/concurrency/blocking_wait.dart';
import 'package:dart_ui/src/concurrency/native_condition_variable.dart';
import 'package:dart_ui/src/concurrency/native_mutex.dart';
import 'package:dart_ui/src/concurrency/native_sync_bindings.dart';
import 'package:test/test.dart';

/// Holds [address] locked for [holdMilliseconds], then releases and exits.
///
/// A stand-in for the isolate that is slow, and - if it were to exit without
/// releasing - for the isolate that died inside its critical section. The
/// difference between the two is invisible to everybody else, which is the
/// whole reason [NativeMutex.acquire] has a deadline.
void holdLock(List<Object> request) {
  final SendPort reply = request[0] as SendPort;
  final int address = request[1] as int;
  final int holdMilliseconds = request[2] as int;
  final NativeMutex mutex = NativeMutex.attach(address);
  mutex.acquire(timeout: const Duration(seconds: 2));
  reply.send('held');
  sleep(Duration(milliseconds: holdMilliseconds));
  mutex.release();
  reply.send('released');
}

void main() {
  group('symbol resolution', () {
    test('the platform pair binds, and says where it came from', () {
      expect(
        NativeSyncApi.isAvailable,
        isTrue,
        reason: 'nothing bound: ${NativeSyncApi.missingSymbol}',
      );
      final NativeSyncApi api = NativeSyncApi.instance;
      // Printed rather than only asserted: when a CI machine deadlocks, the
      // first question is which implementation was underneath, and the answer
      // has to already be in the log.
      printOnFailure('native sync provenance: ${api.provenance}');
      expect(api.provenance, isNotEmpty);
      expect(
        api.flavor,
        Platform.isWindows
            ? NativeSyncFlavor.slimReaderWriterLock
            : NativeSyncFlavor.pthread,
      );
      expect(
        api.waitScratchBytes,
        Platform.isWindows ? 0 : 16,
        reason: 'POSIX needs one struct timespec of private scratch per '
            'waiting isolate; Windows takes a relative millisecond count',
      );
    });

    test('this process is 64-bit, which the timespec layout assumes', () {
      // `struct timespec` is written as two 64-bit fields. On a 32-bit POSIX
      // target `long` is four bytes and that layout is wrong - silently, in
      // the direction of a deadline in the distant past or the distant future.
      expect(sizeOf<Pointer<Void>>(), 8);
    });
  });

  group('ABI reservations', () {
    test('a mutex fits its reservation, and the sentinel proves it', () {
      final NativeMutex mutex = NativeMutex.allocate();
      addTearDown(mutex.destroy);
      // Checked at construction too; repeated after real use because an
      // overrun by a lock's *contended* state would not show up at init.
      mutex.checkGuard();
      expect(mutex.tryAcquire(), isTrue);
      mutex.release();
      mutex.runLocked(() {});
      mutex.checkGuard();
    });

    test('a condition variable fits its reservation', () {
      final NativeMutex mutex = NativeMutex.allocate();
      final NativeConditionVariable condition =
          NativeConditionVariable.allocate();
      addTearDown(() {
        condition.destroy();
        mutex.destroy();
      });
      condition.checkGuard();
      // A wait that times out still exercises the parked-waiter state, which
      // is where a condition variable actually uses its bytes.
      mutex.acquire();
      expect(
        condition.waitFor(mutex, const Duration(milliseconds: 30)),
        isFalse,
        reason: 'nobody signalled it, so it must report the timeout',
      );
      mutex.release();
      condition.checkGuard();
      mutex.checkGuard();
    });

    test('the reservation is documented as larger than any known size', () {
      // The table in `nativeMutexReservedBytes` lists 64 as the largest
      // `pthread_mutex_t` in the wild (macOS). This is the assertion that the
      // constant was not later trimmed to "just enough".
      expect(nativeMutexReservedBytes, greaterThanOrEqualTo(128));
      expect(nativeConditionReservedBytes, greaterThanOrEqualTo(128));
      expect(nativeSyncGuardBytes, greaterThanOrEqualTo(16));
    });

    test('a corrupted sentinel is reported by name', () {
      // The negative half: without this, "the guard never fired" and "the
      // guard cannot fire" look the same.
      final NativeMutex mutex = NativeMutex.allocate();
      addTearDown(mutex.destroy);
      final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(mutex.address);
      memory.asTypedList(
          nativeMutexReservedBytes + 1)[nativeMutexReservedBytes] = 0;
      expect(
        mutex.checkGuard,
        throwsA(isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('overran'),
        )),
      );
    });
  });

  group('NativeMutex', () {
    test('runLocked releases when the body throws', () {
      final NativeMutex mutex = NativeMutex.allocate();
      addTearDown(mutex.destroy);
      expect(
        () => mutex.runLocked<void>(() => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      // The failure this guards against is a lock left held forever by an
      // early return or a bounds check, which every later isolate inherits.
      expect(mutex.tryAcquire(), isTrue);
      mutex.release();
    });

    test('acquire gives up by name instead of hanging', () async {
      final NativeMutex mutex = NativeMutex.allocate();
      final ReceivePort replies = ReceivePort();
      final ReceivePort exited = ReceivePort();
      // A StreamIterator and not a broadcast stream: a broadcast stream drops
      // whatever arrives while nothing is listening, and the gap between one
      // `first` completing and the next subscribing is exactly where the
      // holder's second message would vanish.
      final StreamIterator<Object?> events = StreamIterator<Object?>(replies);
      await Isolate.spawn(
        holdLock,
        <Object>[replies.sendPort, mutex.address, 900],
        onExit: exited.sendPort,
        debugName: 'holder',
      );
      expect(await events.moveNext(), isTrue);
      expect(events.current, 'held');

      // The dead-holder scenario, minus the death: `AcquireSRWLockExclusive`
      // and `pthread_mutex_lock` would wait here forever with no way to say
      // so. This must fail, and it must fail with a name.
      final Stopwatch elapsed = Stopwatch()..start();
      expect(
        () => mutex.acquire(timeout: const Duration(milliseconds: 200)),
        throwsA(isA<BlockingWaitTimeout>()),
      );
      elapsed.stop();
      expect(elapsed.elapsedMilliseconds, lessThan(1500),
          reason: 'the deadline must be honoured, not merely reported');

      expect(await events.moveNext(), isTrue);
      expect(events.current, 'released');
      await events.cancel();
      await exited.first;
      replies.close();
      exited.close();

      // And once the holder is gone the lock is usable again: a timeout is a
      // report about the wait, not damage to the lock.
      mutex.acquire(timeout: const Duration(seconds: 2));
      mutex.release();
      mutex.destroy();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('BlockingWaitPolicy', () {
    test('the root isolate is recognised, and this one is not it', () {
      // The test runner spawns a suite isolate named `test_suite:<uri>`, so
      // every blocking call in this file is legal. That is worth asserting:
      // if a future runner changed this, the tests here would start failing
      // for a reason that has nothing to do with the code under test.
      expect(Isolate.current.debugName, isNot('main'));
      expect(BlockingWaitPolicy.isRootIsolate, isFalse);
    });

    test('the override is isolate-local and reversible', () {
      BlockingWaitPolicy.allowOnThisIsolate();
      addTearDown(BlockingWaitPolicy.refuseOnThisIsolate);
      expect(() => BlockingWaitPolicy.check('anything'), returnsNormally);
    });
  });
}
