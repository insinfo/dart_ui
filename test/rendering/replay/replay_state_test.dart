import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/replay/replay_state.dart';
import 'package:test/test.dart';

const Rect _surface = Rect.fromLTRB(0, 0, 100, 100);

ReplayState _rooted({int initialDepth = 16}) =>
    ReplayState(initialDepth: initialDepth)..reset(deviceBounds: _surface);

void main() {
  group('scopes', () {
    test('reset roots the walk at the surface with no scopes open', () {
      final state = _rooted();
      expect(state.saveDepth, 0);
      expect(state.clip, _surface);
      expect(state.transform, Transform2D.identity);
    });

    test('restore undoes both the transform and the clip', () {
      final state = _rooted();
      state.save();
      state.concat(const Transform2D.translation(10, 20));
      state.clipDeviceRect(const Rect.fromLTRB(0, 0, 10, 10));
      expect(state.saveDepth, 1);

      state.restore();
      expect(state.saveDepth, 0);
      expect(state.transform, Transform2D.identity);
      expect(state.clip, _surface);
    });

    test('siblings do not see each other, nesting composes', () {
      final state = _rooted();
      state.save();
      state.concat(const Transform2D.scaling(2, 2));
      state.save();
      state.concat(const Transform2D.translation(10, 5));
      // this AFTER other: scale applies to the already translated point.
      expect(
        state.deviceBoundsOf(const Rect.fromLTRB(0, 0, 4, 4)),
        const Rect.fromLTRB(20, 10, 28, 18),
      );

      state.restore();
      expect(
        state.deviceBoundsOf(const Rect.fromLTRB(0, 0, 4, 4)),
        const Rect.fromLTRB(0, 0, 8, 8),
      );
      state.restore();
    });
  });

  group('imbalance', () {
    test('restore with nothing open throws by name', () {
      final state = _rooted();
      expect(state.restore, throwsA(isA<UnbalancedRestoreException>()));
    });

    test('the underflow error names the problem, not the stack', () {
      final state = _rooted();
      state.save();
      state.restore();
      expect(
        () => state.restore(),
        throwsA(
          isA<UnbalancedRestoreException>().having(
            (e) => e.message,
            'message',
            contains('restore with no matching save'),
          ),
        ),
      );
    });

    test('outstanding saves are visible to the caller that ends the walk', () {
      // The state itself cannot know a stream ended; saveDepth is the whole
      // contract the player enforces UnbalancedSaveException on.
      final state = _rooted()
        ..save()
        ..save();
      expect(state.saveDepth, 2);
    });

    test('UnbalancedSaveException says how many are open', () {
      const error = UnbalancedSaveException(3);
      expect(error.outstandingSaves, 3);
      expect(error.toString(), contains('3 save(s) still open'));
    });
  });

  group('clip', () {
    test('clipping only ever narrows', () {
      final state = _rooted();
      state.clipDeviceRect(const Rect.fromLTRB(10, 10, 50, 50));
      state.clipDeviceRect(const Rect.fromLTRB(0, 0, 200, 30));
      expect(state.clip, const Rect.fromLTRB(10, 10, 50, 30));
    });

    test('an empty clip cannot be reopened from inside its scope', () {
      final state = _rooted();
      state.clipDeviceRect(const Rect.fromLTRB(10, 10, 20, 20));
      state.clipDeviceRect(const Rect.fromLTRB(60, 60, 70, 70));
      expect(state.clip.isEmpty, isTrue);

      state.clipDeviceRect(_surface);
      expect(state.clip.isEmpty, isTrue);
    });
  });

  group('stack storage', () {
    test('a frame of hundreds of save/restore pairs grows nothing', () {
      final state = _rooted(initialDepth: 4);
      for (var i = 0; i < 500; i++) {
        state.save();
        state.concat(const Transform2D.translation(1, 1));
        state.restore();
      }
      expect(state.saveDepth, 0);
      expect(state.stackGrowths, 0);
      expect(state.transform, Transform2D.identity);
    });

    test('deep nesting grows once, and the next frame reuses it', () {
      final state = _rooted(initialDepth: 4);
      for (var i = 0; i < 40; i++) {
        state.save();
      }
      expect(state.stackCapacity, greaterThanOrEqualTo(40));
      final int growths = state.stackGrowths;
      expect(growths, greaterThan(0));

      // reset keeps the storage: this is the arena property the whole design
      // rests on, and the only way to see it is that no further growth happens.
      state.reset(deviceBounds: _surface);
      for (var i = 0; i < 40; i++) {
        state.save();
      }
      expect(state.stackGrowths, growths);
    });

    test('a grown stack still restores the values saved before it grew', () {
      final state = _rooted(initialDepth: 2);
      state.save();
      state.concat(const Transform2D.translation(7, 0));
      final Transform2D outer = state.transform;
      for (var i = 0; i < 10; i++) {
        state.save();
        state.concat(const Transform2D.translation(1, 0));
      }
      for (var i = 0; i < 10; i++) {
        state.restore();
      }
      expect(state.transform, outer);
      state.restore();
      expect(state.transform, Transform2D.identity);
    });
  });
}
