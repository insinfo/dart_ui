/// The same model, the same camera, down the CPU rasteriser and down the
/// Direct3D 12 mesh pipeline, compared pixel by pixel.
///
/// `test/rendering/gpu/d3d11/d3d11_mesh_cpu_parity_test.dart` is this file's
/// twin, scene for scene and budget for budget, and it carries the whole
/// argument for *why* the tolerance is two fractions rather than one maximum:
/// two triangle rasterisers disagree legitimately at a silhouette, where the
/// difference is the full distance from lit surface to clear colour, so a
/// single "max channel deviation" would have to be 255 to pass and would
/// measure nothing. That argument is not repeated. The vocabulary is:
///
///   * `shadingBudget` - the fraction of pixels whose worst channel differs by
///     **more than one level**. One level is rounding; anything above it is
///     arithmetic that diverged.
///   * `geometryBudget` - the fraction whose worst channel differs by **more
///     than sixteen levels**. Far above any rounding these scenes produce and
///     far below the distance from model to background, so it counts pixels
///     where the two disagreed about *coverage*.
///
/// ## Why the same budgets, and what changed
///
/// The numbers are inherited rather than re-derived, and that is the finding.
/// Direct3D fixes triangle coverage exactly and both Direct3D backends compile
/// the same shading to the same rules, so a Direct3D 12 frame that differed
/// from a Direct3D 11 one would be a bug in one of them, not a property of the
/// API. Measured at 256x192 on an Intel(R) UHD Graphics at feature level 12_1
/// - the same adapter the Direct3D 11 table was measured on:
///
/// | scene | pixels differing | worst channel | > 1 level | > 16 levels |
/// |---|---|---|---|---|
/// | cube, flat | 0 | 0 | 0 | 0 |
/// | six 1x1 textures, unlit | 0 | 0 | 0 | 0 |
/// | two crossing quads | 0 | 0 | 0 | 0 |
/// | sphere, smooth | 73 | **1** | 0 | 0 |
/// | sphere, flat | 4 | 16 | 3 | 0 |
/// | open double-sided shell | 43 | 34 | 1 | 1 |
/// | tiled checkerboard, unlit | 113 | 151 | 113 | 113 |
///
/// Six of the seven rows are the Direct3D 11 table's, digit for digit. The one
/// that moved is the shell - 43 differing pixels where Direct3D 11 has 38 -
/// and it moved in the column that does not enter a budget: the counts that
/// do, 1 over one level and 1 over sixteen, are identical. Five extra pixels
/// differing by a single level on the fold of a bowl is the float32 shading
/// arithmetic landing the other side of a tie, which is exactly what the
/// budgets are sized for and exactly what the depth format predicts: this
/// pipeline's buffer is `D32_FLOAT` where the Direct3D 11 one's is
/// `D24_UNORM_S8_UINT`, so along a surface that folds back on itself the two
/// order near-coincident fragments with different precision. It is the only
/// place in the file where the two backends are entitled to differ at all.
///
/// So the budgets are: **zero** wherever every edge in the scene is straight,
/// because there the two fill rules provably cover the same pixels; **0.02% of
/// the frame** - ten pixels - wherever a silhouette is curved; and **0.5%** on
/// the tiled texture alone, whose count depends on the adapter's interpolator
/// rather than on Direct3D's exactly specified coverage rules. Each scene's
/// comment carries its own observation.
///
/// ## The budgets can fail
///
/// The last group perturbs the two pieces of state that can be wrong without
/// crashing. On Direct3D 12 both live in a **pipeline state object** rather
/// than in a bindable state object, which is why [D3d12MeshRenderer] keys its
/// pipeline cache on them: a perturbation that returned the cached object
/// would make the sabotage pass by doing nothing. Measured:
/// clearing `frontCounterClockwise` moves **33.3%** of the frame past sixteen
/// levels, reversing the depth comparison **41.9%**, and disabling the depth
/// test **17.1%** - against budgets of 0.02%, between eight hundred and two
/// thousand times the margin. Those three numbers are the Direct3D 11 file's
/// to within a tenth of a percent, which says the two pipelines are wrong in
/// the same way when they are broken in the same way.
///
/// ## The scenes are generated, not loaded
///
/// No file on disk, for the reason the Direct3D 11 file gives: a parity test
/// that needed `D:/3d/sonic.glb` would pass on one machine and skip on every
/// other. `tool/d3d12_mesh_probe.dart` is where real models are measured.
///
/// It skips rather than fails where no device answers, which on the Linux and
/// macOS halves of CI is every run.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_mesh_pipeline.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

/// 256x192: wide enough that the aspect ratio is not 1 - a projection that
/// dropped the aspect divide would still match at 256x256 - and small enough
/// that the CPU rasteriser runs the whole file in a second.
const int _width = 256;
const int _height = 192;

/// Prints every measurement rather than only the failures.
///
/// The budgets below are observations, and an observation has to be
/// re-measurable: `MESH_PARITY_REPORT=1 dart test -j 1 <file>` prints what this
/// run saw, which is how the numbers in the comments were arrived at and how
/// they are checked after a driver update. An environment variable and not a
/// `--dart-define`, because the test runner does not forward one to the isolate
/// it spawns.
final bool _reportMeasurements =
    Platform.environment.containsKey('MESH_PARITY_REPORT');

