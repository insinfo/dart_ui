import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_stencil_cover_driver.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_stencil_cover_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
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
  test('scissor rounds outward, clips and follows y-flip convention', () {
    final StencilCoverGlScissor topDown = StencilCoverGlScissor.fromBounds(
      left: -2.1,
      top: 3.2,
      right: 12.4,
      bottom: 8.1,
      viewportWidth: 10,
      viewportHeight: 20,
      yFlip: 0,
    );
    expect(
      <int>[topDown.x, topDown.y, topDown.width, topDown.height],
      <int>[0, 11, 10, 6],
    );
    final StencilCoverGlScissor bottomUp = StencilCoverGlScissor.fromBounds(
      left: 2.1,
      top: 3.2,
      right: 8.4,
      bottom: 8.1,
      viewportWidth: 10,
      viewportHeight: 20,
      yFlip: 1,
    );
    expect(
      <int>[bottomUp.x, bottomUp.y, bottomUp.width, bottomUp.height],
      <int>[2, 3, 7, 6],
    );
  });

  test('stencil symbols are optional for the established GL probe', () {
    expect(kStencilCoverGlRequiredSymbols, <String>[
      'glColorMask',
      'glClearStencil',
      'glStencilMask',
      'glStencilFunc',
      'glStencilOpSeparate',
      'glFrontFace',
      'glDrawArrays',
      'glGetFramebufferAttachmentParameteriv',
    ]);
    expect(
      missingStencilCoverGlSymbols(
        (String name) =>
            name == 'glStencilFunc' ? nullptr : Pointer<Void>.fromAddress(1),
      ),
      <String>['glStencilFunc'],
    );
    for (final String symbol in kStencilCoverGlRequiredSymbols) {
      expect(kRequiredGlSymbols, isNot(contains(symbol)));
    }
  });

  test('replays clear, non-zero accumulation and cover in strict order', () {
    final StencilCoverDrawPlan plan = _plan(FillRule.nonZero);
    final _FakeDriver driver = _FakeDriver();
    final StencilCoverGlExecutor executor = StencilCoverGlExecutor(driver)
      ..initialize(desktop: true);

    final StencilCoverGlExecutionStats stats = executor.submit(
      plan,
      materials: <StencilGlMaterial>[
        StencilGlMaterial(
          red: 0.25,
          green: 0.125,
          blue: 0,
          alpha: 0.5,
          blendMode: blendModeSrcOver,
        ),
      ],
      viewportWidth: 100,
      viewportHeight: 80,
      yFlip: 0,
    );

    expect(stats.draws, 1);
    expect(stats.commands, 3);
    expect(stats.accumulationTriangles, 2);
    expect(stats.coverDraws, 1);
    expect(stats.clearCommands, 1);
    expect(driver.uploadedVertices, 6);
    expect(driver.events, <String>[
      'create:desktop',
      'upload:6',
      'coverUpload:6',
      'begin:100x80:0',
      'scissor:0,0,10,10',
      'clear:0/255',
      'scissor:0,0,10,10',
      'state:false:always:incrementWrap/decrementWrap',
      'triangles:0+6',
      'scissor:0,0,10,10',
      'state:true:notEqualZero:zero/zero',
      'blend:one/oneMinusSrcAlpha',
      'color:0.25,0.125,0.0,0.5',
      'cover:0',
      'end',
    ]);
  });

  test('even-odd uses invert and least-significant-bit cover', () {
    final _FakeDriver driver = _FakeDriver();
    final StencilCoverGlExecutor executor = StencilCoverGlExecutor(driver)
      ..initialize(desktop: false);
    executor.submit(
      _plan(FillRule.evenOdd),
      materials: <StencilGlMaterial>[
        StencilGlMaterial(red: 1, green: 1, blue: 1, alpha: 1),
      ],
      viewportWidth: 10,
      viewportHeight: 10,
      yFlip: 1,
    );

    expect(driver.vertexSource, contains('#version 300 es'));
    expect(
      driver.events,
      contains(
        'state:false:always:'
        'invertLeastSignificantBit/invertLeastSignificantBit',
      ),
    );
    expect(
      driver.events,
      contains('state:true:leastSignificantBitSet:zero/zero'),
    );
  });

  test('shader projection follows dense and sparse y-flip convention', () {
    final _FakeDriver driver = _FakeDriver();
    StencilCoverGlExecutor(driver).initialize(desktop: true);
    expect(
      driver.vertexSource,
      contains('1.0 - aPosition.y * 2.0 / uViewport.y'),
    );
    expect(driver.vertexSource, contains('if (uYFlip != 0) ndc.y = -ndc.y'));
  });

  test('runtime capabilities are checked before upload and begin', () {
    final _FakeDriver driver = _FakeDriver(
      capabilities: const StencilCoverCapabilities(
        stencilBits: 1,
        sampleCount: 1,
        separateFrontBackOperations: false,
        wrapOperations: false,
        invertOperation: true,
        scissoredClear: true,
      ),
    );
    final StencilCoverGlExecutor executor = StencilCoverGlExecutor(driver)
      ..initialize(desktop: true);
    expect(
      () => executor.submit(
        _plan(FillRule.nonZero, antiAlias: false),
        materials: <StencilGlMaterial>[
          StencilGlMaterial(red: 1, green: 1, blue: 1, alpha: 1),
        ],
        viewportWidth: 10,
        viewportHeight: 10,
        yFlip: 0,
      ),
      throwsUnsupportedError,
    );
    expect(driver.uploadedVertices, 0);
    expect(driver.events, isNot(contains(startsWith('begin:'))));
  });

  test('failed draw closes pass and device loss never deletes names', () {
    final _FakeDriver driver = _FakeDriver(failDraw: true);
    final StencilCoverGlExecutor executor = StencilCoverGlExecutor(driver)
      ..initialize(desktop: true);
    expect(
      () => executor.submit(
        _plan(FillRule.nonZero),
        materials: <StencilGlMaterial>[
          StencilGlMaterial(red: 1, green: 1, blue: 1, alpha: 1),
        ],
        viewportWidth: 10,
        viewportHeight: 10,
        yFlip: 0,
      ),
      throwsStateError,
    );
    expect(driver.events.last, 'end');

    executor.discardNativeResources();
    expect(executor.isInitialized, isFalse);
    expect(driver.discards, 1);
    expect(driver.deletes, 0);
    executor.initialize(desktop: true);
    expect(driver.creates, 2);
    executor.disposeAfterDeviceLoss();
    expect(driver.discards, 2);
    expect(driver.deletes, 0);
  });

  test('normal disposal deletes once and material validation is pre-pass', () {
    final _FakeDriver driver = _FakeDriver();
    final StencilCoverGlExecutor executor = StencilCoverGlExecutor(driver)
      ..initialize(desktop: true);
    expect(
      () => executor.submit(
        _plan(FillRule.nonZero),
        materials: <StencilGlMaterial>[],
        viewportWidth: 10,
        viewportHeight: 10,
        yFlip: 0,
      ),
      throwsRangeError,
    );
    expect(driver.events, isNot(contains(startsWith('begin:'))));
    executor
      ..dispose()
      ..dispose();
    expect(driver.deletes, 1);
    expect(() => executor.initialize(desktop: true), throwsStateError);
  });
}

