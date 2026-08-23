import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/vector/stencil_cover_draw_plan.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

const StencilCoverCapabilities _full = StencilCoverCapabilities(
  stencilBits: 8,
  sampleCount: 4,
  separateFrontBackOperations: true,
  wrapOperations: true,
  invertOperation: true,
  scissoredClear: true,
);

void main() {
  test('non-zero accumulates signed winding and even-odd toggles parity', () {
    final Path sameDirection = (PathBuilder()
          ..addRect(const Rect.fromLTRB(0, 0, 20, 20))
          ..addRect(const Rect.fromLTRB(5, 5, 15, 15)))
        .build();
    final StencilCoverDrawPlan nonZero = StencilCoverDrawPlan()
      ..append(
        sameDirection,
        clip: const Rect.fromLTRB(-10, -10, 30, 30),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      );
    final StencilCoverDrawPlan evenOdd = StencilCoverDrawPlan()
      ..append(
        sameDirection,
        clip: const Rect.fromLTRB(-10, -10, 30, 30),
        materialIndex: 0,
        fillRule: FillRule.evenOdd,
        capabilities: _full,
      );

    // Deliberately off the fans' shared diagonal: hardware's top-left rule
    // assigns an edge sample to one triangle, while this tiny simulator uses
    // inclusive half-plane tests and would count the shared edge twice.
    expect(_stencilAt(nonZero, 0, 9, 10), 2);
    expect(_coveredAt(nonZero, 0, 9, 10), isTrue);
    expect(_stencilAt(evenOdd, 0, 9, 10), 0);
    expect(_coveredAt(evenOdd, 0, 9, 10), isFalse);
    expect(_coveredAt(nonZero, 0, 2, 3), isTrue);
    expect(_coveredAt(evenOdd, 0, 2, 3), isTrue);
  });

  test('opposite contour winding cancels for both rules', () {
    final Path hole = (PathBuilder()
          ..addRect(const Rect.fromLTRB(0, 0, 20, 20))
          ..moveTo(5, 5)
          ..lineTo(5, 15)
          ..lineTo(15, 15)
          ..lineTo(15, 5)
          ..close())
        .build();
    for (final FillRule rule in FillRule.values) {
      final StencilCoverDrawPlan plan = StencilCoverDrawPlan()
        ..append(
          hole,
          clip: const Rect.fromLTRB(0, 0, 20, 20),
          materialIndex: 0,
          fillRule: rule,
          capabilities: _full,
        );
      expect(_stencilAt(plan, 0, 9, 10), 0, reason: rule.name);
      expect(_coveredAt(plan, 0, 9, 10), isFalse, reason: rule.name);
    }
  });

  test('commands and states explicitly describe clear accumulate cover', () {
    final StencilCoverDrawPlan plan = StencilCoverDrawPlan()
      ..append(
        Path.rect(const Rect.fromLTRB(2, 3, 12, 13)),
        clip: const Rect.fromLTRB(4, 1, 20, 9),
        materialIndex: 7,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      );

    expect(plan.drawCoverBounds(0), const Rect.fromLTRB(4, 3, 12, 9));
    expect(plan.drawMaterial(0), 7);
    expect(plan.commandCount, 3);
    expect(
      <StencilCoverCommandKind>[
        for (var i = 0; i < 3; i++) plan.commandKind(i),
      ],
      <StencilCoverCommandKind>[
        StencilCoverCommandKind.clear,
        StencilCoverCommandKind.accumulate,
        StencilCoverCommandKind.cover,
      ],
    );
    expect(plan.commandState(0).clearValue, 0);
    expect(plan.commandState(1).colorWrites, isFalse);
    expect(
      plan.commandState(1).frontPass,
      StencilOperation.incrementWrap,
    );
    expect(
      plan.commandState(1).backPass,
      StencilOperation.decrementWrap,
    );
    expect(plan.commandState(2).compare, StencilCompare.notEqualZero);
    expect(plan.commandState(2).frontPass, StencilOperation.zero);
  });

  test('degenerate and move-only contours do not enlarge cover geometry', () {
    final Path path = (PathBuilder()
          ..moveTo(-1000, -1000)
          ..moveTo(2, 3)
          ..lineTo(12, 3)
          ..lineTo(2, 13)
          ..close()
          ..moveTo(1000, 1000)
          ..lineTo(1001, 1001)
          ..lineTo(1002, 1002)
          ..close())
        .build();
    final StencilCoverDrawPlan plan = StencilCoverDrawPlan()
      ..append(
        path,
        clip: const Rect.fromLTRB(-2000, -2000, 2000, 2000),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      );

    expect(plan.triangleCount, 1);
    expect(plan.drawCoverBounds(0), const Rect.fromLTRB(2, 3, 12, 13));
  });

  test('draw order and three-pass boundaries are retained', () {
    final StencilCoverDrawPlan plan = StencilCoverDrawPlan()
      ..append(
        Path.rect(const Rect.fromLTRB(0, 0, 4, 4)),
        clip: const Rect.fromLTRB(0, 0, 20, 20),
        materialIndex: 9,
        fillRule: FillRule.evenOdd,
        capabilities: _full,
      )
      ..append(
        Path.rect(const Rect.fromLTRB(2, 2, 8, 8)),
        clip: const Rect.fromLTRB(0, 0, 20, 20),
        materialIndex: 3,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      );

    expect(plan.drawMaterial(0), 9);
    expect(plan.drawMaterial(1), 3);
    expect(
      <int>[for (var i = 0; i < plan.commandCount; i++) plan.commandDraw(i)],
      <int>[0, 0, 0, 1, 1, 1],
    );
    final StencilCoverPassState parity = plan.commandState(1);
    expect(parity.writeMask, 1);
    expect(parity.frontPass, StencilOperation.invertLeastSignificantBit);
    expect(plan.commandState(2).compare, StencilCompare.leastSignificantBitSet);
  });

  test('reset clears lengths and reuses high-water arenas', () {
    final Path path =
        (PathBuilder()..addOval(const Rect.fromLTRB(0, 0, 40, 40))).build();
    final StencilCoverDrawPlan plan = StencilCoverDrawPlan(
      initialTriangles: 1,
      initialDraws: 1,
    )..append(
        path,
        clip: const Rect.fromLTRB(0, 0, 40, 40),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      );
    final vertexArena = plan.vertexStorage;
    final drawArena = plan.drawStorage;
    final commandArena = plan.commandStorage;
    final int growths = plan.arenaGrowths;
    final int retained = plan.metrics.retainedCapacityBytes;

    plan
      ..reset()
      ..append(
        path,
        clip: const Rect.fromLTRB(0, 0, 40, 40),
        materialIndex: 1,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      );
    expect(plan.vertexStorage, same(vertexArena));
    expect(plan.drawStorage, same(drawArena));
    expect(plan.commandStorage, same(commandArena));
    expect(plan.arenaGrowths, growths);
    expect(plan.metrics.retainedCapacityBytes, retained);
  });

  test('hardware requirements reject unsupported targets by reason', () {
    Path path() => Path.rect(const Rect.fromLTRB(0, 0, 4, 4));
    StencilCoverDrawPlan plan() => StencilCoverDrawPlan();
    void append(StencilCoverDrawPlan target, FillRule rule,
            StencilCoverCapabilities capabilities) =>
        target.append(
          path(),
          clip: const Rect.fromLTRB(0, 0, 4, 4),
          materialIndex: 0,
          fillRule: rule,
          capabilities: capabilities,
        );

    expect(
      () => append(
        plan(),
        FillRule.nonZero,
        const StencilCoverCapabilities(
          stencilBits: 4,
          sampleCount: 4,
          separateFrontBackOperations: true,
          wrapOperations: true,
          invertOperation: true,
          scissoredClear: true,
        ),
      ),
      throwsA(isA<UnsupportedError>().having(
        (e) => e.message,
        'message',
        contains('8 stencil bits'),
      )),
    );
    expect(
      () => append(
        plan(),
        FillRule.evenOdd,
        const StencilCoverCapabilities(
          stencilBits: 8,
          sampleCount: 4,
          separateFrontBackOperations: true,
          wrapOperations: true,
          invertOperation: false,
          scissoredClear: true,
        ),
      ),
      throwsA(isA<UnsupportedError>().having(
        (e) => e.message,
        'message',
        contains('invert'),
      )),
    );
    expect(
      () => append(
        plan(),
        FillRule.nonZero,
        const StencilCoverCapabilities(
          stencilBits: 8,
          sampleCount: 1,
          separateFrontBackOperations: true,
          wrapOperations: true,
          invertOperation: true,
          scissoredClear: true,
        ),
      ),
      throwsA(isA<UnsupportedError>().having(
        (e) => e.message,
        'message',
        contains('4 samples'),
      )),
    );
  });

  test('geometry limits reject transactionally without retaining triangles',
      () {
    final StencilCoverDrawPlan plan =
        StencilCoverDrawPlan(maxTrianglesPerDraw: 1);

    expect(
      () => plan.append(
        Path.rect(const Rect.fromLTRB(0, 0, 10, 10)),
        clip: const Rect.fromLTRB(0, 0, 10, 10),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      ),
      throwsA(
        isA<StencilCoverPlanError>().having(
          (error) => error.rejection,
          'rejection',
          StencilCoverRejection.triangleLimitExceeded,
        ),
      ),
    );
    expect(plan.vertexCount, 0);
    expect(plan.drawCount, 0);
    expect(plan.commandCount, 0);
  });

  test('non-finite flattened geometry is rejected by name', () {
    final Path path = (PathBuilder()
          ..moveTo(0, 0)
          ..lineTo(double.infinity, 0)
          ..lineTo(0, 10)
          ..close())
        .build();
    final StencilCoverDrawPlan plan = StencilCoverDrawPlan();

    expect(
      () => plan.append(
        path,
        clip: const Rect.fromLTRB(0, 0, 10, 10),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      ),
      throwsA(
        isA<StencilCoverPlanError>().having(
          (error) => error.rejection,
          'rejection',
          StencilCoverRejection.nonFiniteGeometry,
        ),
      ),
    );
    expect(plan.vertexCount, 0);
  });
}

