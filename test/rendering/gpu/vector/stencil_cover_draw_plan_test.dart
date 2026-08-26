import 'dart:typed_data';

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
    // Both fans sit inside the clip, so neither leaves winding its own cover
    // fails to zero and the second draw joins the first draw's clear group.
    expect(
      <StencilCoverCommandKind>[
        for (var i = 0; i < plan.commandCount; i++) plan.commandKind(i),
      ],
      <StencilCoverCommandKind>[
        StencilCoverCommandKind.clear,
        StencilCoverCommandKind.accumulate,
        StencilCoverCommandKind.cover,
        StencilCoverCommandKind.accumulate,
        StencilCoverCommandKind.cover,
      ],
    );
    expect(
      <int>[for (var i = 0; i < plan.commandCount; i++) plan.commandDraw(i)],
      <int>[0, 0, 0, 1, 1],
    );
    expect(plan.clearGroupCount, 1);
    expect(plan.clearGroupDrawCount(0), 2);
    // The union of both covers, and a mask wide enough for both rules: the
    // even-odd draw writes bit zero, the non-zero draw all eight.
    expect(plan.commandBounds(0), const Rect.fromLTRB(0, 0, 8, 8));
    expect(plan.commandState(0).writeMask, 0xFF);
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

  test('a trimmed fan still shares the clear, because it cannot overspill', () {
    // Draw 0 is trimmed by the clip. Its accumulation is scissored to its own
    // cover, so the winding it would have written outside never reaches the
    // buffer and the group has nothing to protect the next draw from.
    final StencilCoverDrawPlan plan = StencilCoverDrawPlan()
      ..append(
        Path.rect(const Rect.fromLTRB(0, 0, 20, 20)),
        clip: const Rect.fromLTRB(0, 0, 10, 20),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      )
      ..append(
        Path.rect(const Rect.fromLTRB(12, 0, 18, 6)),
        clip: const Rect.fromLTRB(0, 0, 40, 40),
        materialIndex: 0,
        fillRule: FillRule.evenOdd,
        capabilities: _full,
      )
      ..append(
        Path.rect(const Rect.fromLTRB(22, 0, 28, 6)),
        clip: const Rect.fromLTRB(0, 0, 40, 40),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      );

    expect(plan.clearGroupCount, 1);
    expect(plan.clearGroupDrawCount(0), 3);
    expect(plan.metrics.clearCommandCount, 1);
    expect(plan.metrics.coalescedClearCount, 2);
    expect(plan.commandBounds(0), const Rect.fromLTRB(0, 0, 28, 20));
    expect(plan.commandState(0).writeMask, 0xFF);
    // The accumulation's own rectangle, which is what an executor scissors to.
    expect(plan.commandBounds(1), plan.drawCoverBounds(0));

    final StencilCoverDrawPlan perDraw =
        StencilCoverDrawPlan(coalesceClears: false)
          ..append(
            Path.rect(const Rect.fromLTRB(0, 0, 20, 20)),
            clip: const Rect.fromLTRB(0, 0, 10, 20),
            materialIndex: 0,
            fillRule: FillRule.nonZero,
            capabilities: _full,
          );
    expect(perDraw.clearGroupCount, 1);
    expect(perDraw.metrics.coalescedClearCount, 0);
  });

  test('coalescing changes no pixel of a multi-path scene', () {
    // The identity proof for the optimisation. Two plans, same paths, one with
    // grouped clears and one with the clear-per-draw contract that preceded
    // it; the stencil and colour buffers a command replay produces must match
    // exactly, not approximately.
    StencilCoverDrawPlan build({required bool coalesce}) {
      final StencilCoverDrawPlan plan =
          StencilCoverDrawPlan(coalesceClears: coalesce);
      for (var i = 0; i < 6; i++) {
        final double x = (i % 3) * 14.0;
        final double y = (i ~/ 3) * 14.0;
        plan.append(
          i.isEven
              ? Path.rect(Rect.fromLTRB(x + 1, y + 1, x + 12, y + 12))
              : (PathBuilder()
                    ..addRect(Rect.fromLTRB(x + 1, y + 1, x + 12, y + 12))
                    ..addRect(Rect.fromLTRB(x + 4, y + 4, x + 9, y + 9)))
                  .build(),
          // The middle column is clipped, so one draw in each row leaves
          // residue and the grouping has to notice.
          clip: i % 3 == 1
              ? Rect.fromLTRB(x + 3, y, x + 10, y + 40)
              : const Rect.fromLTRB(0, 0, 44, 40),
          materialIndex: i % 2,
          fillRule: i.isEven ? FillRule.nonZero : FillRule.evenOdd,
          capabilities: _full,
        );
      }
      return plan;
    }

    final StencilCoverDrawPlan grouped = build(coalesce: true);
    final StencilCoverDrawPlan perDraw = build(coalesce: false);

    expect(perDraw.clearGroupCount, perDraw.drawCount);
    expect(grouped.clearGroupCount, lessThan(perDraw.clearGroupCount));
    expect(grouped.commandCount, lessThan(perDraw.commandCount));

    final _Surface a = _replay(grouped, 44, 40);
    final _Surface b = _replay(perDraw, 44, 40);
    expect(a.color, orderedEquals(b.color));
    // The stencil too: with every command scissored to its own rectangle, a
    // grouped plan does not merely paint the same pixels, it leaves the same
    // buffer behind.
    expect(a.stencil, orderedEquals(b.stencil));
    // A scene that painted nothing would satisfy the equalities above.
    expect(a.color.any((int value) => value != 0), isTrue);
  });

  test('cover quads are built once and match their draw bounds', () {
    final StencilCoverDrawPlan plan = StencilCoverDrawPlan()
      ..append(
        Path.rect(const Rect.fromLTRB(2, 3, 12, 13)),
        clip: const Rect.fromLTRB(0, 0, 40, 40),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      )
      ..append(
        Path.rect(const Rect.fromLTRB(20, 21, 30, 31)),
        clip: const Rect.fromLTRB(0, 0, 40, 40),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
        capabilities: _full,
      );

    expect(plan.coverVertexCount, 12);
    for (var draw = 0; draw < plan.drawCount; draw++) {
      final Rect bounds = plan.drawCoverBounds(draw);
      final int first = plan.drawCoverFirstVertex(draw);
      expect(first, draw * 6);
      final List<double> quad = <double>[
        for (var i = 0; i < 12; i++) plan.coverVertexStorage[first * 2 + i],
      ];
      expect(quad.sublist(0, 2), <double>[bounds.left, bounds.top]);
      expect(quad.sublist(10, 12), <double>[bounds.right, bounds.bottom]);
    }
  });
}

