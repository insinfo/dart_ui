/// CustomPaint with Flutter's CustomPainter, and the clip widgets with
/// clippers and clip behaviours, driven through BuildOwner and
/// PipelineOwner.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../painting/helpers.dart';

const Color _red = Color(0xFFFF0000);
const (int, int, int, int) _redPixel = (0xFF, 0, 0, 0xFF);

final class _Recorder extends CustomPainter {
  _Recorder(this.log, {this.tag = 'a', super.repaint, this.hit});

  final List<String> log;
  final String tag;
  final bool? hit;

  @override
  void paint(Canvas canvas, Size size) {
    log.add('$tag ${size.width}x${size.height}');
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = _red);
  }

  @override
  bool shouldRepaint(_Recorder oldDelegate) => oldDelegate.tag != tag;

  @override
  bool? hitTest(Offset position) => hit;
}

final class _HalfClipper extends CustomClipper<Rect> {
  _HalfClipper({super.reclip});

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(_HalfClipper oldClipper) => false;
}

final class _Triangle extends CustomClipper<Path> {
  const _Triangle();

  @override
  Path getClip(Size size) => Path()
    ..moveTo(0, 0)
    ..lineTo(size.width, 0)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(_Triangle oldClipper) => false;
}

Widget _sized(Widget child, {double size = 40}) =>
    Center(child: SizedBox(width: size, height: size, child: child));

