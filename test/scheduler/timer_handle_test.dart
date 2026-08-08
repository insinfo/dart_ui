import 'package:dart_ui/src/scheduler/timer_handle.dart';
import 'package:test/test.dart';

void main() {
  group('TimerHandle', () {
    test('is active until it is cancelled or fires', () {
      final handle = TimerHandle(onCancel: (_) {});
      expect(handle.isActive, isTrue);
      expect(handle.isCancelled, isFalse);
    });

    test('cancel de-registers exactly once and reports the handle', () {
      final cancelled = <TimerHandle>[];
      final handle = TimerHandle(onCancel: cancelled.add);

      handle.cancel();

      expect(cancelled, hasLength(1));
      expect(identical(cancelled.single, handle), isTrue);
      expect(handle.isActive, isFalse);
      expect(handle.isCancelled, isTrue);
    });

    test('cancelling twice is a no-op, not an error or a second teardown', () {
      var cancels = 0;
      final handle = TimerHandle(onCancel: (_) => cancels++);

      handle.cancel();
      handle.cancel();
      handle.cancel();

      expect(cancels, 1);
      expect(handle.isActive, isFalse);
    });

    test('cancelling after firing does not de-register a second time', () {
      var cancels = 0;
      final handle = TimerHandle(onCancel: (_) => cancels++);

      handle.markFired();
      handle.cancel();

      expect(cancels, 0);
      expect(handle.isActive, isFalse);
      expect(handle.isCancelled, isFalse);
    });

    test('fired and cancelled are distinguishable, not just "not active"', () {
      final fired = TimerHandle(onCancel: (_) {})..markFired();
      final cancelled = TimerHandle(onCancel: (_) {})..cancel();

      expect(fired.isActive, isFalse);
      expect(cancelled.isActive, isFalse);
      expect(fired.isCancelled, isFalse);
      expect(cancelled.isCancelled, isTrue);
    });

    test('toString names the terminal state, for diagnostics', () {
      final pending = TimerHandle(onCancel: (_) {});
      expect(pending.toString(), contains('pending'));
      expect((TimerHandle(onCancel: (_) {})..cancel()).toString(),
          contains('cancelled'));
      expect((TimerHandle(onCancel: (_) {})..markFired()).toString(),
          contains('fired'));
    });
  });
}