/// Stencil and colour of a command replay, as bytes that can be compared.
final class _Surface {
  _Surface(int pixels)
      : stencil = Uint8List(pixels),
        color = Uint8List(pixels);

  final Uint8List stencil;
  final Uint8List color;
}

/// Executes a plan's commands the way the fixed-function pipeline would.
///
/// Deliberately literal: scissor rectangles round outward exactly as
/// `StencilCoverGlScissor` does, stencil operations wrap in eight bits, and a
/// cover writes `material + 1` so an untouched pixel and a filled one stay
/// distinguishable.
_Surface _replay(StencilCoverDrawPlan plan, int width, int height) {
  final _Surface surface = _Surface(width * height);
  for (var command = 0; command < plan.commandCount; command++) {
    final int draw = plan.commandDraw(command);
    final Rect bounds = plan.commandBounds(command);
    final StencilCoverPassState state = plan.commandState(command);
    final int x0 = bounds.left.floor().clamp(0, width);
    final int x1 = bounds.right.ceil().clamp(0, width);
    final int y0 = bounds.top.floor().clamp(0, height);
    final int y1 = bounds.bottom.ceil().clamp(0, height);
    switch (plan.commandKind(command)) {
      case StencilCoverCommandKind.clear:
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            surface.stencil[y * width + x] &= ~state.writeMask & 0xFF;
          }
        }
      case StencilCoverCommandKind.accumulate:
        // Scissored like every other command - the invariant the plan's
        // grouping is proved against.
        final int first = plan.drawFirstVertex(draw);
        final int end = first + plan.drawVertexCount(draw);
        for (var vertex = first; vertex < end; vertex += 3) {
          final double ax = plan.vertexX(vertex);
          final double ay = plan.vertexY(vertex);
          final double bx = plan.vertexX(vertex + 1);
          final double by = plan.vertexY(vertex + 1);
          final double cx = plan.vertexX(vertex + 2);
          final double cy = plan.vertexY(vertex + 2);
          final double area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
          final StencilOperation operation =
              area > 0 ? state.frontPass : state.backPass;
          for (var y = y0; y < y1; y++) {
            for (var x = x0; x < x1; x++) {
              if (!_insideTriangle(x + 0.5, y + 0.5, ax, ay, bx, by, cx, cy)) {
                continue;
              }
              final int index = y * width + x;
              final int before = surface.stencil[index];
              final int after = switch (operation) {
                StencilOperation.keep => before,
                StencilOperation.zero => 0,
                StencilOperation.incrementWrap => (before + 1) & 0xFF,
                StencilOperation.decrementWrap => (before - 1) & 0xFF,
                StencilOperation.invertLeastSignificantBit => before ^ 0xFF,
              };
              surface.stencil[index] = (before & ~state.writeMask & 0xFF) |
                  (after & state.writeMask);
            }
          }
        }
      case StencilCoverCommandKind.cover:
        final Rect quad = plan.drawCoverBounds(draw);
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            if (x + 0.5 < quad.left ||
                x + 0.5 > quad.right ||
                y + 0.5 < quad.top ||
                y + 0.5 > quad.bottom) {
              continue;
            }
            final int index = y * width + x;
            final int masked = surface.stencil[index] & state.compareMask;
            final bool passes = switch (state.compare) {
              StencilCompare.always => true,
              StencilCompare.notEqualZero => masked != 0,
              StencilCompare.leastSignificantBitSet => masked == 1,
            };
            if (!passes) continue;
            surface.color[index] = plan.drawMaterial(draw) + 1;
            surface.stencil[index] &= ~state.writeMask & 0xFF;
          }
        }
    }
  }
  return surface;
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
