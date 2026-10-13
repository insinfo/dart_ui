/// The colour picker: HSV arithmetic, the hex codec, and the four ways a
/// colour gets in - plane, strips, keys and typing.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('HsvColor', () {
    test('round-trips the primaries, the greys and a translucent colour', () {
      for (final Color color in const <Color>[
        Color(0xFFFF0000),
        Color(0xFF00FF00),
        Color(0xFF0000FF),
        Color(0xFFFFFFFF),
        Color(0xFF000000),
        Color(0xFF808080),
        Color(0x80336699),
        Color(0xFFFFA500),
      ]) {
        expect(HsvColor.fromColor(color).toColor(), color,
            reason: colorToHex(color));
      }
    });

    test('reads hue, saturation and value the textbook way', () {
      final HsvColor orange = HsvColor.fromColor(const Color(0xFFFFA500));
      expect(orange.hue, closeTo(38.8, 0.1));
      expect(orange.saturation, 1);
      expect(orange.value, 1);
      expect(HsvColor.fromColor(const Color(0xFF808080)).saturation, 0);
    });
  });

  group('hex', () {
    test('writes RRGGBB for opaque colours and AARRGGBB otherwise', () {
      expect(colorToHex(const Color(0xFF3366CC)), '3366CC');
      expect(colorToHex(const Color(0x803366CC)), '803366CC');
    });

    test('reads the short, long and alpha forms, with or without #', () {
      expect(colorFromHex('#36c'), const Color(0xFF3366CC));
      expect(colorFromHex('3366cc'), const Color(0xFF3366CC));
      expect(colorFromHex(' #803366CC '), const Color(0x803366CC));
      expect(colorFromHex('12345'), isNull);
      expect(colorFromHex('GG0000'), isNull);
      expect(colorFromHex(''), isNull);
    });
  });

  group('ColorPicker', () {
    test('a press in the plane sets saturation across and value down', () {
      final _Picker picker = _Picker(const Color(0xFFFF0000));
      final RenderColorPlane plane = picker.find<RenderColorPlane>();
      picker.drag(plane, const Offset(0.5, 0), const Offset(0.5, 0));
      final HsvColor chosen = HsvColor.fromColor(picker.chosen.last);
      expect(chosen.hue, 0);
      expect(chosen.saturation, closeTo(0.5, 0.01));
      expect(chosen.value, 1);
      picker.dispose();
    });

    test('dragging the hue strip keeps saturation and value', () {
      final _Picker picker = _Picker(const HsvColor(1, 0, 0.5, 0.8).toColor());
      final RenderColorStrip hue = picker
          .findAll<RenderColorStrip>()
          .firstWhere((RenderColorStrip strip) => strip.hue);
      picker.drag(hue, const Offset(0.5, 0.1), const Offset(0.5, 0.5));
      final HsvColor chosen = HsvColor.fromColor(picker.chosen.last);
      expect(chosen.hue, closeTo(180, 2));
      expect(chosen.saturation, closeTo(0.5, 0.01));
      expect(chosen.value, closeTo(0.8, 0.01));
      picker.dispose();
    });

    test('the alpha strip sets opacity, and hiding it hides alpha', () {
      final _Picker picker = _Picker(const Color(0xFF0000FF));
      final RenderColorStrip alpha = picker
          .findAll<RenderColorStrip>()
          .firstWhere((RenderColorStrip strip) => !strip.hue);
      picker.drag(alpha, const Offset(0.25, 0.5), const Offset(0.25, 0.5));
      expect(picker.chosen.last.alpha, closeTo(64, 2));
      picker.dispose();

      final _Picker opaque = _Picker(const Color(0xFF0000FF), showAlpha: false);
      expect(
        opaque.findAll<RenderColorStrip>().where((s) => !s.hue),
        isEmpty,
      );
      opaque.dispose();
    });

    test('a colour dragged to black keeps its hue on the way back up', () {
      // Grey has no hue. A picker that re-read the hue from RGB would snap
      // the strip to red the moment the value reached zero.
      final _Picker picker = _Picker(const HsvColor(1, 200, 1, 1).toColor());
      final RenderColorPlane plane = picker.find<RenderColorPlane>();
      picker
        ..drag(plane, const Offset(0.999, 0), const Offset(0.999, 1.5))
        ..settle();
      expect(picker.chosen.last, const Color(0xFF000000));
      picker
        ..drag(plane, const Offset(0.999, 0.999), const Offset(0.999, -0.5))
        ..settle();
      expect(HsvColor.fromColor(picker.chosen.last).hue, closeTo(200, 1));
      picker.dispose();
    });

    test('the arrow keys move the plane cursor in steps', () {
      final _Picker picker =
          _Picker(const HsvColor(1, 120, 0.5, 0.5).toColor());
      final RenderColorPlane plane = picker.find<RenderColorPlane>();
      plane.focusNode!.requestFocus();
      picker
        ..key(logicalKeyArrowRight)
        ..key(logicalKeyArrowUp);
      final HsvColor chosen = HsvColor.fromColor(picker.chosen.last);
      expect(chosen.saturation, closeTo(0.5 + RenderColorPlane.keyStep, 0.01));
      expect(chosen.value, closeTo(0.5 + RenderColorPlane.keyStep, 0.01));
      picker.dispose();
    });

    test('typing a complete hex code chooses it; a partial one does not', () {
      final _Picker picker = _Picker(const Color(0xFF000000));
      final TextEditingController hex = picker.hexController;
      hex.value = '12';
      expect(picker.chosen, isEmpty);
      hex.value = '#336699';
      expect(picker.chosen.single, const Color(0xFF336699));
      picker.dispose();
    });
  });

  group('the eyedropper', () {
    test('shows where the window can sample, and takes what it brings back',
        () async {
      final _Sampler window = _Sampler(const Color(0x80FF8800));
      final _Picker picker =
          _Picker(const Color(0xFF000000), showAlpha: false, window: window);
      final RenderIconButton dropper = picker.find<RenderIconButton>();
      dropper.activate();
      await Future<void>.delayed(Duration.zero);
      picker.settle();
      expect(window.samples, 1);
      expect(picker.chosen.single, const Color(0xFFFF8800),
          reason: 'opaque: this picker hides alpha');
      picker.dispose();
    });

    test('a cancel changes nothing; no sampler, no button', () async {
      final _Sampler window = _Sampler(null);
      final _Picker picker = _Picker(const Color(0xFF000000), window: window);
      picker.find<RenderIconButton>().activate();
      await Future<void>.delayed(Duration.zero);
      expect(picker.chosen, isEmpty);
      picker.dispose();

      final _Picker plain = _Picker(const Color(0xFF000000));
      expect(plain.findAll<RenderIconButton>(), isEmpty);
      plain.dispose();
    });
  });
}

