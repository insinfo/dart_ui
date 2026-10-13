/// BoxDecoration with Flutter's borderRadius, Border, BoxShadow and shape;
/// ShapeDecoration with the shape borders; Container's border padding.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const Color _fill = Color(0xFF3366CC);
const (int, int, int, int) _fillPixel = (0x33, 0x66, 0xCC, 0xFF);
const Color _line = Color(0xFFCC3311);
const (int, int, int, int) _linePixel = (0xCC, 0x33, 0x11, 0xFF);

Widget _box(Decoration decoration, {double size = 40}) => Center(
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(decoration: decoration),
      ),
    );

void main() {
  group('BoxDecoration', () {
    test('borderRadius rounds per corner', () async {
      final Framebuffer fb = await renderWidget(
        _box(const BoxDecoration(
          color: _fill,
          borderRadius: BorderRadius.only(topLeft: Radius.circular(16)),
        )),
      );
      // The box spans 12..52 inside the 64 window.
      expect(pixelAt(fb, 13, 13), kBackgroundPixel, reason: 'rounded corner');
      expect(pixelAt(fb, 50, 13), _fillPixel, reason: 'square corner');
      expect(pixelAt(fb, 13, 50), _fillPixel);
    });

    test('borderRadius wins over the legacy radius', () {
      const BoxDecoration d = BoxDecoration(
          radius: 3, borderRadius: BorderRadius.all(Radius.circular(9)));
      expect(d.effectiveBorderRadius(null), BorderRadius.circular(9));
      expect(const BoxDecoration(radius: 3).effectiveBorderRadius(null),
          BorderRadius.circular(3));
      expect(const BoxDecoration().effectiveBorderRadius(null), isNull);
    });

    test('Border.all paints inside the box, like the legacy BoxBorder',
        () async {
      Future<Framebuffer> paint(BoxBorder border) => renderWidget(
            _box(BoxDecoration(color: _fill, border: border), size: 20),
            width: 20,
            height: 20,
          );
      final Framebuffer flutter =
          await paint(Border.all(color: _line, width: 2));
      final Framebuffer legacy =
          await paint(const BoxBorder(color: _line, width: 2));
      for (final (int x, int y) in <(int, int)>[(10, 0), (10, 1), (10, 3)]) {
        expect(pixelAt(flutter, x, y), pixelAt(legacy, x, y));
      }
      expect(pixelAt(flutter, 10, 1), _linePixel);
      expect(pixelAt(flutter, 10, 3), _fillPixel);
    });

    test('non-uniform sides are painted with their own widths', () async {
      final Framebuffer fb = await renderWidget(
        _box(const BoxDecoration(
          color: _fill,
          border: Border(
            top: BorderSide(color: _line, width: 6),
            left: BorderSide(color: Color(0xFF00FF00), width: 2),
          ),
        )),
      );
      expect(pixelAt(fb, 32, 14), _linePixel, reason: 'inside the top side');
      expect(pixelAt(fb, 32, 19), _fillPixel);
      expect(pixelAt(fb, 12, 32), (0, 0xFF, 0, 0xFF));
      expect(pixelAt(fb, 51, 32), _fillPixel, reason: 'no right side');
    });

    test('a circle shape fills the circle and borders it', () async {
      final Framebuffer fb = await renderWidget(
        _box(BoxDecoration(
          color: _fill,
          shape: BoxShape.circle,
          border: Border.all(color: _line, width: 3),
        )),
      );
      expect(pixelAt(fb, 32, 32), _fillPixel);
      expect(pixelAt(fb, 13, 13), kBackgroundPixel);
      expect(pixelAt(fb, 32, 13), _linePixel, reason: 'top of the ring');
    });

    test('a box shadow darkens around and under the box, fading out', () async {
      final Framebuffer fb = await renderWidget(
        _box(
          const BoxDecoration(
            color: _fill,
            boxShadow: <BoxShadow>[
              BoxShadow(
                  color: Color(0xFF000000),
                  blurRadius: 8,
                  offset: Offset(0, 4)),
            ],
          ),
          size: 32,
        ),
      );
      // Box: 16..48. Below it the shadow is darkest near the edge and fades.
      final (int r1, _, _, _) = pixelAt(fb, 32, 49);
      final (int r2, _, _, _) = pixelAt(fb, 32, 55);
      final (int r3, _, _, _) = pixelAt(fb, 32, 62);
      expect(r1, lessThan(r2));
      expect(r2, lessThanOrEqualTo(r3));
      expect(r1, lessThan(0x20), reason: 'darker than the background');
      expect(pixelAt(fb, 32, 32), _fillPixel, reason: 'the box covers it');
      expect(pixelAt(fb, 32, 4), kBackgroundPixel,
          reason: 'offset down: nothing far above');
    });

    test('hit testing follows the shape', () {
      const BoxDecoration circle =
          BoxDecoration(color: _fill, shape: BoxShape.circle);
      expect(circle.hitTest(const Size(20, 20), const Offset(10, 10)), isTrue);
      expect(circle.hitTest(const Size(20, 20), const Offset(1, 1)), isFalse);
      final BoxDecoration rounded =
          BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(8));
      expect(
          rounded.hitTest(const Size(20, 20), const Offset(0.5, 0.5)), isFalse);
      expect(
          const BoxDecoration(color: _fill)
              .hitTest(const Size(20, 20), const Offset(0.5, 0.5)),
          isTrue);
    });

    test('padding is the border width; isEmpty knows what paints', () {
      expect(BoxDecoration(border: Border.all(width: 3)).padding,
          const EdgeInsets.all(3));
      expect(const BoxDecoration().isEmpty, isTrue);
      expect(const BoxDecoration(boxShadow: <BoxShadow>[BoxShadow()]).isEmpty,
          isFalse);
      expect(const BoxDecoration(border: BoxBorder(width: 0)).isEmpty, isTrue);
    });

    test('lerp interpolates radii, borders and shadows', () {
      final BoxDecoration a = BoxDecoration(
        color: const Color(0xFF000000),
        borderRadius: BorderRadius.circular(0),
        boxShadow: const <BoxShadow>[BoxShadow(blurRadius: 0)],
      );
      final BoxDecoration b = BoxDecoration(
        color: const Color(0xFFFF0000),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(width: 4),
        boxShadow: const <BoxShadow>[BoxShadow(blurRadius: 10)],
      );
      final BoxDecoration mid = BoxDecoration.lerp(a, b, 0.5)!;
      expect(mid.color, const Color(0xFF800000));
      expect(mid.borderRadius, BorderRadius.circular(5));
      expect(mid.border!.top.width, 2);
      expect(mid.boxShadow!.single.blurRadius, 5);
      expect(Decoration.lerp(a, b, 0.5), mid);
    });

    test('equality covers the new fields', () {
      expect(
        BoxDecoration(borderRadius: BorderRadius.circular(2)),
        BoxDecoration(borderRadius: BorderRadius.circular(2)),
      );
      expect(
        const BoxDecoration(boxShadow: <BoxShadow>[BoxShadow(blurRadius: 1)]) ==
            const BoxDecoration(
                boxShadow: <BoxShadow>[BoxShadow(blurRadius: 2)]),
        isFalse,
      );
    });
  });

  group('borders', () {
    test('BorderSide semantics', () {
      const BorderSide side = BorderSide(width: 4);
      expect(side.strokeInset, 4);
      expect(side.strokeOutset, 0);
      expect(
          side.copyWith(strokeAlign: BorderSide.strokeAlignCenter).strokeInset,
          2);
      expect(side.scale(0).style, BorderStyle.none);
      expect(BorderSide.none.isVisible, isFalse);
      expect(BorderSide.merge(side, side).width, 8);
      expect(BorderSide.lerp(side, const BorderSide(width: 8), 0.5).width, 6);
    });

    test('Border constructors and isUniform', () {
      const BorderSide s = BorderSide(color: _line, width: 2);
      expect(
          Border.all(color: _line, width: 2), const Border.fromBorderSide(s));
      const Border sym = Border.symmetric(vertical: s);
      expect(sym.left, s);
      expect(sym.top, BorderSide.none);
      expect(sym.isUniform, isFalse);
      expect(Border.all().isUniform, isTrue);
      expect(Border.all(width: 2) + Border.all(width: 3), Border.all(width: 5));
      expect(
          const BorderDirectional(start: s)
              .resolve(TextDirection.rightToLeft)
              .right,
          s);
    });

    test('shape borders: outer paths and dimensions', () {
      const Rect r = Rect.fromLTRB(0, 0, 40, 20);
      final Path rounded =
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
              .getOuterPath(r);
      expect(rounded.contains(const Offset(0.5, 0.5)), isFalse);
      expect(rounded.contains(const Offset(20, 10)), isTrue);
      final Path circle = const CircleBorder().getOuterPath(r);
      expect(circle.getBounds().width, closeTo(20, 1e-3));
      final Path stadium = const StadiumBorder().getOuterPath(r);
      expect(stadium.contains(const Offset(1, 10)), isTrue);
      expect(stadium.contains(const Offset(1, 1)), isFalse);
      expect(const StadiumBorder(side: BorderSide(width: 3)).dimensions,
          const EdgeInsets.all(3));
      expect(
          ShapeBorder.lerp(
              const CircleBorder(), const CircleBorder(eccentricity: 1), 0.5),
          const CircleBorder(eccentricity: 0.5));
    });
  });

  group('ShapeDecoration', () {
    test('a stadium with an outline', () async {
      final Framebuffer fb = await renderWidget(
        const Center(
          child: SizedBox(
            width: 60,
            height: 20,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: _fill,
                shape: StadiumBorder(side: BorderSide(color: _line, width: 2)),
              ),
            ),
          ),
        ),
      );
      // Box: x 2..62, y 22..42.
      expect(pixelAt(fb, 32, 32), _fillPixel);
      expect(pixelAt(fb, 32, 22), _linePixel);
      expect(pixelAt(fb, 3, 23), kBackgroundPixel, reason: 'round end');
    });

    test('fromBoxDecoration keeps the picture', () {
      final ShapeDecoration s = ShapeDecoration.fromBoxDecoration(BoxDecoration(
          color: _fill,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: _line)));
      expect(s.shape, isA<RoundedRectangleBorder>());
      expect((s.shape as RoundedRectangleBorder).side.color, _line);
      expect(
          ShapeDecoration.fromBoxDecoration(
                  const BoxDecoration(shape: BoxShape.circle))
              .shape,
          const CircleBorder());
    });

    test('hit testing follows the outer path', () {
      const ShapeDecoration d = ShapeDecoration(shape: CircleBorder());
      expect(d.hitTest(const Size(20, 20), const Offset(10, 10)), isTrue);
      expect(d.hitTest(const Size(20, 20), const Offset(1, 1)), isFalse);
    });

    test('a sweep gradient fill', () async {
      final Framebuffer fb = await renderWidget(
        _box(const ShapeDecoration(
          shape: CircleBorder(),
          gradient: SweepGradient(colors: <Color>[
            Color(0xFFFF0000),
            Color(0xFF0000FF),
          ]),
        )),
      );
      final (int r, _, int b, _) = pixelAt(fb, 48, 33);
      expect(r, greaterThan(b), reason: 'red near angle zero');
      expect(pixelAt(fb, 13, 13), kBackgroundPixel);
    });
  });

  group('Container', () {
    test('adds the border width to its padding, as in Flutter', () {
      final (BuildOwner owner, _) = mountAndPaint(
        Align(
          alignment: Alignment.topLeft,
          child: Container(
            decoration: BoxDecoration(border: Border.all(width: 5)),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      RenderBox? sized;
      void walk(RenderBox node) {
        if (node is RenderConstrainedBox) sized ??= node;
        node.visitChildren(walk);
      }

      walk(owner.renderRoot!);
      expect(sized, isNotNull);
      expect(sized!.localToGlobal(Offset.zero), const Offset(5, 5));
    });

    test('a foreground decoration paints over the child', () async {
      final Framebuffer fb = await renderWidget(
        Center(
          child: Container(
            width: 20,
            height: 20,
            foregroundDecoration: const BoxDecoration(color: _line),
            child: const ColoredBox(color: _fill),
          ),
        ),
      );
      expect(pixelAt(fb, 32, 32), _linePixel);
    });
  });
}
