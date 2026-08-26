@TestOn('browser')

/// The experimental sparse-strip pipeline on a real WebGL2 context.
///
/// The VM cannot answer the two questions this file exists for. The first is
/// whether the GLES 3.00 dialect of the sparse shader **compiles and links** in
/// a browser - `gl_sparse_strips.dart` emits it, `webgl_sparse_driver.dart`
/// hands it to `getContext('webgl2')`, and nothing short of a real driver can
/// say whether every uniform survived. The second is what the pipeline
/// actually *draws*, which for a coverage-carrying path is the whole claim: a
/// solid interior must land as the paint, a boundary strip must land as the
/// paint scaled by its alpha8 texel, and a refused submission must leave the
/// target's pixels exactly as it found them.
///
/// See `webgl_session.dart` for the skip contract. The short form:
/// `@TestOn('browser')` keeps this out of CI's plain `dart test`, and inside a
/// browser every test names why it skipped when there is no context - which on
/// a headless machine without `--enable-unsafe-swiftshader` is the normal
/// outcome and not a bug in this backend.
///
/// Run it with:
///
/// ```
/// dart test -p chrome test/rendering/gpu/webgl/
/// ```
library;

import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'webgl_session.dart';

void main() {
  late WebGlSession session;

  setUpAll(() {
    session = WebGlSession.open(enableExperimentalSparseStrips: true);
  });
  tearDownAll(() => session.close());

  /// Skips the calling test when there is no device, naming the reason.
  bool ready() {
    final String? reason = session.skipReason;
    if (reason == null) return true;
    printOnFailure('skipped: $reason');
    markTestSkipped('no WebGL2 device: $reason');
    return false;
  }

  /// A cleared offscreen target and the framebuffer object behind it.
  ({WebGlOffscreenTarget target, web.WebGLFramebuffer? fbo}) cleared(
    int width,
    int height,
  ) {
    final WebGlOffscreenTarget target = session.target(width, height);
    final web.WebGL2RenderingContext gl = session.device!.gl;
    gl
      ..bindFramebuffer(
        web.WebGL2RenderingContext.FRAMEBUFFER,
        target.debugFramebuffer,
      )
      ..viewport(0, 0, width, height)
      ..disable(web.WebGL2RenderingContext.SCISSOR_TEST)
      ..clearColor(0, 0, 0, 0)
      ..clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT);
    return (target: target, fbo: target.debugFramebuffer);
  }

  group('the opt-in', () {
    test('is on for a context adopted with the flag', () {
      if (!ready()) return;
      // Linking happened during adoptContext; a device that reports true has
      // already compiled the GLES dialect of the sparse shader on this driver.
      expect(session.device!.experimentalSparseStripsEnabled, isTrue);
    });

    test('is off - and refuses - for a context adopted without it', () {
      // A second context on purpose, closed immediately: this is the claim
      // that the default path is unchanged, and it cannot be made on the
      // session's own device.
      final WebGlSession plain = WebGlSession.open();
      try {
        if (plain.skipReason != null) {
          printOnFailure('skipped: ${plain.skipReason}');
          markTestSkipped('no WebGL2 device: ${plain.skipReason}');
          return;
        }
        expect(plain.device!.experimentalSparseStripsEnabled, isFalse);
        expect(
          () => plain.device!.submitSparseStrips(
            SparseStripDrawPlan()
              ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0),
            materials: <SparseGlMaterial>[_white()],
            viewportWidth: 4,
            viewportHeight: 4,
          ),
          throwsStateError,
        );
      } finally {
        plain.close();
      }
    });
  });

  group('what it draws', () {
    test('a solid interior lands as the paint, on whole pixels', () {
      if (!ready()) return;
      final ({WebGlOffscreenTarget target, web.WebGLFramebuffer? fbo}) surface =
          cleared(8, kStripHeight);
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(StripBuffer()..addFill(2, 0, 3), materialIndex: 0);

      final SparseGlExecutionStats stats = session.device!.submitSparseStrips(
        plan,
        materials: <SparseGlMaterial>[_white()],
        viewportWidth: 8,
        viewportHeight: kStripHeight,
        surfaceFramebuffer: surface.fbo,
      );
      expect(stats.drawCalls, 1);
      expect(stats.instances, 1);

      expect(
        session.device!.readPixelsInto(surface.target.framebuffer),
        isTrue,
      );
      final Framebuffer pixels = surface.target.framebuffer;
      for (var y = 0; y < kStripHeight; y++) {
        for (var x = 0; x < 8; x++) {
          final bool inside = x >= 2 && x < 5;
          expect(
            _alpha(pixels, x, y),
            inside ? 255 : 0,
            reason: 'pixel ($x, $y) should be '
                '${inside ? 'covered' : 'untouched'}; a fill quad is placed on '
                'whole pixels and must not bleed',
          );
        }
      }
      surface.target.dispose();
    });

    test('a boundary strip lands as the paint scaled by its alpha8 texel', () {
      if (!ready()) return;
      final ({WebGlOffscreenTarget target, web.WebGLFramebuffer? fbo}) surface =
          cleared(8, kStripHeight);
      // Four columns of coverage, each a different level, so a shader that
      // sampled the wrong texel - or filtered between two - shows up as a
      // shifted or smeared ramp rather than as a uniform grey.
      final StripBuffer source = StripBuffer();
      final int alpha = source.reserveAlphas(4 * kStripHeight);
      for (var row = 0; row < kStripHeight; row++) {
        for (var column = 0; column < 4; column++) {
          source.alphas[alpha + row * 4 + column] = 64 * (column + 1) - 1;
        }
      }
      source.addStrip(1, 0, 4, alpha);
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(source, materialIndex: 0);

      final SparseGlExecutionStats stats = session.device!.submitSparseStrips(
        plan,
        materials: <SparseGlMaterial>[_white()],
        viewportWidth: 8,
        viewportHeight: kStripHeight,
        surfaceFramebuffer: surface.fbo,
      );
      expect(stats.drawCalls, 1);
      expect(stats.alphaUploads, 1);

      expect(
        session.device!.readPixelsInto(surface.target.framebuffer),
        isTrue,
      );
      final Framebuffer pixels = surface.target.framebuffer;
      for (var column = 0; column < 4; column++) {
        final int expected = 64 * (column + 1) - 1;
        for (var row = 0; row < kStripHeight; row++) {
          expect(
            _alpha(pixels, 1 + column, row),
            closeTo(expected, 2),
            reason: 'column $column carries coverage $expected; the tolerance '
                'is for the driver\'s sampler precision, not for a wrong '
                'texel',
          );
        }
      }
      expect(_alpha(pixels, 0, 0), 0);
      expect(_alpha(pixels, 5, 0), 0);
      surface.target.dispose();
    });

    test('a gradient material samples the shared LUT across the quad', () {
      if (!ready()) return;
      final ({WebGlOffscreenTarget target, web.WebGLFramebuffer? fbo}) surface =
          cleared(8, kStripHeight);
      final LinearGradient gradient = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 8,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0xFF000000),
          GradientStop(1, 0xFFFFFFFF),
        ],
      );
      final GpuGradientCache cache =
          GpuGradientCache(allocator: session.device!);
      final GpuGradientBinding binding = cache.resolve(gradient);
      final GpuGradientShaderParameters parameters =
          GpuGradientShaderParameters.fromPaint(ReplayPaint(
        argbColor: 0,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrcOver,
        antiAlias: true,
        gradient: gradient,
      ));

      session.device!.submitSparseStrips(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 8), materialIndex: 0),
        materials: <SparseGlMaterial>[
          SparseGlMaterial.gradient(
            gradientBinding: binding,
            gradientParameters: parameters,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 8,
        viewportHeight: kStripHeight,
        surfaceFramebuffer: surface.fbo,
      );

      expect(
        session.device!.readPixelsInto(surface.target.framebuffer),
        isTrue,
      );
      final Framebuffer pixels = surface.target.framebuffer;
      // Every stop is opaque, so the whole quad is opaque whatever the ramp
      // does, and the red channel is the ramp itself.
      for (var x = 0; x < 8; x++) {
        expect(_alpha(pixels, x, 0), 255);
      }
      final List<int> ramp = <int>[
        for (var x = 0; x < 8; x++) _red(pixels, x, 0),
      ];
      expect(ramp.first, lessThan(64),
          reason: 'the first stop is black: $ramp');
      expect(ramp.last, greaterThan(191),
          reason: 'the last stop is white: $ramp');
      for (var x = 1; x < 8; x++) {
        expect(ramp[x], greaterThanOrEqualTo(ramp[x - 1]),
            reason: 'a pad-spread linear ramp is monotonic: $ramp');
      }
      cache.clear();
      surface.target.dispose();
    });

    test('an inverted projection is a flag, not a guess', () {
      if (!ready()) return;
      // kYFlipTopDown is what a pass rendering into a texture something else
      // will sample uses. Drawing the same quad both ways and finding it in
      // different rows is what makes the flag observable at all - and a
      // backend that ignored it would draw every layer upside down.
      final ({WebGlOffscreenTarget target, web.WebGLFramebuffer? fbo}) surface =
          cleared(4, 8);
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(StripBuffer()..addFill(0, 0, 4), materialIndex: 0);
      session.device!.submitSparseStrips(
        plan,
        materials: <SparseGlMaterial>[_white()],
        viewportWidth: 4,
        viewportHeight: 8,
        yFlip: kYFlipTopDown,
        surfaceFramebuffer: surface.fbo,
      );
      expect(
        session.device!.readPixelsInto(surface.target.framebuffer),
        isTrue,
      );
      final Framebuffer flipped = surface.target.framebuffer;
      // Device rows 0..3 written upside down land in the bottom half of a
      // buffer that readPixelsInto has already turned top-down.
      expect(_alpha(flipped, 0, 0), 0);
      expect(_alpha(flipped, 0, 7), 255);
      surface.target.dispose();
    });
  });

  group('a refusal', () {
    test('leaves the target exactly as it found it', () {
      if (!ready()) return;
      final ({WebGlOffscreenTarget target, web.WebGLFramebuffer? fbo}) surface =
          cleared(8, kStripHeight);
      // One good submission, so there is something to disturb.
      session.device!.submitSparseStrips(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 4), materialIndex: 0),
        materials: <SparseGlMaterial>[_white()],
        viewportWidth: 8,
        viewportHeight: kStripHeight,
        surfaceFramebuffer: surface.fbo,
      );
      expect(
        session.device!.readPixelsInto(surface.target.framebuffer),
        isTrue,
      );
      final List<int> before = <int>[
        for (var x = 0; x < 8; x++) _alpha(surface.target.framebuffer, x, 0),
      ];

      expect(
        () => session.device!.submitSparseStrips(
          SparseStripDrawPlan()
            ..append(StripBuffer()..addFill(4, 0, 4), materialIndex: 9),
          materials: <SparseGlMaterial>[_white()],
          viewportWidth: 8,
          viewportHeight: kStripHeight,
          surfaceFramebuffer: surface.fbo,
        ),
        throwsRangeError,
      );

      expect(
        session.device!.readPixelsInto(surface.target.framebuffer),
        isTrue,
      );
      final List<int> after = <int>[
        for (var x = 0; x < 8; x++) _alpha(surface.target.framebuffer, x, 0),
      ];
      expect(after, before,
          reason: 'a refused sparse submission must be invisible, so the '
              'caller can fall back to the dense atlas without repairing '
              'anything');
      surface.target.dispose();
    });
  });
}

/// Opaque white, premultiplied, source-over: the paint that makes coverage
/// readable straight off the alpha channel.
SparseGlMaterial _white() => SparseGlMaterial(
      red: 1,
      green: 1,
      blue: 1,
      alpha: 1,
      blendMode: blendModeSrcOver,
    );

int _red(Framebuffer pixels, int x, int y) =>
    pixels.pixels[pixels.offsetOf(x, y)];

int _alpha(Framebuffer pixels, int x, int y) =>
    pixels.pixels[pixels.offsetOf(x, y) + 3];
