/// Backend-neutral stencil-then-cover geometry and pass contract.
///
/// Each path becomes three ordered commands:
///
///  1. clear stencil to zero inside the clipped cover bounds;
///  2. rasterise signed contour fans with colour writes disabled;
///  3. cover the bounds where stencil passes, writing colour and zeroing the
///     stencil samples that passed.
///
/// Non-zero increments front-facing triangles and decrements back-facing
/// triangles with wrapping arithmetic, then covers values unequal to zero.
/// Even-odd inverts stencil bit zero for every triangle and covers where that
/// bit is set. In y-down device space a positive signed triangle is clockwise;
/// the usual y-flipping projection turns it counter-clockwise in NDC, so it is
/// the front face named by this contract.
///
/// Curves are flattened on the CPU, but no polygon tessellation is required:
/// a triangle fan is a signed decomposition, so concavity and intersections
/// cancel through the stencil operations instead of through CPU topology.
library;

import 'dart:typed_data';

import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../path/fill_rule.dart';

const int kStencilCoverVertexStride = 2;
const int kStencilCoverDrawStride = 6;
const int kStencilCoverCommandStride = 2;
const int kStencilCoverBoundsStride = 4;

enum StencilCoverCommandKind { clear, accumulate, cover }

enum StencilCompare { always, notEqualZero, leastSignificantBitSet }

enum StencilOperation {
  keep,
  zero,
  incrementWrap,
  decrementWrap,
  invertLeastSignificantBit,
}

enum StencilCoverRejection { nonFiniteGeometry, triangleLimitExceeded }

final class StencilCoverPlanError extends StateError {
  StencilCoverPlanError(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final StencilCoverRejection rejection;
}

/// Fixed-function state required by one command.
final class StencilCoverPassState {
  const StencilCoverPassState({
    required this.colorWrites,
    required this.compare,
    required this.compareMask,
    required this.writeMask,
    required this.frontPass,
    required this.backPass,
    this.clearValue,
  });

  final bool colorWrites;
  final StencilCompare compare;
  final int compareMask;
  final int writeMask;
  final StencilOperation frontPass;
  final StencilOperation backPass;
  final int? clearValue;
}

/// Stencil features exposed by a backend render target.
final class StencilCoverCapabilities {
  const StencilCoverCapabilities({
    required this.stencilBits,
    required this.sampleCount,
    required this.separateFrontBackOperations,
    required this.wrapOperations,
    required this.invertOperation,
    required this.scissoredClear,
  });

  final int stencilBits;
  final int sampleCount;
  final bool separateFrontBackOperations;
  final bool wrapOperations;
  final bool invertOperation;
  final bool scissoredClear;

  String? unsupportedReason(StencilCoverRequirements requirements) {
    if (stencilBits < requirements.minimumStencilBits) {
      return 'needs ${requirements.minimumStencilBits} stencil bits, has '
          '$stencilBits';
    }
    if (requirements.minimumSampleCount > sampleCount) {
      return 'antialiasing needs ${requirements.minimumSampleCount} samples, '
          'has $sampleCount';
    }
    if (!scissoredClear) return 'needs stencil clear restricted to bounds';
    if (requirements.requiresSeparateFrontBack &&
        !separateFrontBackOperations) {
      return 'non-zero needs separate front/back stencil operations';
    }
    if (requirements.requiresWrap && !wrapOperations) {
      return 'non-zero needs increment/decrement wrap operations';
    }
    if (requirements.requiresInvert && !invertOperation) {
      return 'even-odd needs stencil invert';
    }
    return null;
  }
}

/// Requirements derived from fill rule and antialiasing policy.
final class StencilCoverRequirements {
  const StencilCoverRequirements._({
    required this.minimumStencilBits,
    required this.minimumSampleCount,
    required this.requiresSeparateFrontBack,
    required this.requiresWrap,
    required this.requiresInvert,
  });

  factory StencilCoverRequirements.forDraw({
    required FillRule fillRule,
    required bool antiAlias,
    int nonZeroStencilBits = 8,
  }) {
    if (nonZeroStencilBits <= 0) {
      throw ArgumentError.value(
        nonZeroStencilBits,
        'nonZeroStencilBits',
        'must be > 0',
      );
    }
    return StencilCoverRequirements._(
      minimumStencilBits: fillRule == FillRule.nonZero ? nonZeroStencilBits : 1,
      minimumSampleCount: antiAlias ? 4 : 1,
      requiresSeparateFrontBack: fillRule == FillRule.nonZero,
      requiresWrap: fillRule == FillRule.nonZero,
      requiresInvert: fillRule == FillRule.evenOdd,
    );
  }

