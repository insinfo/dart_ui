/// The implicitly animated widgets, tested as arithmetic over time.
///
/// "It builds" is not what these widgets can be wrong about. What they can be
/// wrong about is the number: the value at t=0, the value at the midpoint under
/// a named curve, whether the end lands exactly on the target, and - the one
/// that is invisible in a screenshot - whether a target that changes mid-flight
/// resumes from where the property is or teleports back to where the previous
/// transition started.
///
/// Two structural claims are checked here too, because they are the ones the
/// class comments make and neither shows up in a picture: a tick rebuilds this
/// widget and *not* its subtree, and a zero duration never reaches the
/// controller that would divide by it.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('AnimatedOpacity', () {
    test('at t=0 the value is still where it was, not where it is going', () {
      final _Harness harness = _Harness.opacity(1);

      harness
        ..target(0)
        ..settle()
        ..tickNow();

      expect(harness.opacity, 1.0,
          reason: 'no time has passed; a fade that starts at its destination '
              'is a fade nobody sees');
      harness.dispose();
    });

    test('a linear midpoint is exactly halfway', () {
      final _Harness harness = _Harness.opacity(1);

      harness
        ..target(0)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));

      expect(harness.opacity, 0.5);
      harness.dispose();
    });

    test('a named curve is applied to the progress, not to the value', () {
      final _Harness harness = _Harness.opacity(0, curve: Curves.decelerate);

      harness
        ..target(1)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));

      // `decelerate` is fast then slow, so half the time is more than half the
      // distance. The exact equality pins *where* the curve is applied: shaping
      // the controller's progress and shaping the interpolated value are the
      // same thing for one property and stop agreeing the moment a second one
      // with a different range joins it.
      expect(harness.opacity, Curves.decelerate.transform(0.5));
      expect(harness.opacity, greaterThan(0.6),
          reason: 'a decelerating fade-in is more than half done at half time');
      harness.dispose();
    });

    test('the end lands exactly on the target', () {
      final _Harness harness = _Harness.opacity(1);

      harness
        ..target(0)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 100));

      expect(harness.opacity, 0.0,
          reason: 'exactly, not 1e-17: the controller accumulates integer '
              'microseconds so that the last frame divides to exactly 1');
      harness.dispose();
    });

    test('changing the target mid-flight resumes from the current value', () {
      final _Harness harness = _Harness.opacity(0);

      harness
        ..target(1)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));
      expect(harness.opacity, 0.5);

      // Turn around. The new transition has to start from 0.5, which is where
      // the property is, and not from 0, which is where the previous one began.
      harness
        ..target(0)
        ..settle()
        ..tickNow();
      expect(harness.opacity, 0.5, reason: 'the reversal is not a jump');

      harness.advance(const Duration(milliseconds: 50));
      expect(harness.opacity, 0.25);

      harness.advance(const Duration(milliseconds: 50));
      expect(harness.opacity, 0.0);
      harness.dispose();
    });

    test('a zero duration assigns instead of dividing by zero', () {
      final _Harness harness = _Harness.opacity(1, duration: Duration.zero);

      harness
        ..target(0)
        ..settle();

      expect(harness.opacity, 0.0);
      expect(harness.clock.tickerCount, 0,
          reason: 'no controller was built, so nothing registered with the '
              'clock - AnimationController rejects a zero duration by name');
      harness.dispose();
    });

    test('with no AnimationScope it works and simply does not animate', () {
      final _Harness harness = _Harness.opacity(1, withClock: false);

      harness
        ..target(0)
        ..settle();

      expect(harness.opacity, 0.0);
      harness.dispose();
    });

    test('a reduced-motion theme skips the transition', () {
      final _Harness harness = _Harness.opacity(1, reducedMotion: true);

      harness
        ..target(0)
        ..settle()
        ..tickNow();

      expect(harness.opacity, 0.0);
      expect(harness.clock.tickerCount, 0);
      harness.dispose();
    });

    test('onEnd fires once, at the end', () {
      int ended = 0;
      final _Harness harness = _Harness.opacity(1, onEnd: () => ended++);

      harness
        ..target(0)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));
      expect(ended, 0, reason: 'halfway is not the end');

      harness.advance(const Duration(milliseconds: 50));
      expect(ended, 1);

      harness.advance(const Duration(milliseconds: 50));
      expect(ended, 1, reason: 'a finished animation does not finish again');
      harness.dispose();
    });

    test('a tick rebuilds this widget and not the subtree under it', () {
      final _Harness harness = _Harness.opacity(1);
      expect(harness.childBuilds, 1);

      harness
        ..target(0)
        ..settle();
      final int afterRetarget = harness.childBuilds;

      harness
        ..tickNow()
        ..advance(const Duration(milliseconds: 25))
        ..advance(const Duration(milliseconds: 25))
        ..advance(const Duration(milliseconds: 25));

      expect(harness.opacity, 0.25);
      expect(harness.childBuilds, afterRetarget,
          reason: 'three ticks moved the value and rebuilt nothing below the '
              'AnimatedOpacity; `widget.child` is the same instance every '
              'time, so updateChild takes its identical short circuit');
      harness.dispose();
    });
  });

  group('AnimatedAlign', () {
    test('the alignment walks, and a null factor stays null', () {
      final _AlignHarness harness = _AlignHarness(Alignment.topLeft);

      harness
        ..target(Alignment.bottomRight)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));

      expect(harness.alignment, Alignment.center,
          reason: 'halfway between the two opposite corners');
      expect(harness.render.widthFactor, isNull);

      harness.advance(const Duration(milliseconds: 50));
      expect(harness.alignment, Alignment.bottomRight);
      harness.dispose();
    });

    test('every property is retargeted, not only the first one that moved', () {
      final _AlignHarness harness = _AlignHarness(
        Alignment.topLeft,
        widthFactor: 1,
      );

      // Both change in the same update. A `||` chain in `retarget` would stop
      // after the alignment and leave the factor aimed at 1 while the widget
      // asked for 3.
      harness
        ..target(Alignment.bottomRight, widthFactor: 3)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 100));

      expect(harness.alignment, Alignment.bottomRight);
      expect(harness.render.widthFactor, 3.0);
      harness.dispose();
    });
  });

  group('AnimatedPadding', () {
    test('each edge walks independently', () {
      final _PaddingHarness harness =
          _PaddingHarness(const EdgeInsets.only(left: 10));

      harness
        ..target(const EdgeInsets.only(left: 30, top: 8))
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));

      expect(harness.padding, const EdgeInsets.only(left: 20, top: 4));

      harness.advance(const Duration(milliseconds: 50));
      expect(harness.padding, const EdgeInsets.only(left: 30, top: 8));
      harness.dispose();
    });
  });

  group('AnimatedPositioned', () {
    test('the stack child slides, and its parent data is what moves', () {
      final _PositionedHarness harness = _PositionedHarness(left: 0, top: 0);

      harness
        ..target(left: 100, top: 40)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));

      expect(harness.parentData.left, 50.0);
      expect(harness.parentData.top, 20.0);
      expect(harness.childOffset, const Offset(50, 20),
          reason: 'the parent data reached the stack, which is the half a '
              'ParentDataWidget can silently get wrong');

      harness.advance(const Duration(milliseconds: 50));
      expect(harness.childOffset, const Offset(100, 40));
      harness.dispose();
    });

    test('an edge that turns null snaps rather than sliding to zero', () {
      final _PositionedHarness harness = _PositionedHarness(left: 0, top: 0);

      harness
        ..target(left: null, top: 0)
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 25));
      expect(harness.parentData.left, 0.0, reason: 'before the midpoint');

      harness.advance(const Duration(milliseconds: 50));
      expect(harness.parentData.left, isNull, reason: 'after it');
      harness.dispose();
    });
  });

  group('AnimatedDefaultTextStyle', () {
    test('size and colour interpolate; family snaps at the midpoint', () {
      final _TextStyleHarness harness = _TextStyleHarness(
        const TextStyle(
          fontSize: 10,
          color: Color(0xFF000000),
          fontFamily: 'A',
        ),
      );

      harness
        ..target(const TextStyle(
          fontSize: 20,
          color: Color(0xFFFFFFFF),
          fontFamily: 'B',
        ))
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 25));

      expect(harness.style.fontSize, 12.5);
      expect(harness.style.fontFamily, 'A', reason: 'before the midpoint');

      harness.advance(const Duration(milliseconds: 50));
      expect(harness.style.fontSize, 17.5);
      expect(harness.style.fontFamily, 'B');
      expect(harness.style.color!.red, greaterThan(0x80));

      harness.advance(const Duration(milliseconds: 25));
      expect(harness.style.fontSize, 20.0);
      expect(harness.style.color, const Color(0xFFFFFFFF));
      harness.dispose();
    });
  });

  group('inside a real application frame', () {
    // The harnesses above stand in for the window's settle loop. This one is
    // the window's settle loop: `ApplicationWindow.drawFrame` ticks the clock
    // *inside* the frame and then gives up with "the frame did not settle in 8
    // passes" if the resulting build keeps re-dirtying itself. That failure has
    // been paid for three times in this repository and it does not reproduce
    // headlessly with a hand-rolled owner, so the real shell runs here.
    test('a running transition never stops a frame from settling', () async {
      final GlobalKey<_TogglerState> key = GlobalKey<_TogglerState>();
      final List<FrameworkError> errors = <FrameworkError>[];
      final Application application = await Application.start(
        rootWidget: _Toggler(key: key),
        backends: <WindowingBackendEntry>[
          const WindowingBackendEntry(
            name: 'headless',
            create: HeadlessWindowingBackend.new,
          ),
        ],
        options: ApplicationOptions(
          size: const Size(64, 64),
          onError: errors.add,
        ),
      );
      final ApplicationWindow window = application.primaryWindow;

      await window.drawFrame();
      expect(key.currentState, isNotNull);
      key.currentState!.flip();

      // The shell's clock is virtual and moves only when a real timer says an
      // animation frame is due, so the wait here is what lets that timer fire.
      // Each frame it arms then advances virtual time by one interval, and
      // fifteen of them cover the 100 ms transition several times over.
      for (int frame = 0; frame < 15; frame++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await window.drawFrame();
      }

      expect(errors, isEmpty,
          reason: 'a frame that failed to settle reports through '
              'ApplicationOptions.onError before anything is visible');
      expect(application.framesPresented, greaterThanOrEqualTo(15));

      RenderOpacity? opacity;
      void walk(RenderBox node) {
        if (node is RenderOpacity) opacity = node;
        node.visitChildren(walk);
      }

      walk(application.buildOwner.renderRoot!);
      expect(opacity!.opacity, 0.0,
          reason: 'the transition ran to completion on the shell\'s own clock');

      application.dispose();
      await application.closed;
    });
  });
}

