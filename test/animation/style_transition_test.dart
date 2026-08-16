/// Section 28.7: a style change reached over time, at
/// [PropertyPrecedence.animation], and interruptible.
///
/// The two tests that matter most here are the interruption case - a second
/// state change mid-transition must start from the value on screen, not from
/// the value the first transition started at - and reduced motion, which must
/// land on the final value without animating.
library;

import 'package:dart_ui/src/animation/clock.dart';
import 'package:dart_ui/src/animation/curves.dart';
import 'package:dart_ui/src/widgets/properties.dart';
import 'package:dart_ui/src/widgets/style.dart';
import 'package:dart_ui/src/widgets/theme.dart';
import 'package:test/test.dart';

const int _red = 0xFFFF0000;
const int _blue = 0xFF0000FF;
const int _purple = 0xFF800080;

const UiProperty<int> background = UiProperty<int>(
  name: 'background',
  defaultValue: _red,
);

/// The default matches the unhovered style value on purpose, so the first
/// `apply` in each test is a genuine no-op and every transition observed
/// afterwards was caused by the state change under test.
const UiProperty<double> padding = UiProperty<double>(
  name: 'padding',
  defaultValue: 4.0,
  invalidation: PropertyInvalidation.layout,
);

const Duration _hundredMs = Duration(milliseconds: 100);

Styles _styles() => Styles(rules: <StyleRule>[
      const StyleRule(
        selector: TypeSelector('Button'),
        setters: <StyleSetter<Object?>>[
          StyleSetter<int>(background, _red),
          StyleSetter<double>(padding, 4.0),
        ],
      ),
      const StyleRule(
        selector: AndSelector(<StyleSelector>[
          TypeSelector('Button'),
          PseudoClassSelector(PseudoClass.hover),
        ]),
        setters: <StyleSetter<Object?>>[
          StyleSetter<int>(background, _blue),
          StyleSetter<double>(padding, 12.0),
        ],
      ),
    ]);

StyleTarget _button({bool hovered = false}) => StyleTarget(
      type: 'Button',
      states: hovered ? <PseudoClass>{PseudoClass.hover} : <PseudoClass>{},
    );

/// A store, a clock and a runner wired together the way an element would.
final class _Harness {
  _Harness({bool reducedMotion = false, Duration duration = _hundredMs})
      : store = PropertyStore(Object()) {
    runner = StyleTransitionRunner(
      store: store,
      clock: clock,
      reducedMotion: reducedMotion,
      transitions: <PropertyTransition<Object?>>[
        PropertyTransitions.ofColor(
          background,
          duration: duration,
          curve: Curves.linear,
        ),
        PropertyTransitions.ofDouble(
          padding,
          duration: duration,
          curve: Curves.linear,
        ),
      ],
    );
  }

  final PropertyStore store;
  final AnimationClock clock = AnimationClock();
  late final StyleTransitionRunner runner;
  final Styles styles = _styles();

  Duration _now = Duration.zero;

  int get colour => store.read<int>(background);

  double get pad => store.read<double>(padding);

  PropertyInvalidation apply({bool hovered = false}) =>
      runner.apply(styles, _button(hovered: hovered));

  /// Advances the virtual clock by [delta] and ticks once, the way one frame
  /// would. No wall clock anywhere.
  void frame(Duration delta) {
    _now += delta;
    clock.tick(_now);
  }

  /// The baseline frame a newly started transition needs; see
  /// `AnimationController`, which behaves the same way.
  void settleBaseline() => frame(Duration.zero);
}