void main() {
  final session = _MeshSession.open();
  tearDownAll(session.close);

  group('the CPU and the Direct3D 12 mesh pipeline draw the same model', () {
    test('a closed cube, flat: 0 px', () async {
      // The floor of the whole comparison. Six flat quadrilaterals, culled,
      // with straight silhouette edges. If this differs, nothing below it means
      // anything.
      //
      // Observed: **0 pixels differ at all**, of 49 152. Not merely inside the
      // budget - identical - which says the transcription of `_shade`, the
      // matrix transpose, the depth remap and the winding are all exact where
      // the geometry gives them no room to disagree. The budget is zero for the
      // structural reason: every edge here is straight, so the two fill rules
      // cover the same pixels.
      await _expectParity(
        session,
        MeshScene(
            mesh: _cube(), camera: _camera(_cube()), shading: MeshShading.flat),
        shadingBudget: 0,
        geometryBudget: 0,
      );
    });

    test('six 1x1 textures, unlit: 0 px', () async {
      // `modulate` in isolation, on eighteen channel pairs and with no texel
      // boundary anywhere. Each face of the cube is its own primitive with its
      // own single-texel base-colour map and its own colour factor, so the fold
      // `(texel * factor + 127) / 255` is evaluated on eighteen distinct
      // integer pairs and one level of drift in any of them repaints a face.
      //
      // Single-texel maps deliberately: the last scene in this group shows that
      // two samplers disagree about which texel covers a pixel centred on a
      // texel boundary, and that disagreement would otherwise hide a fold that
      // drifted. With one texel there is no boundary and the budget can be
      // zero, which is the only budget that says the arithmetic is right.
      //
      // It is also what proves the texture is rebound per primitive: six
      // materials, six shader-resource views, and a pipeline that bound the
      // first for all six would paint the cube in one colour.
      //
      // Observed: **0 pixels differ**. The epsilon in `modulate` is what makes
      // that true - without it the integer divide lands a few ulps below a
      // whole quotient and `floor` takes it down a level. The texels are
      // saturated, so a red-blue swap between `0xAARRGGBB` in Dart and the
      // texture's DXGI format would be over a hundred levels on two thirds of
      // the frame.
      final Mesh3D mesh = _texturedFaces();
      await _expectParity(
        session,
        MeshScene(
            mesh: mesh, camera: _camera(mesh), shading: MeshShading.unlit),
        shadingBudget: 0,
        geometryBudget: 0,
      );
    });

    test('two crossing quads, depth-tested: 0 px', () async {
      // The depth buffer, isolated. Two quads pass through each other at an
      // angle, so along the intersection the nearer surface changes from one to
      // the other and any disagreement about depth is a visible wedge rather
      // than a pixel. Straight edges again, so the budget is zero for the same
      // structural reason the cube's is.
      //
      // Observed: **0 pixels differ**, with the model covering 41.9% of the
      // frame. That is the depth remap `(z + w) * 0.5` and `LESS` against a
      // buffer cleared to 1 reproducing an `infinity`-cleared buffer and a `<`
      // test exactly, along a seam where the two surfaces are within a float of
      // each other.
      final Mesh3D mesh = _crossingQuads();
      await _expectParity(
        session,
        MeshScene(mesh: mesh, camera: _camera(mesh)),
        shadingBudget: 0,
        geometryBudget: 0,
      );
    });

    test('a sphere, smooth: 73 px, none over 1 level', () async {
      // The scene the pipeline is really for, and the one with the most room to
      // disagree: 2 048 triangles, a curved silhouette, and a normal
      // interpolated per pixel.
      //
      // The normal is where the `noperspective` declaration is proved. HLSL
      // interpolates perspective-correctly by default and `MeshRasterizer`
      // interpolates the normal affinely - its comment #5 argues for exactly
      // that - so a shader without the modifier shades this sphere from a
      // normal a fraction of a degree off over its whole surface.
      //
      // Observed: 73 pixels of 49 152 differ and **the largest difference is
      // one level**, so nothing at all lands in either budget. The budgets are
      // nevertheless not zero, and the reason is the difference between what
      // was measured and what is guaranteed: Direct3D fixes triangle coverage
      // exactly, so the silhouette is the same on every adapter, but the
      // shading arithmetic is float32 against Dart's float64 and a tie can
      // round the other way on another device. 0.02% of the frame is 10 pixels
      // - about 2% of this sphere's 470-pixel silhouette - which is room for
      // that and for nothing structural: the smallest perturbation the sabotage
      // group produces is 17% of the frame, eight hundred times this.
      final Mesh3D mesh = _sphere();
      await _expectParity(
        session,
        MeshScene(mesh: mesh, camera: _camera(mesh)),
        shadingBudget: 0.0002,
        geometryBudget: 0.0002,
      );
    });

    test('a sphere, flat: 4 px, 3 over 1 level', () async {
      // The de-indexed vertex stream. `MeshShading.flat` shades from the face's
      // own plane normal, which is not a property of any vertex, so the
      // pipeline builds a second stream with three vertices per triangle each
      // carrying its face's normal - and the cross product that computes it is
      // `MeshRasterizer`'s `faceNormalOf` character for character.
      //
      // A version that reused the smooth stream would draw this identically to
      // the test above rather than failing, which is why the scene is here: on
      // a sphere, flat and smooth are visibly different pictures.
      //
      // Observed: 4 pixels differ, 3 of them by more than one level and none by
      // more than sixteen. Same budgets and same argument as the scene above.
      final Mesh3D mesh = _sphere();
      await _expectParity(
        session,
        MeshScene(mesh: mesh, camera: _camera(mesh), shading: MeshShading.flat),
        shadingBudget: 0.0002,
        geometryBudget: 0.0002,
      );
    });

    test('an open double-sided shell: 43 px, 1 over 16 levels', () async {
      // The reversed normal. A back face that survived culling - which is what
      // `doubleSided` means - is lit with its normal negated, and without that
      // the inside of this bowl is flat ambient and looks like a hole.
      //
      // It is also the only scene where `SV_IsFrontFace` is read at all: with
      // culling on, every fragment is front-facing by construction and the
      // branch is dead. So this is what says `FrontCounterClockwise = TRUE`
      // reaches the pixel stage as well as the rasteriser, and that the two
      // agree about which face is which.
      //
      // Observed: 43 pixels differ, 1 by more than one level and that same 1 by
      // more than sixteen - a single point on the rim, where the bowl's
      // silhouette is a fold rather than an edge. This is the one scene whose
      // differing-pixel count is not the Direct3D 11 file's; see the library
      // comment for why a `D32_FLOAT` depth buffer moves five single-level
      // pixels on a fold and nothing else in the file.
      final Mesh3D mesh = _shell(doubleSided: true);
      await _expectParity(
        session,
        MeshScene(mesh: mesh, camera: _camera(mesh)),
        shadingBudget: 0.0002,
        geometryBudget: 0.0002,
      );
    });

    test('a tiled checkerboard, wrapping: 113 px', () async {
      // The sampler's addressing mode. The UVs run to 3 over an 8x8
      // checkerboard, so each face carries 24x24 tiles: with `CLAMP` instead of
      // `REPEAT` the picture would be one tile with the edge texel smeared over
      // the other 575, which is tens of thousands of pixels rather than the
      // hundred below.
      //
      // **This scene's differences are a third kind, neither shading nor
      // coverage, and it is the only budget here that is loose.** A pixel
      // centre that lands within a float of a texel boundary can go to either
      // texel: the CPU computes `(u * width).floor()` from Dart doubles and the
      // sampler computes the same thing in float32, and where they disagree the
      // pixel takes the other checker - 151 levels, the full distance between
      // the two colours, on a pixel where nothing is wrong.
      //
      // It was measured rather than assumed to be jitter. A 64x1 ramp texture
      // over the same cube, where a one-texel error is four levels rather than
      // 151, differs on **48 pixels of 33 000 covered, every one of them by
      // exactly one texel**. A half-texel offset - the classic sampler bug -
      // would shift the whole surface and differ on every covered pixel by a
      // constant; this differs on a quarter of a percent of them by one step,
      // which is rounding at a boundary and nothing else. The rate also behaves
      // the way jitter must: with a coarse texture the pixels beside a boundary
      // sit much closer to the exact texel edge, so the same absolute error
      // flips far more of them - a 2x2 map flips 27% of its boundary pixels
      // where this one flips under 1%.
      //
      // Observed: 113 pixels of 49 152, 0.230%. The budget is 0.5%, a little
      // over twice that, because this is the one count in the file that depends
      // on the adapter's interpolator rather than on Direct3D's exactly
      // specified coverage rules.
      final Mesh3D mesh = _cube(texture: _checkerboard(), uvScale: 3);
      await _expectParity(
        session,
        MeshScene(
            mesh: mesh, camera: _camera(mesh), shading: MeshShading.unlit),
        shadingBudget: 0.005,
        geometryBudget: 0.005,
      );
    });
  });

  group('the pipeline is cached and the test can fail', () {
    test('geometry is uploaded once and drawn many times', () async {
      // The measurement the whole cache exists for. A 451 838-triangle model is
      // 46.5 MiB of vertices and indices; re-uploading it at 60 Hz is about
      // 2.8 GB/s of traffic for geometry that never changed, and it is
      // invisible in the picture. Ten frames of an orbiting camera must
      // therefore leave `bufferUploadCount` where the first frame left it.
      final _MeshSession live = session;
      if (live.device == null) {
        markTestSkipped(live.skipReason!);
        return;
      }
      final D3d12MeshRenderer renderer = live.renderer;
      final Mesh3D mesh = _sphere();
      final D3d12OffscreenTarget target = live.target(_width, _height);
      try {
        MeshCamera camera = _camera(mesh);
        await _renderGpu(
            target, renderer, MeshScene(mesh: mesh, camera: camera));
        final int afterFirst = renderer.bufferUploadCount;
        // Two: one vertex buffer and one index buffer for the single
        // primitive. Asserted rather than assumed, so a pipeline that started
        // splitting a mesh into chunks would have to say so here.
        expect(afterFirst, greaterThanOrEqualTo(2));
        for (var i = 0; i < 10; i++) {
          camera = camera.withYaw(camera.yaw + 0.05);
          await _renderGpu(
              target, renderer, MeshScene(mesh: mesh, camera: camera));
        }
        expect(
          renderer.bufferUploadCount,
          afterFirst,
          reason: 'the geometry was re-uploaded on a frame that changed only '
              'the camera, which is the traffic the cache exists to stop',
        );
        expect(renderer.cachedPrimitiveCount, 1);
        renderer.discardMesh(mesh);
        expect(renderer.cachedPrimitiveCount, 0);
        expect(renderer.cachedBufferBytes, 0);
      } finally {
        renderer.discardMesh(mesh);
        target.dispose();
      }
    });

    test('a budget that cannot hold both meshes evicts the older one',
        () async {
      // The other half of the cache, and the half that only matters on a
      // machine that runs out: a viewer that opens model after model must not
      // grow without bound. The eviction is least-recently-used, so drawing A,
      // then B, then A again under a budget that fits one of them uploads A
      // twice - and asserting the *upload count* rather than the resident bytes
      // is what says the eviction really released the buffers rather than
      // merely forgetting them.
      final _MeshSession live = session;
      if (live.device == null) {
        markTestSkipped(live.skipReason!);
        return;
      }
      final D3d12MeshRenderer renderer = live.renderer;
      final D3d12OffscreenTarget target = live.target(_width, _height);
      final int budget = renderer.bufferBudgetBytes;
      final Mesh3D first = _sphere();
      final Mesh3D second = _shell(doubleSided: false);
      try {
        await _renderGpu(
            target, renderer, MeshScene(mesh: first, camera: _camera(first)));
        // Just under what the sphere alone needs, so the second mesh cannot
        // join it. Read from the renderer rather than computed here: the vertex
        // stride is the pipeline's business.
        renderer.bufferBudgetBytes = renderer.cachedBufferBytes - 1;
        await _renderGpu(
            target, renderer, MeshScene(mesh: second, camera: _camera(second)));
        expect(renderer.cachedPrimitiveCount, 1,
            reason: 'the budget fits one mesh and two are resident');
        final int uploads = renderer.bufferUploadCount;
        await _renderGpu(
            target, renderer, MeshScene(mesh: first, camera: _camera(first)));
        expect(renderer.bufferUploadCount, greaterThan(uploads),
            reason: 'the evicted mesh was drawn again and not re-uploaded, so '
                'its buffers were kept after all');
      } finally {
        renderer.bufferBudgetBytes = budget;
        renderer.discardMesh(first);
        renderer.discardMesh(second);
        target.dispose();
      }
    });

    test('flipping the winding leaves the model hollow', () async {
      // The sabotage. `MeshRasterizer._drawProjected` calls a positive
      // screen-space signed area back-facing, and with y pointing down that is
      // the clockwise triangle; Direct3D calls the clockwise triangle
      // *front*-facing unless `FrontCounterClockwise` is set. Clearing the flag
      // therefore culls exactly the triangles the CPU keeps and keeps exactly
      // the ones it culls - the sphere is drawn from the inside.
      //
      // Measured and recorded here so the magnitude is on record rather than
      // merely asserted to be large: **33.3% of the frame more than sixteen
      // levels out**, against a budget of 0.02% - sixteen hundred times the
      // tolerance. That is what makes the tolerance a measurement rather than
      // a hope.
      //
      // The flag is part of [D3d12MeshRenderer]'s pipeline-state key, and it
      // has to be: Direct3D 12 bakes the winding into the pipeline state
      // object, so a cache that ignored the flag would hand back the object
      // built with the old value and this test would pass by drawing exactly
      // the same picture twice.
      await _expectSabotage(
        session,
        _sphere(),
        apply: (D3d12MeshRenderer renderer) =>
            renderer.frontCounterClockwise = false,
        restore: (D3d12MeshRenderer renderer) =>
            renderer.frontCounterClockwise = true,
        atLeast: 0.05,
      );
    });

    test('reversing the depth comparison draws the far surface first',
        () async {
      // The second sabotage, on the scene built for it. `GREATER` against a
      // buffer cleared to 1 rejects every fragment, so the picture is the clear
      // colour and nothing else - which is a bigger difference than the
      // "inside out" one and is the honest result of the perturbation rather
      // than a chosen one.
      //
      // Measured: **41.9% of the frame more than sixteen levels out**, and the
      // frame's coverage of the model falls to 0% - the clear colour and
      // nothing else.
      await _expectSabotage(
        session,
        _crossingQuads(),
        apply: (D3d12MeshRenderer renderer) =>
            renderer.depthTest = D3d12MeshDepthTest.greater,
        restore: (D3d12MeshRenderer renderer) =>
            renderer.depthTest = D3d12MeshDepthTest.less,
        atLeast: 0.05,
      );
    });

    test('turning the depth test off lets far triangles overwrite near ones',
        () async {
      // The third, and the one closest to a real bug: `ALWAYS` still draws
      // every triangle, so the frame looks like a model rather than like a
      // failure. What is wrong is the order - the last triangle submitted wins
      // - and only a comparison can see it.
      //
      // Measured: **17.1% of the frame more than sixteen levels out** on the
      // crossing quads, against a budget of 0. The sphere would show nothing:
      // it is convex and culled, so no two surviving fragments ever land on
      // one pixel and the depth test has nothing to order. Choosing the scene
      // that can expose the perturbation is part of the perturbation being
      // real.
      await _expectSabotage(
        session,
        _crossingQuads(),
        apply: (D3d12MeshRenderer renderer) =>
            renderer.depthTest = D3d12MeshDepthTest.always,
        restore: (D3d12MeshRenderer renderer) =>
            renderer.depthTest = D3d12MeshDepthTest.less,
        atLeast: 0.02,
      );
    });
  });
}