  final int minimumStencilBits;
  final int minimumSampleCount;
  final bool requiresSeparateFrontBack;
  final bool requiresWrap;
  final bool requiresInvert;

  /// Largest non-zero winding guaranteed not to wrap to zero.
  int get maximumSafeAbsoluteWinding => (1 << minimumStencilBits) - 1;
}

final class StencilCoverPlanMetrics {
  const StencilCoverPlanMetrics({
    required this.drawCount,
    required this.commandCount,
    required this.triangleCount,
    required this.retainedCapacityBytes,
    required this.arenaGrowths,
  });

  final int drawCount;
  final int commandCount;
  final int triangleCount;
  final int retainedCapacityBytes;
  final int arenaGrowths;
}

/// Reusable command and signed triangle arenas.
final class StencilCoverDrawPlan {
  StencilCoverDrawPlan({
    int initialTriangles = 128,
    int initialDraws = 32,
    int maxTrianglesPerDraw = 65536,
  })  : maxTrianglesPerDraw =
            _positive(maxTrianglesPerDraw, 'maxTrianglesPerDraw'),
        _vertices = Float32List(
          _positive(initialTriangles, 'initialTriangles') *
              3 *
              kStencilCoverVertexStride,
        ),
        _draws = Int32List(
          _positive(initialDraws, 'initialDraws') * kStencilCoverDrawStride,
        ),
        _bounds = Float32List(initialDraws * kStencilCoverBoundsStride),
        _commands = Int32List(initialDraws * 3 * kStencilCoverCommandStride);

  final int maxTrianglesPerDraw;

  Float32List _vertices;
  Int32List _draws;
  Float32List _bounds;
  Int32List _commands;
  int _vertexCount = 0;
  int _drawCount = 0;
  int _commandCount = 0;
  int _growths = 0;

  int get vertexCount => _vertexCount;
  int get triangleCount => _vertexCount ~/ 3;
  int get drawCount => _drawCount;
  int get commandCount => _commandCount;
  int get arenaGrowths => _growths;

  Float32List get vertexStorage => _vertices;
  Int32List get drawStorage => _draws;
  Float32List get boundsStorage => _bounds;
  Int32List get commandStorage => _commands;

  double vertexX(int vertex) => _vertex(vertex, 0);
  double vertexY(int vertex) => _vertex(vertex, 1);

  int drawMaterial(int draw) => _draw(draw, 0);
  FillRule drawFillRule(int draw) => FillRule.values[_draw(draw, 1)];
  bool drawAntiAlias(int draw) => _draw(draw, 2) != 0;
  int drawFirstVertex(int draw) => _draw(draw, 3);
  int drawVertexCount(int draw) => _draw(draw, 4);
  int drawRequiredStencilBits(int draw) => _draw(draw, 5);

  Rect drawCoverBounds(int draw) {
    _checkDraw(draw);
    final int base = draw * kStencilCoverBoundsStride;
    return Rect.fromLTRB(
      _bounds[base],
      _bounds[base + 1],
      _bounds[base + 2],
      _bounds[base + 3],
    );
  }

  StencilCoverCommandKind commandKind(int command) =>
      StencilCoverCommandKind.values[_command(command, 0)];
  int commandDraw(int command) => _command(command, 1);

  /// Explicit API-neutral stencil state for [command].
  StencilCoverPassState commandState(int command) {
    final StencilCoverCommandKind kind = commandKind(command);
    final int draw = commandDraw(command);
    final FillRule rule = drawFillRule(draw);
    final int fullMask = (1 << drawRequiredStencilBits(draw)) - 1;
    return switch (kind) {
      StencilCoverCommandKind.clear => StencilCoverPassState(
          colorWrites: false,
          compare: StencilCompare.always,
          compareMask: fullMask,
          writeMask: fullMask,
          frontPass: StencilOperation.keep,
          backPass: StencilOperation.keep,
          clearValue: 0,
        ),
      StencilCoverCommandKind.accumulate => rule == FillRule.nonZero
          ? StencilCoverPassState(
              colorWrites: false,
              compare: StencilCompare.always,
              compareMask: fullMask,
              writeMask: fullMask,
              frontPass: StencilOperation.incrementWrap,
              backPass: StencilOperation.decrementWrap,
            )
          : const StencilCoverPassState(
              colorWrites: false,
              compare: StencilCompare.always,
              compareMask: 0x01,
              writeMask: 0x01,
              frontPass: StencilOperation.invertLeastSignificantBit,
              backPass: StencilOperation.invertLeastSignificantBit,
            ),
      StencilCoverCommandKind.cover => StencilCoverPassState(
          colorWrites: true,
          compare: rule == FillRule.nonZero
              ? StencilCompare.notEqualZero
              : StencilCompare.leastSignificantBitSet,
          compareMask: rule == FillRule.nonZero ? fullMask : 0x01,
          writeMask: rule == FillRule.nonZero ? fullMask : 0x01,
          frontPass: StencilOperation.zero,
          backPass: StencilOperation.zero,
        ),
    };
  }