void main() {
  group('a transition writes at PropertyPrecedence.animation', () {
    test('and nothing else does', () {
      final _Harness harness = _Harness();
      harness.apply();
      expect(harness.colour, _red);
      expect(
        harness.store.isSetAt(background, PropertyPrecedence.animation),
        isFalse,
        reason: 'no change, no animation',
      );

      harness.apply(hovered: true);
      expect(
        harness.store.isSetAt(background, PropertyPrecedence.animation),
        isTrue,
      );
      expect(
        harness.store.effectivePrecedence(background),
        PropertyPrecedence.animation,
      );
      expect(harness.colour, _red, reason: 'holds the old value at t=0');
      expect(harness.runner.activeTransitionCount, 2);
    });

    test('the animation slot wins over the trigger that started it', () {
      final _Harness harness = _Harness()..apply();
      harness.apply(hovered: true);
      // The hover rule already wrote blue at `trigger`; the transition covers
      // it with the interpolated value, which is what stops the two fighting.
      expect(harness.store.isSetAt(background, PropertyPrecedence.trigger),
          isTrue);
      expect(harness.colour, _red);
    });

    test('a locally assigned property has nothing to transition', () {
      // `local` outranks `style` and `trigger`, so a hover rule does not
      // change the effective value at all - and a transition to a value that
      // is not going to be shown would be motion with no cause.
      final _Harness harness = _Harness()..apply();
      harness.store.write<int>(background, 0xFF00FF00);
      harness.apply(hovered: true);
      expect(harness.colour, 0xFF00FF00);
      expect(harness.store.effectivePrecedence(background),
          PropertyPrecedence.local);
      expect(
        harness.store.isSetAt(background, PropertyPrecedence.animation),
        isFalse,
      );
    });

    test('a running transition outranks a local assignment', () {
      // Section 24.6's order: animation beats local. A transition that lost to
      // a local write would visibly stall for its whole duration.
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 50));
      harness.store.write<int>(background, 0xFF00FF00);
      expect(harness.colour, _purple);
      expect(harness.store.effectivePrecedence(background),
          PropertyPrecedence.animation);
    });

    test('clears the slot on completion, revealing the style value', () {
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(_hundredMs);

      expect(harness.colour, _blue);
      expect(harness.pad, 12.0);
      expect(harness.runner.activeTransitionCount, 0);
      expect(
        harness.store.isSetAt(background, PropertyPrecedence.animation),
        isFalse,
        reason: 'the style layer already holds the target, so ending is '
            'simply dropping the slot',
      );
      expect(harness.store.effectivePrecedence(background),
          PropertyPrecedence.trigger);
    });

    test('interpolates through the declared curve', () {
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 50));

      expect(harness.colour, _purple);
      expect(harness.pad, 8.0);
      expect(harness.runner.isTicking, isTrue);
    });

    test('reports the invalidation of every property it starts', () {
      final _Harness harness = _Harness()..apply();
      // `padding` invalidates layout, `background` only paint; the merged
      // answer must be the stronger one.
      expect(harness.apply(hovered: true), PropertyInvalidation.layout);
    });
  });

  group('interruption', () {
    test('a reversal mid-flight starts from the value on screen', () {
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 50));
      expect(harness.colour, _purple, reason: 'halfway from red to blue');

      // The pointer leaves. The new transition must begin at purple - not at
      // blue (where the first one was heading) and not at red (where it
      // started). Getting this wrong makes a control snap on every crossing.
      harness.apply();
      expect(harness.colour, _purple);
      expect(harness.pad, 8.0);
      expect(harness.runner.activeTransitionCount, 2);

      harness.frame(const Duration(milliseconds: 50));
      // Halfway from purple back to red: red channel 0x80 -> 0xFF is 0xC0,
      // blue channel 0x80 -> 0x00 is 0x40.
      expect(harness.colour, 0xFFC00040);
      expect(harness.pad, 6.0);

      harness.frame(const Duration(milliseconds: 50));
      expect(harness.colour, _red);
      expect(harness.pad, 4.0);
      expect(harness.runner.activeTransitionCount, 0);
    });

    test('the interrupted transition runs a full duration from where it was',
        () {
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 90));
      final double nearlyThere = harness.pad;
      expect(nearlyThere, closeTo(11.2, 1e-12));

      harness.apply();
      // The elapsed time of the interrupted transition must not carry over: a
      // transition that inherited 90 ms of progress would finish in 10 ms.
      harness.frame(const Duration(milliseconds: 50));
      expect(harness.pad, closeTo(11.2 - (11.2 - 4.0) * 0.5, 1e-12));
      expect(harness.runner.activeTransitionCount, 2);
    });

    test('re-applying the same state does not restart the clock', () {
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 40));
      expect(harness.pad, closeTo(7.2, 1e-12));

      // A style pass that ran every frame would otherwise reset the elapsed
      // time every frame and the transition would never finish.
      harness
        ..apply(hovered: true)
        ..apply(hovered: true);
      expect(harness.runner.activeTransitionCount, 2);
      expect(harness.pad, closeTo(7.2, 1e-12));

      harness.frame(const Duration(milliseconds: 60));
      expect(harness.pad, 12.0);
      expect(harness.runner.activeTransitionCount, 0);
    });

    test('an interruption that resolves back to the current value stops', () {
      final _Harness harness = _Harness()..apply();
      // Hover on then immediately off, before any frame ran: nothing moved,
      // so there is nothing to animate back to.
      harness.apply(hovered: true);
      expect(harness.runner.activeTransitionCount, 2);
      harness.apply();
      expect(harness.runner.activeTransitionCount, 0);
      expect(harness.colour, _red);
      expect(
        harness.store.isSetAt(background, PropertyPrecedence.animation),
        isFalse,
      );
    });

    test('three crossings in a row each start from the current value', () {
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 25));
      final double a = harness.pad;
      harness
        ..apply()
        ..frame(const Duration(milliseconds: 25));
      final double b = harness.pad;
      harness
        ..apply(hovered: true)
        ..frame(const Duration(milliseconds: 25));
      final double c = harness.pad;

      expect(a, closeTo(6.0, 1e-12));
      expect(b, closeTo(5.5, 1e-12), reason: 'heading back down from 6.0');
      expect(c, closeTo(7.125, 1e-12), reason: 'heading back up from 5.5');
      // Never a snap: every sample stays inside the declared range.
      for (final double value in <double>[a, b, c]) {
        expect(value, greaterThanOrEqualTo(4.0));
        expect(value, lessThanOrEqualTo(12.0));
      }
    });
  });

  group('reduced motion', () {
    test('jumps straight to the final value', () {
      final _Harness harness = _Harness(reducedMotion: true)..apply();
      harness.apply(hovered: true);

      expect(harness.colour, _blue);
      expect(harness.pad, 12.0);
      expect(harness.runner.activeTransitionCount, 0);
      expect(harness.runner.isTicking, isFalse);
      expect(
        harness.store.isSetAt(background, PropertyPrecedence.animation),
        isFalse,
        reason: 'no animation slot is written at all; the style value is the '
            'effective value immediately',
      );
    });

    test('turning it on mid-transition finishes what was playing', () {
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 50));
      expect(harness.colour, _purple);

      harness.runner.reducedMotion = true;
      expect(harness.colour, _blue);
      expect(harness.pad, 12.0);
      expect(harness.runner.activeTransitionCount, 0);
    });

    test('it does not stop the clock', () {
      // The flag shortens transitions. It must not freeze the frame loop, or a
      // progress spinner and a caret would stop with it.
      final _Harness harness = _Harness(reducedMotion: true)..apply();
      harness
        ..apply(hovered: true)
        ..frame(const Duration(milliseconds: 16))
        ..frame(const Duration(milliseconds: 16));
      expect(harness.clock.tickCount, 2);
      expect(harness.clock.tickerCount, 1,
          reason: 'the runner stays registered and keeps being ticked');
    });

    test('turning it back off animates subsequent changes again', () {
      final _Harness harness = _Harness(reducedMotion: true)..apply();
      harness.apply(hovered: true);
      expect(harness.colour, _blue);

      harness.runner.reducedMotion = false;
      harness
        ..apply()
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 50));
      expect(harness.colour, _purple);
    });

    test('the theme carries the flag', () {
      expect(ThemeData.neutralLight.reducedMotion, isFalse);
      final ThemeData reduced =
          ThemeData.neutralLight.copyWith(reducedMotion: true);
      expect(reduced.reducedMotion, isTrue);
      expect(reduced, isNot(ThemeData.neutralLight));
      expect(reduced.hashCode, isNot(ThemeData.neutralLight.hashCode));
      expect(
        reduced.copyWith(reducedMotion: false),
        ThemeData.neutralLight,
      );
    });
  });

  group('the runner as a ticker', () {
    test('registers with the clock and is advanced once per tick', () {
      final _Harness harness = _Harness()..apply();
      expect(harness.clock.tickerCount, 1);
      expect(harness.runner.isTicking, isFalse);

      harness.apply(hovered: true);
      expect(harness.runner.isTicking, isTrue);
      expect(harness.clock.hasActiveTickers, isTrue);

      harness
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 25));
      expect(harness.pad, closeTo(6.0, 1e-12));
      // A second tick at the same instant is a zero-length step and must
      // change nothing.
      harness.frame(Duration.zero);
      expect(harness.pad, closeTo(6.0, 1e-12));
    });

    test('an idle gap before a transition is not charged to it', () {
      final _Harness harness = _Harness()..apply();
      harness
        ..settleBaseline()
        ..frame(const Duration(seconds: 30));

      harness
        ..apply(hovered: true)
        ..frame(const Duration(milliseconds: 16))
        ..frame(const Duration(milliseconds: 34));
      expect(harness.pad, closeTo(6.72, 1e-12),
          reason: '34 ms of a 100 ms transition, not 30 seconds of it');
    });

    test('dispose lands the transition and unregisters', () {
      final _Harness harness = _Harness()..apply();
      harness
        ..apply(hovered: true)
        ..settleBaseline()
        ..frame(const Duration(milliseconds: 50));
      harness.runner.dispose();
      expect(harness.colour, _blue);
      expect(harness.clock.tickerCount, 0);
    });

    test('two transitions for one property are rejected', () {
      expect(
        () => StyleTransitionRunner(
          store: PropertyStore(Object()),
          transitions: <PropertyTransition<Object?>>[
            PropertyTransitions.ofColor(background, duration: _hundredMs),
            PropertyTransitions.ofColor(background, duration: _hundredMs),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('a zero-duration transition opts that property out', () {
      final _Harness harness = _Harness(duration: Duration.zero)..apply();
      harness.apply(hovered: true);
      expect(harness.colour, _blue);
      expect(harness.runner.activeTransitionCount, 0);
    });
  });
}