// ---------------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------------

Future<void> _expectParity(
  _MeshSession session,
  MeshScene scene, {
  required double shadingBudget,
  required double geometryBudget,
}) async {
  if (session.device == null) {
    markTestSkipped(session.skipReason!);
    return;
  }
  final D3d12OffscreenTarget target = session.target(_width, _height);
  try {
    final Framebuffer gpu = await _renderGpu(target, session.renderer, scene);
    final Framebuffer cpu = _renderCpu(scene);
    final _Difference difference = _compare(cpu, gpu);
    printOnFailure('measured: $difference');
    // ignore: avoid_print
    if (_reportMeasurements) print('MEASURED $difference');
    // A frame that drew nothing agrees with a CPU frame that also drew nothing,
    // and would pass every budget below. So the model has to be *there*, and
    // "there" is measured as coverage rather than as a count of colours: a
    // flat-shaded cube is four colours including the background, and a guard
    // that demanded more would refuse the very scene it is protecting.
    expect(
      difference.gpuCoverage,
      greaterThan(0.05),
      reason:
          'the Direct3D frame is ${(difference.gpuCoverage * 100).toStringAsFixed(1)}% model, so the comparison below would pass on '
          'an empty frame',
    );
    expect(
      difference.overOneFraction,
      lessThanOrEqualTo(shadingBudget),
      reason: 'shading: $difference',
    );
    expect(
      difference.overSixteenFraction,
      lessThanOrEqualTo(geometryBudget),
      reason: 'coverage: $difference',
    );
  } finally {
    session.renderer.discardMesh(scene.mesh);
    target.dispose();
  }
}