/// A window whose eyedropper returns [colour] - null for a cancel.
final class _Sampler implements WindowController {
  _Sampler(this.colour);

  final Color? colour;
  int samples = 0;

  @override
  bool get canSampleScreenColor => true;

  @override
  Future<Color?> sampleScreenColor() async {
    samples++;
    return colour;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One picker in a tree, re-built with each colour it reports, as an
/// application holding the colour in its state would.
final class _Picker {
  _Picker(Color initial, {this.showAlpha = true, this.window})
      : _color = initial {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(400, 400)),
      ),
    );
    owner.updateRoot(_build());
    settle();
  }

  final bool showAlpha;
  final WindowController? window;
  late final BuildOwner owner;
  Color _color;
  final List<Color> chosen = <Color>[];

  Widget _build() {
    final Widget picker = Align(
      alignment: Alignment.topLeft,
      child: ColorPicker(
        value: _color,
        showAlpha: showAlpha,
        onChanged: (Color color) {
          chosen.add(color);
          _color = color;
          owner.updateRoot(_build());
        },
      ),
    );
    final WindowController? controller = window;
    return controller == null
        ? picker
        : WindowScope(controller: controller, child: picker);
  }

  void settle() {
    for (int pass = 0; pass < 8; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  List<T> findAll<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  T find<T extends RenderBox>() => findAll<T>().single;

  TextEditingController get hexController {
    TextEditingController? controller;
    void visit(Element element) {
      final Widget widget = element.widget;
      if (widget is TextField) controller = widget.controller;
      element.visitChildren(visit);
    }

    owner.rootElement!.visitChildren(visit);
    return controller!;
  }

  /// Presses at [from] and moves to [to], both as fractions of [box].
  void drag(RenderBox box, Offset from, Offset to) {
    Offset at(Offset fraction) => box.localToGlobal(
        Offset(fraction.dx * box.size.width, fraction.dy * box.size.height));
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at(from),
      button: PointerButton.primary,
    ));
    settle();
    owner.dispatchPointerEvent(PointerMoveEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at(to),
    ));
    settle();
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at(to),
      button: PointerButton.primary,
    ));
    settle();
  }

  void key(int logicalKey) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
    settle();
  }

  void dispose() => owner.dispose();
}