/// A root whose animated target a test can flip from outside the tree.
final class _Toggler extends StatefulWidget {
  const _Toggler({super.key});

  @override
  State<_Toggler> createState() => _TogglerState();
}

final class _TogglerState extends State<_Toggler> {
  double _opacity = 1;

  void flip() => setState(() => _opacity = 0);

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 100),
        child: const ColoredBox(color: Color(0xFF334455)),
      );
}

/// Everything the harnesses share: an owner, a virtual clock, and the loop that
/// stands in for the window's settle pass.
abstract class _Base {
  _Base({
    required this.withClock,
    required this.reducedMotion,
    Size size = const Size(200, 200),
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
  }

  final bool withClock;
  final bool reducedMotion;
  final AnimationClock clock = AnimationClock();
  final ManualDispatcher dispatcher = ManualDispatcher();

  late final BuildOwner owner;

  Widget content();

  Widget _root() {
    final Widget themed = Theme(
      data: ThemeData.neutralLight.copyWith(reducedMotion: reducedMotion),
      child: content(),
    );
    return withClock ? AnimationScope(clock: clock, child: themed) : themed;
  }

  /// Mounts or re-mounts the root and runs frames until nothing is dirty.
  ///
  /// The loop is the window's, shrunk: build, then layout and paint, then look
  /// again - because a tick that lands mid-frame dirties a build the frame is
  /// already settling, and eight passes is where the real one gives up.
  void settle({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (pass == 0) {
        owner.updateRoot(_root());
      } else {
        owner.buildScope();
      }
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree did not settle in $maxPasses passes');
  }

  /// A frame at the current instant: establishes the controller's origin
  /// without consuming any of its duration.
  void tickNow() {
    clock.tick(dispatcher.elapsed);
    _pump();
  }

  /// Moves the virtual clock and runs the frame that follows.
  void advance(Duration delta) {
    dispatcher.advance(delta);
    clock.tick(dispatcher.elapsed);
    _pump();
  }

  void _pump({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the frame did not settle in $maxPasses passes');
  }

  void dispose() => owner.dispose();

  /// The single node of type [T] in the render tree.
  T find<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return found.single;
  }
}

final class _Harness extends _Base {
  _Harness.opacity(
    this._opacity, {
    this.curve = Curves.linear,
    this.duration = const Duration(milliseconds: 100),
    this.onEnd,
    super.withClock = true,
    super.reducedMotion = false,
  }) {
    settle();
  }

  final Curve curve;
  final Duration duration;
  final void Function()? onEnd;
  double _opacity;

  /// How many times the subtree *below* the animated widget has been built.
  int childBuilds = 0;

  /// One const child, built once and handed to every rebuild, which is what
  /// makes the `identical` short circuit in `Element.updateChild` apply.
  late final Widget _child = Builder(
    builder: (BuildContext context) {
      childBuilds++;
      return const ColoredBox(color: Color(0xFF112233));
    },
  );

  void target(double value) => _opacity = value;

  @override
  Widget content() => AnimatedOpacity(
        opacity: _opacity,
        duration: duration,
        curve: curve,
        onEnd: onEnd,
        child: _child,
      );

  double get opacity => find<RenderOpacity>().opacity;
}

final class _AlignHarness extends _Base {
  _AlignHarness(this._alignment, {double? widthFactor})
      : _widthFactor = widthFactor,
        super(withClock: true, reducedMotion: false) {
    settle();
  }

  Alignment _alignment;
  double? _widthFactor;

  void target(Alignment value, {double? widthFactor}) {
    _alignment = value;
    _widthFactor = widthFactor ?? _widthFactor;
  }

  @override
  Widget content() => AnimatedAlign(
        alignment: _alignment,
        widthFactor: _widthFactor,
        duration: const Duration(milliseconds: 100),
        child: const SizedBox(width: 20, height: 20),
      );

  RenderAlign get render => find<RenderAlign>();

  Alignment get alignment => render.alignment;
}

final class _PaddingHarness extends _Base {
  _PaddingHarness(this._padding)
      : super(withClock: true, reducedMotion: false) {
    settle();
  }

  EdgeInsets _padding;

  void target(EdgeInsets value) => _padding = value;

  @override
  Widget content() => AnimatedPadding(
        padding: _padding,
        duration: const Duration(milliseconds: 100),
        child: const SizedBox(width: 20, height: 20),
      );

  EdgeInsets get padding => find<RenderPadding>().padding;
}

final class _PositionedHarness extends _Base {
  _PositionedHarness({required double? left, required double? top})
      : _left = left,
        _top = top,
        super(withClock: true, reducedMotion: false) {
    settle();
  }

  double? _left;
  double? _top;

  void target({required double? left, required double? top}) {
    _left = left;
    _top = top;
  }

  @override
  Widget content() => Stack(
        children: <Widget>[
          AnimatedPositioned(
            left: _left,
            top: _top,
            width: 20,
            height: 20,
            duration: const Duration(milliseconds: 100),
            child: const ColoredBox(color: Color(0xFF445566)),
          ),
        ],
      );

  RenderColoredBox get child => find<RenderColoredBox>();

  StackParentData get parentData => child.parentData! as StackParentData;

  Offset get childOffset => child.offsetFromParent;
}

final class _TextStyleHarness extends _Base {
  _TextStyleHarness(this._style)
      : super(withClock: true, reducedMotion: false) {
    settle();
  }

  TextStyle _style;
  TextStyle? _observed;

  void target(TextStyle value) => _style = value;

  @override
  Widget content() => AnimatedDefaultTextStyle(
        style: _style,
        duration: const Duration(milliseconds: 100),
        child: Builder(
          builder: (BuildContext context) {
            _observed = DefaultTextStyle.of(context);
            return const ColoredBox(color: Color(0xFF778899));
          },
        ),
      );

  /// The style a descendant actually reads.
  ///
  /// Read through a real dependency rather than off the widget, because
  /// `DefaultTextStyle.updateShouldNotify` compares by identity - a style that
  /// interpolates to an equal-but-new instance still has to reach the subtree,
  /// and one that stops changing must stop notifying.
  TextStyle get style => _observed!;
}
