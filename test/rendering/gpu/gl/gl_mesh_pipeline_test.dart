/// The same model down the CPU rasteriser and the GL mesh pipeline.
///
/// The differential rule `test/differential/cpu_gpu_parity_test.dart` states
/// applies here unchanged: one scene, two renderers, one comparison, and no
/// reference written by hand. Where the two disagree one of them is wrong, and
/// the tolerance is not the place to record that.
///
/// ## The tolerance, declared
///
/// Unlike the 2D suite this cannot declare zero, and `tool/mesh_scenes.dart`
/// carries the argument for why: two triangle rasterisers make a *coverage*
/// decision per pixel, GL makes it on a fixed-point sub-pixel grid with a
/// top-left fill rule and `MeshRasterizer` makes it in float at pixel centres
/// with an inclusive test on both sides, so a boundary pixel can legitimately
/// be background in one image and lit surface in the other. That is a
/// difference of a hundred levels with nothing wrong.
///
/// So the comparison is split, and only the half with a bound on it is tight:
///
///   * **interior deviation ≤ 2**, over pixels whose 3x3 neighbourhood in the
///     CPU image spans at most two levels. Away from a discontinuity a
///     one-pixel coverage disagreement cannot move a value by more than that
///     spread, so anything above it is a real disagreement about *shading*.
///     Measured on Intel UHD Graphics through `tool/gl_mesh_probe.dart`:
///     **0** for flat and unlit, **1** for smooth on the built-in scene, and
///     **2** on `sonic.glb`, `robotnik.glb`, `StarShip2.obj` and the
///     451,838-triangle `Mario+Kart+3D+Statue.stl` at 1080x780. The one level
///     on the smooth path is the sphere, and it is explained: GL interpolates
///     a varying with perspective correction and `MeshRasterizer` interpolates
///     normals affinely, on purpose.
///   * **edge ratio ≤ 1**, the differing pixels over the pixels sitting on a
///     discontinuity in the CPU image. It says the differences are confined to
///     boundaries rather than spread across surfaces. Measured: 0.02 on the
///     451,838-triangle model, 0.08 on the built-in scene, 0.56 on the
///     textured `sonic.glb` - a nearest-sampled texture puts a discontinuity
///     at every texel boundary, which is why that one is higher and still
///     under the budget.
///
/// Neither is a knob. If the interior deviation moves, one of the two shading
/// paths changed and the answer is to find which.
///
/// ## What is deliberately not compared
///
/// **Wireframe.** `MeshRasterizer._line` is Bresenham with a hand-rolled depth
/// bias; GL rasterises a line with its own diamond-exit rule and no bias. They
/// draw the same edges and put different pixels on them - measured at an
/// interior deviation of 216 - so comparing them would be measuring two line
/// rasterisers rather than the mesh pipeline. The mode is drawn and is not
/// claimed to match.
///
/// ## And a headless test does not prove a backend works
///
/// This file renders into a framebuffer object it creates with a depth
/// renderbuffer attached, so it can say nothing about whether a *window's*
/// pixel format carries depth bits - and a surface without them depth-tests
/// against nothing and reports no error at all. `tool/gl_mesh_probe.dart` is
/// the file that answers that, on a real `HWND`, and it found 24 bits.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_mesh_pipeline.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:test/test.dart';

// The scene and the metric live with the probe on purpose: a test and a probe
// that measured different scenes could disagree about whether the pipeline
// works without either being wrong. See that file's library comment.
import '../../../../tool/mesh_scenes.dart';

/// Small enough that a full comparison is cheap, large enough that the sphere
/// covers a few thousand pixels - a scene rendered at 64x64 agrees trivially
/// because almost every pixel is a boundary.
const int _width = 320;
const int _height = 240;

/// See the library comment. Not a knob.
const int _interiorTolerance = 2;
const double _edgeRatioBudget = 1.0;

