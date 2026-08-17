/// The proxy nodes, checked against pixels and against coordinates.
///
/// Two things this file deliberately does not do. It does not assert "paint did
/// not throw": every claim below is either an exact colour read out of a
/// rasterised framebuffer, an exact offset, or an exact command stream. And it
/// does not compare a node against another display list produced by the same
/// node - where a reference is needed it is either the same scene built without
/// the node under test, or a number computed by hand from `mul255`.
///
/// The background is `0xFF204060` and the content `0xFFCC3311`, the same pair
/// `test/rendering/cpu_layers_test.dart` uses, so a value that looks wrong here
/// can be compared against the layer suite without re-deriving anything.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const int _background = 0xFF204060;
const int _content = 0xFFCC3311;

/// A leaf that fills a rectangle and records every point a hit test carried
/// into its own coordinate space.
///
/// The recording is what makes the transform tests assertions about *geometry*
/// rather than about "something was hit": a rotation that lands the pointer on
/// the wrong pixel still returns this node, and only the recorded offset says
/// so.
///
/// [fill] may extend past [preferred] on purpose. A child that paints outside
/// the box it was given is the only way to see a clip work at all - a proxy
/// passes its constraints straight through, so a well-behaved child can never
/// be bigger than the clip that wraps it.
final class _Probe extends RenderBox {
  _Probe({required this.preferred, this.color, this.fill});

  final Size preferred;
  final int? color;
  final Rect? fill;

  /// Every position [hitTestSelf] was offered, in order.
  final List<Offset> hits = <Offset>[];

  Offset? get lastHit => hits.isEmpty ? null : hits.last;

  @override
  void performLayout() {
    size = constraints.constrain(preferred);
  }

  @override
  bool hitTestSelf(Offset position) {
    hits.add(position);
    return true;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final int? color = this.color;
    if (color == null) return;
    final Rect local = fill ?? Rect.fromLTWH(0, 0, size.width, size.height);
    // antiAlias off: every rectangle in this file lands on integer pixel
    // boundaries, so coverage is 0 or 1 and an exact colour assertion has no
    // rounding to absorb.
    final int paintId = list.addPaint(colorArgb: color, antiAlias: false);
    list.drawRectangle(local.shift(offset), paintId);
  }
}

/// Rasterises [node] over [_background] on a [size]-square surface.
///
/// [constraints] defaults to a tight box the size of the surface. A test that
/// needs the node to be *smaller* than the surface - which is the only way to
/// see anything happen outside it, a clip especially - passes its own.
Future<Framebuffer> _render(
  RenderBox node, {
  int size = 16,
  BoxConstraints? constraints,
}) async {
  node.layout(
    constraints ?? BoxConstraints.tight(Size(size.toDouble(), size.toDouble())),
  );
  final DisplayList list = DisplayList();
  node.paint(list, Offset.zero);
  final MemoryRenderTarget target = await memoryTarget(size, size);
  addTearDown(target.dispose);
  await target.renderDisplayList(list, clearColor: _background);
  return target.framebuffer;
}

/// The command stream an already laid-out [node] produces.
List<DisplayListCommand> _paint(RenderBox node) {
  final DisplayList list = DisplayList();
  node.paint(list, Offset.zero);
  return expandDisplayList(list);
}

/// The command stream [node] produces at [size], for the structural claims.
List<DisplayListCommand> _commands(RenderBox node, {int size = 16}) {
  node.layout(BoxConstraints.tight(Size(size.toDouble(), size.toDouble())));
  return _paint(node);
}

/// (r, g, b, a) of the background as it lands in a framebuffer.
const (int, int, int, int) _backgroundPixel = (0x20, 0x40, 0x60, 0xFF);
const (int, int, int, int) _contentPixel = (0xCC, 0x33, 0x11, 0xFF);