  /// Appends one device-space path and returns its draw index, or `-1` if the
  /// geometry or clipped cover is empty.
  int append(
    Path path, {
    required Rect clip,
    required int materialIndex,
    required FillRule fillRule,
    required StencilCoverCapabilities capabilities,
    bool antiAlias = true,
    int nonZeroStencilBits = 8,
    Transform2D transform = Transform2D.identity,
    double flattenTolerance = kDefaultFlattenTolerance,
  }) {
    if (materialIndex < 0) {
      throw RangeError.value(materialIndex, 'materialIndex', 'must be >= 0');
    }
    if (path.isEmpty || clip.isEmpty) return -1;
    for (var point = 0; point < path.pointCount; point++) {
      if (!path.pointX(point).isFinite || !path.pointY(point).isFinite) {
        throw StencilCoverPlanError(
          StencilCoverRejection.nonFiniteGeometry,
          'the source path contains a non-finite local coordinate',
        );
      }
    }
    final StencilCoverRequirements requirements =
        StencilCoverRequirements.forDraw(
      fillRule: fillRule,
      antiAlias: antiAlias,
      nonZeroStencilBits: nonZeroStencilBits,
    );
    final String? unsupported = capabilities.unsupportedReason(requirements);
    if (unsupported != null) {
      throw UnsupportedError('stencil-then-cover unavailable: $unsupported');
    }

    final int firstVertex = _vertexCount;
    final _FanSink sink = _FanSink(this);
    try {
      path.flattenTo(
        sink,
        tolerance: flattenTolerance,
        transform: transform,
      );
    } catch (_) {
      // Appending is transactional. A rejected or malformed path must not
      // leave triangles that a later draw could accidentally submit.
      _vertexCount = firstVertex;
      rethrow;
    }
    final int emitted = _vertexCount - firstVertex;
    if (emitted == 0) return -1;
    final Rect cover = sink.bounds.intersect(clip);
    if (cover.isEmpty) {
      _vertexCount = firstVertex;
      return -1;
    }

    _ensureDrawCapacity(_drawCount + 1);
    final int draw = _drawCount++;
    final int drawBase = draw * kStencilCoverDrawStride;
    _draws[drawBase] = materialIndex;
    _draws[drawBase + 1] = fillRule.index;
    _draws[drawBase + 2] = antiAlias ? 1 : 0;
    _draws[drawBase + 3] = firstVertex;
    _draws[drawBase + 4] = emitted;
    _draws[drawBase + 5] = requirements.minimumStencilBits;
    final int boundsBase = draw * kStencilCoverBoundsStride;
    _bounds[boundsBase] = cover.left;
    _bounds[boundsBase + 1] = cover.top;
    _bounds[boundsBase + 2] = cover.right;
    _bounds[boundsBase + 3] = cover.bottom;
    _appendCommand(StencilCoverCommandKind.clear, draw);
    _appendCommand(StencilCoverCommandKind.accumulate, draw);
    _appendCommand(StencilCoverCommandKind.cover, draw);
    return draw;
  }

  /// Clears logical lengths while keeping high-water arenas.
  void reset() {
    _vertexCount = 0;
    _drawCount = 0;
    _commandCount = 0;
  }

  StencilCoverPlanMetrics get metrics => StencilCoverPlanMetrics(
        drawCount: _drawCount,
        commandCount: _commandCount,
        triangleCount: triangleCount,
        retainedCapacityBytes: _vertices.lengthInBytes +
            _draws.lengthInBytes +
            _bounds.lengthInBytes +
            _commands.lengthInBytes,
        arenaGrowths: _growths,
      );