void main() {
  final _GlSession session = _GlSession.open();
  tearDownAll(session.close);

  final Mesh3D scene = buildProbeScene();

  group('the GL mesh pipeline', () {
    test('links its program on a real context', () {
      if (session.skip('a program cannot be linked without one')) return;
      expect(session.pipeline, isNotNull);
      expect(session.diagnostics, isEmpty);
    });

    test('its off-screen target really has depth bits', () {
      if (session.skip('nothing to query')) return;
      // The check that a headless suite *can* make honestly: this framebuffer
      // is one this test attached a GL_DEPTH_COMPONENT24 renderbuffer to, so
      // 24 here proves the attachment, not the window.
      expect(session.pipeline!.depthBitsOfCurrentTarget(), 24);
    });

    test('smooth shading matches the CPU rasteriser: interior 1, edge 0.08',
        () {
      // Observed on Intel UHD Graphics: interior deviation 1, edge ratio 0.08.
      // The one level is the sphere - the only shape whose normal varies
      // inside a triangle - and it is the affine/perspective interpolation
      // difference named in the library comment.
      _expectParity(session, scene, MeshShading.smooth);
    });

    test('flat shading matches the CPU rasteriser: interior 0, edge 0.00', () {
      // Zero, and it should be: a face normal is constant across a triangle,
      // so perspective correction has nothing to change. Six differing pixels
      // out of 149,000 on the probe's larger frame, all on silhouettes.
      _expectParity(session, scene, MeshShading.flat);
    });

    test('unlit matches the CPU rasteriser: interior 0, edge 0.00', () {
      // The texture path with the lighting taken out, so a failure here is
      // the sampler or the base-colour multiply and cannot be the shading.
      _expectParity(session, scene, MeshShading.unlit);
    });

    test('the geometry is uploaded once, not once a frame', () {
      if (session.skip('nothing to upload')) return;
      final GlMeshPipeline pipeline = session.pipeline!;
      session.surface!.bind();
      _render(pipeline, scene, MeshShading.smooth);
      final int afterFirst = pipeline.bufferUploadCount;
      final int bytesAfterFirst = pipeline.uploadedByteCount;
      expect(afterFirst, greaterThan(0),
          reason: 'a frame that uploaded nothing drew nothing');

      for (var frame = 0; frame < 8; frame++) {
        _render(pipeline, scene, MeshShading.smooth);
      }
      // The whole point of the cache. A 451,838-triangle model is 46.5 MB of
      // vertices; re-uploading it at 60 Hz is 2.8 GB/s for geometry that never
      // changed.
      expect(pipeline.bufferUploadCount, afterFirst);
      expect(pipeline.uploadedByteCount, bytesAfterFirst);
      expect(pipeline.lastError, isNull);
    });

    test('switching shading mode uploads the faceted buffer once more', () {
      if (session.skip('nothing to upload')) return;
      final GlMeshPipeline pipeline = session.pipeline!;
      // A *second* build of the scene, so this test's primitives are objects
      // the cache has never seen. Reusing `scene` would measure whatever the
      // parity tests above happened to have built already, and the answer
      // would depend on the order the tests ran in.
      final Mesh3D fresh = buildProbeScene();
      session.surface!.bind();
      _render(pipeline, fresh, MeshShading.smooth);
      final int afterSmooth = pipeline.bufferUploadCount;
      _render(pipeline, fresh, MeshShading.flat);
      final int afterFlat = pipeline.bufferUploadCount;
      // Flat needs a de-indexed buffer that smooth cannot supply - a face
      // normal is not any vertex's attribute - so it pays one upload per
      // primitive and then never again.
      expect(afterFlat, greaterThan(afterSmooth));
      _render(pipeline, fresh, MeshShading.flat);
      expect(pipeline.bufferUploadCount, afterFlat);
      // And going back is free, which is what proves the first buffer was kept
      // rather than replaced.
      _render(pipeline, fresh, MeshShading.smooth);
      expect(pipeline.bufferUploadCount, afterFlat);
      pipeline.releaseMesh(fresh);
    });
  });

  group('the comparison can fail', () {
    // A parity suite that passes with the depth test disabled is not testing
    // the depth buffer, and one that passes with the winding reversed is not
    // testing culling. Both knobs exist for exactly this, and both are
    // documented as diagnostics-only on GlMeshPipeline.

    test('a depth test of GL_ALWAYS moves the interior by 180 levels', () {
      if (session.skip('nothing to sabotage')) return;
      final MeshImageDiff sane = _diff(session, scene, MeshShading.smooth);
      final GlMeshPipeline pipeline = session.pipeline!;
      pipeline.debugDepthFunc = glAlways;
      final MeshImageDiff broken;
      try {
        broken = _diff(session, scene, MeshShading.smooth);
      } finally {
        pipeline.debugDepthFunc = glLess;
      }
      // Measured at 480x360: interior 1 -> 180, differing 0.94% -> 10.29%.
      // The far box is submitted after the near one, so without a depth test
      // it paints over it.
      expect(sane.interiorDeviation, lessThanOrEqualTo(_interiorTolerance));
      expect(broken.interiorDeviation, greaterThan(50),
          reason: 'the scene has nothing occluding anything, so this suite '
              'would pass with no depth buffer at all');
      expect(broken.differingPixels, greaterThan(sane.differingPixels * 5));
    });

    test('a front face of GL_CW moves the interior by 195 levels', () {
      if (session.skip('nothing to sabotage')) return;
      final MeshImageDiff sane = _diff(session, scene, MeshShading.smooth);
      final GlMeshPipeline pipeline = session.pipeline!;
      pipeline.debugFrontFace = glCw;
      final MeshImageDiff broken;
      try {
        broken = _diff(session, scene, MeshShading.smooth);
      } finally {
        pipeline.debugFrontFace = glCcw;
      }
      // Measured at 480x360: interior 1 -> 195, differing 0.94% -> 52.13%,
      // edge ratio 0.08 -> 4.24. Both closed boxes and the sphere turn inside
      // out, which is the failure that reads as a normals bug.
      expect(sane.interiorDeviation, lessThanOrEqualTo(_interiorTolerance));
      expect(broken.interiorDeviation, greaterThan(50));
      expect(broken.edgeRatio, greaterThan(_edgeRatioBudget));
    });
  });

  group('normalMatrixOf', () {
    // Pure arithmetic, so it needs no GL and runs everywhere. It is tested
    // separately because the pipeline's own frames pass the identity - the CPU
    // rasteriser has no model matrix - so nothing else here would exercise it.

    test('is the identity for a rotation', () {
      // A rotation is orthonormal, so its inverse transpose is itself. This is
      // the case that would still pass if the transpose had been dropped, and
      // it is here to pin the convention rather than to catch a bug.
      // Normalised here rather than written out: a quaternion that is a
      // thousandth off unit length produces a matrix that is a thousandth off
      // orthonormal, and the test would then be measuring the quaternion.
      const double x = 0.2;
      const double y = 0.3;
      const double z = 0.1;
      const double w = 0.9;
      final double norm = math.sqrt(x * x + y * y + z * z + w * w);
      final Matrix4 rotation = Matrix4.rotationFromQuaternion(
          x / norm, y / norm, z / norm, w / norm);
      final Matrix4 normal = normalMatrixOf(rotation);
      for (var i = 0; i < 12; i++) {
        if (i % 4 == 3) continue;
        expect(normal[i], closeTo(rotation[i], 1e-12));
      }
    });

    test('inverts a non-uniform scale rather than repeating it', () {
      // The case the matrix exists for. Scaling x by 4 makes a surface's
      // normal tilt the *other* way; multiplying the normal by the model
      // matrix would tilt it with the surface and light a squashed sphere as
      // if the light had moved.
      final Matrix4 scale = Matrix4.scale(const Vector3(4, 1, 1));
      final Matrix4 normal = normalMatrixOf(scale);
      expect(normal[0], closeTo(0.25, 1e-12));
      expect(normal[5], closeTo(1, 1e-12));
      expect(normal[10], closeTo(1, 1e-12));
    });

    test('a singular matrix gives the identity, not infinities', () {
      // Exporters produce zero-axis scales. A matrix of infinities would put
      // NaN into every normal that shares a vertex, which is the argument
      // `Vector3.normalized` already makes for returning zero.
      final Matrix4 flattened = normalMatrixOf(Matrix4.scale(
        const Vector3(1, 0, 1),
      ));
      expect(flattened[0], 1);
      expect(flattened[5], 1);
      expect(flattened[10], 1);
    });
  });
}

