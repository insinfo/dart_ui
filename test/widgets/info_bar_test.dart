import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('InfoBar', () {
    test('announces severity, title and message as one label', () {
      final harness = _Harness(
        child: const InfoBar(
          title: 'Disk almost full',
          message: 'Only 2 GB remain.',
          severity: InfoBarSeverity.warning,
        ),
      );
      harness.frame();

      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(harness.owner.renderRoot);
      expect(
        snapshot.nodes.map((SemanticsNode n) => n.label),
        contains('warning: Disk almost full. Only 2 GB remain.'),
      );
      harness.dispose();
    });

    test('the close button fires onClose', () {
      int closed = 0;
      final harness = _Harness(
        child: InfoBar(
          title: 'Saved',
          severity: InfoBarSeverity.success,
          onClose: () => closed++,
        ),
      );
      harness.frame();

      harness.find<RenderButton>()!.activate();
      expect(closed, 1);
      harness.dispose();
    });

    test('severities resolve to distinct accents on the theme', () {
      const ThemeData theme = ThemeData.neutralLight;
      final Set<Color> accents = <Color>{
        for (final InfoBarSeverity severity in InfoBarSeverity.values)
          InfoBar.accentFor(severity, theme),
      };
      expect(accents, hasLength(InfoBarSeverity.values.length));
    });
  });

  group('ToastController', () {
    test('show adds, dismiss removes, listeners hear both', () {
      final ToastController controller = ToastController();
      int notified = 0;
      controller.addListener(() => notified++);

      final int id = controller.show('Saved');
      expect(controller.entries, hasLength(1));
      expect(notified, 1);

      controller.dismiss(id);
      expect(controller.entries, isEmpty);
      expect(notified, 2);

      controller.dismiss(id);
      expect(notified, 2, reason: 'dismissing a gone toast is silent');
    });
  });

  group('ToastHost', () {
    test('renders the controller\'s toasts and closes them by button', () {
      final ToastController controller = ToastController();
      final harness = _Harness(
        child: ToastHost(
          controller: controller,
          child: const SizedBox(width: 300, height: 200),
        ),
      );
      harness.frame();
      expect(harness.find<RenderInfoBarChrome>(), isNull);

      controller.show('Copied', duration: null);
      harness.frame();
      expect(harness.find<RenderInfoBarChrome>(), isNotNull);

      harness.find<RenderButton>()!.activate();
      harness.frame();
      expect(controller.entries, isEmpty);
      expect(harness.find<RenderInfoBarChrome>(), isNull);
      harness.dispose();
    });

    test('with a clock, a timed toast dismisses itself', () {
      final AnimationClock clock = AnimationClock();
      final ManualDispatcher dispatcher = ManualDispatcher();
      final ToastController controller = ToastController();
      final harness = _Harness(
        child: ToastHost(
          controller: controller,
          clock: clock,
          child: const SizedBox(width: 300, height: 200),
        ),
      );
      harness.frame();

      controller.show('Done', duration: const Duration(seconds: 2));
      harness.frame();
      expect(controller.entries, hasLength(1));

      // First tick establishes the timer's origin; then time passes.
      clock.tick(dispatcher.elapsed);
      dispatcher.advance(const Duration(seconds: 1));
      clock.tick(dispatcher.elapsed);
      harness.frame();
      expect(controller.entries, hasLength(1),
          reason: 'one second of a two-second toast');

      dispatcher.advance(const Duration(seconds: 1));
      clock.tick(dispatcher.elapsed);
      harness.frame();
      expect(controller.entries, isEmpty);
      harness.dispose();
    });

    test('without a clock, a timed toast waits to be dismissed', () {
      final ToastController controller = ToastController();
      final harness = _Harness(
        child: ToastHost(
          controller: controller,
          child: const SizedBox(width: 300, height: 200),
        ),
      );
      harness.frame();

      controller.show('Stuck around', duration: const Duration(seconds: 2));
      harness.frame();

      expect(controller.entries, hasLength(1));
      harness.dispose();
    });
  });
}

final class _Harness {
  _Harness({required this.child}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(320, 220)),
      ),
    );
    _mount();
  }

  final Widget child;
  late final BuildOwner owner;

  void _mount() => owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: child,
      ));

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  T? find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is T) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  void dispose() => owner.dispose();
}