StencilCoverDrawPlan _plan(FillRule rule, {bool antiAlias = true}) =>
    StencilCoverDrawPlan()
      ..append(
        (PathBuilder()..addRect(const Rect.fromLTRB(0, 0, 10, 10))).build(),
        clip: const Rect.fromLTRB(0, 0, 10, 10),
        materialIndex: 0,
        fillRule: rule,
        capabilities: _full,
        antiAlias: antiAlias,
      );

final class _FakeDriver implements StencilCoverGlDriver {
  _FakeDriver({
    this.failDraw = false,
    this.capabilities = _full,
  });

  final bool failDraw;
  @override
  final StencilCoverCapabilities capabilities;
  final List<String> events = <String>[];
  String vertexSource = '';
  int uploadedVertices = 0;
  int uploadedCoverVertices = 0;
  int creates = 0;
  int deletes = 0;
  int discards = 0;

  @override
  void createResources({
    required String vertexSource,
    required String fragmentSource,
  }) {
    creates++;
    this.vertexSource = vertexSource;
    events.add('create:${vertexSource.contains('330') ? 'desktop' : 'es'}');
  }

  @override
  void deleteResources() {
    deletes++;
    events.add('delete');
  }

  @override
  void uploadVertices(Float32List vertices, int vertexCount) {
    uploadedVertices = vertexCount;
    events.add('upload:$vertexCount');
  }

  @override
  void uploadCoverVertices(Float32List vertices, int vertexCount) {
    uploadedCoverVertices = vertexCount;
    events.add('coverUpload:$vertexCount');
  }

  @override
  void beginStencilCoverPass({
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) =>
      events.add('begin:${viewportWidth}x$viewportHeight:$yFlip');

  @override
  void setScissor({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) =>
      events.add(
        'scissor:${_n(left)},${_n(top)},${_n(right)},${_n(bottom)}',
      );

  @override
  void clearStencil({required int value, required int writeMask}) =>
      events.add('clear:$value/$writeMask');

  @override
  void setPassState(StencilCoverPassState state) => events.add(
        'state:${state.colorWrites}:${state.compare.name}:'
        '${state.frontPass.name}/${state.backPass.name}',
      );

  @override
  void setBlendState(GpuBlendState blend) =>
      events.add('blend:${blend.source.name}/${blend.destination.name}');

  @override
  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  ) =>
      events.add('color:$red,$green,$blue,$alpha');

  @override
  void drawTriangles({required int firstVertex, required int vertexCount}) {
    events.add('triangles:$firstVertex+$vertexCount');
    if (failDraw) throw StateError('injected draw failure');
  }

  @override
  void drawCover({required int firstVertex}) =>
      events.add('cover:$firstVertex');

  @override
  void endStencilCoverPass() => events.add('end');

  @override
  void discardNativeResources() {
    discards++;
    events.add('discard');
  }
}

String _n(double value) => value.toStringAsFixed(0);
