/// Explicit OpenGL executor for backend-neutral stencil-then-cover plans.
///
/// This remains an opt-in seam. It is not reached by the established dense
/// display-list renderer and therefore cannot silently change its output.
library;

import 'dart:typed_data';

import '../../../graphics/display_list_opcodes.dart';
import '../gpu_pipeline.dart';
import '../vector/stencil_cover_draw_plan.dart';

/// Premultiplied colour and blend state used by a stencil cover command.
final class StencilGlMaterial {
  StencilGlMaterial({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
    this.blendMode = blendModeSrcOver,
  }) {
    for (final (String, double) channel in <(String, double)>[
      ('red', red),
      ('green', green),
      ('blue', blue),
      ('alpha', alpha),
    ]) {
      if (!channel.$2.isFinite || channel.$2 < 0 || channel.$2 > 1) {
        throw ArgumentError.value(channel.$2, channel.$1, 'must be 0..1');
      }
    }
    if (red > alpha || green > alpha || blue > alpha) {
      throw ArgumentError('colour channels must be premultiplied by alpha');
    }
    gpuBlendForMode(blendMode);
  }

  final double red;
  final double green;
  final double blue;
  final double alpha;
  final int blendMode;
}

/// Small fakeable contract over the GL operations used by approach C.
abstract interface class StencilCoverGlDriver {
  StencilCoverCapabilities get capabilities;

  void createResources({
    required String vertexSource,
    required String fragmentSource,
  });

  void deleteResources();

  /// Uploads [vertexCount] tightly packed `x,y` accumulation vertices.
  void uploadVertices(Float32List vertices, int vertexCount);

  /// Uploads every cover quad of the submission in one transfer.
  ///
  /// Six `x,y` vertices per draw, so [drawCover] only has to name the first.
  /// This replaces a `bufferData` per cover - a buffer orphan each - with one
  /// per submission, and moves no other state.
  void uploadCoverVertices(Float32List vertices, int vertexCount);

  void beginStencilCoverPass({
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  });

  /// Restricts every following command to this rectangle.
  ///
  /// Called by the executor before each command, including the accumulation.
  /// A driver that scissors only where it obviously matters - the clear and
  /// the cover - leaves the accumulation inheriting whatever came last, which
  /// is a wrong shape the moment two draws share a clear.
  void setScissor({
    required double left,
    required double top,
    required double right,
    required double bottom,
  });

  void clearStencil({required int value, required int writeMask});

  void setPassState(StencilCoverPassState state);

  void setBlendState(GpuBlendState blend);

  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  );

  void drawTriangles({required int firstVertex, required int vertexCount});

  /// Draws the pre-uploaded quad at [firstVertex].
  void drawCover({required int firstVertex});

  void endStencilCoverPass();

  /// Forgets object names invalidated by context loss without deleting them.
  void discardNativeResources();
}

final class StencilCoverGlExecutionStats {
  const StencilCoverGlExecutionStats({
    required this.draws,
    required this.commands,
    required this.accumulationTriangles,
    required this.coverDraws,
    required this.clearCommands,
  });

  final int draws;
  final int commands;
  final int accumulationTriangles;
  final int coverDraws;
  final int clearCommands;
}

/// Owns the optional stencil program and replays [StencilCoverDrawPlan].
final class StencilCoverGlExecutor {
  StencilCoverGlExecutor(this._driver);

  final StencilCoverGlDriver _driver;
  bool _initialized = false;
  bool _disposed = false;

  bool get isInitialized => _initialized;
  bool get isDisposed => _disposed;

  void initialize({required bool desktop}) {
    _throwIfDisposed();
    if (_initialized) return;
    _driver.createResources(
      vertexSource: _vertexShader(desktop: desktop),
      fragmentSource: _fragmentShader(desktop: desktop),
    );
    _initialized = true;
  }

