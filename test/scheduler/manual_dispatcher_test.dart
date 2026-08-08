// Imported through the barrel on purpose: it is the surface a backend or a
// widget-layer test will actually depend on, so it needs a consumer.
import 'package:dart_ui/src/scheduler/scheduler.dart';
import 'package:test/test.dart';

void main() {
  group('ManualDispatcher ordering', () {
    test('runs every priority in strict order, most urgent first', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      for (final priority in DispatcherPriority.values.reversed) {
        dispatcher.post(() => log.add(priority.name), priority: priority);
      }
      dispatcher.drain();

      expect(
        log,
        DispatcherPriority.values.map((priority) => priority.name).toList(),
      );
    });

    test('is FIFO within one priority', () {
      final dispatcher = ManualDispatcher();
      final log = <int>[];

      for (var index = 0; index < 5; index++) {
        dispatcher.post(
          () => log.add(index),
          priority: DispatcherPriority.animation,
        );
      }
      dispatcher.drain();

      expect(log, <int>[0, 1, 2, 3, 4]);
    });

    test('post defaults to normal priority', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.post(() => log.add('default'));
      dispatcher.post(
        () => log.add('explicit'),
        priority: DispatcherPriority.normal,
      );
      dispatcher.post(() => log.add('idle'), priority: DispatcherPriority.idle);
      dispatcher.drain();

      expect(log, <String>['default', 'explicit', 'idle']);
    });

    test('an urgent post from inside a callback overtakes queued work', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.post(
        () {
          log.add('idle-1');
          dispatcher.post(
            () => log.add('input'),
            priority: DispatcherPriority.input,
          );
        },
        priority: DispatcherPriority.idle,
      );
      dispatcher.post(
        () => log.add('idle-2'),
        priority: DispatcherPriority.idle,
      );
      dispatcher.drain();

      expect(log, <String>['idle-1', 'input', 'idle-2']);
    });

    test('drain means empty, including work posted while draining', () {
      final dispatcher = ManualDispatcher();
      final log = <int>[];

      void chain(int step) {
        log.add(step);
        if (step < 4) dispatcher.post(() => chain(step + 1));
      }

      dispatcher.post(() => chain(0));
      dispatcher.drain();

      expect(log, <int>[0, 1, 2, 3, 4]);
      expect(dispatcher.pendingCallbackCount, 0);
    });

    test('a callback is never pre-empted mid-flight', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.post(() {
        log.add('outer-start');
        dispatcher.post(
          () => log.add('immediate'),
          priority: DispatcherPriority.immediate,
        );
        log.add('outer-end');
      });
      dispatcher.drain();

      expect(log, <String>['outer-start', 'outer-end', 'immediate']);
    });

    test('draining an empty dispatcher does nothing', () {
      final dispatcher = ManualDispatcher();
      dispatcher.drain();
      expect(dispatcher.elapsed, Duration.zero);
      expect(dispatcher.pendingCallbackCount, 0);
    });

    test('drain does not move virtual time, so timers do not fire', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.schedule(Duration.zero, () => log.add('timer'));
      dispatcher.post(() => log.add('callback'));
      dispatcher.drain();

      expect(log, <String>['callback']);
      expect(dispatcher.pendingTimerCount, 1);
      expect(dispatcher.elapsed, Duration.zero);
    });
  });

  group('ManualDispatcher virtual time', () {
    test('fires timers in time order across several advances', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.schedule(const Duration(milliseconds: 30), () {
        log.add('c');
      });
      dispatcher.schedule(const Duration(milliseconds: 10), () {
        log.add('a');
      });
      dispatcher.schedule(const Duration(milliseconds: 20), () {
        log.add('b');
      });

      dispatcher.advance(const Duration(milliseconds: 15));
      expect(log, <String>['a']);
      expect(dispatcher.elapsed, const Duration(milliseconds: 15));

      dispatcher.advance(const Duration(milliseconds: 10));
      expect(log, <String>['a', 'b']);

      dispatcher.advance(const Duration(milliseconds: 10));
      expect(log, <String>['a', 'b', 'c']);
      expect(dispatcher.elapsed, const Duration(milliseconds: 35));
      expect(dispatcher.pendingTimerCount, 0);
    });

    test('timers due at the same instant fire in scheduling order', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      for (final name in <String>['first', 'second', 'third']) {
        dispatcher.schedule(
          const Duration(milliseconds: 10),
          () => log.add(name),
        );
      }
      dispatcher.advance(const Duration(milliseconds: 10));

      expect(log, <String>['first', 'second', 'third']);
    });

    test('elapsed is the timer instant while its callback runs', () {
      final dispatcher = ManualDispatcher();
      final seen = <Duration>[];

      dispatcher.schedule(const Duration(milliseconds: 10), () {
        seen.add(dispatcher.elapsed);
      });
      dispatcher.schedule(const Duration(milliseconds: 20), () {
        seen.add(dispatcher.elapsed);
      });
      dispatcher.advance(const Duration(milliseconds: 50));

      expect(seen, <Duration>[
        const Duration(milliseconds: 10),
        const Duration(milliseconds: 20),
      ]);
      expect(dispatcher.elapsed, const Duration(milliseconds: 50));
    });

    test('a timer scheduled by a timer fires in the same advance', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.schedule(const Duration(milliseconds: 10), () {
        log.add('a@${dispatcher.elapsed.inMilliseconds}');
        dispatcher.schedule(const Duration(milliseconds: 5), () {
          log.add('b@${dispatcher.elapsed.inMilliseconds}');
        });
      });
      dispatcher.advance(const Duration(milliseconds: 50));

      expect(log, <String>['a@10', 'b@15']);
    });

    test('a timer scheduled past the window waits for the next advance', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.schedule(const Duration(milliseconds: 10), () {
        dispatcher.schedule(const Duration(milliseconds: 100), () {
          log.add('late');
        });
      });

      dispatcher.advance(const Duration(milliseconds: 50));
      expect(log, isEmpty);
      expect(dispatcher.nextTimerDue, const Duration(milliseconds: 110));

      dispatcher.advance(const Duration(milliseconds: 60));
      expect(log, <String>['late']);
    });

    test('advance drains the queue at every instant it visits', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.post(() => log.add('queued before advance'));
      dispatcher.schedule(const Duration(milliseconds: 10), () {
        log.add('timer 1');
        dispatcher.post(() => log.add('posted by timer 1'));
      });
      dispatcher.schedule(const Duration(milliseconds: 20), () {
        log.add('timer 2');
      });
      dispatcher.advance(const Duration(milliseconds: 50));

      expect(log, <String>[
        'queued before advance',
        'timer 1',
        'posted by timer 1',
        'timer 2',
      ]);
    });

    test('one big advance equals several small ones', () {
      List<String> script(List<Duration> steps) {
        final dispatcher = ManualDispatcher();
        final log = <String>[];
        for (var index = 1; index <= 3; index++) {
          dispatcher.schedule(Duration(seconds: index), () {
            log.add('timer $index @${dispatcher.elapsed.inSeconds}');
            dispatcher.post(() => log.add('post $index'));
          });
        }
        for (final step in steps) {
          dispatcher.advance(step);
        }
        return log;
      }

      expect(
        script(<Duration>[const Duration(seconds: 3)]),
        script(<Duration>[
          const Duration(seconds: 1),
          const Duration(seconds: 1),
          const Duration(seconds: 1),
        ]),
      );
    });

    test('a zero or negative delay is due immediately', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.schedule(Duration.zero, () => log.add('zero'));
      dispatcher.schedule(
        const Duration(milliseconds: -5),
        () => log.add('negative'),
      );
      dispatcher.advance(Duration.zero);

      expect(log, <String>['zero', 'negative']);
      expect(dispatcher.elapsed, Duration.zero);
    });

    test('advance refuses to move time backwards', () {
      final dispatcher = ManualDispatcher();
      expect(
        () => dispatcher.advance(const Duration(milliseconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a day of virtual time costs no measurable real time', () {
      final dispatcher = ManualDispatcher();
      final fired = <Duration>[];
      for (var hour = 1; hour <= 24; hour++) {
        dispatcher.schedule(
          Duration(hours: hour),
          () => fired.add(dispatcher.elapsed),
        );
      }

      final stopwatch = Stopwatch()..start();
      dispatcher.advance(const Duration(days: 1));
      stopwatch.stop();

      expect(fired, hasLength(24));
      expect(fired.first, const Duration(hours: 1));
      expect(fired.last, const Duration(hours: 24));
      expect(dispatcher.elapsed, const Duration(days: 1));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('the same script produces the same log whenever it is run', () {
      List<String> script() {
        final dispatcher = ManualDispatcher();
        final log = <String>[];
        dispatcher.post(
          () => log.add('render'),
          priority: DispatcherPriority.render,
        );
        dispatcher.post(
          () => log.add('input'),
          priority: DispatcherPriority.input,
        );
        dispatcher.schedule(const Duration(milliseconds: 16), () {
          log.add('frame @${dispatcher.elapsed.inMilliseconds}');
        });
        dispatcher.advance(const Duration(milliseconds: 33));
        return log;
      }

      final first = script();
      final busy = List<int>.generate(200000, (index) => index)
          .fold<int>(0, (sum, value) => sum + value);
      final second = script();

      expect(busy, greaterThan(0));
      expect(second, first);
    });
  });

  group('ManualDispatcher cancellation', () {
    test('a cancelled timer never fires', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      final handle = dispatcher.schedule(
        const Duration(milliseconds: 10),
        () => log.add('timer'),
      );
      expect(dispatcher.pendingTimerCount, 1);

      handle.cancel();

      expect(dispatcher.pendingTimerCount, 0);
      expect(handle.isActive, isFalse);
      dispatcher.advance(const Duration(milliseconds: 50));
      expect(log, isEmpty);
    });

    test('cancelling twice does not disturb the other timers', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.schedule(
        const Duration(milliseconds: 5),
        () => log.add('keep me'),
      );
      final handle = dispatcher.schedule(
        const Duration(milliseconds: 10),
        () => log.add('drop me'),
      );

      handle.cancel();
      handle.cancel();

      expect(dispatcher.pendingTimerCount, 1);
      dispatcher.advance(const Duration(milliseconds: 50));
      expect(log, <String>['keep me']);
    });

    test('cancelling an already fired timer is a no-op', () {
      final dispatcher = ManualDispatcher();
      var runs = 0;

      final handle = dispatcher.schedule(
        const Duration(milliseconds: 10),
        () => runs++,
      );
      dispatcher.advance(const Duration(milliseconds: 20));
      handle.cancel();
      dispatcher.advance(const Duration(milliseconds: 20));

      expect(runs, 1);
      expect(handle.isActive, isFalse);
      expect(handle.isCancelled, isFalse);
    });

    test('a callback can cancel a timer that has not fired yet', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];
      late final TimerHandle second;

      dispatcher.schedule(const Duration(milliseconds: 10), () {
        log.add('first');
        second.cancel();
      });
      second = dispatcher.schedule(
        const Duration(milliseconds: 20),
        () => log.add('second'),
      );

      dispatcher.advance(const Duration(milliseconds: 50));

      expect(log, <String>['first']);
      expect(second.isCancelled, isTrue);
      expect(dispatcher.pendingTimerCount, 0);
    });

    test('a timer can cancel itself from inside its own callback', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];
      late final TimerHandle self;

      self = dispatcher.schedule(const Duration(milliseconds: 10), () {
        log.add('active during callback: ${self.isActive}');
        self.cancel();
        log.add('active after cancel: ${self.isActive}');
      });
      dispatcher.advance(const Duration(milliseconds: 50));

      expect(log, <String>[
        'active during callback: false',
        'active after cancel: false',
      ]);
      expect(self.isCancelled, isFalse);
    });

    test('a queued callback can cancel a timer before time moves', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      final handle = dispatcher.schedule(
        const Duration(milliseconds: 10),
        () => log.add('timer'),
      );
      dispatcher.post(handle.cancel);
      dispatcher.advance(const Duration(milliseconds: 50));

      expect(log, isEmpty);
    });
  });

  group('ManualDispatcher error policy', () {
    test('an error propagates and leaves the rest of the queue intact', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.post(
        () => throw StateError('boom'),
        priority: DispatcherPriority.input,
      );
      dispatcher.post(() => log.add('survivor'));

      expect(dispatcher.drain, throwsA(isA<StateError>()));
      expect(log, isEmpty);
      expect(dispatcher.pendingCallbackCount, 1);

      dispatcher.drain();

      expect(log, <String>['survivor']);
      expect(dispatcher.pendingCallbackCount, 0);
    });

    test('a failed callback is not run a second time', () {
      final dispatcher = ManualDispatcher();
      var attempts = 0;

      dispatcher.post(() {
        attempts++;
        throw StateError('boom');
      });

      expect(dispatcher.drain, throwsA(isA<StateError>()));
      dispatcher.drain();

      expect(attempts, 1);
    });

    test('a failing timer stops advance at its own instant', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.schedule(
        const Duration(milliseconds: 10),
        () => throw StateError('boom'),
      );
      dispatcher.schedule(
        const Duration(milliseconds: 20),
        () => log.add('later'),
      );

      expect(
        () => dispatcher.advance(const Duration(milliseconds: 50)),
        throwsA(isA<StateError>()),
      );
      expect(dispatcher.elapsed, const Duration(milliseconds: 10));
      expect(dispatcher.pendingTimerCount, 1);

      dispatcher.advance(const Duration(milliseconds: 40));

      expect(log, <String>['later']);
      expect(dispatcher.elapsed, const Duration(milliseconds: 50));
    });

    test('onError keeps the pump going and never loses the error', () {
      final errors = <Object>[];
      final traces = <StackTrace>[];
      final dispatcher = ManualDispatcher(
        onError: (error, stackTrace) {
          errors.add(error);
          traces.add(stackTrace);
        },
      );
      final log = <String>[];

      dispatcher.post(() => throw StateError('first'));
      dispatcher.post(() => log.add('between'));
      dispatcher.schedule(
        const Duration(milliseconds: 10),
        () => throw StateError('second'),
      );
      dispatcher.schedule(
        const Duration(milliseconds: 20),
        () => log.add('after'),
      );
      dispatcher.advance(const Duration(milliseconds: 50));

      expect(log, <String>['between', 'after']);
      expect(errors.map((error) => '$error').toList(), <String>[
        'Bad state: first',
        'Bad state: second',
      ]);
      expect(traces, hasLength(2));
      expect(dispatcher.elapsed, const Duration(milliseconds: 50));
    });

    test('the propagated error keeps its own stack trace', () {
      final dispatcher = ManualDispatcher();
      dispatcher.post(() => throw StateError('boom'));

      StackTrace? caught;
      try {
        dispatcher.drain();
      } catch (_, stackTrace) {
        caught = stackTrace;
      }

      expect(caught, isNotNull);
      expect('$caught', contains('manual_dispatcher_test.dart'));
    });
  });

  group('ManualDispatcher re-entrancy', () {
    test('drain from inside a callback throws', () {
      final dispatcher = ManualDispatcher();
      dispatcher.post(dispatcher.drain);
      expect(dispatcher.drain, throwsA(isA<StateError>()));
    });

    test('advance from inside a callback throws', () {
      final dispatcher = ManualDispatcher();
      dispatcher.post(() => dispatcher.advance(const Duration(seconds: 1)));
      expect(dispatcher.drain, throwsA(isA<StateError>()));
    });

    test('run from inside a timer callback throws', () {
      final dispatcher = ManualDispatcher();
      dispatcher.schedule(const Duration(seconds: 1), dispatcher.run);
      expect(dispatcher.run, throwsA(isA<StateError>()));
    });

    test('a failed pump does not leave the dispatcher locked', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.post(() => throw StateError('boom'));
      expect(dispatcher.drain, throwsA(isA<StateError>()));

      dispatcher.post(() => log.add('still usable'));
      dispatcher.drain();

      expect(log, <String>['still usable']);
    });

    test('a runaway callback is reported instead of hanging', () {
      final dispatcher = ManualDispatcher(runawayLimit: 10);
      void repost() => dispatcher.post(repost);
      dispatcher.post(repost);

      expect(dispatcher.drain, throwsA(isA<StateError>()));
    });

    test('a timer rescheduling itself at the same instant is reported', () {
      final dispatcher = ManualDispatcher(runawayLimit: 10);
      void rearm() => dispatcher.schedule(Duration.zero, rearm);
      dispatcher.schedule(Duration.zero, rearm);

      expect(
        () => dispatcher.advance(const Duration(seconds: 1)),
        throwsA(isA<StateError>()),
      );
    });

    test('runawayLimit must be usable', () {
      expect(
        () => ManualDispatcher(runawayLimit: 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('ManualDispatcher loop control', () {
    test('run drains, fast-forwards to each timer, and returns quiescent', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.post(() => log.add('queued'));
      dispatcher.schedule(const Duration(hours: 1), () => log.add('hourly'));

      dispatcher.run();

      expect(log, <String>['queued', 'hourly']);
      expect(dispatcher.elapsed, const Duration(hours: 1));
      expect(dispatcher.isRunning, isFalse);
      expect(dispatcher.pendingCallbackCount, 0);
      expect(dispatcher.pendingTimerCount, 0);
    });

    test('isRunning is true only while run is pumping', () {
      final dispatcher = ManualDispatcher();
      final seen = <bool>[];

      expect(dispatcher.isRunning, isFalse);
      dispatcher.post(() => seen.add(dispatcher.isRunning));
      dispatcher.run();

      expect(seen, <bool>[true]);
      expect(dispatcher.isRunning, isFalse);
    });

    test('stop ends run after the running callback and keeps queued work', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];
      var ticks = 0;

      void tick() {
        ticks++;
        log.add('tick $ticks @${dispatcher.elapsed.inSeconds}');
        if (ticks == 3) {
          dispatcher.post(() => log.add('after stop'));
          dispatcher.stop();
          return;
        }
        dispatcher.schedule(const Duration(seconds: 1), tick);
      }

      dispatcher.schedule(const Duration(seconds: 1), tick);
      dispatcher.run();

      expect(log, <String>['tick 1 @1', 'tick 2 @2', 'tick 3 @3']);
      expect(dispatcher.elapsed, const Duration(seconds: 3));
      expect(dispatcher.pendingCallbackCount, 1);
      expect(dispatcher.isRunning, isFalse);

      dispatcher.drain();
      expect(log.last, 'after stop');
    });

    test('stop while not running is harmless and does not poison run', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.stop();
      dispatcher.stop();
      dispatcher.post(() => log.add('ran'));
      dispatcher.run();

      expect(log, <String>['ran']);
    });

    test('run can be called again after it returned', () {
      final dispatcher = ManualDispatcher();
      final log = <String>[];

      dispatcher.post(() => log.add('first'));
      dispatcher.run();
      dispatcher.post(() => log.add('second'));
      dispatcher.run();

      expect(log, <String>['first', 'second']);
    });
  });

  group('ManualDispatcher backend protocol', () {
    test('wake counts only explicit wakes, not posts or schedules', () {
      final dispatcher = ManualDispatcher();

      dispatcher.post(() {});
      dispatcher.schedule(const Duration(seconds: 1), () {});
      expect(dispatcher.wakeCount, 0);

      dispatcher.wake();
      dispatcher.wake();
      expect(dispatcher.wakeCount, 2);
    });

    test('hasThreadAccess is a seam for code that branches on it', () {
      expect(ManualDispatcher().hasThreadAccess, isTrue);
      expect(
        ManualDispatcher(hasThreadAccess: false).hasThreadAccess,
        isFalse,
      );
    });

    test('pending counters report what has not run yet', () {
      final dispatcher = ManualDispatcher();

      expect(dispatcher.nextTimerDue, isNull);
      dispatcher.post(() {}, priority: DispatcherPriority.input);
      dispatcher.post(() {}, priority: DispatcherPriority.idle);
      dispatcher.schedule(const Duration(seconds: 2), () {});
      dispatcher.schedule(const Duration(seconds: 1), () {});

      expect(dispatcher.pendingCallbackCount, 2);
      expect(dispatcher.pendingTimerCount, 2);
      expect(dispatcher.nextTimerDue, const Duration(seconds: 1));
    });
  });
}