/// Renders the scene twice through one renderer - once correct, once with
/// [apply] in force - and asserts the perturbed frame is at least [atLeast] of
/// the frame away from the correct one.
///
/// Against the *correct GPU frame* and not against the CPU one, deliberately:
/// the question a fallibility check answers is "would this test notice", and
/// the thing it must notice is a change in this pipeline. Comparing against the
/// CPU would fold the perturbation together with the tolerance the parity tests
/// already measured.
Future<void> _expectSabotage(
  _MeshSession session,
  Mesh3D mesh, {
  required void Function(D3d12MeshRenderer) apply,
  required void Function(D3d12MeshRenderer) restore,
  required double atLeast,
}) async {
  if (session.device == null) {
    markTestSkipped(session.skipReason!);
    return;
  }
  final D3d12MeshRenderer renderer = session.renderer;
  final D3d12OffscreenTarget target = session.target(_width, _height);
  final MeshScene scene = MeshScene(mesh: mesh, camera: _camera(mesh));
  try {
    final Framebuffer good = _copy(await _renderGpu(target, renderer, scene));
    apply(renderer);
    final Framebuffer broken = await _renderGpu(target, renderer, scene);
    final _Difference difference = _compare(good, broken);
    // ignore: avoid_print
    if (_reportMeasurements) print('SABOTAGE $difference');
    expect(
      difference.overSixteenFraction,
      greaterThanOrEqualTo(atLeast),
      reason: 'the perturbation changed almost nothing, so the parity budgets '
          'above are not measuring what they claim: $difference',
    );
  } finally {
    restore(renderer);
    renderer.discardMesh(mesh);
    target.dispose();
  }
}