  StencilCoverGlExecutionStats submit(
    StencilCoverDrawPlan plan, {
    required List<StencilGlMaterial> materials,
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) {
    _throwIfDisposed();
    if (!_initialized) {
      throw StateError('initialize the stencil-cover executor before submit');
    }
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    if (yFlip != 0 && yFlip != 1) {
      throw ArgumentError.value(yFlip, 'yFlip', 'must be 0 or 1');
    }
    if (plan.commandCount == 0) {
      return const StencilCoverGlExecutionStats(
        draws: 0,
        commands: 0,
        accumulationTriangles: 0,
        coverDraws: 0,
        clearCommands: 0,
      );
    }
    _validatePlan(plan, materials);

    _driver.uploadVertices(plan.vertexStorage, plan.vertexCount);
    _driver.uploadCoverVertices(
      plan.coverVertexStorage,
      plan.coverVertexCount,
    );
    _driver.beginStencilCoverPass(
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      yFlip: yFlip,
    );
    var clearCommands = 0;
    var coverDraws = 0;
    var accumulationTriangles = 0;
    try {
      for (var command = 0; command < plan.commandCount; command++) {
        final int draw = plan.commandDraw(command);
        // The command's rectangle, not the draw's, and set for *every* command
        // rather than only the ones that obviously need it. A coalesced clear
        // scissors to the union of its group; an accumulation scissors to its
        // own cover, which is the only region its cover will read. Letting the
        // accumulation inherit the previous rectangle is what broke when the
        // clears were first grouped. See `stencil_cover_draw_plan.dart`.
        final bounds = plan.commandBounds(command);
        final StencilCoverPassState state = plan.commandState(command);
        _driver.setScissor(
          left: bounds.left,
          top: bounds.top,
          right: bounds.right,
          bottom: bounds.bottom,
        );
        switch (plan.commandKind(command)) {
          case StencilCoverCommandKind.clear:
            _driver.clearStencil(
              value: state.clearValue!,
              writeMask: state.writeMask,
            );
            clearCommands++;
          case StencilCoverCommandKind.accumulate:
            _driver.setPassState(state);
            _driver.drawTriangles(
              firstVertex: plan.drawFirstVertex(draw),
              vertexCount: plan.drawVertexCount(draw),
            );
            accumulationTriangles += plan.drawVertexCount(draw) ~/ 3;
          case StencilCoverCommandKind.cover:
            final StencilGlMaterial material =
                materials[plan.drawMaterial(draw)];
            _driver
              ..setPassState(state)
              ..setBlendState(gpuBlendForMode(material.blendMode))
              ..setPremultipliedColor(
                material.red,
                material.green,
                material.blue,
                material.alpha,
              )
              ..drawCover(firstVertex: plan.drawCoverFirstVertex(draw));
            coverDraws++;
        }
      }
    } finally {
      _driver.endStencilCoverPass();
    }
    return StencilCoverGlExecutionStats(
      draws: plan.drawCount,
      commands: plan.commandCount,
      accumulationTriangles: accumulationTriangles,
      coverDraws: coverDraws,
      clearCommands: clearCommands,
    );
  }

  void discardNativeResources() {
    _throwIfDisposed();
    if (_initialized) _driver.discardNativeResources();
    _initialized = false;
  }

  void dispose() {
    if (_disposed) return;
    if (_initialized) _driver.deleteResources();
    _initialized = false;
    _disposed = true;
  }

  /// Context loss already destroyed GL objects; only Dart lifecycle remains.
  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    if (_initialized) _driver.discardNativeResources();
    _initialized = false;
    _disposed = true;
  }

  void _validatePlan(
    StencilCoverDrawPlan plan,
    List<StencilGlMaterial> materials,
  ) {
    // The adapter queries the currently bound target. Keep that snapshot
    // consistent for every draw in this submission without caching it across
    // framebuffers or frames.
    final StencilCoverCapabilities capabilities = _driver.capabilities;
    for (var draw = 0; draw < plan.drawCount; draw++) {
      final int material = plan.drawMaterial(draw);
      if (material < 0 || material >= materials.length) {
        throw RangeError.range(
          material,
          0,
          materials.isEmpty ? 0 : materials.length - 1,
          'materialIndex',
        );
      }
      final StencilCoverRequirements requirements =
          StencilCoverRequirements.forDraw(
        fillRule: plan.drawFillRule(draw),
        antiAlias: plan.drawAntiAlias(draw),
        nonZeroStencilBits: plan.drawRequiredStencilBits(draw),
      );
      final String? unsupported = capabilities.unsupportedReason(requirements);
      if (unsupported != null) {
        throw UnsupportedError('stencil-then-cover unavailable: $unsupported');
      }
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the stencil-cover executor is disposed');
  }
}

String _vertexShader({required bool desktop}) => desktop
    ? r'''#version 330 core
layout(location = 0) in vec2 aPosition;
uniform vec2 uViewport;
uniform int uYFlip;
void main() {
  vec2 ndc = vec2(aPosition.x * 2.0 / uViewport.x - 1.0,
                  1.0 - aPosition.y * 2.0 / uViewport.y);
  if (uYFlip != 0) ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
}'''
    : r'''#version 300 es
precision highp float;
layout(location = 0) in vec2 aPosition;
uniform vec2 uViewport;
uniform int uYFlip;
void main() {
  vec2 ndc = vec2(aPosition.x * 2.0 / uViewport.x - 1.0,
                  1.0 - aPosition.y * 2.0 / uViewport.y);
  if (uYFlip != 0) ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
}''';

String _fragmentShader({required bool desktop}) => desktop
    ? r'''#version 330 core
uniform vec4 uColor;
out vec4 fragColor;
void main() { fragColor = uColor; }'''
    : r'''#version 300 es
precision mediump float;
uniform vec4 uColor;
out vec4 fragColor;
void main() { fragColor = uColor; }''';
