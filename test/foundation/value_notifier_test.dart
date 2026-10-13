/// `ValueNotifier` as Flutter's: a `ChangeNotifier` and a `ValueListenable`,
/// so it goes wherever a `Listenable` does - while the older listener shape,
/// `void Function(T value)`, keeps working.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../layout/helpers.dart';

void main() {
  group('ValueNotifier', () {
    test('is a ChangeNotifier and a ValueListenable', () {
      final ValueNotifier<int> notifier = ValueNotifier<int>(1);
      expect(notifier, isA<ChangeNotifier>());
      expect(notifier, isA<Listenable>());
      expect(notifier, isA<ValueListenable<int>>());
      final ValueListenable<int> readOnly = notifier;
      expect(readOnly.value, 1);
      expect('$notifier', 'ValueNotifier<int>(1)');
    });

    test('Flutter\'s zero-argument listener', () {
      final ValueNotifier<String> notifier = ValueNotifier<String>('a');
      final List<String> seen = <String>[];
      void listener() => seen.add(notifier.value);
      notifier
        ..addListener(listener)
        ..value = 'b'
        // Equal value: no notification, as in Flutter.
        ..value = 'b'
        ..value = 'c';
      expect(seen, <String>['b', 'c']);
      notifier
        ..removeListener(listener)
        ..value = 'd';
      expect(seen, <String>['b', 'c']);
    });

    test('the value-taking listener still works, and is removable', () {
      final ValueNotifier<int> notifier = ValueNotifier<int>(0);
      final List<int> seen = <int>[];
      void listener(int value) => seen.add(value);
      notifier
        ..addListener(listener)
        ..value = 3;
      expect(seen, <int>[3]);
      notifier
        ..removeListener(listener)
        ..value = 4;
      expect(seen, <int>[3]);
    });

    test('a Listenable view only sees the zero-argument shape', () {
      final ValueNotifier<int> notifier = ValueNotifier<int>(0);
      final Listenable listenable = notifier;
      var calls = 0;
      void listener() => calls++;
      listenable.addListener(listener);
      notifier.value = 1;
      listenable.removeListener(listener);
      notifier.value = 2;
      expect(calls, 1);
    });

    test('anything else is refused by name', () {
      final ValueNotifier<int> notifier = ValueNotifier<int>(0);
      expect(() => notifier.addListener((int a, int b) {}),
          throwsA(isA<ArgumentError>()));
      expect(() => notifier.addListener((String s) {}),
          throwsA(isA<ArgumentError>()));
    });

    test('Listenable.merge and dispose', () {
      final ValueNotifier<int> a = ValueNotifier<int>(0);
      final ValueNotifier<bool> b = ValueNotifier<bool>(false);
      var calls = 0;
      Listenable.merge(<Listenable>[a, b]).addListener(() => calls++);
      a.value = 1;
      b.value = true;
      expect(calls, 2);
      a.dispose();
      expect(() => a.addListener(() {}), throwsStateError);
    });
  });

  group('as a Listenable in the widget layer', () {
    test('ValueListenableBuilder takes a ValueListenable and rebuilds',
        () async {
      final ValueNotifier<int> counter = ValueNotifier<int>(0);
      final ValueListenable<int> listenable = counter;
      final List<int> built = <int>[];
      final BuildOwner owner = BuildOwner(
          pipelineOwner: PipelineOwner(
              rootConstraints: BoxConstraints.tight(const Size(10, 10))));
      owner.updateRoot(ValueListenableBuilder<int>(
        valueListenable: listenable,
        builder: (BuildContext context, int value, Widget? child) {
          built.add(value);
          return const SizedBox();
        },
      ));
      owner.buildScope();
      counter.value = 5;
      owner.buildScope();
      expect(built, <int>[0, 5]);
    });

    test('ListenableBuilder and AnimatedBuilder rebuild on it', () {
      final ValueNotifier<int> counter = ValueNotifier<int>(0);
      final List<String> built = <String>[];
      final BuildOwner owner = BuildOwner(
          pipelineOwner: PipelineOwner(
              rootConstraints: BoxConstraints.tight(const Size(10, 10))));
      owner.updateRoot(Column(children: <Widget>[
        ListenableBuilder(
          listenable: counter,
          builder: (BuildContext context, Widget? child) {
            built.add('listenable ${counter.value}');
            return const SizedBox();
          },
        ),
        AnimatedBuilder(
          animation: counter,
          builder: (BuildContext context, Widget? child) {
            built.add('animated ${counter.value}');
            return const SizedBox();
          },
        ),
      ]));
      owner.buildScope();
      counter.value = 1;
      owner.buildScope();
      expect(built, <String>[
        'listenable 0',
        'animated 0',
        'listenable 1',
        'animated 1',
      ]);
    });

    test('CustomPainter(repaint:) repaints when it changes', () async {
      final ValueNotifier<Color> colour =
          ValueNotifier<Color>(const Color(0xFFFF0000));
      final PipelineOwner pipeline = PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(4, 4)));
      BuildOwner(pipelineOwner: pipeline)
          .updateRoot(CustomPaint(painter: _Fill(colour)));
      Future<(int, int, int, int)> paint() async {
        final DisplayList list = DisplayList();
        pipeline.drawFrame(list);
        final MemoryRenderTarget target = await memoryTarget(4, 4);
        addTearDown(target.dispose);
        await target.renderDisplayList(list, clearColor: 0xFFFFFFFF);
        return pixelAt(target.framebuffer, 1, 1);
      }

      expect(await paint(), (0xFF, 0, 0, 0xFF));
      colour.value = const Color(0xFF0000FF);
      expect(pipeline.needsPaint, isTrue,
          reason: 'the notifier changed and the painter listens to it');
      expect(await paint(), (0, 0, 0xFF, 0xFF));
    });
  });
}

final class _Fill extends CustomPainter {
  _Fill(this.colour) : super(repaint: colour);

  final ValueNotifier<Color> colour;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawRect(Offset.zero & size, Paint()..color = colour.value);

  @override
  bool shouldRepaint(_Fill oldDelegate) => false;
}