Future<Framebuffer> _renderGpu(
  D3d12OffscreenTarget target,
  D3d12MeshRenderer renderer,
  MeshScene scene,
) async {
  final Frame frame = target.beginFrame(const FrameRequest());
  renderer.drawScene(target, scene);
  final PresentResult result = await target.present(frame);
  expect(result.status, PresentStatus.presented, reason: '$result');
  return target.framebuffer;
}

Framebuffer _renderCpu(MeshScene scene) {
  final Framebuffer target = Framebuffer.allocate(
    width: _width,
    height: _height,
    // BGRA, because `MeshRasterizer` writes its 32-bit words as B, G, R, A and
    // the readback is asked for the same order. Comparing an RGBA readback
    // against it would report every coloured pixel as a difference and every
    // grey one as a match, which is the worst possible failure mode: the cube
    // scenes would pass and the textured ones would not.
    format: PixelFormat.bgra8888Premultiplied,
  );
  MeshRasterizer().render(
    target,
    scene.mesh,
    scene.camera,
    shading: scene.shading,
    backgroundArgb: scene.backgroundArgb ?? 0xFF10151F,
    lightDirection: scene.lightDirection,
    ambient: scene.ambient,
  );
  return target;
}

Framebuffer _copy(Framebuffer source) {
  final Framebuffer out = Framebuffer.allocate(
    width: source.width,
    height: source.height,
    format: source.format,
  );
  out.pixels.setRange(0, source.pixels.length, source.pixels);
  return out;
}