void main() {
  group('CustomPaint', () {
    test('paints a CustomPainter at its size, at its place', () async {
      final List<String> log = <String>[];
      final Framebuffer fb =
          await renderWidget(_sized(CustomPaint(painter: _Recorder(log))));
      expect(log, <String>['a 40.0x40.0']);
      expect(pixelAt(fb, 32, 32), _redPixel);
      expect(pixelAt(fb, 4, 4), kBackgroundPixel);
    });

    test('without a child it takes size; with one, the child\'s size', () {
      final (BuildOwner owner, _) = mountAndPaint(Align(
        alignment: Alignment.topLeft,
        child: CustomPaint(
            painter: _Recorder(<String>[]), size: const Size(12, 7)),
      ));
      RenderCustomPaint? node;
      void find(RenderBox n) {
        if (n is RenderCustomPaint) node = n;
        n.visitChildren(find);
      }

      find(owner.renderRoot!);
      expect(node!.size, const Size(12, 7));

      final (BuildOwner owner2, _) = mountAndPaint(Align(
        alignment: Alignment.topLeft,
        child: CustomPaint(
          painter: _Recorder(<String>[]),
          size: const Size(12, 7),
          child: const SizedBox(width: 30, height: 3),
        ),
      ));
      node = null;
      find(owner2.renderRoot!);
      expect(node!.size, const Size(30, 3));
    });

    test('background, child, foreground, in that order', () {
      final List<String> log = <String>[];
      mountAndPaint(_sized(CustomPaint(
        painter: _Recorder(log, tag: 'back'),
        foregroundPainter: _Recorder(log, tag: 'front'),
        child: const SizedBox(width: 40, height: 40),
      )));
      expect(log, <String>['back 40.0x40.0', 'front 40.0x40.0']);
    });

    test('shouldRepaint decides whether a new painter repaints', () {
      final List<String> log = <String>[];
      final RenderCustomPaint node =
          RenderCustomPaint(painter: _Recorder(log, tag: 'x'));
      final PipelineOwner pipeline = PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(10, 10)));
      pipeline.root = node;
      pipeline.drawFrame(DisplayList());
      expect(log, hasLength(1));
      expect(node.needsPaint, isFalse);
      node.painter = _Recorder(log, tag: 'x');
      expect(node.needsPaint, isFalse, reason: 'same tag: no repaint');
      node.painter = _Recorder(log, tag: 'y');
      expect(node.needsPaint, isTrue);
    });

    test('the repaint listenable repaints without a rebuild', () {
      final _Counter tick = _Counter();
      final RenderCustomPaint node =
          RenderCustomPaint(painter: _Recorder(<String>[], repaint: tick));
      final PipelineOwner pipeline = PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(10, 10)));
      pipeline.root = node;
      expect(tick.listeners, 1);
      pipeline.drawFrame(DisplayList());
      expect(node.needsPaint, isFalse);
      tick.fire();
      expect(node.needsPaint, isTrue);
      pipeline.root = null;
      expect(tick.listeners, 0, reason: 'detached: unsubscribed');
    });

    test('hit testing asks the painters', () {
      RenderCustomPaint laid(CustomPaint w) {
        final RenderCustomPaint node = RenderCustomPaint(
            painter: w.painter, foregroundPainter: w.foregroundPainter);
        node.layout(BoxConstraints.tight(const Size(10, 10)));
        return node;
      }

      expect(
          laid(CustomPaint(painter: _Recorder(<String>[])))
              .hitTest(const Offset(5, 5)),
          isNotNull,
          reason: 'a background painter claims the box by default');
      expect(
          laid(CustomPaint(painter: _Recorder(<String>[], hit: false)))
              .hitTest(const Offset(5, 5)),
          isNull);
      expect(
          laid(CustomPaint(foregroundPainter: _Recorder(<String>[])))
              .hitTest(const Offset(5, 5)),
          isNull,
          reason: 'a foreground painter claims nothing by default');
      expect(
          laid(CustomPaint(foregroundPainter: _Recorder(<String>[], hit: true)))
              .hitTest(const Offset(5, 5)),
          isNotNull);
    });

    test('the framework\'s BoxPainter closure still works', () async {
      final Framebuffer fb = await renderWidget(_sized(CustomPaint(
        painter: (DisplayList list, Size size) => list.drawRect(0, 0,
            size.width, size.height, list.addPaint(colorArgb: _red.value)),
        size: const Size(40, 40),
      )));
      expect(pixelAt(fb, 32, 32), _redPixel);
    });

    test('anything else is an ArgumentError', () {
      expect(() => RenderCustomPaint(painter: 'nope'), throwsArgumentError);
    });
  });

  group('clips', () {
    Widget red() => const ColoredBox(color: _red);

    test('ClipOval cuts to the inscribed oval, in paint and for the pointer',
        () async {
      final Framebuffer fb = await renderWidget(_sized(ClipOval(child: red())));
      expect(pixelAt(fb, 32, 32), _redPixel);
      expect(pixelAt(fb, 13, 13), kBackgroundPixel);
      final RenderClipOval node =
          RenderClipOval(child: RenderColoredBox(color: _red));
      node.layout(BoxConstraints.tight(const Size(20, 20)));
      expect(node.hitTest(const Offset(10, 10)), isNotNull);
      expect(node.hitTest(const Offset(1, 1)), isNull);
    });

    test('ClipPath with a clipper', () async {
      final Framebuffer fb = await renderWidget(
          _sized(ClipPath(clipper: const _Triangle(), child: red())));
      expect(pixelAt(fb, 16, 16), _redPixel, reason: 'top-left half');
      expect(pixelAt(fb, 48, 48), kBackgroundPixel);
    });

    test('ClipPath.shape clips to a ShapeBorder', () async {
      final Framebuffer fb = await renderWidget(_sized(ClipPath.shape(
        shape: const StadiumBorder(),
        child: red(),
      )));
      expect(pixelAt(fb, 32, 32), _redPixel);
      expect(pixelAt(fb, 13, 13), kBackgroundPixel);
    });

    test('ClipRRect takes Flutter\'s borderRadius', () async {
      final Framebuffer fb = await renderWidget(_sized(ClipRRect(
        borderRadius: const BorderRadius.only(bottomRight: Radius.circular(20)),
        child: red(),
      )));
      expect(pixelAt(fb, 13, 13), _redPixel, reason: 'square corner');
      expect(pixelAt(fb, 50, 50), kBackgroundPixel, reason: 'round corner');
    });

    test('Clip.none paints unclipped', () async {
      final Framebuffer fb = await renderWidget(_sized(ClipOval(
        clipBehavior: Clip.none,
        child: red(),
      )));
      expect(pixelAt(fb, 13, 13), _redPixel);
    });

    test('ClipRect with a clipper, and its reclip listenable', () {
      final _Counter reclip = _Counter();
      final (BuildOwner owner, DisplayList list) = mountAndPaint(_sized(
          ClipRect(clipper: _HalfClipper(reclip: reclip), child: red())));
      final ClipRectCommand clip =
          expandDisplayList(list).whereType<ClipRectCommand>().single;
      expect(clip.right - clip.left, 20);
      RenderClipRect? node;
      void find(RenderBox n) {
        if (n is RenderClipRect) node = n;
        n.visitChildren(find);
      }

      find(owner.renderRoot!);
      expect(node!.hitTest(const Offset(30, 10)), isNull,
          reason: 'outside the custom clip');
      expect(node!.hitTest(const Offset(10, 10)), isNotNull);
      expect(node!.needsPaint, isFalse);
      reclip.fire();
      expect(node!.needsPaint, isTrue);
    });

    test('a rotated CustomPainter clip still cuts the right shape', () async {
      final Framebuffer fb = await renderWidget(_sized(CustomPaint(
        painter: _Rotated(),
      )));
      expect(pixelAt(fb, 32, 32), _redPixel);
    });
  });
}

final class _Rotated extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..translate(size.width / 2, size.height / 2)
      ..rotate(math.pi / 6)
      ..clipRRect(RRect.fromLTRBR(-15, -15, 15, 15, const Radius.circular(4)))
      ..drawPaint(Paint()..color = _red);
  }

  @override
  bool shouldRepaint(_Rotated oldDelegate) => false;
}

/// A [Listenable] that counts its listeners.
final class _Counter implements Listenable {
  final List<void Function()> _listeners = <void Function()>[];

  int get listeners => _listeners.length;

  void fire() {
    for (final void Function() l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);
}