void main() {
  group('RenderProxyBox', () {
    test('is exactly its child, at its own origin', () {
      final _Probe child = _Probe(preferred: const Size(30, 20));
      // RenderRepaintBoundary is the proxy that adds nothing at all, which
      // makes it the one that measures the base class rather than a subclass.
      final RenderRepaintBoundary node = RenderRepaintBoundary(child: child);

      node.layout(BoxConstraints(maxWidth: 100, maxHeight: 100));

      expect(node.size, const Size(30, 20));
      expect(child.size, const Size(30, 20),
          reason: 'constraints pass through');
      expect(child.offsetFromParent, Offset.zero);
    });

    test('collapses to the smallest constraint with no child', () {
      final RenderRepaintBoundary node = RenderRepaintBoundary();

      node.layout(BoxConstraints(minWidth: 4, maxWidth: 100));

      expect(node.size, const Size(4, 0));
    });

    test('forwards intrinsics and hit tests to the child', () {
      final _Probe child = _Probe(preferred: const Size(30, 20));
      final RenderRepaintBoundary node = RenderRepaintBoundary(child: child);
      node.layout(BoxConstraints(maxWidth: 100, maxHeight: 100));

      expect(node.getMaxIntrinsicWidth(double.infinity), 0.0,
          reason: '_Probe declares none, and the proxy must not invent one');
      expect(node.hitTest(const Offset(5, 5)), same(child));
      expect(child.lastHit, const Offset(5, 5),
          reason: 'a proxy adds no displacement');
    });
  });

  group('RenderOpacity', () {
    test('at 0.5 composites to the exact value mul255 produces', () async {
      final RenderOpacity node = RenderOpacity(
        opacity: 0.5,
        child: _Probe(preferred: const Size(16, 16), color: _content),
      );

      final Framebuffer buffer = await _render(node);

      // Derived by hand from `mul255(v, a) == round(v * a / 255)`, not read off
      // a previous run. 0.5 quantises to alpha 0x80; the layer holds the
      // content scaled by it, and that is composited source-over onto the
      // background scaled by the complement:
      //
      //   r: mul255(0xCC, 0x80) + mul255(0x20, 0x7F) = 102 + 16 = 118
      //   g: mul255(0x33, 0x80) + mul255(0x40, 0x7F) =  26 + 32 =  58
      //   b: mul255(0x11, 0x80) + mul255(0x60, 0x7F) =   9 + 48 =  57
      expect(pixelAt(buffer, 8, 8), (118, 58, 57, 0xFF));

      // And the same numbers, re-derived through the rasteriser's own helper,
      // so that a change to mul255 fails here as loudly as a change to this
      // node would.
      expect(
        pixelAt(buffer, 8, 8),
        (
          mul255(0xCC, 0x80) + mul255(0x20, 0x7F),
          mul255(0x33, 0x80) + mul255(0x40, 0x7F),
          mul255(0x11, 0x80) + mul255(0x60, 0x7F),
          0xFF,
        ),
      );
    });

    test('at 0.5 the alpha really is 0x80 and not 127', () {
      // The rounding at the quantisation step, pinned: `(0.5 * 255).round()`
      // is 128, and truncation would give 127 - a whole level darker on every
      // half-opacity fade in the framework.
      expect(RenderOpacity(opacity: 0.5).alpha, 0x80);
      expect(RenderOpacity(opacity: 1.0).alpha, 0xFF);
      expect(RenderOpacity(opacity: 0.0).alpha, 0x00);
    });

    test('at 1 emits no saveLayer at all', () async {
      final RenderOpacity opaque = RenderOpacity(
        opacity: 1.0,
        child: _Probe(preferred: const Size(16, 16), color: _content),
      );

      final List<DisplayListCommand> commands = _commands(opaque);

      expect(
        commands.whereType<SaveLayerCommand>(),
        isEmpty,
        reason: 'a layer to multiply every channel by 1 is a cost with no '
            'output',
      );
      // Stronger than "no saveLayer": the stream is *identical* to the one the
      // child produces on its own, so nothing at all was emitted around it.
      final _Probe bare =
          _Probe(preferred: const Size(16, 16), color: _content);
      expect(
        commands.map((DisplayListCommand c) => c.toString()).toList(),
        _commands(bare).map((DisplayListCommand c) => c.toString()).toList(),
      );
    });

    test('at 1 the pixels are the pixels of no opacity at all', () async {
      final Framebuffer layered = await _render(
        RenderOpacity(
          opacity: 1.0,
          child: _Probe(preferred: const Size(16, 16), color: _content),
        ),
      );
      final Framebuffer bare = await _render(
        _Probe(preferred: const Size(16, 16), color: _content),
      );

      expect(pixelAt(layered, 8, 8), _contentPixel);
      expect(pixelAt(layered, 8, 8), pixelAt(bare, 8, 8));
    });

    test('at 0 draws nothing, keeps its space, and still takes the hit',
        () async {
      final _Probe child =
          _Probe(preferred: const Size(16, 16), color: _content);
      final RenderOpacity node = RenderOpacity(opacity: 0.0, child: child);

      final Framebuffer buffer = await _render(node);

      expect(pixelAt(buffer, 8, 8), _backgroundPixel, reason: 'nothing drawn');
      expect(node.size, const Size(16, 16), reason: 'the space is still taken');

      // The decision this class documents at length: a fade must not change
      // what is clickable partway through. `0.001` and `0.0` are the same
      // 8-bit alpha, so the alternative would make interactivity depend on
      // where a double happened to round.
      expect(node.hitTest(const Offset(8, 8)), same(child));
      expect(child.lastHit, const Offset(8, 8));
    });

    test('rejects an opacity outside 0..1 instead of clamping it', () {
      expect(() => RenderOpacity(opacity: 1.5), throwsArgumentError);
      expect(() => RenderOpacity(opacity: -0.1), throwsArgumentError);
      expect(() => RenderOpacity(opacity: double.nan), throwsArgumentError);
    });

    test('a changed opacity repaints without relaying out', () {
      final _Probe child = _Probe(preferred: const Size(16, 16));
      final RenderOpacity node = RenderOpacity(opacity: 1.0, child: child);
      node.layout(BoxConstraints.tight(const Size(16, 16)));
      node.clearNeedsPaintSubtree();

      node.opacity = 0.25;

      expect(node.needsPaint, isTrue);
      expect(node.needsLayout, isFalse, reason: 'alpha cannot move a box');
    });
  });

  group('RenderTransform', () {
    // An exact quarter turn, written out rather than built from
    // `Transform2D.rotation(pi / 2)`: `cos(pi / 2)` is 6.1e-17, not 0, and
    // every assertion below would need a tolerance to hide it. The factory is
    // checked against this matrix in its own test.
    const Transform2D quarterTurn = Transform2D(0, 1, -1, 0, 0, 0);

    test('carries a hit backwards through the inverse, to the exact point', () {
      final _Probe child = _Probe(preferred: const Size(100, 100));
      final RenderTransform node = RenderTransform(
        transform: quarterTurn,
        alignment: Alignment.center,
        child: child,
      );
      node.layout(BoxConstraints.tight(const Size(100, 100)));

      final RenderBox? hit = node.hitTest(const Offset(10, 20));

      expect(hit, same(child));
      // A quarter turn about (50, 50) maps the child's (20, 90) to the
      // parent's (10, 20); the hit test runs that backwards. Both directions
      // are asserted, because a transform applied in the wrong direction still
      // lands inside the box and would still "hit".
      expect(child.lastHit, const Offset(20, 90));
      expect(
        node.effectiveTransform.transformOffset(const Offset(20, 90)),
        const Offset(10, 20),
      );
    });

    test('Transform2D.rotation agrees with the exact matrix', () {
      final Transform2D built = Transform2D.rotation(math.pi / 2);
      expect(built.a, closeTo(0, 1e-15));
      expect(built.b, closeTo(1, 1e-15));
      expect(built.c, closeTo(-1, 1e-15));
      expect(built.d, closeTo(0, 1e-15));
    });

    test('a singular transform refuses the hit rather than returning NaN', () {
      final _Probe child = _Probe(preferred: const Size(20, 20));
      final RenderTransform node = RenderTransform(
        // Collapsed onto a vertical line: determinant exactly 0.
        transform: const Transform2D.scaling(0, 1),
        alignment: Alignment.center,
        child: child,
      );
      node.layout(BoxConstraints.tight(const Size(20, 20)));

      expect(node.effectiveTransform.determinant, 0);
      expect(node.effectiveTransform.invert(), isNull);
      expect(node.hitTest(const Offset(10, 10)), isNull);
      // The point of the test: the child was never offered a poisoned
      // coordinate. A naive inverse divides by zero and hands it (NaN, NaN),
      // which `size.contains` then rejects - the right answer, by accident,
      // after every coordinate downstream has already been spoiled.
      expect(child.hits, isEmpty);
    });

    test('a singular transform paints nothing', () async {
      final Framebuffer buffer = await _render(
        RenderTransform(
          transform: const Transform2D.scaling(1, 0),
          alignment: Alignment.center,
          child: _Probe(preferred: const Size(16, 16), color: _content),
        ),
      );

      expect(pixelAt(buffer, 8, 8), _backgroundPixel);
    });

    test('a rotation moves the pixels it says it moves', () async {
      // The child is 16x16 but inks only its top-left quadrant, so a quarter
      // turn about the centre is visible: the ink has to end up in the
      // top-right quadrant and nowhere else.
      final Framebuffer buffer = await _render(
        RenderTransform(
          transform: quarterTurn,
          alignment: Alignment.center,
          child: _Probe(
            preferred: const Size(16, 16),
            color: _content,
            fill: const Rect.fromLTRB(0, 0, 8, 8),
          ),
        ),
      );

      expect(pixelAt(buffer, 12, 4), _contentPixel, reason: 'top-right now');
      expect(pixelAt(buffer, 4, 4), _backgroundPixel, reason: 'left behind');
      expect(pixelAt(buffer, 4, 12), _backgroundPixel);
      expect(pixelAt(buffer, 12, 12), _backgroundPixel);
    });

    test('a translation folds into the paint offset, emitting no matrix',
        () async {
      final RenderTransform node = RenderTransform(
        transform: const Transform2D.translation(3, 4),
        child: _Probe(
          preferred: const Size(16, 16),
          color: _content,
          fill: const Rect.fromLTRB(0, 0, 4, 4),
        ),
      );

      expect(
        _commands(node).whereType<TransformCommand>(),
        isEmpty,
        reason: 'a translation is an offset; a save/restore pair and a matrix '
            'concatenation would buy nothing',
      );
      expect(_commands(node).whereType<SaveCommand>(), isEmpty);

      final Framebuffer buffer = await _render(node);
      expect(pixelAt(buffer, 5, 6), _contentPixel);
      expect(pixelAt(buffer, 1, 1), _backgroundPixel);
    });

    test('an identity transform emits nothing around the child', () {
      final RenderTransform node = RenderTransform(
        child: _Probe(preferred: const Size(16, 16), color: _content),
      );

      final List<DisplayListCommand> commands = _commands(node);

      expect(commands.whereType<SaveCommand>(), isEmpty);
      expect(commands.whereType<TransformCommand>(), isEmpty);
      expect(commands, hasLength(1));
    });

    test('a real rotation does emit save, transform, restore, in that order',
        () {
      final RenderTransform node = RenderTransform(
        transform: quarterTurn,
        alignment: Alignment.center,
        child: _Probe(preferred: const Size(16, 16), color: _content),
      );

      final List<DisplayListCommand> commands = _commands(node);

      expect(commands.first, isA<SaveCommand>());
      expect(commands[1], isA<TransformCommand>());
      expect(commands.last, isA<RestoreCommand>());
      // The matrix that goes out is the local one conjugated by the paint
      // offset - here zero, so it is the local one unchanged. A missing
      // conjugation only shows up at a non-zero offset, which the pixel test
      // above covers.
      final TransformCommand emitted = commands[1] as TransformCommand;
      final Transform2D effective = node.effectiveTransform;
      expect(emitted.a, effective.a);
      expect(emitted.b, effective.b);
      expect(emitted.c, effective.c);
      expect(emitted.d, effective.d);
      expect(emitted.tx, effective.tx);
      expect(emitted.ty, effective.ty);
    });

    test('transformHitTests: false leaves the pointer where layout put it', () {
      final _Probe child = _Probe(preferred: const Size(100, 100));
      final RenderTransform node = RenderTransform(
        transform: quarterTurn,
        alignment: Alignment.center,
        transformHitTests: false,
        child: child,
      );
      node.layout(BoxConstraints.tight(const Size(100, 100)));

      expect(node.hitTest(const Offset(10, 20)), same(child));
      expect(child.lastHit, const Offset(10, 20), reason: 'untransformed');
    });

    test('alignment moves the pivot, origin adds to it', () {
      final RenderTransform node = RenderTransform(
        transform: quarterTurn,
        alignment: Alignment.topLeft,
        child: _Probe(preferred: const Size(20, 20)),
      );
      node.layout(BoxConstraints.tight(const Size(20, 20)));

      // Top-left pivot: the transform is unconjugated.
      expect(node.effectiveTransform, quarterTurn);

      node.alignment = null;
      node.origin = const Offset(10, 10);
      // A pivot at (10, 10) sends the child's (10, 10) to itself.
      expect(
        node.effectiveTransform.transformOffset(const Offset(10, 10)),
        const Offset(10, 10),
      );
    });

    test('does not size to the transform, so siblings never move', () {
      final RenderTransform node = RenderTransform(
        transform: const Transform2D.scaling(4, 4),
        child: _Probe(preferred: const Size(10, 10)),
      );

      node.layout(BoxConstraints(maxWidth: 100, maxHeight: 100));

      expect(node.size, const Size(10, 10),
          reason: 'a paint-time transform is invisible to layout');
    });
  });

  group('RenderClipRect', () {
    test('cuts exactly at its own edge', () async {
      // The clip is 8x8 on a 16x16 surface and its child paints 16x16: without
      // the clip the overflow is visible, with it the boundary is the box.
      final Framebuffer clipped = await _render(
        RenderClipRect(
          child: _Probe(
            preferred: const Size(8, 8),
            color: _content,
            fill: const Rect.fromLTRB(0, 0, 16, 16),
          ),
        ),
        constraints: BoxConstraints.tight(const Size(8, 8)),
      );

      expect(pixelAt(clipped, 7, 7), _contentPixel, reason: 'last pixel in');
      expect(pixelAt(clipped, 8, 7), _backgroundPixel, reason: 'first out');
      expect(pixelAt(clipped, 7, 8), _backgroundPixel);
    });

    test('and without it the same child overflows, so the clip did that',
        () async {
      final Framebuffer unclipped = await _render(
        _Probe(
          preferred: const Size(8, 8),
          color: _content,
          fill: const Rect.fromLTRB(0, 0, 16, 16),
        ),
        constraints: BoxConstraints.tight(const Size(8, 8)),
      );

      expect(pixelAt(unclipped, 8, 7), _contentPixel);
      expect(pixelAt(unclipped, 15, 15), _contentPixel);
    });

    test('refuses a hit outside the clip, using the same rectangle', () {
      final _Probe child = _Probe(preferred: const Size(8, 8));
      final RenderClipRect node = RenderClipRect(child: child);
      node.layout(BoxConstraints(maxWidth: 16, maxHeight: 16));

      expect(node.hitTest(const Offset(7, 7)), same(child));
      expect(node.hitTest(const Offset(9, 7)), isNull,
          reason: 'clipped away and therefore not clickable');
    });

    test('emits a clip around its child and nothing when it has none', () {
      final List<DisplayListCommand> commands = _commands(
        RenderClipRect(
          child: _Probe(preferred: const Size(16, 16), color: _content),
        ),
      );

      expect(commands.first, isA<SaveCommand>());
      final ClipRectCommand clip = commands[1] as ClipRectCommand;
      expect((clip.left, clip.top, clip.right, clip.bottom),
          (0.0, 0.0, 16.0, 16.0));
      expect(commands.last, isA<RestoreCommand>());

      expect(_commands(RenderClipRect()), isEmpty);
    });
  });

  group('RenderClipRRect', () {
    test('rejects a hit in the corner and keeps one on the edge', () {
      final _Probe child = _Probe(preferred: const Size(20, 20));
      final RenderClipRRect node = RenderClipRRect(radius: 6, child: child);
      node.layout(BoxConstraints.tight(const Size(20, 20)));

      // Middle of the top edge: no corner quadrant applies, so the radius is
      // irrelevant there.
      expect(node.hitTest(const Offset(10, 0.5)), same(child));
      expect(node.hitTest(const Offset(0.5, 10)), same(child));
      // Deep in the top-left corner, well outside a radius-6 arc.
      expect(node.hitTest(const Offset(0.5, 0.5)), isNull);
      expect(node.hitTest(const Offset(19.5, 19.5)), isNull);
    });

    test('the corner boundary is the arc, to within a hundredth of a pixel',
        () {
      final RenderClipRRect node = RenderClipRRect(
        radius: 6,
        child: _Probe(preferred: const Size(20, 20)),
      );
      node.layout(BoxConstraints.tight(const Size(20, 20)));

      // The arc's centre is (6, 6). At 45 degrees it passes through
      // 6 - 6/sqrt(2) = 1.7574. Straddling it by a hundredth of a pixel:
      //   (1.76, 1.76) -> 4.24^2 * 2 = 35.96 <= 36, inside
      //   (1.75, 1.75) -> 4.25^2 * 2 = 36.13 >  36, outside
      expect(node.hitTest(const Offset(1.76, 1.76)), isNotNull);
      expect(node.hitTest(const Offset(1.75, 1.75)), isNull);
    });

    test('clamps an over-large radius to half the shorter side', () {
      final RenderClipRRect node = RenderClipRRect(
        radius: 500,
        child: _Probe(preferred: const Size(20, 10)),
      );
      node.layout(BoxConstraints.tight(const Size(20, 10)));

      expect(node.effectiveRadius, 5, reason: 'a stadium, not a crossed path');
      expect(node.hitTest(const Offset(10, 5)), isNotNull);
      expect(node.hitTest(const Offset(0.2, 0.2)), isNull);
    });

    test('rejects a negative or non-finite radius', () {
      expect(() => RenderClipRRect(radius: -1), throwsArgumentError);
      expect(
          () => RenderClipRRect(radius: double.infinity), throwsArgumentError);
    });

    test(
        'DECLARED ABSENT: the painted corner is still square, because no '
        'rasterizer implements opClipPath', () async {
      // A characterisation test, not an endorsement. `DisplayListPlayer` throws
      // on opClipPath and the three blend modes cannot express a mask, so this
      // node emits the rectangular clip rather than an opcode that crashes
      // every backend. The consequence is measured here so that it is on the
      // record and so that the day a mask stage lands this test fails and has
      // to be replaced by its opposite.
      final RenderClipRRect node = RenderClipRRect(
        radius: 8,
        child: _Probe(preferred: const Size(16, 16), color: _content),
      );

      final Framebuffer buffer = await _render(node);

      expect(
        pixelAt(buffer, 0, 0),
        _contentPixel,
        reason: 'the corner wedge is NOT clipped in paint today',
      );
      expect(
        _commands(node).whereType<ClipPathCommand>(),
        isEmpty,
        reason: 'emitting one would throw in the player',
      );

      // And the disagreement the class comment admits to, in one place: the
      // same point that paints is refused a pointer.
      node.layout(BoxConstraints.tight(const Size(16, 16)));
      expect(node.hitTest(const Offset(0.5, 0.5)), isNull);
    });
  });

  group('RenderDecoratedBox', () {
    test('fills, then borders inside its own box', () async {
      final Framebuffer buffer = await _render(
        RenderDecoratedBox(
          decoration: const BoxDecoration(
            color: Color(0xFF3366CC),
            border: BoxBorder(color: Color(0xFFCC3311), width: 2),
          ),
          child: _Probe(preferred: const Size(16, 16)),
        ),
      );

      // The border is inset by half its width, so a width of 2 occupies rows
      // 0 and 1 exactly - it does not straddle the edge and does not grow the
      // box by a pixel on each side.
      expect(pixelAt(buffer, 8, 0), (0xCC, 0x33, 0x11, 0xFF));
      expect(pixelAt(buffer, 8, 1), (0xCC, 0x33, 0x11, 0xFF));
      expect(pixelAt(buffer, 8, 3), (0x33, 0x66, 0xCC, 0xFF), reason: 'fill');
      expect(pixelAt(buffer, 8, 8), (0x33, 0x66, 0xCC, 0xFF));
      expect(pixelAt(buffer, 15, 8), (0xCC, 0x33, 0x11, 0xFF),
          reason: 'the far edge, still inside the box');
    });

    test('a radius really rounds, unlike the clip', () async {
      // Radius 8 on a 16x16 box is a circle. The corner pixel is outside it
      // and the centre is inside, which is the whole claim.
      final Framebuffer buffer = await _render(
        RenderDecoratedBox(
          decoration: const BoxDecoration(color: Color(_content), radius: 8),
          child: _Probe(preferred: const Size(16, 16)),
        ),
      );

      expect(pixelAt(buffer, 0, 0), _backgroundPixel,
          reason: 'outside the arc');
      expect(pixelAt(buffer, 8, 8), _contentPixel);
      // (8, 1) rather than (8, 0): the circle is tangent to y = 0 at exactly
      // one point, so the topmost row of pixels is partially covered and
      // antialiased. One row down every corner of the pixel is inside the disc.
      expect(pixelAt(buffer, 8, 1), _contentPixel, reason: 'top of the circle');
    });

    test('emits a rounded rectangle for the fill when there is a radius', () {
      final List<DisplayListCommand> commands = _commands(
        RenderDecoratedBox(
          decoration: const BoxDecoration(color: Color(_content), radius: 4),
          child: _Probe(preferred: const Size(16, 16)),
        ),
      );

      final DrawRRectCommand fill =
          commands.whereType<DrawRRectCommand>().single;
      expect(fill.radii, everyElement(4.0));
      expect((fill.left, fill.top, fill.right, fill.bottom),
          (0.0, 0.0, 16.0, 16.0));
    });

    test('the border radius shrinks with the inset, so it traces the fill', () {
      final List<DisplayListCommand> commands = _commands(
        RenderDecoratedBox(
          decoration: const BoxDecoration(
            color: Color(_content),
            radius: 4,
            border: BoxBorder(color: Color(0xFF000000), width: 2),
          ),
          child: _Probe(preferred: const Size(16, 16)),
        ),
      );

      final List<DrawRRectCommand> rounded =
          commands.whereType<DrawRRectCommand>().toList();
      expect(rounded, hasLength(2));
      expect(rounded[1].radii, everyElement(3.0),
          reason: 'radius 4 minus the 1px inset');
      expect(
        (rounded[1].left, rounded[1].top, rounded[1].right, rounded[1].bottom),
        (1.0, 1.0, 15.0, 15.0),
      );
    });

    test('an empty decoration emits nothing and takes no pointer', () {
      final _Probe child = _Probe(preferred: const Size(16, 16));
      final RenderDecoratedBox node = RenderDecoratedBox(child: child);
      node.layout(BoxConstraints.tight(const Size(16, 16)));

      expect(_paint(node), isEmpty);
      expect(node.hitTestSelf(Offset.zero), isFalse,
          reason: 'DecoratedBox() must not be a pointer trap');
    });

    test('a fully transparent fill still takes the pointer', () {
      // The same rule RenderColoredBox states: a surface that is drawn is a
      // surface, and going inert as alpha reaches zero would make a fade
      // change behaviour halfway through.
      final RenderDecoratedBox node = RenderDecoratedBox(
        decoration: const BoxDecoration(color: Color(0x00000000)),
        child: _Probe(preferred: const Size(16, 16)),
      );
      node.layout(BoxConstraints.tight(const Size(16, 16)));

      expect(node.hitTestSelf(Offset.zero), isTrue);
    });
  });

  group('RenderCenter', () {
    test('fills a bounded box and puts the child in the middle', () {
      final _Probe child = _Probe(preferred: const Size(10, 6));
      final RenderCenter node = RenderCenter(child: child);

      node.layout(BoxConstraints.tight(const Size(30, 20)));

      expect(node.size, const Size(30, 20));
      expect(child.size, const Size(10, 6));
      expect(child.offsetFromParent, const Offset(10, 7));
    });

    test('shrink-wraps an unbounded axis', () {
      final _Probe child = _Probe(preferred: const Size(10, 6));
      final RenderCenter node = RenderCenter(child: child);

      node.layout(BoxConstraints(maxHeight: 20));

      expect(node.size, const Size(10, 20),
          reason: 'no leftover width to centre in, so no width to take');
      expect(child.offsetFromParent, const Offset(0, 7));
    });

    test('carries a hit through the displacement it applied', () {
      final _Probe child = _Probe(preferred: const Size(10, 6));
      final RenderCenter node = RenderCenter(child: child);
      node.layout(BoxConstraints.tight(const Size(30, 20)));

      expect(node.hitTest(const Offset(15, 10)), same(child));
      expect(child.lastHit, const Offset(5, 3), reason: 'the child centre');
      expect(node.hitTest(const Offset(2, 2)), isNull,
          reason: 'inside the box but outside the child');
    });
  });

  group('IgnorePointer against a sibling behind it', () {
    ({RenderStack stack, _Probe back, _Probe front, RenderBox wrapper}) build(
      RenderBox Function(RenderBox child) wrap,
    ) {
      final _Probe back = _Probe(preferred: const Size(20, 20));
      final _Probe front = _Probe(preferred: const Size(20, 20));
      final RenderBox wrapper = wrap(front);
      final RenderStack stack = RenderStack(fit: StackFit.expand)
        ..add(back)
        ..add(wrapper);
      stack.layout(BoxConstraints.tight(const Size(20, 20)));
      return (stack: stack, back: back, front: front, wrapper: wrapper);
    }

    test('lets the event through to whatever is underneath', () {
      final result =
          build((RenderBox child) => RenderIgnorePointer(child: child));

      final RenderBox? hit = result.stack.hitTest(const Offset(5, 5));

      expect(hit, same(result.back),
          reason: 'ignoring means the subtree is not there for a pointer');
      expect(result.front.hits, isEmpty);
      expect(result.back.lastHit, const Offset(5, 5));
    });

    test('and passes it to its own child when it is not ignoring', () {
      final result = build(
        (RenderBox child) => RenderIgnorePointer(ignoring: false, child: child),
      );

      expect(result.stack.hitTest(const Offset(5, 5)), same(result.front));
      expect(result.back.hits, isEmpty);
    });

    test('ignoring is a pointer decision only: it still paints', () async {
      final Framebuffer buffer = await _render(
        RenderIgnorePointer(
          child: _Probe(preferred: const Size(16, 16), color: _content),
        ),
      );

      expect(pixelAt(buffer, 8, 8), _contentPixel);
    });
  });

  group('AbsorbPointer against a sibling behind it', () {
    ({RenderStack stack, _Probe back, _Probe front, RenderBox wrapper}) build({
      required bool absorbing,
    }) {
      final _Probe back = _Probe(preferred: const Size(20, 20));
      final _Probe front = _Probe(preferred: const Size(20, 20));
      final RenderAbsorbPointer wrapper =
          RenderAbsorbPointer(absorbing: absorbing, child: front);
      final RenderStack stack = RenderStack(fit: StackFit.expand)
        ..add(back)
        ..add(wrapper);
      stack.layout(BoxConstraints.tight(const Size(20, 20)));
      return (stack: stack, back: back, front: front, wrapper: wrapper);
    }

    test('eats the event: neither its child nor the sibling behind sees it',
        () {
      final result = build(absorbing: true);

      final RenderBox? hit = result.stack.hitTest(const Offset(5, 5));

      expect(hit, same(result.wrapper), reason: 'the absorber is the target');
      expect(result.front.hits, isEmpty);
      expect(
        result.back.hits,
        isEmpty,
        reason: 'this is the whole difference from IgnorePointer, and a test '
            'that only checked the child would not see it',
      );
    });

    test('and forwards to its child when it is not absorbing', () {
      final result = build(absorbing: false);

      expect(result.stack.hitTest(const Offset(5, 5)), same(result.front));
      expect(result.back.hits, isEmpty);
    });

    test('the two differ only in who is left holding the event', () {
      final ignored =
          RenderIgnorePointer(child: _Probe(preferred: const Size(20, 20)));
      final absorbed =
          RenderAbsorbPointer(child: _Probe(preferred: const Size(20, 20)));
      ignored.layout(BoxConstraints.tight(const Size(20, 20)));
      absorbed.layout(BoxConstraints.tight(const Size(20, 20)));

      expect(ignored.hitTest(const Offset(5, 5)), isNull);
      expect(absorbed.hitTest(const Offset(5, 5)), same(absorbed));
    });
  });

  group('RenderRepaintBoundary', () {
    test('is transparent to layout, paint and hit testing', () async {
      final Framebuffer buffer = await _render(
        RenderRepaintBoundary(
          child: _Probe(preferred: const Size(16, 16), color: _content),
        ),
      );

      expect(pixelAt(buffer, 8, 8), _contentPixel);
      expect(
        _commands(
          RenderRepaintBoundary(
            child: _Probe(preferred: const Size(16, 16), color: _content),
          ),
        ),
        hasLength(1),
        reason: 'a marker emits nothing of its own',
      );
    });

    test('NO CACHE BEHIND IT: it repaints on every frame, dirty or not', () {
      final RenderRepaintBoundary node = RenderRepaintBoundary(
        child: _Probe(preferred: const Size(16, 16), color: _content),
      );
      node.layout(BoxConstraints.tight(const Size(16, 16)));

      for (int frame = 0; frame < 3; frame++) {
        final DisplayList list = DisplayList();
        node.paint(list, Offset.zero);
        node.clearNeedsPaintSubtree();
      }

      // Three, not one. `PipelineOwner.flushPaint` walks the whole tree into a
      // fresh display list every frame and this node does not interrupt it, so
      // wrapping a subtree in a repaint boundary today buys exactly nothing.
      // A retained-layer implementation is precisely the change that makes
      // this number stop at 1, which is why it is asserted before the feature
      // exists.
      expect(node.paintCount, 3);
      expect(node.isRepaintBoundary, isTrue);
    });
  });

  group('RenderVisibility', () {
    test('visible is an ordinary proxy', () async {
      final RenderVisibility node = RenderVisibility(
        child: _Probe(preferred: const Size(16, 16), color: _content),
      );

      final Framebuffer buffer = await _render(node);

      expect(node.size, const Size(16, 16));
      expect(pixelAt(buffer, 8, 8), _contentPixel);
    });

    test('hidden with maintainSize keeps the space and drops paint and hits',
        () async {
      final _Probe child =
          _Probe(preferred: const Size(10, 6), color: _content);
      final RenderVisibility node =
          RenderVisibility(visible: false, child: child);

      node.layout(BoxConstraints(maxWidth: 16, maxHeight: 16));

      expect(node.size, const Size(10, 6), reason: 'the row does not reflow');
      expect(_paint(node), isEmpty);
      expect(node.hitTest(const Offset(5, 3)), isNull);
      expect(child.hits, isEmpty);
    });

    test('hidden without maintainSize gives the space back', () {
      final _Probe child = _Probe(preferred: const Size(10, 6));
      final RenderVisibility node = RenderVisibility(
        visible: false,
        maintainSize: false,
        child: child,
      );

      node.layout(BoxConstraints(maxWidth: 16, maxHeight: 16));

      expect(node.size, Size.zero);
      // Still laid out, deliberately: skipping it leaves a child with no size
      // at all, and a tight zero constraint makes a flex report an overflow
      // nobody asked for.
      expect(child.hasSize, isTrue);
      expect(child.size, const Size(10, 6));
      expect(node.hitTest(Offset.zero), isNull);
    });

    test('showing it again restores both the space and the paint', () async {
      final RenderVisibility node = RenderVisibility(
        visible: false,
        maintainSize: false,
        child: _Probe(preferred: const Size(16, 16), color: _content),
      );
      node.layout(BoxConstraints.tight(const Size(16, 16)));
      expect(_paint(node), isEmpty);

      node.visible = true;

      expect(node.needsLayout, isTrue,
          reason: 'its own size just changed, so an ancestor must hear');
      final Framebuffer buffer = await _render(node);
      expect(node.size, const Size(16, 16));
      expect(pixelAt(buffer, 8, 8), _contentPixel);
    });

    test('with the size maintained, toggling is a repaint and not a relayout',
        () {
      final RenderVisibility node = RenderVisibility(
        child: _Probe(preferred: const Size(16, 16)),
      );
      node.layout(BoxConstraints.tight(const Size(16, 16)));
      node.clearNeedsPaintSubtree();

      node.visible = false;

      expect(node.needsPaint, isTrue);
      expect(node.needsLayout, isFalse);
    });
  });
}