  bool _addTriangle(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
    int trianglesInDraw,
  ) {
    for (final double value in <double>[ax, ay, bx, by, cx, cy]) {
      if (!value.isFinite) {
        throw StencilCoverPlanError(
          StencilCoverRejection.nonFiniteGeometry,
          'flattening produced a non-finite device coordinate',
        );
      }
    }
    final double signedArea = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    if (signedArea == 0) return false;
    if (trianglesInDraw >= maxTrianglesPerDraw) {
      throw StencilCoverPlanError(
        StencilCoverRejection.triangleLimitExceeded,
        'one draw exceeds the configured limit of $maxTrianglesPerDraw '
        'signed triangles',
      );
    }
    _ensureVertexCapacity(_vertexCount + 3);
    for (final (double, double) point in <(double, double)>[
      (ax, ay),
      (bx, by),
      (cx, cy),
    ]) {
      final int base = _vertexCount * kStencilCoverVertexStride;
      _vertices[base] = point.$1;
      _vertices[base + 1] = point.$2;
      _vertexCount++;
    }
    return true;
  }

  void _appendCommand(StencilCoverCommandKind kind, int draw) {
    final int base = _commandCount * kStencilCoverCommandStride;
    _commands[base] = kind.index;
    _commands[base + 1] = draw;
    _commandCount++;
  }

  void _ensureVertexCapacity(int count) {
    final int required = count * kStencilCoverVertexStride;
    if (required <= _vertices.length) return;
    var length = _vertices.length * 2;
    while (length < required) {
      length *= 2;
    }
    _vertices = Float32List(length)..setRange(0, _vertices.length, _vertices);
    _growths++;
  }

  void _ensureDrawCapacity(int count) {
    final int requiredDraws = count * kStencilCoverDrawStride;
    if (requiredDraws > _draws.length) {
      var length = _draws.length * 2;
      while (length < requiredDraws) {
        length *= 2;
      }
      _draws = Int32List(length)..setRange(0, _draws.length, _draws);
      _growths++;
    }
    final int requiredBounds = count * kStencilCoverBoundsStride;
    if (requiredBounds > _bounds.length) {
      var length = _bounds.length * 2;
      while (length < requiredBounds) {
        length *= 2;
      }
      _bounds = Float32List(length)..setRange(0, _bounds.length, _bounds);
      _growths++;
    }
    final int requiredCommands = count * 3 * kStencilCoverCommandStride;
    if (requiredCommands > _commands.length) {
      var length = _commands.length * 2;
      while (length < requiredCommands) {
        length *= 2;
      }
      _commands = Int32List(length)..setRange(0, _commands.length, _commands);
      _growths++;
    }
  }

  double _vertex(int vertex, int field) {
    if (vertex < 0 || vertex >= _vertexCount) {
      throw RangeError.index(vertex, _vertices, 'vertex');
    }
    return _vertices[vertex * kStencilCoverVertexStride + field];
  }

  int _draw(int draw, int field) {
    _checkDraw(draw);
    return _draws[draw * kStencilCoverDrawStride + field];
  }

  int _command(int command, int field) {
    if (command < 0 || command >= _commandCount) {
      throw RangeError.index(command, _commands, 'command');
    }
    return _commands[command * kStencilCoverCommandStride + field];
  }

  void _checkDraw(int draw) {
    if (draw < 0 || draw >= _drawCount) {
      throw RangeError.index(draw, _draws, 'draw');
    }
  }
}

final class _FanSink implements PolylineSink {
  _FanSink(this.plan);

  final StencilCoverDrawPlan plan;
  double _anchorX = 0;
  double _anchorY = 0;
  double _previousX = 0;
  double _previousY = 0;
  int _pointCount = 0;
  int _triangleCount = 0;
  double _left = double.infinity;
  double _top = double.infinity;
  double _right = double.negativeInfinity;
  double _bottom = double.negativeInfinity;

  Rect get bounds =>
      _left.isFinite ? Rect.fromLTRB(_left, _top, _right, _bottom) : Rect.zero;

  @override
  void moveTo(double x, double y) {
    _anchorX = x;
    _anchorY = y;
    _previousX = x;
    _previousY = y;
    _pointCount = 1;
  }

  @override
  void lineTo(double x, double y) {
    if (_pointCount == 0) {
      moveTo(x, y);
      return;
    }
    if (_pointCount >= 2) {
      final bool emitted = plan._addTriangle(
        _anchorX,
        _anchorY,
        _previousX,
        _previousY,
        x,
        y,
        _triangleCount,
      );
      if (emitted) {
        _triangleCount++;
        _include(_anchorX, _anchorY);
        _include(_previousX, _previousY);
        _include(x, y);
      }
    }
    _previousX = x;
    _previousY = y;
    _pointCount++;
  }

  @override
  void close() => _pointCount = 0;

  void _include(double x, double y) {
    if (x < _left) _left = x;
    if (x > _right) _right = x;
    if (y < _top) _top = y;
    if (y > _bottom) _bottom = y;
  }
}

int _positive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'must be > 0');
  return value;
}
