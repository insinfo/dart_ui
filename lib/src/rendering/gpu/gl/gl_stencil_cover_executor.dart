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

  /// Uploads [vertexCount] tightly packed `x,y` vertices.
  void uploadVertices(Float32List vertices, int vertexCount);

  void beginStencilCoverPass({
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  });

  void clearStencil({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required int value,
    required int writeMask,
  });

  void setPassState(StencilCoverPassState state);

  void setBlendState(GpuBlendState blend);

  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  );

  void drawTriangles({required int firstVertex, required int vertexCount});

  void drawCover({
    required double left,
    required double top,
    required double right,
    required double bottom,
  });

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
        final bounds = plan.drawCoverBounds(draw);
        final StencilCoverPassState state = plan.commandState(command);
        switch (plan.commandKind(command)) {
          case StencilCoverCommandKind.clear:
            _driver.clearStencil(
              left: bounds.left,
              top: bounds.top,
              right: bounds.right,
              bottom: bounds.bottom,
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
              ..drawCover(
                left: bounds.left,
                top: bounds.top,
                right: bounds.right,
                bottom: bounds.bottom,
              );
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