/// How far apart two renders of one scene are, in the three sizes that have
/// three different causes.
final class _Difference {
  const _Difference({
    required this.pixels,
    required this.differing,
    required this.maxChannel,
    required this.overOne,
    required this.overSixteen,
    required this.gpuCoverage,
  });

  final int pixels;
  final int differing;
  final int maxChannel;
  final int overOne;
  final int overSixteen;

  /// The fraction of the second frame that is not the clear colour.
  ///
  /// The guard against a comparison that passes because both frames are empty.
  final double gpuCoverage;

  double get overOneFraction => overOne / pixels;
  double get overSixteenFraction => overSixteen / pixels;

  @override
  String toString() => '$differing/$pixels px differ, max $maxChannel levels, '
      '>1: $overOne (${(overOneFraction * 100).toStringAsFixed(3)}%), '
      '>16: $overSixteen (${(overSixteenFraction * 100).toStringAsFixed(3)}%), '
      'coverage ${(gpuCoverage * 100).toStringAsFixed(1)}%';
}

_Difference _compare(Framebuffer a, Framebuffer b) {
  var differing = 0;
  var maxChannel = 0;
  var overOne = 0;
  var overSixteen = 0;
  var covered = 0;
  // The clear colour of every scene here, as the B, G, R bytes a
  // `bgra8888Premultiplied` framebuffer stores it in.
  const int clearB = 0x1F;
  const int clearG = 0x15;
  const int clearR = 0x10;
  for (var y = 0; y < a.height; y++) {
    final int rowA = y * a.bytesPerRow;
    final int rowB = y * b.bytesPerRow;
    for (var x = 0; x < a.width; x++) {
      final int atA = rowA + x * 4;
      final int atB = rowB + x * 4;
      if (b.pixels[atB] != clearB ||
          b.pixels[atB + 1] != clearG ||
          b.pixels[atB + 2] != clearR) {
        covered++;
      }
      var worst = 0;
      for (var c = 0; c < 3; c++) {
        final int delta = (a.pixels[atA + c] - b.pixels[atB + c]).abs();
        if (delta > worst) worst = delta;
      }
      if (worst == 0) continue;
      differing++;
      if (worst > maxChannel) maxChannel = worst;
      if (worst > 1) overOne++;
      if (worst > 16) overSixteen++;
    }
  }
  return _Difference(
    pixels: a.width * a.height,
    differing: differing,
    maxChannel: maxChannel,
    overOne: overOne,
    overSixteen: overSixteen,
    gpuCoverage: covered / (a.width * a.height),
  );
}

// ---------------------------------------------------------------------------
// The scenes
// ---------------------------------------------------------------------------

/// A camera framing [mesh], with a yaw and pitch that put no face square on.
///
/// Not axis-aligned on purpose: a camera looking straight at a cube's face
/// hides a transposed matrix, a swapped axis and half the ways a projection can
/// be wrong, because the picture is a symmetric square either way.
MeshCamera _camera(Mesh3D mesh) =>
    MeshCamera.frame(mesh.computeBounds(), yaw: 0.7, pitch: 0.42);

/// The unit cube, two triangles a face, optionally textured.
Mesh3D _cube({MeshTexture? texture, double uvScale = 1}) {
  final List<double> positions = <double>[];
  final List<double> normals = <double>[];
  final List<double> uvs = <double>[];
  final List<int> indices = <int>[];

  void face(
    Vector3 origin,
    Vector3 right,
    Vector3 up,
    Vector3 normal,
  ) {
    final int base = positions.length ~/ 3;
    final List<Vector3> corners = <Vector3>[
      origin,
      origin + right,
      origin + right + up,
      origin + up,
    ];
    const List<List<double>> corner = <List<double>>[
      <double>[0, 0],
      <double>[1, 0],
      <double>[1, 1],
      <double>[0, 1],
    ];
    for (var i = 0; i < 4; i++) {
      positions
        ..add(corners[i].x)
        ..add(corners[i].y)
        ..add(corners[i].z);
      normals
        ..add(normal.x)
        ..add(normal.y)
        ..add(normal.z);
      uvs
        ..add(corner[i][0] * uvScale)
        ..add(corner[i][1] * uvScale);
    }
    // Counter-clockwise seen from outside, which is the winding every format
    // this framework reads uses and therefore the one the pipeline must treat
    // as front-facing.
    indices
      ..addAll(<int>[base, base + 1, base + 2])
      ..addAll(<int>[base, base + 2, base + 3]);
  }

  const Vector3 x = Vector3(1, 0, 0);
  const Vector3 y = Vector3(0, 1, 0);
  const Vector3 z = Vector3(0, 0, 1);
  face(const Vector3(0, 0, 1), x, y, z);
  face(const Vector3(1, 0, 0), const Vector3(-1, 0, 0), y,
      const Vector3(0, 0, -1));
  face(const Vector3(1, 0, 1), const Vector3(0, 0, -1), y, x);
  face(const Vector3(0, 0, 0), z, y, const Vector3(-1, 0, 0));
  face(const Vector3(0, 1, 1), x, const Vector3(0, 0, -1), y);
  face(const Vector3(0, 0, 0), x, z, const Vector3(0, -1, 0));

  return Mesh3D(
    name: 'cube',
    format: 'generated',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
        positions: Float32List.fromList(positions),
        indices: Uint32List.fromList(indices),
        normals: Float32List.fromList(normals),
        uvs: Float32List.fromList(uvs),
        material: MeshMaterial(
          colorArgb: 0xFFC8A050,
          baseColorTexture: texture,
        ),
      ),
    ],
  );
}

