import 'package:dart_ui/src/gestures/arena.dart';
import 'package:test/test.dart';

import 'gesture_test_support.dart';

void main() {
  group('the walkover', () {
    test('a lone member wins as soon as the arena closes', () {
      final arena = GestureArenaManager();
      final lonely = RecordingMember('lonely');
      arena.add(1, lonely);

      expect(lonely.log, isEmpty, reason: 'nothing is decided while open');
      arena.close(1);

      expect(lonely.log, <String>['accept']);
      expect(arena.hasArena(1), isFalse, reason: 'a resolved arena is gone');
    });

    test('resolution is synchronous - no microtask, no await', () async {
      // The single most important property for a deterministic suite. Flutter
      // defers the default win to a microtask; here it lands inside close(),
      // so a test never has to await anything to observe a tap.
      final arena = GestureArenaManager();
      final lonely = RecordingMember('lonely');
      arena.add(2, lonely);
      arena.close(2);
      expect(lonely.log, <String>['accept']);
    });

    test('the last member standing wins when the others drop out', () {
      final arena = GestureArenaManager();
      final quitter = EagerMember('quitter');
      final survivor = RecordingMember('survivor');
      quitter.entry = arena.add(3, quitter);
      arena.add(3, survivor);
      arena.close(3);

      expect(survivor.log, isEmpty, reason: 'two candidates, nothing decided');
      quitter.concede();

      expect(quitter.log, <String>['reject']);
      expect(survivor.log, <String>['accept']);
    });
  });

  group('two siblings', () {
    test('the inner one wins the sweep, because it joined first', () {
      // This is the whole of "inner beats outer in the common case". The
      // hit-test path is offered deepest-first, so the inner recognizer is
      // member zero, and the sweep awards the first member.
      final arena = GestureArenaManager();
      final inner = RecordingMember('inner');
      final outer = RecordingMember('outer');
      arena.add(4, inner);
      arena.add(4, outer);
      arena.close(4);
      arena.sweep(4);

      expect(inner.log, <String>['accept']);
      expect(outer.log, <String>['reject']);
    });

    test('but not always: the outer one wins by claiming first', () {
      // Order is only the tie-break. Evidence beats position: an outer drag
      // that crossed its slop knows something the inner tap does not, and it
      // takes the gesture on the spot.
      final arena = GestureArenaManager();
      final inner = RecordingMember('inner');
      final outer = EagerMember('outer');
      arena.add(5, inner);
      outer.entry = arena.add(5, outer);
      arena.close(5);

      expect(inner.log, isEmpty);
      outer.claim();

      expect(outer.log, <String>['accept']);
      expect(inner.log, <String>['reject']);
      expect(arena.hasArena(5), isFalse);
    });

    test('a claim made while the arena is open waits for it to close', () {
      // A member that claims during dispatch must not win before the deeper
      // members have even been offered the press.
      final arena = GestureArenaManager();
      final eager = EagerMember('eager');
      eager.entry = arena.add(6, eager);
      eager.claim();
      final late = RecordingMember('late');
      arena.add(6, late);

      expect(eager.log, isEmpty, reason: 'parked, not granted');
      expect(late.log, isEmpty);

      arena.close(6);
      expect(eager.log, <String>['accept']);
      expect(late.log, <String>['reject']);
    });

    test('only the first eager claim counts', () {
      final arena = GestureArenaManager();
      final first = EagerMember('first');
      final second = EagerMember('second');
      first.entry = arena.add(7, first);
      second.entry = arena.add(7, second);
      second.claim();
      first.claim();
      arena.close(7);

      expect(second.log, <String>['accept']);
      expect(first.log, <String>['reject']);
    });
  });

  group('cancellation', () {
    test('a cancelled pointer resolves the arena with nobody winning', () {
      final arena = GestureArenaManager();
      final a = RecordingMember('a');
      final b = RecordingMember('b');
      arena.add(8, a);
      arena.add(8, b);
      arena.close(8);

      arena.cancel(8);

      expect(a.log, <String>['reject']);
      expect(b.log, <String>['reject']);
      expect(arena.hasArena(8), isFalse, reason: 'not left dangling');
      expect(arena.openArenaCount, 0);
    });

    test('cancelling an open arena works too - a press that never landed', () {
      final arena = GestureArenaManager();
      final a = RecordingMember('a');
      arena.add(9, a);
      arena.cancel(9);

      expect(a.log, <String>['reject']);
      expect(arena.hasArena(9), isFalse);
    });

    test('a hold does not postpone a cancel', () {
      // A hold says "wait for more input". A cancel says there will be none.
      // Honouring the hold would leak the arena and every recognizer with it.
      final arena = GestureArenaManager();
      final a = RecordingMember('a');
      final b = RecordingMember('b');
      arena.add(10, a);
      arena.add(10, b);
      arena.close(10);
      arena.hold(10);

      arena.cancel(10);

      expect(a.log, <String>['reject']);
      expect(b.log, <String>['reject']);
      expect(arena.openArenaCount, 0);
    });

    test('a sweep after a cancel is a no-op, not a second resolution', () {
      final arena = GestureArenaManager();
      final a = RecordingMember('a');
      final b = RecordingMember('b');
      arena.add(11, a);
      arena.add(11, b);
      arena.close(11);
      arena.cancel(11);
      arena.sweep(11);

      expect(a.log, <String>['reject']);
      expect(b.log, <String>['reject']);
      expect(a.settledExactlyOnce, isTrue);
      expect(b.settledExactlyOnce, isTrue);
    });
  });

  group('the contract', () {
    test('every member is settled exactly once, whatever the route', () {
      for (final String route in <String>['sweep', 'cancel', 'claim']) {
        final arena = GestureArenaManager();
        final passive = RecordingMember('passive');
        final claimant = EagerMember('claimant');
        arena.add(12, passive);
        claimant.entry = arena.add(12, claimant);
        arena.close(12);
        switch (route) {
          case 'sweep':
            arena.sweep(12);
          case 'cancel':
            arena.cancel(12);
          case 'claim':
            claimant.claim();
        }
        expect(passive.settledExactlyOnce, isTrue, reason: route);
        expect(claimant.log.length, 1, reason: route);
      }
    });

    test('a member that resolves in its own favour still hears about it', () {
      final arena = GestureArenaManager();
      final winner = EagerMember('winner');
      winner.entry = arena.add(13, winner);
      arena.add(13, RecordingMember('other'));
      arena.close(13);
      winner.claim();

      expect(winner.log, <String>['accept']);
    });

    test('resolving twice is harmless', () {
      final arena = GestureArenaManager();
      final member = EagerMember('member');
      member.entry = arena.add(14, member);
      arena.add(14, RecordingMember('other'));
      arena.close(14);
      member.claim();
      member.claim();
      member.concede();

      expect(member.log, <String>['accept']);
    });

    test('joining after the arena closed is an error, not a late entry', () {
      final arena = GestureArenaManager();
      arena.add(15, RecordingMember('a'));
      arena.add(15, RecordingMember('b'));
      arena.close(15);

      expect(
        () => arena.add(15, RecordingMember('c')),
        throwsA(isA<StateError>()),
      );
    });

    test('sweeping an arena that is still open is an error', () {
      final arena = GestureArenaManager();
      arena.add(16, RecordingMember('a'));
      arena.add(16, RecordingMember('b'));

      expect(() => arena.sweep(16), throwsA(isA<StateError>()));
    });
  });

  group('hold and release', () {
    test('a hold postpones the sweep until the hold ends', () {
      final arena = GestureArenaManager();
      final first = RecordingMember('first');
      final second = RecordingMember('second');
      arena.add(17, first);
      arena.add(17, second);
      arena.close(17);
      arena.hold(17);
      arena.sweep(17);

      expect(first.log, isEmpty, reason: 'the sweep is owed, not performed');

      arena.release(17);
      expect(first.log, <String>['accept']);
      expect(second.log, <String>['reject']);
    });

    test('a walkover suppressed by a hold is owed on release', () {
      final arena = GestureArenaManager();
      final quitter = EagerMember('quitter');
      final survivor = RecordingMember('survivor');
      quitter.entry = arena.add(18, quitter);
      arena.add(18, survivor);
      arena.close(18);
      arena.hold(18);
      quitter.concede();

      expect(survivor.log, isEmpty);

      arena.release(18);
      expect(survivor.log, <String>['accept']);
    });
  });

  group('bookkeeping', () {
    test('arenas are per pointer and do not interfere', () {
      final arena = GestureArenaManager();
      final one = RecordingMember('one');
      final two = RecordingMember('two');
      arena.add(20, one);
      arena.add(21, two);
      expect(arena.openArenaCount, 2);

      arena.close(20);
      expect(one.log, <String>['accept']);
      expect(two.log, isEmpty);
      expect(arena.openArenaCount, 1);

      arena.close(21);
      expect(arena.openArenaCount, 0);
    });

    test('an arena everybody left is removed rather than kept empty', () {
      final arena = GestureArenaManager();
      final a = EagerMember('a');
      final b = EagerMember('b');
      a.entry = arena.add(22, a);
      b.entry = arena.add(22, b);
      arena.close(22);
      a.concede();
      b.concede();

      expect(arena.hasArena(22), isFalse);
      expect(arena.openArenaCount, 0);
    });
  });
}
