import 'package:dart_ui/src/scheduler/dispatcher_priority.dart';
import 'package:test/test.dart';

void main() {
  group('DispatcherPriority', () {
    test('declares the frame pipeline order required by section 9.4', () {
      expect(
        DispatcherPriority.values.map((priority) => priority.name).toList(),
        <String>[
          'immediate',
          'input',
          'animation',
          'layout',
          'render',
          'normal',
          'idle',
        ],
      );
    });

    test('sorting ascending yields dispatch order', () {
      final shuffled = <DispatcherPriority>[
        DispatcherPriority.idle,
        DispatcherPriority.layout,
        DispatcherPriority.immediate,
        DispatcherPriority.render,
        DispatcherPriority.input,
        DispatcherPriority.normal,
        DispatcherPriority.animation,
      ]..sort();
      expect(shuffled, DispatcherPriority.values);
    });

    test('urgency comparison is the inverse of index', () {
      expect(
        DispatcherPriority.input.isMoreUrgentThan(DispatcherPriority.render),
        isTrue,
      );
      expect(
        DispatcherPriority.render.isMoreUrgentThan(DispatcherPriority.input),
        isFalse,
      );
      expect(
        DispatcherPriority.idle.isLessUrgentThan(DispatcherPriority.normal),
        isTrue,
      );
      expect(
        DispatcherPriority.input.isMoreUrgentThan(DispatcherPriority.input),
        isFalse,
      );
      expect(
        DispatcherPriority.input.isLessUrgentThan(DispatcherPriority.input),
        isFalse,
      );
    });

    test('input runs before animation before layout before render', () {
      expect(
        DispatcherPriority.input.compareTo(DispatcherPriority.animation),
        lessThan(0),
      );
      expect(
        DispatcherPriority.animation.compareTo(DispatcherPriority.layout),
        lessThan(0),
      );
      expect(
        DispatcherPriority.layout.compareTo(DispatcherPriority.render),
        lessThan(0),
      );
      expect(
        DispatcherPriority.render.compareTo(DispatcherPriority.render),
        0,
      );
    });

    test('the documented default is normal', () {
      expect(DispatcherPriority.defaultPriority, DispatcherPriority.normal);
    });
  });
}