/// The cube again, but as six primitives, each with a single-texel map and a
/// colour factor of its own.
///
/// Six materials rather than one, because the interesting thing about a
/// per-primitive texture is that it has to be *rebound*: a pipeline that set
/// the shader-resource view once per frame instead of once per primitive draws
/// this cube in one colour and every other scene in this file identically.
Mesh3D _texturedFaces() {
  const List<int> texels = <int>[
    0xFFE04020,
    0xFF20E040,
    0xFF4020E0,
    0xFFE0E020,
    0xFF20E0E0,
    0xFFE020E0,
  ];
  const List<int> factors = <int>[
    0xFFFFFFFF,
    0xFFC8A050,
    0xFF80FF40,
    0xFF3060C0,
    0xFFFFA0A0,
    0xFF7F7F7F,
  ];
  final Mesh3D whole = _cube();
  final MeshPrimitive source = whole.primitives.single;
  final List<MeshPrimitive> faces = <MeshPrimitive>[];
  for (var face = 0; face < 6; face++) {
    final Float32List positions =
        Float32List.sublistView(source.positions, face * 12, face * 12 + 12);
    final Float32List normals =
        Float32List.sublistView(source.normals!, face * 12, face * 12 + 12);
    final Float32List uvs =
        Float32List.sublistView(source.uvs!, face * 8, face * 8 + 8);
    faces.add(MeshPrimitive(
      positions: Float32List.fromList(positions),
      normals: Float32List.fromList(normals),
      uvs: Float32List.fromList(uvs),
      indices: Uint32List.fromList(<int>[0, 1, 2, 0, 2, 3]),
      material: MeshMaterial(
        colorArgb: factors[face],
        baseColorTexture: MeshTexture(
          width: 1,
          height: 1,
          pixels: Uint32List.fromList(<int>[texels[face]]),
          name: 'face $face',
        ),
      ),
    ));
  }
  return Mesh3D(name: 'textured faces', format: 'generated', primitives: faces);
}

/// A UV sphere: 32 meridians by 32 rings, 2 048 triangles.
Mesh3D _sphere() {
  const int meridians = 32;
  const int rings = 32;
  final Float32List positions = Float32List((rings + 1) * (meridians + 1) * 3);
  final Float32List normals = Float32List((rings + 1) * (meridians + 1) * 3);
  final Float32List uvs = Float32List((rings + 1) * (meridians + 1) * 2);
  var p = 0;
  var t = 0;
  for (var ring = 0; ring <= rings; ring++) {
    final double phi = math.pi * ring / rings;
    for (var meridian = 0; meridian <= meridians; meridian++) {
      final double theta = 2 * math.pi * meridian / meridians;
      final double x = math.sin(phi) * math.cos(theta);
      final double y = math.cos(phi);
      final double z = math.sin(phi) * math.sin(theta);
      positions[p] = x;
      positions[p + 1] = y;
      positions[p + 2] = z;
      normals[p] = x;
      normals[p + 1] = y;
      normals[p + 2] = z;
      p += 3;
      uvs[t] = meridian / meridians;
      uvs[t + 1] = ring / rings;
      t += 2;
    }
  }
  final List<int> indices = <int>[];
  for (var ring = 0; ring < rings; ring++) {
    for (var meridian = 0; meridian < meridians; meridian++) {
      final int a = ring * (meridians + 1) + meridian;
      final int b = a + meridians + 1;
      indices
        ..addAll(<int>[a, b, a + 1])
        ..addAll(<int>[a + 1, b, b + 1]);
    }
  }
  return Mesh3D(
    name: 'sphere',
    format: 'generated',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
        positions: positions,
        indices: Uint32List.fromList(indices),
        normals: normals,
        uvs: uvs,
        material: const MeshMaterial(colorArgb: 0xFF9FB4D0),
      ),
    ],
  );
}