// ---------------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------------

void _expectParity(_GlSession session, Mesh3D scene, MeshShading shading) {
  if (session.skip('there is nothing to compare')) return;
  final MeshImageDiff diff = _diff(session, scene, shading);
  printOnFailure('$diff\n${diff.report}');
  expect(
    diff.interiorDeviation,
    lessThanOrEqualTo(_interiorTolerance),
    reason: 'the two paths disagree by ${diff.interiorDeviation} levels away '
        'from any edge, over a declared tolerance of $_interiorTolerance. '
        'That is a shading difference, not a rasterisation one.\n'
        '${diff.report}',
  );
  expect(
    diff.edgeRatio,
    lessThanOrEqualTo(_edgeRatioBudget),
    reason: 'the differences are not confined to boundaries: '
        '${diff.differingPixels} pixels differ against ${diff.edgePixels} '
        'sitting on a discontinuity',
  );
}

MeshImageDiff _diff(_GlSession session, Mesh3D scene, MeshShading shading) {
  final GlMeshPipeline pipeline = session.pipeline!;
  session.surface!.bind();
  _render(pipeline, scene, shading);
  final Framebuffer gpu = Framebuffer.allocate(width: _width, height: _height);
  expect(session.surface!.readInto(gpu), isTrue);
  expect(pipeline.lastError, isNull);
  expect(pipeline.depthDiagnostic, isNull);

  final Framebuffer cpu = Framebuffer.allocate(width: _width, height: _height);
  MeshRasterizer().render(cpu, scene, probeSceneCamera, shading: shading);

  // Two blank surfaces agree perfectly, so a scene that drew nothing would
  // pass silently - the same guard the 2D differential suite keeps.
  expect(_isUniform(cpu), isFalse,
      reason: 'the CPU render is blank, so comparing it proves nothing');
  expect(_isUniform(gpu), isFalse, reason: 'the GL render is blank');

  return compareMeshImages(cpu, gpu);
}

