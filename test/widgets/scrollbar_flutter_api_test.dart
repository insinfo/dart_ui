/// `Scrollbar` with Flutter's parameters: `controller:` (the scroll view's
/// `ScrollController`), `thumbVisibility`, `trackVisibility`, `thickness`,
/// `radius` and `interactive`.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _Harness {
  _Harness(Widget Function() root) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      ),
    );
    owner.updateRoot(Theme(data: ThemeData.neutralLight, child: root()));
    frame();
  }

  late final BuildOwner owner;
  DisplayList display = DisplayList();

  void frame() {
    for (int pass = 0; pass < 8; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      display = DisplayList();
      owner.pipelineOwner.drawFrame(display);
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('never settled');
  }

  RenderScrollbar? get bar {
    RenderScrollbar? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is RenderScrollbar) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  /// The rounded rectangles drawn, with their x radius.
  List<(Rect, double)> get rrects {
    final DisplayListReader reader = DisplayListReader(display);
    final List<(Rect, double)> out = <(Rect, double)>[];
    while (reader.moveNext()) {
      if (reader.opcode != opDrawRRect) continue;
      out.add((
        Rect.fromLTRB(reader.floatAt(0), reader.floatAt(1), reader.floatAt(2),
            reader.floatAt(3)),
        reader.floatAt(4),
      ));
    }
    return out;
  }

  void dispose() => owner.dispose();
}

Widget _list(ScrollController controller) => ListView(
      controller: controller,
      children: <Widget>[
        for (int i = 0; i < 40; i++) const SizedBox(height: 20),
      ],
    );

void main() {
  test('controller: follows the ScrollController given to the view', () {
    final ScrollController controller = ScrollController();
    final _Harness harness = _Harness(() => Scrollbar(
          controller: controller,
          thumbVisibility: true,
          child: _list(controller),
        ));

    // The view attached during the first build and laid out; the bar shows
    // that view's position.
    expect(controller.hasClients, isTrue);
    final RenderScrollbar bar = harness.bar!;
    expect(identical(bar.position, controller.position), isTrue);
    expect(bar.thumbMetrics!.start, 0);

    controller.jumpTo(controller.position.maxScrollExtent);
    harness.frame();
    expect(bar.thumbMetrics!.start + bar.thumbMetrics!.extent,
        bar.usableTrackExtent);
    harness.dispose();
  });

  test('controller: also takes a ScrollPosition, as the views do', () {
    final ScrollPosition position =
        ScrollPosition(viewportExtent: 100, contentExtent: 400);
    final _Harness harness = _Harness(() => Scrollbar(
          controller: position,
          child: const SizedBox(width: 200, height: 100),
        ));
    expect(identical(harness.bar!.position, position), isTrue);
    harness.dispose();
  });

  test('neither position nor controller is a named ArgumentError', () {
    expect(
      () => _Harness(() => const Scrollbar(child: SizedBox())),
      throwsA(isA<ArgumentError>().having(
          (ArgumentError e) => e.message, 'message', contains('controller'))),
    );
  });

  test('thumbVisibility: false hides the thumb until it scrolls', () {
    final ScrollController controller = ScrollController();
    final _Harness harness = _Harness(() => Scrollbar(
          controller: controller,
          thumbVisibility: false,
          dispatcher: ManualDispatcher(),
          child: _list(controller),
        ));
    expect(harness.bar, isNull, reason: 'hidden until something moves');
    controller.jumpTo(40);
    harness.frame();
    expect(harness.bar, isNotNull);
    // The bar appearing did not rebuild the list from scratch: same
    // position, same offset.
    expect(controller.offset, 40);
    expect(identical(harness.bar!.position, controller.position), isTrue);
    harness.dispose();
  });

  test('the scroll view\'s own bar stands down under an explicit one', () {
    final ScrollController controller = ScrollController();
    final _Harness harness = _Harness(() => Scrollbar(
          controller: controller,
          thickness: 10,
          child: _list(controller),
        ));
    var bars = 0;
    void walk(RenderBox node) {
      if (node is RenderScrollbar) bars++;
      node.visitChildren(walk);
    }

    walk(harness.owner.renderRoot!);
    expect(bars, 1, reason: 'one thumb, not two drawn over each other');
    expect(harness.bar!.thickness, 10);
    harness.dispose();
  });

  test('thickness, radius and trackVisibility reach the painted bar', () {
    final ScrollController controller = ScrollController();
    final _Harness harness = _Harness(() => Scrollbar(
          controller: controller,
          thumbVisibility: true,
          trackVisibility: true,
          thickness: 8,
          radius: const Radius.circular(2),
          child: _list(controller),
        ));
    final RenderScrollbar bar = harness.bar!;
    expect(bar.thickness, 8);
    expect(bar.radius, const Radius.circular(2));
    expect(bar.trackVisibility, isTrue);
    // Track and thumb, both 8 wide and with the 2 px corners asked for.
    final List<(Rect, double)> drawn = harness.rrects;
    expect(drawn, hasLength(2));
    for (final (Rect rect, double radius) in drawn) {
      expect(rect.width, 8);
      expect(radius, 2);
    }
    harness.dispose();
  });

  test('trackVisibility: false leaves only the thumb', () {
    final ScrollController controller = ScrollController();
    final _Harness harness = _Harness(() => Scrollbar(
          controller: controller,
          trackVisibility: false,
          child: _list(controller),
        ));
    expect(harness.rrects, hasLength(1));
    harness.dispose();
  });

  test('interactive: false makes it an indicator', () {
    final ScrollController controller = ScrollController();
    final _Harness harness = _Harness(() => Scrollbar(
          controller: controller,
          interactive: false,
          child: _list(controller),
        ));
    expect(harness.bar!.interactive, isFalse);
    harness.dispose();
  });
}