/// The top half of a sphere with its normals pointing out: an open bowl seen
/// from above, so both sides of the surface are in shot at once.
Mesh3D _shell({required bool doubleSided}) {
  const int meridians = 24;
  const int rings = 10;
  final List<double> positions = <double>[];
  final List<double> normals = <double>[];
  for (var ring = 0; ring <= rings; ring++) {
    final double phi = math.pi * 0.5 * ring / rings;
    for (var meridian = 0; meridian <= meridians; meridian++) {
      final double theta = 2 * math.pi * meridian / meridians;
      final double x = math.sin(phi) * math.cos(theta);
      final double y = -math.cos(phi);
      final double z = math.sin(phi) * math.sin(theta);
      positions
        ..add(x)
        ..add(y)
        ..add(z);
      normals
        ..add(x)
        ..add(y)
        ..add(z);
    }
  }
  final List<int> indices = <int>[];
  for (var ring = 0; ring < rings; ring++) {
    for (var meridian = 0; meridian < meridians; meridian++) {
      final int a = ring * (meridians + 1) + meridian;
      final int b = a + meridians + 1;
      indices
        ..addAll(<int>[a, b, a + 1])
        ..addAll(<int>[a + 1, b, b + 1]);
    }
  }
  return Mesh3D(
    name: 'shell',
    format: 'generated',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
        positions: Float32List.fromList(positions),
        indices: Uint32List.fromList(indices),
        normals: Float32List.fromList(normals),
        material: MeshMaterial(
          colorArgb: 0xFFB07050,
          doubleSided: doubleSided,
        ),
      ),
    ],
  );
}

/// Two quads through each other at an angle, double-sided so neither is culled.
Mesh3D _crossingQuads() {
  final List<double> positions = <double>[];
  final List<double> normals = <double>[];
  final List<int> indices = <int>[];

  void quad(List<Vector3> corners, Vector3 normal) {
    final int base = positions.length ~/ 3;
    for (final Vector3 corner in corners) {
      positions
        ..add(corner.x)
        ..add(corner.y)
        ..add(corner.z);
      normals
        ..add(normal.x)
        ..add(normal.y)
        ..add(normal.z);
    }
    indices
      ..addAll(<int>[base, base + 1, base + 2])
      ..addAll(<int>[base, base + 2, base + 3]);
  }

  quad(const <Vector3>[
    Vector3(-1, -1, 0),
    Vector3(1, -1, 0),
    Vector3(1, 1, 0),
    Vector3(-1, 1, 0),
  ], const Vector3(0, 0, 1));
  // Rotated about y by roughly 50 degrees, so the two planes cross along a line
  // that runs diagonally across the picture rather than down its middle.
  const double c = 0.6428;
  const double s = 0.7660;
  quad(const <Vector3>[
    Vector3(-c, -1, s),
    Vector3(c, -1, -s),
    Vector3(c, 1, -s),
    Vector3(-c, 1, s),
  ], const Vector3(s, 0, c));

  return Mesh3D(
    name: 'crossing quads',
    format: 'generated',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
        positions: Float32List.fromList(positions),
        indices: Uint32List.fromList(indices),
        normals: Float32List.fromList(normals),
        material: const MeshMaterial(
          colorArgb: 0xFFD0C0A0,
          doubleSided: true,
        ),
      ),
    ],
  );
}

/// A checkerboard of two saturated colours, [size] texels square.
///
/// Saturated, so a red-blue swap between `0xAARRGGBB` in Dart and the texture's
/// DXGI format is 151 levels rather than a shade. The size is a parameter
/// because the two textured scenes want opposite things from it: one wants as
/// few texel boundaries as possible, the other as many.
MeshTexture _checkerboard({int size = 8}) {
  final Uint32List pixels = Uint32List(size * size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      pixels[y * size + x] = (x + y).isEven ? 0xFFE04020 : 0xFF2040E0;
    }
  }
  return MeshTexture(
      width: size, height: size, pixels: pixels, name: 'checkerboard $size');
}

// ---------------------------------------------------------------------------
// The device
// ---------------------------------------------------------------------------

final class _MeshSession {
  _MeshSession._(this.device, this._renderer, this.skipReason);

  final D3d12RenderDevice? device;
  final D3d12MeshRenderer? _renderer;

  /// Null when the device opened. A string when it did not, so a run with no
  /// GPU reports what was missing rather than passing quietly.
  final String? skipReason;

  D3d12MeshRenderer get renderer => _renderer!;

  static _MeshSession open() {
    if (!Platform.isWindows) {
      return _MeshSession._(null, null,
          'Direct3D 12 needs Windows; this is ${Platform.operatingSystem}');
    }
    final D3d12DeviceAttempt attempt;
    try {
      attempt = D3d12RenderDevice.open();
    } on Object catch (error) {
      return _MeshSession._(null, null, 'no D3D12 device: $error');
    }
    final D3d12RenderDevice? device = attempt.device;
    if (device == null) {
      return _MeshSession._(
          null, null, 'no Direct3D 12 device: ${attempt.failureText}');
    }
    final Object built = D3d12MeshRenderer.create(device);
    if (built is BackendDiagnostic) {
      device.dispose();
      return _MeshSession._(null, null,
          'the mesh pipeline was refused: ${built.message}; ${built.detail}');
    }
    return _MeshSession._(device, built as D3d12MeshRenderer, null);
  }

  /// A BGRA target, for the reason `_renderCpu` gives: the readback and the
  /// CPU framebuffer have to store their channels in the same order or every
  /// coloured pixel reads as a difference and every grey one as a match.
  D3d12OffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.bgra8888Premultiplied,
      )) as D3d12OffscreenTarget;

  void close() {
    _renderer?.dispose();
    device?.dispose();
  }
}