int _stencilAt(
  StencilCoverDrawPlan plan,
  int draw,
  double x,
  double y,
) {
  var value = 0;
  final int first = plan.drawFirstVertex(draw);
  final int end = first + plan.drawVertexCount(draw);
  for (var vertex = first; vertex < end; vertex += 3) {
    final double ax = plan.vertexX(vertex);
    final double ay = plan.vertexY(vertex);
    final double bx = plan.vertexX(vertex + 1);
    final double by = plan.vertexY(vertex + 1);
    final double cx = plan.vertexX(vertex + 2);
    final double cy = plan.vertexY(vertex + 2);
    if (!_insideTriangle(x, y, ax, ay, bx, by, cx, cy)) continue;
    if (plan.drawFillRule(draw) == FillRule.evenOdd) {
      value ^= 1;
    } else {
      final double signedArea = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
      value += signedArea > 0 ? 1 : -1;
    }
  }
  return value;
}

bool _coveredAt(
  StencilCoverDrawPlan plan,
  int draw,
  double x,
  double y,
) {
  final int stencil = _stencilAt(plan, draw, x, y);
  return plan.drawFillRule(draw) == FillRule.nonZero
      ? stencil != 0
      : (stencil & 1) != 0;
}

bool _insideTriangle(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
) {
  final double ab = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
  final double bc = (cx - bx) * (py - by) - (cy - by) * (px - bx);
  final double ca = (ax - cx) * (py - cy) - (ay - cy) * (px - cx);
  final bool negative = ab < 0 || bc < 0 || ca < 0;
  final bool positive = ab > 0 || bc > 0 || ca > 0;
  return !(negative && positive);
}