void _render(GlMeshPipeline pipeline, Mesh3D scene, MeshShading shading) {
  pipeline.render(
    mesh: scene,
    camera: probeSceneCamera,
    width: _width,
    height: _height,
    shading: shading,
    measure: true,
  );
}

bool _isUniform(Framebuffer buffer) {
  final Uint8List pixels = buffer.pixels;
  final int first = buffer.offsetOf(0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      final int at = buffer.offsetOf(x, y);
      if (pixels[at] != pixels[first] ||
          pixels[at + 1] != pixels[first + 1] ||
          pixels[at + 2] != pixels[first + 2]) {
        return false;
      }
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// Session plumbing - the shape `cpu_gpu_parity_test.dart` uses, and for the
// same reason: a context costs tens of milliseconds and, on Windows, a window.
// ---------------------------------------------------------------------------

final class _GlSession {
  _GlSession._(
    this.pipeline,
    this.surface,
    this.skipReason,
    this.diagnostics,
    this._context,
    this._glSurface,
  );

  final GlMeshPipeline? pipeline;
  final GlMeshOffscreenSurface? surface;

  /// Null when everything opened. A string when it did not, so a run with no
  /// GPU reports what was missing rather than passing quietly.
  final String? skipReason;

  final List<Object> diagnostics;
  final GlContext? _context;
  final Win32GlSurface? _glSurface;

  static _GlSession _failed(
    String reason, [
    GlContext? context,
    Win32GlSurface? glSurface,
  ]) {
    context?.dispose();
    glSurface?.dispose();
    return _GlSession._(null, null, reason, const <Object>[], null, null);
  }

  static _GlSession open() {
    if (!Platform.isWindows) {
      // The EGL path in gl_context.dart can serve one too, and wiring it here
      // without a machine to run it on would be a guess rather than a test.
      return _failed('this session only opens a WGL context; '
          '${Platform.operatingSystem} needs the EGL path wiring in');
    }
    try {
      final Win32GlSurfaceAttempt attempt = Win32GlSurface.hidden(
        width: _width,
        height: _height,
        className: 'DartUiGlMeshTest',
      );
      final Win32GlSurface? glSurface = attempt.surface;
      if (glSurface == null) {
        return _failed('no GL surface: ${attempt.diagnostics.join('; ')}');
      }
      final GlContextAttempt contextAttempt = glSurface.createContext();
      final GlContext? context = contextAttempt.context;
      if (context == null) {
        return _failed(
            'no GL context: ${contextAttempt.diagnostics.join('; ')}',
            null,
            glSurface);
      }
      if (!context.makeCurrent()) {
        return _failed(
            'the context refused to become current', context, glSurface);
      }
      final GlApi gl = GlApi(context.procAddress);
      final GlMeshPipelineAttempt built = GlMeshPipeline.create(gl: gl);
      if (built.pipeline == null) {
        return _failed('no mesh pipeline: ${built.diagnostics.join('; ')}',
            context, glSurface);
      }
      final Object target = GlMeshOffscreenSurface.create(
        api: gl,
        heap: NativeHeap.tryBind(null)!,
        width: _width,
        height: _height,
      );
      if (target is! GlMeshOffscreenSurface) {
        built.pipeline!.dispose();
        return _failed('no off-screen target: $target', context, glSurface);
      }
      return _GlSession._(
        built.pipeline,
        target,
        null,
        built.diagnostics,
        context,
        glSurface,
      );
    } on Object catch (error) {
      return _failed('opening a GL session threw: $error');
    }
  }

  /// Marks the current test skipped and returns true when there is no device.
  ///
  /// Printed rather than silent, like the 2D differential suite: a run with no
  /// GPU has to say so instead of looking like a run that compared something.
  bool skip(String what) {
    final String? reason = skipReason;
    if (reason == null) return false;
    markTestSkipped('no GL mesh pipeline, so $what: $reason');
    return true;
  }

  void close() {
    surface?.dispose();
    pipeline?.dispose();
    _context?.dispose();
    _glSurface?.dispose();
  }
}
